#!/usr/bin/env bash
set -euo pipefail

# Run the KoeKit test suite.
#
# swift-testing (`import Testing`) ships in the toolchain but, on a machine with
# only the Command Line Tools installed (no full Xcode), SwiftPM does not wire up
# its framework/dylib search paths automatically. This script adds them when
# needed and otherwise defers to a plain `swift test` (e.g. on CI, which has full
# Xcode). See docs/decisions.md 2026-07-04.

FW=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
LIBDIR=/Library/Developer/CommandLineTools/Library/Developer/usr/lib

if [[ "$(xcode-select -p 2>/dev/null || true)" != *Xcode.app* ]] \
   && [[ -d "$FW" ]] && [[ -f "$LIBDIR/lib_TestingInterop.dylib" ]]; then
  exec env DYLD_LIBRARY_PATH="$LIBDIR" swift test \
    -Xswiftc -F -Xswiftc "$FW" \
    -Xlinker -F -Xlinker "$FW" \
    -Xlinker -rpath -Xlinker "$FW" \
    -Xlinker -rpath -Xlinker "$LIBDIR" "$@"
else
  exec swift test "$@"
fi
