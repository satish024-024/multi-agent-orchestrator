# ORCHESTRATION.md — OpenCode + Antigravity orchestration

## Architecture

```
You — the human coordinator
        │  plans, decomposes, routes, reviews
        ▼
┌─────────────────────────────┐
│ orchestrator (CLI, bash)    │
│  status · plan · run ·      │
│  logs · resume              │
├─────────────────────────────┤
│ router.sh (deterministic)   │  config.json thresholds
├──────────────┬──────────────┤
│ opencode.sh  │ antigravity.sh│  backend adapters
│ (adapter)    │ (adapter)     │
├──────────────┴──────────────┤
│ tasks/<id>.json + <id>.md   │  task contract + handoff notes
│ logs/<id>.log (sanitized)   │
└─────────────────────────────┘
        │                 │
        ▼                 ▼
  OpenCode CLI       agy CLI
  routine coding     complex reasoning,
  free models        integration, fallback
        │                 │
        └────────┬────────┘
                 ▼
        Verification gate: tests,
        git diff, coordinator review
```

Muse stays the coordinator; the two CLIs are execution backends only. The
repository's own tests are the final quality gate — a task is `done` only when
its verification step passes.

## Backends (verified 2026-10-16)

| | OpenCode | Antigravity |
|---|---|---|
| Binary | `~/.opencode/bin/opencode` v1.19.2 | `~/.local/bin/agy` v1.4.0 |
| Install source | Official: `curl -fsSL https://opencode.ai/install \| bash` (OpenCode 1, repo `anomalyco/opencode`) | Pre-existing |
| Default model | `opencode/deepseek-v4.1-flash-free` (DeepSeek V4.1 Flash, free, cost=0, no credentials needed) | `gemini-3.8-flash-low` |
| Complex model | `opencode/deepseek-v4.1-flash` (paid Console) | `claude-opus-4-6-thinking` |
| Run interface | `opencode run --dir DIR -m provider/model --format json "prompt"`; resume with `-s SESSION --fork` | `agy --model M --effort E --output-format json --print-timeout Ns -p "prompt"`; resume with `--conversation ID --continue` |
| Structured output | NDJSON events (`step_start`, `text`, `step_finish` with tokens+cost) | JSON `{conversation_id, status, response, duration_seconds, num_turns, usage}` |
| Native timeout | none — wrapped with `timeout(1)` | `--print-timeout <duration>` + external `timeout(1)` |
| Auth | OpenCode Console free models work with zero stored credentials | Antigravity OAuth (healthy); `~/.gemini/` never touched by the orchestrator |

Other verified-free model IDs: `opencode/mimo-v2.6-flash-free`,
`opencode/nemotron-3.5-lightning-free`, `opencode/nemotron-3-ultra-free`,
`opencode/nemotron-3.5-super-vl-free`, `opencode/muse-spark-1.3-contributor-free`,
`opencode/big-pickle`, `opencode/space-bunny-free`, `opencode/cat-jam-free`,
`opencode/longcat-2.5-preview-free`, `opencode/glm-5.3-flash-free`. All are
"free for a limited time" per opencode.ai/docs — the router treats model
availability as checked at runtime, never assumed.

## Routing policy (deterministic; see `router.sh`, tunables in `config.json`)

- `low` / `medium` complexity or unspecified → **OpenCode** (free, fast).
- `high` complexity → **Antigravity** with the complex model.
- Explicit `--backend opencode|antigravity` overrides the policy (fails closed if that backend is not ready).
- If the chosen backend is unavailable/degraded → the other backend (fallback).
- If neither is usable → task is **blocked**, state preserved, reason recorded. Never invents quota data; never double-executes.

Retries: `max_retries_per_backend` (default 2) with exponential backoff
(`retry_backoff_base_seconds` × attempt) on error classes `rate_limit, auth,
timeout, model_error`. `network` errors do not trigger fallback
(they usually affect both backends). Fallback happens at most once per task
— the orchestrator never ping-pongs between backends (QA fix 2026-10-16).
`fatal` errors (bad workdir, oversized prompt) fail fast with no retry.

## Task contract (`tasks/<id>.json`)

`id, description, workdir, complexity, backend, model, timeout_seconds,
status (planned|running|done|failed|blocked), git_status_before, worktree,
logs[], changed_files[], conversation_id, session_id, result{}, handoff`.
A human-readable handoff note (`tasks/<id>.md`) is written after every run and
resume so work can continue after context loss: it carries the resume command.

## Memory integration (TASK 4, 2026-10-16)

Full architecture: `docs/MEMORY-ARCHITECTURE.md`. Summary of what the
orchestrator and both backends now use:

- **GrafMCP** (persistent fact memory): daemon on `127.0.0.1:7688`
  (localhost-only, unauthenticated routes — never expose), DB
  `~/workspace/tools/grafmcp/data/graph.kuzu`. 12–22 tools
  (`remember`/`recall`/`expand`/`connect`/`find_nodes`/`search_facts`/`get_node`/
  `tree`/`read_graph`/`forget`/…).
- **Graphify** (code knowledge graph): `graphify 0.9.91` CLI
  (`~/.local/bin/graphify`); per-repo `graphify-out/graph.json`
  (orchestrator: 70 nodes; Quantum_Spark_QDE_v2: 17,147 nodes).
- **Wiring**: agy IDE config `~/.gemini/antigravity/mcp_config.json` has
  `graf-memory` (stdio bridge) + `graphify` (uv-run MCP server,
  workspace-relative graph path); the `agy` CLI registry has `graf-memory`
  (`agy mcp add`, since the CLI ignores `mcp_config.json`); OpenCode runs via
  `opencode-safe.json` → `{"mcp": {"graf-memory": {"type": "local", ...}}}`
  (flat shape verified with `opencode mcp list`).
- **Workspace rule**: every graf-memory call passes an explicit `workspace`
  (repo dir basename); auto-folder workspace is unreliable for both agents.
- **Memory-first workflow**: task start = `recall`+`expand` (GrafMCP),
  `explain`/`path`/`query` (Graphify), git status, then route; task end =
  `remember` discoveries/decisions, update handoffs, `graphify update <repo>`,
  run tests. Cross-agent OpenCode↔Antigravity memory sharing verified with
  canary tests 2026-10-16 (see `tests/memory-results-20261016.md`).

## Safety rules

- Least privilege: OpenCode runs under `opencode-safe.json` (`OPENCODE_CONFIG`)
  — read/glob/grep/write/edit allowed inside the project dir; bash allows
  everything EXCEPT a denylist (`rm -rf*`, `sudo*`, `curl|bash`, `git push*`,
  `npm publish*`, `mkfs*`, `dd*`, `chmod -R*`, `chown*`, `apt*`, `shutdown*`,
  `wget|sh`).
  **Honest limitation (QA 2026-10-16):** a denylist is a guardrail, not a
  sandbox — it is bypassable via shell tricks (`rm -r -f`, `/bin/rm`,
  `$(...)`, chaining). The real safety boundaries are: tasks run in their
  designated project dir (disposable `/tmp` repos for untrusted work), no
  auto-push/deploy, and coordinator review of every diff before anything
  consequential happens.
  agy is never given `--dangerously-skip-permissions`.
- Git gate: pre-run `git status`/`diff --stat` is recorded in the task. Dirty
  worktrees are recorded as "understood"; `--worktree BRANCH` creates an
  isolated git worktree for parallel/conflicting work. No agent may overwrite
  another's uncommitted work — separate worktrees, coordinator merges.
- Approval gates: push, deploy, publish, production migrations, and any spending
  are in `safety.actions_requiring_approval` — the orchestrator never performs
  them itself; they need human approval.
- Timeouts on every execution; runaway processes are killed by `timeout(1)`.
- Logs are sanitized (secret-looking values redacted) before being written.
- Secrets and machine-specific config stay out of version control; the
  orchestrator never reads credential stores (`~/.local/share/opencode/auth.json`,
  `~/.gemini/` tokens).

## Operational commands

```
orchestrator status                                  # backend versions + readiness (smoke-tested, cached 10 min)
orchestrator plan "<task>" [--complexity C] [--dir D]
orchestrator run "<task>" [--backend opencode|antigravity] [--complexity low|medium|high] \
                        [--dir DIR] [--timeout S] [--worktree BRANCH]
orchestrator logs <task-id> [--tail N]
orchestrator resume <task-id> [--timeout S]
```

## Recovery procedures

- **Interrupted task**: `orchestrator resume <id>` re-executes with the recorded
  session/conversation token so the backend continues with prior context.
- **Backend down mid-task**: automatic fallback to the other backend (one
  attempt), then the task is marked `failed` with the error class; the handoff
  note preserves everything needed to retry manually.
- **Both backends down**: task marked `blocked`; `status` shows which readiness
  check failed; fix auth/network, then `resume`.
- **Rate limited**: classified as `rate_limit`; bounded retries with backoff, then
  fallback. The orchestrator never claims to know remaining quota.
- **Conflicting parallel work**: rerun with `--worktree <branch>`; the
  coordinator reconciles branches and runs tests before merging.

## Known limitations / next improvements

1. OpenCode free models are "limited time" offers — if they disappear, `status`
   degrades to `degraded` and routing falls back to Antigravity automatically.
   **Observed 2026-10-16 ~13:35 IST:** the free-model gateway hangs for ALL
   free models (zero output, 60–90s; pristine config hangs too — provider-side,
   not caused by TASK 4). Re-check `opencode run` before relying on OpenCode;
   `agy` verified healthy and is the live fallback.
2. No native OpenCode usage/quota API — quota state is inferred from error
   classification only.
3. Decomposition of large tasks into subtasks is still the coordinator's job;
   the router scores one task at a time (no automatic fan-out yet).
4. `agy models` listing is auth-dependent; if Antigravity auth lapses, the
   adapter reports `auth-failed` and routing excludes it.
5. agy self-updates (observed 1.3.3 → 1.4.0 during setup) — adapter pins behavior
   to verified flags, not versions.

## Readiness cache (fixed 2026-10-16)

`readiness()` caches backend health for 10 min. Two hardening rules (added after
transient `ag_smoke` timeouts under concurrent load blocked real work):
1. Recomputation is serialized with `flock`; waiters serve the stale cache.
2. Failures are NEVER cached — only a check with at least one backend "yes" is
   persisted. A total failure is served once to its caller and not stored.
`orchestrator` binary backed up at `orchestrator.bak-20261016-readiness`.

## Hot-edit warning (lesson 2026-10-16)

Never edit the `orchestrator` script while background `run` jobs are in flight.
Bash parses the script incrementally; inserting lines mid-file shifts byte
offsets and the running shell executes wrong lines (observed: a `run` job
jumped into `cmd_resume` code after a readiness-cache patch). Wait for jobs to
finish, or accept that in-flight jobs may misbehave.
