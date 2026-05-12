---
name: deep-code-review
description: |
  Deep multi-agent code review for Codex. Defaults to branch-vs-base diff; falls back to whole-codebase audit when no branch context (already on base, empty diff, or the user passes `full`). Use for deep review, pre-merge validation, or full project audit.

  Trigger words: "deep review", "code review", "audit this codebase", "review branch vs main", "review working tree".
---

# Deep Code Review

Analyze code against the full codebase context, git history, and project purpose. Determine whether the code is **justified, coherent, and safe** — going far beyond surface-level review.

Modeled after [Anthropic's official Code Review](../../docs/etc/claude-code-review/overview.md) multi-agent architecture (parallel specialized agents → critic verification → dedup & rank → report), adapted for local analysis without GitHub integration. Dispatched through Codex's [subagent](https://developers.openai.com/codex/subagents) support, following the PR-review pattern from the official Codex subagents guide (`pr_explorer` + `reviewer` + `docs_researcher`), generalized to 5 dimensions.

Operates in one of two modes, selected automatically from the user's request + real repo state:

- **Branch Mode** — reviews branch-vs-base diff, or the uncommitted working tree when no commits are ahead of base.
- **Full Codebase Mode** — audits the entire repository as a fresh codebase. Triggered when already on base with a clean tree, when the base can't be resolved, or when the user passes `full`.

## Input

Parse the user's invoking message for the mode hint:

- If the message contains the literal token `full`, `all`, `codebase`, or `whole` → Full Codebase Mode.
- Otherwise, treat any branch-looking token (e.g., `main`, `develop`, `origin/main`) as the **base branch**; default to `main` if none is given.

## Philosophy

Ordinary code review asks "is this code correct?" Deep code review asks:

- **Why** was this change made? Does the intent align with project goals?
- **What** existing patterns does it break or follow?
- **Where** does it create hidden coupling or architectural drift?
- **When** combined with the rest of the codebase, does it still make sense?
- **How** are new concepts named? Do they communicate intent clearly?

Default focus is **correctness** — bugs that would break production. Formatting preferences and style nits are noise unless `AGENTS.md` or `REVIEW.md` explicitly requires them.

## Workflow

### Phase 1: Context Gathering

Build a full picture of the work being reviewed and project conventions.

#### Step 1.1: Mode Detection

Decide whether this run is Branch Mode or Full Codebase Mode **before** doing any other work. Mode selection combines the parsed user hint with the actual repo state.

Run this shell block (adapt `ARG` to the token you parsed from the user's message):

```bash
ARG="${ARG:-main}"  # set from the parsed user hint, default 'main'

# 1) Explicit override: user passed 'full' / 'all' / 'codebase' / 'whole' → Full Codebase Mode.
case "$ARG" in
  full|all|codebase|whole|--full)
    MODE="full"
    BASE=""
    ;;
  *)
    BASE="$ARG"
    # Verify the base branch exists locally; if not, try origin/<base>; otherwise fall back to full mode.
    if git rev-parse --verify --quiet "$BASE" >/dev/null; then
      :
    elif git rev-parse --verify --quiet "origin/$BASE" >/dev/null; then
      BASE="origin/$BASE"
    else
      echo "Base '$ARG' not found locally or on origin — falling back to Full Codebase Mode."
      MODE="full"
      BASE=""
    fi
    ;;
esac

# 2) Decide between committed-branch review, working-tree review, and full audit.
if [ -z "$MODE" ]; then
  COMMITS_AHEAD="$(git rev-list --count "$BASE"..HEAD 2>/dev/null || echo 0)"
  WORKING_TREE_DIRTY="$(git status --porcelain 2>/dev/null)"

  if [ "$COMMITS_AHEAD" -gt 0 ]; then
    # Feature branch with commits vs base — the original use case.
    MODE="branch"
    BRANCH_VARIANT="committed"
    DIFF_SPEC="$BASE...HEAD"
    LOG_SPEC="$BASE..HEAD"
  elif [ -n "$WORKING_TREE_DIRTY" ]; then
    # No commits ahead, but uncommitted work exists — review the working tree against HEAD.
    MODE="branch"
    BRANCH_VARIANT="working-tree"
    DIFF_SPEC="HEAD"
    LOG_SPEC=""  # no committed arc to inspect
  else
    # Clean tree, already on base → whole-codebase audit.
    MODE="full"
  fi
fi

echo "Mode: $MODE"
if [ "$MODE" = "branch" ]; then
  echo "Branch variant: $BRANCH_VARIANT"
  echo "Base: $BASE"
  echo "Diff spec: $DIFF_SPEC"
fi
```

**Decision rule**: `MODE=branch` → Step 1.2A; `MODE=full` → Step 1.2B. Phases 2–6 adapt per the **Agent Behavior by Mode** table below. Branch Mode has two variants — `committed` (feature branch with commits ahead of base, diff=`$BASE...HEAD`) and `working-tree` (no commits ahead but staged/unstaged changes exist, diff=`HEAD`). In `working-tree` there is no commit arc, so Agent 1 runs in its Full-Mode *Project Purpose* form.

#### Step 1.2A: Branch Mode context

```bash
# Changes being reviewed
[ -n "$LOG_SPEC" ] && git log --oneline "$LOG_SPEC"   # committed variant only
git diff "$DIFF_SPEC"
git diff --name-only "$DIFF_SPEC"
git diff --stat "$DIFF_SPEC"

# Project history (recent commits on base)
git log --oneline -20 "$BASE"

# Convention files — root level
cat AGENTS.md 2>/dev/null || echo "No AGENTS.md found"
cat REVIEW.md 2>/dev/null || echo "No REVIEW.md found"
```

**Directory-level `AGENTS.md` hierarchy**: Codex loads `AGENTS.md` files along the path from the repo root to the current working directory, merging from root down (closer files override earlier). For each directory containing changed files, check for a local `AGENTS.md`. Rules in a subdirectory's `AGENTS.md` apply to files under that path and override higher-level guidance. Collect all of them.

```bash
# For each changed directory, check for local AGENTS.md
git diff --name-only "$DIFF_SPEC" | xargs -I{} dirname {} | sort -u | while read dir; do
  [ -f "$dir/AGENTS.md" ] && echo "=== $dir/AGENTS.md ===" && cat "$dir/AGENTS.md"
done
```

> Codex also supports `AGENTS.override.md` and any `project_doc_fallback_filenames` entries (see [Project instructions discovery](https://developers.openai.com/codex/config-advanced#project-instructions-discovery)). If the repo uses those, treat them with the same precedence: override beats base, closer directory beats farther.

#### Step 1.2B: Full Codebase Mode context

There is no diff to anchor on — you are auditing the project as a whole. Build a structural map and load all convention files first, then let the agents pick what to read deeply.

```bash
# Repo shape
git log --oneline -20
git ls-files | wc -l
git ls-files | sed 's|/[^/]*$||' | sort -u | head -50  # top-level + nested directories

# Hotspots: files touched most often in recent history (good targets for risk/regression analysis).
# Try the 6-month window first; fall back to the last 500 commits for low-activity or newly-cloned repos.
HOTSPOTS="$(git log --pretty=format: --name-only --since='6 months ago' 2>/dev/null | grep -v '^$' | sort | uniq -c | sort -rn | head -30)"
if [ -z "$HOTSPOTS" ]; then
  HOTSPOTS="$(git log -500 --pretty=format: --name-only 2>/dev/null | grep -v '^$' | sort | uniq -c | sort -rn | head -30)"
fi
printf '%s\n' "$HOTSPOTS"

# Convention files — every AGENTS.md / REVIEW.md in the repo
find . -name AGENTS.md -not -path '*/node_modules/*' -not -path '*/.git/*'
find . -name REVIEW.md -not -path '*/node_modules/*' -not -path '*/.git/*'
cat AGENTS.md 2>/dev/null || echo "No root AGENTS.md found"
cat REVIEW.md 2>/dev/null || echo "No root REVIEW.md found"
```

Enumerate source files by language (e.g., `**/*.{ts,tsx,js,py,go,rs}`) so the agents know what surface area exists. Do **not** try to read every file — pick by hotspot, by entry point (`main.*`, `index.*`, `app.*`, `cli.*`), and by convention-file proximity.

**If `REVIEW.md` exists** (in either mode), parse its prioritize/deprioritize sections to calibrate what the agents focus on and what they skip.

### Adaptive Depth

Scale review thoroughness with the size of the work being reviewed.

**Branch Mode** — scale by diff size:

| Diff Size | Agent Behavior |
|-----------|---------------|
| **Small** (<50 lines) | Focused analysis. Agents read only directly related files. Skip Agent 1 (Intent) if single commit with clear message. |
| **Medium** (50-500 lines) | Standard analysis. All 5 agents run. Read surrounding context for each changed file. |
| **Large** (500+ lines) | Deep analysis. Agents trace full call chains, read all callers/importers of changed modules, check for multi-file regressions extensively. |

**Full Codebase Mode** — scale by repo size (use `git ls-files | wc -l`):

| Repo Size | Agent Behavior |
|-----------|---------------|
| **Small** (<100 source files) | All 5 agents read every source file (excluding generated, vendored, lockfiles). |
| **Medium** (100-1000 source files) | Agents prioritize by: hotspot files (high churn), entry points, modules referenced by `AGENTS.md`, and one representative file per package/directory. Skim the rest for pattern violations. |
| **Large** (1000+ source files) | Agents pick a focused slice: top 20 churn hotspots, all entry points, all config/security-sensitive files, plus a sampled traversal. Report explicitly notes the slice that was reviewed and what was deferred. |

### Phase 2: Deep Analysis

Spawn **5 parallel subagents** — one per review dimension. Codex supports subagent workflows ([docs](https://developers.openai.com/codex/subagents)) and only spawns them when explicitly asked, so the main orchestrator must request fan-out in one message.

**How to spawn** (pick whichever applies to the session):

1. **Built-in `explorer` agent (read-only)** is the right default for each analysis subagent — every dimension here is read-only investigation. Example prompt shape:

   > Spawn five `explorer` subagents in parallel, one per analysis dimension below, and wait for all results before returning. Give each agent the full diff, changed-file list, commit log, and the contents of every relevant `AGENTS.md` / `REVIEW.md`. Dimensions: (1) Intent & Justification … (5) Completeness & Historical Context.

2. **Custom agents** defined in `.codex/agents/*.toml` or `~/.codex/agents/*.toml` (e.g., a `reviewer` agent with `model_reasoning_effort = "high"` and `sandbox_mode = "read-only"`). If the repo ships review-oriented custom agents, prefer them — they already encode the right model and sandbox posture.

Each subagent inherits the parent sandbox policy and approval mode. Keep subagents in **read-only** sandbox for this skill; there is no reason for review agents to write files.

If subagents aren't available in the current Codex surface (e.g., IDE extension until that ships), fall back to running the five analyses sequentially in the main agent, in the same order, producing the same outputs.

#### Agent Behavior by Mode

For Branch Mode each agent receives the full diff, file list, and commit history — analyze only what changed (and its blast radius across other files). For Full Codebase Mode there is no diff anchor, so each agent's responsibility shifts:

| Agent | Branch Mode focus | Full Codebase Mode focus |
|-------|-------------------|--------------------------|
| **1. Intent & Justification** | Are commits coherent? Does the branch achieve a clear purpose? | **Re-scoped to *Project Purpose*.** Read `README`, root `AGENTS.md`, and top-level entry points (`main.*`, `index.*`, `app.*`, `cli.*`) to verify the codebase as-built matches its stated purpose. Score 1–10 as normal. Only skip entirely if no purpose-defining doc exists — in that case the dimension is dropped from the overall average (see Scoring Guide). Also used by the Branch Mode `working-tree` variant, which has no commit arc to inspect. |
| **2. Architectural Coherence** | Do changes follow existing patterns? Are all callers updated? | Map the actual module graph. Find inconsistencies (multiple ways to do the same thing), broken layering, circular dependencies, dead modules, modules with no callers, abstractions that leak. |
| **3. Naming & Semantics** | Are newly-introduced names accurate and consistent? | Sample identifiers across modules. Find domain-language drift (e.g., `user`/`account`/`member` mixed for the same concept), naming-convention inconsistencies, vague names in public APIs. |
| **4. Risk & Safety** | Does this change add risk? Secrets in the diff? | Scan the entire codebase for: hardcoded secrets, unsafe patterns (SQL injection, command injection, XSS), missing input validation at boundaries, missing auth checks, race conditions, unbounded resource usage, error swallowing. |
| **5. Completeness & Historical Context** | Were all callers updated? Are tests added? | Find TODOs/FIXMEs/XXX, dead code, orphaned files, stale `AGENTS.md` statements (does the doc still describe the actual code?), missing tests for critical modules, hotspot files with no test coverage. |

Phases 3–6 apply identically in both modes. The Agent 1–5 subsections that follow are the **Branch Mode baseline**; when running Full Mode (or the `working-tree` Branch variant) treat them as the substance of each agent's checks but apply the focus/scope shift from the table above, reading "the diff" / "this branch" / "modified files" as "the reviewed slice".

#### Agent 1: Intent & Justification Analyzer

Examine every change and answer:

- Does each commit message accurately describe what was changed?
- Is there a clear, coherent purpose across all commits?
- Are there changes that seem unrelated to the stated intent (scope creep)?
- Are there commits that contradict each other (churn)?
- Would a reviewer understand **why** these changes exist without asking?
- If the branch has multiple commits, does the commit sequence tell a logical story?

Score: How well-justified is this branch? (1-10)

#### Agent 2: Architectural Coherence & Cross-File Analyzer

This is the most critical agent. The key differentiator of deep review is reasoning **across files**, not just within the diff.

**Pattern consistency**:
- Does the change follow existing patterns in the codebase?
- Does it introduce new patterns that conflict with established ones?
- Are imports, dependencies, and module boundaries respected?
- Does it create circular dependencies or hidden coupling?
- Is abstraction level consistent with surrounding code?

**Cross-file dependency analysis** (read actual source files, trace imports and callers):
- Do the changes break assumptions in other files that depend on the modified code?
- If a function signature, return type, or behavior changed — are **all callers** updated?
- If a new parameter was added in one file, is the corresponding state and logic updated **everywhere** it needs to be?
- Does the change affect shared state, configs, or constants used by other modules?

**Parameter/state path completeness**:
- Is every new parameter or state path handled at every point in its lifecycle?
- Are new enum values, config options, or feature flags handled in all switch/match statements?
- If a new error type was introduced, is it caught everywhere it can be thrown?

**Convention compliance**:
- Do changes comply with `AGENTS.md` and `REVIEW.md` guidelines? Verify by reading the actual files — do not assume.
- Check directory-level `AGENTS.md` rules for files in subdirectories, remembering that closer files override farther ones in Codex's merge order.

Read actual source files — do NOT guess patterns from filenames alone.

Score: How architecturally coherent are the changes? (1-10)

#### Agent 3: Naming & Semantics Analyzer

For every newly introduced name in the diff (variables, functions, classes, fields, parameters, constants, types, DB columns, API fields, config keys, file names):

**Accuracy**

- Does the name accurately describe what it represents?
- Flag vague names (`data`, `info`, `temp`, `result`, `val`, `item`, `obj`) when a more specific name exists.
- Could the name be misleading? (e.g., `isValid` that returns a string, `count` that holds a list, `getUserName` that also fetches email)

**Convention consistency** — Read sibling code to verify, don't assume:

- Is it consistent with the naming convention of its surroundings? (camelCase vs snake_case vs PascalCase)
- Does it match the domain language used elsewhere in the codebase? (e.g., if the project says `user` don't introduce `account` for the same concept)
- Are abbreviations consistent with existing ones? Don't introduce `msg` if the project uses `message`.

**Semantic correctness**

- Is the abstraction level of the name appropriate? (e.g., `handleClick` in a domain layer vs `submitOrder`)
- For booleans: does it read naturally as a predicate? (`isActive`, `hasPermission`, `canEdit` — not `active`, `permission`, `edit`)
- For collections: is it pluralized or does it indicate plurality? (`users`, `itemList`, `orderMap` — not `user` for an array)
- For functions: does the verb accurately describe the action? (`fetch` vs `get` vs `compute` vs `find` — each implies different behavior)

Score: How well-named are new identifiers? (1-10)

#### Agent 4: Risk & Safety Analyzer

Identify potential risks:

- **Regression risk**: Does this change affect critical paths? Check git blame to see how frequently touched files are.
- **Silent regression**: Could this change break existing behavior without any test or caller failing? Trace downstream effects through the actual call chain — not just the diff.
- **Data safety**: Any changes to data models, migrations, or storage? Are migrations backward-compatible?
- **Security**: New inputs, auth changes, permission modifications? Do error messages leak internal details to users?
- **Secrets & credentials**: Hardcoded API keys, tokens, passwords, private keys, connection strings, or `.env` values in the diff? Flag ANY string that looks like a secret (high-entropy strings, `sk-`, `AKIA`, `ghp_`, `-----BEGIN`, base64-encoded blobs). Also check if new files like `.env`, `credentials.json`, `*.pem`, `*.key` are being committed.
- **Performance**: N+1 queries, missing indexes, unbounded loops, large allocations?
- **Concurrency**: Race conditions, deadlocks, shared state mutations?
- **Error handling**: Silent failures, swallowed errors, missing rollbacks?
- **Edge cases**: Boundary conditions, empty inputs, Unicode, timezone issues?
- **Idempotency**: For webhook handlers, async jobs, retry-able operations — can they safely run multiple times?

Score: Risk level of these changes (1-10, where 10 = very risky)

#### Agent 5: Completeness & Historical Context Analyzer

**Completeness check**:

- Are there TODOs, FIXMEs, or placeholder code left behind?
- If a function signature changed, were all callers updated? (Cross-reference with Agent 2)
- If a config option was added, is it documented?
- If tests were needed, were they added?
- If an API changed, were clients/consumers updated?
- Are there dead code artifacts from refactoring?
- Do error messages match the actual error conditions?
- Do code comments in modified files still accurately describe the code after the change?
- **`AGENTS.md`/`REVIEW.md` freshness**: Do the changes make any existing `AGENTS.md` or `REVIEW.md` statements outdated? If so, flag that documentation needs updating. (This is bidirectional — violations of `AGENTS.md` are nits, but changes that make `AGENTS.md` stale are also flagged.)

**Historical context check**:

- Read git blame and history of modified files — are there patterns or constraints from past changes that this branch violates?
- Check if similar changes were previously reverted or had issues.
- Look at code comments in modified files for guidance that the changes should comply with.
- Check if the modified files have had frequent recent changes (hotspot) — high churn files deserve extra scrutiny.

Score: How complete and historically informed is the work? (1-10)

### Phase 3: Verification (Critic Agent)

After all 5 analysis agents complete, launch a **verification agent** (one more `explorer` subagent, or the orchestrator itself if subagents aren't available) that acts as an adversarial critic. This is the false-positive elimination step.

For each candidate issue reported by the analysis agents:

1. **Re-read the actual code** at the reported location — does the issue genuinely exist?
2. **Check if it's pre-existing** *(Branch Mode only)* — was this already present before the reviewed slice? Use `git show "$BASE":path/to/file` in the `committed` variant, or `git show HEAD:path/to/file` in the `working-tree` variant (because the slice there is the uncommitted diff against HEAD, not against the base). In Full Codebase Mode every finding is by definition "pre-existing" — skip this step and let severity be driven by real impact instead.
3. **Verify cross-file impact** — if the issue claims something breaks downstream, trace the actual call chain. Read the downstream code.
4. **Falsify the finding** — actively try to disprove it, don't just re-confirm it. Construct the simplest concrete scenario (specific input, specific config, specific data shape, specific timing) under which the finding would have to matter, then trace that scenario through the real code and data. If you can't construct one, the finding is structural-only and must be downgraded or dropped. *"The call path exists"* is necessary but not sufficient — verify that the data flowing through the path makes the impact real. Re-confirming the same hypothesis in the same head is not falsification.
5. **Check `REVIEW.md` deprioritize rules** — if the issue falls under a deprioritized category, demote or discard it.
6. **Assign severity and confidence** — using the scales below.

This step exists to catch false positives that individual agents may produce when analyzing in isolation. Most false positives at this stage come from one mistake: confirming a structural change exists without checking whether the data flowing through it makes the change matter.

### Phase 4: Severity & Confidence Classification

#### Severity (per issue)

| Level | Label | Meaning |
|-------|-------|---------|
| 🔴 | **Normal** | Bug or issue that should be fixed before merging (Branch Mode) or fixed promptly (Full Codebase Mode) |
| 🟡 | **Nit** | Minor issue, worth fixing but not blocking. `AGENTS.md` violations default to this level. |
| 🟣 | **Pre-existing** | *Branch Mode only.* Bug in the codebase not introduced by this branch — flagged only if important enough to note. **Not used in Full Codebase Mode** — all findings there are inherently pre-existing, so report them as 🔴 Normal or 🟡 Nit based on actual severity. |

#### Confidence (per issue, 0-100)

**Confidence is about demonstrated impact, not structural certainty.** A finding can have a 100% accurate call-chain trace and still be a false positive if the data flowing through that chain makes the impact trivial or invisible. Before assigning ≥ 80, you must be able to state the **before/after delta in concrete terms** — one input, one observable difference. "I traced the call path and the change exists" is not enough on its own.

| Score | Meaning |
|-------|---------|
| 0 | False positive — doesn't stand up to scrutiny, or is pre-existing |
| 25 | Might be real, but could be false positive. Stylistic issues not in `AGENTS.md`/`REVIEW.md` |
| 50 | Real issue, but minor. Not important relative to overall changes |
| 75 | Real issue with concrete evidence of impact (specific input → specific wrong/changed observable output, or quoted `AGENTS.md`/`REVIEW.md` violation). Not "the call path exists" — *demonstrated*. |
| 100 | Confirmed real issue. Will happen frequently. Concrete reproduction or directly quoted rule violation. |

**Only report issues with confidence >= 80.** If a finding feels strong but you cannot describe the before/after delta in one concrete line, it is below 80 — fix the analysis or drop the finding.

### False Positive Filters

Discard these before reporting:

- Issues a linter, typechecker, or compiler would catch — assume CI handles these
- Pedantic nitpicks a senior engineer wouldn't flag
- General quality concerns unless explicitly required by `AGENTS.md` or `REVIEW.md`
- Issues silenced by explicit lint-ignore comments
- Items listed in `REVIEW.md`'s deprioritize section
- Formatting, import ordering, and naming-only comments without runtime risk (unless `REVIEW.md` prioritizes them)

**Branch Mode only**:

- Pre-existing issues not introduced in this branch (mark as 🟣 only if important)
- Intentional functionality changes consistent with the branch purpose
- Issues on lines not modified in this branch
- Changes in functionality that are likely intentional or directly related to the broader change

**Full Codebase Mode only**:

- Findings that exist in vendored/generated code (`vendor/`, `node_modules/`, generated protobufs, build artifacts) — these are not project code
- Findings about test fixtures or example code that intentionally contain anti-patterns
- "Could be refactored" suggestions without a concrete impact — Full Mode is even more vulnerable to design-taste noise than Branch Mode, so the impact bar stays at 80+ confidence

### Phase 5: Cross-Reference & Deduplicate

After verification:

1. **Deduplicate** — merge issues that multiple agents found independently. Note when multiple agents flagged the same issue (stronger signal).
2. **Identify overlapping concerns** — issues flagged by multiple agents get higher priority
3. **Resolve contradictions** — if agents disagree, the critic's verification takes precedence
4. **Prioritize by impact** — rank findings by real-world consequence, respecting `REVIEW.md` priority guidance
5. **Verify `AGENTS.md`/`REVIEW.md` references** — if citing a rule, confirm it actually exists and quote verbatim

### Phase 6: Report

Present findings in this format. **In Branch Mode**, use the title `# Deep Code Review: [branch-name]` and include the branch/commits/files-changed lines. **In Full Codebase Mode**, use the title `# Deep Code Review: Full Codebase Audit` and replace the branch overview with the repo overview shown below.

```markdown
# Deep Code Review: [branch-name | "Full Codebase Audit"]

## Overview

<!-- Branch Mode (pick ONE overview block, drop the other) -->
- **Mode**: Branch ([committed | working-tree])
- **Branch**: [name] -> [base]   <!-- working-tree variant: "working tree -> HEAD" -->
- **Commits**: [count]            <!-- omit for working-tree variant -->
- **Files changed**: [count] (+[additions] / -[deletions])
- **Review depth**: [Small / Standard / Deep] based on diff size
- **Review date**: [date]

<!-- Full Codebase Mode -->
- **Mode**: Full Codebase
- **Repo**: [repo name or path] @ [HEAD short sha]
- **Source files reviewed**: [count] of [total] ([sampling strategy if not 100%])
- **Review depth**: [Small / Medium / Large] based on repo size
- **Slice deferred**: [list any directories/files explicitly skipped, or "none"]
- **Review date**: [date]

## Scores

| Dimension               | Score    | Assessment         |
| ----------------------- | -------- | ------------------ |
| Intent & Justification  | X/10     | [one-line summary] |
| Architectural Coherence | X/10     | [one-line summary] |
| Naming & Semantics      | X/10     | [one-line summary] |
| Risk Level              | X/10     | [one-line summary] |
| Completeness            | X/10     | [one-line summary] |
| **Overall**             | **X/10** | **[verdict]**      |

> In **Full Codebase Mode** (and the Branch Mode `working-tree` variant), rename *"Intent & Justification"* to *"Project Purpose"*. If Agent 1 was skipped entirely because no purpose-defining docs exist, drop the row and compute Overall over the remaining four dimensions.

## Critical Issues (must address)

1. 🔴 **[Issue title]** (confidence: XX/100)
   `file/path.ts:42`
   [Brief description]
   <details><summary>Reasoning</summary>

   **Found by**: Agent [N] ([name])
   **Verified by**: Critic agent confirmed by [method]
   **Before/After** (required for impact claims — regression / behavior change / information loss / performance / security / concurrency): for one concrete input, what does the system actually do differently? One line is enough — but it must reference real data, not just call paths.
   [Why this was flagged, how it was verified, what evidence confirms it.
   If cross-file: show the dependency chain.]

   </details>

## Important Findings (should address)

1. 🟡 **[Issue title]** (confidence: XX/100)
   `file/path.ts:15`
   [Brief description]
   <details><summary>Reasoning</summary>

   **Found by**: Agent [N] ([name])
   [Explanation and verification]

   </details>

## Pre-existing Issues (not introduced by this branch)

*Branch Mode only. Omit this section entirely in Full Codebase Mode.*

1. 🟣 **[Issue title]**
   `file/path.ts:88`
   [Brief description — flagged because it's important enough to note]

## Naming Issues

| Location | Current Name | Issue | Suggested |
|----------|-------------|-------|-----------|
| `file.ts:10` | `data` | Vague — holds user preferences | `userPreferences` |

## Documentation Staleness

[Branch Mode: list any `AGENTS.md` or `REVIEW.md` statements that this branch makes outdated. Quote the stale statement and explain what changed.
Full Codebase Mode: list `AGENTS.md` or `REVIEW.md` statements that no longer match the actual code today. Quote the stale statement and point to the file/line that contradicts it.]

## Observations (consider)

[Numbered list of non-blocking observations]

## What's Done Well

[Branch Mode: acknowledge specific things the branch does right.
Full Codebase Mode: acknowledge codebase-wide strengths — good patterns, clean abstractions, thorough handling, healthy areas.]

## Verdict

[Branch Mode: APPROVE / REQUEST CHANGES / NEEDS DISCUSSION
Full Codebase Mode: HEALTHY / MAINTENANCE NEEDED / STRUCTURAL CONCERNS]

[2-3 sentence summary of overall assessment]
```

## Scoring Guide

**Overall score calculation**: Average of (Justification + Coherence + Naming + Completeness + (10 - Risk))

In Full Codebase Mode, **Justification is replaced by Project Purpose** (does the codebase as-built match its stated purpose?). If Agent 1 was skipped entirely, drop the dimension and average over the remaining four.

| Score | Meaning (Branch Mode) | Meaning (Full Codebase Mode) |
|-------|----------------------|------------------------------|
| 9-10 | Excellent — merge confidently | Healthy — only minor maintenance |
| 7-8 | Good — minor issues only | Mostly healthy — focused cleanup needed |
| 5-6 | Acceptable — some concerns to address | Some structural debt — plan remediation |
| 3-4 | Needs work — significant issues found | Significant structural issues — invest before adding features |
| 1-2 | Major concerns — reconsider approach | Major rot — substantial rework warranted |

## Important Rules

- **Read actual code**, not just diffs. Understand context by reading surrounding functions and files.
- **Trace cross-file dependencies**. This is the most valuable thing deep review does. When a function signature, return type, config, or shared state changes, trace every consumer.
- **Compare against real patterns** in the codebase. Don't assume conventions — verify them by reading sibling code.
- **Be specific**. Every finding must include a file path and line number.
- **No false positives**. The critic step must verify every finding. If confidence < 80%, don't report it.
- **Demonstrate impact, don't just trace structure**. For any finding that claims a real-world consequence (regression, behavior change, information loss, performance, security, concurrency, race), tracing the call path is necessary but not sufficient. Examine the *data* flowing through that path and state what observably differs. "Function X is no longer called on this path" is structural; "function X is no longer called on this path, so for input I the user-visible field Y goes from value A to value B" is impact-grounded. Only the second deserves ≥ 80 confidence. The most common false positive at this level is high-confidence structural reasoning that, on inspection of the actual data shape, turns out to change nothing meaningful.
- **Cite sources**. When referencing `AGENTS.md`/`REVIEW.md` rules, quote the exact rule. When referencing codebase conventions, show the existing code that establishes the pattern.
- **Include reasoning**. Every issue must have a collapsible reasoning section explaining why it was flagged, which agent found it, and how the critic verified it.
- **Classify severity**. Use 🔴 Normal / 🟡 Nit / 🟣 Pre-existing for every finding (Branch Mode); use 🔴 Normal / 🟡 Nit only in Full Codebase Mode. `AGENTS.md` violations default to 🟡 Nit.
- **Focus on correctness**. Default focus is bugs that would break production. Style nits are noise unless `AGENTS.md`/`REVIEW.md` explicitly requires them.
- **Respect `REVIEW.md` priorities**. If `REVIEW.md` has prioritize/deprioritize sections, calibrate findings accordingly.
- **Acknowledge good work**. Dedicate a section to what the branch (or codebase, in Full Mode) does well.
- **Do not check build signal**. Do not attempt to build, typecheck, or run tests. Assume CI handles that separately.
- **Keep subagents read-only**. Every agent in this skill is investigative — spawn with `sandbox_mode = "read-only"` (either via the built-in `explorer` agent or a custom review agent). Review work should never mutate the working tree.
- **Advisory only**. This review provides analysis — it does not approve or block merges. The human reviewer retains full authority.
- **Pick the right mode and stick to it**. Mode is decided in Phase 1 from the user's hint combined with real repo state (base existence, commits ahead, working-tree dirtiness). Once selected, every subsequent phase uses that mode's rules — do not silently mix modes mid-run.
