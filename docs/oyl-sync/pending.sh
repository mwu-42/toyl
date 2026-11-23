#!/bin/bash
# The toyl changes Oyl hasn't taken in yet: the entries in ~/toyl/docs/oyl-changes.md numbered after the one
# in ~/Oyl/.toyl-sync. Prints nothing when Oyl's up to date (or toyl isn't there).
#   pending.sh            the entries
#   pending.sh --latest   just the latest entry's number
changes="${TOYL_REPO:-$HOME/toyl}/docs/oyl-changes.md"
synced_file="${OYL_REPO:-$HOME/Oyl}/.toyl-sync"
[[ -f "$changes" ]] || exit 0
if [[ "${1:-}" == "--latest" ]]; then
    awk '/^## [0-9]+ · / { n = $2 } END { print n + 0 }' "$changes"
    exit 0
fi
synced=$([[ -f "$synced_file" ]] && tr -dc '0-9' < "$synced_file")
awk -v since="${synced:-0}" '/^## [0-9]+ · / { show = ($2 + 0 > since) } show { print }' "$changes"
