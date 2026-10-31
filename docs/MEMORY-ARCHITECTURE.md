# MEMORY-ARCHITECTURE.md — shared graph memory for the orchestrator (TASK 4, 2026-10-16)

## Roles (do not confuse the tools)

| Tool | Role | What it stores |
|---|---|---|
| **GrafMCP** (`SecCodeSmith/GrafMCP`, MIT) | Persistent graph memory: facts, decisions, relationships, cross-session continuity | Entities + observations + typed relations in Kuzu |
| **Graphify** (`Graphify-Labs/graphify` 0.9.91, Apache-2.0) | Codebase knowledge graph: symbols, calls, imports, dependencies | `graphify-out/graph.json` per repo (tree-sitter AST, EXTRACTED/INFERRED edges) |
| OpenCode / Antigravity | Execution backends only | — |
| Muse (Luffy) | Coordinator, planner, memory manager, verification authority | — |

AGENTS.md, WORKBOARD.md, Git, source files, and tests stay authoritative for
their purposes. Graph memory is a **retrieval layer**, not a replacement.

## Authenticity record (verified 2026-10-16)

- Genuine Graphify = `Graphify-Labs/graphify`, PyPI package **`graphifyy`**
  (double-y). Installed via `uv tool install graphifyy` → `graphify 0.9.91`.
  The README explicitly warns other `graphify*` packages are unaffiliated.
- The pre-existing npm `@sentropic/graphify` v0.19.0
  (`~/workspace/tools/graphify`) is a **deprecated Engram forwarding shim**
  (a different product — agent memory substrate), NOT genuine Graphify.
  Left installed and untouched; its old graph output was backed up to
  `~/workspace/repos/Quantum_Spark_QDE_v2/graphify-out.engram-20261003/`.
- `github.com/Graphify-Labs/graphify-mcp` documents the **hosted cloud** MCP
  service (api.graphify.com, OAuth, account required) — deliberately NOT used
  (local-first, no new accounts, no spending).

## Installed locations & versions

- Graphify CLI: `~/.local/bin/graphify` → `graphify 0.9.91` (uv tool, isolated).
  `uv` 0.13.1 at `~/.local/bin/uv`.
- GrafMCP: `~/workspace/tools/grafmcp` (git clone of SecCodeSmith/GrafMCP).
  Daemon: `node src/daemon.js`, **PID 46506 → 49751 after test restart**,
  listens **127.0.0.1:7688 ONLY** (verified via `ss`).
  DB: `~/workspace/tools/grafmcp/data/graph.kuzu` (Kuzu embedded, single writer = daemon).
  Activity log: `~/workspace/tools/grafmcp/data/activity.jsonl`.
  Dashboard: `http://127.0.0.1:7688` (no auth — localhost-only is a hard requirement).
  Bridge (stdio, per agent launch): `node ~/workspace/tools/grafmcp/src/index.js`.
- OpenCode skill: `~/.config/opencode/skills/graphify/SKILL.md` (+ references/).
- Antigravity skill: `~/.gemini/config/skills/graphify/` (installed by
  `graphify antigravity install`; cwd-relative `.agents/` files landed in /tmp, harmless).

## MCP wiring (verified 2026-10-16)

Antigravity `~/.gemini/antigravity/mcp_config.json`
(backup: `mcp_config.json.bak-20261016-task4`):
- `graf-memory`: `node $HOME/workspace/tools/grafmcp/src/index.js`
  (stdio; bridge auto-spawns/self-heals the daemon)
- `graphify`: `uv run --with graphifyy --with mcp -m graphify.serve ${workspace.path}/graphify-out/graph.json`
  (replaced the dead `python3 -m graphify.serve` entry — no such module ever existed).
  `${workspace.path}` is expanded by the Antigravity IDE surface.
- NOTE: the `agy` **CLI** does not read `mcp_config.json`; it uses its own
  registry: `agy mcp add graf-memory node $HOME/workspace/tools/grafmcp/src/index.js`
  (reversible via `agy mcp remove`). Headless agy auto-denies MCP calls, so
  non-interactive runs need `--dangerously-skip-permissions` (covered by
  the user's standing auto-approve setting for Antigravity).

OpenCode `~/workspace/orchestrator/opencode-safe.json`
(backup: `opencode-safe.json.bak-20261016-task4`):
- Accepted shape (empirical, `opencode mcp list` → `✓ graf-memory connected`):
  `{"mcp": {"graf-memory": {"type": "local", "command": ["node", "$HOME/workspace/tools/grafmcp/src/index.js"], "enabled": true}}}`

## Workspace naming policy

GrafMCP auto-selects a workspace from the bridge's launch-folder basename,
which is unpredictable for both agents — **every graf-memory tool call MUST
pass an explicit `workspace` argument**. Naming: the repository directory
basename (`orchestrator`, `Quantum_Spark_QDE_v2`, `SEVA-FIRST-CHALLENGE`).
Disposable test workspaces are prefixed `task4-` / suffixed `-selftest` and
deleted after use. `workspace: "all"` is read-only cross-workspace search.

## Memory categories → entity types

| # | Category | Entity types | Relations (examples) |
|---|---|---|---|
| 1 | User-approved durable preferences & operating instructions | `preference`, `instruction` | `supersedes` |
| 2 | Project goals, architecture, constraints, technical decisions | `goal`, `architecture`, `constraint`, `decision` | `constrains`, `implements` |
| 3 | Implementation discoveries & debugging lessons | `discovery`, `lesson`, `bug` | `caused_by`, `fixed_by` |
| 4 | Task ownership, progress, dependencies, blockers | `task`, `blocker` | `depends_on`, `blocked_by`, `owned_by` |
| 5 | Repo paths, symbols, commits, test evidence | `module`, `symbol`, `commit`, `test_evidence` | `defined_in`, `verified_by` |
| 6 | Cross-project reusable lessons | `lesson` (workspace `all`-searchable) | `applies_to` |
| 7 | Backend handoff notes (OpenCode ↔ Antigravity) | `handoff` | `continues`, `handed_to` |

Rules: stable entity names; associate every entry with project/repo/workspace;
**supersede, don't contradict** — when a decision becomes obsolete, `remember`
the new fact on the same entity and `forget` the stale observation;
never store secrets, tokens, private keys, or huge raw logs.

## Memory-first workflow

**Task start** (before routing):
1. Identify repo + workspace (basename).
2. `recall` keywords from the request in that workspace; `expand` (depth 2)
   the best hits.
3. `graphify explain` / `path` / `query` the relevant symbols
   (`--graph <repo>/graphify-out/graph.json`).
4. `git status` + read only the files needed to confirm retrieved info.
5. Create/update the WORKBOARD task entry.
6. Route per the existing routing policy.

**Task end** (after verification):
1. `remember` durable discoveries / changed decisions / reusable lessons.
2. Record commit ids, paths, verification results.
3. Update task status + handoff notes (WORKBOARD + `tasks/<id>.md`).
4. `graphify update <repo>` after meaningful source changes
   (incremental, no LLM; see refresh commands below).
5. Run tests; record actual outcomes.

Trivial questions skip memory writes. If memory retrieval fails, report it and
fall back to normal repo inspection — never invent context.

## Graphify indexing & refresh

| Repo | Graph | Command |
|---|---|---|
| `~/workspace/orchestrator` | 70 nodes / 102 edges | `graphify extract ~/workspace/orchestrator --code-only --no-label` |
| `~/workspace/repos/Quantum_Spark_QDE_v2` | 17,147 nodes / 40,564 edges (87% EXTRACTED) | `graphify extract ~/workspace/repos/Quantum_Spark_QDE_v2 --code-only --no-label` |
| `~/workspace/repos/SEVA-FIRST-CHALLENGE` | docs-only (30 docs, 0 code) — needs one LLM-backed run | `graphify extract ~/workspace/repos/SEVA-FIRST-CHALLENGE` with an LLM key (BLOCKED: no-spending constraint) |

Refresh: `graphify update <path>` (incremental, no LLM),
`graphify watch <path>` (auto-rebuild), `graphify check-update <path>` (cron-safe).
Query: `graphify explain "<symbol>" --graph <graph.json>`,
`graphify path "<a>" "<b>" --graph <graph.json>`,
`graphify query "<question>" --graph <graph.json>`.

## Network topology & access control (verified)

- Host: Muse VM (`$HOME`). Service owner: GrafMCP daemon (single writer).
- Endpoints: `http://127.0.0.1:7688` (dashboard + MCP `POST /mcp` + JSON API).
  **All 15 HTTP routes are unauthenticated** (incl. `POST /api/shutdown`,
  `POST /api/edit` with `delete_workspace`, `GET /api/graph`) and responses
  carry `Access-Control-Allow-Origin: *` — any local process or local web page
  can read/write/delete memory. **Localhost-only bind is therefore a HARD
  security requirement.**
- No 0.0.0.0 bind, no firewall ports opened, no tunnels published.
  Remote access: unsupported without the user's explicit authorization — if ever
  needed, via private VPN or authenticated tunnel only, never direct exposure.
- No private IPs, credentials, or tokens are stored in repo files.

## Backup & recovery

- `cd ~/workspace/tools/grafmcp && npm run backup` → `backups/memory-<ts>.json`
  (reads the live daemon over HTTP; daemon keeps running).
- Restore: `npm run stop`, then
  `npm run restore -- backups/memory-<ts>.json` (needs exclusive DB access),
  then start again (`npm start` or first agent connect).
- Restore was **verified 2026-10-16** against a `/tmp` copy of the DB
  (production untouched): 4 entities / 5 facts / 1 relation round-tripped.
- Retention: keep timestamped JSON snapshots; no age-based auto-deletion.
  Destructive workspace deletion (`delete_workspace`, dashboard 🗑) requires
  explicit approval per incident — never automated.

## Known limitations (2026-10-16)

1. **OpenCode free-model gateway hanging** since ~13:35 IST (all free models,
   pristine config too — provider-side, not caused by this work). The
   orchestrator's Antigravity fallback covers it; `agy` verified healthy.
   Re-check `opencode run` before relying on the OpenCode backend.
2. SEVA-FIRST-CHALLENGE docs graph needs one LLM-backed `graphify extract`
   (spending approval required).
3. `${workspace.path}` in the agy graphify MCP entry expands on the
   Antigravity IDE surface; the `agy` CLI registry uses the skill/CLI path instead.
4. GrafMCP `cleanup` removes only exact-duplicate facts; contradictory memories
   need manual `forget`/supersede.
5. Conversations are NOT auto-persisted — only what agents explicitly `remember`.
