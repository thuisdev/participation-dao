// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IGovernor} from "@openzeppelin/contracts/governance/IGovernor.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

import {ParticipationGovernor} from "../src/ParticipationGovernor.sol";
import {ParticipationToken} from "../src/ParticipationToken.sol";

/// @title ParticipationGovernorTest
/// @notice DAO-2 configuration tests: governance parameters, wiring of Governor, token and timelock, and the timelock
///         role setup (Governor is sole proposer, open executor, no admin left). The proposal lifecycle is covered by the
///         DAO-6 integration test.
contract ParticipationGovernorTest is Test {
    // -------------------------------------------------------------------------
    // Constants
    // -------------------------------------------------------------------------

    uint48 private constant TOKEN_ADMIN_DELAY = 1 days;
    uint256 private constant TIMELOCK_MIN_DELAY = 10 minutes;
    uint48 private constant VOTING_DELAY = 5 minutes;
    uint32 private constant VOTING_PERIOD = 30 minutes;
    uint256 private constant PROPOSAL_THRESHOLD = 20e18;
    uint256 private constant QUORUM_PERCENTAGE = 4;

    // -------------------------------------------------------------------------
    // State
    // -------------------------------------------------------------------------

    ParticipationToken private _token;
    TimelockController private _timelock;
    ParticipationGovernor private _governor;
    address private _deployer;

    // -------------------------------------------------------------------------
    // Setup
    // -------------------------------------------------------------------------

    function setUp() public {
        _deployer = makeAddr("deployer");

        // startPrank keeps msg.sender = deployer for every call until stopPrank, so reading role constants is safe here
        vm.startPrank(_deployer);

        _token = new ParticipationToken(_deployer, TOKEN_ADMIN_DELAY);

        // DAO-2: no proposers yet (Governor does not exist), open executor, deployer as temporary admin
        address[] memory proposers = new address[](0);
        address[] memory executors = new address[](1);
        executors[0] = address(0);
        _timelock = new TimelockController(TIMELOCK_MIN_DELAY, proposers, executors, _deployer);

        _governor = new ParticipationGovernor(
            VOTING_DELAY, VOTING_PERIOD, PROPOSAL_THRESHOLD, QUORUM_PERCENTAGE, _token, _timelock
        );

        // DAO-2: Governor becomes sole proposer and canceller of the timelock
        _timelock.grantRole(_timelock.PROPOSER_ROLE(), address(_governor));
        _timelock.grantRole(_timelock.CANCELLER_ROLE(), address(_governor));

        // DAO-2: deployer gives up admin rights, from now on roles can only change through a proposal
        _timelock.renounceRole(_timelock.DEFAULT_ADMIN_ROLE(), _deployer);

        vm.stopPrank();
    }

    // -------------------------------------------------------------------------
    // Governance parameters (DAO-2)
    // -------------------------------------------------------------------------

    /// @notice DAO-2: votingDelay, votingPeriod, proposalThreshold and quorum are set from the constructor arguments.
    function test_constructor_validParams_setsGovernanceParameters() public view {
        assertEq(_governor.name(), "ParticipationGovernor");
        assertEq(_governor.votingDelay(), VOTING_DELAY);
        assertEq(_governor.votingPeriod(), VOTING_PERIOD);
        assertEq(_governor.proposalThreshold(), PROPOSAL_THRESHOLD);
        assertEq(_governor.quorumNumerator(), QUORUM_PERCENTAGE);
    }

    /// @notice DAO-2: the Governor reads votes from the ParticipationToken and executes through the timelock.
    function test_constructor_validParams_wiresTokenAndTimelock() public view {
        assertEq(address(_governor.token()), address(_token));
        assertEq(_governor.timelock(), address(_timelock));
    }

    /// @notice DAO-2: the Governor adopts the token's timestamp clock, so its durations are interpreted in seconds.
    function test_clock_fromToken_usesTimestampMode() public view {
        assertEq(_governor.CLOCK_MODE(), "mode=timestamp");
        assertEq(_governor.clock(), vm.getBlockTimestamp());
    }

    /// @notice DAO-2: parameters cannot be changed directly, only by the timelock while executing a proposal.
    function test_setVotingDelay_byDeployer_revertsOnlyExecutor() public {
        vm.expectRevert(abi.encodeWithSelector(IGovernor.GovernorOnlyExecutor.selector, _deployer));
        vm.prank(_deployer);
        _governor.setVotingDelay(1);
    }

    // -------------------------------------------------------------------------
    // Timelock setup (DAO-2)
    // -------------------------------------------------------------------------

    /// @notice DAO-2: the timelock enforces the configured minimum delay between queue and execute.
    function test_getMinDelay_afterSetup_returnsConfiguredDelay() public view {
        assertEq(_timelock.getMinDelay(), TIMELOCK_MIN_DELAY);
    }

    /// @notice DAO-2: the Governor holds the proposer and canceller roles, so it can queue and cancel operations.
    function test_hasRole_governor_isProposerAndCanceller() public view {
        assertTrue(_timelock.hasRole(_timelock.PROPOSER_ROLE(), address(_governor)));
        assertTrue(_timelock.hasRole(_timelock.CANCELLER_ROLE(), address(_governor)));
    }

    /// @notice DAO-2: the executor role is open (address(0)), so anyone can execute a proposal once the delay passed.
    function test_hasRole_zeroAddress_isExecutor() public view {
        assertTrue(_timelock.hasRole(_timelock.EXECUTOR_ROLE(), address(0)));
    }

    /// @notice DAO-2: after setup the deployer keeps no role and the timelock administers itself.
    function test_hasRole_afterRenounce_deployerHasNoRolesAndTimelockIsAdmin() public view {
        assertFalse(_timelock.hasRole(_timelock.DEFAULT_ADMIN_ROLE(), _deployer));
        assertFalse(_timelock.hasRole(_timelock.PROPOSER_ROLE(), _deployer));
        assertTrue(_timelock.hasRole(_timelock.DEFAULT_ADMIN_ROLE(), address(_timelock)));
    }

    /// @notice DAO-2: the former admin cannot add another proposer, so the Governor stays the sole proposer.
    function test_grantRole_byFormerAdmin_revertsUnauthorizedAccount() public {
        bytes32 proposerRole = _timelock.PROPOSER_ROLE();
        bytes32 adminRole = _timelock.DEFAULT_ADMIN_ROLE();

        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, _deployer, adminRole)
        );
        vm.prank(_deployer);
        _timelock.grantRole(proposerRole, _deployer);
    }
}
