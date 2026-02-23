#!/usr/bin/env bash
# Purge stale data from Dolt databases:
#   - Orphaned "hooked" issues (handoffs that were never unhooked)
#   - Tombstoned issues (logically deleted, still taking space)
#   - Closed molecules (ephemeral workflow state, no longer needed)
#   - Closed digests (patrol cycle summaries, operational noise)
#   - Closed merge beads (refinery merge records, operational noise)
#   - Closed ephemeral issues (any remaining ephemeral cruft)
#   - Stale jsonl-import branches
#
# Idempotent — safe to re-run anytime.
#
# Usage:
#   purge-stale-data.sh              # all databases
#   purge-stale-data.sh hq dypt      # specific databases only

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/dolt-common.sh"
[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && { show_help "$0"; exit 0; }
parse_db_args "$@"

echo "=== Stale Data Cleanup ==="
echo ""

# Pre-flight
for db in "${DBS[@]}"; do
    hooked=$(cd "$DOLT_DATA" && dolt sql -q "USE $db; SELECT COUNT(*) FROM issues WHERE status = 'hooked';" 2>/dev/null | grep -oP '\d+' | tail -1 || echo 0)
    tombs=$(cd "$DOLT_DATA" && dolt sql -q "USE $db; SELECT COUNT(*) FROM issues WHERE status = 'tombstone';" 2>/dev/null | grep -oP '\d+' | tail -1 || echo 0)
    mols=$(cd "$DOLT_DATA" && dolt sql -q "USE $db; SELECT COUNT(*) FROM issues WHERE id LIKE '%-mol-%' AND status = 'closed';" 2>/dev/null | grep -oP '\d+' | tail -1 || echo 0)
    digests=$(cd "$DOLT_DATA" && dolt sql -q "USE $db; SELECT COUNT(*) FROM issues WHERE title LIKE 'Digest:%' AND status = 'closed';" 2>/dev/null | grep -oP '\d+' | tail -1 || echo 0)
    merges=$(cd "$DOLT_DATA" && dolt sql -q "USE $db; SELECT COUNT(*) FROM issues WHERE title LIKE 'Merge:%' AND status = 'closed';" 2>/dev/null | grep -oP '\d+' | tail -1 || echo 0)
    ephemeral=$(cd "$DOLT_DATA" && dolt sql -q "USE $db; SELECT COUNT(*) FROM issues WHERE ephemeral = true AND status = 'closed';" 2>/dev/null | grep -oP '\d+' | tail -1 || echo 0)
    import_branches=$(cd "$DOLT_DATA" && dolt sql -q "USE $db; SELECT COUNT(*) FROM dolt_branches WHERE name LIKE 'jsonl-import-%';" 2>/dev/null | grep -oP '\d+' | tail -1 || echo 0)
    echo "  $db: $hooked hooked, $tombs tombstones, $mols mols, $digests digests, $merges merges, $ephemeral ephemeral"
done

echo ""

failed=0
for db in "${DBS[@]}"; do
    sql_file="$SCRIPT_DIR/purge-stale-${db}.sql"
    if [ ! -f "$sql_file" ]; then
        # No per-db SQL file — generate generic cleanup inline
        sql_file=$(mktemp)
        trap "rm -f '$sql_file'" EXIT

        cat > "$sql_file" <<EOSQL
-- Auto-generated stale data cleanup for $db
USE $db;

-- Purge orphaned hooked issues and their related data
DELETE FROM issue_snapshots WHERE issue_id IN (SELECT id FROM issues WHERE status = 'hooked');
DELETE FROM interactions WHERE issue_id IN (SELECT id FROM issues WHERE status = 'hooked');
DELETE FROM comments WHERE issue_id IN (SELECT id FROM issues WHERE status = 'hooked');
DELETE FROM labels WHERE issue_id IN (SELECT id FROM issues WHERE status = 'hooked');
DELETE FROM dependencies WHERE issue_id IN (SELECT id FROM issues WHERE status = 'hooked') OR depends_on_id IN (SELECT id FROM issues WHERE status = 'hooked');
DELETE FROM child_counters WHERE parent_id IN (SELECT id FROM issues WHERE status = 'hooked');
DELETE FROM events WHERE issue_id IN (SELECT id FROM issues WHERE status = 'hooked');
DELETE FROM issues WHERE status = 'hooked';

-- Purge tombstoned issues and their related data
DELETE FROM issue_snapshots WHERE issue_id IN (SELECT id FROM issues WHERE status = 'tombstone');
DELETE FROM interactions WHERE issue_id IN (SELECT id FROM issues WHERE status = 'tombstone');
DELETE FROM comments WHERE issue_id IN (SELECT id FROM issues WHERE status = 'tombstone');
DELETE FROM labels WHERE issue_id IN (SELECT id FROM issues WHERE status = 'tombstone');
DELETE FROM dependencies WHERE issue_id IN (SELECT id FROM issues WHERE status = 'tombstone') OR depends_on_id IN (SELECT id FROM issues WHERE status = 'tombstone');
DELETE FROM child_counters WHERE parent_id IN (SELECT id FROM issues WHERE status = 'tombstone');
DELETE FROM events WHERE issue_id IN (SELECT id FROM issues WHERE status = 'tombstone');
DELETE FROM issues WHERE status = 'tombstone';

-- Purge closed molecules and their related data
DELETE FROM issue_snapshots WHERE issue_id IN (SELECT id FROM issues WHERE id LIKE '%-mol-%' AND status = 'closed');
DELETE FROM interactions WHERE issue_id IN (SELECT id FROM issues WHERE id LIKE '%-mol-%' AND status = 'closed');
DELETE FROM comments WHERE issue_id IN (SELECT id FROM issues WHERE id LIKE '%-mol-%' AND status = 'closed');
DELETE FROM labels WHERE issue_id IN (SELECT id FROM issues WHERE id LIKE '%-mol-%' AND status = 'closed');
DELETE FROM dependencies WHERE issue_id IN (SELECT id FROM issues WHERE id LIKE '%-mol-%' AND status = 'closed') OR depends_on_id IN (SELECT id FROM issues WHERE id LIKE '%-mol-%' AND status = 'closed');
DELETE FROM child_counters WHERE parent_id IN (SELECT id FROM issues WHERE id LIKE '%-mol-%' AND status = 'closed');
DELETE FROM events WHERE issue_id IN (SELECT id FROM issues WHERE id LIKE '%-mol-%' AND status = 'closed');
DELETE FROM issues WHERE id LIKE '%-mol-%' AND status = 'closed';

-- Purge closed digests (patrol cycle summaries)
DELETE FROM issue_snapshots WHERE issue_id IN (SELECT id FROM issues WHERE title LIKE 'Digest:%' AND status = 'closed');
DELETE FROM interactions WHERE issue_id IN (SELECT id FROM issues WHERE title LIKE 'Digest:%' AND status = 'closed');
DELETE FROM comments WHERE issue_id IN (SELECT id FROM issues WHERE title LIKE 'Digest:%' AND status = 'closed');
DELETE FROM labels WHERE issue_id IN (SELECT id FROM issues WHERE title LIKE 'Digest:%' AND status = 'closed');
DELETE FROM dependencies WHERE issue_id IN (SELECT id FROM issues WHERE title LIKE 'Digest:%' AND status = 'closed') OR depends_on_id IN (SELECT id FROM issues WHERE title LIKE 'Digest:%' AND status = 'closed');
DELETE FROM child_counters WHERE parent_id IN (SELECT id FROM issues WHERE title LIKE 'Digest:%' AND status = 'closed');
DELETE FROM events WHERE issue_id IN (SELECT id FROM issues WHERE title LIKE 'Digest:%' AND status = 'closed');
DELETE FROM issues WHERE title LIKE 'Digest:%' AND status = 'closed';

-- Purge closed merge beads (refinery merge records)
DELETE FROM issue_snapshots WHERE issue_id IN (SELECT id FROM issues WHERE title LIKE 'Merge:%' AND status = 'closed');
DELETE FROM interactions WHERE issue_id IN (SELECT id FROM issues WHERE title LIKE 'Merge:%' AND status = 'closed');
DELETE FROM comments WHERE issue_id IN (SELECT id FROM issues WHERE title LIKE 'Merge:%' AND status = 'closed');
DELETE FROM labels WHERE issue_id IN (SELECT id FROM issues WHERE title LIKE 'Merge:%' AND status = 'closed');
DELETE FROM dependencies WHERE issue_id IN (SELECT id FROM issues WHERE title LIKE 'Merge:%' AND status = 'closed') OR depends_on_id IN (SELECT id FROM issues WHERE title LIKE 'Merge:%' AND status = 'closed');
DELETE FROM child_counters WHERE parent_id IN (SELECT id FROM issues WHERE title LIKE 'Merge:%' AND status = 'closed');
DELETE FROM events WHERE issue_id IN (SELECT id FROM issues WHERE title LIKE 'Merge:%' AND status = 'closed');
DELETE FROM issues WHERE title LIKE 'Merge:%' AND status = 'closed';

-- Purge any remaining closed ephemeral issues
DELETE FROM issue_snapshots WHERE issue_id IN (SELECT id FROM issues WHERE ephemeral = true AND status = 'closed');
DELETE FROM interactions WHERE issue_id IN (SELECT id FROM issues WHERE ephemeral = true AND status = 'closed');
DELETE FROM comments WHERE issue_id IN (SELECT id FROM issues WHERE ephemeral = true AND status = 'closed');
DELETE FROM labels WHERE issue_id IN (SELECT id FROM issues WHERE ephemeral = true AND status = 'closed');
DELETE FROM dependencies WHERE issue_id IN (SELECT id FROM issues WHERE ephemeral = true AND status = 'closed') OR depends_on_id IN (SELECT id FROM issues WHERE ephemeral = true AND status = 'closed');
DELETE FROM child_counters WHERE parent_id IN (SELECT id FROM issues WHERE ephemeral = true AND status = 'closed');
DELETE FROM events WHERE issue_id IN (SELECT id FROM issues WHERE ephemeral = true AND status = 'closed');
DELETE FROM issues WHERE ephemeral = true AND status = 'closed';

CALL DOLT_ADD('.');
CALL DOLT_COMMIT('--allow-empty', '-m', 'chore: purge stale data from $db');

SELECT
    (SELECT COUNT(*) FROM issues WHERE status = 'hooked') AS remaining_hooked,
    (SELECT COUNT(*) FROM issues WHERE status = 'tombstone') AS remaining_tombstones,
    (SELECT COUNT(*) FROM issues WHERE id LIKE '%-mol-%' AND status = 'closed') AS remaining_closed_mols,
    (SELECT COUNT(*) FROM issues WHERE title LIKE 'Digest:%' AND status = 'closed') AS remaining_digests,
    (SELECT COUNT(*) FROM issues WHERE title LIKE 'Merge:%' AND status = 'closed') AS remaining_merges,
    (SELECT COUNT(*) FROM issues WHERE ephemeral = true AND status = 'closed') AS remaining_ephemeral;
EOSQL
    fi

    echo "--- Purging $db ---"
    if (cd "$DOLT_DATA" && dolt sql --file "$sql_file" 2>&1); then
        echo "  $db: done"
    else
        echo "  $db: FAILED"
        failed=$((failed + 1))
    fi
    echo ""
done

# Delete stale jsonl-import branches
echo "--- Cleaning import branches ---"
for db in "${DBS[@]}"; do
    branches=$(cd "$DOLT_DATA" && dolt sql -q "USE $db; SELECT name FROM dolt_branches WHERE name LIKE 'jsonl-import-%';" 2>/dev/null \
        | grep 'jsonl-import-' | sed 's/|//g' | tr -d ' ' || true)
    count=$(echo "$branches" | grep -c 'jsonl-import-' || true)
    if [ "$count" -gt 0 ]; then
        while IFS= read -r branch; do
            [ -z "$branch" ] && continue
            cd "$DOLT_DATA" && dolt sql -q "USE $db; CALL DOLT_BRANCH('-D', '$branch');" >/dev/null 2>&1 || true
        done <<< "$branches"
        echo "  $db: deleted $count import branches"
    fi
done

echo ""
echo "=== Summary ==="
for db in "${DBS[@]}"; do
    total=$(cd "$DOLT_DATA" && dolt sql -q "USE $db; SELECT COUNT(*) FROM issues;" 2>/dev/null | grep -oP '\d+' | tail -1)
    cruft=$(cd "$DOLT_DATA" && dolt sql -q "USE $db; SELECT COUNT(*) FROM issues WHERE status IN ('hooked', 'tombstone') OR (status = 'closed' AND (id LIKE '%-mol-%' OR title LIKE 'Digest:%' OR title LIKE 'Merge:%' OR ephemeral = true));" 2>/dev/null | grep -oP '\d+' | tail -1)
    echo "  $db: $total issues ($cruft stale remaining)"
done

if [ $failed -gt 0 ]; then
    echo ""
    echo "WARNING: $failed database(s) had errors"
    exit 1
fi

echo ""
echo "Run dolt-gc.sh to reclaim disk space."
