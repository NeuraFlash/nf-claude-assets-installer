#!/usr/bin/env bash
#
# lint-skills.sh
#
# Sanity checks every skills/<name>/SKILL.md:
#   - Has a YAML frontmatter block with `name` and `description`.
#   - Contains the Step 0 telemetry block.
#   - Contains the Step N telemetry block.
#   - Skill `name` field starts with `neuraflash-`.
#
# Exits non-zero if any check fails. Run in CI on every PR.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

fail=0
warn()   { printf '\033[1;33m[lint]\033[0m %s\n' "$*" >&2; fail=1; }
notice() { printf '\033[1;36m[lint]\033[0m %s\n' "$*" >&2; }      # informational, never fails
ok()     { printf '\033[1;32m[lint]\033[0m %s\n' "$*"; }

for skill_dir in "$ROOT"/skills/*/; do
  name="$(basename "$skill_dir")"
  skill="$skill_dir/SKILL.md"

  if [ ! -f "$skill" ]; then
    warn "$name: SKILL.md missing — run scripts/build-skills.sh"
    continue
  fi

  # Frontmatter present
  if ! head -1 "$skill" | grep -q '^---$'; then
    warn "$name: SKILL.md does not start with '---' frontmatter"
    continue
  fi

  # Required frontmatter fields
  for field in name description; do
    if ! awk '/^---$/{c++; next} c==1' "$skill" | grep -q "^${field}:"; then
      warn "$name: missing '$field:' in frontmatter"
    fi
  done

  # name prefix
  fm_name="$(awk '/^---$/{c++; next} c==1' "$skill" | awk -F': *' '/^name:/{print $2; exit}')"
  if [ "$name" = "_template" ]; then
    : # template is exempt from prefix check
  elif [[ "$fm_name" != neuraflash-* && "$fm_name" != nf-* ]]; then
    notice "$name: frontmatter name '$fm_name' does not use the 'neuraflash-' or 'nf-' prefix (allowed, just FYI)"
  fi

  # Telemetry contract
  grep -q 'telemetry.skill_start'  "$skill" || warn "$name: missing Step 0 (telemetry.skill_start)"
  grep -q 'telemetry.skill_end'    "$skill" || warn "$name: missing Step N (telemetry.skill_end)"

  [ $fail -eq 0 ] && ok "$name"
done

if [ $fail -ne 0 ]; then
  echo
  echo "lint failed." >&2
  exit 1
fi

echo
echo "all skills passed lint."
