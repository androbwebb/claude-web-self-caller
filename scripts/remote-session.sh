# shellcheck shell=bash
# Remote session API helper. Source this file (e.g. from ~/.bashrc) and then
# call `remote-session <cmd> [args]` in any Claude Code session.
#
# Install from an environment setup script:
#   curl -fsSL https://raw.githubusercontent.com/androbwebb/claude-web-self-caller/main/scripts/remote-session.sh \
#     -o ~/.remote-session.sh
#   echo '[ -f ~/.remote-session.sh ] && . ~/.remote-session.sh' >> ~/.bashrc
#
# Auth: reads $CLAUDE_OAUTH_TOKEN, else /home/claude/.claude/remote/.oauth_token.
# Org UUID: $CLAUDE_CODE_ORGANIZATION_UUID, else GET /api/oauth/profile.
# Refresh: if $CLAUDE_OAUTH_REFRESH_TOKEN is set, any 401/403 from a session
#   API call triggers a one-shot refresh + retry.
# Don't have a token? Run `remote-session setup-token` for an interactive
# OAuth (PKCE) flow that prints the env vars to add to your Remote
# Environment configuration.
#
# Needs: curl, jq. `setup-token` also needs openssl.

remote-session() {
  local base="https://api.anthropic.com"
  local beta="ccr-byoc-2025-07-29"
  local version="2023-06-01"

  _rs_uuid() {
    if command -v uuidgen >/dev/null 2>&1; then
      uuidgen | tr '[:upper:]' '[:lower:]'
    elif [ -r /proc/sys/kernel/random/uuid ]; then
      cat /proc/sys/kernel/random/uuid
    else
      python3 -c 'import uuid;print(uuid.uuid4())' 2>/dev/null \
        || { echo "remote-session: need uuidgen, /proc/sys/kernel/random/uuid, or python3" >&2; return 1; }
    fi
  }

  _rs_token() {
    if [ -n "$_RS_ACCESS_CACHE" ]; then
      printf '%s' "$_RS_ACCESS_CACHE"
    elif [ -n "$CLAUDE_OAUTH_TOKEN" ]; then
      printf '%s' "$CLAUDE_OAUTH_TOKEN"
    elif [ -r /home/claude/.claude/remote/.oauth_token ]; then
      tr -d '\n' < /home/claude/.claude/remote/.oauth_token
    else
      echo "remote-session: no token (set CLAUDE_OAUTH_TOKEN or run \`remote-session setup-token\`)" >&2
      return 1
    fi
  }

  # PKCE OAuth client constants (Claude Code public client).
  _RS_OAUTH_CLIENT_ID="9d1c250a-e61b-44d9-88ed-5944d1962f5e"
  _RS_OAUTH_REDIRECT_URI="https://platform.claude.com/oauth/code/callback"
  _RS_OAUTH_AUTH_URL="https://claude.com/cai/oauth/authorize"
  _RS_OAUTH_SCOPE="user:inference user:sessions:claude_code user:profile"

  _rs_refresh_token() {
    if [ -n "$_RS_REFRESH_CACHE" ]; then
      printf '%s' "$_RS_REFRESH_CACHE"
    elif [ -n "$CLAUDE_OAUTH_REFRESH_TOKEN" ]; then
      printf '%s' "$CLAUDE_OAUTH_REFRESH_TOKEN"
    else
      return 1
    fi
  }

  # Mint a new access token from the refresh token. On success caches the new
  # access token (and any rotated refresh token) in shell vars so subsequent
  # commands in this shell pick it up without touching env or disk.
  _rs_refresh_access_token() {
    local rt
    rt=$(_rs_refresh_token) || {
      echo "remote-session: no refresh token (set CLAUDE_OAUTH_REFRESH_TOKEN or run \`remote-session setup-token\`)" >&2
      return 1
    }
    local body resp status json access new_rt
    body=$(jq -n \
      --arg gt "refresh_token" \
      --arg rt "$rt" \
      --arg cid "$_RS_OAUTH_CLIENT_ID" \
      '{grant_type:$gt, refresh_token:$rt, client_id:$cid}')
    resp=$(curl -sS -w $'\n%{http_code}' -X POST "$base/v1/oauth/token" \
      -H 'Content-Type: application/json' -d "$body")
    status=$(printf '%s' "$resp" | tail -n1)
    json=$(printf '%s' "$resp" | sed '$d')
    if [ "$status" != "200" ]; then
      echo "remote-session: token refresh failed (HTTP $status). Run \`remote-session setup-token\`." >&2
      printf '%s\n' "$json" >&2
      return 1
    fi
    access=$(printf '%s' "$json" | jq -r '.access_token // empty')
    [ -n "$access" ] || { echo "remote-session: refresh response missing access_token" >&2; return 1; }
    _RS_ACCESS_CACHE="$access"
    new_rt=$(printf '%s' "$json" | jq -r '.refresh_token // empty')
    if [ -n "$new_rt" ] && [ "$new_rt" != "$rt" ]; then
      _RS_REFRESH_CACHE="$new_rt"
      echo "remote-session: refresh token rotated; update CLAUDE_OAUTH_REFRESH_TOKEN in your Remote Environment to:" >&2
      printf '  %s\n' "$new_rt" >&2
    fi
    return 0
  }

  # Decode the session ingress JWT (present in every remote Claude Code
  # session) and read organization_uuid from its payload. No API call needed.
  _rs_org_from_ingress() {
    local path="${CLAUDE_SESSION_INGRESS_TOKEN_FILE:-/home/claude/.claude/remote/.session_ingress_token}"
    [ -r "$path" ] || return 1
    local jwt mid padded uuid
    jwt=$(tr -d '\n' < "$path")
    mid=${jwt#*.}; mid=${mid%%.*}
    [ -n "$mid" ] || return 1
    # base64url -> base64 (pad to multiple of 4)
    padded=$(printf '%s' "$mid" | tr '_-' '/+')
    while [ $(( ${#padded} % 4 )) -ne 0 ]; do padded="${padded}="; done
    uuid=$(printf '%s' "$padded" | base64 -d 2>/dev/null | jq -r '.organization_uuid // empty' 2>/dev/null)
    [ -n "$uuid" ] && printf '%s' "$uuid"
  }

  _rs_org() {
    if [ -n "$_RS_ORG_CACHE" ]; then
      printf '%s' "$_RS_ORG_CACHE"; return 0
    fi
    if [ -n "$CLAUDE_CODE_ORGANIZATION_UUID" ]; then
      _RS_ORG_CACHE="$CLAUDE_CODE_ORGANIZATION_UUID"
      printf '%s' "$_RS_ORG_CACHE"; return 0
    fi
    local from_ingress
    from_ingress=$(_rs_org_from_ingress)
    if [ -n "$from_ingress" ]; then
      _RS_ORG_CACHE="$from_ingress"
      printf '%s' "$_RS_ORG_CACHE"; return 0
    fi
    local attempt=0 tok body status
    while :; do
      tok=$(_rs_token) || return 1
      body=$(curl -sS -w $'\n%{http_code}' "$base/api/oauth/profile" \
        -H "Authorization: Bearer $tok" -H "anthropic-version: $version")
      status=$(printf '%s' "$body" | tail -n1)
      body=$(printf '%s' "$body" | sed '$d')
      if [ "$status" = "200" ]; then
        _RS_ORG_CACHE=$(printf '%s' "$body" | jq -r '.organization.uuid')
        printf '%s' "$_RS_ORG_CACHE"
        return 0
      fi
      if { [ "$status" = "401" ] || [ "$status" = "403" ]; } && [ "$attempt" -eq 0 ]; then
        attempt=1
        if _rs_refresh_access_token; then
          continue
        fi
      fi
      echo "remote-session: could not resolve org UUID ($status). Set CLAUDE_CODE_ORGANIZATION_UUID or use a token with user:profile scope." >&2
      return 1
    done
  }

  _rs_curl() {
    local method="$1" path="$2" data="$3"
    local attempt=0 tok org resp status body
    while :; do
      tok=$(_rs_token) || return 1
      org=$(_rs_org) || return 1
      if [ -n "$data" ]; then
        resp=$(curl -sS -w $'\n%{http_code}' -X "$method" "$base$path" \
          -H "Authorization: Bearer $tok" \
          -H "anthropic-version: $version" \
          -H "anthropic-beta: $beta" \
          -H "x-organization-uuid: $org" \
          -H "content-type: application/json" \
          --data "$data")
      else
        resp=$(curl -sS -w $'\n%{http_code}' -X "$method" "$base$path" \
          -H "Authorization: Bearer $tok" \
          -H "anthropic-version: $version" \
          -H "anthropic-beta: $beta" \
          -H "x-organization-uuid: $org")
      fi
      status=$(printf '%s' "$resp" | tail -n1)
      body=$(printf '%s' "$resp" | sed '$d')
      case "$status" in
        2*)
          printf '%s' "$body"
          return 0
          ;;
        401|403)
          if [ "$attempt" -eq 0 ]; then
            attempt=1
            if _rs_refresh_access_token; then
              continue
            fi
          fi
          [ -n "$body" ] && printf '%s\n' "$body" >&2
          echo "remote-session: HTTP $status (token may be invalid or missing scope). Run \`remote-session setup-token\`." >&2
          return 1
          ;;
        *)
          [ -n "$body" ] && printf '%s\n' "$body" >&2
          echo "remote-session: HTTP $status" >&2
          return 1
          ;;
      esac
    done
  }

  _rs_create() {
    local repo="$1" env_id="$2" prompt="$3" title="${4:-${3:0:100}}"
    local uuid; uuid=$(_rs_uuid) || return 1
    local payload
    payload=$(jq -n \
      --arg title "$title" \
      --arg env "$env_id" \
      --arg repo "$repo" \
      --arg url "https://github.com/$repo" \
      --arg uuid "$uuid" \
      --arg content "$prompt" \
      '{
        title: $title,
        environment_id: $env,
        session_context: {
          sources: [{type:"git_repository", url:$url, revision:"main"}],
          outcomes: [{type:"git_repository", git_info:{type:"github", repo:$repo, branches:[]}}],
          model: "claude-opus-4-7[1m]"
        },
        events: [{
          type:"event",
          data:{uuid:$uuid, session_id:"", type:"user", parent_tool_use_id:null,
                message:{role:"user", content:$content}}
        }]
      }')
    _rs_curl POST /v1/sessions "$payload"
  }

  # Poll events until a `result` event appears, print the final assistant text.
  _rs_wait() {
    local sid="$1" timeout_sec="${2:-900}"
    local started=$SECONDS last_id="" body
    local last_assistant=""
    while [ $((SECONDS - started)) -lt "$timeout_sec" ]; do
      local path="/v1/sessions/$sid/events"
      if [ -n "$last_id" ]; then path="$path?after_id=$last_id"; fi
      body=$(_rs_curl GET "$path") || return 1

      local got_result
      got_result=$(printf '%s' "$body" \
        | jq -r 'any(.data[]?; (.type // .event_type) == "result")')

      # Update last_assistant from any new assistant events we just saw
      local new_text
      new_text=$(printf '%s' "$body" | jq -r '
        [.data[]?
          | select((.type // .event_type) == "assistant")
          | (.message.content // .payload.message.content) as $c
          | if ($c | type) == "array"
            then ($c | map(select(.type=="text") | .text) | join("\n"))
            else empty end
        ] | last // empty')
      if [ -n "$new_text" ]; then last_assistant="$new_text"; fi

      if [ "$got_result" = "true" ]; then
        printf '%s\n' "$last_assistant"
        return 0
      fi

      local new_last
      new_last=$(printf '%s' "$body" | jq -r '.last_id // empty')
      if [ -n "$new_last" ]; then last_id="$new_last"; fi
      sleep 3
    done
    echo "remote-session: wait timed out after ${timeout_sec}s" >&2
    return 1
  }

  local cmd="$1"; shift || true
  case "$cmd" in
    envs)
      _rs_curl GET /v1/environment_providers \
        | jq -r '.environments[] | "\(.environment_id)  \(.state)  \(.name)"'
      ;;
    list)
      _rs_curl GET /v1/sessions \
        | jq -r '.data[] | "\(.id)  \(.session_status // "?")  \((.session_context.outcomes[0].git_info.repo) // "-")  \(.title)"'
      ;;
    status)
      [ -z "$1" ] && { echo "usage: remote-session status <sessionId>" >&2; return 2; }
      _rs_curl GET "/v1/sessions/$1" | jq .
      ;;
    events)
      [ -z "$1" ] && { echo "usage: remote-session events <sessionId> [limit]" >&2; return 2; }
      local limit="${2:-20}"
      _rs_curl GET "/v1/sessions/$1/events" \
        | jq -r --argjson n "$limit" '
            .data[:$n][] as $e
            | ($e.created_at // "") as $t
            | ($e.type // $e.event_type // "?") as $k
            | (
                if $k == "assistant" or $k == "user" then
                  ($e.message.content // $e.payload.message.content) as $c
                  | (if ($c | type) == "string" then $c[:200]
                     elif ($c | type) == "array" then
                       [$c[] | if .type=="text" then .text[:200]
                               elif .type=="tool_use" then "[tool_use: \(.name)]"
                               elif .type=="tool_result" then "[tool_result]"
                               else "[\(.type)]" end] | join(" ")
                     else "" end)
                else "" end
              ) as $d
            | "\($t)  \($k)  \($d)"'
      ;;
    send)
      [ -z "$1" ] || [ -z "$2" ] && { echo 'usage: remote-session send <sessionId> "<prompt>"' >&2; return 2; }
      local sid="$1" prompt="$2"
      local uuid; uuid=$(_rs_uuid) || return 1
      local payload
      payload=$(jq -n --arg sid "$sid" --arg uuid "$uuid" --arg content "$prompt" \
        '{events:[{uuid:$uuid, session_id:$sid, type:"user", parent_tool_use_id:null, message:{role:"user", content:$content}}]}')
      _rs_curl POST "/v1/sessions/$sid/events" "$payload" >/dev/null \
        && echo "sent to $sid"
      ;;
    archive)
      [ -z "$1" ] && { echo "usage: remote-session archive <sessionId>" >&2; return 2; }
      _rs_curl POST "/v1/sessions/$1/archive" '' >/dev/null && echo "archived $1"
      ;;
    create)
      [ -z "$1" ] || [ -z "$2" ] || [ -z "$3" ] && {
        echo 'usage: remote-session create <repo> <envId> "<prompt>" [title]' >&2; return 2; }
      _rs_create "$1" "$2" "$3" "$4" | jq '{id, title, environment_id, session_status}'
      ;;
    wait)
      [ -z "$1" ] && { echo "usage: remote-session wait <sessionId> [timeoutSec]" >&2; return 2; }
      _rs_wait "$1" "${2:-900}"
      ;;
    execute)
      [ -z "$1" ] || [ -z "$2" ] || [ -z "$3" ] && {
        echo 'usage: remote-session execute <repo> <envId> "<prompt>" [timeoutSec]' >&2; return 2; }
      local timeout_sec="${4:-900}"
      local sid
      sid=$(_rs_create "$1" "$2" "$3" "" | jq -r '.id') || return 1
      echo "# session $sid" >&2
      _rs_wait "$sid" "$timeout_sec"
      local rc=$?
      [ "$rc" -eq 0 ] && _rs_curl POST "/v1/sessions/$sid/archive" '' >/dev/null 2>&1
      return $rc
      ;;
    setup-token)
      command -v openssl >/dev/null 2>&1 || { echo "remote-session: setup-token needs openssl" >&2; return 1; }
      command -v jq >/dev/null 2>&1     || { echo "remote-session: setup-token needs jq" >&2; return 1; }

      _rs_b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }

      local verifier challenge state enc_redirect enc_scope auth_url
      verifier=$(openssl rand 64 | _rs_b64url)
      challenge=$(printf '%s' "$verifier" | openssl dgst -sha256 -binary | _rs_b64url)
      state=$(openssl rand 32 | _rs_b64url)
      enc_redirect=$(jq -rn --arg s "$_RS_OAUTH_REDIRECT_URI" '$s|@uri')
      enc_scope=$(jq -rn --arg s "$_RS_OAUTH_SCOPE" '$s|@uri')
      auth_url="${_RS_OAUTH_AUTH_URL}?code=true&client_id=${_RS_OAUTH_CLIENT_ID}&response_type=code&redirect_uri=${enc_redirect}&scope=${enc_scope}&code_challenge=${challenge}&code_challenge_method=S256&state=${state}"

      printf '\nOpen this URL in a browser and authorize Claude Code:\n\n  %s\n\n' "$auth_url" >&2
      printf 'After approval, the page shows a string of the form  <code>#<state>\nPaste it here: ' >&2
      local pasted code in_state
      IFS= read -r pasted || return 1
      pasted=$(printf '%s' "$pasted" | tr -d '[:space:]')
      [ -n "$pasted" ] || { echo "remote-session: empty input" >&2; return 1; }
      code=${pasted%%#*}
      in_state=${pasted##*#}
      if [ -z "$code" ] || [ "$code" = "$pasted" ]; then
        echo "remote-session: pasted value should look like <code>#<state>" >&2
        return 1
      fi
      if [ "$in_state" != "$state" ]; then
        echo "remote-session: state mismatch (expected $state, got $in_state)" >&2
        return 1
      fi

      local body resp status json
      body=$(jq -n \
        --arg gt "authorization_code" \
        --arg code "$code" \
        --arg state "$state" \
        --arg cid "$_RS_OAUTH_CLIENT_ID" \
        --arg ru "$_RS_OAUTH_REDIRECT_URI" \
        --arg cv "$verifier" \
        '{grant_type:$gt, code:$code, state:$state, client_id:$cid, redirect_uri:$ru, code_verifier:$cv}')
      resp=$(curl -sS -w $'\n%{http_code}' -X POST "$base/v1/oauth/token" \
        -H 'Content-Type: application/json' -d "$body")
      status=$(printf '%s' "$resp" | tail -n1)
      json=$(printf '%s' "$resp" | sed '$d')
      if [ "$status" != "200" ]; then
        echo "remote-session: token exchange failed (HTTP $status):" >&2
        printf '%s\n' "$json" >&2
        return 1
      fi

      local access refresh org_uuid org_name account_email scope_granted expires_in
      access=$(printf '%s'        "$json" | jq -r '.access_token // empty')
      refresh=$(printf '%s'       "$json" | jq -r '.refresh_token // empty')
      org_uuid=$(printf '%s'      "$json" | jq -r '.organization.uuid // empty')
      org_name=$(printf '%s'      "$json" | jq -r '.organization.name // empty')
      account_email=$(printf '%s' "$json" | jq -r '.account.email_address // empty')
      scope_granted=$(printf '%s' "$json" | jq -r '.scope // empty')
      expires_in=$(printf '%s'    "$json" | jq -r '.expires_in // empty')

      [ -n "$access" ] || { echo "remote-session: token response missing access_token" >&2; return 1; }

      # Cache for the current shell so subsequent commands use the new token.
      _RS_ACCESS_CACHE="$access"
      [ -n "$refresh" ]  && _RS_REFRESH_CACHE="$refresh"
      [ -n "$org_uuid" ] && _RS_ORG_CACHE="$org_uuid"

      cat >&2 <<EOF

Authorized as ${account_email:-?}  (${org_name:-?})
  scope:      ${scope_granted:-?}
  expires_in: ${expires_in:-?}s

Add these to your Claude Code Remote Environment configuration
(claude.com/settings -> Environments -> <your env> -> Environment variables):

EOF
      printf 'CLAUDE_OAUTH_TOKEN=%s\n' "$access"
      [ -n "$refresh" ]  && printf 'CLAUDE_OAUTH_REFRESH_TOKEN=%s\n' "$refresh"
      [ -n "$org_uuid" ] && printf 'CLAUDE_CODE_ORGANIZATION_UUID=%s\n' "$org_uuid"

      cat >&2 <<'EOF'

The access token expires in 8h; with the refresh token saved, this CLI
will auto-refresh on 401/403. If refresh ever fails, re-run
`remote-session setup-token`.
EOF
      ;;
    ""|help|-h|--help)
      cat <<'USAGE'
remote-session — spawn and drive Claude Code remote sessions from the shell.

Each session is a real Claude Code worker running in an Anthropic cloud
sandbox against a GitHub repo you choose. You can delegate work to it and
read the result back as a string. Tasks usually take 20s–several minutes.

WHEN TO USE
  - Delegating a bounded sub-task to another Claude session (code research,
    summarization, multi-file edits in a different repo, etc.)
  - Anything that needs a fresh sandbox or a different repo than yours
  - Parallel work: spawn multiple sessions, wait on each

COMMANDS
  envs                                       List available environments (pick an env_... ID)
  list                                       List your sessions
  status  <sessionId>                        Full session detail (JSON)
  events  <sessionId> [limit]                Pretty-print recent events (assistant text, tool calls)
  send    <sessionId> "<prompt>"             Send a follow-up prompt to an existing session
  wait    <sessionId> [timeoutSec=900]       Block until `result` event; print final assistant text
  archive <sessionId>                        Archive a session when done
  create  <repo> <envId> "<prompt>" [title]  Create session with initial prompt; returns JSON
  execute <repo> <envId> "<prompt>" [timeoutSec=900]
                                             One-shot: create + wait + print final text + archive (recommended)
  setup-token                                Interactive OAuth login (PKCE). Prints env vars to add
                                             to your Remote Environment configuration.

TYPICAL FLOW (synchronous, one-shot)
  remote-session envs                        # pick an env_... ID once
  remote-session execute owner/repo env_01Xxx "Summarize the main README in 3 bullets."

TYPICAL FLOW (async / multi-turn)
  sid=$(remote-session create owner/repo env_01Xxx "Start exploring" | jq -r .id)
  remote-session events "$sid"
  remote-session send   "$sid" "Now open a PR with your findings"
  remote-session wait   "$sid"
  remote-session archive "$sid"

PROMPTING TIPS
  - Tell the session what to produce ("respond with only the version number").
  - Scope it tightly — each session starts fresh and has no memory.
  - For read-only tasks, say "do not modify files". For write tasks, say whether
    you want a PR.
  - Opus 4.7 1M-context is the default model.

AUTH
  Token:    $CLAUDE_OAUTH_TOKEN, else /home/claude/.claude/remote/.oauth_token
  Refresh:  $CLAUDE_OAUTH_REFRESH_TOKEN. When set, any 401/403 from a session
            API call triggers a one-shot refresh + retry transparently. If
            refresh fails, re-run `remote-session setup-token`.
  OrgID:    $CLAUDE_CODE_ORGANIZATION_UUID, else decoded from the session
            ingress JWT (works inside any Claude Code remote session),
            else GET /api/oauth/profile (needs user:profile scope).
  No token? Run `remote-session setup-token` for an interactive PKCE login.
USAGE
      ;;
    *)
      echo "remote-session: unknown command '$cmd' (try: help)" >&2
      return 2
      ;;
  esac
}
