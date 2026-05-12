# Official Prompting Principles for Goal Specs

Condensed from OpenAI official prompting guidance and Codex/GPT coding guidance. Use as principles, not as mandatory wording.

Sources:
- https://developers.openai.com/api/docs/guides/prompt-engineering#coding
- https://developers.openai.com/cookbook/examples/gpt-5/gpt-5_prompting_guide
- https://developers.openai.com/cookbook/examples/gpt-5/gpt-5-1_prompting_guide#how-to-metaprompt-effectively

## Principles to encode

1. **Role and workflow clarity**
   - State that the agent is acting as a software engineering agent responsible for implementation and verification.
   - Specify expected workflow: inspect, plan, edit, test, review, iterate.

2. **Structured scope beats prose-only prompts**
   - Use labeled sections: Goal, Context, Scope, Constraints, Verification, Done When.
   - Put exact file paths/functions in scope sections when known.

3. **Persistence with bounded autonomy**
   - Ask the agent to keep going until the defined goal is complete.
   - Bound that persistence with Do Not Touch and Stop/Escalate clauses.

4. **Testing and validation are part of the task**
   - Include targeted tests and rerun expectations.
   - Require the agent to read failures, patch within scope, and rerun.

5. **Metaprompting is failure-mode driven**
   - When improving a prompt/spec, first identify failure modes and contradictory instructions.
   - Then patch the spec narrowly instead of rewriting everything.

6. **Avoid over-tooling and over-editing**
   - Tell the agent what evidence is already trusted.
   - Prevent repeated broad searches once the implementation surface is clear.

7. **Markdown cleanliness**
   - Format paths, classes, commands, and code symbols with backticks.
   - Keep the final `/goal` block copy-pasteable.
