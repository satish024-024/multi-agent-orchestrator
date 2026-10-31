#!/usr/bin/env bash
# Deterministic routing policy. Pure function: no side effects, no LLM.
# Usage: router.sh <complexity> <preferred_backend_or_empty> <oc_ready:yes|no> <ag_ready:yes|no> <qd_ready:yes|no>
# Prints JSON: {"backend":"opencode","model":"...","reason":"..."}
# Exit 0 = routed, exit 3 = no usable backend (blocked).
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CFG="$ROOT/config.json"

complexity="${1:-}" preferred="${2:-}" oc_ready="${3:-no}" ag_ready="${4:-no}" qd_ready="${5:-no}"

oc_model=$(jq -r '.opencode.default_model' "$CFG")
qd_model=$(jq -r '.qoder.default_model' "$CFG")
ag_model=$(jq -r '.antigravity.default_model' "$CFG")
ag_complex_model=$(jq -r '.antigravity.complex_model' "$CFG")
default_backend=$(jq -r '.routing.default_backend' "$CFG")

route() { # backend model reason
  jq -n --arg b "$1" --arg m "$2" --arg r "$3" \
    '{backend:$b, model:$m, reason:$r}'
  exit 0
}

blocked() {
  jq -n --arg r "$1" '{backend:"none", model:"", reason:$r}'
  exit 3
}

# Explicit backend override wins if that backend is ready.
if [ -n "$preferred" ]; then
  case "$preferred" in
    opencode)
      [ "$oc_ready" = yes ] && route opencode "$oc_model" "explicit --backend opencode"
      blocked "preferred backend opencode is not ready (unavailable or failed readiness check)" ;;
    antigravity)
      [ "$ag_ready" = yes ] && route antigravity "$ag_model" "explicit --backend antigravity"
      blocked "preferred backend antigravity is not ready (unavailable or failed readiness check)" ;;
    qoder)
      [ "$qd_ready" = yes ] && route qoder "$qd_model" "explicit --backend qoder"
      blocked "preferred backend qoder is not ready (unavailable or failed readiness check)" ;;
    *) blocked "unknown backend '$preferred' (expected opencode|antigravity|qoder)" ;;
  esac
fi

# Deterministic policy: routine -> Qoder (free models, verified working);
# complex -> Antigravity (stronger). OpenCode stays in the chain but its free
# inference is provider-degraded (2026-10-23), so it is last resort until its
# readiness smoke passes again. Antigravity is the standing fallback.
case "$complexity" in
  low|medium|"")
    [ "$qd_ready" = yes ] && route qoder "$qd_model" "routine task (complexity=${complexity:-unspecified}) -> Qoder default per policy"
    [ "$oc_ready" = yes ] && route opencode "$oc_model" "Qoder unavailable -> OpenCode fallback"
    [ "$ag_ready" = yes ] && route antigravity "$ag_model" "Qoder+OpenCode unavailable -> Antigravity fallback"
    blocked "no usable backend: qoder ready=$qd_ready opencode ready=$oc_ready antigravity ready=$ag_ready" ;;
  high)
    [ "$ag_ready" = yes ] && route antigravity "$ag_complex_model" "complex task -> Antigravity per policy"
    [ "$qd_ready" = yes ] && route qoder "$qd_model" "Antigravity unavailable -> Qoder fallback for complex task"
    [ "$oc_ready" = yes ] && route opencode "$oc_model" "Antigravity+Qoder unavailable -> OpenCode fallback for complex task (quality may be lower)"
    blocked "no usable backend: qoder ready=$qd_ready opencode ready=$oc_ready antigravity ready=$ag_ready" ;;
  *) blocked "unknown complexity '$complexity' (expected low|medium|high)" ;;
esac
