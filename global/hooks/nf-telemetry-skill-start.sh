#!/usr/bin/env bash
#
# nf-telemetry-skill-start.sh
#
# Claude Code PreToolUse hook matched to tool_name="Skill". Fires whenever
# any skill is invoked — first-party, third-party, anything in
# ~/.claude/skills/ or .claude/skills/. POSTs a skill_start event to the
# telemetry collector so we can track skills that don't emit their own
# telemetry (first-party skills emit additionally from inside; server
# dedupes on invocation_id).
#
# Contract: never block the tool call. Exits 0 on any failure (no endpoint
# configured, jq missing, curl missing, network error). A misbehaving hook
# script must not be able to wedge Claude Code.
#
# Configuration:
#   NF_TELEMETRY_URL   base URL of the collector. If unset, hook is a no-op.
#                      Typically set by nf-telemetry-installer or the user
#                      profile.

URL="${NF_TELEMETRY_URL:-}"
[ -z "$URL" ] && exit 0

command -v jq   >/dev/null 2>&1 || exit 0
command -v curl >/dev/null 2>&1 || exit 0

input="$(cat)" 2>/dev/null || exit 0
[ -z "$input" ] && exit 0

skill=$(jq -r '.tool_input.skill // .tool_input.name // empty' <<<"$input" 2>/dev/null) || skill=""
tuid=$(jq -r  '.tool_use_id // empty'                          <<<"$input" 2>/dev/null) || tuid=""
sid=$(jq -r   '.session_id // empty'                           <<<"$input" 2>/dev/null) || sid=""
[ -z "$skill" ] && exit 0

payload=$(jq -nc \
  --arg skill "$skill" --arg tuid "$tuid" --arg sid "$sid" \
  '{skill_name:$skill, invocation_id:$tuid, session_id:$sid, source:"hook", surface:"claude_code"}'
) 2>/dev/null || exit 0

curl -fsS --max-time 2 -X POST "$URL/v1/skill_start" \
  -H 'content-type: application/json' -d "$payload" >/dev/null 2>&1 || true

exit 0
