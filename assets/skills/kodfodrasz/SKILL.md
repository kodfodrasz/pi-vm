---
name: kodfodrasz
description: Pragmatic, locally understandable software development style with a functional core, explicit I/O, simple tests, recoverable workflows, and plain technical English. Use when writing, reviewing, refactoring, or documenting code.
---

# Kodfodrasz

Prefer code that a competent developer or agent can understand locally, without reconstructing an elaborate architecture. Favor clarity, accuracy, and maintainability over line count, patterns, and theoretical purity. These are preferences, not rigid rules.

## Coding style

### Local reasoning

- Make behavior, dependencies, and failure modes understandable from a function and a few nearby definitions.
- Avoid navigation through many files, abstraction layers, registrations, or implicit conventions.
- Minimize indirection, hidden state, and the number of concepts needed to understand an operation.
- Introduce architectural boundaries only when their benefits justify their complexity.

### Simplicity and abstraction

- Prefer explicit, straightforward control flow.
- Do not apply DRY or "Clean Code" mechanically. Duplication can be cheaper than abstraction.
- For code used 1–3 times, prefer inlining unless extraction improves readability, establishes a meaningful contract, or protects a shared invariant.
- Similar code need not share a reason to change.
- Prefer cohesive, relatively flat functions over chains of trivial helpers. A long semantic operation can be clearer than many short ones.
- Extract at meaningful semantic boundaries, not arbitrary function-size limits.
- Avoid clever plumbing, speculative generality, and premature extensibility.
- Prefer a few cohesive, well-organized files over many tiny modules.
- Minimize dependencies, infrastructure, and deployment complexity.

### Dependencies and design decisions

- Prefer standard libraries, approved dependencies, and small, proven ecosystem solutions. Avoid NIH: small-looking tasks can hide hard correctness requirements, including Unicode and non-English text.
- Minimize **total dependency footprint**, not just package count: consider direct and transitive code volume, maintenance and supply-chain exposure, hidden behavior, and runtime/lifecycle constraints.
- Do not import a large framework to use a tiny fraction of its capabilities. Conversely, a cohesive family of compatible libraries may be simpler and safer than many unrelated micro-dependencies, even with some unused code.
- Use a well-established, focused dependency when it solves a hard problem reliably and project policy allows it. Do not substitute a fragile partial implementation merely to avoid dependencies.
- Ask before consequential new dependencies or architectural choices unless autonomous work is requested. Offer a recommendation and brief pros/cons; do not interrupt for small, low-risk, permitted additions or routine reversible decisions.
- Weigh correctness, maintenance, maturity, licensing, security, installed footprint, and complexity **removed**. Apply judgment rather than hard package-count or size limits.
- If preferences are unclear, ask a few focused questions and reuse the answers. In autonomous mode, choose pragmatically and report consequential trade-offs; autonomy does not waive supply-chain scrutiny.

### Functional core and I/O boundaries

Favor functional programming principles without enforcing purity everywhere. Organize code around:

1. **Pure functions:** Deterministic transformations without observable side effects.
2. **I/O adapters:** Explicit functions that read or write data at system boundaries.
3. **Pure semantic operations:** High-level actions composed from pure functions, operating on ordinary values.
4. **I/O workflows:** Clear orchestration of I/O and transformations, typically `read → transform → write`.
5. **Entrypoints:** Simple setup, configuration, and orchestration that need little or no dedicated testing.

- Keep business logic in the pure core where practical. Prefer explicit data flow over hidden state.
- Use native language facilities instead of building frameworks. Use idiomatic dependency injection where appropriate (e.g., ASP.NET), but sparingly; pure functions generally do not need it.
- Use types and explicit contracts, especially at functional boundaries.
- Prefer data structures that make invalid states hard to represent **when doing so is simple in the language**. Do not invent elaborate type machinery for theoretical guarantees.

### Testing

- Prefer linear, declarative tests with explicit inputs and expected outputs.
- Avoid branches, loops, complex fixtures, and elaborate test helpers where possible.
- Parameterized test vectors are fine; give every case a meaningful semantic description, not just an index.
- Test pure transformations with literal inputs or representative saved fixtures.
- Do not reproduce implementation logic to calculate expected results.
- Avoid mocks: they often verify configured expectations rather than real behavior. Mock libraries also add opaque machinery, hidden call semantics, and dependencies.
- If substitution is needed, prefer a small, explicit fake whose implementation is easy to inspect.
- Test I/O contracts separately with integration tests against real services where practical.
- Keep ordinary unit tests independent of external I/O; test observable behavior rather than implementation details.

### Processing, progress, and recovery

- Separate I/O from computation where practical, but do not force one huge batch.
- Prefer bounded batches, incremental progress, and predictable resource use.
- Consider queues, iterators, streams, and producer-consumer pipelines when they simplify composition; use native, well-understood primitives rather than custom frameworks.
- Make progress observable, and preserve completed work during long operations.
- Isolate per-item failures; do not discard successful work because one item failed.
- For multi-stage workflows, consider durable intermediate results and resume checkpoints.
- Prefer idempotent operations, content-addressed artifacts, and reusable caches where appropriate.
- Make retries safe. Do not assume external operations are idempotent without evidence; state consequential assumptions and ask when uncertain.

### Judgment

- Prefer clear code over clever types, abstractions, or strict functional patterns.
- Make pragmatic exceptions when they improve comprehensibility.
- Never add complexity solely to comply with this guide.
- Between working solutions, prefer fewer concepts, dependencies, and hidden behaviors.

## Writing and comment style

Use **plain technical English**: Simple English grammar with precise software engineering vocabulary.

### Language and agent communication

- Prefer short, direct sentences, active voice, common words, and concrete verbs.
- Use established technical terms freely and consistently. Explain unfamiliar or project-specific terms; never dilute technical meaning.
- Preserve exact API names, identifiers, commands, configuration keys, and error messages.
- Lead with the result or action. Avoid filler, idioms, promotional language, and narration of routine work.
- Distinguish facts, assumptions, and recommendations. Report what changed, what was tested, and what remains unresolved. Never imply unrun tests passed.
- Favor technical accuracy and clarity over mechanical brevity.

### Project documentation

- Document **durable, reader-relevant information**: purpose, usage, configuration, observable behavior, contracts, constraints, and recovery procedures.
- Do not turn README files or design documentation into agent progress reports, code-review responses, or summaries of how a refactor was implemented.
- Omit implementation trivia: function counts, helper names, file-by-file inventories, code formatting choices, and claims about following coding principles. Readers can inspect the code when these details matter.
- Describe the current system, not what changed during this task. Keep task history in commits, changelogs, or the agent's final response, as appropriate.
- Update documentation only when documented behavior, usage, or contracts change, or existing documentation becomes inaccurate. **A code refactor alone is not a reason to rewrite documentation.**
- If an implementation detail is an enduring interface or extension point, document only what readers need to use or maintain it. Otherwise, omit it.

### Comments and docstrings

- Comment only when code cannot clearly express a **durable invariant, constraint, contract, or non-obvious reason**. Explain *why*, not what the code already says.
- Make comments **self-contained**: understandable from the current code and its documented contracts, without chat history, prompts, tickets, or prior revisions.
- Describe the system as it is. Do not encode requests, discussions, temporary decisions, migration history, or development-process notes.
- Avoid phrases such as “as discussed,” “for now,” “previously,” and “the new implementation.”
- Remove stale or redundant comments. Keep historical rationale in commits or design records. Cite external specifications only when they define an enduring contract.

### References

- [Simple English Wikipedia: How to write Simple English pages](https://simple.wikipedia.org/wiki/Wikipedia:How_to_write_Simple_English_pages)
- [Google developer documentation style guide](https://developers.google.com/style)
- [Google: Jargon](https://developers.google.com/style/jargon)
- [Microsoft: Use simple words and concise sentences](https://learn.microsoft.com/en-us/style-guide/word-choice/use-simple-words-concise-sentences)
