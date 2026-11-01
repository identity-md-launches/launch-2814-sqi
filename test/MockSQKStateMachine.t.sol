// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {MockSQK} from "src/MockSQK.sol";
import {Managed} from "src/Managed.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

/// @dev Closed actor set: every mint and transfer has a corresponding independent ledger entry.
contract MockSQKHandler is Test {
    MockSQK public immutable token;
    address[4] public actors;
    address public expectedOwner;
    address public expectedPendingOwner;
    uint256 public minted;
    uint256 public transfers;
    uint256 public delegatedTransfers;
    uint256 public rejectedCalls;
    uint256 public handovers;
    mapping(address => uint256) public balances;
    mapping(address => mapping(address => uint256)) public allowances;

    constructor(MockSQK token_, address[4] memory actors_) {
        token = token_;
        actors = actors_;
        expectedOwner = actors_[0];
        balances[expectedOwner] = 100_000_000 ether;
    }

    function mint(uint8 recipientSeed, uint96 amountSeed) external {
        address recipient = actors[recipientSeed % 4];
        uint256 amount = bound(amountSeed, 0, 1_000_000 ether);
        vm.prank(expectedOwner);
        token.mint(recipient, amount);
        balances[recipient] += amount;
        minted += amount;
    }

    function transfer(uint8 fromSeed, uint8 toSeed, uint256 amountSeed) external {
        address from = actors[fromSeed % 4];
        address to = actors[toSeed % 4];
        uint256 amount = bound(amountSeed, 0, balances[from]);
        vm.prank(from);
        assertTrue(token.transfer(to, amount));
        balances[from] -= amount;
        balances[to] += amount;
        ++transfers;
    }

    function approve(uint8 fromSeed, uint8 spenderSeed, uint96 amountSeed, bool infinite) external {
        address from = actors[fromSeed % 4];
        address spender = actors[spenderSeed % 4];
        uint256 amount = infinite ? type(uint256).max : uint256(amountSeed);
        vm.prank(from);
        assertTrue(token.approve(spender, amount));
        allowances[from][spender] = amount;
    }

    function transferFrom(uint8 fromSeed, uint8 toSeed, uint8 spenderSeed, uint256 amountSeed) external {
        address from = actors[fromSeed % 4];
        address to = actors[toSeed % 4];
        address spender = actors[spenderSeed % 4];
        uint256 maximum = balances[from];
        uint256 allowed = allowances[from][spender];
        if (allowed < maximum) maximum = allowed;
        uint256 amount = bound(amountSeed, 0, maximum);
        vm.prank(spender);
        assertTrue(token.transferFrom(from, to, amount));
        balances[from] -= amount;
        balances[to] += amount;
        if (allowed != type(uint256).max) allowances[from][spender] -= amount;
        ++delegatedTransfers;
    }

    function proposeOwner(uint8 nextSeed) external {
        // OZ's zero pending owner cancels a proposal; it never renounces current ownership.
        address next = nextSeed % 5 == 4 ? address(0) : actors[nextSeed % 4];
        vm.prank(expectedOwner);
        token.transferOwnership(next);
        expectedPendingOwner = next;
    }

    function acceptOwner(uint8 actorSeed) external {
        address actor = actors[actorSeed % 4];
        if (actor != expectedPendingOwner) {
            vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, actor));
            vm.prank(actor);
            token.acceptOwnership();
            ++rejectedCalls;
        } else {
            vm.prank(actor);
            token.acceptOwnership();
            expectedOwner = actor;
            expectedPendingOwner = address(0);
            ++handovers;
        }
    }

    function rejectInvalidOperation(uint8 actorSeed, uint8 modeSeed) external {
        address actor = actors[actorSeed % 4];
        uint256 mode = modeSeed % 5;
        if (mode < 2) {
            if (actor == expectedOwner) actor = actors[(uint256(actorSeed) % 4 + 1) % 4];
            vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, actor));
            vm.prank(actor);
            if (mode == 0) token.mint(actor, 1);
            else token.transferOwnership(actor);
        } else if (mode == 2) {
            vm.expectRevert(Managed.RenounceDisabled.selector);
            vm.prank(expectedOwner);
            token.renounceOwnership();
        } else if (mode == 3) {
            uint256 tooMuch = balances[actor] + 1;
            vm.expectRevert(
                abi.encodeWithSelector(
                    IERC20Errors.ERC20InsufficientBalance.selector, actor, balances[actor], tooMuch
                )
            );
            vm.prank(actor);
            token.transfer(actors[(uint256(actorSeed) % 4 + 1) % 4], tooMuch);
        } else {
            // Explicitly revoke then test a delegated call; an approval cannot survive revocation.
            address spender = actors[(uint256(actorSeed) % 4 + 1) % 4];
            vm.prank(actor);
            token.approve(spender, 0);
            allowances[actor][spender] = 0;
            vm.expectRevert(
                abi.encodeWithSelector(
                    IERC20Errors.ERC20InsufficientAllowance.selector, spender, uint256(0), uint256(1)
                )
            );
            vm.prank(spender);
            token.transferFrom(actor, spender, 1);
        }
        ++rejectedCalls;
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract MockSQKStateMachineTest is Test {
    MockSQK private token;
    MockSQKHandler private handler;
    address[4] private actors;

    function setUp() public {
        vm.chainId(11_155_111);
        actors = [
            makeAddr("token owner"), makeAddr("token alice"), makeAddr("token bob"), makeAddr("token carol")
        ];
        token = new MockSQK(actors[0]);
        handler = new MockSQKHandler(token, actors);
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](8);
        selectors[0] = MockSQKHandler.mint.selector;
        selectors[1] = MockSQKHandler.transfer.selector;
        selectors[2] = MockSQKHandler.approve.selector;
        selectors[3] = MockSQKHandler.transferFrom.selector;
        selectors[4] = MockSQKHandler.proposeOwner.selector;
        selectors[5] = MockSQKHandler.acceptOwner.selector;
        selectors[6] = MockSQKHandler.rejectInvalidOperation.selector;
        // Make transfers more frequent than governance changes.
        selectors[7] = MockSQKHandler.transfer.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    function invariant_supplyAndAllBalancesMatchIndependentLedger() public view {
        uint256 sum;
        for (uint256 i; i < actors.length; ++i) {
            assertEq(token.balanceOf(actors[i]), handler.balances(actors[i]), "balance ledger");
            sum += token.balanceOf(actors[i]);
        }
        assertEq(sum, token.totalSupply(), "tokens cannot appear outside the actor set");
        assertEq(token.totalSupply(), 100_000_000 ether + handler.minted(), "only owner mint changes supply");
        assertEq(token.balanceOf(address(0)), 0);
    }

    function invariant_allowancesAndOwnershipMatchIndependentLedger() public view {
        for (uint256 i; i < actors.length; ++i) {
            for (uint256 j; j < actors.length; ++j) {
                assertEq(token.allowance(actors[i], actors[j]), handler.allowances(actors[i], actors[j]));
            }
        }
        assertEq(token.owner(), handler.expectedOwner());
        assertEq(token.pendingOwner(), handler.expectedPendingOwner());
        assertTrue(token.owner() != address(0));
    }

    function test_handlerExercisesFiniteInfiniteAndSelfTransfersAcrossHandover() public {
        handler.mint(1, 100);
        handler.transfer(1, 1, 17);
        handler.approve(1, 2, 19, false);
        handler.transferFrom(1, 3, 2, 19);
        assertEq(token.allowance(actors[1], actors[2]), 0);
        handler.approve(1, 2, 0, true);
        handler.transferFrom(1, 1, 2, 20);
        assertEq(token.allowance(actors[1], actors[2]), type(uint256).max);
        handler.proposeOwner(1);
        handler.acceptOwner(2);
        handler.acceptOwner(1);
        handler.mint(3, 1);
        for (uint8 mode; mode < 5; ++mode) {
            handler.rejectInvalidOperation(0, mode);
        }
        handler.proposeOwner(3);
        handler.proposeOwner(4);
        handler.acceptOwner(3);
        assertEq(handler.handovers(), 1);
        assertEq(handler.delegatedTransfers(), 2);
        assertEq(handler.rejectedCalls(), 7);
        invariant_supplyAndAllBalancesMatchIndependentLedger();
        invariant_allowancesAndOwnershipMatchIndependentLedger();
    }
}

contract MockSQKEdgesTest is Test {
    MockSQK private token;
    address private owner;
    address private alice;

    function setUp() public {
        vm.chainId(11_155_111);
        owner = makeAddr("edge owner");
        alice = makeAddr("edge alice");
        token = new MockSQK(owner);
    }

    function test_fullInitialSupplyTransferAndZeroSelfTransferPreserveSupply() public {
        uint256 supply = token.totalSupply();
        vm.prank(owner);
        token.transfer(alice, supply);
        vm.startPrank(alice);
        token.transfer(alice, supply);
        token.transfer(owner, 0);
        token.transfer(owner, 1);
        vm.stopPrank();
        assertEq(token.balanceOf(owner), 1);
        assertEq(token.balanceOf(alice), supply - 1);
        assertEq(token.totalSupply(), supply);
    }

    function test_zeroRecipientFailuresLeaveBalancesAndAllowanceUntouched() public {
        uint256 supply = token.totalSupply();
        vm.startPrank(owner);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.mint(address(0), 1);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 1);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        token.approve(address(0), 1);
        token.approve(alice, 1);
        vm.stopPrank();
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(alice);
        token.transferFrom(owner, address(0), 1);
        assertEq(token.allowance(owner, alice), 1);
        assertEq(token.balanceOf(owner), supply);
        assertEq(token.totalSupply(), supply);
    }

    function test_supplyAtUint256LimitRejectsOverflowAtomically() public {
        uint256 initialSupply = token.totalSupply();
        vm.startPrank(owner);
        token.mint(alice, type(uint256).max - initialSupply);
        vm.expectRevert(abi.encodeWithSignature("Panic(uint256)", uint256(0x11)));
        token.mint(owner, 1);
        vm.stopPrank();
        assertEq(token.totalSupply(), type(uint256).max);
        assertEq(token.balanceOf(owner), initialSupply);
        assertEq(token.balanceOf(alice), type(uint256).max - initialSupply);
    }
}
