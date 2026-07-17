#!/usr/bin/env bash
# 선택한 cmux surface와 Git worktree를 읽기 전용으로 확인한다.
set -euo pipefail

WORKSPACE="${1:?사용법: monitor-worker.sh WORKSPACE SURFACE WORKTREE}"
SURFACE="${2:?사용법: monitor-worker.sh WORKSPACE SURFACE WORKTREE}"
WORKTREE="${3:?사용법: monitor-worker.sh WORKSPACE SURFACE WORKTREE}"

[[ "$WORKSPACE" =~ ^workspace:[0-9]+$ ]] \
  || { echo "안전하지 않은 workspace ref: $WORKSPACE" >&2; exit 1; }
[[ "$SURFACE" =~ ^surface:[0-9]+$ ]] \
  || { echo "안전하지 않은 surface ref: $SURFACE" >&2; exit 1; }
[ -d "$WORKTREE" ] \
  || { echo "Git worktree가 아닙니다: $WORKTREE" >&2; exit 1; }
IS_WORKTREE="$(GIT_OPTIONAL_LOCKS=0 git -C "$WORKTREE" rev-parse --is-inside-work-tree 2>/dev/null)" \
  || { echo "Git worktree가 아닙니다: $WORKTREE" >&2; exit 1; }
[ "$IS_WORKTREE" = true ] \
  || { echo "Git worktree가 아닙니다: $WORKTREE" >&2; exit 1; }

cmux read-screen --workspace "$WORKSPACE" --surface "$SURFACE" --scrollback --lines 80
GIT_OPTIONAL_LOCKS=0 git -C "$WORKTREE" status --short --branch
GIT_OPTIONAL_LOCKS=0 git -C "$WORKTREE" log -1 --oneline
