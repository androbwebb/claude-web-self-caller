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
#   - interactive shells (via ~/.bashrc and/or ~/.zshrc source line)
#   - Claude's Bash tool (via BASH_ENV, so `bash -c '...'` preloads it)
#
# Install from a non-main branch (e.g. to try a PR before merge):
#   REMOTE_SESSION_REF=my-branch curl -fsSL \
#     "https://raw.githubusercontent.com/androbwebb/claude-web-self-caller/my-branch/scripts/env-install.sh" | bash
set -euo pipefail

REF="${REMOTE_SESSION_REF:-main}"
RAW_URL="${REMOTE_SESSION_RAW_URL:-https://raw.githubusercontent.com/androbwebb/claude-web-self-caller/${REF}/scripts/remote-session.sh}"
INSTALL_PATH="${REMOTE_SESSION_INSTALL_PATH:-$HOME/.remote-session.sh}"

echo "[env-install] fetching $RAW_URL"
curl -fsSL "$RAW_URL" -o "$INSTALL_PATH"
chmod 644 "$INSTALL_PATH"

# Interactive shells: add source line to whichever rc files exist (idempotent).
# Covers bash (.bashrc) and zsh (.zshrc) — macOS users default to zsh.
SOURCE_LINE="[ -f $INSTALL_PATH ] && . $INSTALL_PATH"
RC_FILES=()
[ -f "$HOME/.bashrc" ] && RC_FILES+=("$HOME/.bashrc")
[ -f "$HOME/.zshrc" ]  && RC_FILES+=("$HOME/.zshrc")
if [ "${#RC_FILES[@]}" -eq 0 ]; then
  case "${SHELL##*/}" in
    zsh) RC_FILES+=("$HOME/.zshrc") ;;
    *)   RC_FILES+=("$HOME/.bashrc") ;;
  esac
  touch "${RC_FILES[0]}"
fi
for rc in "${RC_FILES[@]}"; do
  if ! grep -qxF "$SOURCE_LINE" "$rc"; then
    printf '\n# remote-session helper (installed by env-install.sh)\n%s\n' "$SOURCE_LINE" >> "$rc"
    echo "[env-install] added source line to $rc"
  else
    echo "[env-install] $rc already sources $INSTALL_PATH"
  fi
done

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
  # Fallback: append BASH_ENV export to each rc file. Won't cover truly
  # non-interactive `bash -c` calls unless the parent env exports BASH_ENV,
  # but it's enough for shells the user spawns themselves.
  for rc in "${RC_FILES[@]}"; do
    if ! grep -qxF "export BASH_ENV=$INSTALL_PATH" "$rc"; then
      echo "export BASH_ENV=$INSTALL_PATH" >> "$rc"
    fi
  done
  echo "[env-install] no write access to /etc/profile.d; set BASH_ENV in ${RC_FILES[*]}"
fi

cat <<EOF
[env-install] done.
  Open a new shell (or run \`source $INSTALL_PATH\`), then:
    remote-session help          # full usage
    remote-session setup-token   # interactive OAuth login (first-time setup)
EOF
