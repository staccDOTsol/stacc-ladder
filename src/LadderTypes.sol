// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";

/// @notice One fee tier of a token's pool family.
struct Tier {
    uint24 fee;
    int24 spacing;
}

/// @notice A quote asset and the v4 pool that prices it in native ETH (unused for ETH).
struct QuoteCfg {
    bool listed;
    PoolKey ethPool;
}

/// @notice Where a non-quote token's price comes from.
///         PONS: the Pons bonding curve, until it graduates.
///         V4: a v4 pool against ETH or a listed quote (Pons's graduated pool after the switch).
struct TokenRef {
    uint8 kind;
    address curve;
    PoolKey pool;
}

uint8 constant REF_NONE = 0;
uint8 constant REF_PONS = 1;
uint8 constant REF_V4 = 2;

/// @notice Price and volatility memory for one (token, quote) pair, in ticks of "quote per token".
///         Updated at most once per block. `sPrev` is the smoothed tick as it stood before the
///         current block's observation, so nothing done inside this block can move it.
struct Obs {
    uint64 blk;
    uint64 time;
    int24 last;
    int24 sPrev;
    int24 sCur;
    uint128 varRate; // ticks^2 per second, scaled by 1e6
}

/// @notice One of a book's positions in one pool. side 0 = ask (token only), 1 = bid (quote only).
struct Pos {
    int24 lo;
    int24 hi;
    uint128 liq;
    uint128 placed; // quote placed (bids) or token placed (asks), at placement
}

/// @notice A registered pool of a token's family.
struct Family {
    bool known;
    bool tokenIs0;
    uint8 tier;
    address token;
    Currency quote;
}

/// @notice A depositor's book. Balances are ERC-6909 claims the hook holds in the PoolManager.
struct Book {
    address[] tokens;
    Currency[] quotes;
    mapping(Currency => uint256) bal;
    mapping(Currency => uint256) locked;
    mapping(Currency => int256) quoteTotal;
    mapping(address => uint64) lastRebalance;
    address operator;
    bool exists;
    PoolId[] pools; // every pool this book holds a position in
    mapping(PoolId => uint256) poolIdx; // 1-based
}

struct Due {
    address book;
    address token;
}

struct Params {
    uint32 tau; // smoothing time constant, seconds
    uint32 horizon; // volatility horizon, seconds
    uint32 feePerVol; // target fee pips per tick of horizon sigma
    uint32 widthMult; // range width = widthMult/100 * sigma
    int24 minWidth;
    int24 maxWidth;
    int24 maxDev; // refuse to place when live and smoothed disagree by more
    int24 minVol; // sigma floor, ticks
    int24 initVol; // sigma before any history, ticks
    uint32 interval; // auto-rebalance a (book, token) no more often than this
    uint16 quoteDriftBps; // swap between quotes when a quote is this far off target
    uint16 maxSlipBps; // max price move of a quote-rebalance swap
    uint8 shieldMax; // books the shield may move per swap
    uint32 stepGas; // gas handed to each in-swap step
    int24 tipTicks; // shield: ranges may sit (pool fee + tipTicks) toward the taker of the reference
    int24 offsetTicks; // re-lay: edge distance from the reference, away from the taker (negative = toward)
}

/// @notice The EIP-8429 fee ratchet: the k-th reference to a token in a block pays
///         floorPips * k^2 (capped at capPips), the first kFree references free.
struct RatchetCfg {
    uint32 floorPips;
    uint8 kFree;
    uint32 capPips;
}

/// @notice The hook's fee token: toll is converted to it and burned (burnBps of each toll),
///         and every token family also gets pools against it.
struct BurnCfg {
    address token;
    uint16 burnBps;
    uint128 minBurnWei; // burn a currency's pending toll only once it is worth this much ETH
}

struct State {
    IPoolManager pm;
    address owner;
    address beneficiary;
    uint16 sinkBps;
    Params p;
    Tier[] tiers;
    Currency[] quoteList;
    mapping(Currency => QuoteCfg) quotes;
    mapping(address => bool) ponsFactory;
    mapping(address => TokenRef) refs;
    mapping(bytes32 => Obs) obs;
    mapping(address => Book) books;
    mapping(PoolId => Family) fam;
    mapping(PoolId => mapping(address => Pos[2])) pos;
    mapping(PoolId => address[]) poolBooks;
    mapping(PoolId => mapping(address => uint256)) poolBookIdx; // 1-based
    mapping(PoolId => mapping(bytes32 => uint256)) addedAt;
    mapping(Currency => uint256) toll;
    mapping(address => uint256) ratchet; // token => (block << 64) | count
    Due[] due; // (book, token) pairs for the in-swap step; token 0 = the book's quote mix
    mapping(bytes32 => bool) isDue;
    uint256 dueCursor;
    uint256 shieldCursor;
    RatchetCfg rc;
    BurnCfg burn;
    mapping(PoolId => PoolKey) keyOf;
    mapping(Currency => uint256) burnable;
    Currency[] tollCurrencies;
    mapping(Currency => bool) isTollCurrency;
    uint256 burnCursor;
}
