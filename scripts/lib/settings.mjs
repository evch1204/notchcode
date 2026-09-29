// Shared helpers for connect.mjs and disconnect.mjs. Node 20, no packages.
// Only ever touches hook entries whose command contains MARKER.

import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

export const MARKER = "notchcode-hook.sh";

const here = path.dirname(fileURLToPath(import.meta.url));
export const HOOK_SCRIPT = path.resolve(here, "..", "..", "hooks", MARKER);

// The status line. Claude Code hands the plan limits (rate_limits) only to the single
// `statusLine` command, so connect makes ours that command and saves whatever was there
// in the chain file; notchcode-statusline.sh runs it with the same stdin and prints its
// output, so the owner's status line (Orca, sidecar-pane, ...) looks exactly as before.
// HooksInstaller.swift carries the same logic.
export const STATUSLINE_MARKER = "notchcode-statusline.sh";
export const STATUSLINE_SCRIPT = path.resolve(here, "..", "..", "hooks", STATUSLINE_MARKER);
export const DEFAULT_SETTINGS = path.join(os.homedir(), ".claude", "settings.json");
export const DEFAULT_CHAIN = path.join(os.homedir(), "Library", "Application Support", "notchcode", "statusline-chain.json");
/** Keys of the previous statusLine that shape how it looks; ours copies them. */
const CARRIED = ["padding", "refreshInterval"];

/**
 * The hook groups notchcode installs, one per Claude Code event, in install order.
 * `cmd(kind)` builds the command line for one event kind. HooksInstaller.swift and
 * plugin/hooks/hooks.json carry the same table; keep all three in step.
 *
 * Blocking hooks must be synchronous: Claude Code ignores `async` on PermissionRequest
 * and PreToolUse anyway, and they need to return a decision. 65 s > the hook's 59 s wait.
 * Passive hooks are async so they never slow Claude down (Claude Code runs Stop and
 * UserPromptSubmit synchronously regardless; the script returns in well under a second).
 * https://code.claude.com/docs/en/hooks.md
 */
export function wantedHooks(cmd) {
  const passive = (kind) => ({ type: "command", command: cmd(kind), timeout: 5, async: true });
  return {
    PermissionRequest: { hooks: [{ type: "command", command: cmd("permission"), timeout: 65 }] },
    PreToolUse: {
      matcher: "Bash",
      // Only `git commit` reaches the app; every other Bash call skips the hook entirely.
      hooks: [{ type: "command", if: "Bash(git commit *)", command: cmd("pre_tool"), timeout: 65 }],
    },
    PostToolUse: { matcher: "Edit|Write|MultiEdit|Bash", hooks: [passive("post_tool")] },
    Notification: { hooks: [passive("notification")] },
    Stop: { hooks: [passive("stop")] },
    SessionStart: { hooks: [passive("session_start")] },
    SessionEnd: { hooks: [passive("session_end")] },
    UserPromptSubmit: { hooks: [passive("user_prompt")] },
    SubagentStart: { hooks: [passive("subagent_start")] },
    SubagentStop: { hooks: [passive("subagent_stop")] },
  };
}

/** Opens the app in the background if it is not running. Plugin only: a settings.json
 *  install is made by the app or by hand, and the app is already there. */
export const LAUNCH_APP = "pgrep -xq notchcode || open -g -b com.evch.notchcode 2>/dev/null || true";

/** plugin/hooks/hooks.json: the same table, pointed at the plugin's own copy of the script. */
export function pluginHooks() {
  const wanted = wantedHooks((kind) => `"\${CLAUDE_PLUGIN_ROOT}"/hooks/${MARKER} ${kind}`);
  wanted.SessionStart.hooks.unshift({ type: "command", command: LAUNCH_APP, timeout: 5, async: true });
  // settings.json and hooks.json both hold an array of matcher groups per event.
  const hooks = {};
  for (const [event, group] of Object.entries(wanted)) hooks[event] = [group];
  return { hooks };
}

export function parseArgs(argv) {
  const args = { settings: DEFAULT_SETTINGS, chain: null, dryRun: false };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--settings") args.settings = path.resolve(argv[++i] ?? "");
    else if (a.startsWith("--settings=")) args.settings = path.resolve(a.slice("--settings=".length));
    else if (a === "--chain") args.chain = path.resolve(argv[++i] ?? "");
    else if (a.startsWith("--chain=")) args.chain = path.resolve(a.slice("--chain=".length));
    else if (a === "--dry-run") args.dryRun = true;
    else if (a === "-h" || a === "--help") args.help = true;
    else throw new Error(`unknown argument: ${a}`);
  }
  args.chain ??= chainPathFor(args.settings);
  return args;
}

export function readSettings(file) {
  if (!fs.existsSync(file)) return { data: {}, existed: false, trailingNewline: true };
  const text = fs.readFileSync(file, "utf8");
  const data = text.trim() === "" ? {} : JSON.parse(text);
  if (data === null || typeof data !== "object" || Array.isArray(data)) {
    throw new Error(`${file} is not a JSON object`);
  }
  return { data, existed: true, trailingNewline: text.endsWith("\n") || text.trim() === "" };
}

/** Backups kept next to settings.json; older ones we made are deleted. Same in HooksInstaller.swift. */
export const KEPT_BACKUPS = 5;

/**
 * Backs up (if the file exists) then writes atomically, keeping 2-space indentation and file mode.
 * A symlinked settings.json (a dotfiles repo) stays a link: the write goes to the file it points
 * at, with the temp file in that file's folder so the rename stays on one volume.
 */
export function writeSettings(file, data, { existed, trailingNewline }) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  let target = file;
  try { target = fs.realpathSync(file); } catch { /* not there yet: write it where asked */ }
  let backup = null;
  let mode = 0o600;
  if (existed) {
    const stamp = new Date().toISOString().replace(/[:.]/g, "-");
    backup = `${file}.notchcode-backup-${stamp}`;
    fs.copyFileSync(target, backup);
    mode = fs.statSync(target).mode & 0o777;
    pruneBackups(file);
  }
  const text = JSON.stringify(data, null, 2) + (trailingNewline ? "\n" : "");
  const tmp = `${target}.notchcode-tmp-${process.pid}`;
  fs.writeFileSync(tmp, text, { mode });
  fs.renameSync(tmp, target);
  return backup;
}

/** Keeps the newest KEPT_BACKUPS `<file>.notchcode-backup-*` (the timestamps sort by name). */
function pruneBackups(file) {
  const prefix = `${path.basename(file)}.notchcode-backup-`;
  let names = [];
  try { names = fs.readdirSync(path.dirname(file)).filter((n) => n.startsWith(prefix)).sort(); } catch { return; }
  for (const name of names.slice(0, Math.max(0, names.length - KEPT_BACKUPS))) {
    try { fs.unlinkSync(path.join(path.dirname(file), name)); } catch { /* keep going */ }
  }
}

export function isOurs(hook) {
  return !!hook && typeof hook.command === "string" && hook.command.includes(MARKER);
}

/**
 * Removes our hooks from one event's group list. Groups left with no hooks are dropped;
 * everything else is kept exactly as it was.
 * Returns { groups, firstIndex, removed } where firstIndex is where our first group sat.
 */
export function stripOurs(groups) {
  const out = [];
  let firstIndex = -1;
  let removed = 0;
  for (const group of Array.isArray(groups) ? groups : []) {
    const hooks = group && Array.isArray(group.hooks) ? group.hooks : null;
    if (!hooks || !hooks.some(isOurs)) { out.push(group); continue; }
    if (firstIndex < 0) firstIndex = out.length;
    const kept = hooks.filter((h) => !isOurs(h));
    removed += hooks.length - kept.length;
    if (kept.length > 0) out.push({ ...group, hooks: kept });
  }
  return { groups: out, firstIndex, removed };
}

export function shellQuote(s) {
  return /^[A-Za-z0-9_./:@%+=-]+$/.test(s) ? s : `'${s.replace(/'/g, `'\\''`)}'`;
}

// MARK: statusLine

/**
 * Where the previous statusLine is saved. The real settings file uses the fixed path the
 * script reads by default. Any other settings file (a test copy) gets its own chain file
 * beside it, so testing on a copy never touches the real chain file.
 */
export function chainPathFor(settingsFile) {
  return path.resolve(settingsFile) === path.resolve(DEFAULT_SETTINGS)
    ? DEFAULT_CHAIN
    : `${path.resolve(settingsFile)}.notchcode-statusline-chain.json`;
}

/** Our statusLine command. A non-default chain file is passed in NOTCHCODE_CHAIN. */
export function statusLineCommand(script, chain) {
  const q = shellQuote(script);
  return path.resolve(chain) === path.resolve(DEFAULT_CHAIN) ? q : `NOTCHCODE_CHAIN=${shellQuote(chain)} ${q}`;
}

export function isOurStatusLine(line) {
  return !!line && typeof line === "object" && typeof line.command === "string" && line.command.includes(STATUSLINE_MARKER);
}

/**
 * { exists, hasPrevious, previous? }: previous is the saved statusLine, verbatim.
 * A chain file that exists but cannot be read throws, so the status line is never guessed at.
 */
export function readChain(file) {
  if (!fs.existsSync(file)) return { exists: false, hasPrevious: false };
  let raw;
  try { raw = JSON.parse(fs.readFileSync(file, "utf8")); } catch {
    throw new Error(`the saved status line in ${file} is not readable; not touching the status line`);
  }
  if (raw && typeof raw === "object" && !Array.isArray(raw) && "previous" in raw) {
    return { exists: true, hasPrevious: true, previous: raw.previous };
  }
  return { exists: true, hasPrevious: false };
}

export function writeChain(file, previous) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  const tmp = `${file}.tmp-${process.pid}`;
  fs.writeFileSync(tmp, JSON.stringify({ previous }, null, 2) + "\n");
  fs.renameSync(tmp, file);
}

export function removeChain(file) {
  try { fs.unlinkSync(file); return true; } catch { return false; }
}

/**
 * The statusLine connect wants, given what is there now.
 *   - not ours: ours is {type, command} plus padding / refreshInterval copied from the old one,
 *     and the old one (if any) goes to the chain file.
 *   - already ours: only the command is brought up to date; the chain file is left alone.
 * Returns { line, chain: "keep" | "write" | "remove", previous }.
 */
export function planStatusLine(had, command) {
  if (isOurStatusLine(had)) {
    return { line: had.command === command ? had : { ...had, command }, chain: "keep" };
  }
  const line = { type: "command", command };
  if (had && typeof had === "object" && !Array.isArray(had)) {
    for (const k of CARRIED) if (k in had) line[k] = had[k];
  }
  return had === undefined ? { line, chain: "remove" } : { line, chain: "write", previous: had };
}

/** A short name for a statusLine, for messages. */
export function describeStatusLine(line) {
  const c = line && typeof line.command === "string" ? line.command : "";
  if (!c) return JSON.stringify(line);
  if (c.includes(".orca/")) return "Orca's status line";
  if (c.includes("sidecar")) return "sidecar-pane's status line";
  const m = /([\w.-]+)\.(sh|mjs|cjs|js|py|cmd)\b/.exec(c);
  return m ? m[0] : c.length > 48 ? `${c.slice(0, 48)}…` : c;
}
