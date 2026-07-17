#!/usr/bin/env bash
# 스캐폴딩 품질 게이트 (결정 32). 프로젝트 루트에서 실행.
# 사용법: scaffold-check.sh [--smoke]
# 통과 시 log/scaffold-check.pass 생성. dispatch.sh는 이 파일 없이는 기동 거부.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/lib.sh
. "$SCRIPT_DIR/lib.sh"
need_yq
P="$(pwd)"; FAIL=0
r()  { if [ "$1" = 0 ]; then echo "PASS  $2"; else echo "FAIL  $2"; FAIL=1; fi; }
# ck <설명> <명령...> — set -e 아래에서도 안전하게 판정 기록
ck() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then r 0 "$d"; else r 1 "$d"; fi; }

# 1) 필수 파일
for f in HARNESS.md STATUS.md tasks.yaml README.md; do
  ck "$f 존재" test -f "$P/$f"
done
ck "log/ 존재" test -d "$P/log"
ck "agents/ 존재" test -d "$P/agents"
ck "git 저장소" git -C "$P" rev-parse --git-dir
ck "log/HANDOFF.md 존재" test -f "$P/log/HANDOFF.md"
ck "log/decisions/ 존재" test -d "$P/log/decisions"
ck ".harness state library 존재" test -f "$P/.harness/lib/state.sh"
for f in .harness/bin/checkpoint .harness/bin/decision-open \
  .harness/bin/decision-hook .harness/bin/decision-close .harness/bin/hook-smoke-pass \
  .claude/settings.json .codex/hooks.json; do
  ck "$f 존재" test -f "$P/$f"
done
ck "decision-hook 실행 가능" test -x "$P/.harness/bin/decision-hook"
ck ".harness/bin/worker-wrap 실행 가능" test -x "$P/.harness/bin/worker-wrap"
for f in live-status live-roadmap live-status-hook github-private; do
  ck ".harness/bin/$f 실행 가능" test -x "$P/.harness/bin/$f"
done
ck "Claude hooks JSON 파싱" yq -e '.hooks.UserPromptSubmit and .hooks.Stop' "$P/.claude/settings.json"
ck "Codex hooks JSON 파싱" yq -e '.hooks.UserPromptSubmit and .hooks.Stop' "$P/.codex/hooks.json"

# 2) HARNESS.md 필수 섹션 + 플레이스홀더
for sec in "## 목표" "## 맥락" "## 제약" "## 위임 레벨" "## 실행 정책" "## 완료 기준"; do
  ck "HARNESS.md 섹션: $sec" grep -q "^$sec" "$P/HARNESS.md"
done
if grep -q "{{" "$P/HARNESS.md" 2>/dev/null; then r 1 "HARNESS.md 플레이스홀더 없음"; else r 0 "HARNESS.md 플레이스홀더 없음"; fi
for f in STATUS.md log/HANDOFF.md; do
  if grep -q '{{' "$P/$f" 2>/dev/null; then r 1 "$f 플레이스홀더 없음"
  else r 0 "$f 플레이스홀더 없음"; fi
done
if [ -f "$P/.harness/lib/state.sh" ]; then
  if bash -c ". '$P/.harness/lib/state.sh'; validate_state" >/dev/null 2>&1; then
    r 0 "상태 계약(HANDOFF/STATUS/tasks/.done/pending)"
  else
    r 1 "상태 계약(HANDOFF/STATUS/tasks/.done/pending)"
  fi
fi

# 3) tasks.yaml 파싱 + 순환 의존(Kahn 반복 제거)
ck "tasks.yaml 파싱" yq -e '.tasks' "$P/tasks.yaml"
ck "실행 계약" validate_execution_contract "$P/tasks.yaml"
ck "verify.cacheable은 boolean" yq -e \
  '[.tasks[]? | select(.verify | tag == "!!map") |
    select(.verify | has("cacheable")) |
    (.verify.cacheable | tag == "!!bool")] | all' "$P/tasks.yaml"
N="$(yq -r '.tasks | length' "$P/tasks.yaml")"
if [ "$N" -gt 0 ]; then
  # shellcheck disable=SC2016  # $i는 yq 문법이며 셸 확장 대상이 아님
  EDGES="$(yq -r '.tasks[] | .id as $i | (.depends_on[]? | . + " " + $i)' "$P/tasks.yaml")"
  REMAIN="$(yq -r '.tasks[].id' "$P/tasks.yaml")"
  E="$EDGES"
  progress=1
  while [ -n "$REMAIN" ] && [ "$progress" = 1 ]; do
    progress=0
    for id in $REMAIN; do
      if ! printf '%s\n' "$E" | grep -q " $id\$"; then     # 들어오는 간선 없음
        REMAIN="$(printf '%s\n' "$REMAIN" | grep -v "^$id\$" || true)"
        E="$(printf '%s\n' "$E" | grep -v "^$id " || true)"
        progress=1
      fi
    done
  done
  ck "tasks.yaml 순환 의존 없음" test -z "$REMAIN"
  # 4) 각 태스크의 브리프 필수 필드
  while IFS= read -r id; do
    if ! valid_task_id "$id"; then
      r 1 "안전한 task id: $id"
      continue
    fi
    if ! b="$(task_value "$P/tasks.yaml" "$id" '.brief')"; then
      r 1 "안전한 task id: $id"
      continue
    fi
    ck "브리프 존재: $b" test -f "$P/$b"
    for field in "임무" "산출물" "쓰기 허용 경로" "완료 신호"; do
      ck "브리프 $b: '$field' 정의" grep -q "$field" "$P/$b"
    done
    vc="$(task_value "$P/tasks.yaml" "$id" '.verify.command // ""')"
    if [ -n "$vc" ]; then
      ck "verify.command 실행 가능: $id ($vc)" command -v "$vc"
    fi
  done < <(yq -r '.tasks[]? | (.id // "")' "$P/tasks.yaml")
fi

# 5) --smoke: mux 왕복 (디스패치→로그→.done→판독). AI 토큰 소모 없음(sh 워커).
if [ "${1:-}" = "--smoke" ]; then
  MUX="$(detect_mux)"; WS="hx-smoke-$$"; DONE="$P/log/smoke.done"; LOG="$P/log/smoke.log"
  rm -f "$DONE" "$LOG"
  SNIPPET="echo smoke-ok; { echo 'run_id: smoke-$$'; echo 'status: DONE'; } > '$DONE'; sleep 30"
  # cmux에는 pipe-pane이 없으므로(실측) tee로 로그를 남긴다
  WRAP="sh -c $(printf '%q' "$SNIPPET") 2>&1 | tee -a $(printf '%q' "$LOG")"
  if [ "$MUX" = cmux ]; then
    # cmux 터미널은 앱이 워크스페이스를 화면에 그려야 시작된다(실측) → 생성 후 선택
    REF="$(cmux new-workspace --name "$WS" --cwd "$P" --command "$WRAP" \
      | grep -o 'workspace:[0-9]*' | head -1)"
    if [ -n "$REF" ]; then cmux select-workspace --workspace "$REF" >/dev/null; fi
  else
    tmux new-session -d -s "$WS" -c "$P" "$WRAP"
  fi
  i=0; until [ -f "$DONE" ] || [ "$i" -ge 15 ]; do sleep 1; i=$((i+1)); done
  if [ -f "$DONE" ] && grep -q "^status: DONE" "$DONE"; then
    r 0 "스모크: 왕복(.done 생성·판독)"
  else
    r 1 "스모크: 왕복(.done 생성·판독)"
  fi
  echo "(스모크 창 '$WS'는 확인 후 직접 닫는다 — 완료 창 유지 원칙, 결정 31)"
fi

if [ "$FAIL" = 0 ]; then
  { echo "passed_at: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "commit: $(git -C "$P" rev-parse --short HEAD 2>/dev/null || echo none)"
  } > "$P/log/scaffold-check.pass"
  echo "scaffold-check: 전체 PASS → log/scaffold-check.pass"
else
  rm -f "$P/log/scaffold-check.pass"
  die "scaffold-check FAIL — 위 항목을 고치고 재실행"
fi
