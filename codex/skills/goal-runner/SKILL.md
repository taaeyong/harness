---
name: goal-runner
description: Run or resume implementation from a ~/.tasks task folder created by goal-spec-writer. Use when the user invokes $goal-runner, provides a task folder, or wants to execute a task spec through Codex goal-style implementation while leaving review artifacts and copy-paste handoff prompts for Claude Code deep-code-review.
---

# goal-runner

Implement a task from a persistent task folder. This skill is a thin execution wrapper around the task folder contract; it does not replace the spec and must not broaden scope beyond `spec.md`.

## Inputs

Accept either:

- A task folder path, e.g. `~/.tasks/myrepo/issue-42/`
- A `<scope>/<task-key>` pair, e.g. `myrepo/issue-42`
- A bare `<task-key>`; resolve it under the current git repo slug first
- No argument; list likely tasks for the current repo and ask one concise selection question if ambiguous

Task folder must contain at minimum:

- `README.md` — current status board
- `spec.md` — implementation source of truth
- `handoffs.md` — preferred, but create it if missing

## Workflow

### 1. Resolve task folder

Determine current repo slug with `basename $(git rev-parse --show-toplevel)` when inside a git repo.

Resolution priority:

1. Existing path passed by user
2. `~/.tasks/<scope>/<task-key>/` when user passes `scope/task-key`
3. `~/.tasks/<current-repo-slug>/<task-key>/` for bare task keys
4. If no argument, list `~/.tasks/<current-repo-slug>/*/README.md` first, then `~/.tasks/*/*/README.md` as fallback

If multiple plausible tasks remain, ask exactly one concise question. Do not guess when it could run the wrong task.

### 2. Read status and spec

Read `README.md` and `spec.md` before implementation.

Before editing, normalize the task's branch strategy:

- **Implementation/review base**: branch or commit used for local work and Claude review diffs.
- **PR target base**: branch the final PR should merge into, usually the repo default branch such as `main`.
- **Implementation branch/worktree**: branch/worktree to edit.

Do not treat the implementation/review base as the PR target base just because it appears in the diff command. If `PR target base` is missing and the implementation/review base is a non-default branch, ask one concise question before implementation or PR handoff. If the remote default branch is the clear target, record `PR target base: <default>` as an explicit assumption in README/spec-derived artifacts.

Status behavior:

- `ready-for-implementation` or `implementation-in-progress`: proceed.
- `ready-for-external-review` or legacy `ready-for-review`: do not implement; tell the user to run `/goal-code-review` in Claude Code using the task folder and `claude-review-prompt.md`.
- `review-complete` or `changes-requested`: proceed only if the user asked to apply review fixes; read `review.md`, keep `spec.md` as source of truth, and write `fix.md`.
- `ready-for-pr` or `pr-opened`: do not implement unless the user explicitly asks for follow-up fixes.
- Unknown status: proceed only if `spec.md` is clear; update README with the normalized status.

### 3. Execute bounded implementation

Treat `spec.md` as the canonical requirements. Keep edits inside its Editable Scope and obey Do Not Touch / Stop-Escalate rules.

If Codex goal tools are available and no active goal exists, create a goal whose objective is: implement this task folder to ready-for-external-review with review artifacts. If goal tools are unavailable, execute directly in the current session using the same contract.

Use or create a dedicated implementation branch/worktree when the spec or README names one. If absent, choose a branch consistent with the repo convention, usually `codex/<task-key>` or `codex/<task-key>-<short-purpose>`.

### 4. Self-review before external handoff

Before handing to Claude Code, perform a local self-review:

- Re-read `spec.md` and compare it with the final diff.
- Confirm edits stayed inside Editable Scope and did not violate Do Not Touch.
- Confirm the verification commands/evidence prove the Done When criteria or record explicit gaps.
- Check for obvious regressions, debug leftovers, secrets, broad cleanup, and unrelated formatting churn.
- Record the self-review result in `review-packet.md`, updating it again after the review commit hash exists.

This does not replace Claude Code deep-code-review; it only prevents handing over obviously incomplete work.

### 5. Create a stable local review commit

Before setting the task to `ready-for-external-review`, create a local source-code commit that Claude Code can review by hash.

Commit policy:

- Commit after implementation, verification, and self-review show the source diff is ready for external review.
- Commit only the scoped source/worktree changes for the task. Do not accidentally stage unrelated local edits.
- Do not push, open a PR, or create remote side effects.
- Use the repo's required commit-message protocol; if none is more specific, use the Lore Commit Protocol from `AGENTS.md`.
- If verification has material failures, unresolved scope, destructive risk, or a Stop/Escalate condition, do not commit; document the blocker and leave the review target as uncommitted.
- If only unrelated pre-existing checks fail, a commit is allowed after targeted validation passes; document the full-check gap in `verification.md` and `review-packet.md`.
- For review-fix runs, create a follow-up fix commit instead of amending the implementation commit unless the user explicitly asks and Claude review has not started.

After committing:

- Capture the full head commit hash.
- Use `git diff <implementation/review-base>...<head> -- .` as the default review diff command.
- Refresh `artifacts/diff.patch` from the committed base/head diff when possible.
- If the task folder itself is outside the source repo, leave task artifacts uncommitted; they are handoff state, not product source.

### 6. Required end artifacts

Before stopping, update or create:

- `README.md`
  - `Status: ready-for-external-review`
  - repo, implementation/review base, PR target base, branch, worktree
  - review target commit, or a clear blocker note if no commit was created
  - next action for Claude Code deep-code-review, explicitly naming `/goal-code-review`
- `review-packet.md`
  - review target: implementation/review base, head, diff command
  - PR target base for later publishing
  - implementation summary
  - changed files
  - verification evidence
  - self-review checklist/result
  - known gaps/risks
  - requested review focus
- `claude-review-prompt.md`
  - exact copy-paste prompt for the C session
  - task folder path
  - source worktree/repo path
  - implementation/review base/head/diff command
  - instruction to write findings to `review.md`
- `handoffs.md`
  - keep A -> B, B -> C, C -> B, and B -> PR prompts current
  - B -> C must be a copy-paste `/goal-code-review` command block, not only "read and execute"
  - B -> PR must explicitly name the PR target base and warn not to reuse the review base blindly
- `verification.md` when verification is non-trivial or failed/blocked
- `artifacts/diff.patch` when a stable diff can be captured

Do not push, create a PR, or continue beyond Claude review unless the user explicitly asks.

## Minimal B -> C handoff shape

Use this shape in `handoffs.md`, `README.md` next action, and the final response whenever the next step is Claude Code review:

```text
/goal-code-review

Task folder:
~/.tasks/<scope>/<task-key>/

Review prompt:
~/.tasks/<scope>/<task-key>/claude-review-prompt.md
```

## Minimal review-packet shape

```md
# Review Packet: <task-key>

## Review target
- Implementation/review base: <base>
- Head: <review commit hash, or explicit uncommitted blocker>
- Diff command: `git diff <base>...<head>`

## PR target
- Base branch: <branch final PR should target>

## Intent
<what the implementation is meant to accomplish>

## Implementation summary
- <key change>

## Changed files
- `<path>` — <why>

## Verification evidence
- `<command>` — <result>

## Self-review
- Scope matched spec: <yes/no + note>
- Do Not Touch respected: <yes/no + note>
- Done When covered: <yes/no + note>
- No obvious debug/secrets/unrelated churn: <yes/no + note>

## Known gaps / risks
- <none or explicit gap>

## Review focus
1. <most important invariant>
2. <second invariant>
```

## Minimal claude-review-prompt shape

Write this file at `claude-review-prompt.md` before stopping:

````md
# Claude Code Deep Review Prompt: <task-key>

You are the C session in a multi-session workflow. Use your normal deep-code-review judgment for this implementation.

## Inputs
- Task folder: `~/.tasks/<scope>/<task-key>/`
- Source repo/worktree: `<path>`
- Implementation/review base: `<base branch or commit>`
- PR target base: `<branch final PR should target>`
- Head: `<head branch or commit>`
- Diff command: `<git diff command>`

## Read first
1. `README.md`
2. `spec.md`
3. `review-packet.md`
4. `verification.md` if present

## Review rules
- Do not edit source code.
- Do not commit, push, create branches, or open a PR.
- Treat `spec.md` as the source of truth.
- Write the final review to `~/.tasks/<scope>/<task-key>/review.md`.

## Output
Use whatever finding format your deep-code-review workflow normally uses.
Please make the final state clear enough for the B session to decide one of:
- apply fixes from `review.md`
- proceed to PR
````

## Final response

Report only:

- task folder
- branch/worktree
- review commit or explicit no-commit blocker
- changed files summary
- verification evidence
- review-packet path
- claude-review-prompt path
- next Claude Code command block, explicitly using `/goal-code-review` with task folder and review prompt paths
