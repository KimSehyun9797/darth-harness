#!/usr/bin/env bash
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CMD="$ROOT/template/.harness/bin/github-private"
REAL_PATH="$PATH"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/github-private-tests.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
pass=0
fail=0

ok() { pass=$((pass + 1)); printf 'ok - %s\n' "$1"; }
not_ok() { fail=$((fail + 1)); printf 'not ok - %s\n' "$1"; }
run_test() {
  name="$1"
  shift
  if [ ! -x "$CMD" ]; then
    not_ok "$name (command missing)"
    return
  fi
  if ( "$@" ); then ok "$name"; else not_ok "$name"; fi
}

mkdir -p "$TMP/fake-bin"
cat > "$TMP/fake-bin/gh" <<'SH'
#!/bin/sh
set -u
state="${GH_STATE_DIR:?}"
mkdir -p "$state"
printf '%s\n' "$*" >> "$state/calls"

if [ "$1 $2" = "auth status" ]; then
  exit 0
fi
if [ "$1 $2" = "api user" ]; then
  printf '%s\n' TestOwner
  exit 0
fi
if [ "$1 $2" = "config get" ]; then
  printf '%s\n' https
  exit 0
fi
if [ "$1 $2" = "repo view" ]; then
  [ -f "$state/repository" ] || exit 1
  repo="$(cat "$state/repository")"
  visibility="$(cat "$state/visibility")"
  printf '%s\n' "$visibility" "file://$state/remote.git" "file://$state/remote.git"
  exit 0
fi
if [ "$1 $2" = "repo create" ]; then
  repo="$3"
  shift 3
  [ "$#" -eq 1 ] && [ "$1" = --private ] || exit 42
  [ ! -e "$state/create-fails" ] || exit 43
  printf '%s\n' "$repo" > "$state/repository"
  printf '%s\n' PRIVATE > "$state/visibility"
  git init -q --bare "$state/remote.git"
  if [ -e "$state/fail-push-once" ]; then
    cat > "$state/remote.git/hooks/pre-receive" <<EOF
#!/bin/sh
rm -f "$state/remote.git/hooks/pre-receive"
exit 1
EOF
    chmod +x "$state/remote.git/hooks/pre-receive"
  fi
  exit 0
fi
exit 44
SH
chmod +x "$TMP/fake-bin/gh"

make_project() {
  p="$1"
  mkdir -p "$p/dir"
  printf '# demo\n' > "$p/README.md"
  printf 'content\n' > "$p/dir/file with space.txt"
  (
    cd "$p" || exit
    git init -q
    git config user.name harness-test
    git config user.email harness-test@example.invalid
    git checkout -qb main
    git add .
    git commit -qm initial
  )
}

run_cmd() {
  p="$1"
  state="$2"
  shift 2
  (
    cd "$p" || exit
    GH_STATE_DIR="$state" PATH="$TMP/fake-bin:$REAL_PATH" "$CMD" "$@"
  )
}

confirmation_from() {
  printf '%s\n' "$1" | awk -F= '$1 == "CONFIRM_SHA256" {print $2; exit}'
}

plan_defaults_private_and_lists_exact_tree() {
  p="$TMP/default-project"; state="$TMP/default-state"
  make_project "$p"
  out="$(run_cmd "$p" "$state" plan)" || return 1
  printf '%s\n' "$out" | grep -Fxq 'REPOSITORY=TestOwner/default-project' || return 1
  printf '%s\n' "$out" | grep -Fxq 'VISIBILITY=PRIVATE' || return 1
  printf '%s\n' "$out" | grep -Fxq 'REMOTE_STATE=absent' || return 1
  printf '%s\n' "$out" | grep -Fxq 'FILES=2' || return 1
  printf '%s\n' "$out" | grep -Fxq '  - README.md' || return 1
  printf '%s\n' "$out" | grep -Fxq '  - dir/file\ with\ space.txt' || return 1
  confirmation_from "$out" | grep -Eq '^[0-9a-f]{64}$'
}
run_test 'plan defaults to private owner/project and lists the exact committed tree' plan_defaults_private_and_lists_exact_tree

explicit_repository_override_is_exact() {
  p="$TMP/override-project"; state="$TMP/override-state"
  make_project "$p"
  out="$(run_cmd "$p" "$state" plan --repo ExampleOrg/chosen-name)" || return 1
  printf '%s\n' "$out" | grep -Fxq 'REPOSITORY=ExampleOrg/chosen-name'
}
run_test 'plan accepts only an explicit OWNER/NAME override' explicit_repository_override_is_exact

dirty_tree_stops_before_remote_calls() {
  p="$TMP/dirty-project"; state="$TMP/dirty-state"
  make_project "$p"
  printf 'dirty\n' >> "$p/README.md"
  ! run_cmd "$p" "$state" plan >/dev/null 2>&1 || return 1
  [ ! -s "$state/calls" ]
}
run_test 'dirty tracked or untracked state stops before GitHub calls' dirty_tree_stops_before_remote_calls

wrong_confirmation_stops_before_create() {
  p="$TMP/wrong-confirm-project"; state="$TMP/wrong-confirm-state"
  make_project "$p"
  ! run_cmd "$p" "$state" apply --confirm 0000000000000000000000000000000000000000000000000000000000000000 >/dev/null 2>&1 || return 1
  ! grep -Fq 'repo create' "$state/calls"
}
run_test 'a mismatched plan digest stops before repository creation' wrong_confirmation_stops_before_create

conflicting_origin_stops_before_create() {
  p="$TMP/conflict-project"; state="$TMP/conflict-state"
  make_project "$p"
  git -C "$p" remote add origin https://example.invalid/not-the-target.git
  ! run_cmd "$p" "$state" plan >/dev/null 2>&1 || return 1
  ! grep -Fq 'repo create' "$state/calls"
}
run_test 'a conflicting origin stops before repository creation' conflicting_origin_stops_before_create

existing_non_private_repository_is_rejected() {
  p="$TMP/public-project"; state="$TMP/public-state"
  make_project "$p"
  mkdir -p "$state"
  printf 'TestOwner/public-project\n' > "$state/repository"
  printf 'PUBLIC\n' > "$state/visibility"
  git init -q --bare "$state/remote.git"
  ! run_cmd "$p" "$state" plan >/dev/null 2>&1 || return 1
  ! grep -Fq 'repo create' "$state/calls"
}
run_test 'an existing non-private repository is rejected before push' existing_non_private_repository_is_rejected

private_create_connects_and_pushes_exact_head() {
  p="$TMP/success-project"; state="$TMP/success-state"
  make_project "$p"
  plan="$(run_cmd "$p" "$state" plan)" || return 1
  confirm="$(confirmation_from "$plan")"
  run_cmd "$p" "$state" apply --confirm "$confirm" >/dev/null || return 1
  grep -Fxq 'repo create TestOwner/success-project --private' "$state/calls" || return 1
  ! grep -Fq -- '--public' "$state/calls" || return 1
  [ "$(git -C "$p" remote get-url origin)" = "file://$state/remote.git" ] || return 1
  [ "$(git -C "$p" rev-parse HEAD)" = "$(git --git-dir="$state/remote.git" rev-parse refs/heads/main)" ]
}
run_test 'apply creates only private, connects origin, and pushes the reviewed HEAD' private_create_connects_and_pushes_exact_head

failed_push_is_retryable_without_recreate() {
  p="$TMP/retry-project"; state="$TMP/retry-state"
  make_project "$p"
  mkdir -p "$state"; : > "$state/fail-push-once"
  first_plan="$(run_cmd "$p" "$state" plan)" || return 1
  first_confirm="$(confirmation_from "$first_plan")"
  ! run_cmd "$p" "$state" apply --confirm "$first_confirm" >/dev/null 2>&1 || return 1
  [ -f "$state/repository" ] || return 1
  second_plan="$(run_cmd "$p" "$state" plan)" || return 1
  second_confirm="$(confirmation_from "$second_plan")"
  run_cmd "$p" "$state" apply --confirm "$second_confirm" >/dev/null || return 1
  [ "$(grep -Fc 'repo create ' "$state/calls")" -eq 1 ] || return 1
  [ "$(git -C "$p" rev-parse HEAD)" = "$(git --git-dir="$state/remote.git" rev-parse refs/heads/main)" ]
}
run_test 'a failed push resumes against the same private repo without recreation' failed_push_is_retryable_without_recreate

printf '\nRESULT: PASS=%s FAIL=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
