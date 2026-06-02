# ExactPegBandHook — Design Specification

A Uniswap v4 hook implementing a **piecewise AMM curve**: inside an inventory
band it is a **constant-sum** market maker (exact peg price `p`, **zero
slippage**); outside the band it switches to an **offset constant-product**
curve that is **C1-continuous** with the flat segment (no price jump at the
boundary). Intended for **pegged / correlated assets** (e.g. stablecoin pairs).

> **Status:** specification only. This document is the authoritative reference
> for behavior, math, and invariants. Implementation is to follow in Claude
> Code against the project's existing conventions (`house-style.md` and the v4
> reference docs in project knowledge).

---

## 1. Summary of locked decisions

| # | Decision | Value |
|---|----------|-------|
| 1 | Pinned price `p` | **Fixed static constant**, set by deployer at init. No oracle. Stablecoin pairs. |
| 2 | Boundary-crossing swaps | **Split** in one `beforeSwap`: fill in-band at `p`, then continue along the arm. Flagged in README. |
| 3 | Governance | **Fully immutable.** Deployer configures `p`, band `α`, `fee` at init; no admin, no upgrade, no pause. LPs can always withdraw. |
| 4 | Depeg posture | **Keyless ride.** No circuit breaker. On a real depeg, LPs bear loss by design; arbitrageurs reprice the pool. |
| 5 | LP deposits | **Pro-rata only** (deposit in current reserve ratio). Single-sided is out of scope. Flagged in README. |
| 6 | Fee | **Flat, deployer-configurable**, charged everywhere (including in-band). Deployer may set it to `0`. |
| 7 | Scope | **Multi-pool primitive.** Anyone may initialize a pool with this hook; per-pool config from `hookData`, all state keyed by `PoolId`. |

**Custody note:** this is a **trust-minimized custodial** hook. The hook holds
reserves as ERC-6909 claim tokens while liquidity is in the pool. Immutability +
no admin + always-available withdrawal minimize trust, but this is *not*
non-custodial. Treat it as the highest-risk hook tier: fuzz + third-party audit
before mainnet.

---

## 2. Base contract & lifecycle callbacks

Inherit from **`BaseCustomCurve`** (`v4-periphery` / OpenZeppelin Uniswap Hooks),
which extends `BaseCustomAccounting` → `BaseHook`. This replaces the
PoolManager's native concentrated-liquidity math with our curve and routes all
liquidity through the hook.

`getHookPermissions()` must return **exactly** this set (the `BaseCustomCurve`
group — only the flags actually used):

```solidity
beforeInitialize:               true   // decode + validate + store per-pool config
beforeAddLiquidity:             true   // intercept; route through hook (pro-rata)
beforeRemoveLiquidity:          true   // intercept; route through hook
beforeSwap:                     true   // run the piecewise curve
beforeSwapReturnDelta:          true   // return the BeforeSwapDelta that overrides swap output
// everything else false:
afterInitialize, afterAddLiquidity, afterRemoveLiquidity, afterSwap,
beforeDonate, afterDonate, afterSwapReturnDelta,
afterAddLiquidityReturnDelta, afterRemoveLiquidityReturnDelta
```

No `afterSwap` and no oracle reads are needed because `p` is static.

---

## 3. Notation & per-pool state

- `token0`, `token1` — pool currencies (sorted, as v4 requires).
- `p` — **price of `token0` denominated in `token1`**, as a `1e18` fixed-point
  value. `1 token0 = p / 1e18 token1` in economic terms. **Must incorporate
  decimal scaling** (see §8). For two 18-decimal stablecoins at 1:1, `p = 1e18`.
- `x`, `y` — **principal reserves** of `token0`, `token1` that the curve math
  operates on (held by the hook as claim tokens). Distinct from accrued fees.
- `S` — **canonical pool size**: the constant-sum total at peg of the *flat
  segment*, `S = p·x + y` evaluated **on the flat segment**. Stored per pool.
  `S` is fixed by swaps and changes **only** on add/remove liquidity (and, if
  fees are folded into principal — see §6 — by the fee amount).
- `α` — **band parameter** in `(0, 0.5)`, fixed-point `1e18`. The pool is
  in-band while `token1`'s value share is within `[α, 1−α]`, i.e.
  `α·S ≤ y ≤ (1−α)·S` (equivalently `α·S ≤ p·x ≤ (1−α)·S`).
- `fee` — flat swap fee, `uint24` in pips (1e-6), deployer-set, may be `0`.

**Per-pool config struct, keyed by `PoolId`, set once at `beforeInitialize`,
immutable thereafter:**

```solidity
struct PoolConfig {
    uint256 p;       // 1e18 fixed-point, token1 per token0 (decimal-adjusted)
    uint256 alpha;   // 1e18 fixed-point, in (0, 0.5e18)
    uint24  fee;     // pips
    bool    set;     // guard against re-init / unconfigured pools
}
mapping(PoolId => PoolConfig) internal _config;
mapping(PoolId => uint256)    internal _S;     // canonical size, see §6
```

All config arrives via `hookData` on `initialize` and is decoded in
`beforeInitialize`. Validate: `set == false` (not already configured),
`0 < alpha < 0.5e18`, `p > 0`. Revert otherwise.

---

## 4. The curve

### 4.1 In-band — constant sum (exact peg, zero slippage)

While `α·S ≤ y ≤ (1−α)·S`, the invariant is:

```
p·x + y = S          (constant)
```

Marginal price is exactly `p` everywhere on this segment → **zero slippage**.
For an exact-input swap of `dIn` (pre-fee) of the input token, the pre-fee output
is:

- selling `token0` (zeroForOne): `dOut(token1) = p · dIn / 1e18`
- selling `token1`: `dOut(token0) = dIn · 1e18 / p`

Selling `token0` decreases `y` toward the lower edge `y = α·S`; selling `token1`
increases `y` toward the upper edge `y = (1−α)·S`.

### 4.2 Band edges

- **Lower edge** `E_low` (`token1` scarce / `token0` abundant): `y = α·S`,
  `x = (1−α)·S / p`.
- **Upper edge** `E_high` (`token1` abundant / `token0` scarce): `y = (1−α)·S`,
  `x = α·S / p`.

### 4.3 Out-of-band — offset constant product (C1-continuous)

Each arm uses an offset CPMM with virtual-reserve offsets `(a, b)` and constant
`k = L²`:

```
(x + a)·(y + b) = L²
marginal price (token0 in token1) = (y + b) / (x + a)
```

Offsets are chosen so the arm (1) passes through its band edge and (2) has
marginal price **exactly `p`** at that edge → continuity of both reserves and
price (C1, no jump). Using virtual-reserve form with liquidity `L`:

For an edge at point `(x_e, y_e)`:

```
a = L / sqrt(p)  −  x_e
b = L · sqrt(p)  −  y_e
k = L²
```

Verify at the edge: `x_e + a = L/√p`, `y_e + b = L√p`, product `= L²` ✓, price
`= (L√p)/(L/√p) = p` ✓. (Work in `1e18` fixed point; `sqrt(p)` via a
fixed-point sqrt. Be careful with rounding — see §7.)

- **Lower arm** (used when `y < α·S`): offsets from `E_low`. As `y` falls
  further, price `(y+b)/(x+a)` falls below `p` (token0 gets cheaper as it floods
  in). Correct direction.
- **Upper arm** (used when `y > (1−α)·S`): offsets from `E_high`. As `y` rises,
  price rises above `p` (token0 gets more expensive as it gets scarce). Correct
  direction.

### 4.4 Wall depth `L`

`L` controls how steeply price departs from `p` outside the band (the "hardness"
of the wall). It is the one remaining degree of freedom.

- **v1 decision:** fix `L` by a deterministic rule, **not** a deployer param
  (keep config to `p, α, fee` per the simplest-first principle).
- **Default rule:** `L = S / (2·sqrt(p))`. This makes the arm's virtual
  liquidity scale with pool size and gives a moderate wall. Recompute `L` from
  current `S` whenever a swap touches an arm; **hold it fixed for the duration
  of a single swap** (see §5).
- **Flagged optimization:** exposing `L` (or a wall-steepness multiplier) as a
  4th immutable deployer param. Document, don't build, in v1.

### 4.5 Property: arms make extraction costlier but do NOT make the pool undrainable

With `b > 0` (which the default rule yields for `α < 0.5`), a reserve can reach
`0` at a **finite (high) price**, i.e. the pool is fully drainable at escalating
cost — same spirit as a plain CPMM, which is only asymptotically un-drainable.
This is consistent with the keyless depeg posture (decision #4) but **must be
documented** so LPs/auditors understand the tail.

---

## 5. Swap algorithm (the boundary-split — primary bug surface)

A single swap may begin in-band and push reserves across an edge. Handle it in
**one** `_beforeSwap`, in two pieces, against a curve **fixed at swap entry**
(compute `S`, edges, and `L` from pre-swap state; do not recompute mid-swap):

1. Determine direction (`zeroForOne`), and exact-input vs exact-output
   (`params.amountSpecified` sign).
2. Locate current region from pre-swap `(x, y, S)`.
3. **In-band fill:** fill along constant-sum at price `p` until either the swap
   is satisfied or reserves reach the relevant edge (`y = α·S` or `(1−α)·S`).
4. **Arm fill:** if amount remains, continue along the offset-CPMM arm
   (solve the arm invariant for the remaining input/output).
5. Sum the two pieces → total `unspecifiedAmount`.
6. Apply fee (§6), build the `BeforeSwapDelta`, and `take`/`settle` via the
   `BaseCustomCurve` pattern (see `BaseCustomCurve.sol` in project knowledge —
   exact-input vs exact-output `take`/`settle` ordering and delta signs).
7. Update stored principal reserves `(x, y)` to post-swap values on the curve.

Support **both exact-input and exact-output**. Exact-output in-band is the
symmetric inverse; exact-output crossing an edge splits the same way.

**Delta sign convention (document inline in code):** the returned
`BeforeSwapDelta` packs `(specifiedDelta, unspecifiedDelta)`; follow the exact
sign pattern in `BaseCustomCurve._beforeSwap` (specified positive when taken
from the pool's claim balance, unspecified negative when settled out, and the
mirror for exact-output). Every delta sign must carry a comment stating its
direction.

---

## 6. Fees & the canonical-size invariant

- Fee is charged on the **input** token, `fee` pips, everywhere (in-band too).
- Fees are accounted via `BaseCustomCurve`'s **separate** fee mechanism
  (`_getSwapFeeAmount` + the `feesAccrued` delta) so they **do not perturb the
  swap curve's principal reserves**. Principal reserves move only along the
  fixed `S`-curve; `S` changes only on add/remove liquidity.
- **No-leakage invariant (MUST hold, MUST be fuzz-tested):** a swap immediately
  followed by its reverse must never return *more* than was put in (net of
  fees). Round-trips lose only the fee, never extract principal. This is the
  single most important correctness property of the curve and the boundary
  split.

> **Implementation watch-point:** keeping principal reserves, accrued fees, and
> `S` mutually consistent is the trickiest part. If at any point principal
> reserves drift off the `S`-curve, round-trip leakage becomes possible. The
> fee/principal separation above is the recommended approach; whatever the
> implementation, it must satisfy the no-leakage fuzz test.

---

## 7. Liquidity

- **Add (pro-rata only):** deposits must be in the current reserve ratio.
  Compute `shares` proportional to value added (`p·Δx + Δy`) over `S`; increase
  `x`, `y`, and `S` proportionally; mint shares. Single-sided is **rejected** in
  v1.
- **Remove:** burn shares; return `x`, `y` pro-rata; decrease `S`. LPs can
  **always** exit (no condition bricks withdrawal — verify in tests).
- **Native liquidity blocked:** `beforeAddLiquidity` / `beforeRemoveLiquidity`
  revert direct PoolManager liquidity modification (inherited
  `BaseCustomCurve` behavior); all liquidity flows through the hook's own
  add/remove entry points.
- **First-depositor / share-inflation attack:** because shares are minted on
  deposit, this is exposed to the classic ERC-4626-style first-deposit inflation
  attack. **Mitigate** with a minimum initial liquidity that is permanently
  locked (burned shares) or a virtual-shares/virtual-reserves offset. Pick one,
  document it, and add a test that the attack fails.
- The **initial deposit sets the pool's starting inventory point** within (or
  outside) the band — document that the initializer chooses where the pool
  starts.

---

## 8. Decimals & fixed-point

- Stablecoin pairs frequently mix decimals (e.g. USDC 6 / DAI 18). `p` must
  fold the decimal ratio into the price so that `p·x + y = S` is dimensionally
  consistent. Define `p` as **token1 base units per token0 base unit, ×1e18**.
  Example: USDC(6)→token0, DAI(18)→token1 at economic 1:1 ⇒
  `p = 1e18 · 10^(18-6) = 1e30`. Document the formula the deployer must use.
- Use a vetted fixed-point library for `mulDiv` and `sqrt` (e.g. Solady /
  Solmate / OZ `Math.mulDiv`, `FixedPointMathLib.sqrt`). Pin rounding
  **against** the swapper / **toward** the pool on every step so rounding can
  never create extractable value (ties into §6 no-leakage).

---

## 9. Security considerations (specific to this hook)

1. **Trust-minimized custodial, highest-risk tier.** Holds funds + returns
   deltas → fuzz + third-party audit mandatory before mainnet.
2. **Accounting / no-leakage.** The boundary split and fee/principal separation
   are the core risk. Fuzz round-trips and multi-hop paths across the band
   edges; assert no principal extraction.
3. **`onlyPoolManager` on every callback.** Inherited via `BaseHook`; confirm
   `_beforeSwap` etc. are only reachable from the PoolManager.
4. **No specific-pool `PoolKey` restriction (by design).** This is a public
   primitive; any pool may use it. Safety comes from per-`PoolId` config + state
   isolation, not from whitelisting a key. Verify state cannot bleed across
   pools.
5. **Decimal / rounding correctness.** Wrong `p` scaling or loose rounding =
   silent value leak. Test with mixed-decimal pairs.
6. **Rebasing / fee-on-transfer tokens break the invariant.** Reserves change
   out from under `p·x + y = S`. **Forbid** them; document (e.g. use wstETH,
   never raw stETH). Consider rejecting at init if detectable; at minimum
   document loudly.
7. **Reentrancy.** All token movement happens via `take`/`settle` inside the v4
   lock; no external calls beyond the configured tokens. Still treat token
   transfers as untrusted; the rebasing/FoT ban covers the worst cases.
8. **Depeg (keyless, by design).** On a real depeg the pool parks at a band edge
   and bleeds to arbitrageurs; LPs bear it. No breaker. Document as a known,
   accepted tail risk.
9. **Immutability.** No admin, no upgrade, no pause. Config fixed at init →
   minimal centralization risk. This is a feature; do not add knobs in v1.
10. **First-deposit inflation attack.** See §7 — mitigate and test.

---

## 10. Deliverables & repo layout

```
src/ExactPegBandHook.sol
script/DeployExactPegBandHook.s.sol
test/ExactPegBandHook.t.sol
README section (see §11)
```

### Conventions (from project house style)

- Solidity `^0.8.24`; Foundry only (no Hardhat).
- Inherit `BaseCustomCurve` (→ `BaseHook`).
- Override the **internal** `_beforeSwap`, `_beforeInitialize`, etc. — never the
  external `IHooks` functions.
- **Named imports only** (`import {Foo} from "...";`).
- All per-pool state keyed by `PoolId`; nothing global.
- `getHookPermissions()` returns only the flags in §2.

### Deployment

- **CREATE2 + `HookMiner`** to mine a salt producing an address whose low bits
  encode exactly the permissions in §2. Provide
  `script/DeployExactPegBandHook.s.sol`.
- Test/deploy against local anvil with `--code-size-limit 30000`.

---

## 11. Test plan (`test/ExactPegBandHook.t.sol`)

Use v4-template fixtures (`deployFreshManagerAndRouters`, deploy hook to a mined
address, etc.). Required tests:

1. **Initialization** — config decoded & stored from `hookData`; re-init
   reverts; invalid `alpha`/`p` revert.
2. **Permission flags** — `getHookPermissions()` matches §2 exactly; deployed
   address low bits match.
3. **Happy path, in-band** — a swap fully inside the band executes at **exactly
   `p`** (zero slippage), minus fee; reserves and `S` consistent afterward.
4. **Boundary-crossing split** — a swap that starts in-band and crosses an edge
   is filled in two pieces; output equals in-band piece at `p` plus arm piece;
   price is continuous across the edge (no jump).
5. **Adversarial (≥1):**
   - wrong caller — direct call to a callback from a non-PoolManager reverts;
   - native liquidity modification reverts (must route through hook);
   - **no-leakage fuzz** — random swap then exact reverse never returns more
     than input net of fees (the §6 invariant);
   - first-deposit inflation attack fails (the §7 mitigation holds).
6. **LP lifecycle** — pro-rata add mints correct shares; remove returns
   pro-rata; single-sided add reverts; LPs can always exit.
7. **Fee = 0** — pool behaves correctly with zero fee.
8. **Mixed decimals** — a 6/18 pair with correctly scaled `p` swaps at the right
   economic rate.

Property/fuzz tests (Echidna/Medusa or Foundry invariant tests) on the
no-leakage invariant are strongly recommended beyond the unit tests above.

---

## 12. Out of scope for v1 (flagged optimizations)

- Oracle / dynamic `p` (only needed for accruing assets; this is static-peg).
- Deployer-configurable wall depth `L`.
- Single-sided liquidity.
- Any pause / circuit breaker / admin.
- Dynamic or in-band-vs-out-of-band differentiated fees.
