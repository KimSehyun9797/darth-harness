#!/usr/bin/env bash
# 한 번에 status pane을 여는 진입점. 현재 디렉터리가 하네스 프로젝트면 그것을,
# 아니면 마지막으로 pane을 켠 프로젝트(active-project 포인터)를 사용한다.
set -u

launcher="$HOME/.local/bin/agent-harness-live-status"
[ -x "$launcher" ] || launcher="$(command -v agent-harness-live-status 2>/dev/null || true)"
[ -n "$launcher" ] || { printf 'ERROR: agent-harness-live-status not installed (run install.sh)\n' >&2; exit 1; }

root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [ -z "$root" ] || { [ ! -f "$root/HARNESS.md" ] && [ ! -d "$root/.harness" ]; }; then
  state_dir="${HARNESS_STATE_DIR:-$HOME/.local/state/agent-harness}"
  root="$(head -1 "$state_dir/active-project" 2>/dev/null || true)"
fi
[ -n "$root" ] && [ -d "$root" ] || {
  printf 'ERROR: no harness project here and no active-project pointer\n' >&2
  exit 1
}

"$launcher" start "$root" claude
