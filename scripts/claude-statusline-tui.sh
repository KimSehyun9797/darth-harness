#!/usr/bin/env bash
# Claude statusline 입력을 표시하면서 프로젝트 live status를 best-effort로 갱신한다.
# 세션 cwd가 하네스 프로젝트가 아니면, 마지막으로 status pane을 켠 프로젝트
# (active-project 포인터)로 공급한다 — 홈 디렉터리 세션도 게이지가 최신을 유지한다.
set -u

input="$(cat 2>/dev/null || true)"
json_value() { printf '%s' "$input" | jq -r "$1 // empty" 2>/dev/null || true; }
remaining_pct() {
  case "$1" in ''|*[!0-9]*) printf '?'; return;; esac
  [ "$1" -le 100 ] 2>/dev/null || { printf '?'; return; }
  printf '%s' "$((100 - $1))"
}

# 프로젝트의 live-status 실행기를 찾는다. 하네스 소스 저장소 자체는
# .harness/bin이 없으므로 template 쪽 실행기를 쓴다.
live_status_bin() { # $1=project-root
  if [ -x "$1/.harness/bin/live-status" ]; then
    printf '%s' "$1/.harness/bin/live-status"
  elif [ -f "$1/AGENTS.md" ] && [ -x "$1/template/.harness/bin/live-status" ]; then
    printf '%s' "$1/template/.harness/bin/live-status"
  fi
}

root="$(json_value '.workspace.current_dir')"
model="$(json_value '.model.display_name')"
[ -n "$model" ] || model="$(json_value '.model')"
[ -n "$model" ] || model='?'
context_left="$(remaining_pct "$(json_value '.context_window.used_percentage')")"
five_left="$(remaining_pct "$(json_value '.rate_limits.five_hour.used_percentage')")"
weekly_left="$(remaining_pct "$(json_value '.rate_limits.seven_day.used_percentage')")"

target=''
[ -n "$root" ] && target="$(live_status_bin "$root")"
if [ -z "$target" ]; then
  pointer="${HARNESS_STATE_DIR:-$HOME/.local/state/agent-harness}/active-project"
  candidate="$(head -1 "$pointer" 2>/dev/null || true)"
  if [ -n "$candidate" ] && [ -d "$candidate" ]; then
    target="$(live_status_bin "$candidate")"
    [ -z "$target" ] || root="$candidate"
  fi
fi

if [ -n "$target" ]; then
  HARNESS_PROJECT_ROOT="$root" "$target" orchestrator-update \
    --provider claude --model-observed "$model" \
    --context-left-pct "$context_left" --context-left '?' \
    --weekly-left-pct "$weekly_left" --captured-at "$(date +%s)" \
    >/dev/null 2>&1 || true
fi

printf '%s · 5H %s%% left · WEEK %s%% left · CTX %s%% left\n' \
  "$model" "$five_left" "$weekly_left" "$context_left"
