// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "@uniswap/v4-periphery/test/shared/HookMiner.sol";

import {MesaHook} from "../src/MesaHook.sol";

/**
 * @title DeployMesaHook
 * @notice CREATE2 + HookMiner deployment for a single MesaHook pool instance.
 *
 * In Uniswap v4 a hook's permission flags are encoded in the LOW BITS of its address. The
 * PoolManager reads those bits, so a hook only works if it is deployed to an address whose
 * bottom 14 bits exactly equal its `getHookPermissions()` bitmap. We therefore mine a CREATE2
 * salt (HookMiner) that yields such an address, then deploy with it.
 *
 * MesaHook is single-instance-per-pool, so run this once per pool with that pool's p/alpha/fee.
 *
 * NOTE: a MesaHook deployment exceeds the default contract size limit. Run a local node with the
 * raised limit:
 *
 *     anvil --code-size-limit 30000
 *
 * and deploy against it, e.g.:
 *
 *     forge script script/DeployMesaHook.s.sol \
 *         --rpc-url http://localhost:8545 --broadcast \
 *         --code-size-limit 30000 --private-key <KEY>
 *
 * Configure the pool via environment variables (with sensible defaults for two 18-dp 1:1 stables):
 *     POOL_MANAGER  address of the deployed v4 PoolManager (required)
 *     PEG_PRICE     p, token1-per-token0 ×1e18, decimal-adjusted (default 1e18)
 *     ALPHA         band parameter ×1e18, in (0, 0.5e18)        (default 0.1e18)
 *     FEE           flat swap fee in pips                        (default 100 = 0.01%)
 */
contract DeployMesaHook is Script {
    /// @dev The canonical deterministic CREATE2 factory (same address on every chain). HookMiner
    ///      must mine against this exact deployer for the mined address to be valid at broadcast.
    address internal constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    function run() external returns (MesaHook hook) {
        IPoolManager manager = IPoolManager(vm.envAddress("POOL_MANAGER"));
        uint256 p = vm.envOr("PEG_PRICE", uint256(1e18));
        uint256 alpha = vm.envOr("ALPHA", uint256(1e17)); // 0.1e18
        uint24 fee = uint24(vm.envOr("FEE", uint256(100))); // 0.01%

        // The exact permission bitmap MesaHook declares in getHookPermissions().
        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
                | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
        );

        bytes memory constructorArgs = abi.encode(manager, p, alpha, fee, "Mesa LP", "MESA-LP");

        // Mine a salt whose CREATE2 address has exactly `flags` in its low bits.
        (address hookAddress, bytes32 salt) =
            HookMiner.find(CREATE2_DEPLOYER, flags, type(MesaHook).creationCode, constructorArgs);

        vm.startBroadcast();
        hook = new MesaHook{salt: salt}(manager, p, alpha, fee, "Mesa LP", "MESA-LP");
        vm.stopBroadcast();

        require(address(hook) == hookAddress, "DeployMesaHook: mined address mismatch");

        console2.log("MesaHook deployed at:", address(hook));
        console2.log("  p     :", p);
        console2.log("  alpha :", alpha);
        console2.log("  fee   :", fee);
    }
}
