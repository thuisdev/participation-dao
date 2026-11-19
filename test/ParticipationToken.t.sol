// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {ParticipationToken} from "../src/ParticipationToken.sol";

/// @title ParticipationTokenTest
/// @notice Unit tests for the custom logic of ParticipationToken only: minter role wiring, non-transferability, the
///         timestamp clock override and its integration with vote checkpoints. Inherited OpenZeppelin behaviour
///         (delegation events, delegateBySig, nonce replay protection, supply limits) is not re-tested.
contract ParticipationTokenTest is Test {
    // -------------------------------------------------------------------------
    // Constants
    // -------------------------------------------------------------------------

    uint48 private constant ADMIN_DELAY = 1 days;
    uint256 private constant ALICE_POINTS = 100e18;
    uint256 private constant BOB_POINTS = 50e18;
    uint256 private constant EXTRA_POINTS = 20e18;

    // -------------------------------------------------------------------------
    // State
    // -------------------------------------------------------------------------

    ParticipationToken private _token;
    address private _admin;
    address private _minter;
    address private _alice;
    address private _bob;

    // -------------------------------------------------------------------------
    // Setup
    // -------------------------------------------------------------------------

    function setUp() public {
        _admin = makeAddr("admin");
        _minter = makeAddr("minter");
        _alice = makeAddr("alice");
        _bob = makeAddr("bob");

        _token = new ParticipationToken(_admin, ADMIN_DELAY);

        // Cache the role first: vm.prank only applies to the next call, which would otherwise be MINTER_ROLE()
        bytes32 minterRole = _token.MINTER_ROLE();
        vm.prank(_admin);
        _token.grantRole(minterRole, _minter);

        vm.startPrank(_minter);
        _token.mint(_alice, ALICE_POINTS);
        _token.mint(_bob, BOB_POINTS);
        vm.stopPrank();
    }

    // -------------------------------------------------------------------------
    // Minting (DAO-1, DAO-8)
    // -------------------------------------------------------------------------

    /// @notice DAO-1: the account holding MINTER_ROLE can mint, and balance and total supply increase.
    function test_mint_byMinter_increasesBalanceAndSupply() public {
        vm.prank(_minter);
        _token.mint(_bob, EXTRA_POINTS);

        assertEq(_token.balanceOf(_bob), BOB_POINTS + EXTRA_POINTS);
        assertEq(_token.totalSupply(), ALICE_POINTS + BOB_POINTS + EXTRA_POINTS);
    }

    /// @notice DAO-1 / DAO-8: accounts without MINTER_ROLE cannot mint, so voting power can only come from the Earner.
    function test_mint_byNonMinter_revertsUnauthorizedAccount() public {
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, _bob, _token.MINTER_ROLE())
        );
        vm.prank(_bob);
        _token.mint(_bob, EXTRA_POINTS);
    }

    // -------------------------------------------------------------------------
    // Non-transferability (DAO-1)
    // -------------------------------------------------------------------------

    /// @notice DAO-1: direct transfers between holders revert.
    function test_transfer_betweenHolders_revertsNonTransferable() public {
        vm.expectRevert(ParticipationToken.NonTransferable.selector);
        vm.prank(_alice);
        _token.transfer(_bob, EXTRA_POINTS);
    }

    /// @notice DAO-1: approve still works, but transferFrom reverts even with a valid allowance.
    function test_transferFrom_withApproval_revertsNonTransferable() public {
        vm.prank(_alice);
        _token.approve(_bob, EXTRA_POINTS);

        vm.expectRevert(ParticipationToken.NonTransferable.selector);
        vm.prank(_bob);
        _token.transferFrom(_alice, _bob, EXTRA_POINTS);
    }

    /// @notice DAO-1: no amount, including zero and amounts above the balance, can be transferred.
    function testFuzz_transfer_anyAmount_revertsNonTransferable(uint256 amount) public {
        vm.expectRevert(ParticipationToken.NonTransferable.selector);
        vm.prank(_alice);
        _token.transfer(_bob, amount);
    }

    // -------------------------------------------------------------------------
    // Clock and checkpoints (DAO-1)
    // -------------------------------------------------------------------------

    /// @notice ERC-6372: the overridden clock returns timestamps and reports timestamp mode.
    function test_clock_afterWarp_returnsTimestamp() public {
        uint256 newTimestamp = 1_000_000;
        vm.warp(newTimestamp);

        assertEq(_token.clock(), newTimestamp);
        assertEq(_token.CLOCK_MODE(), "mode=timestamp");
    }

    /// @notice DAO-1: checkpoints are keyed by timestamp, so the Governor can read historical votes and supply for
    ///         proposal snapshots and quorum.
    function test_getPastVotes_withTimestampClock_returnsHistoricalValue() public {
        vm.prank(_alice);
        _token.delegate(_alice);
        uint256 snapshotTime = vm.getBlockTimestamp();

        vm.warp(vm.getBlockTimestamp() + 1 days);
        vm.prank(_minter);
        _token.mint(_alice, EXTRA_POINTS);

        // Past lookups require a timepoint strictly before the current clock
        vm.warp(vm.getBlockTimestamp() + 1);

        assertEq(_token.getPastVotes(_alice, snapshotTime), ALICE_POINTS);
        assertEq(_token.getVotes(_alice), ALICE_POINTS + EXTRA_POINTS);
        assertEq(_token.getPastTotalSupply(snapshotTime), ALICE_POINTS + BOB_POINTS);
    }
}
