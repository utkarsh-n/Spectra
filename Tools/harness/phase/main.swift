// macOS runner for the phase-space engine oracles (built and run by Tools/check-phase.sh).
//
// Compiled together with Spectra/Phase/*.swift, Spectra/Core (media, SI), Spectra/RF (the array
// factor oracle) and SpectraTests/PhaseTests.swift (-D SPECTRA_HARNESS), so the checks are
// exactly the ones `PhaseTests` runs in XCTest.
//
//   phase-check [-v] [group-substring]
//
// Prints every check (PASS/FAIL, name, measured vs expected), a per-group timing line, and
// exits 1 if anything failed.
import Foundation

let arguments = CommandLine.arguments.dropFirst().filter { $0 != "-v" }
let filter = arguments.first?.lowercased()

var passed = 0
var failed = 0
let start = Date()
print("Spectra phase-space engine oracles (Utkarsh's convention (C), wigner-spacetime.md rules 1–6)")
for group in PhaseOracleSuite.groups where filter.map({ group.name.lowercased().contains($0) }) ?? true {
  let t0 = Date()
  let checks = group.run()
  let ms = Date().timeIntervalSince(t0) * 1000
  print("\n── \(group.name) (\(checks.count) checks, \(String(format: "%.0f", ms)) ms)")
  for c in checks {
    print((c.passed ? "PASS  " : "FAIL  ") + c.name + " — " + c.detail)
    if c.passed { passed += 1 } else { failed += 1 }
  }
}
let seconds = Date().timeIntervalSince(start)
print("\n\(passed) passed, \(failed) failed in \(String(format: "%.2f", seconds)) s.")
if passed + failed == 0 {
  print("No oracle group matched \"\(filter ?? "")\".")
} else {
  print(failed == 0 ? "All phase checks passed." : "\(failed) check(s) failed.")
}
exit(failed == 0 && passed > 0 ? 0 : 1)
