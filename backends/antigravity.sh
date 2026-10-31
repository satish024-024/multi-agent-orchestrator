#!/usr/bin/env bash
# Antigravity backend adapter — verified against agy 1.3.3 CLI.
# Uses ONLY flags confirmed by `agy --help` and live print-mode tests.
# Auth/config in ~/.gemini/ is NEVER modified here — inspect only.
set -uo pipefail

AGY_BIN="${AGY_BIN:-$HOME/.local/bin/agy}"

# ag_available -> prints version, exit 0 if the binary launches.
ag_available() {
  local v
  v=$("$AGY_BIN" --version 2>/dev/null | head -1 | tr -d ' \t\r\n') || return 1
  [ -n "$v" ] || return 1
  echo "$v"
}

# ag_auth_ready -> exit 0 if `agy models` returns at least one model (needs valid auth).
ag_auth_ready() {
  timeout 60 "$AGY_BIN" models 2>/dev/null | grep -qE '^[a-z0-9][a-z0-9._-]*[[:space:]]'
}

# ag_models -> one model id per line.
ag_models() {
  timeout 60 "$AGY_BIN" models 2>/dev/null | awk '{print $1}' | grep -E '^[a-z0-9._-]+$'
}

# ag_classify_error <logfile> -> rate_limit | auth | network | timeout | model_error | ok | unknown
ag_classify_error() {
  local log="$1"
  if grep -qiE '429|rate.?limit|too many requests|quota|resource.?exhausted' "$log" 2>/dev/null; then echo rate_limit; return; fi
  if grep -qiE '401|403|unauthori[sz]ed|invalid[_- ]grant|token expired|reauth|login required|OAuth' "$log" 2>/dev/null; then echo auth; return; fi
  if grep -qiE 'ECONNREFUSED|ENOTFOUND|ETIMEDOUT|network|socket hang up|fetch failed|getaddrinfo|dial tcp' "$log" 2>/dev/null; then echo network; return; fi
  if grep -qiE 'print-timeout|deadline exceeded|timed out' "$log" 2>/dev/null; then echo timeout; return; fi
  if grep -qE '"status":"(ERROR|FAILED)"' "$log" 2>/dev/null; then echo model_error; return; fi
  echo unknown
}

# Sanitize a logfile in place: redact secret-looking values.
# Deliberately does NOT touch usage telemetry (input_tokens/output_tokens/...).
_ag_sanitize() {
  local log="$1"
  sed -i -E \
    -e 's/\b(Bearer[[:space:]]+)[A-Za-z0-9._~+/=-]+/\1<redacted>/gi' \
    -e 's/\b((ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]+|sk-[A-Za-z0-9]+|xox[bap]-[A-Za-z0-9-]+|ya29\.[A-Za-z0-9._-]+|AIza[A-Za-z0-9._-]+)/<redacted>/g' \
    -e "s/(^|[^A-Za-z0-9_.-])((api[_-]?key|client[_-]?secret|(auth|access|refresh|id)[_-]?token|password|passwd|private[_-]?key)[\"']?[[:space:]]*[:=][[:space:]]*[\"']?)[^\"'[:space:];,]+/\1\2<redacted>/gi" \
    -e "s/(^|[^A-Za-z0-9_.-])(token[\"']?[[:space:]]*[:=][[:space:]]*[\"']?)[^\"'[:space:];,]+/\1\2<redacted>/gi" \
    "$log"
}

# Sanitize a logfile in place: redact anything that looks like a secret value.
ag_sanitize() { _ag_sanitize "$1"; }

# ag_run <workdir> <model> <effort> <timeout_s> <conversation_id_or_empty> <logfile>
# Prompt comes on stdin. Prints: conversation=<id> exit=<code> error=<class>
ag_run() {
  local workdir="$1" model="$2" effort="$3" timeout_s="$4" conv_id="$5" logfile="$6"
  local prompt code=0

  prompt=$(cat)
  # Guard against ARG_MAX (E2BIG): fail fast on oversized prompts.
  if [ "${#prompt}" -gt 102400 ]; then
    echo "FATAL: prompt too large (${#prompt} bytes > 102400)" >> "$logfile"
    echo "conversation=none exit=2 error=fatal"
    return 2
  fi
  : > "$logfile"
  (
    cd "$workdir" || { echo "FATAL: cannot cd to workdir: $workdir" >> "$logfile"; exit 2; }
    if [ -n "$conv_id" ]; then
      timeout "$timeout_s" "$AGY_BIN" --model "$model" --effort "$effort" \
        --output-format json --print-timeout "${timeout_s}s" \
        --conversation "$conv_id" --continue -p "$prompt" >> "$logfile" 2>> "$logfile"
    else
      timeout "$timeout_s" "$AGY_BIN" --model "$model" --effort "$effort" \
        --output-format json --print-timeout "${timeout_s}s" \
        -p "$prompt" >> "$logfile" 2>> "$logfile"
    fi
  ) || code=$?
  [ "$code" -eq 124 ] && echo "timeout marker: external timeout ${timeout_s}s exceeded" >> "$logfile"

  local cid
  cid=$(grep -oE '"conversation_id":"[^"]+"' "$logfile" | head -1 | cut -d'"' -f4)
  ag_sanitize "$logfile"

  local class="ok"
  [ "$code" -ne 0 ] && class=$(ag_classify_error "$logfile")
  [ "$code" -eq 124 ] && class="timeout"
  [ "$code" -eq 2 ] && class="fatal"
  echo "conversation=${cid:-none} exit=${code} error=${class}"
  return "$code"
}

# ag_smoke <workdir> <timeout_s> -> exit 0 if a trivial call succeeds.
ag_smoke() {
  local tmp
  tmp=$(mktemp)
  echo "Reply with exactly: AG_SMOKE_OK" | ag_run "$1" "gemini-3.8-flash-low" "low" "$2" "" "$tmp" >/dev/null 2>&1
  local code=$?
  if grep -q "AG_SMOKE_OK" "$tmp"; then rm -f "$tmp"; return 0; fi
  rm -f "$tmp"; return "$code"
}
