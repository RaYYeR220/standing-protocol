// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script, console} from "forge-std/Script.sol";
import {StandingRegistry} from "../src/StandingRegistry.sol";
import {StandingPool} from "../src/StandingPool.sol";
import {CreditManager} from "../src/CreditManager.sol";

/// @notice Deploys the protocol against the live Cleanverse stack.
/// @dev Addresses default to Monad, where the Cleanverse contracts sit at the same addresses on
///      testnet and mainnet. Override any of them with an env var to point at another chain.
contract Deploy is Script {
    address constant APASS_REGISTRY = 0xbA82D189540CaC9DC6FF46B6837CaC1BFdEC58B9;
    address constant POLICY = 0x36489bE45fa84f70a0c2BDB11D824Be608CB12Dd;
    address constant VALIDATOR = 0xaC7e5179C2C7f03f209136886c172eb34F161792;
    address constant AUSDC = 0xaC0893567D43C3E7e6e35a72803df05416C1f20D;

    /// @dev Protocol ceilings. Fixed at deployment and unraisable afterwards.
    uint256 constant MAX_LOAN_PRINCIPAL = 25_000e6;
    uint256 constant MAX_CREDIT_LINE = 50_000e6;
    uint256 constant MAX_TERM = 365 days;

    function run() external {
        address apass = vm.envOr("APASS_REGISTRY", APASS_REGISTRY);
        address policy = vm.envOr("POLICY", POLICY);
        address validator = vm.envOr("VALIDATOR", VALIDATOR);
        address asset = vm.envOr("VERIFIED_ASSET", AUSDC);

        uint256 pk = vm.envUint("PRIVATE_KEY");
        address admin = vm.addr(pk);

        vm.startBroadcast(pk);

        StandingRegistry registry = new StandingRegistry(admin);
        StandingPool pool = new StandingPool(asset, apass, policy, validator, admin);
        CreditManager manager = new CreditManager(
            address(pool),
            address(registry),
            apass,
            policy,
            validator,
            asset,
            admin,
            MAX_LOAN_PRINCIPAL,
            MAX_CREDIT_LINE,
            MAX_TERM
        );

        pool.setCreditManager(address(manager));
        registry.grantRole(registry.RECORDER_ROLE(), address(manager));

        // The credit history is the collateral, so nobody — including the deployer — may write to
        // it except through the credit manager's own accounting. Renouncing admin here is what
        // makes "an operator can make this stricter, never more generous" true rather than a
        // statement of intent: after this transaction the recorder set can no longer be changed.
        registry.renounceRole(registry.DEFAULT_ADMIN_ROLE(), admin);

        vm.stopBroadcast();

        console.log("STANDING_REGISTRY=%s", address(registry));
        console.log("STANDING_POOL=%s", address(pool));
        console.log("CREDIT_MANAGER=%s", address(manager));
        console.log("APASS_REGISTRY=%s", apass);
        console.log("POLICY=%s", policy);
        console.log("VALIDATOR=%s", validator);
        console.log("VERIFIED_ASSET=%s", asset);
    }
}
