# harness

> Brown Field 환경에서 AI 에이전트에게 일을 잘 시키는 5단계 사이클 skill 모음

Claude Code + Codex 양쪽에서 바로 쓸 수 있는 skill 묶음입니다. `clone && install` 한 번으로 두 플랫폼이 동시에 활성화됩니다.

## 왜 만들었나

AI가 코드를 쓰는 시대에 사람의 역할은 "잘 짜기"에서 "잘 일하는 환경을 만들기"로 바뀝니다. brown field — 이미 존재하는 레거시·운영 코드베이스에서 AI 에이전트가 일을 제대로 하려면, 한 사이클 안에 다섯 단계가 박혀 있어야 합니다: **정의 → Spec → 실행 → 검증 → 축적**.

이 repo는 그 사이클을 도구로 구현한 결과물입니다.

## 5단계 사이클 매핑

| 단계 | Claude skill | Codex skill |
|---|---|---|
| ① 정의 | `clarify`, `deep-interview` | `deep-interview` |
| ② Spec | — | `goal-spec-writer` |
| ③ 실행 | — | `goal-runner` |
| ④ 검증 | `goal-code-review` | `deep-code-review`, `x-pr`, `one-click-super-pr-omx` |
| ⑤ 축적 | `wrap` | `wrap` |

## 설치

```bash
git clone https://github.com/taaeyong/harness.git
cd harness
./install.sh
```

`install.sh`는 `claude/skills/*`와 `codex/skills/*`를 각각 `~/.claude/skills/`와 `~/.codex/skills/`로 심볼릭 링크합니다. 기존에 같은 이름의 실제 파일이 있으면 건너뜁니다(덮어쓰지 않음).

설치 후 Claude Code / Codex CLI를 재시작하면 skill이 인식됩니다.

## Skills

### Claude (`~/.claude/skills/`)

- **`clarify`** — 모호한 요구사항을 인터뷰로 정리. 가볍게 쓸 때
- **`deep-interview`** — Socratic 인터뷰로 ambiguity 점수를 정량적으로 떨어뜨림. `oh-my-claudecode` upstream에서 adapt — 자세한 내용은 `ATTRIBUTION.md`
- **`goal-code-review`** — Codex `goal-runner` 결과 폴더를 받아 `deep-code-review`로 넘기는 어댑터. Claude↔Codex 검증 핸드오프
- **`wrap`** — 세션 마무리. 학습한 것을 rules / CLAUDE.md / AGENTS.md로 승격

### Codex (`~/.codex/skills/`)

- **`deep-interview`** — Claude 버전의 omx 자매 배포. 같은 컨셉을 Codex에서 — 자세한 내용은 `ATTRIBUTION.md`
- **`goal-spec-writer`** — task brief를 goal-ready Codex `/goal` spec으로 변환
- **`goal-runner`** — `~/.tasks/` task 폴더 spec을 실제 코드로 실행
- **`deep-code-review`** — 브랜치 변경 깊은 리뷰. 의도·일관성·안전성까지
- **`x-pr`** — 로컬 변경을 ready-for-review GitHub PR로 발행. PR 본문에 의도·변경·리스크·검증 흔적 자동 포함
- **`one-click-super-pr-omx`** — PR 생성/업데이트 + CodeRabbit 리뷰 자동 수정 루프 (omx 플러그인 필요)
- **`wrap`** — Claude 버전과 동일

## License

MIT. `deep-interview` 한 항목만 별도 출처 — `ATTRIBUTION.md` 참조.
