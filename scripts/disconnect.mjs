#!/usr/bin/env node
// Removes notchcode's hooks (command contains notchcode-hook.sh) from ~/.claude/settings.json.
// Every other hook is left exactly as it was. An event key is removed only if it ends up empty.
// If the statusLine is ours, puts back the one saved in the chain file (or removes the key when
// there was none) and deletes the chain file. A statusLine that is not ours is left alone.
//
//   node scripts/disconnect.mjs [--settings <path>] [--chain <path>] [--dry-run]

import {
  parseArgs, readSettings, writeSettings, stripOurs, isOurStatusLine, readChain, removeChain, describeStatusLine,
} from "./lib/settings.mjs";

function main() {
  const args = parseArgs(process.argv.slice(2));
  if (args.help) {
    console.log("usage: node scripts/disconnect.mjs [--settings <path>] [--chain <path>] [--dry-run]");
    return;
  }
  const file = readSettings(args.settings);
  if (!file.existed) { console.log(`nothing to do: ${args.settings} does not exist`); return; }
  const hooks = file.data.hooks;
  const hasHooks = !!hooks && typeof hooks === "object" && !Array.isArray(hooks);

  let changed = false;
  let restored = false;
  const line = file.data.statusLine;
  if (isOurStatusLine(line)) {
    const chain = readChain(args.chain);
    if (chain.hasPrevious) {
      file.data.statusLine = chain.previous;
      console.log(`statusLine: put back ${describeStatusLine(chain.previous)}`);
    } else {
      delete file.data.statusLine;
      console.log("statusLine: removed (there was none before)");
    }
    changed = restored = true;
  } else if (line !== undefined) {
    console.log(`statusLine: left alone, it is ${describeStatusLine(line)}, not notchcode`);
  }

  for (const event of hasHooks ? Object.keys(hooks) : []) {
    if (!Array.isArray(hooks[event])) continue;
    const { groups, removed } = stripOurs(hooks[event]);
    if (removed === 0) continue;
    changed = true;
    if (groups.length === 0) {
      delete hooks[event];
      console.log(`removed ${event}`);
    } else {
      hooks[event] = groups;
      console.log(`removed ${event} (kept ${groups.length} other entr${groups.length === 1 ? "y" : "ies"})`);
    }
  }

  if (!changed) { console.log("nothing to do: no notchcode hooks or status line found"); return; }
  if (args.dryRun) {
    if (restored) console.log(`dry run: would remove ${args.chain}`);
    console.log(`dry run: would write ${args.settings}`);
    return;
  }
  const backup = writeSettings(args.settings, file.data, file);
  if (backup) console.log(`backup ${backup}`);
  console.log(`wrote ${args.settings}`);
  // Chain file last: until settings.json is written, ours may still run and needs it.
  if (restored && removeChain(args.chain)) console.log(`removed ${args.chain}`);
}

try {
  main();
} catch (err) {
  console.error(`disconnect: ${err.message}`);
  process.exit(1);
}
