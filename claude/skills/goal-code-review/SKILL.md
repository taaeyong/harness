---
name: goal-code-review
description: "Wrap /deep-code-review for Codex goal-runner task folders. Reads <task-folder> (README.md, spec.md, review-packet.md, fix.md if present), invokes /deep-code-review against the recorded base..head, writes <task-folder>/review.md with goal-shaped verdict and Done-When matrix, and emits a paste-ready Codex handoff prompt. Use when user invokes /goal-code-review <task-folder>, asks to review a goal-runner result, or supplies a ~/.tasks/... folder for review. **vs 형제 스킬**: 일반 브랜치 깊은 리뷰는 'deep-code-review', 단일 PR은 'review' — 이 스킬은 Codex goal-runner 태스크 폴더 전용 어댑터."
argument-hint: "<task-folder> [--rerun]"
allowed-tools: Read, Write, Bash, Grep, Glob, Skill, Agent
---

# goal-code-review

Thin I/O adapter around `/deep-code-review` for Codex goal-runner task folders.

## Wrapper relationship — STRICT delegation

This skill is a thin adapter. It MUST:

- Invoke `/deep-code-review` verbatim. Preserve unchanged: 5 parallel agents (Intent, Architecture/Cross-file, Naming, Risk, Completeness), critic verification, severity (`:red_circle:` Normal / `:yellow_circle:` Nit / `:purple_circle:` Pre-existing), confidence ≥80 reporting threshold, 5-dimension scoring, false-positive filters, and CLAUDE.md/REVIEW.md hierarchy reading.
- NOT re-implement, override, short-circuit, or "improve" any `/deep-code-review` logic.
- Add ONLY adapter layers around the core:
  - **Input adapter** — derive base/head/source-repo from the task folder.
  - **Output adapter** — translate the report into goal-shaped review.md + Codex handoff.
  - **Goal-specific addenda** that AUGMENT (never replace) `/deep-code-review`: Spec conformance check (Done-When matrix), Do-Not-Touch scope check, fix.md re-review delta.
- When goal conventions and `/deep-code-review` defaults conflict: `/deep-code-review` wins on review methodology; goal wins on artifact location, naming, and verdict vocabulary.

The user is satisfied with `/deep-code-review` as-is. Do not regress it.

## Input contract

Positional arg 1: `<task-folder>` — absolute or `~`-prefixed path.

Flag: `--rerun` — present iff `fix.md` exists and the user wants delta review against the prior `review.md`.

Required files in `<task-folder>`:

- `README.md` — status, source repo path, base SHA, head SHA, diff command
- `spec.md` — source of truth: Editable Scope, Do Not Touch, Done When, Stop / Escalate, Verification Loop
- `review-packet.md` — implementer's claims: changed files, verification evidence, known gaps
- `fix.md` — optional; present only on re-review

If any required file is missing or unparseable → abort with verdict **Blocked**. Do NOT invoke `/deep-code-review`.

## Workflow

### Step 1 — Read & validate inputs

Read in order: `README.md` → `spec.md` → `review-packet.md` → `fix.md` (if present).

Extract: `source_repo`, `base_sha`, `head_sha`, `diff_command`.

Verify in `source_repo`:

- Is a git repo (`git -C <repo> rev-parse --git-dir`).
- `git rev-parse <base_sha>` and `git rev-parse <head_sha>` both succeed.
- Both SHAs are reachable.

Any failure → write `review.md` with verdict **Blocked** + a single Findings entry naming the missing input. Stop.

### Step 2 — Invoke /deep-code-review (unchanged)

Set working directory to `source_repo`. Confirm `HEAD == head_sha` first.

**Case A — `HEAD == head_sha`**: cd `source_repo`, invoke `/deep-code-review` directly.

> Case A is fragile when another session may share `source_repo`'s primary working tree. Re-run `git -C <source_repo> rev-parse HEAD` immediately before delegating to `/deep-code-review`, and again before each downstream verification step (file reads, rg searches) if more than ~30 seconds have passed. If HEAD has drifted from `head_sha`, abandon Case A and restart at Step 2 with Case B. A single early HEAD check is not enough — concurrent `git switch` / `git checkout` from another session can silently move HEAD between any two queries.

**Case B — `HEAD ≠ head_sha` (typical for merged/landed tasks)**:

If `head_sha` is reachable (`git -C <source_repo> rev-parse <head_sha>^{commit}` succeeds): create a temporary detached worktree at `head_sha`, run the review there, then clean up.

```bash
WORKTREE=/tmp/goal-code-review-$(basename <task-folder>)-$(date +%s)
git -C <source_repo> worktree add --detach "$WORKTREE" <head_sha>
cd "$WORKTREE"
# invoke /deep-code-review here
# ... after review.md is fully written in Step 5:
git -C <source_repo> worktree remove --force "$WORKTREE"
```

The worktree write only touches `.git/worktrees/` metadata — `source_repo`'s primary working tree is never modified. Always run `worktree remove` before Step 6, even if `/deep-code-review` errored. Use a `trap` if scripted.

If `head_sha` is unreachable → **Blocked**, suggest `git -C <source_repo> fetch origin <head_sha>` or verify the SHA.

**Case C — `--rerun` flag set AND fix.md present**: review current `HEAD` instead of `head_sha`. Record the actually-reviewed HEAD in review.md and use the prior review.md (or review.md.bak) as the baseline for Step 4 delta. Do NOT use a worktree.

Invoke via Skill tool:

```
Skill(skill="deep-code-review", args="<base_sha>")
```

Pass NO custom flags or short-circuits. `/deep-code-review` must run its full 5-agent + critic flow against `<base_sha>..HEAD` where HEAD is whatever the current cwd points to (worktree HEAD in Case B, source_repo HEAD in Cases A and C).

Capture its full report verbatim for embedding in Step 5.

### Step 3 — Spec conformance check (additive)

After `/deep-code-review` completes, perform checks it does not natively cover.

(a) Parse `spec.md` for these sections (regex on headings):

- "Editable Scope", "Do Not Touch", "Read-only Context"
- "Done When"
- "Stop / Escalate If"
- "Verification Loop" (commands to inject into handoff)

(b) **Done-When matrix**: for each Done-When clause × evidence in the diff or review-packet → `OK` / `Partial` / `Missing`.

(c) **Scope-violation check**: every changed file from the diff vs Editable Scope. A file modified inside "Do Not Touch" → upgrade to wrapper-level **BLOCKER** regardless of `/deep-code-review` confidence.

(d) **Stop/Escalate trigger check**: did the implementation hit a condition that should have stopped goal-runner? Flag.

These produce ADDITIONAL findings; never delete or downgrade a `/deep-code-review` finding.

### Step 4 — fix.md re-review delta (only if fix.md present)

Recover the prior `review.md` from `<task-folder>/review.md.bak` (created in Step 5 of the previous run) or the task folder's git history if tracked. If unrecoverable, ask the user whether prior findings still apply.

For each prior finding:

- Was it addressed? (Verify fix.md's claim against actual code, not just the claim.)
- Did the fix introduce a regression in the new `/deep-code-review` run?
- Categorize: `Resolved` / `Partially Resolved` / `Unresolved` / `Regression`.

Add a "Re-review Delta" section to `review.md`.

### Step 5 — Write review.md

Use the template below. Embed `/deep-code-review`'s full report verbatim inside the "Detailed Findings" section so the user retains full fidelity. Goal-specific sections wrap around it.

If `<task-folder>/review.md` already exists, rename the prior copy to `review.md.bak` first (single-level backup; do not chain `.bak.bak`).

### Step 6 — Emit final response

Print to chat:

1. Verdict: **Proceed to PR** / **Needs fixes** / **Blocked**
2. Counts: BLOCKER (wrapper) / `:red_circle:` Normal / `:yellow_circle:` Nit / `:purple_circle:` Pre-existing
3. Path to `<task-folder>/review.md`
4. Paste-ready Codex handoff prompt as a fenced code block.

Do NOT auto-pbcopy. The user has a separate clipboard step.

## Verdict translation

| `/deep-code-review` verdict | scope violation? | wrapper verdict |
|---|---|---|
| APPROVE | No | Proceed to PR |
| REQUEST CHANGES | No | Needs fixes |
| NEEDS DISCUSSION | No | Blocked |
| any | Yes | Blocked |
| input invalid / dcr unavailable | n/a | Blocked |

Additional rules:

- ≥1 `:red_circle:` Normal with confidence ≥80 → at least **Needs fixes**.
- Only `:yellow_circle:` Nit findings → **Proceed to PR** (list under Optional Polish).
- Any modified file inside Do-Not-Touch → **BLOCKER** overrides APPROVE.

## review.md template

```markdown
# Goal Code Review: <task-name>

- Reviewer: Claude Code (goal-code-review wrapper over /deep-code-review)
- Task folder: <abs path>
- Source repo: <abs path>
- Base: <base_sha>
- Head: <head_sha actually reviewed>
- Diff command: `<verbatim>`
- Date: <YYYY-MM-DD>

## Verdict

**<Proceed to PR | Needs fixes | Blocked>**

Rationale (2-3 sentences):
- ...

Severity counts:
- BLOCKER (wrapper scope check): N
- :red_circle: Normal: N
- :yellow_circle: Nit: N
- :purple_circle: Pre-existing: N

## Spec Conformance

### Editable scope
- Files modified inside Editable Scope: N
- Files modified inside Do Not Touch: N  ← BLOCKER if non-zero
- Files modified inside Read-only Context: N  ← warn

### Done-When matrix
| Clause | Evidence | Status |
|---|---|---|
| ... | ... | OK / Partial / Missing |

### Stop / Escalate triggers
- Hit: <list or "none">

## Re-review Delta  (only if fix.md was present)

| Prior finding | Status | Evidence |
|---|---|---|
| ... | Resolved / Partial / Unresolved / Regression | ... |

## Detailed Findings (from /deep-code-review)

<EMBED /deep-code-review's full report verbatim:
 - Overview (branch, commits, files changed, review depth, date)
 - Scores table (5 dims + Overall)
 - Critical Issues (:red_circle:)
 - Important Findings (:yellow_circle:)
 - Pre-existing Issues (:purple_circle:)
 - Naming Issues table
 - Documentation Staleness
 - Observations
 - What's Done Well
 - /deep-code-review verdict line>

## Optional Polish

- <aggregate of :yellow_circle: / Nit items the user may defer>

## Codex Handoff

<paste-ready prompt; see Handoff template below>
```

## Handoff template

````
# Codex: <task-name> — review handoff

Read <task-folder>/review.md and decide:
(A) apply fixes — required when verdict is "Needs fixes" or "Blocked"
(B) PR as-is — only when verdict is "Proceed to PR"

If applying fixes:
- Stay inside spec.md "Editable Scope".
- Do NOT touch Do-Not-Touch paths.
- Conventional Commits; one logical change per commit; no --amend on
  existing commits.
- After fixes, write <task-folder>/fix.md describing what was changed and
  why, referencing each addressed finding by its review.md section heading.
- Run the verification gates listed in spec.md "Verification Loop":
<auto-injected from spec.md, indented 2 spaces, fenced if commands>
- Update README.md status to ready-for-pr.
- Stop before `gh pr create` unless explicitly asked.

If gates fail, fix the smallest scope and rerun until green, or document
the blocker in fix.md and stop.
````

## Read-only enforcement

This skill MUST NOT:

- Edit or write anything outside `<task-folder>/review.md`, `<task-folder>/review.md.bak`, and the temporary `/tmp/goal-code-review-*` worktree (Step 2 Case B).
- Run `git commit`, `push`, `branch -d/-D`, mutating `checkout` (on `source_repo`'s primary working tree), `reset`, `rebase`, `merge`, `cherry-pick`, `tag`, `stash drop`, or any write op against tracked source files.
- Run `gh pr create` or any release action.
- Run `npm install` / `build` / `lint` / `test` unless the user explicitly asks in the same turn (e.g. "also run the gates").
- Modify `source_repo`'s primary working tree.

Read-only git allowed: `log`, `diff`, `show`, `blame`, `rev-parse`, `ls-files`, `status` (without `-u` side effects), `config --get`.

Conditional writes allowed (Case B only):

- `git worktree add --detach <path> <sha>` — creates an isolated worktree to materialize a historical SHA. Modifies `.git/worktrees/` metadata only.
- `git worktree remove --force <path>` — paired cleanup, mandatory before Step 6.

Both must target a `/tmp/goal-code-review-*` path. Do not create worktrees inside `source_repo` or any user-facing directory.

## Edge cases

| Condition | Handling |
|---|---|
| Task folder missing | Blocked, "task folder not found". |
| README.md missing source_repo / base / head | Blocked, list missing keys. |
| source_repo not a git repo | Blocked. |
| Base or head SHA unreachable | Blocked, suggest `git fetch origin`. |
| HEAD ≠ head_sha and not `--rerun` | Blocked (Step 2). |
| ripgrep / `git show` returns inconsistent results for the same path between two queries | HEAD drift smoke signal — a concurrent session likely moved HEAD between queries. Re-run `git -C <source_repo> rev-parse HEAD`; if it differs from the value recorded at the top of Step 2, abandon Case A and restart at Step 2 with Case B (worktree at the original `head_sha`). Discard any partial verification done after the drift. |
| `/deep-code-review` fails | Partial review.md, verdict "Blocked: /deep-code-review unavailable — reason: <error>". No shallow fallback. |
| spec.md missing Done-When section | Record "Done-When matrix unavailable" and continue; do not block. |
| review.md already exists | Back up to review.md.bak (single-level), then overwrite. |
| Source diff > 500 lines | Recommend (do not enforce) re-running this skill in a forked subagent context to protect main conversation. |

## Compound Engineering

> CE 루프: `~/.claude/skills/create-skill/references/compound-engineering.md` 참조

### 회고 체크리스트

- `/deep-code-review`가 spec.md context로 미리 거를 수 있었던 false positive를 냈나? spec.md를 더 좁게 쓰는 게 답인지 확인.
- wrapper의 Do-Not-Touch scope 검사가 잡은 항목을 `/deep-code-review`도 별도로 잡았나? 중복이면 wrapper 룰이 잉여인지, 아니면 `/deep-code-review`가 놓친 영역을 wrapper가 보강한 건지 분리.
- verdict 번역표(APPROVE→Proceed to PR 등)가 사용자 결정과 일치했나? 사용자가 wrapper verdict을 override했다면 어떤 신호를 추가해야 일치할지 메모.
- handoff prompt를 받은 Codex가 깔끔하게 행동했나? 오해한 항목이 있다면 handoff 템플릿에 어떤 line을 추가해야 할지 기록.
- review.md가 다음 라운드(fix.md 작성)의 입력으로 충분했나? finding heading naming 컨벤션이 일관됐는지 확인.
- spec.md 자체에 모호함이 드러났다면 goal-spec-writer로 피드백할 항목 메모. (이 skill은 spec.md를 직접 수정하지 않음.)

## Anti-patterns

- 절대 `/deep-code-review`의 finding을 paraphrase / 요약 / "개선"하지 말 것 — verbatim embed.
- Normal/Nit/Pre-existing을 한 버킷으로 묶지 말 것.
- `/deep-code-review`를 건너뛰고 goal-shaped review를 쓰지 말 것 (shortcut path 금지).
- source repo 경로나 default base=main을 하드코딩하지 말 것 — 항상 README.md에서 도출.
- auto-checkout, auto-fetch, source repo working tree 변경 금지.
- `gh pr create` / commit / push 절대 금지.
