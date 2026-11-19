// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {IGovernor} from "@openzeppelin/contracts/governance/IGovernor.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

import {Earner} from "../src/Earner.sol";
import {ParticipationGovernor} from "../src/ParticipationGovernor.sol";
import {ParticipationToken} from "../src/ParticipationToken.sol";
import {Treasury} from "../src/Treasury.sol";

/// @title DAOIntegrationTest
/// @notice DAO-6 / DAO-10: full workflow with all contracts wired as in the deploy script. Proves that voting power comes
///         from participation, that quorum is reached and that an executed proposal changes state on the Treasury.
contract DAOIntegrationTest is Test {
    // -------------------------------------------------------------------------
    // Constants
    // -------------------------------------------------------------------------

    uint48 private constant TOKEN_ADMIN_DELAY = 1 days;
    uint256 private constant TIMELOCK_MIN_DELAY = 10 minutes;
    uint48 private constant VOTING_DELAY = 5 minutes;
    uint32 private constant VOTING_PERIOD = 30 minutes;
    uint256 private constant PROPOSAL_THRESHOLD = 20e18; // two check-ins worth of points
    uint256 private constant QUORUM_PERCENTAGE = 4;
    uint256 private constant STARTING_ETH = 10 ether;

    uint256 private constant ALICE_FUNDING = 0.3 ether; // 30 points
    uint256 private constant BOB_FUNDING = 0.2 ether; // 20 points
    uint256 private constant ALICE_POINTS = 40e18; // check-in 10 + funding 30
    uint256 private constant BOB_POINTS = 30e18; // check-in 10 + funding 20
    uint256 private constant GRANT_AMOUNT = 0.1 ether;

    // GovernorCountingSimple vote options
    uint8 private constant VOTE_AGAINST = 0;
    uint8 private constant VOTE_FOR = 1;

    string private constant DESCRIPTION = "Grant 0.1 ETH from the Treasury to the grantee";

    // -------------------------------------------------------------------------
    // State
    // -------------------------------------------------------------------------

    ParticipationToken private _token;
    TimelockController private _timelock;
    ParticipationGovernor private _governor;
    Treasury private _treasury;
    Earner private _earner;

    address private _deployer;
    address private _alice;
    address private _bob;
    address private _grantee;

    // -------------------------------------------------------------------------
    // Setup
    // -------------------------------------------------------------------------

    function setUp() public {
        _deployer = makeAddr("deployer");
        _alice = makeAddr("alice");
        _bob = makeAddr("bob");
        _grantee = makeAddr("grantee");

        // Give the users ETH so they can fund the Treasury
        vm.deal(_alice, STARTING_ETH);
        vm.deal(_bob, STARTING_ETH);

        vm.startPrank(_deployer);

        // 1. Token
        _token = new ParticipationToken(_deployer, TOKEN_ADMIN_DELAY);

        // 2. Timelock: no proposers yet, open executor, deployer as temporary admin
        address[] memory proposers = new address[](0);
        address[] memory executors = new address[](1);
        executors[0] = address(0);
        _timelock = new TimelockController(TIMELOCK_MIN_DELAY, proposers, executors, _deployer);

        // 3. Governor
        _governor = new ParticipationGovernor(
            VOTING_DELAY, VOTING_PERIOD, PROPOSAL_THRESHOLD, QUORUM_PERCENTAGE, _token, _timelock
        );

        // 4. Treasury owned by the timelock (DAO-3)
        _treasury = new Treasury(address(_timelock), _deployer);

        // 5. Earner: deployer can pause fast, timelock administers roles
        _earner = new Earner(_token, _treasury, _deployer, address(_timelock));

        // 6. Wiring
        _token.grantRole(_token.MINTER_ROLE(), address(_earner));
        _timelock.grantRole(_timelock.PROPOSER_ROLE(), address(_governor));
        _timelock.grantRole(_timelock.CANCELLER_ROLE(), address(_governor));
        _timelock.renounceRole(_timelock.DEFAULT_ADMIN_ROLE(), _deployer);

        vm.stopPrank();
    }

    // -------------------------------------------------------------------------
    // Happy path (DAO-6, DAO-7, DAO-10)
    // -------------------------------------------------------------------------

    /// @notice DAO-6: earn -> delegate -> propose -> vote -> queue -> execute moves ETH from the Treasury to the grantee.
    function test_proposalLifecycle_grantProposal_releasesEthFromTreasury() public {
        // 1. Voting power comes from participation (DAO-4, DAO-5)
        _earnPointsAndDelegate(_alice, ALICE_FUNDING);
        _earnPointsAndDelegate(_bob, BOB_FUNDING);
        assertEq(_token.getVotes(_alice), ALICE_POINTS);
        assertEq(_token.getVotes(_bob), BOB_POINTS);

        // The proposal threshold reads votes at clock() - 1, so move past the delegation timestamp
        vm.warp(vm.getBlockTimestamp() + 1);

        uint256 treasuryBefore = address(_treasury).balance;
        uint256 granteeBefore = _grantee.balance;
        assertEq(treasuryBefore, ALICE_FUNDING + BOB_FUNDING);

        // 2. Propose
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) = _buildGrantProposal();
        vm.prank(_alice);
        uint256 proposalId = _governor.propose(targets, values, calldatas, DESCRIPTION);
        _assertState(proposalId, IGovernor.ProposalState.Pending);

        // 3. Vote after the snapshot
        vm.warp(_governor.proposalSnapshot(proposalId) + 1);
        _assertState(proposalId, IGovernor.ProposalState.Active);
        vm.prank(_alice);
        _governor.castVote(proposalId, VOTE_FOR);
        vm.prank(_bob);
        _governor.castVote(proposalId, VOTE_FOR);

        // 4. Voting ends: quorum reached and majority For
        vm.warp(_governor.proposalDeadline(proposalId) + 1);
        _assertState(proposalId, IGovernor.ProposalState.Succeeded);
        (, uint256 forVotes, uint256 abstainVotes) = _governor.proposalVotes(proposalId);
        assertGe(forVotes + abstainVotes, _governor.quorum(_governor.proposalSnapshot(proposalId)));

        // 5. Queue in the timelock
        bytes32 descriptionHash = keccak256(bytes(DESCRIPTION));
        _governor.queue(targets, values, calldatas, descriptionHash);
        _assertState(proposalId, IGovernor.ProposalState.Queued);

        // 6. Execute after the timelock delay; the Treasury emits GrantReleased (DAO-7)
        vm.warp(_governor.proposalEta(proposalId) + 1);
        vm.expectEmit(true, false, false, true, address(_treasury));
        emit Treasury.GrantReleased(_grantee, GRANT_AMOUNT);
        _governor.execute(targets, values, calldatas, descriptionHash);
        _assertState(proposalId, IGovernor.ProposalState.Executed);

        // 7. Real state change on the target contract
        assertEq(address(_treasury).balance, treasuryBefore - GRANT_AMOUNT);
        assertEq(_grantee.balance, granteeBefore + GRANT_AMOUNT);
    }

    // -------------------------------------------------------------------------
    // Negative paths (DAO-6)
    // -------------------------------------------------------------------------

    /// @notice DAO-6: an account below the proposal threshold cannot create a proposal.
    function test_propose_belowThreshold_revertsInsufficientProposerVotes() public {
        // Bob only checks in: 10 points, threshold is 20
        vm.startPrank(_bob);
        _earner.checkIn();
        _token.delegate(_bob);
        vm.stopPrank();
        vm.warp(vm.getBlockTimestamp() + 1);

        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) = _buildGrantProposal();

        vm.expectRevert(
            abi.encodeWithSelector(
                IGovernor.GovernorInsufficientProposerVotes.selector, _bob, 10e18, PROPOSAL_THRESHOLD
            )
        );
        vm.prank(_bob);
        _governor.propose(targets, values, calldatas, DESCRIPTION);
    }

    /// @notice DAO-6: Against votes do not count towards quorum, so a proposal without For/Abstain votes is defeated.
    function test_state_onlyAgainstVotes_defeatedByQuorum() public {
        uint256 proposalId = _setUpVotersAndPropose();

        vm.warp(_governor.proposalSnapshot(proposalId) + 1);
        vm.prank(_bob);
        _governor.castVote(proposalId, VOTE_AGAINST);

        vm.warp(_governor.proposalDeadline(proposalId) + 1);

        (, uint256 forVotes, uint256 abstainVotes) = _governor.proposalVotes(proposalId);
        assertLt(forVotes + abstainVotes, _governor.quorum(_governor.proposalSnapshot(proposalId)));
        _assertState(proposalId, IGovernor.ProposalState.Defeated);
    }

    /// @notice DAO-6: votes are read at the snapshot, so points earned after it do not add voting weight.
    function test_castVote_pointsEarnedAfterSnapshot_doNotCount() public {
        uint256 proposalId = _setUpVotersAndPropose();
        vm.warp(_governor.proposalSnapshot(proposalId) + 1);

        // Bob earns 20 more points after the snapshot (still within his epoch cap of 50)
        vm.prank(_bob);
        _earner.fundTreasury{value: BOB_FUNDING}();
        assertEq(_token.getVotes(_bob), BOB_POINTS + 20e18);

        vm.prank(_bob);
        uint256 weight = _governor.castVote(proposalId, VOTE_FOR);

        assertEq(weight, BOB_POINTS);
    }

    /// @notice DAO-6: a queued proposal cannot be executed before the timelock delay has passed.
    function test_execute_beforeTimelockDelay_reverts() public {
        uint256 proposalId = _setUpVotersAndPropose();
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) = _buildGrantProposal();
        bytes32 descriptionHash = keccak256(bytes(DESCRIPTION));

        vm.warp(_governor.proposalSnapshot(proposalId) + 1);
        vm.prank(_alice);
        _governor.castVote(proposalId, VOTE_FOR);
        vm.warp(_governor.proposalDeadline(proposalId) + 1);
        _governor.queue(targets, values, calldatas, descriptionHash);

        // Revert comes from the timelock (operation not ready yet)
        vm.expectRevert();
        _governor.execute(targets, values, calldatas, descriptionHash);
    }

    // -------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------

    /// @notice Lets a user check in, fund the Treasury and self-delegate.
    /// @param user Account that earns points.
    /// @param fundingAmount ETH the user sends to fundTreasury.
    function _earnPointsAndDelegate(address user, uint256 fundingAmount) private {
        vm.startPrank(user);
        _earner.checkIn();
        _earner.fundTreasury{value: fundingAmount}();
        _token.delegate(user);
        vm.stopPrank();
    }

    /// @notice Gives Alice and Bob voting power and lets Alice create the grant proposal.
    /// @return proposalId Id of the created proposal.
    function _setUpVotersAndPropose() private returns (uint256 proposalId) {
        _earnPointsAndDelegate(_alice, ALICE_FUNDING);
        _earnPointsAndDelegate(_bob, BOB_FUNDING);
        vm.warp(vm.getBlockTimestamp() + 1);

        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) = _buildGrantProposal();
        vm.prank(_alice);
        return _governor.propose(targets, values, calldatas, DESCRIPTION);
    }

    /// @notice Builds a single-action proposal that calls Treasury.releaseETH(grantee, GRANT_AMOUNT).
    /// @return targets Contracts to call (the Treasury).
    /// @return values ETH the timelock sends with each call (zero, the Treasury pays from its own balance).
    /// @return calldatas Encoded releaseETH call.
    function _buildGrantProposal()
        private
        view
        returns (address[] memory targets, uint256[] memory values, bytes[] memory calldatas)
    {
        targets = new address[](1);
        values = new uint256[](1);
        calldatas = new bytes[](1);

        targets[0] = address(_treasury);
        values[0] = 0;
        calldatas[0] = abi.encodeCall(Treasury.releaseETH, (payable(_grantee), GRANT_AMOUNT));
    }

    /// @notice Asserts the current state of a proposal.
    /// @param proposalId Id of the proposal.
    /// @param expected Expected ProposalState.
    function _assertState(uint256 proposalId, IGovernor.ProposalState expected) private view {
        assertEq(uint256(_governor.state(proposalId)), uint256(expected));
    }
}
