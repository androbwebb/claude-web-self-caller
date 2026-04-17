#!/bin/bash
# SessionStart hook: install the `remote-session` helper into this Claude
# Code session. Runs every time a session starts, so you always get the
# latest version from main (no env-cache staleness).
#
# Consumers: copy this file to your repo as .claude/hooks/session-start.sh
# and register it in .claude/settings.json. See the README for details.
set -euo pipefail

INSTALL_PATH="${REMOTE_SESSION_INSTALL_PATH:-$HOME/.remote-session.sh}"
RAW_URL="${REMOTE_SESSION_RAW_URL:-https://raw.githubusercontent.com/androbwebb/claude-web-self-caller/main/scripts/remote-session.sh}"

curl -fsSL "$RAW_URL" -o "$INSTALL_PATH"
chmod 644 "$INSTALL_PATH"

# Claude's Bash tool invokes `bash -c …` (non-interactive, non-login), so
# ~/.bashrc is NOT sourced. BASH_ENV is read on every `bash -c`, which
# preloads the function into every tool call. Persist it via CLAUDE_ENV_FILE
# so the variable survives past this hook.
if [ -n "${CLAUDE_ENV_FILE:-}" ]; then
  echo "export BASH_ENV=\"$INSTALL_PATH\"" >> "$CLAUDE_ENV_FILE"
fi

# Interactive shells: also source from .bashrc (idempotent).
BASHRC="$HOME/.bashrc"
touch "$BASHRC"
SOURCE_LINE="[ -f $INSTALL_PATH ] && . $INSTALL_PATH"
if ! grep -qxF "$SOURCE_LINE" "$BASHRC"; then
  printf '\n# remote-session (installed by SessionStart hook)\n%s\n' "$SOURCE_LINE" >> "$BASHRC"
fi
