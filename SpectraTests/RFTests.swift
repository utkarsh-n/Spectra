// RF engine oracles: every worked value of the verified reference (Docs/research/rf-physics.md
// with its [corrected in review] fixes, and the "Verified reference" in rf-physics-review.md),
// plus round trips and sanity checks of the simulator.
//
// This file is compiled twice:
//   - into SpectraTests, where RFTests runs one XCTest per oracle group;
//   - into the macOS harness (Tools/check-rf.sh, with -D SPECTRA_HARNESS) together with
//     Spectra/RF/**/*.swift and Tools/harness/rf/main.swift.
// So it must stay Foundation/Accelerate-only outside the XCTest section.
#if !SPECTRA_HARNESS
import XCTest
@testable import Spectra
#endif
import Accelerate
import Foundation
import simd

// MARK: - Check plumbing

/// One oracle comparison.
nonisolated struct RFCheckResult: Sendable {
  let group: String
  let name: String
  let passed: Bool
  let detail: String
}

/// Accumulates the checks of one group.
nonisolated struct RFCheckList: Sendable {
  let group: String
  private(set) var results: [RFCheckResult] = []

  init(_ group: String) { self.group = group }

  /// Passes when |actual − expected| ≤ max(abs, rel·|expected|). Default: 1e-9 relative
  /// (closed forms).
  mutating func close(_ name: String, _ actual: Double, _ expected: Double, abs a: Double = 0, rel r: Double = 1e-9) {
    let tol = max(a, r * Swift.abs(expected))
    let ok = actual.isFinite == expected.isFinite && (actual == expected || Swift.abs(actual - expected) <= tol)
    results.append(RFCheckResult(group: group, name: name, passed: ok,
                                 detail: String(format: "got %.10g, want %.10g ± %.3g", actual, expected, tol)))
  }

  /// A value printed with `decimals` decimals in the reference: half a unit in the last place.
  mutating func printed(_ name: String, _ actual: Double, _ expected: Double, decimals: Int) {
    close(name, actual, expected, abs: 0.5 * pow(10, -Double(decimals)) * (1 + 1e-9) + 1e-15, rel: 0)
  }

  /// A value printed with `digits` significant figures (e.g. 7.864 960e-2 → 7 digits).
  mutating func significant(_ name: String, _ actual: Double, _ expected: Double, digits: Int) {
    let exponent = floor(log10(Swift.abs(expected)))
    close(name, actual, expected, abs: 0.5 * pow(10, exponent - Double(digits - 1)) * (1 + 1e-9), rel: 0)
  }

  mutating func check(_ name: String, _ condition: Bool, _ detail: String = "") {
    results.append(RFCheckResult(group: group, name: name, passed: condition, detail: detail))
  }
}

// MARK: - Oracles

nonisolated enum RFOracles {
  /// Group names in run order.
  static let groups = [
    "constants", "antennas", "antenna-model", "arrays", "propagation", "atmosphere", "building", "fading",
    "noise", "error-rates", "analog", "numerology", "systems", "dsp", "modulation", "channel", "link", "robustness",
  ]

  static func run(_ group: String) -> [RFCheckResult] {
    switch group {
    case "constants": constants()
    case "antennas": antennas()
    case "antenna-model": antennaModel()
    case "arrays": arrays()
    case "propagation": propagation()
    case "atmosphere": atmosphere()
    case "building": building()
    case "fading": fading()
    case "noise": noise()
    case "error-rates": errorRates()
    case "analog": analog()
    case "numerology": numerology()
    case "systems": systems()
    case "dsp": dsp()
    case "modulation": modulation()
    case "channel": channel()
    case "link": link()
    case "robustness": robustness()
    default: [RFCheckResult(group: group, name: "unknown group", passed: false, detail: "")]
    }
  }

  static func runAll() -> [RFCheckResult] { groups.flatMap { run($0) } }

  private static let c = RF.Const.c
  private static let pi = Double.pi

  // MARK: Constants and units

  static func constants() -> [RFCheckResult] {
    var k = RFCheckList("constants")
    k.close("c", RF.Const.c, 299_792_458)
    k.close("k_B", RF.Const.kB, 1.380_649e-23)
    k.close("h", RF.Const.h, 6.626_070_15e-34)
    k.close("eta0", RF.Const.eta0, 376.730_313_412)
    k.printed("FSPL constant 20log10(4π/c)", RF.Const.fsplConstantDB, -147.552_2168, decimals: 7)
    k.printed("kT0 dBm/Hz", RF.Const.kT0dBmPerHz, -173.975_19, decimals: 5)
    k.printed("120π/η0 − 1 ≈ 0.069 %", (RF.Const.eta120pi / RF.Const.eta0 - 1) * 100, 0.069, decimals: 3)
    k.close("dB power 2 → 3.0103", RF.Units.dB(power: 2), 3.010_299_956_639_812)
    k.close("dB amplitude 2 → 6.0206", RF.Units.dB(amplitude: 2), 6.020_599_913_279_624)
    k.close("dBm 1 W", RF.Units.dBm(watts: 1), 30)
    k.close("watts 30 dBm", RF.Units.watts(dBm: 30), 1)
    k.significant("photon 2.4 GHz J", RF.Units.photonEnergyJ(frequency: 2.4e9), 1.5903e-24, digits: 5)
    k.significant("photon 2.4 GHz µeV", RF.Units.photonEnergyEV(frequency: 2.4e9) * 1e6, 9.926, digits: 4)
    k.printed("dBd → dBi offset", RF.Units.dBdToDBi, 2.1509, decimals: 4)
    k.printed("light time to a GPS satellite (ms)", RF.Units.lightTime(distance: 20_200e3) * 1e3, 67.4, decimals: 1)
    k.check("ITU band 2.45 GHz = UHF", RF.Units.ituBand(frequency: 2.45e9) == "UHF")
    k.check("ITU band 13.56 MHz = HF", RF.Units.ituBand(frequency: 13.56e6) == "HF")
    // V.431: upper band limits are inclusive, lower ones exclusive.
    k.check("ITU band 3 GHz = UHF (upper limit inclusive)", RF.Units.ituBand(frequency: 3e9) == "UHF", RF.Units.ituBand(frequency: 3e9) ?? "nil")
    k.check("ITU band 300 MHz = VHF", RF.Units.ituBand(frequency: 300e6) == "VHF")
    k.check("ITU band just above 3 GHz = SHF", RF.Units.ituBand(frequency: 3.000_001e9) == "SHF")
    k.check("ITU band 3 THz = THF, 3 Hz and NaN = nil",
            RF.Units.ituBand(frequency: 3e12) == "THF" && RF.Units.ituBand(frequency: 3) == nil && RF.Units.ituBand(frequency: .nan) == nil)
    k.check("format 2.45 GHz", RF.Units.format(frequency: 2.45e9) == "2.45 GHz", RF.Units.format(frequency: 2.45e9))
    k.check("format 13.56 MHz", RF.Units.format(frequency: 13.56e6) == "13.6 MHz", RF.Units.format(frequency: 13.56e6))
    k.check("format 20 200 km", RF.Units.format(distance: 20_200e3) == "20,200 km", RF.Units.format(distance: 20_200e3))
    k.check("format −40.2 dBm", RF.Units.format(dB: -40.2311, unit: "dBm") == "−40.2 dBm")
    k.check("format ∞ distance (no Int(∞) trap)", RF.Units.format(distance: .infinity) == "∞ km", RF.Units.format(distance: .infinity))
    k.check("format 10²⁵ m in light-years", RF.Units.format(distance: 1e25).hasSuffix(" ly"), RF.Units.format(distance: 1e25))
    k.check("format NaN frequency = —", RF.Units.format(frequency: .nan) == "—")
    // Special functions behind the antenna and diffraction formulas.
    k.printed("Cin(2π)", RF.Special.cin(2 * pi), 2.437_653, decimals: 6)
    k.close("Q(0) = ½", RF.Special.Q(0), 0.5)
    k.close("Φ⁻¹(0.975)", RF.Special.inverseNormalCDF(0.975), 1.959_963_984_540_054, rel: 1e-12)
    k.close("Φ⁻¹(Φ(−4.2))", RF.Special.inverseNormalCDF(RF.Special.normalCDF(-4.2)), -4.2, rel: 1e-10)
    let f1 = RF.Special.fresnel(1)
    k.close("Fresnel C(1)", f1.c, 0.779_893_400_376_823, rel: 1e-12)
    k.close("Fresnel S(1)", f1.s, 0.438_259_147_390_355, rel: 1e-12)
    let f3 = RF.Special.fresnel(3)
    k.close("Fresnel C(3) (continued fraction)", f3.c, 0.605_720_789_297_686, rel: 1e-11)
    k.close("Fresnel S(3)", f3.s, 0.496_312_998_967_377, rel: 1e-11)
    let s10 = RF.Special.sici(10)
    k.close("Si(10)", s10.si, 1.658_347_594_218_874, rel: 1e-12)
    k.close("Ci(10)", s10.ci, -0.045_456_433_004_455, rel: 1e-11)
    k.close("I0(1)", RF.Special.besselI0(1), 1.266_065_877_752_008, rel: 1e-13)
    k.close("I0(20)·e⁻²⁰ (asymptotic)", RF.Special.besselI0Scaled(20), 0.089_780_311_884_826_4, rel: 1e-9)
    return k.results
  }

  // MARK: Antenna formulas (rf-physics A, verified reference)

  static func antennas() -> [RFCheckResult] {
    var k = RFCheckList("antennas")
    let A = RF.Antennas.self
    // A.1 Hertzian dipole.
    k.significant("Hertzian 0.01λ R_r (η0)", A.hertzianRadiationResistance(lengthWavelengths: 0.01), 0.078_902, digits: 5)
    k.significant("Hertzian 0.01λ R_r (120π)", A.hertzianRadiationResistance(lengthWavelengths: 0.01, eta: RF.Const.eta120pi), 0.078_957, digits: 5)
    // The thin-dipole integral tends to the Hertzian D = 1.5 as L → 0.
    k.printed("D 1.5 = 1.76091 dBi (thin dipole at L → 0)", 10 * log10(A.ThinDipole(lengthWavelengths: 1e-4).directivity), 1.760_91, decimals: 5)
    // A.2 short dipole.
    k.printed("short dipole 0.1λ R_r", A.shortDipoleRadiationResistance(lengthWavelengths: 0.1), 1.973_92, decimals: 5)
    // A.3 thin dipole table: L, R_r, R_in, D, D dBi, HPBW (decimals as printed).
    let rows: [(L: Double, rr: Double, rin: Double?, d: Double, ddb: Double, hpbw: Double?)] = [
      (0.10, 0.191, 1.999, 1.5050, 1.775, 89.53), (0.25, 6.716, 13.431, 1.5318, 1.852, 87.04),
      (0.50, 73.079, 73.079, 1.6409, 2.151, 78.08), (0.75, 185.68, 371.36, 1.8821, 2.746, 64.01),
      (1.00, 198.95, nil, 2.4110, 3.822, 47.84), (1.25, 106.46, 212.93, 3.2825, 5.162, 32.61),
      (1.50, 105.42, 105.42, 2.2263, 3.476, nil),
    ]
    for r in rows {
      let d = A.ThinDipole(lengthWavelengths: r.L)
      let tag = String(format: "dipole %.2fλ", r.L)
      let rrDecimals = r.rr < 1 ? 3 : (r.rr < 100 ? 3 : 2)
      k.printed("\(tag) R_r", d.radiationResistance(), r.rr, decimals: r.L == 0.25 || r.L == 0.5 ? 3 : rrDecimals)
      if let rin = r.rin {
        k.printed("\(tag) R_in", d.inputResistance(), rin, decimals: r.L >= 0.75 ? 2 : 3)
      } else {
        k.check("\(tag) R_in = ∞ (thin wire)", d.inputResistance().isInfinite)
      }
      k.printed("\(tag) D", d.directivity, r.d, decimals: 4)
      k.printed("\(tag) D dBi", 10 * log10(d.directivity), r.ddb, decimals: 3)
      if let hp = r.hpbw { k.printed("\(tag) HPBW", d.hpbwDeg ?? .nan, hp, decimals: 2) }
    }
    let half = A.ThinDipole(lengthWavelengths: 0.5)
    k.printed("λ/2 radiation integral 𝓘 = Cin(2π)/2", half.radiationIntegral, 1.218_827, decimals: 6)
    k.printed("λ/2 R_r = η0·Cin(2π)/4π", RF.Const.eta0 * RF.Special.cin(2 * pi) / (4 * pi), 73.079, decimals: 3)
    k.printed("λ/2 R_r (120π)", half.radiationResistance(eta: RF.Const.eta120pi), 73.130, decimals: 3)
    k.printed("λ/2 D = 4/Cin(2π)", 4 / RF.Special.cin(2 * pi), 1.6409, decimals: 4)
    k.close("λ/2 reactance +j42.5", A.halfWaveDipoleReactance, 42.5)
    k.printed("1.5λ lobe at 42.56°", A.ThinDipole(lengthWavelengths: 1.5).thetaMaxDeg, 42.56, decimals: 2)
    k.check("main lobe at broadside for L = 1.44λ", A.ThinDipole(lengthWavelengths: 1.44).thetaMaxDeg == 90)
    k.check("main lobe leaves broadside by L = 1.45λ", A.ThinDipole(lengthWavelengths: 1.45).thetaMaxDeg < 89)
    let aeHalf = A.effectiveAperture(gain: half.directivity, wavelength: c / 1e9)
    k.printed("λ/2 A_e at 1 GHz (m²)", aeHalf, 0.011_736, decimals: 6)
    k.printed("λ/2 A_e ≈ 0.13λ²", aeHalf / pow(c / 1e9, 2), 0.13, decimals: 2)
    // A.4 monopole.
    k.printed("λ/4 monopole R", half.radiationResistance() / 2, 36.540, decimals: 3)
    k.printed("λ/4 monopole D", 2 * half.directivity, 3.2818, decimals: 4)
    k.printed("λ/4 monopole dBi", 10 * log10(2 * half.directivity), 5.161, decimals: 3)
    k.check("λ/4 monopole Z = 36.5 + j21.25", A.quarterWaveMonopoleImpedance == RF.Complex(36.5, 21.25))
    // A.5 small loop.
    k.printed("loop constant (8/3)η0π³", A.smallLoopRadiationResistance(areaOverLambdaSquared: 1), 31_149.3, decimals: 1)
    k.printed("loop constant (120π) = 320π⁴", A.smallLoopRadiationResistance(areaOverLambdaSquared: 1, eta: RF.Const.eta120pi), 31_170.9, decimals: 1)
    let a = 0.02
    let areaOverL2 = pi * a * a
    k.significant("loop a = 0.02λ (η0)", A.smallLoopRadiationResistance(areaOverLambdaSquared: areaOverL2), 0.049_189, digits: 5)
    k.significant("loop a = 0.02λ (120π)", A.smallLoopRadiationResistance(areaOverLambdaSquared: areaOverL2, eta: RF.Const.eta120pi), 0.049_223, digits: 5)
    k.significant("loop 120π = 20π²(C/λ)⁴", A.smallLoopRadiationResistance(areaOverLambdaSquared: areaOverL2, eta: RF.Const.eta120pi), 20 * pi * pi * pow(2 * pi * a, 4), digits: 12)
    k.significant("NFC 40×30 mm N 4 at 13.56 MHz (120π)", A.smallLoopRadiationResistance(area: 1.2e-3, frequency: 13.56e6, turns: 4, eta: RF.Const.eta120pi), 3.006e-6, digits: 4)
    k.printed("NFC λ/2π (m)", A.smallAntennaBoundary(wavelength: c / 13.56e6), 3.519, decimals: 3)
    let amArea = pi * 0.005 * 0.005
    k.significant("AM bar air (120π)", A.smallLoopRadiationResistance(area: amArea, frequency: 1e6, turns: 60, eta: RF.Const.eta120pi), 8.57e-11, digits: 3)
    k.significant("AM bar ferrite μ 100", A.smallLoopRadiationResistance(area: amArea, frequency: 1e6, turns: 60, muEffective: 100, eta: RF.Const.eta120pi), 8.57e-7, digits: 3)
    // A.6 patch.
    let patches: [(er: Double, h: Double, f: Double, w: Double, ee: Double, dl: Double, l: Double)] = [
      (2.2, 1.588e-3, 10e9, 11.8503, 1.9715, 0.8110, 9.0534),
      (4.4, 1.6e-3, 2.45e9, 37.2343, 4.0809, 0.7386, 28.8093),
      (20, 4e-3, 1575.42e6, 29.3630, 16.3527, 1.5929, 20.3431),
    ]
    for p in patches {
      let d = A.PatchDesign(epsilonR: p.er, height: p.h, frequency: p.f)
      let tag = "patch ε_r \(p.er)"
      k.printed("\(tag) W mm", d.width * 1000, p.w, decimals: 4)
      k.printed("\(tag) ε_eff", d.epsilonEffective, p.ee, decimals: 4)
      k.printed("\(tag) ΔL mm", d.deltaL * 1000, p.dl, decimals: 4)
      k.printed("\(tag) L mm", d.length * 1000, p.l, decimals: 4)
    }
    // A.7 Yagi.
    k.printed("7.1 dBd = 9.25 dBi", RF.Units.dBi(fromDBd: 7.1), 9.25, decimals: 2)
    let nbs: [(Double, Int, Double)] = [(0.4, 3, 7.1), (0.8, 5, 9.2), (1.2, 6, 10.2), (2.2, 12, 12.25), (3.2, 17, 13.4), (4.2, 15, 14.2)]
    for (boom, n, g) in nbs {
      k.close("NBS boom \(boom)λ (\(n) el) dBd", A.yagiGainDBd(boomWavelengths: boom).gainDBd, g)
    }
    // A.8 helix.
    let hx = A.HelixEstimates(circumference: 1, turns: 10, spacing: 0.25)
    k.close("helix Kraus D", hx.krausDirectivity, 30)
    k.printed("helix Kraus dBi", 10 * log10(hx.krausDirectivity), 14.771, decimals: 3)
    k.printed("helix Kraus HPBW", hx.krausHPBWDeg, 32.888, decimals: 3)
    k.close("helix R_in 140 Ω", hx.inputResistance, 140)
    k.printed("helix AR", hx.axialRatio, 1.050, decimals: 3)
    k.close("helix S&T D", hx.stutzmanThieleDirectivity, 15.5)
    k.printed("helix S&T dBi", 10 * log10(hx.stutzmanThieleDirectivity), 11.903, decimals: 3)
    k.printed("helix S&T HPBW", hx.stutzmanThieleHPBWDeg, 41.110, decimals: 3)
    k.printed("helix Emerson dBi", hx.emersonGainDBi ?? .nan, 12.846, decimals: 3)
    k.printed("Kraus 10.79 = 10log10(12C²NS) at C = N = S = 1", 10 * log10(A.HelixEstimates(circumference: 1, turns: 1, spacing: 1).krausDirectivity), 10.79, decimals: 2)
    // A.9 horn, A.10 dish.
    let lambda10 = c / 10e9
    let horn = A.hornGain(apertureA: 0.10 / lambda10, apertureB: 0.08 / lambda10)
    k.printed("horn G", horn, 57.046, decimals: 3)
    k.printed("horn dBi", 10 * log10(horn), 17.562, decimals: 3)
    let lambda12 = c / 12e9
    let dishD = 0.6 / lambda12
    let dish = A.dishGain(diameter: dishD, efficiency: 0.65)
    k.printed("dish G", dish, 3700.30, decimals: 2)
    k.printed("dish dBi", 10 * log10(dish), 35.682, decimals: 3)
    k.printed("Airy half-power u", A.airyHalfPowerArgument, 1.616_34, decimals: 5)
    k.printed("uniform HPBW 1.0290 λ/D rad", 2 * A.airyHalfPowerArgument / pi, 1.0290, decimals: 4)
    k.printed("uniform HPBW 58.96° λ/D", 2 * A.airyHalfPowerArgument / pi * 180 / pi, 58.96, decimals: 2)
    k.printed("dish uniform HPBW", A.uniformApertureHPBWDeg(diameter: dishD), 2.4550, decimals: 4)
    k.printed("dish tapered HPBW 70λ/D", A.taperedDishHPBWDeg(diameter: dishD), 2.9146, decimals: 4)
    // A.12 planar arrays.
    k.printed("8×8 of 5 dBi", A.planarArrayGainDBi(elementGainDBi: 5, nx: 8, ny: 8), 23.06, decimals: 2)
    k.printed("1×4 of 5 dBi", A.planarArrayGainDBi(elementGainDBi: 5, nx: 1, ny: 4), 11.02, decimals: 2)
    k.printed("λ/2 at 28 GHz mm", RF.Units.wavelength(frequency: 28e9) / 2 * 1000, 5.3534, decimals: 4)
    k.printed("λ/2 at 39 GHz mm", RF.Units.wavelength(frequency: 39e9) / 2 * 1000, 3.8435, decimals: 4)
    k.printed("beamforming N 64", A.arrayGainDB(elements: 64), 18.06, decimals: 2)
    k.printed("beamforming N 256", A.arrayGainDB(elements: 256), 24.08, decimals: 2)
    // A.14 Friis, EIRP.
    k.printed("FSPL 2.45 GHz 10 m", RF.Propagation.fsplDB(distance: 10, frequency: 2.45e9), 60.2311, decimals: 4)
    k.printed("Friis P_r", RF.Propagation.friisReceivedPowerDBm(txPowerDBm: 20, txGainDBi: 0, rxGainDBi: 0, distance: 10, frequency: 2.45e9), -40.2311, decimals: 4)
    k.close("EIRP 23 + 5 − 1", A.eirpDBm(txPowerDBm: 23, gainDBi: 5, feedLossDB: 1), 27)
    // A.15 polarization.
    k.printed("PLF linear 45°", A.plfDB(A.linearPLF(mismatchDeg: 45)), -3.0103, decimals: 4)
    let z = SIMD3<Double>(0, 0, 1)
    let wave = RF.ReferencePolarization.vertical.vector(propagation: z)
    let rhcpWave = RF.ReferencePolarization.rhcp.vector(propagation: z)
    let rxCirc = RF.ReferencePolarization.rhcp.vector(propagation: -z)
    let rxLHCP = RF.ReferencePolarization.lhcp.vector(propagation: -z)
    k.printed("PLF linear → circular", 10 * log10(wave.plf(with: rxCirc)), -3.0103, decimals: 4)
    k.close("PLF RHCP → RHCP = 1", rhcpWave.plf(with: rxCirc), 1, abs: 1e-12)
    k.close("PLF RHCP → LHCP = 0", rhcpWave.plf(with: rxLHCP), 0, abs: 1e-12)
    k.close("PLF display clamp −40 dB", A.plfDB(0), -40)
    k.printed("PLF linear 80°", 10 * log10(A.linearPLF(mismatchDeg: 80)), -15.2066, decimals: 4)
    // gyre-integration §4.2 PLF rows.
    k.printed("PLF linear 30° (gyre §4.2)", 10 * log10(A.linearPLF(mismatchDeg: 30)), -1.249, decimals: 3)
    k.printed("PLF linear 60° (gyre §4.2)", 10 * log10(A.linearPLF(mismatchDeg: 60)), -6.021, decimals: 3)
    k.printed("PLF linear 89° (gyre §4.2)", 10 * log10(A.linearPLF(mismatchDeg: 89)), -35.163, decimals: 3)
    // A.16 mismatch.
    let mm: [(RF.Complex, Double, Double, Double, Double)] = [
      (RF.Complex(73), 0.186_99, 1.4600, 14.564, 0.1546), (RF.Complex(36.5), 0.156_07, 1.3699, 16.134, 0.1071),
      (RF.Complex(73, 42.5), 0.371_34, 2.1814, 8.605, 0.6444), (RF.Complex(100), 0.333_33, 2.0000, 9.542, 0.5115),
    ]
    for (zl, g, vswr, rl, ml) in mm {
      let m = RF.Mismatch(load: zl, reference: 50)
      let tag = "Z_L \(zl)"
      k.printed("\(tag) |Γ|", m.gammaMagnitude, g, decimals: 5)
      k.printed("\(tag) VSWR", m.vswr, vswr, decimals: 4)
      k.printed("\(tag) RL", m.returnLossDB, rl, decimals: 3)
      k.printed("\(tag) ML", m.mismatchLossDB, ml, decimals: 4)
    }
    k.close("36.5 Ω Γ is negative", RF.Mismatch(resistance: 36.5).gamma.re, -0.156_069_364_161_849_7, rel: 1e-12)
    let open = RF.Mismatch(load: RF.Complex(.infinity), resistiveOnly: true)
    k.check("infinite load (thin dipole at L = nλ): Γ = 1, VSWR ∞, RL 0 dB, ML ∞",
            open.gamma == RF.Complex.one && open.vswr.isInfinite && open.returnLossDB == 0 && open.mismatchLossDB.isInfinite)
    k.check("reactance raises |Γ| (resistive-only is a lower bound)",
            RF.Mismatch(load: RF.Complex(73, 42.5)).gammaMagnitude > RF.Mismatch(resistance: 73).gammaMagnitude)
    // A.17 field regions.
    k.printed("λ/2π at 2.4 GHz mm", A.smallAntennaBoundary(wavelength: c / 2.4e9) * 1000, 19.8806, decimals: 4)
    k.printed("dish 2D²/λ", A.farFieldBoundary(size: 0.6, wavelength: lambda12), 28.820, decimals: 3)
    k.printed("dish 0.62√(D³/λ)", A.reactiveNearFieldBoundary(size: 0.6, wavelength: lambda12), 1.823, decimals: 3)
    return k.results
  }

  // MARK: Pattern model (numerical integration over the sphere)

  static func antennaModel() -> [RFCheckResult] {
    var k = RFCheckList("antenna-model")
    func model(_ style: RF.AntennaStyle, frequency: Double = 2.45e9, _ edit: (inout RF.AntennaParameters) -> Void = { _ in }) -> RF.AntennaModel {
      var p = RF.AntennaParameters(style: style, frequency: frequency)
      edit(&p)
      return RF.AntennaModel(p)
    }
    // Dipole through the 3D pattern integral (same oracle values, ±1e-3 rel).
    for (L, d, hp) in [(0.5, 1.6409, 78.08), (1.0, 2.4110, 47.84), (1.25, 3.2825, 32.61)] {
      let m = model(.dipole) { $0.dipoleLength = L }
      k.printed("model dipole \(L)λ D", m.directivity, d, decimals: 4)
      k.printed("model dipole \(L)λ E-plane HPBW", m.ePlaneHPBWDeg ?? .nan, hp, decimals: 2)
      k.check("model dipole \(L)λ H-plane omni", m.hPlaneHPBWDeg == nil)
    }
    let d15 = model(.dipole) { $0.dipoleLength = 1.5 }
    k.printed("model dipole 1.5λ peak 42.56° from the wire", acos(abs(d15.peakDirection.z)) * 180 / pi, 42.56, decimals: 2)
    let mono = model(.monopole)
    k.printed("model monopole D", mono.directivity, 3.2818, decimals: 4)
    k.printed("model monopole dBi", mono.directivityDBi, 5.161, decimals: 3)
    k.check("model monopole Z 36.54 + j21.25", abs(mono.inputImpedance!.z.re - 36.540) < 5e-4 && mono.inputImpedance!.z.im == 21.25)
    k.close("model monopole nothing below ground", mono.field(SIMD3(0.6, 0, -0.8)), 0)
    let short = model(.shortDipole) { $0.shortDipoleLength = 0.1 }
    k.close("model short dipole D 1.5", short.directivity, 1.5, rel: 1e-6)
    k.printed("model short dipole HPBW 90°", short.ePlaneHPBWDeg ?? .nan, 90, decimals: 6)
    k.printed("model short dipole R_r", short.radiationResistance?.value ?? .nan, 1.973_92, decimals: 5)
    let loop = model(.smallLoop, frequency: 13.56e6)
    k.close("model loop D 1.5", loop.directivity, 1.5, rel: 1e-6)
    k.check("model loop field region λ/2π (electrically small)", loop.fieldRegions.isElectricallySmall && loop.fieldRegions.region(at: 0.04) == .reactiveNear)
    k.check("NFC coil at 2.45 GHz is flagged as not small", model(.smallLoop).notes.contains { $0.contains("C ≲ λ/10") })
    // Patch two-slot directivity (rf-physics A.6, full integral with L_e).
    for (er, h, f, dbi) in [(2.2, 1.588e-3, 10e9, 7.354), (4.4, 1.6e-3, 2.45e9, 6.085), (20.0, 4e-3, 1575.42e6, 5.102), (1.0001, 3e-3, 5.8e9, 9.343)] {
      let m = model(.patch, frequency: f) {
        $0.patchEpsilonR = er
        $0.patchHeight = h
      }
      k.close("model patch ε_r \(er) two-slot D", m.directivityDBi, dbi, abs: 0.01, rel: 0)
    }
    // ULA through the 3D model.
    let ula = model(.phasedArray)
    k.close("model ULA 8 λ/2 D", ula.directivity, 8, rel: 1e-6)
    k.printed("model ULA E-plane HPBW", ula.ePlaneHPBWDeg ?? .nan, 12.80, decimals: 2)
    let steered = model(.phasedArray) { $0.steerTheta = 30 }
    k.printed("model ULA steered 30° from broadside HPBW", steered.ePlaneHPBWDeg ?? .nan, 14.84, decimals: 2)
    k.close("model ULA steered peak", steered.peakDirection.x, 0.5, abs: 1e-6)
    let grating = model(.phasedArray) {
      $0.arraySpacing = 0.9
      $0.steerTheta = 30
    }
    k.check("model ULA d 0.9λ at 30° shows grating lobes", !grating.arrayGratingLobes.isEmpty)
    k.check("model ULA d 0.6λ at 30° has none", model(.phasedArray) { $0.arraySpacing = 0.6; $0.steerTheta = 30 }.arrayGratingLobes.isEmpty)
    for lobe in grating.arrayGratingLobes {
      k.close("grating lobe is full height", grating.field(lobe), 1, abs: 1e-9)
    }
    // Planar arrays of isotropic elements against the exact sum formula
    // D = N²/Σ_mn cos(k·r_mn·ŝ)·sinc(k|r_mn|), independent of the pattern integral.
    func isotropicPlanarDBi(_ n: Int, _ d: Double, _ steerDeg: Double) -> Double {
      let s = sin(steerDeg * pi / 180)
      var sum = 0.0
      for p in -(n - 1)...(n - 1) {
        for q in -(n - 1)...(n - 1) {
          let kr = 2 * pi * d * Double(p * p + q * q).squareRoot()
          sum += Double((n - abs(p)) * (n - abs(q))) * cos(2 * pi * d * Double(p) * s) * (kr == 0 ? 1 : sin(kr) / kr)
        }
      }
      return 10 * log10(pow(Double(n * n), 2) / sum)
    }
    for (n, d, st) in [(8, 0.5, 0.0), (16, 1.0, 45.0), (64, 2.0, 30.0)] {
      let m = model(.phasedArray, frequency: 28e9) {
        $0.arrayNx = n
        $0.arrayNy = n
        $0.arraySpacing = d
        $0.steerTheta = st
      }
      k.close("model \(n)×\(n) isotropic, d \(d)λ, steer \(st)°: D = exact sum", m.directivityDBi, isotropicPlanarDBi(n, d, st), abs: 0.001, rel: 0)
    }
    // Patch-element arrays against brute-force θ–φ / s–t midpoint integrations (numpy, ≥ 1.8·10⁷
    // points; RF review scratch scripts), normalized to the pattern's true maximum.
    func patchArray(_ n: Int, _ d: Double, _ steer: Double) -> RF.AntennaModel {
      model(.phasedArray, frequency: 28e9) {
        $0.arrayNx = n
        $0.arrayNy = n
        $0.arraySpacing = d
        $0.steerTheta = steer
        $0.arrayElement = .patch
      }
    }
    k.close("model 16×16 patch λ/2 steered 30°: D 28.4693 dBi", patchArray(16, 0.5, 30).directivityDBi, 28.4693, abs: 0.002, rel: 0)
    let grating16 = patchArray(16, 2, 30)
    k.close("model 16×16 patch 2λ steered 30°: D 30.5669 dBi at the true maximum", grating16.directivityDBi, 30.5669, abs: 0.002, rel: 0)
    k.check("… the maximum is the grating lobe at broadside, not the steered beam", grating16.peakDirection.z > 0.9999)
    let grating64 = patchArray(64, 2, 30)
    k.close("model 64×64 patch 2λ steered 30°: D 41.4376 dBi (was 15.6 with a sidelobe as peak)", grating64.directivityDBi, 41.4376, abs: 0.002, rel: 0)
    k.close("… toward the steered beam: 40.4330 dBi", grating64.directivityDBi(toward: SIMD3(0.5, 0, 0.75.squareRoot())), 40.4330, abs: 0.002, rel: 0)
    let horn = model(.horn, frequency: 10e9)
    k.close("model horn pattern D 19.7095 dBi (brute force)", horn.directivityDBi, 19.7095, abs: 0.002, rel: 0)
    // Aperture styles: the pattern integral against the closed forms.
    let dish = model(.dish, frequency: 12e9) { $0.dishDiameter = 0.6 / (c / 12e9) }
    k.printed("model dish gain = η(πD/λ)²", dish.gainDBi, 35.682, decimals: 3)
    k.close("model dish pattern HPBW ≈ uniform aperture", dish.ePlaneHPBWDeg ?? .nan, 2.4550, abs: 0.002)
    k.close("model dish pattern D ≈ (πD/λ)²", dish.directivityDBi, 10 * log10(pow(pi * 0.6 / (c / 12e9), 2)), abs: 0.05)
    k.printed("model horn gain", horn.gainDBi, 17.562, decimals: 3)
    k.close("model horn pattern D ≈ 0.81·4πAB/λ² (taper efficiency)", horn.directivityDBi, 10 * log10(8 / (pi * pi) * 4 * pi * 3.3356 * 2.6685), abs: 0.2)
    let helix = model(.helix)
    k.close("model helix pattern D = Kraus", helix.directivity, 30, rel: 1e-6)
    k.check("model helix is RHCP", helix.polarizationLossFactor(toward: SIMD3(0, 0, 1), receiver: .rhcp) > 0.99)
    k.check("model helix rejects LHCP", helix.polarizationLossFactor(toward: SIMD3(0, 0, 1), receiver: .lhcp) < 0.01)
    k.check("helix wound at 5.7° is flagged as outside Kraus's pitch", model(.helix) { $0.helixSpacing = 0.1 }.notes.contains { $0.contains("pitch") })
    k.check("default helix (14.0°) is not flagged", !helix.notes.contains { $0.contains("pitch") })
    let yagi = model(.yagi)
    k.printed("model Yagi gain = NBS table at 1.0λ boom", yagi.gainDBi, RF.Units.dBi(fromDBd: 9.2 + (10.2 - 9.2) * 0.5), decimals: 9)
    k.check("model Yagi beams forward", yagi.field(SIMD3(0, 0, 1)) > 0.999 && yagi.field(SIMD3(0, 0, -1)) < 0.5)
    let pifa = model(.pifa)
    k.printed("model PIFA gain = 1.5 × 0.55", pifa.gainDBi, 10 * log10(1.5 * 0.55), decimals: 6)
    // Every style builds, normalizes to 1 and has positive finite directivity.
    for style in RF.AntennaStyle.allCases {
      let m = model(style)
      k.check("\(style.rawValue) builds", m.directivity.isFinite && m.directivity >= 1, "D = \(m.directivity)")
      k.close("\(style.rawValue) peak |F| = 1", m.field(m.peakDirection), 1, abs: 1e-9)
      let mesh = RF.PatternMesh(model: m, rows: 31, columns: 48)
      k.check("\(style.rawValue) mesh", mesh.values.count == 31 * 48 && mesh.values.allSatisfy { $0 >= 0 && $0 <= 1 })
      let cut = m.cut(.e, count: 360)
      k.check("\(style.rawValue) E-cut peaks at 0°", abs(cut.values[180] - 1) < 1e-9)
    }
    // Polarization follows the wire.
    let dip = model(.dipole)
    let pv = dip.polarization(SIMD3(1, 0, 0))
    k.close("dipole polarization along z at broadside", abs(pv.re.z), 1, abs: 1e-12)
    k.close("dipole vs vertical reference PLF = 1", dip.polarizationLossFactor(toward: SIMD3(1, 0, 0), receiver: .vertical), 1, abs: 1e-12)
    k.close("dipole vs horizontal reference PLF = 0", dip.polarizationLossFactor(toward: SIMD3(1, 0, 0), receiver: .horizontal), 0, abs: 1e-12)
    k.close("mismatch: λ/2 dipole (73.08 + j42.5 Ω) VSWR on 50 Ω", dip.mismatch?.vswr ?? 0, 2.1814, abs: 1e-3)
    k.check("1λ dipole (R_in = ∞) reflects totally: VSWR ∞", model(.dipole) { $0.dipoleLength = 1 }.mismatch?.vswr.isInfinite == true)
    // gyre-integration §4.2 pose cases: λ/2 dipole along z, source on the horizon along +x.
    k.printed("λ/2 dipole F² 30° from the wire", 10 * log10(dip.power(SIMD3(sin(pi / 6), 0, cos(pi / 6)))), -7.5808, decimals: 4)
    let rolled = dip.linkFactor(attitude: simd_quatd(angle: pi / 3, axis: SIMD3(1, 0, 0)), toward: SIMD3(1, 0, 0), reference: .vertical)
    k.close("roll 60° about the line of sight: pattern 0 dB", rolled.patternDB, 0, abs: 1e-9)
    k.printed("roll 60°: polarization −6.02 dB", rolled.polarizationDB, -6.02, decimals: 2)
    let pitched = dip.linkFactor(attitude: simd_quatd(angle: pi / 3, axis: SIMD3(0, 1, 0)), toward: SIMD3(1, 0, 0), reference: .vertical)
    k.printed("pitch 60° toward the source: pattern −7.58 dB", pitched.patternDB, -7.58, decimals: 2)
    k.close("pitch 60°: polarization matched", pitched.polarizationDB, 0, abs: 1e-9)
    let st = RF.AntennaModel.steering(toward: SIMD3(0.5, 0, 0.8660254037844386))
    k.close("beam-lock steering θ", st.theta, 30, abs: 1e-9)
    // Aperture phase space (SPEC-features §3c): the transform of each source distribution over
    // the direction cosine u is the model's principal-plane factor (element and obliquity
    // factors divided out). `worst` is the largest normalized difference over u.
    func worst(_ dist: RF.ApertureDistribution?, _ us: [Double], reference: Double, _ modelFactor: (Double) -> Double) -> Double {
      guard let dist else { return .infinity }
      let f0 = dist.factor(directionCosine: reference).magnitude
      return us.map { abs(dist.factor(directionCosine: $0).magnitude / f0 - modelFactor($0)) }.max() ?? .infinity
    }
    let us = stride(from: -0.95, through: 0.95, by: 0.01).map { $0 }
    func w(_ u: Double, _ v: Double = 0) -> Double { (1 - u * u - v * v).squareRoot() }
    let arrE = model(.phasedArray, frequency: 28e9) { $0.arrayNx = 16; $0.arrayNy = 4; $0.arraySpacing = 0.6; $0.steerTheta = 25 }
    let u0 = sin(25 * pi / 180)
    k.check("aperture: array E (16 elements, steered 25°) transforms to AF_x",
            worst(arrE.apertureDistribution(plane: .e), us, reference: u0) { arrE.field(SIMD3($0, 0, w($0))) } < 1e-6)
    let arrH = model(.phasedArray, frequency: 28e9) { $0.arrayNx = 16; $0.arrayNy = 4; $0.arraySpacing = 0.6; $0.steerTheta = 25; $0.steerPhi = 90 }
    k.check("aperture: array H (4 elements, steered in y) transforms to AF_y",
            worst(arrH.apertureDistribution(plane: .h), us, reference: u0) { arrH.field(SIMD3(0, $0, w($0))) } < 1e-6)
    k.check("aperture: steering is a linear phase (|aₙ| = 1, phase step −kd·sin25°)", {
      guard let d = arrE.apertureDistribution() else { return false }
      let step = atan2(Double(d.samples.q[1] * d.samples.i[0] - d.samples.i[1] * d.samples.q[0]),
                       Double(d.samples.i[1] * d.samples.i[0] + d.samples.q[1] * d.samples.q[0]))
      return d.samples.magnitudes().allSatisfy { abs($0 - 1) < 1e-6 } && abs(step - remainder(-2 * pi * 0.6 * u0, 2 * pi)) < 1e-6
    }())
    k.check("aperture: horn E (uniform over B) transforms to sinc(πBu)",
            worst(horn.apertureDistribution(plane: .e), us, reference: 0) { horn.field(SIMD3($0, 0, w($0))) / ((1 + w($0)) / 2) } < 3e-3)
    k.check("aperture: horn H (TE₁₀ cosine over A) transforms to cos(πAu)/(1 − 4A²u²)",
            worst(horn.apertureDistribution(plane: .h), us, reference: 0) { horn.field(SIMD3(0, $0, w($0))) / ((1 + w($0)) / 2) } < 3e-3)
    let smallDish = model(.dish, frequency: 12e9) { $0.dishDiameter = 8 }
    k.check("aperture: dish projection √(R² − x²) transforms to the Airy factor",
            worst(smallDish.apertureDistribution(), us, reference: 0) { smallDish.field(SIMD3($0, 0, w($0))) / ((1 + w($0)) / 2) } < 5e-3)
    let patchModel = model(.patch)
    k.check("aperture: patch E (two slots L_e apart) transforms to cos(k L_e u/2)",
            worst(patchModel.apertureDistribution(plane: .e), us, reference: 0) { patchModel.field(SIMD3($0, 0, w($0))) } < 1e-9)
    k.check("aperture: patch H (uniform over W) transforms to sinc(k W u/2)",
            worst(patchModel.apertureDistribution(plane: .h), us, reference: 0) { patchModel.field(SIMD3(0, $0, w($0))) / w($0) } < 3e-3)
    let yagiModel = model(.yagi)
    k.check("aperture: Yagi boom (Hansen–Woodyard phase) transforms to the end-fire AF",
            worst(yagiModel.apertureDistribution(), us, reference: 1) { yagiModel.field(SIMD3(0, w($0), $0)) } < 1e-6)
    for L in [0.5, 1.25, 1.5] {
      let wire = model(.dipole) { $0.dipoleLength = L }
      let dist = wire.apertureDistribution()
      // field ∝ |F(u)|·sinθ with u = cosθ: fit the one scale factor, then compare everywhere
      // (nulls included).
      let grid = stride(from: -0.95, through: 0.95, by: 0.01).map { $0 }
      let g = grid.map { u in (dist?.factor(directionCosine: u).magnitude ?? .nan) * w(u) }
      let fieldValues = grid.map { u in wire.field(SIMD3(w(u), 0, u)) }
      let scale = zip(fieldValues, g).reduce(0.0) { $0 + $1.0 * $1.1 } / g.reduce(0.0) { $0 + $1 * $1 }
      let err = zip(fieldValues, g).map { abs($0 - scale * $1) }.max() ?? .infinity
      k.check("aperture: \(L)λ dipole current transforms to the thin-wire pattern / sinθ", err < 3e-3, String(format: "max error %.2e", err))
    }
    k.check("aperture: none for helix, loop, PIFA or a wire's H-plane",
            model(.helix).apertureDistribution() == nil && model(.smallLoop).apertureDistribution() == nil
              && model(.pifa).apertureDistribution() == nil && model(.dipole).apertureDistribution(plane: .h) == nil)
    return k.results
  }

  // MARK: Arrays (A.11)

  static func arrays() -> [RFCheckResult] {
    var k = RFCheckList("arrays")
    let Arr = RF.Arrays.self
    k.printed("ULA 8 λ/2 D (numeric)", Arr.directivity(elements: 8, spacing: 0.5, beta: 0), 8.000, decimals: 3)
    k.printed("ULA D dBi", 10 * log10(Arr.directivity(elements: 8, spacing: 0.5, beta: 0)), 9.031, decimals: 3)
    k.close("ULA D ≈ 2Nd/λ", Arr.broadsideDirectivityApprox(elements: 8, spacing: 0.5), 8)
    k.printed("ULA HPBW exact", Arr.hpbwDeg(elements: 8, spacing: 0.5, beta: 0) ?? .nan, 12.80, decimals: 2)
    k.printed("ULA HPBW approx", Arr.broadsideHPBWApproxDeg(elements: 8, spacing: 0.5), 12.71, decimals: 2)
    k.printed("ULA first sidelobe", Arr.highestSidelobeDB(elements: 8, spacing: 0.5, beta: 0) ?? .nan, -12.80, decimals: 2)
    k.printed("ULA AF_n(45°)", Arr.normalizedAF(theta: pi / 4, elements: 8, spacing: 0.5, beta: 0), 0.071_61, decimals: 5)
    let beta = Arr.steeringPhase(spacing: 0.5, steerTheta: pi / 3)
    k.printed("steer 60°: β", beta * 180 / pi, -90.000, decimals: 3)
    k.printed("steer 60°: peak", Arr.beamPeakDeg(elements: 8, spacing: 0.5, beta: beta), 60.000, decimals: 3)
    k.printed("steer 60°: HPBW", Arr.hpbwDeg(elements: 8, spacing: 0.5, beta: beta) ?? .nan, 14.84, decimals: 2)
    k.printed("grating-free at 60°", Arr.gratingFreeSpacing(steerTheta: pi / 3), 0.6667, decimals: 4)
    k.close("grating-free broadside = λ", Arr.gratingFreeSpacing(steerTheta: pi / 2), 1, abs: 1e-15)
    k.close("same limit from broadside", Arr.gratingFreeSpacing(steerFromBroadside: pi / 6), Arr.gratingFreeSpacing(steerTheta: pi / 3), rel: 1e-12)
    k.check("no grating lobes at d = 0.66λ, 60°", Arr.gratingLobes(spacing: 0.66, beta: Arr.steeringPhase(spacing: 0.66, steerTheta: pi / 3)).isEmpty)
    k.check("grating lobe at d = 0.7λ, 60°", !Arr.gratingLobes(spacing: 0.7, beta: Arr.steeringPhase(spacing: 0.7, steerTheta: pi / 3)).isEmpty)
    k.check("unscanned d = λ puts lobes on the axis", Arr.gratingLobes(spacing: 1.0, beta: 0).count == 2)
    k.close("AF_n(ψ = 0) = 1", Arr.normalizedAF(psi: 0, elements: 8), 1)
    k.close("ULA N 8 λ/2: tower at 60° sits in the second null", Arr.normalizedAF(theta: pi / 3, elements: 8, spacing: 0.5, beta: 0), 0, abs: 1e-12)
    let firstNull = RF.Numerics.bisect(70 * pi / 180, 80 * pi / 180) { Arr.normalizedAF(theta: $0, elements: 8, spacing: 0.5, beta: 0) } ?? .nan
    k.printed("first null at 75.52° (ψ = 2π/N), found on the AF", firstNull * 180 / pi, 75.52, decimals: 2)
    // Main beam outside visible space (|β| > kd): the peak is an interior sidelobe, not an end
    // point (the end-point rule gave D = 0.62 < 1). Independent numpy value (2·10⁶-point trapezoid).
    k.printed("ULA 8, d 0.1λ, β = π: D 1.679532 (beam not visible)", Arr.directivity(elements: 8, spacing: 0.1, beta: pi), 1.679_532, decimals: 6)
    k.check("ULA D ≥ 1 for any β", stride(from: -6.0, through: 6.0, by: 0.25).allSatisfy { Arr.directivity(elements: 5, spacing: 0.15, beta: $0) >= 1 - 1e-9 })
    k.close("AF zero at the first null", Arr.normalizedAF(theta: acos(0.25), elements: 8, spacing: 0.5, beta: 0), 0, abs: 1e-12)
    return k.results
  }

  // MARK: Propagation (B.1–B.6)

  static func propagation() -> [RFCheckResult] {
    var k = RFCheckList("propagation")
    let P = RF.Propagation.self
    k.printed("FSPL 1 km 1 GHz", P.fsplDB(distance: 1000, frequency: 1e9), 92.4478, decimals: 4)
    k.printed("P.525 rounded form", P.fsplP525RoundedDB(distanceKm: 1, frequencyMHz: 1000), 92.4, decimals: 1)
    k.printed("FSPL GPS 20 200 km L1", P.fsplDB(distance: 20_200e3, frequency: 1575.42e6), 182.5027, decimals: 4)
    k.close("free-space distance inverse", P.freeSpaceDistance(lossDB: 92.4478, frequency: 1e9), 1000, rel: 1e-5)
    k.printed("log-distance PL0 2.4 GHz 1 m", P.fsplDB(distance: 1, frequency: 2.4e9), 40.0520, decimals: 4)
    k.printed("log-distance n 3, 20 m", P.logDistanceDB(distance: 20, frequency: 2.4e9, exponent: 3), 79.0829, decimals: 4)
    k.close("log-distance inverse", P.logDistanceRange(lossDB: 79.082_9, referenceDistance: 1, referenceLossDB: P.fsplDB(distance: 1, frequency: 2.4e9), exponent: 3), 20, rel: 1e-5)
    k.close("RSSI → distance", P.distanceFromRSSI(rssiDBm: -80, rssiAt1mDBm: -60, exponent: 2), 10, rel: 1e-12)
    let office = P.LogDistanceEnvironment.all.first { $0.id == "officeHard" }!
    k.check("Andersen office n 3.0 σ 7.0", office.exponent == 3...3 && office.sigma == 7...7)
    let factory = P.LogDistanceEnvironment.all.first { $0.id == "factoryLOS" }!
    k.check("Andersen factory LOS σ 3.0–6.0 (corrected)", factory.sigma == 3...6 && factory.exponent == 1.6...2.0)
    k.printed("InH LOS 5.5 GHz 10 m", P.TR38901.indoorOfficeLOS.pathLossDB(distance3D: 10, frequencyGHz: 5.5), 64.5073, decimals: 4)
    k.printed("InH NLOS 5.5 GHz 10 m", P.TR38901.indoorOfficeNLOS.pathLossDB(distance3D: 10, frequencyGHz: 5.5), 74.0350, decimals: 4)
    k.printed("UMa NLOS 3.5 GHz 500 m", P.TR38901.urbanMacroNLOS.pathLossDB(distance3D: 500, frequencyGHz: 3.5), 124.2505, decimals: 4)
    k.printed("UMi NLOS 28 GHz 200 m", P.TR38901.urbanMicroNLOS.pathLossDB(distance3D: 200, frequencyGHz: 28), 134.7460, decimals: 4)
    k.printed("FSPL 28 GHz 200 m", P.fsplDB(distance: 200, frequency: 28e9), 107.412, decimals: 3)
    k.check("38.901 σ: 3 / 8.03 / 7.8 / 8.2 dB", P.TR38901.allCases.map(\.shadowSigmaDB) == [3, 8.03, 7.8, 8.2])
    let tr = P.TwoRay(txHeight: 30, rxHeight: 1.5, frequency: 900e6)
    k.printed("two-ray d_x", tr.crossoverDistance, 1697.63, decimals: 2)
    k.printed("two-ray d_c (last maximum)", tr.criticalDistance, 540.37, decimals: 2)
    k.printed("two-ray last null (exact)", tr.lastNull ?? .nan, 268.5, decimals: 1)
    k.printed("two-ray last null ≈ 2h_th_r/λ", tr.lastNullEstimate, 270.2, decimals: 1)
    k.printed("two-ray 1 km exact", tr.exactLossDB(distance: 1000), 88.0119, decimals: 4)
    k.printed("two-ray 1 km asymptote", tr.asymptoticLossDB(distance: 1000), 86.9357, decimals: 4)
    k.printed("two-ray 1 km FSPL", P.fsplDB(distance: 1000, frequency: 900e6), 91.5326, decimals: 4)
    k.printed("two-ray 10 km exact", tr.exactLossDB(distance: 10_000), 126.9463, decimals: 4)
    k.printed("two-ray 10 km asymptote", tr.asymptoticLossDB(distance: 10_000), 126.9357, decimals: 4)
    k.printed("two-ray 10 km FSPL", P.fsplDB(distance: 10_000, frequency: 900e6), 111.5326, decimals: 4)
    // d_c is the last maximum: the two rays add (field doubles, 6 dB below free space loss).
    k.close("d_c is constructive (Δφ = π)", tr.exactLossDB(distance: tr.criticalDistance) - P.fsplDB(distance: tr.criticalDistance, frequency: 900e6), -6.02, abs: 0.02)
    k.check("last null is deep", tr.exactLossDB(distance: tr.lastNull ?? 0) - P.fsplDB(distance: tr.lastNull ?? 1, frequency: 900e6) > 30)
    k.printed("Hata a(h_m)", P.hataMobileCorrection(frequencyMHz: 900, mobileHeight: 1.5, largeCity: false), 0.015_88, decimals: 5)
    k.printed("Hata small/medium", P.hataDB(frequencyMHz: 900, baseHeight: 30, mobileHeight: 1.5, distanceKm: 5, environment: .smallMediumCity), 151.0244, decimals: 4)
    k.printed("Hata large city", P.hataDB(frequencyMHz: 900, baseHeight: 30, mobileHeight: 1.5, distanceKm: 5, environment: .largeCity), 151.0412, decimals: 4)
    k.printed("Hata suburban", P.hataDB(frequencyMHz: 900, baseHeight: 30, mobileHeight: 1.5, distanceKm: 5, environment: .suburban), 141.0818, decimals: 4)
    k.printed("Hata open", P.hataDB(frequencyMHz: 900, baseHeight: 30, mobileHeight: 1.5, distanceKm: 5, environment: .open), 122.5180, decimals: 4)
    k.printed("COST-231 C_m 0", P.cost231DB(frequencyMHz: 1800, baseHeight: 30, mobileHeight: 1.5, distanceKm: 2, metropolitan: false), 146.8007, decimals: 4)
    k.printed("COST-231 C_m 3", P.cost231DB(frequencyMHz: 1800, baseHeight: 30, mobileHeight: 1.5, distanceKm: 2, metropolitan: true), 149.8007, decimals: 4)
    k.printed("knife J(0) approx", P.knifeEdgeLossApproxDB(nu: 0), 6.0329, decimals: 4)
    k.printed("knife J(0) exact", P.knifeEdgeLossExactDB(nu: 0), 6.0206, decimals: 4)
    let nu = P.knifeEdgeNu(height: 10, d1: 1000, d2: 1000, wavelength: c / 900e6)
    k.printed("knife ν", nu, 1.095_824, decimals: 6)
    k.printed("knife J approx", P.knifeEdgeLossApproxDB(nu: nu), 14.5298, decimals: 4)
    k.printed("knife J exact", P.knifeEdgeLossExactDB(nu: nu), 14.4762, decimals: 4)
    k.close("knife ν ≤ −0.78 → 0 dB", P.knifeEdgeLossApproxDB(nu: -1), 0)
    return k.results
  }

  // MARK: Atmosphere (B.7–B.8)

  static func atmosphere() -> [RFCheckResult] {
    var k = RFCheckList("atmosphere")
    let At = RF.Atmosphere.self
    k.check("P.676 tables: 44 O₂ + 35 H₂O lines", At.oxygenLines.count == 44 && At.waterVapourLines.count == 35)
    // Total-pressure convention (1013.25 hPa total, 15 °C, 7.5 g/m³), ±0.005 dB/km on top of the
    // printed rounding (the reference allows ±0.05 within one convention).
    let rows: [(f: Double, o: Double, w: Double, t: Double, decimals: Int)] = [
      (1, 0.0053, 0.0001, 0.0054, 4), (2.4, 0.0068, 0.0003, 0.0071, 4), (22.235, 0.0130, 0.1803, 0.1933, 4), (28, 0.0183, 0.0825, 0.1008, 4),
      (39, 0.0458, 0.0760, 0.1218, 4), (60, 14.502, 0.154, 14.656, 3), (64, 6.770, 0.174, 6.944, 3), (71, 0.237, 0.213, 0.450, 3),
      (118.75, 1.334, 0.610, 1.944, 3), (183.31, 0.013, 28.247, 28.260, 3),
    ]
    for r in rows {
      let g = At.gasSpecificAttenuation(frequencyGHz: r.f)
      // One unit in the last printed place (the reference itself allows ±0.05 dB/km).
      let tol = r.decimals == 4 ? 0.0001 : 0.001
      k.close("P.676 \(r.f) GHz oxygen", g.oxygen, r.o, abs: tol, rel: 0)
      k.close("P.676 \(r.f) GHz water", g.waterVapour, r.w, abs: tol, rel: 0)
      k.close("P.676 \(r.f) GHz total", g.oxygen + g.waterVapour, r.t, abs: tol, rel: 0)
    }
    k.printed("P.676 60 GHz total convention", At.gasAttenuationDBPerKm(frequencyGHz: 60), 14.656, decimals: 3)
    var dry = RF.Atmosphere.AirState.standard
    dry.convention = .dry
    k.printed("P.676 60 GHz dry convention", At.gasAttenuationDBPerKm(frequencyGHz: 60, air: dry), 14.778, decimals: 3)
    k.printed("vapour pressure e", RF.Atmosphere.AirState.standard.vapourPressure, 9.97, decimals: 2)
    k.printed("dry pressure", RF.Atmosphere.AirState.standard.dryPressure, 1003.28, decimals: 2)
    var peakF = 0.0
    var peakV = 0.0
    var f = 60.70
    while f <= 60.90 {
      let v = At.gasSpecificAttenuation(frequencyGHz: f).oxygen
      if v > peakV {
        peakV = v
        peakF = f
      }
      f += 0.001
    }
    k.printed("O₂ peak value", peakV, 14.906, decimals: 3)
    // gyre-integration §4.5 (835 hPa is total pressure, so dry p = 825.0 hPa).
    let denver = RF.Atmosphere.AirState(pressure: 835, temperatureC: 15, waterVapourDensity: 7.5, convention: .total)
    let g60 = At.gasSpecificAttenuation(frequencyGHz: 60, air: denver)
    let g28 = At.gasSpecificAttenuation(frequencyGHz: 28, air: denver)
    k.printed("P.676 60 GHz γ_o at 835 hPa", g60.oxygen, 12.270, decimals: 3)
    k.printed("P.676 60 GHz total at 835 hPa", g60.oxygen + g60.waterVapour, 12.401, decimals: 3)
    k.printed("P.676 28 GHz γ_o at 835 hPa", g28.oxygen, 0.0124, decimals: 4)
    k.printed("P.676 28 GHz total at 835 hPa", g28.oxygen + g28.waterVapour, 0.0845, decimals: 4)
    k.printed("O₂ peak frequency", peakF, 60.806, decimals: 3)
    // P.838-3 Table 5 rows from the coefficient regressions.
    let rain: [(Double, Double, Double, Double, Double)] = [
      (28, 0.2051, 0.9679, 0.1964, 0.9277), (39, 0.4215, 0.8743, 0.4058, 0.8486), (60, 0.8606, 0.7656, 0.8515, 0.7486),
    ]
    for (fr, kh, ah, kv, av) in rain {
      let co = At.rainCoefficients(frequencyGHz: fr)
      k.printed("P.838 \(fr) GHz k_H", co.kH, kh, decimals: 4)
      k.printed("P.838 \(fr) GHz α_H", co.alphaH, ah, decimals: 4)
      k.printed("P.838 \(fr) GHz k_V", co.kV, kv, decimals: 4)
      k.printed("P.838 \(fr) GHz α_V", co.alphaV, av, decimals: 4)
    }
    // Specific attenuation from the printed Table 5 coefficients (reference values) and from ours.
    // γ = kR^α from the printed Table 5 rows through `combined` (τ = 0 selects k_H, α_H).
    func tableGamma(_ kh: Double, _ ah: Double, _ kv: Double, _ av: Double, _ r: Double) -> Double {
      let h = RF.Atmosphere.RainCoefficients(kH: kh, alphaH: ah, kV: kv, alphaV: av).combined(elevationDeg: 0, tiltDeg: 0)
      return h.k * pow(r, h.alpha)
    }
    k.printed("rain 28 GHz 25 mm/h (table k, α)", tableGamma(0.2051, 0.9679, 0.1964, 0.9277, 25), 4.6241, decimals: 4)
    k.printed("rain 39 GHz 25 mm/h (table k, α)", tableGamma(0.4215, 0.8743, 0.4058, 0.8486, 25), 7.0310, decimals: 4)
    k.printed("rain 60 GHz 25 mm/h (table k, α)", tableGamma(0.8606, 0.7656, 0.8515, 0.7486, 25), 10.1173, decimals: 4)
    k.printed("rain 28 GHz 50 mm/h (table k, α)", tableGamma(0.2051, 0.9679, 0.1964, 0.9277, 50), 9.0448, decimals: 4)
    k.close("rain 28 GHz 25 mm/h (regression)", At.rainAttenuationDBPerKm(frequencyGHz: 28, rainRate: 25), 4.6241, abs: 0.002, rel: 0)
    k.close("rain 39 GHz 25 mm/h (regression)", At.rainAttenuationDBPerKm(frequencyGHz: 39, rainRate: 25), 7.0310, abs: 0.002, rel: 0)
    k.close("rain 60 GHz 25 mm/h (regression)", At.rainAttenuationDBPerKm(frequencyGHz: 60, rainRate: 25), 10.1173, abs: 0.002, rel: 0)
    k.close("rain 28 GHz 50 mm/h (regression)", At.rainAttenuationDBPerKm(frequencyGHz: 28, rainRate: 50), 9.0448, abs: 0.004, rel: 0)
    // P.838-3 is a 1–1000 GHz regression: outside it the coefficients are clamped (unclamped, 100 MHz
    // at 25 mm/h gave 21 dB/km and FM at 10 km in 100 mm/h rain 6800 dB).
    for f in [0.000146, 0.0136, 0.0981, 0.5] {
      let g = At.rainAttenuationDBPerKm(frequencyGHz: f, rainRate: 100)
      k.check("rain at \(f) GHz uses the 1 GHz coefficients (< 0.003 dB/km at 100 mm/h)",
              g == At.rainAttenuationDBPerKm(frequencyGHz: 1, rainRate: 100) && g < 0.003, String(format: "%.4g dB/km", g))
    }
    k.check("rain above 1000 GHz uses the 1000 GHz coefficients", At.rainCoefficients(frequencyGHz: 2000) == At.rainCoefficients(frequencyGHz: 1000))
    let co = At.rainCoefficients(frequencyGHz: 28)
    let vert = co.combined(elevationDeg: 0, tiltDeg: 90)
    k.close("P.838 τ = 90° gives the V coefficients", vert.k, co.kV, rel: 1e-12)
    k.close("P.838 τ = 90° α_V", vert.alpha, co.alphaV, rel: 1e-12)
    return k.results
  }

  // MARK: Building entry (B.9)

  static func building() -> [RFCheckResult] {
    var k = RFCheckList("building")
    let B = RF.Building.self
    let trad: [(Double, Double)] = [(0.7, 14.102), (3.5, 15.721), (28, 20.182), (60, 22.363)]
    let eff: [(Double, Double)] = [(0.7, 31.576), (3.5, 30.886), (28, 41.676), (60, 49.676)]
    for (f, v) in trad { k.printed("P.2109 traditional \(f) GHz", B.entryLossDB(frequencyGHz: f, building: .traditional), v, decimals: 3) }
    for (f, v) in eff { k.printed("P.2109 thermally efficient \(f) GHz", B.entryLossDB(frequencyGHz: f, building: .thermallyEfficient), v, decimals: 3) }
    k.check("P.2109 P = 0 and P = 1 stay finite (clamped to 10⁻⁶…1 − 10⁻⁶)",
            B.entryLossDB(frequencyGHz: 3.5, probability: 0, building: .traditional).isFinite && B.entryLossDB(frequencyGHz: 3.5, probability: 1, building: .traditional).isFinite)
    k.check("P.2109 loss grows with probability", B.entryLossDB(frequencyGHz: 3.5, probability: 0.9, building: .traditional) > B.entryLossDB(frequencyGHz: 3.5, building: .traditional))
    k.printed("O2I low-loss 3.5 GHz", B.O2IModel.lowLoss.wallLossDB(frequencyGHz: 3.5), 12.6975, decimals: 4)
    k.printed("O2I high-loss 3.5 GHz", B.O2IModel.highLoss.wallLossDB(frequencyGHz: 3.5), 27.4993, decimals: 4)
    k.printed("O2I low-loss 28 GHz", B.O2IModel.lowLoss.wallLossDB(frequencyGHz: 28), 17.8288, decimals: 4)
    k.printed("O2I high-loss 28 GHz", B.O2IModel.highLoss.wallLossDB(frequencyGHz: 28), 35.0290, decimals: 4)
    k.close("O2I σ low/high/A", B.O2IModel.lowLoss.sigmaDB + B.O2IModel.highLoss.sigmaDB + B.O2IModel.lowLossA.sigmaDB, 4.4 + 6.5 + 4.4)
    k.close("low-loss A uses plywood", B.O2IModel.lowLossA.wallLossDB(frequencyGHz: 3.5),
            5 - 10 * log10(0.3 * pow(10, -(2 + 0.2 * 3.5) / 10) + 0.7 * pow(10, -(1.03 + 0.17 * 3.5) / 10)))
    k.close("glass 2 + 0.2f", B.Material.glass.lossDB(frequencyGHz: 10), 4)
    k.close("IRR glass 25.4 + 0.11f (Rel-19)", B.Material.irrGlass.lossDB(frequencyGHz: 10), 26.5)
    k.close("concrete 5 + 4f", B.Material.concrete.lossDB(frequencyGHz: 10), 45)
    k.close("plywood 1.03 + 0.17f", B.Material.plywood.lossDB(frequencyGHz: 10), 2.73)
    k.close("wood 4.85 + 0.12f", B.Material.wood.lossDB(frequencyGHz: 10), 6.05)
    k.close("indoor 0.5 dB/m", B.indoorLossDB(indoorDistance: 10), 5)
    k.close("two concrete walls at 3.5 GHz", B.wallsLossDB([(.concrete, 2)], frequencyGHz: 3.5), 38)
    return k.results
  }

  // MARK: Fading (B.10–B.12)

  static func fading() -> [RFCheckResult] {
    var k = RFCheckList("fading")
    let F = RF.Fading.self
    k.significant("Rayleigh outage −10 dB", F.rayleighOutage(belowMeanDB: 10), 0.095_1626, digits: 6)
    k.significant("Rayleigh outage −20 dB", F.rayleighOutage(belowMeanDB: 20), 0.009_9502, digits: 5)
    k.significant("Rayleigh outage −30 dB", F.rayleighOutage(belowMeanDB: 30), 9.9950e-4, digits: 5)
    k.close("B_c,50 at 1 µs", F.coherenceBandwidth50(delaySpread: 1e-6), 200e3)
    k.close("B_c,90 at 1 µs", F.coherenceBandwidth90(delaySpread: 1e-6), 20e3)
    k.printed("B_c,50 at 363 ns (kHz)", F.coherenceBandwidth50(delaySpread: 363e-9) / 1e3, 551, decimals: 0)
    k.printed("f_m 30 m/s 3.5 GHz", F.maxDoppler(speed: 30, frequency: 3.5e9), 350.2423, decimals: 4)
    k.printed("T_c 0.423/f_m (ms)", F.coherenceTime(maxDoppler: F.maxDoppler(speed: 30, frequency: 3.5e9)) * 1000, 1.2077, decimals: 4)
    k.printed("T_c 9/16πf_m (ms)", F.coherenceTimeHalfCorrelation(maxDoppler: F.maxDoppler(speed: 30, frequency: 3.5e9)) * 1000, 0.5112, decimals: 4)
    k.printed("f_m 100 km/h 2 GHz", F.maxDoppler(speed: 100 / 3.6, frequency: 2e9), 185.313, decimals: 3)
    k.close("RMS delay spread two equal taps 1 µs apart", F.rmsDelaySpread(delays: [0, 1e-6], powers: [1, 1]), 0.5e-6, rel: 1e-12)
    k.check("frequency selective: 20 MHz over 100 ns", F.isFrequencySelective(bandwidth: 20e6, delaySpread: 100e-9))
    // pdfs integrate to 1.
    let ray = RF.Numerics.integrate(0, 10, panels: 40) { F.rayleighPDF($0, sigma: 1) }
    k.close("Rayleigh pdf integrates to 1", ray, 1, abs: 1e-9)
    let (s, sg) = F.ricianParameters(k: 10)
    let ric = RF.Numerics.integrate(0, 4, panels: 80) { F.ricianPDF($0, s: s, sigma: sg) }
    k.close("Rician K 10 pdf integrates to 1", ric, 1, abs: 1e-7)
    k.close("Rician unit power s² + 2σ² = 1", s * s + 2 * sg * sg, 1, rel: 1e-12)
    k.printed("Rayleigh power σ in dB, (10/ln10)·π/√6", F.rayleighDBStandardDeviation, 5.570, decimals: 3)
    var expRng = RF.SeededRandom(seed: 1)
    var m1 = 0.0
    var m2 = 0.0
    let samples = 1_000_000
    for _ in 0..<samples {
      let db = 10 * log10(-log(1 - expRng.uniform()))
      m1 += db
      m2 += db * db
    }
    let sd = (m2 / Double(samples) - pow(m1 / Double(samples), 2)).squareRoot()
    k.close("Rayleigh RSSI σ from 10⁶ exponential samples", sd, 5.570, abs: 0.03)
    let clarke = RF.Numerics.integrate(-1, 1, panels: 400) { F.clarkeSpectrum($0 * 0.999_999, maxDoppler: 1) }
    k.close("Clarke spectrum integrates to ≈ 1", clarke, 1, abs: 0.01)
    return k.results
  }

  // MARK: Noise and capacity (C.1–C.4)

  static func noise() -> [RFCheckResult] {
    var k = RFCheckList("noise")
    let N = RF.Noise.self
    k.printed("kT 290 K", N.densityDBmPerHz(), -173.975, decimals: 3)
    k.printed("kT 300 K", N.densityDBmPerHz(temperature: 300), -173.828, decimals: 3)
    k.printed("floor 20 MHz NF 7", N.floorDBm(bandwidth: 20e6, noiseFigureDB: 7), -93.9649, decimals: 4)
    k.printed("floor 1 MHz NF 0", N.floorDBm(bandwidth: 1e6), -113.9752, decimals: 4)
    k.printed("floor LTE 18 MHz NF 7", N.floorDBm(bandwidth: 18e6, noiseFigureDB: 7), -94.422, decimals: 3)
    k.printed("k = −228.6 dBW/K/Hz", N.densityDBmPerHz(temperature: 1) - 30, -228.6, decimals: 1)
    // A source colder than T₀ lowers only the source part of k(T + T_e)B (rf-physics C.2,
    // T_e = (F − 1)T₀); kTB·F would give −132.828 dBm here. Independent Python value.
    k.printed("cold sky 3 K, NF 1 dB, 1 MHz", N.floorDBm(bandwidth: 1e6, noiseFigureDB: 1, temperature: 3), -119.6733, decimals: 4)
    k.close("k(T + T_e)B = kT₀B·F at T₀", N.floorDBm(bandwidth: 20e6, noiseFigureDB: 7, temperature: RF.Const.T0), N.densityDBmPerHz() + 10 * log10(20e6) + 7, rel: 1e-12)
    k.printed("kTB 1 MHz", N.floorDBm(bandwidth: 1e6), -113.98, decimals: 2)
    k.printed("kTB 2 MHz", N.floorDBm(bandwidth: 2e6), -110.96, decimals: 2)
    k.printed("kTB 12.5 kHz", N.floorDBm(bandwidth: 12.5e3), -133.0, decimals: 1)
    k.printed("cascade LNA + mixer F", pow(10, N.cascadeNoiseFigureDB([.init("LNA", noiseFigureDB: 1, gainDB: 20), .init("Mixer", noiseFigureDB: 10, gainDB: 0)]) / 10), 1.348_93, decimals: 5)
    k.printed("cascade NF dB", N.cascadeNoiseFigureDB([.init("LNA", noiseFigureDB: 1, gainDB: 20), .init("Mixer", noiseFigureDB: 10, gainDB: 0)]), 1.2999, decimals: 4)
    k.printed("T_e for NF 1 dB", N.equivalentTemperature(noiseFigureDB: 1), 75.09, decimals: 2)
    k.close("NF ↔ T_e round trip", N.noiseFigureDB(equivalentTemperature: N.equivalentTemperature(noiseFigureDB: 3.7)), 3.7, rel: 1e-12)
    k.printed("GPS C/N₀", N.cn0DBHz(receivedPowerDBm: -128.5, noiseFigureDB: 2), 43.475, decimals: 3)
    k.close("SNR = P_r − floor", N.snrDB(receivedPowerDBm: -80, bandwidth: 20e6, noiseFigureDB: 7), -80 - N.floorDBm(bandwidth: 20e6, noiseFigureDB: 7), rel: 1e-12)
    k.printed("Shannon 20 MHz 20 dB (Mb/s)", N.shannonCapacity(bandwidth: 20e6, snrDB: 20) / 1e6, 133.1642, decimals: 4)
    k.printed("Shannon 100 MHz 30 dB (Mb/s)", N.shannonCapacity(bandwidth: 100e6, snrDB: 30) / 1e6, 996.723, decimals: 3)
    k.printed("Shannon 1 MHz 0 dB (Mb/s)", N.shannonCapacity(bandwidth: 1e6, snrDB: 0) / 1e6, 1.000, decimals: 3)
    k.printed("Shannon limit Eb/N0", N.shannonLimitEbN0DB, -1.5917, decimals: 4)
    k.close("Shannon with zero bandwidth (CW carrier) = 0, not NaN", N.shannonCapacity(bandwidth: 0, snrDB: .infinity), 0)
    k.close("required SNR inverts capacity", N.requiredSNRDB(rate: 133.164_2e6, bandwidth: 20e6), 20, abs: 1e-5)
    k.printed("MIMO SISO", N.mimoCapacity(realChannel: [[1]], snrDB: 20), 6.6582, decimals: 4)
    k.printed("MIMO I₂", N.mimoCapacity(realChannel: [[1, 0], [0, 1]], snrDB: 20), 11.3449, decimals: 4)
    let i4 = (0..<4).map { r in (0..<4).map { c in r == c ? 1.0 : 0 } }
    k.printed("MIMO I₄", N.mimoCapacity(realChannel: i4, snrDB: 20), 18.8018, decimals: 4)
    k.printed("MIMO [[1, ½], [½, 1]]", N.mimoCapacity(realChannel: [[1, 0.5], [0.5, 1]], snrDB: 20), 10.5814, decimals: 4)
    let hc: [[RF.Complex]] = [[RF.Complex(0, 1), RF.Complex(0)], [RF.Complex(0), RF.Complex(0, -1)]]
    k.printed("MIMO phase-only channel = I₂", N.mimoCapacity(channel: hc, snrDB: 20), 11.3449, decimals: 4)
    k.close("Eb/N0 ↔ SNR", N.ebN0DB(snrDB: 10, bandwidth: 1e6, bitRate: 2e6), 10 - 10 * log10(2.0), rel: 1e-12)
    k.close("Es/N0 = Eb/N0 + 10log k", N.esN0DB(ebN0DB: 10, bitsPerSymbol: 4), 10 + 10 * log10(4.0), rel: 1e-12)
    return k.results
  }

  // MARK: Error rates and EVM (C.6–C.7)

  static func errorRates() -> [RFCheckResult] {
    var k = RFCheckList("error-rates")
    let E = RF.ErrorRates.self
    k.significant("BPSK 0 dB", E.bpskBER(ebN0DB: 0), 7.864_960e-2, digits: 7)
    k.significant("BPSK 6.79 dB", E.bpskBER(ebN0DB: 6.79), 9.994e-4, digits: 4)
    k.significant("BPSK 9.59 dB", E.bpskBER(ebN0DB: 9.59), 9.953e-6, digits: 4)
    k.significant("BPSK 10 dB", E.bpskBER(ebN0DB: 10), 3.872_108e-6, digits: 7)
    k.printed("BPSK 1e-5 needs", E.requiredEbN0DB(.bpsk, targetBER: 1e-5) ?? .nan, 9.587_86, decimals: 5)
    k.close("QPSK per bit = BPSK", E.ber(.qpsk, ebN0DB: 7) ?? .nan, E.bpskBER(ebN0DB: 7), rel: 1e-15)
    let es16 = RF.Noise.esN0DB(ebN0DB: 10, bitsPerSymbol: 4)
    k.significant("16QAM P_s approx", E.mqamSERApprox(order: 16, esN0DB: es16), 7.016_60e-3, digits: 6)
    k.significant("16QAM P_s exact", E.mqamSERExact(order: 16, esN0DB: es16), 7.004_29e-3, digits: 6)
    k.significant("64QAM P_s 14 dB", E.mqamSERApprox(order: 64, esN0DB: RF.Noise.esN0DB(ebN0DB: 14, bitsPerSymbol: 6)), 1.292_40e-2, digits: 6)
    k.significant("256QAM P_s 18 dB", E.mqamSERApprox(order: 256, esN0DB: RF.Noise.esN0DB(ebN0DB: 18, bitsPerSymbol: 8)), 2.777_68e-2, digits: 6)
    k.significant("8PSK P_s Es/N0 15 dB", E.mpskSER(order: 8, esN0DB: 15), 2.339_45e-3, digits: 6)
    k.close("Gray P_b ≈ P_s/log2 M", E.ber(.qam16, ebN0DB: 10) ?? .nan, E.mqamSERExact(order: 16, esN0DB: es16) / 4, rel: 1e-12)
    k.check("high-SNR SER has no cancellation", (E.ser(.qam16, ebN0DB: 26) ?? 0) > 0)
    k.check("OOK has no reference formula", E.ber(.ook, ebN0DB: 10) == nil)
    k.printed("EVM 3.5 % in dB", E.evmDB(fromRatio: 0.035), -29.119, decimals: 3)
    k.printed("EVM 2.5 % in dB", E.evmDB(fromRatio: 0.025), -32.041, decimals: 3)
    k.printed("EVM −35 dB in %", E.evmRatio(fromDB: -35) * 100, 1.7783, decimals: 4)
    k.printed("EVM −38 dB in %", E.evmRatio(fromDB: -38) * 100, 1.2589, decimals: 4)
    k.check("38.104 EVM table", E.nrEVMRequirement(.qpsk) == 0.175 && E.nrEVMRequirement(.qam16) == 0.125 && E.nrEVMRequirement(.qam64) == 0.08
      && E.nrEVMRequirement(.qam256) == 0.035 && E.nrEVMRequirement(.qam1024, carrierFrequency: 3.5e9) == 0.025
      && E.nrEVMRequirement(.qam1024, carrierFrequency: 28e9) == 0.028)
    k.close("802.11ax 1024QAM EVM", E.wifi6EVM1024DB, -35)
    return k.results
  }

  // MARK: Analog theory (D.1–D.5)

  static func analog() -> [RFCheckResult] {
    var k = RFCheckList("analog")
    let T = RF.AnalogTheory.self
    k.close("AM m 1 P_t/P_c", T.amPowerRatio(modulationIndex: 1), 1.5)
    k.printed("AM m 1 efficiency %", T.amSidebandEfficiency(modulationIndex: 1) * 100, 33.33, decimals: 2)
    k.close("AM m 0.5 P_t/P_c", T.amPowerRatio(modulationIndex: 0.5), 1.125)
    k.printed("AM m 0.5 efficiency %", T.amSidebandEfficiency(modulationIndex: 0.5) * 100, 11.11, decimals: 2)
    for (n, v) in [(0, 0.765_20), (1, 0.440_05), (2, 0.114_90), (3, 0.019_56)] {
      k.printed("J\(n)(1)", T.besselLine(order: n, beta: 1), v, decimals: 5)
    }
    k.printed("J0(1) 6 digits", RF.Special.besselJ(0, 1), 0.765_198, decimals: 6)
    k.printed("carrier null β", T.carrierNullBeta, 2.404_826, decimals: 6)
    k.close("J0 at the null", RF.Special.besselJ(0, T.carrierNullBeta), 0, abs: 1e-12)
    k.printed("J0(5)", RF.Special.besselJ(0, 5), -0.177_60, decimals: 5)
    k.printed("J1(5)", RF.Special.besselJ(1, 5), -0.327_58, decimals: 5)
    k.printed("J4(5)", RF.Special.besselJ(4, 5), 0.391_232, decimals: 6)
    k.printed("β = 5 power within ±6 (%)", T.fmPowerFraction(beta: 5, withinSidebands: 6) * 100, 99.356, decimals: 3)
    k.close("β = 75/15", T.fmModulationIndex(deviation: 75e3, audioFrequency: 15e3), 5)
    k.close("Carson broadcast", T.carsonBandwidth(deviation: 75e3, audioFrequency: 15e3), 180e3)
    k.close("Carson AMPS", T.carsonBandwidth(deviation: 12e3, audioFrequency: 3e3), 30e3)
    k.close("J₋ₙ = (−1)ⁿJₙ", T.besselLines(beta: 2, maxOrder: 3)[0].amplitude, -RF.Special.besselJ(3, 2), rel: 1e-12)
    k.close("BLE h 0.5 at 1 Mb/s → Δf", T.fskDeviation(index: 0.5, bitRate: 1e6), 250e3)
    k.close("h = 2Δf/R_b", T.fskModulationIndex(deviation: 250e3, bitRate: 1e6), 0.5)
    k.printed("GSM δ", T.gaussianDelta(bt: 0.3), 0.441_684, decimals: 6)
    k.close("broadcast FM 100 % deviation", T.broadcastFMDeviation, 75e3)
    return k.results
  }

  // MARK: Numerology (D.4–D.9, E)

  static func numerology() -> [RFCheckResult] {
    var k = RFCheckList("numerology")
    let NR = RF.Numerology.NR.self
    k.printed("NR T_c ns", NR.tc * 1e9, 0.508_626, decimals: 6)
    k.close("NR κ", (1 / (15_000 * 2048.0)) / NR.tc, 64, rel: 1e-12)
    let mu: [(Int, Double, Double, Double)] = [(0, 66.6667, 4687.50, 1e-3), (1, 33.3333, 2343.75, 0.5e-3), (3, 8.3333, 585.94, 0.125e-3), (6, 1.0417, 73.24, 15.625e-6)]
    for (m, tu, cp, slot) in mu {
      k.printed("NR µ\(m) T_u µs", NR.usefulDuration(mu: m) * 1e6, tu, decimals: 4)
      k.printed("NR µ\(m) CP ns", NR.normalCPDuration(mu: m) * 1e9, cp, decimals: 2)
      k.close("NR µ\(m) slot", NR.slotDuration(mu: m), slot, rel: 1e-12)
      k.close("NR µ\(m) SCS", NR.subcarrierSpacing(mu: m), 15_000 * pow(2, Double(m)))
    }
    k.printed("NR µ6 CP 73.242 ns", NR.normalCPDuration(mu: 6) * 1e9, 73.242, decimals: 3)
    k.close("NR long CP adds 16κ T_c", NR.normalCPDuration(mu: 0, firstInHalfSubframe: true) - NR.normalCPDuration(mu: 0), 16 * 64 * NR.tc, rel: 1e-12)
    k.close("NR guard band 100 MHz 30 kHz", NR.guardBandKHz(bandwidthMHz: 100, resourceBlocks: 273, scsKHz: 30), 845)
    k.printed("NR-ARFCN 633 333", NR.arfcnToFrequencyMHz(633_333), 3499.995, decimals: 3)
    k.check("NR-ARFCN round trip", NR.frequencyToARFCN(3499.995) == 633_333)
    k.close("NR-ARFCN FR2 offset", NR.arfcnToFrequencyMHz(2_016_667), 24_250.08)
    k.check("NR max RB 273/135/264/148", NR.maxResourceBlocks.map(\.rb) == [273, 135, 264, 148])
    k.check("FR1 410–7125, FR2-1 24 250–52 600, FR2-2 52 600–71 000",
            NR.fr1MHz == 410...7125 && NR.fr2_1MHz == 24_250...52_600 && NR.fr2_2MHz == 52_600...71_000)
    k.check("n77 3300–4200 TDD", NR.bands.contains { $0.name == "n77" && $0.lowMHz == 3300 && $0.highMHz == 4200 && $0.duplex == .tdd })
    k.check("n260 37–40 GHz", NR.bands.contains { $0.name == "n260" && $0.lowMHz == 37_000 && $0.highMHz == 40_000 })
    k.close("UE power class 3", NR.powerClass3DBm, 23)
    let LTE = RF.Numerology.LTE.self
    k.printed("LTE T_s ns", LTE.ts * 1e9, 32.552, decimals: 3)
    k.printed("LTE T_u µs", LTE.usefulDuration * 1e6, 66.667, decimals: 3)
    k.printed("LTE CP first µs", LTE.normalCPFirst * 1e6, 5.208, decimals: 3)
    k.printed("LTE CP µs", LTE.normalCP * 1e6, 4.6875, decimals: 4)
    k.printed("LTE extended CP µs", LTE.extendedCP * 1e6, 16.667, decimals: 3)
    k.check("LTE slot 15 360 T_s", LTE.slotSamples == 15_360)
    k.close("LTE slot 0.5 ms", Double(LTE.slotSamples) * LTE.ts, 0.5e-3, rel: 1e-12)
    k.check("LTE RB table 6/15/25/50/75/100", LTE.resourceBlocks.map(\.rb) == [6, 15, 25, 50, 75, 100] && LTE.resourceBlocks(bandwidthMHz: 20) == 100)
    let W = RF.Numerology.WiFi.self
    k.close("Wi-Fi Δf 312.5 kHz", W.legacySubcarrierSpacing, 312_500)
    k.close("Wi-Fi T_u 3.2 µs", 1 / W.legacySubcarrierSpacing, 3.2e-6, rel: 1e-12)
    k.close("HE Δf 78.125 kHz", W.heSubcarrierSpacing, 78_125)
    k.close("HE T_u 12.8 µs", 1 / W.heSubcarrierSpacing, 12.8e-6, rel: 1e-12)
    k.printed("11a Mb/s", W.rate11a / 1e6, 54, decimals: 6)
    k.printed("11n Mb/s", W.rate11n / 1e6, 600, decimals: 6)
    k.printed("11ac Mb/s", W.rate11ac / 1e6, 6933.3, decimals: 1)
    k.printed("11ax Mb/s", W.rate11ax / 1e6, 9607.84, decimals: 2)
    k.printed("11be Mb/s", W.rate11be / 1e6, 23_058.82, decimals: 2)
    k.printed("iPhone 15 Pro Max ax 160 MHz 2 SS", W.rateIPhone15ProMax / 1e6, 2401.96, decimals: 2)
    k.printed("HE MCS11 20 MHz 1 SS", W.phyRate(dataSubcarriers: 234, bitsPerSymbol: 10, codeRate: 5.0 / 6, symbolDuration: 13.6e-6) / 1e6, 143.382, decimals: 3)
    k.printed("HE MCS11 80 MHz 1 SS", W.phyRate(dataSubcarriers: 980, bitsPerSymbol: 10, codeRate: 5.0 / 6, symbolDuration: 13.6e-6) / 1e6, 600.490, decimals: 3)
    k.printed("HE 160 MHz 2 SS", W.phyRate(dataSubcarriers: 1960, bitsPerSymbol: 10, codeRate: 5.0 / 6, symbolDuration: 13.6e-6, streams: 2) / 1e6, 2401.961, decimals: 3)
    let BT = RF.Numerology.Bluetooth.self
    k.check("BLE index → MHz", BT.leChannelMHz(0) == 2404 && BT.leChannelMHz(10) == 2424 && BT.leChannelMHz(11) == 2428 && BT.leChannelMHz(36) == 2478)
    k.check("BLE advertising 37/38/39", BT.leChannelMHz(37) == 2402 && BT.leChannelMHz(38) == 2426 && BT.leChannelMHz(39) == 2480)
    k.check("BR channel 39 = 2441 MHz", BT.brChannelMHz(39) == 2441 && BT.brChannelMHz(79) == nil)
    k.printed("BT slot µs", BT.slotDuration * 1e6, 625, decimals: 9)
    for (idx, cm) in [(37, 12.48), (38, 12.36), (39, 12.09)] {
      k.printed("BLE ch \(idx) λ cm", c / ((BT.leChannelMHz(idx) ?? 0) * 1e6) * 100, cm, decimals: 2)
    }
    let G = RF.Numerology.GSM.self
    k.printed("GSM symbol rate ksym/s", G.symbolRate / 1e3, 270.833, decimals: 3)
    k.printed("GSM T_b µs", G.symbolPeriod * 1e6, 3.692_31, decimals: 5)
    k.close("GSM B = 0.3/T", 0.3 * G.symbolRate, 81_250, rel: 1e-12)
    k.printed("GSM slot µs", G.slotDuration * 1e6, 576.9, decimals: 1)
    k.close("GSM slot = 156.25 symbols", G.slotDuration * G.symbolRate, 156.25, rel: 1e-12)
    k.printed("GSM frame ms", G.frameDuration * 1e3, 4.615, decimals: 3)
    k.close("EDGE gross kb/s", G.edgeGrossRate / 1e3, 812.5, rel: 1e-12)
    k.close("P-GSM ARFCN 62 UL", G.pgsmUplinkMHz(arfcn: 62) ?? .nan, 902.4, rel: 1e-12)
    k.close("P-GSM ARFCN 62 DL", G.pgsmDownlinkMHz(arfcn: 62) ?? .nan, 947.4, rel: 1e-12)
    let GPS = RF.Numerology.GPS.self
    k.close("GPS L1", GPS.l1, 1575.42e6, rel: 1e-12)
    k.close("GPS L2", GPS.l2, 1227.6e6, rel: 1e-12)
    k.close("GPS L5", GPS.l5, 1176.45e6, rel: 1e-12)
    k.close("C/A period 1 ms", Double(GPS.caCodeLength) / GPS.caChipRate, 1e-3, rel: 1e-12)
    k.close("L5 period 1 ms", Double(GPS.l5CodeLength) / GPS.l5ChipRate, 1e-3, rel: 1e-12)
    k.close("L1 minimum −128.5 dBm", GPS.l1MinimumPowerDBW + 30, -128.5)
    let U = RF.Numerology.UWB.self
    k.close("UWB ch5", U.channel5, 6489.6e6, rel: 1e-12)
    k.close("UWB ch9", U.channel9, 7987.2e6, rel: 1e-12)
    k.printed("UWB 1 m ToF ns", U.timeOfFlight(distance: 1) * 1e9, 3.3356, decimals: 4)
    k.printed("UWB c/2B m", U.rangeResolution, 0.300, decimals: 3)
    k.close("UWB two-way ranging", U.twoWayDistance(roundTrip: 1e-6 + 2 * U.timeOfFlight(distance: 5), reply: 1e-6), 5, rel: 1e-9)
    let NFC = RF.Numerology.NFC.self
    k.close("NFC 106 kb/s class", NFC.bitRate, 105_937.5)
    k.printed("NFC ETU µs", 1 / NFC.bitRate * 1e6, 9.4395, decimals: 4)
    k.close("NFC subcarrier", NFC.subcarrier, 847_500)
    k.check("US AM raster 117 carriers", RF.Numerology.Broadcast.amCarriersUS.count == 117)
    k.check("US FM ch 201 = 88.1, ch 300 = 107.9",
            abs((RF.Numerology.Broadcast.fmChannelMHz(201) ?? 0) - 88.1) < 1e-9 && abs((RF.Numerology.Broadcast.fmChannelMHz(300) ?? 0) - 107.9) < 1e-9)
    k.printed("G_p GPS C/A", RF.Numerology.processingGainDB(chipRate: 1.023e6, bitRate: 50), 43.1091, decimals: 4)
    k.printed("G_p IS-95", RF.Numerology.processingGainDB(chipRate: 1.2288e6, bitRate: 9600), 21.0721, decimals: 4)
    k.printed("G_p Barker-11", RF.SpreadingCode.barker11.processingGainDB, 10.4139, decimals: 4)
    k.printed("G_p WCDMA SF 256 (3.84 Mcps / 15 ksym/s)", RF.Numerology.processingGainDB(chipRate: 3.84e6, bitRate: 15e3), 24.08, decimals: 2)
    return k.results
  }

  // MARK: Systems catalog

  static func systems() -> [RFCheckResult] {
    var k = RFCheckList("systems")
    let all = RF.SystemsCatalog.all
    let ids = all.map(\.id)
    k.check("unique ids", Set(ids).count == ids.count)
    let required = ["amps", "gsm", "is95", "edge", "umts", "lte", "nr-fr1", "nr-fr2", "6g", "wifi-b", "wifi-a", "wifi-g", "wifi-n", "wifi-ac",
                    "wifi-ax", "wifi-6e", "wifi-be", "bt-classic", "ble", "gps-l1", "gps-l5", "nfc", "uwb-ch5", "uwb-ch9", "am", "fm", "dab", "tv", "qi",
                    "fmcw-77", "fmcw-24"]
    for id in required { k.check("catalog has \(id)", RF.SystemsCatalog.system(id: id) != nil) }
    for cat in RF.SystemCategory.allCases { k.check("\(cat.rawValue) chip non-empty", !RF.SystemsCatalog.systems(in: cat).isEmpty) }
    for s in all {
      let inBand = s.bands.isEmpty || s.bands.contains { $0.contains(s.carrier) } || s.isSpeculative
      k.check("\(s.id) carrier inside a band", inBand, RF.Units.format(frequency: s.carrier))
      k.check("\(s.id) bands have low < high (Qi2's 360 kHz point excepted)", s.bands.allSatisfy { $0.lowMHz < $0.highMHz || $0.name == "Qi2 MPP" })
      k.check("\(s.id) channel widths ascending", s.channelWidths == s.channelWidths.sorted())
      if let q = s.maxQAM { k.check("\(s.id) max QAM is a power of 4", q >= 16 && q.nonzeroBitCount == 1 && q.trailingZeroBitCount % 2 == 0) }
    }
    k.check("6G is speculative and alone", all.filter(\.isSpeculative).map(\.id) == ["6g"])
    k.check("mmWave is partial (US A2849 only)", RF.SystemsCatalog.system(id: "nr-fr2")?.iPhone == .partial)
    k.check("Wi-Fi 7 not in this iPhone", RF.SystemsCatalog.system(id: "wifi-be")?.iPhone == .no)
    k.check("Wi-Fi 6E in this iPhone", RF.SystemsCatalog.system(id: "wifi-6e")?.iPhone == .yes)
    k.check("BT, BLE, NFC, UWB, Qi, GPS in this iPhone", ["bt-classic", "ble", "nfc", "uwb-ch5", "uwb-ch9", "qi", "gps-l1", "gps-l5"].allSatisfy { RF.SystemsCatalog.system(id: $0)?.iPhone == .yes })
    k.check("AMPS, IS-95, AM, FM, DAB, TV not in this iPhone", ["amps", "is95", "am", "fm", "dab", "tv"].allSatisfy { RF.SystemsCatalog.system(id: $0)?.iPhone == .no })
    k.check("mmWave bands n258/n260/n261", RF.SystemsCatalog.iPhoneMMWaveBands == ["n258", "n260", "n261"])
    k.check("A2849 LTE list has 31 bands", RF.SystemsCatalog.iPhoneLTEBands.count == 31)
    k.check("A2849 NR list has 27 bands", RF.SystemsCatalog.iPhoneNRBands.count == 27)
    k.close("Wi-Fi 7 peak", RF.SystemsCatalog.system(id: "wifi-be")?.peakRate?.value ?? 0, RF.Numerology.WiFi.rate11be)
    k.close("Wi-Fi 6E peak = this iPhone's 2401.96 Mb/s", RF.SystemsCatalog.system(id: "wifi-6e")?.peakRate?.value ?? 0, RF.Numerology.WiFi.rateIPhone15ProMax)
    k.close("GPS L1 carrier", RF.SystemsCatalog.system(id: "gps-l1")?.carrier ?? 0, 1575.42e6, rel: 1e-12)
    k.check("max QAM: LTE/NR FR1 1024, 11ax 1024, 11be 4096",
            RF.SystemsCatalog.system(id: "lte")?.maxQAM == 1024 && RF.SystemsCatalog.system(id: "nr-fr1")?.maxQAM == 1024
              && RF.SystemsCatalog.system(id: "wifi-ax")?.maxQAM == 1024 && RF.SystemsCatalog.system(id: "wifi-be")?.maxQAM == 4096)
    k.check("systems containing 2.44 GHz include BLE", RF.SystemsCatalog.systems(containing: 2.44e9).contains { $0.id == "ble" })
    k.check("UMTS 2140 MHz carrier lies in Band I downlink (2110–2170 MHz)",
            RF.SystemsCatalog.system(id: "umts")?.bands.contains { $0.name.hasPrefix("Band I (") && $0.contains(2140e6) } == true)
    k.check("UMTS is not listed at 1800 MHz (Band IV is 1710–1755 / 2110–2155, not 1700–2100)",
            !RF.SystemsCatalog.systems(containing: 1800e6).contains { $0.id == "umts" })
    // Codable round trip of the whole catalog.
    do {
      let data = try JSONEncoder().encode(all)
      let back = try JSONDecoder().decode([RF.RadioSystem].self, from: data)
      k.check("catalog Codable round trip", back == all, "\(data.count) bytes")
    } catch {
      k.check("catalog Codable round trip", false, "\(error)")
    }
    // Every waveform simulates a frame; noiseless digital ones decode without error.
    for s in all {
      var link = RF.BasebandLink(RF.BasebandLinkConfig(system: s))
      _ = link.next()
      let f = link.next()
      k.check("\(s.id) simulates", f.rx.count > 0 && f.tx.count == f.rx.count, "\(f.rx.count) samples")
      if s.waveform.dataModulation != nil || { if case .fsk = s.waveform { return true }; return false }() {
        k.check("\(s.id) noiseless frame decodes", !f.sentBits.isEmpty && f.bitErrors == 0, "\(f.bitErrors) errors in \(f.sentBits.count)")
      }
    }
    return k.results
  }

  // MARK: DSP (G)

  static func dsp() -> [RFCheckResult] {
    var k = RFCheckList("dsp")
    let D = RF.DSP.self
    k.close("Δf 48 kHz / 4096", D.resolution(sampleRate: 48_000, count: 4096), 11.718_75)
    k.printed("window 4096 at 48 kHz (ms)", D.windowDuration(sampleRate: 48_000, count: 4096) * 1e3, 85.333, decimals: 3)
    k.close("Δf 48 kHz / 1024", D.resolution(sampleRate: 48_000, count: 1024), 46.875)
    k.close("bin 100 of 1024 at 48 kHz", D.binFrequency(100, sampleRate: 48_000, count: 1024), 4687.5)
    k.close("alias 60 Hz at 100 Hz", D.aliasFrequency(60, sampleRate: 100), 40)
    k.close("alias 50 Hz at 100 Hz (Nyquist)", D.aliasFrequency(50, sampleRate: 100), 50)
    k.close("alias 120 Hz at 100 Hz", D.aliasFrequency(120, sampleRate: 100), 20)
    k.close("alias 1 kHz at 800 Hz", D.aliasFrequency(1000, sampleRate: 800), 200)
    k.check("60 Hz at 100 Hz is aliased", D.isAliased(60, sampleRate: 100))
    // Unit cosine at bin 100, N = 1024: |X| = 512 (rect) / 256 (Hann); Parseval.
    let n = 1024
    let cosine = (0..<n).map { Float(cos(2 * pi * 100 * Double($0) / Double(n))) }
    let fft = RF.FFT(count: n)!
    let X = fft.forward(RF.IQBuffer(real: cosine))
    k.close("vDSP |X[100]| rect", X[100].magnitude, 512, rel: 1e-5)
    let hann = D.window(.hann, count: n)
    let Xh = fft.forward(RF.IQBuffer(real: zip(cosine, hann).map { $0 * $1 }))
    k.close("vDSP |X[100]| Hann", Xh[100].magnitude, 256, rel: 1e-5)
    let timeEnergy = cosine.reduce(0.0) { $0 + Double($1 * $1) }
    var freqEnergy = 0.0
    for b in 0..<n { freqEnergy += X[b].magnitudeSquared }
    k.close("Parseval time side", timeEnergy, 512, rel: 1e-5)
    k.close("Parseval frequency side /N", freqEnergy / Double(n), 512, rel: 1e-5)
    // vDSP against the double-precision reference FFT at every power of two.
    var rng = RF.SeededRandom(seed: 42)
    var worst = 0.0
    for log2n in 3...12 {
      let m = 1 << log2n
      var re = (0..<m).map { _ in rng.uniform(-1, 1) }
      var im = (0..<m).map { _ in rng.uniform(-1, 1) }
      let buffer = RF.IQBuffer(i: re.map { Float($0) }, q: im.map { Float($0) })
      let y = RF.FFT(count: m)!.forward(buffer)
      RF.ReferenceFFT.transform(re: &re, im: &im)
      for b in 0..<m { worst = max(worst, hypot(Double(y.i[b]) - re[b], Double(y.q[b]) - im[b]) / Double(m).squareRoot()) }
    }
    k.check("vDSP FFT matches reference FFT (N 8…4096)", worst < 1e-5, String(format: "max error %.2e", worst))
    var roundTrip = RF.IQBuffer(i: [1, 2, 3, 4, 5, 6, 7, 8], q: [0, -1, 0, 1, 0, -1, 0, 1])
    let original = roundTrip
    let f8 = RF.FFT(count: 8)!
    f8.forward(&roundTrip)
    f8.inverse(&roundTrip)
    k.check("FFT inverse(forward(x)) = x", zip(roundTrip.i, original.i).allSatisfy { abs($0 - $1) < 1e-5 })
    k.check("FFT rejects non power of two", RF.FFT(count: 1000) == nil)
    // Windows (Harris; periodic like vDSP).
    k.close("Hann coherent gain", D.coherentGain(hann), 0.5, rel: 1e-6)
    k.printed("Hann ENBW bins", D.equivalentNoiseBandwidth(hann), 1.5, decimals: 5)
    k.printed("Hann scalloping", D.scallopingLossDB(hann), 1.4236, decimals: 4)
    k.printed("rect scalloping", D.scallopingLossDB(D.window(.rectangular, count: n)), 3.9224, decimals: 4)
    k.printed("Hann highest sidelobe", D.highestSidelobeDB(hann), -31.47, decimals: 2)
    k.printed("rect highest sidelobe", D.highestSidelobeDB(D.window(.rectangular, count: n)), -13.26, decimals: 2)
    var vdspHann = [Float](repeating: 0, count: n)
    vDSP_hann_window(&vdspHann, vDSP_Length(n), Int32(vDSP_HANN_DENORM))
    k.check("our Hann = vDSP_HANN_DENORM (periodic)", zip(vdspHann, hann).allSatisfy { abs($0 - $1) < 1e-6 })
    var normHann = [Float](repeating: 0, count: n)
    vDSP_hann_window(&normHann, vDSP_Length(n), Int32(vDSP_HANN_NORM))
    k.printed("vDSP_HANN_NORM mean square", normHann.reduce(0.0) { $0 + Double($1 * $1) } / Double(n), 1.000, decimals: 3)
    // vDSP real DFT (zrop) scales forward by 2 and packs Nyquist in Oi[0].
    if let setup = vDSP_DFT_zrop_CreateSetup(nil, vDSP_Length(n), .FORWARD) {
      let ir = (0..<(n / 2)).map { cosine[2 * $0] }
      let ii = (0..<(n / 2)).map { cosine[2 * $0 + 1] }
      var orr = [Float](repeating: 0, count: n / 2)
      var oi = [Float](repeating: 0, count: n / 2)
      vDSP_DFT_Execute(setup, ir, ii, &orr, &oi)
      vDSP_DFT_DestroySetup(setup)
      k.close("vDSP zrop |H[100]| = 2×512", Double(hypot(orr[100], oi[100])), 1024, rel: 1e-5)
    } else {
      k.check("vDSP zrop setup", false)
    }
    // Leakage: complex exponential half a bin off (rect 3.9224 dB, Hann 1.4236 dB).
    var analyzer = RF.SpectrumAnalyzer(count: n, window: .rectangular)!
    func tone(_ bin: Double) -> RF.IQBuffer {
      RF.IQBuffer(i: (0..<n).map { Float(cos(2 * pi * bin * Double($0) / Double(n))) }, q: (0..<n).map { Float(sin(2 * pi * bin * Double($0) / Double(n))) })
    }
    let onRect = analyzer.powerDB(tone(100))[100 + n / 2]
    let offRect = analyzer.powerDB(tone(100.5))[100 + n / 2]
    k.close("rect half-bin loss (complex tone)", Double(onRect - offRect), 3.9224, abs: 0.001, rel: 0)
    k.close("tone scaling: unit tone reads 0 dB", Double(onRect), 0, abs: 1e-4, rel: 0)
    var hannAnalyzer = RF.SpectrumAnalyzer(count: n, window: .hann)!
    let onHann = hannAnalyzer.powerDB(tone(100))[100 + n / 2]
    let offHann = hannAnalyzer.powerDB(tone(100.5))[100 + n / 2]
    k.close("Hann half-bin loss (complex tone)", Double(onHann - offHann), 1.4236, abs: 0.001, rel: 0)
    let realOff = hannAnalyzer.realSpectrumDB((0..<n).map { Float(cos(2 * pi * 100.5 * Double($0) / Double(n))) })
    k.close("Hann half-bin loss (real cosine)", -Double(realOff[100]), 1.4236, abs: 0.04, rel: 0)
    var rectReal = RF.SpectrumAnalyzer(count: n, window: .rectangular)!
    let realRect = rectReal.realSpectrumDB((0..<n).map { Float(cos(2 * pi * 100.5 * Double($0) / Double(n))) })
    k.close("rect half-bin loss (real cosine, ±0.04)", -Double(max(realRect[100], realRect[101])), 3.92, abs: 0.04, rel: 0)
    // PSD: white noise of variance σ² reads σ²/f_s.
    var noiseRng = RF.SeededRandom(seed: 7)
    var psdSum = 0.0
    var psdAnalyzer = RF.SpectrumAnalyzer(count: n, window: .hann)!
    for _ in 0..<64 {
      var w = RF.IQBuffer(count: n)
      for j in 0..<n {
        let (a, b) = noiseRng.gaussianPair()
        w.i[j] = Float(a * 0.5.squareRoot())
        w.q[j] = Float(b * 0.5.squareRoot())
      }
      let p = psdAnalyzer.powerDB(w, scaling: .density(sampleRate: 1000))
      psdSum += p.reduce(0.0) { $0 + pow(10, Double($1) / 10) } / Double(n)
    }
    k.close("PSD of unit-power noise = 1/f_s", 10 * log10(psdSum / 64), -30, abs: 0.1, rel: 0)
    var long = RF.IQBuffer(count: 8 * n)
    for j in 0..<(8 * n) {
      let (a, b) = noiseRng.gaussianPair()
      long.i[j] = Float(a * 0.5.squareRoot())
      long.q[j] = Float(b * 0.5.squareRoot())
    }
    let welch = psdAnalyzer.averagedPowerDB(long, scaling: .density(sampleRate: 1000))
    let welchMean = welch.reduce(0.0) { $0 + pow(10, Double($1) / 10) } / Double(n)
    k.close("Welch PSD of unit-power noise = 1/f_s", 10 * log10(welchMean), -30, abs: 0.1, rel: 0)
    let welchSpread = welch.map { Double($0) }.reduce(0.0) { $0 + pow($1 - 10 * log10(welchMean), 2) } / Double(n)
    k.check("Welch averaging steadies the noise floor (σ < 2.5 dB)", welchSpread.squareRoot() < 2.5, String(format: "σ %.2f dB", welchSpread.squareRoot()))
    // Filters.
    let lp = D.firTaps(.lowpass, cutoff: 0.1, taps: 101)
    k.close("FIR low-pass DC gain", D.firMagnitude(lp, at: 0), 1, abs: 1e-6)
    k.close("FIR low-pass −6 dB at cutoff", 20 * log10(D.firMagnitude(lp, at: 0.1)), -6.02, abs: 0.1)
    k.check("FIR Blackman stopband < −60 dB", 20 * log10(D.firMagnitude(lp, at: 0.2)) < -60)
    let hp = D.firTaps(.highpass, cutoff: 0.1, taps: 101)
    k.check("FIR high-pass passes 0.3, blocks DC", abs(D.firMagnitude(hp, at: 0.3) - 1) < 1e-3 && D.firMagnitude(hp, at: 0) < 1e-4)
    let bq = D.Biquad(.lowpass, frequency: 1000, sampleRate: 48_000)
    k.close("biquad Butterworth −3 dB at corner", bq.magnitude(at: 1000, sampleRate: 48_000), 1 / 2.0.squareRoot(), rel: 1e-9)
    k.close("biquad DC gain", bq.magnitude(at: 0, sampleRate: 48_000), 1, rel: 1e-12)
    // Streaming FIR equals one-shot filtering.
    var fir = D.FIRFilter(taps: lp)
    let sig = (0..<3000).map { Float(sin(Double($0) * 0.05)) + Float(sin(Double($0) * 1.9)) }
    var oneShot = D.FIRFilter(taps: lp)
    let whole = oneShot.process(sig)
    let pieces = fir.process(Array(sig[0..<1000])) + fir.process(Array(sig[1000..<1777])) + fir.process(Array(sig[1777...]))
    k.check("streaming FIR is seamless", zip(whole, pieces).allSatisfy { abs($0 - $1) < 1e-5 })
    // Decimate / interpolate keep a low tone's amplitude.
    let low = (0..<4800).map { Float(sin(2 * pi * 500 * Double($0) / 48_000)) }
    var interp = D.Interpolator(factor: 4)
    let up = interp.process(low)
    var dec = D.Decimator(factor: 4)
    let back = dec.process(up)
    let tail = back[2000...]
    k.close("interpolate ×4 → decimate ÷4 amplitude", Double(tail.max() ?? 0), 1, abs: 0.01)
    k.check("decimate output count", back.count == low.count)
    let d3 = D.decimate(low, factor: 3)
    k.check("one-shot decimate length", d3.count == (low.count - 63) / 3 + 1)
    k.close("linear resample length", Double(D.resampleLinear(low, from: 48_000, to: 8000).count), 800, abs: 0)
    var env = D.EnvelopeFollower(attack: 0.001, release: 0.05, sampleRate: 48_000)
    k.close("envelope follower settles on a sine's peak", Double(env.process(low + low).last ?? 0), 1, abs: 0.1)
    var nco = D.NCO(frequency: 1000, sampleRate: 48_000)
    let carrier = nco.generate(count: 48)
    k.close("NCO completes one cycle in 48 samples", Double(carrier.i[47]), cos(2 * pi * 47 / 48), abs: 1e-6)
    // RRC pair is Nyquist: matched filter peak 1 at the symbol, ~0 one symbol away.
    let rrc = D.rootRaisedCosine(rolloff: 0.35, samplesPerSymbol: 8, spanSymbols: 16)
    var pair = [Double](repeating: 0, count: 2 * rrc.count - 1)
    for a in rrc.indices { for b in rrc.indices { pair[a + b] += Double(rrc[a] * rrc[b]) } }
    k.close("RRC ⊗ RRC peak", pair[rrc.count - 1], 1, abs: 1e-6)
    k.close("RRC ⊗ RRC zero ISI one symbol away", pair[rrc.count - 1 + 8], 0, abs: 2e-3)
    let gauss = D.gaussianTaps(bt: 0.3, samplesPerSymbol: 8)
    k.close("Gaussian taps sum to 1", Double(gauss.reduce(0, +)), 1, abs: 1e-6)
    return k.results
  }

  // MARK: Modulation round trips (D.6–D.9)

  static func modulation() -> [RFCheckResult] {
    var k = RFCheckList("modulation")
    let q16 = RF.Constellation(.qam16)
    let p0 = q16.map(bits: [0, 0, 0, 0])[0]
    let p2 = q16.map(bits: [0, 0, 1, 0])[0]
    k.close("16QAM 0000 → (1 + j)/√10 re", p0.re, 0.316_23, abs: 5e-6)
    k.close("16QAM 0000 im", p0.im, 0.316_23, abs: 5e-6)
    k.close("16QAM 0010 → (3 + j)/√10 re", p2.re, 3 / 10.0.squareRoot(), abs: 1e-6)
    k.close("16QAM 0010 im", p2.im, 1 / 10.0.squareRoot(), abs: 1e-6)
    let qp = RF.Constellation(.qpsk).map(bits: [0, 1])[0]
    k.close("QPSK 01 → (1 − j)/√2", qp.re - qp.im, 2 / 2.0.squareRoot(), abs: 1e-6)
    for (m, norm) in [(16, 10.0), (64, 42), (256, 170), (1024, 682), (4096, 2730)] {
      k.close("\(m)QAM normalization 1/√\(Int(norm))", RF.Constellation.qamNormalization(order: m), 1 / norm.squareRoot(), rel: 1e-12)
    }
    k.check("bits per symbol 1/2/3/4/6/8/10/12",
            [RF.DigitalModulation.bpsk, .qpsk, .psk8, .qam16, .qam64, .qam256, .qam1024, .qam4096].map(\.bitsPerSymbol) == [1, 2, 3, 4, 6, 8, 10, 12])
    for mod in RF.DigitalModulation.allCases {
      let cons = RF.Constellation(mod)
      let power = cons.points.reduce(0.0) { $0 + $1.magnitudeSquared } / Double(cons.points.count)
      k.close("\(mod.rawValue) unit average power", power, 1, rel: 1e-12)
      var rng = RF.SeededRandom(seed: UInt64(mod.bitsPerSymbol))
      let bits = rng.bits(mod.bitsPerSymbol * 500)
      k.check("\(mod.rawValue) map → demap", cons.demap(cons.map(bits: bits)) == bits)
      if mod.isSquareQAM, mod != .qpsk {
        // Gray: horizontally and vertically adjacent points differ in exactly one bit.
        let step = 2 * RF.Constellation.qamNormalization(order: mod.order)
        var grayOK = true
        for (v, p) in cons.points.enumerated() {
          for (dx, dy) in [(step, 0.0), (0.0, step)] {
            if let w = cons.points.firstIndex(where: { abs($0.re - p.re - dx) < 1e-9 && abs($0.im - p.im - dy) < 1e-9 }) {
              if (v ^ w).nonzeroBitCount != 1 { grayOK = false }
            }
          }
        }
        k.check("\(mod.rawValue) Gray neighbours differ by one bit", grayOK)
      }
    }
    // Pulse shaping round trip.
    let shaper = RF.PulseShaper(samplesPerSymbol: 8, rolloff: 0.35, spanSymbols: 16)
    var rng = RF.SeededRandom(seed: 9)
    let syms = RF.Constellation(.qam64).map(bits: rng.bits(6 * 300))
    let shaped = shaper.shape(syms)
    k.close("RRC shaped samples carry the symbols' power", shaped.slice(128..<(shaped.count - 128)).meanPower, syms.meanPower, rel: 0.05)
    let rx = shaper.receive(shaped)
    let evm = RF.EVMResult.measure(received: rx.slice(0..<(rx.count - 16)), reference: syms.slice(0..<(rx.count - 16)))
    k.check("RRC tx/rx recovers 64QAM (EVM < 1 %)", evm.percent < 1, String(format: "%.3f %%", evm.percent))
    // OFDM numerology of 802.11a/g.
    let wifi = RF.OFDMConfig.wifiLegacy
    k.check("802.11a 48 data + 4 pilots", wifi.dataSubcarriers.count == 48 && wifi.pilotSubcarriers.count == 4)
    k.close("802.11a sample rate 20 MHz", wifi.sampleRate, 20e6)
    k.close("802.11a CP 0.8 µs", wifi.cyclicPrefixDuration, 0.8e-6, rel: 1e-12)
    k.close("802.11a T_u 3.2 µs", wifi.usefulDuration, 3.2e-6, rel: 1e-12)
    let mod = RF.OFDMModulator(config: wifi)!
    let ofdmSyms = RF.Constellation(.qam256).map(bits: rng.bits(8 * 480))
    let wave = mod.modulate(ofdmSyms)
    k.close("OFDM unit mean power", wave.meanPower, 1, abs: 0.05)
    let back = RF.OFDMDemodulator(config: wifi)!.demodulate(wave)
    k.check("OFDM round trip 256QAM", RF.Constellation(.qam256).demap(back.data) == RF.Constellation(.qam256).demap(ofdmSyms))
    // An ideal channel is estimated as H = 1 and the raw points are already the data: a receiver
    // gain error cancels in the equalizer, so only these see it.
    let unitH = (0..<back.channelEstimate.count).allSatisfy { abs(back.channelEstimate.i[$0] - 1) < 1e-4 && abs(back.channelEstimate.q[$0]) < 1e-4 }
    k.check("OFDM training estimate of an ideal channel is H = 1", unitH && back.channelEstimate.count == 52)
    k.close("OFDM raw points = data (no gain error)", back.raw.meanPower, back.data.meanPower, rel: 1e-4)
    let pilotCfg = RF.OFDMConfig.scaled(name: "pilots", fftSize: 128, subcarrierSpacing: 15e3)
    let pilotBack = RF.OFDMDemodulator(config: pilotCfg)!.demodulate(RF.OFDMModulator(config: pilotCfg)!.modulate(RF.Constellation(.qpsk).map(bits: rng.bits(2 * 400))))
    k.check("OFDM pilot estimate of an ideal channel is H = 1",
            (0..<pilotBack.channelEstimate.count).allSatisfy { abs(pilotBack.channelEstimate.i[$0] - 1) < 1e-4 && abs(pilotBack.channelEstimate.q[$0]) < 1e-4 })
    k.check("OFDM CP copies the symbol tail", (0..<16).allSatisfy { wave.i[$0] == wave.i[64 + $0] })
    // Degenerate scaled numerologies stay usable (a pilot on every subcarrier, or a full band,
    // used to give no data subcarriers — a division by zero — or two subcarriers on one bin).
    for (spacing, fraction) in [(1, 0.8), (6, 1.0), (2, 0.01)] {
      let c = RF.OFDMConfig.scaled(name: "edge", fftSize: 16, usedFraction: fraction, pilotSpacing: spacing, subcarrierSpacing: 15e3)
      let bins = Set(c.usedSubcarriers.map { c.bin($0) })
      k.check("scaled OFDM (pilot spacing \(spacing), fraction \(fraction)) has data and distinct bins",
              !c.dataSubcarriers.isEmpty && bins.count == c.usedSubcarriers.count && !bins.contains(0))
      var l = RF.BasebandLink(RF.BasebandLinkConfig(waveform: .ofdm(modulation: .qpsk, config: c)))
      let f = l.next()
      k.check("… and simulates error-free without noise", !f.sentBits.isEmpty && f.bitErrors == 0)
    }
    // FSK / GFSK / GMSK.
    for (name, settings) in [("GMSK", RF.FSKSettings.gmsk()), ("BLE", .bluetoothLE()), ("BR", .bluetoothBR()), ("CPFSK", RF.FSKSettings(index: 0.5, bt: nil))] {
      var modulator = RF.FSKModulator(settings)
      let bits = rng.bits(400)
      let w = modulator.modulate(bits: bits + [0, 0, 0, 0])
      let got = RF.FSKDemodulator(settings).demodulate(w, offset: modulator.filterDelay, symbols: 400)
      k.check("\(name) round trip", got == bits)
    }
    var ble = RF.FSKModulator(.bluetoothLE())
    let ones = ble.modulate(bits: [UInt8](repeating: 1, count: 40))
    let ph = ones.phases()
    var dphi = Double(ph[200] - ph[199])
    if dphi < -pi { dphi += 2 * pi }
    k.close("BLE steady tone at +250 kHz", dphi / (2 * pi) * 8e6, 250e3, rel: 1e-4)
    // DSSS codes.
    for len in [3, 7, 15, 31, 63, 127, 255, 511, 1023] {
      guard let code = RF.SpreadingCode.forLength(len) else {
        k.check("m-sequence \(len) exists", false)
        continue
      }
      let off = (1..<len).map { code.autocorrelation(lag: $0) }
      k.check("m-sequence \(len): off-peak autocorrelation −1/L", off.allSatisfy { abs($0 + 1 / Double(len)) < 1e-12 })
    }
    let barker = RF.SpreadingCode.barker11
    k.check("Barker-11 sidelobes ≤ 1/11 (aperiodic)", (1..<11).allSatisfy { lag in
      abs((0..<(11 - lag)).reduce(0.0) { $0 + Double(barker.chips[$1] * barker.chips[$1 + lag]) }) <= 1 + 1e-12
    })
    let spreader = RF.DSSSSpreader(code: .mSequence127)
    let ds = RF.Constellation(.qpsk).map(bits: rng.bits(40))
    let despread = spreader.despread(spreader.spread(ds))
    k.check("DSSS spread → despread", RF.Constellation(.qpsk).demap(despread) == RF.Constellation(.qpsk).demap(ds))
    // Analog modulators on real audio blocks.
    let audio = (0..<4800).map { Float(0.7 * sin(2 * pi * 440 * Double($0) / 48_000)) }
    var am = RF.AnalogModulator(RF.AnalogSettings(kind: .am))
    var amd = RF.AnalogDemodulator(RF.AnalogSettings(kind: .am))
    amd.dcBlock = false
    let amOut = amd.demodulate(am.modulate(audio))
    k.check("AM round trip (known carrier)", zip(amOut, audio).allSatisfy { abs($0 - $1) < 1e-5 })
    var fmSettings = RF.AnalogSettings(kind: .fm)
    fmSettings.fmDeviation = 5000
    var fm = RF.AnalogModulator(fmSettings)
    var fmd = RF.AnalogDemodulator(fmSettings)
    let fmOut = fmd.demodulate(fm.modulate(audio))
    k.check("FM round trip", zip(fmOut.dropFirst(), audio.dropFirst()).allSatisfy { abs($0 - $1) < 2e-4 })
    var pm = RF.AnalogModulator(RF.AnalogSettings(kind: .pm))
    var pmd = RF.AnalogDemodulator(RF.AnalogSettings(kind: .pm))
    pmd.dcBlock = false
    let pmOut = pmd.demodulate(pm.modulate(audio))
    k.check("PM round trip", zip(pmOut, audio).allSatisfy { abs($0 - $1) < 1e-5 })
    // Text messages.
    k.check("text → bits → text", RF.Bits.toText(RF.Bits.fromText("Spectra ⚡︎ 5G")) == "Spectra ⚡︎ 5G")
    // Transmitter and Receiver as separate streaming stages (Patch Modulator → Demodulator),
    // fed blocks that do not line up with symbols or frames.
    let streams: [(String, RF.Waveform, Int)] = [
      ("linear 16QAM RRC", .linear(modulation: .qam16, symbolRate: 1e6, pulse: .rootRaisedCosine(rolloff: 0.35)), 777),
      ("OOK NRZ", .linear(modulation: .ook, symbolRate: 1e5, pulse: .rectangular), 300),
      ("GMSK", .fsk(index: 0.5, bt: 0.3, symbolRate: 270_833), 333),
      ("DSSS QPSK 127", .dsss(modulation: .qpsk, chipsPerSymbol: 127, chipRate: 1e6), 500),
      ("OFDM preamble", .ofdm(modulation: .qam64, config: .wifiLegacy), 1000),
      ("OFDM pilots", .ofdm(modulation: .qam256, config: .scaled(name: "t", fftSize: 128, subcarrierSpacing: 15e3)), 1024),
    ]
    for (name, waveform, block) in streams {
      let settings = RF.WaveformSettings(waveform: waveform)
      var tx = RF.Transmitter(settings)
      var rx = RF.Receiver(settings)
      var sent: [UInt8] = []
      var stream = RF.IQBuffer()
      for _ in 0..<3 {
        let b = rng.bits(settings.framePlan.bits)
        sent += b
        stream.append(tx.modulate(bits: b).samples)
      }
      // One more frame flushes the transmit filter's tail (not compared), then silence.
      stream.append(tx.modulate(bits: [UInt8](repeating: 0, count: settings.framePlan.bits)).samples)
      stream.append(RF.IQBuffer(count: 600))
      var got: [UInt8] = []
      var pos = 0
      while pos < stream.count {
        let end = min(stream.count, pos + block)
        got += rx.receive(stream.slice(pos..<end)).bits
        pos = end
      }
      k.check("stream \(name): blocks of \(block) decode in order", got.count >= sent.count && zip(sent, got).allSatisfy { $0 == $1 },
              "\(got.count) bits for \(sent.count) sent")
    }
    var fmSet = RF.WaveformSettings(waveform: .analogFM(deviation: 75e3, audioBandwidth: 15e3))
    fmSet.targetSamples = 4096
    k.check("FM IQ rate ≥ 2.5 × Carson", fmSet.sampleRate >= 2.5 * 180e3 && fmSet.analogOversampling == 10)
    k.close("occupied bandwidth: 802.11a 52 × 312.5 kHz", RF.WaveformSettings(waveform: .ofdm(modulation: .qam64, config: .wifiLegacy)).occupiedBandwidth, 16.25e6)
    k.close("occupied bandwidth: RRC (1 + β)R_s", RF.WaveformSettings(waveform: .linear(modulation: .qpsk, symbolRate: 1e6, pulse: .rootRaisedCosine(rolloff: 0.35))).occupiedBandwidth, 1.35e6)
    // FMCW chirp (SPEC-features §3c): instantaneous frequency −B/2 + B·m/M, a straight line of
    // slope B/T in time–frequency, unit power, restarting at −B/2 every chirp.
    let radar = RF.SystemsCatalog.system(id: "fmcw-77")!
    let chirpSettings = RF.WaveformSettings(waveform: radar.waveform)
    k.close("FMCW 77: sample rate 2B = 2 GS/s", chirpSettings.sampleRate, 2e9)
    k.check("FMCW 77: one chirp = 4096 samples", chirpSettings.chirpSamples == 4096)
    k.close("FMCW 77: occupied bandwidth = B", chirpSettings.occupiedBandwidth, 1e9)
    var chirpTX = RF.Transmitter(chirpSettings)
    // Two calls of 1.5 chirps each: the sweep must continue seamlessly across calls.
    var sweep = chirpTX.sweep(count: 3 * 4096 / 2)
    sweep.append(chirpTX.sweep(count: 3 * 4096 / 2))
    k.close("FMCW sweep unit power", sweep.meanPower, 1, rel: 1e-5)
    var worstIF = 0.0
    var sxx = 0.0
    var sxy = 0.0
    for n in 0..<(sweep.count - 1) {
      let re = Double(sweep.i[n + 1] * sweep.i[n] + sweep.q[n + 1] * sweep.q[n])
      let im = Double(sweep.q[n + 1] * sweep.i[n] - sweep.i[n + 1] * sweep.q[n])
      let f = atan2(im, re) / (2 * pi) * 2e9
      let m = Double(n % 4096)
      worstIF = max(worstIF, abs(f - (-0.5e9 + 1e9 * m / 4096)))
      if n < 4096 { sxx += (m - 2047.5) * (m - 2047.5); sxy += (m - 2047.5) * f }
    }
    k.check("FMCW instantaneous frequency = −B/2 + B·m/M across 3 chirps (< 10 kHz)", worstIF < 1e4, String(format: "worst %.3g Hz", worstIF))
    k.close("FMCW slope B/T = 4.8828e14 Hz/s (regression)", sxy / sxx * 2e9, 1e9 / 2.048e-6, rel: 1e-6)
    var radarLink = RF.BasebandLink(RF.BasebandLinkConfig(system: radar))
    let radarFrame = radarLink.next()
    k.check("FMCW frame: 4096 samples, nothing to decode", radarFrame.tx.count == 4096 && radarFrame.received.isEmpty && radarFrame.sentBits.isEmpty)
    var chirpAnalyzer = RF.SpectrumAnalyzer(count: 4096, window: .hann)!
    let chirpSpectrum = chirpAnalyzer.powerDB(radarFrame.tx).map { pow(10, Double($0) / 10) }
    let inBand = (0..<4096).filter { abs(Double($0 - 2048)) < 1024 }.reduce(0.0) { $0 + chirpSpectrum[$1] }
    k.check("FMCW: > 99 % of the power inside ±B/2", inBand / chirpSpectrum.reduce(0, +) > 0.99,
            String(format: "%.4f", inBand / chirpSpectrum.reduce(0, +)))
    k.close("FMCW 24: chirp of 200 MHz in 10.24 µs", RF.WaveformSettings(waveform: RF.SystemsCatalog.system(id: "fmcw-24")!.waveform).sampleRate, 400e6)
    return k.results
  }

  // MARK: Channel and receiver (B.10–B.12 in simulation)

  static func channel() -> [RFCheckResult] {
    var k = RFCheckList("channel")
    let n = 1 << 16
    let ones = RF.IQBuffer(i: [Float](repeating: 1, count: n), q: [Float](repeating: 0, count: n))
    // AWGN at 10 dB: noise power 0.1.
    var awgn = RF.ChannelSimulator(config: RF.ChannelConfig(snrDB: 10, seed: 3), sampleRate: 1e6)
    let y = awgn.process(ones)
    var noisePower = 0.0
    for j in 0..<n { noisePower += Double((y.i[j] - 1) * (y.i[j] - 1) + y.q[j] * y.q[j]) }
    k.close("AWGN 10 dB noise power", noisePower / Double(n), 0.1, rel: 0.02)
    var again = RF.ChannelSimulator(config: RF.ChannelConfig(snrDB: 10, seed: 3), sampleRate: 1e6)
    k.check("AWGN is seeded (same seed, same noise)", again.process(ones) == y)
    // Rayleigh by sum of sinusoids: unit mean power and the exponential outage law.
    var power = 0.0
    var below10 = 0
    var count = 0
    for seed in 1...40 {
      var rng = RF.SeededRandom(seed: UInt64(seed))
      let sos = RF.SumOfSinusoids(maxDoppler: 50, sinusoids: 16, rng: &rng)
      var t = 0.0
      while t < 20 {
        let g = sos.gain(at: t).magnitudeSquared
        power += g
        if g < 0.1 { below10 += 1 }
        count += 1
        t += 0.007
      }
    }
    k.close("Rayleigh SoS mean power", power / Double(count), 1, abs: 0.05)
    k.close("Rayleigh SoS outage −10 dB ≈ 0.0952", Double(below10) / Double(count), 0.095_16, abs: 0.015)
    // Clarke autocorrelation J0(2πf_mτ) at τ = 2.405/(2π f_m) is ≈ 0.
    var corr = 0.0
    var corrCount = 0
    for seed in 1...2000 {
      var rng = RF.SeededRandom(seed: UInt64(seed) &* 77)
      let sos = RF.SumOfSinusoids(maxDoppler: 10, sinusoids: 16, rng: &rng)
      let a = sos.gain(at: 0.3)
      let b = sos.gain(at: 0.3 + 2.404_825_557_7 / (2 * pi * 10))
      corr += (a * b.conjugate).re
      corrCount += 1
    }
    k.close("Clarke correlation zero at J0's first null", corr / Double(corrCount), 0, abs: 0.06)
    // CFO rotates by 2πft.
    var cfo = RF.ChannelSimulator(config: RF.ChannelConfig(frequencyOffsetHz: 1000), sampleRate: 1e6)
    let rotated = cfo.process(RF.IQBuffer(i: [Float](repeating: 1, count: 1000), q: [Float](repeating: 0, count: 1000)))
    k.close("CFO phase after 250 samples = π/2", Double(atan2(rotated.q[250], rotated.i[250])), pi / 2, abs: 1e-5)
    // Multipath taps sum to unit power with an exponential profile.
    let mp = RF.ChannelSimulator(config: RF.ChannelConfig(delaySpread: 200e-9), sampleRate: 20e6)
    k.close("multipath tap powers sum to 1", mp.tapPowers.reduce(0, +), 1, rel: 1e-12)
    k.check("multipath profile decays", zip(mp.tapPowers, mp.tapPowers.dropFirst()).allSatisfy { $0 > $1 })
    // The simulated taps keep the requested RMS delay spread, including when 5σ_τ needs more than
    // 32 one-sample taps (1 µs at 20 MS/s used to come out at 0.43 µs, at 2.66 GS/s at 3.5 ns).
    for (fs, sigma) in [(20e6, 100e-9), (3.84e6, 300e-9), (20e6, 1e-6), (2.6624e9, 1e-6), (2.1667e6, 1e-6)] {
      let ch = RF.ChannelSimulator(config: RF.ChannelConfig(delaySpread: sigma), sampleRate: fs)
      k.close("channel σ_τ \(sigma * 1e9) ns at \(fs / 1e6) MS/s (\(ch.tapDelays.count) taps)", ch.rmsDelaySpread, sigma, rel: 1e-6)
    }
    var negativeK = RF.ChannelSimulator(config: RF.ChannelConfig(snrDB: 20, dopplerHz: 10, fading: .rician(k: -1)), sampleRate: 1e6)
    k.check("Rician K < 0 is read as Rayleigh (no NaN)", negativeK.process(ones.slice(0..<256)).i.allSatisfy(\.isFinite))
    // OFDM equalizer removes static multipath inside the CP; single carrier suffers ISI.
    var cfg = RF.BasebandLinkConfig(waveform: .ofdm(modulation: .qam64, config: .wifiLegacy))
    cfg.delaySpread = 100e-9
    cfg.snrDB = 40
    var ofdm = RF.BasebandLink(cfg)
    var ofdmErrors = 0
    for _ in 0..<5 { ofdmErrors += ofdm.next().bitErrors }
    k.check("OFDM preamble + equalizer: 64QAM through 100 ns multipath, 40 dB, no errors", ofdmErrors == 0, "\(ofdmErrors) errors")
    var lteCfg = RF.BasebandLinkConfig(system: RF.SystemsCatalog.system(id: "lte")!)
    lteCfg.delaySpread = 300e-9
    lteCfg.snrDB = 40
    var lte = RF.BasebandLink(lteCfg)
    var lteErrors = 0
    for _ in 0..<5 { lteErrors += lte.next().bitErrors }
    k.check("OFDM scattered pilots: LTE 256QAM through 300 ns multipath, 40 dB, no errors", lteErrors == 0, "\(lteErrors) errors")
    var cfoCfg = RF.BasebandLinkConfig(waveform: .ofdm(modulation: .qam16, config: .wifiLegacy))
    cfoCfg.frequencyOffsetHz = 2000
    cfoCfg.snrDB = 30
    var cfoLink = RF.BasebandLink(cfoCfg)
    var cfoErrors = 0
    for _ in 0..<5 { cfoErrors += cfoLink.next().bitErrors }
    k.check("OFDM pilots track a 2 kHz CFO (16QAM, 30 dB)", cfoErrors == 0, "\(cfoErrors) errors")
    var sc = RF.BasebandLinkConfig(waveform: .linear(modulation: .qam64, symbolRate: 20e6, pulse: .rootRaisedCosine(rolloff: 0.35)))
    sc.delaySpread = 100e-9
    sc.snrDB = 40
    var single = RF.BasebandLink(sc)
    _ = single.next()
    let scEVM = single.next().evm?.percent ?? 0
    k.check("single carrier at 20 Msym/s smears in the same multipath (EVM > 10 %)", scEVM > 10, String(format: "%.1f %%", scEVM))
    // Monte-Carlo BER against AWGN theory.
    for (mod, eb) in [(RF.DigitalModulation.bpsk, 6.0), (.qam16, 10.0)] {
      var c = RF.BasebandLinkConfig(waveform: .linear(modulation: mod, symbolRate: 1e6, pulse: .rootRaisedCosine(rolloff: 0.35)))
      c.snrDB = RF.Noise.esN0DB(ebN0DB: eb, bitsPerSymbol: mod.bitsPerSymbol)
      c.seed = 11
      var link = RF.BasebandLink(c)
      var counter = RF.BERCounter()
      for _ in 0..<800 {
        let f = link.next()
        counter.add(sent: f.sentBits, received: f.receivedBits)
      }
      let theory = RF.ErrorRates.ber(mod, ebN0DB: eb) ?? .nan
      k.close("Monte-Carlo \(mod.rawValue) BER at \(eb) dB vs theory", counter.ber, theory, rel: 0.1)
    }
    var oc = RF.BasebandLinkConfig(waveform: .ofdm(modulation: .qpsk, config: .wifiLegacy))
    oc.snrDB = RF.Noise.esN0DB(ebN0DB: 6, bitsPerSymbol: 2)
    oc.seed = 5
    var ol = RF.BasebandLink(oc)
    var oCounter = RF.BERCounter()
    // The training estimate averages over frames (running mean, then 16-frame memory): skip the
    // first 16 frames, after which the estimation noise costs about 0.1 dB.
    for _ in 0..<16 { _ = ol.next() }
    for _ in 0..<100 {
      let f = ol.next()
      oCounter.add(sent: f.sentBits, received: f.receivedBits)
    }
    k.close("Monte-Carlo OFDM QPSK BER (averaged training estimate) vs theory", oCounter.ber, RF.ErrorRates.bpskBER(ebN0DB: 6), rel: 0.2)
    // EVM tracks the set SNR when noise-limited (SNR ≈ −EVM_dB).
    var ec = RF.BasebandLinkConfig(waveform: .linear(modulation: .qam16, symbolRate: 1e6, pulse: .rootRaisedCosine(rolloff: 0.35)))
    ec.snrDB = 25
    var el = RF.BasebandLink(ec)
    _ = el.next()
    k.close("EVM-estimated SNR ≈ set E_s/N₀", el.next().evm?.estimatedSNRDB ?? 0, 25, abs: 0.6)
    // Analog voice through FM at high CNR comes back clean.
    var fc = RF.BasebandLinkConfig(waveform: .analogFM(deviation: 75e3, audioBandwidth: 15e3))
    fc.snrDB = 40
    var fl = RF.BasebandLink(fc)
    let voice = (0..<1024).map { Float(0.6 * sin(2 * pi * 440 * Double($0) / 48_000)) }
    var outAudio: [Float] = []
    for _ in 0..<6 { outAudio += fl.next(audio: voice).audio ?? [] }
    let steady = Array(outAudio[(outAudio.count - 2048)...])
    let rms = (steady.reduce(0.0) { $0 + Double($1 * $1) } / Double(steady.count)).squareRoot()
    k.close("FM voice level preserved (RMS of 0.6 sine)", rms, 0.6 / 2.0.squareRoot(), rel: 0.03)
    var ac = RF.BasebandLinkConfig(waveform: .analogAM(depth: 0.8))
    ac.snrDB = 50
    var al = RF.BasebandLink(ac)
    var amAudio: [Float] = []
    for _ in 0..<12 { amAudio += al.next(audio: voice).audio ?? [] }
    let amSteady = Array(amAudio[(amAudio.count - 4096)...])
    let amRMS = (amSteady.reduce(0.0) { $0 + Double($1 * $1) } / Double(amSteady.count)).squareRoot()
    k.close("AM voice level preserved", amRMS, 0.6 / 2.0.squareRoot(), rel: 0.03)
    return k.results
  }

  // MARK: Link budget

  static func link() -> [RFCheckResult] {
    var k = RFCheckList("link")
    var x = RF.LinkBudgetInput(frequency: 2.45e9, bandwidth: 20e6)
    x.txPowerDBm = 20
    x.distance = 10
    x.noiseFigureDB = 7
    let r = RF.LinkBudget.evaluate(x)
    k.printed("budget = Friis", r.receivedPowerDBm, -40.2311, decimals: 4)
    k.printed("budget noise floor", r.noiseFloorDBm, -93.9649, decimals: 4)
    k.close("budget SNR", r.snrDB, -40.231_1 + 93.964_9, abs: 1e-3)
    k.close("budget capacity = Shannon", r.capacity, RF.Noise.shannonCapacity(bandwidth: 20e6, snrDB: r.snrDB), rel: 1e-12)
    k.close("distance from RSSI inverts the budget", RF.LinkBudget.distance(forReceivedPower: -40.2311, input: x) ?? .nan, 10, rel: 1e-4)
    var y = x
    y.walls = [RF.WallLayer(.concrete, count: 1)]
    y.rainRate = 25
    y.frequency = 28e9
    y.includeGas = true
    y.distance = 200
    y.model = .tr38901(.urbanMicroNLOS)
    let s = RF.LinkBudget.evaluate(y)
    k.printed("UMi NLOS term", s.pathLossDB, 134.7460, decimals: 4)
    k.close("concrete wall at 28 GHz", s.wallsLossDB, 5 + 4 * 28)
    k.close("rain over 200 m at 28 GHz", s.rainLossDB, RF.Atmosphere.rainAttenuationDBPerKm(frequencyGHz: 28, rainRate: 25) * 0.2, rel: 1e-12)
    k.close("gas over 200 m", s.gasLossDB, RF.Atmosphere.gasAttenuationDBPerKm(frequencyGHz: 28) * 0.2, rel: 1e-12)
    let sum = s.terms.reduce(0.0) { $0 + $1.dB }
    k.close("budget bars add up to P_r", sum, s.receivedPowerDBm, abs: 1e-9)
    var gps = RF.LinkBudgetInput(frequency: 1575.42e6, bandwidth: 2.046e6)
    gps.distance = 20_200e3
    gps.txPowerDBm = -128.5 + RF.Propagation.fsplDB(distance: 20_200e3, frequency: 1575.42e6)
    let g = RF.LinkBudget.evaluate(gps)
    k.close("GPS budget lands at −128.5 dBm", g.receivedPowerDBm, -128.5, abs: 1e-9)
    var two = x
    two.model = .twoRay(txHeight: 30, rxHeight: 1.5)
    two.frequency = 900e6
    two.distance = 1000
    k.printed("two-ray model term", RF.LinkBudget.evaluate(two).pathLossDB, 88.0119, decimals: 4)
    var hata = x
    hata.model = .hata(environment: .smallMediumCity, baseHeight: 30, mobileHeight: 1.5)
    hata.frequency = 900e6
    hata.distance = 5000
    k.printed("Hata model term", RF.LinkBudget.evaluate(hata).pathLossDB, 151.0244, decimals: 4)
    hata.frequency = 2.4e9
    k.check("Hata outside 150–1500 MHz warns", !RF.LinkBudget.evaluate(hata).notes.isEmpty)
    var ke = x
    ke.frequency = 900e6
    ke.distance = 2000
    ke.obstructionHeight = 10
    k.printed("knife edge in the budget", RF.LinkBudget.evaluate(ke).diffractionLossDB, 14.4762, decimals: 4)
    k.check("range for 10 dB SNR exists", (RF.LinkBudget.range(forSNR: 10, input: x) ?? 0) > 10)
    var fm = RF.LinkBudgetInput(frequency: 98.1e6, bandwidth: 200e3)
    fm.distance = 10_000
    fm.rainRate = 100
    let fmRain = RF.LinkBudget.evaluate(fm)
    k.check("FM in 100 mm/h rain over 10 km: < 0.03 dB (was 6800 dB), with a P.838 range note",
            fmRain.rainLossDB < 0.03 && fmRain.notes.contains { $0.contains("P.838") }, String(format: "%.4g dB", fmRain.rainLossDB))
    let cw = RF.LinkBudget.evaluate(RF.LinkBudgetInput(frequency: 146e3, bandwidth: 0))
    k.check("zero bandwidth (Qi carrier): capacity 0, not NaN", cw.capacity == 0)
    k.check("zero bandwidth: spectral efficiency 0 (was +∞), SNR +∞", cw.spectralEfficiency == 0 && cw.snrDB == .infinity)
    return k.results
  }

  // MARK: Robustness (out-of-range and non-finite inputs from knobs, Patch cables or sensors)

  /// Every input here once trapped (Int(NaN), Int(∞)), produced NaN/∞, or ran for seconds.
  static func robustness() -> [RFCheckResult] {
    var k = RFCheckList("robustness")
    func finite(_ xs: [Float]) -> Bool { xs.allSatisfy(\.isFinite) }
    // Antenna models: NaN in every knob (was a trap in ThinDipole), and knobs far outside their
    // ranges (a 500λ horn integrated for 5 s; zero efficiencies gave −∞ dBi).
    for style in RF.AntennaStyle.allCases {
      var nan = RF.AntennaParameters(style: style, frequency: .nan)
      nan.shortDipoleLength = .nan; nan.dipoleLength = .nan; nan.monopoleHeight = .nan; nan.loopArea = .nan
      nan.loopTurns = .nan; nan.loopMuEffective = .nan; nan.patchEpsilonR = .nan; nan.patchHeight = .nan
      nan.yagiSpacing = .nan; nan.helixTurns = .nan; nan.helixCircumference = .nan; nan.helixSpacing = .nan
      nan.hornA = .nan; nan.hornB = .nan; nan.hornEfficiency = .nan; nan.dishDiameter = .nan; nan.dishEfficiency = .nan
      nan.arraySpacing = .nan; nan.steerTheta = .nan; nan.steerPhi = .nan; nan.radiationEfficiency = .nan
      nan.pifaCurrentPath = .nan; nan.referenceImpedance = .nan
      var wild = RF.AntennaParameters(style: style, frequency: -1)
      wild.dipoleLength = 50; wild.monopoleHeight = -1; wild.loopArea = -1; wild.patchEpsilonR = 0; wild.patchHeight = 0
      wild.yagiElements = 1000; wild.yagiSpacing = 5; wild.helixTurns = 1e4; wild.hornA = 500; wild.hornB = 0
      wild.hornEfficiency = 0; wild.dishDiameter = 5000; wild.dishEfficiency = 0; wild.arrayNx = 1000; wild.arrayNy = -3
      wild.arraySpacing = 10; wild.steerTheta = 500; wild.arrayElement = .patch; wild.radiationEfficiency = 0
      for (tag, p) in [("NaN knobs", nan), ("knobs out of range", wild)] {
        let m = RF.AntennaModel(p)
        let readouts: [Double] = [m.directivity, m.gainDBi, m.effectiveAperture, m.largestDimension, m.fieldRegions.farField, m.field(m.peakDirection),
                        m.ePlaneHPBWDeg ?? 0, m.hPlaneHPBWDeg ?? 0, m.radiationResistance?.value ?? 0]
        let mesh = RF.PatternMesh(model: m, rows: 19, columns: 24)
        k.check("\(style.rawValue), \(tag): finite readouts and mesh", readouts.allSatisfy(\.isFinite) && finite(mesh.values) && m.directivity >= 1 - 1e-6,
                readouts.map { String(format: "%.3g", $0) }.joined(separator: " "))
      }
      let clamped = RF.AntennaModel(wild).parameters
      let L = RF.AntennaParameters.Limits.self
      if style == .horn {
        k.check("horn 500λ is clamped to the knob limit 20λ", clamped.hornA == L.hornAperture.upperBound && clamped.hornB == L.hornAperture.lowerBound)
      }
      if style == .phasedArray {
        k.check("array 1000 × −3 at 10λ is clamped to 64 × 1 at 2λ, steer 90°",
                clamped.arrayNx == 64 && clamped.arrayNy == 1 && clamped.arraySpacing == 2 && clamped.steerTheta == 90)
      }
    }
    k.close("ThinDipole(NaN) is the half-wave dipole", RF.Antennas.ThinDipole(lengthWavelengths: .nan).directivity, 1.6409, abs: 1e-4)
    k.close("ULA with no elements has D = 1", RF.Arrays.directivity(elements: 0, spacing: 0.5, beta: 0), 1, rel: 1e-9)
    k.check("lobe search on a 10⁹λ spacing returns at once", RF.Arrays.lobeDirections(spacing: 1e9, beta: 0).isEmpty)
    // Demappers: NaN/∞ decision points used to trap in Int(NaN) (a NaN from any upstream node).
    let poison = RF.IQBuffer(i: [.nan, .infinity, -.infinity, 1e30, 0], q: [.nan, -.infinity, .infinity, -1e30, .nan])
    for mod in RF.DigitalModulation.allCases {
      let bits = RF.Constellation(mod).demap(poison)
      k.check("\(mod.rawValue) demaps NaN/∞ without trapping", bits.count == 5 * mod.bitsPerSymbol && bits.allSatisfy { $0 <= 1 })
    }
    var junk = RF.IQBuffer(count: 3000)
    for n in 0..<3000 {
      junk.i[n] = [Float.nan, .infinity, -.infinity][n % 3]
      junk.q[n] = .nan
    }
    for s in RF.SystemsCatalog.all {
      var rx = RF.Receiver(RF.WaveformSettings(waveform: s.waveform))
      let b = rx.receive(junk)
      k.check("\(s.id) receiver survives a NaN/∞ block", b.bits.allSatisfy { $0 <= 1 })
    }
    // Channel: NaN settings, zero sample rate, an absurd delay spread.
    var nanChannel = RF.ChannelConfig(snrDB: .nan, delaySpread: .nan, dopplerHz: .nan, fading: .rician(k: .nan), frequencyOffsetHz: .nan)
    nanChannel.seed = 4
    var ch = RF.ChannelSimulator(config: nanChannel, sampleRate: 1e6)
    let ones = RF.IQBuffer(i: [Float](repeating: 1, count: 512), q: [Float](repeating: 0, count: 512))
    k.check("NaN channel settings read as off", finite(ch.process(ones).i) && ch.config.snrDB == nil && ch.tapDelays == [0])
    var zeroRate = RF.ChannelSimulator(config: RF.ChannelConfig(snrDB: 10, delaySpread: 1e-6, dopplerHz: 50, fading: .rayleigh), sampleRate: 0)
    let zr = zeroRate.process(ones)
    k.check("sample rate 0 reads as 1 Hz: finite output", finite(zr.i) && finite(zr.q) && zeroRate.sampleRate == 1)
    let huge = RF.ChannelSimulator(config: RF.ChannelConfig(delaySpread: 1), sampleRate: 1e9)
    k.check("1 s delay spread at 1 GS/s: delay line capped at 2²² samples", (huge.tapDelays.last ?? 0) <= 4_194_304 && huge.tapDelays.count <= 32)
    // Waveforms at the edges of their knobs.
    let gTaps0 = RF.DSP.gaussianTaps(bt: 0, samplesPerSymbol: 8)
    let gTapsInf = RF.DSP.gaussianTaps(bt: .infinity, samplesPerSymbol: 8)
    k.check("Gaussian BT 0 (was 0/0 = NaN): flat taps summing to 1", finite(gTaps0) && abs(Double(gTaps0.reduce(0, +)) - 1) < 1e-6)
    k.check("Gaussian BT ∞: a single centre tap", gTapsInf[16] == 1 && gTapsInf.reduce(0, +) == 1)
    k.check("RRC with NaN roll-off and 0 samples/symbol stays finite", finite(RF.DSP.rootRaisedCosine(rolloff: .nan, samplesPerSymbol: 0, spanSymbols: 0)))
    let edges: [(String, RF.Waveform)] = [
      ("GFSK BT 0", .fsk(index: 0.5, bt: 0, symbolRate: 1e6)),
      ("FM with no deviation or audio (was ∞ noise)", .analogFM(deviation: 0, audioBandwidth: 0)),
      ("FM ±10 MHz (oversampling capped at 64)", .analogFM(deviation: 10e6, audioBandwidth: 15e3)),
      ("linear at 0 sym/s", .linear(modulation: .qam64, symbolRate: 0, pulse: .rootRaisedCosine(rolloff: 0.35))),
      ("chirp with B = 0, T = NaN", .chirp(bandwidth: 0, duration: .nan)),
    ]
    for (name, w) in edges {
      var c = RF.BasebandLinkConfig(waveform: w)
      c.snrDB = 20
      c.fading = .rayleigh
      c.dopplerHz = 50
      c.delaySpread = 100e-9
      var link = RF.BasebandLink(c)
      var ok = true
      for _ in 0..<2 {
        let f = link.next()
        ok = ok && finite(f.tx.i) && finite(f.rx.i) && finite(f.rx.q) && finite(f.received.i) && finite(f.audio ?? [])
      }
      k.check("\(name): finite frames", ok)
    }
    k.check("FM analog oversampling capped", RF.WaveformSettings(waveform: .analogFM(deviation: 10e6, audioBandwidth: 15e3)).analogOversampling == 64)
    let odd = RF.OFDMConfig.scaled(name: "odd", fftSize: 1000, usedFraction: .nan, cpFraction: -1, subcarrierSpacing: 15e3)
    k.check("scaled OFDM rounds 1000 points up to 1024 (a 1000-point FFT cannot be built)", odd.fftSize == 1024 && odd.cyclicPrefix >= 1)
    var oddLink = RF.BasebandLink(RF.BasebandLinkConfig(waveform: .ofdm(modulation: .qam16, config: odd)))
    let oddFrame = oddLink.next()
    k.check("… and its link decodes without noise", !oddFrame.sentBits.isEmpty && oddFrame.bitErrors == 0)
    // Link budget, propagation and helpers.
    var lb = RF.LinkBudgetInput(frequency: 0, bandwidth: -5)
    lb.distance = .nan
    let r = RF.LinkBudget.evaluate(lb)
    k.check("link budget with f 0, B −5, d NaN: finite received power, a note, no capacity",
            r.receivedPowerDBm.isFinite && !r.notes.isEmpty && r.capacity == 0 && r.spectralEfficiency == 0)
    k.close("P.2109 at f 0 uses its 0.08 GHz edge (was NaN)", RF.Building.entryLossDB(frequencyGHz: 0, building: .traditional),
            RF.Building.entryLossDB(frequencyGHz: 0.08, building: .traditional), rel: 1e-12)
    k.check("NR-ARFCN of ∞ / NaN stays on the raster", RF.Numerology.NR.frequencyToARFCN(.infinity) == 3_279_165 && RF.Numerology.NR.frequencyToARFCN(.nan) == 0)
    k.check("resample to an ∞ rate returns the input", RF.DSP.resampleLinear([1, 2, 3], from: 1, to: .infinity) == [1, 2, 3])
    k.check("FIR with −3 taps gives 1 tap", RF.DSP.firTaps(.lowpass, cutoff: 0.1, taps: -3).count == 1)
    k.check("decimate by 0 returns the input", RF.DSP.decimate([1, 2, 3], factor: 0) == [1, 2, 3])
    return k.results
  }
}

// MARK: - XCTest

#if !SPECTRA_HARNESS
final class RFTests: XCTestCase {
  private func assertGroup(_ group: String, file: StaticString = #filePath, line: UInt = #line) {
    let results = RFOracles.run(group)
    XCTAssertFalse(results.isEmpty, "\(group): no checks", file: file, line: line)
    for r in results where !r.passed {
      XCTFail("\(group) / \(r.name): \(r.detail)", file: file, line: line)
    }
  }

  func testConstants() { assertGroup("constants") }
  func testAntennaFormulas() { assertGroup("antennas") }
  func testAntennaPatternModel() { assertGroup("antenna-model") }
  func testArrays() { assertGroup("arrays") }
  func testPropagation() { assertGroup("propagation") }
  func testAtmosphere() { assertGroup("atmosphere") }
  func testBuildingEntry() { assertGroup("building") }
  func testFading() { assertGroup("fading") }
  func testNoiseAndCapacity() { assertGroup("noise") }
  func testErrorRatesAndEVM() { assertGroup("error-rates") }
  func testAnalogTheory() { assertGroup("analog") }
  func testNumerology() { assertGroup("numerology") }
  func testSystemsCatalog() { assertGroup("systems") }
  func testDSP() { assertGroup("dsp") }
  func testModulationRoundTrips() { assertGroup("modulation") }
  func testChannelAndReceiver() { assertGroup("channel") }
  func testLinkBudget() { assertGroup("link") }
  func testRobustness() { assertGroup("robustness") }

  /// Generating and analysing 4096 complex samples (OFDM 256-QAM through multipath + AWGN,
  /// receive, Hann spectrum). The 2 ms budget is for an optimized build on the iPhone; Debug
  /// builds are several times slower, so this only guards against gross regressions.
  func testFramePerformance() {
    var cfg = RF.BasebandLinkConfig(system: RF.SystemsCatalog.system(id: "nr-fr1")!)
    cfg.snrDB = 30
    cfg.delaySpread = 100e-9
    var link = RF.BasebandLink(cfg)
    var analyzer = RF.SpectrumAnalyzer(count: 4096)!
    var spectrum = [Float]()
    _ = link.next()
    let start = Date()
    for _ in 0..<20 {
      let f = link.next()
      analyzer.powerDB(f.rx, into: &spectrum)
    }
    let ms = Date().timeIntervalSince(start) / 20 * 1000
    XCTAssertLessThan(ms, 50, "frame took \(ms) ms")
  }
}
#endif
