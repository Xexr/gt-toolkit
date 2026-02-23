#!/usr/bin/env bash
# Full Dolt database cleanup: wisps, branches, stale data, then GC.
# Idempotent — safe to re-run anytime.
#
# IMPORTANT: Will stop and restart the Dolt server for GC.
#
# Usage:
#   dolt-full-cleanup.sh                          # standard cleanup
#   dolt-full-cleanup.sh --audit                  # + cruft audit (report only)
#   dolt-full-cleanup.sh --audit-purge            # + cruft audit and purge all found
#   dolt-full-cleanup.sh --deep                   # + shallow reset (discard local history)
#   dolt-full-cleanup.sh --deep --reset-remote    # + rebuild remotes too
#   dolt-full-cleanup.sh hq dypt                  # specific databases only
#   dolt-full-cleanup.sh --deep hq dypt           # flags and databases can be mixed

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/dolt-common.sh"
[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && { show_help "$0"; exit 0; }

# Parse flags and database args
DEEP=false
RESET_REMOTE=false
AUDIT=false
AUDIT_PURGE=false
DB_ARGS=()

for arg in "$@"; do
    case "$arg" in
        --deep)         DEEP=true ;;
        --reset-remote) RESET_REMOTE=true ;;
        --audit)        AUDIT=true ;;
        --audit-purge)  AUDIT=true; AUDIT_PURGE=true ;;
        *)              DB_ARGS+=("$arg") ;;
    esac
done

if [ "$RESET_REMOTE" = true ] && [ "$DEEP" = false ]; then
    echo "ERROR: --reset-remote requires --deep"
    echo "Remote reset only makes sense after a shallow reset of local databases."
    exit 1
fi

run_step() {
    if [ ${#DB_ARGS[@]} -gt 0 ]; then
        "$@" "${DB_ARGS[@]}"
    else
        "$@"
    fi
}

# Calculate total steps
total_steps=4
[ "$AUDIT" = true ] && total_steps=$((total_steps + 1))
[ "$DEEP" = true ] && total_steps=$((total_steps + 1))
[ "$RESET_REMOTE" = true ] && total_steps=$((total_steps + 1))
step=0

next_step() {
    step=$((step + 1))
    echo "━━━ Step $step/$total_steps: $1 ━━━"
    echo ""
}

echo "╔══════════════════════════════════════╗"
echo "║       Dolt Full Cleanup              ║"
if [ "$AUDIT" = true ]; then
    if [ "$AUDIT_PURGE" = true ]; then
        echo "║       + Cruft audit & purge          ║"
    else
        echo "║       + Cruft audit (report only)    ║"
    fi
fi
if [ "$DEEP" = true ]; then
    echo "║       Mode: DEEP (history reset)     ║"
fi
if [ "$RESET_REMOTE" = true ]; then
    echo "║       + Remote rebuild               ║"
fi
echo "╚══════════════════════════════════════╝"
echo ""

# Step 1: Purge wisps
next_step "Purge wisps"
run_step "$SCRIPT_DIR/purge-all-wisps.sh"
echo ""

# Step 2: Purge polecat branches
next_step "Purge polecat branches"
run_step "$SCRIPT_DIR/purge-polecat-branches.sh"
echo ""

# Step 3: Purge stale data (hooked, tombstones, closed molecules)
next_step "Purge stale data"
run_step "$SCRIPT_DIR/purge-stale-data.sh"
echo ""

# Step 4 (--audit/--audit-purge): Cruft audit
if [ "$AUDIT" = true ]; then
    next_step "Cruft audit"
    audit_flags=()
    if [ "$AUDIT_PURGE" = true ]; then
        audit_flags+=(--purge-all)
    else
        audit_flags+=(--auto)
    fi
    if [ ${#DB_ARGS[@]} -gt 0 ]; then
        "$SCRIPT_DIR/audit-cruft.sh" "${audit_flags[@]}" "${DB_ARGS[@]}"
    else
        "$SCRIPT_DIR/audit-cruft.sh" "${audit_flags[@]}"
    fi
    echo ""
fi

# Step 5: GC (requires server stop)
next_step "Garbage collection"

server_was_running=false
if pgrep -af "dolt sql-server" | grep -q "$DOLT_DATA"; then
    server_was_running=true
    echo "Stopping Dolt server..."
    gt dolt stop 2>&1 || true
    for i in $(seq 1 10); do
        pgrep -af "dolt sql-server" | grep -q "$DOLT_DATA" || break
        sleep 1
    done
fi

run_step "$SCRIPT_DIR/dolt-gc.sh"
echo ""

# Step N (--deep): Shallow reset local databases
if [ "$DEEP" = true ]; then
    next_step "Shallow reset (discard local history)"
    run_step "$SCRIPT_DIR/dolt-shallow-reset.sh"
    echo ""
fi

# Step N (--reset-remote): Rebuild remotes
if [ "$RESET_REMOTE" = true ]; then
    next_step "Remote reset (rebuild remote storage)"
    run_step "$SCRIPT_DIR/dolt-remote-reset.sh"
    echo ""
fi

# Restart server if it was running
if [ "$server_was_running" = true ]; then
    echo "Restarting Dolt server..."
    gt dolt start 2>&1 || true
fi

echo ""
echo "╔══════════════════════════════════════╗"
echo "║       Cleanup complete               ║"
echo "╚══════════════════════════════════════╝"
