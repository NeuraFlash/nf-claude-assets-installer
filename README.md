# nf-claude-assets-installer

Public install payload for [NeuraFlash](https://neuraflash.com)'s internal
Claude assets — skills, subagents, slash commands, global rules, and MCP server
wiring for both **Claude Code** and **Claude Desktop**.

> ⚠️ Auto-published from a private source repo on every release tag.
> Don't open PRs or push directly — your changes will be wiped on the next
> publish.

## Install

```sh
bash <(curl -fsSL https://raw.githubusercontent.com/neuraflash/nf-claude-assets-installer/main/install.sh)
```

That one-liner downloads the latest payload tarball into a temp dir and runs
the installer from there — no clone, no manual unpack. Idempotent: rerun any
time to upgrade.

## Uninstall

```sh
bash <(curl -fsSL https://raw.githubusercontent.com/neuraflash/nf-claude-assets-installer/main/uninstall.sh)
```

Removes only what the installer added. Anything in `~/.claude/CLAUDE.md`
outside the `nf-claude-assets` marker block is preserved.

## What gets installed

| Asset            | Destination                                  | Surface                |
| ---------------- | -------------------------------------------- | ---------------------- |
| Skills           | `~/.claude/skills/`                          | Claude Code            |
| Subagents        | `~/.claude/agents/`                          | Claude Code            |
| Slash commands   | `~/.claude/commands/`                        | Claude Code            |
| Global rules     | `~/.claude/CLAUDE.md` (between markers)      | Claude Code            |
| Telemetry hooks  | `~/.claude/hooks/` + `~/.claude/settings.json` (`PreToolUse`/`PostToolUse` on `Skill`) | Claude Code |
| MCP servers      | `claude mcp add` + `claude_desktop_config`   | Claude Code + Desktop  |

Claude Desktop skills are uploaded once at the Team-license level and propagate
automatically — they are not installed per-machine.

### MCP servers wired

| Name            | Purpose                                          | First-use auth                                              |
| --------------- | ------------------------------------------------ | ----------------------------------------------------------- |
| `context7`      | Library / framework / API docs lookup            | none                                                        |
| `gdrive`        | Google Drive — list, search, read files          | `npx -y @modelcontextprotocol/server-gdrive auth` once      |
| `lucid`         | Lucidchart / Lucidspark — search, read, generate | browser OAuth on first call                                 |
| `atlassian`     | Jira + Confluence                                | browser OAuth on first call                                 |
| `salesforce-dx` | Salesforce orgs, metadata, data, users, testing  | `sf org login web` (requires `sf` CLI)                      |

> The **telemetry MCP** is intentionally not installed here — install it
> separately via [`nf-telemetry-installer`](https://github.com/neuraflash/nf-telemetry-installer).

## Telemetry coverage for third-party skills

The installer wires two Claude Code hooks (`PreToolUse` / `PostToolUse`,
matcher `Skill`) that capture **every** skill invocation — first-party,
third-party, anything. The Pre hook stashes start state keyed by Claude
Code's `tool_use_id`; the Post hook reads it, computes duration, and POSTs
one event (matching the `mcp-telemetry-emitter` wire format) to your
collector with `source: "hook"` so the server can dedupe against events
that the in-skill MCP path also emits.

The hooks are no-ops until both env vars are exported — the same vars the
telemetry MCP server reads, so a single shell profile entry covers both
code paths:

```sh
export TELEMETRY_ENDPOINT="<collector URL>"
export TELEMETRY_TOKEN="<bearer token>"
```

If you've already run [`nf-telemetry-installer`](https://github.com/neuraflash/nf-telemetry-installer)
these are typically set for you. If not, get them from the same source.

**Claude Desktop has no hooks.** To track third-party skills uploaded to the
Team-license skills console, wrap their `SKILL.md` first:

```sh
scripts/wrap-thirdparty-skill.sh path/to/foreign/SKILL.md > wrapped-SKILL.md
```

…then upload `wrapped-SKILL.md` instead. The wrap script splices the
`skill_start` / `skill_end` telemetry contract into the skill body and is a
no-op on already-wrapped files.

## Requirements

- macOS or Linux
- `curl`, `tar`, `bash` (preinstalled on macOS / most Linux distros)
- Node 18+
- Claude Code (`claude` CLI) and/or Claude Desktop
- Salesforce CLI (`sf`) — only if you use the `salesforce-dx` MCP

If `node` is missing, the installer exits with a clear message. If `sf` is
missing, it warns but still wires the MCP entry so it'll work the moment you
install the CLI.

## Verifying the install

```sh
claude mcp list
```

You should see `context7`, `gdrive`, `lucid`, `atlassian`, `salesforce-dx`.
New skills/agents/commands appear in `~/.claude/{skills,agents,commands}/`.

## Pinning a specific version

The current version is in [`VERSION`](./VERSION). Versioned tarballs ship with
every release if you'd rather not always run `latest`:

```sh
VERSION=0.2.0
curl -fsSL "https://github.com/neuraflash/nf-claude-assets-installer/raw/main/nf-claude-assets-${VERSION}.tar.gz" -o assets.tar.gz
mkdir -p assets && tar -xzf assets.tar.gz -C assets
bash assets/install.sh
```

## License

UNLICENSED — internal NeuraFlash use only.
