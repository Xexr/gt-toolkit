# Formulas

Design and planning formulas for the `gt sling` pipeline. These take a feature from initial idea through to a fully reviewed design spec, then into a detailed implementation plan.

## Architecture

The formulas follow an **expansion/wrapper pattern**:

- **Expansion formulas** (`*-expansion.formula.toml`) contain the actual multi-step logic. They use `type = "expansion"` and define `[[template]]` steps with `{target}` placeholders, allowing them to be composed into larger workflows.

- **Wrapper formulas** are thin standalone entrypoints that expand a single expansion formula into a runnable workflow. They define a placeholder `[[steps]]` block and use `[compose] [[compose.expand]]` to inline the expansion. Use these when you want to run one stage of the pipeline in isolation.

- **spec-workflow** is the orchestrator that composes all four spec expansions into a single end-to-end pipeline with a human gate at the end.

- **plan-writing** converts a reviewed spec into an implementation plan via deep codebase analysis (3 parallel agents) and structured plan generation.

## The Pipeline

The full spec pipeline runs four stages sequentially. Each stage can also be run standalone via its wrapper formula.

### Stage 1: Multimodal Scope Questions

**Formula:** `spec-multimodal-scope-questions-expansion`

Surfaces design blind spots using a 3x3 matrix of models (Opus, GPT, Gemini) and perspectives (User Advocate, Product Designer, Domain Expert).

**Steps:**
1. Gather codebase context via Haiku
2. Dispatch 9 parallel analyses (3 models x 3 perspectives)
3. Consolidate per-model (3 parallel Haiku tasks)
4. Synthesize into a single prioritized question backlog (P0/P1/P2/P3)

**Outputs:** `plans/{feature}/01-scope/questions.md` plus per-model analysis files

**Vars:** `feature` (name), `brief` (1-3 sentence description)

---

### Stage 2: Brainstorm

**Formula:** `spec-brainstorm-expansion`

Turns scope questions into a validated design spec through structured dialogue.

**Steps:**
1. Check for prior scope questions, present summary, ask user to select scope
2. Triage questions into auto-answerable vs branch points (human decisions)
3. Interactive dialogue: present auto-answers, walk through branch points one at a time
4. Write spec document incrementally, validating each section with user
5. Commit

**Two modes:** If scope questions exist from Stage 1, uses them to accelerate brainstorming. Otherwise runs standard brainstorming from scratch.

**Outputs:** `plans/{feature}/02-spec/spec.md`, `plans/{feature}/01-scope/question-triage.md`

**Vars:** `feature`, `brief`

---

### Stage 3: Questions Interview

**Formula:** `spec-questions-interview-expansion`

Reviews the spec for completeness with a two-pass approach.

**Steps:**
1. Load spec and assess: completeness check (were scope questions addressed?) plus fresh 6-category assessment (Objective, Done Criteria, Scope, Constraints, Dependencies, Safety)
2. Ask clarifying questions via `AskUserQuestion` for any gaps found
3. Loop until clean (max 3 passes)
4. Summarize refinements and update spec
5. Commit

**Outputs:** Updated `plans/{feature}/02-spec/spec.md` with "Spec Review" section

**Vars:** `feature`

---

### Stage 4: Multimodal Review

**Formula:** `spec-multimodal-review-expansion`

Final quality gate using 3 models in parallel across 12 review categories.

**Steps:**
1. Gather or reuse codebase context
2. Dispatch 3 models in parallel (Opus 4.6, GPT 5.3 Codex, Gemini 3 Pro) with all review categories (codebase match, security, design quality, performance, etc.)
3. Synthesize: deduplicate, build comparison table, group issues by severity
4. Present findings, gate on user "go" / "skip"
5. Resolve ambiguities, update spec with review section
6. Commit

**Outputs:** `plans/{feature}/02-spec/spec-review.md`, updated `plans/{feature}/02-spec/spec.md`

**Vars:** `feature`

---

## Plan Writing

### Stage 5: Implementation Plan

**Formula:** `plan-writing-expansion`

Converts a reviewed spec into a comprehensive implementation plan by running deep codebase analysis, then writing a phased delivery plan with file-level mapping and acceptance criteria.

**Steps:**
1. Validate inputs — confirm spec exists, check for prior codebase context
2. Deep codebase analysis — 3 parallel Sonnet agents exploring architecture, integration surface, and patterns/conventions
3. Consolidate analysis into `plan-context.md`
4. Write implementation plan with phased delivery, spec coverage matrix, and technical risks
5. Commit plan and artifacts

**Outputs:** `plans/{feature}/03-plan/plan.md`, `plans/{feature}/03-plan/plan-context.md`

**Vars:** `feature`, `brief`

**Prerequisite:** Run `spec-workflow` (or at least `spec-brainstorm`) first to produce `plans/{feature}/02-spec/spec.md`.

---

### Stage 6: Plan Review

**Formula:** `plan-review-to-spec-expansion`

Verifies the plan fully addresses the spec and aligns with codebase analysis using 3 parallel review agents checking different directions.

**Steps:**
1. Validate inputs — confirm spec, plan, and plan-context exist
2. Parallel review — 3 agents: spec→plan (forward coverage), plan→spec (reverse traceability), plan→context (codebase alignment)
3. Consolidate findings — cross-reference, deduplicate, severity-rank (P0/P1/P2)
4. Present & resolve — interactive resolution of P0 and P1 findings (update plan, update spec, or accept)
5. Commit review and any updates

**Review directions:**

| Agent | Direction | Catches |
|-------|-----------|---------|
| 1 | Spec → Plan | Dropped requirements, incomplete coverage |
| 2 | Plan → Spec | Scope creep, gold-plating, unbacked decisions |
| 3 | Plan → Context | Codebase contradictions, missed integration points, pattern non-compliance |

**Outputs:** `plans/{feature}/03-plan/plan-review.md`, updated plan and/or spec if fixes applied

**Vars:** `feature`

**Prerequisite:** Run `plan-writing` first to produce `plans/{feature}/03-plan/plan.md`.

---

## Standalone Wrappers

These formulas are thin wrappers that let you run a single pipeline stage in isolation. They each define one placeholder step and use `[compose]` to expand the corresponding expansion formula. No additional logic beyond what the expansion provides.

| Wrapper | Expands | Use when... |
|---------|---------|-------------|
| `spec-multimodal-scope-questions` | `spec-multimodal-scope-questions-expansion` | You want scope questions without continuing to brainstorm |
| `spec-brainstorm` | `spec-brainstorm-expansion` | You want to brainstorm a spec (with or without prior scope questions) |
| `spec-questions-interview` | `spec-questions-interview-expansion` | You have a spec and want a completeness review |
| `spec-multimodal-review` | `spec-multimodal-review-expansion` | You have a spec and want multi-model review |
| `plan-writing` | `plan-writing-expansion` | You have a reviewed spec and want an implementation plan |
| `plan-review-to-spec` | `plan-review-to-spec-expansion` | You have a plan and want to verify it covers the spec |

---

## Orchestrator

### spec-workflow

The full spec pipeline. Composes all four expansion formulas sequentially with dependency chains between steps and a single human gate at the end.

```
Stage 1: Scope Questions --> Stage 2: Brainstorm --> Stage 3: Interview --> Stage 4: Review --> Gate: Final Review
```

Stages 2 and 3 are interactive (user dialogue), so intermediate gates are unnecessary. The single final gate lets you review the complete picture before marking done.

**Usage:**
```bash
gt sling spec-workflow <crew> \
  --var feature="command-palette" \
  --var brief="Add a keyboard-centric command palette for power users..."
```

**Vars:** `feature`, `brief`

Approve the final gate with `bd gate resolve <gate-id>`.

### Full Pipeline (spec + plan + review)

To run the complete pipeline from spec through plan review:

```bash
# Stage 1-4: Spec pipeline
gt sling spec-workflow <crew> \
  --var feature="command-palette" \
  --var brief="Add a keyboard-centric command palette for power users..."

# Stage 5: Plan (after spec is reviewed and approved)
gt sling plan-writing <crew> \
  --var feature="command-palette" \
  --var brief="Add a keyboard-centric command palette for power users..."

# Stage 6: Plan review (verify plan covers the spec)
gt sling plan-review-to-spec <crew> \
  --var feature="command-palette"
```
