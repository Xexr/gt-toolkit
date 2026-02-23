#!/usr/bin/env bash
# Squash local Dolt databases to a single commit, discarding all history.
# Preserves all current data, remote configuration, and wisp table schemas.
# Compatible with any remote type (file://, GitHub, DoltHub).
#
# After squashing, recreates dolt_ignore entries and wisp table schemas
# so that the beads migration doesn't need to run again. Wisp data is
# intentionally not preserved (it's ephemeral).
#
# IMPORTANT: Requires the Dolt server to be stopped. The caller is
# responsible for stopping/starting the server (dolt-full-cleanup.sh
# handles this automatically).
#
# Usage:
#   dolt-shallow-reset.sh              # all databases
#   dolt-shallow-reset.sh hq dypt      # specific databases only

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/dolt-common.sh"
[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && { show_help "$0"; exit 0; }
parse_db_args "$@"

# Safety check: server must be stopped
if pgrep -af "dolt sql-server" | grep -q "$DOLT_DATA"; then
    echo "ERROR: Dolt SQL server is running on .dolt-data."
    echo "Stop the server first: gt dolt stop"
    exit 1
fi

# SQL to recreate dolt_ignore entries and wisp table schemas.
# Order matters: dolt_ignore patterns must be committed BEFORE creating
# the wisp tables, otherwise the tables get tracked in Dolt history.
read -r -d '' WISP_SETUP_SQL <<'ENDSQL' || true
-- Step 1: Add dolt_ignore patterns
REPLACE INTO dolt_ignore VALUES ('wisps', true);
REPLACE INTO dolt_ignore VALUES ('wisp_%', true);
CALL DOLT_ADD('dolt_ignore');
CALL DOLT_COMMIT('--allow-empty', '-m', 'chore: add wisp patterns to dolt_ignore');

-- Step 2: Create wisp tables (now ignored by Dolt)
CREATE TABLE IF NOT EXISTS `wisps` (
  `id` varchar(255) NOT NULL,
  `content_hash` varchar(64),
  `title` varchar(500) NOT NULL,
  `description` text NOT NULL,
  `design` text NOT NULL,
  `acceptance_criteria` text NOT NULL,
  `notes` text NOT NULL,
  `status` varchar(32) NOT NULL DEFAULT 'open',
  `priority` int NOT NULL DEFAULT '2',
  `issue_type` varchar(32) NOT NULL DEFAULT 'task',
  `assignee` varchar(255),
  `estimated_minutes` int,
  `created_at` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP,
  `created_by` varchar(255) DEFAULT '',
  `owner` varchar(255) DEFAULT '',
  `updated_at` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  `closed_at` datetime,
  `closed_by_session` varchar(255) DEFAULT '',
  `external_ref` varchar(255),
  `spec_id` varchar(1024),
  `compaction_level` int DEFAULT '0',
  `compacted_at` datetime,
  `compacted_at_commit` varchar(64),
  `original_size` int,
  `sender` varchar(255) DEFAULT '',
  `ephemeral` tinyint(1) DEFAULT '0',
  `wisp_type` varchar(32) DEFAULT '',
  `pinned` tinyint(1) DEFAULT '0',
  `is_template` tinyint(1) DEFAULT '0',
  `crystallizes` tinyint(1) DEFAULT '0',
  `mol_type` varchar(32) DEFAULT '',
  `work_type` varchar(32) DEFAULT 'mutex',
  `quality_score` double,
  `source_system` varchar(255) DEFAULT '',
  `metadata` json DEFAULT (json_object()),
  `source_repo` varchar(512) DEFAULT '',
  `close_reason` text DEFAULT (''),
  `event_kind` varchar(32) DEFAULT '',
  `actor` varchar(255) DEFAULT '',
  `target` varchar(255) DEFAULT '',
  `payload` text DEFAULT (''),
  `await_type` varchar(32) DEFAULT '',
  `await_id` varchar(255) DEFAULT '',
  `timeout_ns` bigint DEFAULT '0',
  `waiters` text DEFAULT (''),
  `hook_bead` varchar(255) DEFAULT '',
  `role_bead` varchar(255) DEFAULT '',
  `agent_state` varchar(32) DEFAULT '',
  `last_activity` datetime,
  `role_type` varchar(32) DEFAULT '',
  `rig` varchar(255) DEFAULT '',
  `due_at` datetime,
  `defer_until` datetime,
  PRIMARY KEY (`id`),
  KEY `idx_wisps_assignee` (`assignee`),
  KEY `idx_wisps_created_at` (`created_at`),
  KEY `idx_wisps_external_ref` (`external_ref`),
  KEY `idx_wisps_issue_type` (`issue_type`),
  KEY `idx_wisps_priority` (`priority`),
  KEY `idx_wisps_spec_id` (`spec_id`),
  KEY `idx_wisps_status` (`status`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_bin;

CREATE TABLE IF NOT EXISTS `wisp_labels` (
  `issue_id` varchar(255) NOT NULL,
  `label` varchar(255) NOT NULL,
  PRIMARY KEY (`issue_id`,`label`),
  KEY `idx_wisp_labels_label` (`label`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_bin;

CREATE TABLE IF NOT EXISTS `wisp_dependencies` (
  `issue_id` varchar(255) NOT NULL,
  `depends_on_id` varchar(255) NOT NULL,
  `type` varchar(32) NOT NULL DEFAULT 'blocks',
  `created_at` datetime DEFAULT CURRENT_TIMESTAMP,
  `created_by` varchar(255) DEFAULT '',
  `metadata` json DEFAULT (json_object()),
  `thread_id` varchar(255) DEFAULT '',
  PRIMARY KEY (`issue_id`,`depends_on_id`),
  KEY `idx_wisp_dep_depends` (`depends_on_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_bin;

CREATE TABLE IF NOT EXISTS `wisp_events` (
  `id` bigint NOT NULL AUTO_INCREMENT,
  `issue_id` varchar(255) NOT NULL,
  `event_type` varchar(32) NOT NULL,
  `actor` varchar(255) DEFAULT '',
  `old_value` text DEFAULT (''),
  `new_value` text DEFAULT (''),
  `comment` text DEFAULT (''),
  `created_at` datetime DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (`id`),
  KEY `idx_wisp_events_issue` (`issue_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_bin;

CREATE TABLE IF NOT EXISTS `wisp_comments` (
  `id` bigint NOT NULL AUTO_INCREMENT,
  `issue_id` varchar(255) NOT NULL,
  `author` varchar(255) DEFAULT '',
  `text` text NOT NULL,
  `created_at` datetime DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (`id`),
  KEY `idx_wisp_comments_issue` (`issue_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_bin;
ENDSQL

echo "=== Squash Reset (Local) ==="
echo ""

# Pre-flight: show current sizes
echo "Before:"
for db in "${DBS[@]}"; do
    size=$(du -sh "$DOLT_DATA/$db/" 2>/dev/null | cut -f1)
    commits=$(cd "$DOLT_DATA/$db" && dolt log --oneline 2>/dev/null | wc -l || echo "?")
    echo "  $db: $size ($commits commits)"
done
echo ""

failed=0
for db in "${DBS[@]}"; do
    db_dir="$DOLT_DATA/$db"

    echo "--- Resetting $db ---"

    # Save ALL remote configs (not just origin)
    remotes=()
    while IFS= read -r line; do
        name=$(echo "$line" | awk '{print $1}')
        url=$(echo "$line" | awk '{print $2}')
        if [ -n "$name" ] && [ -n "$url" ]; then
            remotes+=("$name=$url")
        fi
    done < <(cd "$db_dir" && dolt remote -v 2>/dev/null || true)

    # Count issues before for verification
    before_count=$(cd "$db_dir" && dolt sql -q "SELECT COUNT(*) FROM issues;" 2>/dev/null | grep -oP '\d+' | tail -1)

    # Dump current data to SQL (no CREATE DATABASE wrapper)
    tmp_dir=$(mktemp -d)
    echo "  Dumping data..."
    if ! (cd "$db_dir" && dolt dump --no-create-db -f -fn "$tmp_dir/dump.sql" 2>&1); then
        echo "  $db: FAILED (dump failed)"
        rm -rf "$tmp_dir"
        failed=$((failed + 1))
        continue
    fi

    # Create fresh database, import data, single commit
    echo "  Rebuilding as single commit..."
    mkdir "$tmp_dir/fresh"
    if ! (cd "$tmp_dir/fresh" && dolt init >/dev/null 2>&1 \
        && dolt sql < "$tmp_dir/dump.sql" 2>&1 \
        && dolt add . \
        && dolt commit -m "squash: reset $db to single commit" >/dev/null 2>&1); then
        echo "  $db: FAILED (rebuild failed)"
        rm -rf "$tmp_dir"
        failed=$((failed + 1))
        continue
    fi

    # Verify data integrity
    after_count=$(cd "$tmp_dir/fresh" && dolt sql -q "SELECT COUNT(*) FROM issues;" 2>/dev/null | grep -oP '\d+' | tail -1)
    if [ "$before_count" != "$after_count" ]; then
        echo "  $db: FAILED (issue count mismatch: $before_count -> $after_count)"
        rm -rf "$tmp_dir"
        failed=$((failed + 1))
        continue
    fi

    # Recreate dolt_ignore + wisp table schemas
    echo "  Recreating wisp tables..."
    if ! (cd "$tmp_dir/fresh" && dolt sql <<< "$WISP_SETUP_SQL" >/dev/null 2>&1); then
        echo "  $db: WARNING (wisp table setup failed, migration will recreate on next bd command)"
    fi

    # Re-add ALL remotes to fresh database
    for remote_entry in "${remotes[@]}"; do
        rname="${remote_entry%%=*}"
        rurl="${remote_entry#*=}"
        (cd "$tmp_dir/fresh" && dolt remote add "$rname" "$rurl" 2>/dev/null) || true
    done

    # Swap: old -> backup, fresh -> live
    mv "$db_dir" "${db_dir}.bak"
    mv "$tmp_dir/fresh" "$db_dir"
    rm -rf "$tmp_dir"

    new_size=$(du -sh "$db_dir/" 2>/dev/null | cut -f1)
    old_size=$(du -sh "${db_dir}.bak/" 2>/dev/null | cut -f1)
    remote_count=${#remotes[@]}
    echo "  $db: $old_size -> $new_size ($before_count issues, $remote_count remotes preserved)"

    # Remove backup
    rm -rf "${db_dir}.bak"
    echo ""
done

echo "=== After Squash Reset ==="
for db in "${DBS[@]}"; do
    size=$(du -sh "$DOLT_DATA/$db/" 2>/dev/null | cut -f1)
    commits=$(cd "$DOLT_DATA/$db" && dolt log --oneline 2>/dev/null | wc -l || echo "?")
    echo "  $db: $size ($commits commits)"
done

if [ $failed -gt 0 ]; then
    echo ""
    echo "WARNING: $failed database(s) had errors"
    exit 1
fi

echo ""
echo "Squash reset complete. All databases have a single commit with wisp tables ready."
