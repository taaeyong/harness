---
name: super-pr-omx
description: "CodeRabbit 리뷰 자동 수정 루프 (omx 전용). oh-my-codex의 state_write로 ralph state를 직접 활성화하여 persistence를 보장한다. omx 플러그인 설치 필수."
argument-hint: "[target-branch]"
---

# Super PR Skill

PR 생성/업데이트와 CodeRabbit 리뷰 자동 수정을 하나로 통합한 skill.
사용자의 요청에 따라 두 가지 모드로 동작한다:

- **PR 모드**: PR 제목/본문 생성 또는 업데이트
- **리뷰 수정 루프 모드**: 봇 리뷰를 자동으로 수정→커밋→푸시→답글하고, 모든 리뷰가 통과할 때까지 반복

사용자가 "PR 만들어줘", "PR 업데이트" 등이면 PR 모드.
"리뷰 수정해줘", "$super-pr-omx", "CodeRabbit 처리해줘" 등이면 리뷰 수정 루프 모드.
명확하지 않으면 현재 PR 상태를 확인하여 미해결 리뷰가 있으면 리뷰 수정 루프, 없으면 PR 모드로 진입한다.

> **경로 표기**: 이 문서에서 `$SKILL_DIR`은 `~/.codex/skills/one-click-super-pr-omx`를 의미한다.
> Codex가 `CODEX_SKILL_DIR` 환경변수를 주입한다면 그 값을 우선 사용하되, 없으면 절대경로로 호출한다.

---

## PR 모드

현재 브랜치의 커밋과 diff를 분석하여 PR 제목/본문을 생성하거나 업데이트한다.

### Steps

1. 현재 브랜치와 target branch 확인 (기본: `main`, 인자로 지정 가능)
2. **기존 PR 확인**: `gh pr list --head <current-branch> --state open --json number,title,body`
3. `git log <target>..HEAD --oneline` + `git diff <target>...HEAD --stat` + `git diff <target>...HEAD --no-color`
4. 분석 후 생성:
   - **Title**: conventional commit 형식 (예: `feat(module): short summary`)
   - **Description**: `$SKILL_DIR/references/pr-template.md` 템플릿 기반 구조화 마크다운

### 기존 PR 있을 때 (update mode)

5. 기존 제목/본문과 비교하여 diff 표시
6. 사용자 승인 후 `gh pr edit <number> --title "..." --body-file <temp-file>`

### 기존 PR 없을 때 (create mode)

5. 생성된 제목/본문을 사용자에게 제시
6. 승인 후 사용자가 직접 생성하거나 요청 시 `gh pr create`

### PR 모드 완료 후 → 리뷰 수정 루프 자동 진입

PR 생성/업데이트 후, `bash $SKILL_DIR/scripts/gh_shortcut.sh wait-for-coderabbit`으로 CodeRabbit 리뷰를 대기한다. 리뷰가 도착하면 자동으로 리뷰 수정 루프 모드로 진입한다. **사용자에게 확인을 구하지 않고 즉시 자동 전환한다.**

### Rules (PR 모드)

- Title: conventional commit 형식, 72자 이내
- Description: 리뷰어가 코드를 한 줄씩 읽지 않아도 이해할 수 있도록 간결하되 충분히 작성
- 한국어로 작성
- 제목/본문을 마크다운 코드블록으로 감싸서 복사 편의 제공
- update mode에서 제목이 달라졌으면 본문과 함께 제목도 업데이트
- PR 본문 마지막에 반드시 `@coderabbitai review` 태그 포함 — non-default base/target branch에서는 CodeRabbit 자동 실행이 skip될 수 있음

---

## 리뷰 수정 루프 모드

PR에 달린 CodeRabbit 리뷰를 자동으로 수정하고, 모든 리뷰가 통과할 때까지 반복한다.

```text
check → fetch-reviews → 분류 → 수정 → 커밋 → 푸시 → 답글
  → wait-for-coderabbit → check → ... → 종료 → PR 메시지 업데이트
```

### `$SKILL_DIR/scripts/gh_shortcut.sh` Reference

리뷰 루프의 deterministic한 부분(API 호출, 종료 판정, 대기)을 담당하는 bash 스크립트.

| Command | 설명 | Exit code |
|---------|------|-----------|
| `init` | GH_HOST, OWNER, REPO, PR_NUMBER, BRANCH 자동 감지 | 0=성공, 3=prerequisite 실패 |
| `check [--sha SHA] [--since TS]` | 종료 조건 판정(CodeRabbit success/skip, threads, reviews, review-body feedback) | 0=종료, 1=계속 |
| `fetch-reviews [--since TS]` | 리뷰 조회 + CodeRabbit 포맷 파싱 → JSON | 0=성공 |
| `reply <comment_id> <body>` | 인라인 코멘트에 답글 | 0=성공 |
| `reply --pr-comment <body>` | PR 일반 코멘트 | 0=성공 |
| `create-issue <title> [< body]` | 스코프 외 건 이슈 생성 | 0=성공 |
| `wait-for-coderabbit [--timeout N] [--interval N]` | CodeRabbit 완료 대기 + 자동 트리거. `Review skipped` success는 성공으로 보지 않고 `@coderabbitai review`로 재트리거 | 0=성공, 2=timeout |

**`fetch-reviews` 출력 필드** (각 comment):

| 필드 | 설명 |
|------|------|
| `comment_id` | 답글 시 사용하는 REST API ID |
| `review_id` | review body / outside-diff feedback일 때 사용하는 review id (`comment_id=null`) |
| `source` | `inline` 생략 또는 `review_body`; `review_body`면 `reply --pr-comment`로 답글 |
| `thread_id` | GraphQL node_id |
| `path`, `line` | 수정 대상 파일/라인 |
| `severity` | `critical` / `major` / `minor` / `nitpick` (CodeRabbit 이모지 파싱) |
| `summary` | 한국어 요약 (첫 번째 bold 라인) |
| `prompt` | CodeRabbit의 "Prompt for AI Agents" 블록 — 수정 지시사항 |
| `suggestion` | diff 포맷의 수정 제안 코드 |
| `is_resolved` | 스레드 resolve 여부 |
| `addressed` | `✅ Addressed in commit` 감지 여부 |

**`fetch-reviews` 최상위 필드**:

| 필드 | 설명 |
|------|------|
| `review_prompt` | CodeRabbit의 통합 "Prompt for AI Agents" (review body에서 추출) |
| `review_feedbacks` | `CHANGES_REQUESTED`와 `COMMENTED` 상태의 actionable review-level body / outside-diff feedback 배열 (`review_id`, `body`, `state`, `submitted_at`) |
| `comments` | 인라인 코멘트 배열 (위 필드 포함) |
| `unresolved` | `is_resolved=false && addressed=false`인 인라인 코멘트 + 아직 PR 답글로 addressed 처리되지 않은 review-body feedback |
| `summary` | `total`, `unresolved`, `review_feedbacks`, `addressed`, `by_severity` 카운트 |

### 종료 조건

3단계 종료 판정을 순서대로 확인한다:

#### Level 1: Clean Exit

`bash $SKILL_DIR/scripts/gh_shortcut.sh check`가 exit 0을 반환하면 즉시 종료.
내부적으로 아래 조건을 확인한다:

1. **CodeRabbit status `success`** 이고 description이 `Review skipped`가 아님
2. **미해결 스레드 0건**
3. **새 `CHANGES_REQUESTED` 리뷰 없음**
4. **새 actionable review-body / outside-diff feedback 없음**

#### Level 2: Soft Exit

`check`가 exit 1이지만 아래 조건을 **모두** 충족하면 종료:

1. **CodeRabbit status `success`**
2. **새 `CHANGES_REQUESTED` 리뷰 없음**
3. **모든 미해결 스레드에 2회 이상 답글 완료** (reply_tracker로 추적)

Soft Exit 사유: CodeRabbit 오탐, 설계 의견 차이, 이슈 전환 후 미resolve 등.
종료 시 PR에 요약 코멘트: `"N건 addressed but unresolved (오탐/설계 의도 — 답글 참조)"`.

#### Level 3: Force Exit

`--max-iterations` 초과 시 강제 종료. 남은 미해결 전체 보고.

#### 추가 방어: Empty Round Exit

`fetch-reviews` 결과 unresolved 0건이고 새 코멘트도 없는데 `check`가 exit 1인 경우 → 즉시 종료.
(CodeRabbit status가 아직 pending인 경우 등)

#### 추가 방어: Consecutive Timeout Exit

`wait-for-coderabbit`이 **연속 2회 timeout** (exit 2)하면 → CodeRabbit 불응으로 판단, 즉시 종료.

### Arguments (리뷰 루프)

| 인자 | 기본값 | 설명 |
|------|--------|------|
| `--max-iterations` | `10` | 최대 반복 횟수 (무한 루프 방지) |

### Prerequisites

`bash $SKILL_DIR/scripts/gh_shortcut.sh init` 실행 시 자동 검증 (gh CLI, 인증, git repo, open PR). 실패 시 에러 메시지 출력.

추가로 자동 커밋/푸시를 위해 sandbox/approval 설정에서 `git commit *`, `git push *`가 허용되어야 한다 (Codex의 `approval_policy="never"` + `sandbox_mode="danger-full-access"` 조합이거나 명시적 허용).

oh-my-codex 플러그인 설치 필수 (`omx_state` MCP server의 `state_write` 도구 사용).

### omx 연동

이 모드는 oh-my-codex의 `omx_state` MCP server에서 제공하는 `state_write` 도구를 직접 호출하여 ralph state를 활성화한다. state 파일이 존재하면 omx의 persistent-mode Stop hook이 세션 종료를 차단하여 루프가 중단 없이 지속된다.

> **omx 플러그인 필수**: `state_write` MCP 도구가 없으면 이 모드는 동작하지 않는다. omx가 없는 환경에서는 `super-pr-loop` 또는 `super-pr-rw`(ralph 위임 변형)를 사용한다.

> **MCP 도구 로딩**: 첫 호출 전에 `ToolSearch("select:state_write,state_read,state_clear")` 또는 `ToolSearch("omx state")`로 deferred 도구를 로드해야 한다.

### Steps (리뷰 루프)

#### 0. 초기 설정

1. `eval "$(bash $SKILL_DIR/scripts/gh_shortcut.sh init)"` — prerequisite 체크 + 환경변수 설정
2. `state_write` MCP 도구 호출:
   ```
   mode="ralph", active=true, iteration=1,
   max_iterations={max_iterations},
   current_phase="executing",
   started_at="<now>",
   task_description="PR #{pr_number} CodeRabbit 리뷰 resolve"
   ```
   - 이 호출로 `.omx/state/ralph-state.json`이 생성되어 persistent-mode Stop hook이 세션 종료를 차단한다.
3. 내부 상태 초기화:
   - `reply_tracker`: `{ [comment_id]: reply_count }` — 각 코멘트에 답글 단 횟수 추적
   - `consecutive_timeouts`: 0 — wait-for-coderabbit 연속 timeout 횟수

#### 1. 종료 확인

종료 판정을 순서대로 수행한다:

1. `bash $SKILL_DIR/scripts/gh_shortcut.sh check --since "$LAST_PUSH_TS"` — **exit 0이면 Clean Exit → Step 6(종료).**

2. exit 1이면 `fetch-reviews`로 현재 상태 확인:
   - **Empty Round Exit**: unresolved 0건 + 새 코멘트 없음 → Step 6(종료).
   - **Soft Exit 판정**: CodeRabbit success + 새 리뷰 없음 + 모든 unresolved comment의 `reply_tracker[comment_id] >= 2` → Step 6(종료, Soft Exit).
     - 종료 시 PR 코멘트: `"N건 addressed but unresolved (오탐/설계 의도 — 답글 참조)"`
   - `source="review_body"` 또는 `comment_id=null`인 feedback은 GitHub inline reply 대상이 아니므로 수정/스킵 후 `reply --pr-comment`로 답글한다.
   - 위 조건 모두 불충족 → Step 2로 진행.

#### 2. 리뷰 조회 및 분류

`bash $SKILL_DIR/scripts/gh_shortcut.sh fetch-reviews --since "$LAST_PUSH_TS"` 실행 후 `unresolved` 배열의 각 코멘트를 분류:

| severity | PR 스코프 내 | PR 스코프 외 / 사소한 건 |
|----------|:---:|:---:|
| critical / major | 반드시 수정 | 수정 (가능하면) |
| minor | 수정 | **issue 생성** |
| nitpick | 수정 | **issue 생성** |
| 질문/토론 | 답글만 | 답글만 |

각 코멘트의 `prompt` 필드가 exact 수정 지시사항, `suggestion` 필드가 diff 제안. 파일 읽기 → 중복 수정 방지 → PR 스코프 판단 → 수정 또는 issue 생성.
`review_body` feedback은 CodeRabbit의 outside-diff / review-level 코멘트이므로 `path`/`line`이 비어 있을 수 있다. 이 경우 `prompt`와 `body`에서 파일/라인을 추출하거나 PR diff를 직접 확인한다.

#### 3. 수정 적용

**스코프 내**: Edit 도구로 수정. 같은 패턴이 다른 파일에도 있으면 선제적 일괄 수정. Python 파일은 `ast.parse()`로 구문 검증.

**스코프 외**: `bash $SKILL_DIR/scripts/gh_shortcut.sh create-issue "제목" <<< "내용"` 으로 GitHub Issue 전환.

#### 4. 커밋 & 푸시

```text
fix(scope): 리뷰 반영 요약 (1줄)

- 파일1: 수정 내용
- 파일2: 수정 내용

Co-Authored-By: Codex <noreply@openai.com>
```

수정된 파일만 `git add` → `git commit -m "<msg>"` → `git push origin <branch>`. 푸시 후 `LAST_PUSH_TS`를 현재 시각으로 갱신.

#### 5. 답글 달기

모든 지적에 예외 없이 답글 (`bash $SKILL_DIR/scripts/gh_shortcut.sh reply`):
- 수정 건: `bash $SKILL_DIR/scripts/gh_shortcut.sh reply <comment_id> "수정 완료 ({hash}). {요약}."`
- issue 전환 건: `bash $SKILL_DIR/scripts/gh_shortcut.sh reply <comment_id> "Issue #{num}로 등록했습니다."`
- Duplicate: `bash $SKILL_DIR/scripts/gh_shortcut.sh reply <comment_id> "이전 커밋({hash})에서 이미 수정되었습니다."`
- 리뷰 body 전용: `bash $SKILL_DIR/scripts/gh_shortcut.sh reply --pr-comment "내용"`

인라인 답글 후 CodeRabbit이 자동으로 스레드를 resolve한다. Review-body feedback은 스레드가 없으므로 이후 `fetch-reviews --since "$LAST_PUSH_TS"` 기준으로 새 feedback만 계속 처리한다.

답글 완료 후:
1. 각 답글한 `comment_id`에 대해 `reply_tracker[comment_id]` += 1.
2. `state_write` MCP 도구로 iteration 증가: `mode="ralph", iteration` += 1, `current_phase="executing"`.
3. `bash $SKILL_DIR/scripts/gh_shortcut.sh wait-for-coderabbit` 실행:
   - **exit 0 (성공)**: `consecutive_timeouts = 0` 리셋 → Step 1로 돌아감.
   - **exit 2 (timeout)**: `consecutive_timeouts` += 1.
     - `consecutive_timeouts >= 2` → **Consecutive Timeout Exit** → Step 6(종료).
     - 그 외 → Step 1로 돌아감.

#### 6. 종료

1. **PR 메시지 업데이트**: 이 skill의 PR 모드를 사용하여 제목/본문 업데이트 (`gh pr edit`)
2. **Issue 전환 요약**: issue 전환 건이 있으면 PR에 요약 코멘트
3. **Soft Exit 시**: PR에 요약 코멘트 — `"N건 addressed but unresolved (오탐/설계 의도 — 답글 참조)"`
4. **종료 보고**: exit level (Clean/Soft/Force/Empty Round/Consecutive Timeout), iteration 수, 수정 파일, 커밋, 처리 코멘트 수 보고
5. `$cancel`을 실행하여 ralph state를 정리한다 (`state_clear(mode="ralph")` 호출됨).

### Rules (리뷰 루프)

- **omx 전용**: 이 모드는 oh-my-codex 플러그인의 `omx_state` MCP `state_write`에 의존한다. omx가 설치되지 않은 환경에서는 `super-pr-loop` 또는 `super-pr-rw`를 사용한다.
- **완전 자율 실행**: 이 skill이 트리거되면 종료 조건 충족까지 모든 단계를 사용자 확인 없이 자율적으로 수행한다. 중간에 "진행할까요?", "수정할까요?" 등의 확인 질문을 하지 않는다.
- **최소 변경 원칙**: 지적 부분만 수정. 동일 패턴은 선제적 일괄 수정으로 다음 라운드 최소화.
- **수정 불가 건은 설명**: 의도적 설계면 답글로 사유 설명.
- **무한 루프 방지**: `--max-iterations` 초과 시 강제 종료 후 남은 리뷰 보고
- 커밋 메시지는 한국어로 작성
