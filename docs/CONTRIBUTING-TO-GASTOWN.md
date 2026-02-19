# Contributing to Gas Town: A Guide

This document covers how to contribute to the Gas Town project, maintain your own bleeding-edge fork, and keep your local binary up to date with your changes.

---

## Table of Contents

1. [Overview: The Open Source Contribution Flow](#overview)
2. [Key Concepts](#key-concepts)
3. [Setting Up Your Fork](#setting-up-your-fork)
4. [Branch Strategy](#branch-strategy)
5. [Development Workflow](#development-workflow)
6. [Making a Pull Request](#making-a-pull-request)
7. [Maintaining Your Fork](#maintaining-your-fork)
8. [Building Your Patched Binary](#building-your-patched-binary)
9. [CI/CD and Tests](#cicd-and-tests)
10. [Upstream Contribution Guidelines](#upstream-contribution-guidelines)
11. [Quick Reference](#quick-reference)

---

## Overview

```
┌─────────────────────────┐     fork      ┌─────────────────────────┐
│  steveyegge/gastown     │ ─────────────▶│   Xexr/gastown          │
│     (upstream)          │               │     (your fork)         │
└─────────────────────────┘               └─────────────────────────┘
          │                                         │
          │ fetch upstream                          │ clone
          │                                         ▼
          │                               ┌─────────────────────────┐
          └──────────────────────────────▶│  ~/gt/gastown/crew/...  │
                                          │   (local working copy)  │
                                          └─────────────────────────┘
                                                    │
                                                    │ make install
                                                    ▼
                                          ┌─────────────────────────┐
                                          │  ~/.local/bin/gt        │
                                          │   (your patched binary) │
                                          └─────────────────────────┘
```

**The flow:**
1. Fork the upstream repo to your GitHub account
2. Clone your fork locally (as a gt rig)
3. Make fixes on feature branches (one per PR, branched from `upstream/main`)
4. Open Pull Requests to upstream
5. Cherry-pick finalized PRs onto your fork's `main` (your bleeding-edge branch)
6. Build and install your patched binary from `main`

---

## Key Concepts

### Fork
Your personal copy of the repository on GitHub. You have full control — push branches, make changes. It maintains a link to the original ("upstream") repo.

### Remotes
- **origin**: Your fork (Xexr/gastown) — where you push
- **upstream**: The original repo (steveyegge/gastown) — where you pull updates

### Pull Request (PR)
A proposal to merge your changes into upstream:
1. Create a branch in your fork
2. Push changes
3. Open PR on GitHub
4. Maintainer reviews and merges (or doesn't)

### Cherry-pick
Copy a specific commit from one branch to another without merging everything:
```bash
git cherry-pick abc123  # Apply just commit abc123 to current branch
```

Useful when:
- You want one fix from a branch but not everything
- Upstream merged some PRs but not others — cherry-pick the unmerged ones

### Rebase
Replay your commits on top of a new base:
```bash
git checkout my-branch
git rebase upstream/main  # Move my-branch commits on top of latest upstream
```

This keeps your patches "on top" of upstream changes.

---

## Setting Up Your Fork

### One-time setup

#### 1. Fork and create the rig

```bash
# Fork on GitHub
gh repo fork steveyegge/gastown --clone=false

# Add gastown as a rig (creates clone at ~/gt/gastown)
gt rig add gastown git@github.com:Xexr/gastown.git
```

This creates the rig structure with `mayor/`, `refinery/`, `witness/`, `polecats/`, and an empty `crew/` directory. The refinery contains the git clone.

#### 2. Migrate beads to Dolt server mode

`gt rig add` initializes beads with SQLite by default. If your town runs Dolt server mode (check `gt dolt status`), you need to migrate. This is a multi-step process — you cannot go directly from SQLite to Dolt server.

```bash
cd ~/gt/gastown/mayor/rig

# Step 1: Disable beads-sync before migrating
# IMPORTANT: The upstream repo has a beads-sync branch with thousands of
# project management issues. If you leave sync-branch enabled, bd doctor
# or bd init will import them all into your database.
# In .beads/config.yaml, comment out:
#   sync-branch: beads-sync

# Step 2: SQLite → embedded Dolt (creates schema)
bd migrate dolt --yes

# Step 3: Move embedded Dolt to centralized server location
gt dolt migrate

# Step 4: Restart Dolt server to pick up new database
gt dolt stop && gt dolt start

# Step 5: Configure server mode in .beads/metadata.json
# Replace contents with:
# {
#   "database": "dolt",
#   "jsonl_export": "issues.jsonl",
#   "backend": "dolt",
#   "dolt_mode": "server",
#   "dolt_server_port": 3307,
#   "dolt_database": "gastown"
# }

# Step 6: Restart bd daemons in ALL workspaces
# They hold stale connections to the old server state
bd daemons list  # Find running daemons
# Restart each one (hq, dypt, gastown, etc.)

# Step 7: Clean up leftover SQLite/embedded files
rm .beads/beads.db .beads/beads.backup-*.db
rmdir .beads/dolt 2>/dev/null  # Only if empty after migration
```

#### 3. Set up Dolt remote

```bash
# Create local filesystem remote (matches hq/dypt pattern)
mkdir ~/dolt-remotes/gastown && cd ~/dolt-remotes/gastown && dolt init

# Add remote to gastown database
cd ~/gt/.dolt-data/gastown
dolt remote add origin file:///home/xexr/dolt-remotes/gastown
```

#### 4. Create rig/agent beads

```bash
# gt doctor detects missing beads and can create them
gt doctor --fix
```

This creates the rig identity bead (`gt-rig-gastown`) and agent beads (`gt-gastown-witness`, `gt-gastown-refinery`).

#### 5. Create a crew member (your working copy)

```bash
gt crew add furiosa --rig gastown
```

Crew members are full git clones (not worktrees). Your crew workspace at `~/gt/gastown/crew/furiosa/` is where you'll do all your development work.

#### 6. Set up upstream remote on your crew member

```bash
cd ~/gt/gastown/crew/furiosa
git remote add upstream git@github.com:steveyegge/gastown.git
git fetch upstream

# Verify
git remote -v
# origin    git@github.com:Xexr/gastown.git (fetch)
# origin    git@github.com:Xexr/gastown.git (push)
# upstream  git@github.com:steveyegge/gastown.git (fetch)
# upstream  git@github.com:steveyegge/gastown.git (push)
```

**Note:** Remotes are per-clone. Setting upstream on the refinery does NOT propagate to crew members. Set it on the clone you'll actually work in.

---

## Branch Strategy

Your fork has three types of branches, each with a clear purpose:

### `main` — your bleeding-edge branch

Your fork's `main` is **not** a mirror of upstream. It is `upstream/main` plus finalized cherry-picks of your unmerged PRs. This is the branch you build from, the branch all Gas Town clones track, and the branch you could share with others.

```
upstream/main ─────────────────────────────────────▶ (pristine upstream)

origin/main ───●───●───────────────────────────────▶ (upstream + your patches)
               │   │
               │   └─ cherry-pick: fix/dolt-branch-isolation (PR #1299)
               └───── cherry-pick: fix/rig-park-enforcement (PR #1209)
```

**Rules for `main`:**
- Only add finalized, squashed commits (one commit per feature/fix)
- Never force-push (others may track this branch)
- When upstream merges one of your PRs, rebase drops the cherry-pick automatically

**Never open a PR from your fork's `main` branch.** Always create a dedicated feature branch per PR. PRs from `main` would include all your cherry-picks, making reviews messy.

### `fix/*` and `feat/*` — PR branches

Every fix or feature starts as a clean branch from `upstream/main`. This is the unit of contribution — one branch per PR, isolated from your fork's patches:

```bash
git fetch upstream
git checkout -b fix/something upstream/main
# ... make changes, test, commit ...
git push origin fix/something
gh pr create --repo steveyegge/gastown
```

**Always branch from `upstream/main`**, not from `origin/main`. This keeps your PRs clean — they contain only the changes relevant to that fix, not your other patches.

### `xexr/wip` — disposable testing branch (optional)

When you need to test multiple unfinalized features together, create a WIP branch. This is temporary, local-only, and can be rebuilt or force-pushed freely:

```bash
git checkout -b xexr/wip main
git cherry-pick <wip-commit-from-feat/integration>
git cherry-pick <wip-commit-from-fix/other-thing>
# Test the combination, rebuild as needed
```

**Rules for `xexr/wip`:**
- Never share it — it gets force-pushed and rebuilt regularly
- When WIP work is finalized, squash it and cherry-pick onto `main`
- Delete and recreate as needed

### The three branches visualized

```
upstream/main ──────────────────────────────────────▶ pristine reference
                                                       (fetch only)

origin/main ────●───●───────────────────────────────▶ bleeding edge
                │   │                                  (shareable, never force-pushed)
                │   └─ finalized fix (1 squashed commit)
                └───── finalized feature (1 squashed commit)

fix/thing ──────●───●───●───────────────────────────▶ PR branch
                │   │   │                              (clean, from upstream/main)
                │   │   └─ iterate
                │   └───── iterate
                └──────── initial implementation

xexr/wip ──────●───●───●───────────────────────────▶ testing scratchpad
               │   │   │                              (disposable, local only)
               │   │   └─ cherry-pick from fix/thing
               │   └───── cherry-pick from feat/other
               └──────── based on main
```

---

## Development Workflow

Go is a compiled language — there is no interpreter or hot-reload dev server like you get with JS/TS (`vite`, `next dev`, `nodemon`). Every code change requires a rebuild before you can see the effect. Go compiles fast though, so the cycle is quick.

### The edit-build-test loop

```bash
# 1. Make your code change in your editor

# 2. Quick build (local binary, no version info)
go build -o ./gt ./cmd/gt

# 3. Test with the local binary
./gt <command you're fixing>

# 4. Repeat until happy
```

### Build options

| Command | What it does | When to use |
|---------|-------------|-------------|
| `go build -o ./gt ./cmd/gt` | Compiles a binary in the current directory. No version info, no code generation. | Fast iteration during development |
| `go run ./cmd/gt <args>` | Compiles and runs in one step, no binary left on disk. | Quick one-off tests |
| `make build` | Runs `go generate`, then builds with version/commit info via `-ldflags`. | When you need `gt version` to work |
| `make install` | Runs `make build`, then copies the binary to `~/.local/bin/gt`. | Final install to replace your system `gt` |

**Key difference**: `go build` alone skips code generation (`go generate ./...`) and doesn't inject version metadata. `make build`/`make install` run the full pipeline including generation and ldflags. For most development iteration, `go build` is fine. Use `make install` when you're ready to commit or need the binary on your PATH.

### Typical bug fix workflow

```bash
# 1. Create branch from latest upstream
git fetch upstream
git checkout -b fix/the-bug upstream/main

# 2. Investigate and make changes
#    (edit source files)

# 3. Inner loop: build and test
go build -o ./gt ./cmd/gt
./gt <command>          # manual test
go test ./internal/...  # run relevant tests

# 4. When satisfied, run full test suite
go test ./...

# 5. Format and lint
gofmt -w .
go vet ./...

# 6. Commit, push, and open PR
git add <files>
git commit -m "fix(scope): description of fix"
git push origin fix/the-bug
gh pr create --repo steveyegge/gastown

# 7. Once finalized, cherry-pick onto main for your local binary
git checkout main
git cherry-pick fix/the-bug   # Or specific commit hash
git push origin main
make install
```

### Running tests

```bash
go test ./...                    # Full suite
go test ./internal/rig/...       # Specific package
go test -v ./internal/rig/...    # Verbose (see individual test names)
go test -run TestSpecificName ./internal/rig/...  # Single test
```

---

## Making a Pull Request

### 1. Create feature branch from latest upstream

```bash
git fetch upstream
git checkout -b fix/rig-park-enforcement upstream/main
```

### 2. Make your changes

Edit code, add tests if applicable.

### 3. Test locally

```bash
# Run tests
go test ./...

# Build and test manually
go build -o ./gt ./cmd/gt
./gt <command you're fixing>
```

### 4. Commit with good messages

```bash
git add -A
git commit -m "fix(rig): witness/refinery start checks parked status

The witness and refinery start commands now check rig operational
status before spawning agents. Returns error if rig is parked/docked.

Closes #1152"
```

**Commit message format** (from upstream CONTRIBUTING.md):
- Present tense ("Add feature" not "Added feature")
- First line under 72 characters
- Reference issues: `Closes #1152` or `(gt-xxx)`
- Conventional commits style: `fix(scope):`, `feat(scope):`, `docs:`, etc.

### 5. Push to your fork

```bash
git push origin fix/rig-park-enforcement
```

### 6. Open PR

```bash
gh pr create --repo steveyegge/gastown \
  --title "fix(rig): witness/refinery start checks parked status" \
  --body "## Summary
Witness and refinery start commands now check rig operational status.

## Changes
- Add IsParked()/IsDocked() checks in witness.Start()
- Add IsParked()/IsDocked() checks in refinery.Start()
- Return user-friendly error message

## Testing
- Added unit tests for parked/docked scenarios
- Manual testing: \`gt rig park <rig> && gt witness start <rig>\` → error

Closes #1152"
```

---

## Maintaining Your Fork

### When upstream updates (routine sync)

```bash
# 1. Fetch upstream
git fetch upstream

# 2. Rebase your main onto upstream
#    Your cherry-picks replay on top of the new upstream commits
git checkout main
git rebase upstream/main

# 3. Push (fast-forward if no cherry-picks changed, force if rebase rewrote them)
git push origin main
# If the rebase rewrote cherry-pick hashes (rare), you'll need:
# git push origin main --force-with-lease
```

**Why rebase instead of merge?** Rebase keeps your cherry-picks as clean commits on top of upstream. A merge would create merge commits and make the history harder to reason about.

**Note on force-push:** Rebase rewrites commit hashes. If your cherry-picks applied cleanly on the new upstream base, the content is identical but the hashes change. If anyone tracks your fork, communicate major rebases. In practice this is rare — most syncs fast-forward cleanly because upstream is moving and your cherry-picks are small.

### When your PR is merged upstream

The fix is now in `upstream/main`. When you rebase:

```bash
git fetch upstream
git checkout main
git rebase upstream/main
# Git detects the duplicate cherry-pick and drops it automatically
```

If git doesn't auto-drop it (different squash strategy upstream), manually drop it:

```bash
git rebase -i upstream/main
# Mark the now-redundant commit as "drop"
```

### When your PR is NOT merged

Keep it on `main`. It carries forward on each rebase. No action needed.

### Adding a finalized fix to main

After a feature branch is finalized and the PR is submitted:

```bash
# Squash the feature branch to a single commit (if multi-commit)
git checkout fix/the-thing
git rebase -i upstream/main  # squash all commits into one

# Cherry-pick onto main
git checkout main
git cherry-pick fix/the-thing
git push origin main

# Build patched binary
make install
```

### Follow-up fixes after cherry-picking to main

If you need to add another fix to an already-cherry-picked PR:

```bash
# Make the fix on the feature branch
git checkout fix/the-thing
# ... edit, commit ...
git push origin fix/the-thing  # Updates the PR

# Cherry-pick the new commit onto main
git checkout main
git cherry-pick <new-commit-hash>
git push origin main
make install
```

This means `main` has two commits for one feature. That's fine — both get dropped when upstream merges the PR.

### Escape hatch: extracting a PR from main

If you accidentally developed a fix directly on `main` and need to extract it as a clean PR:

```bash
# Find the commit hash
git log main --oneline

# Create PR branch from upstream/main and cherry-pick
git fetch upstream
git checkout -b fix/specific-thing upstream/main
git cherry-pick abc123
git push origin fix/specific-thing
```

---

## Building Your Patched Binary

### Build from main (normal workflow)

All Gas Town clones track `main`. The binary is built from `main`:

```bash
cd ~/gt/gastown/crew/<name>  # Your working copy
git checkout main
make install

# Verify
gt version
# Should show your commit hash
```

### Build from xexr/wip (testing unfinalized work)

When testing WIP features that aren't on `main` yet:

```bash
git checkout xexr/wip
SKIP_UPDATE_CHECK=1 make install
```

The `SKIP_UPDATE_CHECK=1` flag suppresses the stale binary warning that occurs because `mayor/rig` tracks `main` but the binary is built from a different branch.

### The Makefile

Gas Town uses a standard Makefile:
- `make build` — Build the binary
- `make install` — Build and install to `~/.local/bin/gt`
- `make test` — Run tests
- `make clean` — Remove built binary

Version info (shown in `gt version`) comes from git:
```makefile
VERSION := $(shell git describe --tags --always --dirty)
COMMIT := $(shell git rev-parse --short HEAD)
```

### Gas Town doctor compatibility

`gt doctor --fix` expects all persistent clones (crew, witness/rig, refinery/rig, mayor/rig) to be on `main`. Since your fork's `main` carries your patches, this works naturally — no branch juggling needed.

After updating formulas in the binary, run:
```bash
gt doctor --fix
```
This syncs embedded formulas from the binary to `~/gt/.beads/formulas/`.

---

## CI/CD and Tests

### Current CI Status

Gas Town has GitHub Actions CI that runs:
- **Lint**: `golangci-lint`
- **Test**: `go test ./...` with coverage
- **Integration Tests**: End-to-end tests
- **Check embedded formulas**: Ensures formulas are in sync
- **Windows CI**: Cross-platform testing

**Note**: As of February 2026, CI is frequently failing on main and PRs. This appears to be due to:
- Flaky integration tests
- Formula sync issues
- Test infrastructure problems

**PRs are being merged despite CI failures** — the maintainer (Steve) reviews manually and merges if the changes are sound. Don't let CI failures discourage you from submitting PRs.

### Running tests locally

```bash
# Full test suite
go test ./...

# Specific package
go test ./internal/rig/...

# With verbose output
go test -v ./...

# With coverage
go test -cover ./...
```

### Before submitting a PR

1. Run `go test ./...` locally
2. Run `gofmt -w .` to format code
3. Run `go vet ./...` for static analysis
4. Build and manually test your changes

---

## Upstream Contribution Guidelines

From Gas Town's CONTRIBUTING.md:

### What to contribute

**Good first contributions:**
- Bug fixes with clear reproduction steps
- Documentation improvements
- Test coverage for untested code paths
- Small, focused features

**For larger changes:** Open an issue first to discuss the approach.

### Code style

- Follow standard Go conventions (`gofmt`, `go vet`)
- Keep functions focused and small
- Add comments for non-obvious logic
- Include tests for new functionality

### Commit messages

- Present tense ("Add feature" not "Added feature")
- First line under 72 characters
- Reference issues: `Fix timeout bug (gt-xxx)` or `Closes #123`

### PR naming conventions

Based on merged PRs, use conventional commit prefixes:
- `fix(scope):` — Bug fixes
- `feat(scope):` — New features
- `docs:` — Documentation
- `chore:` — Maintenance tasks
- `refactor:` — Code restructuring

Examples from recent PRs:
- `fix(witness): add grace period before auto-nuking idle polecats`
- `fix(shell): use detected shell RC path in activation message`
- `feat(doctor): distinguish fixed vs unfixed in --fix output`

---

## Quick Reference

### Daily workflow

```bash
# Start of day: sync with upstream
git fetch upstream
git checkout main && git rebase upstream/main && git push origin main

# Work on a fix (always branch from upstream/main)
git fetch upstream
git checkout -b fix/something upstream/main
# ... edit, test, commit ...
git push origin fix/something
gh pr create --repo steveyegge/gastown

# Cherry-pick finalized fix onto main
git checkout main
git cherry-pick <squashed-commit-hash>
git push origin main
make install
```

### Common commands

| Task | Command |
|------|---------|
| Sync main with upstream | `git fetch upstream && git rebase upstream/main && git push` |
| Create PR branch | `git checkout -b fix/thing upstream/main` |
| Open PR | `gh pr create --repo steveyegge/gastown` |
| Cherry-pick to main | `git checkout main && git cherry-pick <hash> && git push` |
| Build patched binary | `make install` (from `main`) |
| Run tests | `go test ./...` |
| Create WIP test branch | `git checkout -b xexr/wip main` |
| Update formulas after build | `gt doctor --fix` |

### Useful aliases

Add to `~/.gitconfig`:
```ini
[alias]
    sync-upstream = "!git fetch upstream && git checkout main && git rebase upstream/main && git push origin main"
    pr-branch = "!f() { git fetch upstream && git checkout -b $1 upstream/main; }; f"
```

---

## Troubleshooting

### Upstream beads-sync issues flooding your fork

**Symptom**: `bd ready` or `bd list` shows hundreds of upstream project issues (created by `stevey`, `mayor`, `gastown/crew/joe`, etc.) that don't belong to you.

**Root cause**: The upstream repo has a `beads-sync` git branch containing thousands of project management issues in `.beads/issues.jsonl`. When you fork and `gt rig add`, this branch gets cloned. The bd daemon creates a beads-sync worktree, detects the JSONL, and imports all upstream issues into your Dolt database via the central Dolt server at `~/.dolt-data` (port 3307).

**The data path**:
```
upstream beads-sync branch (in fork)
  → git worktree at .git/beads-worktrees/beads-sync/
    → .beads/issues.jsonl (3.8MB, ~5700 upstream issues)
      → imported into Dolt server gastown database
        → bd list / bd ready shows upstream issues
```

**Prevention** (during initial setup — Step 1 in "Migrate beads to Dolt"):
1. Comment out `sync-branch: beads-sync` in `.beads/config.yaml` **before** running any bd commands
2. Delete the `beads-sync` branch from your fork: `gh api -X DELETE repos/YOUR_USER/gastown/git/refs/heads/beads-sync`

**Fix** (if upstream issues already imported):
```bash
# 1. Remove the beads-sync worktree
cd ~/gt/gastown/mayor/rig
git worktree remove .git/beads-worktrees/beads-sync --force

# 2. Delete local and remote beads-sync branch
git branch -D beads-sync
gh api -X DELETE repos/YOUR_USER/gastown/git/refs/heads/beads-sync
git remote prune origin

# 3. Comment out sync-branch in ALL config files
#    Check both mayor/rig/.beads/config.yaml AND crew/*/.beads/config.yaml
#    Change:  sync-branch: beads-sync
#    To:      # sync-branch disabled — upstream beads-sync has project issues we don't want
#             # sync-branch: beads-sync

# 4. Purge upstream issues from the Dolt server
#    The data lives in the central Dolt server, NOT in .beads/dolt/
cd ~/gt/.dolt-data
dolt sql -q "USE gastown; DELETE FROM comments WHERE issue_id NOT IN (SELECT id FROM issues WHERE created_by IN ('YOUR_USER') OR created_by LIKE '%YOUR_CREW_NAME%');"
dolt sql -q "USE gastown; DELETE FROM dependencies WHERE issue_id NOT IN (SELECT id FROM issues WHERE created_by IN ('YOUR_USER') OR created_by LIKE '%YOUR_CREW_NAME%');"
dolt sql -q "USE gastown; DELETE FROM labels WHERE issue_id NOT IN (SELECT id FROM issues WHERE created_by IN ('YOUR_USER') OR created_by LIKE '%YOUR_CREW_NAME%');"
dolt sql -q "USE gastown; DELETE FROM events WHERE id NOT IN (SELECT id FROM issues WHERE created_by IN ('YOUR_USER') OR created_by LIKE '%YOUR_CREW_NAME%');"
dolt sql -q "USE gastown; DELETE FROM child_counters WHERE parent_id NOT IN (SELECT id FROM issues WHERE created_by IN ('YOUR_USER') OR created_by LIKE '%YOUR_CREW_NAME%');"
dolt sql -q "USE gastown; DELETE FROM issues WHERE created_by NOT IN ('YOUR_USER') AND created_by NOT LIKE '%YOUR_CREW_NAME%';"

# 5. Commit the purge
cd ~/gt/.dolt-data/gastown
dolt add . && dolt commit -m "Purge upstream issues" --author "You <you@email.com>"
dolt push origin main

# 6. Restart the bd daemon
kill $(cat ~/gt/gastown/mayor/rig/.beads/daemon.pid)
cd ~/gt/gastown/mayor/rig && bd daemon --start

# 7. Verify — should only show your local beads
bd ready
```

**Key insight**: The beads database that `bd` queries is on the central Dolt SQL server (`~/.dolt-data`, port 3307), configured via `.beads/metadata.json` (`dolt_mode: server`, `dolt_database: gastown`). The `.beads/dolt/` directory in the rig is a separate embedded instance and is NOT what `bd` reads from in server mode.

### Rebase conflicts

```bash
# During rebase, if conflicts occur:
# 1. Edit conflicting files
# 2. Stage resolved files
git add <file>
# 3. Continue rebase
git rebase --continue
# Or abort if needed
git rebase --abort
```

### Accidentally committed to main

```bash
# Move commits to a new branch
git branch fix/oops
git checkout main
git reset --hard upstream/main
git checkout fix/oops
```

### Lost commits after rebase

```bash
# Git reflog shows all recent HEAD positions
git reflog
# Find the commit hash and cherry-pick or reset to it
git cherry-pick <hash>
```

### Purging wisp beads for fresh patrols

When resetting trial state, use the purge scripts:
```bash
# Purge all Dolt databases
~/gt/scripts/purge-all-wisps.sh

# Purge specific databases only
~/gt/scripts/purge-all-wisps.sh hq dypt
```

These scripts are idempotent and safe to re-run.
