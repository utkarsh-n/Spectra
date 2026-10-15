#!/bin/zsh
# Spin engine gate: compiles Spectra/Spin with swiftc on macOS and runs every oracle of
# SpectraTests/SpinTests.swift (gyre-integration.md §10 with the review's corrections, Gyre's
# eight physcheck cases, and the worked values of §4.1, §4.8, §4.10, §5). No Xcode project, no
# simulator; takes about half a minute.
#
#   Tools/check-spin.sh                 all steps
#   Tools/check-spin.sh <substring>     run only oracle groups whose name contains it
#
# Steps (any failure exits non-zero):
#   1. typecheck Spin as the app compiles it: Swift 6, default MainActor isolation,
#      approachable-concurrency features, warnings as errors;
#   2. typecheck Spin against the iOS 27 SDK (arm64-apple-ios27.0);
#   3. typecheck SpinTests.swift as the test target sees it: Spin built as module `Spectra`
#      (-enable-testing, MainActor default) and `@testable import`ed next to XCTest, for macOS
#      and for the iOS 27 SDK;
#   4. build the harness (Spin + SpinTests.swift -D SPECTRA_HARNESS + Tools/harness/spin/main.swift,
#      default nonisolated isolation, Swift 6, -O) and run every oracle.
#
# Everything is copied to and built in ${SPECTRA_SPIN_BUILD:-$TMPDIR/SpectraSpinCheck}, never
# in the iCloud project folder.
set -e -o pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${SPECTRA_SPIN_BUILD:-${TMPDIR:-/tmp}/SpectraSpinCheck}"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode-beta.app/Contents/Developer}"
IOS_SDK="$DEVELOPER_DIR/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS27.0.sdk"
MAC_FRAMEWORKS="$DEVELOPER_DIR/Platforms/MacOSX.platform/Developer/Library/Frameworks"
MAC_XCTEST_OVERLAY="$DEVELOPER_DIR/Platforms/MacOSX.platform/Developer/usr/lib"
IOS_FRAMEWORKS="$DEVELOPER_DIR/Platforms/iPhoneOS.platform/Developer/Library/Frameworks"
IOS_XCTEST_OVERLAY="$DEVELOPER_DIR/Platforms/iPhoneOS.platform/Developer/usr/lib"

mkdir -p "$WORK/src"
rsync -a --delete --exclude '.DS_Store' --exclude '*.md' "$ROOT/Spectra/Spin/" "$WORK/src/Spin/"
mkdir -p "$WORK/src/Tests" "$WORK/src/Harness" "$WORK/module" "$WORK/module-ios"
cp "$ROOT/SpectraTests/SpinTests.swift" "$WORK/src/Tests/"
cp "$ROOT/Tools/harness/spin/main.swift" "$WORK/src/Harness/"

cd "$WORK/src"
spin=("${(@f)$(find Spin -name '*.swift' | LC_ALL=C sort)}")
print "spin-engine: ${#spin} Spin files ($(cat $spin | wc -l | tr -d ' ') lines), SpinTests.swift ($(wc -l < Tests/SpinTests.swift | tr -d ' ') lines)"

approachable=(-enable-upcoming-feature NonisolatedNonsendingByDefault -enable-upcoming-feature InferIsolatedConformances)
app_flags=(-swift-version 6 -default-isolation MainActor -parse-as-library -warnings-as-errors $approachable)

print "1/4 typecheck Spin (macOS, Swift 6, default MainActor isolation)"
xcrun swiftc -typecheck "${app_flags[@]}" $spin

print "2/4 typecheck Spin (iOS 27 SDK, arm64-apple-ios27.0)"
if [[ -d "$IOS_SDK" ]]; then
  xcrun swiftc -typecheck "${app_flags[@]}" -sdk "$IOS_SDK" -target arm64-apple-ios27.0 $spin
else
  print "    skipped: $IOS_SDK not found"
fi

print "3/4 typecheck SpinTests.swift against Spin as module Spectra (@testable, XCTest; macOS and iOS 27)"
test_flags=(-typecheck -swift-version 6 -parse-as-library -warnings-as-errors $approachable)
xcrun swiftc -emit-module -module-name Spectra -enable-testing "${app_flags[@]}" $spin \
  -emit-module-path "$WORK/module/Spectra.swiftmodule"
xcrun swiftc "${test_flags[@]}" -I "$WORK/module" -I "$MAC_XCTEST_OVERLAY" -F "$MAC_FRAMEWORKS" Tests/SpinTests.swift
if [[ -d "$IOS_SDK" ]]; then
  ios=(-sdk "$IOS_SDK" -target arm64-apple-ios27.0)
  xcrun swiftc -emit-module -module-name Spectra -enable-testing "${app_flags[@]}" $ios $spin \
    -emit-module-path "$WORK/module-ios/Spectra.swiftmodule"
  xcrun swiftc "${test_flags[@]}" $ios -I "$WORK/module-ios" -I "$IOS_XCTEST_OVERLAY" -F "$IOS_FRAMEWORKS" Tests/SpinTests.swift
fi

print "4/4 build harness (default nonisolated isolation, -O) and run the oracles"
xcrun swiftc -O -swift-version 6 -warnings-as-errors -D SPECTRA_HARNESS $spin Tests/SpinTests.swift Harness/main.swift \
  -o "$WORK/spin-check"
print ""
"$WORK/spin-check" "$@"
print ""
print "check-spin: OK"
