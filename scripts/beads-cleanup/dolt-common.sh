#!/usr/bin/env bash
# Shared helpers for Dolt maintenance scripts.
# Source this file, don't execute it directly.
#
# Environment variables:
#   DOLT_DATA       Path to the Dolt data directory (default: auto-detect from gt root)
#   DOLT_REMOTES    Path to the Dolt remotes directory (default: $DOLT_DATA/../dolt-remotes)

# Auto-detect DOLT_DATA: walk up from this script's directory looking for .dolt-data
if [ -z "${DOLT_DATA:-}" ]; then
    _dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    while [ "$_dir" != "/" ]; do
        if [ -d "$_dir/.dolt-data" ]; then
            DOLT_DATA="$_dir/.dolt-data"
            break
        fi
        _dir="$(dirname "$_dir")"
    done
    unset _dir

    if [ -z "${DOLT_DATA:-}" ]; then
        echo "ERROR: Could not find .dolt-data directory. Set DOLT_DATA environment variable."
        exit 1
    fi
fi

# Auto-detect DOLT_REMOTES relative to DOLT_DATA
if [ -z "${DOLT_REMOTES:-}" ]; then
    DOLT_REMOTES="$(dirname "$DOLT_DATA")/dolt-remotes"
fi

# Print help text extracted from the script's header comments.
# Usage: show_help "$0" (call from the sourcing script)
show_help() {
    local script="$1"
    # Print comment block at top of file (lines starting with #, skip shebang)
    sed -n '2,/^[^#]/{ /^#/s/^# \{0,1\}//p; }' "$script"
}

# Discover all Dolt databases, excluding system schemas.
discover_databases() {
    local dbs=()
    while IFS= read -r line; do
        local db
        db=$(echo "$line" | sed 's/|//g' | tr -d ' ')
        [ -z "$db" ] && continue
        [[ "$db" == "Database" ]] && continue
        [[ "$db" == "information_schema" ]] && continue
        [[ "$db" == "mysql" ]] && continue
        [[ "$db" == "---"* ]] && continue
        [[ "$db" == "+"* ]] && continue
        dbs+=("$db")
    done < <(cd "$DOLT_DATA" && dolt sql -q "SHOW DATABASES;" 2>/dev/null)
    echo "${dbs[@]}"
}

# Parse arguments: supports space-separated and comma-separated database names.
# Sets the DBS global array.
# Usage: parse_db_args "$@"
parse_db_args() {
    DBS=()
    for arg in "$@"; do
        IFS=',' read -ra parts <<< "$arg"
        DBS+=("${parts[@]}")
    done

    if [ ${#DBS[@]} -eq 0 ]; then
        read -ra DBS <<< "$(discover_databases)"
    fi

    if [ ${#DBS[@]} -eq 0 ]; then
        echo "No databases found in $DOLT_DATA"
        exit 1
    fi
}
