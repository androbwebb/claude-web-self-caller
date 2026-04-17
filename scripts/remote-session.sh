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
#
# Needs: curl, jq.

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
    if [ -n "$CLAUDE_OAUTH_TOKEN" ]; then
      printf '%s' "$CLAUDE_OAUTH_TOKEN"
    elif [ -r /home/claude/.claude/remote/.oauth_token ]; then
      tr -d '\n' < /home/claude/.claude/remote/.oauth_token
    else
      echo "remote-session: no token (set CLAUDE_OAUTH_TOKEN)" >&2
      return 1
    fi
  }

  _rs_org() {
    if [ -n "$_RS_ORG_CACHE" ]; then
      printf '%s' "$_RS_ORG_CACHE"; return 0
    fi
    if [ -n "$CLAUDE_CODE_ORGANIZATION_UUID" ]; then
      _RS_ORG_CACHE="$CLAUDE_CODE_ORGANIZATION_UUID"
      printf '%s' "$_RS_ORG_CACHE"; return 0
    fi
    local tok; tok=$(_rs_token) || return 1
    local body status
    body=$(curl -sS -w $'\n%{http_code}' "$base/api/oauth/profile" \
      -H "Authorization: Bearer $tok" -H "anthropic-version: $version")
    status=$(printf '%s' "$body" | tail -n1)
    body=$(printf '%s' "$body" | sed '$d')
    if [ "$status" != "200" ]; then
      echo "remote-session: could not resolve org UUID ($status). Set CLAUDE_CODE_ORGANIZATION_UUID or use a token with user:profile scope." >&2
      return 1
    fi
    _RS_ORG_CACHE=$(printf '%s' "$body" | jq -r '.organization.uuid')
    printf '%s' "$_RS_ORG_CACHE"
  }

  _rs_curl() {
    local method="$1" path="$2" data="$3"
    local tok org
    tok=$(_rs_token) || return 1
    org=$(_rs_org) || return 1
    if [ -n "$data" ]; then
      curl -sS -X "$method" "$base$path" \
        -H "Authorization: Bearer $tok" \
        -H "anthropic-version: $version" \
        -H "anthropic-beta: $beta" \
        -H "x-organization-uuid: $org" \
        -H "content-type: application/json" \
        --data "$data"
    else
      curl -sS -X "$method" "$base$path" \
        -H "Authorization: Bearer $tok" \
        -H "anthropic-version: $version" \
        -H "anthropic-beta: $beta" \
        -H "x-organization-uuid: $org"
    fi
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
      ;;
    ""|help|-h|--help)
      cat <<'USAGE'
remote-session <command> [args]

Commands:
  envs                             List available environments
  list                             List your sessions
  status  <sessionId>              Full session detail
  events  <sessionId> [limit]      Pretty-print recent events
  send    <sessionId> "<prompt>"   Send a follow-up prompt
  archive <sessionId>              Archive a session
  create  <repo> <envId> "<prompt>" [title]
                                   Create a new session with initial prompt
  wait    <sessionId> [timeoutSec] Block until session finishes; print final assistant text
  execute <repo> <envId> "<prompt>" [timeoutSec]
                                   One-shot: create + wait + print final assistant text
USAGE
      ;;
    *)
      echo "remote-session: unknown command '$cmd' (try: help)" >&2
      return 2
      ;;
  esac
}
