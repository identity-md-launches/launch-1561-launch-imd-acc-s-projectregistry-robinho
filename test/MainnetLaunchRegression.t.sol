// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Stacker} from "src/Stacker.sol";

/// @dev Local rehearsal only; accepts the exact init code assembled from the launch manifest.
contract MainnetStackerFactory {
    function deploy(bytes memory initCode, bytes32 salt) external returns (address deployed) {
        assembly ("memory-safe") {
            deployed := create2(0, add(initCode, 32), mload(initCode), salt)
        }
        require(deployed != address(0), "deployment failed");
    }
}

contract MainnetLaunchRegressionTest is Test {
    address internal constant IMD = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;
    address internal constant SIMD = 0x9Efa934D9fAd4AE28c998a40195646b965a97247;

    /// @dev The `sepolia` branch's launch.json lists the Sepolia registry instead; these checks are
    /// for the mainnet manifest, so they skip there.
    modifier mainnetManifest() {
        string memory json = vm.readFile("./launch.json");
        if (
            keccak256(bytes(vm.parseJsonString(json, ".contracts[0].contract")))
                != keccak256("Stacker")
        ) {
            vm.skip(true);
        }
        _;
    }

    function _manifestArguments() internal view returns (address imd, address simd) {
        string memory json = vm.readFile("./launch.json");
        assertEq(vm.parseJsonString(json, ".kind"), "evm_contracts");
        assertEq(vm.parseJsonString(json, ".contracts[0].contract"), "Stacker");
        assertFalse(vm.keyExistsJson(json, ".contracts[1]"), "mainnet launches only the Stacker");
        string[] memory args = vm.parseJsonStringArray(json, ".contracts[0].constructorArgs");
        assertEq(args.length, 2, "the audited two-address constructor");
        imd = vm.parseAddress(args[0]);
        simd = vm.parseAddress(args[1]);
        assertEq(imd, IMD, "real mainnet IMD, not the Sepolia test token");
        assertEq(simd, SIMD, "real mainnet staked-IMD vault");
    }

    function test_manifestPinsExactlyOneMainnetStacker() public mainnetManifest {
        _manifestArguments();
    }

    function test_manifestCreate2WorksWithoutDependenciesOrInitialization() public mainnetManifest {
        vm.chainId(1);
        (address imd, address simd) = _manifestArguments();
        assertEq(imd.code.length, 0);
        assertEq(simd.code.length, 0);
        MainnetStackerFactory factory = new MainnetStackerFactory();
        bytes memory initCode = abi.encodePacked(type(Stacker).creationCode, abi.encode(imd, simd));
        assertLe(initCode.length, 49_152, "EIP-3860 init code limit");
        bytes32 salt = keccak256("mainnet Stacker rehearsal");
        address predicted = address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(bytes1(0xff), address(factory), salt, keccak256(initCode))
                    )
                )
            )
        );

        address deployed = factory.deploy(initCode, salt);
        assertEq(deployed, predicted);
        assertEq(vm.getNonce(address(factory)), 2, "one application created");
        assertEq(vm.getNonce(deployed), 1, "constructor created no additional contracts");
        Stacker stacker = Stacker(deployed);
        assertEq(address(stacker.IMD()), imd);
        assertEq(address(stacker.SIMD()), simd);
        assertEq(stacker.totalStacked(), 0);
        assertEq(stacker.projectStacked(address(factory)), 0);
        assertEq(stacker.projectShares(address(factory)), 0);

        bytes memory runtime = deployed.code;
        assertGt(runtime.length, 0);
        assertLe(runtime.length, 24_576, "EIP-170 runtime limit");
        for (uint256 i; i < runtime.length; ++i) {
            uint8 op = uint8(runtime[i]);
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x5f;
                continue;
            }
            assertTrue(op != 0xf4 && op != 0xf2 && op != 0xff, "forbidden runtime opcode");
        }

        // With no code at either dependency, the zero path must remain entirely local.
        vm.recordLogs();
        assertEq(stacker.credit(makeAddr("mainnet rehearsal trader"), 0), 0);
        assertEq(vm.getRecordedLogs().length, 0);
        assertEq(stacker.totalStacked(), 0);
    }
}
