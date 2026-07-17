#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
P="${1:?사용법: scripts/migrate-b002.sh <project-root> [--apply]}"
MODE="${2:-dry-run}"
[ -d "$P/.git" ] || { echo "ERROR: git 프로젝트 아님: $P" >&2; exit 1; }
case "$MODE" in dry-run|--apply) :;; *) echo "ERROR: 두 번째 인자는 --apply만 허용" >&2; exit 1;; esac

if [ "$MODE" = --apply ] && [ -f "$P/tasks.yaml" ]; then
  yq -e '.tasks | tag == "!!seq"' "$P/tasks.yaml" >/dev/null 2>&1 \
    || { echo "ERROR: tasks.yaml 파싱 실패 — 이전하지 않음" >&2; exit 1; }
  if yq -e '.tasks[] | select(.status == "done" or .status == "verified")' \
      "$P/tasks.yaml" >/dev/null 2>&1; then
    echo "ERROR: 완료된 태스크가 있어 B-001 계약을 자동 이전하지 않습니다." >&2
    echo "불변 .done과 검증 증거의 수동 이전·재검증 계획을 먼저 승인하세요." >&2
    exit 1
  fi
fi

paths='log/HANDOFF.md
log/decisions/.gitkeep
.harness/lib/state.sh
.harness/bin/checkpoint
.harness/bin/decision-open
.harness/bin/decision-hook
.harness/bin/decision-close
.harness/bin/hook-smoke-pass
.harness/bin/worker-wrap
.claude/settings.json
.codex/hooks.json'

conflicts=""
while IFS= read -r rel; do
  [ -n "$rel" ] || continue
  src="$ROOT/template/$rel"; dst="$P/$rel"
  [ -e "$src" ] || { echo "ERROR: template 누락: $rel" >&2; exit 1; }
  if [ -e "$dst" ] && ! cmp -s "$src" "$dst"; then conflicts="$conflicts $rel"; fi
done <<EOF
$paths
EOF
[ -z "$conflicts" ] || { echo "ERROR: 기존 파일 충돌:$conflicts" >&2; exit 1; }

echo "B-002 migration ($MODE):"
while IFS= read -r rel; do
  [ -n "$rel" ] || continue
  if [ -e "$P/$rel" ]; then echo "  SAME $rel"; else echo "  ADD  $rel"; fi
done <<EOF
$paths
EOF
[ "$MODE" = --apply ] || exit 0

while IFS= read -r rel; do
  [ -n "$rel" ] || continue
  [ -e "$P/$rel" ] && continue
  mkdir -p "$(dirname "$P/$rel")"
  cp "$ROOT/template/$rel" "$P/$rel"
done <<EOF
$paths
EOF
chmod +x "$P"/.harness/bin/*
echo "적용 완료. STATUS.md와 log/HANDOFF.md 플레이스홀더를 채운 뒤 scaffold-check를 실행하세요."
