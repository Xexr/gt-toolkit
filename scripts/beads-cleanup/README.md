# Beads Cleanup Scripts

> **WARNING: These scripts permanently delete data from your Dolt databases.**
> They purge beads (wisps, molecules, ephemeral issues, tombstones), drop
> branches, squash commit history, and force-push to remotes. Read each
> script's description below and its `--help` output before running it.
> There is no undo once data is purged and committed.

Maintenance scripts for Dolt databases used by the beads issue tracker.
All scripts auto-discover databases and accept comma-separated or space-separated database names.

Run any script with `-h` or `--help` for usage details.

## Setup

Scripts auto-detect the `.dolt-data` directory by walking up from the script location.
Override with environment variables if needed:

```bash
export DOLT_DATA=/path/to/.dolt-data
export DOLT_REMOTES=/path/to/dolt-remotes
```

## Scripts

### Wrapper

| Script | Description |
|--------|-------------|
| `dolt-full-cleanup.sh` | Runs all cleanup steps in order. Handles server stop/restart. Supports `--audit`, `--deep`, `--reset-remote` flags. |

### Individual Steps

Run in this order (or use the wrapper):

| # | Script | Description |
|---|--------|-------------|
| 1 | `purge-all-wisps.sh` | Delete wisp beads (patrol ephemeral state) |
| 2 | `purge-polecat-branches.sh` | Delete stale `polecat-*` Dolt branches |
| 3 | `purge-stale-data.sh` | Purge hooked orphans, tombstones, closed molecules, digests, merges, ephemeral issues |
| 4 | `audit-cruft.sh` | Scan for test artifacts, operational noise, stale convoys. Interactive or `--auto`/`--purge-all`/`--json`. |
| 5 | `dolt-gc.sh` | Dolt garbage collection (requires server stopped) |
| 6 | `dolt-shallow-reset.sh` | Squash databases to single commit via dump/reimport. Preserves all remote configs and recreates wisp table schemas. (requires server stopped) |
| 7 | `dolt-remote-reset.sh` | Rebuild remote storage from current shallow state. Handles both file and network remotes. (requires server stopped) |

### Shared

| Script | Description |
|--------|-------------|
| `dolt-common.sh` | Sourced by all scripts. Provides `DOLT_DATA`, `DOLT_REMOTES`, `discover_databases()`, `parse_db_args()`, `show_help()`. |

## Common Usage

```bash
# Standard cleanup (steps 1-3 + GC)
./dolt-full-cleanup.sh

# Standard cleanup + cruft audit report
./dolt-full-cleanup.sh --audit

# Standard cleanup + cruft audit with auto-purge
./dolt-full-cleanup.sh --audit-purge

# Nuclear option: everything + shallow reset + remote rebuild
./dolt-full-cleanup.sh --audit-purge --deep --reset-remote

# Target specific databases
./dolt-full-cleanup.sh hq,dypt

# Run cruft audit standalone (report only)
./audit-cruft.sh --auto

# Run cruft audit with JSON output (for agents)
./audit-cruft.sh --json
```

## Remote Types

Scripts handle both local and network Dolt remotes:

| Remote type | Example | Behavior |
|-------------|---------|----------|
| File | `file:///path/to/remote` | Directory replaced with fresh push |
| GitHub | `https://github.com/org/db` | Force-push overwrites remote history |
| DoltHub | `https://doltremoteapi.dolthub.com/org/db` | Force-push overwrites remote history |

`dolt-shallow-reset.sh` preserves all remote configurations during squash (not
just origin). `dolt-remote-reset.sh` detects the remote type and uses the
appropriate strategy (directory replace vs force-push).

## Database Discovery

Scripts auto-discover databases from `SHOW DATABASES` on the Dolt server.
System schemas (`information_schema`, `mysql`) are excluded automatically.
No hardcoded database lists — new rigs are picked up immediately.
