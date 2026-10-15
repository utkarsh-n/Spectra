#!/bin/zsh
# Core parity gate: compiles Spectra/Core with swiftc on macOS and runs every parity category
# of SpectraTests/Fixtures/vectors.json (spectra-lab's 11,746 cases), printing per-category
# max error and PASS/FAIL. No Xcode project, no simulator; about half a minute.
#
#   Tools/check-core.sh          all steps
#   Tools/check-core.sh -v       also print the first messages of passing categories
#
# Steps (any failure exits non-zero):
#   0. no Core file shares its basename with another file of the app target (Swift forbids it);
#   1. typecheck Core as the app compiles it: Swift 6, default MainActor isolation,
#      approachable-concurrency features, warnings as errors;
#   2. typecheck Core against the iOS 27 SDK (arm64-apple-ios27.0);
#   3. build the harness (Core + SpectraTests/ParityVectors.swift + Tools/harness/core/main.swift,
#      default nonisolated isolation, -O) and run it against the fixture;
#   4. XCTest: build Core as module `Spectra` (-enable-testing, default MainActor isolation) and
#      SpectraTests/{ParityVectors,CoreParityTests}.swift as an .xctest bundle with
#      `@testable import Spectra` and Fixtures/vectors.json as a resource, then run it with
#      `xcrun xctest` (the same tests the iOS test target runs, on macOS); it must execute every
#      `func test…` of CoreParityTests.swift with 0 failures (no vacuous pass);
#   5. staleness: the fixture must equal spectra-lab/tests/parity/vectors.json, that file must
#      be current with spectra-lab's sources (`generate.mjs --check`, read-only) and the generated
#      tables must match `node Tools/gen-tables.mjs --check` (skipped when spectra-lab or node
#      is missing).
#
# Everything is copied to and built in ${SPECTRA_CORE_BUILD:-$TMPDIR/SpectraCoreCheck}, never
# in the iCloud project folder.
set -e -o pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${SPECTRA_CORE_BUILD:-${TMPDIR:-/tmp}/SpectraCoreCheck}"
LAB="${SPECTRA_LAB:-$ROOT/../spectra-lab}"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode-beta.app/Contents/Developer}"
IOS_SDK="$DEVELOPER_DIR/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS27.0.sdk"

mkdir -p "$WORK/src"
rsync -a --delete --exclude '.DS_Store' --exclude '*.md' "$ROOT/Spectra/Core/" "$WORK/src/Core/"
mkdir -p "$WORK/src/Tests" "$WORK/src/Harness"
cp "$ROOT/SpectraTests/ParityVectors.swift" "$WORK/src/Tests/"
cp "$ROOT/SpectraTests/Fixtures/vectors.json" "$WORK/src/Tests/"
cp "$ROOT/Tools/harness/core/main.swift" "$WORK/src/Harness/"

cd "$WORK/src"
core=("${(@f)$(find Core -name '*.swift' | LC_ALL=C sort)}")
print "core-port: ${#core} Core files ($(cat $core | wc -l | tr -d ' ') lines)"

app_flags=(-swift-version 6 -default-isolation MainActor -parse-as-library -warnings-as-errors
  -enable-upcoming-feature NonisolatedNonsendingByDefault -enable-upcoming-feature InferIsolatedConformances)

# Swift refuses two files with the same basename in one module, so a Core file must not share
# its name with any other file of the app target (e.g. RF/DSP/Spectrum.swift).
dupes=("${(@f)$(find "$ROOT/Spectra" -name '*.swift' -exec basename {} \; | LC_ALL=C sort | uniq -d)}")
clash=0
for d in $dupes; do
  [[ -z "$d" ]] && continue
  if [[ -n "$(find "$ROOT/Spectra/Core" -name "$d")" ]]; then
    print -u2 "    file name clash: $d is used by Core and elsewhere in the app target"
    clash=1
  else
    print "    note: $d is used twice outside Core (not core-port's file)"
  fi
done
(( clash )) && exit 1

print "1/5 typecheck (macOS, Swift 6, default MainActor isolation)"
xcrun swiftc -typecheck "${app_flags[@]}" $core

print "2/5 typecheck (iOS 27 SDK, arm64-apple-ios27.0)"
if [[ -d "$IOS_SDK" ]]; then
  xcrun swiftc -typecheck "${app_flags[@]}" -sdk "$IOS_SDK" -target arm64-apple-ios27.0 $core
else
  print "    skipped: $IOS_SDK not found"
fi

print "3/5 build harness (default nonisolated isolation, -O) and run parity"
xcrun swiftc -O -swift-version 6 -warnings-as-errors -D SPECTRA_HARNESS $core Tests/ParityVectors.swift Harness/main.swift \
  -o "$WORK/core-parity"
print ""
"$WORK/core-parity" "$WORK/src/Tests/vectors.json" "$@"
print ""

print "4/5 XCTest bundle (@testable import Spectra) under xcrun xctest"
MAC_DEV="$DEVELOPER_DIR/Platforms/MacOSX.platform/Developer"
if [[ -d "$MAC_DEV/Library/Frameworks/XCTest.framework" ]]; then
  XT="$WORK/xctest"
  rm -rf "$XT" && mkdir -p "$XT/SpectraTests.xctest/Contents/MacOS" "$XT/SpectraTests.xctest/Contents/Resources"
  cp "$ROOT/SpectraTests/CoreParityTests.swift" "$WORK/src/Tests/"
  xcrun swiftc -emit-library -emit-module -module-name Spectra -enable-testing -Onone "${app_flags[@]}" $core \
    -o "$XT/libSpectra.dylib" -Xlinker -install_name -Xlinker @rpath/libSpectra.dylib
  xcrun swiftc -emit-library -module-name SpectraTests -swift-version 6 -parse-as-library -warnings-as-errors \
    -enable-upcoming-feature NonisolatedNonsendingByDefault -enable-upcoming-feature InferIsolatedConformances \
    -I "$XT" -L "$XT" -lSpectra -F "$MAC_DEV/Library/Frameworks" -I "$MAC_DEV/usr/lib" -L "$MAC_DEV/usr/lib" \
    -framework XCTest -Xlinker -rpath -Xlinker "$MAC_DEV/Library/Frameworks" -Xlinker -rpath -Xlinker "$MAC_DEV/usr/lib" \
    -Xlinker -rpath -Xlinker "$XT" Tests/ParityVectors.swift Tests/CoreParityTests.swift \
    -o "$XT/SpectraTests.xctest/Contents/MacOS/SpectraTests"
  cp "$ROOT/SpectraTests/Fixtures/vectors.json" "$XT/SpectraTests.xctest/Contents/Resources/"
  cat > "$XT/SpectraTests.xctest/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>SpectraTests</string>
<key>CFBundleIdentifier</key><string>com.utkarsh.spectra.tests</string>
<key>CFBundlePackageType</key><string>BNDL</string>
<key>CFBundleName</key><string>SpectraTests</string>
</dict></plist>
PLIST
  # A bundle that loads but runs nothing also exits 0, so the run must execute every test
  # method of CoreParityTests (counted from the source) with 0 failures.
  expected=$(grep -cE '^[[:space:]]*func test[A-Za-z0-9_]*\(' "$ROOT/SpectraTests/CoreParityTests.swift")
  if xcrun xctest "$XT/SpectraTests.xctest" > "$XT/xctest.log" 2>&1; then
    summary=$(grep -E "Executed [0-9]+ tests?, with [0-9]+ failures?" "$XT/xctest.log" | tail -1)
    print "    $(print -r -- "$summary" | sed -E 's/^[[:space:]]+//')"
    ran=$(print -r -- "$summary" | sed -E 's/.*Executed ([0-9]+) tests?.*/\1/')
    failed=$(print -r -- "$summary" | sed -E 's/.*with ([0-9]+) failures?.*/\1/')
    if [[ -z "$summary" || "$ran" != "$expected" || "$failed" != "0" ]]; then
      print -u2 "    XCTest ran ${ran:-0} of $expected CoreParityTests methods with ${failed:-?} failures (log: $XT/xctest.log)"
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
print ""

print "5/5 staleness"
if [[ -f "$LAB/tests/parity/vectors.json" ]]; then
  if cmp -s "$LAB/tests/parity/vectors.json" "$ROOT/SpectraTests/Fixtures/vectors.json"; then
    print "    fixture matches spectra-lab/tests/parity/vectors.json"
  else
    print -u2 "    STALE: SpectraTests/Fixtures/vectors.json differs from $LAB/tests/parity/vectors.json (copy it over)"
    exit 1
  fi
  if command -v node > /dev/null; then
    # The lab copy must itself be current with spectra-lab's sources (read-only --check).
    node "$LAB/tests/parity/generate.mjs" --check | sed 's/^/    spectra-lab: /'
    (cd "$ROOT" && SPECTRA_LAB="$LAB" node Tools/gen-tables.mjs --check | sed 's/^/    /')
  else
    print "    node not found: generated-table check skipped"
  fi
else
  print "    spectra-lab not found at $LAB: skipped"
fi
print "check-core: OK"
