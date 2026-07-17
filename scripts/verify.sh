#!/usr/bin/env bash
# 검증·승격 기록 (B-001, 스펙 4.5). 프로젝트 루트에서 실행. 오케스트레이터 전용.
# 사용법: verify.sh <태스크ID> [--recheck]
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib.sh"
need_yq
P="$(pwd)"
ID="${1:?사용법: verify.sh <태스크ID> [--recheck]}"
printf '%s' "$ID" | grep -Eq '^[A-Za-z0-9._-]+$' \
  || die "안전하지 않은 task id: $ID"
MODE="${2:-}"
case "$MODE" in ""|--recheck) :;; *) die "두 번째 인자는 --recheck만 허용";; esac
TASKS="$P/tasks.yaml"
RUNS="$P/log/$ID.runs"; DONE="$P/log/$ID.done"
VLOG="$P/log/$ID.verify.log"
seq_n=0
ev()   { seq_n=$((seq_n+1)); printf '[%d] %s %s\n' "$seq_n" "$(utc_now)" "$*" >> "$VLOG"; }
fail() { trap - ERR; ev "FAIL: $*" || true; die "$*"; }
unexpected_error() {
  local rc="$1" line="$2"
  trap - ERR
  ev "FAIL: 내부 오류 line=$line exit=$rc" 2>/dev/null || true
  exit "$rc"
}

# 게이트 1: 최신 실행 종료 확인 (결정 16 — 최신 dispatched만 유효)
RUN_ID=unknown; STARTED=""; FIN_AT=""; FIN_EXIT=""; RUN_PARSE_OK=1
if [ -f "$RUNS" ]; then
  if RUN_STATE="$(awk '
    $3 == "event:" && $4 == "dispatched" {
      rid=$2; started=""; finished=""; exit_code=""; next
    }
    $2 == rid && $3 == "event:" && $4 == "started"  {started=$6}
    $2 == rid && $3 == "event:" && $4 == "finished" {finished=$6; exit_code=$8}
    END {if (rid) printf "%s|%s|%s|%s", rid, started, finished, exit_code}
  ' "$RUNS")"; then
    if [ -n "$RUN_STATE" ]; then
      IFS='|' read -r RUN_ID STARTED FIN_AT FIN_EXIT <<EOF
$RUN_STATE
EOF
    fi
  else
    RUN_PARSE_OK=0
  fi
fi
printf '=== verify %s run %s attempt %s mode=%s ===\n' \
  "$ID" "$RUN_ID" "$(utc_now)" "${MODE:-full}" >> "$VLOG" \
  || die "verify.log attempt 헤더 기록 실패: $VLOG"
trap 'unexpected_error "$?" "$LINENO"' ERR
[ -f "$TASKS" ] || fail "tasks.yaml 없음 — 프로젝트 루트에서 실행하세요"
yq -e '.tasks | tag == "!!seq"' "$TASKS" >/dev/null 2>&1 \
  || fail "tasks.yaml 파싱 실패"
yq -e ".tasks[] | select(.id == \"$ID\")" "$TASKS" >/dev/null 2>&1 \
  || fail "태스크 '$ID' 가 tasks.yaml에 없음"
[ -f "$RUNS" ] || fail ".runs 없음: log/$ID.runs"
[ "$RUN_PARSE_OK" = 1 ] || fail ".runs 파싱 실패: log/$ID.runs"
[ "$RUN_ID" != unknown ] || fail ".runs에 dispatched 사건 없음 (B-001 새 형식 필요)"
[ -n "$STARTED" ]  || fail "started 사건 없음: $RUN_ID"
[ -n "$FIN_AT" ]   || fail "finished 사건 없음(워커 실행 중?): $RUN_ID"
[ "$FIN_EXIT" = 0 ] || fail "워커 종료 코드 $FIN_EXIT ≠ 0: $RUN_ID"
ev "gate finished-run: run_id=$RUN_ID started=$STARTED finished=$FIN_AT exit_code=$FIN_EXIT"

# 게이트 2: .done 마커 (불변 완료 증명서, 스펙 4.3)
[ -f "$DONE" ] || fail ".done 없음"
M_STATUS="$(yq -r '.status // ""' "$DONE")" || fail ".done YAML 파싱 실패"
M_RUN="$(yq -r '.run_id // ""' "$DONE")" || fail ".done YAML 파싱 실패"
ARTIFACT="$(yq -r '.artifact // ""' "$DONE")" || fail ".done YAML 파싱 실패"
[ "$M_STATUS" = DONE ] || fail ".done status가 DONE 아님: $M_STATUS"
[ "$M_RUN" = "$RUN_ID" ] || fail ".done run_id($M_RUN)가 최신 실행($RUN_ID)과 불일치"
{ [ -n "$ARTIFACT" ] && [ -f "$P/$ARTIFACT" ]; } || fail "artifact 없음: $ARTIFACT"
ev "gate done-marker: run_id=$M_RUN artifact=$ARTIFACT"

# 게이트 3: 해시 포착 (스펙 4.5)
VY="$P/log/$ID.verified.yaml"
DONE_SHA="$(sha256_file "$DONE")" || fail ".done SHA-256 계산 실패"
WT="$(yq -r ".tasks[] | select(.id == \"$ID\") | .worktree // \".\"" "$TASKS")" \
  || fail "tasks.yaml worktree 파싱 실패"
if [ "$WT" != "." ]; then
  case "$WT" in /*|..|../*|*/../*|*/..) fail "안전하지 않은 worktree 경로: $WT";; esac
  [ -d "$P/$WT" ] || fail "worktree 없음: $WT"
  WT_ROOT="$(cd "$P/$WT" && pwd -P)" || fail "worktree 경로 확인 실패: $WT"
  GIT_ROOT="$(git -C "$P/$WT" rev-parse --show-toplevel 2>/dev/null)" \
    || fail "Git worktree 아님: $WT"
  GIT_ROOT="$(cd "$GIT_ROOT" && pwd -P)" || fail "Git worktree 루트 확인 실패: $WT"
  [ "$GIT_ROOT" = "$WT_ROOT" ] || fail "독립 Git worktree 루트 아님: $WT"
  case "$ARTIFACT" in
    "$WT"/*) WT_ARTIFACT="${ARTIFACT#"$WT"/}";;
    *) fail "artifact가 격리 worktree 밖에 있음: $ARTIFACT";;
  esac
  BLOB="$(git -C "$P/$WT" hash-object "$P/$ARTIFACT")" \
    || fail "artifact git blob 계산 실패: $ARTIFACT"
  HEAD_BLOB="$(git -C "$P/$WT" ls-tree HEAD -- "$WT_ARTIFACT" | awk 'NR == 1 {print $3}')" \
    || fail "artifact HEAD blob 계산 실패: $WT_ARTIFACT"
  [ -n "$HEAD_BLOB" ] || fail "artifact가 worktree HEAD에 추적되지 않음: $WT_ARTIFACT"
  [ "$BLOB" = "$HEAD_BLOB" ] || fail "artifact가 worktree HEAD blob과 불일치: $WT_ARTIFACT"
  git -C "$P/$WT" diff --quiet HEAD -- "$WT_ARTIFACT" \
    || fail "artifact에 미커밋 변경 존재: $WT_ARTIFACT"
  WT_HEAD="$(git -C "$P/$WT" rev-parse HEAD)" || fail "worktree HEAD 계산 실패: $WT"
  WT_TREE="$(git -C "$P/$WT" rev-parse 'HEAD^{tree}')" || fail "worktree tree 계산 실패: $WT"
else
  BLOB="$(git -C "$P" hash-object "$P/$ARTIFACT")" \
    || fail "artifact git blob 계산 실패: $ARTIFACT"
  WT_HEAD=shared; WT_TREE=shared
fi
ev "hash: done_sha256=$DONE_SHA artifact_git_blob=$BLOB worktree_head=$WT_HEAD worktree_tree=$WT_TREE"

# --recheck: 병합 전 재확인 — 검증 명령 재실행 없이 기록·현재 해시 일치만 검사 (스펙 4.5)
if [ "$MODE" = --recheck ]; then
  [ -f "$VY" ] || fail "recheck: verified.yaml 없음"
  rc_ok=1
  [ "$(yq -r '.run_id // ""' "$VY")" = "$RUN_ID" ]        || { ev "recheck 불일치: run_id"; rc_ok=0; }
  [ "$(yq -r '.done_sha256 // ""' "$VY")" = "$DONE_SHA" ] || { ev "recheck 불일치: done_sha256"; rc_ok=0; }
  [ "$(yq -r '.artifact_git_blob // ""' "$VY")" = "$BLOB" ] || { ev "recheck 불일치: artifact_git_blob"; rc_ok=0; }
  [ "$(yq -r '.worktree_head // ""' "$VY")" = "$WT_HEAD" ] || { ev "recheck 불일치: worktree_head"; rc_ok=0; }
  [ "$(yq -r '.worktree_tree // ""' "$VY")" = "$WT_TREE" ] || { ev "recheck 불일치: worktree_tree"; rc_ok=0; }
  [ "$rc_ok" = 1 ] || fail "recheck 불일치 — 병합 금지 (log/$ID.verify.log 참조)"
  ev "recheck PASS: 기록과 현재 상태 일치"
  echo "recheck PASS: $ID ($RUN_ID) — 병합 가능"
  exit 0
fi

# 게이트 4: 검증 실행 — 원 stdout·stderr 전체 보존 (스펙 4.5)
V_CMD="$(yq -r ".tasks[] | select(.id == \"$ID\") | .verify.command // \"\"" "$TASKS")" \
  || fail "verify.command 파싱 실패"
[ -n "$V_CMD" ] || fail "tasks.yaml에 verify.command 없음 — 승격 불가 (스펙 4.4)"
V_ARGS=()
while IFS= read -r -d '' a; do V_ARGS+=("$a"); done \
  < <(yq -r -0 ".tasks[] | select(.id == \"$ID\") | .verify.args[]?" "$TASKS")
command -v "$V_CMD" >/dev/null 2>&1 || fail "verify.command 실행 파일 없음: $V_CMD"
ev "exec: $V_CMD ${V_ARGS[*]:-}"
CACHEABLE="$(yq -r ".tasks[] | select(.id == \"$ID\") | .verify.cacheable // false" "$TASKS")" \
  || fail "verify.cacheable 파싱 실패"
[ "$CACHEABLE" = true ] || CACHEABLE=false
RUNNER=("$SCRIPT_DIR/verify-cache.sh" --task "$ID" --scope related)
[ "$CACHEABLE" = true ] && RUNNER+=(--cacheable)
RUNNER+=("$ID-verify" -- "$V_CMD")
if [ "${#V_ARGS[@]}" -gt 0 ]; then
  RUNNER+=("${V_ARGS[@]}")
fi
OUTPUTS="$(mktemp -d)" || fail "검증 산출물 보관 디렉터리 생성 실패"
restore_verify_outputs() {
  trap - EXIT HUP INT TERM
  [ -f "$VLOG" ] && cat "$VLOG" >> "$OUTPUTS/verify.log"
  rm -f "$VLOG" "$VY"
  [ -f "$OUTPUTS/verify.log" ] && mv "$OUTPUTS/verify.log" "$VLOG"
  [ -f "$OUTPUTS/verified.yaml" ] && mv "$OUTPUTS/verified.yaml" "$VY"
  rmdir "$OUTPUTS" 2>/dev/null || true
}
trap 'restore_verify_outputs' EXIT HUP INT TERM
[ -f "$VLOG" ] && mv "$VLOG" "$OUTPUTS/verify.log"
[ -f "$VY" ] && mv "$VY" "$OUTPUTS/verified.yaml"
RECEIPTS_BEFORE="$(mktemp)" || fail "영수증 목록 임시 파일 생성 실패"
find "$P/log/receipts" -type f -name "$ID-verify-*.yaml" -print 2>/dev/null | sort > "$RECEIPTS_BEFORE"
INPUT_SHA="$(workspace_tree_sha256 "$P")"
COMMAND_SHA="$(nul_sha256 "$V_CMD")"
if [ "${#V_ARGS[@]}" -gt 0 ]; then
  COMMAND_SHA="$(nul_sha256 "$V_CMD" "${V_ARGS[@]}")"
fi
ENVIRONMENT_SHA="$(verification_environment_sha256 "$V_CMD")"
CACHE_KEY="$(nul_sha256 "$INPUT_SHA" "$COMMAND_SHA" "$ENVIRONMENT_SHA")"
RAW="$(mktemp)" || fail "검증 runner 출력 임시 파일 생성 실패"
set +e
( cd "$P" && "${RUNNER[@]}" ) > "$RAW" 2>&1
V_EXIT=$?
set -e
CACHE_TERMINAL="$(awk '
  /^VERIFY_CACHE / {
    if ($0 !~ /^VERIFY_CACHE (HIT|MISS|DISABLED)$/) exit 1
    count++
    result=$2
  }
  END { if (count != 1) exit 1; print result }
' "$RAW")" || fail "runner terminal result가 없거나 잘못됨"
case "$CACHE_TERMINAL" in
  HIT) CACHE_RESULT=hit ;;
  MISS) CACHE_RESULT=miss ;;
  DISABLED) CACHE_RESULT=disabled ;;
  *) fail "runner terminal result가 잘못됨: $CACHE_TERMINAL" ;;
esac
printf 'VERIFY_CACHE %s\n' "$CACHE_TERMINAL"
if [ "$V_EXIT" != 0 ]; then
  rm -f "$RAW" "$RECEIPTS_BEFORE"
  ev "FAIL: 검증 명령 실패 exit=$V_EXIT — verified.yaml 미게시" || true
  echo "ERROR: 검증 명령 실패 exit=$V_EXIT — verified.yaml 미게시" >&2
  exit "$V_EXIT"
fi
if [ "$CACHEABLE" = true ]; then
  RECEIPT="$P/log/receipts/$ID-verify-$CACHE_KEY.yaml"
else
  RECEIPT="$(find "$P/log/receipts" -type f -name "$ID-verify-*.yaml" -print 2>/dev/null | sort \
    | comm -13 "$RECEIPTS_BEFORE" -)"
fi
rm -f "$RECEIPTS_BEFORE"
[ -n "$RECEIPT" ] && [ -f "$RECEIPT" ] || fail "runner 영수증을 찾지 못함"
RAW_LOG="$(yq -r '.raw_log // ""' "$RECEIPT")" || fail "runner raw_log 파싱 실패"
STDOUT_SHA="$(yq -r '.stdout_sha256 // ""' "$RECEIPT")" || fail "runner stdout_sha256 파싱 실패"
[ -f "$P/$RAW_LOG" ] || fail "runner raw log 없음: $RAW_LOG"
[ "$(sha256_file "$P/$RAW_LOG")" = "$STDOUT_SHA" ] || fail "runner raw log SHA-256 불일치"
[ -f "$OUTPUTS/verify.log" ] && mv "$OUTPUTS/verify.log" "$VLOG"
{ printf -- '--- raw output begin ---\n'; cat "$P/$RAW_LOG"
  printf -- '--- raw output end exit_code=%d ---\n' "$V_EXIT"; } >> "$VLOG"
rm -f "$RAW"
rm -f "$OUTPUTS/verified.yaml"
rmdir "$OUTPUTS"
trap - EXIT HUP INT TERM

# 게이트 5: 원자 게시 (tmp → mv)
HARNESS_COMMIT="$(git -C "$HARNESS_ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)"
yaml_sq() { printf "%s" "$1" | sed "s/'/''/g"; }
{
  echo "version: 1"
  echo "task: $ID"
  echo "run_id: $RUN_ID"
  echo "verified_by: '$(yaml_sq "${HARNESS_VERIFIER:-orchestrator}")'"
  echo "verified_at: $(utc_now)"
  echo "harness_commit: $HARNESS_COMMIT"
  echo "done_sha256: $DONE_SHA"
  echo "artifact: '$(yaml_sq "$ARTIFACT")'"
  echo "artifact_git_blob: $BLOB"
  echo "worktree: '$(yaml_sq "$WT")'"
  echo "worktree_head: $WT_HEAD"
  echo "worktree_tree: $WT_TREE"
  echo "verify_command: []"
  echo "verify_exit_code: $V_EXIT"
  echo "stdout_sha256: $STDOUT_SHA"
  echo "verify_log: $RAW_LOG"
  echo "verification_receipt: ${RECEIPT#"$P/"}"
  echo "cache: $CACHE_RESULT"
} > "$VY.tmp"
VERIFY_ARG="$V_CMD" yq -i '.verify_command += [strenv(VERIFY_ARG)]' "$VY.tmp"
if [ "${#V_ARGS[@]}" -gt 0 ]; then
  for a in "${V_ARGS[@]}"; do
    VERIFY_ARG="$a" yq -i '.verify_command += [strenv(VERIFY_ARG)]' "$VY.tmp"
  done
fi
mv "$VY.tmp" "$VY"
ev "publish: log/$ID.verified.yaml sha256=$(sha256_file "$VY")"
echo "verify PASS: $ID ($RUN_ID) → log/$ID.verified.yaml"
echo "다음: tasks.yaml status를 verified로 갱신 후 .harness/bin/checkpoint 커밋 (오케스트레이터)"
