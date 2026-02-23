#!/usr/bin/env bash
# Delete stale polecat-* branches from Dolt databases.
# Polecat branches are created per-session and never cleaned up.
# Idempotent — safe to re-run anytime.
#
# Usage:
#   purge-polecat-branches.sh              # all databases
#   purge-polecat-branches.sh hq gastown   # specific databases only

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/dolt-common.sh"
[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && { show_help "$0"; exit 0; }
parse_db_args "$@"

echo "=== Polecat Branch Cleanup ==="
echo ""

total_deleted=0
failed=0

for db in "${DBS[@]}"; do
    # Get list of polecat branches
    branches=$(cd "$DOLT_DATA" && dolt sql -q "USE $db; SELECT name FROM dolt_branches WHERE name LIKE 'polecat-%';" 2>/dev/null \
        | grep 'polecat-' | sed 's/|//g' | tr -d ' ' || true)

    count=$(echo "$branches" | grep -c 'polecat-' || true)

    if [ "$count" -eq 0 ]; then
        echo "  $db: no polecat branches"
        continue
    fi

    echo "  $db: $count polecat branches — deleting..."

    db_deleted=0
    while IFS= read -r branch; do
        [ -z "$branch" ] && continue
        if (cd "$DOLT_DATA" && dolt sql -q "USE $db; CALL DOLT_BRANCH('-D', '$branch');" >/dev/null 2>&1); then
            db_deleted=$((db_deleted + 1))
        else
            echo "    WARNING: failed to delete $branch"
            failed=$((failed + 1))
        fi
    done <<< "$branches"

    echo "    deleted $db_deleted branches"
    total_deleted=$((total_deleted + db_deleted))
done

echo ""
echo "=== Summary ==="
echo "  Deleted: $total_deleted polecat branches"

# Verify
for db in "${DBS[@]}"; do
    remaining=$(cd "$DOLT_DATA" && dolt sql -q "USE $db; SELECT COUNT(*) FROM dolt_branches WHERE name LIKE 'polecat-%';" 2>/dev/null \
        | grep -oP '\d+' | tail -1 || echo "?")
    total_branches=$(cd "$DOLT_DATA" && dolt sql -q "USE $db; SELECT COUNT(*) FROM dolt_branches;" 2>/dev/null \
        | grep -oP '\d+' | tail -1 || echo "?")
    echo "  $db: $remaining polecat branches remaining ($total_branches total branches)"
done

if [ $failed -gt 0 ]; then
    echo ""
    echo "WARNING: $failed branch deletion(s) failed"
    exit 1
fi

echo ""
echo "Run dolt-gc.sh to reclaim disk space."
