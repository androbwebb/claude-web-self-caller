#!/usr/bin/env bash
# Install a SessionStart hook into the CURRENT repo so every Claude Code
# session that opens this repo gets the `remote-session` helper preloaded.
# Unlike env-install.sh (which snapshots into the env filesystem), this
# runs on every session start and always fetches the latest script.
#
# Usage (from inside the target repo):
#   curl -fsSL https://raw.githubusercontent.com/androbwebb/claude-web-self-caller/main/scripts/install-hook.sh | bash
set -euo pipefail

RAW_BASE="${REMOTE_SESSION_RAW_BASE:-https://raw.githubusercontent.com/androbwebb/claude-web-self-caller/main}"

if [ ! -d .git ] && [ -z "${ALLOW_NON_REPO:-}" ]; then
  echo "[install-hook] no .git here; run from your repo root (or set ALLOW_NON_REPO=1)" >&2
  exit 1
fi

mkdir -p .claude/hooks
HOOK_PATH=".claude/hooks/session-start.sh"
SETTINGS_PATH=".claude/settings.json"

echo "[install-hook] fetching $RAW_BASE/.claude/hooks/session-start.sh -> $HOOK_PATH"
curl -fsSL "$RAW_BASE/.claude/hooks/session-start.sh" -o "$HOOK_PATH"
chmod +x "$HOOK_PATH"

# Merge hook registration into .claude/settings.json. Create if missing.
if [ -f "$SETTINGS_PATH" ]; then
  if command -v jq >/dev/null 2>&1; then
    tmp=$(mktemp)
    jq '.hooks.SessionStart //= [] |
        (.hooks.SessionStart | map(.hooks[]?.command) | index("$CLAUDE_PROJECT_DIR/.claude/hooks/session-start.sh")) as $idx |
        if $idx == null then
          .hooks.SessionStart += [{"hooks":[{"type":"command","command":"$CLAUDE_PROJECT_DIR/.claude/hooks/session-start.sh"}]}]
        else . end' "$SETTINGS_PATH" > "$tmp" && mv "$tmp" "$SETTINGS_PATH"
    echo "[install-hook] merged SessionStart entry into $SETTINGS_PATH"
  else
    echo "[install-hook] jq not found; $SETTINGS_PATH exists — please add manually:" >&2
    echo '  .hooks.SessionStart[].hooks[] = { "type": "command", "command": "$CLAUDE_PROJECT_DIR/.claude/hooks/session-start.sh" }' >&2
    exit 1
  fi
else
  cat > "$SETTINGS_PATH" <<'JSON'
{
  "hooks": {
    "SessionStart": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "$CLAUDE_PROJECT_DIR/.claude/hooks/session-start.sh"
          }
        ]
      }
    ]
  }
}
JSON
  echo "[install-hook] wrote $SETTINGS_PATH"
fi

echo "[install-hook] done. Commit $HOOK_PATH and $SETTINGS_PATH; new sessions will preload remote-session."
