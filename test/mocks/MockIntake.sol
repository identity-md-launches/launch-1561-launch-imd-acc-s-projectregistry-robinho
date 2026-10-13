// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IIntake} from "../../src/ProjectRegistry.sol";
import {OracleAttestation} from "../../src/oracle/OracleAttestation.sol";

/// @dev The Sepolia test IMD: anyone can mint.
contract MintableIMD is ERC20 {
    constructor() ERC20("Identity.md (test)", "IMD") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev Stands in for the IdentityMD Intake v2: takes the payment the way the real one does (pulls
/// exactly `amount` of `asset` to its treasury), records the request, and lets a test play the
/// writer, delivering an answer or a failure with the gas the real Intake gives (200k on mainnet,
/// 1M on Sepolia) inside a try, so a reverting callback can't block the write.
contract MockIntake is IIntake {
    bytes32 public constant ACTION = "oracle.request@oracle-1";
    uint256 public constant PRICE = 0.5e18;
    uint256 public price = PRICE;
    address public constant TREASURY = address(0x7EA5);

    struct Req {
        address payer;
        address target;
        bytes4 selector;
        bytes4 onFailure;
        bool completed;
        bytes body;
    }

    mapping(bytes32 => Req) internal _reqs;
    uint256 public count;
    bytes32 public lastId;

    error ActionNotSold();
    error PriceNotMet();

    function setPrice(uint256 amount) external {
        price = amount;
    }

    function priceOf(bytes32 action, address) external view returns (uint256) {
        return action == ACTION ? price : 0;
    }

    function requestWithFailure(
        bytes32 action,
        bytes calldata body,
        Callback calldata callback,
        bytes4 onFailure,
        address asset,
        uint256 amount
    ) external returns (bytes32 id) {
        if (action != ACTION || price == 0) revert ActionNotSold();
        if (amount < price) revert PriceNotMet();
        IERC20(asset).transferFrom(msg.sender, TREASURY, amount);
        id = keccak256(abi.encode(address(this), ++count));
        _reqs[id] = Req(msg.sender, callback.target, callback.selector, onFailure, false, body);
        lastId = id;
    }

    function requests(bytes32 id) external view returns (address, address, bytes4, bool) {
        Req storage r = _reqs[id];
        return (r.payer, r.target, r.selector, r.completed);
    }

    function bodyOf(bytes32 id) external view returns (bytes memory) {
        return _reqs[id].body;
    }

    /// @dev Status 0 with an answer: calls the callback with `gasLimit`, like `complete`.
    function deliver(
        bytes32 id,
        OracleAttestation.Attestation calldata a,
        bytes calldata sig,
        uint256 gasLimit
    ) external returns (bool delivered) {
        Req storage r = _reqs[id];
        r.completed = true;
        (delivered,) = r.target.call{gas: gasLimit}(abi.encodeWithSelector(r.selector, id, a, sig));
    }

    /// @dev Status 1 or 2: calls the failure function with `gasLimit`.
    function fail(bytes32 id, uint8 status, bytes32 reason, uint256 gasLimit)
        external
        returns (bool delivered)
    {
        Req storage r = _reqs[id];
        r.completed = true;
        (delivered,) = r.target.call{gas: gasLimit}(
            abi.encodeWithSelector(r.onFailure, id, status, reason, uint16(0), uint16(0), bytes(""))
        );
    }

    /// @dev Completed with no call at all (as a version 1 request, or a callback that never ran).
    function completeSilently(bytes32 id) external {
        _reqs[id].completed = true;
    }
}

/// @dev Anything with code can be a project.
contract MockProject {}
