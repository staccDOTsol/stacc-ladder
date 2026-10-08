// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2, Vm} from "forge-std/Test.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {StaccLadder} from "../src/StaccLadder.sol";
import {Pos} from "../src/LadderTypes.sol";
import {Config} from "../script/Config.sol";
import {Router, IERC20T} from "./Router.sol";

interface IPonsCurveT {
    function buy(uint256 quoteIn, uint256 minTokensOut, address recipient) external payable returns (uint256);
    function getReserves() external view returns (uint256, uint256);
    function graduated() external view returns (bool);
    function realQuoteReserve() external view returns (uint256);
}

contract StaccLadderForkTest is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    IPoolManager pm = Config.PM;
    StaccLadder hook;
    Router router;
    address constant WHALE = 0x26E8134eCC3af5cCE32f34B03E7BD2f318B25158;
    Currency constant ETH = Currency.wrap(address(0));
    Currency USDG = Currency.wrap(Config.USDG);
    IERC20T zero = IERC20T(Config.ZERO);
    IERC20T usdg = IERC20T(Config.USDG);
    address bookA = makeAddr("bookA");

    function setUp() public {
        vm.createSelectFork("robinhood");
        hook = _deploy();
        hook.listQuote(USDG, Config.usdgEthPool());
        hook.setPonsFactory(Config.PONS_FACTORY, true);
        hook.listPons(Config.ZERO_CURVE);
        router = new Router(pm);
        vm.deal(address(router), 50 ether);
        vm.startPrank(WHALE);
        zero.transfer(address(router), 20_000_000e18);
        zero.transfer(bookA, 60_000_000e18);
        vm.stopPrank();
        deal(Config.USDG, address(router), 100e6);
        deal(Config.USDG, bookA, 200e6);
        vm.deal(bookA, 1 ether);
    }

    function _deploy() internal returns (StaccLadder h) {
        bytes memory init = abi.encodePacked(
            type(StaccLadder).creationCode,
            abi.encode(pm, address(this), address(this), uint16(0), Config.tiers(), Config.params())
        );
        bytes32 ih = keccak256(init);
        uint256 salt;
        address a;
        for (;; ++salt) {
            a = address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), Config.CREATE2, bytes32(salt), ih)))));
            if (uint160(a) & Hooks.ALL_HOOK_MASK == Config.FLAGS) break;
        }
        (bool ok,) = Config.CREATE2.call(abi.encodePacked(bytes32(salt), init));
        require(ok && a.code.length > 0, "deploy");
        h = StaccLadder(payable(a));
    }

    function _book(address who, address[] memory tokens, uint256 z, uint256 u, uint256 e) internal {
        Currency[] memory qs = new Currency[](2);
        qs[0] = ETH;
        qs[1] = USDG;
        vm.startPrank(who);
        hook.setBook(tokens, qs, address(0));
        if (z != 0) {
            zero.approve(address(hook), z);
            hook.deposit(Currency.wrap(Config.ZERO), z);
        }
        if (u != 0) {
            usdg.approve(address(hook), u);
            hook.deposit(USDG, u);
        }
        if (e != 0) hook.deposit{value: e}(ETH, e);
        vm.stopPrank();
    }

    function _zeroOnly() internal pure returns (address[] memory t) {
        t = new address[](1);
        t[0] = Config.ZERO;
    }

    function _laidOut() internal {
        hook.openFamily(Config.ZERO);
        _book(bookA, _zeroOnly(), 50_000_000e18, 100e6, 0.2 ether);
        hook.rebalance(bookA, Config.ZERO);
    }

    // ───────────────────────────── layout ─────────────────────────────

    function test_familyAndLayout() public {
        _laidOut();
        (int24 refUsdg, bool ok1) = hook.pairTick(Config.ZERO, USDG);
        (int24 refEth, bool ok2) = hook.pairTick(Config.ZERO, ETH);
        assertTrue(ok1 && ok2, "refs");
        console2.log("ref tick ZERO/USDG", int256(refUsdg));
        console2.log("ref tick ZERO/ETH ", int256(refEth));
        uint256 placedZero;
        uint256 asks;
        for (uint8 t; t < 4; ++t) {
            // ZERO < USDG: token is currency0, asks above the reference
            (PoolKey memory k,) = hook.familyKey(Config.ZERO, USDG, t);
            (, int24 pt,,) = pm.getSlot0(k.toId());
            Pos memory ask = hook.position(k.toId(), bookA, 0);
            Pos memory bid = hook.position(k.toId(), bookA, 1);
            if (ask.liq != 0) {
                asks++;
                placedZero += ask.placed;
                assertGt(ask.lo, pt, "usdg ask above pool");
                assertGe(ask.lo, refUsdg, "usdg ask at/above ref");
            }
            if (bid.liq != 0) {
                assertLe(bid.hi, pt, "usdg bid at/below pool");
                assertLe(bid.hi, refUsdg, "usdg bid at/below ref");
            }
            // ETH < ZERO: token is currency1, price = ZERO per ETH; asks below -ref
            (k,) = hook.familyKey(Config.ZERO, ETH, t);
            (, pt,,) = pm.getSlot0(k.toId());
            ask = hook.position(k.toId(), bookA, 0);
            bid = hook.position(k.toId(), bookA, 1);
            if (ask.liq != 0) {
                asks++;
                placedZero += ask.placed;
                assertLe(ask.hi, pt, "eth ask at/below pool");
                assertLe(ask.hi, -refEth, "eth ask behind ref");
            }
            if (bid.liq != 0) {
                assertGt(bid.lo, pt, "eth bid above pool");
                assertGe(bid.lo, -refEth, "eth bid behind ref");
            }
        }
        assertGt(asks, 0, "asks placed");
        assertApproxEqRel(placedZero, 50_000_000e18, 0.001e18, "all ZERO laid");
        (uint256 freeZ,,) = hook.balanceOf(bookA, Currency.wrap(Config.ZERO));
        assertLt(freeZ, 1e18, "no ZERO left idle");
    }

    // ───────────────────────────── ratchet ─────────────────────────────

    function _usdgKey(uint8 t) internal view returns (PoolKey memory k) {
        (k,) = hook.familyKey(Config.ZERO, USDG, t);
    }

    function test_swapRatchet_sameBlock() public {
        _laidOut();
        PoolKey memory k = _usdgKey(1);
        Currency z = Currency.wrap(Config.ZERO);
        // buy ZERO with 2 USDG, exact in, three times in one block
        uint256 t0 = hook.tollOf(z);
        BalanceDelta d1 = router.swap(k, false, -2e6);
        uint256 t1 = hook.tollOf(z);
        BalanceDelta d2 = router.swap(k, false, -2e6);
        uint256 t2 = hook.tollOf(z);
        BalanceDelta d3 = router.swap(k, false, -2e6);
        uint256 t3 = hook.tollOf(z);
        assertEq(hook.referencesThisBlock(Config.ZERO), 3, "k");
        assertEq(t1 - t0, 0, "first reference free");
        uint256 out2 = uint256(uint128(d2.amount0()));
        uint256 out3 = uint256(uint128(d3.amount0()));
        // toll = 10bp*k^2 of the unspecified (output) leg, measured before the toll
        assertApproxEqRel(t2 - t1, (out2 + (t2 - t1)) * 40 / 10_000, 0.001e18, "k=2 pays 40bp");
        assertApproxEqRel(t3 - t2, (out3 + (t3 - t2)) * 90 / 10_000, 0.001e18, "k=3 pays 90bp");
        console2.log("swap1 out", uint256(uint128(d1.amount0())));
        vm.roll(block.number + 1);
        router.swap(k, false, -2e6);
        assertEq(hook.referencesThisBlock(Config.ZERO), 1, "next block resets");
    }

    function test_lpToll_jitBundle() public {
        hook.openFamily(Config.ZERO);
        PoolKey memory k = _usdgKey(1);
        (, int24 pt,,) = pm.getSlot0(k.toId());
        int24 lo = (pt / 100 - 20) * 100;
        int24 hi = (pt / 100 + 20) * 100;
        Router.Act[] memory a = new Router.Act[](2);
        a[0] = Router.Act(false, k, false, 1e15, lo, hi, bytes32(uint256(7)));
        a[1] = Router.Act(false, k, false, -1e15, lo, hi, bytes32(uint256(7)));
        uint256 tz0 = hook.tollOf(Currency.wrap(Config.ZERO));
        uint256 tu0 = hook.tollOf(USDG);
        BalanceDelta[] memory d = router.run(a);
        uint256 tz = hook.tollOf(Currency.wrap(Config.ZERO)) - tz0;
        uint256 tu = hook.tollOf(USDG) - tu0;
        // add is k=1 (free); remove is k=2 plus one for the same block = 3 -> 90 bp of principal
        uint256 principal0 = uint256(uint128(d[1].amount0())) + tz;
        assertApproxEqRel(tz, principal0 * 90 / 10_000, 0.01e18, "same-block remove pays k=3");
        assertGt(tu, 0, "both legs tolled");
        console2.log("JIT add/remove toll ZERO, USDG", tz, tu);
    }

    // ───────────────────────────── cascade / listing / shield gas ─────────────────────────────

    function test_oneInitOpensThePairsTiers() public {
        // an outsider initializes only the 3% ZERO/USDG pool; the hook opens the other tiers
        PoolKey memory k = _usdgKey(2);
        (int24 ref,) = hook.pairTick(Config.ZERO, USDG);
        pm.initialize(k, _sqrtAt(ref));
        for (uint8 t; t < 4; ++t) {
            (uint160 sp,,,) = pm.getSlot0(_usdgKey(t).toId());
            assertGt(sp, 0, "tier opened");
            assertTrue(hook.family(_usdgKey(t).toId()).known, "tier registered");
        }
        (PoolKey memory ek,) = hook.familyKey(Config.ZERO, ETH, 0);
        (uint160 esp,,,) = pm.getSlot0(ek.toId());
        assertEq(esp, 0, "other quotes untouched");
    }

    function _sqrtAt(int24 t) internal pure returns (uint160) {
        return TickMath.getSqrtPriceAtTick(t);
    }

    function test_quoteListing_firstComeOwnerRepoints() public {
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(StaccLadder.NotOwner.selector);
        hook.listQuote(USDG, Config.usdgEthPool());
        hook.listQuote(USDG, Config.usdgEthPool()); // owner may re-point
    }

    function test_lowGasSwapCannotSkipShield() public {
        _laidOut();
        PoolKey memory k = _usdgKey(1);
        vm.expectRevert();
        router.swap{gas: 2_000_000}(k, false, -1e6);
        router.swap(k, false, -1e6);
    }

    // ───────────────────────────── shield ─────────────────────────────

    function test_shield_followsCurvePump() public {
        _laidOut();
        PoolKey memory k = _usdgKey(1);
        Pos memory before = hook.position(k.toId(), bookA, 0);
        (int24 ref0,) = hook.pairTick(Config.ZERO, USDG);
        // the curve pumps: someone buys 0.5 ETH of ZERO on Pons
        address buyer = makeAddr("ponsBuyer");
        vm.deal(buyer, 1 ether);
        vm.prank(buyer);
        IPonsCurveT(Config.ZERO_CURVE).buy{value: 0.5 ether}(0.5 ether, 0, buyer);
        (int24 ref1,) = hook.pairTick(Config.ZERO, USDG);
        console2.log("ref before pump", int256(ref0));
        console2.log("ref after pump ", int256(ref1));
        assertGt(ref1, ref0, "pump");
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 2);
        // an arber comes to buy our ZERO: the shield moves the ask behind the new reference first
        router.swap(k, false, -1e6);
        Pos memory moved = hook.position(k.toId(), bookA, 0);
        console2.log("ask lo before", int256(before.lo));
        console2.log("ask lo after ", int256(moved.lo));
        if (before.lo < ref1) {
            assertGe(moved.lo, ref1, "ask moved behind the pumped reference");
        }
    }

    // ───────────────────────────── orchestration ─────────────────────────────

    function test_autoStep_relaysAfterInterval() public {
        _laidOut();
        PoolKey memory k = _usdgKey(1);
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 1000);
        vm.recordLogs();
        router.swap(k, false, -1e6);
        router.swap(k, false, -1e6); // second swap reaches the next due entry
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool relaid;
        bytes32 sig = keccak256("Rebalanced(address,address,uint256,uint256)");
        bytes32 qsig = keccak256("QuotesRebalanced(address,address,address,uint256)");
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(hook) && (logs[i].topics[0] == sig || logs[i].topics[0] == qsig)) {
                relaid = true;
            }
        }
        assertTrue(relaid, "in-swap step re-laid the book");
    }

    function test_quoteMix_movesUsdgToEth() public {
        hook.openFamily(Config.ZERO);
        _book(bookA, _zeroOnly(), 10_000_000e18, 150e6, 0);
        (uint256 eth0,,) = hook.balanceOf(bookA, ETH);
        hook.rebalanceQuotes(bookA);
        (uint256 eth1,,) = hook.balanceOf(bookA, ETH);
        (uint256 u1,, int256 ut) = hook.balanceOf(bookA, USDG);
        console2.log("ETH after quote mix", eth1);
        console2.log("USDG after quote mix", u1);
        assertGt(eth1, eth0, "bought ETH");
        assertEq(ut, 150e6, "depositor-keyed quote total unchanged by the mix");
    }

    function test_unwindAndWithdraw() public {
        _laidOut();
        vm.startPrank(bookA);
        hook.unwind(bookA, Config.ZERO);
        (uint256 z,,) = hook.balanceOf(bookA, Currency.wrap(Config.ZERO));
        (uint256 u,,) = hook.balanceOf(bookA, USDG);
        (uint256 e,,) = hook.balanceOf(bookA, ETH);
        assertApproxEqRel(z, 50_000_000e18, 0.0001e18, "ZERO back");
        uint256 zb = zero.balanceOf(bookA);
        hook.withdraw(bookA, Currency.wrap(Config.ZERO), z, bookA);
        hook.withdraw(bookA, USDG, u, bookA);
        hook.withdraw(bookA, ETH, e, bookA);
        vm.stopPrank();
        assertEq(zero.balanceOf(bookA) - zb, z, "ZERO withdrawn");
        assertApproxEqAbs(u, 100e6, 2, "USDG back");
    }

    function test_outsiderCannotTouchBook() public {
        _laidOut();
        vm.expectRevert(StaccLadder.NotBookOwner.selector);
        hook.withdraw(bookA, USDG, 1, address(this));
    }

    // ───────────────────────────── graduation ─────────────────────────────

    /// @dev Pons's launch record: (token, curve, deployer, feeRecipient, pairToken, threshold, poolFee, tickSpacing, ...)
    function gradKey(address token) internal view returns (PoolKey memory) {
        (bool ok, bytes memory r) =
            Config.PONS_FACTORY.staticcall(abi.encodeWithSignature("getLaunchedToken(address)", token));
        require(ok, "launch record");
        (,,,, address pair,, uint256 fee, int256 ts) =
            abi.decode(r, (address, address, address, address, address, uint256, uint256, int256));
        (, bytes memory h) = Config.PONS_FACTORY.staticcall(abi.encodeWithSignature("memeHook()"));
        address memeHook = abi.decode(h, (address));
        bool pairFirst = pair < token;
        return PoolKey(
            Currency.wrap(pairFirst ? pair : token),
            Currency.wrap(pairFirst ? token : pair),
            uint24(fee),
            int24(ts),
            IHooks(memeHook)
        );
    }

    function test_graduation_switchesReferenceToUni() public {
        _laidOut();
        address buyer = makeAddr("graduator");
        vm.deal(buyer, 10 ether);
        vm.prank(buyer);
        IPonsCurveT(Config.ZERO_CURVE).buy{value: 5 ether}(5 ether, 0, buyer);
        assertTrue(IPonsCurveT(Config.ZERO_CURVE).graduated(), "graduated");
        (, bool okPre) = hook.pairTick(Config.ZERO, ETH);
        assertFalse(okPre, "curve reference retires at graduation");
        // Pons graduates in two steps: the sweep above, then anyone seeds the Uniswap pool
        (bool seeded,) = Config.PONS_FACTORY.call(abi.encodeWithSignature("createGraduatedPool(address)", Config.ZERO));
        assertTrue(seeded, "pool seeded");
        PoolKey memory key = gradKey(Config.ZERO);
        console2.log("graduated pool fee", uint256(key.fee));
        console2.log("graduated pool spacing", int256(key.tickSpacing));
        // no call needed: the Pons reference reads the seeded pool on its own
        (int24 post, bool okPost) = hook.pairTick(Config.ZERO, ETH);
        assertTrue(okPost, "uni reference live without a switch call");
        hook.graduate(Config.ZERO, key); // the explicit switch still works and agrees
        (int24 post2,) = hook.pairTick(Config.ZERO, ETH);
        assertEq(post2, post, "same price either way");
        console2.log("post-bond ref tick ZERO/ETH", int256(post));
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 5);
        hook.rebalance(bookA, Config.ZERO);
    }
}
