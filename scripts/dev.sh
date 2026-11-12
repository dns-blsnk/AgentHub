#!/bin/zsh
# Live loop: rebuilds and relaunches AgentHub whenever a file in Sources/ or Package.swift changes.
# A failed build keeps the previous app running and prints the errors. Ctrl+C to stop.
set -uo pipefail

cd "$(dirname "$0")/.."

latest_change() {
    find Sources Package.swift -type f \( -name '*.swift' -o -name 'Package.swift' \) -exec stat -f %m {} + | sort -n | tail -1
}

relaunch() {
    echo "\n[dev] $(date +%H:%M:%S) building…"
    if ./scripts/build-app.sh --debug 2>&1 | grep -E 'error:|warning:|Compiling|Build complete' ; [[ ${pipestatus[1]} -eq 0 ]]; then
        pkill -x AgentHub 2>/dev/null && sleep 0.3
        open build/AgentHub.app
        echo "[dev] $(date +%H:%M:%S) relaunched"
    else
        echo "[dev] $(date +%H:%M:%S) build failed, previous version keeps running"
    fi
}

relaunch
last=$(latest_change)
while true; do
    sleep 1
    now=$(latest_change)
    if [[ "$now" != "$last" ]]; then
        sleep 0.4  # let a burst of saves settle
        last=$(latest_change)
        relaunch
    fi
done
