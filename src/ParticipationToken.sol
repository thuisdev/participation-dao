// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {
    AccessControlDefaultAdminRules
} from "@openzeppelin/contracts/access/extensions/AccessControlDefaultAdminRules.sol";
import {ERC20Votes} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {Nonces} from "@openzeppelin/contracts/utils/Nonces.sol";
import {Time} from "@openzeppelin/contracts/utils/types/Time.sol";

/// @title ParticipationToken - Non-transferable voting token of the Participation DAO
/// @author Adrian (thuisdev)
/// @notice Holds the voting power users earn through on-chain participation. Tokens cannot be transferred and are only
///         minted by the Earner contract. Holders must delegate (to themselver or another acc)
/// @dev DAO-1: ERC20Votes stores checkpoints of voting power, which the Governor reads via getPastVotes.
///      DAO-1 / DAO-5: delegate, delegateBySig, delegates, getVotes, getPastVotes, getPastTotalSupply and the events
///      DelegateChanged and DelegateVotesChanged are inherited unchanged from OpenZeppelin Votes, which keeps the token
///      compatible with the Governor and with Snapshot. The clock is overridden to timestamps (ERC-6372) so Governor
///      periods, the timelock delay and Earner epochs all use seconds.
contract ParticipationToken is ERC20, AccessControlDefaultAdminRules, ERC20Permit, ERC20Votes {
    // -------------------------------------------------------------------------
    // Constants
    // -------------------------------------------------------------------------

    /// @notice Role allowed to mint voting points. Granted to the Earner contract in the deploy script.
    /// @dev DAO-1 / DAO-8: minting is restricted to the Earner through AccessControl.
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");

    // -------------------------------------------------------------------------
    // Errors
    // -------------------------------------------------------------------------

    /// @notice Thrown when tokens would move between non-zero addresses (transfer or transferFrom).
    error NonTransferable();

    // -------------------------------------------------------------------------
    // Constructor
    // -------------------------------------------------------------------------

    /// @notice Deploys the token and assigns the initial default admin.
    /// @dev DAO-8: AccessControlDefaultAdminRules makes admin transfers two-step and delayed by `initialAdminDelay`.
    ///      Reverts with AccessControlInvalidDefaultAdmin if `initialAdmin` is the zero address. MINTER_ROLE is not
    ///      granted here because the Earner is deployed after the token and needs the token address in its constructor.
    /// @param initialAdmin Account that receives DEFAULT_ADMIN_ROLE and grants MINTER_ROLE to the Earner.
    /// @param initialAdminDelay Seconds a newly proposed admin has to wait before it can accept the admin role.
    constructor(address initialAdmin, uint48 initialAdminDelay)
        ERC20("ParticipationToken", "PT")
        ERC20Permit("ParticipationToken")
        AccessControlDefaultAdminRules(initialAdminDelay, initialAdmin)
    {}

    // -------------------------------------------------------------------------
    // External functions
    // -------------------------------------------------------------------------

    /// @notice Mints voting points to an account.
    /// @dev DAO-1: only callable by MINTER_ROLE (the Earner). Minted points only
    ///      count as votes once `to` has delegated.
    /// @param to Account receiving the points.
    /// @param amount Number of points to mint, with 18 decimals.
    function mint(address to, uint256 amount) external onlyRole(MINTER_ROLE) {
        _mint(to, amount);
    }

    // -------------------------------------------------------------------------
    // Public Functions
    // -------------------------------------------------------------------------

    /// @notice Returns the current timepoint used for vote checkpoints.
    /// @dev ERC-6372: overridden from block numbers to timestamps. The Governor reads this clock from the token and
    ///      interprets votingDelay and votingPeriod in seconds.
    /// @return timepoint Current block timestamp as uint48.
    function clock() public view override returns (uint48) {
        return Time.timestamp();
    }

    /// @notice Returns the next unused nonce of an account for permit and delegateBySig signatures.
    /// @dev Required override because ERC20Permit and Votes both inherit Nonces. The nonce prevents signature replay.
    /// @param owner Account whose nonce is queried.
    /// @return nonce Current nonce of `owner`.
    function nonces(address owner) public view override(ERC20Permit, Nonces) returns (uint256) {
        return super.nonces(owner);
    }

    /// @notice Describes the clock so off-chain tools (Tally, Snapshot, frontends) interpret timepoints correctly.
    /// @dev ERC-6372: must match clock(). Has no on-chain effect.
    /// @return mode The string "mode=timestamp".
    function CLOCK_MODE() public pure override returns (string memory) {
        return "mode=timestamp";
    }

    // -------------------------------------------------------------------------
    // Internal Functions
    // -------------------------------------------------------------------------

    /// @notice Updates balances and voting units on mint and burn, and blocks every transfer.
    /// @dev DAO-1: the token is non-transferable. Only mints (`from` is zero) and burns (`to` is zero) pass. transfer and
    ///      transferFrom both route through this function and revert. super._update calls ERC20Votes, which moves the
    ///      voting units to the delegate of `to` and writes a checkpoint.
    /// @param from Sender, the zero address for mints.
    /// @param to Recipient, the zero address for burns.
    /// @param value Amount of tokens moved.
    function _update(address from, address to, uint256 value) internal override(ERC20, ERC20Votes) {
        if (from != address(0) && to != address(0)) {
            revert NonTransferable();
        }
        super._update(from, to, value);
    }
}
