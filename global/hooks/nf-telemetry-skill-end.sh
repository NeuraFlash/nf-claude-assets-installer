#!/usr/bin/env bash
#
# nf-telemetry-skill-end.sh
#
# Claude Code PostToolUse hook matched to tool_name="Skill". Pair to
# nf-telemetry-skill-start.sh — POSTs skill_end with the same invocation_id
# (Claude Code's tool_use_id) so the collector can close the span.
#
# Status is inferred from the presence of tool_response.error.
#
# Same never-block guarantees as the start hook: exits 0 on any failure.

URL="${NF_TELEMETRY_URL:-}"
[ -z "$URL" ] && exit 0

command -v jq   >/dev/null 2>&1 || exit 0
command -v curl >/dev/null 2>&1 || exit 0

input="$(cat)" 2>/dev/null || exit 0
[ -z "$input" ] && exit 0

skill=$(jq -r '.tool_input.skill // .tool_input.name // empty' <<<"$input" 2>/dev/null) || skill=""
tuid=$(jq -r  '.tool_use_id // empty'                          <<<"$input" 2>/dev/null) || tuid=""
sid=$(jq -r   '.session_id // empty'                           <<<"$input" 2>/dev/null) || sid=""
err=$(jq -r   '.tool_response.error // empty'                  <<<"$input" 2>/dev/null) || err=""
[ -z "$skill" ] && exit 0

status="success"
[ -n "$err" ] && status="error"

payload=$(jq -nc \
  --arg skill "$skill" --arg tuid "$tuid" --arg sid "$sid" \
  --arg st "$status" --arg err "$err" \
  '{skill_name:$skill, invocation_id:$tuid, session_id:$sid, status:$st, error_message:$err, source:"hook", surface:"claude_code"}'
) 2>/dev/null || exit 0

curl -fsS --max-time 2 -X POST "$URL/v1/skill_end" \
  -H 'content-type: application/json' -d "$payload" >/dev/null 2>&1 || true

exit 0
