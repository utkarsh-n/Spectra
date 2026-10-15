// Parity vectors for the Swift port of spectra-lab's core (port-plan.md §4–§5).
//
// This file is compiled twice:
//   - into SpectraTests, where CoreParityTests runs one XCTest per category;
//   - into the macOS harness (Tools/check-core.sh, with -D SPECTRA_HARNESS), together with
//     Spectra/Core/**/*.swift and Tools/harness/core/main.swift.
// So it holds both the Decodable mirror of vectors.json and the per-category checks, and it
// must stay Foundation-only.
#if !SPECTRA_HARNESS
@testable import Spectra
#endif
import Foundation

// MARK: - JSON mirror

/// One JSON value of `vectors.json`. Numbers decode with `JSONDecoder` (bit-exact with V8's
/// shortest round-trip output); non-finite numbers arrive as the strings "Infinity",
/// "-Infinity" and "NaN" and are read back through `double`.
nonisolated enum ParityJSON: Decodable, Sendable {
  case null
  case bool(Bool)
  case number(Double)
  case string(String)
  case array([ParityJSON])
  case object([String: ParityJSON])

  init(from decoder: any Decoder) throws {
    let c = try decoder.singleValueContainer()
    if c.decodeNil() {
      self = .null
    } else if let d = try? c.decode(Double.self) {
      self = .number(d)
    } else if let b = try? c.decode(Bool.self) {
      self = .bool(b)
    } else if let s = try? c.decode(String.self) {
      // spectra-lab's copy is British; the Core's UI copy is American (AmericanSpelling).
      self = .string(AmericanSpelling.us(s))
    } else if let a = try? c.decode([ParityJSON].self) {
      self = .array(a)
    } else {
      self = .object(try c.decode([String: ParityJSON].self))
    }
  }

  /// The member `key` of an object (`.null` when absent or not an object).
  subscript(key: String) -> ParityJSON {
    if case .object(let o) = self { return o[key] ?? .null }
    return .null
  }

  /// Element `index` of an array (`.null` when out of range or not an array).
  subscript(index: Int) -> ParityJSON {
    if case .array(let a) = self, a.indices.contains(index) { return a[index] }
    return .null
  }

  /// A number, including the vectors' string encoding of ±∞ and NaN; nil otherwise.
  var double: Double? {
    switch self {
    case .number(let d): d
    case .string("Infinity"): .infinity
    case .string("-Infinity"): -.infinity
    case .string("NaN"): .nan
    default: nil
    }
  }

  /// A number with an exact integer value.
  var int: Int? {
    guard let d = double, d.isFinite, d == d.rounded(), abs(d) < 9e15 else { return nil }
    return Int(d)
  }

  var string: String? {
    if case .string(let s) = self { return s }
    return nil
  }

  var bool: Bool? {
    if case .bool(let b) = self { return b }
    return nil
  }

  /// The elements of an array (empty for anything else).
  var array: [ParityJSON] {
    if case .array(let a) = self { return a }
    return []
  }

  /// The members of an object (empty for anything else).
  var object: [String: ParityJSON] {
    if case .object(let o) = self { return o }
    return [:]
  }

  var isNull: Bool {
    if case .null = self { return true }
    return false
  }
}

/// `spectra-lab/tests/parity/vectors.json`: `meta` plus one `{about, cases}` per category.
nonisolated struct ParityVectors: Decodable, Sendable {
  struct Meta: Decodable, Sendable {
    var generator: String
    var seed: Int
    var sourceSha256: String
    var counts: [String: Int]
    var total: Int
    var tolerance: String
  }

  struct Category: Decodable, Sendable {
    var about: String
    var cases: [ParityJSON]
  }

  let meta: Meta
  let categories: [String: Category]

  private struct Key: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init(_ s: String) { stringValue = s }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
  }

  init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: Key.self)
    meta = try c.decode(Meta.self, forKey: Key("meta"))
    var categories: [String: Category] = [:]
    for key in c.allKeys where key.stringValue != "meta" {
      categories[key.stringValue] = try c.decode(Category.self, forKey: key)
    }
    self.categories = categories
  }

  static func load(contentsOf url: URL) throws -> ParityVectors {
    try JSONDecoder().decode(ParityVectors.self, from: Data(contentsOf: url))
  }
}

// MARK: - Tolerances and reports

/// Tolerance classes of port-plan §4 (also stated in `meta.tolerance`).
nonisolated enum ParityTolerance: Sendable {
  /// Bit-identical (−0 equals 0, NaN equals NaN): strings, keys, counts and anything built
  /// from + − × ÷ √ alone.
  case exact
  /// |a − b| ≤ 1e-12·|b|, or ≤ 1e-300 near zero: single-expression results with one libm call.
  case tight
  /// |a − b| ≤ max(1e-10·|b|, 1e-13): chained results (specimens, media, samples, fieldview).
  case chained
  /// |a − b| ≤ the given bound (bounded quantities: cosines, angles, integrated trajectories).
  case absolute(Double)

  func allows(_ a: Double, _ b: Double) -> Bool {
    if a == b || (a.isNaN && b.isNaN) { return true }
    guard a.isFinite, b.isFinite else { return false }
    let d = abs(a - b)
    switch self {
    case .exact: return false
    case .tight: return d <= Swift.max(1e-12 * abs(b), 1e-300)
    case .chained: return d <= Swift.max(1e-10 * abs(b), 1e-13)
    case .absolute(let bound): return d <= bound
    }
  }
}

/// The outcome of one category.
nonisolated struct ParityReport: Sendable {
  var category: String
  /// Vector cases visited.
  var cases = 0
  /// Individual value comparisons.
  var checks = 0
  var failures = 0
  /// The first few failure descriptions.
  var messages: [String] = []
  /// Largest |a − b|/|b| over the numeric comparisons (|a − b| when b = 0).
  var maxRelative = 0.0
  /// Largest |a − b| over the numeric comparisons.
  var maxAbsolute = 0.0

  var passed: Bool { failures == 0 && cases > 0 }
}

/// Accumulates comparisons for one category.
nonisolated struct ParityCheck {
  var report: ParityReport
  /// Prefix for failure messages, usually the case index.
  var label = ""

  init(_ category: String) { report = ParityReport(category: category) }

  mutating func fail(_ message: @autoclosure () -> String) {
    report.failures += 1
    if report.messages.count < 12 { report.messages.append("\(report.category) \(label) \(message())") }
  }

  /// Compares an optional number with a JSON number or null (null-ness is exact).
  mutating func number(
    _ actual: Double?, _ expected: ParityJSON, _ tol: ParityTolerance, _ what: @autoclosure () -> String
  ) {
    report.checks += 1
    switch (actual, expected.double) {
    case (nil, nil) where expected.isNull:
      return
    case (let a?, let b?):
      if a.isFinite && b.isFinite {
        let d = abs(a - b)
        report.maxAbsolute = Swift.max(report.maxAbsolute, d)
        report.maxRelative = Swift.max(report.maxRelative, b == 0 ? d : d / abs(b))
      }
      if !tol.allows(a, b) {
        fail("\(what()): got \(a), expected \(b) (diff \(a - b))")
      }
    default:
      fail("\(what()): got \(actual.map { "\($0)" } ?? "nil"), expected \(expected)")
    }
  }

  mutating func text(_ actual: String?, _ expected: ParityJSON, _ what: @autoclosure () -> String) {
    report.checks += 1
    if actual != expected.string || (actual == nil && !expected.isNull) {
      if !(actual == nil && expected.isNull) {
        fail("\(what()): got \(actual.map { "\"\($0)\"" } ?? "nil"), expected \(expected)")
      }
    }
  }

  mutating func flag(_ actual: Bool?, _ expected: ParityJSON, _ what: @autoclosure () -> String) {
    report.checks += 1
    let ok = actual == nil ? expected.isNull : actual == expected.bool
    if !ok { fail("\(what()): got \(actual.map { "\($0)" } ?? "nil"), expected \(expected)") }
  }

  mutating func count(_ actual: Int, _ expected: Int, _ what: @autoclosure () -> String) {
    report.checks += 1
    if actual != expected { fail("\(what()): count \(actual), expected \(expected)") }
  }

  mutating func that(_ condition: Bool, _ what: @autoclosure () -> String) {
    report.checks += 1
    if !condition { fail(what()) }
  }
}

// MARK: - Category checks

/// Runs every category of `vectors.json` against the Swift port (port-plan §5).
nonisolated enum ParityChecks {
  /// The categories in generator order (port-plan §5 table).
  static let categoryNames: [String] = [
    "constants", "tables", "dataTables", "conversions", "bandAt", "describe", "spectralRGB", "displayColor",
    "format", "crossedDetents", "nearestComparison", "jonesFields", "ellipse", "polarizer", "intensity",
    "planck", "components", "pulse", "laser", "electronTrajectory", "oscillatorResponse", "lorentzEpsilon",
    "drude", "complexIndex", "slab", "anchorsBridge", "logLog", "media", "xcom", "waterAbsorption",
    "specimens", "waterAlpha", "inSeries", "dnaAbsorbance", "samples", "hydrogenLines", "hydrogenLine",
    "larmor", "sanitize", "editSource", "timeScale", "deserialize", "applyPreset", "fieldview",
  ]

  /// Every category, a coverage report (file vs checker vs `meta.counts`), the independent
  /// reference values, the native extensions that have no JS counterpart, the display helpers
  /// and the edge-input robustness checks.
  static func runAll(_ vectors: ParityVectors) -> [ParityReport] {
    categoryNames.map { run($0, in: vectors) } + [coverage(vectors), referenceValues(), nativeExtensions(), display(), robustness()]
  }

  /// One category.
  static func run(_ name: String, in vectors: ParityVectors) -> ParityReport {
    var c = ParityCheck(name)
    guard let category = vectors.categories[name] else {
      c.fail("missing from vectors.json")
      return c.report
    }
    let cases = category.cases
    c.report.cases = cases.count
    switch name {
    case "constants": constants(&c, cases)
    case "tables": tables(&c, cases)
    case "dataTables": dataTables(&c, cases)
    case "conversions": conversions(&c, cases)
    case "bandAt": bandAt(&c, cases)
    case "describe": describe(&c, cases)
    case "spectralRGB": spectralRGB(&c, cases)
    case "displayColor": displayColor(&c, cases)
    case "format": format(&c, cases)
    case "crossedDetents": crossedDetents(&c, cases)
    case "nearestComparison": nearestComparison(&c, cases)
    case "jonesFields": jonesFields(&c, cases)
    case "ellipse": ellipse(&c, cases)
    case "polarizer": polarizer(&c, cases)
    case "intensity": intensity(&c, cases)
    case "planck": planck(&c, cases)
    case "components": components(&c, cases)
    case "pulse": pulse(&c, cases)
    case "laser": laser(&c, cases)
    case "electronTrajectory": electronTrajectory(&c, cases)
    case "oscillatorResponse": oscillatorResponse(&c, cases)
    case "lorentzEpsilon": lorentzEpsilon(&c, cases)
    case "drude": drude(&c, cases)
    case "complexIndex": complexIndex(&c, cases)
    case "slab": slab(&c, cases)
    case "anchorsBridge": anchorsBridge(&c, cases)
    case "logLog": logLog(&c, cases)
    case "media": media(&c, cases)
    case "xcom": xcom(&c, cases)
    case "waterAbsorption": waterAbsorption(&c, cases)
    case "specimens": specimens(&c, cases)
    case "waterAlpha": waterAlpha(&c, cases)
    case "inSeries": inSeries(&c, cases)
    case "dnaAbsorbance": dnaAbsorbance(&c, cases)
    case "samples": samples(&c, cases)
    case "hydrogenLines": hydrogenLines(&c, cases)
    case "hydrogenLine": hydrogenLine(&c, cases)
    case "larmor": larmor(&c, cases)
    case "sanitize": sanitize(&c, cases)
    case "editSource": editSource(&c, cases)
    case "timeScale": timeScale(&c, cases)
    case "deserialize": deserialize(&c, cases)
    case "applyPreset": applyPreset(&c, cases)
    case "fieldview": fieldview(&c, cases)
    default: c.fail("no checker for this category")
    }
    return c.report
  }

  /// Every category in the file has a checker, every checker has vectors, and the case counts
  /// match `meta.counts` and `meta.total`.
  static func coverage(_ vectors: ParityVectors) -> ParityReport {
    var c = ParityCheck("coverage")
    c.report.cases = vectors.categories.count
    for name in vectors.categories.keys.sorted() {
      c.that(categoryNames.contains(name), "category \(name) has no checker")
    }
    var total = 0
    for name in categoryNames {
      let n = vectors.categories[name]?.cases.count ?? -1
      total += Swift.max(0, n)
      c.count(n, vectors.meta.counts[name] ?? -2, "\(name) cases vs meta.counts")
    }
    c.count(total, vectors.meta.total, "total cases vs meta.total")
    return c.report
  }

  // MARK: Shared helpers

  private static func source(_ j: ParityJSON) -> WaveSource {
    WaveSource(
      enabled: j["enabled"].bool ?? true, kind: WaveSource.Kind(rawValue: j["kind"].string ?? "") ?? .plane,
      lambda: j["lambda"].double ?? 550e-9, e0: j["E0"].double ?? 1000, theta: j["theta"].double ?? 90,
      delta: j["delta"].double ?? 0, phi: j["phi"].double ?? 0, cycles: j["cycles"].double ?? 3,
      temperature: j["temperature"].double ?? 5772)
  }

  private static func checkSource(
    _ c: inout ParityCheck, _ s: WaveSource, _ e: ParityJSON, lambda: ParityTolerance, _ what: String
  ) {
    c.flag(s.enabled, e["enabled"], "\(what).enabled")
    c.text(s.kind.rawValue, e["kind"], "\(what).kind")
    c.number(s.lambda, e["lambda"], lambda, "\(what).lambda")
    c.number(s.e0, e["E0"], .exact, "\(what).E0")
    c.number(s.theta, e["theta"], .exact, "\(what).theta")
    c.number(s.delta, e["delta"], .exact, "\(what).delta")
    c.number(s.phi, e["phi"], .exact, "\(what).phi")
    c.number(s.cycles, e["cycles"], .exact, "\(what).cycles")
    c.number(s.temperature, e["temperature"], .exact, "\(what).temperature")
  }

  /// Compares every known key of a JS state (unknown keys pass through in JS and are dropped
  /// by Codable; port-plan §7 Q19).
  private static func checkState(_ c: inout ParityCheck, _ s: SpectraState, _ e: ParityJSON) {
    let sources = e["sources"].array
    c.count(s.sources.count, sources.count, "sources")
    for (i, x) in sources.enumerated() where i < s.sources.count {
      checkSource(&c, s.sources[i], x, lambda: .tight, "sources[\(i)]")
    }
    c.number(Double(s.active), e["active"], .exact, "active")
    c.flag(s.link, e["link"], "link")
    c.text(s.medium.rawValue, e["medium"], "medium")
    c.number(s.speed, e["speed"], .exact, "speed")
    c.text(s.instrument.rawValue, e["instrument"], "instrument")
    let sc = e["scope"]
    c.flag(s.scope.showE, sc["showE"], "scope.showE")
    c.flag(s.scope.showB, sc["showB"], "scope.showB")
    c.flag(s.scope.showS, sc["showS"], "scope.showS")
    c.number(s.scope.yaw, sc["yaw"], .exact, "scope.yaw")
    c.number(s.scope.pitch, sc["pitch"], .exact, "scope.pitch")
    c.number(s.scope.zoom, sc["zoom"], .exact, "scope.zoom")
    let d = e["decompose"]
    c.text(s.decompose.tab.rawValue, d["tab"], "decompose.tab")
    c.number(s.decompose.polarizer, d["polarizer"], .exact, "decompose.polarizer")
    c.text(s.decompose.probeMode.rawValue, d["probeMode"], "decompose.probeMode")
    c.number(s.decompose.a0, d["a0"], .exact, "decompose.a0")
    let b = e["bench"]
    c.text(s.bench.arrangement.rawValue, b["arrangement"], "bench.arrangement")
    c.number(s.bench.lambda0, b["lambda0"], .exact, "bench.lambda0")
    c.text(s.bench.focus.rawValue, b["focus"], "bench.focus")
    let l = e["lab"]
    c.text(s.lab.sample.rawValue, l["sample"], "lab.sample")
    c.text(s.lab.mode.rawValue, l["mode"], "lab.mode")
    c.number(s.lab.sweep, l["sweep"], .exact, "lab.sweep")
    c.flag(s.lab.sweeping, l["sweeping"], "lab.sweeping")
    let f = e["feedback"]
    c.flag(s.feedback.sound, f["sound"], "feedback.sound")
    c.flag(s.feedback.haptics, f["haptics"], "feedback.haptics")
    c.number(s.feedback.strength, f["strength"], .exact, "feedback.strength")
    c.flag(s.playing, e["playing"], "playing")
    c.text(s.preset, e["preset"], "preset")
  }

  // MARK: Constants and static tables

  private static func constants(_ c: inout ParityCheck, _ cases: [ParityJSON]) {
    let values: [String: Double] = [
      "C": SI.c, "H": SI.h, "HBAR": SI.hbar, "E_CHARGE": SI.e, "KB": SI.kB, "NA": SI.nA, "EPS0": SI.eps0,
      "MU0": SI.mu0, "ME": SI.me, "ME_EV": SI.meEV, "ME_OVER_MP": SI.meOverMp, "RYDBERG_INF": SI.rydbergInf,
      "R_HYDROGEN": SI.rHydrogen, "WIEN_B": SI.wienB, "GAMMA_PROTON_HZ_PER_T": SI.gammaProtonHzPerT,
      "HC_EV_M": SI.hcEVm, "EV_TO_KCAL_PER_MOL": SI.eVToKcalPerMol, "EV_TO_KJ_PER_MOL": SI.eVToKJPerMol,
      "PAIR_THRESHOLD_EV": SI.pairThresholdEV, "IONIZING_EV": SI.ionizingEV, "VISIBLE_EDGE_EV": SI.visibleEdgeEV,
      "LOG_MIN": Spectrum.logMin, "LOG_MAX": Spectrum.logMax, "XCOM_MIN_EV": Matter.xcomMinEV,
      "XCOM_MAX_EV": Matter.xcomMaxEV, "XCOM_LAMBDA_MAX": Matter.xcomLambdaMax, "ZINC_ne": Matter.zinc.ne,
      "ZINC_wp": Matter.zinc.wp, "ZINC_gamma": Matter.zinc.gamma, "ZINC_plasmaEV": Matter.zinc.plasmaEV,
      "FV_MAX_RATIO": FieldView.maxRatio,
    ]
    for x in cases {
      let name = x["name"].string ?? "?"
      c.label = name
      guard let v = values[name] else {
        c.fail("constant not ported")
        continue
      }
      c.number(v, x["value"], .exact, "value")
    }
  }

  private static func tables(_ c: inout ParityCheck, _ cases: [ParityJSON]) {
    guard let t = cases.first else { return }
    c.label = "bands"
    let bands = t["bands"].array
    c.count(Spectrum.bands.count, bands.count, "bands")
    for (b, e) in zip(Spectrum.bands, bands) {
      c.text(b.key.rawValue, e["key"], "key")
      c.text(b.name, e["name"], "name")
      c.text(b.short, e["short"], "short")
      c.number(b.lo, e["lo"], .exact, "\(b.key).lo")
      c.number(b.hi, e["hi"], .exact, "\(b.key).hi")
      c.text(b.colorHex, e["color"], "\(b.key).color")
    }
    c.label = "detents"
    let detents = t["detents"].array
    c.count(Spectrum.detents.count, detents.count, "detents")
    for (d, e) in zip(Spectrum.detents, detents) {
      c.number(d.log, e["log"], .tight, "\(d.label).log")
      c.text(d.kind.rawValue, e["kind"], "kind")
      c.text(d.label, e["label"], "label")
    }
    c.label = "sizeComparisons"
    let sizes = t["sizeComparisons"].array
    c.count(Spectrum.sizeComparisons.count, sizes.count, "sizeComparisons")
    for (s, e) in zip(Spectrum.sizeComparisons, sizes) {
      c.number(s.size, e["size"], .exact, "size")
      c.text(s.label, e["label"], "label")
    }
    c.label = "workFunctions"
    let wf = t["workFunctions"].object
    c.count(Matter.workFunctions.count, wf.count, "workFunctions")
    for w in Matter.workFunctions { c.number(w.eV, wf[w.metal] ?? .null, .exact, w.metal) }
    c.number(Matter.zincWorkFunction, wf["zinc"] ?? .null, .exact, "zincWorkFunction")
    c.label = "series"
    let series = t["series"].array
    c.count(Samples.series.count, series.count, "series")
    for (s, e) in zip(Samples.series, series) {
      c.number(Double(s.n1), e["n1"], .exact, "n1")
      c.text(s.name, e["name"], "name")
    }
    c.label = "instruments"
    let instruments = t["instruments"].array
    c.count(SpectraState.Instrument.allCases.count, instruments.count, "instruments")
    for (i, e) in zip(SpectraState.Instrument.allCases, instruments) {
      c.text(i.rawValue, e["key"], "key")
      c.text(i.name, e["name"], "\(i).name")
      c.text(i.detail, e["detail"], "\(i).detail")
    }
    c.label = "sourceNames"
    let names = t["sourceNames"].array
    c.count(SpectraState.sourceNames.count, names.count, "sourceNames")
    for (n, e) in zip(SpectraState.sourceNames, names) { c.text(n, e, "name") }
    c.count(FieldView.sourceLetters.count, names.count, "FieldView.sourceLetters")
    for (n, e) in zip(FieldView.sourceLetters, names) { c.text(n, e, "FieldView letter") }
    c.label = "sourceKinds"
    let kinds = t["sourceKinds"].array
    c.count(WaveSource.Kind.allCases.count, kinds.count, "sourceKinds")
    for (k, e) in zip(WaveSource.Kind.allCases, kinds) {
      c.text(k.rawValue, e["key"], "key")
      c.text(k.name, e["name"], "\(k).name")
      c.text(k.note, e["note"], "\(k).note")
    }
    c.label = "media"
    let media = t["media"].array
    c.count(Matter.Medium.allCases.count, media.count, "media")
    for (m, e) in zip(Matter.Medium.allCases, media) {
      c.text(m.rawValue, e["key"], "key")
      c.text(m.name, e["name"], "\(m).name")
    }
    c.label = "specimens"
    let specimens = t["specimens"].array
    c.count(SpecimenKey.allCases.count, specimens.count, "specimens")
    for (s, e) in zip(SpecimenKey.allCases, specimens) {
      c.text(s.rawValue, e["key"], "key")
      c.text(s.name, e["name"], "\(s).name")
      c.text(s.sub, e["sub"], "\(s).sub")
    }
    c.label = "samples"
    let samples = t["samples"].array
    c.count(SampleKey.allCases.count, samples.count, "samples")
    for (s, e) in zip(SampleKey.allCases, samples) {
      c.text(s.rawValue, e["key"], "key")
      c.text(s.name, e["name"], "\(s).name")
      c.text(s.source.rawValue, e["source"], "\(s).source")
      let modes = e["modes"].array
      c.count(s.modes.count, modes.count, "\(s).modes")
      for (m, me) in zip(s.modes, modes) { c.text(m.rawValue, me, "\(s).mode") }
      let notes = e["notes"].array
      c.count(s.modes.count, notes.count, "\(s).notes")
      for (m, ne) in zip(s.modes, notes) { c.text(s.note(mode: m), ne, "\(s).note(\(m.rawValue))") }
      let axis = e["axis"]
      c.text(s.axis.kind.rawValue, axis["kind"], "\(s).axis.kind")
      c.number(s.axis.from, axis["from"], .exact, "\(s).axis.from")
      c.number(s.axis.to, axis["to"], .exact, "\(s).axis.to")
      c.text(s.axis.label, axis["label"], "\(s).axis.label")
    }
    c.label = "presets"
    let presets = t["presets"].array
    c.count(SpectraPreset.all.count, presets.count, "presets")
    for (p, e) in zip(SpectraPreset.all, presets) {
      c.text(p.key, e["key"], "key")
      c.text(p.name, e["name"], "\(p.key).name")
      c.text(p.detail, e["detail"], "\(p.key).detail")
      c.text(p.note, e["note"], "\(p.key).note")
    }
    c.label = "defaults"
    checkState(&c, SpectraState(), t["defaults"])
    c.label = "defaultSource"
    checkSource(&c, WaveSource(), t["defaultSource"], lambda: .exact, "defaultSource")
  }

  private static func dataTables(_ c: inout ParityCheck, _ cases: [ParityJSON]) {
    guard let t = cases.first else { return }
    let xcom = t["xcom"].object
    c.count(XCOMMaterial.allCases.count, xcom.count, "XCOM materials")
    for m in XCOMMaterial.allCases {
      c.label = "xcom.\(m.rawValue)"
      let e = xcom[m.rawValue] ?? .null
      c.text(m.name, e["name"], "name")
      c.number(m.density, e["density"], .exact, "density")
      c.text(m.sourceURL, e["source"], "source")
      let rows = e["rows"].array
      c.count(m.table.count, rows.count, "rows")
      for (i, r) in rows.enumerated() where i < m.table.count {
        c.number(m.table.xs[i], r[0], .exact, "row \(i) MeV")
        c.number(m.table.ys[i], r[1], .exact, "row \(i) mu/rho")
      }
    }
    c.label = "segelstein"
    let rows = t["waterAbsorption"].array
    let table = SegelsteinWater.table
    c.count(table.count, rows.count, "rows")
    for (i, r) in rows.enumerated() where i < table.count {
      c.number(table.xs[i], r[0], .exact, "row \(i) nm")
      c.number(table.ys[i], r[1], .exact, "row \(i) alpha")
    }
  }

  // MARK: Spectrum

  private static func conversions(_ c: inout ParityCheck, _ cases: [ParityJSON]) {
    for (i, x) in cases.enumerated() {
      c.label = "#\(i)"
      guard let lambda = x["lambda"].double else { continue }
      c.number(Spectrum.frequency(lambda), x["frequency"], .exact, "frequency")
      c.number(Spectrum.wavelength(frequency: x["frequency"].double ?? .nan), x["wavelength"], .exact, "wavelength")
      c.number(Spectrum.photonEV(lambda), x["photonEV"], .exact, "photonEV")
      let ev = x["photonEV"].double ?? .nan
      c.number(Spectrum.wavelength(eV: ev), x["wavelengthFromEV"], .exact, "wavelengthFromEV")
      c.number(Spectrum.kcalPerMol(eV: ev), x["kcalPerMol"], .exact, "kcalPerMol")
      c.number(Spectrum.kjPerMol(eV: ev), x["kjPerMol"], .exact, "kjPerMol")
      c.number(Spectrum.wavenumber(lambda), x["wavenumber"], .exact, "wavenumber")
      c.number(Spectrum.wavelength(wavenumber: x["wavenumber"].double ?? .nan), x["fromWavenumber"], .exact, "fromWavenumber")
      c.number(Spectrum.clampLog(x["log"].double ?? .nan), x["clampLog"], .exact, "clampLog")
    }
  }

  private static func bandAt(_ c: inout ParityCheck, _ cases: [ParityJSON]) {
    for (i, x) in cases.enumerated() {
      c.label = "#\(i)"
      let lambda = x["lambda"].double ?? .nan
      c.text(Spectrum.band(at: lambda).key.rawValue, x["band"], "band(\(lambda))")
      c.text(Spectrum.subBand(at: lambda), x["sub"], "subBand(\(lambda))")
      c.text(Spectrum.ionizationClass(lambda).rawValue, x["ion"], "ionizationClass(\(lambda))")
    }
  }

  private static func describe(_ c: inout ParityCheck, _ cases: [ParityJSON]) {
    for (i, x) in cases.enumerated() {
      c.label = "#\(i)"
      let lambda = x["lambda"].double ?? .nan
      let d = Spectrum.describe(lambda)
      c.number(d.f, x["f"], .exact, "f")
      c.number(d.ev, x["ev"], .exact, "ev")
      c.text(d.band.key.rawValue, x["band"], "band")
      c.text(d.sub, x["sub"], "sub")
      c.text(d.ion.rawValue, x["ion"], "ion")
      c.text(d.ion.label, x["ionLabel"], "ionLabel")
      c.text(d.colorHex, x["color"], "color(\(lambda))")
      let t = x["text"]
      c.text(d.text.lambda, t["lambda"], "text.lambda(\(lambda))")
      c.text(d.text.f, t["f"], "text.f(\(lambda))")
      c.text(d.text.ev, t["ev"], "text.ev(\(lambda))")
      c.text(d.text.kcal, t["kcal"], "text.kcal(\(lambda))")
      c.text(d.text.wavenumber, t["wavenumber"], "text.wavenumber(\(lambda))")
    }
  }

  private static func spectralRGB(_ c: inout ParityCheck, _ cases: [ParityJSON]) {
    for (i, x) in cases.enumerated() {
      c.label = "#\(i)"
      let nm = x["nm"].double ?? .nan
      let rgb = Spectrum.spectralRGB(nm: nm)
      c.number(rgb.x, x["rgb"][0], .exact, "r(\(nm))")
      c.number(rgb.y, x["rgb"][1], .exact, "g(\(nm))")
      c.number(rgb.z, x["rgb"][2], .exact, "b(\(nm))")
    }
  }

  private static func displayColor(_ c: inout ParityCheck, _ cases: [ParityJSON]) {
    for (i, x) in cases.enumerated() {
      c.label = "#\(i)"
      let lambda = x["lambda"].double ?? .nan
      c.text(Spectrum.displayColorHex(lambda), x["color"], "displayColor(\(lambda))")
      c.text(Spectrum.hueName(nm: lambda * 1e9), x["hue"], "hueName(\(lambda * 1e9))")
    }
  }

  private static func format(_ c: inout ParityCheck, _ cases: [ParityJSON]) {
    for (i, e) in cases.enumerated() {
      c.label = "#\(i)"
      let x = e["x"].double ?? .nan
      let a = abs(x)
      c.text(JSFormat.sig3(x), e["sig3"], "sig3(\(x))")
      c.text(JSFormat.sci(x), e["sci"], "sci(\(x))")
      c.text(JSFormat.sci(x, unit: "Hz"), e["sciUnit"], "sci(\(x), Hz)")
      c.text(JSFormat.length(a), e["length"], "length(\(a))")
      c.text(JSFormat.frequency(a * 1e10), e["frequency"], "frequency(\(a * 1e10))")
      c.text(JSFormat.energy(a), e["energy"], "energy(\(a))")
      c.text(JSFormat.kcal(eV: a), e["kcal"], "kcal(\(a))")
    }
  }

  private static func crossedDetents(_ c: inout ParityCheck, _ cases: [ParityJSON]) {
    for (i, x) in cases.enumerated() {
      c.label = "#\(i)"
      let from = x["from"].double ?? .nan, to = x["to"].double ?? .nan
      let got = Spectrum.crossedDetents(fromLog: from, toLog: to).map(\.label)
      let want = x["crossed"].array.compactMap(\.string)
      c.that(got == want, "crossedDetents(\(from), \(to)): got \(got), expected \(want)")
    }
  }

  private static func nearestComparison(_ c: inout ParityCheck, _ cases: [ParityJSON]) {
    for (i, x) in cases.enumerated() {
      c.label = "#\(i)"
      let r = Spectrum.nearestComparison(x["lambda"].double ?? .nan)
      c.number(r.size, x["size"], .exact, "size")
      c.text(r.label, x["label"], "label")
      c.number(r.ratio, x["ratio"], .exact, "ratio")
      c.number(r.decades, x["decades"], .absolute(1e-13), "decades")
    }
  }

  // MARK: Wave

  private static func jonesFields(_ c: inout ParityCheck, _ cases: [ParityJSON]) {
    for (i, x) in cases.enumerated() {
      c.label = "#\(i)"
      let s = WaveSource(
        lambda: x["lambda"].double ?? .nan, theta: x["theta"].double ?? .nan, delta: x["delta"].double ?? .nan,
        phi: x["phi"].double ?? .nan)
      let j = Wave.jones(s)
      c.number(j.ax, x["jones"]["ax"], .absolute(1e-15), "jones.ax")
      c.number(j.ay, x["jones"]["ay"], .absolute(1e-15), "jones.ay")
      c.number(j.delta, x["jones"]["delta"], .exact, "jones.delta")
      let f = Wave.fields(s, phase: x["q"].double ?? .nan)
      c.number(f.ex, x["fields"]["ex"], .absolute(1e-15), "fields.ex")
      c.number(f.ey, x["fields"]["ey"], .absolute(1e-15), "fields.ey")
      c.number(f.bx, x["fields"]["bx"], .absolute(1e-15), "fields.bx")
      c.number(f.by, x["fields"]["by"], .absolute(1e-15), "fields.by")
      let q = Wave.phase(s, z: x["z"].double ?? .nan, t: x["t"].double ?? .nan, n: x["n"].double ?? .nan)
      c.number(q, x["phase"], .exact, "phase")
    }
  }

  private static func ellipse(_ c: inout ParityCheck, _ cases: [ParityJSON]) {
    for (i, x) in cases.enumerated() {
      c.label = "#\(i)"
      let theta = x["theta"].double ?? .nan, delta = x["delta"].double ?? .nan
      let e = Wave.ellipse(WaveSource(theta: theta, delta: delta))
      c.text(e.kind.rawValue, x["kind"], "kind(\(theta), \(delta))")
      c.text(e.sense?.rawValue, x["sense"], "sense(\(theta), \(delta))")
      // Circular light: orientation is atan2 of two ~1e-17 values (port-plan §7 Q13), skipped.
      if e.kind != .circular { c.number(e.orientation, x["orientation"], .absolute(1e-12), "orientation") }
      c.number(e.chi, x["chi"], .absolute(1e-12), "chi")
    }
  }

  private static func polarizer(_ c: inout ParityCheck, _ cases: [ParityJSON]) {
    for (i, x) in cases.enumerated() {
      c.label = "#\(i)"
      let s = WaveSource(theta: x["theta"].double ?? .nan, delta: x["delta"].double ?? .nan)
      c.number(Wave.polarizerTransmission(s, alphaDeg: x["alpha"].double ?? .nan), x["T"], .absolute(1e-14), "T")
    }
  }

  private static func intensity(_ c: inout ParityCheck, _ cases: [ParityJSON]) {
    for (i, x) in cases.enumerated() {
      c.label = "#\(i)"
      let e0 = x["E0"].double ?? .nan, lambda = x["lambda"].double ?? .nan, n = x["n"].double ?? .nan
      let reflect = x["reflect"].bool ?? false
      c.number(Wave.intensity(e0: e0, n: n), x["intensity"], .exact, "intensity")
      c.number(Wave.intensity(e0: e0), x["intensityVacuum"], .exact, "intensityVacuum")
      c.number(Wave.peakB(e0: e0, n: n), x["peakB"], .exact, "peakB")
      c.number(Wave.radiationPressure(e0: e0, n: n, reflect: reflect), x["radiationPressure"], .exact, "radiationPressure")
      c.number(Wave.photonFlux(e0: e0, lambda: lambda, n: n), x["photonFlux"], .exact, "photonFlux")
    }
  }

  private static func planck(_ c: inout ParityCheck, _ cases: [ParityJSON]) {
    for (i, x) in cases.enumerated() {
      c.label = "#\(i)"
      let t = x["T"].double ?? .nan, lambda = x["lambda"].double ?? .nan
      c.number(Wave.wienPeak(t), x["wienPeak"], .exact, "wienPeak")
      c.number(Wave.planckLambda(lambda, temperature: t), x["planck"], .tight, "planck(\(lambda), \(t))")
    }
  }

  private static func components(_ c: inout ParityCheck, _ cases: [ParityJSON]) {
    for (i, x) in cases.enumerated() {
      c.label = "#\(i)"
      let s = WaveSource(
        kind: WaveSource.Kind(rawValue: x["kind"].string ?? "") ?? .plane, lambda: x["lambda"].double ?? .nan,
        phi: x["phi"].double ?? .nan, cycles: x["cycles"].double ?? .nan, temperature: x["temperature"].double ?? .nan)
      let got = Wave.components(s, count: x["count"].int ?? 15)
      let want = x["components"].array
      c.count(got.count, want.count, "components")
      for (k, (g, w)) in zip(got, want).enumerated() {
        c.number(g.lambda, w["lambda"], s.kind == .thermal ? .tight : .exact, "[\(k)].lambda")
        c.number(g.amp, w["amp"], .tight, "[\(k)].amp")
        c.number(g.phase, w["phase"], .exact, "[\(k)].phase")
      }
    }
  }

  private static func pulse(_ c: inout ParityCheck, _ cases: [ParityJSON]) {
    for (i, x) in cases.enumerated() {
      c.label = "#\(i)"
      let s = WaveSource(kind: .pulse, cycles: x["cycles"].double ?? .nan)
      c.number(Wave.pulseEnvelope(s, phase: x["q"].double ?? .nan), x["envelope"], .tight, "envelope")
      c.number(Wave.pulseBandwidth(s), x["bandwidth"], .tight, "bandwidth")
    }
  }

  private static func laser(_ c: inout ParityCheck, _ cases: [ParityJSON]) {
    for (i, x) in cases.enumerated() {
      c.label = "#\(i)"
      let e0 = x["E0"].double ?? .nan, lambda = x["lambda"].double ?? .nan, a = x["a"].double ?? .nan
      c.number(Wave.a0(e0: e0, lambda: lambda), x["a0"], .exact, "a0")
      c.number(Wave.fieldForA0(a, lambda: lambda), x["fieldForA0"], .exact, "fieldForA0")
      c.number(Wave.quiverAmplitude(e0: e0, lambda: lambda), x["quiver"], .exact, "quiver")
      c.number(Wave.driftSpeed(a), x["drift"], .exact, "drift")
    }
  }

  private static func electronTrajectory(_ c: inout ParityCheck, _ cases: [ParityJSON]) {
    for (i, x) in cases.enumerated() {
      c.label = "#\(i)"
      let a = x["a"].double ?? .nan
      guard let mode = Wave.ProbeMode(rawValue: x["mode"].string ?? "") else {
        c.fail("unknown mode \(x["mode"])")
        continue
      }
      let s = WaveSource(theta: x["theta"].double ?? .nan, delta: x["delta"].double ?? .nan)
      let pts = Wave.electronTrajectory(
        s, a: a, mode: mode, cycles: x["cycles"].double ?? .nan, steps: x["steps"].int ?? 0)
      c.count(pts.count, x["count"].int ?? -1, "points")
      // Integrated over up to 4,000 midpoint steps: 1e-12·max(1, a²) absolute (port-plan §4).
      let tol = ParityTolerance.absolute(1e-12 * Swift.max(1, a * a))
      for p in x["samples"].array {
        guard let k = p["i"].int, pts.indices.contains(k) else {
          c.fail("sample index \(p["i"]) out of range")
          continue
        }
        let g = pts[k]
        c.number(g.eta, p["eta"], .exact, "[\(k)].eta")
        c.number(g.t, p["t"], tol, "[\(k)].t")
        c.number(g.x, p["x"], tol, "[\(k)].x")
        c.number(g.y, p["y"], tol, "[\(k)].y")
        c.number(g.z, p["z"], tol, "[\(k)].z")
        c.number(g.ux, p["ux"], tol, "[\(k)].ux")
        c.number(g.uy, p["uy"], tol, "[\(k)].uy")
        c.number(g.uz, p["uz"], tol, "[\(k)].uz")
        c.number(g.gamma, p["gamma"], tol, "[\(k)].gamma")
      }
    }
  }

  // MARK: Matter

  private static func oscillatorResponse(_ c: inout ParityCheck, _ cases: [ParityJSON]) {
    for (i, x) in cases.enumerated() {
      c.label = "#\(i)"
      let r = Matter.oscillatorResponse(
        omega: x["omega"].double ?? .nan, omega0: x["omega0"].double ?? .nan, gamma: x["gamma"].double ?? .nan)
      c.number(r.amplitude, x["amplitude"], .tight, "amplitude")
      c.number(r.lag, x["lag"], .tight, "lag")
      c.number(r.power, x["power"], .exact, "power")
    }
  }

  private static func lorentzEpsilon(_ c: inout ParityCheck, _ cases: [ParityJSON]) {
    for (i, x) in cases.enumerated() {
      c.label = "#\(i)"
      let oscillators = x["oscillators"].array.map {
        Matter.LorentzOscillator(w0: $0["w0"].double ?? .nan, wp: $0["wp"].double ?? .nan, gamma: $0["gamma"].double ?? .nan)
      }
      let eps = Matter.lorentzEpsilon(omega: x["omega"].double ?? .nan, oscillators)
      c.number(eps.re, x["eps"]["re"], .exact, "eps.re")
      c.number(eps.im, x["eps"]["im"], .exact, "eps.im")
    }
  }

  private static func drude(_ c: inout ParityCheck, _ cases: [ParityJSON]) {
    for (i, x) in cases.enumerated() {
      c.label = "#\(i)"
      let eps = Matter.drudeEpsilon(
        omega: x["omega"].double ?? .nan, wp: x["wp"].double ?? .nan, gamma: x["gamma"].double ?? .nan)
      c.number(eps.re, x["eps"]["re"], .exact, "eps.re")
      c.number(eps.im, x["eps"]["im"], .exact, "eps.im")
      let ix = Matter.index(fromEpsilon: eps)
      c.number(ix.n, x["index"]["n"], .exact, "index.n")
      c.number(ix.k, x["index"]["k"], .exact, "index.k")
    }
  }

  private static func complexIndex(_ c: inout ParityCheck, _ cases: [ParityJSON]) {
    for (i, x) in cases.enumerated() {
      c.label = "#\(i)"
      let z = Matter.Complex(x["re"].double ?? .nan, x["im"].double ?? .nan)
      let r = Matter.Complex.sqrt(z)
      c.number(r.re, x["sqrt"]["re"], .exact, "sqrt.re(\(z))")
      c.number(r.im, x["sqrt"]["im"], .exact, "sqrt.im(\(z))")
      let ix = Matter.index(fromEpsilon: z)
      c.number(ix.n, x["n"], .exact, "n")
      c.number(ix.k, x["k"], .exact, "k")
      c.number(
        Matter.absorptionFromK(x["k"].double ?? .nan, lambda: x["lambda"].double ?? .nan), x["absorption"], .exact,
        "absorption")
      c.number(
        Matter.normalReflectance(n: x["n"].double ?? .nan, k: x["k"].double ?? .nan), x["reflectance"], .exact,
        "reflectance")
    }
  }

  private static func slab(_ c: inout ParityCheck, _ cases: [ParityJSON]) {
    // The generator spreads slab()'s {T, R, A} over its own `R` input, so the vector's `R` is
    // the slab's total reflectance and the face reflectance is lost. `slabFaceR` restores the
    // true inputs (re-run of generate.mjs, same seed, keeping R), so all three outputs are
    // checked against JS from JS inputs. (The earlier bisection recovered R by inverting
    // Matter.slab itself, which a consistent bug in slab would have survived.)
    c.count(cases.count, slabFaceR.count, "slab cases vs recorded face reflectances")
    for (i, (x, rFace)) in zip(cases, slabFaceR).enumerated() {
      c.label = "#\(i)"
      let r = Matter.slab(r: rFace, alphaPerCm: x["alpha"].double ?? .nan, thicknessCm: x["thickness"].double ?? .nan)
      c.number(r.t, x["T"], .chained, "T")
      c.number(r.r, x["R"], .chained, "R")
      c.number(r.a, x["A"], .chained, "A")
    }
  }

  /// The face reflectance R each `slab` vector was generated with, in case order. Obtained by
  /// running spectra-lab tests/parity/generate.mjs (seed 20261003) with line 335 changed to
  /// keep `Rin: R`; every other category of that run is byte-identical to the fixture.
  private static let slabFaceR: [Double] = [
    0, 0, 0.822985099395737, 0.02978383500594646, 0.5370147593785077,
    0.0974273084430024, 0.09244424821808934, 0.99, 0.99, 0.059092670469544833,
    0.006951407343149186, 0.5653476882725954, 0.99, 0.0019373190356418491, 0,
    0.99, 0.99, 0.08971855451818556, 0.0704464865848422, 0.99,
    0, 0, 0.99, 0, 0.06456994828768074,
    0.0233653032919392, 0.0609986711293459, 0, 0.99, 0.99,
    0.07439936688169838, 0.99, 0.32053672545589507, 0, 0.7880544455256313,
    0.9145307578146458, 0.6535789065528661, 0, 0.05181933389976621, 0.99,
    0.99, 0.563072043005377, 0.99, 0, 0,
    0.7808247408829629, 0.99, 0, 0.99, 0.02571085887029767,
    0.99, 0.062293381360359494, 0.03437711461447179, 0.828080843668431, 0.8111793592106551,
    0.99, 0.07577595156617463, 0.0509500996908173, 0.00013145916163921357, 0.06007090874481946,
    0.99, 0.99, 0.99, 0, 0,
    0.99, 0.46372655197046697, 0.8008899949491024, 0.99, 0.011375830951146783,
    0.5701309896539897, 0, 0.7088523639831692, 0.99, 0,
    0.7636848110705614, 0.07168796840123833, 0.08902685111388564, 0.028934169095009565, 0.99,
  ]

  private static func anchorsBridge(_ c: inout ParityCheck, _ cases: [ParityJSON]) {
    let rows = LogLogTable(rows: [(100e-9, 4e5), (200e-9, 100), (400e-9, 0.004), (2e-6, 0.004), (9e-6, 5000), (1e3, 1e-6)])
    for (i, x) in cases.enumerated() {
      c.label = "#\(i)"
      let lambda = x["lambda"].double ?? .nan
      c.number(Matter.anchors(rows, lambda), x["anchors"], .chained, "anchors(\(lambda))")
      let b = x["bridge"]
      let v = Matter.bridge(
        lambda, b["la"].double ?? .nan, b["va"].double ?? .nan, b["lb"].double ?? .nan, b["vb"].double ?? .nan)
      c.number(v, b["value"], .chained, "bridge(\(lambda))")
    }
  }

  private static func logLog(_ c: inout ParityCheck, _ cases: [ParityJSON]) {
    let rows = LogLogTable(rows: [(1, 10), (2, 5), (2, 50), (4, 20), (8, 1)])
    for (i, x) in cases.enumerated() {
      c.label = "#\(i)"
      let v = x["x"].double ?? .nan
      c.number(Matter.logLog(rows, v), x["value"], .tight, "logLog(\(v))")
    }
  }

  private static func media(_ c: inout ParityCheck, _ cases: [ParityJSON]) {
    for (i, x) in cases.enumerated() {
      c.label = "#\(i)"
      let lambda = x["lambda"].double ?? .nan
      for m in Matter.Medium.allCases {
        let ix = m.index(lambda), e = x[m.rawValue]
        c.number(ix.n, e["n"], .chained, "\(m).n(\(lambda))")
        c.number(ix.k, e["k"], .chained, "\(m).k(\(lambda))")
        c.flag(ix.valid, e["valid"], "\(m).valid(\(lambda))")
      }
    }
  }

  private static func xcom(_ c: inout ParityCheck, _ cases: [ParityJSON]) {
    for (i, x) in cases.enumerated() {
      c.label = "#\(i)"
      guard let m = XCOMMaterial(rawValue: x["material"].string ?? "") else {
        c.fail("unknown material \(x["material"])")
        continue
      }
      let ev = x["ev"].double ?? .nan
      c.number(Matter.massAttenuation(m, eV: ev), x["massAttenuation"], .tight, "massAttenuation(\(m), \(ev))")
      c.number(Matter.linearAttenuation(m, eV: ev), x["linearAttenuation"], .tight, "linearAttenuation(\(m), \(ev))")
      c.number(
        Matter.linearAttenuation(m, eV: ev, density: x["density"].double ?? .nan), x["linearAttenuationDensity"],
        .tight, "linearAttenuation(\(m), \(ev), density)")
    }
  }

  private static func waterAbsorption(_ c: inout ParityCheck, _ cases: [ParityJSON]) {
    for (i, x) in cases.enumerated() {
      c.label = "#\(i)"
      let lambda = x["lambda"].double ?? .nan
      c.number(Matter.waterAbsorption(lambda), x["alpha"], .tight, "waterAbsorption(\(lambda))")
    }
  }

  // MARK: Specimens

  private static func specimens(_ c: inout ParityCheck, _ cases: [ParityJSON]) {
    for (i, x) in cases.enumerated() {
      guard let key = SpecimenKey(rawValue: x["specimen"].string ?? "") else {
        c.fail("unknown specimen \(x["specimen"])")
        continue
      }
      let lambda = x["lambda"].double ?? .nan
      c.label = "#\(i) \(key.rawValue) λ=\(lambda)"
      let source = x["E0"].double.map { WaveSource(lambda: lambda, e0: $0) }
      let options = SpecimenOptions(lambda0: x["lambda0"].double ?? 120e-9)
      let r = key.evaluate(lambda, source: source, options: options)
      c.number(r.transmission, x["T"], .chained, "T")
      c.number(r.reflection, x["R"], .chained, "R")
      c.number(r.absorption, x["A"], .chained, "A")
      c.number(r.alpha, x["alpha"], .chained, "alpha")
      c.number(r.absorbance, x["absorbance"], .chained, "absorbance")
      c.number(r.boneT, x["boneT"], .chained, "boneT")
      c.number(r.contrast, x["contrast"], .chained, "contrast")
      c.text(r.source.rawValue, x["source"], "source")
      let e = x["response"], p = r.response
      c.text(p.kind.rawValue, e["kind"], "response.kind")
      c.text(p.text, e["text"], "response.text")
      c.number(p.amplitude, e["amplitude"], .chained, "response.amplitude")
      c.number(p.lag, e["lag"], .chained, "response.lag")
      c.number(p.power, e["power"], .chained, "response.power")
      c.text(p.regime?.rawValue, e["where"], "response.where")
      c.number(p.value, e["value"], .chained, "response.value")
      c.number(p.heating, e["heating"], .chained, "response.heating")
      if e["eject"].isNull {
        c.that(p.ejectKeMax == nil, "response.eject: got keMax \(p.ejectKeMax ?? .nan), expected null")
      } else {
        c.number(p.ejectKeMax, e["eject"]["keMax"], .chained, "response.eject.keMax")
      }
      c.flag(p.resonance, e["resonance"], "response.resonance")
    }
  }

  private static func waterAlpha(_ c: inout ParityCheck, _ cases: [ParityJSON]) {
    for (i, x) in cases.enumerated() {
      c.label = "#\(i)"
      let lambda = x["lambda"].double ?? .nan
      let w = Specimens.waterAlpha(lambda)
      c.number(w.alpha, x["alpha"], .chained, "alpha(\(lambda))")
      c.text(w.source.rawValue, x["source"], "source(\(lambda))")
    }
  }

  private static func inSeries(_ c: inout ParityCheck, _ cases: [ParityJSON]) {
    for (i, x) in cases.enumerated() {
      let lambda = x["lambda"].double ?? .nan
      c.label = "#\(i) λ=\(lambda)"
      let steps = Specimens.inSeries(lambda, source: WaveSource(lambda: lambda, e0: x["E0"].double ?? .nan))
      let want = x["series"].array
      c.count(steps.count, want.count, "steps")
      for (s, w) in zip(steps, want) {
        c.text(s.key.rawValue, w["key"], "key")
        c.number(s.before, w["before"], .chained, "\(s.key).before")
        c.number(s.after, w["after"], .chained, "\(s.key).after")
      }
    }
  }

  private static func dnaAbsorbance(_ c: inout ParityCheck, _ cases: [ParityJSON]) {
    for (i, x) in cases.enumerated() {
      c.label = "#\(i)"
      let lambda = x["lambda"].double ?? .nan
      c.number(Specimens.dnaAbsorbance(lambda), x["A"], .tight, "A(\(lambda))")
    }
  }

  // MARK: Samples

  private static func samples(_ c: inout ParityCheck, _ cases: [ParityJSON]) {
    for (i, e) in cases.enumerated() {
      c.label = "#\(i)"
      guard let key = SampleKey(rawValue: e["sample"].string ?? ""), let mode = SampleMode(rawValue: e["mode"].string ?? "")
      else {
        c.fail("unknown sample/mode \(e["sample"]) \(e["mode"])")
        continue
      }
      let x = e["x"].double ?? .nan
      if let u = e["u"].double {
        c.number(key.axis.x(at: u), e["x"], key.axis.kind == .lambdaLog ? .tight : .exact, "\(key).axis.x(at: \(u))")
      }
      c.number(key.value(x, mode: mode), e["value"], .chained, "\(key).value(\(x), \(mode.rawValue))")
      c.number(key.toLambda(x, mode: mode), e["toLambda"], .chained, "\(key).toLambda(\(x), \(mode.rawValue))")
    }
  }

  private static func hydrogenLines(_ c: inout ParityCheck, _ cases: [ParityJSON]) {
    for x in cases {
      guard let mode = SampleMode(rawValue: x["mode"].string ?? "") else {
        c.fail("unknown mode \(x["mode"])")
        continue
      }
      c.label = mode.rawValue
      let got = Samples.hydrogenLines(mode: mode)
      let want = x["lines"].array
      c.count(got.count, want.count, "lines")
      for (k, (g, w)) in zip(got, want).enumerated() {
        c.number(g.lambda, w["lambda"], .exact, "[\(k)].lambda")
        c.text(g.series, w["series"], "[\(k)].series")
        c.number(Double(g.n1), w["n1"], .exact, "[\(k)].n1")
        c.number(Double(g.n2), w["n2"], .exact, "[\(k)].n2")
        c.number(g.strength, w["strength"], .tight, "[\(k)].strength")
      }
    }
  }

  private static func hydrogenLine(_ c: inout ParityCheck, _ cases: [ParityJSON]) {
    for (i, x) in cases.enumerated() {
      c.label = "#\(i)"
      let n1 = x["n1"].int ?? 0, n2 = x["n2"].int ?? 0
      c.number(Samples.hydrogenLine(n1: n1, n2: n2), x["lambda"], .exact, "hydrogenLine(\(n1), \(n2))")
    }
  }

  private static func larmor(_ c: inout ParityCheck, _ cases: [ParityJSON]) {
    for (i, x) in cases.enumerated() {
      c.label = "#\(i)"
      let b0 = x["B0"].double ?? .nan
      let f = x["ppm"].double.map { Samples.larmor(b0: b0, ppm: $0) } ?? Samples.larmor(b0: b0)
      c.number(f, x["f"], .exact, "larmor(\(b0), \(x["ppm"]))")
    }
  }

  // MARK: State and presets

  private static func sanitize(_ c: inout ParityCheck, _ cases: [ParityJSON]) {
    for (i, x) in cases.enumerated() {
      c.label = "#\(i)"
      // λ = 10^clamp(log₁₀ λ) drifts by a few ulp through pow/log10 (port-plan §7 Q9).
      checkSource(&c, source(x["input"]).sanitized(), x["output"], lambda: .tight, "output")
    }
  }

  private static func editSource(_ c: inout ParityCheck, _ cases: [ParityJSON]) {
    for (i, x) in cases.enumerated() {
      c.label = "#\(i)"
      var state = SpectraState()
      state.sources = x["before"].array.map(source)
      state.active = x["active"].int ?? 0
      state.link = x["link"].bool ?? false
      let value = x["value"]
      let edit: SpectraState.SourceEdit
      switch x["key"].string ?? "" {
      case "lambda": edit = .lambda(value.double ?? .nan)
      case "E0": edit = .e0(value.double ?? .nan)
      case "temperature": edit = .temperature(value.double ?? .nan)
      case "theta": edit = .theta(value.double ?? .nan)
      case "delta": edit = .delta(value.double ?? .nan)
      case "phi": edit = .phi(value.double ?? .nan)
      case "cycles": edit = .cycles(value.double ?? .nan)
      case "kind": edit = .kind(WaveSource.Kind(rawValue: value.string ?? "") ?? .plane)
      case "enabled": edit = .enabled(value.bool ?? false)
      default:
        c.fail("unknown key \(x["key"])")
        continue
      }
      c.label = "#\(i) \(x["key"].string ?? "")"
      state.edit(edit)
      let after = x["after"].array
      c.count(state.sources.count, after.count, "sources")
      for (k, (s, e)) in zip(state.sources, after).enumerated() {
        checkSource(&c, s, e, lambda: .tight, "after[\(k)]")
      }
    }
  }

  private static func timeScale(_ c: inout ParityCheck, _ cases: [ParityJSON]) {
    for (i, x) in cases.enumerated() {
      c.label = "#\(i)"
      var state = SpectraState()
      state.sources = x["sources"].array.map(source)
      state.speed = x["speed"].double ?? .nan
      c.number(state.timeScale, x["timeScale"], .exact, "timeScale")
      c.number(state.slowMotion, x["slowMotion"], .exact, "slowMotion")
      let want = x["enabled"].array.compactMap(\.int)
      c.that(state.enabledIndices == want, "enabled: got \(state.enabledIndices), expected \(want)")
      c.count(state.enabledSources.count, want.count, "enabledSources")
    }
  }

  private static func deserialize(_ c: inout ParityCheck, _ cases: [ParityJSON]) {
    for (i, x) in cases.enumerated() {
      c.label = "#\(i)"
      checkState(&c, SpectraState.deserialize(x["text"].string ?? ""), x["state"])
    }
  }

  /// The two base states of the `applyPreset` vectors.
  private static func presetBase(_ name: String) -> SpectraState {
    var s = SpectraState()
    if name == "modified" {
      s.link = true
      s.active = 2
      s.medium = .water
      s.speed = 0.5
      s.sources[1].enabled = true
      s.sources[2].enabled = true
      s.decompose.polarizer = 77
      s.lab.sweeping = true
      s.bench.lambda0 = 300e-9
    }
    return s
  }

  private static func applyPreset(_ c: inout ParityCheck, _ cases: [ParityJSON]) {
    for (i, x) in cases.enumerated() {
      let key = x["key"].string ?? "", base = x["base"].string ?? ""
      c.label = "#\(i) \(base)/\(key)"
      var state = presetBase(base)
      let known = state.apply(preset: key)
      c.that(known == (SpectraPreset.named(key) != nil), "apply(preset:) result")
      checkState(&c, state, x["state"])
    }
  }

  // MARK: Display (ui/fieldview.js)

  private static func fieldview(_ c: inout ParityCheck, _ cases: [ParityJSON]) {
    for x in cases {
      c.label = x["name"].string ?? "?"
      let st = x["state"]
      guard let medium = Matter.Medium(rawValue: st["medium"].string ?? "") else {
        c.fail("unknown medium \(st["medium"])")
        continue
      }
      let ds = FieldView.displaySources(sources: st["sources"].array.map(source), medium: medium)
      let want = x["displaySources"]
      c.number(ds.ref.lambda, want["ref"], .exact, "ref")
      c.flag(ds.inMedium, want["inMedium"], "inMedium")
      c.text(FieldView.hiddenNote(ds), want["hiddenNote"], "hiddenNote")
      let list = want["list"].array
      c.count(ds.list.count, list.count, "list")
      for (d, e) in zip(ds.list, list) {
        let w = "list[\(d.index)]"
        c.number(Double(d.index), e["index"], .exact, "\(w).index")
        c.number(d.scale, e["scale"], .chained, "\(w).scale")
        c.text(d.colorHex, e["color"], "\(w).color")
        c.text(d.tag, e["tag"], "\(w).tag")
        c.number(Double(d.hidden), e["hidden"], .exact, "\(w).hidden")
        c.number(d.jones.ax, e["jones"]["ax"], .absolute(1e-15), "\(w).jones.ax")
        c.number(d.jones.ay, e["jones"]["ay"], .absolute(1e-15), "\(w).jones.ay")
        c.number(d.jones.delta, e["jones"]["delta"], .exact, "\(w).jones.delta")
        let comps = e["comps"].array
        c.count(d.comps.count, comps.count, "\(w).comps")
        for (k, (g, ce)) in zip(d.comps, comps).enumerated() {
          c.number(g.r, ce["r"], .chained, "\(w).comps[\(k)].r")
          c.number(g.amp, ce["amp"], .chained, "\(w).comps[\(k)].amp")
          c.number(g.phase, ce["phase"], .exact, "\(w).comps[\(k)].phase")
          c.number(g.n, ce["n"], .chained, "\(w).comps[\(k)].n")
          c.number(g.k, ce["k"], .chained, "\(w).comps[\(k)].k")
          c.number(g.lambda, ce["lambda"], .chained, "\(w).comps[\(k)].lambda")
        }
      }
      for (k, s) in x["fieldAt"].array.enumerated() {
        let p = FieldView.fieldAt(
          ds, z: s["z"].double ?? .nan, t: s["t"].double ?? .nan, speed: s["speed"].double ?? .nan, only: s["only"].int)
        c.number(p.ex, s["ex"], .chained, "fieldAt[\(k)].ex")
        c.number(p.ey, s["ey"], .chained, "fieldAt[\(k)].ey")
        c.number(p.n, s["n"], .chained, "fieldAt[\(k)].n")
      }
    }
  }

  // MARK: Independent reference values (spectra-lab tests/core.test.mjs)

  /// spectra-lab's own physics suite (`tests/core.test.mjs`) against
  /// `tests/fixtures/reference.json`: values transcribed from NIST ASD, CODATA 2018 / SI 2019,
  /// the Schott N-BK7 data sheet, Malitson 1965, the CRC Handbook, Segelstein 1981 and standard
  /// DNA spectrophotometry, not generated by the code. Parity proves the port equals the JS;
  /// these prove both agree with the cited sources. Tolerances are the suite's own.
  static func referenceValues() -> ParityReport {
    var c = ParityCheck("reference")
    c.report.cases = 14
    var seed: UInt32 = 4242
    func rand() -> Double {
      seed = seed &* 1_664_525 &+ 1_013_904_223
      return Double(seed) / 4_294_967_296
    }
    func near(_ a: Double?, _ b: Double, _ eps: Double, _ what: @autoclosure () -> String) {
      c.number(a, .number(b), .absolute(eps), what())
    }
    func inRange(_ v: Double?, _ lo: Double, _ hi: Double, _ what: @autoclosure () -> String) {
      c.that(v.map { $0 >= lo && $0 <= hi } ?? false, "\(what()): \(v.map { "\($0)" } ?? "nil") not in [\(lo), \(hi)]")
    }

    c.label = "constants and unit conversions"
    near(SI.hcEVm * 1e9, 1239.84198, 1e-4, "hc eV·nm (CODATA)")
    near(SI.eVToKcalPerMol, 23.0605, 1e-3, "eV → kcal/mol")
    near(SI.eVToKJPerMol, 96.4853, 1e-3, "eV → kJ/mol")
    for _ in 0..<2000 {
      let l = pow(10, Spectrum.logMin + rand() * (Spectrum.logMax - Spectrum.logMin))
      near(Spectrum.wavelength(frequency: Spectrum.frequency(l)) / l, 1, 1e-12, "λ → f → λ at \(l)")
      near(Spectrum.wavelength(eV: Spectrum.photonEV(l)) / l, 1, 1e-12, "λ → E → λ at \(l)")
      near(Spectrum.wavelength(wavenumber: Spectrum.wavenumber(l)) / l, 1, 1e-12, "λ → ν̃ → λ at \(l)")
    }
    near(Spectrum.photonEV(550e-9), 2.2543, 1e-4, "photon energy at 550 nm")
    near(Spectrum.wavelength(eV: SI.ionizingEV) * 1e9, 123.98, 0.01, "10 eV wavelength nm")

    c.label = "bands, detents and formatting"
    let bandCases: [(Double, Spectrum.BandKey)] = [
      (550e-9, .visible), (399.9e-9, .uv), (700e-9, .ir), (0.5, .microwave), (3, .radio), (5e-12, .gamma),
    ]
    for (l, key) in bandCases { c.text(Spectrum.band(at: l).key.rawValue, .string(key.rawValue), "band at \(l)") }
    c.text(Spectrum.ionizationClass(100e-9).rawValue, .string("ionizing"), "100 nm")
    c.text(Spectrum.ionizationClass(254e-9).rawValue, .string("bond"), "254 nm")
    c.text(Spectrum.ionizationClass(550e-9).rawValue, .string("none"), "550 nm")
    c.count(Spectrum.crossedDetents(fromLog: log10(800e-9), toLog: log10(500e-9)).count, 1, "800 → 500 nm detents")
    c.count(Spectrum.crossedDetents(fromLog: log10(500e-9), toLog: log10(500e-9)).count, 0, "500 → 500 nm detents")
    c.text(JSFormat.length(550e-9), .string("550 nm"), "length 550 nm")
    c.text(JSFormat.length(0.12236), .string("12.2 cm"), "length 12.2 cm")
    c.text(JSFormat.frequency(545.1e12), .string("545 THz"), "frequency 545 THz")
    c.text(JSFormat.energy(60000), .string("60.0 keV"), "energy 60 keV")
    let hex = Spectrum.displayColorHex(550e-9)
    c.that(
      hex.count == 7 && hex.hasPrefix("#") && hex.dropFirst().allSatisfy { "0123456789abcdef".contains($0) },
      "visible display colour is lowercase #rrggbb, got \(hex)")
    c.text(Spectrum.nearestComparison(1.2e-2).label, .string("a bee"), "nearest comparison at 1.2 cm")

    c.label = "hydrogen (NIST ASD vacuum wavelengths)"
    near(Samples.hydrogenLine(n1: 1, n2: 2) * 1e9, 121.567, 0.005, "Lyman α")
    near(Samples.hydrogenLine(n1: 2, n2: 3) * 1e9, 656.461, 0.02, "H α")
    near(Samples.hydrogenLine(n1: 2, n2: 4) * 1e9, 486.271, 0.01, "H β")
    near(Samples.hydrogenLine(n1: 2, n2: 5) * 1e9, 434.169, 0.01, "H γ")
    near(Samples.hydrogenLine(n1: 2, n2: 6) * 1e9, 410.289, 0.01, "H δ")
    let absorption = Samples.hydrogenLines(mode: .absorption)
    c.that(!absorption.isEmpty && absorption.allSatisfy { $0.series == "Lyman" }, "absorption lines are all Lyman")

    c.label = "refractive indices (Schott, Malitson, CRC)"
    near(Matter.Medium.glass.index(587.56e-9).n, 1.5168, 1e-4, "BK7 n_d")
    near(Matter.Medium.glass.index(486.13e-9).n, 1.5224, 1e-4, "BK7 n_F")
    near(Matter.Medium.glass.index(656.27e-9).n, 1.5143, 1e-4, "BK7 n_C")
    near(Matter.Medium.silica.index(587.56e-9).n, 1.4585, 1e-4, "fused silica n_d")
    near(Matter.Medium.diamond.index(589.3e-9).n, 2.4175, 1e-3, "diamond 589.3 nm")
    near(Matter.Medium.water.index(589e-9).n, 1.3330, 1e-3, "water 589 nm")
    c.that(!Matter.Medium.glass.index(5e-6).valid, "BK7 Sellmeier invalid at 5 µm")

    c.label = "NIST XCOM interpolation"
    for m in XCOMMaterial.allCases {
      let t = m.table
      for i in 0..<t.count {
        if i + 1 < t.count && t.xs[i + 1] == t.xs[i] { continue }  // at an edge the upper value applies
        near(Matter.massAttenuation(m, eV: t.xs[i] * 1e6).map { $0 / t.ys[i] }, 1, 1e-9, "\(m) at \(t.xs[i]) MeV")
      }
      for i in 1..<t.count where t.xs[i] != t.xs[i - 1] {
        let v = Matter.massAttenuation(m, eV: (t.xs[i - 1] * t.xs[i]).squareRoot() * 1e6)
        inRange(
          v, Swift.min(t.ys[i - 1], t.ys[i]) * (1 - 1e-12), Swift.max(t.ys[i - 1], t.ys[i]) * (1 + 1e-12),
          "\(m) midpoint \(i)")
      }
    }
    c.that(
      (Matter.massAttenuation(.lead, eV: 88.0045e3) ?? 0) > 4 * (Matter.massAttenuation(.lead, eV: 88.0e3) ?? .infinity),
      "lead K edge jumps more than 4×")
    c.that(Matter.massAttenuation(.water, eV: 1) == nil, "water at 1 eV is outside the table")

    c.label = "water absorption (Segelstein 1981)"
    near(Matter.waterAbsorption(550e-9), 0.00055845, 1e-9, "α at 550 nm")
    near(Matter.waterAbsorption(10e-6), 638.25, 1e-6, "α at 10 µm")
    let oven = SI.c / 2.45e9
    inRange(Matter.waterAbsorption(oven).map { 1 / $0 }, 1.5, 2.0, "2.45 GHz penetration depth, cm")
    let debye = Matter.Medium.water.index(oven)
    inRange(1 / Matter.absorptionFromK(debye.k, lambda: oven), 1.5, 2.0, "Debye penetration depth, cm")

    c.label = "Lorentz oscillator"
    near(Matter.oscillatorResponse(omega: 1e-4, omega0: 1, gamma: 0.1).lag, 0, 0.01, "lag far below")
    near(Matter.oscillatorResponse(omega: 1, omega0: 1, gamma: 0.1).lag, 90, 1e-9, "lag on resonance")
    near(Matter.oscillatorResponse(omega: 1e3, omega0: 1, gamma: 0.1).lag, 180, 0.01, "lag far above")
    near(Matter.oscillatorResponse(omega: 1, omega0: 1, gamma: 0.1).power, 1, 1e-12, "power on resonance")
    near(
      Matter.lorentzEpsilon(omega: 0.5, [Matter.LorentzOscillator(w0: 1, wp: 1, gamma: 0)]).re, 1 + 1 / 0.75, 1e-12,
      "undamped ε(ω = ω0/2)")

    c.label = "polarization"
    for _ in 0..<500 {
      let theta = rand() * 180 - 90, alpha = rand() * 180
      let malus = cos(((alpha - theta) * Double.pi) / 180)
      near(Wave.polarizerTransmission(WaveSource(theta: theta, delta: 0), alphaDeg: alpha), malus * malus, 1e-12, "Malus")
      near(Wave.polarizerTransmission(WaveSource(theta: 45, delta: 90), alphaDeg: alpha), 0.5, 1e-12, "circular 50%")
    }
    c.text(Wave.ellipse(WaveSource(theta: 30, delta: 0)).kind.rawValue, .string("linear"), "30°/0°")
    near(Wave.ellipse(WaveSource(theta: 30, delta: 0)).orientation, 30, 1e-9, "30° orientation")
    c.text(Wave.ellipse(WaveSource(theta: 45, delta: 90)).kind.rawValue, .string("circular"), "45°/90°")
    c.text(Wave.ellipse(WaveSource(theta: 45, delta: 40)).kind.rawValue, .string("elliptical"), "45°/40°")
    near(Wave.peakB(e0: 1000), 1000 / SI.c, 1e-18, "B0 = E0/c")
    near(Wave.intensity(e0: 1000), 1327.2, 0.1, "I at 1 kV/m")

    c.label = "free electron, exact solution"
    let linear = WaveSource(theta: 0, delta: 0)
    for a in [0.1, 1, 2, 5] {
      let pts = Wave.electronTrajectory(linear, a: a, mode: .both, cycles: 1, steps: 4000)
      for p in stride(from: 0, to: pts.count, by: 97).map({ pts[$0] }) {
        near(p.x, a * (1 - cos(p.eta)), 1e-5 * Swift.max(1, a), "x(η) a=\(a)")
        near(p.z, ((a * a) / 4) * (p.eta - sin(2 * p.eta) / 2), 1e-5 * Swift.max(1, a * a), "z(η) a=\(a)")
        near(p.gamma - p.uz, 1, 1e-12, "light-front invariant a=\(a)")
      }
      if let end = pts.last { near(end.z / end.t, Wave.driftSpeed(a), 1e-6, "drift a=\(a)") }
    }
    c.that(
      Wave.electronTrajectory(linear, a: 2, mode: .electric, cycles: 1, steps: 400).allSatisfy { $0.z == 0 },
      "E only: no forward push")
    c.that(
      Wave.electronTrajectory(linear, a: 2, mode: .magnetic, cycles: 1, steps: 400).allSatisfy {
        $0.x == 0 && $0.y == 0 && $0.z == 0
      }, "B only: nothing moves from rest")
    near(Wave.a0(e0: Wave.fieldForA0(2, lambda: 800e-9), lambda: 800e-9), 2, 1e-12, "a0 round trip")

    c.label = "Planck and Wien"
    for t in [2.725, 310, 5772] {
      let peak = Wave.wienPeak(t)
      var best = 0.0, bestL = 0.0
      for i in 0...20000 {
        let l = peak * pow(10, -0.3 + (0.6 * Double(i)) / 20000)
        let v = Wave.planckLambda(l, temperature: t)
        if v > best {
          best = v
          bestL = l
        }
      }
      near(bestL / peak, 1, 2e-4, "Planck maximum at the Wien peak, T = \(t)")
    }
    near(Wave.wienPeak(310) * 1e6, 9.348, 1e-3, "310 K peak µm")
    near(Wave.components(WaveSource(kind: .pulse, cycles: 3)).reduce(0) { $0 + $1.amp }, 1, 1e-12, "pulse L1 norm")

    c.label = "specimens stay physical"
    let src = WaveSource()
    var lg = Spectrum.logMin
    while lg <= Spectrum.logMax {
      let l = pow(10, lg)
      for key in SpecimenKey.allCases {
        let r = key.evaluate(l, source: src)
        for (name, v) in [("T", r.transmission), ("R", r.reflection), ("A", r.absorption)] {
          if let v { inRange(v, -1e-12, 1 + 1e-12, "\(key).\(name) at \(l)") }
        }
        if let t = r.transmission, let rr = r.reflection, let aa = r.absorption { near(t + rr + aa, 1, 1e-9, "\(key) T+R+A at \(l)") }
        c.that(r.response.text.count > 10, "\(key) text at \(l)")
      }
      lg += 0.005
    }

    c.label = "specimen anchors"
    let a260 = Specimens.dnaAbsorbance(260e-9)
    near(a260, 1.0, 0.02, "DNA A260")
    inRange(a260 / Specimens.dnaAbsorbance(280e-9), 1.8, 2.0, "A260/A280")
    inRange(a260 / Specimens.dnaAbsorbance(230e-9), 2.0, 2.4, "A260/A230")
    c.that(SpecimenKey.zinc.evaluate(650e-9).response.ejectKeMax == nil, "red light ejects nothing from zinc")
    near(SpecimenKey.zinc.evaluate(254e-9).response.ejectKeMax, Spectrum.photonEV(254e-9) - 4.33, 1e-12, "UV-C keMax")
    c.that((SpecimenKey.zinc.evaluate(650e-9).reflection ?? 0) > 0.9, "zinc is a mirror at 650 nm")
    inRange(SpecimenKey.glass.evaluate(550e-9).transmission, 0.9, 0.93, "glass T at 550 nm")
    c.that((SpecimenKey.glass.evaluate(254e-9).transmission ?? 1) < 0.01, "glass blocks UV-C")
    near(SpecimenKey.antenna.evaluate(SI.c / 100e6).response.value, 1, 1e-12, "dipole on resonance")
    c.that((SpecimenKey.antenna.evaluate(SI.c / 300e6).response.value ?? 0) >= 0.5, "third harmonic resonates")
    c.that((SpecimenKey.antenna.evaluate(SI.c / 200e6).response.value ?? 1) < 0.2, "even harmonic does not")
    let xray = SpecimenKey.hand.evaluate(Spectrum.wavelength(eV: 60e3))
    c.that(xray.source == .table, "60 keV finger uses NIST tables")
    c.that((xray.contrast ?? 0) > 0.25, "bone contrast at 60 keV \(xray.contrast ?? .nan)")
    inRange(
      SpecimenKey.water.evaluate(oven, source: WaveSource(e0: 5000)).response.heating, 10, 200, "oven heating K/min")

    c.label = "lab samples"
    near(Samples.larmor(b0: 9.4) / 1e6, 400.229, 0.01, "proton Larmor at 9.4 T, MHz")
    for key in SampleKey.allCases {
      for mode in key.modes {
        for i in 0...200 {
          let x = key.axis.x(at: Double(i) / 200)
          c.that(key.value(x, mode: mode).isFinite, "\(key)/\(mode.rawValue) value finite at \(x)")
          let l = key.toLambda(x, mode: mode)
          c.that(l > 0 && l.isFinite, "\(key)/\(mode.rawValue) toLambda at \(x)")
        }
      }
    }
    c.that(SampleKey.co2.value(1388.2, mode: .ir) < 0.01, "CO₂ symmetric stretch is IR-inactive")
    c.that(SampleKey.co2.value(1388.2, mode: .raman) > 0.9, "but Raman-active")

    c.label = "state"
    var s = SpectraState()
    s.sources[1].enabled = true
    s.link = true
    s.edit(.lambda(1100e-9))
    near(s.sources[1].lambda / s.sources[0].lambda, 450.0 / 550.0, 1e-12, "Link keeps the chord")
    s.edit(.theta(30))
    near(s.sources[1].theta, 30, 1e-12, "Link shifts θ")
    let bad = WaveSource(lambda: 1e9, e0: -5, delta: 270).sanitized()
    c.number(bad.lambda, .number(pow(10, Spectrum.logMax)), .exact, "λ clamps to 10^LOG_MAX")
    c.number(bad.delta, .number(-90), .exact, "δ 270 wraps to −90")
    c.count(SpectraState.deserialize("not json").sources.count, 3, "garbage deserializes to three sources")
    for p in SpectraPreset.all {
      var next = SpectraState()
      next.apply(p)
      c.that(next.sources.allSatisfy { $0.lambda.isFinite && $0.lambda > 0 }, "\(p.key) sources finite")
    }
    near(SpectraState().slowMotion, Spectrum.frequency(550e-9), 1, "slow motion = f(550 nm) at κ 1")
    return c.report
  }

  // MARK: Native extensions (no JS counterpart)

  /// The extended ruler range (LOG_MAX 8) and the long-wave landmarks: the defaults must stay
  /// on the web range, and the ruler must reach 100,000 km only when asked to.
  static func nativeExtensions() -> ParityReport {
    var c = ParityCheck("nativeExtensions")
    c.report.cases = 1
    c.label = "ranges"
    c.number(Spectrum.logMin, .number(-13), .exact, "logMin")
    c.number(Spectrum.logMax, .number(3), .exact, "logMax (web default unchanged)")
    c.number(Spectrum.rulerLogMin, .number(-13), .exact, "rulerLogMin")
    c.number(Spectrum.rulerLogMax, .number(8), .exact, "rulerLogMax")
    c.number(Spectrum.clampLog(7), .number(3), .exact, "clampLog(7)")
    c.number(Spectrum.clampRulerLog(7), .number(7), .exact, "clampRulerLog(7)")
    c.number(Spectrum.clampRulerLog(9), .number(8), .exact, "clampRulerLog(9)")
    c.number(Spectrum.clampRulerLog(-14), .number(-13), .exact, "clampRulerLog(-14)")

    c.label = "sanitize"
    c.number(WaveSource(lambda: 1.408e5).sanitized().lambda, .number(1e3), .tight, "default clamps to 1 km")
    c.number(
      WaveSource(lambda: 1.408e5).sanitized(logRange: Spectrum.rulerLogRange).lambda, .number(1.408e5), .tight,
      "ruler range keeps 140.8 km")
    c.number(
      WaveSource(lambda: 1e9).sanitized(logRange: Spectrum.rulerLogRange).lambda, .number(1e8), .tight,
      "ruler range clamps to 100,000 km")

    c.label = "state"
    var web = SpectraState()
    web.edit(.lambda(5e6))
    c.number(web.sources[0].lambda, .number(1e3), .tight, "edit λ 5,000 km on the web range")
    var ruler = SpectraState()
    ruler.extendedRange = true
    ruler.edit(.lambda(5e6))
    c.number(ruler.sources[0].lambda, .number(5e6), .tight, "edit λ 5,000 km with extendedRange")
    c.that(
      !(String(data: SpectraState().serialized(), encoding: .utf8) ?? "").contains("extendedRange"),
      "default serialization has only the JS keys")
    let restored = SpectraState.deserialize(ruler.serialized())
    c.that(restored.extendedRange, "extendedRange survives a round trip")
    c.number(restored.sources[0].lambda, .number(5e6), .tight, "5,000 km survives a round trip")

    c.label = "landmarks"
    let marks = Dictionary(uniqueKeysWithValues: Spectrum.longWaveLandmarks.map { ($0.id, $0) })
    // Worked values: λ = c/f. Earth-field NMR of water at 50 µT is γ′p·B = 2,128.82 Hz
    // (gyre-integration.md §4.1, shielded γ′p 42.57638543 MHz/T) → 140.826 km.
    c.number(marks["earthNMR"]?.frequency, .number(2128.819_271_5), .absolute(1e-6), "earthNMR f")
    c.number(marks["earthNMR"]?.lambda, .number(140_825.697_142_79), .absolute(1e-6), "earthNMR λ")
    c.number(marks["mains60"]?.lambda, .number(4_996_540.966_666_7), .absolute(1e-3), "mains60 λ")
    c.number(marks["mains50"]?.lambda, .number(5_995_849.16), .absolute(1e-3), "mains50 λ")
    c.number(marks["schumann"]?.lambda, .number(38_287_670.242_656), .absolute(1e-4), "schumann λ")
    for m in Spectrum.longWaveLandmarks {
      let lg = log10(m.lambda)
      c.that(lg > Spectrum.logMax && lg <= Spectrum.rulerLogMax, "\(m.id) lies between LOG_MAX and RULER_LOG_MAX")
      c.text(Spectrum.band(at: m.lambda).key.rawValue, .string("radio"), "\(m.id) band")
    }
    c.that(
      Spectrum.crossedDetents(fromLog: 3, toLog: 8).isEmpty, "no web detents beyond 1 km (band edges end at radio)")

    c.label = "ruler detents"
    c.count(Spectrum.rulerDetents.count, Spectrum.detents.count + Spectrum.longWaveLandmarks.count, "rulerDetents")
    c.that(Array(Spectrum.rulerDetents.prefix(Spectrum.detents.count)) == Spectrum.detents, "rulerDetents start with the web detents")
    let longCrossed = Spectrum.crossedRulerDetents(fromLog: 3, toLog: 8)
    c.that(
      longCrossed.map(\.label) == Spectrum.longWaveLandmarks.map(\.label) && longCrossed.allSatisfy { $0.kind == .landmark },
      "1 km → 100,000 km crosses the four landmarks: \(longCrossed.map(\.label))")
    c.that(
      Spectrum.crossedRulerDetents(fromLog: 8, toLog: 3) == longCrossed, "the crossing set is symmetric in direction")
    // Half-open (lo, hi]: landing exactly on Earth-field NMR fires it, leaving it does not.
    let nmrLog = log10(marks["earthNMR"]?.lambda ?? 1)
    c.count(Spectrum.crossedRulerDetents(fromLog: 5, toLog: nmrLog).count, 1, "arrive on the NMR detent")
    c.count(Spectrum.crossedRulerDetents(fromLog: nmrLog, toLog: 5.5).count, 0, "leave the NMR detent")
    var lgd = Spectrum.logMin
    while lgd < Spectrum.logMax {
      c.that(
        Spectrum.crossedRulerDetents(fromLog: lgd, toLog: lgd + 0.37) == Spectrum.crossedDetents(fromLog: lgd, toLog: lgd + 0.37),
        "ruler detents equal web detents below 1 km at \(lgd)")
      lgd += 0.05
    }

    c.label = "ruler sub-bands"
    // ITU-R V.431: LF 30–300 kHz, VLF 3–30 kHz, ULF 300–3,000 Hz, SLF 30–300 Hz, ELF 3–30 Hz.
    let itu: [(Double, String)] = [
      (1e3, "LF \u{00B7} longwave"), (5e3, "LF \u{00B7} longwave"), (1e4, "VLF"), (marks["earthNMR"]?.lambda ?? 0, "ULF"),
      (marks["mains60"]?.lambda ?? 0, "SLF"), (marks["mains50"]?.lambda ?? 0, "SLF"), (marks["schumann"]?.lambda ?? 0, "ELF"),
      (1e8, "Radio"), (999, "MF \u{00B7} AM broadcast"), (550e-9, "Visible \u{00B7} green"),
    ]
    for (l, name) in itu { c.text(Spectrum.rulerSubBand(at: l), .string(name), "rulerSubBand(\(l))") }
    var lg = Spectrum.logMin
    while lg < Spectrum.logMax {
      let l = pow(10, lg)
      c.that(Spectrum.rulerSubBand(at: l) == Spectrum.subBand(at: l), "rulerSubBand equals subBand below 1 km at \(l)")
      lg += 0.01
    }

    c.label = "beyond 1 km"
    // Every Core function the extended ruler reaches stays finite and physical up to 100,000 km.
    var lgx = Spectrum.logMax
    while lgx <= Spectrum.rulerLogMax {
      let l = pow(10, lgx)
      let d = Spectrum.describe(l)
      c.that(d.f.isFinite && d.ev.isFinite && !d.text.lambda.isEmpty && !d.text.f.isEmpty, "describe(\(l))")
      for key in SpecimenKey.allCases {
        let r = key.evaluate(l, source: WaveSource(lambda: l))
        if let t = r.transmission, let rr = r.reflection, let aa = r.absorption {
          c.that(t.isFinite && rr.isFinite && aa.isFinite, "\(key) finite at \(l)")
          c.number(t + rr + aa, .number(1), .absolute(1e-9), "\(key) T+R+A at \(l)")
        }
        c.that(r.response.text.count > 10, "\(key) text at \(l)")
      }
      var s = SpectraState()
      s.extendedRange = true
      s.edit(.lambda(l))
      let ds = FieldView.displaySources(s)
      let p = FieldView.fieldAt(ds, z: 0.3, t: 1.2, speed: 1)
      c.that(p.ex.isFinite && p.ey.isFinite, "fieldAt finite at \(l)")
      lgx += 0.25
    }

    c.label = "dials"
    for d in SpectraState.Dial.allCases {
      c.that(d.range(extended: false) == d.range, "\(d) range unchanged without the extension")
      let expected = d == .lambda ? Spectrum.rulerLogRange : d.range
      c.that(d.range(extended: true) == expected, "\(d) extended range")
    }

    c.label = "NMR at any field"
    for mode in [SampleMode.nmr400, .nmr60] {
      let b0 = Samples.nmrField(mode)
      for ppm in [-0.3, 0, 1.22, 2.61, 3.69, 4.5] {
        c.number(Samples.ethanolValue(ppm: ppm, b0: b0), .number(SampleKey.nmr.value(ppm, mode: mode)), .exact, "ethanolValue(\(ppm), \(b0))")
        c.number(Samples.nmrLambda(ppm: ppm, b0: b0), .number(SampleKey.nmr.toLambda(ppm, mode: mode)), .exact, "nmrLambda(\(ppm), \(b0))")
      }
    }
    // The web lab's convention (bare γp, ppm from 0) at 50 µT: f = 2,128.874 Hz, λ = 140.822 km.
    c.number(Samples.nmrLambda(ppm: 0, b0: 50e-6), .number(140_822.081_736_6), .absolute(1e-6), "bare-proton λ at 50 µT")

    c.label = "Earth-field NMR of water"
    // gyre-integration.md §4.1 worked values (shielded γ′p): proton f_L at |B|.
    // Rows: |B| (T), f_L (Hz) as printed there, half a unit in its last printed digit. 45.65 µT
    // is Gyre's simulated field |(0, 22, −40)| µT.
    let gyreField = (22.0 * 22 + 40 * 40).squareRoot() * 1e-6
    for (b, f, tol) in [
      (25e-6, 1064.41, 0.005), (gyreField, 1943.65, 0.005), (50e-6, 2128.82, 0.005), (65e-6, 2767.47, 0.005),
      (390e-6, 16_605, 0.5),
    ] {
      c.number(Samples.earthFieldLarmor(b0: b), .number(f), .absolute(tol), "earthFieldLarmor(\(b))")
    }
    c.number(Samples.earthFieldLambda(b0: 50e-6), .number(140_825.697_142_79), .absolute(1e-6), "earthFieldLambda(50 µT)")
    c.number(
      Samples.earthFieldLarmor(b0: 50e-6), .number(marks["earthNMR"]?.frequency ?? .nan), .exact, "the ruler mark is the same line")
    // A 1 µT error moves the line by 42.6 Hz (gyre-integration.md §4.1).
    c.number(
      Samples.earthFieldLarmor(b0: 51e-6) - Samples.earthFieldLarmor(b0: 50e-6), .number(42.576), .absolute(1e-3), "Hz per µT")

    c.label = "instrument controls (ui/controls.js, instruments/*.js)"
    c.that(SpectrumDisplay.speedLogRange == -1.3...0.6, "κ slider log range")
    c.that(SpectrumDisplay.polarizerRange == 0...180, "polarizer range")
    c.that(SpectrumDisplay.a0LogRange == -2...1, "a₀ slider log range")
    c.that(SpectrumDisplay.lambda0LogRange == -8...0, "λ₀ slider log range")
    c.that(SpectraState().bench.lambda0 >= pow(10, SpectrumDisplay.lambda0LogRange.lowerBound), "default λ₀ on its slider")
    c.that(SpectrumDisplay.a0LogRange.contains(log10(SpectraState().decompose.a0)), "default a₀ on its slider")
    return c.report
  }

  // MARK: Display helpers (ui/app.js, ui/feedback.js, instruments/*.js)

  /// `Display/SpectrumDisplay.swift` against values printed by Node from spectra-lab's own
  /// functions (the readout rows transcribe `defaultReadouts` in ui/app.js; the tuner, lab,
  /// prism and pitch helpers are the instruments' expressions). Strings exact, numbers tight.
  static func display() -> ParityReport {
    var c = ParityCheck("display")
    c.report.cases = 13
    func rows(_ state: SpectraState, _ want: [[String]], status: [String], slowmo: String, _ name: String) {
      c.label = "readouts \(name)"
      let got = SpectrumDisplay.readouts(state)
      c.count(got.count, want.count, "rows")
      for (r, w) in zip(got, want) {
        c.text(r.key, .string(w[0]), "key")
        c.text(r.value, .string(w[1]), "\(r.key) value")
        c.text(r.sub, .string(w[2]), "\(r.key) sub")
        c.text(r.colorHex, .string(w[3]), "\(r.key) colour")
      }
      let line = SpectrumDisplay.statusLine(state)
      c.text(line.left, .string(status[0]), "status left")
      c.text(line.right, .string(status[1]), "status right")
      c.text(SpectrumDisplay.slowMotionText(state), .string(slowmo), "slow motion")
    }
    let sup = "\u{00D7}10"
    var water = SpectraState()
    water.medium = .water
    var glass = SpectraState()
    glass.medium = .glass
    glass.sources[0].lambda = 5e-6
    var prism = SpectraState()
    prism.apply(preset: "prism")
    var xray = SpectraState()
    xray.apply(preset: "xray")
    xray.medium = .diamond
    var oven = SpectraState()
    oven.apply(preset: "oven")
    oven.medium = .water
    let common = [
      ["E photon", "2.25 eV", "52.0 kcal/mol", "#ffbf5e"],
    ]
    rows(
      SpectraState(),
      [
        ["\u{03BB} wavelength", "550 nm", "18182 cm\u{207B}\u{00B9}", "#b2ff29"],
        ["f frequency", "545 THz", "period 1.83\(sup)\u{207B}\u{00B9}\u{2075} s", "#59f0b0"],
      ] + common + [
        ["B\u{2080} field", "3.34\(sup)\u{207B}\u{2076} T", "E\u{2080} 1.00\(sup)\u{00B3} V/m", "#ff5c7a"],
        ["Intensity", "1.33\(sup)\u{00B3} W/m\u{00B2}", "3.67\(sup)\u{00B9}\u{2077} photons/cm\u{00B2}\u{00B7}s", "#e8f1ec"],
      ], status: ["Visible \u{00B7} green", "NON-IONIZING"], slowmo: "5.45\(sup)\u{00B9}\u{2074}\u{00D7} slower", "default")
    rows(
      water,
      [
        ["\u{03BB} wavelength", "550 nm", "412 nm in water", "#b2ff29"],
        ["f frequency", "545 THz", "period 1.83\(sup)\u{207B}\u{00B9}\u{2075} s", "#59f0b0"],
      ] + common + [
        ["B\u{2080} field", "4.45\(sup)\u{207B}\u{2076} T", "E\u{2080} 1.00\(sup)\u{00B3} V/m", "#ff5c7a"],
        ["Intensity", "1.77\(sup)\u{00B3} W/m\u{00B2}", "4.91\(sup)\u{00B9}\u{2077} photons/cm\u{00B2}\u{00B7}s", "#e8f1ec"],
        ["n medium", "1.3348", "speed 0.749 c", "#ffbf5e"],
      ], status: ["Visible \u{00B7} green", "NON-IONIZING"], slowmo: "5.45\(sup)\u{00B9}\u{2074}\u{00D7} slower", "water")
    rows(
      glass,
      [
        ["\u{03BB} wavelength", "5.00 \u{00B5}m", "2000 cm\u{207B}\u{00B9}", "#FF7A6B"],
        ["f frequency", "60.0 THz", "period 1.67\(sup)\u{207B}\u{00B9}\u{2074} s", "#59f0b0"],
        ["E photon", "248 meV", "5.72 kcal/mol", "#ffbf5e"],
        ["B\u{2080} field", "5.00\(sup)\u{207B}\u{2076} T", "E\u{2080} 1.00\(sup)\u{00B3} V/m", "#ff5c7a"],
        ["Intensity", "1.99\(sup)\u{00B3} W/m\u{00B2}", "5.01\(sup)\u{00B9}\u{2078} photons/cm\u{00B2}\u{00B7}s", "#e8f1ec"],
        ["n medium", "no data", "outside model range", "#ffbf5e"],
      ], status: ["Mid-wave IR", "NON-IONIZING"], slowmo: "6.00\(sup)\u{00B9}\u{00B3}\u{00D7} slower", "glass 5 µm")
    rows(
      prism,
      [
        ["\u{03BB} wavelength", "450 nm", "295 nm in glass (bk7)", "#2964ff"],
        ["f frequency", "666 THz", "period 1.50\(sup)\u{207B}\u{00B9}\u{2075} s", "#59f0b0"],
        ["E photon", "2.76 eV", "63.5 kcal/mol", "#ffbf5e"],
        ["B\u{2080} field", "5.09\(sup)\u{207B}\u{2076} T", "E\u{2080} 1.00\(sup)\u{00B3} V/m", "#ff5c7a"],
        ["Intensity", "2.02\(sup)\u{00B3} W/m\u{00B2}", "4.59\(sup)\u{00B9}\u{2077} photons/cm\u{00B2}\u{00B7}s", "#e8f1ec"],
        ["n medium", "1.5253", "speed 0.656 c", "#ffbf5e"],
      ], status: ["Visible \u{00B7} blue", "NON-IONIZING"], slowmo: "6.66\(sup)\u{00B9}\u{2074}\u{00D7} slower", "prism")
    rows(
      xray,
      [
        ["\u{03BB} wavelength", "20.7 pm", "483932636 cm\u{207B}\u{00B9}", "#8FD3FF"],
        ["f frequency", "1.45\(sup)\u{00B9}\u{2079} Hz", "period 6.89\(sup)\u{207B}\u{00B2}\u{2070} s", "#59f0b0"],
        ["E photon", "60.0 keV", "1.38\(sup)\u{2076} kcal/mol", "#ffbf5e"],
        ["B\u{2080} field", "8.01\(sup)\u{207B}\u{2076} T", "E\u{2080} 1.00\(sup)\u{00B3} V/m", "#ff5c7a"],
        ["Intensity", "3.19\(sup)\u{00B3} W/m\u{00B2}", "3.31\(sup)\u{00B9}\u{00B3} photons/cm\u{00B2}\u{00B7}s", "#e8f1ec"],
        ["n medium", "no data", "outside model range", "#ffbf5e"],
      ], status: ["Hard \u{2192} soft X-ray", "IONIZING"], slowmo: "1.45\(sup)\u{00B9}\u{2079}\u{00D7} slower", "xray in diamond")
    rows(
      oven,
      [
        ["\u{03BB} wavelength", "12.2 cm", "1.39 cm in water", "#5FD3BC"],
        ["f frequency", "2.45 GHz", "period 4.08\(sup)\u{207B}\u{00B9}\u{2070} s", "#59f0b0"],
        ["E photon", "10.1 \u{00B5}eV", "2.34\(sup)\u{207B}\u{2074} kcal/mol", "#ffbf5e"],
        ["B\u{2080} field", "1.47\(sup)\u{207B}\u{2074} T", "E\u{2080} 5.00\(sup)\u{00B3} V/m", "#ff5c7a"],
        ["Intensity", "2.92\(sup)\u{2075} W/m\u{00B2}", "1.80\(sup)\u{00B2}\u{2075} photons/cm\u{00B2}\u{00B7}s", "#e8f1ec"],
        ["n medium", "8.8014", "speed 0.114 c", "#ffbf5e"],
      ], status: ["UHF", "NON-IONIZING"], slowmo: "2.45\(sup)\u{2079}\u{00D7} slower", "oven in water")

    c.label = "tuner"
    let phrases: [(Double, String)] = [
      (5.5e-7, "1.1\u{00D7} the width of E. coli"), (1e-13, "10\u{00D7} an atomic nucleus"),
      (3.3e-14, "3.3\u{00D7} an atomic nucleus"), (2e-10, "2.0\u{00D7} an atom"), (7e-7, "1.4\u{00D7} the width of E. coli"),
      (0.01, "1/1.2 of a bee"), (50, "1/2.0 of a football field"), (1000, "10\u{00D7} a football field"),
    ]
    for (l, p) in phrases {
      c.text(SpectrumDisplay.comparisonPhrase(l), .string("One wave \u{2248} " + p), "comparisonPhrase(\(l))")
    }
    let decades = [
      "100 fm", "1 pm", "10 pm", "100 pm", "1 nm", "10 nm", "100 nm", "1 \u{00B5}m", "10 \u{00B5}m", "100 \u{00B5}m", "1 mm",
      "1 cm", "10 cm", "1 m", "10 m", "100 m", "1 km", "10 km", "100 km", "1000 km", "10000 km", "100000 km",
    ]
    for (i, label) in decades.enumerated() {
      c.text(SpectrumDisplay.decadeLabel(i - 13), .string(label), "decadeLabel(\(i - 13))")
    }
    for (lg, t) in [(-5.0, 289.7771955), (-7, 28977.71955), (-2, 1), (3, 1), (-13, 1e8)] {
      c.number(SpectrumDisplay.thermalTemperature(atLog: lg), .number(t), .tight, "thermalTemperature(\(lg))")
    }

    c.label = "lab"
    let axis: [(SampleKey, [String])] = [
      (.hydrogen, ["90.0 nm", "160 nm", "430 nm", "656 nm", "2.70 \u{00B5}m"]),
      (.co2, ["4000 cm\u{207B}\u{00B9}", "3392 cm\u{207B}\u{00B9}", "2344 cm\u{207B}\u{00B9}", "1898 cm\u{207B}\u{00B9}", "400 cm\u{207B}\u{00B9}"]),
      (.water, ["4000 cm\u{207B}\u{00B9}", "3392 cm\u{207B}\u{00B9}", "2344 cm\u{207B}\u{00B9}", "1898 cm\u{207B}\u{00B9}", "400 cm\u{207B}\u{00B9}"]),
      (.chlorophyll, ["350 nm", "418 nm", "534 nm", "584 nm", "750 nm"]),
      (.nmr, ["4.50 ppm", "3.69 ppm", "2.29 ppm", "1.70 ppm", "-0.30 ppm"]),
    ]
    for (key, texts) in axis {
      for (u, text) in zip([0, 0.169, 0.46, 0.584, 1], texts) {
        c.text(SpectrumDisplay.labAxisText(key, x: key.axis.x(at: u)), .string(text), "labAxisText(\(key), \(u))")
      }
    }
    let maxima: [(SampleKey, SampleMode, Double)] = [
      (.hydrogen, .emission, 0.9948904079012868), (.hydrogen, .absorption, 0.993315024100175),
      (.co2, .ir, 0.9975434713755773), (.co2, .raman, 0.9861687498944525), (.water, .ir, 0.5222040737917063),
      (.chlorophyll, .a, 1.2458459536376407), (.chlorophyll, .b, 1.1365871749480556), (.nmr, .nmr400, 1),
      (.nmr, .nmr60, 1.0000000000000002),
    ]
    for (key, mode, m) in maxima {
      c.number(SpectrumDisplay.labMaximum(key, mode: mode), .number(m), .chained, "labMaximum(\(key), \(mode.rawValue))")
    }
    let names = ["Emission", "Absorption", "IR absorption", "Raman", "Chlorophyll a", "Chlorophyll b", "400 MHz", "60 MHz"]
    for (mode, name) in zip(SampleMode.allCases, names) { c.text(mode.name, .string(name), "\(mode.rawValue) name") }
    c.text(Samples.lineName(n1: 2, n2: 3), .string("H\u{03B1}"), "Hα")
    c.text(Samples.lineName(n1: 1, n2: 2), .string("Ly\u{03B1}"), "Lyα")
    c.that(Samples.lineName(n1: 4, n2: 9) == nil, "unnamed line")

    c.label = "decompose"
    for (n, dev) in [(1.0, 0.0), (1.5, 0.6489266067663639), (1.52, 0.6794286788345094), (2.4175, 2.0943951023931957), (2.5, 2.0943951023931957)] {
      c.number(SpectrumDisplay.prismDeviation(n: n), .number(dev), .tight, "prismDeviation(\(n))")
    }
    c.that(SpectrumDisplay.stemAxis(logFrequencies: []) == nil, "no stems, no axis")
    if let a = SpectrumDisplay.stemAxis(logFrequencies: [14.7]) {
      c.number(a.lowerBound, .number(14.5), .absolute(1e-12), "single stem lo")
      c.number(a.upperBound, .number(14.9), .absolute(1e-12), "single stem hi")
    }
    if let a = SpectrumDisplay.stemAxis(logFrequencies: [13, 15]) {
      c.number(a.lowerBound, .number(12.85), .absolute(1e-12), "two stems lo")
      c.number(a.upperBound, .number(15.15), .absolute(1e-12), "two stems hi")
    }
    let traj = SpectrumDisplay.probeTrajectory(WaveSource(theta: 0), a0: 2, mode: .both)
    c.count(traj.count, 901, "probe samples")
    c.count(SpectrumDisplay.probeIndex(t: 0, speed: 1, count: traj.count), 0, "probe index at t = 0")
    // η = π·κ·t; one full 3-cycle loop at t = 6/κ, half way at 3/κ.
    c.count(SpectrumDisplay.probeIndex(t: 3, speed: 1, count: traj.count), 450, "probe index half way")
    let eight = SpectrumDisplay.driftFrame(traj, thetaDeg: 0)
    c.number(eight.last?.x, .number(0), .absolute(1e-12), "drift frame closes (z)")
    c.number(SpectrumDisplay.polarizerProjection(ex: 1, ey: 0, alphaDeg: 60), .number(0.5), .absolute(1e-15), "projection")

    c.label = "decompose readouts"
    func check(_ got: [SpectrumDisplay.Readout], _ want: [[String]], _ what: String) {
      c.count(got.count, want.count, "\(what) rows")
      for (r, w) in zip(got, want) {
        c.text(r.key, .string(w[0]), "\(what) key")
        c.text(r.value, .string(w[1]), "\(what) \(r.key) value")
        c.text(r.sub, .string(w[2]), "\(what) \(r.key) sub")
      }
    }
    let e0 = "E\u{2080}", deg = "\u{00B0}"
    var circular = SpectraState()
    circular.apply(preset: "circular")
    var elliptical = SpectraState()
    elliptical.sources[0].theta = 30
    elliptical.sources[0].delta = 40
    elliptical.decompose.polarizer = 77
    var tilted = SpectraState()
    tilted.sources[0].theta = -20
    tilted.decompose.polarizer = 0
    let polarization: [(SpectraState, [[String]], String, String)] = [
      (SpectraState(), [["Ex\u{2080}", "0.00", "of \(e0)"], ["Ey\u{2080}", "1.00", "of \(e0)"], ["\u{03B4} lag", "0\(deg)", "linear"],
        ["Passes", "25%", "polarizer at 30\(deg)"], ["Ellipse", "90\(deg)", "no rotation"]],
        "Ex and Ey move in step, so the tip of E slides along a line at 90\(deg). Malus's law: 25% gets through.", "default"),
      // JS printed "8°" for the circular ellipse (orientation is noise); the port prints "—".
      (circular, [["Ex\u{2080}", "0.71", "of \(e0)"], ["Ey\u{2080}", "0.71", "of \(e0)"], ["\u{03B4} lag", "90\(deg)", "circular"],
        ["Passes", "50%", "polarizer at 30\(deg)"], ["Ellipse", "\u{2014}", "counter-clockwise"]],
        "Ey trails Ex by a quarter cycle, so the tip of E traces a circle. Every polarizer angle passes exactly half.", "circular"),
      (elliptical, [["Ex\u{2080}", "0.87", "of \(e0)"], ["Ey\u{2080}", "0.50", "of \(e0)"], ["\u{03B4} lag", "40\(deg)", "elliptical"],
        ["Passes", "42%", "polarizer at 77\(deg)"], ["Ellipse", "26\(deg)", "counter-clockwise"]],
        "Ey trails Ex by 40\(deg), so the tip of E traces an ellipse. How much passes depends on how the polarizer lines up with it.",
        "elliptical"),
      (tilted, [["Ex\u{2080}", "0.94", "of \(e0)"], ["Ey\u{2080}", "0.34", "of \(e0)"], ["\u{03B4} lag", "0\(deg)", "linear"],
        ["Passes", "88%", "polarizer at 0\(deg)"], ["Ellipse", "-20\(deg)", "no rotation"]],
        "Ex and Ey move in step, so the tip of E slides along a line at -20\(deg). Malus's law: 88% gets through.", "tilted"),
    ]
    for (state, want, note, name) in polarization {
      check(SpectrumDisplay.polarizationReadouts(state), want, "polarization \(name)")
      c.text(SpectrumDisplay.polarizationNote(state), .string(note), "polarization \(name) note")
    }
    var laser = SpectraState()
    laser.apply(preset: "laser")
    var weak = SpectraState()
    weak.decompose.a0 = 0.2
    weak.decompose.probeMode = .electric
    let probes: [(SpectraState, [[String]], String, String)] = [
      (laser, [["a\u{2080} shown", "2.00", "drift 50.0% of c"], ["\(e0) needed", "8.03\(sup)\u{00B9}\u{00B2} V/m", "at 800 nm"],
        ["Your source", "a\u{2080} 2.00\(sup)\u{2070}", "\(e0) 8.03\(sup)\u{00B9}\u{00B2} V/m"], ["Quiver", "255 nm", "your electron's swing"]],
        "Drift 50% c", "laser"),
      (SpectraState(), [["a\u{2080} shown", "1.50", "drift 36.0% of c"], ["\(e0) needed", "8.76\(sup)\u{00B9}\u{00B2} V/m", "at 550 nm"],
        ["Your source", "a\u{2080} 1.71\(sup)\u{207B}\u{00B9}\u{2070}", "\(e0) 1.00\(sup)\u{00B3} V/m"],
        ["Quiver", "0.0150 fm", "your electron's swing"]], "Drift 36% c", "default"),
      (weak, [["a\u{2080} shown", "0.200", "drift 0.990% of c"], ["\(e0) needed", "1.17\(sup)\u{00B9}\u{00B2} V/m", "at 550 nm"],
        ["Your source", "a\u{2080} 1.71\(sup)\u{207B}\u{00B9}\u{2070}", "\(e0) 1.00\(sup)\u{00B3} V/m"],
        ["Quiver", "0.0150 fm", "your electron's swing"]], "No drift", "weak, E only"),
    ]
    for (state, want, drift, name) in probes {
      check(SpectrumDisplay.probeReadouts(state), want, "probe \(name)")
      c.text(SpectrumDisplay.driftTag(state), .string(drift), "probe \(name) drift tag")
    }
    c.that(SpectrumDisplay.probeNote(weak).hasPrefix("With the magnetic force switched off"), "probe note, E only")

    c.label = "feedback"
    for (f, p) in [(3e5, 109.56475905571956), (5.45e14, 545.1308809226366), (3e21, 1753.036144891513), (100e6, 169.64319079487348), (2128.87, 75.4995949301958)] {
      c.number(SpectrumDisplay.soundPitch(frequency: f), .number(p), .tight, "soundPitch(\(f))")
    }
    return c.report
  }

  // MARK: Robustness (edge inputs a UI, a Patch node or corrupted storage can produce)

  /// Inputs outside the web prototype's reach must not trap, and the few that used to (a
  /// negative trajectory step count, an out-of-range `active`, an empty source list) or lost
  /// data (a non-finite field in `serialized()`) are pinned here.
  static func robustness() -> ParityReport {
    var c = ParityCheck("robustness")
    c.report.cases = 1

    c.label = "trajectory"
    c.count(Wave.electronTrajectory(WaveSource(), a: 1, cycles: 1, steps: -1).count, 0, "negative steps → no points (JS)")
    c.count(Wave.electronTrajectory(WaveSource(), a: 1, cycles: 1, steps: 0).count, 1, "zero steps → the start point")

    c.label = "state"
    for (raw, index) in [(7, 2), (3, 2), (-3, 0)] {
      var s = SpectraState()
      s.active = raw
      s.edit(.lambda(600e-9))
      c.number(s.sources[index].lambda, .number(600e-9), .tight, "active \(raw) edits source \(index)")
      c.number(s.activeSource.lambda, .number(600e-9), .tight, "active \(raw) reads source \(index)")
    }
    var ext = SpectraState()
    ext.extendedRange = true
    ext.edit(.lambda(5e6))
    ext.extendedRange = false
    c.number(ext.sources[0].lambda, .number(1e3), .tight, "switching extendedRange off clamps 5,000 km back to 1 km")

    c.label = "serialization"
    var bad = SpectraState()
    bad.apply(preset: "prism")
    bad.speed = .infinity
    bad.scope.zoom = .nan
    bad.decompose.a0 = -.infinity
    let data = bad.serialized()
    c.that(!data.isEmpty, "a non-finite field no longer empties the whole serialization")
    let back = SpectraState.deserialize(data)
    c.number(back.speed, .number(1), .exact, "non-finite κ restores its default")
    c.number(back.scope.zoom, .number(1), .exact, "NaN zoom restores its default")
    c.number(back.decompose.a0, .number(1.5), .exact, "−∞ a₀ restores its default")
    c.that(back.sources == bad.sources && back.medium == .glass && back.preset == "prism", "everything else survives")
    // Key order of JSONEncoder output is not stable, so compare the parsed JSON objects.
    func json(_ d: Data?) -> NSDictionary? { d.flatMap { try? JSONSerialization.jsonObject(with: $0) as? NSDictionary } }
    var linked = SpectraState()
    linked.apply(preset: "laser")
    for st in [SpectraState(), linked] {
      let a = json(st.serialized()), b = json(try? JSONEncoder().encode(st))
      c.that(a != nil && a == b, "finite states serialize as a plain JSONEncoder does")
    }

    c.label = "display"
    let empty = FieldView.displaySources(sources: [], medium: .water)
    c.count(empty.list.count, 0, "no sources, nothing to draw")
    let p0 = FieldView.fieldAt(empty, z: 0.5, t: 1, speed: 1)
    c.that(p0.ex == 0 && p0.ey == 0, "no sources, zero field")
    var far = SpectraState()
    far.extendedRange = true
    far.edit(.lambda(1e8))
    far.speed = pow(10, SpectrumDisplay.speedLogRange.upperBound)
    c.text(SpectrumDisplay.slowMotionText(far), .string("1.33\u{00D7}10\u{2070}\u{00D7} faster"), "3 Hz at κ 3.98 runs faster than life")
    far.speed = 1
    c.text(SpectrumDisplay.slowMotionText(far), .string("3.00\u{00D7}10\u{2070}\u{00D7} slower"), "3 Hz at κ 1")
    far.edit(.lambda(140e3))
    c.text(SpectrumDisplay.statusLine(far).left, .string("ULF"), "status names the ITU band beyond 1 km")
    var kilometre = SpectraState()
    kilometre.edit(.lambda(1e3))
    c.text(SpectrumDisplay.statusLine(kilometre).left, .string(Spectrum.describe(kilometre.sources[0].lambda).sub), "1 km keeps the JS sub-band")

    c.label = "edge sweep"
    let edges: [Double] = [
      0, -0.0, -1, 5e-324, 1e-300, 6.2e-14, 1e-13, 1, 1e3, 1e8, 1e9, 1e300, .greatestFiniteMagnitude, .infinity, -.infinity, .nan,
    ]
    for x in edges {
      c.that(Spectrum.displayColorHex(x).count == 7, "displayColorHex(\(x)) is #rrggbb")
      let d = Spectrum.describe(x)
      c.that(!d.text.lambda.isEmpty && !d.text.f.isEmpty && !d.text.kcal.isEmpty, "describe(\(x)) prints")
      c.that(!Spectrum.rulerSubBand(at: x).isEmpty && !SpectrumDisplay.comparisonPhrase(x).isEmpty, "names at \(x)")
      for f in [0, 2, 40] { c.that(!JSFormat.toFixed(x, f).isEmpty && !JSFormat.toFixed(-x, f).isEmpty, "toFixed(\(x), \(f))") }
      c.that(!JSFormat.toPrecision(x, 3).isEmpty && !JSFormat.sci(x).isEmpty && !JSFormat.sig3(-x).isEmpty, "precision(\(x))")
      for key in SpecimenKey.allCases {
        c.that(!key.evaluate(x, source: WaveSource(e0: x), options: SpecimenOptions(lambda0: x, q: x)).response.text.isEmpty, "\(key)(\(x))")
      }
      for key in SampleKey.allCases {
        for mode in SampleMode.allCases {
          _ = key.value(x, mode: mode)
          _ = key.toLambda(x, mode: mode)
          c.that(!SpectrumDisplay.labAxisText(key, x: x).isEmpty, "\(key)/\(mode.rawValue) axis text at \(x)")
        }
      }
      let wild = WaveSource(kind: .thermal, lambda: x, e0: x, theta: x, delta: x, phi: x, cycles: x, temperature: x)
      for kind in WaveSource.Kind.allCases {
        var w = wild
        w.kind = kind
        let clean = w.sanitized(logRange: Spectrum.rulerLogRange)
        c.that(
          clean.lambda.isFinite && clean.lambda > 0 && clean.e0.isFinite && clean.delta.isFinite && clean.phi.isFinite,
          "sanitize(\(kind), \(x)) is finite")
        c.that(Wave.components(clean, count: 15).allSatisfy { $0.amp.isFinite && $0.lambda > 0 }, "components(\(kind), \(x))")
        _ = Wave.components(w, count: -4)
        _ = Wave.ellipse(w)
      }
      var s = SpectraState()
      s.link = true
      s.sources[2].enabled = true
      for e in [SpectraState.SourceEdit.lambda(x), .e0(x), .temperature(x), .theta(x), .delta(x), .phi(x), .cycles(x)] { s.edit(e) }
      c.that(s.sources.allSatisfy { $0.lambda.isFinite && $0.lambda > 0 && $0.e0.isFinite }, "linked edits by \(x) stay finite")
      let ds = FieldView.displaySources(s)
      let p = FieldView.fieldAt(ds, z: 0.25, t: 3, speed: 1)
      c.that(p.ex.isFinite && p.ey.isFinite, "fieldAt after edits by \(x)")
      s.decompose.a0 = x
      s.speed = x
      c.count(SpectrumDisplay.readouts(s).count, 5, "readouts with κ \(x)")
      c.count(SpectrumDisplay.probeReadouts(s).count, 4, "probe readouts with a₀ \(x)")
      c.that(!SpectrumDisplay.slowMotionText(s).isEmpty && !SpectrumDisplay.driftTag(s).isEmpty, "texts with κ \(x)")
      _ = SpectrumDisplay.probeIndex(t: x, speed: x, count: 901)
      _ = Wave.electronTrajectory(wild, a: x, cycles: 1, steps: 8)
      _ = Spectrum.crossedRulerDetents(fromLog: x, toLog: 0)
    }
    for t in ["", "null", "[]", "{}", "{\"sources\":[1,2,3]}", "{\"sources\":[null,null,null],\"active\":1e300}",
      "{\"sources\":[{\"lambda\":-5},{\"lambda\":0},{\"lambda\":\"x\"}],\"active\":-1e20,\"medium\":\"plasma\"}"]
    {
      let s = SpectraState.deserialize(t)
      c.that(
        s.sources.count == 3 && (0...2).contains(s.active) && s.sources.allSatisfy { $0.lambda.isFinite && $0.lambda > 0 },
        "deserialize(\(t)) is a usable state")
    }
    return c.report
  }
}
