#!/usr/bin/env bash
# Run Dolt garbage collection to reclaim disk space.
# Should be run AFTER purging branches, wisps, and stale data.
#
# IMPORTANT: This requires exclusive access to the database.
# The Dolt SQL server must be stopped first.
#
# Usage:
#   dolt-gc.sh              # GC all databases
#   dolt-gc.sh hq dypt      # GC specific databases only

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/dolt-common.sh"
[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && { show_help "$0"; exit 0; }
parse_db_args "$@"

# Check if the Gas Town Dolt server is running (port 3307, serves .dolt-data).
# Ignore stale test servers on other ports.
if pgrep -af "dolt sql-server" | grep -q "$DOLT_DATA"; then
    echo "ERROR: Dolt SQL server is running on .dolt-data."
    echo "GC requires exclusive access. Stop the server first:"
    echo "  gt dolt stop"
    echo ""
    echo "Then re-run this script, and restart the server after:"
    echo "  gt dolt start"
    exit 1
fi

# Kill any stale test servers (from go test, temp dirs)
stale_pids=$(pgrep -af "dolt sql-server" | grep -v "$DOLT_DATA" | awk '{print $1}' || true)
if [ -n "$stale_pids" ]; then
    echo "Killing stale test Dolt servers: $stale_pids"
    echo "$stale_pids" | xargs kill 2>/dev/null || true
    sleep 1
fi

echo "=== Dolt Garbage Collection ==="
echo ""

# Pre-flight: show current sizes
echo "Before GC:"
for db in "${DBS[@]}"; do
    size=$(du -sh "$DOLT_DATA/$db/" 2>/dev/null | cut -f1)
    echo "  $db: $size"
done
echo ""

# Run GC per database
failed=0
for db in "${DBS[@]}"; do
    echo "--- GC $db ---"
    if (cd "$DOLT_DATA/$db" && dolt gc 2>&1); then
        echo "  $db: done"
    else
        echo "  $db: FAILED"
        failed=$((failed + 1))
    fi
    echo ""
done

# Also GC the remotes
echo "--- GC remotes ---"
for db in "${DBS[@]}"; do
    remote_dir="$DOLT_REMOTES/$db"
    if [ -d "$remote_dir" ]; then
        if (cd "$remote_dir" && dolt gc 2>&1); then
            echo "  $db remote: done"
        else
            echo "  $db remote: FAILED (non-critical)"
        fi
    fi
done

echo ""
echo "=== After GC ==="
for db in "${DBS[@]}"; do
    size=$(du -sh "$DOLT_DATA/$db/" 2>/dev/null | cut -f1)
    echo "  $db: $size"
done

remote_total=$(du -sh "$DOLT_REMOTES/" 2>/dev/null | cut -f1 || true)
echo "  remotes total: ${remote_total:-(no remotes dir)}"

if [ $failed -gt 0 ]; then
    echo ""
    echo "WARNING: $failed database(s) had GC errors"
    exit 1
fi

echo ""
echo "GC complete. Restart the Dolt server: gt dolt start"
