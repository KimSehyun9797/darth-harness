# {{프로젝트명}}

agent-harness 프로젝트. 처음이면 [STATUS.md](STATUS.md)에서 시작하라 — 목표,
현재 상태, 정본 링크가 거기 있다.

- 재개: "하네스 재개" → log/HANDOFF.md를 읽는 것이지 대화 복원이 아니다.
- 규칙: HARNESS.md · 의존성: tasks.yaml · 로그/증거: log/
- 로드맵과 워커 페르소나 지침은 아래에 프로젝트별로 채운다.

## 첫 private GitHub 백업

먼저 실제로 올라갈 저장소·커밋·파일 전체를 확인한다.

```sh
.harness/bin/github-private plan
```

출력의 `CONFIRM_SHA256`이 같은 동안에만 실행한다.

```sh
.harness/bin/github-private apply --confirm <CONFIRM_SHA256>
```

기본 저장소명은 `<GitHub 로그인>/<현재 폴더명>`이다. 다른 이름은 두 명령 모두에
`--repo OWNER/NAME`을 붙인다. 이 도구는 private 생성만 지원하며 force push나 원격
삭제를 하지 않는다. push 실패 시 다시 `plan`부터 실행하면 같은 private 저장소에서
이어간다.

{{로드맵}}
