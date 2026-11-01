// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {MockSQK} from "../src/MockSQK.sol";
import {PremiumModel} from "../src/PremiumModel.sol";
import {CoverPool} from "../src/CoverPool.sol";
import {CoreReader} from "../src/CoreReader.sol";
import {PolicyBook} from "../src/PolicyBook.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract ApplicationFactoryHarness {
    function deploy(address owner, address core) external returns (address[5] memory apps) {
        apps[0] = address(new MockSQK(owner));
        apps[1] = address(new PremiumModel(owner));
        apps[2] = address(new CoverPool(owner, apps[0]));
        apps[3] = address(new CoreReader(core));
        apps[4] = address(new PolicyBook(owner, apps[0], apps[1], apps[2], apps[3]));
    }
}

contract DeploymentTest is Test {
    address private constant CORE = 0x74665dAecA35A2303e767E76a2FF1FB6F93e119f;

    function setUp() public {
        vm.chainId(11_155_111);
    }

    function test_factoryDeploymentWiresBackwardReferencesAndExplicitOwners() public {
        address owner = makeAddr("launch-owner");
        ApplicationFactoryHarness factory = new ApplicationFactoryHarness();
        address[5] memory apps = factory.deploy(owner, CORE);
        assertEq(MockSQK(apps[0]).owner(), owner);
        assertEq(PremiumModel(apps[1]).owner(), owner);
        assertEq(CoverPool(apps[2]).owner(), owner);
        assertEq(PolicyBook(apps[4]).owner(), owner);
        assertEq(MockSQK(apps[0]).balanceOf(owner), 100_000_000 ether);
        assertEq(MockSQK(apps[0]).balanceOf(address(factory)), 0);
        assertEq(address(CoverPool(apps[2]).token()), apps[0]);
        assertEq(address(CoreReader(apps[3]).core()), CORE);
        assertEq(address(PolicyBook(apps[4]).token()), apps[0]);
        assertEq(address(PolicyBook(apps[4]).premiumModel()), apps[1]);
        assertEq(address(PolicyBook(apps[4]).pool()), apps[2]);
        assertEq(address(PolicyBook(apps[4]).reader()), apps[3]);
        assertEq(CoverPool(apps[2]).policyBook(), address(0));
        vm.prank(owner);
        CoverPool(apps[2]).setPolicyBook(apps[4]);
        assertEq(CoverPool(apps[2]).policyBook(), apps[4]);
        for (uint256 i; i < apps.length; ++i) {
            _checkRuntime(apps[i]);
        }
    }

    function test_constructorsSucceedWhenAllExternalDependenciesHaveNoCode() public {
        address owner = makeAddr("owner");
        address dependency = makeAddr("not-yet-deployed");
        new MockSQK(owner);
        new PremiumModel(owner);
        new CoverPool(owner, dependency);
        new CoreReader(CORE);
        new PolicyBook(owner, dependency, dependency, dependency, dependency);
    }

    /// @dev The launch rehearses constructors on an empty chain whose id it chooses; nothing may depend on it.
    function test_constructorsDoNotDependOnChainIdOrCaller() public {
        uint256[3] memory chains = [uint256(31_337), 1, 11_155_111];
        address owner = makeAddr("launch-owner");
        for (uint256 i; i < chains.length; ++i) {
            vm.chainId(chains[i]);
            ApplicationFactoryHarness factory = new ApplicationFactoryHarness();
            vm.prank(makeAddr("launch-wallet"), makeAddr("launch-wallet"));
            address[5] memory apps = factory.deploy(owner, CORE);
            assertEq(MockSQK(apps[0]).owner(), owner);
            assertEq(PremiumModel(apps[1]).owner(), owner);
            assertEq(CoverPool(apps[2]).owner(), owner);
            assertEq(PolicyBook(apps[4]).owner(), owner);
            assertEq(MockSQK(apps[0]).balanceOf(owner), 100_000_000 ether);
            assertEq(MockSQK(apps[0]).balanceOf(address(factory)), 0);
            assertEq(MockSQK(apps[0]).balanceOf(makeAddr("launch-wallet")), 0);
        }
    }

    function test_zeroOwnersAndDependencyAddressesRevert() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new MockSQK(address(0));
        vm.expectRevert(CoverPool.InvalidAddress.selector);
        new CoverPool(address(this), address(0));
        vm.expectRevert(CoreReader.InvalidCore.selector);
        new CoreReader(address(0));
        vm.expectRevert(PolicyBook.InvalidAddress.selector);
        new PolicyBook(address(this), CORE, CORE, CORE, address(0));
    }

    function _checkRuntime(address app) private view {
        bytes memory code = app.code;
        assertGt(code.length, 0);
        assertLe(code.length, 24_576);
        bool reachable = true;
        for (uint256 j; j < code.length; ++j) {
            uint8 op = uint8(code[j]);
            if (op == 0x5b) reachable = true;
            if (op >= 0x60 && op <= 0x7f) {
                j += op - 0x5f;
                continue;
            }
            if (reachable) assertTrue(op != 0xf4 && op != 0xf2 && op != 0xff);
            if (op == 0x00 || op == 0x56 || op == 0xf3 || op == 0xfd || op == 0xfe || op == 0xff) {
                reachable = false;
            }
        }
    }
}
