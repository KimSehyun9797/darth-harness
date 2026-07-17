#!/usr/bin/env bash
# agent-harness 공용 헬퍼. 각 스크립트가 source한다. macOS bash 3.2 호환.
set -euo pipefail

HARNESS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

die()  { echo "ERROR: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "'$1' 필요: $2"; }
need_yq() { need yq "brew install yq"; }

# task_value <tasks.yaml> <task-id> <yq-expression>
# TASK_ID를 환경 변수로 전달해 태스크 ID가 yq 소스에 삽입되지 않게 한다.
valid_task_id() { printf '%s' "$1" | grep -Eq '^[A-Za-z0-9._-]+$'; }

task_value() {
  local tasks="$1" task_id="$2" expression="$3"
  valid_task_id "$task_id" || {
    execution_contract_error "안전하지 않은 task id: $task_id"
    return 1
  }
  TASK_ID="$task_id" yq -r \
    '.tasks[] | select(.id == strenv(TASK_ID)) | '"$expression" "$tasks"
}

execution_contract_error() { echo "execution contract: $*" >&2; return 1; }

context_logical_line_count() {
  local file="$1" lines last_newline
  lines="$(wc -l < "$file" | tr -d '[:space:]')"
  last_newline="$(tail -c 1 "$file" | wc -l | tr -d '[:space:]')"
  if [ -s "$file" ] && [ "$last_newline" = 0 ]; then
    lines=$((lines + 1))
  fi
  printf '%s\n' "$lines"
}

# validate_context_path <project-root> <path>
# 성공 시 CONTEXT_RESOLVED_PATH에 프로젝트 안의 물리 파일 경로를 설정한다.
validate_context_path() {
  local project_root="$1" path="$2" candidate target dir i
  [ -n "$path" ] || return 1
  case "$path" in /*|*"$'\0'"*|*[[:cntrl:]]*) return 1 ;; esac
  case "/$path/" in */../*) return 1 ;; esac
  project_root="$(cd -P "$project_root" 2>/dev/null && pwd)" || return 1
  candidate="$project_root/$path"
  i=0
  while [ -L "$candidate" ]; do
    i=$((i + 1)); [ "$i" -le 40 ] || return 1
    target="$(readlink "$candidate")" || return 1
    case "$target" in /*) candidate="$target";; *) candidate="$(dirname "$candidate")/$target";; esac
    dir="$(cd -P "$(dirname "$candidate")" 2>/dev/null && pwd)" || return 1
    candidate="$dir/$(basename "$candidate")"
  done
  [ -f "$candidate" ] || return 1
  dir="$(cd -P "$(dirname "$candidate")" 2>/dev/null && pwd)" || return 1
  candidate="$dir/$(basename "$candidate")"
  case "$candidate" in "$project_root"/*) ;; *) return 1;; esac
  CONTEXT_RESOLVED_PATH="$candidate"
}

# validate_context_contract <tasks.yaml> <project-root>
validate_context_contract() {
  local tasks="$1" project_root="$2" version version_type id execution field path path_type
  local brief bytes lines count skill skill_type seen_paths seen_skills
  need_yq
  version="$(yq -r '.context_contract_version // ""' "$tasks" 2>/dev/null)" \
    || { execution_contract_error "tasks.yaml 파싱 실패"; return 1; }
  if [ -z "$version" ]; then
    echo "WARNING: legacy context contract (context_contract_version 없음)" >&2
    return 0
  fi
  version_type="$(yq -r '.context_contract_version | tag' "$tasks")"
  [ "$version" = 1 ] && [ "$version_type" = '!!int' ] || {
    execution_contract_error "지원하지 않는 context_contract_version: $version"
    return 1
  }
  project_root="$(cd -P "$project_root" 2>/dev/null && pwd)" || {
    execution_contract_error "프로젝트 루트 없음: $2"; return 1
  }
  while IFS= read -r id; do
    valid_task_id "$id" || { execution_contract_error "안전하지 않은 task id: $id"; return 1; }
    execution="$(task_value "$tasks" "$id" '.execution // ""')"
    [ "$execution" = worker ] || continue
    [ "$(task_value "$tasks" "$id" '.context | tag')" = '!!map' ] || {
      execution_contract_error "$id: context map이 필요합니다"; return 1
    }
    for field in hot_paths cold_paths skills; do
      [ "$(task_value "$tasks" "$id" ".context.$field | tag")" = '!!seq' ] || {
        execution_contract_error "$id: context.$field sequence이 필요합니다"; return 1
      }
    done
    count="$(task_value "$tasks" "$id" '.context.hot_paths | length')"
    [ "$count" -le 5 ] || { execution_contract_error "$id: context.hot_paths는 최대 5개입니다"; return 1; }
    count="$(task_value "$tasks" "$id" '.context.skills | length')"
    [ "$count" -le 5 ] || { execution_contract_error "$id: context.skills는 최대 5개입니다"; return 1; }
    brief="$(task_value "$tasks" "$id" '.brief // ""')"
    validate_context_path "$project_root" "$brief" || {
      execution_contract_error "$id: brief는 프로젝트 안의 일반 파일이어야 합니다"; return 1
    }
    lines="$(context_logical_line_count "$CONTEXT_RESOLVED_PATH")"
    bytes="$(wc -c < "$CONTEXT_RESOLVED_PATH")"
    seen_paths=""
    for field in hot_paths cold_paths; do
      while IFS= read -r path; do
        path_type="$(TASK_ID="$id" CONTEXT_FIELD="$field" CONTEXT_PATH="$path" yq -r '.tasks[] | select(.id == strenv(TASK_ID)) | .context[strenv(CONTEXT_FIELD)][] | select(. == strenv(CONTEXT_PATH)) | tag' "$tasks" | head -1)"
        [ "$path_type" = '!!str' ] || { execution_contract_error "$id: context.$field 항목은 문자열이어야 합니다"; return 1; }
        validate_context_path "$project_root" "$path" || {
          execution_contract_error "$id: context.$field 경로가 안전한 일반 파일이 아닙니다: $path"; return 1
        }
        case "|$seen_paths|" in *"|$path|"*) execution_contract_error "$id: context 경로가 중복됩니다: $path"; return 1;; esac
        seen_paths="$seen_paths|$path"
        if [ "$field" = hot_paths ]; then
          lines=$((lines + $(context_logical_line_count "$CONTEXT_RESOLVED_PATH")))
          bytes=$((bytes + $(wc -c < "$CONTEXT_RESOLVED_PATH")))
        fi
      done < <(TASK_ID="$id" CONTEXT_FIELD="$field" yq -r \
        '.tasks[] | select(.id == strenv(TASK_ID)) | .context[strenv(CONTEXT_FIELD)][]' "$tasks")
    done
    [ "$lines" -le 200 ] || { execution_contract_error "$id: brief와 hot 입력은 최대 200줄입니다"; return 1; }
    [ "$bytes" -le 32768 ] || { execution_contract_error "$id: brief와 hot 입력은 최대 32KiB입니다"; return 1; }
    seen_skills=""
    while IFS= read -r skill; do
      skill_type="$(TASK_ID="$id" CONTEXT_SKILL="$skill" yq -r '.tasks[] | select(.id == strenv(TASK_ID)) | .context.skills[] | select(. == strenv(CONTEXT_SKILL)) | tag' "$tasks" | head -1)"
      if [ "$skill_type" != '!!str' ] || ! printf '%s' "$skill" | grep -Eq '^[A-Za-z0-9._:-]+$'; then
        execution_contract_error "$id: context.skills에 유효한 skill ID가 필요합니다"; return 1
      fi
      case "|$seen_skills|" in *"|$skill|"*) execution_contract_error "$id: context.skills가 중복됩니다: $skill"; return 1;; esac
      seen_skills="$seen_skills|$skill"
    done < <(task_value "$tasks" "$id" '.context.skills[]')
  done < <(yq -r '.tasks[]? | (.id // "")' "$tasks")
}

# validate_execution_contract <tasks.yaml> [project-root]
# contract_version 없는 기존 프로젝트는 경고만 내고 기존 계약을 유지한다.
validate_execution_contract() {
  local tasks="$1" project_root="${2:-$(cd "$(dirname "$1")" && pwd)}" version key value id grade execution role effort gates field
  local design review regression budget_value
  local decision evidence evidence_type status
  need_yq
  version="$(yq -r '.contract_version // ""' "$tasks" 2>/dev/null)" \
    || { execution_contract_error "tasks.yaml 파싱 실패"; return 1; }
  if [ -z "$version" ]; then
    echo "WARNING: legacy execution contract (contract_version 없음)" >&2
    validate_context_contract "$tasks" "$project_root"
    return
  fi
  case "$version" in
    2) echo "WARNING: Lean Gate 미적용 계약(contract_version: 2)" >&2 ;;
    3) ;;
    *) execution_contract_error "지원하지 않는 contract_version: $version"; return 1 ;;
  esac

  for key in default_workers max_concurrent_workers max_delegation_depth; do
    value="$(yq -r ".execution_policy.$key // \"\"" "$tasks")"
    case "$value" in ''|*[!0-9]*) execution_contract_error "execution_policy.$key 값이 필요합니다"; return 1;; esac
  done
  [ "$(yq -r '.execution_policy.default_workers' "$tasks")" = 1 ] \
    || { execution_contract_error "default_workers는 1이어야 합니다"; return 1; }
  [ "$(yq -r '.execution_policy.max_concurrent_workers' "$tasks")" = 3 ] \
    || { execution_contract_error "max_concurrent_workers는 3이어야 합니다"; return 1; }
  [ "$(yq -r '.execution_policy.max_delegation_depth' "$tasks")" = 0 ] \
    || { execution_contract_error "max_delegation_depth는 0이어야 합니다"; return 1; }

  while IFS= read -r id; do
    valid_task_id "$id" || {
      execution_contract_error "안전하지 않은 task id: $id"
      return 1
    }
    if [ "$version" = 3 ]; then
      decision="$(task_value "$tasks" "$id" '.lean_gate.decision // ""')"
      evidence="$(task_value "$tasks" "$id" '.lean_gate.evidence // ""')"
      evidence_type="$(task_value "$tasks" "$id" '.lean_gate.evidence | type')"
      status="$(task_value "$tasks" "$id" '.status // ""')"
      case "$decision" in
        reuse|stdlib|native|installed|minimal|not-needed|not-applicable) ;;
        '') execution_contract_error "$id: tasks.yaml에 lean_gate.decision이 필요합니다"; return 1 ;;
        *) execution_contract_error "$id: 허용하지 않는 lean_gate.decision=$decision"; return 1 ;;
      esac
      if [ "$evidence_type" != '!!str' ] || ! printf '%s' "$evidence" | grep -q '[^[:space:]]'; then
        execution_contract_error "$id: tasks.yaml에 비어 있지 않은 lean_gate.evidence가 필요합니다"
        return 1
      fi
      if [ "$decision" = not-needed ]; then
        [ "$status" = skipped ] || {
          execution_contract_error "$id: not-needed 작업의 status는 skipped여야 합니다"
          return 1
        }
      elif [ "$status" = skipped ]; then
        execution_contract_error "$id: skipped 작업의 lean_gate.decision은 not-needed여야 합니다"
        return 1
      fi
    fi
    grade="$(task_value "$tasks" "$id" '.grade // ""')"
    execution="$(task_value "$tasks" "$id" '.execution // ""')"
    role="$(task_value "$tasks" "$id" '.role // ""')"
    effort="$(task_value "$tasks" "$id" '.effort // ""')"
    design="$(task_value "$tasks" "$id" '.ceremony.design_approved')"
    review="$(task_value "$tasks" "$id" '.ceremony.independent_review')"
    regression="$(task_value "$tasks" "$id" '.ceremony.full_regression')"
    gates="$(task_value "$tasks" "$id" '.ceremony.approval_gates | join(",")')"
    case "$grade" in T0|T1|T2|T3) ;; *) execution_contract_error "$id: 잘못된 grade"; return 1;; esac

    for field in concurrent_workers total_workers model_turns_per_worker model_runs \
      edit_iterations related_test_runs full_test_runs max_input_tokens max_output_tokens \
      changed_files changed_lines dependencies_added; do
      budget_value="$(task_value "$tasks" "$id" ".budget.$field // \"\"")"
      case "$budget_value" in ''|*[!0-9]*) execution_contract_error "$id: budget.${field}는 0 이상의 정수여야 합니다"; return 1;; esac
    done

    case "$grade" in
      T0)
        { [ "$execution/$role/$effort" = deterministic/none/none ] || \
          [ "$execution/$role/$effort" = worker/economy_worker/low ]; } \
          || { execution_contract_error "$id: T0 실행·역할·effort 조합이 잘못됐습니다"; return 1; }
        [ "$design/$review/$regression/$gates" = false/false/false/ ] \
          || { execution_contract_error "$id: T0 ceremony가 잘못됐습니다"; return 1; }
        ;;
      T1)
        { [ "$execution/$role/$effort" = worker/economy_worker/low ] || \
          [ "$execution/$role/$effort" = worker/standard_worker/medium ]; } \
          || { execution_contract_error "$id: T1 실행·역할·effort 조합이 잘못됐습니다"; return 1; }
        [ "$design/$review/$regression/$gates" = false/false/false/ ] \
          || { execution_contract_error "$id: T1 ceremony가 잘못됐습니다"; return 1; }
        ;;
      T2)
        { [ "$execution/$role/$effort" = worker/standard_worker/medium ] || \
          [ "$execution/$role/$effort" = worker/frontier_worker/high ]; } \
          || { execution_contract_error "$id: T2 실행·역할·effort 조합이 잘못됐습니다"; return 1; }
        [ "$design/$review/$regression/$gates" = true/true/true/ ] \
          || { execution_contract_error "$id: T2 ceremony가 잘못됐습니다"; return 1; }
        ;;
      T3)
        { [ "$execution/$role/$effort" = worker/standard_worker/medium ] || \
          [ "$execution/$role/$effort" = worker/frontier_worker/high ]; } \
          || { execution_contract_error "$id: T3 실행·역할·effort 조합이 잘못됐습니다"; return 1; }
        [ "$design/$review/$regression/$gates" = true/true/true/start,risk ] \
          || { execution_contract_error "$id: T3 ceremony가 잘못됐습니다"; return 1; }
        ;;
    esac

    if [ "$execution" = worker ]; then
      for field in concurrent_workers total_workers model_turns_per_worker model_runs; do
        [ "$(task_value "$tasks" "$id" ".budget.$field")" -ge 1 ] \
          || { execution_contract_error "$id: worker budget.${field}는 1 이상이어야 합니다"; return 1; }
      done
      [ "$(task_value "$tasks" "$id" '.budget.concurrent_workers')" -le \
        "$(task_value "$tasks" "$id" '.budget.total_workers')" ] \
        || { execution_contract_error "$id: concurrent_workers가 total_workers보다 큽니다"; return 1; }
    else
      [ "$(task_value "$tasks" "$id" '.budget.concurrent_workers')" = 0 ] \
        && [ "$(task_value "$tasks" "$id" '.budget.total_workers')" = 0 ] \
        && [ "$(task_value "$tasks" "$id" '.budget.model_turns_per_worker')" = 0 ] \
        && [ "$(task_value "$tasks" "$id" '.budget.model_runs')" = 0 ] \
        || { execution_contract_error "$id: deterministic 모델 budget은 0이어야 합니다"; return 1; }
    fi
  done < <(yq -r '.tasks[]? | (.id // "")' "$tasks")
  validate_context_contract "$tasks" "$project_root"
}

# resolve_role <역할> [MODELS.yaml 경로]
# 성공 시 전역 설정: ROLE_NAME, ROLE_EFFORT, ROLE_CMD, ROLE_ARGS(배열) — source하는 스크립트가 사용
# shellcheck disable=SC2034
resolve_role() {
  local role="$1" models="${2:-$HARNESS_ROOT/MODELS.yaml}" n i cmd effort
  need_yq
  [ -f "$models" ] || die "MODELS.yaml 없음: $models"
  effort="$(yq -r ".roles.\"$role\".effort // \"\"" "$models" 2>/dev/null)" \
    || die "MODELS.yaml 파싱 실패"
  case "$effort" in
    low|medium|high) ;;
    *) die "역할 '$role': 유효한 effort가 없습니다 — BLOCKED" ;;
  esac
  n="$(yq -r ".roles.\"$role\".candidates | length" "$models" 2>/dev/null)" \
    || die "MODELS.yaml 파싱 실패"
  { [ "$n" != "null" ] && [ "$n" -gt 0 ]; } 2>/dev/null \
    || die "역할 '$role'의 후보가 없습니다 — BLOCKED"
  i=0
  while [ "$i" -lt "$n" ]; do
    cmd="$(yq -r ".roles.\"$role\".candidates[$i].command" "$models")"
    if command -v "$cmd" >/dev/null 2>&1; then
      ROLE_NAME="$(yq -r ".roles.\"$role\".candidates[$i].name" "$models")"
      ROLE_EFFORT="$effort"
      ROLE_CMD="$cmd"
      ROLE_ARGS=()
      while IFS= read -r a; do ROLE_ARGS+=("$a"); done \
        < <(yq -r ".roles.\"$role\".candidates[$i].args[]?" "$models")
      return 0
    fi
    i=$((i+1))
  done
  die "역할 '$role': 설치된 CLI 후보가 없습니다 — BLOCKED (MODELS.yaml 후보: $n개)"
}

# detect_mux → stdout: cmux | tmux. 둘 다 없으면 설치 안내 후 종료.
detect_mux() {
  if command -v cmux >/dev/null 2>&1 && cmux ping >/dev/null 2>&1; then
    echo cmux; return 0
  fi
  if command -v tmux >/dev/null 2>&1; then echo tmux; return 0; fi
  die "cmux/tmux 둘 다 없습니다. cmux 설치 후 재시도 (tmux: brew install tmux)"
}

utc_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# template/.harness/lib/state.sh의 sha256_file과 동일 로직 —
# 하네스/프로젝트 런타임 분리 원칙상 의도된 중복 (B-001)
sha256_file() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
  else die "SHA-256 도구(shasum 또는 sha256sum) 필요"; fi
}

sha256_stdin() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then sha256sum | awk '{print $1}'
  else die "SHA-256 도구(shasum 또는 sha256sum) 필요"; fi
}

diff_fingerprint() (
  local project_root="$1" path tmp
  tmp="$(mktemp "${TMPDIR:-/tmp}/agent-harness-fingerprint.XXXXXX")" || return 1
  trap 'rm -f -- "$tmp"' EXIT HUP INT TERM
  git -C "$project_root" ls-files --others --exclude-standard -z > "$tmp" || return 1
  {
    printf 'tracked_patch\0'
    git -C "$project_root" diff --binary HEAD -- . || exit 1
    printf '\0untracked_files\0'
    while IFS= read -r -d '' path; do
      [ -f "$project_root/$path" ] && [ ! -L "$project_root/$path" ] || continue
      printf 'path\0%s\0content_sha256\0%s\0' "$path" "$(sha256_file "$project_root/$path")" || exit 1
    done < "$tmp"
  } | sha256_stdin
)

write_budget_stop() (
  local stop_task_id="$1" action="$2" project_root="$3" measured="$4" limit="$5" reason="$6" evidence_status="$7"
  local runs="$project_root/log/$stop_task_id.runs" stop="$project_root/log/$stop_task_id.budget-stop.yaml" tmp="" head diff_hash evidence_hash
  trap 'exit 1' HUP INT TERM
  [ -e "$stop" ] && return 0
  head="$(git -C "$project_root" rev-parse HEAD 2>/dev/null)" || head=unavailable
  diff_hash="$(diff_fingerprint "$project_root")" || diff_hash=unavailable
  if [ -f "$runs" ]; then evidence_hash="$(sha256_file "$runs")"; else evidence_hash=absent; fi
  tmp="$(mktemp "$project_root/log/.${stop_task_id}.budget-stop.XXXXXX")" || return 1
  # shellcheck disable=SC2064 # subshell 종료까지 고정할 temp 경로를 지금 확장한다.
  trap "rm -f -- $(printf '%q' "$tmp")" EXIT
  printf 'version: 1\ntask: %s\naction: %s\nhead: %s\ndiff_fingerprint: %s\nevidence_path: log/%s.runs\nevidence_sha256: %s\nevidence_status: %s\nmeasured: %s\nlimit: %s\nreason: %s\n' \
    "$stop_task_id" "$action" "$head" "$diff_hash" "$stop_task_id" "$evidence_hash" "$evidence_status" "$measured" "$limit" "$reason" > "$tmp" || return 1
  ln "$tmp" "$stop" 2>/dev/null || { [ -e "$stop" ] && return 0; return 1; }
)

budget_changed_metrics() {
  local project_root="$1" path record add del rest path_hash files=0 lines=0 logical mode tmpdir stats untracked seen unique
  tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/agent-harness-stats.XXXXXX")" || return 1
  stats="$tmpdir/stats"; untracked="$tmpdir/untracked"; seen="$tmpdir/seen"; unique="$tmpdir/unique"
  : > "$stats"; : > "$seen"
  git -C "$project_root" diff --cached --no-renames --numstat -z HEAD -- . > "$stats" \
    || { rm -f -- "$stats" "$seen"; rmdir "$tmpdir"; return 1; }
  git -C "$project_root" diff --no-renames --numstat -z -- . >> "$stats" \
    || { rm -f -- "$stats" "$seen"; rmdir "$tmpdir"; return 1; }
  # shellcheck disable=SC2094 # 실패 시 정리하는 입력 파일은 루프에서 쓰지 않는다.
  while IFS= read -r -d '' record; do
    add="${record%%$'\t'*}"; rest="${record#*$'\t'}"; del="${rest%%$'\t'*}"
    path="${rest#*$'\t'}"
    case "$add/$del" in *[!0-9/]*|'/'*) continue;; esac
    if [ -L "$project_root/$path" ]; then continue; fi
    if [ ! -e "$project_root/$path" ]; then
      mode="$(git -C "$project_root" ls-files -s -- "$path" 2>/dev/null)" \
        || { rm -f -- "$stats" "$seen"; rmdir "$tmpdir"; return 1; }
      [ -n "$mode" ] || mode="$(git -C "$project_root" ls-tree HEAD -- "$path" 2>/dev/null)" \
        || { rm -f -- "$stats" "$seen"; rmdir "$tmpdir"; return 1; }
      case "$mode" in 100[0-9][0-9]*$'\t'*|100[0-9][0-9]*' '*) :;; *) continue;; esac
    elif [ ! -f "$project_root/$path" ]; then
      continue
    fi
    path_hash="$(printf '%s' "$path" | sha256_stdin)" \
      || { rm -f -- "$stats" "$seen"; rmdir "$tmpdir"; return 1; }
    printf '%s\n' "$path_hash" >> "$seen" \
      || { rm -f -- "$stats" "$seen"; rmdir "$tmpdir"; return 1; }
    lines=$((lines + add + del))
  done < "$stats"
  git -C "$project_root" ls-files --others --exclude-standard -z > "$untracked" \
    || { rm -f -- "$stats" "$untracked" "$seen"; rmdir "$tmpdir"; return 1; }
  # shellcheck disable=SC2094 # 실패 시 정리하는 입력 파일은 루프에서 쓰지 않는다.
  while IFS= read -r -d '' path; do
    [ -f "$project_root/$path" ] && [ ! -L "$project_root/$path" ] || continue
    if [ -s "$project_root/$path" ] && ! LC_ALL=C grep -Iq '' "$project_root/$path"; then
      continue
    fi
    path_hash="$(printf '%s' "$path" | sha256_stdin)" \
      || { rm -f -- "$stats" "$untracked" "$seen"; rmdir "$tmpdir"; return 1; }
    printf '%s\n' "$path_hash" >> "$seen" \
      || { rm -f -- "$stats" "$untracked" "$seen"; rmdir "$tmpdir"; return 1; }
    logical="$(context_logical_line_count "$project_root/$path")" \
      || { rm -f -- "$stats" "$untracked" "$seen"; rmdir "$tmpdir"; return 1; }
    lines=$((lines + logical))
  done < "$untracked"
  sort -u "$seen" > "$unique" \
    || { rm -f -- "$stats" "$untracked" "$seen" "$unique"; rmdir "$tmpdir"; return 1; }
  files="$(awk 'END { print NR + 0 }' "$unique")" \
    || { rm -f -- "$stats" "$untracked" "$seen" "$unique"; rmdir "$tmpdir"; return 1; }
  BUDGET_CHANGED_FILES="$files" BUDGET_CHANGED_LINES="$lines"
  rm -f -- "$stats" "$untracked" "$seen" "$unique"; rmdir "$tmpdir"
}

budget_runs_state() {
  local project_root="$1" task_id="$2" committed tmp result committed_ref
  local runs="$project_root/log/$task_id.runs"
  [ -e "$runs" ] || { BUDGET_RUNS=0 BUDGET_ACTIVE=0; return 0; }
  [ -f "$runs" ] || return 1
  committed="$(mktemp "${TMPDIR:-/tmp}/agent-harness-runs.XXXXXX")" || return 1
  committed_ref="$(git -C "$project_root" ls-tree HEAD -- "log/$task_id.runs" 2>/dev/null)" \
    || { rm -f -- "$committed"; BUDGET_REASON=committed_evidence; return 1; }
  if [ -n "$committed_ref" ]; then
    git -C "$project_root" show "HEAD:log/$task_id.runs" > "$committed" || { rm -f -- "$committed"; return 1; }
    awk 'NR == FNR { prefix[NR] = $0; count = NR; next }
         FNR <= count && $0 != prefix[FNR] { exit 1 }
         END { if (FNR < count) exit 1 }' "$committed" "$runs" \
      || { rm -f -- "$committed"; BUDGET_REASON=committed_prefix; return 1; }
  fi
  result="$(awk '
    function bad(){ exit 2 }
    /^run_id: [A-Za-z0-9._-]+ event: (budget_reserved|dispatched|started|finished|aborted) / {
      id=$2; event=$4
      if (event == "budget_reserved") { if (id in state) bad(); state[id]="reserved"; runs++; next }
      if (event == "dispatched") { if (!(id in state)) { state[id]="dispatched"; runs++ } else if (state[id] != "reserved") bad(); else state[id]="dispatched"; next }
      if (!(id in state)) bad()
      if (event == "started") { if (state[id] != "reserved" && state[id] != "dispatched") bad(); state[id]="started"; next }
      if (event == "finished" || event == "aborted") { if (state[id] == "finished" || state[id] == "aborted") bad(); state[id]=event; next }
      bad()
    }
    { bad() }
    END { active=0; for (id in state) if (state[id] != "finished" && state[id] != "aborted") active++; print runs " " active }
  ' "$runs")" || { rm -f -- "$committed"; BUDGET_REASON=malformed; return 1; }
  rm -f -- "$committed"
  BUDGET_RUNS="${result%% *}" BUDGET_ACTIVE="${result##* }"
}

budget_assert_dispatch() {
  local tasks="$1" task_id="$2" project_root="$3" model_limit active_limit files_limit lines_limit
  [ -e "$project_root/log/$task_id.budget-stop.yaml" ] && { BUDGET_REASON=existing_stop; return 1; }
  BUDGET_REASON=evidence; budget_runs_state "$project_root" "$task_id" || return 1
  model_limit="$(task_value "$tasks" "$task_id" '.budget.model_runs')"; active_limit="$(task_value "$tasks" "$task_id" '.budget.concurrent_workers')"
  if [ "$BUDGET_RUNS" -ge "$model_limit" ]; then BUDGET_REASON=model_runs; BUDGET_MEASURED="$BUDGET_RUNS"; BUDGET_LIMIT="$model_limit"; return 1; fi
  if [ "$BUDGET_ACTIVE" -ge "$active_limit" ]; then BUDGET_REASON=concurrent_workers; BUDGET_MEASURED="$BUDGET_ACTIVE"; BUDGET_LIMIT="$active_limit"; return 1; fi
  budget_changed_metrics "$project_root" || { BUDGET_REASON=changed_metrics; BUDGET_MEASURED=1; BUDGET_LIMIT=1; return 1; }
  files_limit="$(task_value "$tasks" "$task_id" '.budget.changed_files')"; lines_limit="$(task_value "$tasks" "$task_id" '.budget.changed_lines')"
  if [ "$BUDGET_CHANGED_FILES" -gt "$files_limit" ]; then BUDGET_REASON=changed_files; BUDGET_MEASURED="$BUDGET_CHANGED_FILES"; BUDGET_LIMIT="$files_limit"; return 1; fi
  if [ "$BUDGET_CHANGED_LINES" -gt "$lines_limit" ]; then BUDGET_REASON=changed_lines; BUDGET_MEASURED="$BUDGET_CHANGED_LINES"; BUDGET_LIMIT="$lines_limit"; return 1; fi
}

budget_assert_verification() {
  local tasks="$1" task_id="$2" scope="$3" project_root="$4"
  local limit count files_limit lines_limit dir intent result itask iscope ireceipt iinput icommand ienvironment ihash rihash order receipt_path raw_path receipt_sha raw_sha committed_paths committed_path
  local rattempt rreceipt rstarted rfinished rexit rstatus ptask pscope pinput pcommand penvironment pstarted pfinished pexit praw pstdout digest
  [ -e "$project_root/log/$task_id.budget-stop.yaml" ] && { BUDGET_REASON=existing_stop; return 1; }
  case "$scope" in related) limit="$(task_value "$tasks" "$task_id" '.budget.related_test_runs')";;
    full) limit="$(task_value "$tasks" "$task_id" '.budget.full_test_runs')";;
    *) return 0;;
  esac
  dir="$project_root/log/verification-attempts/$task_id"
  count=0; order=0
  if [ -e "$dir" ] && [ ! -d "$dir" ]; then BUDGET_REASON=attempt_evidence; return 1; fi
  committed_paths="$(git -C "$project_root" ls-tree -r --name-only HEAD -- "log/verification-attempts/$task_id" 2>/dev/null)" \
    || { BUDGET_REASON=attempt_evidence; return 1; }
  while IFS= read -r committed_path; do
    [ -n "$committed_path" ] || continue
    git -C "$project_root" diff --quiet HEAD -- "$committed_path" \
      || { BUDGET_REASON=attempt_evidence; return 1; }
  done <<< "$committed_paths"
  for intent in "$dir"/*.intent.yaml; do
    [ -e "$intent" ] || continue
    itask="$(yq -r '.task // ""' "$intent" 2>/dev/null)" || { BUDGET_REASON=attempt_evidence; return 1; }
    iscope="$(yq -r '.scope // ""' "$intent" 2>/dev/null)" || { BUDGET_REASON=attempt_evidence; return 1; }
    order=$((order + 1))
    [ "$(basename "$intent" .intent.yaml)" = "$(printf '%06d' "$order")" ] || { BUDGET_REASON=attempt_evidence; return 1; }
    [ "$(yq -r '.attempt // ""' "$intent" 2>/dev/null)" = "$order" ] || { BUDGET_REASON=attempt_evidence; return 1; }
    [ "$itask" = "$task_id" ] || { BUDGET_REASON=attempt_evidence; return 1; }
    ireceipt="$(yq -r '.receipt_id // ""' "$intent" 2>/dev/null)" || { BUDGET_REASON=attempt_evidence; return 1; }
    iinput="$(yq -r '.input_sha256 // ""' "$intent" 2>/dev/null)" || { BUDGET_REASON=attempt_evidence; return 1; }
    icommand="$(yq -r '.command_sha256 // ""' "$intent" 2>/dev/null)" || { BUDGET_REASON=attempt_evidence; return 1; }
    ienvironment="$(yq -r '.environment_sha256 // ""' "$intent" 2>/dev/null)" || { BUDGET_REASON=attempt_evidence; return 1; }
    valid_task_id "$ireceipt" || { BUDGET_REASON=attempt_evidence; return 1; }
    for digest in "$iinput" "$icommand" "$ienvironment"; do
      printf '%s\n' "$digest" | grep -Eq '^[0-9a-f]{64}$' || { BUDGET_REASON=attempt_evidence; return 1; }
    done
    case "$iscope" in related|full) ;; *) BUDGET_REASON=attempt_evidence; return 1;; esac
    [ "$iscope" = "$scope" ] && count=$((count + 1))
    result="${intent%.intent.yaml}.result.yaml"
    [ -f "$result" ] || { BUDGET_REASON=attempt_evidence; return 1; }
    ihash="$(sha256_file "$intent")" || { BUDGET_REASON=attempt_evidence; return 1; }
    rihash="$(yq -r '.intent_sha256 // ""' "$result" 2>/dev/null)" || { BUDGET_REASON=attempt_evidence; return 1; }
    [ "$rihash" = "$ihash" ] || { BUDGET_REASON=attempt_evidence; return 1; }
    [ "$(yq -r '.task // ""' "$result")" = "$task_id" ] && [ "$(yq -r '.scope // ""' "$result")" = "$iscope" ] || { BUDGET_REASON=attempt_evidence; return 1; }
    rattempt="$(yq -r '.attempt // ""' "$result")"; rreceipt="$(yq -r '.receipt_id // ""' "$result")"
    [ "$rattempt" = "$order" ] && [ "$rreceipt" = "$ireceipt" ] || { BUDGET_REASON=attempt_evidence; return 1; }
    rstarted="$(yq -r '.started_at // ""' "$result")"; rfinished="$(yq -r '.finished_at // ""' "$result")"
    if ! printf '%s\n' "$rstarted" | grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' \
      || ! printf '%s\n' "$rfinished" | grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'; then
      BUDGET_REASON=attempt_evidence
      return 1
    fi
    rexit="$(yq -r '.exit_code // ""' "$result")"; rstatus="$(yq -r '.status // ""' "$result")"
    case "$rexit/$rstatus" in 0/success|[1-9]/failure|[1-9][0-9]*/failure) ;; *) BUDGET_REASON=attempt_evidence; return 1;; esac
    receipt_path="$(yq -r '.receipt_path // ""' "$result")"; raw_path="$(yq -r '.raw_log // ""' "$result")"
    case "$receipt_path" in log/receipts/*) ;; *) BUDGET_REASON=attempt_evidence; return 1;; esac
    case "$raw_path" in log/cold/verification/*) ;; *) BUDGET_REASON=attempt_evidence; return 1;; esac
    case "$receipt_path" in *..*|*'|'*) BUDGET_REASON=attempt_evidence; return 1;; esac
    case "$raw_path" in *..*|*'|'*) BUDGET_REASON=attempt_evidence; return 1;; esac
    case "${receipt_path#log/receipts/}" in "$ireceipt"-*.yaml) ;; *) BUDGET_REASON=attempt_evidence; return 1;; esac
    receipt_sha="$(yq -r '.receipt_sha256 // ""' "$result")"; raw_sha="$(yq -r '.raw_log_sha256 // ""' "$result")"
    [ -f "$project_root/$receipt_path" ] && [ -f "$project_root/$raw_path" ] || { BUDGET_REASON=attempt_evidence; return 1; }
    [ "$(yq -r '.receipt_id // ""' "$project_root/$receipt_path" 2>/dev/null)" = "$ireceipt" ] || { BUDGET_REASON=attempt_evidence; return 1; }
    [ "$(sha256_file "$project_root/$receipt_path")" = "$receipt_sha" ] && [ "$(sha256_file "$project_root/$raw_path")" = "$raw_sha" ] || { BUDGET_REASON=attempt_evidence; return 1; }
    ptask="$(yq -r '.task // ""' "$project_root/$receipt_path")"; pscope="$(yq -r '.scope // ""' "$project_root/$receipt_path")"
    pinput="$(yq -r '.input_sha256 // ""' "$project_root/$receipt_path")"; pcommand="$(yq -r '.command_sha256 // ""' "$project_root/$receipt_path")"
    penvironment="$(yq -r '.environment_sha256 // ""' "$project_root/$receipt_path")"
    pstarted="$(yq -r '.started_at // ""' "$project_root/$receipt_path")"; pfinished="$(yq -r '.finished_at // ""' "$project_root/$receipt_path")"
    pexit="$(yq -r '.exit_code // ""' "$project_root/$receipt_path")"; praw="$(yq -r '.raw_log // ""' "$project_root/$receipt_path")"
    pstdout="$(yq -r '.stdout_sha256 // ""' "$project_root/$receipt_path")"
    [ "$ptask" = "$itask" ] && [ "$pscope" = "$iscope" ] \
      && [ "$pinput" = "$iinput" ] && [ "$pcommand" = "$icommand" ] && [ "$penvironment" = "$ienvironment" ] \
      && [ "$pstarted" = "$rstarted" ] && [ "$pfinished" = "$rfinished" ] && [ "$pexit" = "$rexit" ] \
      && [ "$praw" = "$raw_path" ] && [ "$pstdout" = "$raw_sha" ] \
      || { BUDGET_REASON=attempt_evidence; return 1; }
  done
  for result in "$dir"/*.result.yaml; do
    [ -e "$result" ] || continue
    intent="${result%.result.yaml}.intent.yaml"
    [ -f "$intent" ] || { BUDGET_REASON=attempt_evidence; return 1; }
  done
  [ "$count" -le "$limit" ] || { BUDGET_REASON="${scope}_test_runs"; BUDGET_MEASURED="$count"; BUDGET_LIMIT="$limit"; return 1; }
  # shellcheck disable=SC2034 # verify-cache.sh가 source 후 읽는 함수 결과다.
  BUDGET_VERIFICATION_COUNT="$count" BUDGET_VERIFICATION_LIMIT="$limit"
  budget_changed_metrics "$project_root" || { BUDGET_REASON=changed_metrics; BUDGET_MEASURED=1; BUDGET_LIMIT=1; return 1; }
  files_limit="$(task_value "$tasks" "$task_id" '.budget.changed_files')"; lines_limit="$(task_value "$tasks" "$task_id" '.budget.changed_lines')"
  [ "$BUDGET_CHANGED_FILES" -le "$files_limit" ] || { BUDGET_REASON=changed_files; BUDGET_MEASURED="$BUDGET_CHANGED_FILES"; BUDGET_LIMIT="$files_limit"; return 1; }
  [ "$BUDGET_CHANGED_LINES" -le "$lines_limit" ] || { BUDGET_REASON=changed_lines; BUDGET_MEASURED="$BUDGET_CHANGED_LINES"; BUDGET_LIMIT="$lines_limit"; return 1; }
}

publish_verification_intent() {
  local project_root="$1" task_id="$2" scope="$3" attempt="$4" input_sha="$5" command_sha="$6" environment_sha="$7" receipt_id="$8" dir tmp path
  dir="$project_root/log/verification-attempts/$task_id"; mkdir -p "$dir" || return 1
  path="$dir/$(printf '%06d' "$attempt").intent.yaml"
  tmp="$(mktemp "$dir/.intent.XXXXXX")" || return 1
  printf 'version: 1\ntask: %s\nscope: %s\nattempt: %s\nreceipt_id: %s\ninput_sha256: %s\ncommand_sha256: %s\nenvironment_sha256: %s\n' "$task_id" "$scope" "$attempt" "$receipt_id" "$input_sha" "$command_sha" "$environment_sha" > "$tmp" || return 1
  ln "$tmp" "$path" 2>/dev/null || { rm -f "$tmp"; return 1; }; rm -f "$tmp"
  # shellcheck disable=SC2034 # verify-cache.sh가 source 후 읽는 함수 결과다.
  VERIFICATION_INTENT_PATH="$path" VERIFICATION_INTENT_SHA256="$(sha256_file "$path")"
}

publish_verification_result() {
  local path="$1" intent_sha="$2" receipt_sha="$3" raw_sha="$4" exit_code="$5" tmp
  local receipt_path="$6" raw_path="$7" started_at="$8" finished_at="$9" result_path status
  result_path="${path%.intent.yaml}.result.yaml"
  if [ "$exit_code" = 0 ]; then status=success; else status=failure; fi
  tmp="$(mktemp "${path%.intent.yaml}.result.XXXXXX")" || return 1
  {
    printf 'version: 1\n'
    printf 'task: %s\n' "$(yq -r '.task' "$path")"
    printf 'scope: %s\n' "$(yq -r '.scope' "$path")"
    printf 'attempt: %s\n' "$(yq -r '.attempt' "$path")"
    printf 'receipt_id: %s\n' "$(yq -r '.receipt_id' "$path")"
    printf 'intent_sha256: %s\n' "$intent_sha"
    printf 'started_at: %s\n' "$started_at"
    printf 'finished_at: %s\n' "$finished_at"
    printf 'status: %s\n' "$status"
    printf 'receipt_path: %s\n' "$receipt_path"
    printf 'raw_log: %s\n' "$raw_path"
    printf 'receipt_sha256: %s\n' "$receipt_sha"
    printf 'raw_log_sha256: %s\n' "$raw_sha"
    printf 'exit_code: %s\n' "$exit_code"
  } > "$tmp" || return 1
  ln "$tmp" "$result_path" 2>/dev/null || { rm -f "$tmp"; return 1; }
  rm -f "$tmp"
}

budget_lock_acquire() {
  local lock="$1" owner="$2" marker="$1/.owner-$2" attempt=0
  until mkdir "$lock" 2>/dev/null; do
    attempt=$((attempt + 1))
    [ "$attempt" -lt 100 ] || return 1
    sleep 0.01
  done
  printf '%s\n' "$owner" > "$marker" || { rmdir "$lock" 2>/dev/null || true; return 1; }
}

budget_lock_release() {
  local lock="$1" owner="$2" marker="$1/.owner-$2"
  [ -f "$marker" ] && [ "$(cat "$marker")" = "$owner" ] || return 1
  rm -f -- "$marker" || return 1
  rmdir "$lock"
}

reserve_dispatch_run() {
  local tasks="$1" task_id="$2" project_root="$3" run_id="$4" lock owner
  lock="$project_root/log/.locks/$task_id.dispatch"
  owner="$run_id.reserve.$$"
  mkdir -p "$project_root/log/.locks" || return 1
  budget_lock_acquire "$lock" "$owner" || {
    BUDGET_REASON=lock_timeout BUDGET_MEASURED=1 BUDGET_LIMIT=1
    write_budget_stop "$task_id" dispatch "$project_root" "$BUDGET_MEASURED" "$BUDGET_LIMIT" "$BUDGET_REASON" ambiguous
    return 1
  }
  if ! budget_assert_dispatch "$tasks" "$task_id" "$project_root"; then
    [ "${BUDGET_REASON:-}" = existing_stop ] || write_budget_stop "$task_id" dispatch "$project_root" "${BUDGET_MEASURED:-1}" "${BUDGET_LIMIT:-1}" "$BUDGET_REASON" ambiguous
    budget_lock_release "$lock" "$owner" || true
    return 1
  fi
  printf 'run_id: %s event: budget_reserved at: %s\n' "$run_id" "$(utc_now)" >> "$project_root/log/$task_id.runs" \
    || { budget_lock_release "$lock" "$owner" || true; return 1; }
  budget_lock_release "$lock" "$owner"
}

abort_dispatch_run() {
  local task_id="$1" project_root="$2" run_id="$3" lock owner
  lock="$project_root/log/.locks/$task_id.dispatch"
  owner="$run_id.abort.$$"
  if ! budget_lock_acquire "$lock" "$owner"; then
    write_budget_stop "$task_id" dispatch "$project_root" 1 1 abort_lock_timeout ambiguous
    return 1
  fi
  printf 'run_id: %s event: aborted at: %s\n' "$run_id" "$(utc_now)" >> "$project_root/log/$task_id.runs" \
    || { budget_lock_release "$lock" "$owner" || true; return 1; }
  budget_lock_release "$lock" "$owner"
}

# nul_sha256 <value...> — arguments are unambiguously serialized without eval or joining.
nul_sha256() {
  local value
  for value in "$@"; do printf '%s\0' "$value"; done | sha256_stdin
}

# workspace_tree_sha256 <project-root> — hashes a temporary-index tree while excluding receipts.
workspace_tree_sha256() (
  local project_root="$1" index tree path
  index="$(mktemp "${TMPDIR:-/tmp}/agent-harness-index.XXXXXX")" || die "임시 Git index 생성 실패"
  # shellcheck disable=SC2064 # index 경로를 지역 범위가 살아 있을 때 trap에 고정한다.
  trap "rm -f -- $(printf '%q' "$index")" EXIT
  git -C "$project_root" rev-parse --is-inside-work-tree >/dev/null \
    || die "Git 프로젝트가 아닙니다: $project_root"
  GIT_INDEX_FILE="$index" git -C "$project_root" read-tree HEAD
  GIT_INDEX_FILE="$index" git -C "$project_root" add -u -- .
  GIT_INDEX_FILE="$index" git -C "$project_root" rm -r --cached --ignore-unmatch -- \
    log/cold log/receipts log/verification-attempts >/dev/null
  while IFS= read -r -d '' path; do
    case "$path" in
      log/cold/*|log/receipts/*|log/verification-attempts/*) ;;
      *) GIT_INDEX_FILE="$index" git -C "$project_root" add -- "$path" ;;
    esac
  done < <(git -C "$project_root" ls-files --others --exclude-standard -z)
  tree="$(GIT_INDEX_FILE="$index" git -C "$project_root" write-tree)" \
    || die "임시 Git tree 생성 실패"
  printf '%s\0' "$tree" | sha256_stdin
)

# verification_environment_sha256 <command> [declared-env-name...]
# 선언한 환경 변수만 이름·set/unset 상태·값 전체로 fingerprint에 포함한다.
verification_environment_sha256() {
  local command="$1" command_path executable_sha env_name env_value
  local -a fingerprint
  shift
  command_path="$(command -v "$command" 2>/dev/null || true)"
  executable_sha=unknown
  if [ -n "$command_path" ] && [ -f "$command_path" ]; then
    executable_sha="$(sha256_file "$command_path")"
  fi
  fingerprint=(
    "os=$(uname -s 2>/dev/null || printf unknown)"
    "architecture=$(uname -m 2>/dev/null || printf unknown)"
    "bash=${BASH_VERSION:-unknown}"
    "git=$(git --version 2>/dev/null || printf unknown)"
    "yq=$(yq --version 2>/dev/null || printf unknown)"
    "command_path=${command_path:-unknown}"
    "executable_sha256=$executable_sha"
  )
  if [ "$#" -gt 0 ]; then
    while IFS= read -r env_name; do
      if [ "${!env_name+x}" = x ]; then
        env_value="${!env_name}"
        fingerprint+=("declared_env_name=$env_name" "declared_env_state=set" "declared_env_value=$env_value")
      else
        fingerprint+=("declared_env_name=$env_name" "declared_env_state=unset")
      fi
    done < <(printf '%s\n' "$@" | LC_ALL=C sort -u)
  fi
  nul_sha256 "${fingerprint[@]}"
}
