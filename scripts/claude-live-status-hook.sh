#!/usr/bin/env bash
# Claude Code UserPromptSubmit 훅. 하네스 프로젝트 세션이면 status pane을
# best-effort로 시작·재사용한다. 어떤 실패도 프롬프트 처리를 막지 않는다.
set -u

input="$(cat 2>/dev/null || true)"
cwd="$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null || true)"
[ -n "$cwd" ] && [ -d "$cwd" ] || cwd="$PWD"

root="$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null || true)"
[ -n "$root" ] || root="$cwd"

# 하네스 프로젝트 표식이 없으면 아무것도 하지 않는다.
if [ ! -f "$root/HARNESS.md" ] && [ ! -d "$root/.harness" ]; then
  exit 0
fi

launcher="$HOME/.local/bin/agent-harness-live-status"
[ -x "$launcher" ] || launcher="$(command -v agent-harness-live-status 2>/dev/null || true)"
[ -n "$launcher" ] || exit 0
if [ -x "$launcher" ]; then
  "$launcher" start "$root" claude >/dev/null 2>&1 || true
fi
exit 0
