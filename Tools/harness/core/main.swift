// macOS parity harness for Spectra/Core (built and run by Tools/check-core.sh).
//
// Compiled together with Spectra/Core/**/*.swift and SpectraTests/ParityVectors.swift
// (-D SPECTRA_HARNESS), so the checks are exactly the ones CoreParityTests runs in XCTest.
//
//   core-parity [path/to/vectors.json] [-v]
//
// Prints one row per category (cases, comparisons, max relative and absolute error, PASS or
// FAIL), the first failures of any failing category, and exits 1 if anything failed.
import Foundation

let arguments = CommandLine.arguments.dropFirst()
let verbose = arguments.contains("-v")
let path = arguments.first { !$0.hasPrefix("-") } ?? "SpectraTests/Fixtures/vectors.json"

let loadStart = Date()
let vectors: ParityVectors
do {
  vectors = try ParityVectors.load(contentsOf: URL(fileURLWithPath: path))
} catch {
  print("core-parity: cannot load \(path): \(error)")
  exit(2)
}
let loadSeconds = Date().timeIntervalSince(loadStart)

let runStart = Date()
let reports = ParityChecks.runAll(vectors)
let runSeconds = Date().timeIntervalSince(runStart)

func pad(_ s: String, _ n: Int, left: Bool = false) -> String {
  s.count >= n ? s : (left ? String(repeating: " ", count: n - s.count) + s : s + String(repeating: " ", count: n - s.count))
}

func sci(_ x: Double) -> String { x == 0 ? "0" : String(format: "%.1e", x) }

print("Spectra Core parity: \(path)")
print("  generator \(vectors.meta.generator), seed \(vectors.meta.seed), source sha256 \(vectors.meta.sourceSha256.prefix(12))…")
print("  decoded \(vectors.meta.total) cases in \(String(format: "%.2f", loadSeconds)) s; checked in \(String(format: "%.2f", runSeconds)) s")
print("")
print(pad("category", 20) + pad("cases", 7, left: true) + pad("checks", 9, left: true) + pad("max rel", 10, left: true)
  + pad("max abs", 10, left: true) + "  result")
var passedCategories = 0
var totalChecks = 0
var vectorCases = 0
for r in reports {
  totalChecks += r.checks
  if ParityChecks.categoryNames.contains(r.category) { vectorCases += r.cases }
  if r.passed { passedCategories += 1 }
  let result = r.passed ? "PASS" : "FAIL (\(r.failures))"
  print(pad(r.category, 20) + pad("\(r.cases)", 7, left: true) + pad("\(r.checks)", 9, left: true)
    + pad(sci(r.maxRelative), 10, left: true) + pad(sci(r.maxAbsolute), 10, left: true) + "  " + result)
}
print("")
for r in reports where !r.passed || (verbose && !r.messages.isEmpty) {
  print("\(r.category): \(r.failures) failing comparison(s)")
  for m in r.messages { print("  " + m) }
}
let allPassed = passedCategories == reports.count
print(
  "\(passedCategories)/\(reports.count) categories passed (\(ParityChecks.categoryNames.count) vector categories + coverage + reference + native extensions + display + robustness); "
    + "\(vectorCases) vector cases, \(totalChecks) comparisons.")
print(allPassed ? "PARITY OK" : "PARITY FAILED")
exit(allPassed ? 0 : 1)
