# gt-toolkit Codebase Overview

## Purpose

`gt-toolkit` is a formula pack for Gas Town / beads workflows. It contains reusable
`.formula.toml` workflow definitions for running design-spec pipelines with `gt sling`,
plus placeholder directories for future configs and docs.

## Repository Layout

| Path | Role |
|------|------|
| `README.md` | Top-level project intro and formula install instructions |
| `formulas/` | Core workflow definitions (`*.formula.toml`) |
| `formulas/README.md` | Detailed explanation of formula architecture and pipeline stages |
| `configs/` | Reserved for reusable config templates (currently placeholder) |
| `docs/` | Project documentation (this file lives here) |

## Formula Architecture

The formulas use an expansion/wrapper composition model:

- Expansion formulas (`*-expansion.formula.toml`) contain real multi-step logic
  with reusable `[[template]]` steps and `{target}` placeholders.
- Wrapper workflows (`spec-*.formula.toml` without `-expansion`) expose single
  runnable entrypoints that compose one expansion formula.
- `spec-workflow.formula.toml` is the orchestrator that composes all stages
  into one end-to-end process with a final human gate.

## Included Workflows

### Standalone wrappers

- `spec-multimodal-scope-questions`
- `spec-brainstorm`
- `spec-questions-interview`
- `spec-multimodal-review`
- `spec-workflow` (full pipeline orchestrator)

### Expansion formulas

- `spec-multimodal-scope-questions-expansion`:
  generates scope questions using a 3x3 matrix (3 models x 3 perspectives).
- `spec-brainstorm-expansion`:
  turns scoped questions into a spec through guided dialogue and triage.
- `spec-questions-interview-expansion`:
  runs completeness + fresh-gap assessment and asks follow-up questions.
- `spec-multimodal-review-expansion`:
  runs multi-model spec review, synthesizes findings, and gates on final approval.

## Operational Notes

- Formula files are intended to be copied into `~/.beads/formulas/` for town-wide use
  (or a rig-local `.beads/formulas/` directory for project-scoped use).
- This repository currently has no application runtime code and no native test harness;
  it is primarily declarative workflow content in TOML and Markdown.
