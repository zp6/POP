// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "forge-std/console.sol";

/*
 * ============================================================================
 * Add createTasksBatch selector to existing org paymaster whitelists
 * ============================================================================
 *
 * Companion to UpgradeTaskManagerCreateTasksBatch.s.sol (PR #151), which
 * upgraded the TaskManager beacon impl on Gnosis + Arbitrum. The new
 * createTasksBatch selector (0xc18aa1c9) is now live on the impl, but the
 * three existing orgs still need it added to their PaymasterHub rule sets so
 * 4337/passkey users do not hit RuleDenied(TaskManager, 0xc18aa1c9).
 *
 * Each org is updated on the chain it lives on:
 *   - Poa   (Arbitrum) — Hub.adminCall(ARB_PM, setRulesBatch)
 *   - KUBI  (Gnosis)   — Satellite.adminCall(GNOSIS_PM, setRulesBatch)
 *   - Test6 (Gnosis)   — Satellite.adminCall(GNOSIS_PM, setRulesBatch)
 *
 * The Hub on Arbitrum and the Satellite on Gnosis are both owned by the same
 * deployer EOA, so all four rule writes use that single signer.
 *
 * Deployer / Hub.owner / Satellite.owner: 0xA6F4D9f44Dd980b7168D829d5f74c2b00a46b2c9
 *
 * TaskManager addresses resolved via subgraph (Organization.taskManager.id) —
 * see CLAUDE.md "Subgraph (live deployment lookups)".
 *
 * Usage (sims — run these first):
 *   forge script script/fixes/AddCreateTasksBatchSelectorRules.s.sol:SimAddBatchSelectorArbitrum --fork-url arbitrum -vvv
 *   forge script script/fixes/AddCreateTasksBatchSelectorRules.s.sol:SimAddBatchSelectorGnosis  --fork-url gnosis  -vvv
 *
 * Usage (broadcast):
 *   source .env && forge script script/fixes/AddCreateTasksBatchSelectorRules.s.sol:BroadcastAddBatchSelectorPoa     --rpc-url arbitrum --broadcast --slow
 *   source .env && forge script script/fixes/AddCreateTasksBatchSelectorRules.s.sol:BroadcastAddBatchSelectorGnosis  --rpc-url gnosis  --broadcast --slow
 * ============================================================================
 */

interface IHub {
    function adminCall(address target, bytes calldata data) external returns (bytes memory);
    function owner() external view returns (address);
}

interface IPoaManagerSatellite {
    function adminCall(address target, bytes calldata data) external returns (bytes memory);
    function owner() external view returns (address);
    function poaManager() external view returns (address);
}

interface IPM {
    struct Rule {
        uint32 maxCallGasHint;
        bool allowed;
    }

    function getRule(bytes32 orgId, address target, bytes4 sel) external view returns (Rule memory);
}

// ─── Shared infra addresses ──────────────────────────────────────────────────
address constant DEPLOYER = 0xA6F4D9f44Dd980b7168D829d5f74c2b00a46b2c9;
address constant HUB = 0xB72840B343654eAfb2CFf7acC4Fc6b59E6c3CC71; // PoaManagerHub on Arbitrum
address constant ARB_PM = 0xD6659bCaFAdCB9CC2F57B7aE923c7F1Ca4438a11; // PaymasterHub on Arbitrum
address constant GNOSIS_PM = 0xdEf1038C297493c0b5f82F0CDB49e929B53B4108; // PaymasterHub on Gnosis
address constant GNOSIS_SATELLITE = 0x4Ad70029a9247D369a5bEA92f90840B9ee58eD06; // PoaManagerSatellite on Gnosis

// ─── Org IDs ─────────────────────────────────────────────────────────────────
bytes32 constant POA_ORG = 0xa71879ef0e38b15fe7080196c0102f859e0ca8e7b8c0703ec8df03c66befd069;
bytes32 constant KUBI_ORG = 0xc0f2765d555e21bfad5c6b05accef86a5758e0dee3e9a5b4ee3c3f3069c2102e;
bytes32 constant TEST6_ORG = 0x263b2b29f392647f0fb8ddbb26f099e812ab4ba2777e5e07b906277164181f6b;

// ─── TaskManager proxy addresses (resolved via subgraph) ─────────────────────
address constant POA_TM = 0x681f29751724D2bED331d3EB35e0C9B1C57aF9F0;
address constant KUBI_TM = 0xF57024fC77915Fce8f2608afdd027941bCEE3336;
address constant TEST6_TM = 0x3d93f0D090356D25E7a1614F0F8764b103ca99bc;

// ─── New selector ────────────────────────────────────────────────────────────
// keccak256("createTasksBatch(bytes32,(uint256,bytes,bytes32,address,uint256,bool)[])")[:4]
bytes4 constant SEL_CREATE_TASKS_BATCH = 0xc18aa1c9;

abstract contract Base is Script {
    /// @dev Build the inner setRulesBatch calldata for a single (target, selector) row.
    function _buildInner(bytes32 orgId, address taskManager) internal pure returns (bytes memory) {
        address[] memory targets = new address[](1);
        bytes4[] memory sels = new bytes4[](1);
        bool[] memory allowed = new bool[](1);
        uint32[] memory hints = new uint32[](1);
        targets[0] = taskManager;
        sels[0] = SEL_CREATE_TASKS_BATCH;
        allowed[0] = true;
        return abi.encodeWithSignature(
            "setRulesBatch(bytes32,address[],bytes4[],bool[],uint32[])", orgId, targets, sels, allowed, hints
        );
    }
}

/* ──────────────────────────────────────────────────────────────────────────
 *                         POA — Arbitrum (Hub.adminCall)
 * ────────────────────────────────────────────────────────────────────────*/

contract BroadcastAddBatchSelectorPoa is Base {
    function run() public {
        uint256 key = vm.envOr("PRIVATE_KEY", vm.envUint("DEPLOYER_PRIVATE_KEY"));
        address deployer = vm.addr(key);
        require(deployer == DEPLOYER, "Sender must be the Hub owner (Hudson)");
        require(IHub(HUB).owner() == deployer, "Hub owner mismatch");

        console.log("\n=== Add createTasksBatch -- Poa (Arbitrum) ===");
        console.log("TaskManager:", POA_TM);

        bytes memory inner = _buildInner(POA_ORG, POA_TM);

        vm.startBroadcast(key);
        IHub(HUB).adminCall(ARB_PM, inner);
        vm.stopBroadcast();

        require(IPM(ARB_PM).getRule(POA_ORG, POA_TM, SEL_CREATE_TASKS_BATCH).allowed, "Rule not set after broadcast");
        console.log("Poa createTasksBatch rule set on Arbitrum.");
    }
}

/* ──────────────────────────────────────────────────────────────────────────
 *               KUBI + TEST6 — Gnosis (Satellite.adminCall)
 * ────────────────────────────────────────────────────────────────────────*/

contract BroadcastAddBatchSelectorGnosis is Base {
    function run() public {
        uint256 key = vm.envOr("PRIVATE_KEY", vm.envUint("DEPLOYER_PRIVATE_KEY"));
        address deployer = vm.addr(key);
        require(deployer == DEPLOYER, "Sender must own the Gnosis Satellite (Hudson)");
        require(IPoaManagerSatellite(GNOSIS_SATELLITE).owner() == deployer, "Satellite owner mismatch");

        console.log("\n=== Add createTasksBatch -- KUBI + Test6 (Gnosis) ===");
        console.log("KUBI TaskManager: ", KUBI_TM);
        console.log("Test6 TaskManager:", TEST6_TM);

        vm.startBroadcast(key);
        IPoaManagerSatellite(GNOSIS_SATELLITE).adminCall(GNOSIS_PM, _buildInner(KUBI_ORG, KUBI_TM));
        IPoaManagerSatellite(GNOSIS_SATELLITE).adminCall(GNOSIS_PM, _buildInner(TEST6_ORG, TEST6_TM));
        vm.stopBroadcast();

        require(
            IPM(GNOSIS_PM).getRule(KUBI_ORG, KUBI_TM, SEL_CREATE_TASKS_BATCH).allowed,
            "KUBI rule not set after broadcast"
        );
        require(
            IPM(GNOSIS_PM).getRule(TEST6_ORG, TEST6_TM, SEL_CREATE_TASKS_BATCH).allowed,
            "Test6 rule not set after broadcast"
        );
        console.log("KUBI + Test6 createTasksBatch rules set on Gnosis.");
    }
}

/* ──────────────────────────────────────────────────────────────────────────
 *                              SIMULATIONS
 * ────────────────────────────────────────────────────────────────────────*/

contract SimAddBatchSelectorArbitrum is Base {
    function run() public {
        require(IHub(HUB).owner() == DEPLOYER, "Hub owner mismatch (sim assumes Hudson)");

        console.log("\n=== SIM: createTasksBatch -- Poa (Arbitrum fork) ===");
        console.log("Deployer (pranked):", DEPLOYER);
        console.log("Poa TaskManager:    ", POA_TM);

        bool before_ = IPM(ARB_PM).getRule(POA_ORG, POA_TM, SEL_CREATE_TASKS_BATCH).allowed;
        console.log("Before (Poa):", before_);

        bytes memory inner = _buildInner(POA_ORG, POA_TM);
        vm.prank(DEPLOYER);
        IHub(HUB).adminCall(ARB_PM, inner);

        bool afterPoa = IPM(ARB_PM).getRule(POA_ORG, POA_TM, SEL_CREATE_TASKS_BATCH).allowed;
        console.log("After  (Poa):", afterPoa);
        require(afterPoa, "Poa rule did not stick");

        console.log("PASS: Poa rule set on Arbitrum (sim).");
    }
}

contract SimAddBatchSelectorGnosis is Base {
    function run() public {
        require(IPoaManagerSatellite(GNOSIS_SATELLITE).owner() == DEPLOYER, "Satellite owner is not Hudson");

        console.log("\n=== SIM: createTasksBatch -- KUBI + Test6 (Gnosis fork) ===");
        console.log("Deployer (pranked):", DEPLOYER);
        console.log("KUBI TaskManager:   ", KUBI_TM);
        console.log("Test6 TaskManager:  ", TEST6_TM);

        bool kBefore = IPM(GNOSIS_PM).getRule(KUBI_ORG, KUBI_TM, SEL_CREATE_TASKS_BATCH).allowed;
        bool tBefore = IPM(GNOSIS_PM).getRule(TEST6_ORG, TEST6_TM, SEL_CREATE_TASKS_BATCH).allowed;
        console.log("Before (KUBI):", kBefore);
        console.log("Before (Test6):", tBefore);

        vm.prank(DEPLOYER);
        IPoaManagerSatellite(GNOSIS_SATELLITE).adminCall(GNOSIS_PM, _buildInner(KUBI_ORG, KUBI_TM));

        vm.prank(DEPLOYER);
        IPoaManagerSatellite(GNOSIS_SATELLITE).adminCall(GNOSIS_PM, _buildInner(TEST6_ORG, TEST6_TM));

        bool kAfter = IPM(GNOSIS_PM).getRule(KUBI_ORG, KUBI_TM, SEL_CREATE_TASKS_BATCH).allowed;
        bool tAfter = IPM(GNOSIS_PM).getRule(TEST6_ORG, TEST6_TM, SEL_CREATE_TASKS_BATCH).allowed;
        console.log("After  (KUBI):", kAfter);
        console.log("After  (Test6):", tAfter);
        require(kAfter && tAfter, "Gnosis rules did not stick");

        console.log("PASS: KUBI + Test6 rules set on Gnosis (sim).");
    }
}
