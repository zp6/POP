// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import {TaskManager} from "../../src/TaskManager.sol";
import {TaskPerm} from "../../src/libs/TaskPerm.sol";
import {PoaManagerHub} from "../../src/crosschain/PoaManagerHub.sol";
import {PoaManager} from "../../src/PoaManager.sol";
import {DeterministicDeployer} from "../../src/crosschain/DeterministicDeployer.sol";

/*
 * ============================================================================
 * TaskManager Upgrade — editable budgets (v3)
 * ============================================================================
 *
 * Adds a `TaskPerm.BUDGET` (bit 5) permission so that — in addition to the
 * Executor / passing vote — a configurable hat-holder can resize a project's
 * PT cap and any per-token bounty cap. Permission is strict: the project-
 * manager bypass used by `_checkPerm` is intentionally not granted to budget
 * edits. PMs need an explicit hat assignment.
 *
 * Mechanics:
 *   - `setConfig`'s top-of-function `_requireExecutor()` is moved into each
 *     branch. `EXECUTOR` / `CREATOR_HAT_ALLOWED` / `ROLE_PERM` /
 *     `PROJECT_MANAGER` keep `_requireExecutor()`. `PROJECT_CAP` and
 *     `BOUNTY_CAP` use a new `_requireBudgetEditor(pid)` helper that allows
 *     Executor or any wearer of a hat granted `TaskPerm.BUDGET` globally
 *     (`ROLE_PERM`) or per-project (`setProjectRolePerm`).
 *   - No Layout changes, no new events, no new storage. Drop-in safe for
 *     existing subgraph indexers.
 *
 * Three-step cross-chain upgrade pattern (same as createTasksBatch v2):
 *   1. Deploy impl on Gnosis via DeterministicDeployer
 *   2. Deploy on Arbitrum + upgradeBeaconCrossChain
 *   3. Verify on Gnosis
 *
 * Usage:
 *   source .env && FOUNDRY_PROFILE=production forge script \
 *     script/upgrades/UpgradeTaskManagerEditableBudgets.s.sol:<StepContract> \
 *     --rpc-url <chain> --broadcast --slow
 * ============================================================================
 */

address constant DD = 0x4aC8B5ebEb9D8C3dE3180ddF381D552d59e8835a;
address constant HUB = 0xB72840B343654eAfb2CFf7acC4Fc6b59E6c3CC71;
address constant GNOSIS_POA_MANAGER = 0x794fD39e75140ee1545B1B022E5486B7c863789b;
uint256 constant HYPERLANE_FEE = 0.005 ether;
// Live impl on Gnosis is currently "v2" (createTasksBatch — see
// UpgradeTaskManagerCreateTasksBatch.s.sol). The plain "v3" CREATE3 address
// on Gnosis was already taken by a prior unrelated deployment, so we use a
// content-specific tag to guarantee a fresh deterministic address.
string constant VERSION = "v3-editable-budgets";

/**
 * @title Step1_DeployImplOnGnosis
 * @notice Deploy TaskManager v3 implementation on Gnosis via DD.
 *
 * Usage:
 *   source .env && FOUNDRY_PROFILE=production forge script \
 *     script/upgrades/UpgradeTaskManagerEditableBudgets.s.sol:Step1_DeployImplOnGnosis \
 *     --rpc-url gnosis --broadcast --slow
 */
contract Step1_DeployImplOnGnosis is Script {
    function run() public {
        uint256 deployerKey = vm.envOr("PRIVATE_KEY", vm.envUint("DEPLOYER_PRIVATE_KEY"));
        DeterministicDeployer dd = DeterministicDeployer(DD);

        bytes32 salt = dd.computeSalt("TaskManager", VERSION);
        address predicted = dd.computeAddress(salt);
        console.log("\n=== Step 1: Deploy TaskManager v3 impl on Gnosis ===");
        console.log("Predicted:", predicted);

        if (predicted.code.length > 0) {
            console.log("Already deployed. Skipping.");
            return;
        }

        vm.startBroadcast(deployerKey);
        address deployed = dd.deploy(salt, type(TaskManager).creationCode);
        vm.stopBroadcast();

        require(deployed == predicted, "Address mismatch");
        console.log("Deployed:", deployed);
        console.log("\nNext: Run Step2_UpgradeFromArbitrum on Arbitrum");
    }
}

/**
 * @title Step2_UpgradeFromArbitrum
 * @notice Deploy impl on Arbitrum via DD, upgrade beacon cross-chain.
 *
 * Usage:
 *   source .env && FOUNDRY_PROFILE=production forge script \
 *     script/upgrades/UpgradeTaskManagerEditableBudgets.s.sol:Step2_UpgradeFromArbitrum \
 *     --rpc-url arbitrum --broadcast --slow
 */
contract Step2_UpgradeFromArbitrum is Script {
    function run() public {
        uint256 deployerKey = vm.envOr("PRIVATE_KEY", vm.envUint("DEPLOYER_PRIVATE_KEY"));
        address deployer = vm.addr(deployerKey);

        PoaManagerHub hub = PoaManagerHub(payable(HUB));
        DeterministicDeployer dd = DeterministicDeployer(DD);

        require(hub.owner() == deployer, "Deployer must own Hub");
        require(!hub.paused(), "Hub is paused");

        bytes32 salt = dd.computeSalt("TaskManager", VERSION);
        address predicted = dd.computeAddress(salt);
        console.log("\n=== Step 2: Upgrade TaskManager from Arbitrum ===");
        console.log("DD impl address:", predicted);

        vm.startBroadcast(deployerKey);

        if (predicted.code.length == 0) {
            dd.deploy(salt, type(TaskManager).creationCode);
            console.log("Deployed on Arbitrum");
        } else {
            console.log("Already deployed on Arbitrum");
        }

        hub.upgradeBeaconCrossChain{value: HYPERLANE_FEE}("TaskManager", predicted, VERSION);
        console.log("Beacon upgraded cross-chain");

        vm.stopBroadcast();
        console.log("\nWait ~5 min for Hyperlane relay, then run Step3 on Gnosis.");
    }
}

/**
 * @title Step3_VerifyGnosis
 * @notice Verify the Gnosis beacon upgrade landed.
 *
 * Usage:
 *   forge script script/upgrades/UpgradeTaskManagerEditableBudgets.s.sol:Step3_VerifyGnosis \
 *     --rpc-url gnosis
 */
contract Step3_VerifyGnosis is Script {
    function run() public view {
        DeterministicDeployer dd = DeterministicDeployer(DD);
        bytes32 salt = dd.computeSalt("TaskManager", VERSION);
        address expectedImpl = dd.computeAddress(salt);

        address currentImpl = PoaManager(GNOSIS_POA_MANAGER).getCurrentImplementationById(keccak256("TaskManager"));

        console.log("\n=== Step 3: Verify Gnosis TaskManager Upgrade ===");
        console.log("Expected impl:", expectedImpl);
        console.log("Current impl: ", currentImpl);

        if (currentImpl == expectedImpl) {
            console.log("PASS: TaskManager upgraded to v3 on Gnosis");
            console.log("\nNew capability: TaskPerm.BUDGET (bit 5) lets a configured hat-holder edit");
            console.log("  - PROJECT_CAP via setConfig(PROJECT_CAP, abi.encode(pid, newCap))");
            console.log("  - BOUNTY_CAP via setConfig(BOUNTY_CAP, abi.encode(pid, token, newCap))");
            console.log("Grant: setConfig(ROLE_PERM, abi.encode(BUDGET_HAT, TaskPerm.BUDGET))");
            console.log("Per-project: setProjectRolePerm(pid, BUDGET_HAT, TaskPerm.BUDGET)");
        } else {
            console.log("WAITING: Hyperlane message not yet relayed.");
        }
    }
}

interface IOrgRegistry {
    function orgIds(uint256 index) external view returns (bytes32);
    function proxyOf(bytes32 orgId, bytes32 typeId) external view returns (address);
}

/**
 * @title DryRun_EditableBudgets
 * @notice Pre-flight test on a Gnosis fork. Proves:
 *
 *   Before the upgrade:
 *     A. A random non-executor EOA calling `setConfig(PROJECT_CAP, ...)`
 *        reverts with `NotExecutor` (current behavior).
 *
 *   Apply the upgrade (DD deploy + beacon point):
 *     B. DD-predicted address matches deployed address.
 *     C. PoaManager beacon updates to the new impl.
 *
 *   After the upgrade:
 *     D. Storage preserved — executor address survives the impl swap.
 *     E. Existing project's `cap` and `spent` survive the impl swap.
 *     F. The same random non-executor EOA now reverts with `Unauthorized`
 *        (proves the new gate is live; not `NotExecutor` anymore).
 *     G. Executor → `setConfig(PROJECT_CAP, ...)` still succeeds on a fresh
 *        project (regression for the governance / vote path).
 *     H. Executor → `setConfig(BOUNTY_CAP, ...)` still succeeds.
 *     I. Executor → `setConfig(ROLE_PERM, abi.encode(hat, TaskPerm.BUDGET))`
 *        succeeds (admin path to assign the new permission).
 *     J. Other `setConfig` keys (`EXECUTOR`, `CREATOR_HAT_ALLOWED`,
 *        `ROLE_PERM`, `PROJECT_MANAGER`) still reject non-executor callers
 *        with `NotExecutor` — the per-branch refactor did not widen access
 *        on any unrelated admin key.
 *
 * Does not broadcast.
 *
 * Usage:
 *   FOUNDRY_PROFILE=production forge script \
 *     script/upgrades/UpgradeTaskManagerEditableBudgets.s.sol:DryRun_EditableBudgets \
 *     --rpc-url gnosis
 */
contract DryRun_EditableBudgets is Script {
    address constant ORG_REGISTRY = 0x3744b372abc41589226313F2bB1dB3aCAa22A854;

    function run() public {
        console.log("\n=== DRY RUN: TaskManager v3 upgrade on Gnosis fork ===\n");

        DeterministicDeployer dd = DeterministicDeployer(DD);
        PoaManager pm = PoaManager(GNOSIS_POA_MANAGER);

        // Pull a real TaskManager proxy from OrgRegistry to exercise against
        // production state.
        IOrgRegistry reg = IOrgRegistry(ORG_REGISTRY);
        bytes32 orgId = reg.orgIds(0);
        address proxy = reg.proxyOf(orgId, keccak256("TaskManager"));
        require(proxy != address(0), "DryRun: no TaskManager proxy for org 0");
        TaskManager tm = TaskManager(proxy);

        console.log("orgId:", vm.toString(orgId));
        console.log("TaskManager proxy:", proxy);

        // Pre-state snapshot.
        address implBefore = pm.getCurrentImplementationById(keccak256("TaskManager"));
        console.log("Impl before:", implBefore);

        // Read executor through the live impl.
        address executor = abi.decode(tm.getLensData(4, ""), (address));
        require(executor != address(0), "DryRun: executor unset pre-upgrade");
        console.log("Executor:", executor);

        address randomCaller = makeAddr("randomEOA");

        // Create a fresh, real project against the live impl so the post-upgrade
        // probe targets an existing pid (the new impl checks existence before
        // permission, so a non-existent pid would mask the gate behind NotFound).
        bytes32 probePid = _createFreshProject(tm, executor, bytes("dryrun-probe-existing"));
        bytes memory probeCapCall = abi.encodeCall(
            TaskManager.setConfig, (TaskManager.ConfigKey.PROJECT_CAP, abi.encode(probePid, uint256(2 ether)))
        );

        // ---------- A. Before the upgrade: non-executor → NotExecutor ----------
        vm.prank(randomCaller);
        (bool okA, bytes memory retA) = proxy.call(probeCapCall);
        require(!okA, "DryRun A: random caller must revert pre-upgrade");
        require(bytes4(retA) == TaskManager.NotExecutor.selector, "DryRun A: expected NotExecutor pre-upgrade");
        console.log("A. Pre-upgrade gate confirmed: random EOA -> NotExecutor");

        // Snapshot the project cap/spent so we can prove storage survives.
        (uint256 capBefore, uint256 spentBefore, bool existsBefore) =
            abi.decode(tm.getLensData(2, abi.encode(probePid)), (uint256, uint256, bool));
        require(existsBefore, "DryRun: probe project missing pre-upgrade");

        // ---------- B-C. Apply the upgrade ----------
        bytes32 salt = dd.computeSalt("TaskManager", VERSION);
        address predicted = dd.computeAddress(salt);
        console.log("DD predicted impl:", predicted);

        address deployed;
        if (predicted.code.length == 0) {
            vm.prank(DeterministicDeployer(DD).owner());
            deployed = dd.deploy(salt, type(TaskManager).creationCode);
        } else {
            deployed = predicted;
        }
        require(deployed == predicted, "DryRun B: DD address mismatch");
        require(deployed.code.length > 0, "DryRun B: impl code missing");
        console.log("B. DD-predicted impl matches deployed:", deployed);

        address pmOwner = pm.owner();
        vm.prank(pmOwner);
        pm.upgradeBeacon("TaskManager", deployed, VERSION);
        address implAfter = pm.getCurrentImplementationById(keccak256("TaskManager"));
        require(implAfter == deployed, "DryRun C: beacon upgrade did not stick");
        console.log("C. Beacon upgraded to:", implAfter);

        // ---------- D. Storage preserved (executor) ----------
        address executorAfter = abi.decode(tm.getLensData(4, ""), (address));
        require(executorAfter == executor, "DryRun D: executor address drifted post-upgrade");
        console.log("D. Executor preserved post-upgrade");

        // ---------- E. Existing project cap/spent preserved ----------
        (uint256 capAfter, uint256 spentAfter, bool existsAfter) =
            abi.decode(tm.getLensData(2, abi.encode(probePid)), (uint256, uint256, bool));
        require(existsAfter, "DryRun E: probe project lost post-upgrade");
        require(capAfter == capBefore, "DryRun E: cap drifted");
        require(spentAfter == spentBefore, "DryRun E: spent drifted");
        console.log("E. Probe project storage preserved (cap, spent)");

        // ---------- F. New gate: non-executor now reverts with Unauthorized ----------
        vm.prank(randomCaller);
        (bool okF, bytes memory retF) = proxy.call(probeCapCall);
        require(!okF, "DryRun F: random caller must still revert");
        require(bytes4(retF) == TaskManager.Unauthorized.selector, "DryRun F: expected Unauthorized post-upgrade");
        console.log("F. Post-upgrade gate confirmed: random EOA -> Unauthorized");

        // ---------- G/H/I. Executor flow still works ----------
        _executorBudgetEditsStillWork(tm, executor, probePid);

        // ---------- J. Other admin keys still executor-only ----------
        _verifyOtherKeysStillExecutorOnly(proxy, randomCaller, probePid);

        console.log("\n=== ALL DRY-RUN CHECKS PASSED ===");
        console.log("Safe to broadcast Step1/Step2/Step3 against mainnet.");
    }

    function _createFreshProject(TaskManager tm, address executor, bytes memory title) internal returns (bytes32 pid) {
        TaskManager.BootstrapProjectConfig memory cfg = TaskManager.BootstrapProjectConfig({
            title: title,
            metadataHash: bytes32(0),
            cap: 5 ether,
            managers: new address[](0),
            createHats: new uint256[](0),
            claimHats: new uint256[](0),
            reviewHats: new uint256[](0),
            assignHats: new uint256[](0),
            bountyTokens: new address[](0),
            bountyCaps: new uint256[](0)
        });
        vm.prank(executor);
        pid = tm.createProject(cfg);
        console.log("Fresh project pid:", vm.toString(pid));
    }

    function _executorBudgetEditsStillWork(TaskManager tm, address executor, bytes32 pid) internal {
        // G. Executor can raise the PT cap.
        vm.prank(executor);
        tm.setConfig(TaskManager.ConfigKey.PROJECT_CAP, abi.encode(pid, uint256(10 ether)));
        (uint256 cap,,) = abi.decode(tm.getLensData(2, abi.encode(pid)), (uint256, uint256, bool));
        require(cap == 10 ether, "DryRun G: PROJECT_CAP did not update");
        console.log("G. Executor PROJECT_CAP edit succeeded (cap=10 ether)");

        // H. Executor can resize a bounty cap (set it on a synthetic token addr;
        // we're testing the permission gate and storage write, not transfers).
        address syntheticBountyToken = address(uint160(uint256(keccak256("dryrun-bounty-token"))));
        vm.prank(executor);
        tm.setConfig(TaskManager.ConfigKey.BOUNTY_CAP, abi.encode(pid, syntheticBountyToken, uint256(7 ether)));
        (uint256 bcap,) = abi.decode(tm.getLensData(9, abi.encode(pid, syntheticBountyToken)), (uint256, uint256));
        require(bcap == 7 ether, "DryRun H: BOUNTY_CAP did not update");
        console.log("H. Executor BOUNTY_CAP edit succeeded (cap=7 ether)");

        // I. Executor can grant the new BUDGET perm globally on a hat.
        uint256 syntheticHat = uint256(keccak256("dryrun-budget-hat"));
        vm.prank(executor);
        tm.setConfig(TaskManager.ConfigKey.ROLE_PERM, abi.encode(syntheticHat, TaskPerm.BUDGET));
        console.log("I. Executor granted TaskPerm.BUDGET to hat", syntheticHat);
    }

    function _verifyOtherKeysStillExecutorOnly(address proxy, address randomCaller, bytes32 existingPid) internal {
        bytes[4] memory calls = [
            abi.encodeCall(TaskManager.setConfig, (TaskManager.ConfigKey.EXECUTOR, abi.encode(makeAddr("ignored")))),
            abi.encodeCall(
                TaskManager.setConfig, (TaskManager.ConfigKey.CREATOR_HAT_ALLOWED, abi.encode(uint256(987), true))
            ),
            abi.encodeCall(
                TaskManager.setConfig, (TaskManager.ConfigKey.ROLE_PERM, abi.encode(uint256(987), uint8(0xFF)))
            ),
            abi.encodeCall(
                TaskManager.setConfig,
                (TaskManager.ConfigKey.PROJECT_MANAGER, abi.encode(existingPid, randomCaller, true))
            )
        ];
        string[4] memory labels = ["EXECUTOR", "CREATOR_HAT_ALLOWED", "ROLE_PERM", "PROJECT_MANAGER"];

        for (uint256 i; i < calls.length; ++i) {
            vm.prank(randomCaller);
            (bool ok, bytes memory ret) = proxy.call(calls[i]);
            require(!ok, "DryRun J: admin key did not revert for random caller");
            require(
                bytes4(ret) == TaskManager.NotExecutor.selector,
                "DryRun J: admin key gave wrong revert (must still be NotExecutor)"
            );
            console.log("J.", labels[i], "still rejects non-executor with NotExecutor");
        }
    }
}
