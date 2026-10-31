#!/usr/bin/env bash
# Qoder backend adapter — verified against qodercli 1.1.77.
# QD_BIN is the shim wrapper (~/workspace/tools/qoder-shim/qoder): this VM's
# idmapped overlay fs denies the lchown() Qoder's auth store performs at
# startup; the wrapper preloads a no-op chown shim (ownership already correct).
# Credentials live in ~/.qoder/.auth — never read or logged here.
set -uo pipefail

QD_BIN="${QD_BIN:-$HOME/workspace/tools/qoder-shim/qoder}"

# qd_available -> prints version on stdout, exit 0 if the binary launches.
qd_available() {
  local v
  v=$("$QD_BIN" --version 2>/dev/null | head -1 | tr -d ' \t\r\n') || return 1
  [ -n "$v" ] || return 1
  echo "$v"
}

# qd_auth_ready -> exit 0 if --list-models returns models (requires login).
qd_auth_ready() {
  local out
  out=$(timeout 60 "$QD_BIN" --list-models 2>&1) || return 1
  grep -qi "not logged in" <<<"$out" && return 1
  grep -qE '\S' <<<"$out"
}

# qd_models -> one model id per line, as reported by the CLI for this user.
qd_models() {
  timeout 60 "$QD_BIN" --list-models 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g' | grep -E '\S' | tr -d '\r'
}

# qd_classify_error <logfile> -> rate_limit | auth | network | timeout | model_error | ok | unknown
qd_classify_error() {
  local log="$1"
  if grep -qiE '429|rate.?limit|too many requests|quota exceeded|free.*(limit|quota)|credits? (exhausted|used up)' "$log" 2>/dev/null; then echo rate_limit; return; fi
  if grep -qiE '401|403|unauthori[sz]ed|invalid api key|authentication|not logged in|login required|session expired' "$log" 2>/dev/null; then echo auth; return; fi
  if grep -qiE 'ECONNREFUSED|ENOTFOUND|ETIMEDOUT|network|socket hang up|fetch failed|getaddrinfo' "$log" 2>/dev/null; then echo network; return; fi
  if grep -qiE 'timeout|timed out|deadline exceeded' "$log" 2>/dev/null; then echo timeout; return; fi
  if grep -qiE '"type":"error"|"error"|error:' "$log" 2>/dev/null; then echo model_error; return; fi
  echo unknown
}

# Sanitize a logfile in place: redact secret-looking values (same rules as the
# other adapters; usage telemetry is deliberately left untouched).
_qd_sanitize() {
  local log="$1" q="\""
  sed -i -E \
    -e 's/\b(Bearer[[:space:]]+)[A-Za-z0-9._~+/=-]+/\1<redacted>/gi' \
    -e 's/\b((ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]+|sk-[A-Za-z0-9]+|xox[bap]-[A-Za-z0-9-]+|ya29\.[A-Za-z0-9._-]+|AIza[A-Za-z0-9._-]+)/<redacted>/g' \
    -e "s/(^|[^A-Za-z0-9_.-])((api[_-]?key|client[_-]?secret|(auth|access|refresh|id)[_-]?token|password|passwd|private[_-]?key)[\"']?[[:space:]]*[:=][[:space:]]*[\"']?)[^\"'[:space:];,]+/\1\2<redacted>/gi" \
    -e "s/(^|[^A-Za-z0-9_.-])(token[\"']?[[:space:]]*[:=][[:space:]]*[\"']?)[^\"'[:space:];,]+/\1\2<redacted>/gi" \
    "$log"
}

qd_sanitize() { _qd_sanitize "$1"; }

# qd_run <workdir> <model> <timeout_s> <session_id_or_empty> <logfile>
# Prompt comes on stdin. Prints: session=<id> exit=<code> error=<class>
# Print mode + accept_edits: non-interactive task execution inside the given
# workdir (orchestrator supplies worktrees/disposable dirs per its policy).
qd_run() {
  local workdir="$1" model="$2" timeout_s="$3" session_id="$4" logfile="$5"
  local prompt args=() code=0

  prompt=$(cat)
  if [ "${#prompt}" -gt 102400 ]; then
    echo "FATAL: prompt too large (${#prompt} bytes > 102400)" >> "$logfile"
    echo "session=none exit=2 error=fatal"
    return 2
  fi
  args=(-p "$prompt" -w "$workdir" --permission-mode accept_edits)
  # GrafMCP is our own trusted server: allow the server and its tools, else
  # Qoder's per-tool permission gate blocks MCP calls in non-interactive mode
  # (verified 2026-10-23: without these flags remember/recall are denied).
  args+=(--allowed-mcp-server-names graf-memory
         --allowed-tools "mcp__graf-memory__remember"
         --allowed-tools "mcp__graf-memory__recall"
         --allowed-tools "mcp__graf-memory__*")
  [ -n "$model" ] && args+=(-m "$model")
  [ -n "$session_id" ] && args+=(--session-id "$session_id")

  : > "$logfile"
  timeout "$timeout_s" "$QD_BIN" "${args[@]}" >> "$logfile" 2>> "$logfile" || code=$?
  if [ "$code" -eq 124 ]; then
    echo "timeout marker: external timeout ${timeout_s}s exceeded" >> "$logfile"
  fi

  qd_sanitize "$logfile"

  local class="ok"
  [ "$code" -ne 0 ] && class=$(qd_classify_error "$logfile")
  [ "$code" -eq 124 ] && class="timeout"
  [ "$code" -eq 2 ] && class="fatal"
  echo "session=${session_id:-none} exit=${code} error=${class}"
  return "$code"
}

# qd_smoke <workdir> <model> <timeout_s> -> exit 0 if a trivial call succeeds.
qd_smoke() {
  local tmp
  tmp=$(mktemp)
  echo "Reply with exactly: QD_SMOKE_OK" | qd_run "$1" "$2" "$3" "" "$tmp" >/dev/null 2>&1
  local code=$?
  if grep -q "QD_SMOKE_OK" "$tmp"; then rm -f "$tmp"; return 0; fi
  rm -f "$tmp"; return "$code"
}
