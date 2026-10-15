#!/bin/zsh
# RF engine gate: compiles Spectra/RF with swiftc on macOS and runs every oracle of
# SpectraTests/RFTests.swift (the verified reference's worked values plus simulator round trips),
# then times the 4096-sample Fourier pipeline. No Xcode project, no simulator; under a minute.
#
#   Tools/check-rf.sh            all steps
#   Tools/check-rf.sh -v         also list passing checks
#   Tools/check-rf.sh dsp link   run only these oracle groups (step 6)
#
# Steps (any failure exits non-zero):
#   1. imports: RF may import only Foundation, Accelerate and simd;
#   2. typecheck RF as the app compiles it (Swift 6, default MainActor isolation, approachable
#      concurrency, warnings as errors) plus Tools/harness/rf/IsolationProbe.swift, which calls the
#      API from nonisolated code and detached tasks;
#   3. compile the same objects (-c -wmo) so SIL diagnostics such as definite initialization run;
#   4. typecheck against the iOS 27 SDK (arm64-apple-ios27.0);
#   5. build RF as a testable module named Spectra (app isolation mode) and typecheck
#      SpectraTests/RFTests.swift against it with XCTest, as the SpectraTests target compiles it;
#   6. build the harness (RF + SpectraTests/RFTests.swift + Tools/harness/rf/main.swift, default
#      nonisolated isolation, -O) and run it.
#
# Everything is copied to and built in ${SPECTRA_RF_BUILD:-$TMPDIR/SpectraRFCheck}, never in the
# iCloud project folder.
set -e -o pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${SPECTRA_RF_BUILD:-${TMPDIR:-/tmp}/SpectraRFCheck}"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode-beta.app/Contents/Developer}"
IOS_SDK="$DEVELOPER_DIR/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS27.0.sdk"

rm -rf "$WORK/src"
mkdir -p "$WORK/src/Tests" "$WORK/src/Harness"
rsync -a --delete --exclude '.DS_Store' --exclude '*.md' "$ROOT/Spectra/RF/" "$WORK/src/RF/"
cp "$ROOT/SpectraTests/RFTests.swift" "$WORK/src/Tests/"
cp "$ROOT/Tools/harness/rf/main.swift" "$ROOT/Tools/harness/rf/IsolationProbe.swift" "$WORK/src/Harness/"

cd "$WORK/src"
rf=("${(@f)$(find RF -name '*.swift' | LC_ALL=C sort)}")
print "rf-engine: ${#rf} RF files ($(cat $rf | wc -l | tr -d ' ') lines), RFTests.swift $(wc -l < Tests/RFTests.swift | tr -d ' ') lines"

print "1/6 imports (Foundation, Accelerate, simd only)"
bad=$(grep -hE '^[[:space:]]*(@preconcurrency[[:space:]]+)?import ' $rf | sed -E 's/^[[:space:]]*(@preconcurrency[[:space:]]+)?import[[:space:]]+//' | sort -u | grep -vxE 'Foundation|Accelerate|simd' || true)
if [[ -n "$bad" ]]; then
  print -u2 "    forbidden imports: $bad"
  exit 1
fi

app_flags=(-swift-version 6 -default-isolation MainActor -parse-as-library -warnings-as-errors
  -enable-upcoming-feature NonisolatedNonsendingByDefault -enable-upcoming-feature InferIsolatedConformances)

print "2/6 typecheck (macOS, Swift 6, default MainActor isolation, isolation probe)"
xcrun swiftc -typecheck "${app_flags[@]}" $rf Harness/IsolationProbe.swift

print "3/6 compile objects in the app's isolation mode (SIL diagnostics)"
xcrun swiftc -c -wmo -O "${app_flags[@]}" -module-name SpectraRFProbe $rf Harness/IsolationProbe.swift -o "$WORK/rf-mainactor.o"

print "4/6 typecheck (iOS 27 SDK, arm64-apple-ios27.0)"
if [[ -d "$IOS_SDK" ]]; then
  xcrun swiftc -typecheck "${app_flags[@]}" -sdk "$IOS_SDK" -target arm64-apple-ios27.0 $rf Harness/IsolationProbe.swift
else
  print "    skipped: $IOS_SDK not found"
fi

print "5/6 XCTest view: RFTests.swift against a testable module 'Spectra' built from RF"
MACOS_PLATFORM="$(xcrun --show-sdk-platform-path)"
mkdir -p "$WORK/module"
xcrun swiftc -emit-module -enable-testing "${app_flags[@]}" -module-name Spectra $rf -emit-module-path "$WORK/module/Spectra.swiftmodule"
xcrun swiftc -typecheck -swift-version 6 -warnings-as-errors -enable-upcoming-feature NonisolatedNonsendingByDefault \
  -enable-upcoming-feature InferIsolatedConformances -I "$WORK/module" -F "$MACOS_PLATFORM/Developer/Library/Frameworks" \
  -I "$MACOS_PLATFORM/Developer/usr/lib" Tests/RFTests.swift

print "6/6 build harness (default nonisolated isolation, -O) and run the oracles"
xcrun swiftc -O -swift-version 6 -warnings-as-errors -D SPECTRA_HARNESS $rf Tests/RFTests.swift Harness/main.swift -o "$WORK/rf-oracles"
print ""
"$WORK/rf-oracles" "$@"
print ""
print "check-rf: OK"
