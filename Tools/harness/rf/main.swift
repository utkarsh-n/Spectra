// macOS oracle harness for Spectra/RF (built and run by Tools/check-rf.sh).
//
// Compiled together with Spectra/RF/**/*.swift and SpectraTests/RFTests.swift (-D SPECTRA_HARNESS),
// so the checks are exactly the ones RFTests runs in XCTest. Then it times the Fourier-page
// pipeline (generate + channel + receive + Hann spectrum of 4096 complex samples).
//
//   rf-oracles [-v] [group …]
//
// Prints one row per group (checks, failures), every failing check, the timings, and exits 1 if
// any oracle failed, any group ran no checks, a 4096-sample frame took 2 ms or more, or the
// slowest antenna model the knobs allow (64 × 64 patch array at 2λ) took 300 ms or more to build.
import Foundation

/// CPU time of this thread in ns. The performance guards use it instead of wall time, so a
/// machine busy with other builds (load averages in the hundreds during parallel agent runs)
/// does not fail them; it still counts every instruction the engine executes.
func cpuNanoseconds() -> UInt64 { clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) }

let arguments = Array(CommandLine.arguments.dropFirst())
let verbose = arguments.contains("-v")
let selected = arguments.filter { !$0.hasPrefix("-") }
let groups = selected.isEmpty ? RFOracles.groups : selected

func pad(_ s: String, _ n: Int, left: Bool = false) -> String {
  s.count >= n ? s : (left ? String(repeating: " ", count: n - s.count) + s : s + String(repeating: " ", count: n - s.count))
}

print("Spectra RF oracles (rf-physics.md verified reference)")
print(pad("group", 16) + pad("checks", 8, left: true) + pad("failed", 8, left: true) + pad("time", 10, left: true))
var totalChecks = 0
var failures: [RFCheckResult] = []
var passedGroups = 0
for g in groups {
  let start = Date()
  let results = RFOracles.run(g)
  let ms = Date().timeIntervalSince(start) * 1000
  var failed = results.filter { !$0.passed }
  // A group that produced no checks has tested nothing: that is a failure, not a pass.
  if results.isEmpty { failed.append(RFCheckResult(group: g, name: "no checks ran", passed: false, detail: "empty group")) }
  totalChecks += results.count
  failures += failed
  if failed.isEmpty, !results.isEmpty { passedGroups += 1 }
  print(pad(g, 16) + pad("\(results.count)", 8, left: true) + pad("\(failed.count)", 8, left: true) + pad(String(format: "%.0f ms", ms), 10, left: true))
  if verbose {
    for r in results where r.passed { print("    ok  \(r.name)  (\(r.detail))") }
  }
}
print("")
for f in failures { print("FAIL \(f.group) / \(f.name): \(f.detail)") }
if !failures.isEmpty { print("") }

// MARK: Performance: 4096 complex samples generated, sent through the channel, received and analysed.

print("Frame timing, thread CPU time (4096 samples: generate + channel + receive + 4096-point Hann spectrum, median of 50)")
var analyzer = RF.SpectrumAnalyzer(count: 4096)!
var spectrum = [Float]()
var worstMedian = 0.0
let cases: [(String, RF.BasebandLinkConfig)] = {
  var out: [(String, RF.BasebandLinkConfig)] = []
  for id in ["nr-fr1", "wifi-ax", "lte", "gsm", "ble", "gps-l1", "edge", "fm", "am", "fmcw-77"] {
    var c = RF.BasebandLinkConfig(system: RF.SystemsCatalog.system(id: id)!)
    c.snrDB = 25
    c.delaySpread = 100e-9
    c.fading = .rayleigh
    c.dopplerHz = 50
    c.frequencyOffsetHz = 200
    out.append((id, c))
  }
  var heavy = RF.BasebandLinkConfig(waveform: .linear(modulation: .qam4096, symbolRate: 10e6, pulse: .rootRaisedCosine(rolloff: 0.2)))
  heavy.snrDB = 40
  heavy.delaySpread = 300e-9
  heavy.fading = .rician(k: 5)
  heavy.dopplerHz = 100
  out.append(("4096QAM RRC, 31 taps", heavy))
  return out
}()
for (name, config) in cases {
  var link = RF.BasebandLink(config)
  _ = link.next()
  var times: [Double] = []
  for _ in 0..<50 {
    let start = cpuNanoseconds()
    let frame = link.next()
    var block = frame.rx
    if block.count != 4096 { block.resize(to: 4096) }
    analyzer.powerDB(block, into: &spectrum)
    times.append(Double(cpuNanoseconds() - start) / 1e6)
  }
  times.sort()
  let median = times[times.count / 2]
  worstMedian = max(worstMedian, median)
  print("  " + pad(name, 22) + pad(String(format: "%.3f ms", median), 10, left: true) + pad(String(format: "(max %.3f)", times.last!), 14, left: true))
}
print("")
print("Antenna model build times, thread CPU time (pattern integral + cuts)")
for style in RF.AntennaStyle.allCases {
  var p = RF.AntennaParameters(style: style)
  if style == .phasedArray {
    p.arrayNx = 16
    p.arrayNy = 16
    p.arrayElement = .patch
    p.steerTheta = 30
  }
  let start = cpuNanoseconds()
  let m = RF.AntennaModel(p)
  let mesh = RF.PatternMesh(model: m)
  let ms = Double(cpuNanoseconds() - start) / 1e6
  print("  " + pad(style.displayName, 22) + pad(String(format: "%.2f ms", ms), 10, left: true) + "  D \(String(format: "%.2f", m.directivityDBi)) dBi, mesh \(mesh.rows)×\(mesh.columns)")
}
print("")
print("Antenna model worst cases, thread CPU time (knob limits, best of 3)")
var worstModel = 0.0
let extremes: [(String, (inout RF.AntennaParameters) -> Void)] = [
  ("64×64 patch 2λ steer 30°", { $0.style = .phasedArray; $0.arrayNx = 64; $0.arrayNy = 64; $0.arraySpacing = 2; $0.arrayElement = .patch; $0.steerTheta = 30 }),
  ("64×64 isotropic 2λ 30°", { $0.style = .phasedArray; $0.arrayNx = 64; $0.arrayNy = 64; $0.arraySpacing = 2; $0.steerTheta = 30 }),
  ("64×1 patch 2λ steer 60°", { $0.style = .phasedArray; $0.arrayNx = 64; $0.arraySpacing = 2; $0.arrayElement = .patch; $0.steerTheta = 60 }),
  ("8×8 patch λ/2 steer 40°", { $0.style = .phasedArray; $0.arrayNx = 8; $0.arrayNy = 8; $0.arrayElement = .patch; $0.steerTheta = 40 }),
  ("Horn 20λ × 20λ", { $0.style = .horn; $0.hornA = 20; $0.hornB = 20 }),
  ("Dish 200λ", { $0.style = .dish; $0.dishDiameter = 200 }),
  ("Dipole 3λ", { $0.style = .dipole; $0.dipoleLength = 3 }),
]
for (name, edit) in extremes {
  var p = RF.AntennaParameters(style: .dipole, frequency: 28e9)
  edit(&p)
  // Best of three builds, so a busy machine does not trip the guard.
  var ms = Double.infinity
  var m = RF.AntennaModel(RF.AntennaParameters(style: .dipole))
  for _ in 0..<3 {
    let start = cpuNanoseconds()
    m = RF.AntennaModel(p)
    ms = min(ms, Double(cpuNanoseconds() - start) / 1e6)
  }
  worstModel = max(worstModel, ms)
  print("  " + pad(name, 26) + pad(String(format: "%.2f ms", ms), 10, left: true) + "  D \(String(format: "%.2f", m.directivityDBi)) dBi")
}
print("")
let perfOK = worstMedian < 2 && worstModel < 300
print("\(passedGroups)/\(groups.count) groups passed, \(totalChecks) checks, \(failures.count) failed; slowest frame median \(String(format: "%.3f", worstMedian)) ms (budget 2 ms); slowest antenna model \(String(format: "%.1f", worstModel)) ms (guard 300 ms).")
print(failures.isEmpty && perfOK ? "RF ORACLES OK" : "RF ORACLES FAILED")
exit(failures.isEmpty && perfOK ? 0 : 1)
