#!/usr/bin/env tsx
/**
 * Remote session API helper.
 *
 * Endpoint: POST /v1/sessions on api.anthropic.com (OAuth bearer).
 * Required headers: anthropic-beta: ccr-byoc-2025-07-29, x-organization-uuid.
 * Shape reverse-engineered from the claude CLI binary (SEA bundle).
 *
 * Auth: reads $CLAUDE_OAUTH_TOKEN, else /home/claude/.claude/remote/.oauth_token.
 *
 * Usage:
 *   tsx scripts/remote-session.ts list
 *   tsx scripts/remote-session.ts envs
 *   tsx scripts/remote-session.ts status <sessionId>
 *   tsx scripts/remote-session.ts events <sessionId> [limit]
 *   tsx scripts/remote-session.ts archive <sessionId>
 *   tsx scripts/remote-session.ts create <repo> <envId> "<prompt>" [title]
 *   tsx scripts/remote-session.ts send <sessionId> "<prompt>"
 *   tsx scripts/remote-session.ts wait <sessionId> [timeoutSec]
 *   tsx scripts/remote-session.ts execute <repo> <envId> "<prompt>" [timeoutSec]
 */
import { readFileSync } from "node:fs";
import { randomUUID } from "node:crypto";

const BASE = "https://api.anthropic.com";
const ANTHROPIC_VERSION = "2023-06-01";
const ANTHROPIC_BETA = "ccr-byoc-2025-07-29";

function getToken(): string {
  const envTok = process.env.CLAUDE_OAUTH_TOKEN?.trim();
  if (envTok) return envTok;
  return readFileSync("/home/claude/.claude/remote/.oauth_token", "utf8").trim();
}

let cachedOrgUuid: string | undefined;

/**
 * Decode the session ingress JWT (present in every remote Claude Code
 * session) and read `organization_uuid` from its payload. No API call,
 * no extra scopes required.
 */
function readOrgUuidFromIngressToken(): string | undefined {
  const path =
    process.env.CLAUDE_SESSION_INGRESS_TOKEN_FILE ??
    "/home/claude/.claude/remote/.session_ingress_token";
  let jwt: string;
  try {
    jwt = readFileSync(path, "utf8").trim();
  } catch {
    return undefined;
  }
  const mid = jwt.split(".")[1];
  if (!mid) return undefined;
  try {
    const json = Buffer.from(mid.replace(/-/g, "+").replace(/_/g, "/"), "base64").toString("utf8");
    const payload = JSON.parse(json) as { organization_uuid?: string };
    return payload.organization_uuid;
  } catch {
    return undefined;
  }
}

async function getOrgUuid(): Promise<string> {
  if (cachedOrgUuid) return cachedOrgUuid;
  const envOrg = process.env.CLAUDE_CODE_ORGANIZATION_UUID?.trim();
  if (envOrg) return (cachedOrgUuid = envOrg);
  const fromIngress = readOrgUuidFromIngressToken();
  if (fromIngress) return (cachedOrgUuid = fromIngress);
  const res = await fetch(`${BASE}/api/oauth/profile`, {
    headers: {
      Authorization: `Bearer ${getToken()}`,
      "anthropic-version": ANTHROPIC_VERSION,
    },
  });
  if (!res.ok) {
    throw new Error(
      `Could not resolve organization UUID: /api/oauth/profile returned ${res.status}. ` +
        `Set CLAUDE_CODE_ORGANIZATION_UUID, or use an OAuth token with user:profile scope.`,
    );
  }
  const body = (await res.json()) as { organization?: { uuid?: string } };
  const uuid = body.organization?.uuid;
  if (!uuid) throw new Error("/api/oauth/profile returned no organization.uuid");
  return (cachedOrgUuid = uuid);
}

async function headers(): Promise<Record<string, string>> {
  return {
    Authorization: `Bearer ${getToken()}`,
    "anthropic-version": ANTHROPIC_VERSION,
    "anthropic-beta": ANTHROPIC_BETA,
    "x-organization-uuid": await getOrgUuid(),
    "content-type": "application/json",
  };
}

export interface SessionSummary {
  id: string;
  title: string;
  session_status?: string;
  connection_status?: string;
  environment_id?: string;
  created_at?: string;
  session_context?: {
    sources?: Array<{ url?: string; revision?: string }>;
    outcomes?: Array<{ git_info?: { repo?: string } }>;
  };
}

export interface Environment {
  environment_id: string;
  name: string;
  kind: string;
  state: string;
  created_at: string;
}

export async function listEnvironments(): Promise<Environment[]> {
  const res = await fetch(`${BASE}/v1/environment_providers`, { headers: await headers() });
  if (!res.ok) throw new Error(`envs failed ${res.status}: ${await res.text()}`);
  const body = (await res.json()) as { environments: Environment[] };
  return body.environments ?? [];
}

export async function listSessions(): Promise<SessionSummary[]> {
  const res = await fetch(`${BASE}/v1/sessions`, { headers: await headers() });
  if (!res.ok) throw new Error(`list failed ${res.status}: ${await res.text()}`);
  const body = (await res.json()) as { data: SessionSummary[] };
  return body.data ?? [];
}

export async function getSession(sessionId: string): Promise<SessionSummary> {
  const res = await fetch(`${BASE}/v1/sessions/${sessionId}`, { headers: await headers() });
  if (!res.ok) throw new Error(`get ${sessionId} failed ${res.status}: ${await res.text()}`);
  return (await res.json()) as SessionSummary;
}

export interface SessionEvent {
  event_id?: string;
  type?: string;
  event_type?: string;
  created_at?: string;
  message?: { role?: string; content?: unknown };
  payload?: unknown;
}

export async function getEvents(
  sessionId: string,
  opts: { afterId?: string } = {},
): Promise<{ data: SessionEvent[]; last_id?: string; has_more?: boolean }> {
  const url = new URL(`${BASE}/v1/sessions/${sessionId}/events`);
  if (opts.afterId) url.searchParams.set("after_id", opts.afterId);
  const res = await fetch(url, { headers: await headers() });
  if (!res.ok) throw new Error(`events ${sessionId} failed ${res.status}: ${await res.text()}`);
  return (await res.json()) as { data: SessionEvent[]; last_id?: string; has_more?: boolean };
}

export interface WaitResult {
  finalText: string;
  resultEvent: SessionEvent;
}

/**
 * Poll a session's events until a `result` event appears, then return the
 * final assistant text (concatenated text blocks of the last assistant turn).
 */
export async function waitForResult(
  sessionId: string,
  opts: { timeoutMs?: number; pollMs?: number } = {},
): Promise<WaitResult> {
  const timeoutMs = opts.timeoutMs ?? 15 * 60 * 1000;
  const pollMs = opts.pollMs ?? 3000;
  const started = Date.now();
  let lastAssistant = "";
  let afterId: string | undefined;

  while (Date.now() - started < timeoutMs) {
    const res = await getEvents(sessionId, { afterId });
    for (const e of res.data) {
      const t = e.type ?? e.event_type;
      if (t === "assistant") {
        const msg = e.message ?? (e.payload as { message?: unknown } | undefined)?.message;
        const content = (msg as { content?: unknown } | undefined)?.content;
        if (Array.isArray(content)) {
          const texts = content
            .filter((c: Record<string, unknown>) => c.type === "text")
            .map((c: Record<string, unknown>) => String(c.text));
          if (texts.length) lastAssistant = texts.join("\n");
        }
      }
      if (t === "result") {
        return { finalText: lastAssistant, resultEvent: e };
      }
    }
    if (res.last_id) afterId = res.last_id;
    if (res.has_more) continue;
    await new Promise((r) => setTimeout(r, pollMs));
  }
  throw new Error(`wait ${sessionId} timed out after ${Math.round(timeoutMs / 1000)}s`);
}

export async function sendPrompt(sessionId: string, prompt: string): Promise<void> {
  const body = {
    events: [
      {
        uuid: randomUUID(),
        session_id: sessionId,
        type: "user",
        parent_tool_use_id: null,
        message: { role: "user", content: prompt },
      },
    ],
  };
  const res = await fetch(`${BASE}/v1/sessions/${sessionId}/events`, {
    method: "POST",
    headers: await headers(),
    body: JSON.stringify(body),
  });
  if (!res.ok) throw new Error(`send ${sessionId} failed ${res.status}: ${await res.text()}`);
}

export async function archiveSession(sessionId: string): Promise<void> {
  const res = await fetch(`${BASE}/v1/sessions/${sessionId}/archive`, {
    method: "POST",
    headers: await headers(),
  });
  if (!res.ok && res.status !== 409) {
    throw new Error(`archive ${sessionId} failed ${res.status}: ${await res.text()}`);
  }
}

export interface CreateSessionInput {
  repo: string;
  environmentId: string;
  prompt: string;
  title?: string;
  branch?: string;
  model?: string;
}

export interface CreateSessionResult {
  sessionId: string;
  raw: unknown;
}

export async function createSession(
  input: CreateSessionInput,
): Promise<CreateSessionResult> {
  const branch = input.branch ?? "main";
  const body = {
    title: input.title ?? input.prompt.slice(0, 100),
    environment_id: input.environmentId,
    session_context: {
      sources: [
        {
          type: "git_repository",
          url: `https://github.com/${input.repo}`,
          revision: branch,
        },
      ],
      outcomes: [
        {
          type: "git_repository",
          git_info: { type: "github", repo: input.repo, branches: [] },
        },
      ],
      model: input.model ?? "claude-opus-4-7[1m]",
    },
    events: [
      {
        type: "event",
        data: {
          uuid: randomUUID(),
          session_id: "",
          type: "user",
          parent_tool_use_id: null,
          message: { role: "user", content: input.prompt },
        },
      },
    ],
  };

  const res = await fetch(`${BASE}/v1/sessions`, {
    method: "POST",
    headers: await headers(),
    body: JSON.stringify(body),
  });
  if (!res.ok) throw new Error(`create failed ${res.status}: ${await res.text()}`);
  const json = (await res.json()) as { id: string };
  return { sessionId: json.id, raw: json };
}

/** One-shot: create a session with a prompt, wait for completion, return text. */
export async function executePrompt(
  input: CreateSessionInput & { timeoutMs?: number },
): Promise<{ sessionId: string; finalText: string }> {
  const { sessionId } = await createSession(input);
  const { finalText } = await waitForResult(sessionId, { timeoutMs: input.timeoutMs });
  return { sessionId, finalText };
}

async function main() {
  const [cmd, ...args] = process.argv.slice(2);
  if (cmd === "envs") {
    const envs = await listEnvironments();
    for (const e of envs) {
      console.log(`${e.environment_id}  ${e.state}  ${e.name}`);
    }
  } else if (cmd === "list") {
    const rows = await listSessions();
    for (const s of rows) {
      const repo = s.session_context?.outcomes?.[0]?.git_info?.repo ?? "-";
      console.log(`${s.id}  ${s.session_status ?? "?"}  ${repo}  ${s.title}`);
    }
  } else if (cmd === "status") {
    if (!args[0]) throw new Error("usage: status <sessionId>");
    const s = await getSession(args[0]);
    console.log(JSON.stringify(s, null, 2));
  } else if (cmd === "events") {
    if (!args[0]) throw new Error("usage: events <sessionId> [limit]");
    const limit = args[1] ? Number(args[1]) : 20;
    const res = await getEvents(args[0]);
    const rows = res.data.slice(0, limit);
    for (const e of rows) {
      const t = e.type ?? e.event_type ?? "?";
      const when = e.created_at ?? "";
      let detail = "";
      if (t === "assistant" || t === "user") {
        const msg = e.message ?? (e.payload as { message?: unknown } | undefined)?.message;
        const content = (msg as { content?: unknown } | undefined)?.content;
        if (typeof content === "string") detail = content.slice(0, 200);
        else if (Array.isArray(content)) {
          detail = content
            .map((c: Record<string, unknown>) =>
              c.type === "text"
                ? String(c.text).slice(0, 200)
                : c.type === "tool_use"
                  ? `[tool_use: ${String(c.name)}]`
                  : c.type === "tool_result"
                    ? "[tool_result]"
                    : `[${String(c.type)}]`,
            )
            .join(" ");
        }
      }
      console.log(`${when}  ${t}  ${detail}`);
    }
  } else if (cmd === "execute") {
    const [repo, envId, prompt, timeoutSec] = args;
    if (!repo || !envId || !prompt) {
      throw new Error('usage: execute <repo> <envId> "<prompt>" [timeoutSec]');
    }
    const timeoutMs = timeoutSec ? Number(timeoutSec) * 1000 : undefined;
    const { sessionId, finalText } = await executePrompt({
      repo,
      environmentId: envId,
      prompt,
      timeoutMs,
    });
    console.error(`# session ${sessionId}`);
    console.log(finalText);
  } else if (cmd === "wait") {
    if (!args[0]) throw new Error("usage: wait <sessionId> [timeoutSec]");
    const timeoutMs = args[1] ? Number(args[1]) * 1000 : undefined;
    const { finalText } = await waitForResult(args[0], { timeoutMs });
    console.log(finalText);
  } else if (cmd === "send") {
    if (!args[0] || !args[1]) throw new Error('usage: send <sessionId> "<prompt>"');
    await sendPrompt(args[0], args[1]);
    console.log(`sent to ${args[0]}`);
  } else if (cmd === "archive") {
    if (!args[0]) throw new Error("usage: archive <sessionId>");
    await archiveSession(args[0]);
    console.log(`archived ${args[0]}`);
  } else if (cmd === "create") {
    const [repo, envId, prompt, title] = args;
    if (!repo || !envId || !prompt) {
      throw new Error('usage: create <repo> <envId> "<prompt>" [title]');
    }
    const r = await createSession({ repo, environmentId: envId, prompt, title });
    console.log(JSON.stringify(r, null, 2));
  } else if (cmd === "help" || cmd === "-h" || cmd === "--help" || cmd === undefined) {
    console.log(HELP_TEXT);
  } else {
    console.error(`unknown command: ${cmd}\n\n${HELP_TEXT}`);
    process.exit(1);
  }
}

const HELP_TEXT = `remote-session — spawn and drive Claude Code remote sessions from the shell.

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
  wait    <sessionId> [timeoutSec=900]       Block until \`result\` event; print final assistant text
  archive <sessionId>                        Archive a session when done
  create  <repo> <envId> "<prompt>" [title]  Create session with initial prompt; returns JSON
  execute <repo> <envId> "<prompt>" [timeoutSec=900]
                                             One-shot: create + wait + print final text (recommended)

TYPICAL FLOW (synchronous, one-shot)
  tsx remote-session.ts envs                 # pick an env_... ID once
  tsx remote-session.ts execute owner/repo env_01Xxx "Summarize the main README in 3 bullets."

TYPICAL FLOW (async / multi-turn)
  sid=$(tsx remote-session.ts create owner/repo env_01Xxx "Start exploring" | jq -r .sessionId)
  tsx remote-session.ts events "$sid"
  tsx remote-session.ts send   "$sid" "Now open a PR with your findings"
  tsx remote-session.ts wait   "$sid"
  tsx remote-session.ts archive "$sid"

PROMPTING TIPS
  - Tell the session what to produce ("respond with only the version number").
  - Scope it tightly — each session starts fresh and has no memory.
  - For read-only tasks, say "do not modify files". For write tasks, say whether
    you want a PR.
  - Opus 4.7 1M-context is the default model.

AUTH
  Token:  $CLAUDE_OAUTH_TOKEN, else /home/claude/.claude/remote/.oauth_token
  OrgID:  $CLAUDE_CODE_ORGANIZATION_UUID, else decoded from the session
          ingress JWT (works inside any Claude Code remote session),
          else GET /api/oauth/profile (needs user:profile scope).
`;

if (import.meta.url === `file://${process.argv[1]}`) {
  main().catch((e) => {
    console.error(e);
    process.exit(1);
  });
}
