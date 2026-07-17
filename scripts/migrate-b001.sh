#!/usr/bin/env bash
# B-001 증거 계약으로 기존 프로젝트를 opt-in 이전한다. dry-run 우선 (migrate-b002 패턴).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
P="${1:?사용법: scripts/migrate-b001.sh <project-root> [--apply]}"
MODE="${2:-dry-run}"
[ -d "$P" ] || { echo "ERROR: 프로젝트 디렉터리 없음: $P" >&2; exit 1; }
P="$(cd "$P" && pwd -P)"
GIT_ROOT="$(git -C "$P" rev-parse --show-toplevel 2>/dev/null)" \
  || { echo "ERROR: git 프로젝트 아님: $P" >&2; exit 1; }
GIT_ROOT="$(cd "$GIT_ROOT" && pwd -P)"
[ "$GIT_ROOT" = "$P" ] || { echo "ERROR: Git 프로젝트 루트에서 실행하세요: $P" >&2; exit 1; }
case "$MODE" in dry-run|--apply) :;; *) echo "ERROR: 두 번째 인자는 --apply만 허용" >&2; exit 1;; esac

if [ "$MODE" = --apply ] && [ -f "$P/tasks.yaml" ]; then
  yq -e '.tasks | tag == "!!seq"' "$P/tasks.yaml" >/dev/null 2>&1 \
    || { echo "ERROR: tasks.yaml 파싱 실패 — 이전하지 않음" >&2; exit 1; }
  if yq -e '.tasks[] | select(.status == "done" or .status == "verified")' \
      "$P/tasks.yaml" >/dev/null 2>&1; then
    echo "ERROR: 완료된 태스크가 있어 자동 이전을 거부합니다." >&2
    echo "불변 .done과 검증 증거의 수동 이전·재검증 계획을 먼저 승인하세요." >&2
    exit 1
  fi
fi

add_paths='.harness/bin/worker-wrap'
replace_paths='.harness/lib/state.sh'

conflicts=""
for rel in $add_paths; do
  src="$ROOT/template/$rel"; dst="$P/$rel"
  [ -e "$src" ] || { echo "ERROR: template 누락: $rel" >&2; exit 1; }
  if [ -e "$dst" ] && ! cmp -s "$src" "$dst"; then conflicts="$conflicts $rel"; fi
done
[ -z "$conflicts" ] || { echo "ERROR: 기존 파일 충돌:$conflicts" >&2; exit 1; }

echo "B-001 migration ($MODE):"
for rel in $add_paths; do
  if [ -e "$P/$rel" ]; then echo "  SAME    $rel"; else echo "  ADD     $rel"; fi
done
for rel in $replace_paths; do
  src="$ROOT/template/$rel"; dst="$P/$rel"
  [ -e "$src" ] || { echo "ERROR: template 누락: $rel" >&2; exit 1; }
  if [ ! -e "$dst" ]; then echo "  ADD     $rel"
  elif cmp -s "$src" "$dst"; then echo "  SAME    $rel"
  else echo "  REPLACE $rel"; diff -u "$dst" "$src" || true; fi
done
[ "$MODE" = --apply ] || exit 0

for rel in $add_paths $replace_paths; do
  mkdir -p "$(dirname "$P/$rel")"
  cp "$ROOT/template/$rel" "$P/$rel"
done
chmod +x "$P/.harness/bin/worker-wrap"
echo "적용 완료. scaffold-check를 다시 실행하세요. 기존 VERIFIED 덮어쓰기 마커는"
echo "새 계약 위반입니다 — 해당 태스크는 verify.sh로 재검증하거나 상태를 조정하세요."
