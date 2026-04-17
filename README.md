# claude-web-self-caller

A tiny CLI for launching and driving [Claude Code](https://claude.ai/code) **remote sessions** from a shell, script, or another Claude session — using the same private API the official `claude --remote` CLI uses.

Think of it as a synchronous LLM-agent call with full repo access, tool use, and an answer you can pipe into the next command.

```bash
remote-session execute androbwebb/my-repo env_01Xxx "What tech stack does this project use?"
# => Next.js 16 + React 19 + TypeScript with Prisma/Neon Postgres, Clerk auth, Stripe, and MDX content.
```

## What it does

- **Spawn** a fresh Claude Code session on any environment, against any GitHub repo, with an initial prompt
- **Send** follow-up prompts into an existing session
- **Wait** for a session to finish and read back Claude's answer
- **Inspect** live event streams (assistant text, tool calls, thinking blocks, env logs)
- **Archive** sessions when you're done

All against `api.anthropic.com` with an OAuth bearer token. No browser cookies, no web scraping.

## Two flavors

| File | When to use it |
| --- | --- |
| `remote-session.sh` | Source into bash. Needs `curl` + `jq`. Zero Node deps. Best for env setup scripts. |
| `remote-session.ts` | Run via `tsx`. Needs Node 20+. Best if you want typed imports. |

## Quick start (local)

Bash:

```bash
source ./remote-session.sh
export CLAUDE_CODE_ORGANIZATION_UUID=<your-org-uuid>
remote-session envs
remote-session execute owner/repo env_01Xxx "summarize the README in one sentence"
```

TypeScript:

```bash
npx tsx remote-session.ts envs
npx tsx remote-session.ts execute owner/repo env_01Xxx "summarize the README in one sentence"
```

Or import:

```ts
import { createSession, sendPrompt, waitForResult, executePrompt } from "./remote-session";

const { sessionId, finalText } = await executePrompt({
  repo: "owner/repo",
  environmentId: "env_01Xxx",
  prompt: "summarize the README in one sentence",
});
```

## Install into a Claude Code environment

So every session that env spins up has `remote-session` preloaded:

**Environment setup script:**

```bash
curl -fsSL https://raw.githubusercontent.com/androbwebb/claude-remote/main/env-install.sh | bash
```

**Environment variables:**

```
CLAUDE_CODE_ORGANIZATION_UUID=<your-org-uuid>
```

The installer:

- Drops `remote-session.sh` into `$HOME`
- Sources it from `~/.bashrc` (interactive shells)
- Sets `BASH_ENV` via `/etc/profile.d/` so Claude's own Bash-tool calls (`bash -c …`) also have the function available — letting a Claude session spawn grandchild sessions

## Commands

| Command | Description |
| --- | --- |
| `envs` | List available environments |
| `list` | List your sessions |
| `status <id>` | Full session detail (JSON) |
| `events <id> [limit]` | Pretty-print recent events |
| `send <id> "<prompt>"` | Send a follow-up prompt |
| `wait <id> [timeoutSec]` | Block until session finishes; print final assistant text |
| `archive <id>` | Archive a session |
| `create <repo> <envId> "<prompt>" [title]` | Create a new session with initial prompt |
| `execute <repo> <envId> "<prompt>" [timeoutSec]` | One-shot: create + wait + print |

## Auth

Reads an OAuth bearer token in this order:

1. `$CLAUDE_OAUTH_TOKEN`
2. `/home/claude/.claude/remote/.oauth_token` (exists inside Claude Code sandboxes)

Organization UUID, in order:

1. `$CLAUDE_CODE_ORGANIZATION_UUID`
2. `GET /api/oauth/profile` → `organization.uuid` (needs `user:profile` scope — not present on remote-session tokens, so prefer the env var)

## API endpoints used

All on `https://api.anthropic.com`, with headers `anthropic-version: 2023-06-01`, `anthropic-beta: ccr-byoc-2025-07-29`, and `x-organization-uuid`.

| Method | Path | Purpose |
| --- | --- | --- |
| GET | `/v1/environment_providers` | List environments |
| GET | `/v1/sessions` | List sessions |
| POST | `/v1/sessions` | Create session (can include initial prompt in `events[]`) |
| GET | `/v1/sessions/{id}` | Session detail |
| GET | `/v1/sessions/{id}/events` | Event stream (supports `?after_id=` for incremental polling) |
| POST | `/v1/sessions/{id}/events` | Send a user message |
| POST | `/v1/sessions/{id}/archive` | Archive |

Reverse-engineered from the `claude` CLI binary's JS bundle — not officially documented. Field shapes and endpoints can change without notice.

## Caveats

- **Not an official API.** Anthropic can change or disable any of this. Treat it as a fun hack, not production infra.
- **Token scope.** The OAuth token on a remote session lacks `user:profile` (can't call `/api/oauth/profile` or list GitHub repos via the Anthropic API). Set `CLAUDE_CODE_ORGANIZATION_UUID` directly.
- **Model field** is hard-coded to `claude-opus-4-7[1m]` in `create`. Edit the script if you want something else.
- **Env's repo access.** The target repo must be a GitHub repo the environment's GitHub App installation can see. Private repos without the app won't clone.

## License

MIT
