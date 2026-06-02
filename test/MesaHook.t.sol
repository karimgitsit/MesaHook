// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {HookMiner} from "@uniswap/v4-periphery/test/shared/HookMiner.sol";

import {BaseCustomAccounting} from "uniswap-hooks/src/base/BaseCustomAccounting.sol";
import {MesaHook} from "../src/MesaHook.sol";

/**
 * @title MesaHookTest
 * @notice Full suite for the MesaHook piecewise (constant-sum + offset-CPMM) curve.
 *         Mirrors SPEC §11: initialization, permission flags, in-band zero-slippage,
 *         boundary-crossing split, adversarial (wrong-caller, native-liquidity,
 *         no-leakage round-trip fuzz, inflation-attack), LP lifecycle, fees, mixed decimals.
 */
contract MesaHookTest is Deployers {
    using PoolIdLibrary for PoolKey;

    /// @dev Exactly MesaHook's declared permission bitmap.
    uint160 internal constant FLAGS = uint160(
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
            | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
    );

    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;

    uint256 internal constant ALPHA = 1e17; // 0.1e18
    int24 internal constant TS = 60;

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies(); // sets global currency0/currency1 (both 18 dp), approves routers
    }

    // ---------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------

    function _mine(uint256 p_, uint256 alpha_, uint24 fee_) internal view returns (bytes32 salt) {
        bytes memory args = abi.encode(manager, p_, alpha_, fee_, "Mesa LP", "MESA-LP");
        (, salt) = HookMiner.find(address(this), FLAGS, type(MesaHook).creationCode, args);
    }

    function _deployHook(uint256 p_, uint256 alpha_, uint24 fee_) internal returns (MesaHook hook) {
        bytes memory args = abi.encode(manager, p_, alpha_, fee_, "Mesa LP", "MESA-LP");
        (address addr, bytes32 salt) = HookMiner.find(address(this), FLAGS, type(MesaHook).creationCode, args);
        hook = new MesaHook{salt: salt}(manager, p_, alpha_, fee_, "Mesa LP", "MESA-LP");
        require(address(hook) == addr, "mined address mismatch");
    }

    /// @dev Deploy a hook on the global (18/18) currencies, init its pool, approve, and seed liquidity.
    function _freshPool(uint256 p_, uint256 alpha_, uint24 fee_, uint256 a0, uint256 a1)
        internal
        returns (MesaHook hook, PoolKey memory pk)
    {
        hook = _deployHook(p_, alpha_, fee_);
        pk = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: 0,
            tickSpacing: TS,
            hooks: IHooks(address(hook))
        });
        manager.initialize(pk, SQRT_PRICE_1_1);
        MockERC20(Currency.unwrap(currency0)).approve(address(hook), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(hook), type(uint256).max);
        if (a0 != 0 || a1 != 0) _add(hook, a0, a1);
    }

    function _add(MesaHook hook, uint256 a0, uint256 a1) internal returns (BalanceDelta) {
        return hook.addLiquidity(
            BaseCustomAccounting.AddLiquidityParams({
                amount0Desired: a0,
                amount1Desired: a1,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp,
                tickLower: 0,
                tickUpper: 0,
                userInputSalt: bytes32(0)
            })
        );
    }

    function _remove(MesaHook hook, uint256 shares) internal returns (BalanceDelta) {
        return hook.removeLiquidity(
            BaseCustomAccounting.RemoveLiquidityParams({
                liquidity: shares,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp,
                tickLower: 0,
                tickUpper: 0,
                userInputSalt: bytes32(0)
            })
        );
    }

    function _swapIn(PoolKey memory pk, bool zeroForOne, uint256 amtIn) internal returns (uint256 out) {
        BalanceDelta d = swap(pk, zeroForOne, -int256(amtIn), ZERO_BYTES);
        out = zeroForOne ? uint256(int256(d.amount1())) : uint256(int256(d.amount0()));
    }

    function _swapOut(PoolKey memory pk, bool zeroForOne, uint256 amtOut) internal returns (uint256 paid) {
        BalanceDelta d = swap(pk, zeroForOne, int256(amtOut), ZERO_BYTES);
        paid = zeroForOne ? uint256(-int256(d.amount0())) : uint256(-int256(d.amount1()));
    }

    // =====================================================================
    // §11.1 Initialization
    // =====================================================================

    function test_initialization_storesConfig() public {
        MesaHook hook = _deployHook(1e18, ALPHA, 100);
        assertEq(hook.p(), 1e18);
        assertEq(hook.alpha(), ALPHA);
        assertEq(uint256(hook.swapFee()), 100);
    }

    function test_initialization_singleInstanceGuard() public {
        // The hook binds to the first pool that initializes it; a second pool reverts.
        (MesaHook hook,) = _freshPool(1e18, ALPHA, 0, 0, 0);
        PoolKey memory pk2 = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: 0,
            tickSpacing: 30, // different id, same hook
            hooks: IHooks(address(hook))
        });
        vm.expectRevert();
        manager.initialize(pk2, SQRT_PRICE_1_1);
    }

    function test_construction_rejectsInvalidConfig() public {
        bytes32 s;

        s = _mine(0, ALPHA, 0);
        vm.expectRevert(MesaHook.InvalidPrice.selector);
        new MesaHook{salt: s}(manager, 0, ALPHA, 0, "Mesa LP", "MESA-LP");

        s = _mine(1e18, 0, 0);
        vm.expectRevert(MesaHook.InvalidAlpha.selector);
        new MesaHook{salt: s}(manager, 1e18, 0, 0, "Mesa LP", "MESA-LP");

        s = _mine(1e18, 5e17, 0); // alpha == 0.5e18 (upper-exclusive)
        vm.expectRevert(MesaHook.InvalidAlpha.selector);
        new MesaHook{salt: s}(manager, 1e18, 5e17, 0, "Mesa LP", "MESA-LP");

        s = _mine(1e18, ALPHA, 1e6); // fee == 100%
        vm.expectRevert(MesaHook.InvalidFee.selector);
        new MesaHook{salt: s}(manager, 1e18, ALPHA, 1e6, "Mesa LP", "MESA-LP");
    }

    // =====================================================================
    // §11.2 Permission flags
    // =====================================================================

    function test_permissions_exactlySpecSet() public {
        MesaHook hook = _deployHook(1e18, ALPHA, 0);
        Hooks.Permissions memory perms = hook.getHookPermissions();

        assertTrue(perms.beforeInitialize);
        assertTrue(perms.beforeAddLiquidity);
        assertTrue(perms.beforeRemoveLiquidity);
        assertTrue(perms.beforeSwap);
        assertTrue(perms.beforeSwapReturnDelta);

        // Everything else must be false.
        assertFalse(perms.afterInitialize);
        assertFalse(perms.afterAddLiquidity);
        assertFalse(perms.afterRemoveLiquidity);
        assertFalse(perms.afterSwap);
        assertFalse(perms.beforeDonate);
        assertFalse(perms.afterDonate);
        assertFalse(perms.afterSwapReturnDelta);
        assertFalse(perms.afterAddLiquidityReturnDelta);
        assertFalse(perms.afterRemoveLiquidityReturnDelta);

        // Address low bits encode exactly those flags.
        assertEq(uint160(address(hook)) & Hooks.ALL_HOOK_MASK, FLAGS);
    }

    // =====================================================================
    // §11.3 In-band: exact peg, zero slippage
    // =====================================================================

    function test_inBand_zeroSlippage_exactInput() public {
        (, PoolKey memory pk) = _freshPool(1e18, ALPHA, 0, 1000e18, 1000e18);
        // Small swap stays inside the flat band → price exactly p (=1), zero slippage, no fee.
        uint256 out = _swapIn(pk, true, 10e18);
        assertEq(out, 10e18, "in-band zeroForOne not 1:1");

        uint256 out2 = _swapIn(pk, false, 10e18);
        assertEq(out2, 10e18, "in-band oneForZero not 1:1");
    }

    function test_inBand_zeroSlippage_exactOutput() public {
        (, PoolKey memory pk) = _freshPool(1e18, ALPHA, 0, 1000e18, 1000e18);
        uint256 paid = _swapOut(pk, true, 10e18); // want 10e18 token1 out
        assertEq(paid, 10e18, "in-band exact-output not 1:1");
    }

    // =====================================================================
    // §11.4 Boundary-crossing split + continuity
    // =====================================================================

    function test_boundary_fillToEdge_isZeroSlippage() public {
        (MesaHook hook, PoolKey memory pk) = _freshPool(1e18, ALPHA, 0, 1000e18, 1000e18);
        // Flat capacity selling token0 = y - lo = 1000e18 - 0.1*2000e18 = 800e18.
        uint256 out = _swapIn(pk, true, 800e18);
        assertEq(out, 800e18, "fill-to-edge must be exactly 1:1");
        // Pool now parked exactly on the lower edge: reserve1 == alpha*S == 200e18.
        assertEq(hook.reserve1(pk.toId()), 200e18, "not parked on band edge");
    }

    function test_boundary_crossing_splitsAndStiffens() public {
        (, PoolKey memory pk) = _freshPool(1e18, ALPHA, 0, 1000e18, 1000e18);
        // 1000e18 in: 800e18 flat at p, then 200e18 budget walks the low arm.
        uint256 out = _swapIn(pk, true, 1000e18);
        // Exact integer expectation from the offset-CPMM arm (see test notes / SPEC §4.3).
        assertEq(out, 981818181818181818181, "boundary-split output mismatch");
        // Strictly between flat-only (800e18) and frictionless (1000e18): the wall stiffened.
        assertGt(out, 800e18);
        assertLt(out, 1000e18);
    }

    // =====================================================================
    // §11.5 Adversarial
    // =====================================================================

    function test_adversarial_wrongCaller_reverts() public {
        (MesaHook hook,) = _freshPool(1e18, ALPHA, 0, 0, 0);
        PoolKey memory pk = hook.poolKey();
        SwapParams memory sp = SwapParams({zeroForOne: true, amountSpecified: -1, sqrtPriceLimitX96: MIN_PRICE_LIMIT});
        // Direct call (not from PoolManager) must hit onlyPoolManager.
        vm.expectRevert();
        hook.beforeSwap(address(this), pk, sp, ZERO_BYTES);
    }

    function test_adversarial_nativeLiquidity_reverts() public {
        (, PoolKey memory pk) = _freshPool(1e18, ALPHA, 0, 1000e18, 1000e18);
        // Direct PoolManager liquidity must be rejected — everything routes through the hook.
        vm.expectRevert();
        modifyLiquidityRouter.modifyLiquidity(pk, LIQUIDITY_PARAMS, ZERO_BYTES);
    }

    /// @notice The §6 no-leakage invariant: a swap then its exact reverse never returns more than the
    ///         original input (net of fees). With fee = 0 this is the tightest possible check.
    function testFuzz_noLeakage_roundTrip(uint256 amtIn, bool zeroForOne) public {
        (, PoolKey memory pk) = _freshPool(1e18, ALPHA, 0, 1e24, 1e24);
        amtIn = bound(amtIn, 1e12, 1e24);

        uint256 out = _swapIn(pk, zeroForOne, amtIn);
        if (out == 0) return;

        uint256 back = _swapIn(pk, !zeroForOne, out);
        assertLe(back, amtIn, "round-trip extracted principal");
    }

    /// @notice No-leakage must also hold with a non-zero fee (round-trip loses at least the fee).
    function testFuzz_noLeakage_roundTrip_withFee(uint256 amtIn, bool zeroForOne) public {
        (, PoolKey memory pk) = _freshPool(1e18, ALPHA, 3000, 1e24, 1e24); // 0.30%
        amtIn = bound(amtIn, 1e12, 1e24);

        uint256 out = _swapIn(pk, zeroForOne, amtIn);
        if (out == 0) return;

        uint256 back = _swapIn(pk, !zeroForOne, out);
        assertLe(back, amtIn, "round-trip extracted principal (fee path)");
    }

    function test_inflationAttack_firstDepositFloored() public {
        (MesaHook hook,) = _freshPool(1e18, ALPHA, 0, 0, 0);
        // First deposit whose total value <= MINIMUM_LIQUIDITY (1000) is rejected.
        vm.expectRevert(MesaHook.InsufficientInitialLiquidity.selector);
        _add(hook, 400, 400); // value = 800 <= 1000
    }

    function test_inflationAttack_minimumLiquidityLocked() public {
        (MesaHook hook,) = _freshPool(1e18, ALPHA, 0, 0, 0);
        _add(hook, 1000e18, 1000e18);
        uint256 S0 = 2000e18; // p*x/1e18 + y
        assertEq(hook.balanceOf(DEAD), 1000, "MINIMUM_LIQUIDITY not locked");
        assertEq(hook.balanceOf(address(this)), S0 - 1000, "depositor shares wrong");
        assertEq(hook.totalSupply(), S0, "total supply wrong");
    }

    // =====================================================================
    // §11.6 LP lifecycle
    // =====================================================================

    function test_lp_proRataAddAndRemove() public {
        (MesaHook hook, PoolKey memory pk) = _freshPool(1e18, ALPHA, 0, 1000e18, 1000e18);
        PoolId id = pk.toId();

        // Second deposit in-ratio: 500/500 → 1000e18 shares (ts=2000e18, reserves 1000e18 each).
        uint256 before = hook.balanceOf(address(this));
        BalanceDelta d = _add(hook, 500e18, 500e18);
        assertEq(uint256(-int256(d.amount0())), 500e18, "add amount0 wrong");
        assertEq(uint256(-int256(d.amount1())), 500e18, "add amount1 wrong");
        assertEq(hook.balanceOf(address(this)) - before, 1000e18, "minted shares wrong");
        assertEq(hook.reserve0(id), 1500e18);
        assertEq(hook.reserve1(id), 1500e18);

        // Remove 1000e18 shares (ts=3000e18, reserves 1500e18) → 500/500 back.
        BalanceDelta r = _remove(hook, 1000e18);
        assertEq(uint256(int256(r.amount0())), 500e18, "remove amount0 wrong");
        assertEq(uint256(int256(r.amount1())), 500e18, "remove amount1 wrong");
    }

    function test_lp_singleSidedReverts() public {
        (MesaHook hook,) = _freshPool(1e18, ALPHA, 0, 1000e18, 1000e18);
        vm.expectRevert(MesaHook.SingleSidedNotAllowed.selector);
        _add(hook, 0, 500e18);
        vm.expectRevert(MesaHook.SingleSidedNotAllowed.selector);
        _add(hook, 500e18, 0);
    }

    function test_lp_alwaysCanExit() public {
        (MesaHook hook,) = _freshPool(1e18, ALPHA, 0, 1000e18, 1000e18);
        uint256 bal = hook.balanceOf(address(this));
        _remove(hook, bal);
        assertEq(hook.balanceOf(address(this)), 0, "could not fully exit");
    }

    // =====================================================================
    // §11.7 Fees
    // =====================================================================

    function test_fee_chargedAndFolded() public {
        uint24 fee = 1000; // 0.10%
        (MesaHook hook, PoolKey memory pk) = _freshPool(1e18, ALPHA, fee, 1000e18, 1000e18);
        PoolId id = pk.toId();

        // Exact-input 10e18 token0: fee = ceil(10e18 * 1000 / 1e6) = 1e16, net = 9.99e18 → out = 9.99e18.
        uint256 out = _swapIn(pk, true, 10e18);
        assertEq(out, 9990000000000000000, "fee not applied to output");

        // Full input (incl. fee) lands in the pool; output left the pool.
        assertEq(hook.reserve0(id), 1010e18, "reserve0 should grow by gross input");
        assertEq(hook.reserve1(id), 1000e18 - 9990000000000000000, "reserve1 should fall by output");
        // S grew by the fee's value, so the fee accrues to LPs.
        assertEq(hook.canonicalSize(id), 2000e18 + 1e16, "fee not folded into S");
    }

    function test_fee_zeroIsExact() public {
        (, PoolKey memory pk) = _freshPool(1e18, ALPHA, 0, 1000e18, 1000e18);
        uint256 out = _swapIn(pk, true, 50e18);
        assertEq(out, 50e18, "fee=0 must be exact 1:1 in band");
    }

    // =====================================================================
    // §11.8 Mixed decimals (6 / 18)
    // =====================================================================

    function test_mixedDecimals_economicParity() public {
        MockERC20 a = new MockERC20("SIX", "SIX", 6);
        MockERC20 b = new MockERC20("EIGHTEEN", "EIGHTEEN", 18);
        a.mint(address(this), type(uint128).max);
        b.mint(address(this), type(uint128).max);

        (Currency c0, Currency c1) = address(a) < address(b)
            ? (Currency.wrap(address(a)), Currency.wrap(address(b)))
            : (Currency.wrap(address(b)), Currency.wrap(address(a)));

        uint8 d0 = MockERC20(Currency.unwrap(c0)).decimals();
        uint8 d1 = MockERC20(Currency.unwrap(c1)).decimals();
        uint256 p = d1 >= d0 ? 1e18 * (10 ** (d1 - d0)) : 1e18 / (10 ** (d0 - d1));

        MesaHook hook = _deployHook(p, ALPHA, 0);
        PoolKey memory pk =
            PoolKey({currency0: c0, currency1: c1, fee: 0, tickSpacing: TS, hooks: IHooks(address(hook))});
        manager.initialize(pk, SQRT_PRICE_1_1);

        MockERC20(Currency.unwrap(c0)).approve(address(hook), type(uint256).max);
        MockERC20(Currency.unwrap(c1)).approve(address(hook), type(uint256).max);
        MockERC20(Currency.unwrap(c0)).approve(address(swapRouter), type(uint256).max);
        MockERC20(Currency.unwrap(c1)).approve(address(swapRouter), type(uint256).max);

        // Balanced deposit: 1000 whole tokens of each side.
        _add(hook, 1000 * (10 ** d0), 1000 * (10 ** d1));

        // Sell exactly 1 whole token0; expect ~1 whole token1 (economic 1:1, in band, fee 0).
        uint256 out = _swapIn(pk, true, 10 ** d0);
        assertEq(out, 10 ** d1, "mixed-decimals not economic 1:1");
    }
}
