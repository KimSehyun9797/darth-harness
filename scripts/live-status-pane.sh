#!/usr/bin/env bash
# 현재 harness workspace 아래에 읽기 전용 status pane 하나만 유지한다.
set -u

ACTION="${1:-}"
PROJECT="${2:-}"
PROVIDER="${3:-codex}"
case "$ACTION" in start|stop) :;; *) printf 'Usage: live-status-pane.sh start|stop PROJECT [claude|codex]\n' >&2; exit 2;; esac
[ -d "$PROJECT" ] || { printf 'ERROR: project directory missing\n' >&2; exit 2; }
PROJECT="$(cd "$PROJECT" && pwd)"
case "$PROVIDER" in claude|codex) :;; *) printf 'ERROR: unsupported provider\n' >&2; exit 2;; esac

META="$PROJECT/.harness/live-status-pane.env"
SOURCE="${BASH_SOURCE[0]}"
while [ -L "$SOURCE" ]; do
  SOURCE_DIR="$(cd "$(dirname "$SOURCE")" && pwd)"
  LINK_TARGET="$(readlink "$SOURCE")"
  case "$LINK_TARGET" in
    /*) SOURCE="$LINK_TARGET" ;;
    *) SOURCE="$SOURCE_DIR/$LINK_TARGET" ;;
  esac
done
SCRIPT_DIR="$(cd "$(dirname "$SOURCE")" && pwd)"
valid_workspace() { printf '%s' "$1" | grep -Eq '^workspace:[0-9]+$'; }
valid_surface() { printf '%s' "$1" | grep -Eq '^surface:[0-9]+$'; }
valid_thread() { printf '%s' "$1" | grep -Eq '^[A-Za-z0-9-]+$'; }
read_key() { awk -F= -v k="$2" '$1 == k {sub(/^[^=]*=/, ""); print; exit}' "$1" 2>/dev/null || true; }

# 새 status pane이 압축 레이아웃으로 떨어지지 않게 높이를 best-effort로 확보한다.
# cmux resize-pane의 amount는 픽셀 단위이고, bottom pane은 -U가 위 경계를 올려
# 커진다. 재사용(REUSED)에는 적용하지 않는다 — 매 세션마다 자라지 않게 하고,
# 사용자가 직접 줄인 높이를 존중한다. 실패해도 start를 막지 않는다.
ensure_pane_height() { # $1=workspace $2=surface
  local pane
  for pane in $(cmux list-panes --workspace "$1" 2>/dev/null | grep -o 'pane:[0-9]*'); do
    if cmux list-pane-surfaces --workspace "$1" --pane "$pane" 2>/dev/null \
      | grep -q "$2[^0-9]"; then
      cmux resize-pane --pane "$pane" --workspace "$1" -U --amount 100 \
        >/dev/null 2>&1 || true
      return 0
    fi
  done
  return 0
}

close_surface() {
  surface="$1"
  if ! cmux close-surface --surface "$surface" >/dev/null 2>&1; then
    cmux send-key --surface "$surface" ctrl-c >/dev/null 2>&1 || true
    cmux send --surface "$surface" exit >/dev/null 2>&1 || true
    cmux send-key --surface "$surface" enter >/dev/null 2>&1 \
      || cmux send-key --surface "$surface" Enter >/dev/null 2>&1 || true
  fi
}

publish_meta() {
  mkdir -p "$PROJECT/.harness" || return 1
  chmod 700 "$PROJECT/.harness" || return 1
  tmp="$(mktemp "$META.tmp.XXXXXX")" || return 1
  trap 'rm -f "$tmp"' EXIT HUP INT TERM
  {
    printf 'HARNESS_STATUS_PANE_VERSION=1\n'
    printf 'HARNESS_STATUS_PANE_WORKSPACE=%s\n' "$1"
    printf 'HARNESS_STATUS_PANE_SURFACE=%s\n' "$2"
    printf 'HARNESS_STATUS_PANE_CODEX_THREAD_ID=%s\n' "$3"
    printf 'HARNESS_STATUS_PANE_STARTED_AT=%s\n' "$(date +%s)"
  } > "$tmp" || return 1
  chmod 600 "$tmp" || return 1
  mv "$tmp" "$META" || return 1
  trap - EXIT HUP INT TERM
}

if [ "$ACTION" = stop ]; then
  [ -f "$META" ] || exit 0
  surface="$(read_key "$META" HARNESS_STATUS_PANE_SURFACE)"
  if command -v cmux >/dev/null 2>&1 && valid_surface "$surface"; then
    close_surface "$surface"
  fi
  rm -f "$META"
  exit 0
fi

if ! command -v cmux >/dev/null 2>&1 || ! cmux ping >/dev/null 2>&1; then
  printf 'UNSUPPORTED: cmux is required for live status pane\n' >&2
  exit 1
fi
workspace="${HARNESS_ORCH_WORKSPACE:-$(cmux identify --no-caller 2>/dev/null \
  | yq -r '.caller.workspace_ref // ""' 2>/dev/null)}"
[ -n "$workspace" ] || workspace="$(cmux identify 2>/dev/null | yq -r '.caller.workspace_ref // ""' 2>/dev/null)"
valid_workspace "$workspace" || { printf 'ERROR: current cmux workspace unavailable\n' >&2; exit 1; }
current_thread='?'
if [ "$PROVIDER" = codex ] && valid_thread "${CODEX_THREAD_ID:-}"; then
  current_thread="$CODEX_THREAD_ID"
fi
codex_bin=''
if [ "$PROVIDER" = codex ]; then
  codex_bin="$(command -v codex 2>/dev/null || true)"
  [ -x "$codex_bin" ] || codex_bin=''
fi

if [ -f "$META" ]; then
  old_version="$(read_key "$META" HARNESS_STATUS_PANE_VERSION)"
  old_workspace="$(read_key "$META" HARNESS_STATUS_PANE_WORKSPACE)"
  old_surface="$(read_key "$META" HARNESS_STATUS_PANE_SURFACE)"
  old_thread="$(read_key "$META" HARNESS_STATUS_PANE_CODEX_THREAD_ID)"
  if [ "$old_version" = 1 ] && [ "$old_workspace" = "$workspace" ] \
    && [ "$old_thread" = "$current_thread" ] \
    && valid_surface "$old_surface" \
    && cmux read-screen --surface "$old_surface" --lines 1 >/dev/null 2>&1; then
    printf 'REUSED %s/%s\n' "$workspace" "$old_surface"
    exit 0
  fi
  if valid_surface "$old_surface"; then close_surface "$old_surface"; fi
  rm -f "$META"
fi

surface="$(cmux new-split down --workspace "$workspace" 2>/dev/null \
  | grep -o 'surface:[0-9]*' | head -1)"
valid_surface "$surface" || { printf 'ERROR: cmux split down failed\n' >&2; exit 1; }
command_parts=(env)
[ "$current_thread" = '?' ] || command_parts+=("CODEX_THREAD_ID=$current_thread")
[ -z "$codex_bin" ] || command_parts+=("HARNESS_CODEX_BIN=$codex_bin")
command_parts+=(bash "$SCRIPT_DIR/live-status-session.sh" "$PROJECT" "$PROVIDER")
command="$(printf '%q ' "${command_parts[@]}")"
cmux send --surface "$surface" "$command" >/dev/null 2>&1 || exit 1
cmux send-key --surface "$surface" enter >/dev/null 2>&1 \
  || cmux send-key --surface "$surface" Enter >/dev/null 2>&1 || true
publish_meta "$workspace" "$surface" "$current_thread" || exit 1
ensure_pane_height "$workspace" "$surface"
printf 'STARTED %s/%s\n' "$workspace" "$surface"
