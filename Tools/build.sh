#!/bin/zsh
# Spectra's whole-project build. xcodebuild hangs when it loads a project from this
# iCloud-synced folder (and resource-fork detritus breaks codesign), so the project is
# mirrored to $TMPDIR, generated there with XcodeGen, and built there.
#
#   Tools/build.sh sim     Debug build for the iPhone 17 Pro simulator
#   Tools/build.sh test    unit tests (SpectraTests) on the simulator
#   Tools/build.sh uitest  UI tests (SpectraUITests) on the simulator
#   Tools/build.sh device  Release build for a connected iPhone (-allowProvisioningUpdates)
#
# Anything after the mode is passed to xcodebuild, e.g.
#   Tools/build.sh test -only-testing:SpectraTests/AppTests
#
# Environment:
#   SPECTRA_BUILD_DIR  mirror + derived data (default $TMPDIR/SpectraBuild)
#   SPECTRA_SIM        simulator name (default "iPhone 17 Pro")
#
# Exits non-zero on failure and prints the last 80 error lines. The full log is
# $SPECTRA_BUILD_DIR/<mode>.log; test result bundles land in $SPECTRA_BUILD_DIR/results.
set -e -o pipefail

SRC="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${SPECTRA_BUILD_DIR:-${TMPDIR:-/tmp}/SpectraBuild}"
SIM="${SPECTRA_SIM:-iPhone 17 Pro}"
MODE="${1:-sim}"
(( $# > 0 )) && shift

mkdir -p "$WORK/src" "$WORK/results"
rsync -a --delete \
  --exclude 'Docs/research/rf-physics-calc' \
  --exclude 'Docs/screenshots' \
  --exclude '*.xcodeproj/xcuserdata' \
  --exclude '/build' \
  --exclude '.DS_Store' \
  "$SRC/" "$WORK/src/"

cd "$WORK/src"
xcodegen generate --quiet

# XcodeGen writes Info.plist only inside the mirror; keep the source tree's copy current
# so opening the project directly never ships a plist without the usage strings.
if [[ -f Spectra/Info.plist ]] && ! cmp -s Spectra/Info.plist "$SRC/Spectra/Info.plist"; then
  cp Spectra/Info.plist "$SRC/Spectra/Info.plist"
fi

STAMP="$(date +%Y%m%d-%H%M%S)"
DEST="platform=iOS Simulator,name=$SIM"
common=(-project Spectra.xcodeproj -scheme Spectra -derivedDataPath "$WORK/dd")
case "$MODE" in
  sim)
    cmd=(xcodebuild "${common[@]}" -configuration Debug -destination "$DEST" build) ;;
  test)
    cmd=(xcodebuild "${common[@]}" -configuration Debug -destination "$DEST"
      -resultBundlePath "$WORK/results/test-$STAMP.xcresult" -only-testing:SpectraTests test) ;;
  uitest)
    cmd=(xcodebuild "${common[@]}" -configuration Debug -destination "$DEST"
      -resultBundlePath "$WORK/results/uitest-$STAMP.xcresult" -only-testing:SpectraUITests test) ;;
  device)
    cmd=(xcodebuild "${common[@]}" -configuration Release -destination 'generic/platform=iOS'
      -allowProvisioningUpdates build) ;;
  *)
    print -u2 "usage: Tools/build.sh sim|device|test|uitest [extra xcodebuild args]"
    exit 64 ;;
esac

LOG="$WORK/$MODE.log"
print "→ ${cmd[*]} $*"
print "  log: $LOG"
if "${cmd[@]}" "$@" > "$LOG" 2>&1; then rc=0; else rc=$?; fi

errors="$(grep -E "error:|warning: .*Spectra/|Test Case .* failed|\*\* (BUILD|TEST) FAILED" "$LOG" | sort -u | tail -80 || true)"
[[ -n "$errors" ]] && print -- "$errors"
grep -E "Executed [0-9]+ tests?|\*\* (BUILD|TEST) (SUCCEEDED|FAILED) \*\*" "$LOG" | tail -4 || true
if [[ "$MODE" == test || "$MODE" == uitest ]]; then
  print "  results: $(ls -dt "$WORK"/results/$MODE-*.xcresult 2>/dev/null | head -1)"
fi
exit $rc
