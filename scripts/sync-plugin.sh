#!/bin/sh
# sync-plugin.sh [--check]
#
# Keeps the Claude Code plugin in step with the repo:
#   - copies hooks/notchcode-hook.sh to plugin/hooks/notchcode-hook.sh
#   - writes plugin/hooks/hooks.json from wantedHooks() in scripts/lib/settings.mjs
# Run after editing the hook script or the hook table.
# With --check, writes nothing and exits 1 when either file is out of date.

root=$(cd "$(dirname "$0")/.." && pwd)
src="$root/hooks/notchcode-hook.sh"
dst="$root/plugin/hooks/notchcode-hook.sh"
json="$root/plugin/hooks/hooks.json"

render_json() {
  node --input-type=module -e "
    const { pluginHooks } = await import(process.argv[1]);
    process.stdout.write(JSON.stringify(pluginHooks(), null, 2) + '\\n');
  " "$root/scripts/lib/settings.mjs"
}

if [ "$1" = "--check" ]; then
  ok=0
  cmp -s "$src" "$dst" || { echo "plugin/hooks/notchcode-hook.sh is out of date" >&2; ok=1; }
  render_json | cmp -s - "$json" || { echo "plugin/hooks/hooks.json is out of date" >&2; ok=1; }
  [ "$ok" -eq 0 ] && echo "plugin in sync" || echo "run scripts/sync-plugin.sh" >&2
  exit "$ok"
fi

mkdir -p "$(dirname "$dst")"
cp "$src" "$dst"
chmod 755 "$dst"
echo "copied hooks/notchcode-hook.sh -> plugin/hooks/"
render_json > "$json.tmp" && mv "$json.tmp" "$json"
echo "wrote plugin/hooks/hooks.json"
