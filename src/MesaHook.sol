// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// External imports
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

// Internal imports (OpenZeppelin Uniswap Hooks)
import {BaseCustomCurve} from "uniswap-hooks/src/base/BaseCustomCurve.sol";
import {BaseHook} from "uniswap-hooks/src/base/BaseHook.sol";

/**
 * @title MesaHook
 * @notice A Uniswap v4 piecewise AMM for pegged / correlated assets.
 *
 * Inside an inventory band the curve is a CONSTANT-SUM market maker that trades at the
 * fixed peg price `p` with ZERO slippage (the flat "top" of the mesa). Outside the band
 * it switches to an offset constant-product curve that is C1-continuous with the flat
 * segment (the steep "sides" of the mesa) — no price jump at the boundary.
 *
 * The name "Mesa" is the geological flat-topped plateau with steep cliff sides: a perfect
 * picture of this curve — a flat constant-price top between two steep constant-product walls.
 *
 * Implements `SPEC-ExactPegBandHook.md`. See README for the deviations from the spec that
 * were forced by the installed v4 / OpenZeppelin-Uniswap-Hooks versions:
 *   1. Single-instance-per-pool (OZ BaseCustomCurve is single-pool by design). Deploy one
 *      mined instance per pool. State is still keyed by PoolId per the spec's shape.
 *   2. Config (`p`, `alpha`, `fee`) is set in the CONSTRUCTOR as immutables, not decoded from
 *      `hookData` — current v4 `initialize` carries no `hookData`. Constructor config is
 *      strictly more immutable, which suits the "fully immutable, no admin" posture.
 *   3. Swap fees are FOLDED into the principal reserves and `S` (spec §3 permits this),
 *      because v1.2.1's `_getSwapFeeAmount` is informational only.
 *
 * The internal curve math is done in "value space" (token1-denominated value), which makes
 * the constant-sum segment exactly price-`p` and removes the need for any sqrt. See the
 * `_walk` documentation for the offset derivation.
 *
 * @dev Fully immutable: no admin, no upgrade, no pause. LPs can always withdraw.
 *
 * SECURITY: rebasing / fee-on-transfer tokens are FORBIDDEN. They mutate balances out from
 * under the `p·x + y = S` invariant and silently break accounting. There is no on-chain way
 * to reliably detect them, so this is a usage requirement, not an enforced check. Use wrapped,
 * non-rebasing tokens (e.g. wstETH, never raw stETH).
 */
contract MesaHook is BaseCustomCurve, ERC20 {
    using PoolIdLibrary for PoolKey;

    // ---------------------------------------------------------------------
    // Constants
    // ---------------------------------------------------------------------

    /// @dev Fixed-point one (1e18) used for `p` and `alpha`.
    uint256 internal constant ONE = 1e18;

    /// @dev Upper exclusive bound for `alpha` (0.5e18).
    uint256 internal constant HALF = 5e17;

    /// @dev Fee denominator (pips, 1e-6).
    uint256 internal constant PIPS = 1e6;

    /// @dev Permanently-locked initial liquidity (first-deposit inflation-attack mitigation).
    uint256 internal constant MINIMUM_LIQUIDITY = 1_000;

    /// @dev Burn sink for the locked initial liquidity (cannot be address(0): ERC20 forbids it).
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;

    // ---------------------------------------------------------------------
    // Immutable per-pool config (set once, in the constructor)
    // ---------------------------------------------------------------------

    /// @notice Peg price: token1 base units per token0 base unit, ×1e18 (decimal-adjusted, see README §8).
    uint256 public immutable p;

    /// @notice Band parameter in (0, 0.5e18). Pool is in-band while α·S ≤ y ≤ (1−α)·S.
    uint256 public immutable alpha;

    /// @notice Flat swap fee in pips (1e-6). May be 0. Charged on the input token, everywhere.
    uint24 public immutable swapFee;

    // ---------------------------------------------------------------------
    // Per-pool state (keyed by PoolId; single live pool per deployed instance)
    // ---------------------------------------------------------------------

    /// @notice Principal reserve of token0 (x). Equal to the hook's ERC-6909 claim balance of currency0.
    mapping(PoolId => uint256) public reserve0;
    /// @notice Principal reserve of token1 (y). Equal to the hook's ERC-6909 claim balance of currency1.
    mapping(PoolId => uint256) public reserve1;
    /// @notice Canonical size S (token1 units). On the flat segment S = p·x/1e18 + y. Locates the band edges.
    mapping(PoolId => uint256) public canonicalSize;
    /// @notice Whether `beforeInitialize` has run for this pool.
    mapping(PoolId => bool) public initialized;

    /// @dev Fee charged on the most recent swap, in input-token units. Set in `_getUnspecifiedAmount`,
    ///      read by `_getSwapFeeAmount` for event emission only (same transaction, no cross-tx use).
    uint256 private _lastSwapFee;

    // ---------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------

    error InvalidPrice();
    error InvalidAlpha();
    error InvalidFee();
    error SingleSidedNotAllowed();
    error InsufficientInitialLiquidity();
    error InsufficientLiquidity();
    error ZeroShares();

    // ---------------------------------------------------------------------
    // Construction
    // ---------------------------------------------------------------------

    /**
     * @param manager The v4 PoolManager.
     * @param p_ Peg price, token1-per-token0 ×1e18, decimal-adjusted (see README). Must be > 0.
     * @param alpha_ Band parameter ×1e18. Must satisfy 0 < alpha_ < 0.5e18.
     * @param fee_ Flat swap fee in pips. Must be < 1e6 (100%). May be 0.
     * @param name_ ERC20 name of the LP share token.
     * @param symbol_ ERC20 symbol of the LP share token.
     */
    constructor(
        IPoolManager manager,
        uint256 p_,
        uint256 alpha_,
        uint24 fee_,
        string memory name_,
        string memory symbol_
    ) BaseHook(manager) ERC20(name_, symbol_) {
        if (p_ == 0) revert InvalidPrice();
        if (alpha_ == 0 || alpha_ >= HALF) revert InvalidAlpha();
        if (fee_ >= PIPS) revert InvalidFee();
        p = p_;
        alpha = alpha_;
        swapFee = fee_;
    }

    // ---------------------------------------------------------------------
    // Permissions (spec §2 — exactly these five flags, everything else false)
    // ---------------------------------------------------------------------

    /// @inheritdoc BaseHook
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true, // decode + validate + store per-pool config
            afterInitialize: false,
            beforeAddLiquidity: true, // intercept native liquidity; route through hook (pro-rata)
            beforeRemoveLiquidity: true, // intercept native liquidity; route through hook
            afterAddLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true, // run the piecewise curve
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true, // return the BeforeSwapDelta that overrides swap output
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // ---------------------------------------------------------------------
    // Initialization
    // ---------------------------------------------------------------------

    /// @dev Stores the pool key (via the base) and marks the pool initialized. Config is immutable
    ///      (constructor), so there is nothing to decode here; validation already happened at deploy.
    function _beforeInitialize(address sender, PoolKey calldata key, uint160 sqrtPriceX96)
        internal
        override
        returns (bytes4)
    {
        bytes4 selector = super._beforeInitialize(sender, key, sqrtPriceX96);
        initialized[key.toId()] = true;
        return selector;
    }

    // =====================================================================
    // Swap curve
    // =====================================================================

    /**
     * @dev Computes the swap along the piecewise curve, FOLDS the fee into reserves + S, and persists
     *      the new state. Called once per swap by `BaseCustomCurve._beforeSwap`, which then performs the
     *      take/settle using the value returned here as the "unspecified" amount.
     *
     * Returned value (the unspecified currency amount), per BaseCustomCurve's convention:
     *   - exact input  → the OUTPUT amount the swapper receives (settled out of the pool).
     *   - exact output → the INPUT amount the swapper pays (taken into the pool), INCLUDING the fee.
     *
     * Reserve update is the source of truth that keeps `reserveN` equal to the hook's ERC-6909 balances:
     *   - exact-input zeroForOne: hook takes `specified` token0 (incl. fee) and settles `out` token1
     *     ⇒ reserve0 += specified (delta sign: +, tokens into pool), reserve1 -= out (delta sign: −, tokens out).
     *   - the other three cases are the symmetric mirror; see inline comments.
     */
    function _getUnspecifiedAmount(SwapParams calldata params)
        internal
        override
        returns (uint256 unspecifiedAmount)
    {
        PoolId id = poolKey().toId();
        uint256 x = reserve0[id];
        uint256 y = reserve1[id];
        uint256 S = canonicalSize[id];

        bool zeroForOne = params.zeroForOne;
        bool exactInput = params.amountSpecified < 0;
        uint256 specified = exactInput ? uint256(-params.amountSpecified) : uint256(params.amountSpecified);

        // Band edges in value space (token1 units). lo = α·S, hi = (1−α)·S.
        uint256 lo = Math.mulDiv(alpha, S, ONE);
        uint256 hi = Math.mulDiv(ONE - alpha, S, ONE);

        // Value-space reserves: u = value of token0 reserves (token1 units), v = token1 reserves.
        uint256 u = _value0(x);
        uint256 v = y;

        uint256 feeAmount;
        uint256 newX;
        uint256 newY;
        uint256 dS; // increase to S from the folded fee (token1 value units)

        if (zeroForOne) {
            // Selling token0: in value space the input grows u (Rin=u), the output shrinks v (Rout=v).
            if (exactInput) {
                // Fee on the token0 input, rounded UP (against swapper).
                feeAmount = Math.mulDiv(specified, swapFee, PIPS, Math.Rounding.Ceil);
                uint256 netIn = specified - feeAmount;
                // Input value budget, rounded DOWN (against swapper → not more output than earned).
                uint256 budget = _value0(netIn);
                (, uint256 outValue) = _walk(u, v, lo, hi, true, budget);
                unspecifiedAmount = outValue; // token1 out
                newX = x + specified; // + : token0 (incl. fee) flows into the pool
                newY = y - outValue; // − : token1 flows out to the swapper
                dS = _value0(feeAmount); // grow S by the fee's value
            } else {
                // Exact output: `specified` is token1 out (== output value).
                uint256 outValue = specified;
                (uint256 inValue,) = _walk(u, v, lo, hi, false, outValue);
                uint256 netIn = _value0Inv(inValue, Math.Rounding.Ceil); // token0, rounded UP
                uint256 grossIn = Math.mulDiv(netIn, PIPS, PIPS - swapFee, Math.Rounding.Ceil);
                feeAmount = grossIn - netIn;
                unspecifiedAmount = grossIn; // token0 in (incl. fee)
                newX = x + grossIn; // + : token0 in
                newY = y - outValue; // − : token1 out
                dS = _value0(feeAmount);
            }
        } else {
            // Selling token1: input grows v (Rin=v), output shrinks u (Rout=u).
            if (exactInput) {
                feeAmount = Math.mulDiv(specified, swapFee, PIPS, Math.Rounding.Ceil); // fee in token1
                uint256 netIn = specified - feeAmount;
                uint256 budget = netIn; // token1 value == itself
                (, uint256 outValue) = _walk(v, u, lo, hi, true, budget);
                uint256 outTok0 = _value0Inv(outValue, Math.Rounding.Floor); // token0 out, rounded DOWN
                unspecifiedAmount = outTok0;
                newY = y + specified; // + : token1 (incl. fee) in
                newX = x - outTok0; // − : token0 out
                dS = feeAmount; // fee value (token1 units) == feeAmount
            } else {
                uint256 outTok0 = specified; // token0 out
                // Value of the requested output, rounded UP so we require AT LEAST this much input value.
                uint256 outValue = Math.mulDiv(p, outTok0, ONE, Math.Rounding.Ceil);
                (uint256 inValue,) = _walk(v, u, lo, hi, false, outValue);
                uint256 netIn = inValue; // token1
                uint256 grossIn = Math.mulDiv(netIn, PIPS, PIPS - swapFee, Math.Rounding.Ceil);
                feeAmount = grossIn - netIn;
                unspecifiedAmount = grossIn; // token1 in (incl. fee)
                newY = y + grossIn; // + : token1 in
                newX = x - outTok0; // − : token0 out
                dS = feeAmount;
            }
        }

        reserve0[id] = newX;
        reserve1[id] = newY;
        canonicalSize[id] = S + dS;
        _lastSwapFee = feeAmount;
    }

    /// @dev Fee amount for the most recent swap (input-token units). Used by the base only to emit the
    ///      HookSwap event; the fee is already folded into reserves by `_getUnspecifiedAmount`.
    function _getSwapFeeAmount(SwapParams calldata, uint256) internal view override returns (uint256) {
        return _lastSwapFee;
    }

    /**
     * @dev Core piecewise solver in VALUE SPACE. `Rin` is the reserve that grows, `Rout` the reserve
     *      that shrinks (both token1-value units). As `Rout` decreases it passes through up to three
     *      regions, in this order:
     *
     *        HIGH arm   (Rout > hi):  offset CPMM, offsets A=hi on Rin, B=lo on Rout.
     *        FLAT band  (lo..hi):     constant sum, price exactly 1 ⇒ dIn == dOut.
     *        LOW arm    (Rout < lo):  offset CPMM, offsets A=lo on Rin, B=hi on Rout.
     *
     *      Offset derivation (value space, peg price = 1): each arm uses (Rin+A)(Rout+B)=K and must
     *      (1) pass through its band edge and (2) have marginal value-price 1 at that edge. With wall
     *      depth L=S that gives, at the edge, Rin+A = Rout+B = S, hence A=S−Rin_edge, B=S−Rout_edge.
     *      For the LOW edge (Rin=hi, Rout=lo): A=lo, B=hi. For the HIGH edge (Rin=lo, Rout=hi): A=hi, B=lo.
     *      Both offsets are strictly positive for α<0.5, so a reserve only reaches 0 at a finite (high)
     *      price — the pool is fully drainable at escalating cost (spec §4.5). No sqrt is required.
     *
     *      K is PINNED to the actual entry point of each arm segment (K=(Rin+A)(Rout+B) from the live
     *      reserves). At a true band-edge crossing this equals S² exactly; if prior fee-folding has
     *      nudged reserves slightly off-curve, pinning still yields zero output for zero input, so no
     *      value can ever leak (the drift only ever makes the pool richer).
     *
     * @param exactInput true: `amount` is the input-value budget, fully consumed; returns produced output.
     *                    false: `amount` is the output-value target; returns required input value.
     * @return inValue  total input value moved.
     * @return outValue total output value moved.
     *
     * All rounding favors the pool: output rounded DOWN, required input rounded UP.
     */
    function _walk(uint256 Rin, uint256 Rout, uint256 lo, uint256 hi, bool exactInput, uint256 amount)
        internal
        pure
        returns (uint256 inValue, uint256 outValue)
    {
        uint256 remaining = amount;

        // ---- HIGH arm: Rout from current down to hi ----
        if (Rout > hi) {
            uint256 A = hi;
            uint256 B = lo;
            (Rin, Rout, inValue, outValue, remaining) =
                _segment(Rin, Rout, A, B, hi, false, exactInput, remaining, inValue, outValue);
            if (remaining == 0) return (inValue, outValue);
        }

        // ---- FLAT band: Rout from min(current,hi) down to lo (price 1, dIn == dOut) ----
        if (Rout > lo) {
            uint256 cap = Rout - lo; // output capacity of the flat segment
            if (exactInput) {
                if (remaining >= cap) {
                    inValue += cap;
                    outValue += cap;
                    remaining -= cap;
                    Rin += cap;
                    Rout = lo;
                } else {
                    inValue += remaining;
                    outValue += remaining;
                    return (inValue, outValue);
                }
            } else {
                if (remaining >= cap) {
                    inValue += cap;
                    outValue += cap;
                    remaining -= cap;
                    Rin += cap;
                    Rout = lo;
                } else {
                    inValue += remaining;
                    outValue += remaining;
                    return (inValue, outValue);
                }
            }
        }

        // ---- LOW arm: Rout from lo down toward 0 ----
        {
            uint256 A = lo;
            uint256 B = hi;
            (Rin, Rout, inValue, outValue, remaining) =
                _segment(Rin, Rout, A, B, 0, true, exactInput, remaining, inValue, outValue);
        }

        // Any remainder means the request exceeds what the pool can fill (full drain).
        if (remaining != 0) revert InsufficientLiquidity();
    }

    /**
     * @dev Processes one offset-CPMM arm segment as `Rout` decreases from its current value down to
     *      `bnd` (the next-lower band edge, or 0 for the final low-arm segment). K is pinned to the
     *      live (Rin,Rout). `isLast` marks the unbounded low arm (its capacity check forbids full drain).
     *      Returns updated reserves, accumulated in/out values, and the unconsumed remainder.
     */
    function _segment(
        uint256 Rin,
        uint256 Rout,
        uint256 A,
        uint256 B,
        uint256 bnd,
        bool isLast,
        bool exactInput,
        uint256 remaining,
        uint256 inAcc,
        uint256 outAcc
    ) internal pure returns (uint256, uint256, uint256, uint256, uint256) {
        uint256 K = (Rin + A) * (Rout + B); // pinned; exact 256-bit product
        uint256 outCap = Rout - bnd; // output capacity to the segment boundary

        if (exactInput) {
            // Input needed to reach the boundary: RinBnd = ceil(K/(bnd+B)) − A.
            uint256 inCap = Math.ceilDiv(K, bnd + B) - A - Rin;
            if (remaining >= inCap && !(isLast)) {
                // Fully cross this (bounded) segment.
                return (Rin + inCap, bnd, inAcc + inCap, outAcc + outCap, remaining - inCap);
            }
            if (isLast && remaining >= inCap) {
                // Would require draining the out-reserve to 0 — refuse.
                revert InsufficientLiquidity();
            }
            // Partial fill inside the segment. RoutNew rounded UP ⇒ output rounded DOWN.
            uint256 RinNew = Rin + remaining;
            uint256 RoutNew = Math.ceilDiv(K, RinNew + A) - B;
            return (RinNew, RoutNew, inAcc + remaining, outAcc + (Rout - RoutNew), 0);
        } else {
            if (remaining >= outCap) {
                if (isLast) revert InsufficientLiquidity(); // draining out-reserve to 0
                // Fully cross: input rounded UP via ceilDiv.
                uint256 inCap = Math.ceilDiv(K, bnd + B) - A - Rin;
                return (Rin + inCap, bnd, inAcc + inCap, outAcc + outCap, remaining - outCap);
            }
            // Partial fill: produce exactly `remaining` output; RinNew rounded UP ⇒ input rounded UP.
            uint256 RoutNew = Rout - remaining;
            uint256 RinNew = Math.ceilDiv(K, RoutNew + B) - A;
            return (RinNew, RoutNew, inAcc + (RinNew - Rin), outAcc + remaining, 0);
        }
    }

    // =====================================================================
    // Liquidity (pro-rata only; spec §7)
    // =====================================================================

    /**
     * @dev Pro-rata add. Rejects single-sided. First deposit sets the pool's starting inventory point
     *      and permanently locks MINIMUM_LIQUIDITY shares (inflation-attack mitigation). Persists the
     *      reserve / S increase here (called once, atomically, by `addLiquidity`).
     */
    function _getAmountIn(AddLiquidityParams memory params)
        internal
        override
        returns (uint256 amount0, uint256 amount1, uint256 shares)
    {
        if (params.amount0Desired == 0 || params.amount1Desired == 0) revert SingleSidedNotAllowed();

        PoolId id = poolKey().toId();
        uint256 ts = totalSupply();

        if (ts == 0) {
            // First deposit: take exactly the desired amounts; shares == initial value S.
            amount0 = params.amount0Desired;
            amount1 = params.amount1Desired;
            uint256 S0 = _value0(amount0) + amount1;
            if (S0 <= MINIMUM_LIQUIDITY) revert InsufficientInitialLiquidity();
            shares = S0; // MINIMUM_LIQUIDITY is split off in `_mint`
            reserve0[id] = amount0;
            reserve1[id] = amount1;
            canonicalSize[id] = S0;
        } else {
            uint256 x = reserve0[id];
            uint256 y = reserve1[id];
            // Shares limited by the scarcer side so the deposit lands in the current ratio.
            uint256 s0 = Math.mulDiv(params.amount0Desired, ts, x);
            uint256 s1 = Math.mulDiv(params.amount1Desired, ts, y);
            shares = s0 < s1 ? s0 : s1;
            if (shares == 0) revert ZeroShares();
            // Required deposit for `shares`, rounded UP (against the LP / toward the pool).
            amount0 = Math.mulDiv(shares, x, ts, Math.Rounding.Ceil);
            amount1 = Math.mulDiv(shares, y, ts, Math.Rounding.Ceil);
            reserve0[id] = x + amount0;
            reserve1[id] = y + amount1;
            canonicalSize[id] += Math.mulDiv(shares, canonicalSize[id], ts);
        }
    }

    /**
     * @dev Pro-rata remove. LPs can always exit. Amounts rounded DOWN (toward the pool). Persists the
     *      reserve / S decrease here.
     */
    function _getAmountOut(RemoveLiquidityParams memory params)
        internal
        override
        returns (uint256 amount0, uint256 amount1, uint256 shares)
    {
        shares = params.liquidity;
        if (shares == 0) revert ZeroShares();

        PoolId id = poolKey().toId();
        uint256 ts = totalSupply();
        uint256 x = reserve0[id];
        uint256 y = reserve1[id];

        amount0 = Math.mulDiv(shares, x, ts); // floor
        amount1 = Math.mulDiv(shares, y, ts); // floor

        reserve0[id] = x - amount0;
        reserve1[id] = y - amount1;
        canonicalSize[id] -= Math.mulDiv(shares, canonicalSize[id], ts);
    }

    /// @dev Mint LP shares. On the first deposit, permanently lock MINIMUM_LIQUIDITY to the dead address.
    function _mint(AddLiquidityParams memory, BalanceDelta, BalanceDelta, uint256 shares) internal override {
        if (totalSupply() == 0) {
            _mint(DEAD, MINIMUM_LIQUIDITY);
            _mint(msg.sender, shares - MINIMUM_LIQUIDITY);
        } else {
            _mint(msg.sender, shares);
        }
    }

    /// @dev Burn LP shares from the remover.
    function _burn(RemoveLiquidityParams memory, BalanceDelta, BalanceDelta, uint256 shares) internal override {
        _burn(msg.sender, shares);
    }

    // =====================================================================
    // Fixed-point helpers (vetted OZ Math.mulDiv; rounding stated at each call site)
    // =====================================================================

    /// @dev token0 amount → token1-denominated value (floor). value = p·amount0 / 1e18.
    function _value0(uint256 amount0) internal view returns (uint256) {
        return Math.mulDiv(p, amount0, ONE);
    }

    /// @dev token1-denominated value → token0 amount, with explicit rounding. amount0 = value·1e18 / p.
    function _value0Inv(uint256 value, Math.Rounding rounding) internal view returns (uint256) {
        return Math.mulDiv(value, ONE, p, rounding);
    }
}
