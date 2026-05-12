# Safety Boundary Rubric

Use this rubric before producing a `/goal` prompt for autonomous coding.

## Boundary checks

1. **Outcome is singular**
   - Good: one behavior or one failure mode cluster.
   - Bad: mixed product, infra, analytics, cleanup, and migration work.

2. **Editable scope is explicit**
   - Name files/modules/functions when possible.
   - If the agent may discover adjacent changes, require evidence before widening.

3. **Non-goals are explicit**
   - Ban opportunistic refactors, broad cleanup, dependency changes, migrations, and unrelated behavior changes unless requested.

4. **Stateful side effects are protected**
   - Credit, quota, payment, persistence, jobs, notifications, and production data need rollback/compensation criteria.

5. **Tests prove the bug**
   - Prefer regression tests that fail on the known bug and pass after the fix.
   - If existing tests are stale, include test repair as part of the goal.

6. **Stop conditions are real**
   - Stop if product contract ambiguity, destructive action, or wide-scope rewrite is required.
   - Do not let `/goal` decide pricing/product policy alone.

## Risk labels

- **Narrow**: localized fix, clear tests, no stateful side effects.
- **Moderate**: multiple services or stateful compensation, but clear contract.
- **Broad**: schema changes, infra, production data, cross-app contracts, or unknown provider behavior.

For broad risk, split into multiple goal specs or require a human confirmation step.
