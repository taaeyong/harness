---
name: goal-spec-writer
description: Turn an existing task brief, investigation notes, Jira/PR analysis, or handoff into a goal-ready Codex /goal spec, durable ~/.tasks folder, and copy-paste session handoff prompts. Use when preparing autonomous /goal work, splitting sessions, coordinating Codex/Claude review handoffs, or reducing destructive risk before handing coding work to a long-running agent.
---

# goal-spec-writer

Convert a pre-existing brief into a **goal-ready execution spec** plus a small persistent task folder. This skill is not a broad planning workshop; it is a compiler that makes `/goal` safer by grounding the task in evidence, limiting writable scope, defining verification, and giving later Codex/Claude sessions a shared source of truth.

## Core stance

- Prefer **refining the user's existing spec** over inventing a new plan.
- Treat `/goal` as powerful and potentially destructive: narrow the scope before making it autonomous.
- Use codebase evidence and prior investigation notes before asking questions.
- Ask only when the editable boundary, destructive permission, or acceptance criteria is materially ambiguous.
- Output a durable task folder with `README.md`, `spec.md`, and `handoffs.md`, plus a short `$goal-runner` handoff prompt for the implementation session.

## Inputs to collect

Use available context first:

- Existing handoff/spec/notes/Jira/PR links or summaries
- `task-key` if the user already has one
- Branch policy:
  - implementation/review base branch or commit (where the work starts and what Claude reviews against)
  - PR target base branch (where the PR must merge, usually the repo default such as `main`)
  - target implementation branch/worktree name
- Affected tickets and user-visible symptoms
- Current root-cause hypothesis with evidence vs inference
- Candidate files/modules
- Desired stop condition and tests

If the user gives only a vague request, run a brief interview before writing the spec.

## Workflow

### 1. Establish task identity

Choose a stable `task-key`; it is the primary identifier for the task, not necessarily a ticket ID.

Priority:

1. Explicit user-provided `task-key`
2. Existing ticket/issue key, normalized to lowercase hyphen form (`QA-550` -> `qa-550`)
3. A short slug from the objective (`cleanup-credit-domain`, `stabilize-preview-ci`)

Determine `repo-slug` from the current git root directory name unless the task is explicitly multi-repo. For multi-repo tasks, use a project/org slug such as `myorg`.

Default task folder:

- Single repo: `~/.tasks/<repo-slug>/<task-key>/`
- Multi-repo: `~/.tasks/<project-or-org>/<task-key>/`

Do not put task state under the repository unless the user explicitly asks; repo-local task files can drift across worktrees and leak into PR diffs.

### 2. Bootstrap or update the task folder

Create or update:

- `README.md` — current status board and next action
- `spec.md` — the goal-ready execution spec
- `handoffs.md` — copy-paste prompts for A/B/C/PR session transfers
- `artifacts/` — optional logs, diffs, screenshots, or command output

Do not create a long `goal-prompt.md` by default. The implementation handoff should be a short `$goal-runner` prompt that points at the task folder and lets `spec.md` carry the detailed requirements.

Minimum `README.md` sections:

```md
# Task: <task-key>

## Status
ready-for-implementation

## Objective
<one-line objective>

## Repo / Scope
- Repo: <path or repo name>
- Implementation/review base: <branch/commit>
- PR target base: <branch, usually main/default>
- Branch: pending
- Worktree: pending

## Artifacts
- spec.md: complete
- handoffs.md: complete
- review-packet.md: pending
- claude-review-prompt.md: pending
- review.md: pending
- fix.md: pending
- verification.md: pending
- pr.md: pending

## Next action
B session: run `$goal-runner` with this task folder, implement, self-review, then update README.md, review-packet.md, and claude-review-prompt.md. Stop at ready-for-external-review.
```

Minimum `handoffs.md` sections:

````md
# Session Handoffs: <task-key>

## A -> B: Implementation session
```text
$goal-runner

Task folder:
~/.tasks/<repo-slug>/<task-key>/
```

## B -> C: Claude Code deep-code-review
```text
Read and execute:
~/.tasks/<repo-slug>/<task-key>/claude-review-prompt.md
```

## C -> B: Apply review fixes
```text
$goal-runner

Task folder:
~/.tasks/<repo-slug>/<task-key>/
Apply review.md fixes only. Keep spec.md as the source of truth.
Update fix.md, verification.md, review-packet.md, and README.md.
```

## B -> PR: Publish after review
```text
$x-pr

Task folder:
~/.tasks/<repo-slug>/<task-key>/
Use README.md, spec.md, review-packet.md, review.md, fix.md, and verification.md for PR context.
Use the task's PR target base; do not reuse the implementation/review base unless they are explicitly the same.
```
````

The B -> C prompt is allowed to be a placeholder until `$goal-runner` writes the concrete `claude-review-prompt.md` with branch, base, head, and diff details.

### Branch policy rule

Always separate **implementation/review base** from **PR target base**:

- Implementation/review base is the commit or branch used for local work and Claude review diffs.
- PR target base is the branch the final PR should merge into.
- Do not assume they are the same. A feature-branch review base may still need a PR into `main`.
- If the user did not specify a PR target and the implementation/review base is not the repo default branch, ask one concise question before finalizing the spec.
- If the repo default branch is the obvious target and the user gave no conflicting instruction, set `PR target base` to the remote default branch and record that assumption.

### 3. Read the current brief

Identify:

- target outcome
- included tickets/symptoms
- evidence already established
- likely implementation surface
- risks from autonomous execution

### 4. Map the codebase boundary

Inspect the repository enough to separate:

- **Editable Scope**: files/modules the goal agent may change
- **Read-only Context**: files/modules it may inspect but should avoid editing
- **Do Not Touch**: unrelated domains, migrations, production data, infra, or broad refactors

Prefer exact file paths and function/class names. If the boundary is uncertain, mark it under `Needs Confirmation` or ask a short question.

### 5. Apply the safety gate

Ask at most 1–3 concise questions only if one of these is true:

- the implementation might require destructive/irreversible actions
- database migration, production data, or external side effects might be required
- multiple mutually exclusive product contracts are plausible
- the writable scope is unclear enough that `/goal` may over-edit
- the PR target base is unclear, especially when the implementation/review base is a non-default branch

Otherwise, proceed with explicit assumptions.

### 6. Compile the goal-ready spec

Use `references/goal-ready-spec-template.md` as the output shape.

The final spec must include:

- Goal
- Background / Evidence
- Root-cause hypothesis
- Branch Strategy: implementation/review base, PR target base, and implementation branch/worktree
- Editable Scope
- Do Not Touch
- Constraints
- Implementation Guidance
- Verification Loop
- Done When
- Stop / Escalate If
- Copy-paste `$goal-runner` handoff prompt
- Session handoff guide in `handoffs.md`

The copy-paste `$goal-runner` handoff prompt should be short and pointer-based, for example:

```text
$goal-runner

Task folder:
~/.tasks/<repo-slug>/<task-key>/
```

Include a manual `/goal` fallback only if `goal-runner` is unavailable.

### 7. Rubric-check before finalizing

Load `references/safety-boundary-rubric.md` when the task is bugfix/refactor work or has broad blast radius.
Load `references/official-prompting-principles.md` when the user asks for OpenAI/Codex-prompting alignment or the output will be reused as a prompt standard.

Before handing off, confirm the spec:

- is actionable without more context
- has narrow write scope
- names non-goals
- defines tests/evidence
- prevents broad cleanup or opportunistic rewrites
- includes a clear stop/escalation condition

## Output style

- Default canonical save location is the user-level task folder, not the repository: `~/.tasks/<repo-slug>/<task-key>/`.
- Write the durable goal spec to `~/.tasks/<repo-slug>/<task-key>/spec.md`.
- Write or update the task status board at `~/.tasks/<repo-slug>/<task-key>/README.md`.
- Write or update the session transfer prompts at `~/.tasks/<repo-slug>/<task-key>/handoffs.md`.
- Legacy mirrors are optional: use `~/.codex/goal-specs/...` or repo-local `.omx/plans/goal-spec-<slug>.md` only when the user asks or when an existing workflow requires it.
- If the spec should be committed/reviewed with product code, the user must explicitly ask for a repo `docs/` path; do not assume repo documentation is wanted.
- Also summarize the task folder path, branch strategy, `spec.md` path, `README.md` path, `handoffs.md` path, and the exact short `$goal-runner` handoff block.
- Keep the user-facing response concise; the Markdown file can be detailed.
