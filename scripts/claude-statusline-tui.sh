#!/usr/bin/env bash
# Claude statusline 입력을 표시하면서 프로젝트 live status를 best-effort로 갱신한다.
set -u

input="$(cat 2>/dev/null || true)"
json_value() { printf '%s' "$input" | jq -r "$1 // empty" 2>/dev/null || true; }
remaining_pct() {
  case "$1" in ''|*[!0-9]*) printf '?'; return;; esac
  [ "$1" -le 100 ] 2>/dev/null || { printf '?'; return; }
  printf '%s' "$((100 - $1))"
}

root="$(json_value '.workspace.current_dir')"
model="$(json_value '.model.display_name')"
[ -n "$model" ] || model="$(json_value '.model')"
[ -n "$model" ] || model='?'
context_left="$(remaining_pct "$(json_value '.context_window.used_percentage')")"
five_left="$(remaining_pct "$(json_value '.rate_limits.five_hour.used_percentage')")"
weekly_left="$(remaining_pct "$(json_value '.rate_limits.seven_day.used_percentage')")"

if [ -n "$root" ] && [ -x "$root/.harness/bin/live-status" ]; then
  HARNESS_PROJECT_ROOT="$root" "$root/.harness/bin/live-status" orchestrator-update \
    --provider claude --model-observed "$model" \
    --context-left-pct "$context_left" --context-left '?' \
    --weekly-left-pct "$weekly_left" --captured-at "$(date +%s)" \
    >/dev/null 2>&1 || true
fi

printf '%s · 5H %s%% left · WEEK %s%% left · CTX %s%% left\n' \
  "$model" "$five_left" "$weekly_left" "$context_left"
