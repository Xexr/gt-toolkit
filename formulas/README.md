# Formulas

Design and planning formulas for the `gt sling` pipeline. These take a feature from initial idea through to a fully reviewed design spec, a detailed implementation plan, and a comprehensive beads issue hierarchy ready for execution.

## Architecture

The formulas follow an **expansion/workflow pattern**:

- **Expansion formulas** (`*-expansion.formula.toml`) contain the actual multi-step logic. They use `type = "expansion"` and define `[[template]]` steps with `{target}` placeholders. Expansions can run standalone (a synthetic "main" target resolves placeholders automatically) or be composed into larger workflows.

- **Workflow formulas** (`spec-workflow`, `plan-workflow`, `beads-workflow`) are orchestrators that compose multiple expansion formulas into end-to-end pipelines with dependency chains between stages.

## Multi-LLM Reviews

Stages 1 and 4 use **multi-model analysis** — dispatching the same task to multiple LLMs in parallel and synthesizing their outputs for higher-confidence results. This catches blind spots that any single model might miss.

### Models used

| Model | CLI | Used in |
|-------|-----|---------|
| Claude Opus 4.6 | Built-in (Task tool) | Stages 1, 4 |
| GPT 5.3 Codex | [Codex CLI](https://github.com/openai/codex) (`codex`) | Stages 1, 4 |
| Gemini 3 Pro | [Gemini CLI](https://github.com/google-gemini/gemini-cli) (`gemini`) | Stages 1, 4 |

### What you need

- **Opus only (minimum):** The pipeline works with just Claude. Stages 1 and 4 will skip models whose CLIs aren't installed and synthesize from available results. Single-model output is still valuable.
- **Full multi-LLM (recommended):** Install the Codex and Gemini CLIs for maximum review diversity. Each model brings different reasoning patterns and catches different issues.

### Installing the CLIs

```bash
# Codex CLI (OpenAI) — requires OpenAI authentication
npm install -g @openai/codex

# Gemini CLI (Google) — requires Google authentication
npm install -g @google/gemini-cli
```

Refer to each CLI's documentation for authentication setup: [Codex CLI](https://github.com/openai/codex), [Gemini CLI](https://github.com/google-gemini/gemini-cli).

## The Pipeline

The full pipeline runs 8 stages across three phases, then hands off to execution:

```
┌─────────┐      ┌─────────┐      ┌─────────┐      ┌───────────┐
│  Spec   │ ───▶ │  Plan   │ ───▶ │  Beads  │ ───▶ │ Delivery  │
│ (1-4)   │      │ (5-6)   │      │ (7-8)   │      │   (9)     │
└─────────┘      └─────────┘      └─────────┘      └───────────┘
  idea →           spec →           plan →           beads →
  reviewed spec    reviewed plan    verified beads   landed code
```

Each phase produces reviewed artifacts that feed the next. The detailed stages:

```
SPEC                        PLAN                BEADS                DELIVERY
────────────────────────    ────────────────    ─────────────────    ──────────
1. Scope Questions          5. Plan Writing     7. Beads Creation    9. Epic
   ↓                           ↓                  ↓                    Delivery
2. Brainstorm               6. Plan Review      8. Beads Review
   ↓
3. Questions Interview        plan-workflow       beads-workflow
   ↓
4. Multimodal Review

     spec-workflow
```

Each stage can also be run standalone via its expansion formula.

### Spec (Stages 1-4)

#### Stage 1: Multimodal Scope Questions

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

#### Stage 2: Brainstorm

**Formula:** `spec-brainstorm-expansion`

Turns scope questions into a validated design spec through structured dialogue. Inspired by the brainstorming approach in [obra/superpowers](https://github.com/obra/superpowers/tree/main).

**Steps:**
1. Check for prior scope questions, present summary, ask user to select scope
2. Triage questions into auto-answerable vs branch points (human decisions)
3. Interactive dialogue: present auto-answers, walk through branch points one at a time
4. Write spec document incrementally, validating each section with user
5. Commit

**Two modes:** If scope questions exist from Stage 1, uses them to accelerate brainstorming. Otherwise runs standard brainstorming from scratch.

**Outputs:** `plans/{feature}/02-spec/spec.md`, `plans/{feature}/01-scope/question-triage.md`

**Vars:** `feature` (brief is resolved from `context.md` or by asking the user)

---

#### Stage 3: Questions Interview

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

#### Stage 4: Multimodal Review

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

### Plan (Stages 5-6)

#### Stage 5: Implementation Plan

**Formula:** `plan-writing-expansion`

Converts a reviewed spec into a comprehensive implementation plan by running deep codebase analysis, then writing a phased delivery plan with file-level mapping and acceptance criteria. Inspired by the plan-writing approach in [obra/superpowers](https://github.com/obra/superpowers/tree/main).

**Steps:**
1. Validate inputs — confirm spec exists, check for prior codebase context
2. Deep codebase analysis — 3 parallel Sonnet agents exploring architecture, integration surface, and patterns/conventions
3. Consolidate analysis into `plan-context.md`
4. Write implementation plan with phased delivery, spec coverage matrix, and technical risks
5. Commit plan and artifacts

**Outputs:** `plans/{feature}/03-plan/plan.md`, `plans/{feature}/03-plan/plan-context.md`

**Vars:** `feature`

**Prerequisite:** Run `spec-workflow` (or at least `spec-brainstorm`) first to produce `plans/{feature}/02-spec/spec.md`. The brief is captured in earlier stage artifacts and does not need to be passed again.

---

#### Stage 6: Plan Review

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

### Beads (Stages 7-8)

#### Stage 7: Beads Creation

**Formula:** `beads-creation-expansion`

Converts the reviewed implementation plan into a fully-structured beads hierarchy with validated dependencies for maximum parallelization.

**Steps:**
1. Validate inputs — confirm plan and plan-review exist
2. Draft beads structure — feature epic, phase sub-epics, task issues with acceptance criteria
3. Review pass 1: Completeness — every plan task has a corresponding bead
4. Review pass 2: Dependencies — blockers are real, parallelism is maximized
5. Review pass 3: Clarity — each issue is implementable by a fresh agent
6. Execute — create beads via `bd` commands with `--parent` and `--deps` flags
7. Report and commit

**Outputs:** Beads hierarchy (feature epic → phase sub-epics → task issues) plus `plans/{feature}/04-beads/beads-draft.md` and `plans/{feature}/04-beads/beads-report.md`

**Vars:** `feature`

**Prerequisite:** Run `plan-writing` and `plan-review-to-spec` first.

---

#### Stage 8: Beads Review to Plan

**Formula:** `beads-review-to-plan-expansion`

Verifies that created beads issues accurately represent the implementation plan using 3 parallel review agents with bidirectional coverage checking.

**Steps:**
1. Validate inputs — confirm plan exists and snapshot beads state
2. Parallel review — 3 agents:
   - Plan→Beads (forward): Does every plan task have a corresponding bead with matching content?
   - Beads→Plan (reverse): Does every bead trace back to a plan task? Catches conversion scope creep.
   - Dependency integrity: Does the beads dependency graph match the plan's phasing and prerequisites?
3. Consolidate findings with cross-referencing and severity ranking
4. Present & resolve — auto-apply restorative fixes, escalate genuine ambiguities
5. Commit review report and any updates

**Outputs:** `plans/{feature}/04-beads/beads-review.md`, updated beads (dependencies, acceptance criteria, content)

**Vars:** `feature`

**Prerequisite:** Run `beads-creation` first.

---

### Execution (Stage 9)

#### Stage 9: Epic Delivery

With a reviewed beads hierarchy in place — a feature epic, phase sub-epics, task issues with acceptance criteria, and a validated dependency graph — the final stage is implementation.

The **epic-delivery** skill in [Gas Town](https://github.com/steveyegge/gastown) takes the beads hierarchy produced by stages 7-8 and executes it in a swarm-style fashion: it sets up an integration branch, creates a convoy, then dispatches waves of leaf tasks to polecats in parallel, respecting the dependency graph so blocked work waits while independent tasks run concurrently. Progress is monitored, quality gates are enforced, and completeness is validated against the original plan.

This is not a formula — it's a Claude Code skill that orchestrates the Gas Town machinery (polecats, convoys, the refinery merge queue) to turn your beads into landed code.

The epic-delivery skill is available in [Xexr/marketplace](https://github.com/Xexr/marketplace).

---

## Workflow Formulas

### spec-workflow

Orchestrates stages 1-4 sequentially, ending with a summary of all outputs.

```
Stage 1: Scope Questions → Stage 2: Brainstorm → Stage 3: Interview → Stage 4: Review → Summary
```

Stages 2 and 3 are interactive (user dialogue). Stage 4 presents findings and resolves issues interactively.

**Usage:**
```bash
gt sling spec-workflow <crew> \
  --var feature="command-palette" \
  --var brief="Add a keyboard-centric command palette for power users..."
```

**Vars:** `feature`, `brief`

### plan-workflow

Orchestrates stages 5-6: from reviewed spec to reviewed implementation plan.

```
Stage 5: Plan Writing → Stage 6: Plan Review
```

Step 5 is interactive (user dialogue for architectural decisions). Step 6 auto-applies restorative fixes and only escalates genuine ambiguities.

**Usage:**
```bash
gt sling plan-workflow <crew> \
  --var feature="command-palette"
```

**Vars:** `feature`

**Prerequisite:** Completed spec at `plans/{feature}/02-spec/spec.md` (from `spec-workflow`).

### beads-workflow

Orchestrates stages 7-8: from reviewed plan to verified beads hierarchy.

```
Stage 7: Beads Creation → Stage 8: Beads Review
```

Step 7 is interactive (user dialogue for granularity decisions). Step 8 auto-applies restorative fixes and only escalates genuine ambiguities.

**Usage:**
```bash
gt sling beads-workflow <crew> \
  --var feature="command-palette"
```

**Vars:** `feature`

**Prerequisite:** Reviewed plan at `plans/{feature}/03-plan/plan.md` (from `plan-workflow`).

### Full Pipeline

To run the complete pipeline from idea to reviewed beads:

```bash
# Stages 1-4: Spec pipeline
gt sling spec-workflow <crew> \
  --var feature="command-palette" \
  --var brief="Add a keyboard-centric command palette for power users..."

# Stages 5-6: Plan pipeline (after spec is reviewed)
gt sling plan-workflow <crew> \
  --var feature="command-palette"

# Stages 7-8: Beads pipeline (after plan is reviewed)
gt sling beads-workflow <crew> \
  --var feature="command-palette"
```

Or run each stage individually via its expansion formula:

```bash
# Stage 1: Multimodal scope questions
gt sling spec-multimodal-scope-questions-expansion <crew> \
  --var feature="command-palette" \
  --var brief="Add a keyboard-centric command palette for power users..."

# Stage 2: Brainstorm
gt sling spec-brainstorm-expansion <crew> \
  --var feature="command-palette"

# Stage 3: Questions interview
gt sling spec-questions-interview-expansion <crew> \
  --var feature="command-palette"

# Stage 4: Multimodal review
gt sling spec-multimodal-review-expansion <crew> \
  --var feature="command-palette"

# Stage 5: Plan writing
gt sling plan-writing-expansion <crew> \
  --var feature="command-palette"

# Stage 6: Plan review
gt sling plan-review-to-spec-expansion <crew> \
  --var feature="command-palette"

# Stage 7: Beads creation
gt sling beads-creation-expansion <crew> \
  --var feature="command-palette"

# Stage 8: Beads review
gt sling beads-review-to-plan-expansion <crew> \
  --var feature="command-palette"
```


