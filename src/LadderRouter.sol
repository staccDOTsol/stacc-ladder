// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";
import {State, QuoteCfg, TokenRef, REF_PONS, REF_V4} from "./LadderTypes.sol";
import {LadderRefs, IPonsCurve} from "./LadderRefs.sol";

interface IERC20R {
    function transfer(address, uint256) external returns (bool);
    function approve(address, uint256) external returns (bool);
}

/// @title LadderRouter: moves the hook's claims through native ETH, and burns toll.
/// @notice Runs inside a PoolManager unlock held by the hook. `toEth` spends the hook's ERC-6909
///         claims of a currency and leaves native ETH in the hook; `fromEth` spends native ETH
///         and either mints claims back to the hook or delivers the output to an address. Routes:
///         ETH; listed quotes through their ETH pool; referenced tokens through their Pons curve
///         before graduation, through the pool Pons seeded after it, or through their set v4
///         pool. Every leg checks its output against the smoothed reference from earlier blocks
///         (the worse side of live and smoothed for the hook), so pushing a price inside one
///         transaction makes the leg revert instead of fill.
library LadderRouter {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    Currency internal constant ETH = Currency.wrap(address(0));
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;
    uint256 internal constant FEE_ALLOWANCE_BPS = 300; // pool / curve fees a leg may pay on top of maxSlip

    error Slippage(uint256 out, uint256 minOut);
    error NoRoute();

    event Burned(Currency indexed from, uint256 amountIn, uint256 feeTokenBurned);

    // ───────────────────────────── pricing ─────────────────────────────

    /// @dev Expected output, at the hook-favourable side of live and smoothed, less tolerance.
    function _minOut(State storage s, Currency c, uint256 amt, bool buying) private returns (uint256) {
        (int24 live, int24 sPrev,, bool ok) = LadderRefs.observe(s, Currency.unwrap(c), ETH);
        if (!ok) revert NoRoute();
        // tick = ETH per c. Selling c: expect the higher price. Buying c: expect the lower price.
        int24 t = buying ? (live < sPrev ? live : sPrev) : (live > sPrev ? live : sPrev);
        uint256 sp = TickMath.getSqrtPriceAtTick(t);
        uint256 pX96 = FullMath.mulDiv(sp, sp, 1 << 96);
        uint256 expected = buying ? FullMath.mulDiv(amt, 1 << 96, pX96) : FullMath.mulDiv(amt, pX96, 1 << 96);
        uint256 tol = uint256(s.p.maxSlipBps) + FEE_ALLOWANCE_BPS;
        return tol >= 10_000 ? 0 : expected * (10_000 - tol) / 10_000;
    }

    /// @notice ETH value of `amt` of `c` at the live reference (thresholds only).
    function ethValue(State storage s, Currency c, uint256 amt) public view returns (uint256) {
        if (c.isAddressZero()) return amt;
        (int24 t, bool ok) = LadderRefs.pairTick(s, Currency.unwrap(c), ETH);
        if (!ok) return 0;
        uint256 sp = TickMath.getSqrtPriceAtTick(t);
        return FullMath.mulDiv(amt, FullMath.mulDiv(sp, sp, 1 << 96), 1 << 96);
    }

    // ───────────────────────────── routes ─────────────────────────────

    /// @dev The v4 pool a currency trades against ETH in, when it does not use a live Pons curve.
    function _ethPool(State storage s, Currency c) private view returns (bool ok, PoolKey memory key) {
        QuoteCfg storage q = s.quotes[c];
        if (q.listed) return (true, q.ethPool);
        TokenRef storage r = s.refs[Currency.unwrap(c)];
        if (r.kind == REF_V4) key = r.pool;
        else if (r.kind == REF_PONS) (ok, key) = LadderRefs.ponsPoolKey(IPonsCurve(r.curve), Currency.unwrap(c));
        else return (false, key);
        if (r.kind == REF_V4) ok = true;
        if (ok && !key.currency0.isAddressZero()) ok = false; // routes are single hop against ETH
    }

    function _liveCurve(State storage s, Currency c) private view returns (IPonsCurve) {
        TokenRef storage r = s.refs[Currency.unwrap(c)];
        if (r.kind != REF_PONS) return IPonsCurve(address(0));
        IPonsCurve curve = IPonsCurve(r.curve);
        if (curve.graduated() || curve.pairToken() != address(0)) return IPonsCurve(address(0));
        return curve;
    }

    /// @dev Exact-in swap; `inC` was credited to the hook beforehand (claims burned or ETH settled).
    function _swap(State storage s, PoolKey memory key, Currency inC, uint256 amt)
        private
        returns (uint256 out, uint256 used, Currency outC)
    {
        bool zeroForOne = inC == key.currency0;
        BalanceDelta d = s.pm.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amt),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            ""
        );
        int128 dIn = zeroForOne ? d.amount0() : d.amount1();
        int128 dOut = zeroForOne ? d.amount1() : d.amount0();
        used = dIn < 0 ? uint256(uint128(-dIn)) : 0;
        out = dOut > 0 ? uint256(uint128(dOut)) : 0;
        outC = zeroForOne ? key.currency1 : key.currency0;
    }

    /// @notice Spend `amt` of the hook's claims of `c`; leaves native ETH in the hook.
    function toEth(State storage s, Currency c, uint256 amt) public returns (uint256 ethOut, uint256 used) {
        if (amt == 0) return (0, 0);
        if (c.isAddressZero()) {
            s.pm.burn(address(this), c.toId(), amt);
            s.pm.take(c, address(this), amt);
            return (amt, amt);
        }
        uint256 minOut = _minOut(s, c, amt, false);
        IPonsCurve curve = _liveCurve(s, c);
        if (address(curve) != address(0)) {
            s.pm.burn(address(this), c.toId(), amt);
            s.pm.take(c, address(this), amt);
            IERC20R(Currency.unwrap(c)).approve(address(curve), amt);
            ethOut = curve.sell(amt, 0, address(this));
            used = amt;
        } else {
            (bool ok, PoolKey memory key) = _ethPool(s, c);
            if (!ok) revert NoRoute();
            Currency outC;
            (ethOut, used, outC) = _swap(s, key, c, amt);
            s.pm.burn(address(this), c.toId(), used);
            s.pm.take(outC, address(this), ethOut);
        }
        if (ethOut < minOut) revert Slippage(ethOut, minOut);
    }

    /// @notice Spend `eth` native ETH for `c`, minted to the hook as claims or delivered to `to`.
    function fromEth(State storage s, Currency c, uint256 eth, address to) public returns (uint256 out) {
        if (eth == 0) return 0;
        bool keep = to == address(this);
        if (c.isAddressZero()) {
            if (keep) {
                s.pm.settle{value: eth}();
                s.pm.mint(address(this), c.toId(), eth);
            } else {
                (bool ok,) = to.call{value: eth}("");
                require(ok, "eth");
            }
            return eth;
        }
        uint256 minOut = _minOut(s, c, eth, true);
        IPonsCurve curve = _liveCurve(s, c);
        if (address(curve) != address(0)) {
            out = curve.buy{value: eth}(eth, 0, address(this));
            if (keep) {
                s.pm.sync(c);
                IERC20R(Currency.unwrap(c)).transfer(address(s.pm), out);
                s.pm.settle();
                s.pm.mint(address(this), c.toId(), out);
            } else {
                IERC20R(Currency.unwrap(c)).transfer(to, out);
            }
        } else {
            (bool ok, PoolKey memory key) = _ethPool(s, c);
            if (!ok) revert NoRoute();
            s.pm.settle{value: eth}();
            (uint256 got, uint256 used,) = _swap(s, key, ETH, eth);
            out = got;
            if (eth > used) s.pm.take(ETH, address(this), eth - used);
            if (keep) s.pm.mint(address(this), c.toId(), out);
            else s.pm.take(c, to, out);
        }
        if (out < minOut) revert Slippage(out, minOut);
    }

    // ───────────────────────────── buy and burn ─────────────────────────────

    /// @notice Convert a currency's pending toll into the fee token and send it to 0xdead.
    function burnStep(State storage s, Currency c) public returns (bool) {
        address ft = s.burn.token;
        uint256 amt = s.burnable[c];
        if (ft == address(0) || amt == 0) return false;
        if (s.burn.minBurnWei != 0 && ethValue(s, c, amt) < s.burn.minBurnWei) return false;
        s.burnable[c] = 0;
        uint256 burned;
        if (Currency.unwrap(c) == ft) {
            s.pm.burn(address(this), c.toId(), amt);
            s.pm.take(c, DEAD, amt);
            burned = amt;
        } else {
            (uint256 eth, uint256 used) = toEth(s, c, amt);
            if (used < amt) s.burnable[c] += amt - used;
            burned = fromEth(s, Currency.wrap(ft), eth, DEAD);
        }
        emit Burned(c, amt, burned);
        return true;
    }

    /// @notice One bounded burn per call: the next toll currency with anything pending.
    function nextBurn(State storage s) external {
        uint256 n = s.tollCurrencies.length;
        for (uint256 i; i < n && i < 4; ++i) {
            uint256 j = (s.burnCursor + i) % n;
            Currency c = s.tollCurrencies[j];
            if (s.burnable[c] != 0) {
                s.burnCursor = j + 1;
                burnStep(s, c);
                return;
            }
        }
    }
}
