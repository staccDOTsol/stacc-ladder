// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PonsArb} from "../src/arb/PonsArb.sol";
import {StaccLadder} from "../src/StaccLadder.sol";
import {Config} from "../script/Config.sol";
import {Router, IERC20T} from "./Router.sol";

/// @notice Runs against live Robinhood state, including the deployed StaccLadder and its books.
contract PonsArbForkTest is Test {
    IPoolManager pm = Config.PM;
    address constant ME = 0x26E8134eCC3af5cCE32f34B03E7BD2f318B25158;
    StaccLadder constant HOOK = StaccLadder(payable(0x3BDAd0B539F815eDE3ff89cF511F2C37f99215C7));
    PonsArb arb;
    Router router;

    function setUp() public {
        vm.createSelectFork("robinhood");
        arb = new PonsArb(pm, ME);
        router = new Router(pm);
        vm.deal(address(router), 10 ether);
        deal(Config.ZERO, address(router), 900_000_000e18);
    }

    function _plan(PoolKey memory pool, bool poolCheap, uint256 amt) internal pure returns (PonsArb.Plan memory p) {
        PoolKey memory none;
        p = PonsArb.Plan({
            curve: Config.ZERO_CURVE,
            token: Config.ZERO,
            pool: pool,
            bridge: none,
            useBridge: false,
            poolCheap: poolCheap,
            amountIn: amt
        });
    }

    function test_takesGapOnMispricedPool() public {
        // someone opens a hookless ETH/ZERO pool with ZERO 20% cheaper than the curve
        (int24 ref,) = HOOK.pairTick(Config.ZERO, Currency.wrap(address(0))); // ETH per ZERO
        PoolKey memory k = PoolKey(Currency.wrap(address(0)), Currency.wrap(Config.ZERO), 3000, 60, IHooks(address(0)));
        int24 t = -ref + 2231; // ZERO per ETH, ~25% more ZERO per ETH = ZERO 20% cheaper
        t = (t / 60) * 60;
        pm.initialize(k, TickMath.getSqrtPriceAtTick(t));
        Router.Act[] memory a = new Router.Act[](1);
        a[0] = Router.Act(false, k, false, 3e22, t - 6000, t + 6000, bytes32(0));
        router.run(a);
        uint256 b0 = ME.balance;
        vm.prank(ME);
        uint256 profit = arb.arb(_plan(k, true, 0.005 ether), 0);
        console2.log("profit wei on 0.005 ETH", profit);
        assertGt(profit, 0, "took the gap");
        assertEq(ME.balance - b0, profit, "paid to owner");
        assertEq(address(arb).balance, 0, "holds nothing");
    }

    function test_standsDownOnShieldedBook() public {
        // the live JUSTTESTIN book: buying its stale asks gets shielded first, so no edge
        (PoolKey memory k,) = HOOK.familyKey(0xA0Fc5a405772Fc80e977e0C1E9D20B95FE956c9e, Currency.wrap(address(0)), 1);
        PonsArb.Plan memory p = _plan(k, true, 0.002 ether);
        p.curve = 0xb6B77aB627d476Db286B732B7359F552BBC694F4;
        p.token = 0xA0Fc5a405772Fc80e977e0C1E9D20B95FE956c9e;
        vm.prank(ME);
        vm.expectRevert();
        arb.arb(p, 0);
    }
}
