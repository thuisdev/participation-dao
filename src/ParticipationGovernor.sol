// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Governor} from "@openzeppelin/contracts/governance/Governor.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {GovernorCountingSimple} from "@openzeppelin/contracts/governance/extensions/GovernorCountingSimple.sol";
import {GovernorSettings} from "@openzeppelin/contracts/governance/extensions/GovernorSettings.sol";
import {GovernorTimelockControl} from "@openzeppelin/contracts/governance/extensions/GovernorTimelockControl.sol";
import {GovernorVotes} from "@openzeppelin/contracts/governance/extensions/GovernorVotes.sol";
import {
    GovernorVotesQuorumFraction
} from "@openzeppelin/contracts/governance/extensions/GovernorVotesQuorumFraction.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";

/// @title ParticipationGovernor - Governor of the Participation DAO
/// @author Adrian (thuisdev)
/// @notice Lets accounts with delegated ParticipationToken votes create, vote on, queue and execute proposals. Approved
///         proposals are executed by the TimelockController, which owns the Treasury and every managed contract.
/// @dev DAO-2: composed from OpenZeppelin modules:
///      - GovernorSettings: votingDelay, votingPeriod and proposalThreshold, later changeable only through a proposal
///      - GovernorVotes: reads voting power from the ParticipationToken via getPastVotes at the proposal snapshot
///      - GovernorVotesQuorumFraction: quorum as a percentage of the token's total supply at the proposal snapshot
///      - GovernorCountingSimple: Against / For / Abstain, where For and Abstain count towards quorum
///      - GovernorTimelockControl: successful proposals are queued in and executed by the TimelockController
///      The Governor adopts the token's ERC-6372 clock, so all durations are in seconds. Making this Governor the sole
///      proposer and canceller of the timelock happens in the deploy script.
contract ParticipationGovernor is
    Governor,
    GovernorSettings,
    GovernorCountingSimple,
    GovernorVotes,
    GovernorVotesQuorumFraction,
    GovernorTimelockControl
{
    // -------------------------------------------------------------------------
    // Constructor
    // -------------------------------------------------------------------------

    /// @notice Deploys the Governor, wires it to the voting token and the timelock and sets the governance parameters.
    /// @dev DAO-2: all parameters are passed in by the deploy script, so the testnet demo can use short durations while
    ///      the README justifies production values. GovernorSettings reverts with GovernorInvalidVotingPeriod if
    ///      `votingPeriod_` is zero; GovernorVotesQuorumFraction reverts with GovernorInvalidQuorumFraction if
    ///      `quorumPercentage_` is above 100.
    /// @param votingDelay_ Seconds between proposal creation and vote start, at which point voting power is snapshotted.
    /// @param votingPeriod_ Seconds the vote stays open.
    /// @param proposalThreshold_ Minimum voting power (token units, 18 decimals) an account needs to create a proposal.
    /// @param quorumPercentage_ Percentage (0-100) of total supply at the snapshot that must vote For or Abstain.
    /// @param token_ ParticipationToken that provides voting power (IVotes with a timestamp clock).
    /// @param timelock_ TimelockController that queues and executes successful proposals.
    constructor(
        uint48 votingDelay_,
        uint32 votingPeriod_,
        uint256 proposalThreshold_,
        uint256 quorumPercentage_,
        IVotes token_,
        TimelockController timelock_
    )
        Governor("ParticipationGovernor")
        GovernorSettings(votingDelay_, votingPeriod_, proposalThreshold_)
        GovernorVotes(token_)
        GovernorVotesQuorumFraction(quorumPercentage_)
        GovernorTimelockControl(timelock_)
    {}

    // -------------------------------------------------------------------------
    // Public functions
    // -------------------------------------------------------------------------

    /// @notice Returns the current state of a proposal.
    /// @dev Required override: GovernorTimelockControl extends the core states with Queued and checks the timelock.
    /// @param proposalId Id of the proposal, the hash of its targets, values, calldatas and description hash.
    /// @return currentState Pending, Active, Canceled, Defeated, Succeeded, Queued, Expired or Executed.
    function state(uint256 proposalId)
        public
        view
        override(Governor, GovernorTimelockControl)
        returns (ProposalState currentState)
    {
        return super.state(proposalId);
    }

    /// @notice Returns whether a proposal has to be queued in the timelock before it can be executed.
    /// @dev Required override: always true here because every proposal is executed through the timelock.
    /// @param proposalId Id of the proposal.
    /// @return needsQueuing True if the proposal must be queued before execution.
    function proposalNeedsQueuing(uint256 proposalId)
        public
        view
        override(Governor, GovernorTimelockControl)
        returns (bool needsQueuing)
    {
        return super.proposalNeedsQueuing(proposalId);
    }

    /// @notice Returns the minimum voting power an account needs to create a proposal.
    /// @dev DAO-2 / DAO-6: only accounts with at least this many delegated votes can propose. Required override between
    ///      Governor and GovernorSettings; the value is stored in GovernorSettings and changeable only by governance.
    /// @return threshold Minimum voting power in token units (18 decimals).
    function proposalThreshold() public view override(Governor, GovernorSettings) returns (uint256 threshold) {
        return super.proposalThreshold();
    }

    // -------------------------------------------------------------------------
    // Internal functions
    // -------------------------------------------------------------------------

    /// @notice Schedules the operations of a successful proposal in the timelock.
    /// @dev Required override: GovernorTimelockControl calls scheduleBatch on the timelock, which only works because
    ///      this Governor holds the PROPOSER_ROLE.
    /// @param proposalId Id of the proposal.
    /// @param targets Contracts the proposal calls.
    /// @param values ETH amounts (wei) sent with each call.
    /// @param calldatas Encoded function calls.
    /// @param descriptionHash keccak256 of the proposal description.
    /// @return eta Timestamp from which the queued proposal can be executed.
    function _queueOperations(
        uint256 proposalId,
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) internal override(Governor, GovernorTimelockControl) returns (uint48 eta) {
        return super._queueOperations(proposalId, targets, values, calldatas, descriptionHash);
    }

    /// @notice Executes the operations of a queued proposal through the timelock.
    /// @dev Required override: GovernorTimelockControl calls executeBatch, so the timelock (not this Governor) is
    ///      msg.sender on every target. Targets must therefore be owned by the timelock.
    /// @param proposalId Id of the proposal.
    /// @param targets Contracts the proposal calls.
    /// @param values ETH amounts (wei) sent with each call.
    /// @param calldatas Encoded function calls.
    /// @param descriptionHash keccak256 of the proposal description.
    function _executeOperations(
        uint256 proposalId,
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) internal override(Governor, GovernorTimelockControl) {
        super._executeOperations(proposalId, targets, values, calldatas, descriptionHash);
    }

    /// @notice Cancels a proposal in the Governor and, if already queued, in the timelock.
    /// @dev Required override: GovernorTimelockControl also cancels the timelock operation, which requires this
    ///      Governor to hold the CANCELLER_ROLE.
    /// @param targets Contracts the proposal calls.
    /// @param values ETH amounts (wei) sent with each call.
    /// @param calldatas Encoded function calls.
    /// @param descriptionHash keccak256 of the proposal description.
    /// @return proposalId Id of the cancelled proposal.
    function _cancel(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) internal override(Governor, GovernorTimelockControl) returns (uint256 proposalId) {
        return super._cancel(targets, values, calldatas, descriptionHash);
    }

    /// @notice Returns the address that executes governance actions.
    /// @dev Required override: returns the timelock, so onlyGovernance functions (e.g. GovernorSettings setters) can
    ///      only be called by the timelock during a proposal execution.
    /// @return executor Address of the TimelockController.
    function _executor() internal view override(Governor, GovernorTimelockControl) returns (address executor) {
        return super._executor();
    }
}
