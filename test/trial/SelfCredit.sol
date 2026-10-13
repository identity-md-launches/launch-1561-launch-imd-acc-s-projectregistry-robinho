// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface IERC20Approve {
    function approve(address spender, uint256 amount) external returns (bool);
}

interface IStacker {
    function credit(address trader, uint256 imdAmount) external returns (uint256 shares);
}

/// @title SelfCredit
/// @notice A negative case for the imd/acc ProjectRegistry trial on Sepolia. It is not a trading
/// venue: there are no trades and no fees. Its owner credits the contract's own test IMD to any
/// wallets the owner picks. The registry's oracle panel is expected to refuse to list it.
contract SelfCredit {
    IERC20Approve public immutable imd;
    IStacker public immutable stacker;
    address public immutable owner;

    constructor(IERC20Approve imd_, IStacker stacker_) {
        imd = imd_;
        stacker = stacker_;
        owner = msg.sender;
        imd_.approve(address(stacker_), type(uint256).max);
    }

    /// @notice Credits `amount` of this contract's own IMD to each of `wallets`. No trade happens.
    function creditTo(address[] calldata wallets, uint256 amount) external {
        require(msg.sender == owner, "not owner");
        for (uint256 i; i < wallets.length; ++i) {
            stacker.credit(wallets[i], amount);
        }
    }
}
