#!/usr/bin/env bash
#
# uninstall.sh
#
# Removes everything install.sh added. Does NOT touch the telemetry MCP —
# that has its own uninstaller at nf-telemetry-installer.

set -euo pipefail

# ---- Bootstrap (curl-pipe uninstall) ----------------------------------------
#
# Same pattern as install.sh — if run standalone without the payload around
# us, fetch the latest published tarball and re-run from there. We need the
# payload because uninstall.sh enumerates skills/agents/commands from the
# source to know what to remove from ~/.claude/.

MIRROR_REPO="${NF_MIRROR_REPO:-neuraflash/nf-claude-assets-installer}"
MIRROR_TARBALL_URL="${NF_MIRROR_TARBALL_URL:-https://github.com/${MIRROR_REPO}/raw/main/latest.tar.gz}"

bootstrap() {
  command -v curl >/dev/null 2>&1 || { printf '[nf-assets] curl is required.\n' >&2; exit 1; }
  command -v tar  >/dev/null 2>&1 || { printf '[nf-assets] tar is required.\n' >&2; exit 1; }

  local tmp; tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT INT TERM

  printf '[nf-assets] Fetching uninstall payload from %s\n' "$MIRROR_TARBALL_URL"
  if ! curl -fsSL "$MIRROR_TARBALL_URL" -o "$tmp/payload.tar.gz"; then
    printf '[nf-assets] Failed to fetch payload tarball.\n' >&2
    exit 1
  fi

  mkdir -p "$tmp/payload"
  tar -xzf "$tmp/payload.tar.gz" -C "$tmp/payload"
  [ -f "$tmp/payload/uninstall.sh" ] || { printf '[nf-assets] Tarball missing uninstall.sh\n' >&2; exit 1; }

  local rc=0
  bash "$tmp/payload/uninstall.sh" "$@" || rc=$?
  exit "$rc"
}

NF_SELF="${BASH_SOURCE[0]:-$0}"
NF_SELF_DIR=""
if [ -f "$NF_SELF" ]; then
  NF_SELF_DIR="$(cd "$(dirname "$NF_SELF")" 2>/dev/null && pwd || true)"
fi

if [ -z "${REPO_ROOT:-}" ] && { [ -z "$NF_SELF_DIR" ] || [ ! -f "$NF_SELF_DIR/mcp/servers.json" ]; }; then
  bootstrap "$@"
fi

REPO_ROOT="${REPO_ROOT:-$NF_SELF_DIR}"

CLAUDE_HOME="$HOME/.claude"
CLAUDE_SKILLS="$CLAUDE_HOME/skills"
CLAUDE_AGENTS="$CLAUDE_HOME/agents"
CLAUDE_COMMANDS="$CLAUDE_HOME/commands"
CLAUDE_HOOKS="$CLAUDE_HOME/hooks"
CLAUDE_MD="$CLAUDE_HOME/CLAUDE.md"
CLAUDE_SETTINGS="$CLAUDE_HOME/settings.json"

case "$(uname -s)" in
  Darwin) DESKTOP_CFG="$HOME/Library/Application Support/Claude/claude_desktop_config.json" ;;
  Linux)  DESKTOP_CFG="${XDG_CONFIG_HOME:-$HOME/.config}/Claude/claude_desktop_config.json" ;;
esac

NF_BEGIN='<!-- BEGIN nf-claude-assets — do not edit, rewritten on every install -->'
NF_END='<!-- END nf-claude-assets -->'

log()  { printf '\033[1;34m[nf-assets]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[nf-assets]\033[0m %s\n' "$*" >&2; }

# Remove skills/agents/commands that this repo defines.
remove_code_assets() {
  for skill_dir in "$REPO_ROOT"/skills/*/; do
    name="$(basename "$skill_dir")"
    [ "$name" = "_template" ] && continue
    rm -rf "$CLAUDE_SKILLS/$name" && log "  removed skill: $name" || true
  done

  for f in "$REPO_ROOT"/agents/*.md; do
    [ -e "$f" ] || continue
    name="$(basename "$f")"
    [ "$name" = "_template.md" ] && continue
    rm -f "$CLAUDE_AGENTS/$name" && log "  removed agent: $name" || true
  done

  for f in "$REPO_ROOT"/commands/*.md; do
    [ -e "$f" ] || continue
    name="$(basename "$f")"
    [ "$name" = "_template.md" ] && continue
    rm -f "$CLAUDE_COMMANDS/$name" && log "  removed command: $name" || true
  done
}

# Strip the nf-claude-assets block from ~/.claude/CLAUDE.md, leave the rest.
clean_claude_md() {
  [ -f "$CLAUDE_MD" ] || return 0
  grep -qF "$NF_BEGIN" "$CLAUDE_MD" || return 0
  local tmp; tmp="$(mktemp)"
  awk -v begin="$NF_BEGIN" -v end="$NF_END" '
    $0 == begin { skipping = 1; next }
    $0 == end   { skipping = 0; next }
    !skipping   { print }
  ' "$CLAUDE_MD" > "$tmp"
  mv "$tmp" "$CLAUDE_MD"
  log "  stripped nf-claude-assets block from $CLAUDE_MD"
}

# Remove MCP entries defined in mcp/servers.json (both surfaces).
remove_mcp_servers() {
  local servers_json="$REPO_ROOT/mcp/servers.json"
  [ -f "$servers_json" ] || return 0
  command -v node >/dev/null 2>&1 || return 0

  if command -v claude >/dev/null 2>&1; then
    node -e '
      const fs = require("fs");
      const cfg = JSON.parse(fs.readFileSync(process.env.SERVERS, "utf8"));
      process.stdout.write(JSON.stringify(Object.keys(cfg.servers || {})));
    ' SERVERS="$servers_json" | python3 -c '
import json, subprocess, sys
for name in json.loads(sys.stdin.read()):
    subprocess.run(["claude", "mcp", "remove", name, "--scope", "user"],
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    print(f"[nf-assets]   removed code mcp: {name}")
'
  fi

  if [ -n "${DESKTOP_CFG:-}" ] && [ -f "$DESKTOP_CFG" ]; then
    local tmp; tmp="$(mktemp)"
    SERVERS="$servers_json" CFG="$DESKTOP_CFG" OUT="$tmp" node -e '
      const fs = require("fs");
      const src = JSON.parse(fs.readFileSync(process.env.SERVERS, "utf8"));
      const cfg = JSON.parse(fs.readFileSync(process.env.CFG, "utf8") || "{}");
      cfg.mcpServers = cfg.mcpServers || {};
      for (const name of Object.keys(src.servers || {})) {
        if (cfg.mcpServers[name]) {
          delete cfg.mcpServers[name];
          console.error(`[nf-assets]   removed desktop mcp: ${name}`);
        }
      }
      fs.writeFileSync(process.env.OUT, JSON.stringify(cfg, null, 2) + "\n");
    '
    mv "$tmp" "$DESKTOP_CFG"
  fi
}

# Remove telemetry hooks and strip their entries from settings.json.
remove_hooks() {
  local hooks_src="$REPO_ROOT/global/hooks"
  if [ -d "$hooks_src" ] && [ -d "$CLAUDE_HOOKS" ]; then
    for f in "$hooks_src"/*.sh; do
      [ -e "$f" ] || continue
      local name; name="$(basename "$f")"
      rm -f "$CLAUDE_HOOKS/$name" && log "  removed hook: $name" || true
    done
    # Clean up the dir if we left it empty.
    rmdir "$CLAUDE_HOOKS" 2>/dev/null || true
  fi

  [ -f "$CLAUDE_SETTINGS" ] || return 0
  command -v node >/dev/null 2>&1 || { warn "node not found — left $CLAUDE_SETTINGS untouched."; return 0; }

  local tmp; tmp="$(mktemp)"
  SETTINGS="$CLAUDE_SETTINGS" OUT="$tmp" node -e '
    const fs = require("fs");
    const cfg = JSON.parse(fs.readFileSync(process.env.SETTINGS, "utf8") || "{}");
    if (cfg.hooks) {
      const isOurs = (entry) =>
        (entry.hooks || []).some(h => h.command && h.command.includes("nf-telemetry-skill-"));
      for (const ev of Object.keys(cfg.hooks)) {
        cfg.hooks[ev] = (cfg.hooks[ev] || []).filter(e => !isOurs(e));
        if (cfg.hooks[ev].length === 0) delete cfg.hooks[ev];
      }
      if (Object.keys(cfg.hooks).length === 0) delete cfg.hooks;
    }
    fs.writeFileSync(process.env.OUT, JSON.stringify(cfg, null, 2) + "\n");
  '
  mv "$tmp" "$CLAUDE_SETTINGS"
  log "  stripped nf-telemetry hook entries from $CLAUDE_SETTINGS"
}

main() {
  log "Removing nf-claude-assets from this machine"
  remove_code_assets
  clean_claude_md
  remove_mcp_servers
  remove_hooks
  log "done."
}

main "$@"
