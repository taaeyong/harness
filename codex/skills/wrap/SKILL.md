---
name: wrap
description: This skill should be used when the user asks to "wrap up session", "end session", "session wrap", "/wrap", "document learnings", "what should I commit", or wants to analyze completed work before ending a coding session.
version: 1.0.0
user-invocable: true
---

# Session Wrap (/wrap)

Comprehensive session wrap-up workflow with multi-agent analysis.

## Quick Usage

- `/wrap` - Interactive session wrap-up (recommended)
- `/wrap [message]` - Quick commit with provided message

## Execution Flow

```
1. Check Git Status
2. Phase 1: 4 Analysis Agents (Parallel)
   ┌─────────────────┬─────────────────┐
   │  doc-updater     │  automation-    │
   │  (docs update)   │  scout          │
   ├─────────────────┼─────────────────┤
   │  learning-       │  followup-      │
   │  extractor       │  suggester      │
   └─────────────────┴─────────────────┘
3. Phase 2: Validation Agent (Sequential)
   ┌───────────────────────────────────┐
   │       duplicate-checker           │
   │  (Validate Phase 1 proposals)     │
   └───────────────────────────────────┘
4. Integrate Results & AskUserQuestion
5. Execute Selected Actions
```

## Step 1: Check Git Status

```bash
git status --short
git diff --stat HEAD~3 2>/dev/null || git diff --stat
```

## Step 2: Phase 1 - Analysis Agents (Parallel)

Execute 4 agents in parallel (single message with 4 Agent calls).

### Session Summary (Provide to all agents)

```
Session Summary:
- Work: [Main tasks performed in session]
- Files: [Created/modified files]
- Decisions: [Key decisions made]
```

### Parallel Execution

Each agent uses `subagent_type="general-purpose"` with the agent role loaded from `${baseDir}/references/agent-*.md`.

**Read the agent reference file first**, then include its content as the agent's system instruction in the prompt.

```
Agent(
    subagent_type="general-purpose",
    model="sonnet",
    description="Document update analysis",
    prompt="You are the doc-updater agent. [Include content from references/agent-doc-updater.md]\n\n[Session Summary]\n\nAnalyze if CLAUDE.md, context.md need updates."
)

Agent(
    subagent_type="general-purpose",
    model="sonnet",
    description="Automation pattern analysis",
    prompt="You are the automation-scout agent. [Include content from references/agent-automation-scout.md]\n\n[Session Summary]\n\nAnalyze repetitive patterns or automation opportunities."
)

Agent(
    subagent_type="general-purpose",
    model="sonnet",
    description="Learning points extraction",
    prompt="You are the learning-extractor agent. [Include content from references/agent-learning-extractor.md]\n\n[Session Summary]\n\nExtract learnings, mistakes, and new discoveries."
)

Agent(
    subagent_type="general-purpose",
    model="sonnet",
    description="Follow-up task suggestions",
    prompt="You are the followup-suggester agent. [Include content from references/agent-followup-suggester.md]\n\n[Session Summary]\n\nSuggest incomplete tasks and next session priorities."
)
```

### Agent Roles

| Agent | Model | Role | Output |
|-------|-------|------|--------|
| **doc-updater** | sonnet | Analyze CLAUDE.md/context.md updates | Specific content to add |
| **automation-scout** | sonnet | Detect automation patterns | skill/command/agent suggestions |
| **learning-extractor** | sonnet | Extract learning points | TIL format summary |
| **followup-suggester** | sonnet | Suggest follow-up tasks | Prioritized task list |

## Step 3: Phase 2 - Validation Agent (Sequential)

Run after Phase 1 completes (dependency on Phase 1 results).

```
Agent(
    subagent_type="general-purpose",
    model="haiku",
    description="Phase 1 proposal validation",
    prompt="You are the duplicate-checker agent. [Include content from references/agent-duplicate-checker.md]\n\nValidate Phase 1 analysis results.\n\n## doc-updater proposals:\n[doc-updater results]\n\n## automation-scout proposals:\n[automation-scout results]\n\nCheck if proposals duplicate existing docs/automation:\n1. Complete duplicate: Recommend skip\n2. Partial duplicate: Suggest merge approach\n3. No duplicate: Approve for addition"
)
```

## Step 4: Integrate Results

```markdown
## Wrap Analysis Results

### Documentation Updates
[doc-updater summary]
- Duplicate check: [duplicate-checker feedback]

### Automation Suggestions
[automation-scout summary]
- Duplicate check: [duplicate-checker feedback]

### Learning Points
[learning-extractor summary]

### Follow-up Tasks
[followup-suggester summary]
```

## Step 5: Action Selection

```
AskUserQuestion(
    questions=[{
        "question": "Which actions would you like to perform?",
        "header": "Wrap Options",
        "multiSelect": true,
        "options": [
            {"label": "Create commit (Recommended)", "description": "Commit changes"},
            {"label": "Update CLAUDE.md", "description": "Document new knowledge/workflows"},
            {"label": "Create automation", "description": "Generate skill/command/agent"},
            {"label": "Skip", "description": "End without action"}
        ]
    }]
)
```

## Step 6: Execute Selected Actions

Execute only the actions selected by user.

---

## Quick Reference

### When to Use

- End of significant work session
- Before switching to different project
- After completing a feature or fixing a bug

### When to Skip

- Very short session with trivial changes
- Only reading/exploring code
- Quick one-off question answered

### Arguments

- Empty: Proceed interactively (full workflow)
- Message provided: Use as commit message and commit directly

## Additional Resources

See `references/multi-agent-patterns.md` for detailed orchestration patterns.
