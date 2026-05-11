#!/usr/bin/env bash
#
# build-skills.sh
#
# For each skills/<name>/body.md, generate skills/<name>/SKILL.md by inserting
# the global Step 0 / Step N telemetry blocks. Idempotent — overwrites SKILL.md
# on every run.
#
# Skill author contract for body.md:
#   - Starts with a YAML frontmatter block (--- ... ---) containing `name` and
#     `description`.
#   - The rest of the file is the skill body. Do NOT include Step 0 / Step N
#     blocks; the build script adds them.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PREAMBLE="$ROOT/global/SKILL_PREAMBLE.md"
POSTAMBLE="$ROOT/global/SKILL_POSTAMBLE.md"

[ -f "$PREAMBLE" ]  || { echo "missing $PREAMBLE"  >&2; exit 1; }
[ -f "$POSTAMBLE" ] || { echo "missing $POSTAMBLE" >&2; exit 1; }

built=0
for skill_dir in "$ROOT"/skills/*/; do
  name="$(basename "$skill_dir")"
  body="$skill_dir/body.md"
  out="$skill_dir/SKILL.md"

  if [ ! -f "$body" ]; then
    echo "skip $name (no body.md)" >&2
    continue
  fi

  # Split frontmatter (between first two '---' lines) from body content.
  # Output: <frontmatter><blank line><preamble><body-without-frontmatter><postamble>
  awk -v preamble="$PREAMBLE" -v postamble="$POSTAMBLE" '
    BEGIN { in_fm = 0; fm_done = 0 }
    NR == 1 && /^---[[:space:]]*$/ { in_fm = 1; print; next }
    in_fm && /^---[[:space:]]*$/   { in_fm = 0; fm_done = 1; print
      print ""
      while ((getline line < preamble) > 0) print line
      close(preamble)
      next
    }
    in_fm { print; next }
    fm_done { print }
    END {
      print ""
      while ((getline line < postamble) > 0) print line
      close(postamble)
    }
  ' "$body" > "$out"

  echo "built $name → $out"
  built=$((built + 1))
done

echo
echo "built $built skill(s)."
