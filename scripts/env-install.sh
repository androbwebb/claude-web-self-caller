#!/usr/bin/env bash
# Env setup-script installer for the `remote-session` helper.
#
# Paste this into your Claude Code environment's setup script (or invoke via
# curl | bash from a larger setup script):
#
#   curl -fsSL https://raw.githubusercontent.com/androbwebb/claude-web-self-caller/main/scripts/env-install.sh | bash
#
# Also you can set this env var in the environment config so the orgUUID lookup
# doesn't have to hit /api/oauth/profile (which needs user:profile scope):
#
#   CLAUDE_CODE_ORGANIZATION_UUID=<your-org-uuid>
#
# After this runs, `remote-session` is available in:
#   - interactive shells (via ~/.bashrc source line)
#   - Claude's Bash tool (via BASH_ENV, so `bash -c '...'` preloads it)
set -euo pipefail

RAW_URL="${REMOTE_SESSION_RAW_URL:-https://raw.githubusercontent.com/androbwebb/claude-web-self-caller/main/scripts/remote-session.sh}"
INSTALL_PATH="${REMOTE_SESSION_INSTALL_PATH:-$HOME/.remote-session.sh}"

echo "[env-install] fetching $RAW_URL"
curl -fsSL "$RAW_URL" -o "$INSTALL_PATH"
chmod 644 "$INSTALL_PATH"

# Interactive shells: source it from .bashrc (idempotent).
BASHRC="$HOME/.bashrc"
touch "$BASHRC"
SOURCE_LINE="[ -f $INSTALL_PATH ] && . $INSTALL_PATH"
if ! grep -qxF "$SOURCE_LINE" "$BASHRC"; then
  printf '\n# remote-session helper (installed by env-install.sh)\n%s\n' "$SOURCE_LINE" >> "$BASHRC"
  echo "[env-install] added source line to $BASHRC"
fi

# Non-interactive shells (Claude's Bash tool): BASH_ENV is read on every
# `bash -c`. Export it from /etc/profile.d so it's inherited globally.
PROFILE_D="/etc/profile.d/remote-session.sh"
if [ -w /etc/profile.d ] || [ -w /etc ]; then
  sudo=""
  if [ ! -w /etc/profile.d ]; then sudo="sudo"; fi
  $sudo tee "$PROFILE_D" > /dev/null <<EOF
export BASH_ENV="$INSTALL_PATH"
EOF
  echo "[env-install] wrote $PROFILE_D (sets BASH_ENV=$INSTALL_PATH)"
else
  # Fallback: append BASH_ENV export to ~/.bash_env and set it in .bashrc.
  # Won't cover truly non-interactive `bash -c` calls unless the env
  # already exports BASH_ENV, but better than nothing.
  echo "export BASH_ENV=$INSTALL_PATH" >> "$BASHRC"
  echo "[env-install] no write access to /etc/profile.d; set BASH_ENV in $BASHRC only"
fi

echo "[env-install] done. Commands: $(bash -c "source $INSTALL_PATH && remote-session help 2>&1 | tail -n +3 | head -8" | sed 's/^/  /')"
