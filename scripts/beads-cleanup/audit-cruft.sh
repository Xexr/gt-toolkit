#!/usr/bin/env bash
# Audit Dolt databases for cruft issues and optionally purge them.
#
# Scans for:
#   - Test artifacts (titles matching test/dummy/placeholder/example patterns)
#   - WORK_DONE dispatch receipts
#   - Closed convoys and stale open convoys (Work: prefix)
#   - Convoy landed notifications
#   - ORPHAN/RECOVERY issues
#   - Polecat boot errors
#   - Regression test patterns (B1:/C2:/D1:/E1:/F1: etc.)
#   - Child/Implement stubs
#   - File creation stubs (Create HELLO/JOKE/LOREM etc.)
#   - Closed PR review tasks (PR #NNNN: prefix)
#
# Reports findings per category with issue IDs and titles, then offers
# options: purge all, purge by category, or skip.
#
# Designed to be run interactively or by an agent.
#
# Usage:
#   audit-cruft.sh                    # all databases, interactive
#   audit-cruft.sh hq dypt            # specific databases
#   audit-cruft.sh --auto             # non-interactive, report only
#   audit-cruft.sh --purge-all        # purge everything found
#   audit-cruft.sh --purge=3,5        # purge specific categories by number
#   audit-cruft.sh --json             # output as JSON (for agent consumption)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/dolt-common.sh"
[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && { show_help "$0"; exit 0; }

# Parse flags and database args
MODE="interactive"  # interactive | auto | purge-all | purge-select
PURGE_CATS=""
JSON_OUTPUT=false
DB_ARGS=()

for arg in "$@"; do
    case "$arg" in
        --auto)         MODE="auto" ;;
        --purge-all)    MODE="purge-all" ;;
        --purge=*)      MODE="purge-select"; PURGE_CATS="${arg#--purge=}" ;;
        --json)         JSON_OUTPUT=true ;;
        *)              DB_ARGS+=("$arg") ;;
    esac
done

parse_db_args "${DB_ARGS[@]+"${DB_ARGS[@]}"}"

# ── Category definitions ──────────────────────────────────────────────
# Each category: name, SQL WHERE clause, description
# Categories are checked in order; earlier matches take priority.

declare -a CAT_NAMES CAT_WHERES CAT_DESCS
CAT_NAMES[1]="WORK_DONE receipts"
CAT_WHERES[1]="title LIKE 'WORK_DONE:%'"
CAT_DESCS[1]="Dispatch receipt notifications from completed work"

CAT_NAMES[2]="Closed convoys"
CAT_WHERES[2]="issue_type = 'convoy' AND status = 'closed'"
CAT_DESCS[2]="Completed convoy orchestration records"

CAT_NAMES[3]="Stale open convoys"
CAT_WHERES[3]="issue_type = 'convoy' AND status = 'open' AND title LIKE 'Work:%'"
CAT_DESCS[3]="Open convoy dispatches with Work: prefix (test scaffolding)"

CAT_NAMES[4]="Convoy landed notifications"
CAT_WHERES[4]="title LIKE '%Convoy landed:%'"
CAT_DESCS[4]="Convoy completion notifications"

CAT_NAMES[5]="ORPHAN/RECOVERY issues"
CAT_WHERES[5]="title LIKE 'ORPHAN%' OR title LIKE 'RECOVERY%'"
CAT_DESCS[5]="Orphan recovery and recovery-needed markers"

CAT_NAMES[6]="Polecat boot errors"
CAT_WHERES[6]="title LIKE 'Polecat boot%'"
CAT_DESCS[6]="Polecat sessions that booted with no work"

CAT_NAMES[7]="Regression test patterns"
CAT_WHERES[7]="status = 'closed' AND (title LIKE 'B1:%' OR title LIKE 'B2:%' OR title LIKE 'C1%:%' OR title LIKE 'C2:%' OR title LIKE 'C5:%' OR title LIKE 'D1:%' OR title LIKE 'D2:%' OR title LIKE 'D3:%' OR title LIKE 'D4:%' OR title LIKE 'D5:%' OR title LIKE 'E1:%' OR title LIKE 'E3:%' OR title LIKE 'E5:%' OR title LIKE 'E6:%' OR title LIKE 'F1:%' OR title LIKE 'F2:%')"
CAT_DESCS[7]="Integration branch regression test artifacts (B1/C2/D1/E1/F1 etc.)"

CAT_NAMES[8]="Child/Implement stubs"
CAT_WHERES[8]="status = 'closed' AND (title LIKE 'Child task %' OR title LIKE 'Child with dep %' OR title LIKE 'Implement feature%')"
CAT_DESCS[8]="Template expansion stubs for child tasks"

CAT_NAMES[9]="File creation stubs"
CAT_WHERES[9]="status = 'closed' AND (title LIKE 'Create HELLO%' OR title LIKE 'Create JOKE%' OR title LIKE 'Create INTERESTING%' OR title LIKE 'Create DEEP_%' OR title LIKE 'Create FALLBACK_%' OR title LIKE 'Create INTEGRATION_%' OR title LIKE 'Add TEST_FILE%' OR title LIKE 'Create test-file%' OR title LIKE 'Add LOREM%' OR title LIKE 'Add TESTING%')"
CAT_DESCS[9]="Polecat test file creation stubs (HELLO.md, JOKE.md, etc.)"

CAT_NAMES[10]="Closed PR review tasks"
CAT_WHERES[10]="status = 'closed' AND title LIKE 'PR #%'"
CAT_DESCS[10]="Completed PR review tracking tasks (PRs already merged)"

CAT_NAMES[11]="Test artifacts"
CAT_WHERES[11]="(title LIKE '%dummy%' OR title LIKE '%placeholder%' OR title LIKE '%sample task%' OR title LIKE '%scratch%') OR (status = 'closed' AND (title LIKE '%Integration Branch Test%' OR title LIKE '%Integration branch test%' OR title LIKE '%baseline test%' OR title LIKE '%pipeline test%' OR title LIKE '%Validation test task%' OR title LIKE '%JSON status test%' OR title LIKE '%Standalone task for%'))"
CAT_DESCS[11]="Test artifacts identified by title patterns (conservative — avoids 'test' substring to prevent false positives)"

NUM_CATS=11

# ── Scan ──────────────────────────────────────────────────────────────

declare -A FINDINGS  # key: "db:cat" → count
declare -A FINDING_DETAILS  # key: "db:cat" → "id|title\n..."

total_cruft=0

echo "=== Cruft Audit ==="
echo ""

for db in "${DBS[@]}"; do
    db_total=0
    for cat in $(seq 1 $NUM_CATS); do
        where="${CAT_WHERES[$cat]}"

        # Get count
        count=$(cd "$DOLT_DATA" && dolt sql -q "USE $db; SELECT COUNT(*) FROM issues WHERE $where;" 2>/dev/null | grep -oP '\d+' | tail -1 || echo 0)

        if [ "$count" -gt 0 ]; then
            FINDINGS["$db:$cat"]=$count
            db_total=$((db_total + count))
            total_cruft=$((total_cruft + count))

            # Get details (id + title, max 25 per category)
            details=$(cd "$DOLT_DATA" && dolt sql -q "USE $db; SELECT id, title, status FROM issues WHERE $where ORDER BY title LIMIT 25;" 2>/dev/null || true)
            FINDING_DETAILS["$db:$cat"]="$details"
        fi
    done
done

# ── Report ────────────────────────────────────────────────────────────

if [ "$JSON_OUTPUT" = true ]; then
    echo "{"
    echo "  \"total_cruft\": $total_cruft,"
    echo "  \"categories\": ["
    first_cat=true
    for cat in $(seq 1 $NUM_CATS); do
        cat_total=0
        for db in "${DBS[@]}"; do
            cat_total=$((cat_total + ${FINDINGS["$db:$cat"]:-0}))
        done
        [ "$cat_total" -eq 0 ] && continue

        if [ "$first_cat" = true ]; then first_cat=false; else echo ","; fi
        echo "    {"
        echo "      \"number\": $cat,"
        echo "      \"name\": \"${CAT_NAMES[$cat]}\","
        echo "      \"description\": \"${CAT_DESCS[$cat]}\","
        echo "      \"total\": $cat_total,"
        echo "      \"databases\": {"
        first_db=true
        for db in "${DBS[@]}"; do
            count=${FINDINGS["$db:$cat"]:-0}
            [ "$count" -eq 0 ] && continue
            if [ "$first_db" = true ]; then first_db=false; else echo ","; fi
            echo "        \"$db\": $count"
        done
        echo "      }"
        echo -n "    }"
    done
    echo ""
    echo "  ]"
    echo "}"
    [ "$MODE" = "auto" ] || [ "$MODE" = "interactive" ] && exit 0
fi

if [ "$total_cruft" -eq 0 ]; then
    echo "No cruft found. Databases are clean."
    exit 0
fi

echo "Found $total_cruft potential cruft issues:"
echo ""

for cat in $(seq 1 $NUM_CATS); do
    cat_total=0
    for db in "${DBS[@]}"; do
        cat_total=$((cat_total + ${FINDINGS["$db:$cat"]:-0}))
    done
    [ "$cat_total" -eq 0 ] && continue

    echo "  [$cat] ${CAT_NAMES[$cat]} ($cat_total)"
    echo "      ${CAT_DESCS[$cat]}"
    for db in "${DBS[@]}"; do
        count=${FINDINGS["$db:$cat"]:-0}
        [ "$count" -eq 0 ] && continue
        echo "      $db: $count"
    done
    echo ""
done

# ── Details ───────────────────────────────────────────────────────────

echo "--- Details ---"
echo ""

for cat in $(seq 1 $NUM_CATS); do
    cat_total=0
    for db in "${DBS[@]}"; do
        cat_total=$((cat_total + ${FINDINGS["$db:$cat"]:-0}))
    done
    [ "$cat_total" -eq 0 ] && continue

    echo "[$cat] ${CAT_NAMES[$cat]}:"
    for db in "${DBS[@]}"; do
        count=${FINDINGS["$db:$cat"]:-0}
        [ "$count" -eq 0 ] && continue
        echo "  $db ($count):"
        echo "${FINDING_DETAILS["$db:$cat"]}" | head -30
    done
    echo ""
done

# ── Action ────────────────────────────────────────────────────────────

if [ "$MODE" = "auto" ]; then
    echo "Audit complete. Run with --purge-all or --purge=1,2,3 to clean up."
    exit 0
fi

# Build purge list
CATS_TO_PURGE=()

if [ "$MODE" = "purge-all" ]; then
    for cat in $(seq 1 $NUM_CATS); do
        cat_total=0
        for db in "${DBS[@]}"; do
            cat_total=$((cat_total + ${FINDINGS["$db:$cat"]:-0}))
        done
        [ "$cat_total" -gt 0 ] && CATS_TO_PURGE+=("$cat")
    done
elif [ "$MODE" = "purge-select" ]; then
    IFS=',' read -ra CATS_TO_PURGE <<< "$PURGE_CATS"
elif [ "$MODE" = "interactive" ]; then
    echo "Options:"
    echo "  a) Purge ALL categories above"
    echo "  s) Specify category numbers to purge (comma-separated)"
    echo "  n) Do nothing (exit)"
    echo ""
    read -rp "Choice [a/s/n]: " choice
    case "$choice" in
        a|A)
            for cat in $(seq 1 $NUM_CATS); do
                cat_total=0
                for db in "${DBS[@]}"; do
                    cat_total=$((cat_total + ${FINDINGS["$db:$cat"]:-0}))
                done
                [ "$cat_total" -gt 0 ] && CATS_TO_PURGE+=("$cat")
            done
            ;;
        s|S)
            read -rp "Category numbers (e.g. 1,3,7): " cats_input
            IFS=',' read -ra CATS_TO_PURGE <<< "$cats_input"
            ;;
        *)
            echo "No changes made."
            exit 0
            ;;
    esac
fi

if [ ${#CATS_TO_PURGE[@]} -eq 0 ]; then
    echo "Nothing to purge."
    exit 0
fi

# ── Purge ─────────────────────────────────────────────────────────────

echo ""
echo "=== Purging ==="

purge_issues() {
    local db="$1"
    local where="$2"

    cd "$DOLT_DATA" && dolt sql -q "
        USE $db;
        DELETE FROM issue_snapshots WHERE issue_id IN (SELECT id FROM issues WHERE $where);
        DELETE FROM interactions WHERE issue_id IN (SELECT id FROM issues WHERE $where);
        DELETE FROM comments WHERE issue_id IN (SELECT id FROM issues WHERE $where);
        DELETE FROM labels WHERE issue_id IN (SELECT id FROM issues WHERE $where);
        DELETE FROM dependencies WHERE issue_id IN (SELECT id FROM issues WHERE $where) OR depends_on_id IN (SELECT id FROM issues WHERE $where);
        DELETE FROM child_counters WHERE parent_id IN (SELECT id FROM issues WHERE $where);
        DELETE FROM events WHERE issue_id IN (SELECT id FROM issues WHERE $where);
        DELETE FROM issues WHERE $where;
    " 2>/dev/null
}

for db in "${DBS[@]}"; do
    db_purged=0
    has_work=false

    for cat in "${CATS_TO_PURGE[@]}"; do
        count=${FINDINGS["$db:$cat"]:-0}
        [ "$count" -eq 0 ] && continue
        has_work=true

        where="${CAT_WHERES[$cat]}"
        echo "  $db: purging [$cat] ${CAT_NAMES[$cat]} ($count)..."

        if purge_issues "$db" "$where"; then
            db_purged=$((db_purged + count))
        else
            echo "    WARNING: failed to purge category $cat from $db"
        fi
    done

    if [ "$has_work" = true ]; then
        # Commit all purges for this db in one commit
        cats_list=$(printf "%s," "${CATS_TO_PURGE[@]}")
        cats_list="${cats_list%,}"
        cd "$DOLT_DATA" && dolt sql -q "
            USE $db;
            CALL DOLT_ADD('.');
            CALL DOLT_COMMIT('--allow-empty', '-m', 'chore: audit-cruft purge (categories: $cats_list)');
        " 2>/dev/null || true
        remaining=$(cd "$DOLT_DATA" && dolt sql -q "USE $db; SELECT COUNT(*) FROM issues;" 2>/dev/null | grep -oP '\d+' | tail -1)
        echo "  $db: purged $db_purged, $remaining remaining"
    fi
done

echo ""
echo "=== Purge complete ==="
