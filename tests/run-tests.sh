#!/usr/bin/env bash
# agent-harness 결정론 테스트. mux 불필요(거부 경로·파싱만). 사용법: bash tests/run-tests.sh
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok()   { pass=$((pass+1)); echo "PASS  $1"; }
bad()  { fail=$((fail+1)); echo "FAIL  $1"; }
# t <이름> <기대종료코드> <명령...>
t() {
  local name="$1" want="$2"; shift 2
  local out; out="$("$@" 2>&1)"; local got=$?
  if [ "$got" -eq "$want" ]; then ok "$name"; else bad "$name (exit=$got want=$want) :: $out"; fi
}
# 내부 운영 문서(docs/history, HANDOFF 등)는 working 저장소에만 존재한다.
# clean public release에는 없으므로 해당 검사는 SKIP으로 표시하고 건너뛴다.
HAS_INTERNAL_DOCS=0
[ -d "$ROOT/docs/history" ] && [ -f "$ROOT/HANDOFF.md" ] && HAS_INTERNAL_DOCS=1
# ti <이름> <기대종료코드> <명령...> — 내부 문서가 있을 때만 실행
ti() {
  if [ "$HAS_INTERNAL_DOCS" = 1 ]; then t "$@"
  else echo "SKIP  $1 (internal docs absent)"; fi
}

if [ "${B007_BUDGET_FOCUSED:-0}" = 1 ]; then
  DP="$ROOT/scripts/dispatch.sh"
  mkdir -p "$TMP/b007-bin"
  cat > "$TMP/b007-bin/cmux" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >> "$CMUX_CAPTURE"
case "$1" in ping) exit 0;; identify) printf '{"caller":{"workspace_ref":"workspace:1"}}\n';; new-split) printf 'surface:2\n';; *) exit 0;; esac
SH
  chmod +x "$TMP/b007-bin/cmux"
  cat > "$TMP/b007-models.yaml" <<'YAML'
roles:
  standard_worker:
    effort: medium
    candidates: [{name: fake, command: sh, args: ["-c"]}]
YAML
  b007_project() {
    local p="$1"
    mkdir -p "$p/log" "$p/agents" "$p/.harness/bin" "$p/.harness/lib" "$p/source"
    printf '**현재 단계:** 실행\nBUDGET_STOP: 없음\n' > "$p/STATUS.md"
    printf '**현재 단계:** 실행\nBUDGET_STOP: 없음\n' > "$p/log/HANDOFF.md"
    : > "$p/log/scaffold-check.pass"
    printf '#!/bin/sh\nexit 0\n' > "$p/.harness/bin/worker-wrap"; chmod +x "$p/.harness/bin/worker-wrap"
    printf 'validate_state() { :; }\n' > "$p/.harness/lib/state.sh"
    printf '완료 신호: log/T1.done\n' > "$p/agents/worker-T1.md"
    cat > "$p/tasks.yaml" <<'YAML'
contract_version: 3
execution_policy: {default_workers: 1, max_concurrent_workers: 3, max_delegation_depth: 0}
tasks:
  - id: T1
    name: budget worker
    execution: worker
    role: standard_worker
    effort: medium
    grade: T1
    ceremony: {design_approved: false, independent_review: false, full_regression: false, approval_gates: []}
    lean_gate: {decision: minimal, evidence: minimum}
    depends_on: []
    worktree: "."
    brief: agents/worker-T1.md
    status: pending
    run_id: ""
    budget: {concurrent_workers: 1, total_workers: 1, model_turns_per_worker: 99, model_runs: 1, edit_iterations: 0, related_test_runs: 0, full_test_runs: 0, max_input_tokens: 999, max_output_tokens: 999, changed_files: 99, changed_lines: 999, dependencies_added: 0}
YAML
    (cd "$p" && git init -q && git config user.name test && git config user.email test@example.invalid && git add . && git commit -qm base)
  }
  b007_project "$TMP/b007-first"
  b007_project "$TMP/b007-verification"
  yq -i '(.tasks[] | select(.id == "T1")).budget.related_test_runs = 2 | (.tasks[] | select(.id == "T1")).budget.full_test_runs = 2' "$TMP/b007-verification/tasks.yaml"
  t "B-007: related 검증은 --task 없이 명령을 실행하지 않는다" 0 bash -c \
    "cd '$TMP/b007-verification' && ! '$ROOT/scripts/verify-cache.sh' --cacheable --scope related no-task -- sh -c 'printf ran > command-ran' && [ ! -e command-ran ]"
  b007_project "$TMP/b007-legacy-verification"
  yq -i 'del(.contract_version) | del(.tasks[0].budget)' "$TMP/b007-legacy-verification/tasks.yaml"
  t "B-007: legacy 검증에는 예산을 소급 강제하지 않는다" 0 bash -c \
    "cd '$TMP/b007-legacy-verification' && '$ROOT/scripts/verify-cache.sh' --cacheable --task T1 --scope related legacy -- sh -c 'printf ok' > legacy.out \
     && grep -Fx 'VERIFY_CACHE MISS' legacy.out && [ ! -e log/verification-attempts/T1 ] && [ ! -e log/T1.budget-stop.yaml ]"
  t "B-007: 동일 검증은 MISS 뒤 HIT이고 시도 증거는 한 쌍만 남긴다" 0 bash -c \
    "cd '$TMP/b007-verification' && '$ROOT/scripts/verify-cache.sh' --cacheable --task T1 --scope related evidence -- sh -c 'printf ok' >/dev/null && '$ROOT/scripts/verify-cache.sh' --cacheable --task T1 --scope related evidence -- sh -c 'printf ok' > '$TMP/b007-verification-second.out' && grep -Fx 'VERIFY_CACHE HIT' '$TMP/b007-verification-second.out' && [ \"\$(find log/verification-attempts/T1 -name '*.intent.yaml' | wc -l | tr -d ' ')\" -eq 1 ] && [ \"\$(find log/verification-attempts/T1 -name '*.result.yaml' | wc -l | tr -d ' ')\" -eq 1 ] && [ \"\$(yq -r .receipt_id log/verification-attempts/T1/000001.intent.yaml)\" = evidence ] && [ \"\$(yq -r .receipt_id log/verification-attempts/T1/000001.result.yaml)\" = evidence ] && [ \"\$(yq -r .attempt log/verification-attempts/T1/000001.result.yaml)\" = 1 ]"
  b007_project "$TMP/b007-failed-verification"
  yq -i '(.tasks[] | select(.id == "T1")).budget.related_test_runs = 1' "$TMP/b007-failed-verification/tasks.yaml"
  t "B-007: 실패한 검증도 intent와 해시 결과를 남긴다" 0 bash -c \
    "cd '$TMP/b007-failed-verification' && set +e; '$ROOT/scripts/verify-cache.sh' --cacheable --task T1 --scope related failed -- sh -c 'exit 17' >/dev/null 2>&1; rc=\$?; set -e; [ \"\$rc\" = 17 ] && intent=\$(find log/verification-attempts/T1 -name '*.intent.yaml') && result=\$(find log/verification-attempts/T1 -name '*.result.yaml') && [ -f \"\$result\" ] && [ \"\$(yq -r .intent_sha256 \"\$result\")\" = \"\$(shasum -a 256 \"\$intent\" | awk '{print \$1}')\" ] && [ \"\$(yq -r .exit_code \"\$result\")\" = 17 ] && yq -r .started_at \"\$result\" | grep -Eq '^[0-9T:-]+Z$' && yq -r .finished_at \"\$result\" | grep -Eq '^[0-9T:-]+Z$'"
  b007_project "$TMP/b007-verification-mixed"
  yq -i '(.tasks[] | select(.id == "T1")).budget.related_test_runs = 2 | (.tasks[] | select(.id == "T1")).budget.full_test_runs = 1' "$TMP/b007-verification-mixed/tasks.yaml"
  t "B-007: related와 full 혼합 시도는 전역 순서를 유지하고 범위별로만 센다" 0 bash -c \
    "cd '$TMP/b007-verification-mixed' && '$ROOT/scripts/verify-cache.sh' --cacheable --task T1 --scope related r1 -- sh -c 'printf r1' >/dev/null && '$ROOT/scripts/verify-cache.sh' --cacheable --task T1 --scope full f1 -- sh -c 'printf f1' > '$TMP/b007-mixed-f1.out' && '$ROOT/scripts/verify-cache.sh' --cacheable --task T1 --scope related r2 -- sh -c 'printf r2' >/dev/null && '$ROOT/scripts/verify-cache.sh' --cacheable --task T1 --scope full f1 -- sh -c 'printf f1' > '$TMP/b007-mixed-f2.out' && grep -Fxq 'VERIFY_CACHE MISS' '$TMP/b007-mixed-f1.out' && grep -Fxq 'VERIFY_CACHE HIT' '$TMP/b007-mixed-f2.out' && [ \"\$(yq -r .scope log/verification-attempts/T1/000001.intent.yaml)\" = related ] && [ \"\$(yq -r .scope log/verification-attempts/T1/000002.intent.yaml)\" = full ] && [ \"\$(yq -r .scope log/verification-attempts/T1/000003.intent.yaml)\" = related ]"
  b007_project "$TMP/b007-verification-tamper"
  yq -i '(.tasks[] | select(.id == "T1")).budget.related_test_runs = 2' "$TMP/b007-verification-tamper/tasks.yaml"
  t "B-007: raw log 변조는 다음 명령 전에 durable stop으로 막는다" 0 bash -c \
    "cd '$TMP/b007-verification-tamper' && '$ROOT/scripts/verify-cache.sh' --cacheable --task T1 --scope related tamper -- sh -c 'printf ok' >/dev/null && result=\$(find log/verification-attempts/T1 -name '*.result.yaml') && raw=\$(yq -r .raw_log \"\$result\") && printf tamper > \"\$raw\" && ! '$ROOT/scripts/verify-cache.sh' --cacheable --task T1 --scope related tamper -- sh -c 'printf ran > command-ran' >/dev/null 2>&1 && [ ! -e command-ran ] && grep -Fq 'reason: attempt_evidence' log/T1.budget-stop.yaml"
  b007_project "$TMP/b007-verification-fingerprint-link"
  yq -i '(.tasks[] | select(.id == "T1")).budget.related_test_runs = 2' "$TMP/b007-verification-fingerprint-link/tasks.yaml"
  t "B-007: receipt 지문은 intent 지문과 다르면 다음 명령 전에 막는다" 0 bash -c \
    "cd '$TMP/b007-verification-fingerprint-link' && '$ROOT/scripts/verify-cache.sh' --cacheable --task T1 --scope related fingerprint -- sh -c 'printf ok' >/dev/null && result=\$(find log/verification-attempts/T1 -name '*.result.yaml') && receipt=\$(yq -r .receipt_path \"\$result\") && yq -i '.input_sha256 = \"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\" | .command_sha256 = \"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\" | .environment_sha256 = \"cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc\"' \"\$receipt\" && yq -i \".receipt_sha256 = \\\"\$(shasum -a 256 \"\$receipt\" | awk '{print \$1}')\\\"\" \"\$result\" && ! '$ROOT/scripts/verify-cache.sh' --cacheable --task T1 --scope related fingerprint-next -- sh -c 'printf ran > command-ran' >/dev/null 2>&1 && [ ! -e command-ran ] && grep -Fq 'reason: attempt_evidence' log/T1.budget-stop.yaml"
  b007_project "$TMP/b007-verification-metadata-link"
  yq -i '(.tasks[] | select(.id == "T1")).budget.related_test_runs = 2' "$TMP/b007-verification-metadata-link/tasks.yaml"
  t "B-007: receipt task와 scope는 intent와 다르면 다음 명령 전에 막는다" 0 bash -c \
    "cd '$TMP/b007-verification-metadata-link' && '$ROOT/scripts/verify-cache.sh' --cacheable --task T1 --scope related metadata -- sh -c 'printf ok' >/dev/null && result=\$(find log/verification-attempts/T1 -name '*.result.yaml') && receipt=\$(yq -r .receipt_path \"\$result\") && yq -i '.task = \"OTHER\" | .scope = \"full\"' \"\$receipt\" && yq -i \".receipt_sha256 = \\\"\$(shasum -a 256 \"\$receipt\" | awk '{print \$1}')\\\"\" \"\$result\" && ! '$ROOT/scripts/verify-cache.sh' --cacheable --task T1 --scope related metadata-next -- sh -c 'printf ran > command-ran' >/dev/null 2>&1 && [ ! -e command-ran ] && grep -Fq 'reason: attempt_evidence' log/T1.budget-stop.yaml"
  b007_project "$TMP/b007-verification-time-link"
  yq -i '(.tasks[] | select(.id == "T1")).budget.related_test_runs = 2' "$TMP/b007-verification-time-link/tasks.yaml"
  t "B-007: result 시각은 연결된 receipt 시각과 다르면 HIT 전에 막는다" 0 bash -c \
    "cd '$TMP/b007-verification-time-link' && '$ROOT/scripts/verify-cache.sh' --cacheable --task T1 --scope related time-link -- sh -c 'printf ok' >/dev/null && result=\$(find log/verification-attempts/T1 -name '*.result.yaml') && yq -i '.started_at = \"2000-01-01T00:00:00Z\" | .finished_at = \"2000-01-01T00:00:01Z\"' \"\$result\" && ! '$ROOT/scripts/verify-cache.sh' --cacheable --task T1 --scope related time-link -- sh -c 'printf ok' >/dev/null 2>&1 && grep -Fq 'reason: attempt_evidence' log/T1.budget-stop.yaml"
  b007_project "$TMP/b007-verification-interrupted"
  yq -i '(.tasks[] | select(.id == "T1")).budget.related_test_runs = 2' "$TMP/b007-verification-interrupted/tasks.yaml"
  t "B-007: result 없는 intent는 다음 명령 전에 interrupted stop으로 막는다" 0 bash -c \
    "cd '$TMP/b007-verification-interrupted' && '$ROOT/scripts/verify-cache.sh' --cacheable --task T1 --scope related interrupted -- sh -c 'printf ok' >/dev/null && result=\$(find log/verification-attempts/T1 -name '*.result.yaml') && mv \"\$result\" \"\$result.missing\" && ! '$ROOT/scripts/verify-cache.sh' --cacheable --task T1 --scope related interrupted -- sh -c 'printf ran > command-ran' >/dev/null 2>&1 && [ ! -e command-ran ] && grep -Fq 'reason: attempt_evidence' log/T1.budget-stop.yaml"
  b007_project "$TMP/b007-layout"
  t "B-007: invalid layout은 run·lock·reservation·prompt 없이 거부한다" 0 bash -c \
    "cd '$TMP/b007-layout' && ! PATH='$TMP/b007-bin:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin' CMUX_CAPTURE='$TMP/b007-layout.cmux' HARNESS_MODELS='$TMP/b007-models.yaml' HARNESS_LAYOUT=tiles bash '$DP' T1 >/dev/null 2>&1 && [ ! -e log/.locks/T1.dispatch ] && [ ! -e log/T1.runs ] && [ ! -e log/T1.prompt ] && [ ! -e log/T1.budget-stop.yaml ]"
  b007_project "$TMP/b007-no-mux"
  t "B-007: mux 부재는 run·lock·reservation·prompt 없이 거부한다" 0 bash -c \
    "cd '$TMP/b007-no-mux' && ! PATH='/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin' HARNESS_MODELS='$TMP/b007-models.yaml' bash '$DP' T1 >/dev/null 2>&1 && [ ! -e log/.locks/T1.dispatch ] && [ ! -e log/T1.runs ] && [ ! -e log/T1.prompt ] && [ ! -e log/T1.budget-stop.yaml ]"
  t "B-007: 첫 dispatch는 unknown usage와 advisory budget으로 막지 않는다" 0 bash -c \
    "cd '$TMP/b007-first' && PATH='$TMP/b007-bin:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin' CMUX_CAPTURE='$TMP/b007-first.cmux' HARNESS_MODELS='$TMP/b007-models.yaml' bash '$DP' T1 >/dev/null && grep -q 'event: dispatched' log/T1.runs"
  b007_project "$TMP/b007-runs"
  printf 'run_id: old event: dispatched at: 2026-07-16T00:00:00Z role: standard_worker cli: sh mux: cmux ws: workspace:1/surface:2 grade: T1 effort: medium contract: 3 context: legacy\n' > "$TMP/b007-runs/log/T1.runs"
  t "B-007: model_runs 한도는 모든 dispatch 부작용 전 stop만 남긴다" 0 bash -c \
    "cd '$TMP/b007-runs' && ! PATH='$TMP/b007-bin:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin' CMUX_CAPTURE='$TMP/b007-runs.cmux' HARNESS_MODELS='$TMP/b007-models.yaml' bash '$DP' T1 >/dev/null 2>&1 && [ ! -e log/T1.prompt ] && [ \"\$(wc -l < log/T1.runs | tr -d ' ')\" = 1 ] && ! grep -Eq '^(new-split|new-workspace)( |$)' '$TMP/b007-runs.cmux' && grep -Fq 'reason: model_runs' log/T1.budget-stop.yaml"
  b007_project "$TMP/b007-active"
  yq -i '(.tasks[] | select(.id == "T1")).budget.model_runs = 2' "$TMP/b007-active/tasks.yaml"
  printf 'run_id: old event: dispatched at: 2026-07-16T00:00:00Z role: standard_worker cli: sh mux: cmux ws: workspace:1/surface:2 grade: T1 effort: medium contract: 3 context: legacy\n' > "$TMP/b007-active/log/T1.runs"
  t "B-007: unfinished run은 concurrent_workers 한도에서 pane 전에 멈춘다" 0 bash -c \
    "cd '$TMP/b007-active' && ! PATH='$TMP/b007-bin:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin' CMUX_CAPTURE='$TMP/b007-active.cmux' HARNESS_MODELS='$TMP/b007-models.yaml' bash '$DP' T1 >/dev/null 2>&1 && [ ! -e log/T1.prompt ] && ! grep -Eq '^(new-split|new-workspace)( |$)' '$TMP/b007-active.cmux' && grep -Fq 'reason: concurrent_workers' log/T1.budget-stop.yaml"
  b007_project "$TMP/b007-diff"
  yq -i '(.tasks[] | select(.id == "T1")).budget.changed_files = 1 | (.tasks[] | select(.id == "T1")).budget.changed_lines = 1' "$TMP/b007-diff/tasks.yaml"
  (cd "$TMP/b007-diff" && printf 'one\ntwo' > source/staged && git add source/staged && printf '\nthree\n' >> source/staged && printf 'u\nv' > 'source/ space
-name')
  index_before="$(git -C "$TMP/b007-diff" write-tree)"
  t "B-007: staged+unstaged+NUL-safe untracked와 마지막 줄을 index 변경 없이 센다" 0 bash -c \
    "cd '$TMP/b007-diff' && ! PATH='$TMP/b007-bin:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin' CMUX_CAPTURE='$TMP/b007-diff.cmux' HARNESS_MODELS='$TMP/b007-models.yaml' bash '$DP' T1 >/dev/null 2>&1 && grep -Fq 'reason: changed_files' log/T1.budget-stop.yaml && [ '$index_before' = \"\$(git write-tree)\" ]"
  b007_project "$TMP/b007-lines"
  yq -i '(.tasks[] | select(.id == "T1")).budget.changed_files = 99 | (.tasks[] | select(.id == "T1")).budget.changed_lines = 1' "$TMP/b007-lines/tasks.yaml"
  printf 'one\ntwo\nthree\n' > "$TMP/b007-lines/source/line-overflow"
  t "B-007: changed_lines는 changed_files와 독립적으로 dispatch를 막는다" 0 bash -c \
    "cd '$TMP/b007-lines' && ! PATH='$TMP/b007-bin:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin' CMUX_CAPTURE='$TMP/b007-lines.cmux' HARNESS_MODELS='$TMP/b007-models.yaml' bash '$DP' T1 >/dev/null 2>&1 && grep -Fq 'reason: changed_lines' log/T1.budget-stop.yaml"
  b007_project "$TMP/b007-advisory"
  printf '{\"dependencies\": {\"new-package\": \"1.0.0\"}}\n' > "$TMP/b007-advisory/package.json"
  t "B-007: dependencies_added는 manifest 변경에도 advisory라 dispatch를 막지 않는다" 0 bash -c \
    "cd '$TMP/b007-advisory' && PATH='$TMP/b007-bin:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin' CMUX_CAPTURE='$TMP/b007-advisory.cmux' HARNESS_MODELS='$TMP/b007-models.yaml' bash '$DP' T1 >/dev/null && grep -q 'event: dispatched' log/T1.runs"
  b007_project "$TMP/b007-fingerprint-a"
  b007_project "$TMP/b007-fingerprint-b"
  yq -i '(.tasks[] | select(.id == "T1")).budget.changed_files = 0' "$TMP/b007-fingerprint-a/tasks.yaml"
  yq -i '(.tasks[] | select(.id == "T1")).budget.changed_files = 0' "$TMP/b007-fingerprint-b/tasks.yaml"
  printf 'first\n' > "$TMP/b007-fingerprint-a/source/same-path"
  printf 'second\n' > "$TMP/b007-fingerprint-b/source/same-path"
  t "B-007: 같은 untracked 경로의 내용 변경은 stop 지문을 바꾼다" 0 bash -c \
    "cd '$TMP/b007-fingerprint-a' && ! PATH='$TMP/b007-bin:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin' CMUX_CAPTURE='$TMP/b007-fingerprint-a.cmux' HARNESS_MODELS='$TMP/b007-models.yaml' bash '$DP' T1 >/dev/null 2>&1 && cd '$TMP/b007-fingerprint-b' && ! PATH='$TMP/b007-bin:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin' CMUX_CAPTURE='$TMP/b007-fingerprint-b.cmux' HARNESS_MODELS='$TMP/b007-models.yaml' bash '$DP' T1 >/dev/null 2>&1 && [ \"\$(yq -r .diff_fingerprint '$TMP/b007-fingerprint-a/log/T1.budget-stop.yaml')\" != \"\$(yq -r .diff_fingerprint '$TMP/b007-fingerprint-b/log/T1.budget-stop.yaml')\" ]"
  b007_project "$TMP/b007-bad"
  printf 'broken evidence\n' > "$TMP/b007-bad/log/T1.runs"
  t "B-007: malformed .runs는 삭제를 주장하지 않고 ambiguous로 멈춘다" 0 bash -c \
    "cd '$TMP/b007-bad' && ! PATH='$TMP/b007-bin:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin' CMUX_CAPTURE='$TMP/b007-bad.cmux' HARNESS_MODELS='$TMP/b007-models.yaml' bash '$DP' T1 >/dev/null 2>&1 && grep -Fq 'evidence_status: ambiguous' log/T1.budget-stop.yaml"
  b007_project "$TMP/b007-stop"
  printf 'version: 1\n' > "$TMP/b007-stop/log/T1.budget-stop.yaml"
  cp "$TMP/b007-stop/log/T1.budget-stop.yaml" "$TMP/b007-stop.before"
  t "B-007: 기존 stop은 다음 dispatch를 막는다" 0 bash -c \
    "cd '$TMP/b007-stop' && ! PATH='$TMP/b007-bin:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin' CMUX_CAPTURE='$TMP/b007-stop.cmux' HARNESS_MODELS='$TMP/b007-models.yaml' bash '$DP' T1 >/dev/null 2>&1 && cmp -s log/T1.budget-stop.yaml '$TMP/b007-stop.before' && [ ! -e log/T1.prompt ] && [ ! -e log/T1.runs ] && [ ! -e log/.locks/T1.dispatch ] && ! grep -Eq '^(new-split|new-workspace)( |$)' '$TMP/b007-stop.cmux'"
  b007_project "$TMP/b007-not-needed"
  yq -i '(.tasks[] | select(.id == "T1")).lean_gate.decision = "not-needed" | (.tasks[] | select(.id == "T1")).status = "skipped"' "$TMP/b007-not-needed/tasks.yaml"
  t "B-007: not-needed는 run·lock·reservation·stop 없이 거부한다" 0 bash -c \
    "cd '$TMP/b007-not-needed' && ! PATH='$TMP/b007-bin:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin' CMUX_CAPTURE='$TMP/b007-not-needed.cmux' HARNESS_MODELS='$TMP/b007-models.yaml' bash '$DP' T1 >/dev/null 2>&1 && [ ! -e log/.locks/T1.dispatch ] && [ ! -e log/T1.runs ] && [ ! -e log/T1.budget-stop.yaml ]"
  b007_project "$TMP/b007-effort"
  yq -i '(.tasks[] | select(.id == "T1")).effort = "low"' "$TMP/b007-effort/tasks.yaml"
  t "B-007: effort 불일치는 run·lock·reservation·stop 없이 거부한다" 0 bash -c \
    "cd '$TMP/b007-effort' && ! PATH='$TMP/b007-bin:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin' CMUX_CAPTURE='$TMP/b007-effort.cmux' HARNESS_MODELS='$TMP/b007-models.yaml' bash '$DP' T1 >/dev/null 2>&1 && [ ! -e log/.locks/T1.dispatch ] && [ ! -e log/T1.runs ] && [ ! -e log/T1.budget-stop.yaml ]"
  b007_project "$TMP/b007-prefix"
  printf 'run_id: old event: dispatched at: 2026-07-16T00:00:00Z role: standard_worker cli: sh mux: cmux ws: workspace:1/surface:2 grade: T1 effort: medium contract: 3 context: legacy\n' > "$TMP/b007-prefix/log/T1.runs"
  (cd "$TMP/b007-prefix" && git add log/T1.runs && git commit -qm anchor && : > log/T1.runs)
  t "B-007: committed .runs prefix 절단은 fail-closed한다" 0 bash -c \
    "cd '$TMP/b007-prefix' && ! PATH='$TMP/b007-bin:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin' CMUX_CAPTURE='$TMP/b007-prefix.cmux' HARNESS_MODELS='$TMP/b007-models.yaml' bash '$DP' T1 >/dev/null 2>&1 && grep -Fq 'reason: committed_prefix' log/T1.budget-stop.yaml"
  b007_project "$TMP/b007-pane-fail"
  cat > "$TMP/b007-bin/cmux" <<'SH'
#!/bin/sh
case "$1" in ping) exit 0;; identify) printf '{"caller":{"workspace_ref":"workspace:1"}}\n';; new-split) exit 1;; *) exit 0;; esac
SH
  chmod +x "$TMP/b007-bin/cmux"
  t "B-007: pane 실패는 같은 run의 reservation을 aborted로 닫는다" 0 bash -c \
    "cd '$TMP/b007-pane-fail' && ! PATH='$TMP/b007-bin:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin' CMUX_CAPTURE='$TMP/b007-pane-fail.cmux' HARNESS_MODELS='$TMP/b007-models.yaml' bash '$DP' T1 >/dev/null 2>&1 && grep -q 'event: budget_reserved' log/T1.runs && grep -q 'event: aborted' log/T1.runs && [ \"\$(awk '/event: budget_reserved/{print \$2}' log/T1.runs)\" = \"\$(awk '/event: aborted/{print \$2}' log/T1.runs)\" ] && [ ! -e log/.locks/T1.dispatch ]"
  b007_project "$TMP/b007-pane-foreign-lock"
  cat > "$TMP/b007-bin/cmux" <<'SH'
#!/bin/sh
case "$1" in
  ping) exit 0 ;;
  identify) printf '{"caller":{"workspace_ref":"workspace:1"}}\n' ;;
  new-split)
    mkdir log/.locks/T1.dispatch || exit 90
    printf 'foreign-pane-owner\n' > log/.locks/T1.dispatch/owner
    exit 1
    ;;
  *) exit 0 ;;
esac
SH
  chmod +x "$TMP/b007-bin/cmux"
  t "B-007: pane 실패 중 생긴 foreign lock은 보존하고 durable stop으로 닫힘 불가를 설명한다" 0 bash -c \
    "cd '$TMP/b007-pane-foreign-lock' && ! PATH='$TMP/b007-bin:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin' HARNESS_MODELS='$TMP/b007-models.yaml' bash '$DP' T1 >/dev/null 2>&1 && grep -q 'event: budget_reserved' log/T1.runs && ! grep -q 'event: aborted' log/T1.runs && grep -Fxq 'foreign-pane-owner' log/.locks/T1.dispatch/owner && grep -Fq 'reason: abort_lock_timeout' log/T1.budget-stop.yaml"
  b007_project "$TMP/b007-release-fail"
  cat > "$TMP/b007-bin/cmux" <<'SH'
#!/bin/sh
case "$1" in
  ping) exit 0 ;;
  identify) printf '{"caller":{"workspace_ref":"workspace:1"}}\n' ;;
  new-split) printf 'surface:2\n' ;;
  send)
    start_dir="$(printf '%s\n' "$*" | grep -o '/[^ ]*/log/\.dispatch-start\.[A-Za-z0-9]*' | head -1)"
    [ -z "$start_dir" ] || rmdir "$start_dir"
    ;;
esac
SH
  chmod +x "$TMP/b007-bin/cmux"
  t "B-007: dispatched 뒤 barrier release 실패도 같은 run을 aborted로 닫는다" 0 bash -c \
    "cd '$TMP/b007-release-fail' && ! PATH='$TMP/b007-bin:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin' HARNESS_MODELS='$TMP/b007-models.yaml' bash '$DP' T1 >/dev/null 2>&1 && [ \"\$(awk '/event: / {print \$4}' log/T1.runs)\" = \"budget_reserved
dispatched
aborted\" ] && [ \"\$(awk '/event: / {print \$2}' log/T1.runs | sort -u | wc -l | tr -d ' ')\" = 1 ] && [ ! -e log/.locks/T1.dispatch ]"
  cat > "$TMP/b007-bin/cmux" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >> "$CMUX_CAPTURE"
case "$1" in ping) exit 0;; identify) printf '{"caller":{"workspace_ref":"workspace:1"}}\n';; new-split) printf 'surface:2\n';; *) exit 0;; esac
SH
  chmod +x "$TMP/b007-bin/cmux"
  b007_project "$TMP/b007-barrier-foreign-lock"
  cat > "$TMP/b007-bin/cmux" <<'SH'
#!/bin/sh
case "$1" in
  ping) exit 0 ;;
  identify) printf '{"caller":{"workspace_ref":"workspace:1"}}\n' ;;
  new-split) printf 'surface:2\n' ;;
  send)
    start_dir="$(printf '%s\n' "$*" | grep -o '/[^ ]*/log/\.dispatch-start\.[A-Za-z0-9]*' | head -1)"
    [ -z "$start_dir" ] || rmdir "$start_dir"
    mkdir log/.locks/T1.dispatch || exit 91
    printf 'foreign-barrier-owner\n' > log/.locks/T1.dispatch/owner
    ;;
esac
SH
  chmod +x "$TMP/b007-bin/cmux"
  t "B-007: barrier 실패 중 생긴 foreign lock도 제거하지 않고 durable stop을 남긴다" 0 bash -c \
    "cd '$TMP/b007-barrier-foreign-lock' && ! PATH='$TMP/b007-bin:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin' HARNESS_MODELS='$TMP/b007-models.yaml' bash '$DP' T1 >/dev/null 2>&1 && grep -q 'event: budget_reserved' log/T1.runs && grep -q 'event: dispatched' log/T1.runs && ! grep -q 'event: aborted' log/T1.runs && grep -Fxq 'foreign-barrier-owner' log/.locks/T1.dispatch/owner && grep -Fq 'reason: abort_lock_timeout' log/T1.budget-stop.yaml"
  cat > "$TMP/b007-bin/cmux" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >> "$CMUX_CAPTURE"
case "$1" in ping) exit 0;; identify) printf '{"caller":{"workspace_ref":"workspace:1"}}\n';; new-split) printf 'surface:2\n';; *) exit 0;; esac
SH
  chmod +x "$TMP/b007-bin/cmux"
  b007_project "$TMP/b007-race"
  : > "$TMP/b007-race.cmux"
  t "B-007: 동시 dispatch는 하나만 예약·pane 생성하고 나머지는 stop으로 보존한다" 0 bash -c \
    "cd '$TMP/b007-race' || exit; (PATH='$TMP/b007-bin:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin' CMUX_CAPTURE='$TMP/b007-race.cmux' HARNESS_MODELS='$TMP/b007-models.yaml' bash '$DP' T1 >/dev/null 2>&1) & a=\$!; (PATH='$TMP/b007-bin:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin' CMUX_CAPTURE='$TMP/b007-race.cmux' HARNESS_MODELS='$TMP/b007-models.yaml' bash '$DP' T1 >/dev/null 2>&1) & b=\$!; wait \$a || true; wait \$b || true; [ \"\$(grep -c 'event: budget_reserved' log/T1.runs 2>/dev/null || printf 0)\" = 1 ] && [ \"\$(grep -c '^new-split ' '$TMP/b007-race.cmux')\" = 1 ] && grep -Fq 'reason: model_runs' log/T1.budget-stop.yaml && ! find log -name '.budget-stop.*' -o -path 'log/.locks/T1.dispatch' | grep -q ."
  b007_project "$TMP/b007-stale-lock"
  mkdir -p "$TMP/b007-stale-lock/log/.locks/T1.dispatch"
  t "B-007: stale lock은 제한 대기 뒤 0 아닌 lock_timeout stop으로 fail-closed한다" 0 bash -c \
    "cd '$TMP/b007-stale-lock' && ! PATH='$TMP/b007-bin:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin' CMUX_CAPTURE='$TMP/b007-stale-lock.cmux' HARNESS_MODELS='$TMP/b007-models.yaml' bash '$DP' T1 >/dev/null 2>&1 && [ -d log/.locks/T1.dispatch ] && grep -Fq 'reason: lock_timeout' log/T1.budget-stop.yaml && ! grep -Eq '^(measured|limit): 0$' log/T1.budget-stop.yaml && ! find log -name '.budget-stop.*' | grep -q ."
  b007_project "$TMP/b007-metrics-failure"
  mkdir -p "$TMP/b007-metrics-bin"
  cat > "$TMP/b007-metrics-bin/git" <<'SH'
#!/bin/sh
for arg do [ "$arg" = diff ] && exit 73; done
exec "$REAL_GIT" "$@"
SH
  chmod +x "$TMP/b007-metrics-bin/git"
  t "B-007: diff 증거 실패도 0 대신 changed_metrics stop으로 남긴다" 0 bash -c \
    "cd '$TMP/b007-metrics-failure' && ! PATH='$TMP/b007-metrics-bin:$TMP/b007-bin:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin' REAL_GIT='$(command -v git)' CMUX_CAPTURE='$TMP/b007-metrics-failure.cmux' HARNESS_MODELS='$TMP/b007-models.yaml' bash '$DP' T1 >/dev/null 2>&1 && grep -Fq 'reason: changed_metrics' log/T1.budget-stop.yaml && ! grep -Eq '^(measured|limit): 0$' log/T1.budget-stop.yaml"
  b007_project "$TMP/b007-ls-files-failure"
  cat > "$TMP/b007-metrics-bin/git" <<'SH'
#!/bin/sh
for arg do [ "$arg" = ls-files ] && exit 74; done
exec "$REAL_GIT" "$@"
SH
  chmod +x "$TMP/b007-metrics-bin/git"
  t "B-007: ls-files 증거 실패도 0 대신 changed_metrics stop으로 남긴다" 0 bash -c \
    "cd '$TMP/b007-ls-files-failure' && ! PATH='$TMP/b007-metrics-bin:$TMP/b007-bin:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin' REAL_GIT='$(command -v git)' CMUX_CAPTURE='$TMP/b007-ls-files-failure.cmux' HARNESS_MODELS='$TMP/b007-models.yaml' bash '$DP' T1 >/dev/null 2>&1 && grep -Fq 'reason: changed_metrics' log/T1.budget-stop.yaml && ! grep -Eq '^(measured|limit): 0$' log/T1.budget-stop.yaml"
  b007_project "$TMP/b007-show-failure"
  printf 'run_id: old event: dispatched at: 2026-07-16T00:00:00Z role: standard_worker cli: sh mux: cmux ws: workspace:1/surface:2 grade: T1 effort: medium contract: 3 context: legacy\n' > "$TMP/b007-show-failure/log/T1.runs"
  (cd "$TMP/b007-show-failure" && git add log/T1.runs && git commit -qm evidence)
  cat > "$TMP/b007-metrics-bin/git" <<'SH'
#!/bin/sh
for arg do [ "$arg" = show ] && exit 75; done
exec "$REAL_GIT" "$@"
SH
  chmod +x "$TMP/b007-metrics-bin/git"
  t "B-007: show 증거 실패도 0 대신 evidence stop으로 남긴다" 0 bash -c \
    "cd '$TMP/b007-show-failure' && ! PATH='$TMP/b007-metrics-bin:$TMP/b007-bin:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin' REAL_GIT='$(command -v git)' CMUX_CAPTURE='$TMP/b007-show-failure.cmux' HARNESS_MODELS='$TMP/b007-models.yaml' bash '$DP' T1 >/dev/null 2>&1 && grep -Fq 'reason: evidence' log/T1.budget-stop.yaml && ! grep -Eq '^(measured|limit): 0$' log/T1.budget-stop.yaml"
  b007_project "$TMP/b007-tree-failure"
  printf 'run_id: old event: dispatched at: 2026-07-16T00:00:00Z role: standard_worker cli: sh mux: cmux ws: workspace:1/surface:2 grade: T1 effort: medium contract: 3 context: legacy\n' > "$TMP/b007-tree-failure/log/T1.runs"
  cat > "$TMP/b007-metrics-bin/git" <<'SH'
#!/bin/sh
for arg do [ "$arg" = ls-tree ] && exit 76; done
exec "$REAL_GIT" "$@"
SH
  chmod +x "$TMP/b007-metrics-bin/git"
  t "B-007: committed .runs 판별 ls-tree 실패도 durable evidence stop으로 남긴다" 0 bash -c \
    "cd '$TMP/b007-tree-failure' && ! PATH='$TMP/b007-metrics-bin:$TMP/b007-bin:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin' REAL_GIT='$(command -v git)' CMUX_CAPTURE='$TMP/b007-tree-failure.cmux' HARNESS_MODELS='$TMP/b007-models.yaml' bash '$DP' T1 >/dev/null 2>&1 && grep -Fq 'reason: committed_evidence' log/T1.budget-stop.yaml"
  b007_project "$TMP/b007-stop-temp-failure"
  mkdir -p "$TMP/b007-ln-fail-bin"
  printf '#!/bin/sh\nexit 1\n' > "$TMP/b007-ln-fail-bin/ln"
  chmod +x "$TMP/b007-ln-fail-bin/ln"
  t "B-007: stop 게시 실패에도 temp가 남지 않는다" 0 bash -c \
    "cd '$TMP/b007-stop-temp-failure' && ! PATH='$TMP/b007-ln-fail-bin:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin' bash -c '. \"$ROOT/scripts/lib.sh\"; write_budget_stop T1 dispatch \$PWD 1 1 test ambiguous' && ! find log -name '.T1.budget-stop.*' | grep -q ."
  b007_project "$TMP/b007-stop-temp-signal"
  mkdir -p "$TMP/b007-signal-bin"
  cat > "$TMP/b007-signal-bin/ln" <<'SH'
#!/bin/sh
kill -TERM "$PPID"
sleep 1
exit 1
SH
  chmod +x "$TMP/b007-signal-bin/ln"
  t "B-007: stop 게시 중 신호에도 temp가 남지 않는다" 0 bash -c \
    "cd '$TMP/b007-stop-temp-signal' && ! PATH='$TMP/b007-signal-bin:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin' bash -c '. \"$ROOT/scripts/lib.sh\"; write_budget_stop T1 dispatch \$PWD 1 1 test ambiguous' >/dev/null 2>&1 && ! find log -name '.T1.budget-stop.*' | grep -q ."
  b007_project "$TMP/b007-tracked-text"
  (cd "$TMP/b007-tracked-text" && : > source/staged && printf 'old\n' > source/unstaged && printf 'gone\n' > source/deleted && git add source && git commit -qm tracked-fixture && printf 'one\n' > source/staged && git add source/staged && printf 'new\n' > source/unstaged && rm source/deleted)
  t "B-007: tracked regular staged·unstaged·삭제를 정확히 센다" 0 bash -c \
    "cd '$TMP/b007-tracked-text' && . '$ROOT/scripts/lib.sh' && budget_changed_metrics \$PWD && [ \"\$BUDGET_CHANGED_FILES/\$BUDGET_CHANGED_LINES\" = 3/4 ]"
  b007_project "$TMP/b007-staged-reversed"
  (cd "$TMP/b007-staged-reversed" && : > source/reversed && git add source/reversed && git commit -qm reversed-fixture && printf 'staged\n' > source/reversed && git add source/reversed && : > source/reversed)
  t "B-007: staged 변경을 worktree에서 되돌려도 파일과 양쪽 줄을 센다" 0 bash -c \
    "cd '$TMP/b007-staged-reversed' && . '$ROOT/scripts/lib.sh' && budget_changed_metrics \$PWD && [ \"\$BUDGET_CHANGED_FILES/\$BUDGET_CHANGED_LINES\" = 1/2 ]"
  b007_project "$TMP/b007-tracked-symlink"
  (cd "$TMP/b007-tracked-symlink" && printf a > source/a && printf b > source/b && ln -s a source/link && git add source && git commit -qm symlink-fixture && rm source/link && ln -s b source/link)
  t "B-007: tracked symlink target만 바뀌면 0/0이다" 0 bash -c \
    "cd '$TMP/b007-tracked-symlink' && . '$ROOT/scripts/lib.sh' && budget_changed_metrics \$PWD && [ \"\$BUDGET_CHANGED_FILES/\$BUDGET_CHANGED_LINES\" = 0/0 ]"
  b007_project "$TMP/b007-untracked-empty"
  : > "$TMP/b007-untracked-empty/source/empty"
  t "B-007: untracked empty regular만 있으면 1/0이다" 0 bash -c \
    "cd '$TMP/b007-untracked-empty' && . '$ROOT/scripts/lib.sh' && budget_changed_metrics \$PWD && [ \"\$BUDGET_CHANGED_FILES/\$BUDGET_CHANGED_LINES\" = 1/0 ]"
  b007_project "$TMP/b007-untracked-excluded"
  (cd "$TMP/b007-untracked-excluded" && printf '\000binary\n' > source/binary && ln -s binary source/link && mkfifo source/pipe)
  t "B-007: untracked binary·symlink·FIFO만 있으면 0/0이다" 0 bash -c \
    "cd '$TMP/b007-untracked-excluded' && . '$ROOT/scripts/lib.sh' && budget_changed_metrics \$PWD && [ \"\$BUDGET_CHANGED_FILES/\$BUDGET_CHANGED_LINES\" = 0/0 ]"
  b007_project "$TMP/b007-stop-all-actions"
  printf 'version: 1\ntask: T1\nreason: model_runs\n' > "$TMP/b007-stop-all-actions/log/T1.budget-stop.yaml"
  stop_state_sha="$(cd "$TMP/b007-stop-all-actions" && shasum -a 256 tasks.yaml STATUS.md log/HANDOFF.md)"
  t "B-007: 기존 stop은 dispatch와 검증을 모두 막고 상태 정본을 바꾸지 않는다" 0 bash -c \
    "cd '$TMP/b007-stop-all-actions' \
     && ! PATH='$TMP/b007-bin:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin' CMUX_CAPTURE='$TMP/b007-stop-all-actions.cmux' HARNESS_MODELS='$TMP/b007-models.yaml' bash '$DP' T1 >/dev/null 2>&1 \
     && ! '$ROOT/scripts/verify-cache.sh' --cacheable --task T1 --scope related stopped -- sh -c 'printf ran > command-ran' >/dev/null 2>&1 \
     && [ ! -e command-ran ] && [ ! -e log/verification-attempts/T1 ] \
     && [ \"\$(shasum -a 256 tasks.yaml STATUS.md log/HANDOFF.md)\" = '$stop_state_sha' ]"
  b007_project "$TMP/b007-stop-resume"
  printf 'run_id: old event: dispatched at: 2026-07-16T00:00:00Z role: standard_worker cli: sh mux: cmux ws: workspace:1/surface:2 grade: T1 effort: medium contract: 3 context: legacy\n' > "$TMP/b007-stop-resume/log/T1.runs"
  (cd "$TMP/b007-stop-resume" && git add log/T1.runs && git commit -qm used-budget)
  t "B-007: checkpoint된 stop 제거 뒤 원인이 남으면 새 지문으로 다시 stop" 0 bash -c \
    "cd '$TMP/b007-stop-resume' \
     && ! PATH='$TMP/b007-bin:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin' CMUX_CAPTURE='$TMP/b007-stop-resume.cmux' HARNESS_MODELS='$TMP/b007-models.yaml' bash '$DP' T1 >/dev/null 2>&1 \
     && old=\$(yq -r .diff_fingerprint log/T1.budget-stop.yaml) \
     && git add log/T1.budget-stop.yaml STATUS.md log/HANDOFF.md && git commit -qm budget-stop-checkpoint \
     && rm log/T1.budget-stop.yaml && printf changed > source/after-stop \
     && if PATH='$TMP/b007-bin:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin' CMUX_CAPTURE='$TMP/b007-stop-resume.cmux' HARNESS_MODELS='$TMP/b007-models.yaml' bash '$DP' T1 > second.out 2>&1; then exit 1; fi \
     && { [ -f log/T1.budget-stop.yaml ] || { cat second.out; exit 1; }; } \
     && new=\$(yq -r .diff_fingerprint log/T1.budget-stop.yaml) && [ \"\$new\" != \"\$old\" ]"
  t "B-007: 운영 문서는 stop 체크포인트 뒤에만 명시 승인 재개를 허용" 0 bash -c \
    "for f in doctrine/ORCHESTRATION.md skills/harness/SKILL.md template/HARNESS.md; do \
       grep -Fq 'budget-stop.yaml' '$ROOT/'\"\$f\" && grep -Fq 'STATUS.md' '$ROOT/'\"\$f\" \
         && grep -Fq '명시적 승인' '$ROOT/'\"\$f\" || exit 1; \
     done"
  t "B-007: usage receipt는 원본 해시가 있을 때만 사후 advisory" 0 bash -c \
    "for f in doctrine/ORCHESTRATION.md skills/harness/SKILL.md template/HARNESS.md template/tasks.yaml; do \
       grep -Fq 'normalized usage receipt' '$ROOT/'\"\$f\" \
         && grep -Fq 'source_sha256' '$ROOT/'\"\$f\" && grep -Fq '사후 advisory' '$ROOT/'\"\$f\" || exit 1; \
     done"
  b007_project "$TMP/b007-role-unavailable"
  yq -i '(.tasks[] | select(.id == "T1")).role = "missing"' "$TMP/b007-role-unavailable/tasks.yaml"
  t "B-007: 역할 후보가 없으면 run·lock·reservation·stop 없이 거부한다" 0 bash -c \
    "cd '$TMP/b007-role-unavailable' && ! PATH='$TMP/b007-bin:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin' CMUX_CAPTURE='$TMP/b007-role-unavailable.cmux' HARNESS_MODELS='$TMP/b007-models.yaml' bash '$DP' T1 >/dev/null 2>&1 && [ ! -e log/.locks/T1.dispatch ] && [ ! -e log/T1.runs ] && [ ! -e log/T1.budget-stop.yaml ]"
  echo; echo "결과: PASS=$pass FAIL=$fail"
  exit "$fail"
fi

if [ "${OPERATIONAL_INVARIANTS_FOCUSED:-0}" = 1 ] || [ "${B007_OPERATIONAL_FOCUSED:-0}" = 1 ]; then
  # 운영 불변식만 빠르게 확인한다. 이후의 전체 회귀 묶음은 실행하지 않는다.
  DP="$ROOT/scripts/dispatch.sh"
  MW="$ROOT/scripts/monitor-worker.sh"
  # shellcheck disable=SC2016 # $1·$START_DIR은 별도 Bash 프로세스에서 해석된다.
  t "dispatch: dispatched 기록은 release 게시보다 소스상 앞선다" 0 bash -c \
    'dispatched=$(awk "/event: dispatched/ {print NR; exit}" "$1"); release=$(awk "/: > \\\"\\\$START_DIR\\/release\\\"/ {print NR; exit}" "$1"); [ "$dispatched" -lt "$release" ]' _ "$DP"
  mkdir -p "$TMP/operational-bin"
  CMUXLOG="$TMP/operational-cmux.log"
  cat > "$TMP/operational-bin/cmux" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >> "$CMUXLOG"
start_command() {
  case "$1" in
    *".dispatch-start."*) sh -c "$1" >/dev/null 2>&1 & ;;
    *) sh -c "$1" ;;
  esac
}
case "$1" in
  ping) exit 0 ;;
  identify) printf '{"caller":{"workspace_ref":"workspace:5","surface_ref":"surface:70"}}\n' ;;
  new-split) [ "${CMUX_FAIL_SPLIT:-0}" = 1 ] && exit 1; printf 'surface:99\n' ;;
  new-workspace)
    while [ "$#" -gt 0 ]; do
      if [ "$1" = --command ]; then
        shift
        start_command "$1"
        break
      fi
      shift
    done
    printf 'workspace:88\n'
    ;;
  send)
    shift 3
    start_command "$1"
    ;;
  *) exit 0 ;;
esac
SH
  chmod +x "$TMP/operational-bin/cmux"
  OPERATIONAL_PATH="$TMP/operational-bin:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin"
  cat > "$TMP/operational-models.yaml" <<'YAML'
roles:
  standard_worker:
    effort: medium
    candidates:
      - name: fake-cli
        command: sh
        args: ["-c"]
YAML

  mk_operational_project() { # $1=project directory
    local p="$1"
    mkdir -p "$p/log" "$p/agents" "$p/source" "$p/.harness/bin" "$p/.harness/lib"
    : > "$p/log/scaffold-check.pass"
    cat > "$p/.harness/bin/worker-wrap" <<'SH'
#!/bin/sh
runs="$1"; run_id="$2"
printf '%s\n' "$run_id" > "$(dirname "$runs")/worker-wrap-invoked"
printf 'run_id: %s event: started at: 2026-07-15T00:00:01Z\n' "$run_id" >> "$runs"
printf 'run_id: %s event: finished at: 2026-07-15T00:00:02Z exit_code: 0\n' "$run_id" >> "$runs"
SH
    chmod +x "$p/.harness/bin/worker-wrap"
    printf 'validate_state() { :; }\n' > "$p/.harness/lib/state.sh"
    cat > "$p/tasks.yaml" <<'YAML'
tasks:
  - id: P1
    name: operational worker
    role: standard_worker
    depends_on: []
    worktree: "."
    brief: agents/worker-P1.md
YAML
    printf '완료 신호: log/P1.done\n' > "$p/agents/worker-P1.md"
  }

  cat > "$TMP/assert-operational-events.sh" <<'SH'
#!/bin/sh
set -eu
runs="$1"
i=0
while [ "$i" -lt 100 ] && [ "$(awk '/ event: / { count++ } END { print count + 0 }' "$runs" 2>/dev/null || true)" -lt 3 ]; do
  i=$((i + 1))
  sleep 0.02
done
[ "$(awk '/ event: / { print $4 }' "$runs")" = "dispatched
started
finished" ]
state="$(awk '
  $3 == "event:" && $4 == "dispatched" {
    rid=$2; started=""; finished=""; exit_code=""; next
  }
  $2 == rid && $3 == "event:" && $4 == "started"  {started=$6}
  $2 == rid && $3 == "event:" && $4 == "finished" {finished=$6; exit_code=$8}
  END {if (rid) printf "%s|%s|%s|%s", rid, started, finished, exit_code}
' "$runs")"
IFS='|' read -r run_id started finished exit_code <<EOF
$state
EOF
[ -n "$run_id" ] && [ -n "$started" ] && [ -n "$finished" ] && [ "$exit_code" = 0 ]
SH
  chmod +x "$TMP/assert-operational-events.sh"

  mk_operational_project "$TMP/operational-project"
  t "dispatch 기본: right pane만 만들고 workspace를 만들지 않는다" 0 bash -c \
    "cd '$TMP/operational-project' && : > '$CMUXLOG' && PATH='$OPERATIONAL_PATH' CMUXLOG='$CMUXLOG' HARNESS_MODELS='$TMP/operational-models.yaml' bash '$DP' P1 > '$TMP/operational-default.out' \
     && grep -Fxq 'new-split right --workspace workspace:5' '$CMUXLOG' && ! grep -Fq 'new-workspace' '$CMUXLOG' \
     && grep -Fq 'workspace:5/surface:99 (right)' '$TMP/operational-default.out' \
     && grep -Fq 'mux: cmux ws: workspace:5/surface:99 (right)' log/P1.runs \
     && '$TMP/assert-operational-events.sh' log/P1.runs"
  t "dispatch workspace: 명시하면 새 workspace 호환 경로를 쓴다" 0 bash -c \
    "cd '$TMP/operational-project' && rm -f log/P1.runs && : > '$CMUXLOG' && PATH='$OPERATIONAL_PATH' CMUXLOG='$CMUXLOG' HARNESS_MODELS='$TMP/operational-models.yaml' HARNESS_LAYOUT=workspace bash '$DP' P1 >/dev/null \
     && grep -Fq 'new-workspace' '$CMUXLOG' && ! grep -Fq 'new-split' '$CMUXLOG' \
     && grep -Fq 'mux: cmux ws: workspace:88' log/P1.runs \
     && '$TMP/assert-operational-events.sh' log/P1.runs"
  mkdir -p "$TMP/operational-tmux-bin"
  cat > "$TMP/operational-tmux-bin/tmux" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >> "$TMUXLOG"
for command do :; done
case "$command" in
  *".dispatch-start."*) sh -c "$command" >/dev/null 2>&1 & ;;
  *) sh -c "$command" ;;
esac
SH
  chmod +x "$TMP/operational-tmux-bin/tmux"
  TMUX_PATH="$TMP/operational-tmux-bin:$(dirname "$(command -v yq)"):/usr/bin:/bin"
  t "dispatch tmux: legacy 위치 증거를 유지한다" 0 bash -c \
    "cd '$TMP/operational-project' && rm -f log/P1.runs && : > '$TMP/operational-tmux.log' && PATH='$TMUX_PATH' TMUXLOG='$TMP/operational-tmux.log' HARNESS_MODELS='$TMP/operational-models.yaml' bash '$DP' P1 >/dev/null \
     && grep -Fq 'new-session -d -s hx-P1' '$TMP/operational-tmux.log' \
     && grep -Fq 'mux: tmux ws: hx-P1' log/P1.runs \
     && '$TMP/assert-operational-events.sh' log/P1.runs"
  t "dispatch pane: surface 생성 실패면 dispatched 증거를 남기지 않는다" 0 bash -c \
    "cd '$TMP/operational-project' && rm -f log/P1.runs log/worker-wrap-invoked && : > '$CMUXLOG' && set +e; PATH='$OPERATIONAL_PATH' CMUXLOG='$CMUXLOG' CMUX_FAIL_SPLIT=1 HARNESS_MODELS='$TMP/operational-models.yaml' bash '$DP' P1 >/dev/null 2>&1; rc=\$?; set -e; sleep 0.1; [ \"\$rc\" = 1 ] && [ ! -e log/P1.runs ] && [ ! -e log/worker-wrap-invoked ] && ! find log -maxdepth 1 -name '.dispatch-start.*' | grep -q ."
  t "dispatch 기록 실패: worker-wrap을 시작하지 않고 barrier를 정리한다" 0 bash -c \
    "cd '$TMP/operational-project' && rm -f log/worker-wrap-invoked && rm -rf log/P1.runs && mkdir log/P1.runs && set +e; PATH='$OPERATIONAL_PATH' CMUXLOG='$CMUXLOG' HARNESS_MODELS='$TMP/operational-models.yaml' bash '$DP' P1 >/dev/null 2>&1; rc=\$?; set -e; sleep 0.1; [ \"\$rc\" = 1 ] && [ ! -e log/worker-wrap-invoked ] && ! find log -maxdepth 1 -name '.dispatch-start.*' | grep -q .; rm -rf log/P1.runs"
  t "dispatch layout: 잘못된 값은 cmux 호출 전에 거부한다" 0 bash -c \
    "cd '$TMP/operational-project' && : > '$CMUXLOG' && set +e; PATH='$OPERATIONAL_PATH' CMUXLOG='$CMUXLOG' HARNESS_MODELS='$TMP/operational-models.yaml' HARNESS_LAYOUT=tiles bash '$DP' P1 >/dev/null 2>&1; rc=\$?; set -e; [ \"\$rc\" = 1 ] && [ ! -s '$CMUXLOG' ]"
  t "doctrine: 기본 pane과 명시 workspace 경로를 설명한다" 0 bash -c \
    "grep -Fq 'HARNESS_LAYOUT=pane' '$ROOT/doctrine/ORCHESTRATION.md' && grep -Fq 'HARNESS_LAYOUT=workspace' '$ROOT/doctrine/ORCHESTRATION.md'"

  mkdir -p "$TMP/operational-monitor-bin" "$TMP/operational-worktree"
  MONITORLOG="$TMP/operational-monitor.log"
  cat > "$TMP/operational-monitor-bin/cmux" <<'SH'
#!/bin/sh
printf 'cmux %s\n' "$*" >> "$MONITORLOG"
printf 'selected screen\n'
SH
  cat > "$TMP/operational-monitor-bin/git" <<'SH'
#!/bin/sh
printf 'git locks=%s %s\n' "${GIT_OPTIONAL_LOCKS:-}" "$*" >> "$MONITORLOG"
case "$3" in
  rev-parse) [ -f "$2/.git/HEAD" ] || exit 1; printf 'true\n' ;;
  status) printf '## feature/test\n' ;;
  log) printf 'abc123 latest commit\n' ;;
esac
SH
  chmod +x "$TMP/operational-monitor-bin/cmux" "$TMP/operational-monitor-bin/git"
  (cd "$TMP/operational-worktree" && git init -q)
  MONITOR_PATH="$TMP/operational-monitor-bin:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin"
  t "monitor: 지정 surface와 worktree만 읽는다" 0 bash -c \
    ": > '$MONITORLOG' && PATH='$MONITOR_PATH' MONITORLOG='$MONITORLOG' bash '$MW' workspace:5 surface:99 '$TMP/operational-worktree' > '$TMP/operational-monitor.out' \
     && grep -Fxq 'cmux read-screen --workspace workspace:5 --surface surface:99 --scrollback --lines 80' '$MONITORLOG' \
     && grep -Fxq 'git locks=0 -C $TMP/operational-worktree rev-parse --is-inside-work-tree' '$MONITORLOG' \
     && grep -Fxq 'git locks=0 -C $TMP/operational-worktree status --short --branch' '$MONITORLOG' \
     && grep -Fxq 'git locks=0 -C $TMP/operational-worktree log -1 --oneline' '$MONITORLOG' \
     && [ \"\$(wc -l < '$MONITORLOG' | tr -d ' ')\" = 4 ]"
  mkdir -p "$TMP/operational-empty-git/.git"
  t "monitor: 빈 .git은 cmux를 읽기 전에 거부한다" 0 bash -c \
    ": > '$MONITORLOG' && set +e; PATH='$MONITOR_PATH' MONITORLOG='$MONITORLOG' bash '$MW' workspace:5 surface:99 '$TMP/operational-empty-git' >/dev/null 2>&1; rc=\$?; set -e; [ \"\$rc\" = 1 ] && ! grep -q '^cmux ' '$MONITORLOG' && grep -Fq 'git locks=0 -C $TMP/operational-empty-git rev-parse --is-inside-work-tree' '$MONITORLOG'"
  for monitor_case in 'workspace bad:5 surface:99' 'workspace:5 surface bad:99' 'workspace:5 surface:99 missing'; do
    IFS=' ' read -r monitor_workspace monitor_surface monitor_worktree <<EOF
$monitor_case
EOF
    t "monitor: $monitor_worktree 입력은 cmux/git 호출 전에 거부한다" 0 bash -c \
      ": > '$MONITORLOG' && set +e; PATH='$MONITOR_PATH' MONITORLOG='$MONITORLOG' bash '$MW' '$monitor_workspace' '$monitor_surface' '$TMP/$monitor_worktree' >/dev/null 2>&1; rc=\$?; set -e; [ \"\$rc\" = 1 ] && [ ! -s '$MONITORLOG' ]"
  done
  t "monitor: ps로 워커 상태를 추측하지 않는다" 0 bash -c \
    "! rg -n '(^|[;&|[:space:]])ps([[:space:];&|]|\$)' '$MW'"
  echo; echo "결과: PASS=$pass FAIL=$fail"
  exit "$fail"
fi

if [ "${B006_CONTEXT_LOADING_FOCUSED:-0}" != 1 ]; then
# --- contract-native Lean Gate review fix: focused RED/GREEN block ---
mk_review_v3_contract() { # $1=YAML path
  cat > "$1" <<'YAML'
contract_version: 3
execution_policy:
  default_workers: 1
  max_concurrent_workers: 3
  max_delegation_depth: 0
tasks:
  - id: T0
    lean_gate:
      decision: minimal
      evidence: valid
    execution: deterministic
    role: none
    grade: T0
    effort: none
    ceremony: {design_approved: false, independent_review: false, full_regression: false, approval_gates: []}
    budget: {concurrent_workers: 0, total_workers: 0, model_turns_per_worker: 0, model_runs: 0, edit_iterations: 0, related_test_runs: 0, full_test_runs: 0, max_input_tokens: 0, max_output_tokens: 0, changed_files: 0, changed_lines: 0, dependencies_added: 0}
YAML
}
for evidence in '[]' '{}' 'true'; do
  fixture="$TMP/review-v3-evidence-${evidence//[^[:alnum:]]/x}.yaml"
  mk_review_v3_contract "$fixture"
  yq -i ".tasks[0].lean_gate.evidence = $evidence" "$fixture"
  t "execution contract v3: evidence $evidence 는 YAML 문자열이 아니므로 FAIL" 1 bash -c \
    ". '$ROOT/scripts/lib.sh'; validate_execution_contract '$fixture'"
done
t "docs: deterministic T0는 직접 실행 직전에 v3 계약을 검증하고 dispatch를 우회" 0 bash -c \
  "grep -Fq '. scripts/lib.sh && validate_execution_contract \"\$PWD/tasks.yaml\"' '$ROOT/skills/harness/SKILL.md' \\
   && grep -Fq 'deterministic T0는 \`scripts/dispatch.sh\`를 거치지 않는다' '$ROOT/skills/harness/SKILL.md'"
if [ "${CONTRACT_NATIVE_LEAN_GATE_REVIEW_FIX_FOCUSED:-0}" = 1 ]; then
  echo; echo "결과: PASS=$pass FAIL=$fail"
  exit "$fail"
fi

# --- B-006: receipt policy contract/document focused RED/GREEN block ---
mk_receipt_contract_project() { # $1=scaffold project $2=cacheable YAML or missing
  local p="$1" value="$2" f
  rm -rf "$p"; cp -R "$ROOT/template" "$p"
  for f in HARNESS.md STATUS.md log/HANDOFF.md; do
    sed -i.bak 's/{{[^}]*}}/기입됨/g' "$p/$f" && rm -f "$p/$f.bak"
  done
  cat > "$p/tasks.yaml" <<'YAML'
tasks:
  - id: A
    name: receipt contract
    role: standard_worker
    grade: T1
    depends_on: []
    worktree: "."
    write_paths: []
    done_when: log/A.done
    on_fail: hold_downstream
    status: pending
    brief: agents/worker-A.md
    verify:
      command: sh
      args: []
YAML
  printf '임무: receipt\n산출물: source/out.txt\n쓰기 허용 경로: source/\n완료 신호: log/A.done\n' \
    > "$p/agents/worker-A.md"
  if [ "$value" != missing ]; then
    yq -i ".tasks[0].verify.cacheable = $value" "$p/tasks.yaml"
  fi
  (cd "$p" && git init -q && git config user.name harness-test \
    && git config user.email harness-test@example.invalid \
    && git add -A && git commit -qm init)
}

SC="$ROOT/scripts/scaffold-check.sh"
receipt_cacheable_accepts() {
  local value p
  for value in missing true false; do
    p="$TMP/cacheable-ok-$value"
    mk_receipt_contract_project "$p" "$value"
    (cd "$p" && bash "$SC" >/dev/null) || return 1
  done
}
receipt_cacheable_rejects_non_boolean() {
  local value key p
  for value in '"true"' 1 null; do
    key="$(printf %s "$value" | tr -cd '[:alnum:]')"
    p="$TMP/cacheable-bad-$key"
    mk_receipt_contract_project "$p" "$value"
    if (cd "$p" && bash "$SC" >/dev/null 2>&1); then return 1; fi
  done
}
t "scaffold-check: verify.cacheable은 boolean 또는 생략만 허용" 0 \
  receipt_cacheable_accepts
t "scaffold-check: verify.cacheable의 문자열·숫자·null은 거부" 0 \
  receipt_cacheable_rejects_non_boolean
t "docs: 시간·네트워크·외부 상태 의존 검증의 자동 재사용을 금지" 0 bash -c \
  "for f in doctrine/ORCHESTRATION.md skills/harness/SKILL.md; do \
     grep -Fq '시간·네트워크·외부 상태에' '$ROOT/'\"\$f\" \
       && grep -Fq '의존하는 검증은 자동 재사용하지 않는다' '$ROOT/'\"\$f\" || exit 1; \
   done"
t "docs: cold raw log와 durable receipt의 역할을 구분" 0 bash -c \
  "grep -Fq 'cold raw log' '$ROOT/template/HARNESS.md' \
   && grep -Fq 'durable receipt' '$ROOT/template/HARNESS.md'"
ti "docs: cold raw log와 durable receipt 구분이 설계 스펙에 동기화" 0 bash -c \
  "grep -Fq 'cold raw log' '$ROOT/docs/superpowers/specs/2026-07-12-agent-harness-design.md' \
   && grep -Fq 'durable receipt' '$ROOT/docs/superpowers/specs/2026-07-12-agent-harness-design.md'"
t "docs: T2/T3 리뷰어는 최종 full receipt를 소비하고 전체 suite를 재실행하지 않음" 0 bash -c \
  "for f in doctrine/ORCHESTRATION.md skills/harness/SKILL.md template/HARNESS.md; do \
     grep -Fq 'T2/T3 독립 리뷰어는 최종 full receipt를 소비하고 전체 suite를' '$ROOT/'\"\$f\" \
       && grep -Fq '재실행하지 않는다' '$ROOT/'\"\$f\" || exit 1; \
   done"
ti "docs: T2/T3 리뷰어 receipt 소비 규칙이 설계 스펙에 동기화" 0 bash -c \
  "grep -Fq 'T2/T3 독립 리뷰어는 최종 full receipt를 소비하고 전체 suite를' \
     '$ROOT/docs/superpowers/specs/2026-07-12-agent-harness-design.md' \
   && grep -Fq '재실행하지 않는다' '$ROOT/docs/superpowers/specs/2026-07-12-agent-harness-design.md'"
if [ "${B006_RECEIPTS_CONTRACT_FOCUSED:-0}" = 1 ]; then
  echo; echo "결과: PASS=$pass FAIL=$fail"
  exit "$fail"
fi

# --- B-006: verification receipt runner focused RED/GREEN block ---
mk_receipt_project() { # $1=Git project with a deterministic counter command
  local p="$1"
  mkdir -p "$p"
  (cd "$p" && git init -q && git config user.name harness-test \
    && git config user.email harness-test@example.invalid)
cat > "$p/.gitignore" <<'EOF'
counter
check.sh
log/cold/
EOF
  printf 'tracked input\n' > "$p/input.txt"
  cat > "$p/tasks.yaml" <<'YAML'
contract_version: 3
tasks:
  - id: T-001
    budget:
      related_test_runs: 99
      full_test_runs: 99
      changed_files: 999
      changed_lines: 99999
YAML
  cat > "$p/check.sh" <<'SH'
#!/usr/bin/env bash
set -eu
count="$(cat counter 2>/dev/null || printf 0)"
printf '%s\n' "$((count + 1))" > counter
printf 'checked %s\n' "${1:-default}"
SH
  chmod +x "$p/check.sh"
  (cd "$p" && git add . && git commit -qm init)
}

RC="$ROOT/scripts/verify-cache.sh"
mk_receipt_project "$TMP/receipt-index-failure"
mkdir "$TMP/fakebin-index-failure"
mkdir "$TMP/index-failure-tmp" "$TMP/index-success-tmp"
cat > "$TMP/fakebin-index-failure/git" <<'SH'
#!/bin/sh
for arg do [ "$arg" = write-tree ] && exit 42; done
exec "$REAL_GIT" "$@"
SH
chmod +x "$TMP/fakebin-index-failure/git"
real_git="$(command -v git)"
t "lib: 임시 Git tree 실패는 원래 오류만 보존" 0 bash -c \
  "set +e; PATH='$TMP/fakebin-index-failure':\$PATH TMPDIR='$TMP/index-failure-tmp' REAL_GIT='$real_git' bash -c \
     '. \"\$1/scripts/lib.sh\"; workspace_tree_sha256 \"\$2\"' _ '$ROOT' '$TMP/receipt-index-failure' > '$TMP/index-failure.out' 2>&1; rc=\$?; set -e \
   && [ \"\$rc\" = 1 ] && [ \"\$(cat '$TMP/index-failure.out')\" = 'ERROR: 임시 Git tree 생성 실패' ] \
   && ! find '$TMP/index-failure-tmp' -type f -name 'agent-harness-index.*' | grep -q . \
   || { cat '$TMP/index-failure.out'; exit 1; }"
t "lib: 임시 Git tree 성공 뒤 index를 남기지 않음" 0 bash -c \
  "TMPDIR='$TMP/index-success-tmp' bash -c '. \"\$1/scripts/lib.sh\"; workspace_tree_sha256 \"\$2\" >/dev/null' _ '$ROOT' '$TMP/receipt-index-failure' \
   && ! find '$TMP/index-success-tmp' -type f -name 'agent-harness-index.*' | grep -q ."
mk_receipt_project "$TMP/receipt-cache"
t "verify-cache: 첫 cacheable 실행은 MISS이며 명령을 한 번 실행" 0 bash -c \
  "cd '$TMP/receipt-cache' && '$RC' --cacheable --task T-001 --scope related receipt-a -- ./check.sh one > '$TMP/receipt-cache-first.out' \
   && grep -Fx 'VERIFY_CACHE MISS' '$TMP/receipt-cache-first.out' && [ \"\$(cat counter)\" = 1 ]"
t "verify-cache: 같은 입력은 HIT이며 명령을 재실행하지 않음" 0 bash -c \
  "cd '$TMP/receipt-cache' && '$RC' --cacheable --task T-001 --scope related receipt-a -- ./check.sh one > '$TMP/receipt-cache-second.out' \
   && grep -Fx 'VERIFY_CACHE HIT' '$TMP/receipt-cache-second.out' && [ \"\$(cat counter)\" = 1 ]"
mk_receipt_project "$TMP/receipt-env"
t "verify-cache: 선언한 환경 변수는 같은 값 HIT, 값·unset·empty 변경은 MISS" 0 bash -c \
  "cd '$TMP/receipt-env' \
   && B006_RECEIPTS_ENV=one '$RC' --cacheable --env B006_RECEIPTS_ENV --task T-001 --scope related receipt-env -- ./check.sh > '$TMP/receipt-env-one-first.out' \
   && B006_RECEIPTS_ENV=one '$RC' --cacheable --env B006_RECEIPTS_ENV --task T-001 --scope related receipt-env -- ./check.sh > '$TMP/receipt-env-one-second.out' \
   && B006_RECEIPTS_ENV=two '$RC' --cacheable --env B006_RECEIPTS_ENV --task T-001 --scope related receipt-env -- ./check.sh > '$TMP/receipt-env-two.out' \
   && env -u B006_RECEIPTS_ENV '$RC' --cacheable --env B006_RECEIPTS_ENV --task T-001 --scope related receipt-env -- ./check.sh > '$TMP/receipt-env-unset.out' \
   && B006_RECEIPTS_ENV='' '$RC' --cacheable --env B006_RECEIPTS_ENV --task T-001 --scope related receipt-env -- ./check.sh > '$TMP/receipt-env-empty.out' \
   && grep -hFx 'VERIFY_CACHE MISS' '$TMP/receipt-env-one-first.out' '$TMP/receipt-env-two.out' '$TMP/receipt-env-unset.out' '$TMP/receipt-env-empty.out' \
   && grep -Fx 'VERIFY_CACHE HIT' '$TMP/receipt-env-one-second.out' \
   && [ \"\$(cat counter)\" = 4 ] \
   && receipt=\$(find log/receipts -name 'receipt-env-*.yaml' | head -1) \
   && ! yq -e 'has(\"declared_env_value\")' \"\$receipt\" >/dev/null"
t "verify-cache: 안전하지 않은 선언 환경 변수 이름을 거부" 0 bash -c \
  "cd '$TMP/receipt-env' && ! '$RC' --cacheable --env 'B006-UNSAFE' --scope related receipt-env-unsafe -- ./check.sh >/dev/null 2>&1"
mk_receipt_project "$TMP/receipt-no-task"
t "verify-cache: other scope는 --task 없이 MISS 뒤 HIT" 0 bash -c \
  "cd '$TMP/receipt-no-task' \
   && '$RC' --cacheable --scope other receipt-no-task -- ./check.sh > '$TMP/receipt-no-task-first.out' \
   && '$RC' --cacheable --scope other receipt-no-task -- ./check.sh > '$TMP/receipt-no-task-second.out' \
   && receipt=\$(find log/receipts -name 'receipt-no-task-*.yaml') \
   && grep -Fx 'VERIFY_CACHE MISS' '$TMP/receipt-no-task-first.out' \
   && grep -Fx 'VERIFY_CACHE HIT' '$TMP/receipt-no-task-second.out' \
   && [ \"\$(cat counter)\" = 1 ] \
   && yq -e '.task == \"\" and (.task | tag == \"!!str\")' \"\$receipt\" >/dev/null"
mk_receipt_project "$TMP/receipt-tracked"
t "verify-cache: 추적된 영수증도 입력에서 제외되어 HIT" 0 bash -c \
  "cd '$TMP/receipt-tracked' && '$RC' --cacheable --task T-001 --scope related receipt-tracked -- ./check.sh > '$TMP/receipt-tracked-first.out' \
   && git add log/receipts && git commit -qm receipt \
   && '$RC' --cacheable --task T-001 --scope related receipt-tracked -- ./check.sh > '$TMP/receipt-tracked-second.out' \
   && { grep -Fx 'VERIFY_CACHE HIT' '$TMP/receipt-tracked-second.out' && [ \"\$(cat counter)\" = 1 ]; } \
   || { cat '$TMP/receipt-tracked-second.out'; printf 'counter=%s\\n' \"\$(cat counter)\"; exit 1; }"
printf 'changed tracked input\n' > "$TMP/receipt-cache/input.txt"
t "verify-cache: tracked 내용 변경은 MISS와 재실행" 0 bash -c \
  "cd '$TMP/receipt-cache' && '$RC' --cacheable --task T-001 --scope related receipt-a -- ./check.sh one > '$TMP/receipt-cache-tracked.out' \
   && grep -Fx 'VERIFY_CACHE MISS' '$TMP/receipt-cache-tracked.out' && [ \"\$(cat counter)\" = 2 ]"
t "verify-cache: 명령 인자 변경은 MISS와 재실행" 0 bash -c \
  "cd '$TMP/receipt-cache' && '$RC' --cacheable --task T-001 --scope related receipt-a -- ./check.sh two > '$TMP/receipt-cache-args.out' \
   && grep -Fx 'VERIFY_CACHE MISS' '$TMP/receipt-cache-args.out' && [ \"\$(cat counter)\" = 3 ]"
printf '\n# executable content changes the environment fingerprint\n' >> "$TMP/receipt-cache/check.sh"
t "verify-cache: 실행 파일 변경은 MISS와 재실행" 0 bash -c \
  "cd '$TMP/receipt-cache' && '$RC' --cacheable --task T-001 --scope related receipt-a -- ./check.sh two > '$TMP/receipt-cache-executable.out' \
   && grep -Fx 'VERIFY_CACHE MISS' '$TMP/receipt-cache-executable.out' && [ \"\$(cat counter)\" = 4 ]"
mk_receipt_project "$TMP/receipt-disabled"
t "verify-cache: --cacheable 없이 두 실행은 DISABLED이고 둘 다 실행" 0 bash -c \
  "cd '$TMP/receipt-disabled' && '$RC' --task T-001 --scope related receipt-disabled -- ./check.sh > disabled-first.out \
   && '$RC' --task T-001 --scope related receipt-disabled -- ./check.sh > disabled-second.out \
   && grep -Fx 'VERIFY_CACHE DISABLED' disabled-first.out && grep -Fx 'VERIFY_CACHE DISABLED' disabled-second.out \
   && [ \"\$(cat counter)\" = 2 ]"
mk_receipt_project "$TMP/receipt-failed"
cat > "$TMP/receipt-failed/fail.sh" <<'SH'
#!/usr/bin/env bash
set -eu
count="$(cat counter 2>/dev/null || printf 0)"
printf '%s\n' "$((count + 1))" > counter
exit 17
SH
chmod +x "$TMP/receipt-failed/fail.sh"
t "verify-cache: 실패 실행은 exit 17을 보존하고 두 번째도 실행" 0 bash -c \
  "cd '$TMP/receipt-failed' && set +e; '$RC' --cacheable --task T-001 --scope related receipt-failed -- ./fail.sh > failed-first.out 2>&1; first=\$?; '$RC' --cacheable --task T-001 --scope related receipt-failed -- ./fail.sh > failed-second.out 2>&1; second=\$?; set -e; [ \"\$first\" = 17 ] && [ \"\$second\" = 17 ] && ! grep -Fq 'VERIFY_CACHE HIT' failed-first.out failed-second.out && [ \"\$(cat counter)\" = 2 ]"
mk_receipt_project "$TMP/receipt-terminal-boundary"
cat > "$TMP/receipt-terminal-boundary/no-newline-fail.sh" <<'SH'
#!/usr/bin/env bash
printf broken
exit 23
SH
chmod +x "$TMP/receipt-terminal-boundary/no-newline-fail.sh"
t "verify-cache: newline 없는 실패 출력 뒤 terminal result를 별도 줄로 내고 raw hash를 보존" 0 bash -c \
  "cd '$TMP/receipt-terminal-boundary' && set +e; '$RC' --cacheable --task T-001 --scope related receipt-terminal-boundary -- ./no-newline-fail.sh > runner.out 2>&1; rc=\$?; set -e \
   && [ \"\$rc\" = 23 ] && grep -Fx 'VERIFY_CACHE MISS' runner.out \
   && receipt=\$(find log/receipts -name 'receipt-terminal-boundary-*.yaml') \
   && raw=\$(yq -r .raw_log \"\$receipt\") && [ \"\$(cat \"\$raw\")\" = broken ] \
   && [ \"\$(shasum -a 256 \"\$raw\" | awk '{print \$1}')\" = \"\$(yq -r .stdout_sha256 \"\$receipt\")\" ]"
if [ "${B006_RECEIPTS_FOCUSED:-0}" = 1 ]; then
  echo; echo "결과: PASS=$pass FAIL=$fail"
  exit "$fail"
fi

# --- B-006: B-001 receipt integration focused RED/GREEN block ---
mk_receipt_verify_project() { # $1=project with a deterministic cacheable verify command
  local p="$1"
  mkdir -p "$p"
  cp -R "$ROOT/template/." "$p"
  (cd "$p" && git init -q && git config user.name harness-test \
    && git config user.email harness-test@example.invalid)
  cat > "$p/tasks.yaml" <<'YAML'
contract_version: 3
tasks:
  - id: T-001
    name: receipt example
    budget:
      related_test_runs: 99
      full_test_runs: 99
      changed_files: 999
      changed_lines: 99999
    role: standard_worker
    grade: T1
    depends_on: []
    worktree: "."
    write_paths: []
    done_when: log/T-001.done
    on_fail: hold_downstream
    status: running
    run_id: run-1
    brief: agents/worker-T-001.md
    verify:
      command: sh
      args: ["-c", "count=$(cat log/cold/counter 2>/dev/null || printf 0); printf '%s\\n' $((count + 1)) > log/cold/counter; cat source/out.txt"]
      cacheable: true
YAML
  printf 'payload\n' > "$p/source/out.txt"
  printf 'run_id: run-1\nartifact: source/out.txt\nstatus: DONE\n' > "$p/log/T-001.done"
  { printf 'run_id: run-1 event: dispatched at: 2026-07-14T00:00:00Z role: standard_worker cli: sh mux: tmux ws: hx-T-001\n'
    printf 'run_id: run-1 event: started at: 2026-07-14T00:00:01Z\n'
    printf 'run_id: run-1 event: finished at: 2026-07-14T00:00:05Z exit_code: 0\n'
  } > "$p/log/T-001.runs"
  printf '임무: receipt\n산출물: source/out.txt\n쓰기 허용 경로: source/\n완료 신호: log/T-001.done\n' > "$p/agents/worker-T-001.md"
  (cd "$p" && git add . && git commit -qm init)
}

RVF="$ROOT/scripts/verify.sh"
mk_receipt_verify_project "$TMP/receipt-verify"
t "verify receipt: cacheable 첫 실행은 receipt와 verified 연결을 게시" 0 bash -c \
  "cd '$TMP/receipt-verify' && bash '$RVF' T-001 > '$TMP/receipt-verify-first.out' \
   && receipt=\$(yq -r .verification_receipt log/T-001.verified.yaml) \
   && [ \"\$receipt\" != null ] && [ -f \"\$receipt\" ] \
   && [ \"\$(yq -r .cache log/T-001.verified.yaml)\" = miss ] \
   && [ \"\$(yq -r .verify_log log/T-001.verified.yaml)\" = \"\$(yq -r .raw_log \"\$receipt\")\" ] \
   && [ \"\$(cat log/cold/counter)\" = 1 ]"
t "verify receipt: 같은 cacheable 검증은 HIT이며 명령을 재실행하지 않음" 0 bash -c \
  "cd '$TMP/receipt-verify' && bash '$RVF' T-001 > '$TMP/receipt-verify-second.out' \
   && { grep -Fx 'VERIFY_CACHE HIT' '$TMP/receipt-verify-second.out' && [ \"\$(cat log/cold/counter)\" = 1 ] \
     && [ \"\$(yq -r .cache log/T-001.verified.yaml)\" = hit ]; } \
   || { cat '$TMP/receipt-verify-second.out'; printf 'counter=%s\\n' \"\$(cat log/cold/counter)\"; exit 1; }"

for args_mode in omitted empty; do
  project="$TMP/receipt-verify-empty-args-$args_mode"
  mk_receipt_verify_project "$project"
  if [ "$args_mode" = omitted ]; then
    yq -i 'del(.tasks[0].verify.args)' "$project/tasks.yaml"
  else
    yq -i '.tasks[0].verify.args = []' "$project/tasks.yaml"
  fi
  yq -i '.tasks[0].verify.command = "true"' "$project/tasks.yaml"
  t "verify receipt: /bin/bash에서 verify.args=$args_mode 는 빈 argv로 성공" 0 bash -c \
    "cd '$project' && /bin/bash '$RVF' T-001 >/dev/null \
     && [ \"\$(yq -r .verify_exit_code log/T-001.verified.yaml)\" = 0 ] \
     && [ \"\$(yq -r '.verify_command | length' log/T-001.verified.yaml)\" = 1 ]"
done

for mode in false missing; do
  project="$TMP/receipt-verify-disabled-$mode"
  mk_receipt_verify_project "$project"
  [ "$mode" = false ] && yq -i '.tasks[0].verify.cacheable = false' "$project/tasks.yaml"
  [ "$mode" = missing ] && yq -i 'del(.tasks[0].verify.cacheable)' "$project/tasks.yaml"
  t "verify receipt: cacheable=$mode 는 두 번 실행하고 DISABLED" 0 bash -c \
    "cd '$project' && bash '$RVF' T-001 > first.out && bash '$RVF' T-001 > second.out \
     && grep -Fx 'VERIFY_CACHE DISABLED' first.out second.out \
     && [ \"\$(cat log/cold/counter)\" = 2 ] \
     && [ \"\$(yq -r .cache log/T-001.verified.yaml)\" = disabled ]"
done

mk_receipt_verify_project "$TMP/receipt-verify-terminal"
yq -i '.tasks[0].verify.args[1] = "printf '\''VERIFY_CACHE HIT\\n'\''; cat source/out.txt"' "$TMP/receipt-verify-terminal/tasks.yaml"
t "verify receipt: 중복 terminal result는 fail closed로 verified.yaml을 게시하지 않음" 0 bash -c \
  "cd '$TMP/receipt-verify-terminal' && if bash '$RVF' T-001; then exit 1; else rc=\$?; fi \
   && [ \"\$rc\" != 0 ] && [ ! -e log/T-001.verified.yaml ]"

mk_receipt_verify_project "$TMP/receipt-verify-tampered-receipt"
t "verify receipt: 변조된 cacheable receipt는 재실행 없이 stop" 0 bash -c \
  "cd '$TMP/receipt-verify-tampered-receipt' && bash '$RVF' T-001 >/dev/null \
   && receipt=\$(yq -r .verification_receipt log/T-001.verified.yaml) \
   && yq -i '.stdout_sha256 = \"0\"' \"\$receipt\" \
   && if bash '$RVF' T-001 > second.out 2>&1; then exit 1; fi \
   && [ \"\$(cat log/cold/counter)\" = 1 ] \
   && [ \"\$(yq -r .reason log/T-001.budget-stop.yaml)\" = attempt_evidence ] \
   && [ \"\$(find log/verification-attempts/T-001 -name '*.intent.yaml' | wc -l | tr -d ' ')\" = 1 ]"
mk_receipt_verify_project "$TMP/receipt-verify-tampered-raw"
t "verify receipt: 변조된 cold raw log는 재실행 없이 stop" 0 bash -c \
  "cd '$TMP/receipt-verify-tampered-raw' && bash '$RVF' T-001 >/dev/null \
   && raw=\$(yq -r .verify_log log/T-001.verified.yaml) && printf tampered > \"\$raw\" \
   && if bash '$RVF' T-001 > second.out 2>&1; then exit 1; fi \
   && [ \"\$(cat log/cold/counter)\" = 1 ] \
   && [ \"\$(yq -r .reason log/T-001.budget-stop.yaml)\" = attempt_evidence ] \
   && [ \"\$(find log/verification-attempts/T-001 -name '*.intent.yaml' | wc -l | tr -d ' ')\" = 1 ]"

mk_receipt_verify_project "$TMP/receipt-verify-failed"
yq -i '.tasks[0].verify.args[1] = "printf broken; exit 23"' "$TMP/receipt-verify-failed/tasks.yaml"
t "verify receipt: 실패 command는 exit 23을 보존하고 verified.yaml을 게시하지 않음" 0 bash -c \
  "cd '$TMP/receipt-verify-failed' && if bash '$RVF' T-001; then exit 1; else rc=\$?; fi \
   && [ \"\$rc\" = 23 ] && [ ! -e log/T-001.verified.yaml ]"

mk_receipt_verify_project "$TMP/receipt-verify-decoy"
t "verify receipt: stale decoy가 있어도 이번 비cacheable receipt만 연결" 0 bash -c \
  "cd '$TMP/receipt-verify-decoy' && mkdir -p log/receipts \
   && printf 'version: 1\\ntask: T-001\\nexit_code: 0\\nstdout_sha256: decoy\\nraw_log: log/cold/verification/decoy.log\\n' > log/receipts/T-001-verify-decoy.yaml \
   && bash '$RVF' T-001 >/dev/null && receipt=\$(yq -r .verification_receipt log/T-001.verified.yaml) \
   && [ \"\$receipt\" != log/receipts/T-001-verify-decoy.yaml ]"

mk_receipt_verify_project "$TMP/receipt-verify-recheck"
t "verify receipt: --recheck는 verify-cache와 command를 실행하지 않음" 0 bash -c \
  "cd '$TMP/receipt-verify-recheck' && bash '$RVF' T-001 >/dev/null \
   && before=\$(cat log/cold/counter) && receipts_before=\$(find log/receipts -type f | sort) \
   && bash '$RVF' T-001 --recheck && [ \"\$(cat log/cold/counter)\" = \"\$before\" ] \
   && [ \"\$(find log/receipts -type f | sort)\" = \"\$receipts_before\" ]"

mk_receipt_verify_project "$TMP/receipt-verify-restore"
printf 'old-log\n' > "$TMP/receipt-verify-restore/log/T-001.verify.log"
printf 'old-verified\n' > "$TMP/receipt-verify-restore/log/T-001.verified.yaml"
yq -i '.tasks[0].verify.args[1] = "exit 31"' "$TMP/receipt-verify-restore/tasks.yaml"
t "verify receipt: command 실패에도 기존 VLOG/VY와 이번 attempt·FAIL 감사를 보존" 0 bash -c \
  "cd '$TMP/receipt-verify-restore' && if bash '$RVF' T-001; then exit 1; else rc=\$?; fi \
   && [ \"\$rc\" = 31 ] && grep -Fx old-log log/T-001.verify.log \
   && grep -q '^=== verify T-001 run run-1 attempt ' log/T-001.verify.log \
   && grep -q 'FAIL: 검증 명령 실패 exit=31' log/T-001.verify.log \
   && ! grep -Fq -- '--- raw output begin ---' log/T-001.verify.log \
   && [ \"\$(cat log/T-001.verified.yaml)\" = old-verified ]"

mk_receipt_verified_state() { # $1=project; the caller mutates a valid linked receipt state
  local p="$1" f
  mk_receipt_verify_project "$p"
  for f in STATUS.md log/HANDOFF.md; do
    sed -i.bak 's/{{[^}]*}}/기입됨/g' "$p/$f" && rm -f "$p/$f.bak"
  done
  (cd "$p" && git add STATUS.md log/HANDOFF.md && git commit -qm scaffold)
  (cd "$p" && bash "$RVF" T-001 >/dev/null \
    && yq -i '.tasks[0].status = "verified"' tasks.yaml)
}
for invalid in missing-receipt exit-mismatch stdout-mismatch missing-raw; do
  project="$TMP/receipt-state-$invalid"
  mk_receipt_verified_state "$project"
  case "$invalid" in
    missing-receipt) rm -f "$project/$(yq -r .verification_receipt "$project/log/T-001.verified.yaml")";;
    exit-mismatch) receipt="$(yq -r .verification_receipt "$project/log/T-001.verified.yaml")"; yq -i '.exit_code = 7' "$project/$receipt";;
    stdout-mismatch) yq -i '.stdout_sha256 = "0000000000000000000000000000000000000000000000000000000000000000"' "$project/log/T-001.verified.yaml";;
    missing-raw) raw="$(yq -r .verify_log "$project/log/T-001.verified.yaml")"; rm -f "$project/$raw";;
  esac
  t "state: $invalid receipt 연결을 거부" 1 bash -c \
    "cd '$project' && . .harness/lib/state.sh && validate_state"
done

mk_receipt_verified_state "$TMP/receipt-checkpoint"
t "checkpoint: receipt와 attempt를 커밋하고 cold raw log는 제외" 0 bash -c \
  "cd '$TMP/receipt-checkpoint' && receipt=\$(yq -r .verification_receipt log/T-001.verified.yaml) \
   && raw=\$(yq -r .verify_log log/T-001.verified.yaml) && [ -z \"\$(git status --porcelain -- \"\$raw\")\" ] \
   && .harness/bin/checkpoint verified-T-001 >/dev/null \
   && git ls-files --error-unmatch \"\$receipt\" >/dev/null \
   && git ls-files --error-unmatch log/verification-attempts/T-001/000001.intent.yaml >/dev/null \
   && git ls-files --error-unmatch log/verification-attempts/T-001/000001.result.yaml >/dev/null \
   && ! git ls-files --error-unmatch \"\$raw\" >/dev/null 2>&1 \
   && git show --format= --name-only HEAD | grep -Fx \"\$receipt\" \
   && [ -z \"\$(git status --porcelain)\" ]"

cp -R "$ROOT/template" "$TMP/b007-stop-checkpoint"
for f in STATUS.md log/HANDOFF.md; do
  sed -i.bak 's/{{[^}]*}}/기입됨/g' "$TMP/b007-stop-checkpoint/$f"
  rm -f "$TMP/b007-stop-checkpoint/$f.bak"
done
cat > "$TMP/b007-stop-checkpoint/tasks.yaml" <<'YAML'
contract_version: 3
tasks:
  - id: T1
    status: pending
    run_id: ""
YAML
(cd "$TMP/b007-stop-checkpoint" && git init -q && git config user.name harness-test \
  && git config user.email harness-test@example.invalid && git add . && git commit -qm init)
yq -i '.tasks[0].status = "blocked"' "$TMP/b007-stop-checkpoint/tasks.yaml"
printf '\nBUDGET_STOP T1: model_runs 한도\n' >> "$TMP/b007-stop-checkpoint/STATUS.md"
printf '\nBUDGET_STOP T1: model_runs 한도\n' >> "$TMP/b007-stop-checkpoint/log/HANDOFF.md"
printf 'version: 1\ntask: T1\nreason: model_runs\n' > "$TMP/b007-stop-checkpoint/log/T1.budget-stop.yaml"
t "checkpoint: stop 상태 기록 후 추가와 명시 승인 해소 삭제를 각각 커밋" 0 bash -c \
  "cd '$TMP/b007-stop-checkpoint' && .harness/bin/checkpoint budget-stop-T1 >/dev/null \
   && git ls-files --error-unmatch log/T1.budget-stop.yaml >/dev/null \
   && yq -i '.tasks[0].status = \"pending\"' tasks.yaml && rm log/T1.budget-stop.yaml \
   && printf '\nBUDGET_STOP T1 해소: 명시적 승인\n' >> STATUS.md \
   && printf '\nBUDGET_STOP T1 해소: 명시적 승인\n' >> log/HANDOFF.md \
   && .harness/bin/checkpoint budget-resume-T1 >/dev/null \
   && ! git ls-files --error-unmatch log/T1.budget-stop.yaml >/dev/null 2>&1 \
   && [ -z \"\$(git status --porcelain)\" ]"
if [ "${B006_RECEIPTS_INTEGRATION_FOCUSED:-0}" = 1 ] || \
   [ "${B006_RECEIPTS_ALL_FOCUSED:-0}" = 1 ]; then
  echo; echo "결과: PASS=$pass FAIL=$fail"
  exit "$fail"
fi

# --- lib.sh: resolve_role ---
cat > "$TMP/models-ok.yaml" <<'YAML'
roles:
  standard_worker:
    effort: medium
    candidates:
      - name: fake-cli
        command: sh
        args: ["-c"]
YAML
cat > "$TMP/models-none.yaml" <<'YAML'
roles:
  standard_worker:
    effort: medium
    candidates:
      - name: ghost
        command: no-such-cli-zzz
YAML
cat > "$TMP/models-missing-effort.yaml" <<'YAML'
roles:
  standard_worker:
    candidates:
      - name: fake-cli
        command: sh
        args: ["-c"]
YAML
cat > "$TMP/models-invalid-effort.yaml" <<'YAML'
roles:
  standard_worker:
    effort: extreme
    candidates:
      - name: fake-cli
        command: sh
        args: ["-c"]
YAML
t "resolve_role: 설치된 후보를 찾는다" 0 bash -c \
  ". '$ROOT/scripts/lib.sh'; resolve_role standard_worker '$TMP/models-ok.yaml' && [ \"\$ROLE_CMD\" = sh ] && [ \"\${ROLE_ARGS[0]}\" = -c ] && [ \"\$ROLE_EFFORT\" = medium ]"
t "resolve_role: 후보 소진이면 실패(BLOCKED)" 1 bash -c \
  ". '$ROOT/scripts/lib.sh'; resolve_role standard_worker '$TMP/models-none.yaml'"
t "resolve_role: 없는 역할이면 실패" 1 bash -c \
  ". '$ROOT/scripts/lib.sh'; resolve_role no_such_role '$TMP/models-ok.yaml'"
t "resolve_role: effort 누락이면 BLOCKED" 1 bash -c \
  ". '$ROOT/scripts/lib.sh'; resolve_role standard_worker '$TMP/models-missing-effort.yaml'"
t "resolve_role: 허용하지 않은 effort면 BLOCKED" 1 bash -c \
  ". '$ROOT/scripts/lib.sh'; resolve_role standard_worker '$TMP/models-invalid-effort.yaml'"
t "MODELS.yaml: 5개 역할과 effort가 존재" 0 bash -c \
  "for r in orchestrator economy_worker standard_worker frontier_worker judge; do yq -e \".roles.\$r.candidates | length > 0 and (.roles.\$r.effort == \\\"low\\\" or .roles.\$r.effort == \\\"medium\\\" or .roles.\$r.effort == \\\"high\\\")\" '$ROOT/MODELS.yaml' >/dev/null || exit 1; done"
t "MODELS.yaml: Codex 워커 프로필과 effort가 명시된다" 0 bash -c \
  "for spec in 'economy_worker:gpt-5.6-luna:low' 'standard_worker:gpt-5.6-terra:medium' 'frontier_worker:gpt-5.6-sol:high'; do r=\${spec%%:*}; rest=\${spec#*:}; model=\${rest%%:*}; effort=\${rest#*:}; yq -e \".roles.\$r.candidates[0].name == \\\"codex-\${model#gpt-5.6-}\\\" and .roles.\$r.candidates[0].command == \\\"codex\\\"\" '$ROOT/MODELS.yaml' >/dev/null && yq -r \".roles.\$r.candidates[0].args[]\" '$ROOT/MODELS.yaml' | grep -Fx -- '--model' >/dev/null && yq -r \".roles.\$r.candidates[0].args[]\" '$ROOT/MODELS.yaml' | grep -Fx -- \"\$model\" >/dev/null && yq -r \".roles.\$r.candidates[0].args[]\" '$ROOT/MODELS.yaml' | grep -Fx -- \"model_reasoning_effort=\\\"\$effort\\\"\" >/dev/null || exit 1; done"
t "MODELS.yaml: Claude 워커 프로필과 effort가 명시된다" 0 bash -c \
  "for spec in 'economy_worker:haiku:low' 'standard_worker:sonnet:medium' 'frontier_worker:fable:high'; do r=\${spec%%:*}; rest=\${spec#*:}; model=\${rest%%:*}; effort=\${rest#*:}; yq -r \".roles.\$r.candidates[] | select(.command == \\\"claude\\\") | .args[]\" '$ROOT/MODELS.yaml' | grep -Fx -- \"--model=\$model\" >/dev/null && yq -r \".roles.\$r.candidates[] | select(.command == \\\"claude\\\") | .args[]\" '$ROOT/MODELS.yaml' | grep -Fx -- \"--effort=\$effort\" >/dev/null || exit 1; done"
t "MODELS.yaml: Claude Opus fallback은 frontier Fable에만 있다" 0 bash -c \
  "[ \"\$(yq -r '.roles.frontier_worker.candidates[] | select(.command == \"claude\") | .args[]' '$ROOT/MODELS.yaml' | grep -Fxc -- '--fallback-model=opus')\" = 1 ] && ! yq -r '.roles | to_entries[] | select(.key != \"frontier_worker\") | .value.candidates[]? | select(.command == \"claude\") | .args[]?' '$ROOT/MODELS.yaml' | grep -Fq -- '--fallback-model=opus'"
t "MODELS.yaml: judge는 Claude Fable/high 우선, Codex Sol/high 폴백" 0 bash -c \
  "yq -e '.roles.judge.effort == \"high\" and .roles.judge.candidates[0].name == \"claude-fable\" and .roles.judge.candidates[1].name == \"codex-sol\"' '$ROOT/MODELS.yaml' >/dev/null && yq -r '.roles.judge.candidates[0].args[]' '$ROOT/MODELS.yaml' | grep -Fx -- '--effort=high' >/dev/null && yq -r '.roles.judge.candidates[1].args[]' '$ROOT/MODELS.yaml' | grep -Fx -- 'gpt-5.6-sol' >/dev/null"
t "MODELS.yaml: claude 워커는 mv 허용(원자 .done 게시, B-001)" 0 bash -c \
  "for r in standard_worker economy_worker frontier_worker; do yq -r \".roles.\$r.candidates[] | select(.command == \\\"claude\\\") | .args[]\" '$ROOT/MODELS.yaml' | grep -q 'Bash(mv:\\*)' || exit 1; done"
t "MODELS.yaml: codex 워커·저지는 workspace-write 샌드박스(실측 결함, B-001)" 0 bash -c \
  "for r in economy_worker standard_worker frontier_worker judge; do yq -r \".roles.\$r.candidates[] | select(.command == \\\"codex\\\") | .args | join(\\\" \\\")\" '$ROOT/MODELS.yaml' | grep -q -- '--sandbox workspace-write' || exit 1; done"

# --- scaffold-check ---
SC="$ROOT/scripts/scaffold-check.sh"
mk_proj() { # $1=대상 디렉토리: template 복사 + git init
  rm -rf "$1"; cp -R "$ROOT/template" "$1"
  (cd "$1" && git init -q && git config user.name harness-test \
    && git config user.email harness-test@example.invalid \
    && git add -A && git commit -qm init)
}
fill_project() { # $1=프로젝트: 스캐폴딩 플레이스홀더 전부 채움
  local p="$1" f
  for f in HARNESS.md STATUS.md log/HANDOFF.md; do
    sed -i.bak 's/{{[^}]*}}/기입됨/g' "$p/$f" && rm -f "$p/$f.bak"
  done
  git -C "$p" add HARNESS.md STATUS.md log/HANDOFF.md
  git -C "$p" commit -qm scaffold
}
mk_verified_fixture() { # $1=프로젝트 $2=id $3=run_id : 새 계약(B-001)의 완전한 verified 증거 생성
  local p="$1" id="$2" rid="$3" dsha raw_rel receipt_rel
  raw_rel="log/cold/verification/$id-fixture.log"
  receipt_rel="log/receipts/$id-fixture.yaml"
  { printf 'run_id: %s event: dispatched at: 2026-07-14T00:00:00Z role: standard_worker cli: sh mux: tmux ws: hx-%s\n' "$rid" "$id"
    printf 'run_id: %s event: started at: 2026-07-14T00:00:01Z\n' "$rid"
    printf 'run_id: %s event: finished at: 2026-07-14T00:00:05Z exit_code: 0\n' "$rid"
  } >> "$p/log/$id.runs"
  [ -f "$p/log/$id.done" ] || printf 'run_id: %s\nartifact: source/out.txt\nstatus: DONE\n' "$rid" > "$p/log/$id.done"
  dsha="$(shasum -a 256 "$p/log/$id.done" | awk '{print $1}')"
  mkdir -p "$p/log/cold/verification" "$p/log/receipts"
  : > "$p/$raw_rel"
  { echo "version: 1"; echo "task: $id"; echo "exit_code: 0"
    echo "stdout_sha256: e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    echo "raw_log: $raw_rel"
  } > "$p/$receipt_rel"
  : > "$p/log/$id.verify.log"
  { echo "version: 1"; echo "task: $id"; echo "run_id: $rid"
    echo "verified_by: orchestrator"; echo "verified_at: 2026-07-14T00:00:10Z"
    echo "harness_commit: test"; echo "done_sha256: $dsha"
    echo "artifact: source/out.txt"
    echo "artifact_git_blob: 0000000000000000000000000000000000000000"
    echo "worktree: ."; echo "worktree_head: shared"; echo "worktree_tree: shared"
    echo "verify_command:"; echo "  - sh"; echo "verify_exit_code: 0"
    echo "stdout_sha256: e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    echo "verify_log: $raw_rel"
    echo "verification_receipt: $receipt_rel"
    echo "cache: miss"
  } > "$p/log/$id.verified.yaml"
}
mk_proj "$TMP/p1"
t "scaffold-check: 플레이스홀더 잔존이면 FAIL" 1 bash -c "cd '$TMP/p1' && bash '$SC'"
fill_project "$TMP/p1"
t "scaffold-check: 채우면 PASS + pass 파일 생성" 0 bash -c \
  "cd '$TMP/p1' && bash '$SC' && [ -f log/scaffold-check.pass ]"
# 순환 의존 검출
cat > "$TMP/p1/tasks.yaml" <<'YAML'
tasks:
  - { id: A, name: a, role: standard_worker, grade: T1, depends_on: [B],
      worktree: ".", write_paths: [], done_when: x, on_fail: hold_downstream,
      status: pending, brief: agents/worker-A.md }
  - { id: B, name: b, role: standard_worker, grade: T1, depends_on: [A],
      worktree: ".", write_paths: [], done_when: x, on_fail: hold_downstream,
      status: pending, brief: agents/worker-B.md }
YAML
printf '임무: a\n산출물: x\n쓰기 허용 경로: source/\n완료 신호: log/A.done\n' > "$TMP/p1/agents/worker-A.md"
printf '임무: b\n산출물: x\n쓰기 허용 경로: source/\n완료 신호: log/B.done\n' > "$TMP/p1/agents/worker-B.md"
t "scaffold-check: 순환 의존이면 FAIL" 1 bash -c "cd '$TMP/p1' && bash '$SC'"
# 브리프 필수 필드 누락
mk_proj "$TMP/p2"; fill_project "$TMP/p2"
cat > "$TMP/p2/tasks.yaml" <<'YAML'
tasks:
  - { id: A, name: a, role: standard_worker, grade: T1, depends_on: [],
      worktree: ".", write_paths: [], done_when: x, on_fail: hold_downstream,
      status: pending, brief: agents/worker-A.md }
YAML
printf '임무: a\n산출물: x\n' > "$TMP/p2/agents/worker-A.md"   # 완료 신호 없음
t "scaffold-check: 브리프에 완료 신호 없으면 FAIL" 1 bash -c "cd '$TMP/p2' && bash '$SC'"

mk_proj "$TMP/state-missing"; fill_project "$TMP/state-missing"
rm "$TMP/state-missing/log/HANDOFF.md"
t "scaffold-check: HANDOFF 누락이면 FAIL" 1 bash -c \
  "cd '$TMP/state-missing' && bash '$SC'"

mk_proj "$TMP/state-placeholder"; fill_project "$TMP/state-placeholder"
printf '\n{{남은 상태}}\n' >> "$TMP/state-placeholder/STATUS.md"
t "scaffold-check: STATUS 플레이스홀더면 FAIL" 1 bash -c \
  "cd '$TMP/state-placeholder' && bash '$SC'"

mk_proj "$TMP/state-done"; fill_project "$TMP/state-done"
cat > "$TMP/state-done/tasks.yaml" <<'YAML'
tasks:
  - id: A
    name: a
    role: standard_worker
    grade: T1
    depends_on: []
    worktree: "."
    write_paths: []
    done_when: log/A.done
    on_fail: hold_downstream
    status: verified
    run_id: r1
    brief: agents/worker-A.md
YAML
printf '임무: a\n산출물: x\n쓰기 허용 경로: source/\n완료 신호: log/A.done\n' \
  > "$TMP/state-done/agents/worker-A.md"
t "scaffold-check: verified인데 .done 없으면 FAIL" 1 bash -c \
  "cd '$TMP/state-done' && bash '$SC'"
printf 'run_id: r1\nartifact: source/out.txt\nstatus: DONE\n' > "$TMP/state-done/log/A.done"
t "scaffold-check: verified인데 verified.yaml 없으면 FAIL" 1 bash -c \
  "cd '$TMP/state-done' && bash '$SC'"
sed -i.bak 's/status: DONE/status: VERIFIED/' "$TMP/state-done/log/A.done" \
  && rm "$TMP/state-done/log/A.done.bak"
t "scaffold-check: 옛 VERIFIED 덮어쓰기 마커는 FAIL(B-001)" 1 bash -c \
  "cd '$TMP/state-done' && bash '$SC'"
sed -i.bak 's/status: VERIFIED/status: DONE/' "$TMP/state-done/log/A.done" \
  && rm "$TMP/state-done/log/A.done.bak"
mkdir -p "$TMP/state-done/source"; printf 'x\n' > "$TMP/state-done/source/out.txt"
mk_verified_fixture "$TMP/state-done" A r1
t "scaffold-check: 새 계약 완전 증거면 PASS" 0 bash -c \
  "cd '$TMP/state-done' && bash '$SC'"

mk_proj "$TMP/state-pending"; fill_project "$TMP/state-pending"
cat > "$TMP/state-pending/log/pending-decision.yaml" <<'YAML'
version: 1
id: broken-id
status: awaiting_answer
opened_at: 2026-07-13T00:00:00Z
opened_by: codex
request_path: nowhere
answer_path: nowhere
checkpoint_base: deadbeef
YAML
t "scaffold-check: 잘못된 pending 스키마면 FAIL" 1 bash -c \
  "cd '$TMP/state-pending' && bash '$SC'"

mk_proj "$TMP/checkpoint"; fill_project "$TMP/checkpoint"
CP="$TMP/checkpoint/.harness/bin/checkpoint"
t "checkpoint: check-only validates without commit" 0 bash -c \
  "cd '$TMP/checkpoint' && '$CP' --check-only"
printf 'user source\n' > "$TMP/checkpoint/source/user.txt"
t "checkpoint: dirty source blocks commit" 1 bash -c \
  "cd '$TMP/checkpoint' && '$CP' transition"
rm "$TMP/checkpoint/source/user.txt"
printf '\n상태 전이 기록\n' >> "$TMP/checkpoint/log/HANDOFF.md"
before="$(git -C "$TMP/checkpoint" rev-list --count HEAD)"
t "checkpoint: core state only commit" 0 bash -c \
  "cd '$TMP/checkpoint' && '$CP' transition"
# $1/$2는 아래 bash -c의 위치 매개변수이므로 여기서 확장하지 않는다.
# shellcheck disable=SC2016
t "checkpoint: exactly one commit created" 0 bash -c \
  'test "$(git -C "$1" rev-list --count HEAD)" -eq "$2" && test -z "$(git -C "$1" status --porcelain)"' \
  _ "$TMP/checkpoint" "$((before+1))"

open_fixture_decision() { # project id provider
  local p="$1" id="$2" provider="$3"
  printf '# Decision %s\n\nQuestion: GO or KILL?\n\nRecommendation: GO\n' "$id" \
    > "$p/log/decisions/$id.request.md"
  set_section_value "$p/STATUS.md" '## 다음 사용자 결정' "결정 ID: $id"
  set_section_value "$p/log/HANDOFF.md" '## 열린 결정' "결정 ID: $id"
  (cd "$p" && HARNESS_NATIVE_SMOKE_NONCE='native-smoke-fixture-20260713' \
    .harness/bin/decision-open "$id" "$provider" --smoke)
}

set_section_value() { # file heading value
  local file="$1" heading="$2" value="$3" tmp="$1.tmp"
  awk -v h="$heading" -v v="$value" '
    $0 == h {print; print ""; print v; inside=1; next}
    inside && /^## / {inside=0}
    !inside {print}
  ' "$file" > "$tmp" && mv "$tmp" "$file"
}

mk_proj "$TMP/open"; fill_project "$TMP/open"
ID=D-20260713-120000-01
t "decision-open: normal decision without smoke PASS is rejected" 1 bash -c \
  "printf '# Decision\n' > '$TMP/open/log/decisions/$ID.request.md'; $(declare -f set_section_value); set_section_value '$TMP/open/STATUS.md' '## 다음 사용자 결정' '결정 ID: $ID'; set_section_value '$TMP/open/log/HANDOFF.md' '## 열린 결정' '결정 ID: $ID'; cd '$TMP/open' && .harness/bin/decision-open '$ID' codex"
git -C "$TMP/open" restore STATUS.md log/HANDOFF.md
rm -f "$TMP/open/log/decisions/$ID.request.md"
t "decision-open: request and checkpoint commit" 0 bash -c \
  "$(declare -f set_section_value); $(declare -f open_fixture_decision); open_fixture_decision '$TMP/open' '$ID' codex"
t "decision-open: pending schema and HEAD tracking" 0 bash -c \
  "cd '$TMP/open' && yq -e '.id == \"$ID\" and .status == \"awaiting_answer\"' log/pending-decision.yaml >/dev/null && git diff --quiet HEAD -- log/pending-decision.yaml log/decisions/$ID.request.md"
t "decision-open: second open is rejected" 1 bash -c \
  "cd '$TMP/open' && HARNESS_NATIVE_SMOKE_NONCE='native-smoke-fixture-20260713' .harness/bin/decision-open D-20260713-120001-01 claude --smoke"

mk_proj "$TMP/open-dirty"; fill_project "$TMP/open-dirty"
printf 'dirty\n' > "$TMP/open-dirty/source/user.txt"
printf '# Decision\n' > "$TMP/open-dirty/log/decisions/$ID.request.md"
set_section_value "$TMP/open-dirty/STATUS.md" '## 다음 사용자 결정' "결정 ID: $ID"
set_section_value "$TMP/open-dirty/log/HANDOFF.md" '## 열린 결정' "결정 ID: $ID"
t "decision-open: dirty source is rejected" 1 bash -c \
  "cd '$TMP/open-dirty' && HARNESS_NATIVE_SMOKE_NONCE='native-smoke-fixture-20260713' .harness/bin/decision-open '$ID' codex --smoke"

mk_proj "$TMP/open-no-nonce"; fill_project "$TMP/open-no-nonce"
printf '# Decision\n' > "$TMP/open-no-nonce/log/decisions/$ID.request.md"
set_section_value "$TMP/open-no-nonce/STATUS.md" '## 다음 사용자 결정' "결정 ID: $ID"
set_section_value "$TMP/open-no-nonce/log/HANDOFF.md" '## 열린 결정' "결정 ID: $ID"
t "decision-open: smoke without explicit nonce is rejected" 1 bash -c \
  "cd '$TMP/open-no-nonce' && env -u HARNESS_NATIVE_SMOKE_NONCE .harness/bin/decision-open '$ID' codex --smoke"

t "hooks: Claude and Codex configs parse" 0 bash -c \
  "yq -e '.hooks.UserPromptSubmit[0].hooks[0].type == \"command\" and .hooks.Stop[0].hooks[0].type == \"command\"' '$ROOT/template/.claude/settings.json' >/dev/null && yq -e '.hooks.UserPromptSubmit[0].hooks[0].type == \"command\" and .hooks.Stop[0].hooks[0].type == \"command\"' '$ROOT/template/.codex/hooks.json' >/dev/null"

mk_proj "$TMP/hook-none"; fill_project "$TMP/hook-none"
head_before="$(git -C "$TMP/hook-none" rev-parse HEAD)"
t "hook: no pending means no prompt record" 0 bash -c \
  "cd '$TMP/hook-none' && printf '%s' '{\"hook_event_name\":\"UserPromptSubmit\",\"session_id\":\"s1\",\"turn_id\":\"t1\",\"prompt\":\"ordinary prompt\"}' | .harness/bin/decision-hook codex | yq -e 'tag == \"!!map\" and length == 0' >/dev/null"
t "hook: no pending leaves HEAD and decisions unchanged" 0 bash -c \
  "[ \"\$(git -C '$TMP/hook-none' rev-parse HEAD)\" = '$head_before' ] && [ -z \"\$(find '$TMP/hook-none/log/decisions' -type f ! -name .gitkeep -print -quit)\" ]"

mk_proj "$TMP/hook-answer"; fill_project "$TMP/hook-answer"
open_fixture_decision "$TMP/hook-answer" "$ID" codex >/dev/null
cat > "$TMP/answer-event.json" <<'JSON'
{"hook_event_name":"UserPromptSubmit","session_id":"session-a","turn_id":"turn-a","prompt":"GO\nsecond line"}
JSON
t "hook: answer captured and committed before model" 0 bash -c \
  "cd '$TMP/hook-answer' && HARNESS_NATIVE_SMOKE_NONCE='native-smoke-fixture-20260713' .harness/bin/decision-hook codex < '$TMP/answer-event.json' | yq -e '.hookSpecificOutput.hookEventName == \"UserPromptSubmit\"' >/dev/null"
t "hook: captured state and exact raw SHA" 0 bash -c \
  "cd '$TMP/hook-answer' && [ \"\$(yq -r .status log/pending-decision.yaml)\" = answer_captured ] && git diff --quiet HEAD -- log/pending-decision.yaml log/decisions/$ID.answer.md && expected=\$(printf 'GO\nsecond line' | { if command -v shasum >/dev/null; then shasum -a 256; else sha256sum; fi; } | awk '{print \$1}') && grep -Fq \"prompt_sha256: \$expected\" log/decisions/$ID.answer.md"
t "hook smoke: record current provider/config/core hashes" 0 bash -c \
  "cd '$TMP/hook-answer' && HARNESS_CLIENT_VERSION='codex test 1.0' HARNESS_NATIVE_SMOKE_NONCE='native-smoke-fixture-20260713' .harness/bin/hook-smoke-pass codex '$ID'"
t "hook smoke: current hashes satisfy provider readiness" 0 bash -c \
  "cd '$TMP/hook-answer' && export HARNESS_CLIENT_VERSION='codex test 1.0' && . .harness/lib/state.sh && provider_ready codex"
cp "$TMP/hook-answer/log/hook-smoke-codex.pass" "$TMP/valid-hook-smoke-pass"
t "hook smoke: PASS without nonce evidence is rejected" 1 bash -c \
  "cd '$TMP/hook-answer' && yq -i 'del(.nonce_sha256)' log/hook-smoke-codex.pass && git add log/hook-smoke-codex.pass && git commit -qm 'test nonce-less legacy PASS' && export HARNESS_CLIENT_VERSION='codex test 1.0' && . .harness/lib/state.sh && provider_ready codex"
cp "$TMP/valid-hook-smoke-pass" "$TMP/hook-answer/log/hook-smoke-codex.pass"
git -C "$TMP/hook-answer" add log/hook-smoke-codex.pass
git -C "$TMP/hook-answer" commit -qm 'test restore valid PASS'
t "hook: answer metadata records nonce hash" 0 bash -c \
  "cd '$TMP/hook-answer' && expected=\$(printf '%s' native-smoke-fixture-20260713 | { if command -v shasum >/dev/null; then shasum -a 256; else sha256sum; fi; } | awk '{print \$1}') && grep -Fq \"nonce_sha256: \$expected\" log/decisions/$ID.answer.md"

mk_proj "$TMP/hook-provider-evidence"; fill_project "$TMP/hook-provider-evidence"
open_fixture_decision "$TMP/hook-provider-evidence" "$ID" codex >/dev/null
(cd "$TMP/hook-provider-evidence" && HARNESS_NATIVE_SMOKE_NONCE='native-smoke-fixture-20260713' .harness/bin/decision-hook codex < "$TMP/answer-event.json" >/dev/null)
printf 'provider: codex\n' >> "$TMP/hook-provider-evidence/log/decisions/$ID.answer.md"
awk 'BEGIN {changed=0} /^provider: codex$/ && !changed {print "provider: claude"; changed=1; next} {print}' \
  "$TMP/hook-provider-evidence/log/decisions/$ID.answer.md" > "$TMP/provider-answer" \
  && mv "$TMP/provider-answer" "$TMP/hook-provider-evidence/log/decisions/$ID.answer.md"
git -C "$TMP/hook-provider-evidence" add log/decisions/$ID.answer.md
git -C "$TMP/hook-provider-evidence" commit -qm 'test provider metadata mismatch'
t "hook smoke: body provider line cannot satisfy exact answer metadata" 1 bash -c \
  "cd '$TMP/hook-provider-evidence' && HARNESS_NATIVE_SMOKE_NONCE='native-smoke-fixture-20260713' .harness/bin/hook-smoke-pass codex '$ID'"

mk_proj "$TMP/hook-provider-suffix"; fill_project "$TMP/hook-provider-suffix"
open_fixture_decision "$TMP/hook-provider-suffix" "$ID" codex >/dev/null
(cd "$TMP/hook-provider-suffix" && HARNESS_NATIVE_SMOKE_NONCE='native-smoke-fixture-20260713' .harness/bin/decision-hook codex < "$TMP/answer-event.json" >/dev/null)
awk 'BEGIN {changed=0} /^provider: codex$/ && !changed {print "provider: codex: forged"; changed=1; next} {print}' \
  "$TMP/hook-provider-suffix/log/decisions/$ID.answer.md" > "$TMP/provider-suffix-answer" \
  && mv "$TMP/provider-suffix-answer" "$TMP/hook-provider-suffix/log/decisions/$ID.answer.md"
git -C "$TMP/hook-provider-suffix" add log/decisions/$ID.answer.md
git -C "$TMP/hook-provider-suffix" commit -qm 'test provider metadata suffix'
t "hook smoke: provider metadata suffix cannot satisfy exact value" 1 bash -c \
  "cd '$TMP/hook-provider-suffix' && HARNESS_NATIVE_SMOKE_NONCE='native-smoke-fixture-20260713' .harness/bin/hook-smoke-pass codex '$ID'"

mk_proj "$TMP/hook-provider-pending"; fill_project "$TMP/hook-provider-pending"
open_fixture_decision "$TMP/hook-provider-pending" "$ID" codex >/dev/null
(cd "$TMP/hook-provider-pending" && HARNESS_NATIVE_SMOKE_NONCE='native-smoke-fixture-20260713' .harness/bin/decision-hook codex < "$TMP/answer-event.json" >/dev/null)
yq -i '.opened_by = "claude"' "$TMP/hook-provider-pending/log/pending-decision.yaml"
git -C "$TMP/hook-provider-pending" add log/pending-decision.yaml
git -C "$TMP/hook-provider-pending" commit -qm 'test provider pending mismatch'
t "hook smoke: pending opened_by must exactly match provider" 1 bash -c \
  "cd '$TMP/hook-provider-pending' && HARNESS_NATIVE_SMOKE_NONCE='native-smoke-fixture-20260713' .harness/bin/hook-smoke-pass codex '$ID'"

mk_proj "$TMP/hook-snapshot-failure"; fill_project "$TMP/hook-snapshot-failure"
open_fixture_decision "$TMP/hook-snapshot-failure" "$ID" codex >/dev/null
cp "$TMP/hook-snapshot-failure/log/pending-decision.yaml" "$TMP/pending-before-snapshot"
cat > "$TMP/mktemp-fail-after-startup" <<'SH'
#!/bin/sh
n=0
[ -f "$MKCOUNT" ] && n="$(cat "$MKCOUNT")"
n=$((n + 1))
printf '%s\n' "$n" > "$MKCOUNT"
[ "$n" -eq 5 ] && exit 1
exec "$REAL_MKTEMP" "$@"
SH
chmod +x "$TMP/mktemp-fail-after-startup"
mkdir "$TMP/fakebin"
ln -s "$TMP/mktemp-fail-after-startup" "$TMP/fakebin/mktemp"
printf 'GO\nsecond line' > "$TMP/snapshot-raw-answer"
real_mktemp="$(command -v mktemp)"
t "hook: first prepared snapshot failure retains exact recovery and awaiting state" 0 bash -c \
  "cd '$TMP/hook-snapshot-failure' && printf '0' > '$TMP/mktemp-count' && PATH='$TMP/fakebin:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin' MKCOUNT='$TMP/mktemp-count' REAL_MKTEMP='$real_mktemp' HARNESS_NATIVE_SMOKE_NONCE='native-smoke-fixture-20260713' .harness/bin/decision-hook codex < '$TMP/answer-event.json' | yq -e '.decision == \"block\"' >/dev/null && cmp -s '$TMP/pending-before-snapshot' log/pending-decision.yaml && [ \"\$(yq -r .status log/pending-decision.yaml)\" = awaiting_answer ] && [ ! -e log/decisions/$ID.answer.md ] && [ -f log/decisions/$ID.answer.pending.md ] && bytes=\$(wc -c < '$TMP/snapshot-raw-answer' | tr -d ' ') && tail -c \"\$bytes\" log/decisions/$ID.answer.pending.md | cmp -s '$TMP/snapshot-raw-answer' -"

mk_proj "$TMP/hook-partial-recovery"; fill_project "$TMP/hook-partial-recovery"
open_fixture_decision "$TMP/hook-partial-recovery" "$ID" codex >/dev/null
partial_base="$(git -C "$TMP/hook-partial-recovery" rev-parse HEAD)"
mkdir "$TMP/fakebin-partial-cat"
cat > "$TMP/fakebin-partial-cat/cat" <<'SH'
#!/bin/sh
case "${1:-}" in
  */harness-raw.*)
    printf 'G'
    kill -TERM "$PPID"
    exit 0
    ;;
esac
exec "$REAL_CAT" "$@"
SH
chmod +x "$TMP/fakebin-partial-cat/cat"
cat > "$TMP/partial-retry-event.json" <<'JSON'
{"hook_event_name":"UserPromptSubmit","session_id":"session-retry","turn_id":"turn-retry","prompt":"must not replace interrupted answer"}
JSON
real_cat="$(command -v cat)"
t "hook: signal during recovery build exits interrupted" 2 bash -c \
  "cd '$TMP/hook-partial-recovery' && PATH='$TMP/fakebin-partial-cat:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin' REAL_CAT='$real_cat' HARNESS_NATIVE_SMOKE_NONCE='native-smoke-fixture-20260713' .harness/bin/decision-hook codex < '$TMP/answer-event.json' >/dev/null"
t "hook: interrupted recovery build is never canonical" 0 bash -c \
  "cd '$TMP/hook-partial-recovery' && [ \"\$(git rev-parse HEAD)\" = '$partial_base' ] && [ \"\$(yq -r .status log/pending-decision.yaml)\" = awaiting_answer ] && [ ! -e log/decisions/$ID.answer.pending.md ] && [ -f log/decisions/$ID.answer.pending.md.building ] && [ ! -e log/decisions/$ID.answer.md ]"
t "hook: retry blocks invalid recovery candidate without commit" 0 bash -c \
  "cd '$TMP/hook-partial-recovery' && HARNESS_NATIVE_SMOKE_NONCE='native-smoke-fixture-20260713' .harness/bin/decision-hook codex < '$TMP/partial-retry-event.json' | yq -e '.decision == \"block\"' >/dev/null && [ \"\$(git rev-parse HEAD)\" = '$partial_base' ] && [ \"\$(yq -r .status log/pending-decision.yaml)\" = awaiting_answer ] && [ -f log/decisions/$ID.answer.pending.md.building ] && [ ! -e log/decisions/$ID.answer.md ]"
printf '\n# tampered after smoke\n' >> "$TMP/hook-answer/.harness/bin/decision-hook"
t "hook smoke: changed hook hash invalidates readiness" 1 bash -c \
  "cd '$TMP/hook-answer' && export HARNESS_CLIENT_VERSION='codex test 1.0' && . .harness/lib/state.sh && provider_ready codex"
git -C "$TMP/hook-answer" restore .harness/bin/decision-hook
t "hook Stop: captured answer must be applied and closed" 0 bash -c \
  "cd '$TMP/hook-answer' && printf '%s' '{\"hook_event_name\":\"Stop\",\"last_assistant_message\":\"Captured.\\n\\n결정 ID: $ID\"}' | .harness/bin/decision-hook codex | yq -e '.decision == \"block\"' >/dev/null"

mk_proj "$TMP/hook-missing-nonce"; fill_project "$TMP/hook-missing-nonce"
open_fixture_decision "$TMP/hook-missing-nonce" "$ID" codex >/dev/null
t "hook: smoke capture without nonce is blocked" 0 bash -c \
  "cd '$TMP/hook-missing-nonce' && env -u HARNESS_NATIVE_SMOKE_NONCE .harness/bin/decision-hook codex < '$TMP/answer-event.json' | yq -e '.decision == \"block\"' >/dev/null && [ \"\$(yq -r .status log/pending-decision.yaml)\" = awaiting_answer ]"

mk_proj "$TMP/hook-wrong-nonce"; fill_project "$TMP/hook-wrong-nonce"
open_fixture_decision "$TMP/hook-wrong-nonce" "$ID" codex >/dev/null
t "hook: smoke capture with wrong nonce is blocked" 0 bash -c \
  "cd '$TMP/hook-wrong-nonce' && HARNESS_NATIVE_SMOKE_NONCE=another-valid-native-smoke-20260713 .harness/bin/decision-hook codex < '$TMP/answer-event.json' | yq -e '.decision == \"block\"' >/dev/null && [ \"\$(yq -r .status log/pending-decision.yaml)\" = awaiting_answer ]"

mk_proj "$TMP/hook-mutating"; fill_project "$TMP/hook-mutating"
open_fixture_decision "$TMP/hook-mutating" "$ID" codex >/dev/null
printf 'unrelated baseline\n' > "$TMP/hook-mutating/source/unrelated.txt"
git -C "$TMP/hook-mutating" add source/unrelated.txt
git -C "$TMP/hook-mutating" commit -qm 'test unrelated baseline'
mut_base="$(git -C "$TMP/hook-mutating" rev-parse HEAD)"
cp "$TMP/hook-mutating/log/pending-decision.yaml" "$TMP/hook-mutating/expected-pending"
printf 'unrelated-index-version\n' > "$TMP/hook-mutating/expected-index"
printf 'unrelated-worktree-version\n' > "$TMP/hook-mutating/expected-worktree"
cat > "$TMP/hook-mutating/.git/hooks/pre-commit" <<'SH'
#!/bin/sh
answer="log/decisions/D-20260713-120000-01.answer.md"
cp "$answer" "$EXPECTED_ANSWER"
printf '\nINJECTED BY PRE-COMMIT\n' >> "$answer"
repo_index="$(GIT_INDEX_FILE= git rev-parse --show-toplevel)/.git/index"
printf '%s\n' unrelated-index-version > source/unrelated.txt
GIT_INDEX_FILE="$repo_index" git add source/unrelated.txt
printf '%s\n' unrelated-worktree-version > source/unrelated.txt
SH
chmod +x "$TMP/hook-mutating/.git/hooks/pre-commit"
t "hook: mutating pre-commit blocks and rolls back exact capture" 0 bash -c \
  "cd '$TMP/hook-mutating' && EXPECTED_ANSWER='$TMP/hook-mutating/expected-answer' HARNESS_NATIVE_SMOKE_NONCE='native-smoke-fixture-20260713' .harness/bin/decision-hook codex < '$TMP/answer-event.json' | yq -e '.decision == \"block\"' >/dev/null && [ \"\$(git rev-parse HEAD)\" = '$mut_base' ]"
t "hook: mutating pre-commit retains original recovery and unrelated change" 0 bash -c \
  "cd '$TMP/hook-mutating' && [ \"\$(yq -r .status log/pending-decision.yaml)\" = awaiting_answer ] && cmp -s '$TMP/hook-mutating/expected-pending' log/pending-decision.yaml && cmp -s '$TMP/hook-mutating/expected-answer' log/decisions/$ID.answer.pending.md && cmp -s '$TMP/hook-mutating/expected-index' <(git show :source/unrelated.txt) && cmp -s '$TMP/hook-mutating/expected-worktree' source/unrelated.txt && git diff --cached --quiet HEAD -- log/pending-decision.yaml log/decisions/$ID.answer.md && git diff --quiet HEAD -- log/pending-decision.yaml log/decisions/$ID.answer.md && [ ! -e log/decisions/$ID.answer.md ]"
git -C "$TMP/hook-mutating" reset HEAD -- source/unrelated.txt >/dev/null
rm -f "$TMP/hook-mutating/.git/hooks/pre-commit"
t "hook: recovery after mutating hook commits original answer" 0 bash -c \
  "cd '$TMP/hook-mutating' && HARNESS_NATIVE_SMOKE_NONCE='native-smoke-fixture-20260713' .harness/bin/decision-hook codex < '$TMP/answer-event.json' >/dev/null && grep -Fq 'GO' log/decisions/$ID.answer.md && ! grep -Fq INJECTED log/decisions/$ID.answer.md"

mk_proj "$TMP/hook-mutating-unstaged"; fill_project "$TMP/hook-mutating-unstaged"
open_fixture_decision "$TMP/hook-mutating-unstaged" "$ID" codex >/dev/null
printf 'unrelated baseline\n' > "$TMP/hook-mutating-unstaged/source/unrelated.txt"
git -C "$TMP/hook-mutating-unstaged" add source/unrelated.txt
git -C "$TMP/hook-mutating-unstaged" commit -qm 'test unrelated baseline'
mut_unstaged_base="$(git -C "$TMP/hook-mutating-unstaged" rev-parse HEAD)"
cp "$TMP/hook-mutating-unstaged/log/pending-decision.yaml" "$TMP/hook-mutating-unstaged/expected-pending"
printf 'unrelated-index-version\n' > "$TMP/hook-mutating-unstaged/expected-index"
printf 'unrelated-worktree-version\n' > "$TMP/hook-mutating-unstaged/expected-worktree"
cat > "$TMP/hook-mutating-unstaged/.git/hooks/pre-commit" <<'SH'
#!/bin/sh
answer="log/decisions/D-20260713-120000-01.answer.md"
cp "$answer" "$EXPECTED_ANSWER"
printf '\nINJECTED WITHOUT STAGING\n' >> "$answer"
repo_index="$(GIT_INDEX_FILE= git rev-parse --show-toplevel)/.git/index"
printf '%s\n' unrelated-index-version > source/unrelated.txt
GIT_INDEX_FILE="$repo_index" git add source/unrelated.txt
printf '%s\n' unrelated-worktree-version > source/unrelated.txt
exit 0
SH
chmod +x "$TMP/hook-mutating-unstaged/.git/hooks/pre-commit"
t "hook: unstaged pre-commit answer mutation blocks and rolls back" 0 bash -c \
  "cd '$TMP/hook-mutating-unstaged' && EXPECTED_ANSWER='$TMP/hook-mutating-unstaged/expected-answer' HARNESS_NATIVE_SMOKE_NONCE='native-smoke-fixture-20260713' .harness/bin/decision-hook codex < '$TMP/answer-event.json' | yq -e '.decision == \"block\"' >/dev/null && [ \"\$(git rev-parse HEAD)\" = '$mut_unstaged_base' ] && [ \"\$(yq -r .status log/pending-decision.yaml)\" = awaiting_answer ] && cmp -s '$TMP/hook-mutating-unstaged/expected-pending' log/pending-decision.yaml && cmp -s '$TMP/hook-mutating-unstaged/expected-answer' log/decisions/$ID.answer.pending.md && cmp -s '$TMP/hook-mutating-unstaged/expected-index' <(git show :source/unrelated.txt) && cmp -s '$TMP/hook-mutating-unstaged/expected-worktree' source/unrelated.txt && git diff --cached --quiet HEAD -- log/pending-decision.yaml log/decisions/$ID.answer.md && git diff --quiet HEAD -- log/pending-decision.yaml log/decisions/$ID.answer.md && [ ! -e log/decisions/$ID.answer.md ]"
rm -f "$TMP/hook-mutating-unstaged/.git/hooks/pre-commit"

mk_proj "$TMP/hook-stop"; fill_project "$TMP/hook-stop"
open_fixture_decision "$TMP/hook-stop" "$ID" codex >/dev/null
t "hook Stop: matching decision id passes" 0 bash -c \
  "cd '$TMP/hook-stop' && printf '%s' '{\"hook_event_name\":\"Stop\",\"last_assistant_message\":\"Choose now.\\n\\n결정 ID: $ID\"}' | .harness/bin/decision-hook codex | yq -e 'tag == \"!!map\" and length == 0' >/dev/null"
t "hook Stop: missing decision id blocks" 0 bash -c \
  "cd '$TMP/hook-stop' && printf '%s' '{\"hook_event_name\":\"Stop\",\"last_assistant_message\":\"Choose now?\"}' | .harness/bin/decision-hook codex | yq -e '.decision == \"block\"' >/dev/null"

mk_proj "$TMP/hook-recover"; fill_project "$TMP/hook-recover"
open_fixture_decision "$TMP/hook-recover" "$ID" codex >/dev/null
printf '#!/bin/sh\nexit 1\n' > "$TMP/hook-recover/.git/hooks/pre-commit"
chmod +x "$TMP/hook-recover/.git/hooks/pre-commit"
t "hook: commit failure blocks and retains recovery answer" 0 bash -c \
  "cd '$TMP/hook-recover' && HARNESS_NATIVE_SMOKE_NONCE='native-smoke-fixture-20260713' .harness/bin/decision-hook codex < '$TMP/answer-event.json' | yq -e '.decision == \"block\"' >/dev/null && [ -f log/decisions/$ID.answer.pending.md ] && [ \"\$(yq -r .status log/pending-decision.yaml)\" = awaiting_answer ]"
rm "$TMP/hook-recover/.git/hooks/pre-commit"
cat > "$TMP/retry-event.json" <<'JSON'
{"hook_event_name":"UserPromptSubmit","session_id":"session-b","turn_id":"turn-b","prompt":"retry trigger only"}
JSON
t "hook: next call commits original recovery, not retry text" 0 bash -c \
  "cd '$TMP/hook-recover' && HARNESS_NATIVE_SMOKE_NONCE='native-smoke-fixture-20260713' .harness/bin/decision-hook claude < '$TMP/retry-event.json' | yq -e '.hookSpecificOutput.hookEventName == \"UserPromptSubmit\"' >/dev/null && grep -Fq 'GO' log/decisions/$ID.answer.md && ! grep -Fq 'retry trigger only' log/decisions/$ID.answer.md"

mk_proj "$TMP/hook-block-json"; fill_project "$TMP/hook-block-json"
open_fixture_decision "$TMP/hook-block-json" "$ID" codex >/dev/null
printf '#!/bin/sh\nexit 1\n' > "$TMP/hook-block-json/.git/hooks/pre-commit"
chmod +x "$TMP/hook-block-json/.git/hooks/pre-commit"
mkdir "$TMP/fakebin-recovery-cp"
cat > "$TMP/fakebin-recovery-cp/cp" <<'SH'
#!/bin/sh
last=''
for arg do last="$arg"; done
case "$last" in *.answer.pending.md.rollback.*) exit 1;; esac
exec "$REAL_CP" "$@"
SH
chmod +x "$TMP/fakebin-recovery-cp/cp"
quoted_tmp="$TMP/quoted\"tmp"
mkdir "$quoted_tmp"
real_cp="$(command -v cp)"
t "hook: rollback failure still emits valid fixed block JSON" 0 bash -c \
  "cd '$TMP/hook-block-json' && PATH='$TMP/fakebin-recovery-cp:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin' REAL_CP='$real_cp' TMPDIR='$quoted_tmp' HARNESS_NATIVE_SMOKE_NONCE='native-smoke-fixture-20260713' .harness/bin/decision-hook codex < '$TMP/answer-event.json' | yq -e '.decision == \"block\"' >/dev/null"

mk_proj "$TMP/hook-interrupted"; fill_project "$TMP/hook-interrupted"
open_fixture_decision "$TMP/hook-interrupted" "$ID" codex >/dev/null
cp "$TMP/hook-answer/log/decisions/$ID.answer.md" \
  "$TMP/hook-interrupted/log/decisions/$ID.answer.md"
yq -i '.status = "answer_captured"' "$TMP/hook-interrupted/log/pending-decision.yaml"
git -C "$TMP/hook-interrupted" add log/pending-decision.yaml "log/decisions/$ID.answer.md"
t "hook: interrupted staged capture normalizes and commits original" 0 bash -c \
  "cd '$TMP/hook-interrupted' && HARNESS_NATIVE_SMOKE_NONCE='native-smoke-fixture-20260713' .harness/bin/decision-hook codex < '$TMP/retry-event.json' >/dev/null && git diff --quiet HEAD -- log/pending-decision.yaml log/decisions/$ID.answer.md && grep -Fq 'GO' log/decisions/$ID.answer.md && ! grep -Fq 'retry trigger only' log/decisions/$ID.answer.md"

mk_proj "$TMP/hook-signing"; fill_project "$TMP/hook-signing"
open_fixture_decision "$TMP/hook-signing" "$ID" codex >/dev/null
git -C "$TMP/hook-signing" config commit.gpgsign true
t "hook: interactive signing policy blocks without bypass" 0 bash -c \
  "cd '$TMP/hook-signing' && HARNESS_NATIVE_SMOKE_NONCE='native-smoke-fixture-20260713' .harness/bin/decision-hook codex < '$TMP/answer-event.json' | yq -e '.decision == \"block\"' >/dev/null && [ -f log/decisions/$ID.answer.pending.md ] && [ \"\$(yq -r .status log/pending-decision.yaml)\" = awaiting_answer ]"

state_fixture() {
  local p="$1" status="$2" run_id="${3:-}"
  mk_proj "$p"; fill_project "$p"
  sed -i.bak 's/\*\*현재 단계:\*\* .*/**현재 단계:** 디스패치 · **최고 활성 T등급:** T1/' "$p/STATUS.md" && rm -f "$p/STATUS.md.bak"
  sed -i.bak 's/\*\*현재 단계:\*\* .*/**현재 단계:** 디스패치/' "$p/log/HANDOFF.md" && rm -f "$p/log/HANDOFF.md.bak"
  cat > "$p/tasks.yaml" <<YAML
tasks:
  - id: T-001
    name: example
    role: standard_worker
    grade: T1
    depends_on: []
    worktree: "."
    write_paths: []
    done_when: log/T-001.done
    on_fail: hold_downstream
    status: $status
    run_id: $run_id
    brief: agents/worker-T-001.md
YAML
  printf '임무: example\n산출물: x\n쓰기 허용 경로: source/\n완료 신호: log/T-001.done\n' > "$p/agents/worker-T-001.md"
}

state_fixture "$TMP/state-phase-mismatch" running run-1
sed -i.bak 's/\*\*현재 단계:\*\* 디스패치/**현재 단계:** 루프/' "$TMP/state-phase-mismatch/log/HANDOFF.md" && rm -f "$TMP/state-phase-mismatch/log/HANDOFF.md.bak"
t "state: STATUS and HANDOFF phase mismatch is rejected" 1 bash -c \
  "cd '$TMP/state-phase-mismatch' && . .harness/lib/state.sh && validate_state"
state_fixture "$TMP/state-missing-run" running ''
t "state: running task requires run_id" 1 bash -c \
  "cd '$TMP/state-missing-run' && . .harness/lib/state.sh && validate_state"
state_fixture "$TMP/state-marker-mismatch" verified run-new
printf 'run_id: run-old\nstatus: DONE\n' > "$TMP/state-marker-mismatch/log/T-001.done"
t "state: verified task rejects mismatched marker run_id" 1 bash -c \
  "cd '$TMP/state-marker-mismatch' && . .harness/lib/state.sh && validate_state"
state_fixture "$TMP/state-run-match" verified run-new
printf 'run_id: run-new\nartifact: source/out.txt\nstatus: DONE\n' \
  > "$TMP/state-run-match/log/T-001.done"
mkdir -p "$TMP/state-run-match/source"; printf 'x\n' > "$TMP/state-run-match/source/out.txt"
mk_verified_fixture "$TMP/state-run-match" T-001 run-new
t "state: matching task and marker run_id passes" 0 bash -c \
  "cd '$TMP/state-run-match' && . .harness/lib/state.sh && validate_state"
# --- B-001: state.sh 새 계약 ---
state_fixture "$TMP/state-no-runs" 'done' run-1
mkdir -p "$TMP/state-no-runs/source"; printf 'x\n' > "$TMP/state-no-runs/source/out.txt"
printf 'run_id: run-1\nartifact: source/out.txt\nstatus: DONE\n' \
  > "$TMP/state-no-runs/log/T-001.done"
t "state: done인데 .runs finished 없으면 FAIL" 1 bash -c \
  "cd '$TMP/state-no-runs' && . .harness/lib/state.sh && validate_state"
state_fixture "$TMP/state-no-artifact" 'done' run-1
printf 'run_id: run-1\nstatus: DONE\n' > "$TMP/state-no-artifact/log/T-001.done"
mk_verified_fixture "$TMP/state-no-artifact" T-001 run-1
t "state: done 마커에 필수 artifact가 없으면 FAIL" 1 bash -c \
  "cd '$TMP/state-no-artifact' && . .harness/lib/state.sh && validate_state"
state_fixture "$TMP/state-redispatch" 'done' run-1
mkdir -p "$TMP/state-redispatch/source"; printf 'x\n' > "$TMP/state-redispatch/source/out.txt"
printf 'run_id: run-1\nartifact: source/out.txt\nstatus: DONE\n' \
  > "$TMP/state-redispatch/log/T-001.done"
mk_verified_fixture "$TMP/state-redispatch" T-001 run-1
printf 'run_id: run-1 event: dispatched at: 2026-07-14T00:01:00Z role: standard_worker cli: sh mux: tmux ws: hx-T-001\nrun_id: run-1 event: started at: 2026-07-14T00:01:01Z\n' \
  >> "$TMP/state-redispatch/log/T-001.runs"
t "state: 같은 run_id 재dispatch 뒤 미완료 실행은 FAIL" 1 bash -c \
  "cd '$TMP/state-redispatch' && . .harness/lib/state.sh && validate_state"
state_fixture "$TMP/state-tamper" verified run-1
printf 'run_id: run-1\nartifact: source/out.txt\nstatus: DONE\n' \
  > "$TMP/state-tamper/log/T-001.done"
mkdir -p "$TMP/state-tamper/source"; printf 'x\n' > "$TMP/state-tamper/source/out.txt"
mk_verified_fixture "$TMP/state-tamper" T-001 run-1
printf 'run_id: run-1\nartifact: source/out.txt\nstatus: DONE\ntampered: yes\n' \
  > "$TMP/state-tamper/log/T-001.done"
t "state: .done 사후 변조 감지(done_sha256 불일치) FAIL" 1 bash -c \
  "cd '$TMP/state-tamper' && . .harness/lib/state.sh && validate_state"
state_fixture "$TMP/state-no-vy" verified run-1
printf 'run_id: run-1\nartifact: source/out.txt\nstatus: DONE\n' \
  > "$TMP/state-no-vy/log/T-001.done"
mk_verified_fixture "$TMP/state-no-vy" T-001 run-1
rm "$TMP/state-no-vy/log/T-001.verified.yaml"
t "state: verified인데 verified.yaml 없으면 FAIL" 1 bash -c \
  "cd '$TMP/state-no-vy' && . .harness/lib/state.sh && validate_state"

mk_proj "$TMP/close"; fill_project "$TMP/close"
open_fixture_decision "$TMP/close" "$ID" codex >/dev/null
(cd "$TMP/close" && HARNESS_NATIVE_SMOKE_NONCE='native-smoke-fixture-20260713' .harness/bin/decision-hook codex < "$TMP/answer-event.json" >/dev/null)
t "decision-close: refuses while sections still show open id" 1 bash -c \
  "cd '$TMP/close' && .harness/bin/decision-close '$ID'"
set_section_value "$TMP/close/STATUS.md" '## 다음 사용자 결정' '(없음)'
set_section_value "$TMP/close/log/HANDOFF.md" '## 열린 결정' '(없음)'
t "decision-close: commits state and removes pending" 0 bash -c \
  "cd '$TMP/close' && .harness/bin/decision-close '$ID'"
t "decision-close: request and answer remain, pending gone" 0 bash -c \
  "cd '$TMP/close' && [ ! -e log/pending-decision.yaml ] && [ -f log/decisions/$ID.request.md ] && [ -f log/decisions/$ID.answer.md ] && [ -z \"\$(git status --porcelain)\" ]"

mk_proj "$TMP/close-invalid"; fill_project "$TMP/close-invalid"
open_fixture_decision "$TMP/close-invalid" "$ID" codex >/dev/null
(cd "$TMP/close-invalid" && HARNESS_NATIVE_SMOKE_NONCE='native-smoke-fixture-20260713' \
  .harness/bin/decision-hook codex < "$TMP/answer-event.json" >/dev/null)
set_section_value "$TMP/close-invalid/STATUS.md" '## 다음 사용자 결정' '(없음)'
set_section_value "$TMP/close-invalid/log/HANDOFF.md" '## 열린 결정' '(없음)'
cat > "$TMP/close-invalid/tasks.yaml" <<'YAML'
tasks:
  - id: T-001
    status: done
    run_id: run-missing-evidence
YAML
t "decision-close: 상태 검증 실패면 pending 제거를 커밋하지 않음" 0 bash -c \
  "cd '$TMP/close-invalid' && before=\$(git rev-parse HEAD) \
   && ! .harness/bin/decision-close '$ID' >/dev/null 2>&1 \
   && [ \"\$(git rev-parse HEAD)\" = \"\$before\" ] \
   && [ -f log/pending-decision.yaml ]"

mkdir "$TMP/legacy"; cp "$ROOT/template/HARNESS.md" "$TMP/legacy/HARNESS.md"
(cd "$TMP/legacy" && git init -q)
t "migration: dry-run creates nothing" 0 bash -c \
  "'$ROOT/scripts/migrate-b002.sh' '$TMP/legacy' >/dev/null && [ ! -e '$TMP/legacy/.harness' ] && [ ! -e '$TMP/legacy/log/HANDOFF.md' ]"
t "migration: apply copies B-002 runtime without overwrite" 0 bash -c \
  "'$ROOT/scripts/migrate-b002.sh' '$TMP/legacy' --apply >/dev/null && [ -x '$TMP/legacy/.harness/bin/decision-hook' ] && [ -f '$TMP/legacy/.claude/settings.json' ] && [ -f '$TMP/legacy/.codex/hooks.json' ] && [ -f '$TMP/legacy/log/HANDOFF.md' ]"
t "migration: B-002 적용에 필수 worker-wrap 포함" 0 bash -c \
  "[ -x '$TMP/legacy/.harness/bin/worker-wrap' ]"
mkdir "$TMP/legacy-b2-complete"
(cd "$TMP/legacy-b2-complete" && git init -q)
cat > "$TMP/legacy-b2-complete/tasks.yaml" <<'YAML'
tasks:
  - id: T-001
    status: verified
    run_id: legacy-run
YAML
mkdir -p "$TMP/legacy-b2-complete/log"
printf 'run_id: legacy-run\nstatus: VERIFIED\n' \
  > "$TMP/legacy-b2-complete/log/T-001.done"
t "migration: B-002도 완료된 B-001 이전을 변경 전에 거부" 0 bash -c \
  "! '$ROOT/scripts/migrate-b002.sh' '$TMP/legacy-b2-complete' --apply >/dev/null 2>&1 \
   && [ ! -e '$TMP/legacy-b2-complete/.harness' ] \
   && [ ! -e '$TMP/legacy-b2-complete/log/HANDOFF.md' ]"
printf 'local config\n' > "$TMP/legacy/.codex/hooks.json"
rm -rf "$TMP/legacy/.harness" "$TMP/legacy/.claude"
t "migration: conflict aborts before partial copy" 1 bash -c \
  "'$ROOT/scripts/migrate-b002.sh' '$TMP/legacy' --apply >/dev/null 2>&1"
t "migration: conflict left no partial runtime" 0 bash -c \
  "[ ! -e '$TMP/legacy/.harness' ] && [ ! -e '$TMP/legacy/.claude' ]"

# --- dispatch 거부 경로 (mux 도달 전에 거부되므로 mux 불필요) ---
DP="$ROOT/scripts/dispatch.sh"
mk_proj "$TMP/p3"; fill_project "$TMP/p3"
cat > "$TMP/p3/tasks.yaml" <<'YAML'
tasks:
  - { id: A, name: a, role: standard_worker, grade: T1, depends_on: [],
      worktree: ".", write_paths: [], done_when: x, on_fail: hold_downstream,
      status: pending, brief: agents/worker-A.md }
  - { id: C, name: c, role: standard_worker, grade: T1, depends_on: [A],
      worktree: ".", write_paths: [], done_when: x, on_fail: hold_downstream,
      status: pending, brief: agents/worker-C.md }
YAML
printf '임무: a\n산출물: x\n쓰기 허용 경로: source/\n완료 신호: log/A.done 생성\n' > "$TMP/p3/agents/worker-A.md"
printf '임무: c\n산출물: x\n쓰기 허용 경로: source/\n완료 신호: log/C.done 생성\n' > "$TMP/p3/agents/worker-C.md"
# 방어선: 테스트에서 dispatch가 게이트를 뚫어도 실제 AI CLI에 닿지 않게
# sh 기반 모델 파일로 강제한다 (HARNESS_MODELS 오버라이드).
DPE="env HARNESS_MODELS=$TMP/models-ok.yaml"
t "dispatch: scaffold-check 미통과면 거부" 1 bash -c "cd '$TMP/p3' && $DPE bash '$DP' A"
(cd "$TMP/p3" && bash "$ROOT/scripts/scaffold-check.sh" >/dev/null)
t "dispatch: 없는 태스크면 거부" 1 bash -c "cd '$TMP/p3' && $DPE bash '$DP' ZZZ"
t "dispatch: 의존 미VERIFIED면 거부" 1 bash -c "cd '$TMP/p3' && $DPE bash '$DP' C"
printf 'run_id: r1\nstatus: DONE\n' > "$TMP/p3/log/A.done"
t "dispatch: 의존 DONE(미검증)이어도 거부" 1 bash -c "cd '$TMP/p3' && $DPE bash '$DP' C"
# 완료 신호 문구가 어디에도 없는 브리프로 교체
printf '임무: c\n산출물: x\n쓰기 허용 경로: source/\n' > "$TMP/p3/agents/worker-C.md"
printf 'run_id: r1\nstatus: DONE\n' > "$TMP/p3/log/A.done"
mkdir -p "$TMP/p3/source"; printf 'x\n' > "$TMP/p3/source/out.txt"
mk_verified_fixture "$TMP/p3" A r1
t "dispatch: 브리프에 완료 신호 없으면 거부" 1 bash -c "cd '$TMP/p3' && $DPE bash '$DP' C"

# --- B-001: dispatch 새 게이트 ---
# C의 브리프를 완료 신호가 있는 원본으로 복구해야 아래 테스트가 게이트 3이 아닌
# 게이트 4(의존)에서 거부된다. 이후 p3에서 dispatch를 추가 호출하지 않는다
# (게이트 전부 충족 시 실제 mux 기동에 도달하므로).
printf '임무: c\n산출물: x\n쓰기 허용 경로: source/\n완료 신호: log/C.done 생성\n' > "$TMP/p3/agents/worker-C.md"
t "dispatch: 의존 .done과 verified.yaml run_id 불일치면 거부" 1 bash -c \
  "cd '$TMP/p3' && sed -i.bak 's/^run_id: r1\$/run_id: r2/' log/A.done && rm -f log/A.done.bak; $DPE bash '$DP' C"
printf 'run_id: r1\nstatus: DONE\n' > "$TMP/p3/log/A.done"
mk_proj "$TMP/p4"; fill_project "$TMP/p4"
cp "$TMP/p3/tasks.yaml" "$TMP/p4/tasks.yaml"
printf '임무: a\n산출물: x\n쓰기 허용 경로: source/\n완료 신호: log/A.done 생성\n' > "$TMP/p4/agents/worker-A.md"
printf '임무: c\n산출물: x\n쓰기 허용 경로: source/\n완료 신호: log/C.done 생성\n' > "$TMP/p4/agents/worker-C.md"
(cd "$TMP/p4" && bash "$ROOT/scripts/scaffold-check.sh" >/dev/null)
rm "$TMP/p4/.harness/bin/worker-wrap"
t "dispatch: worker-wrap 없으면 거부" 1 bash -c "cd '$TMP/p4' && $DPE bash '$DP' A"

mk_proj "$TMP/p-runid"; fill_project "$TMP/p-runid"
cat > "$TMP/p-runid/tasks.yaml" <<'YAML'
tasks:
  - { id: A, name: a, role: standard_worker, grade: T1, depends_on: [],
      worktree: ".", write_paths: [], done_when: x, on_fail: hold_downstream,
      status: pending, brief: agents/worker-A.md }
YAML
printf '임무: a\n산출물: x\n쓰기 허용 경로: source/\n완료 신호: log/A.done 생성\n' \
  > "$TMP/p-runid/agents/worker-A.md"
(cd "$TMP/p-runid" && bash "$ROOT/scripts/scaffold-check.sh" >/dev/null)
mkdir -p "$TMP/fakebin-dispatch"
cat > "$TMP/fakebin-dispatch/cmux" <<'SH'
#!/bin/sh
case "$1" in
  ping|select-workspace) exit 0;;
  new-workspace)
    if [ -n "${CMUX_CAPTURE:-}" ]; then printf '%s\n' "$@" > "$CMUX_CAPTURE"; fi
    echo 'workspace:1'
    ;;
  *) exit 1;;
esac
SH
cat > "$TMP/fakebin-dispatch/date" <<'SH'
#!/bin/sh
case "$1" in
  -u) echo '2026-07-14T00:00:00Z';;
  *) echo '20260714-000000';;
esac
SH
cat > "$TMP/fakebin-dispatch/codex" <<'SH'
#!/bin/sh
exit 99
SH
chmod +x "$TMP/fakebin-dispatch/cmux" "$TMP/fakebin-dispatch/date" \
  "$TMP/fakebin-dispatch/codex"
t "dispatch: 같은 초 재실행도 고유 run_id 발급" 0 bash -c \
  "cd '$TMP/p-runid' \
   && PATH='$TMP/fakebin-dispatch:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin' HARNESS_LAYOUT=workspace $DPE bash '$DP' A >/dev/null \
   && PATH='$TMP/fakebin-dispatch:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin' HARNESS_LAYOUT=workspace $DPE bash '$DP' A >/dev/null \
   && [ \"\$(awk '\$4 == \"dispatched\" {print \$2}' log/A.runs | sort -u | wc -l | tr -d ' ')\" = 2 ]"
INJECT_ID='../../b001-injected" or .id == "A'
INJECT_BASE="$TMP/b001-injected\" or .id == \"A"
# shellcheck disable=SC2016 # bash -c 위치 인자는 내부 셸에서 확장한다.
t "dispatch: 주입 task id는 다른 태스크 선택·프로젝트 밖 쓰기 전에 거부" 0 bash -c '
  cd "$1" || exit 1
  PATH="$2:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin" \
    HARNESS_MODELS="$3" bash "$4" "$5" >/dev/null 2>&1
  rc=$?
  [ "$rc" -ne 0 ] && [ ! -e "$6.prompt" ] && [ ! -e "$6.runs" ]
' _ "$TMP/p-runid" "$TMP/fakebin-dispatch" "$TMP/models-ok.yaml" "$DP" \
  "$INJECT_ID" "$INJECT_BASE"

mk_proj "$TMP/p-wtdone"; fill_project "$TMP/p-wtdone"; mkdir "$TMP/p-wtdone/wt"
cat > "$TMP/p-wtdone/tasks.yaml" <<'YAML'
tasks:
  - { id: A, name: a, role: standard_worker, grade: T1, depends_on: [],
      worktree: "wt", write_paths: [], done_when: x, on_fail: hold_downstream,
      status: pending, brief: agents/worker-A.md }
YAML
printf '임무: a\n산출물: x\n쓰기 허용 경로: source/\n완료 신호: log/A.done 생성\n' \
  > "$TMP/p-wtdone/agents/worker-A.md"
(cd "$TMP/p-wtdone" && bash "$ROOT/scripts/scaffold-check.sh" >/dev/null)
cat > "$TMP/models-codex.yaml" <<'YAML'
roles:
  standard_worker:
    effort: medium
    candidates:
      - name: codex-exec
        command: codex
        args: ["exec", "--sandbox", "workspace-write"]
YAML
t "dispatch: 격리 워커가 중앙 .done 경로와 쓰기 권한을 받음" 0 bash -c \
  "cd '$TMP/p-wtdone' \
   && PATH='$TMP/fakebin-dispatch:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin' \
      CMUX_CAPTURE='$TMP/wtdone-cmux-args' HARNESS_LAYOUT=workspace HARNESS_MODELS='$TMP/models-codex.yaml' bash '$DP' A >/dev/null \
   && grep -Fq '$TMP/p-wtdone/log/A.done.tmp' log/A.prompt \
   && grep -Fq -- '--add-dir' '$TMP/wtdone-cmux-args' \
   && grep -Fq '$TMP/p-wtdone/log' '$TMP/wtdone-cmux-args'"

mk_proj "$TMP/p-forged"; fill_project "$TMP/p-forged"
cat > "$TMP/p-forged/tasks.yaml" <<'YAML'
tasks:
  - { id: A, name: a, role: standard_worker, grade: T1, depends_on: [],
      worktree: ".", write_paths: [], done_when: x, on_fail: hold_downstream,
      status: pending, brief: agents/worker-A.md }
  - { id: C, name: c, role: standard_worker, grade: T1, depends_on: [A],
      worktree: ".", write_paths: [], done_when: x, on_fail: hold_downstream,
      status: pending, brief: agents/worker-C.md }
YAML
printf '임무: a\n산출물: x\n쓰기 허용 경로: source/\n완료 신호: log/A.done 생성\n' \
  > "$TMP/p-forged/agents/worker-A.md"
printf '임무: c\n산출물: x\n쓰기 허용 경로: source/\n완료 신호: log/C.done 생성\n' \
  > "$TMP/p-forged/agents/worker-C.md"
(cd "$TMP/p-forged" && bash "$ROOT/scripts/scaffold-check.sh" >/dev/null)
mkdir -p "$TMP/p-forged/source"; printf 'x\n' > "$TMP/p-forged/source/out.txt"
yq -i '.tasks[0].status = "verified" | .tasks[0].run_id = "r1"' \
  "$TMP/p-forged/tasks.yaml"
mk_verified_fixture "$TMP/p-forged" A r1
printf 'status: DONE-FORGED\nrun_id: r1\n' > "$TMP/p-forged/log/A.verified.yaml"
t "dispatch: 위조된 dependency verified.yaml을 거부" 1 bash -c \
  "cd '$TMP/p-forged' \
   && PATH='$TMP/fakebin-dispatch:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin' \
      $DPE bash '$DP' C"

# --- B-001: worker-wrap ---
WW="$ROOT/template/.harness/bin/worker-wrap"
mkdir -p "$TMP/ww"; printf 'hello prompt\n' > "$TMP/ww/p.txt"
t "worker-wrap: started/finished 사건과 exit 0 기록" 0 bash -c \
  "'$WW' '$TMP/ww/a.runs' run-1 '$TMP/ww/a.log' '$TMP/ww/p.txt' -- sh -c 'cat >/dev/null; echo out' >/dev/null \
   && grep -q '^run_id: run-1 event: started at: ....-..-..T..:..:..Z\$' '$TMP/ww/a.runs' \
   && grep -q '^run_id: run-1 event: finished at: ....-..-..T..:..:..Z exit_code: 0\$' '$TMP/ww/a.runs' \
   && grep -q '^out\$' '$TMP/ww/a.log'"
t "worker-wrap: 명령 실패 시 종료 코드 전파 + finished 기록" 7 bash -c \
  "'$WW' '$TMP/ww/b.runs' run-2 '$TMP/ww/b.log' '$TMP/ww/p.txt' -- sh -c 'exit 7' >/dev/null; rc=\$?; \
   grep -q 'event: finished at: .* exit_code: 7\$' '$TMP/ww/b.runs' && exit \$rc"
t "worker-wrap: 안전하지 않은 run_id 거부" 2 \
  "$WW" "$TMP/ww/c.runs" 'bad id!' "$TMP/ww/c.log" "$TMP/ww/p.txt" -- sh -c true
t "worker-wrap: prompt 파일 없으면 거부" 2 \
  "$WW" "$TMP/ww/d.runs" run-4 "$TMP/ww/d.log" "$TMP/ww/no-such" -- sh -c true
t "worker-wrap: -- 구분자 없으면 거부" 2 \
  "$WW" "$TMP/ww/e.runs" run-5 "$TMP/ww/e.log" "$TMP/ww/p.txt" sh -c true
mkdir "$TMP/ww/runs-dir"
t "worker-wrap: started 사건 append 실패를 숨기지 않음" 1 \
  "$WW" "$TMP/ww/runs-dir" run-6 "$TMP/ww/f.log" "$TMP/ww/p.txt" -- sh -c true
mkdir "$TMP/ww/log-dir"
t "worker-wrap: tee 실패는 nonzero finished로 닫힘" 0 bash -c \
  "if '$WW' '$TMP/ww/g.runs' run-7 '$TMP/ww/log-dir' '$TMP/ww/p.txt' -- sh -c true; then exit 1; fi \
   && grep -q 'event: finished at: .* exit_code: 1\$' '$TMP/ww/g.runs'"
t "worker-wrap: finished 사건 append 실패를 숨기지 않음" 1 bash -c \
  "'$WW' '$TMP/ww/h.runs' run-8 '$TMP/ww/h.log' '$TMP/ww/p.txt' -- \
     sh -c 'rm -f \"\$1\"; mkdir \"\$1\"' _ '$TMP/ww/h.runs' >/dev/null"

# --- B-001: lib.sh 헬퍼 ---
t "lib: utc_now는 RFC3339 UTC" 0 bash -c \
  ". '$ROOT/scripts/lib.sh'; utc_now | grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z\$'"
t "lib: sha256_file은 64hex" 0 bash -c \
  ". '$ROOT/scripts/lib.sh'; printf x > '$TMP/h.txt'; sha256_file '$TMP/h.txt' | grep -Eq '^[0-9a-f]{64}\$'"

# --- B-001: verify.sh 픽스처 ---
VF="$ROOT/scripts/verify.sh"
mk_vproj() { # $1=디렉토리: verify 필드를 가진 태스크 T-001 프로젝트
  mk_proj "$1"; fill_project "$1"
  cat > "$1/tasks.yaml" <<'YAML'
tasks:
  - id: T-001
    name: example
    role: standard_worker
    grade: T1
    depends_on: []
    worktree: "."
    write_paths: []
    done_when: log/T-001.done
    on_fail: hold_downstream
    status: running
    run_id: run-1
    brief: agents/worker-T-001.md
    verify:
      command: sh
      args: ["-c", "cat source/out.txt"]
YAML
  printf '임무: example\n산출물: x\n쓰기 허용 경로: source/\n완료 신호: log/T-001.done\n' \
    > "$1/agents/worker-T-001.md"
  printf 'payload\n' > "$1/source/out.txt"
}
mk_runs() { # $1=프로젝트 $2=run_id [$3=exit_code(없으면 finished 생략)]
  printf 'run_id: %s event: dispatched at: 2026-07-14T00:00:00Z role: standard_worker cli: sh mux: tmux ws: hx-T-001\n' "$2" >> "$1/log/T-001.runs"
  printf 'run_id: %s event: started at: 2026-07-14T00:00:01Z\n' "$2" >> "$1/log/T-001.runs"
  if [ "$#" -ge 3 ]; then
    printf 'run_id: %s event: finished at: 2026-07-14T00:00:05Z exit_code: %s\n' "$2" "$3" >> "$1/log/T-001.runs"
  fi
}
mk_done() { # $1=프로젝트 $2=run_id
  printf 'run_id: %s\nartifact: source/out.txt\nstatus: DONE\n' "$2" > "$1/log/T-001.done"
}

mk_vproj "$TMP/v1"
t "verify: .runs 없으면 거부" 1 bash -c "cd '$TMP/v1' && bash '$VF' T-001"
t "verify: .runs 부재도 attempt와 FAIL을 감사 로그에 기록" 0 bash -c \
  "cd '$TMP/v1' && [ -f log/T-001.verify.log ] \
   && grep -q '^=== verify T-001 run unknown attempt ' log/T-001.verify.log \
   && grep -q 'FAIL: .runs 없음' log/T-001.verify.log"
mk_runs "$TMP/v1" run-1
t "verify: finished 없으면 거부(실행 중)" 1 bash -c "cd '$TMP/v1' && bash '$VF' T-001"
mk_vproj "$TMP/v2"; mk_runs "$TMP/v2" run-1 3; mk_done "$TMP/v2" run-1
t "verify: exit_code≠0이면 거부" 1 bash -c "cd '$TMP/v2' && bash '$VF' T-001"
mk_vproj "$TMP/v3"; mk_runs "$TMP/v3" run-1 0
t "verify: .done 없으면 거부" 1 bash -c "cd '$TMP/v3' && bash '$VF' T-001"
mk_done "$TMP/v3" run-0
t "verify: .done run_id가 최신 실행과 불일치면 거부" 1 bash -c "cd '$TMP/v3' && bash '$VF' T-001"
mk_vproj "$TMP/v4"; mk_runs "$TMP/v4" run-old 0; mk_runs "$TMP/v4" run-1
mk_done "$TMP/v4" run-old
t "verify: 오래된 dispatched 실행은 무시(결정 16)" 1 bash -c "cd '$TMP/v4' && bash '$VF' T-001"
mk_vproj "$TMP/v-redispatch"; mk_runs "$TMP/v-redispatch" run-1 0
mk_runs "$TMP/v-redispatch" run-1; mk_done "$TMP/v-redispatch" run-1
t "verify: 같은 run_id 재dispatch 뒤 과거 finished를 무시" 1 bash -c \
  "cd '$TMP/v-redispatch' && bash '$VF' T-001"
mk_vproj "$TMP/v5"; mk_runs "$TMP/v5" run-1 0
printf 'run_id: run-1\nartifact: source/no-such.txt\nstatus: DONE\n' > "$TMP/v5/log/T-001.done"
t "verify: artifact 파일 없으면 거부" 1 bash -c "cd '$TMP/v5' && bash '$VF' T-001"
mk_vproj "$TMP/v6"; mk_runs "$TMP/v6" run-1 0; mk_done "$TMP/v6" run-1
sed -i.bak 's/status: DONE/status: VERIFIED/' "$TMP/v6/log/T-001.done" && rm -f "$TMP/v6/log/T-001.done.bak"
t "verify: .done status가 DONE 아니면 거부(옛 VERIFIED 포함)" 1 bash -c "cd '$TMP/v6' && bash '$VF' T-001"
mk_vproj "$TMP/v-audit-tasks"; mk_runs "$TMP/v-audit-tasks" run-1 0
printf 'tasks: [\n' > "$TMP/v-audit-tasks/tasks.yaml"
t "verify: malformed tasks.yaml 실패도 감사 로그에 기록" 0 bash -c \
  "cd '$TMP/v-audit-tasks' && if bash '$VF' T-001; then exit 1; fi \
   && grep -q '^=== verify T-001 run run-1 attempt ' log/T-001.verify.log \
   && grep -q 'FAIL:' log/T-001.verify.log"
mk_vproj "$TMP/v-audit-done"; mk_runs "$TMP/v-audit-done" run-1 0
printf 'run_id: [\n' > "$TMP/v-audit-done/log/T-001.done"
t "verify: malformed .done 실패도 감사 로그에 기록" 0 bash -c \
  "cd '$TMP/v-audit-done' && if bash '$VF' T-001; then exit 1; fi \
   && grep -q 'FAIL:' log/T-001.verify.log"
mk_vproj "$TMP/v-audit-git"; mk_runs "$TMP/v-audit-git" run-1 0
mk_done "$TMP/v-audit-git" run-1
mkdir "$TMP/fakebin-vgit"
cat > "$TMP/fakebin-vgit/git" <<'SH'
#!/bin/sh
for arg do [ "$arg" = hash-object ] && exit 42; done
exec "$REAL_GIT" "$@"
SH
chmod +x "$TMP/fakebin-vgit/git"
real_git="$(command -v git)"
t "verify: git hash 실패도 감사 로그에 기록" 0 bash -c \
  "cd '$TMP/v-audit-git' \
   && if PATH='$TMP/fakebin-vgit:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin' \
        REAL_GIT='$real_git' bash '$VF' T-001; then exit 1; fi \
   && grep -q 'FAIL:' log/T-001.verify.log"
mk_vproj "$TMP/v7"; mk_runs "$TMP/v7" run-1 0; mk_done "$TMP/v7" run-1
t "verify: 거부 시 verify.log에 attempt 헤더와 FAIL 사건 기록" 0 bash -c \
  "cd '$TMP/v3' && grep -q '^=== verify T-001 run run-1 attempt ' log/T-001.verify.log \
   && grep -q 'FAIL:' log/T-001.verify.log"

# --- B-001: verify.sh 성공 경로 (게이트 3~5) ---
t "verify: 성공 시 verified.yaml 게시 + 필수 필드" 0 bash -c \
  "cd '$TMP/v7' && bash '$VF' T-001 >/dev/null \
   && [ \"\$(yq -r .version log/T-001.verified.yaml)\" = 1 ] \
   && [ \"\$(yq -r .task log/T-001.verified.yaml)\" = T-001 ] \
   && [ \"\$(yq -r .run_id log/T-001.verified.yaml)\" = run-1 ] \
   && [ \"\$(yq -r .verify_exit_code log/T-001.verified.yaml)\" = 0 ] \
   && [ \"\$(yq -r .worktree_head log/T-001.verified.yaml)\" = shared ] \
   && yq -r .stdout_sha256 log/T-001.verified.yaml | grep -Eq '^[0-9a-f]{64}\$' \
   && [ \"\$(yq -r '.verify_command[0]' log/T-001.verified.yaml)\" = sh ]"
t "verify: done_sha256가 실제 .done 해시와 일치" 0 bash -c \
  "cd '$TMP/v7' && [ \"\$(yq -r .done_sha256 log/T-001.verified.yaml)\" = \"\$(shasum -a 256 log/T-001.done | awk '{print \$1}')\" ]"
t "verify: stdout_sha256가 raw 출력 해시와 일치" 0 bash -c \
  "cd '$TMP/v7' && [ \"\$(yq -r .stdout_sha256 log/T-001.verified.yaml)\" = \"\$(printf 'payload\n' | shasum -a 256 | awk '{print \$1}')\" ]"
t "verify: verify.log에 raw 블록과 publish 사건" 0 bash -c \
  "cd '$TMP/v7' && grep -q -- '--- raw output begin ---' log/T-001.verify.log \
   && grep -q '^payload\$' log/T-001.verify.log \
   && grep -q -- '--- raw output end exit_code=0 ---' log/T-001.verify.log \
   && grep -q 'publish: log/T-001.verified.yaml' log/T-001.verify.log"
t "verify: artifact_git_blob가 git hash-object와 일치" 0 bash -c \
  "cd '$TMP/v7' && [ \"\$(yq -r .artifact_git_blob log/T-001.verified.yaml)\" = \"\$(git hash-object source/out.txt)\" ]"
mk_vproj "$TMP/v8"; mk_runs "$TMP/v8" run-1 0; mk_done "$TMP/v8" run-1
cat > "$TMP/v8/tasks.yaml" <<'YAML'
tasks:
  - id: T-001
    name: example
    role: standard_worker
    grade: T1
    depends_on: []
    worktree: "."
    write_paths: []
    done_when: log/T-001.done
    on_fail: hold_downstream
    status: running
    run_id: run-1
    brief: agents/worker-T-001.md
    verify:
      command: sh
      args: ["-c", "echo broken-output; exit 9"]
YAML
t "verify: 검증 명령 실패 시 verified.yaml 미게시 + 원로그 보존" 1 bash -c \
  "cd '$TMP/v8' && bash '$VF' T-001; rc=\$?; \
   [ ! -e log/T-001.verified.yaml ] && [ ! -e log/T-001.verified.yaml.tmp ] \
   && grep -q '^broken-output\$' log/T-001.verify.log \
   && grep -q -- '--- raw output end exit_code=9 ---' log/T-001.verify.log && exit \$rc"
mk_vproj "$TMP/v-argv"; mk_runs "$TMP/v-argv" run-1 0; mk_done "$TMP/v-argv" run-1
cat > "$TMP/v-argv/tasks.yaml" <<'YAML'
tasks:
  - id: T-001
    name: example
    role: standard_worker
    grade: T1
    depends_on: []
    worktree: "."
    write_paths: []
    done_when: log/T-001.done
    on_fail: hold_downstream
    status: running
    run_id: run-1
    brief: agents/worker-T-001.md
    verify:
      command: sh
      args:
        - -c
        - |-
          true
          exit 7
YAML
t "verify: multiline argv 원소를 보존해 실패를 전파" 0 bash -c \
  "cd '$TMP/v-argv' && if bash '$VF' T-001; then exit 1; else rc=\$?; fi \
   && [ \"\$rc\" = 7 ] \
   && [ ! -e log/T-001.verified.yaml ] \
   && grep -q '^=== verify T-001 run run-1 attempt ' log/T-001.verify.log \
   && grep -q 'FAIL: 검증 명령 실패 exit=7' log/T-001.verify.log \
   && receipt=\$(find log/receipts -type f -name 'T-001-verify-*.yaml') \
   && [ \"\$(yq -r .exit_code \"\$receipt\")\" = 7 ] \
   && raw=\$(yq -r .raw_log \"\$receipt\") && [ -f \"\$raw\" ] \
   && [ \"\$(shasum -a 256 \"\$raw\" | awk '{print \$1}')\" = \"\$(yq -r .stdout_sha256 \"\$receipt\")\" ]"
mk_vproj "$TMP/v9"; mk_runs "$TMP/v9" run-1 0; mk_done "$TMP/v9" run-1
sed -i.bak '/verify:/,$d' "$TMP/v9/tasks.yaml" && rm -f "$TMP/v9/tasks.yaml.bak"
t "verify: verify 필드 없으면 승격 불가" 1 bash -c "cd '$TMP/v9' && bash '$VF' T-001"
mk_vproj "$TMP/v10"; mk_runs "$TMP/v10" run-1 0
(cd "$TMP/v10" && git add -A && git commit -qm w && git worktree add -q wt HEAD)
sed -i.bak 's|worktree: "."|worktree: "wt"|' "$TMP/v10/tasks.yaml" && rm -f "$TMP/v10/tasks.yaml.bak"
printf 'payload\n' > "$TMP/v10/wt/source/out.txt"
printf 'run_id: run-1\nartifact: wt/source/out.txt\nstatus: DONE\n' > "$TMP/v10/log/T-001.done"
t "verify: 격리 worktree의 HEAD·tree 해시 기록" 0 bash -c \
  "cd '$TMP/v10' && bash '$VF' T-001 >/dev/null \
   && [ \"\$(yq -r .worktree_head log/T-001.verified.yaml)\" = \"\$(git -C wt rev-parse HEAD)\" ] \
   && [ \"\$(yq -r .worktree_tree log/T-001.verified.yaml)\" = \"\$(git -C wt rev-parse 'HEAD^{tree}')\" ]"
mk_vproj "$TMP/v-wt-dirty"; mk_runs "$TMP/v-wt-dirty" run-1 0
(cd "$TMP/v-wt-dirty" && git add -A && git commit -qm w && git worktree add -q wt HEAD)
sed -i.bak 's|worktree: "."|worktree: "wt"|' "$TMP/v-wt-dirty/tasks.yaml" \
  && rm -f "$TMP/v-wt-dirty/tasks.yaml.bak"
printf 'uncommitted\n' > "$TMP/v-wt-dirty/wt/source/out.txt"
printf 'run_id: run-1\nartifact: wt/source/out.txt\nstatus: DONE\n' \
  > "$TMP/v-wt-dirty/log/T-001.done"
t "verify: 격리 artifact가 HEAD와 다르면 거부" 1 bash -c \
  "cd '$TMP/v-wt-dirty' && bash '$VF' T-001"
mk_vproj "$TMP/v-wt-missing"; mk_runs "$TMP/v-wt-missing" run-1 0
sed -i.bak 's|worktree: "."|worktree: "missing"|' "$TMP/v-wt-missing/tasks.yaml" \
  && rm -f "$TMP/v-wt-missing/tasks.yaml.bak"
mk_done "$TMP/v-wt-missing" run-1
t "verify: 존재하지 않는 non-dot worktree를 거부" 1 bash -c \
  "cd '$TMP/v-wt-missing' && bash '$VF' T-001"
mk_vproj "$TMP/v-checkpoint"; mk_runs "$TMP/v-checkpoint" run-1 0
mk_done "$TMP/v-checkpoint" run-1
(cd "$TMP/v-checkpoint" && git add tasks.yaml agents/worker-T-001.md source/out.txt \
  log/T-001.runs log/T-001.done && git commit -qm 'worker evidence')
(cd "$TMP/v-checkpoint" && bash "$VF" T-001 >/dev/null \
  && yq -i '.tasks[0].status = "verified"' tasks.yaml)
t "checkpoint: verify 증거와 verified 상태를 함께 커밋" 0 bash -c \
  "cd '$TMP/v-checkpoint' && .harness/bin/checkpoint verified-T-001 >/dev/null \
   && git ls-files --error-unmatch log/T-001.verify.log log/T-001.verified.yaml >/dev/null \
   && git diff --quiet HEAD -- tasks.yaml log/T-001.verify.log log/T-001.verified.yaml \
   && [ -z \"\$(git status --porcelain)\" ]"

# --- B-001: verify.sh --recheck (v7을 쓰는 마지막 그룹 — 마지막에 artifact 변조) ---
t "recheck: 무변조면 통과" 0 bash -c "cd '$TMP/v7' && bash '$VF' T-001 --recheck >/dev/null"
t "recheck: 검증 명령을 재실행하지 않는다" 0 bash -c \
  "cd '$TMP/v7' && c1=\$(grep -c -- '--- raw output begin ---' log/T-001.verify.log); \
   bash '$VF' T-001 --recheck >/dev/null; \
   c2=\$(grep -c -- '--- raw output begin ---' log/T-001.verify.log); [ \"\$c1\" = \"\$c2\" ]"
t "recheck: artifact 변조 시 실패" 1 bash -c \
  "cd '$TMP/v7' && printf 'tampered\n' > source/out.txt && bash '$VF' T-001 --recheck"
t "recheck: verified.yaml 없으면 실패" 1 bash -c "cd '$TMP/v9' && bash '$VF' T-001 --recheck"

# --- B-001: scaffold-check·status 게이트 ---
mk_proj "$TMP/p5"; fill_project "$TMP/p5"
rm "$TMP/p5/.harness/bin/worker-wrap"
t "scaffold-check: worker-wrap 없으면 FAIL" 1 bash -c "cd '$TMP/p5' && bash '$SC'"
mk_proj "$TMP/p6"; fill_project "$TMP/p6"
cat > "$TMP/p6/tasks.yaml" <<'YAML'
tasks:
  - id: A
    name: a
    role: standard_worker
    grade: T1
    depends_on: []
    worktree: "."
    write_paths: []
    done_when: log/A.done
    on_fail: hold_downstream
    status: pending
    run_id: ""
    brief: agents/worker-A.md
    verify:
      command: no-such-cli-zzz
      args: []
YAML
printf '임무: a\n산출물: x\n쓰기 허용 경로: source/\n완료 신호: log/A.done\n' > "$TMP/p6/agents/worker-A.md"
t "scaffold-check: verify.command 실행 파일 없으면 FAIL" 1 bash -c "cd '$TMP/p6' && bash '$SC'"

# --- B-001: migration ---
mkdir "$TMP/legacy-b1"; cp "$ROOT/template/HARNESS.md" "$TMP/legacy-b1/HARNESS.md"
(cd "$TMP/legacy-b1" && git init -q)
"$ROOT/scripts/migrate-b002.sh" "$TMP/legacy-b1" --apply >/dev/null
printf 'old state lib\n' > "$TMP/legacy-b1/.harness/lib/state.sh"
rm -f "$TMP/legacy-b1/.harness/bin/worker-wrap"
t "migrate-b001: dry-run은 아무것도 만들지 않는다" 0 bash -c \
  "'$ROOT/scripts/migrate-b001.sh' '$TMP/legacy-b1' >/dev/null \
   && [ ! -e '$TMP/legacy-b1/.harness/bin/worker-wrap' ] \
   && [ \"\$(cat '$TMP/legacy-b1/.harness/lib/state.sh')\" = 'old state lib' ]"
t "migrate-b001: dry-run이 REPLACE를 표시" 0 bash -c \
  "'$ROOT/scripts/migrate-b001.sh' '$TMP/legacy-b1' | grep -q 'REPLACE .harness/lib/state.sh'"
t "migrate-b001: apply가 wrap 추가 + state.sh 교체" 0 bash -c \
  "'$ROOT/scripts/migrate-b001.sh' '$TMP/legacy-b1' --apply >/dev/null \
   && [ -x '$TMP/legacy-b1/.harness/bin/worker-wrap' ] \
   && cmp -s '$ROOT/template/.harness/lib/state.sh' '$TMP/legacy-b1/.harness/lib/state.sh'"
printf 'custom wrap\n' > "$TMP/legacy-b1/.harness/bin/worker-wrap"
t "migrate-b001: ADD 대상 충돌이면 거부" 1 bash -c \
  "'$ROOT/scripts/migrate-b001.sh' '$TMP/legacy-b1' --apply >/dev/null 2>&1"

mk_proj "$TMP/legacy-b1-complete"; fill_project "$TMP/legacy-b1-complete"
printf 'old state lib\n' > "$TMP/legacy-b1-complete/.harness/lib/state.sh"
rm -f "$TMP/legacy-b1-complete/.harness/bin/worker-wrap"
cat > "$TMP/legacy-b1-complete/tasks.yaml" <<'YAML'
tasks:
  - id: T-001
    status: verified
    run_id: legacy-run
YAML
printf 'run_id: legacy-run\nstatus: VERIFIED\n' \
  > "$TMP/legacy-b1-complete/log/T-001.done"
t "migrate-b001: 완료 상태는 변경 전에 fail closed" 0 bash -c \
  "! '$ROOT/scripts/migrate-b001.sh' '$TMP/legacy-b1-complete' --apply >/dev/null 2>&1 \
   && [ ! -e '$TMP/legacy-b1-complete/.harness/bin/worker-wrap' ] \
   && [ \"\$(cat '$TMP/legacy-b1-complete/.harness/lib/state.sh')\" = 'old state lib' ] \
   && grep -q '^status: VERIFIED$' '$TMP/legacy-b1-complete/log/T-001.done'"

mkdir "$TMP/migrate-git-root"
(cd "$TMP/migrate-git-root" && git init -q && git config user.name harness-test \
  && git config user.email harness-test@example.invalid \
  && printf 'root\n' > tracked.txt && git add tracked.txt && git commit -qm init)
git -C "$TMP/migrate-git-root" worktree add -q -b migrate-linked "$TMP/legacy-b1-linked"
t "migrate-b001: linked worktree도 Git 프로젝트로 인정" 0 bash -c \
  "[ -f '$TMP/legacy-b1-linked/.git' ] \
   && '$ROOT/scripts/migrate-b001.sh' '$TMP/legacy-b1-linked' >/dev/null"

ti "docs: B-001 history는 완료와 저지·리뷰 결과를 기록" 0 bash -c \
  "grep -Fq '저지 축 2·3·6 PASS' '$ROOT/docs/history/B-001.md' \
   && grep -Eq '^\*\*상태:\*\* 완료' '$ROOT/docs/history/B-001.md' \
   && grep -Fq '재리뷰 APPROVE' '$ROOT/docs/history/B-001.md'"
t "docs: tasks 템플릿은 불변 done과 별도 verified 계약을 설명" 0 bash -c \
  "grep -Fq '.done은 DONE이고 .verified.yaml과 tasks status=verified 계약을 모두 통과해야 기동' \
    '$ROOT/template/tasks.yaml'"
t "docs: 실행 계약 기본값과 T0~T3가 정본 문서에 동기화" 0 bash -c \
  "grep -Fq '워커 1개' '$ROOT/doctrine/ORCHESTRATION.md' \
   && grep -Fq '동시 워커 상한 3개' '$ROOT/doctrine/ORCHESTRATION.md' \
   && grep -Fq '재귀 위임 깊이 0' '$ROOT/doctrine/ORCHESTRATION.md' \
   && grep -Fq 'T0~T3' '$ROOT/doctrine/ORCHESTRATION.md' \
   && ! grep -Fq '2~4개' '$ROOT/doctrine/ORCHESTRATION.md'"
t "docs: harness skill은 dispatch 전 v3 계약 검증을 요구" 0 bash -c \
  "grep -Fq 'contract_version: 3' '$ROOT/skills/harness/SKILL.md' \
   && grep -Fq 'dispatch 전에' '$ROOT/skills/harness/SKILL.md' \
   && grep -Fq 'Lean Gate' '$ROOT/skills/harness/SKILL.md'"
t "docs: HARNESS 템플릿은 v3 실행 정책과 Lean Gate를 포함" 0 bash -c \
  "grep -Fq '## 실행 정책' '$ROOT/template/HARNESS.md' \
   && grep -Fq 'contract v3' '$ROOT/template/HARNESS.md' \
   && grep -Fq 'Lean Gate' '$ROOT/template/HARNESS.md' \
   && grep -Fq '1 / 3 / 0' '$ROOT/template/HARNESS.md'"
t "docs: v3 Lean Gate가 현재 정본에 동기화" 0 bash -c \
  "grep -Fq 'contract_version: 3' '$ROOT/skills/harness/SKILL.md' \
   && grep -Fq 'Lean Gate' '$ROOT/doctrine/OPERATING.md' \
   && grep -Fq 'Lean Gate' '$ROOT/doctrine/ORCHESTRATION.md'"
ti "docs: v3 Lean Gate가 설계 스펙에 동기화" 0 bash -c \
  "grep -Fq 'contract-native Lean Gate' '$ROOT/docs/superpowers/specs/2026-07-12-agent-harness-design.md'"
mkdir -p "$TMP/install-home"
t "install: Ponytail 설치를 권장하거나 설정하지 않음" 0 bash -c \
  "out=\$(HOME='$TMP/install-home' bash '$ROOT/install.sh' 2>&1); \
   ! printf '%s' \"\$out\" | grep -Eqi 'plugin install ponytail|plugin add ponytail|ponytail\\(RECOMMENDED\\)' \
   && [ ! -e '$TMP/install-home/.claude/plugins/ponytail' ] \
   && [ ! -e '$TMP/install-home/.codex/plugins/ponytail' ]"
t "docs: scaffold-check는 실행 정책 섹션을 요구" 0 bash -c \
  "grep -Fq '\"## 실행 정책\"' '$ROOT/scripts/scaffold-check.sh'"
ti "docs: B-001 history는 리뷰 수정 체크포인트와 최종 배치 표식을 기록" 0 bash -c \
  "grep -Fq '## 리뷰 결함 수정 체크포인트' '$ROOT/docs/history/B-001.md' \
   && grep -Fxq 'FIX-BATCH: DONE tests=140' '$ROOT/docs/history/B-001.md'"
# shellcheck disable=SC2016 # $1은 자식 bash의 위치 인자다.
ti "docs: history router와 작업별 기록이 모두 존재" 0 bash -c \
  'root="$1"; for f in INDEX foundation B-001 B-002 B-003 B-004 B-006 status-tui decisions; do test -s "$root/docs/history/$f.md" || exit 1; done' _ "$ROOT"
# shellcheck disable=SC2016 # $1은 자식 bash의 위치 인자다.
ti "docs: 현재 상태 진입점은 각각 200줄 이하" 0 bash -c \
  '[ "$(wc -l < "$1/HANDOFF.md")" -le 200 ] && [ "$(wc -l < "$1/docs/BACKLOG.md")" -le 200 ]' _ "$ROOT"
# shellcheck disable=SC2016 # $1은 자식 bash의 위치 인자다.
ti "docs: 현재 상태의 history 링크는 모두 존재" 0 bash -c \
  'root="$1"; paths="$(rg -o --no-filename "docs/history/[A-Za-z0-9._/-]+\\.md" "$root/HANDOFF.md" "$root/docs/BACKLOG.md" | sort -u)"; [ -n "$paths" ] || exit 1; printf "%s\n" "$paths" | while IFS= read -r p; do test -f "$root/$p" || exit 1; done' _ "$ROOT"
ti "docs: 완료된 B-006을 미착수 현재 게이트로 표시하지 않음" 0 bash -c \
  "! rg -q 'B-006.*(미착수|작성본 최종 승인|계획 승인 대기)' '$ROOT/HANDOFF.md' '$ROOT/docs/BACKLOG.md'"
# shellcheck disable=SC2016 # $1은 자식 bash의 위치 인자다.
ti "docs: BACKLOG approved queue와 ROADMAP 항목이 기계 대조로 일치" 0 bash -c '
  root="$1"
  nums="$(grep -oE "^[0-9]+\." "$root/docs/BACKLOG.md" | tr -d . | sort -un)"
  [ -n "$nums" ] || { echo "no numbered backlog items"; exit 1; }
  for n in $nums; do
    yq -e ".items[] | select(.id == \"Q$n\")" "$root/ROADMAP.yaml" >/dev/null 2>&1 \
      || { echo "ROADMAP missing Q$n"; exit 1; }
  done
  for id in $(yq -r ".items[].id" "$root/ROADMAP.yaml" | grep -E "^Q[0-9]+$"); do
    printf "%s\n" "$nums" | grep -qx "${id#Q}" \
      || { echo "ROADMAP $id has no BACKLOG entry"; exit 1; }
  done' _ "$ROOT"
fi

# --- B-006 context loading Task 1: contract RED/GREEN block ---
mk_context_contract() { # $1=project root
  local p="$1"
  mkdir -p "$p/agents" "$p/context" "$p/docs"
  printf '임무: context\n완료 신호: log/C-001.done\n' > "$p/agents/worker-C-001.md"
  printf 'HOT_CONTENT\n' > "$p/context/hot-a.md"
  printf 'HOT_SECOND\n' > "$p/context/hot-b.md"
  printf 'COLD_SENTINEL_MUST_NEVER_BE_PACKED\n' > "$p/docs/cold.md"
  cat > "$p/tasks.yaml" <<'YAML'
contract_version: 3
context_contract_version: 1
execution_policy:
  default_workers: 1
  max_concurrent_workers: 3
  max_delegation_depth: 0
tasks:
  - id: C-001
    name: context worker
    lean_gate: {decision: minimal, evidence: context pack needs a minimal implementation}
    execution: worker
    role: standard_worker
    grade: T1
    effort: medium
    ceremony: {design_approved: false, independent_review: false, full_regression: false, approval_gates: []}
    budget: {concurrent_workers: 1, total_workers: 1, model_turns_per_worker: 1, model_runs: 1, edit_iterations: 1, related_test_runs: 1, full_test_runs: 0, max_input_tokens: 1, max_output_tokens: 1, changed_files: 1, changed_lines: 1, dependencies_added: 0}
    brief: agents/worker-C-001.md
    context:
      hot_paths: [context/hot-a.md, context/hot-b.md]
      cold_paths: [docs/cold.md]
      skills: [superpowers:test-driven-development]
YAML
}

mk_context_contract "$TMP/context-contract"
t "context contract: v1 worker hot/cold/skills sequences는 PASS" 0 bash -c \
  ". '$ROOT/scripts/lib.sh'; validate_context_contract '$TMP/context-contract/tasks.yaml' '$TMP/context-contract'"
t "context contract: 실행 계약은 v1 context를 함께 검사" 0 bash -c \
  ". '$ROOT/scripts/lib.sh'; validate_execution_contract '$TMP/context-contract/tasks.yaml' '$TMP/context-contract'"
cp "$TMP/context-contract/tasks.yaml" "$TMP/context-unsupported-version.yaml"
yq -i '.context_contract_version = 2' "$TMP/context-unsupported-version.yaml"
t "context contract: 지원하지 않는 버전은 FAIL" 1 bash -c \
  ". '$ROOT/scripts/lib.sh'; validate_context_contract '$TMP/context-unsupported-version.yaml' '$TMP/context-contract'"
cp "$TMP/context-contract/tasks.yaml" "$TMP/context-non-sequence.yaml"
yq -i '.tasks[0].context.hot_paths = "context/hot-a.md"' "$TMP/context-non-sequence.yaml"
t "context contract: 목록 필드는 sequence가 아니면 FAIL" 1 bash -c \
  ". '$ROOT/scripts/lib.sh'; validate_context_contract '$TMP/context-non-sequence.yaml' '$TMP/context-contract'"
for kind in missing absolute parent duplicate overlap escape; do
  p="$TMP/context-$kind"; rm -rf "$p"; cp -R "$TMP/context-contract" "$p"
  case "$kind" in
    missing) yq -i '.tasks[0].context.hot_paths = ["context/missing.md"]' "$p/tasks.yaml" ;;
    absolute) yq -i '.tasks[0].context.hot_paths = ["/etc/passwd"]' "$p/tasks.yaml" ;;
    parent) yq -i '.tasks[0].context.hot_paths = ["context/../hot-a.md"]' "$p/tasks.yaml" ;;
    duplicate) yq -i '.tasks[0].context.hot_paths = ["context/hot-a.md", "context/hot-a.md"]' "$p/tasks.yaml" ;;
    overlap) yq -i '.tasks[0].context.cold_paths = ["context/hot-a.md"]' "$p/tasks.yaml" ;;
    escape) printf 'outside\n' > "$TMP/outside.md"; ln -s "$TMP/outside.md" "$p/context/escape.md"; yq -i '.tasks[0].context.hot_paths = ["context/escape.md"]' "$p/tasks.yaml" ;;
  esac
  t "context contract: $kind path는 FAIL" 1 bash -c \
    ". '$ROOT/scripts/lib.sh'; validate_context_contract '$p/tasks.yaml' '$p'"
done
cp "$TMP/context-contract/tasks.yaml" "$TMP/context-too-many-hot.yaml"
yq -i '.tasks[0].context.hot_paths = ["context/hot-a.md", "context/hot-b.md", "context/hot-a.md", "context/hot-b.md", "context/hot-a.md", "context/hot-b.md"]' "$TMP/context-too-many-hot.yaml"
t "context contract: hot 파일 여섯 개는 FAIL" 1 bash -c \
  ". '$ROOT/scripts/lib.sh'; validate_context_contract '$TMP/context-too-many-hot.yaml' '$TMP/context-contract'"
cp "$TMP/context-contract/tasks.yaml" "$TMP/context-too-many-skills.yaml"
yq -i '.tasks[0].context.skills = ["a", "b", "c", "d", "e", "f"]' "$TMP/context-too-many-skills.yaml"
t "context contract: skill 여섯 개는 FAIL" 1 bash -c \
  ". '$ROOT/scripts/lib.sh'; validate_context_contract '$TMP/context-too-many-skills.yaml' '$TMP/context-contract'"
for skill_case in empty duplicate; do
  cp "$TMP/context-contract/tasks.yaml" "$TMP/context-skill-$skill_case.yaml"
  if [ "$skill_case" = empty ]; then
    yq -i '.tasks[0].context.skills = [""]' "$TMP/context-skill-$skill_case.yaml"
  else
    yq -i '.tasks[0].context.skills = ["safe", "safe"]' "$TMP/context-skill-$skill_case.yaml"
  fi
  t "context contract: $skill_case skill은 FAIL" 1 bash -c \
    ". '$ROOT/scripts/lib.sh'; validate_context_contract '$TMP/context-skill-$skill_case.yaml' '$TMP/context-contract'"
done
cp "$TMP/context-contract/tasks.yaml" "$TMP/context-too-many-lines.yaml"
yes line | head -201 > "$TMP/context-contract/context/over-limit.md"
yq -i '.tasks[0].context.hot_paths = ["context/over-limit.md"]' "$TMP/context-too-many-lines.yaml"
t "context contract: brief와 hot이 200줄을 넘으면 FAIL" 1 bash -c \
  ". '$ROOT/scripts/lib.sh'; validate_context_contract '$TMP/context-too-many-lines.yaml' '$TMP/context-contract'"
cp -R "$TMP/context-contract" "$TMP/context-logical-200"
printf 'brief without final newline' > "$TMP/context-logical-200/agents/worker-C-001.md"
yes line | head -198 > "$TMP/context-logical-200/context/hot-a.md"
printf 'last hot line without final newline' > "$TMP/context-logical-200/context/hot-b.md"
t "context contract: 여러 파일의 마지막 비개행 줄까지 합쳐 200줄은 PASS" 0 bash -c \
  ". '$ROOT/scripts/lib.sh'; validate_context_contract '$TMP/context-logical-200/tasks.yaml' '$TMP/context-logical-200'"
cp -R "$TMP/context-logical-200" "$TMP/context-logical-201"
printf 'last hot line with newline\none more without final newline' > "$TMP/context-logical-201/context/hot-b.md"
t "context contract: 여러 파일의 마지막 비개행 줄까지 합쳐 201줄은 FAIL" 1 bash -c \
  ". '$ROOT/scripts/lib.sh'; validate_context_contract '$TMP/context-logical-201/tasks.yaml' '$TMP/context-logical-201'"
cp "$TMP/context-contract/tasks.yaml" "$TMP/context-too-many-bytes.yaml"
head -c 32769 /dev/zero | tr '\\0' x > "$TMP/context-contract/context/over-limit-bytes.md"
yq -i '.tasks[0].context.hot_paths = ["context/over-limit-bytes.md"]' "$TMP/context-too-many-bytes.yaml"
t "context contract: brief와 hot이 32KiB를 넘으면 FAIL" 1 bash -c \
  ". '$ROOT/scripts/lib.sh'; validate_context_contract '$TMP/context-too-many-bytes.yaml' '$TMP/context-contract'"
printf 'tasks: []\n' > "$TMP/context-legacy.yaml"
t "context contract: 버전 없는 입력은 legacy 경고와 함께 PASS" 0 bash -c \
  ". '$ROOT/scripts/lib.sh'; validate_context_contract '$TMP/context-legacy.yaml' '$TMP/context-contract' 2>&1 | grep -Fq 'legacy context contract'"
CP="$ROOT/scripts/context-pack.sh"
t "context pack: brief·hot 순서와 cold·skill 색인을 결정론적으로 렌더" 0 bash -c \
  "cd '$TMP/context-contract' && '$CP' C-001 > '$TMP/context-pack-one.out' \\
   && '$CP' C-001 > '$TMP/context-pack-two.out' \\
   && cmp -s '$TMP/context-pack-one.out' '$TMP/context-pack-two.out' \\
   && head -1 '$TMP/context-pack-one.out' | grep -Fx '[HARNESS_CONTEXT_V1]' \\
   && grep -Fq -- '--- BRIEF: agents/worker-C-001.md ---' '$TMP/context-pack-one.out' \\
   && grep -Fq -- '--- HOT: context/hot-a.md ---' '$TMP/context-pack-one.out' \\
   && grep -Fq -- 'HOT_CONTENT' '$TMP/context-pack-one.out' \\
   && grep -Fq -- '--- HOT: context/hot-b.md ---' '$TMP/context-pack-one.out' \\
   && grep -Fq -- 'HOT_SECOND' '$TMP/context-pack-one.out' \\
   && grep -Fq -- '--- COLD INDEX ---' '$TMP/context-pack-one.out' \\
   && grep -Fxq 'docs/cold.md' '$TMP/context-pack-one.out' \\
   && ! grep -Fq 'COLD_SENTINEL_MUST_NEVER_BE_PACKED' '$TMP/context-pack-one.out' \\
   && grep -Fq -- '--- SKILL INDEX ---' '$TMP/context-pack-one.out' \\
   && grep -Fxq 'superpowers:test-driven-development' '$TMP/context-pack-one.out'"
t "context pack: 알 수 없는 task와 잘못된 계약은 partial output 없이 FAIL" 0 bash -c \
  "cd '$TMP/context-contract' && ! '$CP' UNKNOWN > '$TMP/context-pack-unknown.out' 2>/dev/null \\
   && [ ! -s '$TMP/context-pack-unknown.out' ] \\
   && cp tasks.yaml '$TMP/context-pack-invalid.yaml' \\
   && yq -i '.tasks[0].context.hot_paths = [\"context/missing.md\"]' '$TMP/context-pack-invalid.yaml' \\
   && mv tasks.yaml tasks.yaml.valid && mv '$TMP/context-pack-invalid.yaml' tasks.yaml \\
   && ! '$CP' C-001 > '$TMP/context-pack-invalid.out' 2>/dev/null \\
   && [ ! -s '$TMP/context-pack-invalid.out' ] \\
   && mv tasks.yaml.valid tasks.yaml"
t "context pack: /bin/bash에서도 동작" 0 bash -c \
  "cd '$TMP/context-contract' && /bin/bash '$CP' C-001 > '$TMP/context-pack-bash32.out' \\
   && cmp -s '$TMP/context-pack-one.out' '$TMP/context-pack-bash32.out'"

# --- B-006 context loading Task 2: dispatch RED/GREEN block ---
DP="$ROOT/scripts/dispatch.sh"
mk_context_dispatch_project() { # $1=project root $2=v1|legacy
  local p="$1" mode="$2" f
  rm -rf "$p"; cp -R "$ROOT/template" "$p"
  for f in HARNESS.md STATUS.md log/HANDOFF.md; do
    sed -i.bak 's/{{[^}]*}}/기입됨/g' "$p/$f" && rm -f "$p/$f.bak"
  done
  mkdir -p "$p/agents" "$p/context" "$p/docs"
  printf '임무: dispatch context\n완료 신호: log/C-001.done\n' > "$p/agents/worker-C-001.md"
  printf 'DISPATCH_HOT_CONTENT\n' > "$p/context/hot.md"
  printf 'DISPATCH_COLD_SENTINEL\n' > "$p/docs/cold.md"
  printf 'DISPATCH_SKILL_CONTENT_SENTINEL\n' > "$p/docs/selected-skill.md"
  cat > "$p/tasks.yaml" <<'YAML'
contract_version: 3
execution_policy:
  default_workers: 1
  max_concurrent_workers: 3
  max_delegation_depth: 0
tasks:
  - id: C-001
    name: dispatch context worker
    lean_gate: {decision: minimal, evidence: keep the existing Lean Gate instruction}
    execution: worker
    role: standard_worker
    grade: T1
    effort: medium
    ceremony: {design_approved: false, independent_review: false, full_regression: false, approval_gates: []}
    budget: {concurrent_workers: 1, total_workers: 1, model_turns_per_worker: 1, model_runs: 1, edit_iterations: 1, related_test_runs: 1, full_test_runs: 0, max_input_tokens: 1, max_output_tokens: 1, changed_files: 1, changed_lines: 1, dependencies_added: 0}
    depends_on: []
    worktree: "."
    write_paths: []
    done_when: log/C-001.done
    on_fail: hold_downstream
    status: pending
    run_id: ""
    brief: agents/worker-C-001.md
YAML
  if [ "$mode" = v1 ]; then
    cat >> "$p/tasks.yaml" <<'YAML'
context_contract_version: 1
YAML
    yq -i '.tasks[0].context = {"hot_paths": ["context/hot.md"], "cold_paths": ["docs/cold.md"], "skills": ["superpowers:test-driven-development"]}' "$p/tasks.yaml"
  fi
  : > "$p/log/scaffold-check.pass"
  (cd "$p" && git init -q && git config user.name harness-test && git config user.email harness-test@example.invalid && git add -A && git commit -qm fixture)
}

mkdir -p "$TMP/context-dispatch-bin"
cat > "$TMP/context-dispatch-bin/cmux" <<'SH'
#!/bin/sh
[ -z "${CMUX_CAPTURE:-}" ] || printf '%s\n' "$*" >> "$CMUX_CAPTURE"
case "$1" in
  ping|select-workspace|send|send-key) exit 0 ;;
  identify) printf '{"caller":{"workspace_ref":"workspace:1","surface_ref":"surface:2"}}\n' ;;
  new-split) printf 'surface:3\n' ;;
  new-workspace) printf 'workspace:1\n' ;;
  *) exit 1 ;;
esac
SH
chmod +x "$TMP/context-dispatch-bin/cmux"
cat > "$TMP/context-dispatch-models.yaml" <<'YAML'
roles:
  standard_worker:
    effort: medium
    candidates:
      - name: fake-cli
        command: sh
        args: ["-c"]
YAML

mk_context_dispatch_project "$TMP/context-dispatch-v1" v1
t "context dispatch: v1 pack·증거 hash·기존 runtime과 Lean Gate를 함께 기록" 0 bash -c \
  "cd '$TMP/context-dispatch-v1' \\
   && PATH='$TMP/context-dispatch-bin:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin' \\
      CMUX_CAPTURE='$TMP/context-dispatch-v1.cmux' HARNESS_MODELS='$TMP/context-dispatch-models.yaml' bash '$DP' C-001 >/dev/null \\
   && '$CP' C-001 > '$TMP/context-dispatch-v1.pack' \\
   && bytes=\$(wc -c < '$TMP/context-dispatch-v1.pack' | tr -d ' ') \\
   && head -c \"\$bytes\" log/C-001.prompt | cmp -s '$TMP/context-dispatch-v1.pack' - \\
   && grep -Fq '[HARNESS_CONTEXT_V1]' log/C-001.prompt \\
   && grep -Fq 'DISPATCH_HOT_CONTENT' log/C-001.prompt \\
   && grep -Fq 'docs/cold.md' log/C-001.prompt \\
   && grep -Fq 'superpowers:test-driven-development' log/C-001.prompt \\
   && ! grep -Fq 'DISPATCH_COLD_SENTINEL' log/C-001.prompt \\
   && ! grep -Fq 'DISPATCH_SKILL_CONTENT_SENTINEL' log/C-001.prompt \\
   && grep -Fq '[실행 ID:' log/C-001.prompt \\
   && grep -Fq 'Lean Gate: minimal (keep the existing Lean Gate instruction)' log/C-001.prompt \\
   && sha=\$(shasum -a 256 '$TMP/context-dispatch-v1.pack' | awk '{print \$1}') \\
   && grep -Fq \"context: v1 context_sha256: \$sha hot_count: 1 cold_count: 1 skill_count: 1\" log/C-001.runs \
   && grep -Fq 'mux: cmux ws: workspace:1/surface:3 (right)' log/C-001.runs \
   && grep -Fxq 'new-split right --workspace workspace:1' '$TMP/context-dispatch-v1.cmux'"

for legacy_execution_case in parent symlink unsupported-version oversize; do
  p="$TMP/context-dispatch-legacy-execution-$legacy_execution_case"
  mk_context_dispatch_project "$p" v1
  yq -i 'del(.contract_version)' "$p/tasks.yaml"
  case "$legacy_execution_case" in
    parent) yq -i '.tasks[0].context.hot_paths = ["context/../context/hot.md"]' "$p/tasks.yaml" ;;
    symlink) printf 'outside\n' > "$TMP/context-dispatch-outside.md"; ln -s "$TMP/context-dispatch-outside.md" "$p/context/escape.md"; yq -i '.tasks[0].context.hot_paths = ["context/escape.md"]' "$p/tasks.yaml" ;;
    unsupported-version) yq -i '.context_contract_version = 2' "$p/tasks.yaml" ;;
    oversize) yes oversized | head -201 > "$p/context/over-limit.md"; yq -i '.tasks[0].context.hot_paths = ["context/over-limit.md"]' "$p/tasks.yaml" ;;
  esac
  t "context dispatch: legacy execution + v1 $legacy_execution_case 는 모든 부작용 전에 거부" 0 bash -c \
    "cd '$p' && ! PATH='$TMP/context-dispatch-bin:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin' \\
        CMUX_CAPTURE='$p.cmux' HARNESS_MODELS='$TMP/context-dispatch-models.yaml' bash '$DP' C-001 >/dev/null 2>&1 \\
     && [ ! -e log/C-001.prompt ] && [ ! -e log/C-001.runs ] && [ ! -e '$p.cmux' ]"
done

mk_context_dispatch_project "$TMP/context-dispatch-invalid" v1
yq -i '.tasks[0].context.hot_paths = ["context/missing.md"]' "$TMP/context-dispatch-invalid/tasks.yaml"
t "context dispatch: 잘못된 context는 prompt·runs·cmux 전에 거부" 0 bash -c \
  "cd '$TMP/context-dispatch-invalid' && ! PATH='$TMP/context-dispatch-bin:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin' \\
      CMUX_CAPTURE='$TMP/context-dispatch-invalid.cmux' HARNESS_MODELS='$TMP/context-dispatch-models.yaml' bash '$DP' C-001 >/dev/null 2>&1 \\
   && [ ! -e log/C-001.prompt ] && [ ! -e log/C-001.runs ] && [ ! -e '$TMP/context-dispatch-invalid.cmux' ]"

mk_context_dispatch_project "$TMP/context-dispatch-layout-invalid" v1
printf 'HOT_SECRET_SENTINEL\n' > "$TMP/context-dispatch-layout-invalid/context/hot.md"
mkdir -p "$TMP/context-dispatch-layout-tmp"
t "context dispatch: layout 거부도 secret context 임시 파일·barrier·기록을 남기지 않는다" 0 bash -c \
  "cd '$TMP/context-dispatch-layout-invalid' && set +e; \\
     PATH='$TMP/context-dispatch-bin:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin' \\
     TMPDIR='$TMP/context-dispatch-layout-tmp' CMUX_CAPTURE='$TMP/context-dispatch-layout-invalid.cmux' \\
     HARNESS_MODELS='$TMP/context-dispatch-models.yaml' HARNESS_LAYOUT=tiles bash '$DP' C-001 >/dev/null 2>&1; \\
     rc=\$?; set -e; [ \"\$rc\" = 1 ] \\
     && ! find '$TMP/context-dispatch-layout-tmp' -maxdepth 1 -name 'agent-harness-dispatch-context.*' | grep -q . \\
     && ! grep -R -Fq 'HOT_SECRET_SENTINEL' '$TMP/context-dispatch-layout-tmp' \\
     && [ ! -e log/C-001.prompt ] && [ ! -e log/C-001.runs ] \\
     && [ ! -e '$TMP/context-dispatch-layout-invalid.cmux' ] \\
     && ! find log -maxdepth 1 -name '.dispatch-start.*' | grep -q ."

mk_context_dispatch_project "$TMP/context-dispatch-oversized" v1
yes oversized | head -201 > "$TMP/context-dispatch-oversized/context/over-limit.md"
yq -i '.tasks[0].context.hot_paths = ["context/over-limit.md"]' "$TMP/context-dispatch-oversized/tasks.yaml"
t "context dispatch: 과대한 context는 prompt·runs·cmux 전에 거부" 0 bash -c \
  "cd '$TMP/context-dispatch-oversized' && ! PATH='$TMP/context-dispatch-bin:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin' \\
      CMUX_CAPTURE='$TMP/context-dispatch-oversized.cmux' HARNESS_MODELS='$TMP/context-dispatch-models.yaml' bash '$DP' C-001 >/dev/null 2>&1 \\
   && [ ! -e log/C-001.prompt ] && [ ! -e log/C-001.runs ] && [ ! -e '$TMP/context-dispatch-oversized.cmux' ]"

mk_context_dispatch_project "$TMP/context-dispatch-legacy" legacy
t "context dispatch: legacy는 brief-only와 hash 없는 legacy 증거를 유지" 0 bash -c \
  "cd '$TMP/context-dispatch-legacy' \\
   && PATH='$TMP/context-dispatch-bin:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin' \\
      HARNESS_MODELS='$TMP/context-dispatch-models.yaml' bash '$DP' C-001 >/dev/null \\
   && grep -Fq '임무: dispatch context' log/C-001.prompt \\
   && ! grep -Fq '[HARNESS_CONTEXT_V1]' log/C-001.prompt \\
   && grep -Fq 'context: legacy' log/C-001.runs \\
   && ! grep -Fq 'context_sha256:' log/C-001.runs"
# --- B-006 context loading Task 3: template/document synchronization RED/GREEN block ---
t "context docs: tasks template은 v1과 brief 중복 없는 hot/cold/skills 예시를 제공" 0 bash -c \
  "yq -e '.context_contract_version == 1' '$ROOT/template/tasks.yaml' >/dev/null \
   && grep -Fq '#   context:' '$ROOT/template/tasks.yaml' \
   && grep -Fq '#     hot_paths: [\"context/interfaces.md\"]' '$ROOT/template/tasks.yaml' \
   && grep -Fq '#     cold_paths: [\"docs/architecture.md\"]' '$ROOT/template/tasks.yaml' \
   && grep -Fq '#     skills: [\"superpowers:test-driven-development\"]' '$ROOT/template/tasks.yaml' \
   && ! grep -Eq '# +hot_paths:.*agents/worker-' '$ROOT/template/tasks.yaml'"

ti "context docs: root cold-start 전문 읽기와 표시된 worker 예외를 함께 보존" 0 bash -c \
  "grep -Fq 'HANDOFF.md' '$ROOT/AGENTS.md' \
   && grep -Fq 'docs/superpowers/specs/2026-07-12-agent-harness-design.md' '$ROOT/AGENTS.md' \
   && grep -Fq '오케스트레이터와 감사자는 위 cold-start 전문 읽기 규칙을 그대로 따른다' '$ROOT/AGENTS.md' \
   && grep -Fq '[HARNESS_CONTEXT_V1]' '$ROOT/AGENTS.md' \
   && grep -Fq '워커만' '$ROOT/AGENTS.md'"

context_docs_share_contract() {
  local f content files
  files='template/HARNESS.md doctrine/ORCHESTRATION.md skills/harness/SKILL.md'
  [ "$HAS_INTERNAL_DOCS" = 1 ] \
    && files="$files docs/superpowers/specs/2026-07-12-agent-harness-design.md"
  for f in $files; do
    content="$(tr '\n' ' ' < "$ROOT/$f" | tr -s '[:space:]' ' ')"
    case "$content" in *'hot은 지금 책상 위에 펼쳐 둔 자료'*) ;; *) return 1 ;; esac
    case "$content" in *'cold는 서랍에 둔 참고자료'*) ;; *) return 1 ;; esac
    case "$content" in *'선택 스킬은 지금 이름만 정하고 필요할 때 여는 설명서'*) ;; *) return 1 ;; esac
    case "$content" in *'브리프는 자동으로 첫 hot 입력'*) ;; *) return 1 ;; esac
    case "$content" in *'hot_paths 최대 5개'*) ;; *) return 1 ;; esac
    case "$content" in *'skills 최대 5개'*) ;; *) return 1 ;; esac
    case "$content" in *'100줄 목표'*) ;; *) return 1 ;; esac
    case "$content" in *'200줄'*) ;; *) return 1 ;; esac
    case "$content" in *'32 KiB'*) ;; *) return 1 ;; esac
    case "$content" in *'전체 스킬 카탈로그를 숨겼다는 뜻은 아니다'*) ;; *) return 1 ;; esac
  done
}
t "context docs: HARNESS/doctrine/skill/spec의 의미와 한도가 일치" 0 \
  context_docs_share_contract

mk_context_template_scaffold() { # $1=project root
  local p="$1" f
  rm -rf "$p"; cp -R "$ROOT/template" "$p"
  for f in HARNESS.md STATUS.md log/HANDOFF.md; do
    sed -i.bak 's/{{[^}]*}}/기입됨/g' "$p/$f" && rm -f "$p/$f.bak"
  done
  git -C "$p" init -q
  git -C "$p" config user.name harness-test
  git -C "$p" config user.email harness-test@example.invalid
  git -C "$p" add -A
  git -C "$p" commit -qm fixture
}
SC="$ROOT/scripts/scaffold-check.sh"
mk_context_template_scaffold "$TMP/context-template-valid"
t "context scaffold: 갱신한 template의 v1 context 계약은 PASS" 0 bash -c \
  "cd '$TMP/context-template-valid' && bash '$SC' >/dev/null"
mk_context_template_scaffold "$TMP/context-template-invalid"
yq -i '.context_contract_version = 2' "$TMP/context-template-invalid/tasks.yaml"
t "context scaffold: 잘못된 생성 context 계약은 FAIL" 1 bash -c \
  "cd '$TMP/context-template-invalid' && bash '$SC' >/dev/null 2>&1"

if [ "${B006_CONTEXT_LOADING_FOCUSED:-0}" = 1 ]; then
  echo; echo "결과: PASS=$pass FAIL=$fail"
  exit "$fail"
fi

# --- B-006 Task 1: v2 execution contract ---
mk_v2_contract() { # $1=YAML path
  cat > "$1" <<'YAML'
contract_version: 2
execution_policy:
  default_workers: 1
  max_concurrent_workers: 3
  max_delegation_depth: 0
tasks:
  - id: T0
    name: deterministic
    execution: deterministic
    role: none
    grade: T0
    effort: none
    ceremony: {design_approved: false, independent_review: false, full_regression: false, approval_gates: []}
    budget: {concurrent_workers: 0, total_workers: 0, model_turns_per_worker: 0, model_runs: 0, edit_iterations: 1, related_test_runs: 1, full_test_runs: 0, max_input_tokens: 0, max_output_tokens: 0, changed_files: 1, changed_lines: 1, dependencies_added: 0}
  - id: T1
    name: standard
    execution: worker
    role: standard_worker
    grade: T1
    effort: medium
    ceremony: {design_approved: false, independent_review: false, full_regression: false, approval_gates: []}
    budget: {concurrent_workers: 1, total_workers: 1, model_turns_per_worker: 1, model_runs: 1, edit_iterations: 1, related_test_runs: 1, full_test_runs: 0, max_input_tokens: 1, max_output_tokens: 1, changed_files: 1, changed_lines: 1, dependencies_added: 0}
  - id: T2
    name: frontier
    execution: worker
    role: frontier_worker
    grade: T2
    effort: high
    ceremony: {design_approved: true, independent_review: true, full_regression: true, approval_gates: []}
    budget: {concurrent_workers: 1, total_workers: 1, model_turns_per_worker: 1, model_runs: 1, edit_iterations: 1, related_test_runs: 1, full_test_runs: 1, max_input_tokens: 1, max_output_tokens: 1, changed_files: 1, changed_lines: 1, dependencies_added: 0}
  - id: T3
    name: approved frontier
    execution: worker
    role: frontier_worker
    grade: T3
    effort: high
    ceremony: {design_approved: true, independent_review: true, full_regression: true, approval_gates: [start, risk]}
    budget: {concurrent_workers: 1, total_workers: 1, model_turns_per_worker: 1, model_runs: 1, edit_iterations: 1, related_test_runs: 1, full_test_runs: 1, max_input_tokens: 1, max_output_tokens: 1, changed_files: 1, changed_lines: 1, dependencies_added: 0}
YAML
}
mk_v3_contract() { # $1=YAML path
  mk_v2_contract "$1"
  yq -i '
    .contract_version = 3 |
    .tasks[].lean_gate = {
      "decision": "minimal",
      "evidence": "기존 기능으로 해결할 수 없어 명시 범위의 최소 변경을 사용"
    }
  ' "$1"
}
mk_v2_contract "$TMP/v2-valid.yaml"
t "execution contract: 정상 T0~T3 matrix는 PASS" 0 bash -c \
  ". '$ROOT/scripts/lib.sh'; validate_execution_contract '$TMP/v2-valid.yaml'"
t "task_value: TASK_ID 환경변수로 태스크를 안전하게 선택" 0 bash -c \
  ". '$ROOT/scripts/lib.sh'; [ \"\$(task_value '$TMP/v2-valid.yaml' T1 '.name')\" = standard ]"
cp "$TMP/v2-valid.yaml" "$TMP/v2-unsafe-id.yaml"
yq -i '.tasks[1].id = "unsafe;id"' "$TMP/v2-unsafe-id.yaml"
t "execution contract: 안전하지 않은 저장 task id면 FAIL" 1 bash -c \
  ". '$ROOT/scripts/lib.sh'; validate_execution_contract '$TMP/v2-unsafe-id.yaml'"
cp "$TMP/v2-valid.yaml" "$TMP/v2-empty-id.yaml"
yq -i '.tasks[1].id = ""' "$TMP/v2-empty-id.yaml"
t "execution contract: 빈 저장 task id면 FAIL" 1 bash -c \
  ". '$ROOT/scripts/lib.sh'; validate_execution_contract '$TMP/v2-empty-id.yaml'"
for key in default_workers max_concurrent_workers max_delegation_depth; do
  cp "$TMP/v2-valid.yaml" "$TMP/v2-policy-$key.yaml"
  yq -i "del(.execution_policy.$key)" "$TMP/v2-policy-$key.yaml"
  t "execution contract: 정책 $key 누락이면 FAIL" 1 bash -c \
    ". '$ROOT/scripts/lib.sh'; validate_execution_contract '$TMP/v2-policy-$key.yaml'"
done
cp "$TMP/v2-valid.yaml" "$TMP/v2-policy-values.yaml"
yq -i '.execution_policy.default_workers = 2' "$TMP/v2-policy-values.yaml"
t "execution contract: 정책 값 1/3/0 이외면 FAIL" 1 bash -c \
  ". '$ROOT/scripts/lib.sh'; validate_execution_contract '$TMP/v2-policy-values.yaml'"
t "execution contract: if 문맥에서도 정책 위반을 거부" 1 bash -c \
  ". '$ROOT/scripts/lib.sh'; if validate_execution_contract '$TMP/v2-policy-values.yaml'; then exit 0; else exit 1; fi"
cp "$TMP/v2-valid.yaml" "$TMP/v2-bad-grade.yaml"
yq -i '.tasks[1].grade = "T9"' "$TMP/v2-bad-grade.yaml"
t "execution contract: 잘못된 grade면 FAIL" 1 bash -c \
  ". '$ROOT/scripts/lib.sh'; validate_execution_contract '$TMP/v2-bad-grade.yaml'"
cp "$TMP/v2-valid.yaml" "$TMP/v2-bad-execution.yaml"
yq -i '.tasks[1].execution = "deterministic"' "$TMP/v2-bad-execution.yaml"
t "execution contract: grade와 execution 조합이 틀리면 FAIL" 1 bash -c \
  ". '$ROOT/scripts/lib.sh'; validate_execution_contract '$TMP/v2-bad-execution.yaml'"
cp "$TMP/v2-valid.yaml" "$TMP/v2-bad-role.yaml"
yq -i '.tasks[1].role = "frontier_worker"' "$TMP/v2-bad-role.yaml"
t "execution contract: grade와 role 조합이 틀리면 FAIL" 1 bash -c \
  ". '$ROOT/scripts/lib.sh'; validate_execution_contract '$TMP/v2-bad-role.yaml'"
cp "$TMP/v2-valid.yaml" "$TMP/v2-bad-effort.yaml"
yq -i '.tasks[1].effort = "high"' "$TMP/v2-bad-effort.yaml"
t "execution contract: role과 effort 조합이 틀리면 FAIL" 1 bash -c \
  ". '$ROOT/scripts/lib.sh'; validate_execution_contract '$TMP/v2-bad-effort.yaml'"
cp "$TMP/v2-valid.yaml" "$TMP/v2-bad-t2.yaml"
yq -i '.tasks[2].ceremony.independent_review = false' "$TMP/v2-bad-t2.yaml"
t "execution contract: T2 review 누락이면 FAIL" 1 bash -c \
  ". '$ROOT/scripts/lib.sh'; validate_execution_contract '$TMP/v2-bad-t2.yaml'"
cp "$TMP/v2-valid.yaml" "$TMP/v2-bad-t2-regression.yaml"
yq -i '.tasks[2].ceremony.full_regression = false' "$TMP/v2-bad-t2-regression.yaml"
t "execution contract: T2 full regression 누락이면 FAIL" 1 bash -c \
  ". '$ROOT/scripts/lib.sh'; validate_execution_contract '$TMP/v2-bad-t2-regression.yaml'"
cp "$TMP/v2-valid.yaml" "$TMP/v2-bad-t3.yaml"
yq -i '.tasks[3].ceremony.approval_gates = ["start"]' "$TMP/v2-bad-t3.yaml"
t "execution contract: T3 risk gate 누락이면 FAIL" 1 bash -c \
  ". '$ROOT/scripts/lib.sh'; validate_execution_contract '$TMP/v2-bad-t3.yaml'"
cp "$TMP/v2-valid.yaml" "$TMP/v2-budget-missing.yaml"
yq -i 'del(.tasks[1].budget.model_runs)' "$TMP/v2-budget-missing.yaml"
t "execution contract: budget 필드 누락이면 FAIL" 1 bash -c \
  ". '$ROOT/scripts/lib.sh'; validate_execution_contract '$TMP/v2-budget-missing.yaml'"
cp "$TMP/v2-valid.yaml" "$TMP/v2-budget-negative.yaml"
yq -i '.tasks[1].budget.changed_lines = -1' "$TMP/v2-budget-negative.yaml"
t "execution contract: 음수 budget이면 FAIL" 1 bash -c \
  ". '$ROOT/scripts/lib.sh'; validate_execution_contract '$TMP/v2-budget-negative.yaml'"
cp "$TMP/v2-valid.yaml" "$TMP/v2-budget-workers.yaml"
yq -i '.tasks[1].budget.concurrent_workers = 2' "$TMP/v2-budget-workers.yaml"
t "execution contract: concurrent_workers가 total_workers보다 크면 FAIL" 1 bash -c \
  ". '$ROOT/scripts/lib.sh'; validate_execution_contract '$TMP/v2-budget-workers.yaml'"
printf 'tasks: []\n' > "$TMP/v1-legacy.yaml"
t "execution contract: 버전 없는 기존 계약은 경고와 함께 PASS" 0 bash -c \
  ". '$ROOT/scripts/lib.sh'; validate_execution_contract '$TMP/v1-legacy.yaml' > '$TMP/v1-legacy-warning.out' 2>&1 \
   && grep -Fq 'legacy execution contract' '$TMP/v1-legacy-warning.out'"
mk_v3_contract "$TMP/v3-valid.yaml"
for decision in reuse stdlib native installed minimal not-applicable; do
  cp "$TMP/v3-valid.yaml" "$TMP/v3-$decision.yaml"
  yq -i ".tasks[1].lean_gate.decision = \"$decision\"" "$TMP/v3-$decision.yaml"
  t "execution contract v3: ${decision}은 PASS" 0 bash -c \
    ". '$ROOT/scripts/lib.sh'; validate_execution_contract '$TMP/v3-$decision.yaml'"
done
cp "$TMP/v3-valid.yaml" "$TMP/v3-not-needed.yaml"
yq -i '.tasks[1].lean_gate.decision = "not-needed" | .tasks[1].status = "skipped"' "$TMP/v3-not-needed.yaml"
t "execution contract v3: not-needed와 skipped는 PASS" 0 bash -c \
  ". '$ROOT/scripts/lib.sh'; validate_execution_contract '$TMP/v3-not-needed.yaml'"

cp "$TMP/v3-valid.yaml" "$TMP/v3-missing.yaml"
yq -i 'del(.tasks[1].lean_gate)' "$TMP/v3-missing.yaml"
t "execution contract v3: lean_gate 누락이면 FAIL" 1 bash -c \
  ". '$ROOT/scripts/lib.sh'; validate_execution_contract '$TMP/v3-missing.yaml'"

cp "$TMP/v3-valid.yaml" "$TMP/v3-bad.yaml"
yq -i '.tasks[1].lean_gate.decision = "custom"' "$TMP/v3-bad.yaml"
t "execution contract v3: 잘못된 decision이면 FAIL" 1 bash -c \
  ". '$ROOT/scripts/lib.sh'; validate_execution_contract '$TMP/v3-bad.yaml'"

cp "$TMP/v3-valid.yaml" "$TMP/v3-empty.yaml"
yq -i '.tasks[1].lean_gate.evidence = ""' "$TMP/v3-empty.yaml"
t "execution contract v3: 빈 evidence면 FAIL" 1 bash -c \
  ". '$ROOT/scripts/lib.sh'; validate_execution_contract '$TMP/v3-empty.yaml'"

cp "$TMP/v3-valid.yaml" "$TMP/v3-whitespace.yaml"
yq -i '.tasks[1].lean_gate.evidence = "   "' "$TMP/v3-whitespace.yaml"
t "execution contract v3: 공백뿐인 evidence면 FAIL" 1 bash -c \
  ". '$ROOT/scripts/lib.sh'; validate_execution_contract '$TMP/v3-whitespace.yaml'"

cp "$TMP/v3-valid.yaml" "$TMP/v3-pair-a.yaml"
yq -i '.tasks[1].lean_gate.decision = "not-needed" | .tasks[1].status = "pending"' "$TMP/v3-pair-a.yaml"
t "execution contract v3: not-needed인데 skipped가 아니면 FAIL" 1 bash -c \
  ". '$ROOT/scripts/lib.sh'; validate_execution_contract '$TMP/v3-pair-a.yaml'"

cp "$TMP/v3-valid.yaml" "$TMP/v3-pair-b.yaml"
yq -i '.tasks[1].status = "skipped"' "$TMP/v3-pair-b.yaml"
t "execution contract v3: skipped인데 not-needed가 아니면 FAIL" 1 bash -c \
  ". '$ROOT/scripts/lib.sh'; validate_execution_contract '$TMP/v3-pair-b.yaml'"

t "execution contract v2: Lean Gate 미적용 경고와 함께 PASS" 0 bash -c \
  ". '$ROOT/scripts/lib.sh'; validate_execution_contract '$TMP/v2-valid.yaml' > '$TMP/v2-lean-gate-warning.out' 2>&1 \
   && grep -Fq 'Lean Gate 미적용 계약' '$TMP/v2-lean-gate-warning.out'"
cp "$TMP/v3-valid.yaml" "$TMP/v4-unsupported.yaml"
yq -i '.contract_version = 4' "$TMP/v4-unsupported.yaml"
t "execution contract: 지원하지 않는 버전은 FAIL" 1 bash -c \
  ". '$ROOT/scripts/lib.sh'; validate_execution_contract '$TMP/v4-unsupported.yaml'"
mk_proj "$TMP/v2-scaffold"; fill_project "$TMP/v2-scaffold"
mk_v2_contract "$TMP/v2-scaffold/tasks.yaml"
yq -i '.tasks = [] | .execution_policy.max_concurrent_workers = 2' "$TMP/v2-scaffold/tasks.yaml"
t "scaffold-check: v2 계약 위반이면 모델 실행 전에 FAIL" 1 bash -c \
  "cd '$TMP/v2-scaffold' && bash '$SC'"
t "template: judge는 일반 worker task role로 안내하지 않는다" 0 bash -c \
  "! grep -Fq 'frontier_worker | judge' '$ROOT/template/tasks.yaml'"
t "template: 기본 tasks.yaml은 v3 계약 PASS" 0 bash -c \
  ". '$ROOT/scripts/lib.sh'; validate_execution_contract '$ROOT/template/tasks.yaml'"

# --- B-006 Task 3: v2 dispatch enforcement ---
mk_v2_dispatch_proj() { # $1=프로젝트: v2 계약 + dispatch에 필요한 기존 필드
  mk_proj "$1"; fill_project "$1"
  mk_v2_contract "$1/tasks.yaml"
  yq -i '.tasks[] |= (. + {"depends_on": [], "worktree": ".", "write_paths": [], "done_when": "x", "on_fail": "hold_downstream", "status": "pending", "run_id": ""} | .brief = ("agents/worker-" + .id + ".md"))' "$1/tasks.yaml"
  for id in T0 T1 T2 T3; do
    printf '임무: %s\n산출물: x\n쓰기 허용 경로: source/\n완료 신호: log/%s.done 생성\n' "$id" "$id" \
      > "$1/agents/worker-$id.md"
  done
  : > "$1/log/scaffold-check.pass"
}

mk_v3_dispatch_proj() {
  mk_v2_dispatch_proj "$1"
  yq -i '
    .contract_version = 3 |
    .tasks[].lean_gate = {
      "decision": "minimal",
      "evidence": "기존 기능으로 해결할 수 없어 명시 범위의 최소 변경을 사용"
    }
  ' "$1/tasks.yaml"
  git -C "$1" add -A
  git -C "$1" commit -qm v3-fixture
}

mark_v2_running() { # $1=프로젝트, 나머지=running task IDs
  local p="$1" id
  shift
  for id in "$@"; do
    yq -i "(.tasks[] | select(.id == \"$id\")).status = \"running\" | (.tasks[] | select(.id == \"$id\")).run_id = \"run-$id\"" "$p/tasks.yaml"
  done
}

mk_v2_dispatch_proj "$TMP/v2-dispatch"
cat > "$TMP/models-none-role.yaml" <<'YAML'
roles:
  none:
    effort: low
    candidates:
      - name: fake-none
        command: sh
        args: ["-c"]
YAML
t "dispatch v2: deterministic 작업은 모델·mux 전에 거부" 0 bash -c \
  "cd '$TMP/v2-dispatch' && PATH='$TMP/fakebin-dispatch:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin' CMUX_CAPTURE='$TMP/v2-deterministic-mux' HARNESS_MODELS='$TMP/models-none-role.yaml' bash '$DP' T0 >/dev/null 2>&1 && exit 1 || [ ! -e '$TMP/v2-deterministic-mux' ]"

mk_v2_dispatch_proj "$TMP/v2-effort"
cat > "$TMP/models-high-standard.yaml" <<'YAML'
roles:
  standard_worker:
    effort: high
    candidates:
      - name: fake-high
        command: sh
        args: ["-c"]
YAML
t "dispatch v2: task effort와 역할 effort 불일치면 거부" 0 bash -c \
  "cd '$TMP/v2-effort' && PATH='$TMP/fakebin-dispatch:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin' CMUX_CAPTURE='$TMP/v2-effort-mux' HARNESS_MODELS='$TMP/models-high-standard.yaml' bash '$DP' T1 >/dev/null 2>&1 && exit 1 || [ ! -e '$TMP/v2-effort-mux' ]"

mk_v2_dispatch_proj "$TMP/v2-cap-fourth"
mark_v2_running "$TMP/v2-cap-fourth" T0 T2 T3
t "dispatch v2: 다른 running 작업 세 개면 네 번째를 거부" 0 bash -c \
  "cd '$TMP/v2-cap-fourth' && PATH='$TMP/fakebin-dispatch:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin' CMUX_CAPTURE='$TMP/v2-fourth-mux' HARNESS_MODELS='$TMP/models-ok.yaml' bash '$DP' T1 >/dev/null 2>&1 && exit 1 || [ ! -e '$TMP/v2-fourth-mux' ]"

mk_v2_dispatch_proj "$TMP/v2-cap-third"
mark_v2_running "$TMP/v2-cap-third" T0 T2
t "dispatch v2: 다른 running 작업 두 개면 세 번째를 허용·기록" 0 bash -c \
  "cd '$TMP/v2-cap-third' && PATH='$TMP/fakebin-dispatch:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin' CMUX_CAPTURE='$TMP/v2-third-mux' HARNESS_LAYOUT=workspace HARNESS_MODELS='$TMP/models-ok.yaml' bash '$DP' T1 > '$TMP/v2-third.out' \
   && [ -e '$TMP/v2-third-mux' ] \
   && awk '\$2 ~ /^[A-Za-z0-9._-]+$/ && \$4 == \"dispatched\" && /grade: T1 effort: medium contract: 2/' log/T1.runs \
   && grep -Fq '등급 T1 / 논리 역할 standard_worker / 실제 프로필 fake-cli / 생각량 medium' '$TMP/v2-third.out'"

t "dispatch: contract_version 없는 기존 작업은 기존 방식으로 허용" 0 bash -c \
  "cd '$TMP/p-runid' && PATH='$TMP/fakebin-dispatch:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin' HARNESS_LAYOUT=workspace HARNESS_MODELS='$TMP/models-ok.yaml' bash '$DP' A >/dev/null \
   && awk '\$4 == \"dispatched\" {found=1} END {exit !found}' log/A.runs"

mk_v3_dispatch_proj "$TMP/v3-skipped-state"
yq -i '.tasks[1].lean_gate.decision = "not-needed" | .tasks[1].status = "skipped"' "$TMP/v3-skipped-state/tasks.yaml"
t "state v3: 깨끗한 skipped는 PASS" 0 bash -c \
  "cd '$TMP/v3-skipped-state' && . .harness/lib/state.sh && validate_state working"

mk_v3_dispatch_proj "$TMP/v3-skipped-run"
yq -i '.tasks[1].lean_gate.decision = "not-needed" | .tasks[1].status = "skipped" | .tasks[1].run_id = "old-run"' "$TMP/v3-skipped-run/tasks.yaml"
t "state v3: skipped에 run_id가 있으면 FAIL" 1 bash -c \
  "cd '$TMP/v3-skipped-run' && . .harness/lib/state.sh && validate_state working"

for suffix in 'done' verified.yaml verify.log runs prompt log; do
  project="$TMP/v3-skipped-$suffix"
  mk_v3_dispatch_proj "$project"
  yq -i '.tasks[1].lean_gate.decision = "not-needed" | .tasks[1].status = "skipped"' "$project/tasks.yaml"
  : > "$project/log/T1.$suffix"
  t "state v3: skipped에 $suffix 증거가 있으면 FAIL" 1 bash -c \
    "cd '$project' && . .harness/lib/state.sh && validate_state working"
done

mk_v3_dispatch_proj "$TMP/v3-missing-dispatch"
yq -i 'del(.tasks[1].lean_gate)' "$TMP/v3-missing-dispatch/tasks.yaml"
t "dispatch v3: Lean Gate 누락은 모델·mux 전에 거부" 0 bash -c \
  "cd '$TMP/v3-missing-dispatch'; \
   if PATH='$TMP/fakebin-dispatch:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin' \
      CMUX_CAPTURE='$TMP/v3-missing-mux' HARNESS_MODELS='$TMP/models-ok.yaml' \
      bash '$DP' T1 >/dev/null 2>&1; then exit 1; fi; \
   [ ! -e '$TMP/v3-missing-mux' ]"

mk_v3_dispatch_proj "$TMP/v3-not-needed-dispatch"
yq -i '.tasks[1].lean_gate.decision = "not-needed" | .tasks[1].status = "skipped"' "$TMP/v3-not-needed-dispatch/tasks.yaml"
t "dispatch v3: not-needed는 모델·mux 전에 거부" 0 bash -c \
  "cd '$TMP/v3-not-needed-dispatch'; \
   if PATH='$TMP/fakebin-dispatch:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin' \
      CMUX_CAPTURE='$TMP/v3-not-needed-mux' HARNESS_MODELS='$TMP/models-ok.yaml' \
      bash '$DP' T1 >/dev/null 2>&1; then exit 1; fi; \
   [ ! -e '$TMP/v3-not-needed-mux' ]"

mk_v3_dispatch_proj "$TMP/v3-dispatch-ok"
t "dispatch v3: 한 줄 계약과 contract 3을 기록" 0 bash -c \
  "cd '$TMP/v3-dispatch-ok' \
   && PATH='$TMP/fakebin-dispatch:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin' \
      HARNESS_LAYOUT=workspace HARNESS_MODELS='$TMP/models-ok.yaml' bash '$DP' T1 >/dev/null \
   && grep -Fq 'Lean Gate: minimal' log/T1.prompt \
   && grep -Fq '명시 범위의 최소 변경으로 기존 안전 조건을 보존하라' log/T1.prompt \
   && awk '/event: dispatched/ && /contract: 3/ {ok=1} END {exit !ok}' log/T1.runs"

mk_v3_dispatch_proj "$TMP/v3-skipped-dependency"
yq -i '.tasks[0].lean_gate.decision = "not-needed" | .tasks[0].status = "skipped" | .tasks[1].depends_on = ["T0"]' "$TMP/v3-skipped-dependency/tasks.yaml"
t "dispatch v3: skipped dependency는 완료가 아님" 0 bash -c \
  "cd '$TMP/v3-skipped-dependency'; \
   if PATH='$TMP/fakebin-dispatch:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin' \
      CMUX_CAPTURE='$TMP/v3-skipped-dep-mux' HARNESS_MODELS='$TMP/models-ok.yaml' \
      bash '$DP' T1 >/dev/null 2>&1; then exit 1; fi; \
   [ ! -e '$TMP/v3-skipped-dep-mux' ]"

# --- B-001 재리뷰: verify.sh task id 경로 이탈 차단 ---
mk_vproj "$TMP/v-id"
t "verify: 안전하지 않은 task id 거부(경로 이탈 차단)" 1 bash -c \
  "cd '$TMP/v-id' && bash '$VF' '../../evil' 2>/dev/null; rc=\$?; \
   if [ -e '$TMP/evil.verify.log' ] || [ -e '$TMP/v-id/evil.verify.log' ]; then exit 42; fi; exit \$rc"

# --- B-004: dispatch 한 화면 pane 모드 ---
# 가짜 cmux: 호출 인자를 기록하고 최소 응답만 낸다 (실제 cmux 없이 결정 경로 검증)
mkdir -p "$TMP/panebin"
CMUXLOG="$TMP/cmux-calls.log"
cat > "$TMP/panebin/cmux" <<PANESH
#!/bin/sh
printf '%s\n' "\$*" >> "$CMUXLOG"
case "\$1" in
  ping) exit 0 ;;
  identify) printf '{"caller":{"workspace_ref":"workspace:5","surface_ref":"surface:70"}}\n' ;;
  new-split) printf 'OK surface:99 workspace:5\n' ;;
  new-workspace) printf 'OK workspace:88 hx\n' ;;
  *) exit 0 ;;
esac
PANESH
chmod +x "$TMP/panebin/cmux"
PANEPATH="$TMP/panebin:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin"

mk_pane_proj() { # $1=프로젝트: deps 없는 단일 태스크 + scaffold-check.pass 생성
  mk_proj "$1"; fill_project "$1"
  cat > "$1/tasks.yaml" <<'YAML'
tasks:
  - id: P1
    name: pane worker
    role: standard_worker
    grade: T1
    depends_on: []
    worktree: "."
    write_paths: ["source/"]
    done_when: log/P1.done
    on_fail: hold_downstream
    status: pending
    run_id: ""
    brief: agents/worker-P1.md
    skills: [test-driven-development, verification-before-completion]
    verify:
      command: bash
      args: ["-c", "true"]
YAML
  printf '임무: p\n산출물: x\n쓰기 허용 경로: source/\n완료 신호: log/P1.done 생성\n' > "$1/agents/worker-P1.md"
  ( cd "$1" && PATH="$PANEPATH" bash "$ROOT/scripts/scaffold-check.sh" >/dev/null 2>&1 )
  HARNESS_PROJECT_ROOT="$1" "$1/.harness/bin/live-status" orchestrator-update \
    --run-id ORCH-PANE --provider codex --surface surface:70 \
    --phase execute --task 'pane tests' --captured-at 1784044800
}

mk_pane_proj "$TMP/pane1"
t "dispatch(pane): new-split을 쓰고 new-workspace는 쓰지 않는다" 0 bash -c \
  "cd '$TMP/pane1' && : > '$CMUXLOG' && PATH='$PANEPATH' HARNESS_MODELS='$TMP/models-ok.yaml' HARNESS_LAYOUT=pane bash '$ROOT/scripts/dispatch.sh' P1 >/dev/null \
   && grep -q '^new-split' '$CMUXLOG' && ! grep -q '^new-workspace' '$CMUXLOG'"
t "dispatch(pane): 워커 명령을 새 surface에 send한다" 0 bash -c \
  "cd '$TMP/pane1' && grep -Eq '^send .*worker-wrap' '$CMUXLOG'"
t "dispatch(pane): 방향 HARNESS_PANE_DIR를 존중한다" 0 bash -c \
  "cd '$TMP/pane1' && : > '$CMUXLOG' && PATH='$PANEPATH' HARNESS_MODELS='$TMP/models-ok.yaml' HARNESS_LAYOUT=pane HARNESS_PANE_DIR=right bash '$ROOT/scripts/dispatch.sh' P1 >/dev/null \
   && grep -q '^new-split right' '$CMUXLOG'"
t "dispatch(pane): 잘못된 방향은 거부" 1 bash -c \
  "cd '$TMP/pane1' && PATH='$PANEPATH' HARNESS_MODELS='$TMP/models-ok.yaml' HARNESS_LAYOUT=pane HARNESS_PANE_DIR=sideways bash '$ROOT/scripts/dispatch.sh' P1"
t "dispatch(기본): right pane을 만들고 오케스트레이터 workspace/surface를 기록" 0 bash -c \
  "cd '$TMP/pane1' && : > '$CMUXLOG' && PATH='$PANEPATH' HARNESS_MODELS='$TMP/models-ok.yaml' bash '$ROOT/scripts/dispatch.sh' P1 > '$TMP/pane-default.out' \
   && grep -q '^new-split right --workspace workspace:5$' '$CMUXLOG' && ! grep -q '^new-workspace' '$CMUXLOG' \
   && grep -Fq 'workspace:5/surface:99 (right)' '$TMP/pane-default.out'"
t "dispatch(pane): worker 레코드에 부모·모델·스킬·실제 surface를 기록" 0 bash -c \
  "run=\$(sed -n 's/^\\[실행 ID: \\([^ ]*\\).*/\\1/p' '$TMP/pane1/log/P1.prompt') \
   && f='$TMP/pane1/.harness/live-workers/'\$run.env && [ -f \"\$f\" ] \
   && grep -Fxq 'HARNESS_WORKER_PARENT_RUN_ID=ORCH-PANE' \"\$f\" \
   && grep -Fxq 'HARNESS_WORKER_PARENT_SURFACE=surface:70' \"\$f\" \
   && grep -Fxq 'HARNESS_WORKER_PROVIDER=sh' \"\$f\" \
   && grep -Fxq 'HARNESS_WORKER_MODEL_REQUESTED=fake-cli' \"\$f\" \
   && grep -Fxq 'HARNESS_WORKER_REQUIRED_SKILLS=test-driven-development,verification-before-completion' \"\$f\" \
   && grep -Fxq 'HARNESS_WORKER_ACTIVE_SKILLS=?' \"\$f\" \
   && grep -Fxq 'HARNESS_WORKER_STATE=running' \"\$f\" \
   && grep -Fxq 'HARNESS_WORKER_SURFACE=surface:99' \"\$f\" \
   && grep -Fq '$TMP/pane1/.harness/bin/live-status' '$TMP/pane1/log/P1.prompt' \
   && grep -Fq -- \"--run-id \\\"\$run\\\" --state running\" '$TMP/pane1/log/P1.prompt'"
t "dispatch(workspace): 명시하면 새 workspace 호환 경로를 유지" 0 bash -c \
  "cd '$TMP/pane1' && : > '$CMUXLOG' && PATH='$PANEPATH' HARNESS_MODELS='$TMP/models-ok.yaml' HARNESS_LAYOUT=workspace bash '$ROOT/scripts/dispatch.sh' P1 >/dev/null \
   && grep -q '^new-workspace' '$CMUXLOG' && ! grep -q '^new-split' '$CMUXLOG'"
t "dispatch: 잘못된 레이아웃은 거부" 1 bash -c \
  "cd '$TMP/pane1' && PATH='$PANEPATH' HARNESS_MODELS='$TMP/models-ok.yaml' HARNESS_LAYOUT=tiles bash '$ROOT/scripts/dispatch.sh' P1"
t "docs: ORCHESTRATION은 pane 레이아웃(B-004)을 설명" 0 bash -c \
  "grep -Fq 'HARNESS_LAYOUT=pane' '$ROOT/doctrine/ORCHESTRATION.md'"

# --- worker monitor: 선택한 cmux surface와 Git worktree만 읽는다 ---
MW="$ROOT/scripts/monitor-worker.sh"
mkdir -p "$TMP/monitorbin" "$TMP/monitor-worktree"
MONITORLOG="$TMP/monitor-calls.log"
cat > "$TMP/monitorbin/cmux" <<'MONITORCMUX'
#!/bin/sh
printf 'cmux %s\n' "$*" >> "$MONITORLOG"
printf 'selected screen\n'
MONITORCMUX
cat > "$TMP/monitorbin/git" <<'MONITORGIT'
#!/bin/sh
printf 'git %s\n' "$*" >> "$MONITORLOG"
case "$3" in
  rev-parse) [ -f "$2/.git/HEAD" ] || exit 1; printf 'true\n' ;;
  status) printf '## feature/test\n' ;;
  log) printf 'abc123 latest commit\n' ;;
esac
MONITORGIT
chmod +x "$TMP/monitorbin/cmux" "$TMP/monitorbin/git"
MONITORPATH="$TMP/monitorbin:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin"
(cd "$TMP/monitor-worktree" && git init -q)
t "monitor: 선택 surface와 worktree만 정확히 읽는다" 0 bash -c \
  ": > '$MONITORLOG' && PATH='$MONITORPATH' MONITORLOG='$MONITORLOG' bash '$MW' workspace:5 surface:99 '$TMP/monitor-worktree' > '$TMP/monitor.out' \
   && grep -Fxq 'cmux read-screen --workspace workspace:5 --surface surface:99 --scrollback --lines 80' '$MONITORLOG' \
   && grep -Fxq 'git -C $TMP/monitor-worktree rev-parse --is-inside-work-tree' '$MONITORLOG' \
   && grep -Fxq 'git -C $TMP/monitor-worktree status --short --branch' '$MONITORLOG' \
   && grep -Fxq 'git -C $TMP/monitor-worktree log -1 --oneline' '$MONITORLOG' \
   && [ \"\$(wc -l < '$MONITORLOG' | tr -d ' ')\" -eq 4 ] \
   && grep -Fq 'selected screen' '$TMP/monitor.out' && grep -Fq '## feature/test' '$TMP/monitor.out' && grep -Fq 'abc123 latest commit' '$TMP/monitor.out'"
for monitor_case in 'workspace bad:5 surface:99' 'workspace:5 surface bad:99' 'workspace:5 surface:99 missing'; do
  read -r monitor_workspace monitor_surface monitor_path <<< "$monitor_case"
  t "monitor: $monitor_path 입력은 외부 호출 전에 거부" 1 bash -c \
    ": > '$MONITORLOG' && PATH='$MONITORPATH' MONITORLOG='$MONITORLOG' bash '$MW' '$monitor_workspace' '$monitor_surface' '$TMP/$monitor_path' >/dev/null 2>&1; rc=\$?; [ ! -s '$MONITORLOG' ]; exit \$rc"
done
t "monitor: executable ps 토큰을 포함하지 않는다" 0 bash -c \
  "! rg -n '(^|[;&|[:space:]])ps([[:space:];&|]|$)' '$MW'"

# --- TUI-P1: live-status 원자적 상태 기록기 ---
make_live_project() {
  p="$1"
  mkdir -p "$p/.harness/bin"
  cp "$ROOT/template/.harness/bin/live-status" "$p/.harness/bin/live-status"
  chmod +x "$p/.harness/bin/live-status"
}

live_status_orchestrator_is_atomic_and_private() {
  p="$TMP/live-orch"
  make_live_project "$p"
  HARNESS_PROJECT_ROOT="$p" "$p/.harness/bin/live-status" orchestrator-update \
    --run-id ORCH-20260715-01 --provider codex \
    --model-requested gpt-5.3-codex --model-observed gpt-5.3-codex \
    --surface surface:86 --phase plan --task 'TUI producer' \
    --skills 'harness,writing-plans' --context-left-pct '?' \
    --context-left '?' --weekly-left-pct 67 --weekly-resets-at 1784780177 \
    --credits-balance 2190.0125 --credits-delta '?' --credits-available true \
    --billing-route weekly --captured-at 1784044800 || return 1
  f="$p/.harness/live-status.env"
  [ "$(stat -f '%Lp' "$f" 2>/dev/null || stat -c '%a' "$f")" = 600 ] || return 1
  grep -Fx 'HARNESS_STATUS_VERSION=2' "$f" >/dev/null || return 1
  grep -Fx 'HARNESS_ORCHESTRATOR_ACTIVE_SKILLS=harness,writing-plans' "$f" >/dev/null || return 1
  grep -Fx 'HARNESS_CONTEXT_REMAINING_PCT=?' "$f" >/dev/null || return 1
  grep -Fx 'HARNESS_WEEKLY_RESETS_AT=1784780177' "$f" >/dev/null || return 1
  grep -Fx 'HARNESS_CODEX_CREDITS_BALANCE=2190.0125' "$f" >/dev/null || return 1
  grep -Fx 'HARNESS_CODEX_CREDITS_DELTA=?' "$f" >/dev/null || return 1
  grep -Fx 'HARNESS_CODEX_CREDITS_AVAILABLE=true' "$f" >/dev/null || return 1
  grep -Fx 'HARNESS_CODEX_BILLING_ROUTE=weekly' "$f" >/dev/null || return 1
  [ ! -e "$f.tmp" ]
}
t "live-status(orch): 원자적·비공개 기록" 0 live_status_orchestrator_is_atomic_and_private

live_status_provider_switch_resets_usage() {
  p="$TMP/live-orch-switch"
  make_live_project "$p"
  HARNESS_PROJECT_ROOT="$p" "$p/.harness/bin/live-status" orchestrator-update \
    --run-id ORCH-SWITCH-01 --provider codex \
    --model-requested gpt-5.3-codex --model-observed gpt-5.3-codex \
    --phase implement --task 'switch source' --context-left-pct 14 \
    --weekly-left-pct 0 --weekly-resets-at 1784780177 \
    --credits-balance 0 --credits-delta 0.0 --credits-available false \
    --billing-route unavailable --captured-at 1784044800 || return 1
  # 공급자만 바꿔 갱신하면 이전 공급자의 모델·사용량·크레딧은 미상이 된다.
  HARNESS_PROJECT_ROOT="$p" "$p/.harness/bin/live-status" orchestrator-update \
    --provider claude --phase resume --captured-at 1784044900 || return 1
  f="$p/.harness/live-status.env"
  grep -Fx 'HARNESS_ORCHESTRATOR_PROVIDER=claude' "$f" >/dev/null || return 1
  grep -Fx 'HARNESS_ORCHESTRATOR_MODEL_OBSERVED=?' "$f" >/dev/null || return 1
  grep -Fx 'HARNESS_ORCHESTRATOR_MODEL_REQUESTED=?' "$f" >/dev/null || return 1
  grep -Fx 'HARNESS_CONTEXT_REMAINING_PCT=?' "$f" >/dev/null || return 1
  grep -Fx 'HARNESS_WEEKLY_REMAINING_PCT=?' "$f" >/dev/null || return 1
  grep -Fx 'HARNESS_WEEKLY_RESETS_AT=?' "$f" >/dev/null || return 1
  grep -Fx 'HARNESS_CODEX_CREDITS_BALANCE=?' "$f" >/dev/null || return 1
  grep -Fx 'HARNESS_CODEX_BILLING_ROUTE=?' "$f" >/dev/null || return 1
  # 공급자와 무관한 진행 정보는 유지된다.
  grep -Fx 'HARNESS_ORCHESTRATOR_RUN_ID=ORCH-SWITCH-01' "$f" >/dev/null || return 1
  # 같은 공급자로 다시 갱신하면 기존 값을 정상적으로 이어받는다.
  HARNESS_PROJECT_ROOT="$p" "$p/.harness/bin/live-status" orchestrator-update \
    --provider claude --context-left-pct 88 --captured-at 1784045000 || return 1
  grep -Fx 'HARNESS_CONTEXT_REMAINING_PCT=88' "$f" >/dev/null || return 1
  HARNESS_PROJECT_ROOT="$p" "$p/.harness/bin/live-status" orchestrator-update \
    --provider claude --captured-at 1784045100 || return 1
  grep -Fx 'HARNESS_CONTEXT_REMAINING_PCT=88' "$f" >/dev/null
}
t "live-status(orch): 공급자 전환 시 이전 사용량·모델을 이어받지 않음" 0 \
  live_status_provider_switch_resets_usage

live_status_usage_has_its_own_capture_time() {
  p="$TMP/live-orch-usage-age"
  make_live_project "$p"
  HARNESS_PROJECT_ROOT="$p" "$p/.harness/bin/live-status" orchestrator-update \
    --provider claude --weekly-left-pct 40 --captured-at 1784044800 || return 1
  f="$p/.harness/live-status.env"
  grep -Fx 'HARNESS_USAGE_CAPTURED_AT=1784044800' "$f" >/dev/null || return 1
  # 사용량 없는 갱신은 전체 시각만 바꾸고 사용량 시각은 이어받는다.
  HARNESS_PROJECT_ROOT="$p" "$p/.harness/bin/live-status" orchestrator-update \
    --provider claude --phase implement --captured-at 1784044900 || return 1
  grep -Fx 'HARNESS_CAPTURED_AT=1784044900' "$f" >/dev/null || return 1
  grep -Fx 'HARNESS_USAGE_CAPTURED_AT=1784044800' "$f" >/dev/null
}
t "live-status(orch): 사용량 수집 시각은 사용량 갱신에만 전진" 0 \
  live_status_usage_has_its_own_capture_time

statusline_feeds_active_project_pointer() {
  p="$TMP/statusline-pointer-proj"
  make_live_project "$p"
  state="$TMP/statusline-pointer-state"
  mkdir -p "$state"
  printf '%s\n' "$p" > "$state/active-project"
  out="$(printf '{"workspace":{"current_dir":"%s"},"model":{"display_name":"Fable 5"},"context_window":{"used_percentage":30},"rate_limits":{"five_hour":{"used_percentage":10},"seven_day":{"used_percentage":25}}}' "$TMP" \
    | HARNESS_STATE_DIR="$state" bash "$ROOT/scripts/claude-statusline-tui.sh")" || return 1
  printf '%s\n' "$out" | grep -Fq 'Fable 5' || return 1
  f="$p/.harness/live-status.env"
  grep -Fx 'HARNESS_ORCHESTRATOR_MODEL_OBSERVED=Fable 5' "$f" >/dev/null || return 1
  grep -Fx 'HARNESS_CONTEXT_REMAINING_PCT=70' "$f" >/dev/null || return 1
  grep -Fx 'HARNESS_WEEKLY_REMAINING_PCT=75' "$f" >/dev/null || return 1
  grep -Eq '^HARNESS_USAGE_CAPTURED_AT=[0-9]+$' "$f"
}
t "statusline: 프로젝트 밖 세션은 active-project 포인터로 공급" 0 \
  statusline_feeds_active_project_pointer
LS="$ROOT/template/.harness/bin/live-status"
t "live-status(orch): 범위 밖 퍼센트 101 거부" 2 bash -c \
  "HARNESS_PROJECT_ROOT='$TMP/live-rej1' '$LS' orchestrator-update --run-id R --provider codex --weekly-left-pct 101"
t "live-status(orch): run id에 / 포함 거부" 2 bash -c \
  "HARNESS_PROJECT_ROOT='$TMP/live-rej2' '$LS' orchestrator-update --run-id 'a/b' --provider codex"
t "live-status(orch): task에 개행 포함 거부" 2 bash -c \
  "HARNESS_PROJECT_ROOT='$TMP/live-rej3' '$LS' orchestrator-update --run-id R --task \"\$(printf 'a\\nb')\""
t "live-status(orch): 알 수 없는 플래그 거부" 2 bash -c \
  "HARNESS_PROJECT_ROOT='$TMP/live-rej4' '$LS' orchestrator-update --bogus x"

live_status_worker_lifecycle() {
  p="$TMP/live-worker"
  make_live_project "$p"
  HARNESS_PROJECT_ROOT="$p" "$p/.harness/bin/live-status" worker-init \
    --run-id W-TUI-01 --parent-run-id ORCH-20260715-01 \
    --parent-surface surface:86 --provider claude \
    --model-requested opus --role implementer --task-id TUI-PRODUCER \
    --required-skills 'test-driven-development,verification-before-completion' \
    --surface '?' --started-at 1784044801 || return 1
  HARNESS_PROJECT_ROOT="$p" "$p/.harness/bin/live-status" worker-update \
    --run-id W-TUI-01 --state running --surface surface:90 \
    --model-observed claude-opus-4-6 --work 'atomic writer tests' \
    --skills 'test-driven-development' --updated-at 1784044802 || return 1
  HARNESS_PROJECT_ROOT="$p" "$p/.harness/bin/live-status" worker-finish \
    --run-id W-TUI-01 --finished-at 1784044810 || return 1
  f="$p/.harness/live-workers/W-TUI-01.env"
  [ "$(stat -f '%Lp' "$f" 2>/dev/null || stat -c '%a' "$f")" = 600 ] || return 1
  grep -Fx 'HARNESS_WORKER_STATUS_VERSION=1' "$f" >/dev/null || return 1
  grep -Fx 'HARNESS_WORKER_REQUIRED_SKILLS=test-driven-development,verification-before-completion' "$f" >/dev/null || return 1
  grep -Fx 'HARNESS_WORKER_ACTIVE_SKILLS=test-driven-development' "$f" >/dev/null || return 1
  grep -Fx 'HARNESS_WORKER_PARENT_RUN_ID=ORCH-20260715-01' "$f" >/dev/null || return 1
  grep -Fx 'HARNESS_WORKER_PARENT_SURFACE=surface:86' "$f" >/dev/null || return 1
  grep -Fx 'HARNESS_WORKER_MODEL_REQUESTED=opus' "$f" >/dev/null || return 1
  grep -Fx 'HARNESS_WORKER_MODEL_OBSERVED=claude-opus-4-6' "$f" >/dev/null || return 1
  grep -Fx 'HARNESS_WORKER_SURFACE=surface:90' "$f" >/dev/null || return 1
  grep -Fx 'HARNESS_WORKER_STARTED_AT=1784044801' "$f" >/dev/null || return 1
  grep -Fx 'HARNESS_WORKER_STATE=done' "$f" >/dev/null || return 1
  grep -Fx 'HARNESS_WORKER_UPDATED_AT=1784044810' "$f" >/dev/null || return 1
  grep -Fx 'HARNESS_WORKER_FINISHED_AT=1784044810' "$f" >/dev/null || return 1
}
t "live-status(worker): 생명주기 init→update→finish" 0 live_status_worker_lifecycle

live_status_worker_missing_update_fails() {
  p="$TMP/live-worker-missing"
  make_live_project "$p"
  [ -x "$p/.harness/bin/live-status" ] || return 1
  if HARNESS_PROJECT_ROOT="$p" "$p/.harness/bin/live-status" worker-update \
       --run-id GHOST-01 --state running --updated-at 1784044802; then
    return 1
  fi
  [ ! -e "$p/.harness/live-workers/GHOST-01.env" ]
}
t "live-status(worker): 없는 레코드는 갱신 불가" 0 live_status_worker_missing_update_fails

live_status_worker_gc() {
  p="$TMP/live-gc"
  make_live_project "$p"
  [ -x "$p/.harness/bin/live-status" ] || return 1
  b="$p/.harness/bin/live-status"
  w="$p/.harness/live-workers"
  HARNESS_PROJECT_ROOT="$p" "$b" worker-init --run-id W-OLD --provider claude --started-at 1784044700 || return 1
  HARNESS_PROJECT_ROOT="$p" "$b" worker-finish --run-id W-OLD --finished-at 1784044810 || return 1
  HARNESS_PROJECT_ROOT="$p" "$b" worker-init --run-id W-RUN --provider claude --started-at 1784044800 || return 1
  HARNESS_PROJECT_ROOT="$p" "$b" worker-update --run-id W-RUN --state running --updated-at 1784044860 || return 1
  HARNESS_PROJECT_ROOT="$p" "$b" worker-init --run-id W-NEW --provider claude --started-at 1784044850 || return 1
  HARNESS_PROJECT_ROOT="$p" "$b" worker-finish --run-id W-NEW --finished-at 1784044860 || return 1
  printf 'garbage\n' > "$w/W-BAD.env"
  HARNESS_PROJECT_ROOT="$p" "$b" worker-gc --now 1784044871 || return 1
  [ ! -e "$w/W-OLD.env" ] || return 1   # done, age 61s → 제거
  [ -e "$w/W-RUN.env" ] || return 1     # running → 유지
  [ -e "$w/W-NEW.env" ] || return 1     # done, age 11s → 유지
  [ -e "$w/W-BAD.env" ] || return 1     # 손상 → 진단용 유지
}
t "live-status(worker): gc는 오래된 done만 제거" 0 live_status_worker_gc

# --- TUI-P2: Codex 주간 한도·크레딧 생산자 ---
CSP="$ROOT/scripts/codex-status-poller.sh"
make_fake_codex_app_server() {
  target="$1"
  cat > "$target" <<'FAKEAPP'
#!/usr/bin/env bash
while IFS= read -r line; do
  case "$line" in
    *'"id":1'*)
      printf '{"id":1,"result":{"userAgent":"test"}}\n'
      ;;
    *'"id":2'*)
      if [ "${FAKE_LAYOUT:-primary}" = secondary ]; then
        printf '{"id":2,"result":{"rateLimitsByLimitId":{"codex":{"primary":{"usedPercent":50,"windowDurationMins":300,"resetsAt":1784200000},"secondary":{"usedPercent":35,"windowDurationMins":10080,"resetsAt":1784780177},"credits":{"hasCredits":false,"unlimited":false,"balance":"0"}}}}}\n'
      else
        printf '{"id":2,"result":{"rateLimitsByLimitId":{"codex":{"primary":{"usedPercent":%s,"windowDurationMins":10080,"resetsAt":1784780177},"secondary":null,"credits":{"hasCredits":true,"unlimited":false,"balance":"%s"}}}}}\n' "${FAKE_USED:-81}" "${FAKE_BALANCE:-2190.0125}"
      fi
      ;;
  esac
done
FAKEAPP
  chmod +x "$target"
}

codex_status_primary_week_and_credit_delta() {
  p="$TMP/codex-status-primary"
  make_live_project "$p"
  make_fake_codex_app_server "$p/fake-app-server"
  HARNESS_CODEX_APP_SERVER_CMD="$p/fake-app-server" FAKE_USED=81 FAKE_BALANCE=2190.0125 \
    "$CSP" "$p" 0 || return 1
  f="$p/.harness/live-status.env"
  grep -Fx 'HARNESS_WEEKLY_REMAINING_PCT=19' "$f" >/dev/null || return 1
  grep -Fx 'HARNESS_WEEKLY_RESETS_AT=1784780177' "$f" >/dev/null || return 1
  grep -Fx 'HARNESS_CODEX_CREDITS_BALANCE=2190.0125' "$f" >/dev/null || return 1
  grep -Fx 'HARNESS_CODEX_CREDITS_DELTA=?' "$f" >/dev/null || return 1
  grep -Fx 'HARNESS_CODEX_CREDITS_AVAILABLE=true' "$f" >/dev/null || return 1
  grep -Fx 'HARNESS_CODEX_BILLING_ROUTE=weekly' "$f" >/dev/null || return 1
  HARNESS_CODEX_APP_SERVER_CMD="$p/fake-app-server" FAKE_USED=100 FAKE_BALANCE=2189.5000 \
    "$CSP" "$p" 0 || return 1
  grep -Fx 'HARNESS_WEEKLY_REMAINING_PCT=0' "$f" >/dev/null || return 1
  grep -Fx 'HARNESS_CODEX_CREDITS_BALANCE=2189.5000' "$f" >/dev/null || return 1
  grep -Fx 'HARNESS_CODEX_CREDITS_DELTA=-0.5125' "$f" >/dev/null || return 1
  grep -Fx 'HARNESS_CODEX_BILLING_ROUTE=credits' "$f" >/dev/null
}
t "codex-status: primary 7일 창과 크레딧 증감·route를 기록" 0 codex_status_primary_week_and_credit_delta

codex_status_reads_current_thread_context() {
  p="$TMP/codex-status-context"
  make_live_project "$p"
  make_fake_codex_app_server "$p/fake-app-server"
  session="$p/codex-home/sessions/2026/07/16/rollout-context-thread.jsonl"
  mkdir -p "$(dirname "$session")"
  printf '%s\n' \
    '{"type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":197171,"total_tokens":197692},"model_context_window":258400}}}' \
    > "$session"
  CODEX_HOME="$p/codex-home" CODEX_THREAD_ID=context-thread \
    HARNESS_CODEX_APP_SERVER_CMD="$p/fake-app-server" "$CSP" "$p" 0 || return 1
  grep -Fx 'HARNESS_CONTEXT_REMAINING_PCT=24' "$p/.harness/live-status.env" >/dev/null
}
t "codex-status: 현재 thread의 토큰 기록으로 context left를 계산" 0 codex_status_reads_current_thread_context

codex_status_secondary_week() {
  p="$TMP/codex-status-secondary"
  make_live_project "$p"
  make_fake_codex_app_server "$p/fake-app-server"
  HARNESS_CODEX_APP_SERVER_CMD="$p/fake-app-server" FAKE_LAYOUT=secondary \
    "$CSP" "$p" 0 || return 1
  f="$p/.harness/live-status.env"
  grep -Fx 'HARNESS_WEEKLY_REMAINING_PCT=65' "$f" >/dev/null || return 1
  grep -Fx 'HARNESS_CODEX_CREDITS_AVAILABLE=false' "$f" >/dev/null || return 1
  grep -Fx 'HARNESS_CODEX_BILLING_ROUTE=weekly' "$f" >/dev/null
}
t "codex-status: secondary 7일 창도 주간 한도로 선택" 0 codex_status_secondary_week

codex_status_source_tree_uses_template_writer() {
  p="$TMP/codex-status-source-tree"
  mkdir -p "$p/scripts" "$p/template/.harness/bin"
  cp "$CSP" "$p/scripts/codex-status-poller.sh" || return 1
  cp "$ROOT/template/.harness/bin/live-status" "$p/template/.harness/bin/live-status" || return 1
  chmod +x "$p/scripts/codex-status-poller.sh" "$p/template/.harness/bin/live-status"
  make_fake_codex_app_server "$p/fake-app-server"
  HARNESS_CODEX_APP_SERVER_CMD="$p/fake-app-server" FAKE_USED=81 FAKE_BALANCE=2190.0125 \
    "$p/scripts/codex-status-poller.sh" "$p" 0 || return 1
  grep -Fx 'HARNESS_WEEKLY_REMAINING_PCT=19' "$p/.harness/live-status.env" >/dev/null || return 1
  grep -Fx 'HARNESS_CODEX_CREDITS_BALANCE=2190.0125' "$p/.harness/live-status.env" >/dev/null
}
t "codex-status: 하네스 소스 tree는 template writer로 계정 상태를 게시" 0 codex_status_source_tree_uses_template_writer

codex_status_waits_for_initialize_response() {
  p="$TMP/codex-status-handshake"
  make_live_project "$p"
  mkdir -p "$p/fakebin"
  real_jq="$(command -v jq)"
  cat > "$p/fakebin/jq" <<'SH'
#!/bin/sh
"$REAL_JQ" "$@"
rc=$?
case "$*" in
  *'select(.id == 1)'*) [ "$rc" = 0 ] && : > "$INIT_OBSERVED" ;;
esac
exit "$rc"
SH
  cat > "$p/fake-app-server" <<'SH'
#!/bin/sh
initialized=no
while IFS= read -r line; do
  case "$line" in
    *'"id":1'*) printf '{"id":1,"result":{"userAgent":"test"}}\n' ;;
    *'"method":"initialized"'*) [ -e "$INIT_OBSERVED" ] && initialized=yes ;;
    *'"id":2'*)
      [ "$initialized" = yes ] || continue
      printf '{"id":2,"result":{"rateLimitsByLimitId":{"codex":{"primary":{"usedPercent":81,"windowDurationMins":10080,"resetsAt":1784780177},"secondary":null,"credits":{"hasCredits":true,"unlimited":false,"balance":"2190.0125"}}}}}\n'
      ;;
  esac
done
SH
  chmod +x "$p/fakebin/jq" "$p/fake-app-server"
  PATH="$p/fakebin:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin" REAL_JQ="$real_jq" \
    INIT_OBSERVED="$p/init-observed" HARNESS_CODEX_APP_SERVER_CMD="$p/fake-app-server" \
    "$CSP" "$p" 0 || return 1
  grep -Fx 'HARNESS_WEEKLY_REMAINING_PCT=19' "$p/.harness/live-status.env" >/dev/null
}
t "codex-status: initialize 응답 뒤에만 한도 요청을 보냄" 0 codex_status_waits_for_initialize_response

codex_status_waits_for_nonempty_delayed_responses() {
  p="$TMP/codex-status-delayed"
  make_live_project "$p"
  cat > "$p/fake-app-server" <<'SH'
#!/bin/sh
while IFS= read -r line; do
  case "$line" in
    *'"id":1'*) sleep 0.2; printf '{"id":1,"result":{"userAgent":"test"}}\n' ;;
    *'"id":2'*) sleep 0.2; printf '{"id":2,"result":{"rateLimitsByLimitId":{"codex":{"primary":{"usedPercent":81,"windowDurationMins":10080,"resetsAt":1784780177},"secondary":null,"credits":{"hasCredits":true,"unlimited":false,"balance":"2190.0125"}}}}}\n' ;;
  esac
done
SH
  chmod +x "$p/fake-app-server"
  HARNESS_CODEX_APP_SERVER_CMD="$p/fake-app-server" "$CSP" "$p" 0 || return 1
  grep -Fx 'HARNESS_WEEKLY_REMAINING_PCT=19' "$p/.harness/live-status.env" >/dev/null || return 1
  grep -Fx 'HARNESS_CODEX_CREDITS_BALANCE=2190.0125' "$p/.harness/live-status.env" >/dev/null
}
t "codex-status: 느린 빈 initialize·계정 응답을 성공으로 오인하지 않고 기다림" 0 \
  codex_status_waits_for_nonempty_delayed_responses

codex_status_keeps_input_open_until_rate_response() {
  awk '
    /account\/rateLimits\/read/ { request = NR }
    request && /select\(\.id == 2\)/ { response_wait = NR }
    response_wait && /exec 3>&-/ { close_input = NR; exit }
    END { exit !(request < response_wait && response_wait < close_input) }
  ' "$CSP"
}
t "codex-status: 한도 응답까지 app-server 입력을 열어 둠" 0 codex_status_keeps_input_open_until_rate_response

codex_status_retries_failures_before_normal_interval() {
  # shellcheck disable=SC2016 # 소스 원문 리터럴을 그대로 대조한다.
  grep -Fq 'RETRY_INTERVAL="${HARNESS_CODEX_RETRY_INTERVAL:-5}"' "$CSP" || return 1
  awk '
    /if poll_once; then/ { decision = NR }
    decision && /delay="\$INTERVAL"/ { normal = NR }
    normal && /delay="\$RETRY_INTERVAL"/ { retry = NR }
    END { exit !(decision < normal && normal < retry) }
  ' "$CSP"
}
t "codex-status: 실패는 5초 후 재시도하고 성공 후에만 정상 주기를 사용" 0 \
  codex_status_retries_failures_before_normal_interval

codex_status_malformed_is_unknown() {
  p="$TMP/codex-status-malformed"
  make_live_project "$p"
  printf '#!/bin/sh\nprintf "not-json\\n"\n' > "$p/fake-bad"
  chmod +x "$p/fake-bad"
  HARNESS_CODEX_APP_SERVER_CMD="$p/fake-bad" "$CSP" "$p" 0 || return 1
  f="$p/.harness/live-status.env"
  grep -Fx 'HARNESS_WEEKLY_REMAINING_PCT=?' "$f" >/dev/null || return 1
  grep -Fx 'HARNESS_WEEKLY_RESETS_AT=?' "$f" >/dev/null || return 1
  grep -Fx 'HARNESS_CODEX_CREDITS_BALANCE=?' "$f" >/dev/null || return 1
  grep -Fx 'HARNESS_CODEX_CREDITS_DELTA=?' "$f" >/dev/null || return 1
  grep -Fx 'HARNESS_CODEX_CREDITS_AVAILABLE=?' "$f" >/dev/null || return 1
  grep -Fx 'HARNESS_CODEX_BILLING_ROUTE=?' "$f" >/dev/null
}
t "codex-status: 잘못된 응답은 계정 필드를 ?로 내리고 성공 종료" 0 codex_status_malformed_is_unknown

LSH="$ROOT/template/.harness/bin/live-status-hook"
CSL="$ROOT/scripts/claude-statusline-tui.sh"
live_status_hook_scopes_model_updates() {
  p="$TMP/live-hook"
  make_live_project "$p"
  cp "$LSH" "$p/.harness/bin/live-status-hook" || return 1
  chmod +x "$p/.harness/bin/live-status-hook"
  (cd "$p" && git init -q) || return 1
  jq -nc --arg cwd "$p" '{cwd:$cwd, model:"gpt-test"}' | \
    HARNESS_PROJECT_ROOT="$p" "$p/.harness/bin/live-status-hook" codex || return 1
  grep -Fx 'HARNESS_ORCHESTRATOR_PROVIDER=codex' "$p/.harness/live-status.env" >/dev/null || return 1
  grep -Fx 'HARNESS_ORCHESTRATOR_MODEL_OBSERVED=gpt-test' "$p/.harness/live-status.env" >/dev/null || return 1
  HARNESS_PROJECT_ROOT="$p" "$p/.harness/bin/live-status" worker-init \
    --run-id W-HOOK --provider codex --started-at 1784044800 || return 1
  jq -nc --arg cwd "$p" '{cwd:$cwd, model:"gpt-worker"}' | \
    HARNESS_PROJECT_ROOT="$p" HARNESS_WORKER_RUN_ID=W-HOOK \
    "$p/.harness/bin/live-status-hook" codex || return 1
  grep -Fx 'HARNESS_WORKER_MODEL_OBSERVED=gpt-worker' "$p/.harness/live-workers/W-HOOK.env" >/dev/null || return 1
  grep -Fx 'HARNESS_ORCHESTRATOR_MODEL_OBSERVED=gpt-test' "$p/.harness/live-status.env" >/dev/null
}
t "live-status-hook: orchestrator와 worker 모델 갱신을 분리" 0 live_status_hook_scopes_model_updates

live_status_hook_is_best_effort() {
  p="$TMP/live-hook-fail"
  make_live_project "$p"
  cp "$LSH" "$p/.harness/bin/live-status-hook" || return 1
  chmod +x "$p/.harness/bin/live-status-hook"
  printf '#!/bin/sh\nexit 9\n' > "$p/.harness/bin/live-status"
  jq -nc --arg cwd "$p" '{cwd:$cwd, model:"gpt-test"}' | \
    HARNESS_PROJECT_ROOT="$p" "$p/.harness/bin/live-status-hook" codex
}
t "live-status-hook: writer 실패가 provider 입력을 막지 않음" 0 live_status_hook_is_best_effort
t "live-status-hook: 수동 unsupported provider는 거부" 2 bash -c \
  "printf '{}' | '$LSH' other"

live_status_hooks_are_independent() {
  for f in "$ROOT/template/.claude/settings.json" "$ROOT/template/.codex/hooks.json"; do
    for event in UserPromptSubmit Stop; do
      base=".hooks.${event}[0].hooks"
      expected=2
      [ "$event" = UserPromptSubmit ] && expected=3
      [ "$(yq -r "$base | length" "$f")" = "$expected" ] || return 1
      [ "$(yq -r "${base}[0].timeout" "$f")" = 30 ] || return 1
      [ "$(yq -r "${base}[1].timeout" "$f")" = 5 ] || return 1
      yq -r "${base}[0].command" "$f" | grep -Fq 'decision-hook' || return 1
      yq -r "${base}[1].command" "$f" | grep -Fq 'live-status-hook' || return 1
      yq -r "${base}[1].command" "$f" | grep -Fq '|| true' || return 1
      if [ "$event" = UserPromptSubmit ]; then
        [ "$(yq -r "${base}[2].timeout" "$f")" = 5 ] || return 1
        yq -r "${base}[2].command" "$f" | grep -Fq 'agent-harness-live-status' || return 1
        yq -r "${base}[2].command" "$f" | grep -Fq ' start ' || return 1
        yq -r "${base}[2].command" "$f" | grep -Fq '|| true' || return 1
      fi
    done
  done
}
t "live-status-hook: 결정 훅 뒤 독립 best-effort 훅으로 등록" 0 live_status_hooks_are_independent

live_status_prompt_hook_auto_starts_once_per_project() {
  p="$TMP/live-status-auto-open"
  home="$TMP/live-status-auto-home"
  mkdir -p "$p" "$home/.local/bin"
  (cd "$p" && git init -q) || return 1
  p="$(cd "$p" && pwd -P)"
  cat > "$home/.local/bin/agent-harness-live-status" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >> "$AUTO_STATUS_CALLS"
SH
  chmod +x "$home/.local/bin/agent-harness-live-status"
  codex_command="$(yq -r '.hooks.UserPromptSubmit[0].hooks[2].command' "$ROOT/template/.codex/hooks.json")" || return 1
  claude_command="$(yq -r '.hooks.UserPromptSubmit[0].hooks[2].command' "$ROOT/template/.claude/settings.json")" || return 1
  calls="$TMP/live-status-auto.calls"
  (cd "$p" && HOME="$home" AUTO_STATUS_CALLS="$calls" bash -c "$codex_command") || return 1
  HOME="$home" CLAUDE_PROJECT_DIR="$p" AUTO_STATUS_CALLS="$calls" bash -c "$claude_command" || return 1
  grep -Fxq "start $p codex" "$calls" || return 1
  grep -Fxq "start $p claude" "$calls" || return 1
  [ "$(wc -l < "$calls" | tr -d ' ')" = 2 ]
}
t "live-status prompt hook: Codex·Claude 세션은 status pane을 기본 시작" 0 live_status_prompt_hook_auto_starts_once_per_project

claude_statusline_updates_project() {
  p="$TMP/claude-statusline"
  make_live_project "$p"
  output="$(jq -nc --arg cwd "$p" '{workspace:{current_dir:$cwd},model:{display_name:"Claude Opus 4.6"},context_window:{used_percentage:28},rate_limits:{five_hour:{used_percentage:17},seven_day:{used_percentage:35}}}' | "$CSL")" || return 1
  [ -n "$output" ] || return 1
  f="$p/.harness/live-status.env"
  grep -Fx 'HARNESS_ORCHESTRATOR_PROVIDER=claude' "$f" >/dev/null || return 1
  grep -Fx 'HARNESS_ORCHESTRATOR_MODEL_OBSERVED=Claude Opus 4.6' "$f" >/dev/null || return 1
  grep -Fx 'HARNESS_CONTEXT_REMAINING_PCT=72' "$f" >/dev/null || return 1
  grep -Fx 'HARNESS_WEEKLY_REMAINING_PCT=65' "$f" >/dev/null
}
t "claude-statusline: 모델·컨텍스트·주간 상태를 best-effort 기록" 0 claude_statusline_updates_project

claude_statusline_without_runtime_only_prints() {
  p="$TMP/claude-statusline-none"
  mkdir -p "$p"
  output="$(jq -nc --arg cwd "$p" '{workspace:{current_dir:$cwd},model:{display_name:"Claude"},context_window:{used_percentage:10}}' | "$CSL")" || return 1
  [ -n "$output" ] && [ ! -e "$p/.harness/live-status.env" ]
}
t "claude-statusline: runtime 없는 디렉터리에서는 출력만 함" 0 claude_statusline_without_runtime_only_prints

worker_wrap_publishes_live_lifecycle() {
  p="$TMP/live-worker-wrap"
  make_live_project "$p"
  printf 'prompt\n' > "$p/prompt"
  HARNESS_PROJECT_ROOT="$p" "$p/.harness/bin/live-status" worker-init \
    --run-id W-WRAP --provider codex --started-at 1784044800 || return 1
  HARNESS_PROJECT_ROOT="$p" HARNESS_WORKER_RUN_ID=W-WRAP \
    "$ROOT/template/.harness/bin/worker-wrap" "$p/run.runs" W-WRAP "$p/run.log" "$p/prompt" -- sh -c true || return 1
  f="$p/.harness/live-workers/W-WRAP.env"
  grep -Fx 'HARNESS_WORKER_STATE=done' "$f" >/dev/null || return 1
  finished="$(awk -F= '$1 == "HARNESS_WORKER_FINISHED_AT" {print $2}' "$f")"
  [ -n "$finished" ] && grep -Fq "event: finished at:" "$p/run.runs"
}
t "worker-wrap: .runs와 live worker 완료를 함께 게시" 0 worker_wrap_publishes_live_lifecycle

# --- TUI-P4: 워크스페이스당 하단 status pane 하나 ---
LSP="$ROOT/scripts/live-status-pane.sh"
LSS="$ROOT/scripts/live-status-session.sh"
mkdir -p "$TMP/status-pane-bin"
cat > "$TMP/status-pane-bin/cmux" <<'STATUSCMUX'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STATUS_CMUX_LOG"
case "${1:-}" in
  ping) exit 0 ;;
  identify) printf '{"caller":{"workspace_ref":"workspace:5","surface_ref":"surface:70"}}\n' ;;
  read-screen) [ "${STATUS_CMUX_STALE:-0}" != 1 ] ;;
  new-split) printf 'OK surface:94 workspace:5\n' ;;
  list-panes) printf '* pane:7  [1 surface]\n' ;;
  list-pane-surfaces) printf '* surface:94  live-status-session\n' ;;
  resize-pane) exit 0 ;;
  send|send-key) exit 0 ;;
  *) exit 2 ;;
esac
STATUSCMUX
cat > "$TMP/status-pane-bin/codex" <<'STATUSCODEX'
#!/bin/sh
exit 0
STATUSCODEX
chmod +x "$TMP/status-pane-bin/cmux" "$TMP/status-pane-bin/codex"
STATUS_PANE_PATH="$TMP/status-pane-bin:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin"

status_pane_start_reuses_and_stops() {
  p="$TMP/status-pane-project"
  make_live_project "$p"
  log="$TMP/status-pane-calls"
  : > "$log"
  PATH="$STATUS_PANE_PATH" HARNESS_STATE_DIR="$TMP/status-pane-state" STATUS_CMUX_LOG="$log" CODEX_THREAD_ID=thread-test \
    "$LSP" start "$p" codex || return 1
  f="$p/.harness/live-status-pane.env"
  [ "$(stat -f '%Lp' "$f" 2>/dev/null || stat -c '%a' "$f")" = 600 ] || return 1
  grep -Fx 'HARNESS_STATUS_PANE_WORKSPACE=workspace:5' "$f" >/dev/null || return 1
  grep -Fx 'HARNESS_STATUS_PANE_SURFACE=surface:94' "$f" >/dev/null || return 1
  grep -Fx 'HARNESS_STATUS_PANE_CODEX_THREAD_ID=thread-test' "$f" >/dev/null || return 1
  [ "$(grep -c '^new-split down --workspace workspace:5$' "$log")" = 1 ] || return 1
  grep -F 'send --surface surface:94' "$log" | grep -Fq "$p" || return 1
  grep -F 'send --surface surface:94' "$log" | grep -Fq codex || return 1
  grep -F 'send --surface surface:94' "$log" | grep -Fq 'CODEX_THREAD_ID=thread-test' || return 1
  grep -F 'send --surface surface:94' "$log" \
    | grep -Fq "HARNESS_CODEX_BIN=$TMP/status-pane-bin/codex" || return 1
  PATH="$STATUS_PANE_PATH" HARNESS_STATE_DIR="$TMP/status-pane-state" STATUS_CMUX_LOG="$log" CODEX_THREAD_ID=thread-test \
    "$LSP" start "$p" codex || return 1
  [ "$(grep -c '^new-split down --workspace workspace:5$' "$log")" = 1 ] || return 1
  # 높이 확보는 새 split에서 한 번만 — 재사용에서는 다시 resize하지 않는다.
  [ "$(grep -c '^resize-pane --pane pane:7 --workspace workspace:5 -U --amount 100$' "$log")" = 1 ] || return 1
  # start·reuse는 active-project 포인터를 기록하고, stop은 자기 것일 때만 지운다.
  [ "$(head -1 "$TMP/status-pane-state/active-project")" = "$p" ] || return 1
  PATH="$STATUS_PANE_PATH" HARNESS_STATE_DIR="$TMP/status-pane-state" STATUS_CMUX_LOG="$log" "$LSP" stop "$p" || return 1
  [ ! -e "$TMP/status-pane-state/active-project" ] || return 1
  [ ! -e "$f" ] || return 1
  grep -Fq 'send-key --surface surface:94 ctrl-c' "$log"
}
t "live-status-pane: down split 하나를 재사용하고 기록된 surface만 종료" 0 status_pane_start_reuses_and_stops
# shellcheck disable=SC2016 # 소스 원문 리터럴을 그대로 대조한다.
t "live-status-pane: stop은 기록된 status surface를 직접 닫음" 0 \
  grep -Fq 'cmux close-surface --surface "$surface"' "$LSP"

status_pane_installed_symlink_uses_source_session() {
  p="$TMP/status-pane-installed-link"
  home="$TMP/status-pane-installed-home"
  make_live_project "$p"
  mkdir -p "$home/.local/bin"
  ln -s "$LSP" "$home/.local/bin/agent-harness-live-status"
  log="$TMP/status-pane-installed-link.calls"; : > "$log"
  PATH="$STATUS_PANE_PATH" HARNESS_STATE_DIR="$TMP/status-pane-state" STATUS_CMUX_LOG="$log" \
    "$home/.local/bin/agent-harness-live-status" start "$p" codex || return 1
  grep -F 'send --surface surface:94' "$log" \
    | grep -Fq "$ROOT/scripts/live-status-session.sh"
}
t "live-status-pane: 설치 symlink도 저장소의 session 실행기를 사용" 0 status_pane_installed_symlink_uses_source_session
t "repository: live status pane 기록은 Git에서 제외" 0 \
  git -C "$ROOT" check-ignore -q .harness/live-status-pane.env
t "repository: live status runtime은 Git에서 제외" 0 bash -c \
  "git -C '$ROOT' check-ignore -q .harness/live-status.env && git -C '$ROOT' check-ignore -q .harness/live-workers/W-01.env"

status_pane_replaces_stale() {
  p="$TMP/status-pane-stale"
  make_live_project "$p"
  mkdir -p "$p/.harness"
  cat > "$p/.harness/live-status-pane.env" <<'EOF'
HARNESS_STATUS_PANE_VERSION=1
HARNESS_STATUS_PANE_WORKSPACE=workspace:5
HARNESS_STATUS_PANE_SURFACE=surface:93
HARNESS_STATUS_PANE_STARTED_AT=1784044800
EOF
  log="$TMP/status-pane-stale-calls"; : > "$log"
  PATH="$STATUS_PANE_PATH" HARNESS_STATE_DIR="$TMP/status-pane-state" STATUS_CMUX_LOG="$log" STATUS_CMUX_STALE=1 \
    "$LSP" start "$p" claude || return 1
  grep -Fx 'HARNESS_STATUS_PANE_SURFACE=surface:94' "$p/.harness/live-status-pane.env" >/dev/null || return 1
  [ "$(grep -c '^new-split down --workspace workspace:5$' "$log")" = 1 ]
}
t "live-status-pane: stale surface는 down split 하나로 교체" 0 status_pane_replaces_stale

status_pane_replaces_previous_codex_thread() {
  p="$TMP/status-pane-thread-change"
  make_live_project "$p"
  log="$TMP/status-pane-thread-change.calls"; : > "$log"
  PATH="$STATUS_PANE_PATH" HARNESS_STATE_DIR="$TMP/status-pane-state" STATUS_CMUX_LOG="$log" CODEX_THREAD_ID=thread-old \
    "$LSP" start "$p" codex || return 1
  PATH="$STATUS_PANE_PATH" HARNESS_STATE_DIR="$TMP/status-pane-state" STATUS_CMUX_LOG="$log" CODEX_THREAD_ID=thread-new \
    "$LSP" start "$p" codex || return 1
  [ "$(grep -c '^new-split down --workspace workspace:5$' "$log")" = 2 ] || return 1
  grep -Fq 'close-surface --surface surface:94' "$log" || return 1
  grep -Fx 'HARNESS_STATUS_PANE_CODEX_THREAD_ID=thread-new' \
    "$p/.harness/live-status-pane.env" >/dev/null
}
t "live-status-pane: 새 Codex thread는 이전 status pane을 닫고 교체" 0 status_pane_replaces_previous_codex_thread

status_pane_without_cmux_is_unsupported() {
  p="$TMP/status-pane-none"
  make_live_project "$p"
  if PATH='/usr/bin:/bin' "$LSP" start "$p" codex >/dev/null 2>&1; then return 1; fi
  [ ! -e "$p/.harness/live-status-pane.env" ]
}
t "live-status-pane: cmux 없으면 프로젝트 기록 없이 unsupported" 0 status_pane_without_cmux_is_unsupported

status_session_failure_is_isolated() {
  p="$TMP/status-session-failure"
  make_live_project "$p"
  mkdir -p "$p/log/decisions"
  printf 'keep\n' > "$p/log/decisions/D.keep"
  printf 'keep\n' > "$p/log/T.keep.runs"
  printf 'keep\n' > "$p/log/T.keep.done"
  cp "$p/log/decisions/D.keep" "$p/decision.before"
  cp "$p/log/T.keep.runs" "$p/runs.before"
  cp "$p/log/T.keep.done" "$p/done.before"
  printf '#!/bin/sh\nexit 7\n' > "$p/fail-consumer"
  printf '#!/bin/sh\nexit 9\n' > "$p/fail-poller"
  chmod +x "$p/fail-consumer" "$p/fail-poller"
  set +e
  HARNESS_STATUS_TUI_BIN="$p/fail-consumer" HARNESS_CODEX_POLLER_BIN="$p/fail-poller" \
    "$LSS" "$p" codex >/dev/null 2>&1
  rc=$?
  set -e
  [ "$rc" = 7 ] || return 1
  cmp -s "$p/decision.before" "$p/log/decisions/D.keep" || return 1
  cmp -s "$p/runs.before" "$p/log/T.keep.runs" || return 1
  cmp -s "$p/done.before" "$p/log/T.keep.done"
}
t "live-status-session: consumer·poller 실패가 결정·실행 증거와 격리" 0 status_session_failure_is_isolated

# --- TUI-P5 lifecycle: checkpoint·status session이 로드맵을 best-effort 갱신 ---
checkpoint_refreshes_roadmap_after_commit() {
  p="$TMP/checkpoint-roadmap"
  mk_proj "$p"; fill_project "$p"
  cat > "$p/.harness/bin/live-roadmap" <<'SH'
#!/bin/sh
if [ -z "$(git -C "$HARNESS_PROJECT_ROOT" status --porcelain -- STATUS.md tasks.yaml log/HANDOFF.md)" ]; then
  clean=yes
else
  clean=no
fi
printf '%s|core_clean=%s\n' "$*" "$clean" >> "$ROADMAP_CALLS"
exit "${ROADMAP_EXIT:-0}"
SH
  chmod +x "$p/.harness/bin/live-roadmap"
  git -C "$p" add .harness/bin/live-roadmap
  git -C "$p" commit -qm fake-roadmap
  calls="$TMP/checkpoint-roadmap.calls"
  printf '\nfirst roadmap refresh\n' >> "$p/log/HANDOFF.md"
  ROADMAP_CALLS="$calls" "$p/.harness/bin/checkpoint" roadmap-first >/dev/null || return 1
  [ "$(wc -l < "$calls" | tr -d ' ')" = 1 ] || return 1
  grep -Eq '^publish --now [0-9]{1,12}\|core_clean=yes$' "$calls" || return 1
  printf '\nsecond roadmap refresh\n' >> "$p/log/HANDOFF.md"
  ROADMAP_CALLS="$calls" ROADMAP_EXIT=9 \
    "$p/.harness/bin/checkpoint" roadmap-failure >/dev/null || return 1
  [ "$(wc -l < "$calls" | tr -d ' ')" = 2 ] || return 1
  [ -z "$(git -C "$p" status --porcelain -- STATUS.md tasks.yaml log/HANDOFF.md)" ]
}
t "checkpoint: commit 후 로드맵을 갱신하고 갱신 실패는 commit을 막지 않음" 0 checkpoint_refreshes_roadmap_after_commit

status_session_refreshes_roadmap_in_existing_loop() {
  p="$TMP/status-session-roadmap"
  make_live_project "$p"
  calls="$TMP/status-session-roadmap.calls"
  worker_calls="$TMP/status-session-worker.calls"
  poller_calls="$TMP/status-session-poller.calls"
  ready="$TMP/status-session-roadmap.ready"
  mkdir -p "$p/fakebin"
  cat > "$p/.harness/bin/live-roadmap" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >> "$ROADMAP_CALLS"
count="$(wc -l < "$ROADMAP_CALLS" | tr -d ' ')"
[ "$count" -lt 2 ] || : > "$ROADMAP_READY"
exit "${ROADMAP_EXIT:-0}"
SH
  cat > "$p/.harness/bin/live-status" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >> "$WORKER_CALLS"
exit 0
SH
  cat > "$p/fake-consumer" <<'SH'
#!/bin/sh
i=0
while [ ! -e "$ROADMAP_READY" ] && [ "$i" -lt 100 ]; do
  /bin/sleep 0.01
  i=$((i + 1))
done
[ -e "$ROADMAP_READY" ] || exit 8
exit 7
SH
  cat > "$p/fake-poller" <<'SH'
#!/bin/sh
printf 'called\n' >> "$POLLER_CALLS"
exit 0
SH
  cat > "$p/fakebin/sleep" <<'SH'
#!/bin/sh
/bin/sleep 0.02
SH
  chmod +x "$p/.harness/bin/live-roadmap" "$p/.harness/bin/live-status" \
    "$p/fake-consumer" "$p/fake-poller" "$p/fakebin/sleep"
  set +e
  PATH="$p/fakebin:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin" \
    ROADMAP_CALLS="$calls" ROADMAP_READY="$ready" ROADMAP_EXIT=9 \
    WORKER_CALLS="$worker_calls" POLLER_CALLS="$poller_calls" \
    HARNESS_STATUS_INTERVAL=1 HARNESS_STATUS_TUI_BIN="$p/fake-consumer" \
    HARNESS_CODEX_POLLER_BIN="$p/fake-poller" "$LSS" "$p" codex >/dev/null 2>&1
  rc=$?
  set -e
  [ "$rc" = 7 ] || return 1
  [ "$(wc -l < "$calls" | tr -d ' ')" -ge 2 ] || return 1
  grep -Eq '^publish --now [0-9]{1,12}$' "$calls" || return 1
  [ "$(wc -l < "$worker_calls" | tr -d ' ')" -ge 2 ] || return 1
  grep -Eq '^worker-gc --now [0-9]{1,12}$' "$worker_calls" || return 1
  grep -Fxq called "$poller_calls"
}
t "live-status-session: 기존 GC loop에서 즉시·반복 갱신하고 publisher 실패를 격리" 0 status_session_refreshes_roadmap_in_existing_loop

status_session_source_tree_uses_template_producers() {
  p="$TMP/status-session-source-tree"
  mkdir -p "$p/scripts" "$p/template/.harness/bin"
  cp "$LSS" "$p/scripts/live-status-session.sh" || return 1
  calls="$TMP/status-session-source-tree.calls"
  ready="$TMP/status-session-source-tree.ready"
  cat > "$p/template/.harness/bin/live-roadmap" <<'SH'
#!/bin/sh
printf 'roadmap %s\n' "$*" >> "$SOURCE_TREE_CALLS"
: > "$SOURCE_TREE_READY"
SH
  cat > "$p/template/.harness/bin/live-status" <<'SH'
#!/bin/sh
printf 'status %s\n' "$*" >> "$SOURCE_TREE_CALLS"
SH
  cat > "$p/fake-consumer" <<'SH'
#!/bin/sh
i=0
while [ ! -e "$SOURCE_TREE_READY" ] && [ "$i" -lt 100 ]; do
  /bin/sleep 0.01
  i=$((i + 1))
done
[ -e "$SOURCE_TREE_READY" ] || exit 8
exit 7
SH
  chmod +x "$p/scripts/live-status-session.sh" "$p/template/.harness/bin/live-roadmap" \
    "$p/template/.harness/bin/live-status" "$p/fake-consumer"
  set +e
  SOURCE_TREE_CALLS="$calls" SOURCE_TREE_READY="$ready" HARNESS_STATUS_INTERVAL=1 \
    HARNESS_STATUS_TUI_BIN="$p/fake-consumer" \
    "$p/scripts/live-status-session.sh" "$p" claude >/dev/null 2>&1
  rc=$?
  set -e
  [ "$rc" = 7 ] || return 1
  grep -Eq '^roadmap publish --now [0-9]{1,12}$' "$calls" || return 1
  grep -Eq '^status worker-gc --now [0-9]{1,12}$' "$calls"
}
t "live-status-session: 하네스 소스 tree는 template producer로 계속 갱신" 0 status_session_source_tree_uses_template_producers

# --- TUI-P6: 배포·기존 프로젝트 이전·명시적 활성화 ---
for required_live_bin in live-status live-roadmap live-status-hook; do
  mk_proj "$TMP/scaffold-$required_live_bin"; fill_project "$TMP/scaffold-$required_live_bin"
  rm "$TMP/scaffold-$required_live_bin/.harness/bin/$required_live_bin"
  t "scaffold-check: $required_live_bin 없으면 FAIL" 1 bash -c \
    "cd '$TMP/scaffold-$required_live_bin' && bash '$SC'"
done

mk_proj "$TMP/scaffold-github-private"; fill_project "$TMP/scaffold-github-private"
rm "$TMP/scaffold-github-private/.harness/bin/github-private"
t "scaffold-check: github-private 없으면 FAIL" 1 bash -c \
  "cd '$TMP/scaffold-github-private' && bash '$SC'"

make_live_migration_project() {
  p="$1"
  mkdir -p "$p"
  cat > "$p/tasks.yaml" <<'YAML'
tasks:
  - {id: T1, name: Pending task, status: pending}
YAML
  printf 'existing-rule/\n' > "$p/.gitignore"
  (cd "$p" && git init -q && git config user.name harness-test \
    && git config user.email harness-test@example.invalid \
    && git add -A && git commit -qm init)
}

MLIVE="$ROOT/scripts/migrate-live-status.sh"
live_migration_dry_run_classifies_without_writes() {
  p="$TMP/live-migrate-dry"; make_live_migration_project "$p"
  before="$(git -C "$p" rev-parse HEAD):$(git -C "$p" status --porcelain)"
  out="$("$MLIVE" --dry-run "$p")" || return 1
  for rel in .harness/bin/live-status .harness/bin/live-roadmap \
    .harness/bin/live-status-hook .harness/bin/worker-wrap \
    .claude/settings.json .codex/hooks.json; do
    printf '%s\n' "$out" | grep -Eq "^ADD +$rel$" || return 1
  done
  printf '%s\n' "$out" | grep -Eq '^ADD +\.gitignore live-status rules$' || return 1
  after="$(git -C "$p" rev-parse HEAD):$(git -C "$p" status --porcelain)"
  [ "$before" = "$after" ] || return 1
  [ ! -e "$p/.harness" ] && [ ! -e "$p/.claude" ] && [ ! -e "$p/.codex" ]
}
t "live migration: dry-run은 전체 경로를 ADD로 분류하고 쓰지 않음" 0 live_migration_dry_run_classifies_without_writes

live_migration_apply_and_same() {
  p="$TMP/live-migrate-apply"; make_live_migration_project "$p"
  "$MLIVE" --apply "$p" >/dev/null || return 1
  for rel in .harness/bin/live-status .harness/bin/live-roadmap \
    .harness/bin/live-status-hook .harness/bin/worker-wrap; do
    [ -x "$p/$rel" ] || return 1
  done
  yq -e '.hooks.UserPromptSubmit and .hooks.Stop' "$p/.claude/settings.json" >/dev/null || return 1
  yq -e '.hooks.UserPromptSubmit and .hooks.Stop' "$p/.codex/hooks.json" >/dev/null || return 1
  for rule in '.harness/live-status.env' '.harness/live-status.env.tmp.*' \
    '.harness/live-workers/' '.harness/live-status-pane.env' \
    '.harness/live-roadmap.yaml' '.harness/live-roadmap.yaml.tmp.*'; do
    grep -Fxq "$rule" "$p/.gitignore" || return 1
  done
  [ ! -e "$p/.harness/live-status.env" ] || return 1
  [ ! -e "$p/.harness/live-roadmap.yaml" ] || return 1
  [ ! -e "$p/.harness/live-status-pane.env" ] || return 1
  [ ! -d "$p/.harness/live-workers" ] || return 1
  out="$("$MLIVE" --dry-run "$p")" || return 1
  [ "$(printf '%s\n' "$out" | grep -c '^SAME ')" = 7 ]
}
t "live migration: apply는 코드만 복사하고 재실행은 7개 SAME" 0 live_migration_apply_and_same

live_migration_conflict_is_all_or_nothing() {
  p="$TMP/live-migrate-conflict"; make_live_migration_project "$p"
  mkdir -p "$p/.harness/bin"
  printf 'local roadmap implementation\n' > "$p/.harness/bin/live-roadmap"
  git -C "$p" add .harness/bin/live-roadmap && git -C "$p" commit -qm conflict
  if "$MLIVE" --apply "$p" > "$TMP/live-migrate-conflict.out" 2>&1; then return 1; fi
  grep -Eq '^CONFLICT +\.harness/bin/live-roadmap$' "$TMP/live-migrate-conflict.out" || return 1
  [ ! -e "$p/.harness/bin/live-status" ] || return 1
  [ ! -e "$p/.harness/bin/live-status-hook" ] || return 1
  [ ! -e "$p/.claude/settings.json" ] || return 1
  [ ! -e "$p/.codex/hooks.json" ] || return 1
  grep -Fxq 'local roadmap implementation' "$p/.harness/bin/live-roadmap" || return 1
  [ -z "$(git -C "$p" status --porcelain)" ]
}
t "live migration: 충돌 하나면 전체 apply를 부작용 없이 중단" 0 live_migration_conflict_is_all_or_nothing

install_enable_live_status_is_explicit_and_backup_safe() {
  home="$TMP/install-live-home"
  mkdir -p "$home/.claude" "$home/cmux-harness-status/bin" "$TMP/install-live-bin"
  # CI처럼 cmux와 consumer가 없는 환경에서도 결정론적으로 돌도록 가짜를 둔다.
  printf '#!/bin/sh\nexit 0\n' > "$home/cmux-harness-status/bin/cmux-harness-status"
  chmod +x "$home/cmux-harness-status/bin/cmux-harness-status"
  printf '#!/bin/sh\nexit 0\n' > "$TMP/install-live-bin/cmux"
  chmod +x "$TMP/install-live-bin/cmux"
  cat > "$home/.claude/settings.json" <<'JSON'
{"keep":"unchanged","statusLine":{"type":"command","command":"old-status-command","refreshInterval":17}}
JSON
  out="$(HOME="$home" PATH="$TMP/install-live-bin:$PATH" bash "$ROOT/install.sh" --enable-live-status 2>&1)" \
    || return 1
  link="$home/.local/bin/cmux-harness-status"
  launcher="$home/.local/bin/agent-harness-live-status"
  [ -L "$link" ] || return 1
  [ -x "$(readlink "$link")" ] || return 1
  [ -L "$launcher" ] || return 1
  [ "$(readlink "$launcher")" = "$ROOT/scripts/live-status-pane.sh" ] || return 1
  status_tui="$home/.local/bin/status-tui"
  [ -L "$status_tui" ] || return 1
  [ "$(readlink "$status_tui")" = "$ROOT/scripts/status-tui.sh" ] || return 1
  [ "$(find "$home/.claude" -name 'settings.json.bak.*' | wc -l | tr -d ' ')" = 1 ] || return 1
  [ "$(yq -r '.keep' "$home/.claude/settings.json")" = unchanged ] || return 1
  [ "$(yq -r '.statusLine.type' "$home/.claude/settings.json")" = command ] || return 1
  [ "$(yq -r '.statusLine.refreshInterval' "$home/.claude/settings.json")" = 17 ] || return 1
  [ "$(yq -r '.statusLine.command' "$home/.claude/settings.json")" = "$ROOT/scripts/claude-statusline-tui.sh" ] || return 1
  printf '%s\n' "$out" | grep -Fq 'old-status-command' || return 1
  printf '%s\n' "$out" | grep -Fq "$ROOT/scripts/claude-statusline-tui.sh"
}
t "install --enable-live-status: consumer link·Claude 명령 backup·old/new 공개" 0 install_enable_live_status_is_explicit_and_backup_safe

claude_hook_starts_pane_only_for_harness_projects() {
  home="$TMP/claude-hook-home"
  proj="$TMP/claude-hook-proj"; plain="$TMP/claude-hook-plain"
  mkdir -p "$home/.local/bin" "$proj/.harness" "$plain"
  log="$TMP/claude-hook-calls"; : > "$log"
  cat > "$home/.local/bin/agent-harness-live-status" <<SH
#!/bin/sh
printf '%s\n' "\$*" >> "$log"
SH
  chmod +x "$home/.local/bin/agent-harness-live-status"
  # 하네스 프로젝트(.harness 존재): pane 시작을 요청한다.
  printf '{"cwd":"%s"}' "$proj" \
    | HOME="$home" bash "$ROOT/scripts/claude-live-status-hook.sh" || return 1
  grep -Fq "start $proj claude" "$log" || return 1
  # 일반 디렉터리: 아무것도 하지 않고 성공 종료한다.
  printf '{"cwd":"%s"}' "$plain" \
    | HOME="$home" bash "$ROOT/scripts/claude-live-status-hook.sh" || return 1
  [ "$(wc -l < "$log" | tr -d ' ')" = 1 ]
}
t "claude hook: 하네스 프로젝트에서만 status pane을 시작" 0 \
  claude_hook_starts_pane_only_for_harness_projects

install_enable_live_status_registers_claude_hook_once() {
  home="$TMP/install-live-hook-home"
  bin="$TMP/install-live-hook-bin"
  mkdir -p "$home/.claude" "$home/cmux-harness-status/bin" "$bin"
  printf '#!/bin/sh\nexit 0\n' > "$home/cmux-harness-status/bin/cmux-harness-status"
  chmod +x "$home/cmux-harness-status/bin/cmux-harness-status"
  printf '#!/bin/sh\nexit 0\n' > "$bin/cmux"
  chmod +x "$bin/cmux"
  printf '{"hooks":{"UserPromptSubmit":[{"hooks":[{"type":"command","command":"keep-hook"}]}]}}\n' \
    > "$home/.claude/settings.json"
  HOME="$home" PATH="$bin:$PATH" bash "$ROOT/install.sh" --enable-live-status >/dev/null 2>&1 || return 1
  HOME="$home" PATH="$bin:$PATH" bash "$ROOT/install.sh" --enable-live-status >/dev/null 2>&1 || return 1
  s="$home/.claude/settings.json"
  hook="$ROOT/scripts/claude-live-status-hook.sh"
  # 기존 훅은 보존되고, 우리 훅은 두 번 설치해도 한 번만 등록된다.
  [ "$(jq -r '[.hooks.UserPromptSubmit[]?.hooks[]?.command] | index("keep-hook") != null' "$s")" = true ] || return 1
  [ "$(jq --arg h "$hook" -r '[.hooks.UserPromptSubmit[]?.hooks[]?.command | select(. == $h)] | length' "$s")" = 1 ]
}
t "install --enable-live-status: Claude UserPromptSubmit 훅을 멱등 등록" 0 \
  install_enable_live_status_registers_claude_hook_once

install_refuses_unrelated_status_launcher() {
  home="$TMP/install-live-launcher-conflict"
  mkdir -p "$home/.local/bin" "$home/.claude"
  printf '#!/bin/sh\nexit 0\n' > "$home/.local/bin/agent-harness-live-status"
  chmod +x "$home/.local/bin/agent-harness-live-status"
  printf '{"statusLine":{"type":"command","command":"keep-me"}}\n' > "$home/.claude/settings.json"
  cp "$home/.claude/settings.json" "$home/settings.before"
  if HOME="$home" bash "$ROOT/install.sh" --enable-live-status >/dev/null 2>&1; then return 1; fi
  cmp -s "$home/settings.before" "$home/.claude/settings.json" || return 1
  [ ! -e "$home/.local/bin/cmux-harness-status" ] || return 1
  grep -Fq 'exit 0' "$home/.local/bin/agent-harness-live-status"
}
t "install --enable-live-status: 무관한 status launcher를 덮어쓰지 않음" 0 install_refuses_unrelated_status_launcher

install_refuses_unrelated_consumer_binary() {
  home="$TMP/install-live-conflict"
  mkdir -p "$home/.local/bin" "$home/.claude"
  printf '#!/bin/sh\nexit 0\n' > "$home/.local/bin/cmux-harness-status"
  chmod +x "$home/.local/bin/cmux-harness-status"
  printf '{"statusLine":{"type":"command","command":"keep-me"}}\n' > "$home/.claude/settings.json"
  cp "$home/.claude/settings.json" "$home/settings.before"
  if HOME="$home" bash "$ROOT/install.sh" --enable-live-status >/dev/null 2>&1; then return 1; fi
  cmp -s "$home/settings.before" "$home/.claude/settings.json" || return 1
  grep -Fq 'exit 0' "$home/.local/bin/cmux-harness-status"
}
t "install --enable-live-status: 무관한 executable은 덮어쓰지 않음" 0 install_refuses_unrelated_consumer_binary

t "live lifecycle docs: start·phase·worker·close와 pane/monitor 규칙을 실행 계약으로 고정" 0 bash -c \
  "grep -Fq 'live-roadmap publish' '$ROOT/skills/harness/SKILL.md' \
   && grep -Fq 'agent-harness-live-status start' '$ROOT/skills/harness/SKILL.md' \
   && grep -Fq '매 하네스 세션' '$ROOT/skills/harness/SKILL.md' \
   && grep -Fq 'orchestrator-update' '$ROOT/skills/harness/SKILL.md' \
   && grep -Fq 'worker-update' '$ROOT/skills/harness/SKILL.md' \
   && grep -Fq 'worker-finish' '$ROOT/skills/harness/SKILL.md' \
   && grep -Fq 'agent-harness-live-status stop' '$ROOT/skills/harness/SKILL.md' \
   && grep -Fq 'first worker: split right' '$ROOT/skills/harness/SKILL.md' \
   && grep -Fq 'later worker: split down' '$ROOT/skills/harness/SKILL.md' \
   && grep -Fq 'cmux read-screen' '$ROOT/skills/harness/SKILL.md' \
   && grep -Fq 'ps를 사용하지 않는다' '$ROOT/skills/harness/SKILL.md' \
   && grep -Fq 'agent-harness-live-status' '$ROOT/template/HARNESS.md'"
ti "live lifecycle docs: working 저장소 README는 자동 시작·migration 경로를 안내" 0 bash -c \
  "grep -Fq '매 하네스 세션' '$ROOT/README.md' \
   && grep -Fq 'migrate-live-status.sh --dry-run' '$ROOT/README.md'"

# --- TUI-P5: 전체 Queue 1–9 로드맵 스냅샷 ---
make_roadmap_project() {
  p="$1"
  mkdir -p "$p/.harness/bin"
  cp "$ROOT/template/.harness/bin/live-roadmap" "$p/.harness/bin/live-roadmap" || return 1
  chmod +x "$p/.harness/bin/live-roadmap"
}

write_valid_roadmap() {
  p="$1"
  cat > "$p/ROADMAP.yaml" <<'YAML'
version: 1
project:
  id: demo
  name: Demo Project
  purpose: Build a readable harness dashboard
items:
  - id: Q1
    title: Foundation
    state: done
    progress_pct: 100
    children: []
  - id: Q2
    title: Status dashboard
    state: running
    progress_pct: 50
    ignored_private_note: never publish this
    children:
      - {title: Producer, state: done}
      - {title: Readability, state: running}
YAML
}

live_roadmap_publishes_private_normalized_snapshot() {
  p="$TMP/live-roadmap-valid"
  make_roadmap_project "$p" || return 1
  write_valid_roadmap "$p"
  cp "$p/ROADMAP.yaml" "$p/ROADMAP.before"
  HARNESS_PROJECT_ROOT="$p" "$p/.harness/bin/live-roadmap" publish --now 1784192616 || return 1
  f="$p/.harness/live-roadmap.yaml"
  [ "$(stat -f '%Lp' "$p/.harness" 2>/dev/null || stat -c '%a' "$p/.harness")" = 700 ] || return 1
  [ "$(stat -f '%Lp' "$f" 2>/dev/null || stat -c '%a' "$f")" = 600 ] || return 1
  [ "$(yq -r '.version' "$f")" = 1 ] || return 1
  [ "$(yq -r '.project.id' "$f")" = demo ] || return 1
  [ "$(yq -r '.project.name' "$f")" = 'Demo Project' ] || return 1
  [ "$(yq -r '.project.purpose' "$f")" = 'Build a readable harness dashboard' ] || return 1
  [ "$(yq -r '.captured_at' "$f")" = 1784192616 ] || return 1
  [ "$(yq -r '.items | length' "$f")" = 2 ] || return 1
  [ "$(yq -r '.items[1].id' "$f")" = Q2 ] || return 1
  [ "$(yq -r '.items[1].progress_pct' "$f")" = 50 ] || return 1
  [ "$(yq -r '.items[1].children | length' "$f")" = 2 ] || return 1
  [ "$(yq -r '.items[1].children[1].title' "$f")" = Readability ] || return 1
  [ "$(yq -r '.items[1].children[1].state' "$f")" = running ] || return 1
  [ "$(yq -r '.items[1] | has("ignored_private_note")' "$f")" = false ] || return 1
  [ -z "$(find "$p/.harness" -name 'live-roadmap.yaml.tmp.*' -print -quit)" ] || return 1
  cmp -s "$p/ROADMAP.before" "$p/ROADMAP.yaml"
}
t "live-roadmap: 원본을 보존하고 비공개 스냅샷을 원자적 게시" 0 live_roadmap_publishes_private_normalized_snapshot

roadmap_rejection_fixture() {
  p="$1"
  make_roadmap_project "$p" || return 1
  write_valid_roadmap "$p"
}

live_roadmap_rejects_version_2() {
  p="$TMP/live-roadmap-version"; roadmap_rejection_fixture "$p" || return 1
  yq -i '.version = 2' "$p/ROADMAP.yaml"
  HARNESS_PROJECT_ROOT="$p" "$p/.harness/bin/live-roadmap" publish --now 1784192616
}
t "live-roadmap: 지원하지 않는 version 2 거부" 2 live_roadmap_rejects_version_2

live_roadmap_rejects_duplicate_ids() {
  p="$TMP/live-roadmap-duplicate"; roadmap_rejection_fixture "$p" || return 1
  yq -i '.items[1].id = "Q1"' "$p/ROADMAP.yaml"
  HARNESS_PROJECT_ROOT="$p" "$p/.harness/bin/live-roadmap" publish --now 1784192616
}
t "live-roadmap: 중복 Queue ID 거부" 2 live_roadmap_rejects_duplicate_ids

live_roadmap_rejects_100_items() {
  p="$TMP/live-roadmap-many"; roadmap_rejection_fixture "$p" || return 1
  cat > "$p/ROADMAP.yaml" <<'YAML'
version: 1
project: {id: demo, name: Demo Project, purpose: limit fixture}
items:
YAML
  i=0
  while [ "$i" -lt 100 ]; do
    printf '  - {id: Q%s, title: Queue %s, state: pending, progress_pct: 0, children: []}\n' "$i" "$i" >> "$p/ROADMAP.yaml"
    i=$((i + 1))
  done
  HARNESS_PROJECT_ROOT="$p" "$p/.harness/bin/live-roadmap" publish --now 1784192616
}
t "live-roadmap: 상위 항목 100개 거부" 2 live_roadmap_rejects_100_items

live_roadmap_rejects_seven_children() {
  p="$TMP/live-roadmap-children"; roadmap_rejection_fixture "$p" || return 1
  cat > "$p/ROADMAP.yaml" <<'YAML'
version: 1
project: {id: demo, name: Demo Project, purpose: limit fixture}
items:
  - id: Q1
    title: Parent
    state: running
    progress_pct: 50
    children:
YAML
  i=0
  while [ "$i" -lt 7 ]; do
    printf '      - {title: Child %s, state: pending}\n' "$i" >> "$p/ROADMAP.yaml"
    i=$((i + 1))
  done
  HARNESS_PROJECT_ROOT="$p" "$p/.harness/bin/live-roadmap" publish --now 1784192616
}
t "live-roadmap: 하위 항목 7개 거부" 2 live_roadmap_rejects_seven_children

live_roadmap_rejects_bad_progress() {
  p="$TMP/live-roadmap-progress"; roadmap_rejection_fixture "$p" || return 1
  yq -i '.items[1].progress_pct = 101' "$p/ROADMAP.yaml"
  HARNESS_PROJECT_ROOT="$p" "$p/.harness/bin/live-roadmap" publish --now 1784192616
}
t "live-roadmap: 진행률 101 거부" 2 live_roadmap_rejects_bad_progress

live_roadmap_rejects_newline_text() {
  p="$TMP/live-roadmap-newline"; roadmap_rejection_fixture "$p" || return 1
  yq -i '.items[0].title = "line1\nline2"' "$p/ROADMAP.yaml"
  HARNESS_PROJECT_ROOT="$p" "$p/.harness/bin/live-roadmap" publish --now 1784192616
}
t "live-roadmap: 줄바꿈 텍스트 거부" 2 live_roadmap_rejects_newline_text

live_roadmap_rejects_unsafe_id() {
  p="$TMP/live-roadmap-id"; roadmap_rejection_fixture "$p" || return 1
  yq -i '.items[0].id = "bad/id"' "$p/ROADMAP.yaml"
  HARNESS_PROJECT_ROOT="$p" "$p/.harness/bin/live-roadmap" publish --now 1784192616
}
t "live-roadmap: 경로 문자가 든 ID 거부" 2 live_roadmap_rejects_unsafe_id

live_roadmap_rejects_unknown_state() {
  p="$TMP/live-roadmap-state"; roadmap_rejection_fixture "$p" || return 1
  yq -i '.items[0].state = "mystery"' "$p/ROADMAP.yaml"
  HARNESS_PROJECT_ROOT="$p" "$p/.harness/bin/live-roadmap" publish --now 1784192616
}
t "live-roadmap: 알 수 없는 상태 거부" 2 live_roadmap_rejects_unknown_state

live_roadmap_rejects_unknown_flag() {
  p="$TMP/live-roadmap-flag"; roadmap_rejection_fixture "$p" || return 1
  HARNESS_PROJECT_ROOT="$p" "$p/.harness/bin/live-roadmap" publish --bogus x
}
t "live-roadmap: 알 수 없는 플래그 거부" 2 live_roadmap_rejects_unknown_flag

live_roadmap_requires_yq() {
  p="$TMP/live-roadmap-yq"; roadmap_rejection_fixture "$p" || return 1
  PATH='/usr/bin:/bin' HARNESS_PROJECT_ROOT="$p" "$p/.harness/bin/live-roadmap" publish --now 1784192616
}
t "live-roadmap: yq가 없으면 명확히 거부" 2 live_roadmap_requires_yq

live_roadmap_maps_tasks_fallback() {
  p="$TMP/live-roadmap-fallback"
  make_roadmap_project "$p" || return 1
  cat > "$p/tasks.yaml" <<'YAML'
tasks:
  - {id: T1, name: Finished task, status: verified}
  - {id: T2, name: Active task, status: running}
  - {id: T3, name: Failed task, status: failed}
  - {id: T4, name: Waiting task, status: hold}
YAML
  printf 'HARNESS_PROJECT_ID=fallback-demo\n' > "$p/.harness/live-status.env"
  HARNESS_PROJECT_ROOT="$p" "$p/.harness/bin/live-roadmap" publish --now 1784192616 || return 1
  f="$p/.harness/live-roadmap.yaml"
  [ "$(yq -r '.project.id' "$f")" = fallback-demo ] || return 1
  [ "$(yq -r '.project.purpose' "$f")" = '?' ] || return 1
  [ "$(yq -r '.items[0].state' "$f")" = "done" ] || return 1
  [ "$(yq -r '.items[0].progress_pct' "$f")" = 100 ] || return 1
  [ "$(yq -r '.items[1].state' "$f")" = running ] || return 1
  [ "$(yq -r '.items[1].progress_pct' "$f")" = '?' ] || return 1
  [ "$(yq -r '.items[2].state' "$f")" = blocked ] || return 1
  [ "$(yq -r '.items[3].state' "$f")" = pending ] || return 1
  [ "$(yq -r '.items[3].progress_pct' "$f")" = 0 ]
}
t "live-roadmap: ROADMAP이 없으면 tasks 상태를 안전한 로드맵으로 변환" 0 live_roadmap_maps_tasks_fallback

t "github-private: focused private first-push contract" 0 bash "$ROOT/tests/github-private-tests.sh"

echo; echo "결과: PASS=$pass FAIL=$fail"
[ "$fail" -eq 0 ]
