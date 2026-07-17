---
name: harness
description: >
  오케스트레이터-멀티에이전트 하네스. Use when 사용자가 "하네스 시작 <프로젝트명>",
  "harness start", "하네스 재개", "하네스 현황"을 말할 때. 새 프로젝트 스캐폴딩,
  기존 프로젝트 재개, 워커 디스패치·모니터링·저지 루프를 안내한다.
---

# harness — 라우터

이 스킬은 라우터다. 아래 순서로 **읽고 따르라**. 요약본에 의존하지 말 것.

## 0. 공통
- 하네스 레포 위치 확인: `~/agent-harness` (없으면 clone 안내 후 중단).
- 이 프로젝트가 쓰는 하네스 커밋을 HARNESS.md에 고정 기재한다 (결정 22).
- 모든 워커·저지는 보이는 cmux 창으로만 (`scripts/dispatch.sh`). 숨은 서브에이전트 금지.

### 읽기 모드
- 새 오케스트레이터·감사·인계 불일치 조사는 AGENTS.md와 HANDOFF.md, 전체 설계를
  기존 cold-start 규칙대로 전문 정독한다.
- `[HARNESS_CONTEXT_V1]` 정상 dispatched 워커에서 hot은 지금 책상 위에 펼쳐 둔
  자료이고, cold는 서랍에 둔 참고자료이며, 선택 스킬은 지금 이름만 정하고 필요할 때
  여는 설명서다. 브리프는 자동으로 첫 hot 입력이며 `hot_paths`에 중복 기재하지 않는다.
- `hot_paths 최대 5개`, `skills 최대 5개`를 허용하고, 브리프와 hot을 합쳐
  `100줄 목표`, `200줄` 및 `32 KiB` 하드캡을 적용한다. cold와 선택 스킬은 필요할
  때만 연다.
- 선택 스킬은 태스크별 lazy-load 목록일 뿐이며, 외부 클라이언트가 전체 스킬
  카탈로그를 숨겼다는 뜻은 아니다.

## 1. 새 프로젝트 ("하네스 시작 X")
1. `doctrine/ORCHESTRATION.md`를 전문으로 읽는다 — 너는 오케스트레이터다.
2. `template/`를 새 디렉터리로 복사, `git init`.
3. `doctrine/COMMANDING.md`의 지휘 3요소 형식으로 스캐폴딩 인터뷰
   (질문은 한 번에 하나, 추천+근거 포함) → HARNESS.md의 `{{ }}`를 전부 채운다.
4. `scripts/scaffold-check.sh --smoke` 통과까지가 스캐폴딩이다. 통과 전 워커 금지.
5. 첫 원격 백업은 `.harness/bin/github-private plan`으로 private 대상·현재 커밋·
   올라갈 전체 파일과 `CONFIRM_SHA256`을 먼저 보여준다. 같은 지문을 확인한 뒤에만
   `apply --confirm <SHA256>`를 실행한다. public·force push·원격 삭제로 우회하지 않는다.
6. 첫 dispatch 전에 `contract_version: 3`의 각 작업에 Lean Gate 결론과 근거 한 문장을
   기록하고 실행 계약을 검증한다. 누락·오류·`not-needed`면 워커를 기동하지 않는다.
7. 과거 지식 조회: `/wiki-query` (llm-wiki 설치 시).

## 2. 재개 ("하네스 재개")
1. `STATUS.md` → `log/HANDOFF.md`를 읽는다. 대화 기억이 아니라 이 파일들이 정본.
2. 기재된 실행 ID·커밋·.done·워커 상태를 실제 git log·`scripts/status.sh`와 대조.
   불일치하면 진행 없이 사용자에게 보고 (스펙 §4.8).
3. 모델이 바뀌었으면 인계 기록(어느 모델→어느 모델, 이유, 대조 결과)을
   log/HANDOFF.md에 남기고 사용자에게 표시한다.

## 3. 루프 중
- 워커 기동: `scripts/dispatch.sh <태스크ID>` / 관찰: `scripts/status.sh`
- 모델 없는 deterministic T0는 `scripts/dispatch.sh`를 거치지 않는다. 직접 명령 바로 전에
  `. scripts/lib.sh && validate_execution_contract "$PWD/tasks.yaml"`를 실행한 뒤 그 명령을 직접 실행한다.
- 산출물은 기계 검증(테스트·린트) 먼저, 통과하면 `doctrine/JUDGING.md`대로 저지 기동.
- 검증 순서는 워커 related test → 오케스트레이터 receipt 확인 → 통합 코드에서 최종
  full regression 1회 실제 실행 → 독립 리뷰의 영수증 소비다.
- `verify.cacheable: true`는 결정론 검사에만 쓴다. 시간·네트워크·외부 상태에
  의존하는 검증은 자동 재사용하지 않는다.
- 명령 행동을 바꾸는 환경 변수는 `verify-cache.sh --env NAME`으로 모두 선언한다.
  선언한 이름·set/unset 상태·값 전체만 환경 지문에 넣고, 영수증에는 값 대신 해시만
  남긴다. 전체 셸 환경을 자동 해싱하지 않는다.
- `log/cold/verification/`의 cold raw log는 Git에서 제외하고,
  `log/receipts/`의 durable receipt만 짧은 검증 증거로 추적한다.
- T2/T3 독립 리뷰어는 최종 full receipt를 소비하고 전체 suite를 재실행하지 않는다.
- log/<task>.budget-stop.yaml이 있으면 dispatch·재시도·related/full 검증을 모두
  중단한다. 오케스트레이터가 이유와 다음 결정을 tasks.yaml·STATUS.md·HANDOFF.md에
  기록해 checkpoint한 뒤, 새 계약 또는 명시적 승인이 있을 때만 stop을 제거하고
  해소 상태를 다시 checkpoint한다. 삭제만으로 재개하거나 예산을 자동 확대하지 않는다.
- 토큰은 안정된 Codex JSONL/--json 원본과 SHA-256으로 연결된
  log/usage-receipts/<task>/<run-id>.yaml normalized usage receipt의 run_id,
  source_format, source_sha256, input_tokens, output_tokens만 기록한다.
  값은 사후 advisory이며 receipt가 없으면 unknown으로 둔다.
- 상태 전이: STATUS.md·tasks.yaml·log/HANDOFF.md 갱신 → 소스 변경은 별도 의도적
  커밋 → `.harness/bin/checkpoint <reason>`.
- 사용자 답을 기다리는 질문 전: `D-YYYYMMDD-HHMMSS-NN` ID 선택 →
  `log/decisions/<id>.request.md` 작성 → STATUS의 `다음 사용자 결정`과 HANDOFF의
  `열린 결정`에 같은 ID 기록 → `.harness/bin/decision-open <id> <claude|codex>`.
- 질문 마지막에 `결정 ID: <id>`를 표시한다. pending 없이 차단 질문을 보내지 않는다.
- 새 세션에서 `status: answer_captured`를 발견하면 answer 파일과 그 커밋을 먼저
  대조하고 답을 적용한다. STATUS/HANDOFF/tasks를 갱신해 결정 섹션을 `(없음)`으로
  바꾼 뒤 `.harness/bin/decision-close <id>`를 실행한다.
- provider native 훅 스모크 PASS가 없거나 Codex 훅 hash가 재검토 상태면 결정 질문을
  열지 말고 BLOCKED로 보고한다.
- 결정 답은 로컬 Git 역사에 남는다. 비밀값을 답으로 요구하지 말고 자동 push하지
  않는다. 역사 제거가 필요하면 별도 사용자 승인 작업으로 다룬다.

### Live status 실행 계약

이 절은 안내 문구가 아니라 start/resume/transition/close의 필수 실행 순서다.

- `install.sh --enable-live-status`가 설치한 `~/.local/bin/agent-harness-live-status`를
  UserPromptSubmit 훅이 매 하네스 세션에 best-effort로 호출한다. `start`는 기존 pane을
  재사용하므로 같은 세션의 다음 프롬프트가 중복 pane을 만들지 않는다.
- start/resume 검증 후 `.harness/bin/live-roadmap publish --now "$(date +%s)"`를 실행하고,
  `agent-harness-live-status start "$PWD" <claude|codex>`로 workspace당 bottom status
  pane 하나가 실제로 열렸거나 재사용됐는지 확인한다.
- 오케스트레이터 phase·task·model 전이는 `.harness/bin/live-status orchestrator-update`로
  게시한다. 모르는 값은 `?`이며 요청 모델을 관측 모델로 쓰지 않는다.
- 워커 전이는 dispatch가 생성한 run ID로 `worker-update`를 사용하고, 종료 시
  `worker-finish`를 사용한다. 실제 관측 model을 받기 전에는 요청 model을 `~`로 표시한다.
- 프로젝트를 닫을 때 `agent-harness-live-status stop "$PWD"`을 실행한다.
- `first worker: split right`, `later worker: split down`, `status: split down`을 배치
  불변 규칙으로 사용한다. 워커를 별도 workspace에 숨기지 않는다.
- 워커 관찰은 `cmux read-screen --workspace ... --surface ... --scrollback --lines 80`과
  worktree Git 상태만 사용한다. 프로세스 목록 추측을 위해 `ps를 사용하지 않는다`.
- live status 갱신 실패는 checkpoint·decision·worker 실행을 막지 않는 best-effort다.
  단, 화면에서 검증하지 않은 값을 추측해 채우지 않는다.

## 4. 종료
1. `scripts/collect.sh` 취합.
2. 지식 환류(검토 대기함): 배운 것을 `~/knowledge-base/raw/`에 파일로 투하(자동),
   wiki-ingest·커밋·푸시는 목록을 사용자에게 확인받은 후.
3. `log/deviations.md`를 훑어 가비지 컬렉션 후보를 보고 (스펙 §6.5).
