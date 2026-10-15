#!/bin/zsh
# Phase-space engine gate: compiles Spectra/Phase (with Spectra/Core for the media and SI, and
# Spectra/RF for the array-factor oracle) with swiftc on macOS and runs every oracle of
# SpectraTests/PhaseTests.swift: M1/M2/P pointwise, reality, Hudson positivity, cross terms,
# chirp concentration, plane-wave signs (+k₀, +ν₀), the Moyal identity, Fresnel shear, aperture
# far field vs the RF array factor, closed-form Gaussian packets, dispersion shells and the
# timing budgets (Utkarsh's convention (C), Docs/research/wigner-spacetime.md).
# No Xcode project, no simulator.
#
#   Tools/check-phase.sh                 all steps
#   Tools/check-phase.sh <substring>     run only oracle groups whose name contains it (step 6)
#
# Steps (any failure exits non-zero):
#   0. no Phase file shares its basename with another file of the app target;
#   1. imports: Phase may import only Foundation, Accelerate and simd;
#   2. typecheck Phase (+ Core) as the app compiles it: Swift 6, default MainActor isolation,
#      approachable-concurrency features, warnings as errors, plus Tools/harness/phase/
#      IsolationProbe.swift (calls the API from nonisolated code and detached tasks), and compile
#      the objects (-c -wmo) so SIL diagnostics run;
#   3. typecheck against the iOS 27 SDK (arm64-apple-ios27.0);
#   4. XCTest: build Core + RF + Phase as module `Spectra` (-enable-testing, default MainActor
#      isolation, -Onone) and SpectraTests/PhaseTests.swift as an .xctest bundle with
#      `@testable import Spectra`; typecheck it for iOS 27 too; run it with `xcrun xctest`; it must
#      execute every `func test…` of PhaseTests.swift with 0 failures (no vacuous pass);
#   5. build the harness (Core + RF + Phase + PhaseTests.swift -D SPECTRA_HARNESS +
#      Tools/harness/phase/main.swift, default nonisolated isolation, -O) and run every oracle.
#
# Everything is copied to and built in ${SPECTRA_PHASE_BUILD:-$TMPDIR/SpectraPhaseCheck}, never
# in the iCloud project folder.
set -e -o pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${SPECTRA_PHASE_BUILD:-${TMPDIR:-/tmp}/SpectraPhaseCheck}"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode-beta.app/Contents/Developer}"
IOS_SDK="$DEVELOPER_DIR/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS27.0.sdk"
MAC_DEV="$DEVELOPER_DIR/Platforms/MacOSX.platform/Developer"
IOS_DEV="$DEVELOPER_DIR/Platforms/iPhoneOS.platform/Developer"

mkdir -p "$WORK/src/Tests" "$WORK/src/Harness"
for d in Phase Core RF; do
  rsync -a --delete --exclude '.DS_Store' --exclude '*.md' "$ROOT/Spectra/$d/" "$WORK/src/$d/"
done
cp "$ROOT/SpectraTests/PhaseTests.swift" "$WORK/src/Tests/"
cp "$ROOT/Tools/harness/phase/main.swift" "$ROOT/Tools/harness/phase/IsolationProbe.swift" "$WORK/src/Harness/"

cd "$WORK/src"
phase=("${(@f)$(find Phase -name '*.swift' | LC_ALL=C sort)}")
core=("${(@f)$(find Core -name '*.swift' | LC_ALL=C sort)}")
rf=("${(@f)$(find RF -name '*.swift' | LC_ALL=C sort)}")
print "phase-engine: ${#phase} Phase files ($(cat $phase | wc -l | tr -d ' ') lines), PhaseTests.swift $(wc -l < Tests/PhaseTests.swift | tr -d ' ') lines"

print "0/5 file names (no clash with the rest of the app target)"
for f in $phase; do
  b=$(basename "$f")
  n=$(find "$ROOT/Spectra" -name "$b" | wc -l | tr -d ' ')
  if [[ "$n" != "1" ]]; then
    print -u2 "    file name clash: $b appears $n times in Spectra/"
    exit 1
  fi
done

print "1/5 imports (Foundation, Accelerate, simd only)"
bad=$(grep -hE '^[[:space:]]*(@preconcurrency[[:space:]]+)?import ' $phase | sed -E 's/^[[:space:]]*(@preconcurrency[[:space:]]+)?import[[:space:]]+//' | sort -u | grep -vxE 'Foundation|Accelerate|simd' || true)
if [[ -n "$bad" ]]; then
  print -u2 "    forbidden imports: $bad"
  exit 1
fi

approachable=(-enable-upcoming-feature NonisolatedNonsendingByDefault -enable-upcoming-feature InferIsolatedConformances)
app_flags=(-swift-version 6 -default-isolation MainActor -parse-as-library -warnings-as-errors $approachable)

print "2/5 typecheck + compile in the app's isolation mode (Swift 6, default MainActor, isolation probe)"
xcrun swiftc -typecheck "${app_flags[@]}" $phase $core Harness/IsolationProbe.swift
xcrun swiftc -c -wmo -O "${app_flags[@]}" -module-name SpectraPhaseProbe $phase $core Harness/IsolationProbe.swift \
  -o "$WORK/phase-mainactor.o"

print "3/5 typecheck (iOS 27 SDK, arm64-apple-ios27.0)"
if [[ -d "$IOS_SDK" ]]; then
  xcrun swiftc -typecheck "${app_flags[@]}" -sdk "$IOS_SDK" -target arm64-apple-ios27.0 $phase $core Harness/IsolationProbe.swift
else
  print "    skipped: $IOS_SDK not found"
fi

print "4/5 XCTest bundle (@testable import Spectra) under xcrun xctest"
test_flags=(-swift-version 6 -parse-as-library -warnings-as-errors $approachable)
if [[ -d "$IOS_SDK" ]]; then
  mkdir -p "$WORK/module-ios"
  ios=(-sdk "$IOS_SDK" -target arm64-apple-ios27.0)
  xcrun swiftc -emit-module -module-name Spectra -enable-testing "${app_flags[@]}" $ios $phase $core $rf \
    -emit-module-path "$WORK/module-ios/Spectra.swiftmodule"
  xcrun swiftc -typecheck "${test_flags[@]}" $ios -I "$WORK/module-ios" -I "$IOS_DEV/usr/lib" -F "$IOS_DEV/Library/Frameworks" \
    Tests/PhaseTests.swift
  print "    PhaseTests.swift typechecks against the iOS 27 SDK"
fi
if [[ -d "$MAC_DEV/Library/Frameworks/XCTest.framework" ]]; then
  XT="$WORK/xctest"
  rm -rf "$XT" && mkdir -p "$XT/PhaseTests.xctest/Contents/MacOS"
  xcrun swiftc -emit-library -emit-module -module-name Spectra -enable-testing -Onone "${app_flags[@]}" $phase $core $rf \
    -o "$XT/libSpectra.dylib" -Xlinker -install_name -Xlinker @rpath/libSpectra.dylib
  xcrun swiftc -emit-library -module-name SpectraTests "${test_flags[@]}" \
    -I "$XT" -L "$XT" -lSpectra -F "$MAC_DEV/Library/Frameworks" -I "$MAC_DEV/usr/lib" -L "$MAC_DEV/usr/lib" \
    -framework XCTest -Xlinker -rpath -Xlinker "$MAC_DEV/Library/Frameworks" -Xlinker -rpath -Xlinker "$MAC_DEV/usr/lib" \
    -Xlinker -rpath -Xlinker "$XT" Tests/PhaseTests.swift \
    -o "$XT/PhaseTests.xctest/Contents/MacOS/PhaseTests"
  cat > "$XT/PhaseTests.xctest/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>PhaseTests</string>
<key>CFBundleIdentifier</key><string>com.utkarsh.spectra.phasetests</string>
<key>CFBundlePackageType</key><string>BNDL</string>
<key>CFBundleName</key><string>PhaseTests</string>
</dict></plist>
PLIST
  # A bundle that loads but runs nothing also exits 0, so the run must execute every test
  # method of PhaseTests (counted from the source) with 0 failures.
  expected=$(grep -cE '^[[:space:]]*func test[A-Za-z0-9_]*\(' "$ROOT/SpectraTests/PhaseTests.swift")
  if xcrun xctest "$XT/PhaseTests.xctest" > "$XT/xctest.log" 2>&1; then
    summary=$(grep -E "Executed [0-9]+ tests?, with [0-9]+ failures?" "$XT/xctest.log" | tail -1)
    print "    $(print -r -- "$summary" | sed -E 's/^[[:space:]]+//')"
    ran=$(print -r -- "$summary" | sed -E 's/.*Executed ([0-9]+) tests?.*/\1/')
    failed=$(print -r -- "$summary" | sed -E 's/.*with ([0-9]+) failures?.*/\1/')
    if [[ -z "$summary" || "$ran" != "$expected" || "$failed" != "0" ]]; then
      print -u2 "    XCTest ran ${ran:-0} of $expected PhaseTests methods with ${failed:-?} failures (log: $XT/xctest.log)"
      exit 1
    fi
  else
    grep -E "error|failed" "$XT/xctest.log" | head -20 | sed 's/^/    /'
    print -u2 "    XCTest FAILED (log: $XT/xctest.log)"
    exit 1
  fi
else
  print "    skipped: no macOS XCTest.framework under $MAC_DEV"
fi

print "5/5 build harness (default nonisolated isolation, -O) and run the oracles"
xcrun swiftc -O -swift-version 6 -warnings-as-errors -D SPECTRA_HARNESS $phase $core $rf Tests/PhaseTests.swift Harness/main.swift \
  -o "$WORK/phase-check"
print ""
"$WORK/phase-check" "$@"
print ""
print "check-phase: OK"
