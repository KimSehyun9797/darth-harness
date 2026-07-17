#!/usr/bin/env bash
# 선택적 worker 문맥 pack 생성. 프로젝트 루트에서 실행.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/lib.sh
. "$SCRIPT_DIR/lib.sh"

P="$(pwd)"
TASKS="$P/tasks.yaml"
ID="${1:?사용법: context-pack.sh <태스크ID>}"
[ -f "$TASKS" ] || die "tasks.yaml 없음 — 프로젝트 루트에서 실행하세요"
valid_task_id "$ID" || die "안전하지 않은 task id: $ID"
validate_execution_contract "$TASKS" "$P" || die "실행 계약 위반 — context pack 생성 거부"

q() { task_value "$TASKS" "$ID" "$1"; }
NAME="$(q '.name // ""')"
[ -n "$NAME" ] && [ "$NAME" != null ] || die "태스크 '$ID' 가 tasks.yaml에 없음"
EXECUTION="$(q '.execution // ""')"
[ "$EXECUTION" = worker ] || die "태스크 '$ID' 는 모델 worker가 아닙니다"
BRIEF="$(q '.brief // ""')"
[ -n "$BRIEF" ] || die "태스크 '$ID' 의 brief가 없습니다"

PACK="$(mktemp "${TMPDIR:-/tmp}/agent-harness-context.XXXXXX")" \
  || die "context pack 임시 파일 생성 실패"
cleanup() {
  local status=$?
  rm -f -- "$PACK"
  trap - EXIT
  exit "$status"
}
trap cleanup EXIT

{
  printf '%s\n' '[HARNESS_CONTEXT_V1]'
  printf 'task: %s\n\n' "$ID"
  printf '%s\n' "--- BRIEF: $BRIEF ---"
  cat "$P/$BRIEF"
  printf '\n\n'
  while IFS= read -r path; do
    printf '%s\n' "--- HOT: $path ---"
    cat "$P/$path"
    printf '\n\n'
  done < <(q '.context.hot_paths[]')
  printf '%s\n' '--- COLD INDEX ---'
  q '.context.cold_paths[]'
  printf '\n%s\n' '--- SKILL INDEX ---'
  q '.context.skills[]'
  printf '\n%s\n' '--- LOAD RULE ---'
  printf '%s\n' 'hot으로 먼저 작업하고, cold·skill은 필요할 때만 연다.'
} > "$PACK"

cat "$PACK"
