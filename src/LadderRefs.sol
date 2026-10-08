// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";
import {State, QuoteCfg, TokenRef, Obs, Params, REF_PONS, REF_V4} from "./LadderTypes.sol";

interface IPonsCurve {
    function token() external view returns (address);
    function factory() external view returns (address);
    function pairToken() external view returns (address);
    function graduated() external view returns (bool);
    function getReserves() external view returns (uint256 quoteReserve, uint256 tokenReserve);
    function buy(uint256 quoteIn, uint256 minTokensOut, address recipient) external payable returns (uint256);
    function sell(uint256 tokensIn, uint256 minQuoteOut, address recipient) external returns (uint256);
}

/// @title LadderRefs: reference prices and volatility.
/// @notice Ticks are log_1.0001 of "quote per token". A token's reference is its Pons curve,
///         then the pool Pons seeded after graduation (read from the factory's launch record),
///         or a v4 pool the owner set. Quotes are ETH, listed quotes (priced by an ETH pool) and
///         the hook's fee token (priced by its own reference). Observations are recorded at most
///         once per block; `sPrev` is the smoothed tick from earlier blocks only.
library LadderRefs {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    uint256 internal constant ONE = 1e18;

    // ───────────────────────────── references ─────────────────────────────

    /// @dev log_1.0001(num / den), clamped to the usable tick range.
    function _tickFromRatio(uint256 num, uint256 den) private pure returns (int256) {
        if (num == 0) return TickMath.MIN_TICK + 1;
        if (den == 0 || num / den >= (1 << 63)) return TickMath.MAX_TICK - 1;
        uint256 pX192 = FullMath.mulDiv(num, 1 << 192, den);
        uint256 sq = _sqrt(pX192);
        if (sq < TickMath.MIN_SQRT_PRICE) return TickMath.MIN_TICK + 1;
        if (sq >= TickMath.MAX_SQRT_PRICE) return TickMath.MAX_TICK - 1;
        return TickMath.getTickAtSqrtPrice(uint160(sq));
    }

    function _sqrt(uint256 x) private pure returns (uint256 z) {
        if (x == 0) return 0;
        z = x;
        uint256 y = (x >> 1) + 1;
        if (y < z) {
            z = y;
            y = (x / y + y) >> 1;
            while (y < z) {
                z = y;
                y = (x / y + y) >> 1;
            }
        }
    }

    /// @dev Tick of "ETH per one unit of quote c". ETH is 0; a listed quote reads its ETH pool.
    function _quoteEthTick(State storage s, Currency c) private view returns (int256, bool) {
        if (c.isAddressZero()) return (0, true);
        QuoteCfg storage q = s.quotes[c];
        if (!q.listed) {
            // the hook's fee token is a quote for every family, priced through its own reference
            address ft = s.burn.token;
            if (ft != address(0) && Currency.unwrap(c) == ft) return _refTick(s, ft);
            return (0, false);
        }
        (uint160 sp, int24 t,,) = s.pm.getSlot0(q.ethPool.toId());
        if (sp == 0) return (0, false);
        return (-int256(t), true); // pool tick is quote per ETH
    }

    /// @dev Tick of "ETH per one unit of token": quotes directly, tokens through their reference.
    function _ethTick(State storage s, address token) private view returns (int256, bool) {
        Currency c = Currency.wrap(token);
        if (c.isAddressZero() || s.quotes[c].listed) return _quoteEthTick(s, c);
        return _refTick(s, token);
    }

    /// @dev A token's own reference: its Pons curve, then the pool Pons seeded, or a set v4 pool.
    function _refTick(State storage s, address token) private view returns (int256, bool) {
        TokenRef storage r = s.refs[token];
        if (r.kind == REF_PONS) {
            IPonsCurve curve = IPonsCurve(r.curve);
            if (curve.graduated()) return _ponsPoolTick(s, curve, token);
            (uint256 qr, uint256 tr) = curve.getReserves();
            int256 t = _tickFromRatio(qr, tr); // pairToken per token
            (int256 pt, bool ok) = _quoteEthTick(s, Currency.wrap(curve.pairToken()));
            return (t + pt, ok);
        }
        if (r.kind == REF_V4) {
            (uint160 sp, int24 pt,,) = s.pm.getSlot0(r.pool.toId());
            if (sp == 0) return (0, false);
            bool tokenIs0 = Currency.unwrap(r.pool.currency0) == token;
            Currency other = tokenIs0 ? r.pool.currency1 : r.pool.currency0;
            (int256 ot, bool ok) = _quoteEthTick(s, other);
            return ((tokenIs0 ? int256(pt) : -int256(pt)) + ot, ok);
        }
        return (0, false);
    }

    /// @dev After graduation: the Uniswap pool Pons seeded, read from the factory's launch record
    ///      (token, curve, deployer, feeRecipient, pairToken, threshold, poolFee, tickSpacing, ...)
    ///      on Pons's meme hook. Unavailable until that pool holds liquidity.
    function _ponsPoolTick(State storage s, IPonsCurve curve, address token) private view returns (int256, bool) {
        (bool ok, PoolKey memory key) = _ponsPoolKey(curve, token);
        if (!ok) return (0, false);
        (uint160 sp, int24 pt,,) = s.pm.getSlot0(key.toId());
        if (sp == 0 || s.pm.getLiquidity(key.toId()) == 0) return (0, false);
        bool tokenIs0 = Currency.unwrap(key.currency0) == token;
        Currency pair = tokenIs0 ? key.currency1 : key.currency0;
        (int256 ot, bool okq) = _quoteEthTick(s, pair);
        return ((tokenIs0 ? int256(pt) : -int256(pt)) + ot, okq);
    }

    function ponsPoolKey(IPonsCurve curve, address token) external view returns (bool, PoolKey memory key) {
        return _ponsPoolKey(curve, token);
    }

    function _ponsPoolKey(IPonsCurve curve, address token) private view returns (bool, PoolKey memory key) {
        address f = curve.factory();
        (bool ok, bytes memory r) = f.staticcall(abi.encodeWithSignature("getLaunchedToken(address)", token));
        if (!ok || r.length < 256) return (false, key);
        (,,,, address pair,, uint256 fee, int256 ts) =
            abi.decode(r, (address, address, address, address, address, uint256, uint256, int256));
        bytes memory h;
        (ok, h) = f.staticcall(abi.encodeWithSignature("memeHook()"));
        if (!ok || h.length < 32 || fee > type(uint24).max || ts <= 0 || ts > type(int16).max) return (false, key);
        bool pairFirst = pair < token;
        key = PoolKey({
            currency0: Currency.wrap(pairFirst ? pair : token),
            currency1: Currency.wrap(pairFirst ? token : pair),
            fee: uint24(fee),
            tickSpacing: int24(ts),
            hooks: IHooks(abi.decode(h, (address)))
        });
        return (true, key);
    }

    /// @notice Live tick of "quote per token" (log_1.0001), from the token's reference.
    function pairTick(State storage s, address token, Currency q) external view returns (int24, bool) {
        return _pairTick(s, token, q);
    }

    function _pairTick(State storage s, address token, Currency q) private view returns (int24, bool) {
        (int256 a, bool okA) = _ethTick(s, token);
        (int256 b, bool okB) = _quoteEthTick(s, q);
        if (!okA || !okB) return (0, false);
        int256 t = a - b;
        if (t <= TickMath.MIN_TICK) t = TickMath.MIN_TICK + 1;
        if (t >= TickMath.MAX_TICK) t = TickMath.MAX_TICK - 1;
        return (int24(t), true);
    }

    function _obsKey(address token, Currency q) private pure returns (bytes32) {
        return keccak256(abi.encode(token, q));
    }

    /// @dev Record the live reference at most once per block and return
    ///      (live, smoothed-before-this-block, horizon sigma in ticks, ok).
    function observe(State storage s, address token, Currency q)
        external
        returns (int24 live, int24 sPrev, uint256 sigma, bool ok)
    {
        (live, ok) = _pairTick(s, token, q);
        if (!ok) return (0, 0, 0, false);
        Obs storage o = s.obs[_obsKey(token, q)];
        Params storage p = s.p;
        if (o.time == 0) {
            o.blk = uint64(block.number);
            o.time = uint64(block.timestamp);
            o.last = live;
            o.sPrev = live;
            o.sCur = live;
            uint256 iv = uint256(uint24(p.initVol));
            o.varRate = uint128(iv * iv * 1e6 / p.horizon);
        } else if (o.blk != block.number) {
            o.sPrev = o.sCur;
            uint256 dt = block.timestamp - o.time;
            if (dt > 0) {
                uint256 a = dt * ONE / (dt + p.tau);
                o.sCur = int24(int256(o.sCur) + (int256(live) - int256(o.sCur)) * int256(a) / int256(ONE));
                int256 r = int256(live) - int256(o.last);
                uint256 inst = uint256(r * r) * 1e6 / dt;
                uint256 v = o.varRate;
                v = inst > v ? v + (inst - v) * a / ONE : v - (v - inst) * a / ONE;
                o.varRate = uint128(v > type(uint128).max ? type(uint128).max : v);
                o.last = live;
                o.time = uint64(block.timestamp);
            }
            o.blk = uint64(block.number);
        }
        sPrev = o.sPrev;
        sigma = _sigma(s, o);
    }

    function _sigma(State storage s, Obs storage o) private view returns (uint256 sig) {
        if (o.time == 0) return uint256(uint24(s.p.initVol));
        sig = _sqrt(uint256(o.varRate) * s.p.horizon / 1e6);
        uint256 floor = uint256(uint24(s.p.minVol));
        if (sig < floor) sig = floor;
    }

    /// @notice Horizon sigma of a pair from stored observations (no update).
    function sigmaOf(State storage s, address token, Currency q) external view returns (uint256) {
        return _sigma(s, s.obs[_obsKey(token, q)]);
    }

}
