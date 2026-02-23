# Daemon, Boot, and Dogs

An operator's guide to Gas Town's background infrastructure: what runs, when, and why your tokens are burning.

---

## The Daemon (Go Process)

The daemon is **not an AI agent** -- it is a Go binary running as a background service. Every 3 minutes it fires a heartbeat with 16 steps. An initial heartbeat fires immediately on startup.

### Heartbeat Steps

| # | Step | What It Does |
|---|------|-------------|
| 0 | Shutdown guard | Checks `shutdown.lock` via flock -- skips everything if `gt down` is running |
| 0.5 | Telemetry | Increments OTel heartbeat counter |
| 1 | Dolt server | Health check (`SELECT 1`), write capability probe, identity verification. Restarts with exponential backoff if dead. Escalates to Mayor after 5 restarts in 10 minutes. |
| 2 | Ensure Deacon | Start Claude agent if dead. Crash loop detection (5 restarts in 15m blocks further attempts). Exponential backoff (30s initial, doubles to 10m max). |
| 3 | Poke Boot | Spawn a fresh ephemeral Boot agent for Deacon triage |
| 4 | Check Deacon heartbeat | Read `deacon/heartbeat.json`. >15m stale: kill + restart. 5-10m stale: nudge via tmux. |
| 5 | Ensure Witnesses | Per-rig: check alive, detect hung sessions (no output for 30m), start if dead. Skips parked/docked rigs. |
| 6 | Ensure Refineries | Same pattern as witnesses, per-rig. |
| 7 | Ensure Mayor | Always runs (no patrol toggle). Start if dead. |
| 8 | Handle Dogs | Cleanup stuck dogs, detect stale workers (>2h), reap idle dogs (>1h), dispatch plugins to idle dogs. |
| 9 | Lifecycle requests | Check Deacon mail for `LIFECYCLE:` messages (cycle/restart/shutdown). |
| 11 | GUPP violations | Find polecats with hooked work that haven't progressed in >30 minutes. Mail the Witness. |
| 12 | Orphaned work | Find dead polecats that still have work on their hook. Mail the Witness. |
| 13 | Polecat crash detection | Find dead polecat sessions with hooked work. Auto-restart them. Mass death detection (3 deaths in 30s triggers alert). |
| 14 | Cleanup orphaned processes | Kill detached Claude subagent processes with no controlling terminal. |
| 15 | Prune stale branches | `git fetch --prune` + remove merged `polecat/*` branches. |
| 16 | Dispatch queued work | Run `gt scheduler run` for capacity-controlled polecat dispatch. |

### Independent Tickers

These run on their own intervals, separate from the 3-minute heartbeat:

| Ticker | Interval | Purpose |
|--------|----------|---------|
| Dolt health check | 30 seconds | Fast crash detection for Dolt server |
| Dolt remotes push | 15 minutes | Push Dolt databases to git remotes (opt-in) |
| Convoy manager (event poll) | 5 seconds | Watch beads stores for close events, check convoy completion |
| Convoy manager (stranded scan) | 30 seconds | Find stranded convoys, dispatch or auto-close |
| KRC pruner | Configurable | Prune expired ephemeral records |

### Patrol Configuration

Each patrol type can be individually enabled/disabled in `mayor/daemon.json`:
- `deacon`, `witness`, `refinery`, `handler` -- default enabled
- `dolt_remotes` -- opt-in (default disabled)
- Each patrol can filter to specific rigs via the `rigs` field

### Restart Safety

- **Crash loop detection**: 5 restarts in 15 minutes blocks further restarts
- **Exponential backoff**: 30s initial, doubles up to 10m max, resets after 30m stability
- **Shutdown lock**: `daemon/shutdown.lock` via flock prevents restart fights with `gt down`
- **Rig operational state**: Parked/docked rigs and rigs with `auto_restart` disabled are skipped

---

## Boot -- The Daemon's Watchdog

Boot is **not** a regular dog. It is an ephemeral Claude agent spawned **fresh on every daemon tick** (every 3 minutes) with a single job: triage the Deacon.

- **Session name**: `hq-boot` (killed and recreated each tick)
- **Model**: Haiku (same config path as dogs)
- **Working directory**: `~/gt/deacon/dogs/boot/`
- **Prompt**: `"Run gt boot triage now."`
- **Identity**: `GT_ROLE=deacon/boot`, `BD_ACTOR=deacon-boot`

### Boot's 5-Step Triage Cycle

1. **Observe** -- Check Deacon session alive? Peek at pane output (`gt peek deacon`). Read agent bead. Check recent feed activity.
2. **Decide** -- Apply decision matrix (see below).
3. **Act** -- Execute the decision.
4. **Clean** -- Archive stale handoff messages (>1h old) from Deacon's inbox.
5. **Exit** -- Optionally leave handoff mail for next Boot instance, then die.

### Decision Matrix

| Deacon State | Pane Activity | Action |
|---|---|---|
| Dead session | N/A | START (log it; daemon handles actual restart) |
| Alive, active output | N/A | NOTHING |
| Alive, idle < 5m | N/A | NOTHING |
| Alive, idle 5-15m | No mail | NOTHING |
| Alive, idle 5-15m | Has mail | NUDGE |
| Alive, idle > 15m | Any | WAKE |
| Alive, stuck/errors | Any | INTERRUPT (mail requesting restart) |

### Degraded Mode

When tmux is unavailable (`GT_DEGRADED=true`), Boot runs mechanically without AI:
- Check if Deacon alive, restart if dead
- Kill + restart if heartbeat >30m stale
- Nudge if heartbeat >15m stale
- Execute death warrants from `~/gt/warrants/`

### Status

Boot writes its results to `~/gt/deacon/dogs/boot/.boot-status.json`:
```json
{
  "running": false,
  "started_at": "...",
  "completed_at": "...",
  "last_action": "nothing|start|wake|nudge",
  "target": "deacon",
  "error": ""
}
```

Check with `gt boot status`. Also checked by `gt doctor` via `BootHealthCheck`.

---

## Dogs -- The Deacon's Worker Pool

Dogs are **cross-rig reusable infrastructure workers** managed from a kennel at `~/gt/deacon/dogs/`. Unlike ephemeral polecats (created per-task), dogs return to idle after completing work and can be reassigned.

### Characteristics

- **Model**: Claude Haiku (hardcoded early return in config resolver, excluded from cost tier system)
- **Pool size**: Max 4 (default), auto-created on demand
- **Names**: Phonetic alphabet -- alpha, bravo, charlie, delta, echo, foxtrot, golf, hotel
- **Session pattern**: `hq-dog-<name>`
- **Structurally identical**: Any idle dog can receive any task. No specialization.

### How Dogs Get Work

**Automatic (plugin dispatch)**: During daemon heartbeat step 8, `dispatchPlugins()` scans for plugins whose cooldown has elapsed, finds an idle dog, assigns the plugin work.

**Manual (formula/bead dispatch)**: The Deacon or any agent can sling work to dogs:
```bash
gt sling mol-convoy-feed deacon/dogs --var convoy=<id>   # pool dispatch (any idle dog)
gt sling <bead-id> deacon/dogs                           # raw bead dispatch
gt sling <formula> dog:alpha                             # named dog dispatch
```

The dispatch is not limited to predefined tasks -- any formula or bead can be slung to a dog.

### Currently Defined Plugins

| Plugin | Cooldown | Purpose |
|--------|----------|---------|
| github-sheriff | 5 minutes | Monitor GitHub CI checks on open PRs, create beads for failures |
| session-hygiene | 30 minutes | Clean up zombie tmux sessions and orphaned dog sessions |

Plugins are discovered from `~/gt/plugins/` (town-level) and `<rig>/plugins/` (rig-level, overrides by name).

### Formula-Based Tasks (Dispatched by Deacon)

| Formula | Purpose |
|---------|---------|
| `mol-convoy-feed` | Feed stranded convoys by dispatching ready work to polecats |
| `mol-orphan-scan` | Scan for abandoned work |
| `mol-session-gc` | Session garbage collection |

### Dog Lifecycle

```
idle -> assigned (gt sling / plugin dispatch) -> working (tmux + Claude Haiku) -> gt dog done -> idle
```

**Completion**: A dog MUST call `gt dog done` when finished. Without it, the dog stays stuck in "working" state until the daemon's cleanup catches it.

**Stuck detection thresholds**:
| Condition | Action |
|-----------|--------|
| Dead tmux, still "working" | Cleared on next heartbeat |
| Working >2h, no activity | Session killed, work cleared |
| Idle >1h | tmux session killed |
| Idle >4h, pool > 4 dogs | Removed from kennel entirely |

### Dog Work Directory

Each dog gets a worktree per rig (created from bare repos), allowing cross-rig operation:
```
~/gt/deacon/dogs/<name>/          # kennel home
~/gt/deacon/dogs/<name>/<rig>/    # per-rig worktree
~/gt/deacon/dogs/<name>/.dog.json # state file
```

---

## Observability Gap

**`gt status` does NOT show dogs or Boot.** It only displays Mayor, Deacon, Witness, Refinery, Polecats, and Crew.

### How to See What's Actually Running

| Command | Shows |
|---------|-------|
| `gt status` | Mayor, Deacon, Witness, Refinery, Polecats, Crew |
| `gt dog list` | All dogs and their state (idle/working) |
| `gt dog status <name>` | Detailed status for a specific dog |
| `gt boot status` | Boot's last triage result |
| `tmux list-sessions` | All tmux sessions (the ground truth) |

### Token Burn Profile (per 3-minute tick)

When the daemon is running, each heartbeat potentially spawns:

| Agent | Frequency | Model | Nature |
|-------|-----------|-------|--------|
| Boot | Every tick (3m) | Haiku | Ephemeral -- runs triage, then dies |
| Dogs (plugins) | Per cooldown (5m-30m) | Haiku | Persistent session until work done |
| Dogs (formulas) | On demand | Haiku | Persistent session until work done |
| Deacon, Mayor, Witnesses, Refineries | Persistent | Per cost tier | Not re-spawned each tick, just health-checked |

Dogs and Boot default to Haiku and are **excluded from the cost tier system** -- changing tiers (Standard/Economy/Budget) has no effect on them. Override paths exist (`AgentOverride` per-dispatch, `role_agents["dog"]` in settings) but are not used by default.

---

## Key Source Files

| File | Purpose |
|------|---------|
| `internal/daemon/daemon.go` | Daemon heartbeat, all 16 steps |
| `internal/daemon/handler.go` | Dog cleanup, reaping, plugin dispatch |
| `internal/daemon/lifecycle.go` | Lifecycle requests, GUPP violations, orphaned work |
| `internal/boot/boot.go` | Boot spawn, status, triage |
| `internal/cmd/boot.go` | Boot CLI, degraded triage |
| `internal/dog/manager.go` | Dog lifecycle (add, remove, assign, clear) |
| `internal/dog/types.go` | Dog data structures |
| `internal/cmd/dog.go` | Dog CLI commands |
| `internal/cmd/sling_dog.go` | Dog dispatch via sling |
| `internal/plugin/scanner.go` | Plugin discovery |
| `internal/plugin/types.go` | Plugin/gate type definitions |
| `internal/config/loader.go` | Haiku preset for dogs (resolveRoleAgentConfigCore) |
| `internal/config/cost_tier.go` | Dogs excluded from tier management |
| `internal/templates/roles/boot.md.tmpl` | Boot's CLAUDE.md template |
| `internal/templates/roles/dog.md.tmpl` | Dog's CLAUDE.md template |
