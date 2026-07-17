# HARNESS — {{프로젝트명}}

<!-- 스캐폴딩 인터뷰로 채운다. {{ }}가 남아 있으면 scaffold-check가 FAIL한다. -->

## 목표
{{무엇이 되면 끝나는지 1~3문장}}

## 맥락
{{왜 하는지, 배경, 참조 자료 경로}}

## 제약
{{마감, 예산, 건드리면 안 되는 것}}

## 위임 레벨
{{L1|L2|L3}} — L1 단계별 승인 / L2 마일스톤 보고(기본) / L3 게이트까지 전권

## 실행 정책
계약 버전: contract v3 — 기본 워커 / 동시 최대 / 재귀 위임 깊이: **1 / 3 / 0**
작업별 T0~T3 등급·예산·Lean Gate 결론은 `tasks.yaml`에 기록하며, 실제 모델명은 `MODELS.yaml`에서만 관리한다.
검증은 워커 related test → 오케스트레이터 receipt 확인 → 최종 full regression 1회 실제 실행 순서다.
시간·네트워크·외부 상태 의존 검증은 자동 재사용하지 않는다.
`log/cold/verification/`의 cold raw log는 Git에 넣지 않는 상세 원본이고, `log/receipts/`의 durable receipt는 Git에 남기는 짧은 검증 증거다.
T2/T3 독립 리뷰어는 최종 full receipt를 소비하고 전체 suite를 재실행하지 않는다.
log/<task>.budget-stop.yaml이 있으면 새 dispatch·재시도·related/full 검증을 모두 멈춘다. 오케스트레이터가 중단 이유와 다음 결정을 tasks.yaml·STATUS.md·log/HANDOFF.md에 먼저 checkpoint하고, 새 계약 또는 명시적 승인이 있을 때만 stop 제거와 해소 상태를 다시 checkpoint한다.
Codex 토큰은 원본 JSONL/--json의 run_id, source_format, source_sha256, input_tokens, output_tokens를 연결한 log/usage-receipts/<task>/<run-id>.yaml normalized usage receipt에서만 기록하며 사후 advisory로 취급한다.
첫 GitHub 백업은 `.harness/bin/github-private plan`이 보여준 private 저장소·커밋·전체 파일 목록을 확인한 뒤 같은 `CONFIRM_SHA256`으로 `apply`한다. dirty tree, 공개 저장소, 다른 origin, 강제 push와 원격 삭제는 허용하지 않는다.

## Live status 수명주기
활성화 설치가 만든 `agent-harness-live-status`를 UserPromptSubmit 훅이 매 하네스 세션에 자동 호출하며, 기존 pane은 재사용해 중복 생성하지 않는다.
start/resume 검증 후 `.harness/bin/live-roadmap publish --now "$(date +%s)"`와 `agent-harness-live-status start "$PWD" <provider>`를 순서대로 확인한다.
오케스트레이터 전이는 `live-status orchestrator-update`, 워커 전이는 `worker-update`/`worker-finish`, 프로젝트 종료는 `agent-harness-live-status stop`으로 게시한다.
첫 워커는 right split, 추가 워커는 워커 영역의 down split, status는 bottom down split 하나만 사용한다. 관찰은 `cmux read-screen`과 Git 상태만 사용하며 `ps`를 사용하지 않는다.

## 선택적 워커 문맥
`[HARNESS_CONTEXT_V1]` 워커에서 hot은 지금 책상 위에 펼쳐 둔 자료이고, cold는 서랍에 둔 참고자료이며, 선택 스킬은 지금 이름만 정하고 필요할 때 여는 설명서다.
브리프는 자동으로 첫 hot 입력이며 `hot_paths`에 다시 적지 않는다. `hot_paths 최대 5개`, `skills 최대 5개`를 허용하고, 브리프와 hot을 합쳐 `100줄 목표`, `200줄` 및 `32 KiB` 하드캡을 적용한다.
선택 스킬은 태스크별 lazy-load 목록일 뿐이며, 외부 클라이언트가 전체 스킬 카탈로그를 숨겼다는 뜻은 아니다. cold와 선택 스킬은 현재 정보만으로 성공 조건을 판단할 수 없을 때만 연다.

## 시그널 가중치
{{예: 출제자 의도 80% / 공개 자료 20%}}

## 우선순위 매트릭스
{{예: 의도적합 40 / 근거 30 / 임팩트 20 / 데모 10}}

## 용어 사전·인터페이스 계약
{{전역 일관성의 단일 출처. 용어, 파일 경로, 형식}}

## 완료 기준
{{저지의 6번째 축. 필수 게이트 — 가중치로 상쇄 불가}}
