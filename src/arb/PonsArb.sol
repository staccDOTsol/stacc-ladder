// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";

interface IPonsCurveArb {
    function buy(uint256 quoteIn, uint256 minTokensOut, address recipient) external payable returns (uint256);
    function sell(uint256 tokensIn, uint256 minQuoteOut, address recipient) external returns (uint256);
}

interface IERC20Arb {
    function transfer(address, uint256) external returns (bool);
    function approve(address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

/// @title PonsArb: atomic Pons curve <-> Uniswap v4 pool arbitrage, flash-funded by the PoolManager.
/// @notice One call borrows ETH (or the token) inside a PoolManager unlock, trades both legs,
///         repays, and pays the ETH profit to the owner. If the profit is below `minProfit`, the
///         whole transaction reverts. No capital is held. Pools quoted in another currency route
///         through that currency's ETH pool (`bridge`, ETH as currency0).
contract PonsArb is IUnlockCallback {
    using CurrencyLibrary for Currency;

    struct Plan {
        address curve;
        address token;
        PoolKey pool; // token against ETH or against the bridge's quote
        PoolKey bridge; // quote/ETH pool, used when the pool is not quoted in ETH
        bool useBridge;
        bool poolCheap; // true: buy token in the pool, sell on the curve; false: the reverse
        uint256 amountIn; // ETH
    }

    IPoolManager public immutable pm;
    address public immutable owner;
    Currency private constant ETH = Currency.wrap(address(0));

    error NotOwner();
    error NotPoolManager();
    error Unprofitable(uint256 ethBack, uint256 ethIn);

    constructor(IPoolManager pm_, address owner_) {
        pm = pm_;
        owner = owner_;
    }

    receive() external payable {}

    /// @notice Run one arbitrage; returns the ETH profit paid to the owner.
    function arb(Plan calldata p, uint256 minProfit) external returns (uint256 profit) {
        if (msg.sender != owner) revert NotOwner();
        profit = abi.decode(pm.unlock(abi.encode(p)), (uint256));
        if (profit < minProfit) revert Unprofitable(profit, minProfit);
        (bool ok,) = owner.call{value: address(this).balance}("");
        require(ok, "pay");
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(pm)) revert NotPoolManager();
        Plan memory p = abi.decode(data, (Plan));
        Currency tok = Currency.wrap(p.token);
        uint256 ethBack;
        if (p.poolCheap) {
            // ETH -> [quote] -> token in the pools, token -> ETH on the curve
            uint256 tokOut = _toToken(p, p.amountIn);
            pm.take(tok, address(this), tokOut);
            IERC20Arb(p.token).approve(p.curve, tokOut);
            ethBack = IPonsCurveArb(p.curve).sell(tokOut, 0, address(this));
            if (ethBack < p.amountIn) revert Unprofitable(ethBack, p.amountIn);
            pm.settle{value: p.amountIn}();
        } else {
            // ETH -> token on the curve, token -> [quote] -> ETH in the pools
            pm.take(ETH, address(this), p.amountIn);
            uint256 tokIn = IPonsCurveArb(p.curve).buy{value: p.amountIn}(p.amountIn, 0, address(this));
            ethBack = _toEth(p, tokIn);
            pm.sync(tok);
            IERC20Arb(p.token).transfer(address(pm), tokIn);
            pm.settle();
            if (ethBack < p.amountIn) revert Unprofitable(ethBack, p.amountIn);
            pm.take(ETH, address(this), ethBack - p.amountIn);
        }
        return abi.encode(ethBack - p.amountIn);
    }

    function _toToken(Plan memory p, uint256 ethIn) private returns (uint256) {
        if (!p.useBridge) return _swap(p.pool, ETH, ethIn);
        uint256 q = _swap(p.bridge, ETH, ethIn);
        return _swap(p.pool, p.bridge.currency1, q);
    }

    function _toEth(Plan memory p, uint256 tokIn) private returns (uint256) {
        Currency tok = Currency.wrap(p.token);
        if (!p.useBridge) return _swap(p.pool, tok, tokIn);
        uint256 q = _swap(p.pool, tok, tokIn);
        return _swap(p.bridge, p.bridge.currency1, q);
    }

    /// @dev Exact-in swap of `amountIn` of `inC`; returns the output credited to this contract.
    function _swap(PoolKey memory key, Currency inC, uint256 amountIn) private returns (uint256) {
        bool zeroForOne = inC == key.currency0;
        BalanceDelta d = pm.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            ""
        );
        int128 out = zeroForOne ? d.amount1() : d.amount0();
        return out > 0 ? uint256(uint128(out)) : 0;
    }

    /// @notice Recover anything left here (tokens or ETH).
    function sweep(address token) external {
        if (msg.sender != owner) revert NotOwner();
        if (token == address(0)) {
            (bool ok,) = owner.call{value: address(this).balance}("");
            require(ok, "pay");
        } else {
            IERC20Arb(token).transfer(owner, IERC20Arb(token).balanceOf(address(this)));
        }
    }
}
