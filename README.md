# claude-web-self-caller

A small CLI that drives **Claude Code remote web sessions** from another Claude session (or any shell) — using the same private API the `claude --remote` CLI uses.

The point: a Claude Code session that can **spawn and coordinate other Claude Code sessions**. Delegate bounded sub-tasks to fresh sandboxes, run work against a different repo, or fan out parallel sub-agents — then read the answers back as plain strings you can pipe into the next command.



https://github.com/user-attachments/assets/87d533c8-1c5d-43a7-a8d6-de9286c4cc1c



```bash
sid=$(remote-session create owner/repo env_01Xxx "Explore this codebase" | jq -r .id)
remote-session send   "$sid" "What's the test framework?"
remote-session events "$sid" 5          # stream recent events
remote-session wait   "$sid"            # block until done, print final text
remote-session archive "$sid"
```

## How it works

Each `remote-session` is a real Claude Code worker running in an Anthropic cloud sandbox against a GitHub repo you choose. The CLI is a thin wrapper over four REST calls on `api.anthropic.com`:

| REST call | What it does |
| --- | --- |
| `POST /v1/sessions` | Spin up a new worker with an initial prompt |
| `POST /v1/sessions/{id}/events` | Send a follow-up user message |
| `GET  /v1/sessions/{id}/events` | Poll for assistant responses, tool calls, and the terminal `result` event |
| `POST /v1/sessions/{id}/archive` | Clean up when done |

Auth is an OAuth bearer token read from the host Claude Code sandbox (`/home/claude/.claude/remote/.oauth_token`), plus an `x-organization-uuid` header decoded from the session's ingress JWT. No browser cookies, no scraping.

## Commands

| Command | Description |
| --- | --- |
| `envs` | List available environments (pick an `env_...` ID once) |
| `list` | List your sessions |
| `create <repo> <envId> "<prompt>" [title]` | Create a session with an initial prompt; returns JSON |
| `send <id> "<prompt>"` | Send a follow-up user message |
| `events <id> [limit]` | Pretty-print recent events (assistant text, tool calls, errors) |
| `status <id>` | Full session detail as JSON |
| `wait <id> [timeoutSec]` | Block until the session emits `result`; print final assistant text |
| `archive <id>` | Archive the session |
| `execute <repo> <envId> "<prompt>" [timeoutSec]` | One-shot convenience: create + wait + archive |

`execute` is a shortcut for the common "fire one prompt, get one answer, done" case. For anything multi-turn, inspecting tool calls mid-flight, or running many sessions in parallel, use `create`/`send`/`events`/`wait` directly.

## Two flavors

| File | When to use |
| --- | --- |
| `scripts/remote-session.sh` | Source into bash. Needs `curl` + `jq`. Zero Node deps. Best for env setup scripts and hooks. |
| `scripts/remote-session.ts` | Run via `tsx` (Node 20+). Best if you want typed imports in a TS project. |

## Install into a Claude Code environment

Two options, with different tradeoffs:

### Option A — SessionStart hook (recommended)

Drop a `.claude/hooks/session-start.sh` into the repo you want `remote-session` available in. The hook runs at the start of every Claude Code session and fetches the latest helper from `main`, so you never go stale.

From the target repo's root:

```bash
curl -fsSL https://raw.githubusercontent.com/androbwebb/claude-web-self-caller/main/scripts/install-hook.sh | bash
git add .claude && git commit -m "Add remote-session SessionStart hook"
```

The installer writes:

- `.claude/hooks/session-start.sh` — fetches `remote-session.sh`, sets `BASH_ENV` via `$CLAUDE_ENV_FILE` so Claude's own `bash -c` tool calls preload the function
- `.claude/settings.json` — registers the hook (merged into an existing file if present)

Once merged to the repo's default branch, every future session on that repo picks it up.

### Option B — Environment setup script

Install once into a Claude Code environment's filesystem. Good if you want `remote-session` available in every repo that uses that environment, not just one.

Add to your environment's setup script:

```bash
curl -fsSL https://raw.githubusercontent.com/androbwebb/claude-web-self-caller/main/scripts/env-install.sh | bash
```

Optionally set `CLAUDE_CODE_ORGANIZATION_UUID=<your-org-uuid>` in the environment's env vars (skips the JWT/profile lookup).

### Which to pick

| | SessionStart hook | Env setup script |
| --- | --- | --- |
| Scope | Per-repo | Per-environment |
| Runs | Every session start (~0.5s) | Once, at env provisioning |
| Update cadence | Always latest from `main` | Snapshotted; re-provision to refresh |
| Requires repo commit | Yes (`.claude/` files) | No |
| Works across repos | Only where hook is committed | Every repo in that env |

The hook is usually the right default. Use the env script when you can't or don't want to commit to the repo, or when you want a fleet of repos to share one install.

## Local use

If you just want to use it from your laptop shell (no Claude Code in the loop):

```bash
git clone https://github.com/androbwebb/claude-web-self-caller.git
source ./claude-web-self-caller/scripts/remote-session.sh
export CLAUDE_OAUTH_TOKEN=<your-token>
export CLAUDE_CODE_ORGANIZATION_UUID=<your-org-uuid>
remote-session envs
```

TypeScript equivalent:

```bash
npx tsx scripts/remote-session.ts envs
```

Or import it:

```ts
import { createSession, sendPrompt, waitForResult, archiveSession } from "./remote-session";

const { sessionId } = await createSession({
  repo: "owner/repo",
  environmentId: "env_01Xxx",
  prompt: "Explore this codebase",
});
await sendPrompt(sessionId, "What's the test framework?");
const { finalText } = await waitForResult(sessionId);
await archiveSession(sessionId);
```

## Auth resolution

**OAuth bearer token**, in order:

1. `$CLAUDE_OAUTH_TOKEN`
2. `/home/claude/.claude/remote/.oauth_token` (present inside Claude Code sandboxes)

**Organization UUID**, in order:

1. `$CLAUDE_CODE_ORGANIZATION_UUID`
2. Decoded from `/home/claude/.claude/remote/.session_ingress_token` (the session ingress JWT — works inside any Claude Code remote session, no extra scope needed)
3. `GET /api/oauth/profile` → `organization.uuid` (requires `user:profile` scope, which remote-session tokens typically lack)

## Prompting tips

- Tell the session exactly what to produce ("respond with only the version number").
- Scope it tightly — each session starts fresh with no memory of the parent.
- For read-only tasks, say "do not modify files". For write tasks, say whether you want a PR.
- The model is hard-coded to `claude-opus-4-7[1m]` in `create`. Edit the script to change it.

## Caveats

- **Not an official API.** Anthropic can change or disable any of this. Treat it as a fun hack, not production infra. Reverse-engineered from the `claude` CLI's JS bundle.
- **Repo access.** The target repo must be reachable by the environment's GitHub App installation. Private repos without the app won't clone.
- **Token scope.** Remote-session OAuth tokens lack `user:profile`. Use the JWT fallback (automatic) or set `CLAUDE_CODE_ORGANIZATION_UUID`.

## License

MIT
