#!/usr/bin/env bash
# 30초 상태 파악 (결정 33). 프로젝트 루트에서 실행.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/lib.sh
. "$SCRIPT_DIR/lib.sh"
P="$(pwd)"
echo "═══ STATUS.md ═══"
if [ -f "$P/STATUS.md" ]; then cat "$P/STATUS.md"; else echo "(STATUS.md 없음)"; fi
echo; echo "═══ .done 마커 ═══"
found=0
for f in "$P"/log/*.done; do
  [ -e "$f" ] || break
  found=1; echo "── ${f##*/}"; sed -n '1,6p' "$f"
done
[ "$found" = 1 ] || echo "(없음)"
echo; echo "═══ 검증 기록 (.verified.yaml) ═══"
vfound=0
for f in "$P"/log/*.verified.yaml; do
  [ -e "$f" ] || break
  vfound=1; echo "── ${f##*/}"; sed -n '1,6p' "$f"
done
[ "$vfound" = 1 ] || echo "(없음)"
echo; echo "═══ 워커 화면 (hx-*) ═══"
MUX="$(detect_mux)"
if [ "$MUX" = cmux ]; then
  # list-workspaces 형식(실측): "  workspace:6  hx-C" (선택 창은 앞에 '*')
  LIST="$(cmux list-workspaces 2>/dev/null | grep ' hx-' || true)"
  if [ -z "$LIST" ]; then echo "(활성 워커 없음)"; fi
  printf '%s\n' "$LIST" | while IFS= read -r line; do
    [ -n "$line" ] || continue
    ref="$(printf '%s\n' "$line" | grep -o 'workspace:[0-9]*' | head -1)"
    name="$(printf '%s\n' "$line" | grep -o 'hx-[^ ]*' | head -1)"
    echo "── $name ($ref)"
    cmux read-screen --workspace "$ref" 2>/dev/null | tail -12 || echo "(판독 실패)"
  done
else
  LIST="$(tmux ls -F '#S' 2>/dev/null | grep '^hx-' || true)"
  if [ -z "$LIST" ]; then echo "(활성 워커 없음)"; fi
  for s in $LIST; do
    echo "── $s"
    tmux capture-pane -pt "$s" 2>/dev/null | tail -12 || echo "(판독 실패)"
  done
fi
