#!/usr/bin/env bash
#
# install.sh
#
# Bootstrap installer for NeuraFlash Claude assets. Idempotent — rerunning
# upgrades skills/agents/commands and re-merges CLAUDE.md + MCP entries.
#
# Surfaces handled:
#   - Claude Code (always, if `claude` CLI is detected): skills, agents,
#     commands, ~/.claude/CLAUDE.md, MCP servers from mcp/servers.json
#   - Claude Desktop (always, if Desktop is detected): MCP servers only.
#     Skills are uploaded to the Team-license skills console, not installed
#     per-machine.
#
# Telemetry MCP is NOT installed here — run nf-telemetry-installer separately
# (see https://github.com/neuraflash/nf-telemetry-installer).
#
# Usage:
#   # From a clone of the source repo or the public mirror:
#   bash install.sh
#
#   # Direct, no clone (recommended for end users):
#   bash <(curl -fsSL https://raw.githubusercontent.com/neuraflash/nf-claude-assets-installer/main/install.sh)

set -euo pipefail

# ---- Bootstrap (curl-pipe install) ------------------------------------------
#
# When install.sh is run standalone — curl-piped or copied somewhere without
# the rest of the payload — fetch the latest published tarball into a temp
# dir and run install.sh from there. Local clones (payload sitting as
# siblings) skip the bootstrap.

MIRROR_REPO="${NF_MIRROR_REPO:-neuraflash/nf-claude-assets-installer}"
MIRROR_TARBALL_URL="${NF_MIRROR_TARBALL_URL:-https://github.com/${MIRROR_REPO}/raw/main/latest.tar.gz}"

bootstrap() {
  command -v curl >/dev/null 2>&1 || { printf '[nf-assets] curl is required.\n' >&2; exit 1; }
  command -v tar  >/dev/null 2>&1 || { printf '[nf-assets] tar is required.\n' >&2; exit 1; }

  local tmp; tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT INT TERM

  printf '[nf-assets] Fetching install payload from %s\n' "$MIRROR_TARBALL_URL"
  if ! curl -fsSL "$MIRROR_TARBALL_URL" -o "$tmp/payload.tar.gz"; then
    printf '[nf-assets] Failed to fetch payload tarball.\n' >&2
    exit 1
  fi

  mkdir -p "$tmp/payload"
  tar -xzf "$tmp/payload.tar.gz" -C "$tmp/payload"
  [ -f "$tmp/payload/install.sh" ] || { printf '[nf-assets] Tarball missing install.sh\n' >&2; exit 1; }

  local rc=0
  bash "$tmp/payload/install.sh" "$@" || rc=$?
  exit "$rc"
}

NF_SELF="${BASH_SOURCE[0]:-$0}"
NF_SELF_DIR=""
if [ -f "$NF_SELF" ]; then
  NF_SELF_DIR="$(cd "$(dirname "$NF_SELF")" 2>/dev/null && pwd || true)"
fi

# Bootstrap unless REPO_ROOT was explicitly set OR the payload is next to us.
if [ -z "${REPO_ROOT:-}" ] && { [ -z "$NF_SELF_DIR" ] || [ ! -f "$NF_SELF_DIR/mcp/servers.json" ]; }; then
  bootstrap "$@"
fi

# ---- Paths ------------------------------------------------------------------

REPO_ROOT="${REPO_ROOT:-$NF_SELF_DIR}"

CLAUDE_HOME="$HOME/.claude"
CLAUDE_SKILLS="$CLAUDE_HOME/skills"
CLAUDE_AGENTS="$CLAUDE_HOME/agents"
CLAUDE_COMMANDS="$CLAUDE_HOME/commands"
CLAUDE_HOOKS="$CLAUDE_HOME/hooks"
CLAUDE_MD="$CLAUDE_HOME/CLAUDE.md"
CLAUDE_SETTINGS="$CLAUDE_HOME/settings.json"

case "$(uname -s)" in
  Darwin)
    DESKTOP_CFG="$HOME/Library/Application Support/Claude/claude_desktop_config.json"
    DESKTOP_APP_DIR="$HOME/Library/Application Support/Claude"
    ;;
  Linux)
    DESKTOP_CFG="${XDG_CONFIG_HOME:-$HOME/.config}/Claude/claude_desktop_config.json"
    DESKTOP_APP_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/Claude"
    ;;
  *)
    echo "Unsupported OS: $(uname -s). This script targets macOS and Linux." >&2
    exit 1
    ;;
esac

# Markers for the CLAUDE.md merge block — anything between these is owned by
# this installer and rewritten on every run. Content outside the markers is
# left alone.
NF_BEGIN='<!-- BEGIN nf-claude-assets — do not edit, rewritten on every install -->'
NF_END='<!-- END nf-claude-assets -->'

# ---- Logging ----------------------------------------------------------------

log()  { printf '\033[1;34m[nf-assets]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[nf-assets]\033[0m %s\n' "$*" >&2; }
fail() { printf '\033[1;31m[nf-assets]\033[0m %s\n' "$*" >&2; exit 1; }

# ---- Build skills (if author hasn't already) --------------------------------

build_skills() {
  if [ -x "$REPO_ROOT/scripts/build-skills.sh" ]; then
    log "Building SKILL.md files from body.md sources"
    "$REPO_ROOT/scripts/build-skills.sh" >/dev/null
  fi
}

# ---- Copy skills / agents / commands to ~/.claude ---------------------------

install_code_assets() {
  if ! command -v claude >/dev/null 2>&1; then
    log "Claude Code (claude CLI) not detected — skipping Code asset install."
    return 0
  fi

  log "Installing Code assets to $CLAUDE_HOME"
  mkdir -p "$CLAUDE_SKILLS" "$CLAUDE_AGENTS" "$CLAUDE_COMMANDS"

  # Skills — copy every dir except _template
  for skill_dir in "$REPO_ROOT"/skills/*/; do
    name="$(basename "$skill_dir")"
    [ "$name" = "_template" ] && continue
    if [ ! -f "$skill_dir/SKILL.md" ]; then
      warn "skipping $name (no SKILL.md — did build-skills.sh run?)"
      continue
    fi
    dest="$CLAUDE_SKILLS/$name"
    rm -rf "$dest"
    cp -R "$skill_dir" "$dest"
    log "  skill: $name"
  done

  # Agents — copy every .md except _template.md
  for f in "$REPO_ROOT"/agents/*.md; do
    [ -e "$f" ] || continue
    name="$(basename "$f")"
    [ "$name" = "_template.md" ] && continue
    cp "$f" "$CLAUDE_AGENTS/$name"
    log "  agent: $name"
  done

  # Commands — copy every .md except _template.md
  for f in "$REPO_ROOT"/commands/*.md; do
    [ -e "$f" ] || continue
    name="$(basename "$f")"
    [ "$name" = "_template.md" ] && continue
    cp "$f" "$CLAUDE_COMMANDS/$name"
    log "  command: $name"
  done
}

# ---- Merge global CLAUDE.md ------------------------------------------------

merge_claude_md() {
  command -v claude >/dev/null 2>&1 || return 0

  log "Merging global rules into $CLAUDE_MD"
  mkdir -p "$CLAUDE_HOME"
  touch "$CLAUDE_MD"

  local block
  block="$(printf '%s\n%s\n%s\n' "$NF_BEGIN" "$(cat "$REPO_ROOT/global/CLAUDE.md")" "$NF_END")"

  # If markers already exist, replace the block between them. Otherwise append.
  if grep -qF "$NF_BEGIN" "$CLAUDE_MD"; then
    # Use awk to splice — keeps everything before BEGIN and after END untouched.
    local tmp
    tmp="$(mktemp)"
    awk -v begin="$NF_BEGIN" -v end="$NF_END" -v block="$block" '
      $0 == begin { print block; skipping = 1; next }
      $0 == end   { skipping = 0; next }
      !skipping   { print }
    ' "$CLAUDE_MD" > "$tmp"
    mv "$tmp" "$CLAUDE_MD"
  else
    {
      [ -s "$CLAUDE_MD" ] && echo
      echo "$block"
    } >> "$CLAUDE_MD"
  fi
}

# ---- MCP servers (both surfaces) -------------------------------------------

install_mcp_servers() {
  local servers_json="$REPO_ROOT/mcp/servers.json"
  [ -f "$servers_json" ] || { log "No mcp/servers.json — skipping MCP install."; return 0; }

  if ! command -v node >/dev/null 2>&1; then
    warn "node not found — skipping MCP install. Install Node 18+ and rerun."
    return 0
  fi

  # Soft-check for tools the wired MCPs depend on. Don't fail the install —
  # the MCP entries still get written; the user just can't *use* the MCP
  # until the underlying tool is present.
  command -v sf >/dev/null 2>&1 \
    || warn "Salesforce CLI ('sf') not found. The salesforce-dx MCP will register but won't work until you install it (https://developer.salesforce.com/tools/sfdxcli) and run 'sf org login web'."

  log "Installing MCP servers from $servers_json"

  # Code: use `claude mcp add` for each server marked claude_code.
  if command -v claude >/dev/null 2>&1; then
    SERVERS="$servers_json" node -e '
      const fs = require("fs");
      const cfg = JSON.parse(fs.readFileSync(process.env.SERVERS, "utf8"));
      const out = [];
      for (const [name, def] of Object.entries(cfg.servers || {})) {
        if (!(def.surfaces || []).includes("claude_code")) continue;
        out.push({ name, def });
      }
      process.stdout.write(JSON.stringify(out));
    ' | python3 -c '
import json, os, subprocess, sys
for entry in json.loads(sys.stdin.read()):
    name, d = entry["name"], entry["def"]
    subprocess.run(["claude", "mcp", "remove", name, "--scope", d.get("scope", "user")],
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    cmd = ["claude", "mcp", "add", name, d["command"], *d.get("args", []),
           "--scope", d.get("scope", "user")]
    for k, v in (d.get("env") or {}).items():
        cmd += ["--env", f"{k}={v}"]
    subprocess.check_call(cmd)
    print(f"[nf-assets]   code mcp: {name}")
'
  fi

  # Desktop: atomic merge into claude_desktop_config.json.
  if [ -d "$DESKTOP_APP_DIR" ]; then
    [ -f "$DESKTOP_CFG" ] || echo '{}' > "$DESKTOP_CFG"
    local tmp
    tmp="$(mktemp)"
    SERVERS="$servers_json" CFG="$DESKTOP_CFG" OUT="$tmp" node -e '
      const fs = require("fs");
      const src = JSON.parse(fs.readFileSync(process.env.SERVERS, "utf8"));
      const cfg = JSON.parse(fs.readFileSync(process.env.CFG, "utf8") || "{}");
      cfg.mcpServers = cfg.mcpServers || {};
      for (const [name, def] of Object.entries(src.servers || {})) {
        if (!(def.surfaces || []).includes("claude_desktop")) continue;
        cfg.mcpServers[name] = {
          command: def.command,
          args:    def.args || [],
          env:     def.env || {}
        };
        console.error(`[nf-assets]   desktop mcp: ${name}`);
      }
      fs.writeFileSync(process.env.OUT, JSON.stringify(cfg, null, 2) + "\n");
    '
    mv "$tmp" "$DESKTOP_CFG"
  fi
}

# ---- Telemetry hooks (Claude Code) -----------------------------------------
#
# Installs the PreToolUse / PostToolUse hooks that capture every Skill
# invocation (including third-party skills that don't emit telemetry
# themselves). Desktop has no equivalent hook system — for Desktop coverage
# of third-party skills, use scripts/wrap-thirdparty-skill.sh before upload.

install_hooks() {
  command -v claude >/dev/null 2>&1 || return 0

  local hooks_src="$REPO_ROOT/global/hooks"
  [ -d "$hooks_src" ] || { log "No global/hooks/ — skipping hook install."; return 0; }

  log "Installing telemetry hooks to $CLAUDE_HOOKS"
  mkdir -p "$CLAUDE_HOOKS"
  for f in "$hooks_src"/*.sh; do
    [ -e "$f" ] || continue
    local name; name="$(basename "$f")"
    cp "$f" "$CLAUDE_HOOKS/$name"
    chmod +x "$CLAUDE_HOOKS/$name"
    log "  hook: $name"
  done

  if ! command -v node >/dev/null 2>&1; then
    warn "node not found — hook scripts copied but $CLAUDE_SETTINGS not wired. Install Node 18+ and rerun."
    return 0
  fi

  [ -f "$CLAUDE_SETTINGS" ] || echo '{}' > "$CLAUDE_SETTINGS"
  local tmp; tmp="$(mktemp)"
  SETTINGS="$CLAUDE_SETTINGS" HOOKS_DIR="$CLAUDE_HOOKS" OUT="$tmp" node -e '
    const fs = require("fs");
    const startCmd = `${process.env.HOOKS_DIR}/nf-telemetry-skill-start.sh`;
    const endCmd   = `${process.env.HOOKS_DIR}/nf-telemetry-skill-end.sh`;
    const cfg = JSON.parse(fs.readFileSync(process.env.SETTINGS, "utf8") || "{}");
    cfg.hooks = cfg.hooks || {};

    const isOurs = (entry) =>
      (entry.hooks || []).some(h => h.command && h.command.includes("nf-telemetry-skill-"));

    const upsert = (event, cmd) => {
      cfg.hooks[event] = (cfg.hooks[event] || []).filter(e => !isOurs(e));
      cfg.hooks[event].push({ matcher: "Skill", hooks: [{ type: "command", command: cmd }] });
    };

    upsert("PreToolUse",  startCmd);
    upsert("PostToolUse", endCmd);

    fs.writeFileSync(process.env.OUT, JSON.stringify(cfg, null, 2) + "\n");
  '
  mv "$tmp" "$CLAUDE_SETTINGS"
  log "  hooks wired into $CLAUDE_SETTINGS (matcher: Skill)"
}

# ---- Main -------------------------------------------------------------------

main() {
  log "nf-claude-assets installer (version $(cat "$REPO_ROOT/VERSION" 2>/dev/null || echo unknown))"

  build_skills
  install_code_assets
  merge_claude_md
  install_mcp_servers
  install_hooks

  cat <<EOF

[nf-assets] done.

Next steps:
  • Open a new Claude Code session to pick up new skills/agents/commands.
  • Restart Claude Desktop if any MCP entries changed.
  • First-time MCP auth (only the ones you plan to use):
      - lucid       : opens browser on first call (OAuth via mcp-remote)
      - atlassian   : opens browser on first call (OAuth via mcp-remote)
      - gdrive      : run 'npx -y @modelcontextprotocol/server-gdrive auth' once
      - salesforce-dx: 'sf org login web' (Salesforce CLI must be installed)
  • If you have not installed the telemetry MCP yet:
      bash <(curl -fsSL https://raw.githubusercontent.com/neuraflash/nf-telemetry-installer/main/install.sh)
  • Telemetry hooks (Claude Code) are wired but no-op until the telemetry
    env vars are set. If you've run nf-telemetry-installer, both vars are
    typically exported in your shell profile already:
      export TELEMETRY_ENDPOINT="<collector URL>"
      export TELEMETRY_TOKEN="<bearer token>"
    (Same vars the mcp-telemetry-emitter server reads — single source of
    truth.)
EOF
}

main "$@"
