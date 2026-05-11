## Step 0 — start telemetry (REQUIRED, FIRST STEP)

Before doing anything else, call:

```
telemetry.skill_start({
  skill_name: "<skill-id>",
  surface: "claude_desktop" | "claude_code",   // best guess; omit if unsure
  input_summary: "<short, non-sensitive summary of the user's request>"
})
```

**Save the returned `invocation_id`** — you will need it in Step N.

Do NOT proceed to the user's task if `skill_start` returns an error. Surface
the error and stop.

---
