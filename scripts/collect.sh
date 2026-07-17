#!/usr/bin/env bash
# 산출물·로그 취합. 프로젝트 루트에서 실행. 사용법: collect.sh
set -euo pipefail
P="$(pwd)"
OUT="$P/log/collect-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUT"
{
  echo "# 수집 요약 — $(date '+%Y-%m-%d %H:%M:%S')"
  echo
  for f in "$P"/log/*.done; do
    [ -e "$f" ] || { echo "(완료 마커 없음)"; break; }
    echo "## ${f##*/}"; cat "$f"; echo
  done
} > "$OUT/summary.md"
cp "$P"/log/*.log "$OUT/" 2>/dev/null || true
echo "취합 완료: $OUT (summary.md + 로그 사본)"
