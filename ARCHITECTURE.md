# Architecture — Multi-Agent Orchestrator

Short version. The full operating manual is [`docs/ORCHESTRATION.md`](docs/ORCHESTRATION.md); the memory design is [`docs/MEMORY-ARCHITECTURE.md`](docs/MEMORY-ARCHITECTURE.md).

## Components

1. **Coordinator CLI (`orchestrator`)** — bash, stdlib + `jq` only. Commands: `status`, `plan`, `run`, `logs`, `resume`. Owns task state (`tasks/<id>.json`) and sanitized logs.
2. **Router (`router.sh`)** — pure deterministic policy. Inputs: complexity, per-backend readiness, config rules. Outputs: primary backend + ordered fallback chain. No hidden state, no LLM in the routing path — the same inputs always give the same route, and an explicit backend override fails closed.
3. **Backend adapters (`backends/*.sh`)** — one per CLI (Qoder, Antigravity, OpenCode), one shared contract:
   `available` (binary + auth) → `smoke` (live readiness probe) → `run` (prompt on stdin, structured result out) → `classify_error` (stderr/exit → failure class) → `sanitize` (redact secret-looking values from logs in place).
4. **Config (`config.json`)** — models per backend and complexity tier, timeouts, retry budget + backoff, fallback triggers, and the safety block (approval-required actions, destructive-command policy).
5. **Shared memory (GrafMCP, optional)** — one MCP graph-memory server for all backends, namespaced per project workspace. Recall at task start; remember durable outcomes at task end.

## Data flow for one task

```
brief ─▶ plan (router picks backend by complexity + readiness)
      ─▶ run (adapter executes in the target dir, optional git worktree)
      ─▶ output captured ─▶ sanitized log + task state written
      ─▶ on classified transient failure: bounded retry, then next backend in chain
      ─▶ on success: result returned for human verification — never auto-accepted
      ─▶ resume re-enters the same backend session with prior context
```

## Key decisions

- **Bash + jq, no framework.** The system must survive VM replacements and tool churn; the fewer dependencies, the longer it lives. Every piece is inspectable with `cat`.
- **Deterministic routing over "smart" routing.** Predictability beats cleverness when the failure mode is a burned afternoon. Complexity is a human/coordinator judgment at brief time; the router just executes policy.
- **Failure taxonomy before fallback.** Rate-limit, auth, timeout, and model errors are retryable/routable; network errors are not blindly retried; an unclassifiable failure stops and reports. Free-tier model caps are per-model, so the router treats "backend down" and "model capped" as different signals.
- **Sanitize at the source.** Logs are redacted by the adapter that produced them, before they touch disk — not by a later cleanup pass that might never run.
- **Verification is a gate, not a vibe.** A backend's "done" only opens review. The brief's own Verify command decides.
- **State survives everything.** Blocked tasks persist with their state; a dead backend loses a run, never the work.

## Safety boundaries

- Destructive shell patterns denied in the OpenCode permission profile (`opencode-safe.json`).
- Push, deploy, publish, production migration, and spending are **approval-required** — the orchestrator prepares, a human commits.
- No credentials live in this repo. Backends use their own CLI auth; `config.json` (machine paths, local models) is git-ignored — only `config.example.json` ships.
