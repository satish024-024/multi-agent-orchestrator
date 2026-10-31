#!/usr/bin/env bash
# Phase 7 staged test suite for the orchestrator.
# ALL tests run in disposable dirs under /tmp — never in real projects.
# Usage: tests/run.sh ; results appended to tests/results-<date>.md
set -uo pipefail

ORCH="$HOME/workspace/orchestrator/orchestrator"
TS=$(date +%Y%m%d-%H%M%S)
WORK="/tmp/orch-tests-$TS"
RESULT="$HOME/workspace/orchestrator/tests/results-$TS.md"
mkdir -p "$WORK"

pass=0; fail=0; untested=0
note() { echo "$*" | tee -a "$RESULT"; }
verdict() { # name status evidence
  case "$2" in
    PASS) pass=$((pass+1));; FAIL) fail=$((fail+1));; UNTESTED) untested=$((untested+1));; esac
  note ""; note "## $1 — **$2**"; note "$3"
}

note "# Orchestrator test results — $TS"
note "orchestrator: $ORCH"

# ---------- T1: installation ----------
note ""; note "### T1 commands"
V_OC=$($HOME/.opencode/bin/opencode --version 2>&1 | head -1)
V_AGY=$HOME/.local/bin/agy; V_AGY=$($V_AGY --version 2>&1 | head -1)
note "opencode --version => $V_OC"; note "agy --version => $V_AGY"
if [[ "$V_OC" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && "$V_AGY" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  verdict "T1 installation" PASS "opencode=$V_OC agy=$V_AGY (both launch, valid semver)"
else verdict "T1 installation" FAIL "version output unexpected"; fi

# ---------- T2: readiness ----------
ST=$($ORCH status 2>&1)
note ""; note '```'; note "$ST"; note '```'
if grep -q "opencode.*readiness=yes" <<<"$ST" && grep -q "antigravity.*readiness=yes" <<<"$ST"; then
  verdict "T2 readiness" PASS "both backends readiness=yes via smoke tests"
else verdict "T2 readiness" FAIL "status output above"; fi

# ---------- T3: OpenCode basic coding task ----------
R3="$WORK/t3"; mkdir -p "$R3"; cd "$R3" && git init -q && git config user.email t@t && git config user.name t
cat > calc.py <<'EOF'
def add(a, b):
    return a + b
EOF
cat > test_calc.py <<'EOF'
from calc import add
def test_add():
    assert add(2, 3) == 5
EOF
git add -A && git commit -qm init
T3_OUT=$($ORCH run "Add a multiply(a, b) function to calc.py and a test_multiply test in test_calc.py, then run pytest to confirm all tests pass. Keep changes minimal." \
  --backend opencode --complexity low --dir "$R3" --timeout 420 2>&1 | tail -5)
T3_ID=$(grep -oE 't-[0-9]+-[0-9]+' <<<"$T3_OUT" | head -1)
T3_STATUS=$(jq -r .status "$HOME/workspace/orchestrator/tasks/$T3_ID.json" 2>/dev/null)
PYTEST=$(cd "$R3" && python3 -c "
from calc import multiply
assert multiply(2, 3) == 6 and multiply(-1, 5) == -5
import test_calc
test_calc.test_add(); test_calc.test_multiply()
print('ALL CHECKS PASSED')" 2>&1 | tail -2)
note "T3 task=$T3_ID status=$T3_STATUS"; note "pytest after: $PYTEST"
if grep -q "def multiply" "$R3/calc.py" 2>/dev/null && grep -q "ALL CHECKS PASSED" <<<"$PYTEST"; then
  verdict "T3 opencode coding task" PASS "multiply() added, checks pass: $PYTEST (task $T3_ID)"
else verdict "T3 opencode coding task" FAIL "status=$T3_STATUS pytest: $PYTEST (task $T3_ID, see logs)"; fi

# ---------- T4: Antigravity coding task ----------
R4="$WORK/t4"; mkdir -p "$R4"; cd "$R4" && git init -q && git config user.email t@t && git config user.name t
cat > calc.py <<'EOF'
def add(a, b):
    return a + b
EOF
cat > test_calc.py <<'EOF'
from calc import add
def test_add():
    assert add(2, 3) == 5
EOF
git add -A && git commit -qm init
T4_OUT=$($ORCH run "Add a subtract(a, b) function to calc.py and a test_subtract test in test_calc.py, then run pytest to confirm all tests pass. Keep changes minimal." \
  --backend antigravity --complexity low --dir "$R4" --timeout 600 2>&1 | tail -5)
T4_ID=$(grep -oE 't-[0-9]+-[0-9]+' <<<"$T4_OUT" | head -1)
T4_STATUS=$(jq -r .status "$HOME/workspace/orchestrator/tasks/$T4_ID.json" 2>/dev/null)
PYTEST4=$(cd "$R4" && python3 -c "
from calc import subtract
assert subtract(5, 3) == 2 and subtract(0, 4) == -4
import test_calc
test_calc.test_add(); test_calc.test_subtract()
print('ALL CHECKS PASSED')" 2>&1 | tail -2)
note "T4 task=$T4_ID status=$T4_STATUS"; note "pytest after: $PYTEST4"
if grep -q "def subtract" "$R4/calc.py" 2>/dev/null && grep -q "ALL CHECKS PASSED" <<<"$PYTEST4"; then
  verdict "T4 antigravity coding task" PASS "subtract() added, checks pass: $PYTEST4 (task $T4_ID)"
else verdict "T4 antigravity coding task" FAIL "status=$T4_STATUS pytest: $PYTEST4 (task $T4_ID)"; fi

# ---------- T5: routing policy ----------
P_LOW=$($ORCH plan "fix a typo in README" --complexity low 2>&1)
P_HIGH=$($ORCH plan "redesign the multi-module authentication architecture" --complexity high 2>&1)
B_LOW=$(grep -oE 'routing    : [a-z]+' <<<"$P_LOW" | awk '{print $3}')
B_HIGH=$(grep -oE 'routing    : [a-z]+' <<<"$P_HIGH" | awk '{print $3}')
note "plan low => $B_LOW"; note "plan high => $B_HIGH"
if [ "$B_LOW" = "opencode" ] && [ "$B_HIGH" = "antigravity" ]; then
  verdict "T5 routing" PASS "low->$B_LOW, high->$B_HIGH per policy"
else verdict "T5 routing" FAIL "low->$B_LOW high->$B_HIGH"; fi

# ---------- T6: fallback when opencode unavailable ----------
R6=$("$HOME/workspace/orchestrator/router.sh" low "" no yes 2>/dev/null)
B6=$(jq -r .backend <<<"$R6")
R6B=$("$HOME/workspace/orchestrator/router.sh" high "" yes no 2>/dev/null)
B6B=$(jq -r .backend <<<"$R6B")
R6C=$("$HOME/workspace/orchestrator/router.sh" low "" no no 2>&1); C6C=$?
note "oc down, low => $B6"; note "ag down, high => $B6B"; note "both down exit=$C6C"
if [ "$B6" = "antigravity" ] && [ "$B6B" = "opencode" ] && [ "$C6C" -eq 3 ]; then
  verdict "T6 fallback" PASS "unavailable backend -> other backend; both down -> blocked (exit 3, task preserved)"
else verdict "T6 fallback" FAIL "got $B6 / $B6B / exit $C6C"; fi

# ---------- T7: failure handling ----------
R7="$WORK/t7"; mkdir -p "$R7"; cd "$R7" && git init -q && git config user.email t@t && git config user.name t && git commit -qm init --allow-empty
# 7a: bogus model -> error classification, repo untouched
T7A_OUT=$(OC_MODEL_BAD=1 bash -c 'source "$0/backends/opencode.sh"; echo hi | oc_run "$1" "opencode/no-such-model-xyz" 60 "" "$2"' "$HOME/workspace/orchestrator" "$R7" /tmp/t7a.log 2>&1 | tail -2)
T7A_CLASS=$(grep -oE 'error=[a-z_]+' <<<"$T7A_OUT" | cut -d= -f2)
GIT7A=$(cd "$R7" && git status --porcelain | wc -l)
note "bogus model => class=$T7A_CLASS, repo dirty files=$GIT7A"
# 7b: tiny timeout -> timeout class
T7B_OUT=$(bash -c 'source "$0/backends/opencode.sh"; echo "say TIMEOUT_PROBE" | oc_run "$1" "opencode/deepseek-v4.1-flash-free" 8 "" "$2"' "$HOME/workspace/orchestrator" "$R7" /tmp/t7b.log 2>&1 | tail -2)
T7B_CLASS=$(grep -oE 'error=[a-z_]+' <<<"$T7B_OUT" | cut -d= -f2)
note "8s timeout => class=$T7B_CLASS"
# 7c: malformed output -> unknown
echo "garbage {{{ not json" > /tmp/t7c.log
T7C_CLASS=$(bash -c 'source "$0/backends/opencode.sh"; oc_classify_error "$1"' "$HOME/workspace/orchestrator" /tmp/t7c.log)
note "malformed log => class=$T7C_CLASS"
if [ "$T7A_CLASS" = "model_error" ] && [ "$T7B_CLASS" = "timeout" ] && [ "$T7C_CLASS" = "unknown" ] && [ "$GIT7A" = "0" ]; then
  verdict "T7 failure handling" PASS "bogus model->model_error, 8s timeout->timeout, malformed->unknown, repo uncorrupted"
else verdict "T7 failure handling" FAIL "classes: $T7A_CLASS / $T7B_CLASS / $T7C_CLASS, dirty=$GIT7A"; fi

# ---------- T8: context recovery ----------
# interrupt: run with impossibly small timeout -> fails, then resume
R8="$WORK/t8"; mkdir -p "$R8"; cd "$R8" && git init -q && git config user.email t@t && git config user.name t
echo "x = 1" > app.py && git add -A && git commit -qm init
T8_OUT=$($ORCH run "Add a function double(n) returning 2*n to app.py" --backend opencode --dir "$R8" --timeout 8 2>&1 | tail -3)
T8_ID=$(grep -oE 't-[0-9]+-[0-9]+' <<<"$T8_OUT" | head -1)
T8_S1=$(jq -r .status "$HOME/workspace/orchestrator/tasks/$T8_ID.json" 2>/dev/null)
T8_SESS=$(jq -r .session_id "$HOME/workspace/orchestrator/tasks/$T8_ID.json" 2>/dev/null)
T8_HANDOFF=$([ -f "$HOME/workspace/orchestrator/tasks/$T8_ID.md" ] && echo yes || echo no)
R8_OUT=$($ORCH resume "$T8_ID" --timeout 420 2>&1 | tail -3)
T8_S2=$(jq -r .status "$HOME/workspace/orchestrator/tasks/$T8_ID.json" 2>/dev/null)
R8_OK=$(grep -q "def double" "$R8/app.py" 2>/dev/null && echo yes || echo no)
note "interrupt: status=$T8_S1 session_recorded=$([ -n "$T8_SESS" ] && [ "$T8_SESS" != "none" ] && echo yes || echo no) handoff=$T8_HANDOFF"
note "resume: status=$T8_S2 double_present=$R8_OK"
if [ "$T8_S1" = "failed" ] && [ "$T8_HANDOFF" = "yes" ] && [ "$T8_S2" = "done" ] && [ "$R8_OK" = "yes" ]; then
  verdict "T8 context recovery" PASS "interrupted task failed cleanly, handoff note written, resume completed the work"
else verdict "T8 context recovery" FAIL "s1=$T8_S1 s2=$T8_S2 handoff=$T8_HANDOFF double=$R8_OK (task $T8_ID)"; fi

# ---------- T9: concurrency isolation ----------
R9="$WORK/t9"; mkdir -p "$R9"; cd "$R9" && git init -q && git config user.email t@t && git config user.name t
echo "base" > base.txt && git add -A && git commit -qm init && git branch -M main
$ORCH run "Create file alpha.txt containing the word ALPHA" --backend opencode --dir "$R9" --worktree task-alpha --timeout 420 >/tmp/t9a.out 2>&1 &
PIDA=$!
$ORCH run "Create file beta.txt containing the word BETA" --backend opencode --dir "$R9" --worktree task-beta --timeout 420 >/tmp/t9b.out 2>&1 &
PIDB=$!
wait $PIDA; CA=$?; wait $PIDB; CB=$?
A_FILE=$(git -C "$R9" worktree list --porcelain | grep -c task-alpha || true)
MAIN_CLEAN=$(cd "$R9" && git status --porcelain | wc -l)
A_OK=$(find /tmp -path '*task-alpha*' -name alpha.txt 2>/dev/null | head -1)
B_OK=$(find /tmp -path '*task-beta*' -name beta.txt 2>/dev/null | head -1)
note "parallel runs exit=$CA/$CB worktrees listed=$A_FILE main dirty files=$MAIN_CLEAN"
if [ -n "$A_OK" ] && [ -n "$B_OK" ] && [ "$MAIN_CLEAN" = "0" ]; then
  verdict "T9 concurrency" PASS "two parallel worktree runs isolated; main branch untouched"
else verdict "T9 concurrency" FAIL "alpha=$A_OK beta=$B_OK main_dirty=$MAIN_CLEAN"; fi
git -C "$R9" worktree remove --force task-alpha 2>/dev/null; git -C "$R9" worktree remove --force task-beta 2>/dev/null; git -C "$R9" worktree prune

# ---------- T10: regression (existing agy workflows untouched) ----------
export PATH="$HOME/.local/bin:$PATH"
RG1=$(timeout 120 agy --model gemini-3.8-flash-low --effort low --print-timeout 90s -p "Reply with exactly: REG_OK" 2>&1 | tail -1)
RG2=$(agy remote-control status 2>&1 | grep -oE 'active|inactive' | head -1)
RG3=$(agy models 2>&1 | grep -cE 'gemini|claude|gpt')
note "delegate-pattern run => $(grep -o REG_OK <<<"$RG1" || echo MISSING)"
note "keepalive daemon => $RG2 ; models listed => $RG3"
if grep -q REG_OK <<<"$RG1" && [ "$RG2" = "active" ] && [ "$RG3" -ge 3 ]; then
  verdict "T10 regression" PASS "delegate-to-agy pattern works, keepalive daemon active, agy models intact"
else verdict "T10 regression" FAIL "see notes above"; fi

note ""; note "== Summary: PASS=$pass FAIL=$fail UNTESTED=$untested =="
echo "RESULTS: $RESULT (PASS=$pass FAIL=$fail UNTESTED=$untested)"
