#!/usr/bin/env bash
# Deterministic verification receipt runner. Run from a project Git root.
set -euo pipefail

SCRIPT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
. "$SCRIPT_ROOT/scripts/lib.sh"

cacheable=false
task=""
scope=other
env_names=()

while [ "$#" -gt 0 ]; do
  case "$1" in
    --cacheable) cacheable=true; shift ;;
    --task) [ "$#" -ge 2 ] || die "--task 값이 필요합니다"; task="$2"; shift 2 ;;
    --env)
      [ "$#" -ge 2 ] || die "--env 값이 필요합니다"
      printf '%s' "$2" | grep -Eq '^[A-Za-z_][A-Za-z0-9_]*$' \
        || die "안전하지 않은 환경 변수 이름: $2"
      env_names+=("$2")
      shift 2
      ;;
    --scope)
      [ "$#" -ge 2 ] || die "--scope 값이 필요합니다"
      scope="$2"; shift 2
      ;;
    --) shift; break ;;
    -*) die "알 수 없는 옵션: $1" ;;
    *) break ;;
  esac
done

[ "$#" -ge 3 ] || die "사용법: verify-cache.sh [--cacheable] [--task ID] [--scope related|full|other] [--env NAME] RECEIPT_ID -- COMMAND [ARGS...]"
receipt_id="$1"
shift
[ "$1" = -- ] || die "RECEIPT_ID 뒤에 --가 필요합니다"
shift
[ "$#" -ge 1 ] || die "실행할 command가 필요합니다"

valid_task_id "$receipt_id" || die "안전하지 않은 receipt id: $receipt_id"
if [ -n "$task" ]; then valid_task_id "$task" || die "안전하지 않은 task id: $task"; fi
case "$scope" in related|full|other) ;; *) die "scope은 related, full, other 중 하나여야 합니다" ;; esac

need git "Git 저장소에서 실행"
need_yq
project_root="$(git rev-parse --show-toplevel 2>/dev/null)" || die "Git 프로젝트가 아닙니다"
cd "$project_root"
budgeted=false

if [ "$scope" != other ]; then
  [ -n "$task" ] || die "scope $scope 에서는 --task가 필요합니다"
  [ -f "$project_root/tasks.yaml" ] || die "tasks.yaml 없음"
  [ "$(yq -r '.contract_version // ""' "$project_root/tasks.yaml")" = 3 ] && budgeted=true
fi

input_sha256="$(workspace_tree_sha256 "$project_root")"
command_sha256="$(nul_sha256 "$@")"
if [ "${#env_names[@]}" -gt 0 ]; then
  environment_sha256="$(verification_environment_sha256 "$1" "${env_names[@]}")"
else
  environment_sha256="$(verification_environment_sha256 "$1")"
fi
cache_key="$(nul_sha256 "$input_sha256" "$command_sha256" "$environment_sha256")"
receipts_dir="$project_root/log/receipts"
cold_dir="$project_root/log/cold/verification"
mkdir -p "$receipts_dir" "$cold_dir"

if [ "$budgeted" = true ]; then
  if ! budget_assert_verification "$project_root/tasks.yaml" "$task" "$scope" "$project_root"; then
    [ "${BUDGET_REASON:-}" = existing_stop ] || write_budget_stop "$task" verification "$project_root" "${BUDGET_MEASURED:-1}" "${BUDGET_LIMIT:-1}" "$BUDGET_REASON" ambiguous
    die "verification budget stop: ${BUDGET_REASON:-attempt_evidence}"
  fi
fi

receipt_path="$receipts_dir/$receipt_id-$cache_key.yaml"

receipt_is_intact() {
  local raw_log stdout_sha
  [ -f "$receipt_path" ] || return 1
  yq -e '
    .version == 1 and .receipt_id == strenv(RECEIPT_ID) and .task == strenv(TASK) and
    .scope == strenv(SCOPE) and .cacheable == true and .cache == "miss" and
    .input_sha256 == strenv(INPUT_SHA) and .command_sha256 == strenv(COMMAND_SHA) and
    .environment_sha256 == strenv(ENVIRONMENT_SHA) and .cache_key == strenv(CACHE_KEY) and
    .exit_code == 0 and (.stdout_sha256 | test("^[0-9a-f]{64}$")) and
    (.raw_log | test("^log/cold/verification/[A-Za-z0-9._-]+\\.log$"))
  ' "$receipt_path" >/dev/null 2>&1 || return 1
  raw_log="$(yq -r '.raw_log' "$receipt_path")"
  stdout_sha="$(yq -r '.stdout_sha256' "$receipt_path")"
  [ -f "$project_root/$raw_log" ] && [ "$(sha256_file "$project_root/$raw_log")" = "$stdout_sha" ]
}

if [ "$cacheable" = true ] && RECEIPT_ID="$receipt_id" TASK="$task" SCOPE="$scope" \
  INPUT_SHA="$input_sha256" COMMAND_SHA="$command_sha256" ENVIRONMENT_SHA="$environment_sha256" \
  CACHE_KEY="$cache_key" receipt_is_intact; then
  printf 'VERIFY_CACHE HIT\n'
  exit 0
fi

if [ "$budgeted" = true ] && [ "${BUDGET_VERIFICATION_COUNT:-0}" -ge "${BUDGET_VERIFICATION_LIMIT:-0}" ]; then
  BUDGET_REASON="${scope}_test_runs"
  BUDGET_MEASURED="$BUDGET_VERIFICATION_COUNT"
  BUDGET_LIMIT="$BUDGET_VERIFICATION_LIMIT"
  write_budget_stop "$task" verification "$project_root" "$BUDGET_MEASURED" "$BUDGET_LIMIT" "$BUDGET_REASON" verified
  die "verification budget stop: $BUDGET_REASON"
fi

if [ "$cacheable" = true ]; then
  run_key="$cache_key"
  result=MISS
else
  run_key="$(date -u +%Y%m%dT%H%M%SZ)-$$"
  receipt_path="$receipts_dir/$receipt_id-$run_key.yaml"
  result=DISABLED
fi
raw_rel="log/cold/verification/$receipt_id-$run_key.log"
raw_path="$project_root/$raw_rel"
started_at="$(utc_now)"

if [ "$budgeted" = true ]; then
  attempt_count=0
  for attempt_path in "$project_root/log/verification-attempts/$task"/*.intent.yaml; do
    [ -e "$attempt_path" ] || continue
    attempt_count=$((attempt_count + 1))
  done
  publish_verification_intent "$project_root" "$task" "$scope" "$((attempt_count + 1))" "$input_sha256" "$command_sha256" "$environment_sha256" "$receipt_id" \
    || die "verification intent 게시 실패"
fi

set +e
"$@" 2>&1 | tee "$raw_path"
command_status=${PIPESTATUS[0]}
set -e
finished_at="$(utc_now)"
stdout_sha256="$(sha256_file "$raw_path")"
receipt_tmp="$(mktemp "$receipts_dir/.receipt.XXXXXX")" || die "임시 영수증 생성 실패"
trap 'rm -f "$receipt_tmp"' EXIT
{
  printf 'version: 1\n'
  printf 'receipt_id: %s\n' "$receipt_id"
  printf 'task: "%s"\n' "$task"
  printf 'scope: %s\n' "$scope"
  printf 'cacheable: %s\n' "$cacheable"
  printf 'cache: %s\n' "$(printf '%s' "$result" | tr '[:upper:]' '[:lower:]')"
  printf 'input_sha256: %s\n' "$input_sha256"
  printf 'command_sha256: %s\n' "$command_sha256"
  printf 'environment_sha256: %s\n' "$environment_sha256"
  printf 'cache_key: %s\n' "$cache_key"
  printf 'started_at: %s\n' "$started_at"
  printf 'finished_at: %s\n' "$finished_at"
  printf 'exit_code: %s\n' "$command_status"
  printf 'stdout_sha256: %s\n' "$stdout_sha256"
  printf 'raw_log: %s\n' "$raw_rel"
} > "$receipt_tmp"
mv "$receipt_tmp" "$receipt_path"
trap - EXIT
last_raw_byte="$(tail -c 1 "$raw_path" | od -An -t x1 | tr -d '[:space:]')"
if [ -n "$last_raw_byte" ] && [ "$last_raw_byte" != 0a ]; then
  printf '\n'
fi
printf 'VERIFY_CACHE %s\n' "$result"
if [ "$budgeted" = true ]; then
  publish_verification_result "$VERIFICATION_INTENT_PATH" "$VERIFICATION_INTENT_SHA256" "$(sha256_file "$receipt_path")" "$(sha256_file "$raw_path")" "$command_status" "${receipt_path#"$project_root/"}" "$raw_rel" "$started_at" "$finished_at" \
    || die "verification result 게시 실패"
fi
exit "$command_status"
