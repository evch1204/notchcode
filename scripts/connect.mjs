#!/usr/bin/env node
// Adds notchcode's hooks to ~/.claude/settings.json, beside the owner's own hooks, and
// makes hooks/notchcode-statusline.sh the statusLine (the only way to get the plan limits).
// Idempotent: our entries (command contains notchcode-hook.sh) are replaced in place,
// never duplicated. The statusLine that was there before is saved in the chain file
// (~/Library/Application Support/notchcode/statusline-chain.json) and keeps running
// through ours. Nothing else in the file is touched.
//
//   node scripts/connect.mjs [--settings <path>] [--chain <path>] [--dry-run]
//
// With --settings pointing anywhere but ~/.claude/settings.json, the chain file defaults
// to <settings>.notchcode-statusline-chain.json, so a test copy never touches the real one.

import fs from "node:fs";
import {
  HOOK_SCRIPT, parseArgs, readSettings, writeSettings, stripOurs, shellQuote, wantedHooks,
  STATUSLINE_SCRIPT, statusLineCommand, planStatusLine, writeChain, removeChain, describeStatusLine,
} from "./lib/settings.mjs";

const WANTED = wantedHooks((kind) => `${shellQuote(HOOK_SCRIPT)} ${kind}`);

function main() {
  const args = parseArgs(process.argv.slice(2));
  if (args.help) {
    console.log("usage: node scripts/connect.mjs [--settings <path>] [--chain <path>] [--dry-run]");
    return;
  }
  if (!fs.existsSync(HOOK_SCRIPT)) throw new Error(`hook script missing: ${HOOK_SCRIPT}`);
  if (!fs.existsSync(STATUSLINE_SCRIPT)) throw new Error(`status line script missing: ${STATUSLINE_SCRIPT}`);
  try { fs.chmodSync(HOOK_SCRIPT, 0o755); } catch {}
  try { fs.chmodSync(STATUSLINE_SCRIPT, 0o755); } catch {}

  const file = readSettings(args.settings);
  const settings = file.data;
  const before = JSON.stringify(settings);

  if (settings.hooks === undefined) settings.hooks = {};
  if (settings.hooks === null || typeof settings.hooks !== "object" || Array.isArray(settings.hooks)) {
    throw new Error(`"hooks" in ${args.settings} is not an object; not touching it`);
  }
  const hooks = settings.hooks;

  for (const [event, group] of Object.entries(WANTED)) {
    const existing = Array.isArray(hooks[event]) ? hooks[event] : [];
    const { groups, firstIndex, removed } = stripOurs(existing);
    const oldOurs = existing.filter((g) => !groups.includes(g));
    const same = removed === 1 && oldOurs.length === 1 && JSON.stringify(oldOurs[0]) === JSON.stringify(group);
    if (same) { console.log(`kept ${event} (already there)`); continue; }

    const at = firstIndex < 0 ? groups.length : firstIndex;
    groups.splice(at, 0, structuredClone(group));
    hooks[event] = groups;
    console.log(removed > 0 ? `updated ${event}` : `added ${event}`);
  }

  // Our entries on events we no longer use (older versions of this script).
  for (const event of Object.keys(hooks)) {
    if (event in WANTED || !Array.isArray(hooks[event])) continue;
    const { groups, removed } = stripOurs(hooks[event]);
    if (removed === 0) continue;
    if (groups.length === 0) delete hooks[event];
    else hooks[event] = groups;
    console.log(`removed ${event} (no longer used)`);
  }

  // statusLine: ours, with the previous one chained.
  const had = settings.statusLine;
  const plan = planStatusLine(had, statusLineCommand(STATUSLINE_SCRIPT, args.chain));
  if (plan.chain === "keep") {
    console.log(plan.line === had ? "kept statusLine (already notchcode)" : "updated statusLine command");
  } else if (plan.chain === "write") {
    console.log(`statusLine: ${describeStatusLine(had)} is saved to ${args.chain} and keeps running through notchcode`);
  } else {
    console.log("added statusLine (there was none; notchcode's prints nothing)");
  }
  if (plan.line !== had) settings.statusLine = plan.line;

  const settingsChanged = JSON.stringify(settings) !== before;
  if (!settingsChanged) {
    console.log(`no changes to ${args.settings}`);
    return;
  }
  if (args.dryRun) {
    if (plan.chain === "write") console.log(`dry run: would write ${args.chain}`);
    if (plan.chain === "remove" && fs.existsSync(args.chain)) console.log(`dry run: would remove stale ${args.chain}`);
    console.log(`dry run: would write ${args.settings}`);
    return;
  }
  // Chain file first: the status line must never point at ours before the old one is saved.
  if (plan.chain === "write") { writeChain(args.chain, plan.previous); console.log(`wrote ${args.chain}`); }
  if (plan.chain === "remove" && removeChain(args.chain)) console.log(`removed stale ${args.chain}`);
  const backup = writeSettings(args.settings, settings, file);
  if (backup) console.log(`backup ${backup}`);
  console.log(`wrote ${args.settings}`);
}

try {
  main();
} catch (err) {
  console.error(`connect: ${err.message}`);
  process.exit(1);
}
