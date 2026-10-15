// macOS runner for the spin engine oracles (built and run by Tools/check-spin.sh).
//
// Compiled together with Spectra/Spin/*.swift and SpectraTests/SpinTests.swift
// (-D SPECTRA_HARNESS), so the checks are exactly the ones `SpinTests` runs in XCTest.
//
//   spin-check [-v] [group-substring]
//
// Prints every check (PASS/FAIL, name, measured vs expected), a per-group timing line, and
// exits 1 if anything failed. `-v` is accepted for symmetry with check-core; output is
// always complete.
import Foundation

let arguments = CommandLine.arguments.dropFirst().filter { $0 != "-v" }
let filter = arguments.first?.lowercased()

var passed = 0
var failed = 0
let start = Date()
print("Spectra spin engine oracles (gyre-integration.md §10, Gyre physcheck, worked values)")
for group in SpinOracleSuite.groups where filter.map({ group.name.lowercased().contains($0) }) ?? true {
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
  print(failed == 0 ? "All spin checks passed." : "\(failed) check(s) failed.")
}
exit(failed == 0 && passed > 0 ? 0 : 1)
