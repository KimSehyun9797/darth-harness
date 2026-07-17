#!/usr/bin/env bash
# Codex app-server의 읽기 전용 계정 상태를 프로젝트 live-status 레코드로 정규화한다.
set -u

ROOT="${1:-}"
INTERVAL="${2:-60}"
case "$INTERVAL" in ''|*[!0-9]*) printf 'ERROR: interval must be a non-negative integer\n' >&2; exit 2;; esac
RETRY_INTERVAL="${HARNESS_CODEX_RETRY_INTERVAL:-5}"
case "$RETRY_INTERVAL" in ''|*[!0-9]*) RETRY_INTERVAL=5;; esac
[ "$RETRY_INTERVAL" -gt 0 ] || RETRY_INTERVAL=5
[ -n "$ROOT" ] || { printf 'ERROR: project root required\n' >&2; exit 2; }
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HARNESS_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WRITER="$ROOT/.harness/bin/live-status"
if [ "$ROOT" = "$HARNESS_ROOT" ] && [ ! -x "$WRITER" ]; then
  WRITER="$HARNESS_ROOT/template/.harness/bin/live-status"
fi
[ -x "$WRITER" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0

read_key() {
  awk -F= -v k="$2" '$1 == k {sub(/^[^=]*=/, ""); print; exit}' "$1" 2>/dev/null || true
}

record_failure() {
  local reason target tmp
  reason="$1"
  target="${HARNESS_CODEX_DIAGNOSTIC_FILE:-}"
  [ -n "$target" ] || return 0
  umask 077
  tmp="$(mktemp "$target.tmp.XXXXXX")" || return 0
  {
    printf 'reason=%s\n' "$reason"
    [ ! -f "${errors:-}" ] || tail -n 20 "$errors"
    [ ! -f "${output:-}" ] || tail -n 20 "$output"
    [ ! -f "${response:-}" ] || tail -n 5 "$response"
  } > "$tmp"
  chmod 600 "$tmp" 2>/dev/null || true
  mv "$tmp" "$target" 2>/dev/null || rm -f "$tmp"
}

context_remaining_pct() {
  local thread codex_home session candidate sample input total window occupied
  thread="${CODEX_THREAD_ID:-}"
  [ -n "$thread" ] || { printf '?'; return; }
  codex_home="${CODEX_HOME:-${HOME:-}/.codex}"
  session=''
  for candidate in "$codex_home"/sessions/*/*/*/*-"$thread".jsonl; do
    [ -f "$candidate" ] || continue
    session="$candidate"
    break
  done
  [ -r "$session" ] || { printf '?'; return; }
  sample="$(tail -n 1000 "$session" 2>/dev/null | jq -c '
    select(.type == "event_msg" and .payload.type == "token_count")
    | [(.payload.info.last_token_usage.input_tokens // 0),
       (.payload.info.last_token_usage.total_tokens // 0),
       (.payload.info.model_context_window // 0)]
  ' 2>/dev/null | tail -n 1)"
  [ -n "$sample" ] || { printf '?'; return; }
  input="$(printf '%s\n' "$sample" | jq -r '.[0]')"
  total="$(printf '%s\n' "$sample" | jq -r '.[1]')"
  window="$(printf '%s\n' "$sample" | jq -r '.[2]')"
  case "$input:$total:$window" in *[!0-9:]*) printf '?'; return;; esac
  [ "$window" -gt 0 ] || { printf '?'; return; }
  if [ "$input" -gt 0 ]; then occupied="$input"; else occupied="$total"; fi
  awk -v used="$occupied" -v size="$window" 'BEGIN {
    remaining = 100 * (size - used) / size
    if (remaining < 0) remaining = 0
    if (remaining > 100) remaining = 100
    printf "%d", int(remaining + 0.5)
  }'
}

write_unknown() {
  local context
  context="$(context_remaining_pct)"
  HARNESS_PROJECT_ROOT="$ROOT" "$WRITER" orchestrator-update \
    --context-left-pct "$context" \
    --weekly-left-pct '?' --weekly-resets-at '?' \
    --credits-balance '?' --credits-delta '?' --credits-available '?' \
    --billing-route '?' --captured-at "$(date +%s)" >/dev/null 2>&1 || true
}

run_app_server() {
  if [ -n "${HARNESS_CODEX_APP_SERVER_CMD:-}" ]; then
    "$HARNESS_CODEX_APP_SERVER_CMD"
  elif [ -x "${HARNESS_CODEX_BIN:-}" ]; then
    "$HARNESS_CODEX_BIN" app-server
  else
    codex app-server
  fi
}

poll_once() {
  local tmpdir fifo output errors response pid deadline initialized found account weekly used reset
  local balance available unlimited previous delta route context now
  tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/agent-harness-codex-status.XXXXXX")" || { write_unknown; return 1; }
  fifo="$tmpdir/input"; output="$tmpdir/output"; errors="$tmpdir/errors"; response="$tmpdir/response"
  if ! mkfifo "$fifo"; then rmdir "$tmpdir"; write_unknown; return 1; fi
  : > "$output"; : > "$errors"; : > "$response"

  run_app_server < "$fifo" > "$output" 2> "$errors" &
  pid=$!
  exec 3> "$fifo"
  printf '%s\n' \
    '{"id":1,"method":"initialize","params":{"clientInfo":{"name":"agent-harness-live-status","version":"1"}}}' >&3

  deadline=$(( $(date +%s) + 5 )); initialized=false
  while :; do
    if jq -ce 'select(.id == 1)' "$output" 2>/dev/null | grep -q .; then
      initialized=true
      break
    fi
    kill -0 "$pid" 2>/dev/null || break
    if [ "$(date +%s)" -ge "$deadline" ]; then
      kill "$pid" 2>/dev/null || true
      break
    fi
    sleep 0.05
  done
  if [ "$initialized" != true ]; then
    record_failure initialize
    exec 3>&-
    wait "$pid" 2>/dev/null || true
    rm -f "$fifo" "$output" "$errors" "$response"; rmdir "$tmpdir"
    write_unknown
    return 1
  fi

  printf '%s\n' \
    '{"method":"initialized"}' \
    '{"id":2,"method":"account/rateLimits/read","params":null}' >&3

  deadline=$(( $(date +%s) + 5 )); found=false
  while :; do
    jq -ce 'select(.id == 2)' "$output" > "$response" 2>/dev/null || true
    if [ -s "$response" ]; then
      found=true
      kill "$pid" 2>/dev/null || true
      break
    fi
    kill -0 "$pid" 2>/dev/null || break
    if [ "$(date +%s)" -ge "$deadline" ]; then
      kill "$pid" 2>/dev/null || true
      break
    fi
    sleep 0.05
  done
  exec 3>&-
  wait "$pid" 2>/dev/null || true

  if [ "$found" != true ]; then
    record_failure rate_response
    rm -f "$fifo" "$output" "$errors" "$response"; rmdir "$tmpdir"
    write_unknown
    return 1
  fi

  account="$(jq -c '.result.rateLimitsByLimitId.codex // .result.rateLimits // empty' "$response" 2>/dev/null || true)"
  if [ -z "$account" ]; then
    record_failure account_payload
    rm -f "$fifo" "$output" "$errors" "$response"; rmdir "$tmpdir"
    write_unknown
    return 1
  fi
  weekly="$(printf '%s\n' "$account" | jq -c '
    ([.secondary, .primary] | map(select(. != null and .windowDurationMins == 10080)) | .[0])
    // (if ((.secondary.usedPercent | type) == "number") then .secondary else null end)
  ' 2>/dev/null || true)"
  used="$(printf '%s\n' "$weekly" | jq -r '.usedPercent // empty' 2>/dev/null || true)"
  reset="$(printf '%s\n' "$weekly" | jq -r '.resetsAt // empty' 2>/dev/null || true)"
  balance="$(printf '%s\n' "$account" | jq -r '.credits.balance // empty | tostring' 2>/dev/null || true)"
  available="$(printf '%s\n' "$account" | jq -r '
    .credits.hasCredits | if type == "boolean" then tostring else empty end
  ' 2>/dev/null || true)"
  unlimited="$(printf '%s\n' "$account" | jq -r '.credits.unlimited // false' 2>/dev/null || true)"

  case "$used" in ''|*[!0-9]*) used='?';; *) [ "$used" -le 100 ] || used='?';; esac
  case "$reset" in ''|*[!0-9]*) reset='?';; esac
  printf '%s' "$balance" | grep -Eq '^[0-9]+([.][0-9]+)?$' || balance='?'
  case "$available" in true|false) :;; *) available='?';; esac
  [ "$unlimited" = true ] && available=true

  if [ "$used" = '?' ]; then
    weekly='?'; route='?'
  else
    weekly=$((100 - used))
    if [ "$weekly" -gt 0 ]; then
      route=weekly
    elif [ "$available" = true ] && { [ "$unlimited" = true ] || awk -v n="$balance" 'BEGIN { exit !(n + 0 > 0) }'; }; then
      route=credits
    elif [ "$available" = false ]; then
      route=unavailable
    else
      route='?'
    fi
  fi

  previous="$(read_key "$ROOT/.harness/live-status.env" HARNESS_CODEX_CREDITS_BALANCE)"
  delta='?'
  if printf '%s' "$previous" | grep -Eq '^[0-9]+([.][0-9]+)?$' && [ "$balance" != '?' ]; then
    delta="$(awk -v current="$balance" -v old="$previous" 'BEGIN { printf "%.4f", current - old }')"
  fi
  context="$(context_remaining_pct)"
  now="$(date +%s)"
  HARNESS_PROJECT_ROOT="$ROOT" "$WRITER" orchestrator-update \
    --context-left-pct "$context" \
    --weekly-left-pct "$weekly" --weekly-resets-at "$reset" \
    --credits-balance "$balance" --credits-delta "$delta" --credits-available "$available" \
    --billing-route "$route" --captured-at "$now" >/dev/null 2>&1 || true

  rm -f "$fifo" "$output" "$errors" "$response"; rmdir "$tmpdir"
  rm -f "${HARNESS_CODEX_DIAGNOSTIC_FILE:-}"
  return 0
}

while :; do
  if poll_once; then
    delay="$INTERVAL"
  else
    delay="$RETRY_INTERVAL"
  fi
  [ "$INTERVAL" -gt 0 ] || break
  sleep "$delay"
done
