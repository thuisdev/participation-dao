// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {BitMaps} from "@openzeppelin/contracts/utils/structs/BitMaps.sol";

import {ParticipationToken} from "./ParticipationToken.sol";
import {Treasury} from "./Treasury.sol";

/// @title Earner - Converts on-chain participation into voting points
/// @author Adrian (thuisdev)
/// @notice Users earn ParticipationToken points by checking in once per epoch or by funding the DAO Treasury with ETH.
///         Points are capped per user and in total per epoch, so influence grows with participation, not with capital.
/// @dev DAO-4: two earning actions (checkIn, fundTreasury), per-user and global caps per epoch, check-in claims stored
///      in a per-user bitmap (one bit per epoch), awarded points stored in per-epoch counters, PointsEarned on every
///      award. DAO-5: constant-time views for the current epoch, check-in status and remaining caps. DAO-8:
///      AccessControl manages DEFAULT_ADMIN_ROLE and PAUSER_ROLE, both earning actions are blocked while paused, and
///      the ETH transfer follows checks-effects-interactions. The Earner needs MINTER_ROLE on the token.
contract Earner is AccessControl, Pausable {
    using BitMaps for BitMaps.BitMap;

    // -------------------------------------------------------------------------
    // Type declarations
    // -------------------------------------------------------------------------

    /// @notice Action that earned the points, emitted in PointsEarned so indexers can tell both actions apart.
    enum Action {
        CheckIn,
        Funding
    }

    // -------------------------------------------------------------------------
    // Constants & immutables
    // -------------------------------------------------------------------------

    /// @notice Length of one epoch. Check-ins and caps reset every epoch.
    uint256 public constant EPOCH_DURATION = 1 days;

    /// @notice Points awarded for one check-in (10 points, 18 decimals).
    uint256 public constant CHECK_IN_POINTS = 10e18;

    /// @notice Maximum points one user can earn per epoch, from both actions combined (50 points).
    uint256 public constant USER_CAP_PER_EPOCH = 50e18;

    /// @notice Maximum points all users together can earn per epoch (1,000 points).
    uint256 public constant GLOBAL_CAP_PER_EPOCH = 1_000e18;

    /// @notice Points per 1 ETH funded. Wei and points both use 18 decimals, so points = msg.value * POINTS_PER_ETH.
    uint256 public constant POINTS_PER_ETH = 100;

    /// @notice Role allowed to pause and unpause both earning actions.
    /// @dev DAO-8: separate from DEFAULT_ADMIN_ROLE so a fast responder can pause while role changes stay with governance.
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    /// @notice Timestamp at which epoch 0 starts (deployment time).
    uint256 public immutable START_TIME;

    /// @notice Treasury that receives all ETH sent via fundTreasury.
    Treasury public immutable TREASURY;

    /// @notice Voting token whose points are minted by this contract.
    ParticipationToken public immutable TOKEN;

    // -------------------------------------------------------------------------
    // State variables
    // -------------------------------------------------------------------------

    /// @dev DAO-4: one bitmap per user, bit index = epoch. 256 epochs share one storage slot.
    mapping(address user => BitMaps.BitMap) private _checkIns;

    /// @dev DAO-4: points a user earned in an epoch, checked against USER_CAP_PER_EPOCH. A new epoch starts at zero.
    mapping(uint256 epoch => mapping(address user => uint256 points)) private _userPointsInEpoch;

    /// @dev DAO-4: points all users earned in an epoch, checked against GLOBAL_CAP_PER_EPOCH.
    mapping(uint256 epoch => uint256 points) private _totalPointsInEpoch;

    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    /// @notice Emitted whenever points are awarded.
    /// @dev DAO-4: emitted before the mint so the event order follows checks-effects-interactions.
    /// @param user Account that earned the points.
    /// @param epoch Epoch in which the points were earned.
    /// @param action Action that earned the points.
    /// @param points Points awarded (18 decimals).
    event PointsEarned(address indexed user, uint256 indexed epoch, Action action, uint256 points);

    // -------------------------------------------------------------------------
    // Errors
    // -------------------------------------------------------------------------

    /// @notice Thrown when a user tries to check in twice in the same epoch.
    /// @param epoch Epoch the user already checked in.
    error AlreadyCheckedIn(uint256 epoch);

    /// @notice Thrown when an award would exceed the user's cap for the current epoch.
    /// @param remaining Points the user can still earn in this epoch.
    /// @param requested Points the action would award.
    error UserCapExceeded(uint256 remaining, uint256 requested);

    /// @notice Thrown when an award would exceed the global cap for the current epoch.
    /// @param remaining Points all users together can still earn in this epoch.
    /// @param requested Points the action would award.
    error GlobalCapExceeded(uint256 remaining, uint256 requested);

    /// @notice Thrown when fundTreasury is called without ETH.
    error ZeroAmount();

    /// @notice Thrown when forwarding ETH to the Treasury fails.
    error TransferFailed();

    /// @notice Thrown when the initial admin is the zero address.
    error ZeroAddress();

    // -------------------------------------------------------------------------
    // Constructor
    // -------------------------------------------------------------------------

    /// @notice Deploys the Earner, starts epoch 0 and assigns the initial roles.
    /// @dev DAO-8: reverts with ZeroAddress if `initialAdmin` is zero, since nobody could manage roles afterwards. The
    ///      Treasury must be deployed first. MINTER_ROLE on the token is granted to this contract by the token admin
    ///      after deployment.
    /// @param token_ ParticipationToken that this contract mints points on.
    /// @param treasury_ Treasury that receives funded ETH.
    /// @param initialPauser Account that receives PAUSER_ROLE.
    /// @param initialAdmin Account that receives DEFAULT_ADMIN_ROLE and can grant or revoke roles.
    constructor(ParticipationToken token_, Treasury treasury_, address initialPauser, address initialAdmin) {
        if (initialAdmin == address(0)) {
            revert ZeroAddress();
        }

        START_TIME = block.timestamp;
        TOKEN = token_;
        TREASURY = treasury_;

        _grantRole(DEFAULT_ADMIN_ROLE, initialAdmin);
        _grantRole(PAUSER_ROLE, initialPauser);
    }

    // -------------------------------------------------------------------------
    // External functions
    // -------------------------------------------------------------------------

    /// @notice Funds the DAO Treasury with ETH and earns POINTS_PER_ETH points per ETH.
    /// @dev DAO-4: second earning action, subject to both caps. If a cap is exceeded the whole transaction reverts and
    ///      the ETH stays with the user. DAO-8: blocked while paused; points are recorded and minted (effects) before the
    ///      ETH is forwarded to the Treasury (interaction).
    function fundTreasury() external payable whenNotPaused {
        uint256 amount = msg.value;

        if (amount == 0) {
            revert ZeroAmount();
        }

        uint256 points = amount * POINTS_PER_ETH;

        uint256 epoch = currentEpoch();

        _awardPoints(msg.sender, epoch, points, Action.Funding);

        (bool success,) = address(TREASURY).call{value: amount}("");
        if (!success) {
            revert TransferFailed();
        }
    }

    /// @notice Checks in for the current epoch and earns CHECK_IN_POINTS.
    /// @dev DAO-4: first earning action, claimable once per epoch. The claim is marked in the caller's bitmap before
    ///      points are awarded. DAO-8: blocked while paused.
    function checkIn() external whenNotPaused {
        uint256 epoch = currentEpoch();

        if (_checkIns[msg.sender].get(epoch)) {
            revert AlreadyCheckedIn(epoch);
        }

        _checkIns[msg.sender].set(epoch);

        _awardPoints(msg.sender, epoch, CHECK_IN_POINTS, Action.CheckIn);
    }

    /// @notice Pauses checkIn and fundTreasury.
    /// @dev DAO-8: only callable by PAUSER_ROLE. Emits Paused.
    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    /// @notice Resumes checkIn and fundTreasury.
    /// @dev DAO-8: only callable by PAUSER_ROLE. Emits Unpaused.
    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    /// @notice Returns whether a user has already checked in during a given epoch.
    /// @dev DAO-5: constant-time view, reads one bit from the user's check-in bitmap.
    /// @param user Account to query.
    /// @param epoch Epoch to query.
    /// @return claimed True if `user` checked in during `epoch`.
    function claimedCheckIn(address user, uint256 epoch) external view returns (bool claimed) {
        return _checkIns[user].get(epoch);
    }

    /// @notice Returns how many points a user can still earn in the current epoch.
    /// @dev DAO-5: constant-time view. Cannot underflow because a user's counter never exceeds USER_CAP_PER_EPOCH.
    /// @param user Account to query.
    /// @return remaining Points the user can still earn this epoch (18 decimals).
    function remainingUserCap(address user) external view returns (uint256 remaining) {
        return USER_CAP_PER_EPOCH - _userPointsInEpoch[currentEpoch()][user];
    }

    /// @notice Returns how many points all users together can still earn in the current epoch.
    /// @dev DAO-5: constant-time view. Cannot underflow because the total never exceeds GLOBAL_CAP_PER_EPOCH.
    /// @return remaining Points still available to all users this epoch (18 decimals).
    function remainingGlobalCap() external view returns (uint256 remaining) {
        return GLOBAL_CAP_PER_EPOCH - _totalPointsInEpoch[currentEpoch()];
    }

    // -------------------------------------------------------------------------
    // Public functions
    // -------------------------------------------------------------------------

    /// @notice Returns the current epoch number, starting at 0 on deployment.
    /// @dev DAO-5: constant-time view. Integer division rounds down, so an epoch lasts exactly EPOCH_DURATION seconds.
    /// @return epoch Number of full epochs elapsed since START_TIME.
    function currentEpoch() public view returns (uint256 epoch) {
        return (block.timestamp - START_TIME) / EPOCH_DURATION;
    }

    // -------------------------------------------------------------------------
    // Internal functions
    // -------------------------------------------------------------------------

    /// @notice Checks both caps, records the points and mints them to the user.
    /// @dev DAO-4: shared by both earning actions so the cap logic exists only once. The subtractions cannot underflow
    ///      because the counters are only increased after the caps were checked. DAO-8: counters and event (effects)
    ///      come before the mint (interaction).
    /// @param user Account that earns the points.
    /// @param epoch Epoch the points count towards.
    /// @param points Points to award (18 decimals).
    /// @param action Action that earned the points.
    function _awardPoints(address user, uint256 epoch, uint256 points, Action action) internal {
        uint256 globalAvailable = GLOBAL_CAP_PER_EPOCH - _totalPointsInEpoch[epoch];
        uint256 userAvailable = USER_CAP_PER_EPOCH - _userPointsInEpoch[epoch][user];

        if (points > userAvailable) {
            revert UserCapExceeded(userAvailable, points);
        }

        if (points > globalAvailable) {
            revert GlobalCapExceeded(globalAvailable, points);
        }

        _totalPointsInEpoch[epoch] += points;
        _userPointsInEpoch[epoch][user] += points;

        emit PointsEarned(user, epoch, action, points);

        TOKEN.mint(user, points);
    }
}
