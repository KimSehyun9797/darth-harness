#!/usr/bin/env bash
# Project-local agent-harness state contract. macOS Bash 3.2 compatible.
set -euo pipefail

STATE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$STATE_LIB_DIR/../.." && pwd -P)"

state_fail() { echo "ERROR: $*" >&2; return 1; }
need_state_cmd() { command -v "$1" >/dev/null 2>&1 || state_fail "'$1' 필요"; }

sha256_file() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
  else state_fail "SHA-256 도구(shasum 또는 sha256sum) 필요"; fi
}

provider_config_path() {
  case "$1" in
    claude) echo '.claude/settings.json';;
    codex) echo '.codex/hooks.json';;
    *) state_fail "provider는 claude|codex";;
  esac
}

provider_version() {
  if [ -n "${HARNESS_CLIENT_VERSION:-}" ]; then printf '%s\n' "$HARNESS_CLIENT_VERSION"
  else "$1" --version | head -1; fi
}

native_smoke_nonce_sha256() {
  local nonce="${HARNESS_NATIVE_SMOKE_NONCE:-}"
  printf '%s' "$nonce" | grep -Eq '^[A-Za-z0-9._~-]{16,128}$' || return 1
  printf '%s' "$nonce" | { if command -v shasum >/dev/null 2>&1; then shasum -a 256; else sha256sum; fi; } | awk '{print $1}'
}

provider_ready() {
  local provider="$1" pass_rel pass config
  pass_rel="log/hook-smoke-$provider.pass"
  pass="$PROJECT_ROOT/$pass_rel"
  config="$(provider_config_path "$provider")"
  [ -f "$pass" ] && [ -f "$PROJECT_ROOT/$config" ] \
    && [ -f "$PROJECT_ROOT/.harness/bin/decision-hook" ] || return 1
  git -C "$PROJECT_ROOT" ls-files --error-unmatch "$pass_rel" >/dev/null 2>&1 \
    && git -C "$PROJECT_ROOT" diff --quiet HEAD -- "$pass_rel" || return 1
  [ "$(yq -r '.version // 0' "$pass")" = 1 ] \
    && [ "$(yq -r '.provider // ""' "$pass")" = "$provider" ] \
    && [ "$(yq -r '.client_version // ""' "$pass")" = "$(provider_version "$provider")" ] \
    && [ "$(yq -r '.config_sha256 // ""' "$pass")" = "$(sha256_file "$PROJECT_ROOT/$config")" ] \
    && [ "$(yq -r '.hook_sha256 // ""' "$pass")" = "$(sha256_file "$PROJECT_ROOT/.harness/bin/decision-hook")" ] \
    && printf '%s' "$(yq -r '.nonce_sha256 // ""' "$pass")" | grep -Eq '^[0-9a-f]{64}$'
}

require_provider_ready() {
  provider_ready "$1" || state_fail "$1 native hook smoke PASS가 없거나 현재 hook hash와 다릅니다"
}

decode_base64() {
  if printf '' | base64 -D >/dev/null 2>&1; then base64 -D
  else base64 -d; fi
}

section_body() {
  local file="$1" heading="$2"
  awk -v h="$heading" '
    $0 == h {inside=1; next}
    inside && /^## / {exit}
    inside {print}
  ' "$file"
}

assert_index_clean() {
  [ -z "$(git -C "$PROJECT_ROOT" diff --cached --name-only)" ] \
    || state_fail "기존 staged 변경이 있어 자동 커밋을 거부합니다"
}

assert_commit_noninteractive() {
  [ "$(git -C "$PROJECT_ROOT" config --bool commit.gpgsign 2>/dev/null || echo false)" != true ] \
    || state_fail "commit.gpgsign=true: 훅에서 서명 정책을 우회하지 않습니다; 비대화형 서명 구성을 먼저 결정하세요"
}

runs_finished_ok() { # $1=태스크ID $2=run_id — finished(exit_code 0) 사건 존재 확인 (B-001)
  local runs="$PROJECT_ROOT/log/$1.runs"
  [ -f "$runs" ] || return 1
  awk -v wanted="$2" '
    $3 == "event:" && $4 == "dispatched" {
      rid=$2; started=0; finished=0; exit_code=""; next
    }
    $2 == rid && $3 == "event:" && $4 == "started"  {started=1}
    $2 == rid && $3 == "event:" && $4 == "finished" {finished=1; exit_code=$8}
    END {exit rid == wanted && started && finished && exit_code == "0" ? 0 : 1}
  ' "$runs"
}

rfc3339_utc() { printf '%s' "$1" | grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'; }

path_is_core_state() {
  local path="$1" id=""
  case "$path" in STATUS.md|tasks.yaml|log/HANDOFF.md) return 0;; esac
  case "$path" in
    log/*.verified.yaml) id="${path#log/}"; id="${id%.verified.yaml}";;
    log/*.verify.log) id="${path#log/}"; id="${id%.verify.log}";;
    log/receipts/*.yaml) return 0;;
    log/*.budget-stop.yaml)
      id="${path#log/}"; id="${id%.budget-stop.yaml}"
      TASK_ID="$id" yq -e '.tasks[] | select(.id == strenv(TASK_ID))' \
        "$PROJECT_ROOT/tasks.yaml" >/dev/null 2>&1
      return
      ;;
    log/verification-attempts/*/*)
      printf '%s' "$path" | grep -Eq '^log/verification-attempts/[A-Za-z0-9._-]+/[0-9]{6}\.(intent|result)\.yaml$' \
        || return 1
      id="${path#log/verification-attempts/}"; id="${id%%/*}"
      ;;
    *) return 1;;
  esac
  TASK_ID="$id" yq -e '.tasks[] | select(.id == strenv(TASK_ID) and .status == "verified")' \
    "$PROJECT_ROOT/tasks.yaml" >/dev/null 2>&1
}

path_is_open_state() {
  local path="$1" id="$2"
  path_is_core_state "$path" && return 0
  case "$path" in
    log/pending-decision.yaml|log/decisions/"$id".request.md) return 0;;
  esac
  return 1
}

assert_changes_match() {
  local mode="$1" id="${2:-}" line path bad=""
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    path="${line#???}"
    case "$path" in *' -> '*) path="${path##* -> }";; esac
    if [ "$mode" = core ]; then
      path_is_core_state "$path" || bad="$bad $path"
    else
      path_is_open_state "$path" "$id" || bad="$bad $path"
    fi
  done <<EOF
$(git -C "$PROJECT_ROOT" status --porcelain --untracked-files=all)
EOF
  [ -z "$bad" ] || state_fail "허용 목록 밖 변경:$bad"
}

assert_core_only() { assert_changes_match core; }
assert_open_only() { assert_changes_match open "$1"; }

validate_state() {
  local mode="${1:-committed}" f id status marker artifact req ans pstatus n duplicates opened base status_phase handoff_phase run_id marker_run_id vy
  local contract_version decision
  need_state_cmd git; need_state_cmd yq
  [ "$(git -C "$PROJECT_ROOT" rev-parse --show-toplevel)" = "$PROJECT_ROOT" ] \
    || state_fail "프로젝트 Git 루트에서 실행해야 합니다"
  for f in STATUS.md tasks.yaml log/HANDOFF.md; do
    [ -f "$PROJECT_ROOT/$f" ] || state_fail "$f 없음"
  done
  [ -d "$PROJECT_ROOT/log/decisions" ] || state_fail "log/decisions 없음"
  for f in STATUS.md log/HANDOFF.md; do
    ! grep -q '{{' "$PROJECT_ROOT/$f" || state_fail "$f 플레이스홀더 잔존"
  done
  status_phase="$(awk '/^\*\*현재 단계:\*\*/ {sub(/^\*\*현재 단계:\*\* /, ""); sub(/ · .*/, ""); print; exit}' "$PROJECT_ROOT/STATUS.md")"
  handoff_phase="$(awk '/^\*\*현재 단계:\*\*/ {sub(/^\*\*현재 단계:\*\* /, ""); print; exit}' "$PROJECT_ROOT/log/HANDOFF.md")"
  [ -n "$status_phase" ] && [ "$status_phase" = "$handoff_phase" ] || state_fail "STATUS/HANDOFF 현재 단계 불일치"
  yq -e '.tasks' "$PROJECT_ROOT/tasks.yaml" >/dev/null 2>&1 \
    || state_fail "tasks.yaml 파싱 실패"
  contract_version="$(yq -r '.contract_version // ""' "$PROJECT_ROOT/tasks.yaml")"
  duplicates="$(yq -r '.tasks[].id' "$PROJECT_ROOT/tasks.yaml" | sort | uniq -d)"
  [ -z "$duplicates" ] || state_fail "중복 task id: $duplicates"
  n="$(yq -r '.tasks | length' "$PROJECT_ROOT/tasks.yaml")"
  if [ "$n" -gt 0 ]; then
    for id in $(yq -r '.tasks[].id' "$PROJECT_ROOT/tasks.yaml"); do
      printf '%s' "$id" | grep -Eq '^[A-Za-z0-9._-]+$' \
        || state_fail "안전하지 않은 task id: $id"
      status="$(yq -r ".tasks[] | select(.id == \"$id\") | .status" "$PROJECT_ROOT/tasks.yaml")"
      run_id="$(yq -r ".tasks[] | select(.id == \"$id\") | .run_id // \"\"" "$PROJECT_ROOT/tasks.yaml")"
      decision="$(yq -r ".tasks[] | select(.id == \"$id\") | .lean_gate.decision // \"\"" "$PROJECT_ROOT/tasks.yaml")"
      if [ "$contract_version" = 3 ]; then
        if [ "$decision" = not-needed ]; then
          [ "$status" = skipped ] || state_fail "$id: not-needed 작업은 skipped여야 함"
        elif [ "$status" = skipped ]; then
          state_fail "$id: skipped 작업의 Lean Gate 결론은 not-needed여야 함"
        fi
      fi
      case "$status" in
        running|done|verified)
          printf '%s' "$run_id" | grep -Eq '^[A-Za-z0-9._-]+$' || state_fail "$id: $status인데 안전한 run_id 없음";;
      esac
      case "$status" in
        done|verified)
          [ -f "$PROJECT_ROOT/log/$id.done" ] || state_fail "$id: $status인데 .done 없음"
          marker="$(yq -r '.status // ""' "$PROJECT_ROOT/log/$id.done")"
          marker_run_id="$(yq -r '.run_id // ""' "$PROJECT_ROOT/log/$id.done")"
          [ "$marker" = DONE ] \
            || state_fail "$id: .done status는 DONE이어야 함(marker=$marker) — VERIFIED 덮어쓰기는 B-001 계약 위반"
          [ -n "$marker_run_id" ] && [ "$run_id" = "$marker_run_id" ] \
            || state_fail "$id: tasks와 .done run_id 불일치"
          artifact="$(yq -r '.artifact // ""' "$PROJECT_ROOT/log/$id.done")"
          case "$artifact" in ""|/*|..|../*|*/../*|*/..) state_fail "$id: .done artifact는 프로젝트 내부 상대 경로여야 함";; esac
          [ -f "$PROJECT_ROOT/$artifact" ] || state_fail "$id: .done artifact 파일 없음: $artifact"
          runs_finished_ok "$id" "$run_id" \
            || state_fail "$id: .runs에 run_id $run_id의 finished(exit_code 0) 사건 없음"
          if [ "$status" = verified ]; then
            vy="$PROJECT_ROOT/log/$id.verified.yaml"
            [ -f "$vy" ] || state_fail "$id: verified인데 .verified.yaml 없음"
            [ "$(yq -r '.version // 0' "$vy")" = 1 ] || state_fail "$id: verified.yaml version은 1이어야 함"
            [ "$(yq -r '.task // ""' "$vy")" = "$id" ] || state_fail "$id: verified.yaml task 불일치"
            [ "$(yq -r '.run_id // ""' "$vy")" = "$run_id" ] || state_fail "$id: verified.yaml run_id 불일치"
            [ "$(yq -r '.done_sha256 // ""' "$vy")" = "$(sha256_file "$PROJECT_ROOT/log/$id.done")" ] \
              || state_fail "$id: .done 사후 변조 감지(done_sha256 불일치)"
            rfc3339_utc "$(yq -r '.verified_at // ""' "$vy")" || state_fail "$id: verified_at은 UTC RFC3339여야 함"
            [ "$(yq -r '.verify_exit_code // 1' "$vy")" = 0 ] || state_fail "$id: verify_exit_code는 0이어야 함"
            yq -r '.stdout_sha256 // ""' "$vy" | grep -Eq '^[0-9a-f]{64}$' \
              || state_fail "$id: stdout_sha256 형식 오류"
            receipt="$(yq -r '.verification_receipt // ""' "$vy")"
            printf '%s' "$receipt" | grep -Eq '^log/receipts/[A-Za-z0-9._-]+\.yaml$' \
              || state_fail "$id: verification_receipt 경로 오류"
            receipt_path="$PROJECT_ROOT/$receipt"
            [ -f "$receipt_path" ] || state_fail "$id: verification_receipt 파일 없음"
            [ "$(yq -r '.version // 0' "$receipt_path")" = 1 ] || state_fail "$id: receipt version 오류"
            [ "$(yq -r '.task // ""' "$receipt_path")" = "$id" ] || state_fail "$id: receipt task 불일치"
            [ "$(yq -r '.exit_code // ""' "$receipt_path")" = "$(yq -r '.verify_exit_code // ""' "$vy")" ] \
              || state_fail "$id: receipt exit_code 불일치"
            [ "$(yq -r '.stdout_sha256 // ""' "$receipt_path")" = "$(yq -r '.stdout_sha256 // ""' "$vy")" ] \
              || state_fail "$id: receipt stdout_sha256 불일치"
            raw_log="$(yq -r '.raw_log // ""' "$receipt_path")"
            [ "$raw_log" = "$(yq -r '.verify_log // ""' "$vy")" ] \
              || state_fail "$id: receipt raw_log 불일치"
            [ -f "$PROJECT_ROOT/$raw_log" ] || state_fail "$id: verify_log 파일 없음"
            [ "$(sha256_file "$PROJECT_ROOT/$raw_log")" = "$(yq -r '.stdout_sha256 // ""' "$vy")" ] \
              || state_fail "$id: verify_log SHA-256 불일치"
          fi
          ;;
        skipped)
          [ "$contract_version" = 3 ] || state_fail "$id: skipped는 contract v3에서만 허용됨"
          [ "$decision" = not-needed ] || state_fail "$id: skipped의 Lean Gate 결론은 not-needed여야 함"
          [ -z "$run_id" ] || state_fail "$id: skipped인데 run_id가 존재함"
          for f in \
            "$PROJECT_ROOT/log/$id.done" \
            "$PROJECT_ROOT/log/$id.verified.yaml" \
            "$PROJECT_ROOT/log/$id.verify.log" \
            "$PROJECT_ROOT/log/$id.runs" \
            "$PROJECT_ROOT/log/$id.prompt" \
            "$PROJECT_ROOT/log/$id.log"; do
            [ ! -e "$f" ] || state_fail "$id: skipped인데 실행 증거가 존재함: ${f##*/}"
          done
          ;;
        pending|running|failed|blocked|hold)
          [ ! -f "$PROJECT_ROOT/log/$id.done" ] \
            || state_fail "$id: tasks=${status}인데 .done 존재"
          ;;
        *) state_fail "$id: 허용되지 않은 status=$status";;
      esac
    done
  fi
  for f in "$PROJECT_ROOT"/log/*.done; do
    [ -e "$f" ] || break
    [ "${f##*/}" = smoke.done ] && continue
    id="${f##*/}"; id="${id%.done}"
    yq -e ".tasks[] | select(.id == \"$id\")" "$PROJECT_ROOT/tasks.yaml" >/dev/null 2>&1 \
      || state_fail "태스크 없는 .done: $id"
  done
  if [ -f "$PROJECT_ROOT/log/pending-decision.yaml" ]; then
    pstatus="$(yq -r '.status // ""' "$PROJECT_ROOT/log/pending-decision.yaml")"
    id="$(yq -r '.id // ""' "$PROJECT_ROOT/log/pending-decision.yaml")"
    printf '%s' "$id" | grep -Eq '^D-[0-9]{8}-[0-9]{6}-[0-9]{2}$' \
      || state_fail "잘못된 decision id: $id"
    [ "$(yq -r '.version' "$PROJECT_ROOT/log/pending-decision.yaml")" = 1 ] \
      || state_fail "pending version은 1이어야 함"
    case "$(yq -r '.opened_by' "$PROJECT_ROOT/log/pending-decision.yaml")" in claude|codex) :;; *) state_fail "opened_by 오류";; esac
    opened="$(yq -r '.opened_at // ""' "$PROJECT_ROOT/log/pending-decision.yaml")"
    printf '%s' "$opened" | grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' \
      || state_fail "opened_at은 UTC RFC3339여야 함"
    base="$(yq -r '.checkpoint_base // ""' "$PROJECT_ROOT/log/pending-decision.yaml")"
    printf '%s' "$base" | grep -Eq '^[0-9a-f]{40,64}$' \
      || state_fail "checkpoint_base 형식 오류"
    git -C "$PROJECT_ROOT" cat-file -e "$base^{commit}" 2>/dev/null \
      || state_fail "checkpoint_base commit 없음"
    req="log/decisions/$id.request.md"; ans="log/decisions/$id.answer.md"
    [ "$(yq -r '.request_path' "$PROJECT_ROOT/log/pending-decision.yaml")" = "$req" ] \
      || state_fail "request_path 불일치"
    [ "$(yq -r '.answer_path' "$PROJECT_ROOT/log/pending-decision.yaml")" = "$ans" ] \
      || state_fail "answer_path 불일치"
    [ -f "$PROJECT_ROOT/$req" ] || state_fail "decision request 없음"
    section_body "$PROJECT_ROOT/STATUS.md" '## 다음 사용자 결정' | grep -Fq "결정 ID: $id" \
      || state_fail "STATUS decision id 불일치"
    section_body "$PROJECT_ROOT/log/HANDOFF.md" '## 열린 결정' | grep -Fq "결정 ID: $id" \
      || state_fail "HANDOFF decision id 불일치"
    case "$pstatus" in
      awaiting_answer) [ ! -f "$PROJECT_ROOT/$ans" ] || state_fail "awaiting인데 answer 존재";;
      answer_captured) [ -f "$PROJECT_ROOT/$ans" ] || state_fail "captured인데 answer 없음";;
      *) state_fail "pending status 오류: $pstatus";;
    esac
    if [ "$mode" = committed ]; then
      for f in log/pending-decision.yaml "$req"; do
        git -C "$PROJECT_ROOT" ls-files --error-unmatch "$f" >/dev/null 2>&1 \
          || state_fail "$f Git 추적 없음"
        git -C "$PROJECT_ROOT" diff --quiet HEAD -- "$f" || state_fail "$f HEAD와 불일치"
      done
      if [ "$pstatus" = answer_captured ]; then
        git -C "$PROJECT_ROOT" ls-files --error-unmatch "$ans" >/dev/null 2>&1 \
          || state_fail "$ans Git 추적 없음"
        git -C "$PROJECT_ROOT" diff --quiet HEAD -- "$ans" || state_fail "$ans HEAD와 불일치"
      fi
    fi
  else
    section_body "$PROJECT_ROOT/STATUS.md" '## 다음 사용자 결정' | grep -Fq '(없음)' \
      || state_fail "pending 없지만 STATUS 결정이 열려 있음"
    section_body "$PROJECT_ROOT/log/HANDOFF.md" '## 열린 결정' | grep -Fq '(없음)' \
      || state_fail "pending 없지만 HANDOFF 결정이 열려 있음"
  fi
}

commit_paths() {
  local message="$1"; shift
  assert_commit_noninteractive
  git -C "$PROJECT_ROOT" add -- "$@"
  if ! GIT_TERMINAL_PROMPT=0 git -C "$PROJECT_ROOT" commit -m "$message" -- "$@"; then
    git -C "$PROJECT_ROOT" restore --staged -- "$@" >/dev/null 2>&1 || true
    state_fail "Git 커밋 실패"
  fi
}
