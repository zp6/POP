// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import {OrgDeployer} from "../../src/OrgDeployer.sol";
import {PoaManagerHub} from "../../src/crosschain/PoaManagerHub.sol";
import {PoaManager} from "../../src/PoaManager.sol";
import {DeterministicDeployer} from "../../src/crosschain/DeterministicDeployer.sol";

/*
 * ============================================================================
 * OrgDeployer v11 — createTasksBatch in default paymaster whitelist
 * ============================================================================
 *
 * Upgrades OrgDeployer so the default paymaster ruleset emitted by deployFullOrg
 * includes TaskManager.createTasksBatch (selector 0xc18aa1c9). Forward-only:
 * existing orgs are unaffected (they need AddCreateTasksBatchSelectorRules.s.sol).
 *
 * Previous version was v10 (UpgradeOrgDeployerEduRules.s.sol).
 *
 * Deployment flow (mirrors UpgradeOrgDeployerEduRules):
 *   1. Step1_DeployOnGnosis      — deploy impl on Gnosis via DD
 *   2. Step2_UpgradeFromArbitrum — deploy on Arbitrum via DD + cross-chain beacon upgrade
 *   3. Step3_Verify              — confirm Gnosis picked up the upgrade after Hyperlane relay
 *
 * Commands:
 *   source .env && FOUNDRY_PROFILE=production forge script \
 *     script/upgrades/UpgradeOrgDeployerCreateTasksBatch.s.sol:Step1_DeployOnGnosis \
 *     --rpc-url gnosis --broadcast --slow --private-key $DEPLOYER_PRIVATE_KEY
 *
 *   source .env && FOUNDRY_PROFILE=production forge script \
 *     script/upgrades/UpgradeOrgDeployerCreateTasksBatch.s.sol:Step2_UpgradeFromArbitrum \
 *     --rpc-url arbitrum --broadcast --slow --private-key $DEPLOYER_PRIVATE_KEY
 *
 *   FOUNDRY_PROFILE=production forge script \
 *     script/upgrades/UpgradeOrgDeployerCreateTasksBatch.s.sol:Step3_Verify \
 *     --rpc-url gnosis
 * ============================================================================
 */

address constant DD = 0x4aC8B5ebEb9D8C3dE3180ddF381D552d59e8835a;
address constant HUB = 0xB72840B343654eAfb2CFf7acC4Fc6b59E6c3CC71;
address constant GNOSIS_POA_MANAGER = 0x794fD39e75140ee1545B1B022E5486B7c863789b;
uint256 constant HYPERLANE_FEE = 0.005 ether;
string constant VERSION = "v11";

contract Step1_DeployOnGnosis is Script {
    function run() public {
        uint256 deployerKey = vm.envOr("PRIVATE_KEY", vm.envUint("DEPLOYER_PRIVATE_KEY"));
        address deployer = vm.addr(deployerKey);

        DeterministicDeployer dd = DeterministicDeployer(DD);
        bytes32 salt = dd.computeSalt("OrgDeployer", VERSION);
        address predicted = dd.computeAddress(salt);

        console.log("\n=== Step 1: Deploy OrgDeployer v11 on Gnosis ===");
        console.log("Deployer: ", deployer);
        console.log("Predicted:", predicted);

        if (predicted.code.length > 0) {
            console.log("Already deployed. Skipping.");
            return;
        }

        vm.startBroadcast(deployerKey);
        address deployed = dd.deploy(salt, type(OrgDeployer).creationCode);
        vm.stopBroadcast();

        require(deployed == predicted, "Address mismatch");
        console.log("Deployed:", deployed);
        console.log("\nNext: Run Step2_UpgradeFromArbitrum on Arbitrum");
    }
}

contract Step2_UpgradeFromArbitrum is Script {
    function run() public {
        uint256 deployerKey = vm.envOr("PRIVATE_KEY", vm.envUint("DEPLOYER_PRIVATE_KEY"));
        address deployer = vm.addr(deployerKey);

        PoaManagerHub hub = PoaManagerHub(payable(HUB));
        DeterministicDeployer dd = DeterministicDeployer(DD);

        console.log("\n=== Step 2: Upgrade OrgDeployer from Arbitrum ===");
        require(hub.owner() == deployer, "Deployer must own Hub");
        require(!hub.paused(), "Hub is paused");

        bytes32 salt = dd.computeSalt("OrgDeployer", VERSION);
        address impl = dd.computeAddress(salt);
        console.log("OrgDeployer v11 impl:", impl);

        vm.startBroadcast(deployerKey);

        if (impl.code.length == 0) {
            address deployed = dd.deploy(salt, type(OrgDeployer).creationCode);
            require(deployed == impl, "Address mismatch on Arbitrum");
            console.log("Deployed on Arbitrum");
        } else {
            console.log("Already deployed on Arbitrum");
        }

        hub.upgradeBeaconCrossChain{value: HYPERLANE_FEE}("OrgDeployer", impl, VERSION);
        console.log("Beacon upgrade dispatched (Arbitrum local + Gnosis cross-chain)");

        vm.stopBroadcast();

        address pm = address(hub.poaManager());
        address current = PoaManager(pm).getCurrentImplementationById(keccak256("OrgDeployer"));
        require(current == impl, "Arbitrum impl not upgraded");
        console.log("Arbitrum upgrade: PASS");
        console.log("\nWait ~5 min for Hyperlane relay, then run Step3_Verify on Gnosis");
    }
}

contract Step3_Verify is Script {
    function run() public view {
        DeterministicDeployer dd = DeterministicDeployer(DD);
        address expected = dd.computeAddress(dd.computeSalt("OrgDeployer", VERSION));
        address current = PoaManager(GNOSIS_POA_MANAGER).getCurrentImplementationById(keccak256("OrgDeployer"));

        console.log("\n=== Verify Gnosis OrgDeployer Upgrade ===");
        console.log("Expected:", expected);
        console.log("Current: ", current);
        if (current == expected) {
            console.log("PASS: OrgDeployer v11 live on Gnosis");
            console.log("New orgs deployed from now on auto-whitelist createTasksBatch (0xc18aa1c9)");
        } else {
            console.log("WAITING: Hyperlane message not yet relayed.");
        }
    }
}

/**
 * @title SimulateOrgDeployerUpgrade
 * @notice Fork-simulates the upgrade end-to-end on Arbitrum: deploys v11 via DD,
 *         calls upgradeBeaconCrossChain, verifies Arbitrum impl switched.
 *         Does NOT verify Gnosis (that requires cross-chain relay).
 *
 * Usage:
 *   FOUNDRY_PROFILE=production forge script \
 *     script/upgrades/UpgradeOrgDeployerCreateTasksBatch.s.sol:SimulateOrgDeployerUpgrade \
 *     --rpc-url arbitrum
 */
contract SimulateOrgDeployerUpgrade is Script {
    function run() public {
        uint256 deployerKey = vm.envOr("PRIVATE_KEY", vm.envUint("DEPLOYER_PRIVATE_KEY"));
        address deployer = vm.addr(deployerKey);

        PoaManagerHub hub = PoaManagerHub(payable(HUB));
        DeterministicDeployer dd = DeterministicDeployer(DD);
        address pm = address(hub.poaManager());

        console.log("\n=== SIM: OrgDeployer v11 upgrade (Arbitrum fork) ===");
        console.log("Deployer:", deployer);

        address before = PoaManager(pm).getCurrentImplementationById(keccak256("OrgDeployer"));
        console.log("Current impl:", before);

        bytes32 salt = dd.computeSalt("OrgDeployer", VERSION);
        address predicted = dd.computeAddress(salt);
        console.log("Predicted v11:", predicted);

        vm.deal(deployer, 1 ether);
        vm.startPrank(deployer);

        if (predicted.code.length == 0) {
            address deployed = dd.deploy(salt, type(OrgDeployer).creationCode);
            require(deployed == predicted, "Address mismatch");
            console.log("v11 deployed at:", deployed);
        }

        hub.upgradeBeaconCrossChain{value: HYPERLANE_FEE}("OrgDeployer", predicted, VERSION);

        vm.stopPrank();

        address after_ = PoaManager(pm).getCurrentImplementationById(keccak256("OrgDeployer"));
        console.log("New impl:", after_);
        require(after_ == predicted, "Upgrade failed");
        require(after_.code.length > 0, "Impl has no code");
        console.log("New impl codesize:", after_.code.length, "bytes");
        console.log("\nArbitrum upgrade simulation: PASS");
    }
}
