---
name: x-pr
description: Create ready-for-review AI-native GitHub pull requests from local changes. Use when the user says /x-pr, x-pr, AI PR 만들어줘, PR 올려줘, ready PR, CodeRabbit 돌게 PR, or asks Codex to commit, push, and open a reviewable PR with structured context instead of a draft.
---

# x-pr — Codex AI-Native PR Automation

Use this skill to publish local changes as a **ready-for-review PR by default**. It is optimized for AI-assisted work where reviewers need the request, behavior change, risks, and verification evidence captured in the PR body.

## Non-negotiables

- Create a **ready PR**, not a draft, unless the user explicitly says draft.
- Do not stage unrelated files silently. Inspect scope first and stage explicit paths.
- Prefer `gh` for PR creation so CodeRabbit and normal review automation can start immediately.
- Follow the repo's AGENTS.md. If an OMX Lore commit protocol is active, it overrides conventional-commit-only guidance.
- Never include secrets, `.env`, credentials, generated caches, or local state files unless explicitly intended.

## Workflow

### 1. Inspect scope

Run:

```bash
git status -sb
git diff --stat
git diff --name-only
```

Then inspect relevant diffs. If the worktree is mixed, stage only the files that match the user's requested PR scope. Ask only when scope is genuinely ambiguous or staging may include unrelated/destructive changes.

### 2. Choose branch

- If already on a feature branch, stay there.
- If on `develop`, `main`, `master`, or the remote default branch, create `codex/{kebab-intent}`.
- If the user specified a branch name, use it.

### 3. Validate before commit

Run the narrowest meaningful checks for the changed area. Prefer commands already used in the repo or provided by the user. If full lint is known to fail from repo-wide existing issues, run scoped tests/build/typecheck and record the limitation honestly.

### 4. Commit

Use an intent-first commit message. When OMX Lore enforcement is active, use inline `git commit -m ...` paragraphs so pre-tool hooks can inspect it; avoid `-F`/editor commits in Codex.

Required shape under Lore:

```bash
git commit -m "<why this change exists>" \
  -m "<narrative context: constraints, approach, rollout rationale>" \
  -m "Constraint: <external constraint>" \
  -m "Rejected: <alternative> | <reason>" \
  -m "Confidence: <low|medium|high>" \
  -m "Scope-risk: <narrow|moderate|broad>" \
  -m "Directive: <future maintainer guidance>" \
  -m "Tested: <commands/evidence>" \
  -m "Not-tested: <known gaps>" \
  -m "Co-authored-by: OmX <omx@oh-my-codex.dev>"
```

If the repo does not require Lore, use the local convention, usually `feat:`, `fix:`, `refactor:`, or `chore:`.

### 5. Push

```bash
git push -u origin "$(git branch --show-current)"
```

### 6. Open a ready PR

Use `develop` as the default base when that is the repo default or project convention; otherwise use the remote default branch unless the user specified a base.

Create a ready PR, not draft:

```bash
gh pr create --base <base> --head "$(git branch --show-current)" --title "<reviewable title>" --body-file <tmp-pr-body.md>
```

Do **not** pass `--draft` unless the user explicitly asked for a draft PR.

## PR Body Template

Use this template. Keep it concrete and evidence-based.

```markdown
## Request

> {Summarize the user's original request in 1-2 lines.}
> {Include important decisions clarified during the conversation.}

## Changes

{Describe behavior changes, not just files edited.}

- ...
- ...

## Breaking Changes

{Write "없음" if none. If present, include migration guidance.}

| Item | Before | After |
|------|--------|-------|
| ... | ... | ... |

**Migration**: ...

## Concerns

{Be honest about uncertainty, rollout risks, review points, and known limitations. Write "없음" if none.}

- [ ] ...

## Scope Boundaries

{List intentionally excluded work, follow-up PRs, and things not changed.}

- ...

## Review Guide

- **Core logic**: `path/to/file.ts` — why this is the key area.
- **Review carefully**: ...
- **Skimmable**: ...

## Verification

- `<command>` — ✅ <specific result, e.g. N tests passed>
- `<command>` — ⚠️ <if skipped or blocked, explain why>

🤖 Generated with Codex/OMX
```

## Final response to user

After creating the PR, report only what matters:

- PR URL, base, branch, and commit SHA
- ready/draft status
- checks run and results
- files or areas changed
- remaining risks / what reviewers should check
