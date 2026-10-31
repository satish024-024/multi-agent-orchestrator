# Multi-Agent Orchestrator

**One coordinator. Three AI coding backends. Structured briefs, deterministic routing, verification gates, and a shared memory — so agent work is delegated like a team, not sprayed like a prompt.**

Built and operated by **Kadali Satish Kumar** — [portfolio](https://satishkumarkadali.vercel.app/) · [LinkedIn](https://www.linkedin.com/in/kadalisatishkumar)

---

## Why this exists

A single AI coding agent is a single point of failure: model caps, rate limits, auth expiries, and bad days. This system treats AI coding CLIs as **execution backends** behind one stable interface, the way a Forward Deployed Engineer treats any flaky vendor API:

- Work is delegated with a **structured brief** — Objective / Files owned / Constraints / Done when / Verify command
- A **deterministic router** picks the backend by task complexity and live readiness
- Failures are **classified** (rate-limit, auth, timeout, model error, network) and routed around with **bounded retries and one fallback**
- Nothing is "done" until it passes a **verification gate** — a worker's claim is never proof
- All backends share one **graph memory** (GrafMCP), so context survives across tools and sessions

## Backends

| Backend | CLI | Role in the system |
|---|---|---|
| **Qoder** | `qoder` | Default for routine work (free DeepSeek-Flash / Qwen models) |
| **Antigravity** | `agy` | Complex work + standing fallback (Gemini Flash default, Claude Opus for high complexity) |
| **OpenCode** | `opencode` | Third backend (v2.1.3; free model pool, e.g. `nemotron-3-ultra-free`) |

Each backend is a small bash adapter with the same contract: `available / models / classify_error / sanitize / run / smoke`. Backend binary paths are environment-overridable (`AGY_BIN`, `OC_BIN`, `QD_BIN`).

## How it works

```
                 ┌─────────────────────────────┐
   task brief ──▶│  orchestrator (coordinator) │──▶ status / plan / run / logs / resume
                 └──────────────┬──────────────┘
                                │  router.sh — deterministic policy
              ┌─────────────────┼─────────────────┐
              ▼                 ▼                 ▼
          backends/         backends/         backends/
          qoder.sh          antigravity.sh    opencode.sh
              │                 │                 │
              └─────────────────┼─────────────────┘
                                ▼
                  shared graph memory (GrafMCP, MCP)
              tasks/ state · logs/ (sanitized) · worktree isolation
```

- **Routing policy** (`config.json`): low/medium complexity → Qoder, high → Antigravity; fallback chain Qoder → Antigravity → OpenCode; max 2 retries per backend with backoff; explicit `--backend` overrides **fail closed** (no silent rerouting).
- **Failure classification**: backends classify stderr/exit codes into `rate_limit | auth | timeout | model_error | network`; only classified-transient failures fall back. If everything is down, the task state is **preserved as blocked** — never lost, never faked.
- **Safety model**: destructive commands are denied by the OpenCode permission config (`rm -rf`, `sudo`, `git push`, `pip install`, …); push / deploy / publish / spend / production migration require human approval; logs are **sanitized in place** (secret-looking values redacted) before anything is written to disk.
- **Isolation**: optional git-worktree per task, so parallel agents never edit the same files.

## Quickstart

Prerequisites: bash, git, jq, and at least one backend CLI installed and signed in (Qoder, Antigravity, or OpenCode).

```bash
git clone <this-repo> orchestrator && cd orchestrator
cp config.example.json config.json   # adjust binary paths + models to your installs
chmod +x orchestrator router.sh backends/*.sh

./orchestrator status                                   # backend readiness at a glance
./orchestrator plan "Fix the login redirect" low        # see routing without running
./orchestrator run  "Fix the login redirect" --dir /path/to/repo --timeout 600
./orchestrator logs <task-id>
./orchestrator resume <task-id>                         # continue with prior context
```

## Shared memory (optional but recommended)

All backends can attach to the same [GrafMCP](https://github.com/SecCodeSmith/GrafMCP) graph-memory server over MCP, namespaced per project. Workflow: **recall before starting, remember durable learnings after, query the code graph before proposing changes.** Design: [`docs/MEMORY-ARCHITECTURE.md`](docs/MEMORY-ARCHITECTURE.md). If you skip GrafMCP, the orchestrator still routes and runs fine — it just forgets between sessions.

## Evidence

- Full design + operating manual: [`docs/ORCHESTRATION.md`](docs/ORCHESTRATION.md)
- Test suite: [`tests/run.sh`](tests/run.sh) — staged suite on disposable repos covering installation, readiness, real coding tasks on multiple backends, routing, fallback, failure classification, interrupt/resume, and worktree isolation
- Latest full run: **10/10 PASS** (2026-10-16) — raw evidence in [`tests/results-20261016-070425.md`](tests/results-20261016-070425.md); memory tests in [`tests/memory-results-20261016.md`](tests/memory-results-20261016.md)
- Live status is always one command away: `./orchestrator status` (free-tier model caps come and go; the router's job is to route around them)

## Repository layout

```
orchestrator          # the CLI (bash, stdlib + jq only)
router.sh             # deterministic routing policy
backends/             # one adapter per backend CLI
config.example.json   # copy to config.json; models, timeouts, safety gates
opencode-safe.json    # deny-by-default permission profile for OpenCode
docs/                 # ORCHESTRATION.md (manual) · MEMORY-ARCHITECTURE.md
tests/                # run.sh + dated, signed-off result files
```

## License

MIT — see [LICENSE](LICENSE).

---

*This is a working system, not a demo: it runs a real multi-agent engineering workflow daily — delegation, review, and verification included. The coordinator is human; the discipline is in the briefs and the gates.*
