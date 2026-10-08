// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PonsArb} from "../src/arb/PonsArb.sol";
import {StaccLadder} from "../src/StaccLadder.sol";
import {Config} from "../script/Config.sol";

/// @notice What an arber would make against the live books right now (fork of the current block).
contract LiveEdgeForkTest is Test {
    address constant ME = 0x26E8134eCC3af5cCE32f34B03E7BD2f318B25158;
    StaccLadder constant HOOK = StaccLadder(payable(0x3BDAd0B539F815eDE3ff89cF511F2C37f99215C7));
    address constant JT = 0xA0Fc5a405772Fc80e977e0C1E9D20B95FE956c9e;
    address constant JT_CURVE = 0xb6B77aB627d476Db286B732B7359F552BBC694F4;

    function test_liveEdge() public {
        vm.createSelectFork("robinhood");
        PonsArb arb = new PonsArb(Config.PM, ME);
        uint256[5] memory sizes = [uint256(0.0005 ether), 0.001 ether, 0.003 ether, 0.01 ether, 0.03 ether];
        PoolKey memory none;
        for (uint8 tier; tier < 4; ++tier) {
            for (uint256 q; q < 2; ++q) {
                Currency quote = q == 0 ? Currency.wrap(address(0)) : Currency.wrap(Config.USDG);
                (PoolKey memory k,) = HOOK.familyKey(JT, quote, tier);
                for (uint256 dir; dir < 2; ++dir) {
                    for (uint256 i; i < sizes.length; ++i) {
                        PonsArb.Plan memory p = PonsArb.Plan(JT_CURVE, JT, k, q == 0 ? none : Config.usdgEthPool(), q == 1, dir == 0, sizes[i]);
                        uint256 snap = vm.snapshotState();
                        vm.prank(ME);
                        try arb.arb{gas: 10_000_000}(p, 0) returns (uint256 profit) {
                            console2.log(string.concat("tier ", vm.toString(tier), q == 0 ? " ETH " : " USDG ", dir == 0 ? "buyPool " : "buyCurve ", vm.toString(sizes[i])), profit);
                        } catch {}
                        vm.revertToState(snap);
                    }
                }
            }
        }
    }
}
