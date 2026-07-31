import { execSync } from "child_process";
import fs from "fs";
import path from "path";
import {
  signSendWait,
  toUniversal,
  type Chain,
  type ChainContext,
  type Network,
} from "@wormhole-foundation/sdk";
import type { Ntt } from "@wormhole-foundation/sdk-definitions-ntt";
import type { SuiChains } from "@wormhole-foundation/sdk-sui";
import type { SuiNtt } from "@wormhole-foundation/sdk-sui-ntt";
import { Transaction } from "@mysten/sui/transactions";

import { colors } from "../colors.js";
import { getSigner, type SignerType } from "../signers/getSigner";
import { handleDeploymentError } from "../error";
import { ensureNttRoot } from "../validation";
import type { SuiDeploymentResult } from "../commands/shared";
import { promptLine } from "../prompts.js";
import {
  withSuiEnv,
  performPackageUpgradeInPTB,
  buildSuiPackage,
  publishSuiPackage,
  findCreatedObject,
  parsePublishedToml,
  movePublishedTomlToMainTree,
  readSetupProgress,
  saveSetupProgress,
} from "./helpers";

// @mysten/sui v2 gRPC client (#899): signAndExecuteTransaction returns a
// tagged union ({$kind: 'Transaction'|'FailedTransaction'}) and no longer
// emits JSON-RPC-style objectChanges. Rebuild them from
// effects.changedObjects + the objectTypes id→type map so
// findCreatedObject() keeps working.
async function signAndExecuteWithObjectChanges(
  client: any,
  signer: any,
  transaction: any,
  label: string
): Promise<any[]> {
  const result = await client.signAndExecuteTransaction({
    signer,
    transaction,
    include: { effects: true, objectTypes: true },
  });
  const txn = result.Transaction ?? result.FailedTransaction;
  const status = txn?.effects?.status ?? txn?.status;
  if (result.$kind !== "Transaction" || (status && status.success === false)) {
    throw new Error(
      `${label} failed: ${JSON.stringify(status?.error ?? result.$kind)}`
    );
  }
  const objectTypes: Record<string, string> = txn.objectTypes ?? {};
  return (txn.effects?.changedObjects ?? [])
    .filter((c: any) => c.idOperation === "Created")
    .map((c: any) => {
      const ownerKind: string = c.outputOwner?.$kind ?? "";
      return {
        type: "created",
        objectId: c.objectId,
        objectType: objectTypes[c.objectId],
        owner:
          ownerKind.includes("Shared") || ownerKind.includes("Consensus")
            ? { Shared: c.outputOwner?.Shared ?? true }
            : c.outputOwner,
      };
    });
}

export async function upgradeSui<N extends Network, C extends SuiChains>(
  pwd: string,
  version: string | null,
  ntt: SuiNtt<N, C>,
  ctx: ChainContext<N, C>,
  signerType: SignerType
): Promise<void> {
  ensureNttRoot(pwd);

  console.log("Upgrading Sui chain", ctx.chain);

  // Setup Sui environment and execute upgrade
  await withSuiEnv(pwd, ctx, async () => {
    // Determine build environment for Sui 1.63+ package system
    const buildEnv = ctx.network === "Mainnet" ? "mainnet" : "testnet";

    // Build the updated packages
    console.log(`Building updated packages for ${buildEnv} environment...`);
    const packagesToBuild = ["ntt_common", "ntt", "wormhole_transceiver"];

    for (const packageName of packagesToBuild) {
      const packagePath = `${pwd}/sui/packages/${packageName}`;
      console.log(`Building package: ${packageName}`);

      try {
        execSync(`sui move build -e ${buildEnv}`, {
          cwd: packagePath,
          stdio: "inherit",
          env: process.env,
        });
      } catch (error) {
        console.error(`Failed to build package ${packageName}:`, error);
        throw error;
      }
    }

    // Get the current NTT manager address and retrieve upgrade capabilities
    const managerAddress = ntt.contracts.ntt?.manager;
    if (!managerAddress) {
      throw new Error("NTT manager address not found");
    }

    console.log("Retrieving upgrade capabilities...");

    // Get the upgrade cap ID from the NTT state
    let upgradeCapId: string;
    try {
      upgradeCapId = await ntt.getUpgradeCapId();
      console.log(`Found upgrade cap ID: ${upgradeCapId}`);
    } catch (error) {
      console.error("Failed to retrieve upgrade cap ID:", error);
      throw error;
    }

    // Only upgrade the NTT package (other packages don't have upgrade logic)
    const packagesToUpgrade = [{ name: "Ntt", path: "sui/packages/ntt" }];

    console.log("Upgrading packages using pure JavaScript...");

    // Get signer for transactions
    const signer = await getSigner(ctx, signerType);

    for (const pkg of packagesToUpgrade) {
      console.log(`Upgrading package: ${pkg.name}`);

      try {
        // Build the package first
        const packagePath = `${pwd}/${pkg.path}`;
        console.log(`Building package at: ${packagePath}`);

        execSync(`sui move build -e ${buildEnv}`, {
          cwd: packagePath,
          stdio: "pipe",
          env: process.env,
        });

        // Perform all upgrade steps in a single PTB
        console.log(`Performing upgrade for ${pkg.name}...`);
        const upgradeTxs = (async function* () {
          const upgradeTx = await performPackageUpgradeInPTB(
            ctx,
            packagePath,
            upgradeCapId,
            ntt
          );
          yield upgradeTx;
        })();
        await signSendWait(ctx, upgradeTxs, signer.signer);

        console.log(`Successfully upgraded ${pkg.name}`);
      } catch (error) {
        console.error(`Failed to upgrade package ${pkg.name}:`, error);
        throw error;
      }
    }

    console.log("Upgrade process completed for Sui chain", ctx.chain);
  });
}

export async function deploySui<N extends Network, C extends Chain>(
  pwd: string,
  version: string | null,
  mode: Ntt.Mode,
  ch: ChainContext<N, C>,
  token: string,
  signerType: SignerType,
  initialize: boolean,
  skipVerify?: boolean,
  gasBudget?: number,
  packagePath?: string,
  wormholeStateId?: string,
  treasuryCapId?: string
): Promise<SuiDeploymentResult<C>> {
  const finalPackagePath = packagePath || "sui";
  const finalGasBudget = gasBudget || 100000000;

  console.log(`Deploying Sui NTT contracts in ${mode} mode...`);
  console.log(`Package path: ${finalPackagePath}`);
  console.log(`Gas budget: ${finalGasBudget}`);
  console.log(`Target chain: ${ch.chain}`);
  console.log(`Token: ${token}`);

  // Setup Sui environment and execute deployment
  return await withSuiEnv(pwd, ch, async () => {
    const signer = await getSigner(ch, signerType);

    const packagesPath = `${pwd}/${finalPackagePath}/packages`;
    const mainTreePackagesPath = `${finalPackagePath}/packages`;
    const suiPackageNames = ["ntt_common", "ntt", "wormhole_transceiver"];

    // Determine build environment for Sui 1.63+ package system
    const networkType = ch.network;
    const buildEnv = networkType === "Mainnet" ? "mainnet" : "testnet";
    const progressPath = `${mainTreePackagesPath}/.sui-deploy-progress.${buildEnv}.json`;

    // Check for existing Published.toml files from a previous deployment
    const existingPublished = suiPackageNames.filter((p) =>
      fs.existsSync(`${mainTreePackagesPath}/${p}/Published.toml`)
    );

    let skipPublish = false;
    if (existingPublished.length > 0) {
      console.log(
        colors.yellow(
          "\nFound existing Published.toml from a previous deployment:"
        )
      );
      for (const p of existingPublished) {
        console.log(`  ${mainTreePackagesPath}/${p}/Published.toml`);
      }
      console.log();
      console.log(
        "  1) Continue setup  - packages already on-chain, re-run initialization"
      );
      console.log(
        "  2) Redeploy fresh  - delete Published.toml and publish new packages"
      );
      const choice = await promptLine("Choose [1/2]: ");

      if (choice.trim() === "2") {
        // Delete from main tree + any worktree symlinks/files
        for (const p of suiPackageNames) {
          const mainPath = `${mainTreePackagesPath}/${p}/Published.toml`;
          const wtPath = `${packagesPath}/${p}/Published.toml`;
          try {
            fs.unlinkSync(mainPath);
          } catch {}
          try {
            fs.unlinkSync(wtPath);
          } catch {}
        }
        // Also delete progress file
        try {
          fs.unlinkSync(progressPath);
        } catch {}
        console.log("Deleted Published.toml files. Redeploying...");
      } else {
        // Re-create symlinks from worktree → main tree (skip in local mode)
        for (const p of suiPackageNames) {
          const mainPath = `${mainTreePackagesPath}/${p}/Published.toml`;
          const wtPath = `${packagesPath}/${p}/Published.toml`;
          if (path.resolve(mainPath) === path.resolve(wtPath)) continue;
          if (fs.existsSync(mainPath)) {
            fs.rmSync(wtPath, { force: true });
            fs.symlinkSync(path.resolve(mainPath), path.resolve(wtPath));
          }
        }
        skipPublish = true;
        console.log("Continuing setup with existing packages...");
      }
    }

    try {
      // ── Build + Publish phase (skipped when continuing a previous deployment) ──
      if (!skipPublish) {
        console.log("Building Move packages...");
        console.log(`Building for ${buildEnv} environment...`);
        for (const pkg of suiPackageNames) {
          buildSuiPackage(packagesPath, pkg, buildEnv);
        }

        console.log("Deploying packages...");
        for (const pkg of suiPackageNames) {
          publishSuiPackage(packagesPath, pkg, finalGasBudget);
        }

        // Move Published.toml files to main tree and create symlinks
        movePublishedTomlToMainTree(
          packagesPath,
          mainTreePackagesPath,
          suiPackageNames
        );
      }

      // ── Unified setup: both paths read from Published.toml ──

      // Parse Published.toml for package IDs and upgrade caps
      const nttCommonInfo = parsePublishedToml(
        `${mainTreePackagesPath}/ntt_common/Published.toml`,
        buildEnv
      );
      const nttInfo = parsePublishedToml(
        `${mainTreePackagesPath}/ntt/Published.toml`,
        buildEnv
      );
      const whTransceiverInfo = parsePublishedToml(
        `${mainTreePackagesPath}/wormhole_transceiver/Published.toml`,
        buildEnv
      );

      const nttCommonPackageId = nttCommonInfo.packageId;
      const nttPackageId = nttInfo.packageId;
      const whTransceiverPackageId = whTransceiverInfo.packageId;
      const nttUpgradeCapId = nttInfo.upgradeCap;

      console.log(`ntt_common package: ${nttCommonPackageId}`);
      console.log(`ntt package: ${nttPackageId}`);
      console.log(`wormhole_transceiver package: ${whTransceiverPackageId}`);
      console.log(`ntt upgrade cap: ${nttUpgradeCapId}`);

      // Query chain for DeployerCaps to determine which setup steps remain
      const suiSigner = signer.signer as any;
      const client = suiSigner.client;
      const ownerAddress = signer.address.address.toString();

      // v2 gRPC client: getOwnedObjects → listOwnedObjects({owner, type})
      const nttDeployerCaps = await client.listOwnedObjects({
        owner: ownerAddress,
        type: `${nttPackageId}::setup::DeployerCap`,
      });
      const nttDeployerCapId = nttDeployerCaps.objects?.[0]?.objectId;

      const whDeployerCaps = await client.listOwnedObjects({
        owner: ownerAddress,
        type: `${whTransceiverPackageId}::wormhole_transceiver::DeployerCap`,
      });
      const whTransceiverDeployerCapId = whDeployerCaps.objects?.[0]?.objectId;

      // Load setup progress from previous run (if any)
      const progress = readSetupProgress(progressPath);

      // Get Wormhole core bridge state
      let wormholeStateObjectId: string | undefined;
      if (wormholeStateId) {
        wormholeStateObjectId = wormholeStateId;
        console.log(
          `Using provided Wormhole State ID: ${wormholeStateObjectId}`
        );
      } else {
        try {
          console.log(
            "No wormhole state ID provided, looking up from SDK configuration..."
          );
          const wormholeConfig = ch.config.contracts?.coreBridge;
          if (wormholeConfig) {
            wormholeStateObjectId = wormholeConfig;
            console.log(
              `Using Wormhole State ID from SDK: ${wormholeStateObjectId}`
            );
          } else {
            console.log(
              "No Wormhole core bridge contract found in SDK configuration, will skip wormhole transceiver setup"
            );
          }
        } catch (error) {
          console.log(
            "Failed to lookup Wormhole state from SDK, will skip wormhole transceiver setup"
          );
          console.log(
            "Error:",
            error instanceof Error ? error.message : String(error)
          );
        }
      }

      // ── Step 1: complete_burning / complete_locking ──
      let nttStateId = progress.nttStateId;
      let nttAdminCapId = progress.nttAdminCapId;

      if (nttDeployerCapId) {
        console.log("Initializing NTT manager...");
        const chainId = ch.config.chainId;
        const modeArg = mode === "locking" ? "Locking" : "Burning";
        console.log(
          `Completing NTT setup with mode: ${modeArg}, chain ID: ${chainId}`
        );

        const tx = new Transaction();

        if (mode === "burning") {
          console.log("Attempting to call setup::complete_burning...");
          if (!treasuryCapId) {
            throw new Error(
              "Burning mode deployment requires a treasury cap. Please provide --sui-treasury-cap <TREASURY_CAP_ID>"
            );
          }
          console.log("Treasury Cap ID:", treasuryCapId);

          const [adminCap, upgradeCapNtt] = tx.moveCall({
            target: `${nttPackageId}::setup::complete_burning`,
            typeArguments: [token],
            arguments: [
              tx.object(nttDeployerCapId),
              tx.object(nttUpgradeCapId),
              tx.pure.u16(chainId),
              tx.object(treasuryCapId),
            ],
          });
          tx.transferObjects(
            [adminCap, upgradeCapNtt],
            tx.pure.address(ownerAddress)
          );
        } else {
          console.log("Attempting to call setup::complete_locking...");
          const [adminCap, upgradeCapNtt] = tx.moveCall({
            target: `${nttPackageId}::setup::complete_locking`,
            typeArguments: [token],
            arguments: [
              tx.object(nttDeployerCapId),
              tx.object(nttUpgradeCapId),
              tx.pure.u16(chainId),
            ],
          });
          tx.transferObjects(
            [adminCap, upgradeCapNtt],
            tx.pure.address(ownerAddress)
          );
        }

        tx.setGasBudget(finalGasBudget);

        const setupChanges = await signAndExecuteWithObjectChanges(
          client,
          suiSigner._signer,
          tx,
          "NTT setup"
        );

        console.log("Object changes:", JSON.stringify(setupChanges, null, 2));

        nttStateId = findCreatedObject(setupChanges, "state::State", true);
        if (!nttStateId) {
          throw new Error("Could not find NTT State object ID");
        }

        nttAdminCapId = findCreatedObject(setupChanges, "state::AdminCap");

        console.log(`NTT State created at: ${nttStateId}`);
        if (nttAdminCapId) {
          console.log(`NTT AdminCap created at: ${nttAdminCapId}`);
        }

        // Save progress
        progress.nttStateId = nttStateId;
        progress.nttAdminCapId = nttAdminCapId;
        saveSetupProgress(progressPath, progress);
      } else if (nttStateId) {
        console.log(`NTT setup already completed (State: ${nttStateId})`);
      } else {
        throw new Error(
          "NTT DeployerCap not found and no previous setup progress. " +
            "The deployment may be in an inconsistent state."
        );
      }

      // ── Step 2: wormhole_transceiver::complete ──
      let transceiverStateId = progress.transceiverStateId;
      let whTransceiverAdminCapId = progress.whTransceiverAdminCapId;

      if (wormholeStateObjectId && whTransceiverDeployerCapId) {
        console.log("Completing Wormhole Transceiver setup...");

        const transceiverTx = new Transaction();

        console.log(`  Package: ${whTransceiverPackageId}`);
        console.log(`  Type args: ${nttPackageId}::auth::ManagerAuth`);
        console.log(`  Deployer cap: ${whTransceiverDeployerCapId}`);
        console.log(`  Wormhole state: ${wormholeStateObjectId}`);

        const [adminCap] = transceiverTx.moveCall({
          target: `${whTransceiverPackageId}::wormhole_transceiver::complete`,
          typeArguments: [`${nttPackageId}::auth::ManagerAuth`],
          arguments: [
            transceiverTx.object(whTransceiverDeployerCapId),
            transceiverTx.object(wormholeStateObjectId),
          ],
        });

        transceiverTx.transferObjects([adminCap], ownerAddress);
        transceiverTx.setGasBudget(finalGasBudget);

        // Wait for network to settle after NTT setup
        await new Promise((resolve) => setTimeout(resolve, 1000));

        const transceiverChanges = await signAndExecuteWithObjectChanges(
          client,
          suiSigner._signer,
          transceiverTx,
          "Wormhole Transceiver setup"
        );

        console.log(JSON.stringify(transceiverChanges, null, 2));

        transceiverStateId = findCreatedObject(
          transceiverChanges,
          "::wormhole_transceiver::State",
          true
        );
        if (!transceiverStateId) {
          throw new Error(
            "Could not find Wormhole Transceiver State object ID"
          );
        }

        console.log(
          `Wormhole Transceiver State created at: ${transceiverStateId}`
        );

        whTransceiverAdminCapId = findCreatedObject(
          transceiverChanges,
          "::wormhole_transceiver::AdminCap"
        );

        if (whTransceiverAdminCapId) {
          console.log(
            `Wormhole Transceiver AdminCap created at: ${whTransceiverAdminCapId}`
          );
        }

        // Save progress
        progress.transceiverStateId = transceiverStateId;
        progress.whTransceiverAdminCapId = whTransceiverAdminCapId;
        saveSetupProgress(progressPath, progress);
      } else if (transceiverStateId) {
        console.log(
          `Wormhole Transceiver setup already completed (State: ${transceiverStateId})`
        );
      } else if (!wormholeStateObjectId) {
        console.log(
          "Skipping Wormhole Transceiver setup (no wormhole state available)..."
        );
      } else {
        throw new Error(
          "Wormhole Transceiver DeployerCap not found and no previous setup progress. " +
            "The deployment may be in an inconsistent state."
        );
      }

      // ── Step 3: Register transceiver with NTT manager ──
      if (
        nttAdminCapId &&
        transceiverStateId &&
        !progress.transceiverRegistered
      ) {
        console.log("Registering wormhole transceiver with NTT manager...");

        const registerTx = new Transaction();

        console.log(`  NTT State: ${nttStateId}`);
        console.log(`  NTT AdminCap: ${nttAdminCapId}`);
        console.log(
          `  Transceiver Type: ${whTransceiverPackageId}::wormhole_transceiver::TransceiverAuth`
        );

        registerTx.moveCall({
          target: `${nttPackageId}::state::register_transceiver`,
          typeArguments: [
            `${whTransceiverPackageId}::wormhole_transceiver::TransceiverAuth`,
            token,
          ],
          arguments: [
            registerTx.object(nttStateId!),
            // state_object_id param is a pure ID value, not an object ref —
            // passing tx.object() here is CommandArgumentError TypeMismatch
            registerTx.pure.id(transceiverStateId),
            registerTx.object(nttAdminCapId),
          ],
        });

        registerTx.setGasBudget(finalGasBudget);

        try {
          await new Promise((resolve) => setTimeout(resolve, 1000));

          await signAndExecuteWithObjectChanges(
            client,
            suiSigner._signer,
            registerTx,
            "Transceiver registration"
          );

          console.log(
            "Wormhole transceiver successfully registered with NTT manager"
          );
          progress.transceiverRegistered = true;
          saveSetupProgress(progressPath, progress);
        } catch (error) {
          console.error(
            "Failed to register wormhole transceiver with NTT manager:",
            error
          );
          console.warn(
            "Deployment completed but transceiver registration failed. You may need to register it manually."
          );
        }
      } else if (progress.transceiverRegistered) {
        console.log("Transceiver already registered with NTT manager.");
      } else if (!nttAdminCapId) {
        throw new Error(
          "Cannot register transceiver: missing NTT AdminCap ID in progress/results."
        );
      } else if (!transceiverStateId) {
        console.warn(
          "Skipping transceiver registration: no transceiver state available"
        );
      }

      // ── Done ──
      console.log(colors.green("Sui NTT deployment completed successfully!"));
      console.log(`NTT Package ID: ${nttPackageId}`);
      console.log(`NTT State ID: ${nttStateId}`);
      console.log(`Wormhole Transceiver Package ID: ${whTransceiverPackageId}`);
      console.log(
        `Wormhole Transceiver State ID: ${
          transceiverStateId || "Not deployed (skipped)"
        }`
      );

      // Clean up progress file on success
      try {
        fs.unlinkSync(progressPath);
      } catch {}

      return {
        chain: ch.chain,
        address: toUniversal(ch.chain, nttStateId!),
        adminCaps: {
          wormholeTransceiver: whTransceiverAdminCapId,
        },
        transceiverStateIds: {
          wormhole: transceiverStateId,
        },
        packageIds: {
          ntt: nttPackageId,
          nttCommon: nttCommonPackageId,
          wormholeTransceiver: whTransceiverPackageId,
        },
      };
    } catch (deploymentError) {
      handleDeploymentError(
        deploymentError,
        ch.chain,
        ch.network,
        ch.config.rpc
      );
    }
  });
}
