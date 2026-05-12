/**
 * Sync compiled Hardhat ABIs to the frontend.
 *
 * After `npx hardhat compile`, run this to copy each contract's ABI into
 * `frontend/src/lib/abis/{Name}.json`. Reports a summary diff (added /
 * removed signatures) so we know exactly what changed.
 *
 * Usage:
 *   node scripts/sync-abis.js
 *   npm run compile:sync   (compile + sync in one shot)
 */

const { readFileSync, writeFileSync, existsSync, mkdirSync } = require("fs");
const { join } = require("path");

const CONTRACTS    = ["AgentRegistry", "ProgressiveEscrow", "SubscriptionEscrow", "UserRegistry", "AgentMarketplace", "AgentEarningsVault"];
const ARTIFACT_DIR = join(__dirname, "..", "artifacts", "src");
const FRONTEND_DIR = join(__dirname, "..", "..", "frontend", "src", "lib", "abis");

if (!existsSync(FRONTEND_DIR)) mkdirSync(FRONTEND_DIR, { recursive: true });

function sigOf(item) {
  const inputs = (item.inputs || []).map(i => i.type).join(",");
  return item.type === "event" ? `event ${item.name}(${inputs})` : `${item.name}(${inputs})`;
}

function diffAbis(oldAbi, newAbi) {
  const oldSigs = new Set((oldAbi || []).filter(i => i.name).map(sigOf));
  const newSigs = new Set((newAbi || []).filter(i => i.name).map(sigOf));
  const added   = [...newSigs].filter(s => !oldSigs.has(s));
  const removed = [...oldSigs].filter(s => !newSigs.has(s));
  return { added, removed };
}

let totalAdded = 0, totalRemoved = 0, totalSynced = 0;
const lines = [];

for (const name of CONTRACTS) {
  const artifactPath = join(ARTIFACT_DIR, `${name}.sol`, `${name}.json`);
  const targetPath   = join(FRONTEND_DIR, `${name}.json`);

  if (!existsSync(artifactPath)) {
    lines.push(`  ✗ ${name.padEnd(22)} artifact missing — run \`npx hardhat compile\` first`);
    continue;
  }

  const artifact = JSON.parse(readFileSync(artifactPath, "utf8"));
  const newAbi   = artifact.abi;
  if (!newAbi) {
    lines.push(`  ✗ ${name.padEnd(22)} no abi field in artifact`);
    continue;
  }

  let oldAbi = null;
  if (existsSync(targetPath)) {
    try {
      const existing = JSON.parse(readFileSync(targetPath, "utf8"));
      oldAbi = Array.isArray(existing) ? existing : existing.abi;
    } catch { /* fall through to write */ }
  }

  const { added, removed } = diffAbis(oldAbi, newAbi);
  totalAdded   += added.length;
  totalRemoved += removed.length;

  // Frontend imports `.abi` field (see lib/contracts.ts) — preserve that shape
  writeFileSync(targetPath, JSON.stringify({ abi: newAbi }, null, 2));
  totalSynced += 1;

  const delta = added.length || removed.length
    ? `+${added.length} −${removed.length}`
    : "no changes";
  lines.push(`  ✓ ${name.padEnd(22)} ${delta}`);

  for (const s of added)   lines.push(`      + ${s}`);
  for (const s of removed) lines.push(`      − ${s}`);
}

console.log("\n  ABI sync — contracts → frontend");
console.log("  " + "─".repeat(64));
lines.forEach(l => console.log(l));
console.log("  " + "─".repeat(64));
console.log(`  ${totalSynced} synced · +${totalAdded} added · −${totalRemoved} removed\n`);
