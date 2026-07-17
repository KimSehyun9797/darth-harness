#!/usr/bin/env bash
# 워커 1개 기동 (결정 20·31·32·34). 프로젝트 루트에서 실행.
# 사용법: dispatch.sh <태스크ID> [브리프경로]
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/lib.sh
. "$SCRIPT_DIR/lib.sh"
need_yq
P="$(pwd)"
ID="${1:?사용법: dispatch.sh <태스크ID> [브리프경로]}"
printf '%s' "$ID" | grep -Eq '^[A-Za-z0-9._-]+$' \
  || die "안전하지 않은 task id: $ID"
TASKS="$P/tasks.yaml"
[ -f "$TASKS" ] || die "tasks.yaml 없음 — 프로젝트 루트에서 실행하세요"
validate_execution_contract "$TASKS" || die "실행 계약 위반 — 기동 거부"
CONTEXT_VERSION="$(yq -r '.context_contract_version // ""' "$TASKS")"

# 게이트 1: 스캐폴딩 (결정 32)
[ -f "$P/log/scaffold-check.pass" ] \
  || die "scaffold-check 미통과 — scripts/scaffold-check.sh 를 먼저 통과시키세요"

# 게이트 1.5: worker-wrap (B-001) — 실행 사건 기록 없이는 기동하지 않는다
WRAP_BIN="$P/.harness/bin/worker-wrap"
[ -x "$WRAP_BIN" ] || die "worker-wrap 없음 — scripts/migrate-b001.sh로 프로젝트를 갱신하세요"

# 게이트 2: 태스크 존재
q() { task_value "$TASKS" "$ID" "$1"; }
NAME="$(q .name)"
{ [ -n "$NAME" ] && [ "$NAME" != null ]; } || die "태스크 '$ID' 가 tasks.yaml에 없음"
ROLE="$(q .role)"
BRIEF="${2:-$(q .brief)}"
WORKDIR="$(q '.worktree // "."')"
[ -f "$P/$BRIEF" ] || die "브리프 없음: $BRIEF"
CONTRACT_VERSION="$(yq -r '.contract_version // ""' "$TASKS")"
if [ "$CONTRACT_VERSION" = 2 ] || [ "$CONTRACT_VERSION" = 3 ]; then
  EXECUTION="$(q '.execution // ""')"
  [ "$EXECUTION" = worker ] || die "v$CONTRACT_VERSION deterministic 작업은 모델 워커로 기동할 수 없음"
  GRADE="$(q '.grade // ""')"
  TASK_EFFORT="$(q '.effort // ""')"
  MAX_CONCURRENT_WORKERS="$(yq -r '.execution_policy.max_concurrent_workers' "$TASKS")"
  RUNNING_COUNT="$(TASK_ID="$ID" yq -r \
    '.tasks[] | select(.id != strenv(TASK_ID) and .status == "running") | .id' "$TASKS" \
    | wc -l | tr -d ' ')"
  [ "$RUNNING_COUNT" -lt "$MAX_CONCURRENT_WORKERS" ] \
    || die "v$CONTRACT_VERSION 동시 실행 상한($MAX_CONCURRENT_WORKERS) 도달 — 다른 running 작업: $RUNNING_COUNT"
fi
STATE_LIB="$P/.harness/lib/state.sh"
[ -f "$STATE_LIB" ] || die "프로젝트 state.sh 없음: $STATE_LIB"
bash -c '. "$1"; validate_state working' _ "$STATE_LIB" \
  || die "프로젝트 상태 계약 위반 — dependency 검증 전에 상태를 복구하세요"

# 게이트 3: 브리프 완료 신호 (6.5 승격 예시)
grep -q "완료 신호" "$P/$BRIEF" || die "브리프에 '완료 신호' 정의 없음 — 기동 거부"

# 게이트 4: 의존 전부 verified (결정 34 + B-001: .done 불변, 검증 기록 분리)
for dep in $(yq -r ".tasks[] | select(.id == \"$ID\") | .depends_on[]?" "$TASKS"); do
  df="$P/log/$dep.done"; vf="$P/log/$dep.verified.yaml"
  dep_status="$(TASK_ID="$dep" yq -r '.tasks[] | select(.id == strenv(TASK_ID)) | .status // ""' "$TASKS")"
  [ "$dep_status" = verified ] || die "의존 '$dep' status가 verified 아님 — 기동 거부"
  [ -f "$df" ] || die "의존 '$dep' 미완료(.done 없음) — 기동 거부"
  [ "$(yq -r '.status // ""' "$df")" = DONE ] \
    || die "의존 '$dep' .done이 DONE 아님 — 기동 거부 (결정 16)"
  [ -f "$vf" ] || die "의존 '$dep' 검증 기록(.verified.yaml) 없음 — 기동 거부 (결정 16)"
  dep_run="$(yq -r '.run_id // ""' "$df")"; v_run="$(yq -r '.run_id // ""' "$vf")"
  { [ -n "$dep_run" ] && [ "$dep_run" = "$v_run" ]; } \
    || die "의존 '$dep' .done과 .verified.yaml run_id 불일치 — 기동 거부"
done

if [ "$CONTRACT_VERSION" = 3 ]; then
  LEAN_DECISION="$(q '.lean_gate.decision // ""')"
  LEAN_EVIDENCE="$(q '.lean_gate.evidence // ""')"
  [ "$LEAN_DECISION" != not-needed ] || die \
    "Lean Gate에서 불필요하다고 판정한 '$ID'는 시작하지 않습니다 — skipped를 유지하고 하위 의존을 재계획하세요"
fi
resolve_role "$ROLE" "${HARNESS_MODELS:-$HARNESS_ROOT/MODELS.yaml}"
if [ "$CONTRACT_VERSION" = 2 ] || [ "$CONTRACT_VERSION" = 3 ]; then
  [ "$TASK_EFFORT" = "$ROLE_EFFORT" ] \
    || die "v$CONTRACT_VERSION task effort($TASK_EFFORT)와 역할 effort($ROLE_EFFORT) 불일치"
fi
if [ "$WORKDIR" != "." ]; then
  case "$ROLE_CMD" in
    claude|codex) ROLE_ARGS+=("--add-dir" "$P/log" "--add-dir" "$P/.harness/live-workers");;
    *) die "격리 worktree의 중앙 증거 경로를 허용할 수 없는 CLI: $ROLE_CMD";;
  esac
fi
# 레이아웃과 mux는 실행 자원·예산 기록보다 먼저 확인한다. 이 단계의 거부는
# 실행 시도가 아니므로 .runs·lock·stop·prompt를 남기지 않는다.
LAYOUT="${HARNESS_LAYOUT:-pane}"
PANE_DIR="${HARNESS_PANE_DIR:-right}"
case "$LAYOUT" in workspace|pane) :;; *) die "HARNESS_LAYOUT는 workspace|pane";; esac
case "$PANE_DIR" in left|right|up|down) :;; *) die "HARNESS_PANE_DIR는 left|right|up|down";; esac
MUX="$(detect_mux)"
# B-007 Queue 5: 일반 eligibility가 모두 끝난 뒤에만 실행 ID·lock·예약을 만든다.
RUN_ID="$(date +%Y%m%d-%H%M%S)-$$-$ID"
LIVE_WRITER="$P/.harness/bin/live-status"
LIVE_WORKER_INITIALIZED=false
WORKER_PROVIDER="${ROLE_CMD##*/}"
REQUIRED_SKILLS="$(q '.skills // [] | join(",")')"
read_live_key() {
  awk -F= -v k="$2" '$1 == k {sub(/^[^=]*=/, ""); print; exit}' "$1" 2>/dev/null || true
}
PARENT_RUN_ID="$(read_live_key "$P/.harness/live-status.env" HARNESS_ORCHESTRATOR_RUN_ID)"
PARENT_SURFACE="$(read_live_key "$P/.harness/live-status.env" HARNESS_ORCHESTRATOR_SURFACE)"
[ -n "$PARENT_RUN_ID" ] || PARENT_RUN_ID='?'
[ -n "$PARENT_SURFACE" ] || PARENT_SURFACE='?'
live_worker_update() {
  [ -x "$LIVE_WRITER" ] || return 0
  HARNESS_PROJECT_ROOT="$P" "$LIVE_WRITER" "$@" >/dev/null 2>&1 || true
}
if [ "$CONTRACT_VERSION" = 3 ]; then
  reserve_dispatch_run "$TASKS" "$ID" "$P" "$RUN_ID" \
    || die "BUDGET_STOP: dispatch 예산 또는 증거가 허용 범위를 벗어났습니다"
fi
DONE_PATH="$P/log/$ID.done"
START_DIR=""
CONTEXT_PACK_FILE=""
BUDGET_RESERVED_RUN="${RUN_ID}"
cleanup_dispatch_start() {
  local rc=$?
  if [ -n "$START_DIR" ] && [ -d "$START_DIR" ]; then
    : > "$START_DIR/cancel" 2>/dev/null || true
    rm -rf "$START_DIR"
  fi
  [ -z "$CONTEXT_PACK_FILE" ] || rm -f -- "$CONTEXT_PACK_FILE"
  if [ "${LIVE_WORKER_INITIALIZED:-false}" = true ] && [ "$rc" -ne 0 ]; then
    live_worker_update worker-update --run-id "$RUN_ID" --state blocked \
      --work 'cmux launch failed' --updated-at "$(date +%s)"
  fi
  if [ -n "${BUDGET_RESERVED_RUN:-}" ] && [ "$rc" -ne 0 ] && [ "$CONTRACT_VERSION" = 3 ]; then
    abort_dispatch_run "$ID" "$P" "$BUDGET_RESERVED_RUN" || true
  fi
  trap - EXIT HUP INT TERM
  exit "$rc"
}
trap cleanup_dispatch_start EXIT HUP INT TERM
if [ "$CONTEXT_VERSION" = 1 ]; then
  CONTEXT_PACK_FILE="$(mktemp "${TMPDIR:-/tmp}/agent-harness-dispatch-context.XXXXXX")" \
    || die "context pack 임시 파일 생성 실패"
  "$SCRIPT_DIR/context-pack.sh" "$ID" > "$CONTEXT_PACK_FILE" \
    || die "context pack 생성 실패 — 기동 거부"
  CONTEXT_SHA256="$(sha256_file "$CONTEXT_PACK_FILE")"
  HOT_COUNT="$(q '.context.hot_paths | length')"
  COLD_COUNT="$(q '.context.cold_paths | length')"
  SKILL_COUNT="$(q '.context.skills | length')"
  PROMPT="$(cat "$CONTEXT_PACK_FILE")"
else
  PROMPT="$(cat "$P/$BRIEF")"
fi

PROMPT="$PROMPT

[실행 ID: $RUN_ID / 태스크: $ID]
완료하면 $DONE_PATH.tmp 파일에 run_id: $RUN_ID / artifact: <대표 산출물 경로> /
테스트 결과 / status: DONE 을 기재한 뒤 'mv $DONE_PATH.tmp $DONE_PATH' 으로
원자 게시하라. 게시 후 .done 파일을 다시 수정하지 마라."
if [ "$CONTRACT_VERSION" = 3 ]; then
  PROMPT="$PROMPT

Lean Gate: $LEAN_DECISION ($LEAN_EVIDENCE) — 결론을 유지하고, 명시 범위의 최소 변경으로 기존 안전 조건을 보존하라."
fi
if [ -x "$LIVE_WRITER" ]; then
  PROMPT="$PROMPT

작업 시작과 단계 전환 때 아래 명령으로 실제 현재 작업·활성 스킬을 보고하라.
필수 스킬 목록을 실제 사용으로 복사하지 말고, 지금 활성화한 스킬만 적는다.
\"$LIVE_WRITER\" worker-update --run-id \"$RUN_ID\" --state running --work \"현재 수행 중인 한 단계\" --skills \"실제 활성 스킬, 쉼표 구분\" --updated-at \"\$(date +%s)\""
fi
# pane 모드는 cmux 전용 — 오케스트레이터·워커를 한 화면에서 본다 (B-004, 결정 31 예시)
WS="hx-$ID"; LOG="$P/log/$ID.log"
# 프롬프트는 argv가 아니라 파일→stdin으로 전달한다: 터미널 타이핑 경유 시
# 멀티바이트(UTF-8)가 깨져 codex가 거부하는 문제의 근본 해결 (2026-07-13 실측).
PROMPT_FILE="$P/log/$ID.prompt"
printf '%s\n' "$PROMPT" > "$PROMPT_FILE"
# worker-wrap이 started/finished 사건과 종료 코드를 기록하고 tee로 로그를 남긴다 (B-001)
RUNS="$P/log/$ID.runs"
WRAP="$(printf '%q ' env "HARNESS_PROJECT_ROOT=$P" "HARNESS_WORKER_RUN_ID=$RUN_ID" \
  "HARNESS_WORKER_PROVIDER=$WORKER_PROVIDER" "$WRAP_BIN" "$RUNS" "$RUN_ID" "$LOG" "$PROMPT_FILE" -- \
  "$ROLE_CMD" ${ROLE_ARGS[@]+"${ROLE_ARGS[@]}"})"
if [ -x "$LIVE_WRITER" ]; then
  if HARNESS_PROJECT_ROOT="$P" "$LIVE_WRITER" worker-init \
    --run-id "$RUN_ID" --parent-run-id "$PARENT_RUN_ID" --parent-surface "$PARENT_SURFACE" \
    --provider "$WORKER_PROVIDER" --model-requested "$ROLE_NAME" --role "$ROLE" \
    --task-id "$ID" --work "$NAME" --required-skills "$REQUIRED_SKILLS" \
    --state starting --surface '?' --started-at "$(date +%s)" >/dev/null 2>&1; then
    LIVE_WORKER_INITIALIZED=true
  fi
fi
START_DIR="$(mktemp -d "$P/log/.dispatch-start.XXXXXX")" \
  || die "worker 시작 barrier 생성 실패"
# shellcheck disable=SC2016 # 이 문자열은 별도 Bash 프로세스에서 해석된다.
START_GUARD='start_dir=$1
wrap=$2
while :; do
  if [ -f "$start_dir/release" ]; then
    rm -rf "$start_dir"
    exec bash -c "$wrap"
  fi
  [ ! -d "$start_dir" ] || [ -f "$start_dir/cancel" ] && exit 0
  sleep 0.02
done'
GATED_WRAP="$(printf '%q ' bash -c "$START_GUARD" dispatch-start "$START_DIR" "$WRAP")"
mkdir -p "$P/$WORKDIR"
WHERE="$WS"
WORKER_SURFACE='?'
if [ "$MUX" = cmux ] && [ "$LAYOUT" = pane ]; then
  # pane 모드: 오케스트레이터가 있는 워크스페이스에 split을 만들고 그 안에서 워커를
  # 실행한다. new-split은 --command가 없으므로 새 surface에 명령을 send한다.
  # GATED_WRAP은 ASCII 경로·플래그뿐이고 멀티바이트 프롬프트는 stdin(PROMPT_FILE)
  # 경유이므로 send로 전달해도 UTF-8 깨짐이 없다(72행 주의 참조).
  ORCH_WS="${HARNESS_ORCH_WORKSPACE:-$(cmux identify --no-caller 2>/dev/null \
    | yq -r '.caller.workspace_ref // ""' 2>/dev/null)}"
  [ -n "$ORCH_WS" ] || ORCH_WS="$(cmux identify 2>/dev/null | yq -r '.caller.workspace_ref // ""' 2>/dev/null)"
  [ -n "$ORCH_WS" ] || die "pane 모드: 현재 cmux 워크스페이스를 확인할 수 없음 (HARNESS_ORCH_WORKSPACE로 지정)"
  SURF="$(cmux new-split "$PANE_DIR" --workspace "$ORCH_WS" 2>/dev/null \
    | grep -o 'surface:[0-9]*' | head -1)"
  [ -n "$SURF" ] || die "cmux new-split 실패 ($PANE_DIR)"
  WORKER_SURFACE="$SURF"
  cd "$P/$WORKDIR" >/dev/null 2>&1 || true
  cmux send --surface "$SURF" "cd $(printf '%q' "$P/$WORKDIR") && $GATED_WRAP" >/dev/null
  cmux send-key --surface "$SURF" enter >/dev/null 2>&1 \
    || cmux send-key --surface "$SURF" Enter >/dev/null 2>&1 || true
  WHERE="$ORCH_WS/$SURF ($PANE_DIR)"
  WS="$WHERE"
elif [ "$MUX" = cmux ]; then
  # cmux 터미널은 앱이 워크스페이스를 화면에 그려야 시작된다(실측).
  # 생성 직후 선택해 렌더링을 트리거한다 — cmux 앱이 열려 있어야 워커가 돈다.
  REF="$(cmux new-workspace --name "$WS" --cwd "$P/$WORKDIR" --command "$GATED_WRAP" \
    | grep -o 'workspace:[0-9]*' | head -1)"
  [ -n "$REF" ] || die "cmux 워크스페이스 생성 실패"
  cmux select-workspace --workspace "$REF" >/dev/null
  WHERE="$REF"
  WS="$REF"
else
  tmux new-session -d -s "$WS" -c "$P/$WORKDIR" "$GATED_WRAP"
fi
if [ "$LIVE_WORKER_INITIALIZED" = true ]; then
  live_worker_update worker-update --run-id "$RUN_ID" --state running \
    --surface "$WORKER_SURFACE" --updated-at "$(date +%s)"
fi
if [ "$CONTRACT_VERSION" = 2 ] || [ "$CONTRACT_VERSION" = 3 ]; then
  if [ "$CONTEXT_VERSION" = 1 ]; then
    printf 'run_id: %s event: dispatched at: %s role: %s cli: %s mux: %s ws: %s grade: %s effort: %s contract: %s context: v1 context_sha256: %s hot_count: %s cold_count: %s skill_count: %s\n' \
      "$RUN_ID" "$(utc_now)" "$ROLE" "$ROLE_NAME" "$MUX" "$WS" "$GRADE" "$TASK_EFFORT" "$CONTRACT_VERSION" \
      "$CONTEXT_SHA256" "$HOT_COUNT" "$COLD_COUNT" "$SKILL_COUNT" >> "$RUNS"
  else
    printf 'run_id: %s event: dispatched at: %s role: %s cli: %s mux: %s ws: %s grade: %s effort: %s contract: %s context: legacy\n' \
      "$RUN_ID" "$(utc_now)" "$ROLE" "$ROLE_NAME" "$MUX" "$WS" "$GRADE" "$TASK_EFFORT" "$CONTRACT_VERSION" >> "$RUNS"
  fi
else
  if [ "$CONTEXT_VERSION" = 1 ]; then
    printf 'run_id: %s event: dispatched at: %s role: %s cli: %s mux: %s ws: %s context: v1 context_sha256: %s hot_count: %s cold_count: %s skill_count: %s\n' \
      "$RUN_ID" "$(utc_now)" "$ROLE" "$ROLE_NAME" "$MUX" "$WS" \
      "$CONTEXT_SHA256" "$HOT_COUNT" "$COLD_COUNT" "$SKILL_COUNT" >> "$RUNS"
  else
    printf 'run_id: %s event: dispatched at: %s role: %s cli: %s mux: %s ws: %s context: legacy\n' \
      "$RUN_ID" "$(utc_now)" "$ROLE" "$ROLE_NAME" "$MUX" "$WS" >> "$RUNS"
  fi
fi
: > "$START_DIR/release" || die "worker 시작 barrier 해제 실패"
START_DIR=""
BUDGET_RESERVED_RUN=""
if [ "$CONTRACT_VERSION" = 2 ] || [ "$CONTRACT_VERSION" = 3 ]; then
  echo "기동: $ID → $WHERE (등급 $GRADE / 논리 역할 $ROLE / 실제 프로필 $ROLE_NAME / 생각량 $TASK_EFFORT / 실행 $RUN_ID / $MUX / $LAYOUT)"
else
  echo "기동: $ID → $WHERE (역할 $ROLE / $ROLE_NAME / 실행 $RUN_ID / $MUX / $LAYOUT)"
fi
echo "다음: scripts/status.sh 로 관찰. 교정은 브리프 갱신 후 새 실행 (결정 20)."
