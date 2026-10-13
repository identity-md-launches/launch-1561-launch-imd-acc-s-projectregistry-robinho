// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Stacker, IStakedIMD} from "../src/Stacker.sol";
import {ProjectRegistry} from "../src/ProjectRegistry.sol";

/// @dev Test-only factory: one call, two CREATE2 deployments, no initializer or sent value.
contract ApplicationFactoryRehearsal {
    function deploy() external returns (Stacker stacker, ProjectRegistry registry) {
        stacker = new Stacker{salt: bytes32("Stacker")}(
            IERC20(0x2B69099E59b05901faA1DD164fabf098bf831E82),
            IStakedIMD(0xF9e2EEc3B610ec6781f7438aC5Fb4bc049d81Cc1)
        );
        registry = new ProjectRegistry{salt: bytes32("ProjectRegistry")}(
            0xa43e6F75ee006411F79Ac1C84120606C2330DE82,
            0x44a1Cd38474FB1748400E7DEb5F8D786ccE3F89A,
            address(stacker),
            0x5598Aa9146215Bc13eb26f2c692Ad1461Fd32982,
            1,
            5e18,
            3600
        );
    }
}

contract FactoryRehearsalTest is Test {
    function test_sepoliaFactoryDeploysBothInOrderOnAnEmptyChain() public {
        vm.chainId(11155111);
        assertEq(address(0xF9e2EEc3B610ec6781f7438aC5Fb4bc049d81Cc1).code.length, 0);
        assertEq(address(0xa43e6F75ee006411F79Ac1C84120606C2330DE82).code.length, 0);
        ApplicationFactoryRehearsal factory = new ApplicationFactoryRehearsal();
        (Stacker stacker, ProjectRegistry registry) = factory.deploy();
        assertGt(address(stacker).code.length, 0);
        assertGt(address(registry).code.length, 0);
        assertEq(registry.stacker(), address(stacker));
        assertEq(registry.challengeBond(), 5e18);
        assertEq(registry.challengeCooldown(), 3600);
        assertEq(registry.questionChainId(), 1);
        assertEq(stacker.totalStacked(), 0);
        (bool stackerOwner,) = address(stacker).staticcall(abi.encodeWithSignature("owner()"));
        (bool registryOwner,) = address(registry).staticcall(abi.encodeWithSignature("owner()"));
        assertFalse(stackerOwner);
        assertFalse(registryOwner);
    }
}
