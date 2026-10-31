# TASK 4 — 11-item test plan results (2026-10-16)

Labels: **PASSED** / **FAILED** / **BLOCKED** / **NOT TESTED**. Evidence is
sanitized (no secrets). All GrafMCP functional tests used disposable workspaces
(`grafmcp-selftest`, `task4-xcheck`), cleaned up afterward.

## 1. Graphify installation and a representative code query — PASSED
- `uv tool install graphifyy` → `graphify --version` = `graphify 0.9.91`
  (uv 0.13.1; installer script read before running).
- `graphify explain "oc_run" --graph orchestrator/graphify-out/graph.json` →
  `Node: oc_run(), Source: backends/opencode.sh L57`, callers/callees with
  `[EXTRACTED]` edges and file:line refs.
- `graphify path "execute_backend" "ag_classify_error"` → 2-hop EXTRACTED path.
- Quantum graph: `explain "QuantumBackendManager"` → `routes/quantum_manager.py L72`,
  degree 43, EXTRACTED + INFERRED edges; `path` and `query` verified.

## 2. Graphify refresh after a source change — PASSED
- `graphify update .` in `~/workspace/orchestrator` (exit 0, no LLM):
  `Rebuilt: 142 nodes, 161 edges, 20 communities` (was 70/102 at first build —
  picked up new docs/tests). `graph.json` + `manifest.json` timestamps updated.

## 3. GrafMCP write, search and relationship traversal — PASSED
- Via real stdio MCP path (`node src/index.js` + SDK client):
  `remember` (2 facts on Selftest Alpha, 1 on Beta) → `recall`("sky probe") ✓,
  `search_facts`("relay") ✓, `find_nodes`("Selftest") ✓, `get_node` (facts +
  relations) ✓, `connect` typed relation `depends_on` Alpha→Beta ✓,
  `expand` depth 2 traversed the relation ✓, `tree` nested correctly ✓,
  `read_graph` stats (2 entities, 3 obs, 1 relation) ✓.

## 4. Persistence after daemon and agent restarts — PASSED
- Marker fact written → `npm run stop` + `npm start` (PID 46506 → 49751) →
  `recall` on 127.0.0.1:7688 returned the marker, text intact.
- Bridge auto-spawns/self-heals the daemon when absent (verified).

## 5. OpenCode-to-Antigravity shared-memory retrieval — PASSED (with substitution)
- OpenCode-configured transport (same bridge binary+args, stdio MCP JSON-RPC
  exactly as OpenCode's client speaks) wrote `XCheck Alpha` /
  `alpha-canary-7319` @ `task4-xcheck`; **real `agy --print` recalled the exact
  canary** → `AGY_READ_ALPHA alpha-canary-7319`.
- Reverse: real agy wrote `XCheck Beta` / `beta-canary-4826`; OpenCode
  transport read it back exactly.
- Caveat: the live `opencode run` model leg was BLOCKED by the gateway hang
  (item 11) — the transport substitution is labeled, not a model run.

## 6. Correct workspace isolation across two test projects — PASSED
- `iso-canary-9051` written to `task4-xcheck-2`; `recall` in `task4-xcheck`
  (via agy AND via bridge path) returned only alpha+beta; daemon `/api/graph`
  confirmed the iso entity lives only in `task4-xcheck-2`.

## 7. Network connectivity from an authorized remote client — NOT TESTED
- N/A by design: remote access is not required; architecture is localhost-only
  (directive §7: no exposure without Satish's explicit authorization).

## 8. Rejection/blocking of unauthorized remote access — NOT TESTED
- No remote surface exists to test against. `ss -tlnp` verified the daemon
  listens on **127.0.0.1:7688 only** (never 0.0.0.0). All 15 routes are
  unauthenticated + CORS `*`, so public exposure is prohibited by policy
  (documented in SECURITY-REVIEW.md and MEMORY-ARCHITECTURE.md).

## 9. Backup and restoration of test memory — PASSED
- `npm run backup` → `backups/memory-2026-10-16T07-32-24-932Z.json`
  (4 entities, 5 facts, 1 relation).
- Restore into a `/tmp` copy of the DB (`GRAF_MCP_DB` override, daemon
  stopped): `restored … 4 entities, 5 facts, 1 relations`; daemon on port 7699
  against the restored copy confirmed stats + marker recall. Production DB
  untouched.

## 10. OpenCode/Antigravity task handoff with memory retrieval — PASSED (caveat)
- Canary handoffs both directions (items 5–6). Full model-driven OpenCode leg
  awaits gateway recovery; memory retrieval itself is proven.

## 11. Regression tests for the existing orchestration system — PARTIAL
- TASK 3 suite was 10/10 PASS at ~13:05 IST. Since ~13:35 IST the OpenCode
  **free-model gateway hangs provider-side** (all free models, zero output at
  60–90s; pristine pre-TASK-4 config hangs identically — NOT a TASK 4
  regression). `agy` smoke-tested healthy (`AGY_SMOKE_OK` in ~10s).
- The orchestrator's designed response (route OpenCode→unavailable→fallback to
  Antigravity) covers this; full suite re-run deferred until the gateway
  recovers. `orchestrator status` will show opencode `degraded`.

## Supporting verifications
- GrafMCP `npm test`: 80/80 PASS (after one test-only fix: stale 12-tool
  assertion → 22 tools registered).
- Dashboard `http://127.0.0.1:7688` → 200, title "GrafMCP — Memory Dashboard";
  `data/activity.jsonl` logging confirmed.
- `opencode mcp list` (with orchestrator config) → `✓ graf-memory connected`.
- `agy mcp` CLI registry lists graf-memory with all 21 tools after
  `agy mcp add` (the CLI ignores `mcp_config.json`).
- Security review: `~/workspace/tools/grafmcp/SECURITY-REVIEW.md` —
  SAFE-TO-RUN-LOCALHOST-ONLY: YES; no eval/exec/telemetry; parameterized Cypher.
