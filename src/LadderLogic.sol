// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";
import {LiquidityAmounts} from "v4-periphery/libraries/LiquidityAmounts.sol";
import {
    State, Tier, QuoteCfg, TokenRef, Obs, Pos, Family, Book, Due, Params, REF_PONS, REF_V4
} from "./LadderTypes.sol";

interface IPonsCurve {
    function token() external view returns (address);
    function factory() external view returns (address);
    function pairToken() external view returns (address);
    function graduated() external view returns (bool);
    function getReserves() external view returns (uint256 quoteReserve, uint256 tokenReserve);
}

/// @title LadderLogic: references, volatility, placement, rebalancing and the shield.
/// @notice Linked library; every external function runs against the hook's storage by
///         DELEGATECALL, so `address(this)` is the hook and every PoolManager call is the
///         hook's own (its callbacks are skipped and its liquidity is never tolled).
///
///         Placement rule, used everywhere liquidity is put down: a book's ask (token only)
///         sits at or above the HIGHER of the pool price, the live reference and the
///         smoothed reference; its bid (quote only) at or below the LOWER of them. A
///         reference pushed inside one transaction can therefore only make the book's
///         quotes worse for whoever pushed it.
library LadderLogic {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    error NotFamily();
    error NoReference();

    event Rebalanced(address indexed book, address indexed token, uint256 tokenPlaced, uint256 quotePlaced);
    event Shielded(address indexed book, PoolId indexed id, uint8 side, int24 lo, int24 hi);
    event QuotesRebalanced(address indexed book, Currency sold, Currency bought, uint256 amountIn);
    event FamilyPool(address indexed token, Currency indexed quote, uint8 tier, PoolId id);

    Currency internal constant ETH = Currency.wrap(address(0));
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
        if (!q.listed) return (0, false);
        (uint160 sp, int24 t,,) = s.pm.getSlot0(q.ethPool.toId());
        if (sp == 0) return (0, false);
        return (-int256(t), true); // pool tick is quote per ETH
    }

    /// @dev Tick of "ETH per one unit of token": quotes directly, tokens through their reference.
    function _ethTick(State storage s, address token) private view returns (int256, bool) {
        Currency c = Currency.wrap(token);
        if (c.isAddressZero() || s.quotes[c].listed) return _quoteEthTick(s, c);
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
        (bool ok, PoolKey memory key) = ponsPoolKey(curve, token);
        if (!ok) return (0, false);
        (uint160 sp, int24 pt,,) = s.pm.getSlot0(key.toId());
        if (sp == 0 || s.pm.getLiquidity(key.toId()) == 0) return (0, false);
        bool tokenIs0 = Currency.unwrap(key.currency0) == token;
        Currency pair = tokenIs0 ? key.currency1 : key.currency0;
        (int256 ot, bool okq) = _quoteEthTick(s, pair);
        return ((tokenIs0 ? int256(pt) : -int256(pt)) + ot, okq);
    }

    function ponsPoolKey(IPonsCurve curve, address token) public view returns (bool, PoolKey memory key) {
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
    function pairTick(State storage s, address token, Currency q) public view returns (int24, bool) {
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
    function _observe(State storage s, address token, Currency q)
        private
        returns (int24 live, int24 sPrev, uint256 sigma, bool ok)
    {
        (live, ok) = pairTick(s, token, q);
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
    function sigmaOf(State storage s, address token, Currency q) public view returns (uint256) {
        return _sigma(s, s.obs[_obsKey(token, q)]);
    }

    // ───────────────────────────── families ─────────────────────────────

    function familyKey(State storage s, address token, Currency q, uint8 tier)
        public
        view
        returns (PoolKey memory key, bool tokenIs0)
    {
        Tier storage t = s.tiers[tier];
        tokenIs0 = token < Currency.unwrap(q);
        key = PoolKey({
            currency0: tokenIs0 ? Currency.wrap(token) : q,
            currency1: tokenIs0 ? q : Currency.wrap(token),
            fee: t.fee,
            tickSpacing: t.spacing,
            hooks: IHooks(address(this))
        });
    }

    /// @notice Register a pool of this hook as a family pool when its pair and tier qualify.
    function register(State storage s, PoolKey memory key) public returns (bool) {
        PoolId id = key.toId();
        if (s.fam[id].known) return true;
        if (address(key.hooks) != address(this)) return false;
        Currency q;
        address token;
        bool tokenIs0;
        if (_isQuote(s, key.currency0) && s.refs[Currency.unwrap(key.currency1)].kind != 0) {
            q = key.currency0;
            token = Currency.unwrap(key.currency1);
        } else if (_isQuote(s, key.currency1) && s.refs[Currency.unwrap(key.currency0)].kind != 0) {
            q = key.currency1;
            token = Currency.unwrap(key.currency0);
            tokenIs0 = true;
        } else {
            return false;
        }
        uint256 n = s.tiers.length;
        for (uint8 i; i < n; ++i) {
            if (s.tiers[i].fee == key.fee && s.tiers[i].spacing == key.tickSpacing) {
                s.fam[id] = Family({known: true, tokenIs0: tokenIs0, tier: i, token: token, quote: q});
                emit FamilyPool(token, q, i, id);
                return true;
            }
        }
        return false;
    }

    function _isQuote(State storage s, Currency c) private view returns (bool) {
        return c.isAddressZero() || s.quotes[c].listed;
    }

    /// @notice Initialize every missing (token, quote, tier) pool at the live reference price.
    function openFamily(State storage s, address token) external {
        if (s.refs[token].kind == 0) revert NoReference();
        uint256 nq = s.quoteList.length;
        for (uint256 j; j <= nq; ++j) {
            openPair(s, token, j == 0 ? ETH : s.quoteList[j - 1]);
        }
    }

    /// @notice Initialize every missing tier of one (token, quote) pair at the live reference.
    function openPair(State storage s, address token, Currency q) public {
        (int24 live, bool ok) = pairTick(s, token, q);
        if (!ok) return;
        for (uint8 t; t < s.tiers.length; ++t) {
            _ensurePool(s, token, q, t, live);
        }
    }

    /// @notice A pool of this hook was just initialized: register it and, if it belongs to a
    ///         family, open the rest of its pair's fee tiers.
    function onInitialize(State storage s, PoolKey memory key) external {
        if (!register(s, key)) return;
        Family storage f = s.fam[key.toId()];
        openPair(s, f.token, f.quote);
    }

    function _ensurePool(State storage s, address token, Currency q, uint8 tier, int24 pairLive)
        private
        returns (PoolKey memory key, bool tokenIs0, int24 poolTick)
    {
        (key, tokenIs0) = familyKey(s, token, q, tier);
        PoolId id = key.toId();
        uint160 sp;
        (sp, poolTick,,) = s.pm.getSlot0(id);
        if (sp == 0) {
            int24 t = tokenIs0 ? pairLive : -pairLive;
            poolTick = s.pm.initialize(key, TickMath.getSqrtPriceAtTick(t));
        }
        if (!s.fam[id].known) register(s, key);
    }

    // ───────────────────────────── positions ─────────────────────────────

    function _salt(address book, uint8 side) private pure returns (bytes32) {
        return bytes32((uint256(uint160(book)) << 8) | side);
    }

    /// @dev Move one currency's delta between the PoolManager and the book's claims.
    function _settle(State storage s, Book storage b, Currency c, int128 amt) private {
        if (amt > 0) {
            uint256 a = uint256(uint128(amt));
            s.pm.mint(address(this), c.toId(), a);
            b.bal[c] += a;
        } else if (amt < 0) {
            uint256 a = uint256(uint128(-amt));
            s.pm.burn(address(this), c.toId(), a);
            b.bal[c] -= a;
        }
    }

    function _modify(State storage s, address book, PoolKey memory key, int24 lo, int24 hi, int256 dl, uint8 side)
        private
        returns (BalanceDelta delta)
    {
        (delta,) = s.pm.modifyLiquidity(
            key, IPoolManager.ModifyLiquidityParams({tickLower: lo, tickUpper: hi, liquidityDelta: dl, salt: _salt(book, side)}), ""
        );
        Book storage b = s.books[book];
        _settle(s, b, key.currency0, delta.amount0());
        _settle(s, b, key.currency1, delta.amount1());
    }

    function _list(State storage s, PoolId id, address book) private {
        if (s.poolBookIdx[id][book] != 0) return;
        s.poolBooks[id].push(book);
        s.poolBookIdx[id][book] = s.poolBooks[id].length;
    }

    function _unlist(State storage s, PoolId id, address book) private {
        uint256 i = s.poolBookIdx[id][book];
        if (i == 0) return;
        address[] storage l = s.poolBooks[id];
        address last = l[l.length - 1];
        l[i - 1] = last;
        s.poolBookIdx[id][last] = i;
        l.pop();
        delete s.poolBookIdx[id][book];
    }

    /// @dev Remove a book's whole position on one side; returns what came back (principal + fees).
    function _pull(State storage s, address book, PoolKey memory key, uint8 side)
        private
        returns (uint256 got0, uint256 got1)
    {
        PoolId id = key.toId();
        Pos storage p = s.pos[id][book][side];
        if (p.liq == 0) return (0, 0);
        BalanceDelta d = _modify(s, book, key, p.lo, p.hi, -int256(uint256(p.liq)), side);
        got0 = d.amount0() > 0 ? uint256(uint128(d.amount0())) : 0;
        got1 = d.amount1() > 0 ? uint256(uint128(d.amount1())) : 0;
        if (side == 1) {
            Currency q = s.fam[id].quote;
            Book storage b = s.books[book];
            uint256 lk = b.locked[q];
            b.locked[q] = lk > p.placed ? lk - p.placed : 0;
        }
        delete s.pos[id][book][side];
        if (s.pos[id][book][1 - side].liq == 0) _unlist(s, id, book);
    }

    /// @dev Put `amount` of one currency into a single-sided range [lo, hi).
    function _put(
        State storage s,
        address book,
        PoolKey memory key,
        bool holds0,
        uint8 side,
        int24 lo,
        int24 hi,
        uint256 amount
    ) private returns (uint256 used) {
        if (lo >= hi || amount <= 2) return 0;
        uint256 a = amount - 2; // PoolManager rounds the owed amount up
        uint160 sa = TickMath.getSqrtPriceAtTick(lo);
        uint160 sb = TickMath.getSqrtPriceAtTick(hi);
        uint128 liq = holds0
            ? LiquidityAmounts.getLiquidityForAmount0(sa, sb, a)
            : LiquidityAmounts.getLiquidityForAmount1(sa, sb, a);
        if (liq == 0) return 0;
        BalanceDelta d = _modify(s, book, key, lo, hi, int256(uint256(liq)), side);
        int128 owed = holds0 ? d.amount0() : d.amount1();
        used = owed < 0 ? uint256(uint128(-owed)) : 0;
        PoolId id = key.toId();
        s.pos[id][book][side] = Pos({lo: lo, hi: hi, liq: liq, placed: uint128(used)});
        if (side == 1) s.books[book].locked[s.fam[id].quote] += used;
        _list(s, id, book);
    }

    // ───────────────────────────── tick geometry ─────────────────────────────

    function _floor(int24 t, int24 sp) private pure returns (int24) {
        int24 c = t / sp;
        if (t < 0 && t % sp != 0) c--;
        return c * sp;
    }

    function _ceil(int24 t, int24 sp) private pure returns (int24) {
        int24 f = _floor(t, sp);
        return f == t ? t : f + sp;
    }

    function _clamp(int24 t, int24 sp) private pure returns (int24) {
        int24 lo = _ceil(TickMath.MIN_TICK, sp);
        int24 hi = _floor(TickMath.MAX_TICK, sp);
        return t < lo ? lo : (t > hi ? hi : t);
    }

    function _max(int24 a, int24 b) private pure returns (int24) {
        return a > b ? a : b;
    }

    function _min(int24 a, int24 b) private pure returns (int24) {
        return a < b ? a : b;
    }

    /// @dev Bounds for a single-sided range strictly above the current tick (holds token0)
    ///      or at/below it (holds token1). `edge` is the oriented reference the range must
    ///      not cross toward the taker.
    function _above(int24 poolTick, int24 edge, int24 w, int24 sp) private pure returns (int24 lo, int24 hi) {
        lo = _clamp(_ceil(_max(poolTick, edge) + 1, sp), sp);
        hi = _clamp(lo + w, sp);
    }

    function _below(int24 poolTick, int24 edge, int24 w, int24 sp) private pure returns (int24 lo, int24 hi) {
        hi = _clamp(_floor(_min(poolTick, edge), sp), sp);
        lo = _clamp(hi - w, sp);
    }

    // ───────────────────────────── rebalancing ─────────────────────────────

    struct PairPlan {
        Currency q;
        int24 live;
        int24 sPrev;
        uint256 sigma;
        bool ok;
    }

    /// @notice Re-lay one token of one book across its quotes and fee tiers.
    function rebalanceToken(State storage s, address book, address token) public returns (bool) {
        Book storage b = s.books[book];
        if (!_inBook(b, token)) return false;
        uint256 nq = b.quotes.length;
        PairPlan[] memory plan = new PairPlan[](nq);
        uint256 sumSig;
        for (uint256 j; j < nq; ++j) {
            PairPlan memory pp = plan[j];
            pp.q = b.quotes[j];
            (pp.live, pp.sPrev, pp.sigma, pp.ok) = _observe(s, token, pp.q);
            if (pp.ok) {
                int256 dev = int256(pp.live) - int256(pp.sPrev);
                if (dev < 0) dev = -dev;
                if (dev > int256(s.p.maxDev)) pp.ok = false;
            }
            if (pp.ok) sumSig += pp.sigma;
        }
        if (sumSig == 0) return false;

        // Bring the token's liquidity home on every pair we are about to re-lay.
        for (uint256 j; j < nq; ++j) {
            if (!plan[j].ok) continue;
            for (uint8 t; t < s.tiers.length; ++t) {
                (PoolKey memory key,) = familyKey(s, token, plan[j].q, t);
                _pull(s, book, key, 0);
                _pull(s, book, key, 1);
            }
        }

        uint256 tokenTotal = b.bal[Currency.wrap(token)];
        uint256 tokenUsed;
        uint256 quoteUsed;
        for (uint256 j; j < nq; ++j) {
            PairPlan memory pp = plan[j];
            if (!pp.ok) continue;
            uint256 xq = tokenTotal * pp.sigma / sumSig;
            uint256 qq = _quoteBudget(s, b, token, pp);
            (uint256 tu, uint256 qu) = _layPair(s, book, token, pp, xq, qq);
            tokenUsed += tu;
            quoteUsed += qu;
        }
        b.lastRebalance[token] = uint64(block.timestamp);
        emit Rebalanced(book, token, tokenUsed, quoteUsed);
        return true;
    }

    function _inBook(Book storage b, address token) private view returns (bool) {
        uint256 nt = b.tokens.length;
        for (uint256 i; i < nt; ++i) {
            if (b.tokens[i] == token) return true;
        }
        return false;
    }

    /// @dev This token's share of the book's quote q: proportional to its sigma on q among
    ///      the book's tokens (higher-vol tokens get more quote), out of free + locked.
    function _quoteBudget(State storage s, Book storage b, address token, PairPlan memory pp)
        private
        view
        returns (uint256)
    {
        uint256 total;
        uint256 nt = b.tokens.length;
        for (uint256 i; i < nt; ++i) {
            address t = b.tokens[i];
            total += t == token ? pp.sigma : sigmaOf(s, t, pp.q);
        }
        if (total == 0) return 0;
        uint256 target = (b.bal[pp.q] + b.locked[pp.q]) * pp.sigma / total;
        uint256 free = b.bal[pp.q];
        return target < free ? target : free;
    }

    /// @dev Split one pair's token and quote budget across the two fee tiers that bracket the
    ///      sigma-implied fee, ranges as wide as the pair's sigma calls for.
    function _layPair(
        State storage s,
        address book,
        address token,
        PairPlan memory pp,
        uint256 xq,
        uint256 qq
    ) private returns (uint256 tokenUsed, uint256 quoteUsed) {
        (uint8 kLo, uint8 kHi, uint256 wHi) = _tierBlend(s, pp.sigma);
        int256 w = int256(uint256(s.p.widthMult)) * int256(pp.sigma) / 100;
        if (w < s.p.minWidth) w = s.p.minWidth;
        if (w > s.p.maxWidth) w = s.p.maxWidth;
        int24 askRef = _max(pp.live, pp.sPrev);
        int24 bidRef = _min(pp.live, pp.sPrev);
        uint256 xHi = xq * wHi / 1e4;
        uint256 qHi = qq * wHi / 1e4;
        (uint256 a, uint256 c) = _layTier(s, book, token, pp, kLo, xq - xHi, qq - qHi, askRef, bidRef, int24(w));
        tokenUsed += a;
        quoteUsed += c;
        if (kHi != kLo && (xHi != 0 || qHi != 0)) {
            (a, c) = _layTier(s, book, token, pp, kHi, xHi, qHi, askRef, bidRef, int24(w));
            tokenUsed += a;
            quoteUsed += c;
        }
    }

    function _layTier(
        State storage s,
        address book,
        address token,
        PairPlan memory pp,
        uint8 tier,
        uint256 xAmt,
        uint256 qAmt,
        int24 askRef,
        int24 bidRef,
        int24 w
    ) private returns (uint256 tokenUsed, uint256 quoteUsed) {
        (PoolKey memory key, bool tokenIs0, int24 poolTick) = _ensurePool(s, token, pp.q, tier, pp.live);
        int24 sp = key.tickSpacing;
        int24 ws = _ceil(w, sp);
        if (tokenIs0) {
            // price = quote per token: asks above, bids below
            (int24 lo, int24 hi) = _above(poolTick, askRef, ws, sp);
            tokenUsed = _put(s, book, key, true, 0, lo, hi, xAmt);
            (lo, hi) = _below(poolTick, bidRef, ws, sp);
            quoteUsed = _put(s, book, key, false, 1, lo, hi, qAmt);
        } else {
            // price = token per quote: asks below (at <= -askRef), bids above (at >= -bidRef)
            (int24 lo, int24 hi) = _below(poolTick, -askRef, ws, sp);
            tokenUsed = _put(s, book, key, false, 0, lo, hi, xAmt);
            (lo, hi) = _above(poolTick, -bidRef, ws, sp);
            quoteUsed = _put(s, book, key, true, 1, lo, hi, qAmt);
        }
    }

    /// @dev Fee tiers are ascending. Returns the bracketing pair and the weight (1e4) on the upper.
    function _tierBlend(State storage s, uint256 sigma) private view returns (uint8 kLo, uint8 kHi, uint256 wHi) {
        uint256 f = sigma * s.p.feePerVol;
        uint256 n = s.tiers.length;
        if (f <= s.tiers[0].fee) return (0, 0, 0);
        if (f >= s.tiers[n - 1].fee) return (uint8(n - 1), uint8(n - 1), 0);
        for (uint256 k; k + 1 < n; ++k) {
            uint256 a = s.tiers[k].fee;
            uint256 c = s.tiers[k + 1].fee;
            if (f >= a && f < c) return (uint8(k), uint8(k + 1), (f - a) * 1e4 / (c - a));
        }
    }

    /// @notice Pull every position of one token in one book back to free balance.
    function unwind(State storage s, address book, address token) external {
        Book storage b = s.books[book];
        for (uint256 j; j < b.quotes.length; ++j) {
            for (uint8 t; t < s.tiers.length; ++t) {
                (PoolKey memory key,) = familyKey(s, token, b.quotes[j], t);
                _pull(s, book, key, 0);
                _pull(s, book, key, 1);
            }
        }
    }

    // ───────────────────────────── quote mix ─────────────────────────────

    /// @notice Move value between a book's quotes so each quote's share follows the summed
    ///         sigma of the book's tokens on it. One swap per call, through the quotes' ETH pools.
    function rebalanceQuotes(State storage s, address book) public returns (bool) {
        Book storage b = s.books[book];
        uint256 nq = b.quotes.length;
        if (nq < 2) return false;
        uint256[] memory val = new uint256[](nq); // in ETH wei
        uint256[] memory wt = new uint256[](nq);
        int24[] memory refT = new int24[](nq); // ETH per quote, conservative for selling it
        uint256 vTot;
        uint256 wTot;
        for (uint256 j; j < nq; ++j) {
            Currency q = b.quotes[j];
            if (!q.isAddressZero()) {
                (int24 live, int24 sPrev,, bool ok) = _observe(s, Currency.unwrap(q), ETH);
                if (!ok) return false;
                refT[j] = _min(live, sPrev);
            }
            val[j] = _toEth(b.bal[q] + b.locked[q], refT[j]);
            vTot += val[j];
            for (uint256 i; i < b.tokens.length; ++i) {
                wt[j] += sigmaOf(s, b.tokens[i], q);
            }
            wTot += wt[j];
        }
        if (vTot == 0 || wTot == 0) return false;
        uint256 over;
        uint256 under;
        uint256 overBy;
        uint256 underBy;
        for (uint256 j; j < nq; ++j) {
            uint256 target = vTot * wt[j] / wTot;
            if (val[j] > target && val[j] - target > overBy) (overBy, over) = (val[j] - target, j);
            if (target > val[j] && target - val[j] > underBy) (underBy, under) = (target - val[j], j);
        }
        uint256 move = overBy < underBy ? overBy : underBy;
        if (move * 1e4 < vTot * s.p.quoteDriftBps) return false;
        Currency qo = b.quotes[over];
        Currency qu = b.quotes[under];
        uint256 amtIn = _fromEth(move, refT[over]);
        if (amtIn > b.bal[qo]) amtIn = b.bal[qo];
        if (amtIn == 0) return false;
        uint256 got = qo.isAddressZero() ? amtIn : _swapVsEth(s, b, qo, amtIn, false);
        if (!qu.isAddressZero() && got != 0) _swapVsEth(s, b, qu, got, true);
        emit QuotesRebalanced(book, qo, qu, amtIn);
        return true;
    }

    function _toEth(uint256 amt, int24 ethPerQ) private pure returns (uint256) {
        if (ethPerQ == 0) return amt;
        uint256 sp = TickMath.getSqrtPriceAtTick(ethPerQ);
        return FullMath.mulDiv(FullMath.mulDiv(amt, sp, 1 << 96), sp, 1 << 96);
    }

    function _fromEth(uint256 eth, int24 ethPerQ) private pure returns (uint256) {
        if (ethPerQ == 0) return eth;
        uint256 sp = TickMath.getSqrtPriceAtTick(ethPerQ);
        return FullMath.mulDiv(FullMath.mulDiv(eth, 1 << 96, sp), 1 << 96, sp);
    }

    /// @dev Exact-in swap on a quote's ETH pool (ETH is currency0). buyQuote: ETH -> q.
    ///      The price limit keeps the fill within maxSlipBps of the better of live and smoothed.
    function _swapVsEth(State storage s, Book storage b, Currency q, uint256 amtIn, bool buyQuote)
        private
        returns (uint256 out)
    {
        PoolKey memory key = s.quotes[q].ethPool;
        (, int24 poolTick,,) = s.pm.getSlot0(key.toId());
        Obs storage o = s.obs[_obsKey(Currency.unwrap(q), ETH)];
        // pool tick = q per ETH = -(ETH per q)
        int24 a = -o.sPrev;
        int24 slip = int24(uint24(s.p.maxSlipBps));
        uint160 limit;
        if (buyQuote) {
            // ETH -> q is zeroForOne: price falls; stop below the better of pool and smoothed
            limit = TickMath.getSqrtPriceAtTick(_clamp(_max(poolTick, a) - slip, 1));
        } else {
            limit = TickMath.getSqrtPriceAtTick(_clamp(_min(poolTick, a) + slip, 1));
        }
        BalanceDelta d = s.pm.swap(
            key,
            IPoolManager.SwapParams({zeroForOne: buyQuote, amountSpecified: -int256(amtIn), sqrtPriceLimitX96: limit}),
            ""
        );
        _settle(s, b, key.currency0, d.amount0());
        _settle(s, b, key.currency1, d.amount1());
        int128 o1 = buyQuote ? d.amount1() : d.amount0();
        out = o1 > 0 ? uint256(uint128(o1)) : 0;
    }

    // ───────────────────────────── in-swap steps ─────────────────────────────

    /// @notice Before a swap: move books' single-sided ranges in this pool that sit on the
    ///         taker's side of the reference back behind it. Bounded by shieldMax per swap.
    function shield(State storage s, PoolKey memory key) external {
        PoolId id = key.toId();
        Family memory f = s.fam[id];
        if (!f.known) return;
        address[] storage list = s.poolBooks[id];
        uint256 n = list.length;
        if (n == 0) return;
        (int24 live, int24 sPrev,, bool ok) = _observe(s, f.token, f.quote);
        if (!ok) return;
        uint256 m = n < s.p.shieldMax ? n : s.p.shieldMax;
        address[] memory pick = new address[](m);
        uint256 start = s.shieldCursor % n;
        for (uint256 i; i < m; ++i) {
            pick[i] = list[(start + i) % n];
        }
        s.shieldCursor = start + m;
        // oriented edges: asks must sit at token prices >= askRef, bids at <= bidRef
        int24 askE = f.tokenIs0 ? _max(live, sPrev) : -_max(live, sPrev);
        int24 bidE = f.tokenIs0 ? _min(live, sPrev) : -_min(live, sPrev);
        for (uint256 i; i < m; ++i) {
            _shieldBook(s, key, id, f.tokenIs0, pick[i], askE, bidE);
        }
    }

    function _shieldBook(
        State storage s,
        PoolKey memory key,
        PoolId id,
        bool tokenIs0,
        address book,
        int24 askE,
        int24 bidE
    ) private {
        (, int24 poolTick,,) = s.pm.getSlot0(id);
        int24 sp = key.tickSpacing;
        for (uint8 side; side < 2; ++side) {
            Pos memory p = s.pos[id][book][side];
            if (p.liq == 0) continue;
            bool holds0 = side == 0 ? tokenIs0 : !tokenIs0;
            // only untouched single-sided ranges move
            if (holds0 ? poolTick >= p.lo : poolTick < p.hi) continue;
            int24 edge = side == 0 ? askE : bidE;
            int24 w = p.hi - p.lo;
            int24 lo;
            int24 hi;
            if (holds0) {
                if (p.lo > _max(poolTick, edge) + sp) continue; // already behind the edge
                (lo, hi) = _above(poolTick, edge, w, sp);
                if (lo <= p.lo) continue;
            } else {
                if (p.hi < _min(poolTick, edge) - sp) continue;
                (lo, hi) = _below(poolTick, edge, w, sp);
                if (hi >= p.hi) continue;
            }
            (uint256 g0, uint256 g1) = _pull(s, book, key, side);
            _put(s, book, key, holds0, side, lo, hi, holds0 ? g0 : g1);
            emit Shielded(book, id, side, lo, hi);
        }
    }

    /// @notice One bounded unit of orchestration, run after a swap: the next due (book, token)
    ///         re-lays if its interval has passed; a token of 0 means the book's quote mix.
    function autoStep(State storage s) external {
        uint256 n = s.due.length;
        if (n == 0) return;
        uint256 c = s.dueCursor % n;
        s.dueCursor = c + 1;
        Due memory d = s.due[c];
        Book storage b = s.books[d.book];
        if (!b.exists) return;
        if (block.timestamp < uint256(b.lastRebalance[d.token]) + s.p.interval) return;
        if (d.token == address(0)) {
            b.lastRebalance[address(0)] = uint64(block.timestamp);
            rebalanceQuotes(s, d.book);
        } else {
            rebalanceToken(s, d.book, d.token);
        }
    }
}
