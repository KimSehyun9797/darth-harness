#!/usr/bin/env bash
# 기존 프로젝트에 live status 코드만 dry-run 우선으로 이전한다.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MODE="${1:-}"
P="${2:-}"
case "$MODE" in --dry-run|--apply) :;; *) printf 'ERROR: usage: %s --dry-run|--apply PROJECT\n' "$0" >&2; exit 2;; esac
[ -d "$P" ] || { printf 'ERROR: project directory missing: %s\n' "$P" >&2; exit 2; }
P="$(cd "$P" && pwd -P)"
GIT_ROOT="$(git -C "$P" rev-parse --show-toplevel 2>/dev/null)" \
  || { printf 'ERROR: not a git project: %s\n' "$P" >&2; exit 2; }
GIT_ROOT="$(cd "$GIT_ROOT" && pwd -P)"
[ "$GIT_ROOT" = "$P" ] || { printf 'ERROR: run at git project root: %s\n' "$P" >&2; exit 2; }

paths='.harness/bin/live-status
.harness/bin/live-roadmap
.harness/bin/live-status-hook
.harness/bin/worker-wrap
.claude/settings.json
.codex/hooks.json'
ignore_rules='.harness/live-status.env
.harness/live-status.env.tmp.*
.harness/live-workers/
.harness/live-status-pane.env
.harness/live-roadmap.yaml
.harness/live-roadmap.yaml.tmp.*'

conflicts=0
while IFS= read -r rel; do
  [ -n "$rel" ] || continue
  src="$ROOT/template/$rel"; dst="$P/$rel"
  [ -e "$src" ] || { printf 'ERROR: template path missing: %s\n' "$rel" >&2; exit 2; }
  if [ ! -e "$dst" ]; then printf 'ADD      %s\n' "$rel"
  elif cmp -s "$src" "$dst"; then printf 'SAME     %s\n' "$rel"
  else printf 'CONFLICT %s\n' "$rel"; conflicts=1
  fi
done <<EOF
$paths
EOF

missing_ignore=0
while IFS= read -r rule; do
  [ -n "$rule" ] || continue
  grep -Fxq "$rule" "$P/.gitignore" 2>/dev/null || missing_ignore=1
done <<EOF
$ignore_rules
EOF
if [ "$missing_ignore" = 1 ]; then printf 'ADD      .gitignore live-status rules\n'
else printf 'SAME     .gitignore live-status rules\n'; fi

[ "$conflicts" = 0 ] || { printf 'ERROR: conflict found; nothing applied\n' >&2; exit 1; }
[ "$MODE" = --apply ] || exit 0

if [ -f "$P/tasks.yaml" ]; then
  command -v yq >/dev/null 2>&1 || { printf 'ERROR: yq required\n' >&2; exit 2; }
  yq -e '.tasks | tag == "!!seq"' "$P/tasks.yaml" >/dev/null 2>&1 \
    || { printf 'ERROR: invalid tasks.yaml\n' >&2; exit 1; }
  if yq -e '.tasks[] | select(.status == "done" or .status == "verified")' "$P/tasks.yaml" >/dev/null 2>&1; then
    [ -f "$P/.harness/lib/state.sh" ] \
      || { printf 'ERROR: completed project needs existing state validator\n' >&2; exit 1; }
    bash -c 'cd "$1" && . .harness/lib/state.sh && validate_state' _ "$P" >/dev/null 2>&1 \
      || { printf 'ERROR: completed project state validation failed\n' >&2; exit 1; }
  fi
fi

stage="$(mktemp -d "$P/.live-status-migrate.XXXXXX")"
trap 'rm -rf "$stage"' EXIT HUP INT TERM
while IFS= read -r rel; do
  [ -n "$rel" ] || continue
  [ ! -e "$P/$rel" ] || continue
  mkdir -p "$stage/$(dirname "$rel")"
  cp "$ROOT/template/$rel" "$stage/$rel"
done <<EOF
$paths
EOF

if [ "$missing_ignore" = 1 ]; then
  if [ -f "$P/.gitignore" ]; then cp "$P/.gitignore" "$stage/.gitignore"
  else : > "$stage/.gitignore"; fi
  while IFS= read -r rule; do
    [ -n "$rule" ] || continue
    grep -Fxq "$rule" "$stage/.gitignore" 2>/dev/null || printf '%s\n' "$rule" >> "$stage/.gitignore"
  done <<EOF
$ignore_rules
EOF
fi

while IFS= read -r rel; do
  [ -n "$rel" ] || continue
  [ -e "$stage/$rel" ] || continue
  mkdir -p "$(dirname "$P/$rel")"
  mv "$stage/$rel" "$P/$rel"
  [ -x "$ROOT/template/$rel" ] && chmod +x "$P/$rel"
done <<EOF
$paths
EOF
if [ -f "$stage/.gitignore" ]; then mv "$stage/.gitignore" "$P/.gitignore"; fi
printf 'Applied live status code. Runtime records were not copied.\n'
