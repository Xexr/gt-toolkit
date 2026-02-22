# Convoy Manager & Capacity Scheduler: System Analysis

> Working document capturing consolidated understanding of the convoy feeding and
> capacity-controlled dispatch systems, how they interrelate, and open design questions.
>
> Based on analysis of PRs #1615, #1759, #1820, #1747, #1886, #1885, the
> convoy SKILL.md reference, and source-level reading of the dispatch paths.
> February 2026.

## 1. Historical Context: How Work Was Dispatched Before

Before the ConvoyManager and Capacity Scheduler existed, convoy dispatch used
a **redundant observer model**. Three independent agents — the Witness
(per-rig), the Refinery (per-rig), and the Daemon itself — each watched for
bead close events and fed convoys independently.

All three called the same core function: `CheckConvoysForIssueWithAutoStore()`
in what was then `observer.go`. Each observer opened its own beads store
connection, found convoys tracking the closed bead, ran `gt convoy check`,
and called `feedNextReadyIssue()` to dispatch the next ready bead. The
`feedNextReadyIssue` logic — iterating tracked beads, applying type and
blocking filters, dispatching the first eligible one — existed in this
earlier design and was carried forward into the current system.

The idea was redundancy: if one observer missed a close event, another would
catch it. In practice, the implementation was broken:

- The daemon's observer only watched the **town-level (hq) database**, missing
  close events in per-rig stores entirely
- It connected in **embedded mode** instead of server mode
- It **crashed at startup** because Dolt wasn't ready when the daemon started

There was no capacity scheduler, no staging/launch workflow, no wave
computation, and no stranded scan. `gt sling` always spawned polecats
immediately with no concurrency control. If the observers missed a close
event, there was no safety net — the convoy would stall until something
else triggered a feed.

The transition happened on February 17, 2026 (commit `d824cc20`). The
redundant observers in Witness and Refinery were removed, `observer.go` was
renamed to `operations.go`, and the centralised ConvoyManager replaced all
three observers with multi-rig event polling and high-water mark tracking.

## 2. The Two Systems

There are two distinct but composable systems that control how work flows from
"issue is ready" to "polecat is running":

### Convoy Manager (daemon goroutine)

**Owner:** ConvoyManager in `internal/daemon/convoy_manager.go`
**Purpose:** Detect when tracked issues complete and feed the next ready issue.
**Mechanism:** SDK-based polling of all beads stores (hq + per-rig) every 5 seconds.

The ConvoyManager is a goroutine inside the Go daemon process. It maintains
per-store high-water marks and watches for close events. When it detects a
close, it checks if the closed bead is tracked by any convoy, then feeds the
next ready issue via `gt sling`.

Key characteristics:
- Polls all stores every **5 seconds** (not just hq — this was the critical fix in PR #1615)
- Per-store high-water marks ensure exactly-once event processing
- Skips parked/docked rigs
- **Safety guards** (PR #1759): type filtering (only task/bug/feature/chore), blocks
  dependency checking, dispatch failure iteration
- Stranded scan every **30 seconds** as a safety net for edge cases the event poll misses
- Staged convoys (`staged:ready`, `staged:warnings`) are completely inert to the daemon

### Capacity Scheduler (daemon heartbeat step)

**Owner:** `dispatchScheduledWork()` in `internal/cmd/capacity_dispatch.go`
**Purpose:** Control polecat concurrency across all rigs.
**Mechanism:** Daemon heartbeat shells out to `gt scheduler run` every 3 minutes.

The scheduler is a config-driven system (`scheduler.max_polecats` in town settings)
that intercepts `gt sling` calls. When enabled, sling creates ephemeral "sling context"
beads instead of spawning polecats immediately. The daemon heartbeat periodically
dispatches queued context beads within the configured concurrency limit.

Key characteristics:
- Town-level config in `mayor/town-settings.json` under `scheduler` key
- Three modes: direct (`max_polecats <= 0`, default), deferred (`max_polecats > 0`),
  paused (`max_polecats = 0` — creates contexts but daemon doesn't dispatch)
- Sling context beads are ephemeral, contain JSON dispatch params, linked to work
  bead via `tracks` dep. Work beads are **never modified** by the scheduler.
- Capacity measured by live count of polecat tmux sessions (`countActivePolecats()`)
- FIFO ordering by `EnqueuedAt` timestamp
- Circuit breaker: 3 consecutive dispatch failures → quarantined
- Exclusive flock prevents concurrent dispatch cycles

## 3. How They Compose

The two systems compose through the `gt sling` CLI being the shared entry point:

```
                         ┌─────────────────────┐
                         │   ConvoyManager      │
                         │   (5s event poll)    │
                         │                      │
                         │  Detects close event │
                         │  Feeds next ready    │
                         └──────────┬───────────┘
                                    │
                                    │ gt sling <bead> <rig> --no-boot
                                    │
                                    ▼
                         ┌─────────────────────┐
                         │      gt sling        │
                         │   (CLI entry point)  │
                         │                      │
                         │  shouldDeferDispatch()│
                         └──────┬───────┬───────┘
                                │       │
                 max_polecats ≤ 0       max_polecats > 0
                 (direct, default)      (deferred)
                                │       │
                                ▼       ▼
                         ┌──────┐ ┌──────────────┐
                         │Spawn │ │Create sling  │
                         │polecat│ │context bead  │
                         │now   │ │(queued)      │
                         └──────┘ └──────┬───────┘
                                         │
                                         │ Daemon heartbeat (3 min)
                                         │ gt scheduler run
                                         ▼
                                  ┌──────────────┐
                                  │DispatchCycle │
                                  │              │
                                  │ Check capacity│
                                  │ Query pending │
                                  │ FIFO dispatch │
                                  │ Close context │
                                  └──────────────┘
```

When the scheduler is **disabled** (default, `max_polecats = -1`):
- ConvoyManager calls `gt sling` → polecat spawns immediately
- No scheduler involvement at all
- This is how Gas Town has always worked

When the scheduler is **enabled** (`max_polecats > 0`):
- ConvoyManager calls `gt sling` → creates sling context bead (deferred)
- Daemon heartbeat every 3 min → `gt scheduler run` → dispatches within capacity
- The convoy system feeds work into the pipeline; the scheduler controls throughput

## 4. Convoy Stage & Launch Workflow

PR #1820 added a two-phase convoy creation workflow:

1. **`gt convoy stage <epic-id | task-list | convoy-id>`**
   - Walks the bead dependency graph (BFS for epics)
   - Builds in-memory DAG, detects cycles (DFS back-edge)
   - Computes execution waves via Kahn's topological sort
   - Only blocking deps create wave ordering: `blocks`, `conditional-blocks`, `waits-for`
   - `parent-child` is deliberately non-blocking (organizational, not execution)
   - Classifies findings: errors (cycles, missing rig) vs warnings (orphans, parked rigs, etc.)
   - Creates convoy in `staged:ready` or `staged:warnings` status
   - Outputs ASCII dependency tree + wave table

2. **`gt convoy launch <convoy-id>`**
   - Transitions staged → open
   - Dispatches only Wave 1 tasks via `gt sling`
   - Daemon handles subsequent waves automatically via ConvoyManager

Staged convoys are completely inert — daemon skips them in both event poll and
stranded scan. This gives the user a pre-flight validation step before any
work dispatches.

## 5. The Deacon's Current Role

The Deacon is an AI agent (not a daemon goroutine) that acts as a watchdog
and recovery coordinator. It is not a dispatch engine — it makes intelligent
decisions about exceptional cases that the mechanical daemon loops cannot
handle. Its convoy-related responsibilities are:

### Stranded convoy feeding (`gt deacon feed-stranded`)

The Deacon periodically finds stranded convoys (via `gt convoy stranded
--json` — the same command the ConvoyManager's stranded scan uses) and
dispatches dogs to feed them. Unlike the ConvoyManager, the Deacon adds
rate limiting:

- **Per-convoy cooldown** (default 10 minutes) tracked in
  `deacon/feed-stranded-state.json`
- **Max dispatches per cycle** (default 3) to avoid overwhelming the system
- Dispatches a `mol-convoy-feed` molecule to `deacon/dogs`, not the
  individual bead directly

### Recovered bead redispatch (`gt deacon redispatch`)

When a Witness detects a dead polecat with abandoned work, it resets the
bead to `open` status and sends a `RECOVERED_BEAD` mail to the Deacon. The
Deacon then decides whether to re-dispatch:

- **Per-bead cooldown** (default 5 minutes) tracked in
  `deacon/redispatch-state.json`
- **Max attempts** (default 3) before escalating to the Mayor
- Checks bead status before re-slinging (but this check is not atomic with
  the sling call)
- Uses `gt sling --force` to override idempotency checks

### Stale hook cleanup (`gt deacon stale-hooks`)

Finds beads stuck in `hooked` status (default threshold: 1 hour) with dead
assignee tmux sessions. Unhooks them so they become eligible for dispatch
again.

### Relationship to the ConvoyManager

The Deacon and ConvoyManager operate independently with overlapping
responsibilities for stranded work. The ConvoyManager is the fast mechanical
loop (30s scan, immediate sling). The Deacon is the slower intelligent layer
(rate-limited, cooldown-aware, escalation-capable). They share no state
and have no coordination mechanism — see section 8 for the implications.

## 6. Key Design Details

### Three dispatch paths

The convoy system has three distinct dispatch mechanisms, each solving a
different problem:

| Path | Trigger | Interval | Dispatches per cycle | Purpose |
|------|---------|----------|---------------------|---------|
| **Launch** | `gt convoy launch` | One-shot | All Wave 1 in parallel | Cold start — nothing is running, event feed has nothing to react to |
| **Event feed** | Close event in any store | ~5s poll | **Exactly 1** | Steady state — keeps pipeline moving as beads complete |
| **Stranded scan** | Timer | 30s | **Exactly 1** | Safety net — catches orphaned work, dead workers, missed events |

#### Why all three are needed

Launch exists because the event feed **only reacts to close events**. On a
cold convoy with no running polecats, nothing ever closes, so the event feed
never fires. Without launch, you'd be waiting for the stranded scan to pick
up the first bead — and since stranded scan dispatches one per 30s cycle,
an 8-task Wave 1 would take 4 minutes to fully dispatch.

The event feed handles steady-state flow: bead A completes → event feed
detects the close within 5s → feeds the next ready bead → self-sustaining
chain.

The stranded scan is the patrol car. It catches cases the event feed misses:
worker crashes, daemon restarts, race conditions where a close event was
consumed but the feed didn't dispatch.

#### One-at-a-time constraint

Both the event feed (`feedNextReadyIssue` in `operations.go`) and the
stranded scan (`feedFirstReady` in `convoy_manager.go`) dispatch exactly one
bead per cycle, then return. Neither has a documented justification for this
constraint.

The event feed's comment states the design intent:

> Only one issue is dispatched per call. When that issue completes, the
> next close event triggers another feed cycle.

This assumption holds for **linear dependency chains** (A → B → C) but
breaks down for **fan-out patterns**: when a single blocker resolves and
unblocks N beads simultaneously, only one is dispatched via event feed. The
remaining N-1 wait for the stranded scan to pick them up — one per 30s cycle.

The stranded scan has the same limitation despite already having the complete
ready list (`c.ReadyIssues` contains all ready beads). It iterates through
them but returns after the first successful dispatch.

Both automated paths apply identical safety guards:
- `IsSlingableType`: only task/bug/feature/chore (empty defaults to task)
- `isIssueBlocked`: checks blocks/conditional-blocks/waits-for deps, fail-open on errors
- Dispatch failure iteration: continues to next issue on failure

#### Wave ordering is not enforced at runtime

Waves are computed at stage time (`computeWaves` in `convoy_stage.go`) using
Kahn's topological sort on execution edges. They are displayed to the user
for visibility, and Wave 1 is used by launch for the initial burst.

**Waves are never persisted.** They are not stored on the convoy bead or in
any database. Stage computes them, displays them, and discards them. Launch
recomputes them fresh from the live dependency graph — this means the wave
plan always reflects current state, not a stale snapshot from staging.

After launch, the daemon never references wave numbers. Instead, it uses
**dynamic runtime blocking checks** (`isIssueBlocked`) which walk the
bead's dependency edges and check whether blocking targets are still open.
This is more flexible than static waves: a bead can become eligible for
dispatch as soon as its specific blockers resolve, regardless of what "wave"
it was assigned to.

The practical effect is that wave ordering is respected *indirectly* through
the blocking edges that define the waves, but there's no explicit wave-level
batching or sequencing at runtime.

#### Readiness criteria comparison

The event feed and stranded scan use slightly different readiness checks:

| Check | Event feed (`feedNextReadyIssue`) | Stranded scan (`isReadyIssue`) |
|-------|----------------------------------|-------------------------------|
| Status | Must be `open` | `open`, or `in_progress`/`hooked` with dead worker |
| Assignee | Must have no assignee | No assignee, or assignee's tmux session is dead |
| Blocking | `isIssueBlocked` (walks deps) | `t.Blocked` field from issue details |
| Already scheduled | Not checked | Checks for open sling context |
| Type filter | `IsSlingableType` | `IsSlingableType` + `isSlingableBead` (rig routing) |

The stranded scan is more thorough because it's designed to catch edge cases:
orphaned molecules (bead marked in_progress but worker is dead), beads that
were dispatched but whose sling context still exists, etc.

### Scheduler dispatch mechanics

| Setting | Default | Effect |
|---------|---------|--------|
| `max_polecats` | -1 | Direct dispatch (no scheduler) |
| `batch_size` | 1 | Beads dispatched per heartbeat cycle |
| `spawn_delay` | 0s | Delay between spawns within a batch |

Dispatch cycle:
1. Acquire exclusive flock
2. Clean stale contexts (closed/hooked work beads, circuit-broken)
3. Query ready sling contexts (sorted by `EnqueuedAt` — FIFO)
4. `PlanDispatch(available_capacity, batch_size, ready)` → picks `min(cap, batch, ready)`
5. Execute each: `executeSling()` → spawn polecat
6. On success: close sling context bead
7. On failure: increment failure counter; after 3 → circuit-broken

### Capacity measurement

Capacity is measured by **live count of polecat tmux sessions** at dispatch time.
Not a counter that's incremented/decremented — it's self-correcting (crashed
polecats free slots automatically). The count scans all tmux sessions, filters
by session name pattern for polecats.

## 7. Throughput Characteristics (Current Design)

### Scheduler throughput (when enabled)

With scheduler enabled and defaults (`batch_size=1`, heartbeat interval 3 min):

| Scenario | Latency |
|----------|---------|
| Convoy feeds 1 bead, capacity available | 0-5s (event poll) + 0-3min (scheduler dispatch) |
| 3 polecats finish, 3 beads queued | 3 + 3 + 3 = **9 minutes** to dispatch all 3 |
| 10 beads queued, unlimited capacity | **30 minutes** to dispatch all 10 |

The throughput ceiling is `batch_size / heartbeat_interval` = **~20 polecats/hour** at defaults.

Tuning `batch_size` to match `max_polecats` eliminates the per-bead wait but retains
the initial 0-3 min latency before the first dispatch.

### Convoy dispatch throughput (regardless of scheduler)

The convoy feeding logic has its own throughput constraints, independent of the
scheduler:

| Scenario | Dispatch path | Time to fully dispatch |
|----------|--------------|----------------------|
| Launch: 8 Wave 1 beads | Launch burst | **Instant** (all parallel) |
| Linear chain: A→B→C→D | Event feed | ~5s per step (fast) |
| Fan-out: X blocks Y,Z,W — X closes | Event feed + stranded scan | Y: ~5s, Z: ~35s, W: ~65s |
| Fan-out: 10 beads unblocked at once | Event feed + stranded scan | 1st: ~5s, rest: **~4.5 minutes** |
| Cold convoy, no launch used | Stranded scan only | 1 per 30s = **5 min for 10 beads** |

The fan-out case is the critical gap. When a single blocker resolves N beads:
- Event feed dispatches 1 within 5s
- Remaining N-1 wait for stranded scan (1 per 30s)
- Total: ~5s + (N-2) × 30s

For a 10-bead fan-out, this means ~4.5 minutes of unnecessary serialization
when all 10 beads could be dispatched immediately.

## 8. Potential Race Conditions: Deacon vs ConvoyManager

The Deacon and ConvoyManager both detect and act on stranded work
independently. They share no state, hold no shared locks, and have no
coordination mechanism. This creates several race condition windows.

### Existing guards

**Per-bead flock in `gt sling`** — every sling call acquires a file lock at
`~/.runtime/locks/sling/<bead-id>.flock`. If two sling calls target the same
bead simultaneously, the second blocks or fails. This prevents the most
direct form of double-dispatch on a single bead.

**Scheduled beads check in `isReadyIssue`** — the ConvoyManager's stranded
scan calls `areScheduled()` which queries for open sling context beads. If a
bead already has a sling context (queued for scheduler dispatch), stranded
scan skips it.

**Bead status idempotency in `gt sling`** — if a bead is already
hooked/pinned, sling returns a no-op (same target) or error (different
target) unless `--force` is used.

### Where guards break down

**Deacon feed-stranded does not check `areScheduled()`**. It checks
per-convoy cooldown but not whether individual beads within the convoy are
already dispatched or queued. This means the Deacon can dispatch a dog to
feed a convoy that the ConvoyManager is already feeding.

**Deacon redispatch uses `--force`**. This bypasses the idempotency checks
in `gt sling`. If the ConvoyManager has already slung and hooked a recovered
bead, the Deacon's `--force` sling can override the hook and create a
second dispatch.

**Deacon feed-stranded dispatches at the convoy level, not the bead level**.
It slings a `mol-convoy-feed` molecule to a dog, not the individual bead.
The per-bead flock does not help here because the Deacon and ConvoyManager
are slinging different things — one slings the work bead, the other slings
a feed molecule.

**Status checks are not atomic with sling calls**. The Deacon's redispatch
checks bead status before calling `gt sling`, but another actor can change
the status between the check and the sling (TOCTOU window).

### Concrete race scenarios

#### Scenario 1: Dual convoy feeding (medium likelihood, low severity)

1. ConvoyManager stranded scan detects convoy C with ready bead X
2. ConvoyManager slings bead X directly (30s cycle)
3. Deacon feed-stranded detects same convoy C (not in cooldown)
4. Deacon dispatches `mol-convoy-feed` dog for convoy C
5. Dog arrives, finds convoy C, slings bead Y (next ready bead)

**Result**: Two beads dispatched from the same convoy in quick succession.
Not catastrophic — both beads were ready — but the convoy gets more
attention than intended, and if capacity is limited, this consumes extra
slots. The per-bead flock prevents the same bead being slung twice, so the
main risk is resource waste, not duplicate work.

#### Scenario 2: Recovered bead double-dispatch (lower likelihood, medium severity)

1. Witness detects dead polecat for bead X, resets to `open`, mails Deacon
2. ConvoyManager stranded scan sees bead X as ready (open, no live assignee)
3. ConvoyManager slings bead X → polecat starts working
4. Deacon reads `RECOVERED_BEAD` mail, checks status (might still show
   `open` if ConvoyManager's sling is in flight)
5. Deacon calls `gt sling X --force`, overriding the hook

**Result**: The working polecat's bead gets re-hooked to a new target. The
original polecat may continue working on a bead it no longer owns. The
`--force` flag bypasses the idempotency check that would have caught this.

#### Scenario 3: ConvoyManager + scheduler duplicate contexts (lower likelihood, low severity)

1. ConvoyManager event feed slings bead X (creates sling context in deferred mode)
2. ConvoyManager stranded scan runs before scheduler dispatches the context
3. `areScheduled()` check should catch this — bead X has an open sling context
4. But if the sling context creation and the `areScheduled()` query race,
   the context might not be visible yet

**Result**: Two sling contexts for the same bead. Scheduler dispatches both.
Per-bead flock prevents simultaneous polecat spawn, but one succeeds and
the other fails, leaving an orphaned context.

### Risk assessment

| Scenario | Likelihood | Severity | Primary gap |
|----------|-----------|----------|-------------|
| Dual convoy feeding | Medium | Low | Deacon doesn't check `areScheduled()` |
| Recovered bead double-dispatch | Low-Medium | Medium | `--force` bypasses idempotency |
| Duplicate sling contexts | Low | Low | Timing-dependent, mostly guarded |

The most likely failure mode is not two polecats on the same bead (the
per-bead flock mostly prevents this) but rather: the Deacon dispatching a
dog to feed a convoy that the ConvoyManager is already feeding, resulting
in more beads being dispatched than intended within a short window.

## 9. Open Questions

### Convoy dispatch throughput

1. **Why do both feeders dispatch exactly one bead per cycle?** The stranded
   scan already has the full ready list. The event feed already iterates
   through candidates. Both could dispatch all eligible beads in a single
   pass. The one-at-a-time constraint creates a throughput bottleneck for
   fan-out patterns (single blocker unblocking N beads) where N-1 beads
   drain through stranded scan at 1 per 30 seconds.

2. **Could `feedNextReadyIssue` dispatch all newly-unblocked beads?** When
   a close event fires, the event feed could check all tracked beads in the
   convoy and dispatch every one whose blockers are now satisfied, rather
   than stopping after the first. This would make fan-out as fast as the
   initial Wave 1 burst.

3. **Could `feedFirstReady` dispatch all ready beads?** The stranded scan's
   `feedFirstReady` receives a `strandedConvoyInfo` with a complete
   `ReadyIssues` slice. Dispatching all of them instead of just the first
   would clear the backlog in one scan cycle instead of N cycles.

### Scheduler throughput

4. **Why is the default `batch_size` 1?** With capacity already gating concurrency,
   what does limiting to 1-per-cycle add? Could the default safely be equal to
   `max_polecats`?

5. **Why is the scheduler dispatch tied to the 3-minute recovery heartbeat?**
   The heartbeat's 3-minute interval is tuned for agent liveness detection, not
   work dispatch throughput. Could the scheduler get its own faster ticker (like
   the ConvoyManager has its own 5-second poll)?

6. **Could the scheduler be event-driven rather than polled?** The scheduler
   currently piggybacks on the 3-minute recovery heartbeat, but its concern
   (capacity slots) is independent of the ConvoyManager's concern (convoy
   completion). Not all slung work goes through a convoy, so the scheduler
   can't reuse the ConvoyManager's close events. It would need its own
   mechanism — potentially watching for polecat tmux session exits (capacity
   freed) rather than beads events (work completed). A fast event-driven
   path with a shorter safety-net poll (like 30s) would eliminate the 0-3
   minute dispatch latency without coupling it to the convoy system.

### Design coherence

7. **Two polling loops, two intervals, two dispatch paths.** The ConvoyManager polls
   stores every 5s and feeds via `gt sling`. The scheduler polls context beads every
   3min and dispatches via `executeSling`. Could these be unified into a single
   dispatch pipeline?

8. **Stranded scan vs scheduler dispatch overlap.** Both the stranded scan (30s)
    and the scheduler (3min) aim to ensure work gets dispatched. When the scheduler
    is active, does the stranded scan create duplicate sling context beads for the
    same work?

### Operational

9. **Visibility into scheduler state.** `gt scheduler status` and `gt scheduler list`
    exist. Is there a way to see the combined picture — convoy wave plan + what's
    queued + what's actively running + what's blocked?

10. ~~**What happens to sling contexts if the daemon dies?**~~ *Answered:*
    Sling contexts are persistent in the HQ beads DB and survive daemon
    restarts. The scheduler queries all open contexts every cycle with no
    concept of daemon lifetime. On restart, the daemon runs an initial
    heartbeat immediately (before the 3-minute loop), which runs stale
    cleanup (purges circuit-broken, invalid, or terminal-state contexts)
    then dispatches any remaining valid contexts within capacity. No
    orphaned contexts are left behind.

### Deacon / ConvoyManager coordination

11. **Should the Deacon check `areScheduled()` before feeding?** The
    ConvoyManager's stranded scan checks for open sling contexts. The Deacon's
    feed-stranded does not. Adding this check would prevent the Deacon from
    feeding convoys where work is already queued or in flight.

12. **Should the Deacon's redispatch avoid `--force`?** Using `--force`
    bypasses idempotency checks that would catch a bead already hooked by the
    ConvoyManager. Removing `--force` would let the standard idempotency
    checks prevent double-dispatch, at the cost of the Deacon being unable
    to override stale hooks.

13. **Should there be a convoy-level lock for feeding?** A flock on
    `~/.runtime/locks/convoy/<convoy-id>.flock` held during the entire feed
    operation would prevent the Deacon and ConvoyManager from feeding the
    same convoy simultaneously. This would be a stronger guarantee than
    per-bead locking alone.
