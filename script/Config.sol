// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {Tier, Params} from "../src/LadderTypes.sol";

/// @notice Robinhood Chain (4663) addresses and the launch configuration.
library Config {
    IPoolManager internal constant PM = IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951);
    address internal constant CREATE2 = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    address internal constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address internal constant PONS_FACTORY = 0x7eD598BcEf8bd9Edd8C97A195C6d13f40801EC7e;
    address internal constant ZERO = 0x4cbCc4Eb02D7908B86627FBE434D09A506EC3522;
    address internal constant ZERO_CURVE = 0x5C8610B3225Dc9fe9671B549E3a88a01961C9b3D;

    /// @notice afterInitialize, afterAdd(+delta), afterRemove(+delta), beforeSwap, afterSwap(+delta).
    uint160 internal constant FLAGS = Hooks.AFTER_INITIALIZE_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG
        | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
        | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_ADD_LIQUIDITY_RETURNS_DELTA_FLAG
        | Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG;

    /// @notice The deepest hookless ETH/USDG pool on the canonical PoolManager (fee 460, spacing 9).
    function usdgEthPool() internal pure returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(USDG),
            fee: 460,
            tickSpacing: 9,
            hooks: IHooks(address(0))
        });
    }

    function tiers() internal pure returns (Tier[] memory t) {
        t = new Tier[](4);
        t[0] = Tier({fee: 3_000, spacing: 60});
        t[1] = Tier({fee: 10_000, spacing: 100});
        t[2] = Tier({fee: 30_000, spacing: 200});
        t[3] = Tier({fee: 100_000, spacing: 200});
    }

    function params() internal pure returns (Params memory) {
        return Params({
            tau: 600,
            horizon: 3600,
            feePerVol: 20,
            widthMult: 300,
            minWidth: 600,
            maxWidth: 60_000,
            maxDev: 2_000,
            minVol: 50,
            initVol: 1_000,
            interval: 900,
            quoteDriftBps: 1_000,
            maxSlipBps: 100,
            shieldMax: 16,
            stepGas: 8_000_000
        });
    }
}
