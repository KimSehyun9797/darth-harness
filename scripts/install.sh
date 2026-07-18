#!/usr/bin/env bash
# agent-harness 설치·진단 (컴퓨터당 1회, 멱등). 결정 13·30.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
ENABLE_LIVE_STATUS=false
case "${1:-}" in
  '') :;;
  --enable-live-status) ENABLE_LIVE_STATUS=true;;
  *) printf 'ERROR: unknown option: %s\n' "$1" >&2; exit 2;;
esac
ok()   { printf '  [OK]    %s\n' "$1"; }
todo() { printf '  [TODO]  %s\n      → %s\n' "$1" "$2"; }

link() { # $1=대상링크
  mkdir -p "$(dirname "$1")"
  if [ -L "$1" ] && [ "$(readlink "$1")" = "$ROOT/skills/harness" ]; then
    ok "링크 존재: $1"
  elif [ -e "$1" ]; then
    todo "$1 에 다른 항목 존재" "확인 후 수동 정리: ls -la $1"
  else
    ln -s "$ROOT/skills/harness" "$1"; ok "링크 생성: $1"
  fi
}

# chk_cmd <명령> <이름> <안내>
chk_cmd() {
  if command -v "$1" >/dev/null 2>&1; then ok "$2"; else todo "$2 없음" "$3"; fi
}

echo "══ Core (필수) ══"
link "$HOME/.agents/skills/harness"
link "$HOME/.claude/skills/harness"
chk_cmd git "git" "xcode-select --install"
chk_cmd yq "yq(스크립트 필수)" "brew install yq"
if command -v cmux >/dev/null 2>&1; then ok "cmux"
elif command -v tmux >/dev/null 2>&1; then ok "tmux (cmux 폴백)"
else todo "cmux/tmux 둘 다 없음" "cmux 설치 권장, 최소 brew install tmux"; fi

echo "══ Multi-model ══"
chk_cmd claude "claude CLI" "https://claude.com/claude-code"
chk_cmd codex "codex CLI" "npm i -g @openai/codex"

echo "══ Decision hook readiness ══"
echo "  [INFO]  Claude: 프로젝트 .claude/settings.json 훅 검토·허용 필요"
echo "  [INFO]  Codex: 프로젝트를 신뢰한 뒤 /hooks에서 현재 hash를 검토·신뢰해야 함"
echo "  [INFO]  설정 존재만으로 PASS 아님 — 실제 UserPromptSubmit/Stop 스모크 근거 필요"

echo "══ Knowledge sync ══"
# shellcheck disable=SC2088  # 표시용 문자열의 ~ (경로 확장 아님)
if [ -d "$HOME/knowledge-base/.git" ]; then ok "~/knowledge-base git화됨"
else todo "~/knowledge-base 가 git 아님" "정비 트랙(스펙 §6.2 6단계)에서 진행 — 임의 실행 금지"; fi
if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then ok "gh 로그인"
else todo "gh 미로그인" "gh auth login"; fi

echo "══ Optional ══"
if [ -d "$HOME/.claude/skills/llm-wiki" ]; then ok "llm-wiki 스킬(CORE 도구)"
else todo "llm-wiki 스킬 없음" "하네스 vendored 버전 설치는 정비 트랙에서(결정 29)"; fi
chk_cmd graphify "graphify(OPTIONAL)" "사람 승인 후: uv tool install graphifyy && graphify install"
echo "  [INFO]  Lean Gate는 실행 계약 v3에 내장됨 — 외부 Ponytail 플러그인 불필요"

enable_live_status() {
  for cmd in jq yq cmux; do
    command -v "$cmd" >/dev/null 2>&1 \
      || { printf 'ERROR: --enable-live-status requires %s\n' "$cmd" >&2; return 1; }
  done

  consumer=''
  for candidate in "$HOME/cmux-harness-status/bin/cmux-harness-status" \
    "$(dirname "$ROOT")/cmux-harness-status/bin/cmux-harness-status"; do
    if [ -x "$candidate" ]; then consumer="$candidate"; break; fi
  done
  [ -n "$consumer" ] || consumer="$(command -v cmux-harness-status 2>/dev/null || true)"
  [ -x "$consumer" ] || { printf 'ERROR: cmux-harness-status executable not found\n' >&2; return 1; }

  settings="$HOME/.claude/settings.json"
  if [ -e "$settings" ]; then
    jq -e 'type == "object" and ((.statusLine // {}) | type == "object")' "$settings" >/dev/null \
      || { printf 'ERROR: Claude settings/statusLine is not an object\n' >&2; return 1; }
    old_command="$(jq -r '.statusLine.command // "(none)"' "$settings")"
  else
    old_command='(none)'
  fi
  new_command="$ROOT/scripts/claude-statusline-tui.sh"

  local_bin="$HOME/.local/bin/cmux-harness-status"
  launcher_bin="$HOME/.local/bin/agent-harness-live-status"
  launcher_target="$ROOT/scripts/live-status-pane.sh"
  if [ -L "$local_bin" ] && [ "$(readlink "$local_bin")" = "$consumer" ]; then :
  elif [ -e "$local_bin" ] || [ -L "$local_bin" ]; then
    printf 'ERROR: unrelated executable exists: %s\n' "$local_bin" >&2
    return 1
  fi
  if [ -L "$launcher_bin" ] && [ "$(readlink "$launcher_bin")" = "$launcher_target" ]; then :
  elif [ -e "$launcher_bin" ] || [ -L "$launcher_bin" ]; then
    printf 'ERROR: unrelated executable exists: %s\n' "$launcher_bin" >&2
    return 1
  fi

  mkdir -p "$(dirname "$local_bin")" "$HOME/.claude"
  [ -L "$local_bin" ] || ln -s "$consumer" "$local_bin"
  [ -L "$launcher_bin" ] || ln -s "$launcher_target" "$launcher_bin"
  if [ -e "$settings" ]; then
    backup="$settings.bak.$(date +%Y%m%d%H%M%S).$$"
    cp -p "$settings" "$backup"
    input="$settings"
  else
    input=/dev/null
  fi
  tmp="$(mktemp "$HOME/.claude/settings.json.tmp.XXXXXX")"
  # Claude 세션도 Codex처럼 UserPromptSubmit에서 status pane을 자동 시작한다.
  # 이미 같은 명령이 등록돼 있으면 중복 추가하지 않는다(멱등).
  hook_command="$ROOT/scripts/claude-live-status-hook.sh"
  add_hook='.hooks = (.hooks // {})
    | .hooks.UserPromptSubmit = ((.hooks.UserPromptSubmit // [])
        | if ([.[]? | .hooks[]? | .command] | index($hook)) then .
          else . + [{hooks: [{type: "command", command: $hook}]}] end)'
  if [ "$input" = /dev/null ]; then
    jq -n --arg command "$new_command" --arg hook "$hook_command" \
      "{statusLine:{type:\"command\",command:\$command,refreshInterval:60}} | $add_hook" > "$tmp"
  else
    jq --arg command "$new_command" --arg hook "$hook_command" \
      ".statusLine = (.statusLine // {}) | .statusLine.command = \$command | $add_hook" \
      "$input" > "$tmp"
  fi
  chmod 600 "$tmp"
  mv "$tmp" "$settings"
  printf '  [LIVE]  consumer: %s -> %s\n' "$local_bin" "$consumer"
  printf '  [LIVE]  auto-start: %s -> %s\n' "$launcher_bin" "$launcher_target"
  printf '  [LIVE]  claude hook: UserPromptSubmit -> %s\n' "$hook_command"
  printf '  [LIVE]  Claude statusLine old: %s\n' "$old_command"
  printf '  [LIVE]  Claude statusLine new: %s\n' "$new_command"
}

if [ "$ENABLE_LIVE_STATUS" = true ]; then
  echo "══ Live status activation (explicit) ══"
  enable_live_status
fi

echo
echo "완료. [TODO] 항목은 표시된 명령으로 직접 진행하세요 (자동 설치하지 않음)."
