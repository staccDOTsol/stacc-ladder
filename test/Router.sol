// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";

interface IERC20T {
    function transfer(address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
}

/// @notice Test router: runs a list of swaps / liquidity changes inside ONE unlock and settles
///         from its own balances. Each call to `run` is one transaction's worth of actions.
contract Router is IUnlockCallback {
    using CurrencyLibrary for Currency;

    struct Act {
        bool isSwap;
        PoolKey key;
        bool zeroForOne;
        int256 amount; // swap: amountSpecified; liquidity: liquidityDelta
        int24 lo;
        int24 hi;
        bytes32 salt;
    }

    IPoolManager public immutable pm;
    BalanceDelta[] public last;

    constructor(IPoolManager pm_) {
        pm = pm_;
    }

    receive() external payable {}

    function run(Act[] memory acts) external payable returns (BalanceDelta[] memory out) {
        out = abi.decode(pm.unlock(abi.encode(acts)), (BalanceDelta[]));
    }

    function swap(PoolKey memory key, bool zeroForOne, int256 amount) external returns (BalanceDelta) {
        Act[] memory a = new Act[](1);
        a[0] = Act(true, key, zeroForOne, amount, 0, 0, 0);
        return abi.decode(pm.unlock(abi.encode(a)), (BalanceDelta[]))[0];
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(pm), "pm");
        Act[] memory acts = abi.decode(data, (Act[]));
        BalanceDelta[] memory out = new BalanceDelta[](acts.length);
        for (uint256 i; i < acts.length; ++i) {
            Act memory a = acts[i];
            if (a.isSwap) {
                out[i] = pm.swap(
                    a.key,
                    IPoolManager.SwapParams({
                        zeroForOne: a.zeroForOne,
                        amountSpecified: a.amount,
                        sqrtPriceLimitX96: a.zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
                    }),
                    ""
                );
            } else {
                (out[i],) = pm.modifyLiquidity(
                    a.key,
                    IPoolManager.ModifyLiquidityParams({tickLower: a.lo, tickUpper: a.hi, liquidityDelta: a.amount, salt: a.salt}),
                    ""
                );
            }
            _settle(a.key.currency0, out[i].amount0());
            _settle(a.key.currency1, out[i].amount1());
        }
        return abi.encode(out);
    }

    function _settle(Currency c, int128 d) private {
        if (d < 0) {
            uint256 a = uint256(uint128(-d));
            if (c.isAddressZero()) {
                pm.settle{value: a}();
            } else {
                pm.sync(c);
                IERC20T(Currency.unwrap(c)).transfer(address(pm), a);
                pm.settle();
            }
        } else if (d > 0) {
            pm.take(c, address(this), uint256(uint128(d)));
        }
    }
}
