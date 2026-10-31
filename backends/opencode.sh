#!/usr/bin/env bash
# OpenCode backend adapter — verified against opencode v2.1.3 CLI
# (upgraded from 1.19.2 on 2026-10-23; v2 changes absorbed here:
#  - `run` lost --dir -> the adapter cds into the workdir instead
#  - `run --standalone` gives a private server per invocation (v1-like isolation)
#  - `providers list` is now `auth list`
#  - MCP config moved under mcp.servers (see opencode-safe.json migration)
#  - OPENCODE_CONFIG env is NOT honored by v2.1.3 config loading (verified:
#    debug config sources list only global + project files). The safe settings
#    therefore live in the global config ~/.config/opencode/opencode.jsonc
#    (merged 2026-10-23, backup .bak-20261023-v2mig); opencode-safe.json is
#    kept as the human-readable source of those settings.
# Never reads ~/.local/share/opencode/auth.json (credential store).
set -uo pipefail

OC_BIN="${OC_BIN:-$HOME/.opencode/bin/opencode}"
OC_CONFIG="${OC_CONFIG:-$HOME/workspace/orchestrator/opencode-safe.json}"

# oc_available -> prints version on stdout, exit 0 if the binary launches.
oc_available() {
  local v
  v=$("$OC_BIN" --version 2>/dev/null | head -1 | tr -d ' \t\r\n') || return 1
  [ -n "$v" ] || return 1
  echo "$v"
}

# oc_credential_count -> number of stored credentials (does NOT read values).
oc_credential_count() {
  "$OC_BIN" auth list 2>/dev/null \
    | grep -oiE '[0-9]+ credential|[0-9]+ integration' | grep -oE '[0-9]+' | head -1
}
# oc_models -> one model id per line (provider-qualified).
oc_models() {
  OPENCODE_CONFIG="$OC_CONFIG" "$OC_BIN" models 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g' | grep -E '^opencode/' | tr -d '\r'
}

# oc_classify_error <logfile> -> rate_limit | auth | network | timeout | model_error | ok | unknown
oc_classify_error() {
  local log="$1"
  if grep -qiE '429|rate.?limit|too many requests|quota exceeded' "$log" 2>/dev/null; then echo rate_limit; return; fi
  if grep -qiE '401|403|unauthori[sz]ed|invalid api key|authentication|forbidden|permission denied.*api' "$log" 2>/dev/null; then echo auth; return; fi
  if grep -qiE 'ECONNREFUSED|ENOTFOUND|ETIMEDOUT|network|socket hang up|fetch failed|getaddrinfo' "$log" 2>/dev/null; then echo network; return; fi
  if grep -qiE 'timeout|timed out|deadline exceeded' "$log" 2>/dev/null; then echo timeout; return; fi
  if grep -qiE '"type":"error"|"error"' "$log" 2>/dev/null; then echo model_error; return; fi
  echo unknown
}

# Sanitize a logfile in place: redact secret-looking values.
# Deliberately does NOT touch usage telemetry (input_tokens/output_tokens/...).
_oc_sanitize() {
  local log="$1" q="\""
  sed -i -E \
    -e 's/\b(Bearer[[:space:]]+)[A-Za-z0-9._~+/=-]+/\1<redacted>/gi' \
    -e 's/\b((ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]+|sk-[A-Za-z0-9]+|xox[bap]-[A-Za-z0-9-]+|ya29\.[A-Za-z0-9._-]+|AIza[A-Za-z0-9._-]+)/<redacted>/g' \
    -e "s/(^|[^A-Za-z0-9_.-])((api[_-]?key|client[_-]?secret|(auth|access|refresh|id)[_-]?token|password|passwd|private[_-]?key)[\"']?[[:space:]]*[:=][[:space:]]*[\"']?)[^\"'[:space:];,]+/\1\2<redacted>/gi" \
    -e "s/(^|[^A-Za-z0-9_.-])(token[\"']?[[:space:]]*[:=][[:space:]]*[\"']?)[^\"'[:space:];,]+/\1\2<redacted>/gi" \
    "$log"
}

# Sanitize a logfile in place: redact anything that looks like a secret value.
oc_sanitize() { _oc_sanitize "$1"; }

# oc_run <workdir> <model> <timeout_s> <session_id_or_empty> <logfile>
# Prompt comes on stdin. Prints: session=<id> exit=<code> error=<class>
oc_run() {
  local workdir="$1" model="$2" timeout_s="$3" session_id="$4" logfile="$5"
  local prompt args=() code=0

  prompt=$(cat)
  # Guard against ARG_MAX (E2BIG): fail fast on oversized prompts.
  if [ "${#prompt}" -gt 102400 ]; then
    echo "FATAL: prompt too large (${#prompt} bytes > 102400)" >> "$logfile"
    echo "session=none exit=2 error=fatal"
    return 2
  fi
  args=(run --standalone -m "$model" --format json)
  [ -n "$session_id" ] && args+=(--fork -s "$session_id")

  : > "$logfile"
  (
    cd "$workdir" || { echo "FATAL: cannot cd to workdir: $workdir" >> "$logfile"; exit 2; }
    timeout "$timeout_s" "$OC_BIN" "${args[@]}" "$prompt" \
      >> "$logfile" 2>> "$logfile"
  ) || code=$?
  # timeout(1) exit 124 = our timeout
  if [ "$code" -eq 124 ]; then
    echo "timeout marker: external timeout ${timeout_s}s exceeded" >> "$logfile"
  fi

  local sid
  sid=$(grep -oE '"sessionID":"[^"]+"' "$logfile" | head -1 | cut -d'"' -f4)
  oc_sanitize "$logfile"

  local class="ok"
  [ "$code" -ne 0 ] && class=$(oc_classify_error "$logfile")
  [ "$code" -eq 124 ] && class="timeout"
  [ "$code" -eq 2 ] && class="fatal"
  echo "session=${sid:-none} exit=${code} error=${class}"
  return "$code"
}

# oc_smoke <workdir> <model> <timeout_s> -> exit 0 if a trivial call succeeds.
oc_smoke() {
  local tmp
  tmp=$(mktemp)
  echo "Reply with exactly: OC_SMOKE_OK" | oc_run "$1" "$2" "$3" "" "$tmp" >/dev/null 2>&1
  local code=$?
  if grep -q "OC_SMOKE_OK" "$tmp"; then rm -f "$tmp"; return 0; fi
  rm -f "$tmp"; return "$code"
}
