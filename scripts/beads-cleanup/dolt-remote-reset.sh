#!/usr/bin/env bash
# Rebuild Dolt remotes from the current (shallow) local state.
# Replaces remote storage with a fresh push, discarding remote history.
#
# Works with both local file remotes and network remotes (GitHub, DoltHub).
# - File remotes: old directory replaced with fresh one
# - Network remotes: force-push overwrites remote history
#
# IMPORTANT: Requires the Dolt server to be stopped. The caller is
# responsible for stopping/starting the server.
#
# Usage:
#   dolt-remote-reset.sh              # all databases
#   dolt-remote-reset.sh hq dypt      # specific databases only

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

echo "=== Remote Reset ==="
echo ""

failed=0
for db in "${DBS[@]}"; do
    db_dir="$DOLT_DATA/$db"
    remote_url=$(cd "$db_dir" && dolt remote -v 2>/dev/null | awk '/origin/ {print $2}')

    if [ -z "$remote_url" ]; then
        echo "  $db: SKIPPED (no origin remote configured)"
        continue
    fi

    echo "--- Resetting remote for $db ---"
    echo "  Remote: $remote_url"

    if [[ "$remote_url" == file://* ]]; then
        # Local file remote: replace the directory
        remote_path="${remote_url#file://}"

        if [ ! -d "$remote_path" ]; then
            echo "  $db: SKIPPED (remote path does not exist: $remote_path)"
            continue
        fi

        old_size=$(du -sh "$remote_path/" 2>/dev/null | cut -f1)

        # Backup, recreate, push
        mv "$remote_path" "${remote_path}.bak"
        mkdir -p "$remote_path"

        # Initialize as a bare dolt remote directory
        # (dolt push will populate it)
        if (cd "$db_dir" && dolt push origin main 2>&1); then
            new_size=$(du -sh "$remote_path/" 2>/dev/null | cut -f1)
            echo "  $db: $old_size -> $new_size"
            rm -rf "${remote_path}.bak"
        else
            echo "  $db: FAILED (push failed, restoring backup)"
            rm -rf "$remote_path"
            mv "${remote_path}.bak" "$remote_path"
            failed=$((failed + 1))
        fi

    else
        # Network remote (GitHub, DoltHub, etc.): force-push
        echo "  Force-pushing to overwrite remote history..."
        if (cd "$db_dir" && dolt push --force origin main 2>&1); then
            echo "  $db: force-push complete"
        else
            echo "  $db: FAILED (force-push failed)"
            failed=$((failed + 1))
        fi
    fi

    echo ""
done

echo "=== Remote sizes ==="
for db in "${DBS[@]}"; do
    remote_url=$(cd "$DOLT_DATA/$db" && dolt remote -v 2>/dev/null | awk '/origin/ {print $2}')
    if [[ "$remote_url" == file://* ]]; then
        remote_path="${remote_url#file://}"
        size=$(du -sh "$remote_path/" 2>/dev/null | cut -f1)
        echo "  $db: $size"
    else
        echo "  $db: $remote_url (network remote, size not measurable locally)"
    fi
done

if [ $failed -gt 0 ]; then
    echo ""
    echo "WARNING: $failed database(s) had errors"
    exit 1
fi

echo ""
echo "Remote reset complete."
