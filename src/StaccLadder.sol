// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {Position} from "v4-core/libraries/Position.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary, toBalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/types/BeforeSwapDelta.sol";
import {LadderLogic} from "./LadderLogic.sol";
import {LadderRefs, IPonsCurve} from "./LadderRefs.sol";
import {LadderRouter} from "./LadderRouter.sol";
import {
    State, Tier, QuoteCfg, TokenRef, Pos, Family, Book, Due, Params, RatchetCfg, BurnCfg, REF_PONS, REF_V4
} from "./LadderTypes.sol";

interface IERC20Min {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

interface IPonsFactory {
    function memeHook() external view returns (address);
}

/// @title StaccLadder: a quote-agnostic fee-tier ladder hook with the EIP-8429 fee ratchet.
/// @notice Every token with a reference (a Pons curve before graduation, Pons's Uniswap pool
///         after) gets a family of pools: one per (quote, fee tier), all on this hook. Anyone
///         can open pools on the hook and anyone can LP them directly. Depositors can also
///         hand the hook a book instead: their quotes and tokens, keyed to them, which the
///         hook lays across the family as single-sided ranges, sharing each quote among the
///         book's tokens by volatility, choosing fee tiers by volatility (higher vol, higher
///         tier) and range width by each pair's own volatility.
///
///         The fee ratchet (EIP-8429, token-level form) applies to every swap and every LP
///         add or remove on the hook's pools: the k-th reference to a token in a block, across
///         all senders and transactions, pays 10 bp * k^2 of the amount, capped at 100%, the
///         first one free. A remove in the block its position was added counts once more.
///         The toll is taken in kind and held for the beneficiary (sinkBps of it to 0xdead).
///
///         ALPHA. Unaudited. Funds can be lost.
contract StaccLadder is IHooks, IUnlockCallback {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    error NotPoolManager();
    error NotOwner();
    error NotSelf();
    error NotBookOwner();
    error BadQuote();
    error BadRef();
    error BadAmount();
    error BadParams();
    error HookNotImplemented();
    error NeedGasForShield(uint256 gas);

    event Reference(PoolId indexed id, address indexed token, uint8 kind, uint256 k, uint256 toll0, uint256 toll1);
    event Deposit(address indexed book, Currency indexed currency, uint256 amount);
    event Withdraw(address indexed book, Currency indexed currency, uint256 amount, address to);
    event BookSet(address indexed book, address[] tokens, Currency[] quotes, address operator);
    event RefSet(address indexed token, uint8 kind, address curve, PoolId pool);
    event QuoteListed(Currency indexed quote, PoolId ethPool);
    event TollSwept(Currency indexed currency, uint256 toBeneficiary, uint256 toSink);

    uint256 public constant ONE_PIPS = 1_000_000;
    address public constant SINK = 0x000000000000000000000000000000000000dEaD;

    uint8 private constant KIND_SWAP = 0;
    uint8 private constant KIND_ADD = 1;
    uint8 private constant KIND_REMOVE = 2;

    uint8 private constant OP_DEPOSIT = 1;
    uint8 private constant OP_WITHDRAW = 2;
    uint8 private constant OP_TOKEN = 3;
    uint8 private constant OP_QUOTES = 4;
    uint8 private constant OP_UNWIND = 5;
    uint8 private constant OP_SWEEP = 6;
    uint8 private constant OP_BURN = 7;

    State internal s;

    constructor(
        IPoolManager pm,
        address owner_,
        address beneficiary_,
        uint16 sinkBps_,
        Tier[] memory tiers_,
        Params memory p_,
        RatchetCfg memory rc_,
        BurnCfg memory burn_
    ) {
        Hooks.validateHookPermissions(IHooks(address(this)), getHookPermissions());
        if (sinkBps_ > 10_000 || tiers_.length == 0) revert BadParams();
        s.pm = pm;
        s.owner = owner_;
        s.beneficiary = beneficiary_;
        s.sinkBps = sinkBps_;
        for (uint256 i; i < tiers_.length; ++i) {
            if (i > 0 && tiers_[i].fee <= tiers_[i - 1].fee) revert BadParams();
            s.tiers.push(tiers_[i]);
        }
        _setParams(p_);
        _setRatchet(rc_);
        _setBurn(burn_);
    }

    function getHookPermissions() public pure returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: true,
            beforeAddLiquidity: false,
            afterAddLiquidity: true,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: true,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: true,
            afterRemoveLiquidityReturnDelta: true
        });
    }

    modifier onlyPM() {
        if (msg.sender != address(s.pm)) revert NotPoolManager();
        _;
    }

    modifier onlyOwner() {
        if (msg.sender != s.owner) revert NotOwner();
        _;
    }

    modifier onlySelf() {
        if (msg.sender != address(this)) revert NotSelf();
        _;
    }

    // ───────────────────────────── admin ─────────────────────────────

    /// @notice List a quote priced by a live v4 pool against native ETH. Anyone may list a new
    ///         quote; once listed, only the owner can re-point its pricing pool.
    function listQuote(Currency q, PoolKey calldata ethPool) external {
        if (q.isAddressZero() || !ethPool.currency0.isAddressZero() || !(ethPool.currency1 == q)) revert BadQuote();
        if (s.quotes[q].listed && msg.sender != s.owner) revert NotOwner();
        if (s.pm.getLiquidity(ethPool.toId()) == 0) revert BadQuote();
        if (s.refs[Currency.unwrap(q)].kind != 0) revert BadQuote();
        if (!s.quotes[q].listed) s.quoteList.push(q);
        s.quotes[q] = QuoteCfg({listed: true, ethPool: ethPool});
        emit QuoteListed(q, ethPool.toId());
    }

    function setPonsFactory(address factory, bool ok) external onlyOwner {
        s.ponsFactory[factory] = ok;
    }

    /// @notice Reference for a token that is not a Pons launch: a v4 pool against ETH or a quote.
    function setRef(address token, PoolKey calldata pool) external onlyOwner {
        _setV4Ref(token, pool);
    }

    function setParams(Params calldata p_) external onlyOwner {
        _setParams(p_);
    }

    function setBeneficiary(address b, uint16 sinkBps_) external onlyOwner {
        if (sinkBps_ > 10_000) revert BadParams();
        s.beneficiary = b;
        s.sinkBps = sinkBps_;
    }

    function transferOwnership(address o) external onlyOwner {
        s.owner = o;
    }

    /// @notice The fee ratchet's constants: floorPips * k^2 for the k-th reference, kFree free.
    function setRatchet(RatchetCfg calldata rc_) external onlyOwner {
        _setRatchet(rc_);
    }

    /// @notice The fee token (toll is converted to it and burned; every family also gets pools
    ///         against it), the share of each toll burned, and the minimum burn size in ETH.
    function setBurn(BurnCfg calldata b_) external onlyOwner {
        _setBurn(b_);
    }

    /// @notice Replace the fee tiers (ascending fees). Books track their own pools, so positions
    ///         in a dropped tier stay reachable by unwind and rebalance.
    function setTiers(Tier[] calldata tiers_) external onlyOwner {
        if (tiers_.length == 0) revert BadParams();
        delete s.tiers;
        for (uint256 i; i < tiers_.length; ++i) {
            if (i > 0 && tiers_[i].fee <= tiers_[i - 1].fee) revert BadParams();
            s.tiers.push(tiers_[i]);
        }
    }

    function delistQuote(Currency q) external onlyOwner {
        if (!s.quotes[q].listed) return;
        delete s.quotes[q];
        uint256 n = s.quoteList.length;
        for (uint256 i; i < n; ++i) {
            if (s.quoteList[i] == q) {
                s.quoteList[i] = s.quoteList[n - 1];
                s.quoteList.pop();
                break;
            }
        }
    }

    /// @notice Point a token at a Pons curve directly (no factory allowlist check).
    function setPonsRef(address token, address curve) external onlyOwner {
        PoolKey memory none;
        s.refs[token] = TokenRef({kind: REF_PONS, curve: curve, pool: none});
        emit RefSet(token, REF_PONS, curve, none.toId());
    }

    function clearRef(address token) external onlyOwner {
        delete s.refs[token];
    }

    function _setRatchet(RatchetCfg memory rc_) private {
        if (rc_.capPips > ONE_PIPS) revert BadParams();
        s.rc = rc_;
    }

    function _setBurn(BurnCfg memory b_) private {
        if (b_.burnBps > 10_000) revert BadParams();
        s.burn = b_;
    }

    function _setParams(Params memory p_) private {
        if (
            p_.tau == 0 || p_.horizon == 0 || p_.minWidth <= 0 || p_.maxWidth < p_.minWidth || p_.maxDev <= 0
                || p_.minVol <= 0 || p_.initVol <= 0 || p_.maxSlipBps == 0 || p_.maxSlipBps > 5_000
        ) revert BadParams();
        s.p = p_;
    }

    function _setV4Ref(address token, PoolKey memory pool) private {
        bool tokenIs0 = Currency.unwrap(pool.currency0) == token;
        if (!tokenIs0 && Currency.unwrap(pool.currency1) != token) revert BadRef();
        Currency other = tokenIs0 ? pool.currency1 : pool.currency0;
        if (!other.isAddressZero() && !s.quotes[other].listed) revert BadRef();
        (uint160 sp,,,) = s.pm.getSlot0(pool.toId());
        if (sp == 0) revert BadRef();
        s.refs[token] = TokenRef({kind: REF_V4, curve: s.refs[token].curve, pool: pool});
        emit RefSet(token, REF_V4, s.refs[token].curve, pool.toId());
    }

    // ───────────────────────────── references (permissionless) ─────────────────────────────

    /// @notice Use a Pons curve from an allowed factory as its token's reference until graduation.
    function listPons(address curve) external {
        IPonsCurve c = IPonsCurve(curve);
        address token = c.token();
        if (!s.ponsFactory[c.factory()]) revert BadRef();
        if (s.quotes[Currency.wrap(token)].listed) revert BadRef();
        address pair = c.pairToken();
        if (pair != address(0) && !s.quotes[Currency.wrap(pair)].listed) revert BadRef();
        if (s.refs[token].kind == REF_V4) revert BadRef();
        PoolKey memory none;
        s.refs[token] = TokenRef({kind: REF_PONS, curve: curve, pool: none});
        emit RefSet(token, REF_PONS, curve, none.toId());
    }

    /// @notice After graduation, switch the token's reference to the Uniswap pool Pons seeded.
    function graduate(address token, PoolKey calldata pool) external {
        TokenRef storage r = s.refs[token];
        if (r.kind != REF_PONS) revert BadRef();
        IPonsCurve c = IPonsCurve(r.curve);
        if (!c.graduated()) revert BadRef();
        if (address(pool.hooks) != IPonsFactory(c.factory()).memeHook()) revert BadRef();
        if (Currency.unwrap(pool.currency0) != c.pairToken() || Currency.unwrap(pool.currency1) != token) {
            if (Currency.unwrap(pool.currency1) != c.pairToken() || Currency.unwrap(pool.currency0) != token) {
                revert BadRef();
            }
        }
        if (s.pm.getLiquidity(pool.toId()) == 0) revert BadRef();
        _setV4Ref(token, pool);
    }

    function openFamily(address token) external {
        LadderLogic.openFamily(s, token);
    }

    function openPair(address token, Currency q) external {
        LadderLogic.openPair(s, token, q);
    }

    function register(PoolKey calldata key) external returns (bool) {
        return LadderLogic.register(s, key);
    }

    // ───────────────────────────── books ─────────────────────────────

    /// @notice Set the tokens and quotes the caller's book runs, and an optional operator.
    function setBook(address[] calldata tokens, Currency[] calldata quotes, address operator) external {
        Book storage b = s.books[msg.sender];
        for (uint256 i; i < tokens.length; ++i) {
            if (s.refs[tokens[i]].kind == 0) revert BadRef();
        }
        for (uint256 j; j < quotes.length; ++j) {
            Currency q = quotes[j];
            if (!q.isAddressZero() && !s.quotes[q].listed && Currency.unwrap(q) != s.burn.token) revert BadQuote();
        }
        b.tokens = tokens;
        b.quotes = quotes;
        b.operator = operator;
        b.exists = true;
        for (uint256 i; i <= tokens.length; ++i) {
            address t = i == tokens.length ? address(0) : tokens[i];
            bytes32 k = keccak256(abi.encode(msg.sender, t));
            if (!s.isDue[k]) {
                s.isDue[k] = true;
                s.due.push(Due({book: msg.sender, token: t}));
            }
        }
        emit BookSet(msg.sender, tokens, quotes, operator);
    }

    function deposit(Currency c, uint256 amount) external payable {
        if (amount == 0) revert BadAmount();
        if (c.isAddressZero()) {
            if (msg.value != amount) revert BadAmount();
        } else {
            if (msg.value != 0) revert BadAmount();
            IERC20Min(Currency.unwrap(c)).transferFrom(msg.sender, address(this), amount);
        }
        s.pm.unlock(abi.encode(OP_DEPOSIT, msg.sender, c, amount, address(0)));
    }

    /// @notice Withdraw free balance from a book. The owner sends anywhere; an operator only to the owner.
    function withdraw(address book, Currency c, uint256 amount, address to) external {
        _authBook(book);
        if (msg.sender != book) to = book;
        s.pm.unlock(abi.encode(OP_WITHDRAW, book, c, amount, to));
    }

    /// @notice Pull a token's positions in a book back to free balance (book owner or operator).
    function unwind(address book, address token) external {
        _authBook(book);
        s.pm.unlock(abi.encode(OP_UNWIND, book, Currency.wrap(token), 0, address(0)));
    }

    /// @notice Re-lay one token of a book now. Anyone may call; placement never moves toward a taker.
    function rebalance(address book, address token) external {
        s.pm.unlock(abi.encode(OP_TOKEN, book, Currency.wrap(token), 0, address(0)));
    }

    /// @notice Rebalance a book's quote mix (one swap). Anyone may call.
    function rebalanceQuotes(address book) external {
        s.pm.unlock(abi.encode(OP_QUOTES, book, Currency.wrap(address(0)), 0, address(0)));
    }

    /// @notice Pay a currency's beneficiary share of toll out (sinkBps of it to 0xdead).
    function sweepToll(Currency c) external {
        s.pm.unlock(abi.encode(OP_SWEEP, address(0), c, 0, address(0)));
    }

    /// @notice Convert a currency's pending burn share of toll into the fee token and burn it.
    function burnToll(Currency c) external {
        s.pm.unlock(abi.encode(OP_BURN, address(0), c, 0, address(0)));
    }

    function _authBook(address book) private view {
        if (msg.sender != book && msg.sender != s.books[book].operator) revert NotBookOwner();
    }

    function unlockCallback(bytes calldata data) external onlyPM returns (bytes memory) {
        (uint8 op, address bk, Currency c, uint256 amount, address to) =
            abi.decode(data, (uint8, address, Currency, uint256, address));
        if (op == OP_DEPOSIT) {
            if (c.isAddressZero()) {
                s.pm.settle{value: amount}();
            } else {
                s.pm.sync(c);
                IERC20Min(Currency.unwrap(c)).transfer(address(s.pm), amount);
                s.pm.settle();
            }
            s.pm.mint(address(this), c.toId(), amount);
            Book storage b = s.books[bk];
            b.bal[c] += amount;
            if (_isBookQuote(c)) b.quoteTotal[c] += int256(amount);
            emit Deposit(bk, c, amount);
        } else if (op == OP_WITHDRAW) {
            Book storage b = s.books[bk];
            b.bal[c] -= amount;
            if (_isBookQuote(c)) b.quoteTotal[c] -= int256(amount);
            s.pm.burn(address(this), c.toId(), amount);
            s.pm.take(c, to, amount);
            emit Withdraw(bk, c, amount, to);
        } else if (op == OP_TOKEN) {
            LadderLogic.rebalanceToken(s, bk, Currency.unwrap(c));
        } else if (op == OP_QUOTES) {
            LadderLogic.rebalanceQuotes(s, bk);
        } else if (op == OP_UNWIND) {
            LadderLogic.unwind(s, bk, Currency.unwrap(c));
        } else if (op == OP_BURN) {
            LadderRouter.burnStep(s, c);
        } else if (op == OP_SWEEP) {
            uint256 t = s.toll[c];
            s.toll[c] = 0;
            uint256 sink = t * s.sinkBps / 10_000;
            s.pm.burn(address(this), c.toId(), t);
            if (sink != 0) s.pm.take(c, SINK, sink);
            if (t > sink) s.pm.take(c, s.beneficiary, t - sink);
            emit TollSwept(c, t - sink, sink);
        }
        return "";
    }

    function _isQuote(Currency c) private view returns (bool) {
        return c.isAddressZero() || s.quotes[c].listed;
    }

    function _isBookQuote(Currency c) private view returns (bool) {
        return _isQuote(c) || (s.burn.token != address(0) && Currency.unwrap(c) == s.burn.token);
    }

    // ───────────────────────────── the ratchet ─────────────────────────────

    /// @notice Toll rate for the k-th reference to a token in a block.
    function ratchetPips(uint256 k) public view returns (uint256) {
        RatchetCfg memory rc = s.rc;
        if (k <= rc.kFree) return 0;
        uint256 r = uint256(rc.floorPips) * k * k;
        return r > rc.capPips ? rc.capPips : r;
    }

    /// @notice References to `token` so far in this block.
    function referencesThisBlock(address token) external view returns (uint256) {
        uint256 v = s.ratchet[token];
        return (v >> 64) == block.number ? uint64(v) : 0;
    }

    function _bump(address token) private returns (uint256 k) {
        uint256 v = s.ratchet[token];
        k = (v >> 64) == block.number ? uint256(uint64(v)) + 1 : 1;
        s.ratchet[token] = (block.number << 64) | k;
    }

    /// @dev Count a reference to every non-quote currency of the pool; the busier one sets k.
    function _reference(PoolKey calldata key) private returns (uint256 k, address token) {
        if (!_isQuote(key.currency0)) {
            k = _bump(Currency.unwrap(key.currency0));
            token = Currency.unwrap(key.currency0);
        }
        if (!_isQuote(key.currency1)) {
            uint256 k1 = _bump(Currency.unwrap(key.currency1));
            if (k1 > k) (k, token) = (k1, Currency.unwrap(key.currency1));
        }
    }

    function _take(Currency c, uint256 amt) private {
        if (amt == 0) return;
        s.pm.mint(address(this), c.toId(), amt);
        uint256 toBurn = s.burn.token == address(0) ? 0 : amt * s.burn.burnBps / 10_000;
        s.burnable[c] += toBurn;
        s.toll[c] += amt - toBurn;
        if (!s.isTollCurrency[c]) {
            s.isTollCurrency[c] = true;
            s.tollCurrencies.push(c);
        }
    }

    function _abs(int128 a) private pure returns (uint256) {
        return a < 0 ? uint256(uint128(-a)) : uint256(uint128(a));
    }

    // ───────────────────────────── hook callbacks ─────────────────────────────

    function beforeInitialize(address, PoolKey calldata, uint160) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    function afterInitialize(address, PoolKey calldata key, uint160, int24) external onlyPM returns (bytes4) {
        LadderLogic.onInitialize(s, key);
        return IHooks.afterInitialize.selector;
    }

    function beforeAddLiquidity(address, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    function afterAddLiquidity(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        BalanceDelta delta,
        BalanceDelta fees,
        bytes calldata
    ) external onlyPM returns (bytes4, BalanceDelta) {
        PoolId id = key.toId();
        s.addedAt[id][Position.calculatePositionKey(sender, params.tickLower, params.tickUpper, params.salt)] =
            block.number;
        return (IHooks.afterAddLiquidity.selector, _lpToll(key, id, delta, fees, 0, KIND_ADD));
    }

    function beforeRemoveLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    function afterRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        BalanceDelta delta,
        BalanceDelta fees,
        bytes calldata
    ) external onlyPM returns (bytes4, BalanceDelta) {
        if (params.liquidityDelta == 0) return (IHooks.afterRemoveLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
        PoolId id = key.toId();
        uint256 extra =
            s.addedAt[id][Position.calculatePositionKey(sender, params.tickLower, params.tickUpper, params.salt)]
                == block.number ? 1 : 0;
        return (IHooks.afterRemoveLiquidity.selector, _lpToll(key, id, delta, fees, extra, KIND_REMOVE));
    }

    function _lpToll(PoolKey calldata key, PoolId id, BalanceDelta delta, BalanceDelta fees, uint256 extra, uint8 kind)
        private
        returns (BalanceDelta)
    {
        (uint256 k, address token) = _reference(key);
        if (k == 0) return BalanceDeltaLibrary.ZERO_DELTA;
        k += extra;
        uint256 r = ratchetPips(k);
        BalanceDelta principal = delta - fees;
        uint256 t0 = _abs(principal.amount0()) * r / ONE_PIPS;
        uint256 t1 = _abs(principal.amount1()) * r / ONE_PIPS;
        _take(key.currency0, t0);
        _take(key.currency1, t1);
        emit Reference(id, token, kind, k, t0, t1);
        return toBalanceDelta(int128(int256(t0)), int128(int256(t1)));
    }

    function beforeSwap(address, PoolKey calldata key, IPoolManager.SwapParams calldata, bytes calldata)
        external
        onlyPM
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        if (s.fam[key.toId()].known && s.poolBooks[key.toId()].length != 0) {
            uint256 g = s.p.stepGas;
            if (gasleft() < g + 150_000) revert NeedGasForShield(g + 150_000);
            (bool ok,) = address(this).call{gas: g}(abi.encodeCall(this.stepShield, (key)));
            ok;
        }
        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    function afterSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) external onlyPM returns (bytes4, int128) {
        (uint256 k, address token) = _reference(key);
        uint256 t;
        if (k != 0) {
            bool specifiedIs0 = (params.amountSpecified < 0) == params.zeroForOne;
            int128 unspecified = specifiedIs0 ? delta.amount1() : delta.amount0();
            t = _abs(unspecified) * ratchetPips(k) / ONE_PIPS;
            Currency c = specifiedIs0 ? key.currency1 : key.currency0;
            _take(c, t);
            emit Reference(key.toId(), token, KIND_SWAP, k, specifiedIs0 ? 0 : t, specifiedIs0 ? t : 0);
        }
        if (s.due.length != 0) _step(abi.encodeCall(this.stepAuto, ()));
        if (s.tollCurrencies.length != 0) _step(abi.encodeCall(this.stepBurn, ()));
        return (IHooks.afterSwap.selector, int128(int256(t)));
    }

    /// @dev Run an orchestration step in its own frame with a fixed gas budget. A failing or
    ///      starved step is skipped; it never takes the swap down with it.
    function _step(bytes memory call) private {
        uint256 g = s.p.stepGas;
        if (g == 0 || gasleft() < g + 150_000) return;
        (bool ok,) = address(this).call{gas: g}(call);
        ok;
    }

    function stepShield(PoolKey calldata key) external onlySelf {
        LadderLogic.shield(s, key);
    }

    function stepAuto() external onlySelf {
        LadderLogic.autoStep(s);
    }

    function stepBurn() external onlySelf {
        LadderRouter.nextBurn(s);
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    // ───────────────────────────── views ─────────────────────────────

    function owner() external view returns (address) {
        return s.owner;
    }

    function beneficiary() external view returns (address, uint16) {
        return (s.beneficiary, s.sinkBps);
    }

    function poolManager() external view returns (IPoolManager) {
        return s.pm;
    }

    function getParams() external view returns (Params memory) {
        return s.p;
    }

    function tiers() external view returns (Tier[] memory) {
        return s.tiers;
    }

    function quotes() external view returns (Currency[] memory) {
        return s.quoteList;
    }

    function ref(address token) external view returns (TokenRef memory) {
        return s.refs[token];
    }

    function pairTick(address token, Currency q) external view returns (int24, bool) {
        return LadderRefs.pairTick(s, token, q);
    }

    function sigma(address token, Currency q) external view returns (uint256) {
        return LadderRefs.sigmaOf(s, token, q);
    }

    function ratchetCfg() external view returns (RatchetCfg memory) {
        return s.rc;
    }

    function burnCfg() external view returns (BurnCfg memory) {
        return s.burn;
    }

    function burnableOf(Currency c) external view returns (uint256) {
        return s.burnable[c];
    }

    function bookPools(address who) external view returns (PoolId[] memory) {
        return s.books[who].pools;
    }

    function familyKey(address token, Currency q, uint8 tier) external view returns (PoolKey memory key, bool tokenIs0) {
        return LadderLogic.familyKey(s, token, q, tier);
    }

    function family(PoolId id) external view returns (Family memory) {
        return s.fam[id];
    }

    function getBook(address who)
        external
        view
        returns (address[] memory tokens, Currency[] memory quotes_, address operator, bool exists)
    {
        Book storage b = s.books[who];
        return (b.tokens, b.quotes, b.operator, b.exists);
    }

    function balanceOf(address who, Currency c) external view returns (uint256 free, uint256 locked, int256 quoteTotal) {
        Book storage b = s.books[who];
        return (b.bal[c], b.locked[c], b.quoteTotal[c]);
    }

    function position(PoolId id, address who, uint8 side) external view returns (Pos memory) {
        return s.pos[id][who][side];
    }

    function poolBooks(PoolId id) external view returns (address[] memory) {
        return s.poolBooks[id];
    }

    function tollOf(Currency c) external view returns (uint256) {
        return s.toll[c];
    }

    function dueLength() external view returns (uint256) {
        return s.due.length;
    }

    receive() external payable {}
}
