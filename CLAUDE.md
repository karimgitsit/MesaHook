# CLAUDE.md — Uniswap v4 hooks development

Standing conventions for this repo. Follow these on every task unless I say
otherwise in the prompt. The project knowledge / v4 reference docs are the
authoritative reference for v4 interfaces, types, and patterns.

## Environment

- Solidity `^0.8.24`.
- Foundry (`forge`, `anvil`). **Never suggest Hardhat** unless I ask.
- Tests are written in Solidity using `forge-std`.

## Code conventions

- Every hook inherits from `BaseHook` (`v4-periphery/src/utils/BaseHook.sol`),
  directly or via a base like `BaseCustomCurve`.
- Always implement `getHookPermissions()` and return **only** the flags the hook
  actually uses — never enable a permission the hook doesn't need.
- Use the internal underscore-prefixed overrides from `BaseHook` (`_beforeSwap`,
  `_afterSwap`, `_beforeInitialize`, etc.) — **not** the external `IHooks`
  functions directly.
- State that varies per-pool must be keyed by `PoolId`, **never global**.
- Use named imports: `import {Foo} from "...";` — never `import "...";`.

## Deployment

- Hook permissions are encoded in the deployed address — always use **CREATE2
  with `HookMiner`** to find a salt that produces the correct permission bits.
- Provide a deployment script (`script/Deploy<HookName>.s.sol`) for any hook.
- Test against a local anvil node with `--code-size-limit 30000`.

## Testing

- Every hook gets a matching `<HookName>.t.sol` with at least: an
  **initialization** test, a **permission-flag** test, a **happy-path callback**
  test, and **one adversarial** test (wrong caller, malicious pool key, or
  reentrancy).
- Use the v4-template test fixtures (`deployFreshManagerAndRouters`, etc.).

## Security defaults

- Verify `msg.sender == address(poolManager)` on any externally-callable
  function that should only be called by the PoolManager (`onlyPoolManager`).
- Validate the `PoolKey` on every callback if the hook is intended for a
  specific pool or set of pools.
- Treat any external call from within a hook as a reentrancy risk — use
  `ReentrancyGuard` or transient-storage locks.
- For hooks with custom accounting (returning deltas), be explicit about the
  **sign and direction** in comments.
- Flag any upgradeability or privileged-role design as a security concern in
  your response.

## Workflow

- When I describe a new hook, **first ask which lifecycle callbacks it needs**
  before writing code.
- Always show the `getHookPermissions()` return **alongside** the hook contract.
- After writing a hook, **list the security considerations specific to that
  hook's design**.
- Default to the **simplest implementation** that meets the requirement; flag
  optimizations **separately** rather than baking them in upfront.
