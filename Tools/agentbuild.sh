#!/bin/zsh
# Build one builder's slice over the shared baseline, so parallel builders never see each
# other's half-finished files.
#
#   Tools/agentbuild.sh <name> <ownedPath>... [-- test [extra xcodebuild args]]
#
# 1. Copies the baseline project tree (${SPECTRA_BASELINE:-$TMPDIR/SpectraBaseline}, a
#    plain project tree such as $TMPDIR/SpectraBuild/src after a green build) to
#    $TMPDIR/SpectraAgent-<name>/src.
# 2. Overlays each owned path from the live project (a file or a folder; a path that no
#    longer exists in the live project is removed from the copy).
# 3. Runs XcodeGen and builds for the simulator; with "-- test" also runs SpectraTests.
#    Derived data is per agent ($TMPDIR/SpectraAgent-<name>/dd).
#
# Example:
#   Tools/agentbuild.sh scope Spectra/UI/Scope Spectra/Render/Scenes/ScopeScene.swift \
#     Spectra/Render/Scope.metal SpectraTests/ScopeTests.swift -- test
set -e -o pipefail

if (( $# < 2 )); then
  print -u2 "usage: Tools/agentbuild.sh <name> <ownedPath>... [-- test [extra xcodebuild args]]"
  exit 64
fi

SRC="$(cd "$(dirname "$0")/.." && pwd)"
NAME="$1"; shift
BASE="${SPECTRA_BASELINE:-${TMPDIR:-/tmp}/SpectraBaseline}"
WORK="${TMPDIR:-/tmp}/SpectraAgent-$NAME"
SIM="${SPECTRA_SIM:-iPhone 17 Pro}"

paths=()
RUN_TESTS=0
while (( $# > 0 )); do
  if [[ "$1" == "--" ]]; then
    shift
    if [[ "${1:-}" == test ]]; then RUN_TESTS=1; shift; fi
    break
  fi
  paths+=("$1")
  shift
done
extra=("$@")

if [[ ! -f "$BASE/project.yml" ]]; then
  print -u2 "No baseline at $BASE (expected a project tree with project.yml)."
  print -u2 "Create one with: Tools/build.sh sim && rsync -a --delete \$TMPDIR/SpectraBuild/src/ \$TMPDIR/SpectraBaseline/"
  exit 66
fi

mkdir -p "$WORK/src" "$WORK/results"
rsync -a --delete --exclude '*.xcodeproj' "$BASE/" "$WORK/src/"
for p in "${paths[@]}"; do
  p="${p%/}"
  if [[ -d "$SRC/$p" ]]; then
    mkdir -p "$WORK/src/$p"
    rsync -a --delete --exclude '.DS_Store' "$SRC/$p/" "$WORK/src/$p/"
  elif [[ -f "$SRC/$p" ]]; then
    mkdir -p "$(dirname "$WORK/src/$p")"
    cp "$SRC/$p" "$WORK/src/$p"
  else
    rm -rf "$WORK/src/$p"
  fi
  print "  overlay: $p"
done

cd "$WORK/src"
xcodegen generate --quiet

DEST="platform=iOS Simulator,name=$SIM"
common=(-project Spectra.xcodeproj -scheme Spectra -configuration Debug -destination "$DEST"
  -derivedDataPath "$WORK/dd")
if (( RUN_TESTS )); then
  cmd=(xcodebuild "${common[@]}" -resultBundlePath "$WORK/results/test-$(date +%Y%m%d-%H%M%S).xcresult"
    -only-testing:SpectraTests test)
  LOG="$WORK/test.log"
else
  cmd=(xcodebuild "${common[@]}" build)
  LOG="$WORK/build.log"
fi

print "→ ${cmd[*]} ${extra[*]}"
print "  log: $LOG"
if "${cmd[@]}" "${extra[@]}" > "$LOG" 2>&1; then rc=0; else rc=$?; fi
errors="$(grep -E "error:|warning: .*Spectra/|Test Case .* failed|\*\* (BUILD|TEST) FAILED" "$LOG" | sort -u | tail -80 || true)"
[[ -n "$errors" ]] && print -- "$errors"
grep -E "Executed [0-9]+ tests?|\*\* (BUILD|TEST) (SUCCEEDED|FAILED) \*\*" "$LOG" | tail -4 || true
exit $rc
