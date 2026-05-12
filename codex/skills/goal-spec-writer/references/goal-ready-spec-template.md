# Goal Spec Template

Use this template for Markdown specs that are ready to paste into Codex `/goal`.

```md
# Goal Spec: <short title>

## Goal
<One concrete outcome. Phrase as the final user-visible/system behavior, not just files to edit.>

## Target Context
- Repo/worktree: `<path>`
- Base branch/commit: `<branch or commit>`
- Target branch: `<branch>`
- Related tickets/PRs: `<IDs/URLs>`

## Background / Evidence
- <Jira/user symptom evidence>
- <PR/history evidence>
- <Code evidence with file refs>
- <Data/log evidence if available>

## Root-cause Hypothesis
<Separate proven evidence from inference. Include confidence.>

## Editable Scope
The goal agent may edit only these areas unless tests prove a direct dependency requires a small widening:

- `<file/module>` — <why>

## Read-only Context
The goal agent may inspect but should not edit by default:

- `<file/module>` — <why>

## Do Not Touch
- <unrelated domains>
- <infra/config/prod data/migrations unless explicitly allowed>
- <broad refactors or style-only rewrites>

## Constraints
- Preserve existing public/API contracts unless this spec explicitly changes them.
- Prefer root-cause fix over symptom patch.
- Keep diff small and reversible.
- Add/update regression tests before or alongside behavior changes.
- Do not introduce dependencies without explicit approval.

## Implementation Guidance
1. <First bounded step>
2. <Second bounded step>
3. <Edge cases to cover>

## Verification Loop
Run the narrowest meaningful checks first, then widen only as needed:

1. `<targeted test command>`
2. `<service/module test command>`
3. `<lint/typecheck/build command if relevant>`

If a check fails, inspect the failure, patch only the relevant scope, and rerun until passing or blocked.

## Done When
- <Behavior criterion>
- <Regression criterion>
- <Verification evidence criterion>
- <No known introduced errors>

## Stop / Escalate If
- <Writable scope must expand outside Editable Scope>
- <Product contract ambiguity appears>
- <Migration/prod data/destructive action is required>
- <Tests reveal unrelated pre-existing failure that blocks proof>

## Copy-paste `$goal-runner` Handoff

```text
$goal-runner

Task folder:
~/.tasks/<repo-slug>/<task-key>/
```

### Manual `/goal` fallback

Use only if `$goal-runner` is unavailable:

```text
/goal

Read task folder ~/.tasks/<repo-slug>/<task-key>/.
Use README.md and spec.md as the source of truth.
Implement the task.
Before stopping, update README.md and write review-packet.md with implementation summary and verification evidence.
Stop at ready-for-external-review for Claude Code deep-code-review. Do not create a PR yet.
```
```
