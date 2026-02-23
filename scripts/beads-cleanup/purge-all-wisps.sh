#!/usr/bin/env bash
# Purge all wisp beads from Dolt databases.
# Auto-discovers databases and adapts to each schema.
# Idempotent — safe to re-run anytime to reset patrol state.
#
# Handles both legacy wisps (stored in issues table with %-wisp-% IDs)
# and new-style wisps (stored in separate dolt_ignore-d wisp tables:
# wisps, wisp_labels, wisp_dependencies, wisp_events, wisp_comments).
#
# Usage:
#   purge-all-wisps.sh              # all databases
#   purge-all-wisps.sh hq dypt      # specific databases (space-separated)
#   purge-all-wisps.sh hq,dypt      # specific databases (comma-separated)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/dolt-common.sh"
[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && { show_help "$0"; exit 0; }
parse_db_args "$@"

# Helper: check if a table exists in the given database
table_exists() {
    local db="$1" table="$2"
    local result
    result=$(cd "$DOLT_DATA" && dolt sql -q "USE $db; SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = '$db' AND table_name = '$table';" 2>/dev/null | grep -oP '\d+' | tail -1 || echo 0)
    [ "$result" -gt 0 ]
}

echo "=== Wisp Purge ==="
echo "Databases: ${DBS[*]}"
echo ""

# Pre-flight: count wisps in each database (both legacy and new-style)
for db in "${DBS[@]}"; do
    legacy_count=$(cd "$DOLT_DATA" && dolt sql -q "USE $db; SELECT COUNT(*) FROM issues WHERE id LIKE '%-wisp-%';" 2>/dev/null | grep -oP '\d+' | tail -1 || echo 0)
    new_count=0
    if table_exists "$db" "wisps"; then
        new_count=$(cd "$DOLT_DATA" && dolt sql -q "USE $db; SELECT COUNT(*) FROM wisps;" 2>/dev/null | grep -oP '\d+' | tail -1 || echo 0)
    fi
    total=$((legacy_count + new_count))
    echo "  $db: $total wisps (legacy: $legacy_count, wisp table: $new_count)"
done

echo ""

# Purge each database
failed=0
for db in "${DBS[@]}"; do
    legacy_count=$(cd "$DOLT_DATA" && dolt sql -q "USE $db; SELECT COUNT(*) FROM issues WHERE id LIKE '%-wisp-%';" 2>/dev/null | grep -oP '\d+' | tail -1 || echo 0)
    new_count=0
    has_wisps_table=false
    if table_exists "$db" "wisps"; then
        has_wisps_table=true
        new_count=$(cd "$DOLT_DATA" && dolt sql -q "USE $db; SELECT COUNT(*) FROM wisps;" 2>/dev/null | grep -oP '\d+' | tail -1 || echo 0)
    fi
    total=$((legacy_count + new_count))

    if [ "$total" -eq 0 ]; then
        echo "  $db: no wisps, skipping"
        continue
    fi

    echo "--- Purging $db ($total wisps: legacy=$legacy_count, new=$new_count) ---"

    # Build and run purge SQL dynamically
    sql="USE $db;"

    # Legacy wisps (in issues table and related tables)
    if [ "$legacy_count" -gt 0 ]; then
        # Check for optional tables
        if table_exists "$db" "issue_snapshots"; then
            sql+=" DELETE FROM issue_snapshots WHERE issue_id LIKE '%-wisp-%';"
        fi
        if table_exists "$db" "interactions"; then
            sql+=" DELETE FROM interactions WHERE issue_id LIKE '%-wisp-%';"
        fi
        sql+=" DELETE FROM comments WHERE issue_id LIKE '%-wisp-%';"
        sql+=" DELETE FROM labels WHERE issue_id LIKE '%-wisp-%';"
        if table_exists "$db" "dirty_issues"; then
            sql+=" DELETE FROM dirty_issues WHERE issue_id LIKE '%-wisp-%';"
        fi
        sql+=" DELETE FROM dependencies WHERE issue_id LIKE '%-wisp-%' OR depends_on_id LIKE '%-wisp-%';"
        if table_exists "$db" "child_counters"; then
            sql+=" DELETE FROM child_counters WHERE parent_id LIKE '%-wisp-%';"
        fi
        sql+=" DELETE FROM events WHERE issue_id LIKE '%-wisp-%';"
        sql+=" DELETE FROM issues WHERE id LIKE '%-wisp-%';"
    fi

    # New-style wisps (separate dolt_ignore-d tables)
    if [ "$has_wisps_table" = true ] && [ "$new_count" -gt 0 ]; then
        # Truncate via DELETE (TRUNCATE not supported in Dolt)
        for tbl in wisp_comments wisp_dependencies wisp_events wisp_labels wisps; do
            if table_exists "$db" "$tbl"; then
                sql+=" DELETE FROM $tbl;"
            fi
        done
    fi

    sql+=" CALL DOLT_ADD('.');"
    sql+=" CALL DOLT_COMMIT('--allow-empty', '-m', 'chore: purge wisp beads from $db');"

    if (cd "$DOLT_DATA" && dolt sql -q "$sql" 2>&1); then
        echo "  $db: done"
    else
        echo "  $db: FAILED"
        failed=$((failed + 1))
    fi
    echo ""
done

# Summary
echo "=== Summary ==="
for db in "${DBS[@]}"; do
    legacy_count=$(cd "$DOLT_DATA" && dolt sql -q "USE $db; SELECT COUNT(*) FROM issues WHERE id LIKE '%-wisp-%';" 2>/dev/null | grep -oP '\d+' | tail -1 || echo 0)
    new_count=0
    if table_exists "$db" "wisps"; then
        new_count=$(cd "$DOLT_DATA" && dolt sql -q "USE $db; SELECT COUNT(*) FROM wisps;" 2>/dev/null | grep -oP '\d+' | tail -1 || echo 0)
    fi
    total_issues=$(cd "$DOLT_DATA" && dolt sql -q "USE $db; SELECT COUNT(*) FROM issues;" 2>/dev/null | grep -oP '\d+' | tail -1 || echo 0)
    echo "  $db: $legacy_count legacy + $new_count new wisps remaining ($total_issues total issues)"
done

if [ $failed -gt 0 ]; then
    echo ""
    echo "WARNING: $failed database(s) had errors"
    exit 1
fi

echo ""
echo "All clean. Fresh patrols will start from scratch."
