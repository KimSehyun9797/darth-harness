#!/usr/bin/env bash
# Status pane 안에서 poller와 worker GC를 소유하고 TUI를 foreground로 실행한다.
set -u

PROJECT="${1:-}"
PROVIDER="${2:-}"
[ -d "$PROJECT" ] || { printf 'ERROR: project directory missing\n' >&2; exit 2; }
PROJECT="$(cd "$PROJECT" && pwd)"
case "$PROVIDER" in claude|codex) :;; *) printf 'ERROR: provider must be claude or codex\n' >&2; exit 2;; esac
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HARNESS_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
INTERVAL="${HARNESS_STATUS_INTERVAL:-2}"
case "$INTERVAL" in ''|*[!0-9]*) INTERVAL=2;; esac
[ "$INTERVAL" -gt 0 ] || INTERVAL=2

consumer="${HARNESS_STATUS_TUI_BIN:-}"
if [ -z "$consumer" ]; then
  sibling="$(dirname "$HARNESS_ROOT")/cmux-harness-status/bin/cmux-harness-status"
  if [ -x "$sibling" ]; then consumer="$sibling"
  else consumer="$(command -v cmux-harness-status 2>/dev/null || true)"; fi
fi
[ -x "$consumer" ] || { printf 'ERROR: cmux-harness-status executable not found\n' >&2; exit 1; }

background_pids=''
cleanup() {
  for pid in $background_pids; do kill "$pid" 2>/dev/null || true; done
  for pid in $background_pids; do wait "$pid" 2>/dev/null || true; done
}
trap cleanup EXIT HUP INT TERM

writer="$PROJECT/.harness/bin/live-status"
roadmap="$PROJECT/.harness/bin/live-roadmap"
if [ "$PROJECT" = "$HARNESS_ROOT" ]; then
  [ -x "$writer" ] || writer="$HARNESS_ROOT/template/.harness/bin/live-status"
  [ -x "$roadmap" ] || roadmap="$HARNESS_ROOT/template/.harness/bin/live-roadmap"
fi
if [ -x "$writer" ] || [ -x "$roadmap" ]; then
  (
    while :; do
      now="$(date +%s)"
      if [ -x "$writer" ]; then
        HARNESS_PROJECT_ROOT="$PROJECT" "$writer" worker-gc --now "$now" >/dev/null 2>&1 || true
      fi
      if [ -x "$roadmap" ]; then
        HARNESS_PROJECT_ROOT="$PROJECT" "$roadmap" publish --now "$now" >/dev/null 2>&1 || true
      fi
      sleep "$INTERVAL"
    done
  ) &
  background_pids="$background_pids $!"
fi

if [ "$PROVIDER" = codex ]; then
  poller="${HARNESS_CODEX_POLLER_BIN:-$SCRIPT_DIR/codex-status-poller.sh}"
  if [ -x "$poller" ]; then
    HARNESS_CODEX_DIAGNOSTIC_FILE="$PROJECT/.harness/codex-status-poller.log" \
      "$poller" "$PROJECT" 60 >/dev/null 2>&1 &
    background_pids="$background_pids $!"
  fi
fi

set +e
(cd "$PROJECT" && HARNESS_STATUS_INTERVAL="$INTERVAL" "$consumer" --watch)
rc=$?
set -e
trap - EXIT HUP INT TERM
cleanup
exit "$rc"
