// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

import {Earner} from "../src/Earner.sol";
import {ParticipationGovernor} from "../src/ParticipationGovernor.sol";
import {ParticipationToken} from "../src/ParticipationToken.sol";
import {Treasury} from "../src/Treasury.sol";

/// @title Deploy - Deploys and wires the Participation DAO
/// @author Adrian (thuisdev)
/// @notice Deploys token, timelock, governor, treasury and earner, wires all roles and hands every admin right to the
///         timelock. Uses short demo durations for the Sepolia end-to-end run; production values are in the README.
/// @dev DAO-10: run without --broadcast to simulate, with --broadcast --verify to deploy and verify on Etherscan.
contract Deploy is Script {
    // -------------------------------------------------------------------------
    // Demo parameters (Sepolia)
    // -------------------------------------------------------------------------

    /// @notice Delay before the timelock can accept the token admin role. Short so the demo proposal can accept it.
    uint48 public constant TOKEN_ADMIN_DELAY = 5 minutes;

    /// @notice Minimum delay between queue and execute.
    uint256 public constant TIMELOCK_MIN_DELAY = 10 minutes;

    /// @notice Delay between proposal creation and vote start.
    uint48 public constant VOTING_DELAY = 5 minutes;

    /// @notice Duration of the vote.
    uint32 public constant VOTING_PERIOD = 30 minutes;

    /// @notice VOtes needed to create a proposal.
    uint256 public constant PROPOSAL_THRESHOLD = 20e18;

    /// @notice QOrum as percentage of total supply at the proposal snapshot.
    uint256 public constant QORUM_PERCENTAGE = 4;

    // -------------------------------------------------------------------------
    // Script
    // -------------------------------------------------------------------------

    /// @notice Deploys and wires all contracts.
    /// @return token Deployed ParticipationToken.
    /// @return timelock Deployed TimelockController.
    /// @return governor Deployed ParticipationGovernor.
    /// @return treasury Deployed Treasury.
    /// @return earner Deployed Earner.
    function run()
        external
        returns (
            ParticipationToken token,
            TimelockController timelock,
            ParticipationGovernor governor,
            Treasury treasury,
            Earner earner
        )
    {
        vm.startBroadcast();

        // Address of the account that signs the transaction (--acount)
        (, address deployer,) = vm.readCallers();

        // 1. Token, deployer is temporary admin
        token = new ParticipationToken(deployer, TOKEN_ADMIN_DELAY);

        // 2. Timelock: no proposers yet, open executor, deployer as temporary admin
        address[] memory proposers = new address[](0);
        address[] memory executors = new address[](1);
        executors[0] = address(0); // DAO-2: executor is open
        timelock = new TimelockController(TIMELOCK_MIN_DELAY, proposers, executors, deployer);

        // 3.
        governor = new ParticipationGovernor(
            VOTING_DELAY, VOTING_PERIOD, PROPOSAL_THRESHOLD, QORUM_PERCENTAGE, token, timelock
        );

        // 4. Treasury owner by the timelock, deployer can pause
        treasury = new Treasury(address(timelock), deployer);

        // 5. Earner: timelock administers roles, deployer can pause
        earner = new Earner(token, treasury, deployer, address(timelock));

        // 6. DAO-1: only the Earner can mint
        token.grantRole(token.MINTER_ROLE(), address(earner));

        // 7. DAO-2: Governor is sole proposer and canceller of the timelock
        timelock.grantRole(timelock.PROPOSER_ROLE(), address(governor));
        timelock.grantRole(timelock.CANCELLER_ROLE(), address(governor));

        // 8. DAO-2: deployer gives up timelock admin, roles can only change through proposals
        timelock.renounceRole(timelock.DEFAULT_ADMIN_ROLE(), deployer);

        // 9. DAO-1 / DAO-8: start handing the token admin to the timelock. The first porposal accepts it, after that
        // nobody but governance can grant MINTER_ROLE.
        token.beginDefaultAdminTransfer(address(timelock));

        vm.stopBroadcast();

        console.log("ParticipationToken: ", address(token));
        console.log("TimelockController: ", address(timelock));
        console.log("ParticipationGovernor: ", address(governor));
        console.log("Treasury: ", address(treasury));
        console.log("Earner: ", address(earner));
    }
}
