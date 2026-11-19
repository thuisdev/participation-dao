// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

/// @title Treasury - ETH and ERC20 vault of the Participation DAO
/// @author Adrian (thuisdev)
/// @notice Holds the ETH and ERC20 tokens the DAO receives, mainly ETH via Earner.fundTreasury. Funds can only leave
///         through an approved governance proposal executed by the timelock, and payouts can be paused in an emergency.
/// @dev DAO-3: owned by the TimelockController from deployment. The owner is set directly in the constructor, so no
///      acceptOwnership proposal is needed; Ownable2Step still protects every later ownership transfer. Only the owner
///      can release ETH or ERC20 tokens, and both payout paths are protected by ReentrancyGuardTransient. DAO-7:
///      releaseETH is the concrete action that approved proposals execute. DAO-8: Ownable controls payouts,
///      AccessControl controls pausing; the timelock is both owner and DEFAULT_ADMIN_ROLE, so every permission is
///      managed by governance while a separate PAUSER_ROLE can stop payouts quickly.
contract Treasury is Ownable2Step, ReentrancyGuardTransient, Pausable, AccessControl {
    using SafeERC20 for IERC20;

    // -------------------------------------------------------------------------
    // Constants
    // -------------------------------------------------------------------------

    /// @notice Role allowed to pause and unpause releaseETH and releaseERC20.
    /// @dev DAO-8: separate from DEFAULT_ADMIN_ROLE so a fast responder can pause while role changes stay with governance.
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    /// @notice Emitted when ETH is released to a receiver.
    /// @dev DAO-7: emitted before the transfer (checks-effects-interactions).
    /// @param receiver Account that receives the ETH.
    /// @param amount Amount released in wei.
    event GrantReleased(address indexed receiver, uint256 amount);

    /// @notice Emitted when ERC20 tokens are released to a receiver.
    /// @dev DAO-3: emitted before the transfer (checks-effects-interactions).
    /// @param token ERC20 token that was released.
    /// @param receiver Account that receives the tokens.
    /// @param amount Amount released in the token's smallest unit.
    event ERC20Released(IERC20 indexed token, address indexed receiver, uint256 amount);

    // -------------------------------------------------------------------------
    // Errors
    // -------------------------------------------------------------------------

    /// @notice Thrown when the receiver is the zero address.
    error ZeroAddress();

    /// @notice Thrown when a payout of zero is requested.
    error ZeroAmount();

    /// @notice Thrown when the Treasury holds less ETH or tokens than requested.
    /// @param available Current balance of the Treasury (wei for ETH, smallest unit for tokens).
    /// @param requested Amount requested.
    error InsufficientBalance(uint256 available, uint256 requested);

    /// @notice Thrown when sending ETH to the receiver fails.
    error TransferFailed();

    // -------------------------------------------------------------------------
    // Constructor
    // -------------------------------------------------------------------------

    /// @notice Deploys the Treasury with the timelock as owner and role admin, and assigns the initial pauser.
    /// @dev DAO-3: Ownable reverts with OwnableInvalidOwner if `timelock_` is the zero address. DAO-8: the timelock
    ///      receives DEFAULT_ADMIN_ROLE so only governance can grant or revoke PAUSER_ROLE.
    /// @param timelock_ TimelockController that owns the Treasury, executes approved payouts and manages roles.
    /// @param initialPauser Account that receives PAUSER_ROLE and can pause payouts without a proposal.
    constructor(address timelock_, address initialPauser) Ownable(timelock_) {
        _grantRole(DEFAULT_ADMIN_ROLE, timelock_);
        _grantRole(PAUSER_ROLE, initialPauser);
    }

    // -------------------------------------------------------------------------
    // Receive
    // -------------------------------------------------------------------------

    /// @notice Accepts plain ETH transfers, e.g. funding forwarded by the Earner or direct donations.
    /// @dev DAO-3: direct transfers do not earn points; only Earner.fundTreasury does. Not pausable, so funding never
    ///      gets stuck in the Earner while payouts are paused.
    receive() external payable {}

    // -------------------------------------------------------------------------
    // External functions
    // -------------------------------------------------------------------------

    /// @notice Sends ETH from the Treasury to a receiver.
    /// @dev DAO-3 / DAO-7: only callable by the owner (the timelock), so ETH only moves through an executed proposal.
    ///      Checks non-zero receiver, non-zero amount and sufficient balance. DAO-8: blocked while paused; checks, then
    ///      event, then the ETH transfer as the last step, additionally guarded by nonReentrant.
    /// @param receiver Account that receives the ETH.
    /// @param amount Amount to send in wei.
    function releaseETH(address payable receiver, uint256 amount) external nonReentrant onlyOwner whenNotPaused {
        _checkReceiverAndAmount(receiver, amount);

        uint256 available = address(this).balance;
        if (amount > available) {
            revert InsufficientBalance(available, amount);
        }

        emit GrantReleased(receiver, amount);

        (bool success,) = receiver.call{value: amount}("");
        if (!success) {
            revert TransferFailed();
        }
    }

    /// @notice Sends ERC20 tokens held by the Treasury to a receiver.
    /// @dev DAO-3: the Treasury can hold any ERC20 and only the owner (the timelock) can release it, so no token gets
    ///      stuck. SafeERC20 reverts on failure and supports tokens that do not return a bool. DAO-8: blocked while
    ///      paused; checks, then event, then the transfer, guarded by nonReentrant.
    /// @param token ERC20 token to release.
    /// @param receiver Account that receives the tokens.
    /// @param amount Amount to send in the token's smallest unit.
    function releaseERC20(IERC20 token, address receiver, uint256 amount)
        external
        nonReentrant
        onlyOwner
        whenNotPaused
    {
        _checkReceiverAndAmount(receiver, amount);

        uint256 available = token.balanceOf(address(this));
        if (amount > available) {
            revert InsufficientBalance(available, amount);
        }

        emit ERC20Released(token, receiver, amount);

        token.safeTransfer(receiver, amount);
    }

    /// @notice Pauses releaseETH and releaseERC20.
    /// @dev DAO-8: only callable by PAUSER_ROLE. Emits Paused. A proposal queued during the pause can only be executed
    ///      after unpausing.
    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    /// @notice Resumes releaseETH and releaseERC20.
    /// @dev DAO-8: only callable by PAUSER_ROLE. Emits Unpaused.
    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    // -------------------------------------------------------------------------
    // Private functions
    // -------------------------------------------------------------------------

    /// @notice Reverts if the receiver is the zero address or the amount is zero.
    /// @dev DAO-7: shared input checks of releaseETH and releaseERC20.
    /// @param receiver Account that would receive the payout.
    /// @param amount Requested payout amount.
    function _checkReceiverAndAmount(address receiver, uint256 amount) private pure {
        if (receiver == address(0)) {
            revert ZeroAddress();
        }
        if (amount == 0) {
            revert ZeroAmount();
        }
    }
}
