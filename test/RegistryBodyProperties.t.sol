// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {RegistryBase} from "./ProjectRegistry.t.sol";
import {ProjectRegistry} from "src/ProjectRegistry.sol";

/// @notice Exercise the bytes actually paid for, decoding JSON with Foundry rather than
/// duplicating the Solidity serializer. The allowed-input generator discards no fuzz cases.
/// forge-config: default.fuzz.runs = 1000
contract RegistryBodyPropertiesTest is RegistryBase {
    function setUp() public override {
        vm.chainId(11155111);
        super.setUp();
    }

    function testFuzz_applicationBodyRoundTripsValidText(
        bytes32 seed,
        uint8 nameSize,
        uint8 urlSize,
        uint16 rawRate
    ) public {
        string memory name = _text(bound(nameSize, 1, 48), seed);
        string memory url = _url(bound(urlSize, 12, 200), seed);
        uint16 rate = uint16(bound(rawRate, 25, 100));
        _checkApplication(name, url, rate);
    }

    function testFuzz_challengeBodyRoundTripsValidText(bytes32 seed, uint16 size) public {
        _listed();
        _checkChallenge(_text(bound(size, 1, 280), seed));
    }

    function test_applicationMinimumTextAndRate() public {
        _checkApplication("X", "https://a.co", 25);
    }

    function test_applicationMaximumTextAndRate() public {
        _checkApplication(_text(48, keccak256("max name")), _url(200, keccak256("max url")), 100);
    }

    function test_challengeMinimumReason() public {
        _listed();
        _checkChallenge("X");
    }

    function test_challengeMaximumReason() public {
        _listed();
        _checkChallenge(_text(280, keccak256("max reason")));
    }

    function _checkApplication(string memory name, string memory url, uint16 rate) internal {
        vm.prank(applicant);
        bytes32 id = reg.applyListing(project, name, url, rate, beneficiary);
        string memory body = string(intake.bodyOf(id));
        _checkEnvelope(body);
        string memory question = vm.parseJsonString(body, ".question");
        assertTrue(vm.contains(question, string.concat("[NAME]", name, "[/NAME]")));
        assertTrue(vm.contains(question, string.concat("[URL]", url, "[/URL]")));
        assertTrue(vm.contains(question, "untrusted applicant text"));
        assertTrue(vm.contains(question, string.concat(vm.toString(rate), " basis points")));
        assertTrue(
            vm.contains(
                vm.parseJsonString(body, ".definitions.beneficiary"),
                vm.toLowercase(vm.toString(beneficiary))
            )
        );
        assertTrue(_answer(id, true));
        ProjectRegistry.Project memory p = reg.projectOf(project);
        assertTrue(p.listed);
        assertEq(p.rateBps, rate);
        assertEq(p.beneficiary, beneficiary);
    }

    function _checkChallenge(string memory reason) internal {
        vm.warp(reg.projectOf(project).challengeOpenAt);
        vm.prank(challenger);
        bytes32 id = reg.challenge(project, reason);
        string memory body = string(intake.bodyOf(id));
        _checkEnvelope(body);
        string memory question = vm.parseJsonString(body, ".question");
        assertTrue(vm.contains(question, string.concat("[REASON]", reason, "[/REASON]")));
        assertTrue(vm.contains(question, "untrusted text"));
        assertTrue(vm.contains(question, "50 basis points"));
        assertTrue(_answer(id, false));
        assertFalse(reg.isListed(project));
        assertEq(imd.balanceOf(address(reg)), 0);
        assertEq(imd.balanceOf(challenger), 1_000e18 - 0.5e18);
    }

    function _checkEnvelope(string memory body) internal {
        assertLe(bytes(body).length, 16_384, "paid-door body cap");
        assertEq(vm.parseJsonKeys(body, ".").length, 12, "unexpected top-level JSON key");
        assertEq(vm.parseJsonUint(body, ".v"), 1);
        assertEq(vm.parseJsonUint(body, ".chainId"), 1, "question routing chain");
        assertEq(vm.parseJsonUint(body, ".consumer.chainId"), 11155111, "signature domain chain");
        assertEq(vm.parseJsonAddress(body, ".consumer.verifyingContract"), address(reg));
        assertEq(vm.parseJsonUint(body, ".panelSize"), 15);
        assertEq(vm.parseJsonUint(body, ".quorum"), 11);
        assertEq(vm.parseJsonUint(body, ".window.hours"), 1);
        assertEq(vm.parseJsonUint(body, ".validForSeconds"), 86400);
        assertEq(vm.parseJsonString(body, ".answerType"), "bool");
        assertEq(vm.parseJsonString(body, ".evidence"), "panel");
        assertTrue(vm.parseJsonBool(body, ".allowAmbiguous"));
        string memory question = vm.parseJsonString(body, ".question");
        assertGt(bytes(question).length, 0);
        assertLe(bytes(question).length, 2000, "paid-door question cap");
        assertTrue(vm.contains(question, "on chain 11155111"));
        assertTrue(vm.contains(question, vm.toLowercase(vm.toString(project))));
        assertTrue(vm.contains(question, vm.toLowercase(vm.toString(STACKER))));
        string[] memory keys = vm.parseJsonKeys(body, ".definitions");
        assertEq(keys.length, 8, "version 2 rules");
        for (uint256 i; i < keys.length; ++i) {
            assertLe(bytes(keys[i]).length, 64);
            bytes memory value =
                bytes(vm.parseJsonString(body, string.concat(".definitions.", keys[i])));
            assertGt(value.length, 0);
            assertLe(value.length, 512, "paid-door definition cap");
        }
        // The clarifications that let PLEA's rehearsal reach a signed answer.
        assertTrue(
            vm.contains(
                vm.parseJsonString(body, ".definitions.otherPayouts"), "simply earns no points"
            )
        );
        assertTrue(vm.contains(vm.parseJsonString(body, ".definitions.trader"), "hookData"));
        assertTrue(
            vm.contains(vm.parseJsonString(body, ".definitions.feeGuard"), "every allowed setting")
        );
        assertTrue(
            vm.contains(
                vm.parseJsonString(body, ".definitions.lockedValue"), "no owner or team wallet"
            )
        );
        assertTrue(vm.contains(vm.parseJsonString(body, ".definitions.evidence"), "Sourcify"));
    }

    function test_everyForbiddenByteIsRejectedInEveryUserTextFieldBeforePayment() public {
        uint256 applicantBefore = imd.balanceOf(applicant);
        for (uint256 c; c < 256; ++c) {
            if (_allowed(uint8(c))) continue;
            string memory bad = string(abi.encodePacked("x", bytes1(uint8(c)), "y"));
            vm.prank(applicant);
            vm.expectRevert(ProjectRegistry.BadText.selector);
            reg.applyListing(project, bad, "https://a.co", 50, beneficiary);
            vm.prank(applicant);
            vm.expectRevert(ProjectRegistry.BadText.selector);
            reg.applyListing(
                project, "X", string.concat("https://example.org/", bad), 50, beneficiary
            );
        }
        assertEq(imd.balanceOf(applicant), applicantBefore);
        assertEq(intake.count(), 0);
        assertEq(uint8(reg.projectOf(project).ask), uint8(ProjectRegistry.Ask.None));

        _listed();
        vm.warp(reg.projectOf(project).challengeOpenAt);
        uint256 challengerBefore = imd.balanceOf(challenger);
        for (uint256 c; c < 256; ++c) {
            if (_allowed(uint8(c))) continue;
            vm.prank(challenger);
            vm.expectRevert(ProjectRegistry.BadText.selector);
            reg.challenge(project, string(abi.encodePacked("x", bytes1(uint8(c)), "y")));
        }
        assertEq(imd.balanceOf(challenger), challengerBefore);
        assertEq(intake.count(), 1);
        assertEq(imd.balanceOf(address(reg)), 0);
        assertTrue(reg.isListed(project));
        assertEq(uint8(reg.projectOf(project).ask), uint8(ProjectRegistry.Ask.None));
    }

    function test_textLengthsJustOutsideLimitsAreAtomic() public {
        string[3] memory names = ["", _text(49, bytes32(uint256(1))), "X"];
        string[3] memory urls = ["https://a.co", "https://a.co", _url(201, bytes32(uint256(2)))];
        for (uint256 i; i < names.length; ++i) {
            vm.prank(applicant);
            vm.expectRevert(ProjectRegistry.BadText.selector);
            reg.applyListing(project, names[i], urls[i], 50, beneficiary);
        }
        vm.prank(applicant);
        vm.expectRevert(ProjectRegistry.BadText.selector);
        reg.applyListing(project, "X", "https://abc", 50, beneficiary); // 11 bytes
        assertEq(imd.balanceOf(applicant), 1_000e18);
        assertEq(intake.count(), 0);

        _listed();
        vm.warp(reg.projectOf(project).challengeOpenAt);
        string memory longReason = _text(281, keccak256("reason"));
        vm.prank(challenger);
        vm.expectRevert(ProjectRegistry.BadText.selector);
        reg.challenge(project, "");
        vm.prank(challenger);
        vm.expectRevert(ProjectRegistry.BadText.selector);
        reg.challenge(project, longReason);
        assertEq(imd.balanceOf(challenger), 1_000e18);
        assertEq(intake.count(), 1);
        assertEq(imd.balanceOf(address(reg)), 0);
    }

    function _allowed(uint8 c) internal pure returns (bool) {
        return c >= 0x20 && c <= 0x7e && c != 0x22 && c != 0x5c && c != 0x5b && c != 0x5d;
    }

    function _text(uint256 size, bytes32 seed) internal pure returns (string memory) {
        bytes memory value = new bytes(size);
        for (uint256 i; i < size; ++i) {
            uint8 c = 0x20 + uint8(seed[i % 32]) % 95;
            value[i] = _allowed(c) ? bytes1(c) : bytes1("x");
        }
        return string(value);
    }

    function _url(uint256 size, bytes32 seed) internal pure returns (string memory) {
        bytes memory value = new bytes(size);
        bytes memory prefix = bytes("https://a.co");
        for (uint256 i; i < prefix.length; ++i) {
            value[i] = prefix[i];
        }
        if (size > prefix.length) value[prefix.length] = "/";
        for (uint256 i = prefix.length + 1; i < size; ++i) {
            value[i] = bytes1(uint8(97 + uint8(seed[i % 32]) % 26));
        }
        return string(value);
    }
}
