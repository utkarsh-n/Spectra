// Exporter for the independent numpy cross-check of Spectra/Phase (verifier, 2026-10-08).
// Builds deterministic inputs, runs the Swift engine, writes inputs + outputs as JSON
// (17 significant digits) to argv[1].
import Foundation
import simd

var out: [String] = []
func num(_ x: Double) -> String {
  if x.isNaN { return "\"nan\"" }
  if x.isInfinite { return x > 0 ? "\"inf\"" : "\"-inf\"" }
  return String(format: "%.17g", x)
}
@MainActor func put(_ key: String, _ v: [Double]) { out.append("\"\(key)\": [" + v.map(num).joined(separator: ",") + "]") }
@MainActor func put(_ key: String, _ v: Double) { out.append("\"\(key)\": \(num(v))") }
@MainActor func put(_ key: String, _ v: Int) { out.append("\"\(key)\": \(v)") }
@MainActor func put(_ key: String, _ v: String) { out.append("\"\(key)\": \"\(v)\"") }
@MainActor func putF(_ key: String, _ v: [Float]) { put(key, v.map(Double.init)) }
@MainActor func putAxis(_ key: String, _ a: Phase.Axis) { put(key, [a.start, a.step, Double(a.count)]) }
@MainActor func putPlane(_ key: String, _ p: Phase.Plane) {
  put(key + ".values", p.values)
  putAxis(key + ".row", p.rowAxis)
  putAxis(key + ".col", p.columnAxis)
  put(key + ".rowMeasure", p.rowMeasure)
  put(key + ".colMeasure", p.columnMeasure)
  put(key + ".rowIndices", p.rowIndices.map(Double.init))
  put(key + ".kind", p.kind.rawValue)
}
@MainActor func putSignal(_ key: String, _ s: Phase.Signal) {
  put(key + ".re", s.re)
  put(key + ".im", s.im)
  put(key + ".step", s.step)
  put(key + ".origin", s.origin)
}

// Deterministic pseudo-random numbers (SplitMix64).
struct Rng {
  var s: UInt64
  mutating func next() -> Double {
    s &+= 0x9E37_79B9_7F4A_7C15
    var z = s
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return Double((z ^ (z >> 31)) >> 11) / Double(1 << 53) - 0.5
  }
}
var rng = Rng(s: 2026)

// A. 1-D time record (complex, random), non-unit step and non-zero origin.
let a = Phase.Signal(re: (0..<40).map { _ in rng.next() }, im: (0..<40).map { _ in rng.next() }, step: 0.37e-3, origin: 0.0123)
putSignal("A", a)
putPlane("A.W", Phase.wigner(a))
putPlane("A.Wc", Phase.wigner(a, options: Phase.WignerOptions(band: .centered)))
putPlane("A.W64", Phase.wigner(a, options: Phase.WignerOptions(bins: 64)))
putPlane("A.W16", Phase.wigner(a, options: Phase.WignerOptions(bins: 16)))  // M < N: lag rule cuts
putPlane("A.PW", Phase.wigner(a, options: Phase.WignerOptions(bins: 32, lag: .hann(halfWidth: 9), rows: .stride(3))))
putPlane(
  "A.SPW",
  Phase.wigner(a, options: Phase.WignerOptions(bins: 32, lag: .gaussian(halfWidth: 7, sigma: 3), smoothing: .hann(halfWidth: 3))))
putPlane("A.SG", Phase.spectrogram(a, window: .hann(length: 11), bins: 24))
putPlane("A.SGc", Phase.spectrogram(a, window: .gaussian(length: 12, sigma: 2.5), bins: 24, rows: .count(7), band: .centered))
let specA = Phase.spectrum(a, bins: 40, band: .positive)
put("A.spec.power", specA.power)
put("A.spec.aliased", specA.aliased)
let specAc = Phase.spectrum(a, bins: 16, band: .centered)
put("A.specc16.power", specAc.power)
put("A.specc16.aliased", specAc.aliased)

// B. 1-D space record, odd length.
let b = Phase.Signal(re: (0..<33).map { _ in rng.next() }, im: (0..<33).map { _ in rng.next() }, step: 0.21, origin: -1.3, domain: .space)
putSignal("B", b)
putPlane("B.W", Phase.wigner(b))
putPlane("B.Wp", Phase.wigner(b, options: Phase.WignerOptions(band: .positive)))
let specB = Phase.spectrum(b, bins: 40, band: .centered)
put("B.spec.power", specB.power)
put("B.spec.aliased", specB.aliased)

// C. analytic signal and oversampling.
let realC = (0..<50).map { _ in rng.next() }
put("C.x", realC)
putSignal("C.at", Phase.Signal.analytic(real: realC, step: 1e-3, origin: 0.5))
putSignal("C.as", Phase.Signal.analytic(real: realC, step: 0.1, domain: .space))
putSignal("C.atc", Phase.Signal.analytic(real: realC, step: 1e-3, padding: .circular))
let cz = Phase.Signal(re: (0..<30).map { _ in rng.next() }, im: (0..<30).map { _ in rng.next() }, step: 0.5, origin: 1)
putSignal("C.z", cz)
putSignal("C.up", cz.oversampled2x())
putSignal("C.upc", cz.oversampled2x(padding: .circular))
let iqI: [Float] = (0..<16).map { Float(cos(2 * Double.pi * 3 * Double($0) / 16)) }
let iqQ: [Float] = (0..<16).map { Float(sin(2 * Double.pi * 3 * Double($0) / 16)) }
putSignal("C.iq", Phase.Signal.fromIQ(i: iqI, q: iqQ, sampleRate: 16))

// D. 2-D field.
let xA = Phase.Axis(start: -2, step: 0.3, count: 13)
let tA = Phase.Axis(start: 0.7, step: 0.05, count: 11)
let fre = (0..<(13 * 11)).map { _ in rng.next() }
let fim = (0..<(13 * 11)).map { _ in rng.next() }
let field = Phase.Field(re: fre, im: fim, x: xA, t: tA)
put("D.re", fre)
put("D.im", fim)
putAxis("D.x", xA)
putAxis("D.t", tA)
@MainActor func putST(_ key: String, _ w: Phase.SpacetimeWigner) {
  putAxis(key + ".k", w.kAxis)
  putAxis(key + ".nu", w.nuAxis)
  put(key + ".kMeasure", w.kMeasure)
  put(key + ".nuMeasure", w.nuMeasure)
  put(key + ".m1", w.m1)
  put(key + ".m2", w.m2)
  put(key + ".total", w.total)
  put(key + ".kInt", w.kIntegrated.values)
  put(key + ".nuInt", w.nuIntegrated.values)
  if let f = w.full { putF(key + ".full", f) }
  if let s = w.kSlice { put(key + ".slice", s.values) }
  put(key + ".sliceIndex", w.kSliceIndex ?? -1)
  put(key + ".min", w.minValue)
  put(key + ".max", w.maxValue)
  put(key + ".argMin", w.argMin.map(Double.init))
  put(key + ".argMax", w.argMax.map(Double.init))
  put(key + ".exact", w.exactM2 ? 1 : 0)
}
let st = Phase.spacetimeWigner(field, options: Phase.SpacetimeOptions(keepFull: true, kSlice: 1.7))
putST("D.st", st)
let rep = Phase.marginalReport(st, field: field)
put("D.rep", [rep.m1Error, rep.m2IdentityError, rep.m2Error, rep.aliasLevel, rep.parsevalError, rep.spectralParsevalError, rep.energy])
put("D.rep.status", rep.status.badge)
let fs = Phase.spectrum(field, kBins: st.nk, nuBins: st.nnu, kBand: .centered, nuBand: .positive)
put("D.spec.power", fs.power.values)
put("D.spec.aliased", fs.aliased)
let st2 = Phase.spacetimeWigner(field, options: Phase.SpacetimeOptions(kBins: 32, nuBins: 24, kBand: .positive, nuBand: .centered, keepFull: true))
putST("D.st2", st2)
let st3 = Phase.spacetimeWigner(
  field, options: Phase.SpacetimeOptions(lagX: .hann(halfWidth: 3), lagT: .rectangular(halfWidth: 2), keepFull: true))
putST("D.st3", st3)
let st4 = Phase.spacetimeWigner(field, options: Phase.SpacetimeOptions(kBins: 8, nuBins: 6, keepFull: true))  // M < N
putST("D.st4", st4)
let rep4 = Phase.marginalReport(st4, field: field)
put("D.rep4", [rep4.m1Error, rep4.m2IdentityError, rep4.m2Error, rep4.aliasLevel, rep4.parsevalError, rep4.spectralParsevalError, rep4.energy])
put("D.rep4.status", rep4.status.badge)
let rep3 = Phase.marginalReport(st3, field: field)
put("D.rep3.status", rep3.status.badge)

// E. Apertures.
let arr = Phase.Aperture.uniformArray(elements: 5, spacing: 0.7, steerFromBroadsideDeg: 20, wavelength: 2.0, samplesPerElement: 4)
putSignal("E.arr", arr.current)
let arrW = arr.wigner()
putPlane("E.arrW", arrW)
let angles = stride(from: -89.0, through: 89.0, by: 2.5).map { $0 }
put("E.angles", angles)
put("E.arrFF", arr.farField(from: arrW, anglesDeg: angles).map(\.power))
let cont = Phase.Aperture.continuous(width: 3, illumination: .cosine, steerFromBroadsideDeg: -10, wavelength: 1.5, samplesPerWavelength: 6)
putSignal("E.cont", cont.current)
let contW = cont.wigner()
putPlane("E.contW", contW)
put("E.contFF", cont.farField(from: contW, anglesDeg: angles).map(\.power))
let ffc = cont.farField(from: contW)
put("E.contFFcols.theta", ffc.map(\.thetaDeg))
put("E.contFFcols.power", ffc.map(\.power))
let wArr = Phase.Aperture.uniformArray(elements: 6, spacing: 0.5, weights: [0.2, 0.7, 1, 1, 0.7, 0.2])
putSignal("E.warr", wArr.current)

// F. Fresnel.
let k0 = 2 * Double.pi
let beam = Phase.Signal(count: 128, step: 0.25, origin: -16, domain: .space) { x in
  let env = exp(-(x + 2) * (x + 2) / (4 * 2.0))
  return SIMD2(env * cos(0.3 * x), env * sin(0.3 * x))
}
putSignal("F.beam", beam)
let w0 = Phase.wigner(beam)
putPlane("F.W0", w0)
putPlane("F.shear", Phase.fresnelShear(w0, distance: 7, wavenumber: k0))
putPlane("F.shearNeg", Phase.fresnelShear(w0, distance: -5, wavenumber: k0))
putPlane(
  "F.shearCubic",
  Phase.fresnelShear(w0, distance: 7, wavenumber: k0, rowAxis: Phase.Axis(start: -20, step: 0.2, count: 200), interpolation: .cubic))
putPlane("F.shearAS", Phase.fresnelShear(w0, distance: 7, wavenumber: k0, model: .angularSpectrum))
putSignal("F.prop", Phase.fresnelPropagate(beam, distance: 7, wavenumber: k0))
putSignal("F.propAS", Phase.fresnelPropagate(beam, distance: 7, wavenumber: k0, model: .angularSpectrum))

// G. Packet fields.
let units = Phase.DisplayUnits(referenceFrequency: 3e14)
let pm = Phase.ShellModel(.plasma(plasmaFrequency: 2e14), units: units)
let pk = [
  Phase.GaussianPacket(carrierFrequency: 1, width: 1.5, chirp: 0.04, center: -3, direction: 1, amplitude: 1.2, phase: 0.4),
  Phase.GaussianPacket(carrierFrequency: 1.3, width: 2, chirp: 0, center: 4, direction: -1, amplitude: 0.8, phase: -1),
]
let gx = Phase.Axis(start: -10, step: 0.35, count: 40)
let gt = Phase.Axis(start: -2, step: 0.7, count: 9)
let pf = Phase.packetField(pk, model: pm, x: gx, t: gt)
put("G.re", pf.field.re)
put("G.im", pf.field.im)
putAxis("G.x", gx)
putAxis("G.t", gt)
put("G.dropped", pf.droppedFraction)
put("G.carriers", pf.carriers.map { $0 ?? .nan })
let gm = Phase.ShellModel(.medium(.glass), units: Phase.DisplayUnits(referenceWavelength: 600e-9))
let pg = [Phase.GaussianPacket(carrierFrequency: 1, width: 2.5, chirp: -0.02, center: 1)]
let pfg = Phase.packetField(pg, model: gm, x: gx, t: Phase.Axis(start: 0, step: 3, count: 5), gate: .gaussian(center: 6, sigma: 4))
put("G.glass.re", pfg.field.re)
put("G.glass.im", pfg.field.im)
put("G.glass.carrier", pfg.carriers.map { $0 ?? .nan })

// H. Dispersion numbers (SI).
let freqs = [9.1e6, 1.2e7, 3e7, 1e9]
for (name, d) in [
  ("plasma", Phase.Dispersion.plasma(plasmaFrequency: 9e6)), ("waveguide", .waveguide(cutoffFrequency: 6.557e9)),
] {
  let fq = name == "plasma" ? freqs : [6.6e9, 8e9, 1e10, 2e10]
  put("H.\(name).nu", fq)
  put("H.\(name).k", fq.map { d.wavenumber(frequency: $0) ?? .nan })
  put("H.\(name).vg", fq.map { d.groupVelocity(frequency: $0) ?? .nan })
  put("H.\(name).vp", fq.map { d.phaseVelocity(frequency: $0) ?? .nan })
  put("H.\(name).gvd", fq.map { d.taylor(atFrequency: $0)?.gvd ?? .nan })
  put("H.\(name).gvdm", fq.map { d.taylor(atFrequency: $0, direction: -1)?.gvd ?? .nan })
  put("H.\(name).vgm", fq.map { d.taylor(atFrequency: $0, direction: -1)?.groupVelocity ?? .nan })
}
let opt = [400e-9, 550e-9, 800e-9, 1.5e-6, 2e-6]
for m in [Matter.Medium.glass, .silica, .diamond, .water] {
  let d = Phase.Dispersion.medium(m)
  let nus = opt.map { SI.c / $0 }
  put("H.\(m.rawValue).nu", nus)
  put("H.\(m.rawValue).k", nus.map { d.wavenumber(frequency: $0) ?? .nan })
  put("H.\(m.rawValue).vg", nus.map { d.groupVelocity(frequency: $0) ?? .nan })
  put("H.\(m.rawValue).gvd", nus.map { d.taylor(atFrequency: $0)?.gvd ?? .nan })
  put("H.\(m.rawValue).omegaBack", nus.map { d.angularFrequency(wavenumber: d.wavenumber(frequency: $0)!) ?? .nan })
}
let tq = Phase.Dispersion.Taylor(k0: 3, omega0: 5, groupVelocity: -0.7, gvd: 0.4)
put("H.taylor.k", [4.0, 5.0, 6.0].map { Phase.Dispersion.taylor(tq).wavenumber(frequency: $0 / (2 * Double.pi)) ?? .nan })

// I. Scene.
let scene = Phase.phaseSpaceScene(
  Phase.PhaseSpaceRequest(
    packets: [
      Phase.GaussianPacket(carrierFrequency: 1, width: 1.5, center: -1), Phase.GaussianPacket(carrierFrequency: 1.4, width: 1.2, center: 1),
    ], dispersion: .vacuum, referenceFrequency: 5e14, gridSize: 24))
put("I.re", scene.field.re)
put("I.im", scene.field.im)
putAxis("I.x", scene.field.xAxis)
putAxis("I.t", scene.field.tAxis)
putST("I.st", scene.wigner)
put("I.status", scene.report.status.badge)
put("I.notes", scene.notes.joined(separator: " | "))

// J. Live time-frequency views.
let stream: [Float] = (0..<1000).map { j in
  let t = Double(j) / 8000
  return Float(cos(2 * Double.pi * (300 * t + 0.5 * 20_000 * t * t)) + 0.3 * sin(2 * Double.pi * 2500 * t))
}
putF("J.x", stream)
for mode in Phase.TimeFrequencyMode.allCases {
  let tf = Phase.timeFrequency(real: stream, sampleRate: 8000, request: Phase.TimeFrequencyRequest(mode: mode, rows: 50, columns: 64))
  putPlane("J.\(mode.rawValue)", tf.plane)
  put("J.\(mode.rawValue).spectrum", tf.spectrum)
  put("J.\(mode.rawValue).intensity", tf.intensity)
}

let json = "{\n" + out.joined(separator: ",\n") + "\n}\n"
try! json.write(toFile: CommandLine.arguments[1], atomically: true, encoding: .utf8)
print("wrote \(out.count) keys")
