#!/bin/bash
#
# Build and run the Whoopsy test suite. This supersedes `run_tests.sh`, which linked stale objects
# out of `.build` and omitted the `-fmodule-map-file` flag, so it died with `missing required module
# 'CSQLite'` before it ever reached a test.
#
#   ./scripts/test.sh              # all 15 sections
#   ./scripts/test.sh 13 15        # §13 and §15 only
#   ./scripts/test.sh 13,15        # same thing
#   make test SECTIONS=13,15       # same thing, via the Makefile
#
# The runner prints one machine-readable line at the end:
#
#   SUITE sections=1,...,15 assertions=941 failed=0 exit=0
#
# Read that line rather than the `✓` scrollback. This suite has no test discovery, so a section that
# stopped running looks exactly like one that passed — `sections=` is the field that catches it, and
# `assertions=` the field that catches a section that ran but stopped asserting.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
scratch="${WHOOPSY_SCRATCH:-/tmp/whoopsy-verify}"
runner="$scratch/WhoopsyTestRunner"

# **Absolute, and that is load-bearing.** `#filePath` in the runner is whatever path is handed to
# swiftc, and the suite's `whoopExportURL()` climbs three levels from it to find the bundled export.
# A relative path makes the "repo root" it computes depend on the caller's working directory, so
# §11, §13 and §15 each fail with a message that reads like a broken import. An absolute path removes
# that failure class outright, which is why the suite no longer has to be run from the repo root.
main_swift="$repo_root/Tests/WhoopsyTestRunner/main.swift"

module_map="$repo_root/.build/checkouts/GRDB.swift/Sources/CSQLite/module.modulemap"
if [ ! -f "$module_map" ]; then
    echo "Missing $module_map" >&2
    echo "Run 'swift build' once so SwiftPM checks GRDB out into .build/." >&2
    exit 1
fi

# Sections may arrive as arguments or as an environment variable; arguments win.
if [ "$#" -gt 0 ]; then
    WHOOPSY_SECTIONS="$(printf '%s' "$*" | tr ' ' ',')"
fi
export WHOOPSY_SECTIONS="${WHOOPSY_SECTIONS:-}"

echo "▸ Building WhoopsyCore into $scratch ..."
# A scratch path, not `.build`: the default build directory accumulates object files from
# since-deleted sources (`MainTabView`, `SettingsView`, `TodayDashboardView`, `SwiftData*Repository`,
# …) and the link then fails with `symbol(s) not found` for symbols nothing declares any more.
swift build --package-path "$repo_root" --scratch-path "$scratch"

# The platform triple is arm64-apple-macosx on Apple silicon and x86_64-apple-macosx on Intel. Read
# it rather than assuming, so this does not quietly become an Apple-silicon-only script.
triple_dir="$(cd "$scratch" && ls -d -- *-apple-macosx 2>/dev/null | head -1)"
if [ -z "$triple_dir" ]; then
    echo "No *-apple-macosx build directory under $scratch — did 'swift build' succeed?" >&2
    exit 1
fi

echo "▸ Linking the test runner ..."
swiftc \
    -I "$scratch/$triple_dir/debug/Modules" \
    -Xcc -fmodule-map-file="$module_map" \
    "$scratch/$triple_dir/debug/Whoopsy.build/"*.o \
    "$scratch/$triple_dir/debug/GRDB.build/"*.o \
    "$main_swift" \
    -o "$runner"

echo "▸ Running${WHOOPSY_SECTIONS:+ sections $WHOOPSY_SECTIONS} ..."
echo
cd "$repo_root"
exec "$runner"
