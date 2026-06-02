# MesaHook

A Uniswap v4 hook that makes an AMM behave like a **flat-topped plateau** — a *mesa*.

## What it is

MesaHook is a custom-curve hook for **pegged or tightly correlated token pairs** (think
stablecoin/stablecoin, or an LST and its underlying). It replaces Uniswap's default
concentrated-liquidity math with a two-part curve:

- **In the band (the flat top):** a **constant-sum** market maker. Trades happen at a fixed
  peg price `p` with **zero slippage**. While the pool's inventory is reasonably balanced, a
  swap of pegged assets trades exactly 1:1 (at `p`), like swapping nickels for dimes.

- **Outside the band (the steep sides):** a **constant-product** curve (offset so it joins the
  flat top smoothly — no price jump at the edge). As the pool becomes lopsided, price moves
  increasingly against further swaps in that direction, protecting the remaining reserves.

```
price
  ^
  |          flat top = constant-sum at peg p (zero slippage)
  |        ___________________________________
  |       /                                   \
  |      / steep side                steep side \   <- constant-product "walls"
  |_____/_____________________________________ \_____> inventory (token1 share)
        α·S                                  (1-α)·S
```

## Why it's called "Mesa"

A **mesa** is a landform with a **flat top and steep cliff sides**. That is exactly the shape
of this curve: a flat, constant-price top between the band edges, dropping off into steep
constant-product walls on either side. The name is the picture.

## The benefit

- **Zero slippage at the peg.** Inside the band, traders get the exact peg price with no curve
  slippage — far better execution than a plain `x*y=k` pool for assets that should trade ~1:1.
- **Capital efficiency.** Liquidity is concentrated at the price that matters (`p`) instead of
  being smeared across all prices.
- **Graceful edges.** When inventory gets lopsided, the curve smoothly stiffens into a
  constant-product wall instead of running dry at a fixed price, so the pool isn't trivially
  drained and price stays continuous across the band edge.
- **Trust-minimized & immutable.** No admin, no upgrade, no pause, no oracle. Config is fixed
  at deployment and LPs can always withdraw.

## Configurable variables

All three are set **once, at deployment** (constructor), and are then **immutable**:

| Variable | Type | What it does |
|----------|------|--------------|
| `p` | `uint256` (1e18 fixed-point) | The **peg price**: how many token1 *base units* equal one token0 *base unit*, ×1e18. This must fold in the tokens' decimals. |
| `alpha` | `uint256` (1e18 fixed-point) | The **band width**, in `(0, 0.5e18)`. The pool is in the flat zero-slippage zone while token1's value share stays within `[alpha, 1-alpha]`. Smaller `alpha` = narrower flat top / wider walls; larger `alpha` (toward 0.5) = wider flat top. |
| `fee` | `uint24` (pips, 1e-6) | The **flat swap fee**, charged on the input token everywhere (including in-band). May be `0`. Fees accrue to LPs. e.g. `100` = 0.01%, `3000` = 0.30%. |

> There is **no** wall-steepness knob in v1 — the wall depth is fixed by a deterministic rule
> (`L = S`, scaling with pool size). Keeping config to just `p`, `alpha`, `fee` is intentional.

### Setting `p` (the decimals formula)

`p` is **token1 base units per token0 base unit, ×1e18**:

```
p = economic_price(token1 per token0) × 1e18 × 10^(decimals1 - decimals0)
```

Examples (economic 1:1 peg):
- Two 18-decimal stablecoins → `p = 1e18`.
- token0 = USDC (6 dp), token1 = DAI (18 dp) → `p = 1e18 × 10^(18-6) = 1e30`.

## Liquidity

- **Pro-rata only.** Deposits must be in the pool's current reserve ratio; single-sided adds
  are rejected. The **first deposit sets where the pool starts** and permanently locks a tiny
  amount of liquidity (`MINIMUM_LIQUIDITY = 1000` shares) to neutralize the first-depositor
  inflation attack.
- **Always withdrawable.** Removing liquidity returns your pro-rata share of the reserves plus
  accrued fees. Nothing can brick withdrawal.
- LP shares are an ERC-20 minted by the hook itself (one share token per pool).

## Important safety notes

- **Custodial, highest-risk tier.** The hook holds the pool's reserves (as v4 ERC-6909 claims).
  Immutability + always-available withdrawal minimize trust, but this is not non-custodial.
  Fuzz + a third-party audit are mandatory before mainnet.
- **No rebasing / fee-on-transfer tokens.** They mutate balances out from under the curve's
  invariant and silently break accounting. Use wrapped, non-rebasing tokens (e.g. wstETH, never
  raw stETH). This is a usage requirement — it cannot be reliably enforced on-chain.
- **Boundary-crossing swaps are split.** A swap can start in-band and cross an edge; it is
  filled in two pieces (flat part at `p`, then along the wall) within a single swap.
- **Keyless depeg, by design.** There is no circuit breaker. If the assets genuinely depeg, the
  pool parks at a band edge and is repriced by arbitrageurs — **LPs bear the loss**.
- **One hook instance per pool.** Deploy a freshly-mined hook (see `script/DeployMesaHook.s.sol`)
  for each pool, with that pool's `p` / `alpha` / `fee`.

## Build & test

```bash
forge build
# The hook bytecode exceeds the default EVM code-size limit, so tests (which deploy it
# in-EVM) and any local node must raise it:
forge test --code-size-limit 30000
anvil --code-size-limit 30000
```

## Layout

```
src/MesaHook.sol                 the hook
script/DeployMesaHook.s.sol      CREATE2 + HookMiner deployment (one instance per pool)
test/MesaHook.t.sol              full test suite (incl. the no-leakage fuzz invariant)
SPEC-ExactPegBandHook.md         the authoritative design spec MesaHook implements
```
