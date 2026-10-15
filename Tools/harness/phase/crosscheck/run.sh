#!/bin/zsh
# Independent numpy cross-check of Spectra/Phase (phase-engine verifier, 2026-10-08).
# Builds the exporter (Spectra/Phase + Spectra/Core + main.swift, swiftc -O) in a scratch dir
# outside iCloud, writes the engine's outputs for fixed inputs to JSON, and re-derives every
# number with numpy/mpmath straight from convention (C) (direct sums, no shared code).
#   Tools/harness/phase/crosscheck/run.sh      → "N passed, 0 failed", exit 0
set -e -o pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../../.." && pwd)"
WORK="${SPECTRA_PHASE_CROSSCHECK:-${TMPDIR:-/tmp}/SpectraPhaseCrossCheck}"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode-beta.app/Contents/Developer}"
mkdir -p "$WORK/src"
rsync -a --delete --exclude '*.md' "$ROOT/Spectra/Phase/" "$WORK/src/Phase/"
rsync -a --delete --exclude '*.md' "$ROOT/Spectra/Core/" "$WORK/src/Core/"
cp "$HERE/main.swift" "$HERE/verify.py" "$WORK/"
cd "$WORK"
phase=("${(@f)$(find src/Phase -name '*.swift' | LC_ALL=C sort)}")
core=("${(@f)$(find src/Core -name '*.swift' | LC_ALL=C sort)}")
xcrun swiftc -O -swift-version 6 $phase $core main.swift -o exporter
./exporter swift.json
python3 -I verify.py swift.json
