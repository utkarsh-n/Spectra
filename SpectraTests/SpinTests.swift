// Spin engine oracles: every row of gyre-integration.md §10 the spin engine owns (with the
// review's corrections), Gyre's eight physcheck cases ported to HeavyTop, and the worked values
// of §4.1, §4.8, §4.10 and §5.
//
// One source for two runners: XCTest (`SpinTests` below, in the app's test target) and the
// macOS harness (Tools/check-spin.sh compiles this file with Spectra/Spin/*.swift and
// Tools/harness/spin/main.swift, -D SPECTRA_HARNESS). P.676 γ_o lives with the RF engine's tests.
import Foundation
import simd

#if !SPECTRA_HARNESS
  import XCTest

  @testable import Spectra
#endif

/// One oracle comparison.
nonisolated struct SpinCheck: Sendable, Hashable {
  let name: String
  let passed: Bool
  let detail: String
}

/// Collects the comparisons of one group.
nonisolated struct SpinCheckLog: Sendable {
  private(set) var checks: [SpinCheck] = []

  mutating func check(_ name: String, _ ok: Bool, _ detail: String) {
    checks.append(SpinCheck(name: name, passed: ok, detail: detail))
  }
}

/// The oracle suite, grouped as the XCTest methods are.
nonisolated enum SpinOracleSuite {
  struct Group: Sendable {
    let name: String
    let run: @Sendable () -> [SpinCheck]
  }

  static let groups: [Group] = [
    Group(name: "Larmor, cyclotron, g − 2", run: larmorCyclotronAndGMinusTwo),
    Group(name: "Rabi and Bloch", run: rabiAndBloch),
    Group(name: "Lab frame vs rotating frame", run: labFrame),
    Group(name: "Ensemble, dephasing, echo", run: ensemble),
    Group(name: "FID signal and spectrum", run: fidSignal),
    Group(name: "Earth field and readouts", run: earthField),
    Group(name: "Gyre physcheck", run: physcheck),
    Group(name: "Heavy top worked values", run: heavyTopWorkedValues),
    Group(name: "Rotor magnetic resonance", run: rotorResonance),
    Group(name: "Gyroscope tip IQ", run: tipIQ),
    Group(name: "Charged particles", run: charges),
    Group(name: "Optics, air, turntable", run: opticsAirTurntable),
    Group(name: "Knobs, blocks, sound", run: knobsAndBlocks),
    Group(name: "Robustness at the edges", run: robustness),
  ]

  static let uT = 1e-6
  static let water = SpinSpecies.protonWater

  static func rel(_ a: Double, _ b: Double) -> Double { abs(a - b) / max(abs(b), 1e-300) }
  static func fmt(_ x: Double, _ digits: Int = 6) -> String { String(format: "%.\(digits)g", x) }

  // MARK: - Larmor, cyclotron, g − 2 (§4.1, §5.4b, §10 rows 1–4)

  static func larmorCyclotronAndGMinusTwo() -> [SpinCheck] {
    var log = SpinCheckLog()
    let fp = water.larmorHz(field: 50 * uT)
    log.check("proton Larmor (shielded) 50 µT", rel(fp, 2128.8192715) < 1e-9, "\(fmt(fp, 12)) Hz vs 2128.8192715")
    let fe = SpinSpecies.electron.larmorHz(field: 50 * uT)
    log.check("electron Larmor 50 µT", rel(fe, 1.401247569305e6) < 1e-9, "\(fmt(fe, 13)) Hz vs 1401247.569305")
    let fc = Gyration.cyclotronHz(.electron, field: 50 * uT)
    log.check("electron cyclotron 50 µT", rel(fc, 1.3996244917e6) < 1e-9, "\(fmt(fc, 11)) Hz vs 1399624.4917")
    let ratio = fe / fc
    log.check(
      "f_s/f_c = 1 + aₑ", abs(ratio - 1.00115965218) < 1e-11 && abs(ratio - (1 + SpinConstants.electronAnomaly)) < 5e-13,
      "\(fmt(ratio, 15)) (Δ vs CODATA 1 + aₑ: \(fmt(ratio - (1 + SpinConstants.electronAnomaly), 2)))")
    let beat = Gyration.gMinusTwoBeatHz(field: 50 * uT)
    log.check(
      "g − 2 beat 50 µT", abs(beat - 1623.08) < 0.01 && rel(beat, SpinConstants.electronAnomaly * fc) < 1e-6,
      "\(fmt(beat, 7)) Hz = aₑ f_c")
    let pc = Gyration.cyclotronHz(.proton, field: 50 * uT)
    let pr = Gyration.protonSpinToCyclotronRatio()
    log.check(
      "proton orbit vs spin", rel(pc, 762.2) < 1e-4 && rel(pr, SpinConstants.protonMomentNuclearMagnetons) < 1e-8,
      "f_c \(fmt(pc, 6)) Hz (doc 762.2), f_L/f_c \(fmt(pr, 10)) = μₚ/μ_N")
    // Worked table (§4.1): proton to 0.01 Hz, MHz columns to their last printed digit (10 Hz),
    // the beat to 0.1 Hz. The 45.65 µT row is Gyre's |(0, 22, −40)| = 45.6508 µT.
    let rows: [(Double, Double, Double, Double, Double)] = [
      (25 * uT, 1064.41, 0.70062e6, 0.69981e6, 811.5),
      (simd_length(SIMD3<Double>(0, 22, -40)) * uT, 1943.65, 1.27936e6, 1.27788e6, 1481.9),
      (50 * uT, 2128.82, 1.40125e6, 1.39962e6, 1623.1),
      (65 * uT, 2767.47, 1.82162e6, 1.81951e6, 2110.0),
    ]
    var worst = 0.0
    for (b, p, e, c, d) in rows {
      worst = max(worst, abs(water.larmorHz(field: b) - p) / 0.005)
      worst = max(worst, abs(SpinSpecies.electron.larmorHz(field: b) - e) / 5)
      worst = max(worst, abs(Gyration.cyclotronHz(.electron, field: b) - c) / 5)
      worst = max(worst, abs(Gyration.gMinusTwoBeatHz(field: b) - d) / 0.05)
    }
    let f390 = water.larmorHz(field: 390 * uT)
    let e390 = SpinSpecies.electron.larmorHz(field: 390 * uT)
    log.check(
      "Larmor/cyclotron table 25–65 µT and 390 µT", worst <= 1 && abs(f390 - 16_605) < 0.5 && abs(e390 - 10.930e6) < 500,
      "worst |Δ|/half-digit \(fmt(worst, 3)); 390 µT: ¹H \(fmt(f390, 6)) Hz, e⁻ \(fmt(e390 / 1e6, 5)) MHz")
    log.check(
      "proton line per µT", abs(LarmorSonification.pitchJitterHz(species: water, fieldNoise: 1 * uT) - 42.58) < 0.01,
      "42.58 Hz/µT: σ_f = 42.58 Hz/µT × σ_B")
    let lp = water.larmorWavelength(field: 50 * uT)
    let le = SpinSpecies.electron.larmorWavelength(field: 50 * uT)
    log.check(
      "Larmor wavelengths", abs(lp / 1000 - 140.8) < 0.05 && abs(le - 213.9) < 0.1,
      "¹H \(fmt(lp / 1000, 5)) km, e⁻ \(fmt(le, 5)) m")
    let lo = SpinSpecies.electron.field(forLarmorHz: 530e3) / uT
    let hi = SpinSpecies.electron.field(forLarmorHz: 1700e3) / uT
    log.check(
      "electron AM-band chip is conditional",
      LarmorSonification.isInAMBroadcastBand(fe)
        && !LarmorSonification.isInAMBroadcastBand(SpinSpecies.electron.larmorHz(field: 65 * uT))
        && abs(lo - 18.9) < 0.05 && abs(hi - 60.7) < 0.05,
      "in band for \(fmt(lo, 3))–\(fmt(hi, 3)) µT; 65 µT → 1.82 MHz (160 m band)")
    let p = water.thermalPolarization(field: 50 * uT, temperature: 298.15)
    let m0 = water.curieMagnetization(field: 50 * uT, temperature: 298.15)
    log.check(
      "why the phone can't do NMR", abs(p - 1.71e-10) < 0.01e-10 && abs(m0 - 1.61e-7) < 0.01e-7,
      "P \(fmt(p, 3)), M₀ \(fmt(m0, 3)) A/m")
    log.check(
      "species signs and senses",
      water.precessionSense == .clockwise && SpinSpecies.electron.precessionSense == .counterclockwise
        && SpinSpecies.neutron.gamma < 0 && SpinSpecies.helion.gamma < 0
        && rel(SpinSpecies.proton.gammaHzPerT / water.gammaHzPerT - 1, 2.567e-5) < 1e-3,
      "γ > 0 clockwise about B; e⁻, n, ³He counterclockwise; shielding 25.67 ppm")
    return log.checks
  }

  // MARK: - Rabi and Bloch (§4.1, §10 rows 5–7)

  static func rabiAndBloch() -> [SpinCheck] {
    var log = SpinCheckLog()
    let f1 = water.rabiHz(b1: 1 * uT)
    let t90 = water.ninetyDuration(b1: 1 * uT)
    log.check(
      "Rabi f₁ and pulse times",
      abs(f1 - 42.576) < 0.001 && rel(t90, 5.8718e-3) < 1e-4 && rel(water.oneEightyDuration(b1: 1 * uT), 11.744e-3) < 1e-4
        && rel(water.ninetyDuration(b1: 0.1 * uT), 58.72e-3) < 1e-4 && rel(water.ninetyDuration(b1: 10 * uT), 0.587e-3) < 1e-3
        && rel(water.rabiAngular(b1: 1 * uT), 2 * .pi * f1) < 1e-15,
      "f₁ \(fmt(f1, 6)) Hz, t_π/2 \(fmt(t90 * 1e3, 6)) ms, t_π \(fmt(water.oneEightyDuration(b1: 1 * uT) * 1e3, 6)) ms")

    // §10: B₁ 1 µT on resonance, no relaxation, t = 5.8718 ms → M_z/M₀ < 1e-6. The printed time
    // is 5.8718 ms; 1/(4f₁) = 5.871802 ms, so M_z there is ~1e-7.
    var sim = BlochSimulator(b0: 50 * uT, drive: BlochDrive(b1: 1 * uT, continuous: true), relaxation: .none)
    for _ in 0..<7 { sim.step(5.8718e-3 / 7) }
    var exact = BlochSimulator(b0: 50 * uT, drive: BlochDrive(b1: 1 * uT, continuous: true), relaxation: .none)
    exact.step(t90)
    log.check(
      "Bloch π/2 (CW B₁ 1 µT, 5.8718 ms)",
      abs(sim.magnetization.z) < 1e-6 && abs(exact.magnetization.z) < 1e-12 && abs(sim.transverseMagnitude - 1) < 1e-6,
      "M_z \(fmt(sim.magnetization.z, 3)) at 5.8718 ms, \(fmt(exact.magnetization.z, 2)) at exactly 1/(4f₁)")
    var pulsed = BlochSimulator(b0: 50 * uT, drive: BlochDrive(b1: 1 * uT), relaxation: .none)
    pulsed.startPulse(.ninety)
    pulsed.step(0.004)
    pulsed.step(0.004)
    log.check(
      "finite π/2 pulse ends on time",
      abs(pulsed.magnetization.z) < 1e-9 && !pulsed.isPulsing && pulsed.magnetization.y > 0.999_999,
      "M = (\(fmt(pulsed.magnetization.x, 2)), \(fmt(pulsed.magnetization.y, 9)), \(fmt(pulsed.magnetization.z, 2)))")
    var flip = BlochSimulator(b0: 50 * uT, drive: BlochDrive(b1: 2 * uT), relaxation: .none)
    flip.startPulse(RFPulse(degrees: 30))
    flip.step(0.1)
    log.check(
      "arbitrary flip angle (30°)", abs(flip.magnetization.z - cos(.pi / 6)) < 1e-12 && abs(flip.transverseMagnitude - 0.5) < 1e-12,
      "M_z \(fmt(flip.magnetization.z, 12)) vs cos 30°")
    let hard = RFPulse.ninety.rotate(SIMD3(0, 0, 1), gamma: water.gamma)
    let hardE = RFPulse.ninety.rotate(SIMD3(0, 0, 1), gamma: SpinSpecies.electron.gamma)
    let invert = RFPulse.oneEighty.rotate(SIMD3(0, 0, 1), gamma: water.gamma)
    log.check(
      "hard pulse senses",
      simd_distance(hard, SIMD3(0, 1, 0)) < 1e-15 && simd_distance(hardE, SIMD3(0, -1, 0)) < 1e-15
        && simd_distance(invert, SIMD3(0, 0, -1)) < 1e-15,
      "π/2 about x: γ > 0 +z → +y, γ < 0 +z → −y (rotation −γB₁); π inverts")

    // Off resonance (§10): f₁ 42.576 Hz, Δf 10 Hz → maximum inversion 0.94772; |M_xy| still reaches 1.
    let p = Bloch.maxInversionProbability(rabiHz: 42.576, offsetHz: 10)
    let tilt = Bloch.effectiveFieldTilt(rabiHz: 42.576, offsetHz: 10) * 180 / .pi
    var off = BlochSimulator(
      b0: 50 * uT, drive: BlochDrive(b1: 42.576 / water.gammaHzPerT, offsetHz: 10, continuous: true), relaxation: .none)
    var minZ = 1.0
    var maxXY = 0.0
    for _ in 0..<6000 {
      off.step(5e-6)
      minZ = min(minZ, off.magnetization.z)
      maxXY = max(maxXY, off.transverseMagnitude)
    }
    let simP = (1 - minZ) / 2
    log.check(
      "off-resonance maximum inversion", abs(p - 0.94772) < 1e-4 && abs(simP - 0.94772) < 1e-4,
      "f₁²/(f₁² + Δf²) \(fmt(p, 6)), simulated (1 − M_z,min)/2 \(fmt(simP, 6))")
    log.check(
      "off resonance |M_xy| still reaches 1", maxXY > 0.9999 && abs(tilt - 76.8) < 0.05 && abs(off.effectiveHz - 43.735) < 0.001,
      "max |M_xy| \(fmt(maxXY, 6)), B_eff tilt \(fmt(tilt, 4))°, f_eff \(fmt(off.effectiveHz, 6)) Hz")

    var fid = BlochSimulator(b0: 50 * uT, relaxation: BlochRelaxation(t1: .infinity, t2: 1, m0: 1))
    fid.applyHardPulse(.ninety)
    for _ in 0..<60 { fid.step(1.0 / 60) }
    log.check(
      "FID decay (T₂ 1 s, t 1 s)", abs(fid.transverseMagnitude - exp(-1)) < 1e-6,
      "|M⊥| \(fmt(fid.transverseMagnitude, 9)) vs e⁻¹")

    // Free precession phase: after a π/2 (M = +y) with the carrier 5 Hz below the line, the
    // rotating-frame M turns clockwise at Δf and the lab-frame M at the full f_L.
    var phased = BlochSimulator(b0: 50 * uT, drive: BlochDrive(offsetHz: 5), relaxation: .none)
    phased.applyHardPulse(.ninety)
    for _ in 0..<7 { phased.step(0.0137) }
    let tFree = 7 * 0.0137
    let rotPhase = atan2(phased.magnetization.y, phased.magnetization.x)
    let labPhase = atan2(phased.labMagnetization.y, phased.labMagnetization.x)
    let wantRot = SpinMath.wrapAngle(.pi / 2 - 2 * .pi * 5 * tFree)
    let wantLab = SpinMath.wrapAngle(.pi / 2 - 2 * .pi * water.larmorHz(field: 50 * uT) * tFree)
    log.check(
      "free precession phase (rotating and lab frame)",
      abs(SpinMath.wrapAngle(rotPhase - wantRot)) < 1e-9 && abs(SpinMath.wrapAngle(labPhase - wantLab)) < 1e-9,
      "after \(fmt(tFree * 1e3, 4)) ms: rotating \(fmt(rotPhase, 8)) rad (π/2 − 2πΔf t), lab \(fmt(labPhase, 8)) rad (π/2 − 2πf_L t)")

    var long = BlochSimulator(b0: 50 * uT, drive: BlochDrive(b1: 3 * uT, offsetHz: 7, continuous: true), relaxation: .none)
    for _ in 0..<200_000 { long.step(1e-3) }
    log.check(
      "long run stays on the sphere", abs(simd_length(long.magnetization) - 1) < 1e-10,
      "|M| − 1 = \(fmt(simd_length(long.magnetization) - 1, 2)) after 200 000 steps")

    // CW with relaxation: exact per step, so it lands on the solved steady state at any step.
    let relax = BlochRelaxation(t1: 0.1, t2: 0.05, m0: 1)
    var cw = BlochSimulator(
      b0: 50 * uT, drive: BlochDrive(b1: 10 / water.gammaHzPerT, offsetHz: 3, continuous: true), relaxation: relax)
    for _ in 0..<300 { cw.step(1.0 / 60) }
    let ss = cw.steadyState ?? .zero
    var coarse = cw
    coarse.reset()
    coarse.step(5)
    // Textbook CW steady state [Bloch 1946], independent of the solver and of sign conventions:
    // M_z/M₀ = (1 + (ΔT₂)²)/D, |M⊥|/M₀ = Ω₁T₂√(1 + (ΔT₂)²)/D, D = 1 + (ΔT₂)² + Ω₁²T₁T₂.
    let w1 = 2 * Double.pi * 10
    let dw = 2 * Double.pi * 3
    let denominator = 1 + dw * dw * 0.05 * 0.05 + w1 * w1 * 0.1 * 0.05
    let wantZ = (1 + dw * dw * 0.05 * 0.05) / denominator
    let wantXY = w1 * 0.05 * (1 + dw * dw * 0.05 * 0.05).squareRoot() / denominator
    log.check(
      "CW steady state",
      simd_distance(cw.magnetization, ss) < 1e-10 && simd_distance(coarse.magnetization, ss) < 1e-10
        && abs(ss.z - wantZ) < 1e-12 && abs(hypot(ss.x, ss.y) - wantXY) < 1e-12,
      "M(5 s) − M_ss: \(fmt(simd_distance(cw.magnetization, ss), 2)) in 300 frames, \(fmt(simd_distance(coarse.magnetization, ss), 2)) in one step; M_z \(fmt(ss.z, 6)) vs analytic \(fmt(wantZ, 6))")
    var split = SIMD3<Double>(0.3, -0.4, 0.5)
    let bEff = SIMD3<Double>(2e-7, -1e-7, 5e-8)
    let start = split
    for _ in 0..<20_000 { Bloch.step(&split, h: 1e-5, gamma: water.gamma, bEff: bEff, t1: 0.1, t2: 0.05, m0: 1) }
    let prop = Bloch.propagate(start, h: 0.2, gamma: water.gamma, bEff: bEff, t1: 0.1, t2: 0.05, m0: 1)
    log.check(
      "exact propagator = Strang limit", simd_distance(split, prop) < 1e-8,
      "|Δ| \(fmt(simd_distance(split, prop), 2)) after 0.2 s (Strang at h = 10 µs)")

    var ir = SpinEnsemble(count: 1, relaxation: BlochRelaxation(t1: 2.5, t2: 2, m0: 1))
    let irSignal = ir.acquire(.inversionRecovery(inversionTime: 1), duration: 1, sampleRate: 1)
    let expected = abs(1 - 2 * exp(-1 / 2.5))
    log.check(
      "inversion recovery", abs(simd_length(irSignal.last ?? .zero) - expected) < 1e-9,
      "|M⊥| \(fmt(simd_length(irSignal.last ?? .zero), 9)) vs |1 − 2e^(−Tᵢ/T₁)|")
    return log.checks
  }

  // MARK: - Lab frame vs rotating frame (rotation sense, corrected in review)

  static func labFrame() -> [SpinCheck] {
    var log = SpinCheckLog()
    let b0 = 50 * uT
    let b1 = 1 * uT
    let fL = water.larmorHz(field: b0)
    let t90 = water.ninetyDuration(b1: b1)
    var rot = BlochSimulator(b0: b0, drive: BlochDrive(b1: b1, continuous: true), relaxation: .none)
    rot.step(t90)
    let steps = Int((t90 * fL * 400).rounded())
    var lab = LabFrameBloch(species: water)
    lab.run(duration: t90, steps: steps) {
      LabFrameBloch.circularField(b0: b0, b1: b1, frequencyHz: fL, sense: water.precessionSense, at: $0)
    }
    var counter = LabFrameBloch(species: water)
    var minZ = 1.0
    let h = t90 / Double(steps)
    for _ in 0..<steps {
      let tm = counter.time
      counter.step(
        h, field: LabFrameBloch.circularField(b0: b0, b1: b1, frequencyHz: fL, sense: .counterclockwise, at: tm + 0.5 * h))
      minZ = min(minZ, counter.magnetization.z)
    }
    let d = simd_distance(lab.magnetization, rot.labMagnetization)
    var probe = BlochSimulator(b0: b0, drive: BlochDrive(b1: b1, continuous: true), relaxation: .none)
    probe.step(1e-4)
    let want = LabFrameBloch.circularField(b0: b0, b1: b1, frequencyHz: fL, sense: water.precessionSense, at: 1e-4)
    log.check(
      "lab frame reproduces the rotating frame",
      d < 2e-3 && abs(lab.magnetization.z) < 2e-3 && simd_distance(probe.labField, want) < 1e-15,
      "π/2 in the lab (\(steps) steps): |ΔM| \(fmt(d, 2)); the simulator's lab B₁ is (cos ωt, −sin ωt) for γ > 0")
    log.check(
      "counter-rotating B₁ barely tips (negative test)", minZ > 0.999,
      "min M_z \(fmt(minZ, 6)) with B₁ turning the wrong way")
    var relaxed = LabFrameBloch(species: water, relaxation: BlochRelaxation(t1: 0.5, t2: 0.2, m0: 1), magnetization: SIMD3(1, 0, 0))
    relaxed.run(duration: 0.2, steps: 7) { _ in SIMD3(0, 0, b0) }
    let wantXY = exp(-1.0)
    let wantZ = 1 - exp(-0.4)
    let phase = atan2(relaxed.magnetization.y, relaxed.magnetization.x)
    let wantPhase = SpinMath.wrapAngle(-2 * .pi * fL * 0.2)
    log.check(
      "lab-frame free precession with T₁, T₂",
      abs(hypot(relaxed.magnetization.x, relaxed.magnetization.y) - wantXY) < 1e-12 && abs(relaxed.magnetization.z - wantZ) < 1e-12
        && abs(SpinMath.wrapAngle(phase - wantPhase)) < 1e-9,
      "|M⊥| \(fmt(hypot(relaxed.magnetization.x, relaxed.magnetization.y), 10)) vs e⁻¹, clockwise phase exact")
    return log.checks
  }

  // MARK: - Ensemble: dephasing, echo (§4.1, §10 row 8)

  static func ensemble() -> [SpinCheck] {
    var log = SpinCheckLog()
    let g = 1 * uT
    let spread = SpinEnsemble.gradientSpreadHz(species: water, gradient: g, length: 0.1)
    let td = SpinEnsemble.dephasingTime(species: water, gradient: g, length: 0.1)
    let null = SpinEnsemble.firstNull(species: water, gradient: g, length: 0.1)
    log.check(
      "gradient spread and sinc dephasing",
      abs(spread - 4.258) < 0.001 && abs(td - 0.1644) < 0.0005 && abs(null - 0.2349) < 0.0005
        && abs(SpinEnsemble.dephasingTime(species: water, gradient: 10 * uT, length: 0.1) - 0.01644) < 0.00005,
      "Δf \(fmt(spread, 5)) Hz; 1/e at \(fmt(td * 1e3, 4)) ms (not 75 ms), first null \(fmt(null * 1e3, 4)) ms")

    var ens = SpinEnsemble(count: 64, spread: .gradient(teslaPerMetre: g, length: 0.1), relaxation: .none)
    let sig = ens.acquire(.fid, duration: td, sampleRate: 1 / td)
    log.check(
      "64 isochromats give the sinc", abs(simd_length(sig.last ?? .zero) - exp(-1)) < 1e-3,
      "|M⊥|(\(fmt(td * 1e3, 4)) ms) \(fmt(simd_length(sig.last ?? .zero), 6)) vs e⁻¹")

    var echo = SpinEnsemble(
      count: 64, spread: .gradient(teslaPerMetre: g, length: 0.1), relaxation: BlochRelaxation(t1: 2.5, t2: 2, m0: 1))
    let s = echo.acquire(.hahnEcho(tau: 0.05), duration: 0.1, sampleRate: 2000)
    let ratio = simd_length(s.last ?? .zero) / simd_length(s.first ?? SIMD2(1, 0))
    // §10 asks for 1e-3; hard pulses refocus a discrete ensemble exactly, so the echo is
    // e^(−2τ/T₂) to rounding, and 1e-9 also catches an imperfect refocusing pulse (0.98π: −9e-4).
    log.check(
      "Hahn echo (64 isochromats, 1 µT/m over 10 cm, τ 50 ms, T₂ 2 s)", abs(ratio - exp(-0.05)) < 1e-9,
      "echo/FID(0) \(fmt(ratio, 10)) vs e^(−0.05) = \(fmt(exp(-0.05), 10))")

    var live = SpinEnsemble(
      count: 64, spread: .gradient(teslaPerMetre: g, length: 0.1), relaxation: BlochRelaxation(t1: 2.5, t2: 2, m0: 1))
    live.schedule(.hahnEcho(tau: 0.05))
    for _ in 0..<6 { live.advance(1.0 / 60) }
    var batch = SpinEnsemble(
      count: 64, spread: .gradient(teslaPerMetre: g, length: 0.1), relaxation: BlochRelaxation(t1: 2.5, t2: 2, m0: 1))
    let b = batch.acquire(.hahnEcho(tau: 0.05), duration: 0.1, sampleRate: 10)
    log.check(
      "real-time schedule matches batch acquire", simd_distance(live.signal, b.last ?? .zero) < 1e-12,
      "Δ \(fmt(simd_distance(live.signal, b.last ?? .zero), 2))")

    // A one-isochromat ensemble is the single-spin simulator: finite pulse, CW, relaxation.
    let relax = BlochRelaxation(t1: 0.3, t2: 0.1, m0: 1)
    var one = SpinEnsemble(count: 1, relaxation: relax)
    one.drive = BlochDrive(b1: 2 * uT, offsetHz: 4)
    var single = BlochSimulator(b0: 50 * uT, drive: BlochDrive(b1: 2 * uT, offsetHz: 4), relaxation: relax)
    one.startPulse(.ninety)
    single.startPulse(.ninety)
    for _ in 0..<10 {
      one.advance(1.0 / 120)
      single.step(1.0 / 120)
    }
    one.drive.continuous = true
    single.drive.continuous = true
    for _ in 0..<30 {
      one.advance(1.0 / 60)
      single.step(1.0 / 60)
    }
    let diff = simd_distance(one.meanMagnetization, single.magnetization)
    log.check(
      "ensemble of one = single-spin simulator", diff < 1e-10 && !one.isPulsing,
      "|ΔM| \(fmt(diff, 2)) after a finite π/2 off resonance then CW with T₁, T₂")

    // Finite pulses act on the whole line: a strong B₁ tips every isochromat, a weak one only the centre.
    func tipped(b1: Double) -> Double {
      var e = SpinEnsemble(count: 64, spread: .gradient(teslaPerMetre: 100 * uT, length: 0.1), relaxation: .none)
      e.drive.b1 = b1
      e.startPulse(.ninety)
      e.advance(0.5)
      return e.magnetizations.map { 1 - $0.z }.min() ?? 0
    }
    let strong = tipped(b1: 10 * uT)
    let weak = tipped(b1: 0.1 * uT)
    // 10 µT: f₁ 425.8 Hz, so the ±212.9 Hz edge turns about B_eff tilted 63.4° and ends at
    // 1 − M_z = 0.947. 0.1 µT: f₁ 4.26 Hz, the edge can invert at most 4e-4.
    log.check(
      "finite pulses are selective", abs(strong - 0.947) < 0.005 && weak < 1e-3,
      "line ±213 Hz: least-tipped isochromat 1 − M_z \(fmt(strong, 3)) at 10 µT, \(fmt(weak, 2)) at 0.1 µT")

    // A Lorentzian spread (isochromats at the Cauchy quantiles, HWHM 1/(2πT₂*)) decays as
    // e^(−t/T₂*). With 256 midpoint quantiles the discrete line is 0.04 % off at T₂*/2 and 2 %
    // at T₂* (numpy: 0.60674 and 0.37521).
    let t2s = 0.05
    var lor = SpinEnsemble(count: 256, spread: .lorentzian(t2Star: t2s), relaxation: .none)
    let lorSig = lor.acquire(.fid, duration: t2s, sampleRate: 2 / t2s).map { simd_length($0) }
    log.check(
      "Lorentzian spread decays as e^(−t/T₂*)",
      lorSig.count == 3 && abs(lorSig[1] - 0.606742) < 1e-5 && abs(lorSig[2] - 0.375213) < 1e-5
        && abs(lorSig[1] / exp(-0.5) - 1) < 1e-3 && abs(lorSig[2] / exp(-1) - 1) < 0.03,
      "|M⊥| \(fmt(lorSig.count == 3 ? lorSig[1] : .nan, 6)) at T₂*/2 (e^−½ 0.606531), \(fmt(lorSig.count == 3 ? lorSig[2] : .nan, 6)) at T₂* (e⁻¹ 0.367879)")
    return log.checks
  }

  // MARK: - FID signal and spectrum

  static func fidSignal() -> [SpinCheck] {
    var log = SpinCheckLog()
    let fL = water.larmorHz(field: 50 * uT)
    let fs = 48_000.0
    let audio = FIDSignal.audio(FIDParameters(species: water, field: 50 * uT, t2Star: 10), sampleRate: fs, count: 48_000)
    let tone = SpinAnalysis.toneFrequency(audio.map(Double.init), sampleRate: fs, in: 2000...2300)
    log.check("audio FID at true pitch (48 kHz)", abs(tone - fL) < 0.01, "measured \(fmt(tone, 8)) Hz vs f_L \(fmt(fL, 8))")
    let audio44 = FIDSignal.audio(FIDParameters(species: water, field: 50 * uT, t2Star: 10), sampleRate: 44_100, count: 44_100)
    let tone44 = SpinAnalysis.toneFrequency(audio44.map(Double.init), sampleRate: 44_100, in: 2000...2300)
    log.check(
      "audio FID at another rate (44.1 kHz)", abs(tone44 - fL) < 0.01 && FIDSignal.isRepresentable(frequency: fL, sampleRate: 44_100)
        && !FIDSignal.isRepresentable(frequency: 1.4e6, sampleRate: 48_000),
      "measured \(fmt(tone44, 8)) Hz; the electron line cannot be sampled at audio rates")
    if let spec = FIDSpectrum.transform(real: audio, sampleRate: fs) {
      let bin = fs / Double((spec.frequencies.count - 1) * 2)
      log.check(
        "audio spectrum line", abs(spec.peakFrequency - fL) <= bin, "peak \(fmt(spec.peakFrequency, 6)) Hz (bin \(fmt(bin, 3)) Hz)")
    } else {
      log.check("audio spectrum line", false, "transform failed")
    }
    let p = FIDParameters(species: water, field: 50 * uT, t2Star: 0.2)
    let ref = fL - 10
    let bb = FIDSignal.baseband(p, referenceHz: ref, sampleRate: 1000, count: 4096)
    if let spec = FIDSpectrum.transform(bb, sampleRate: 1000) {
      let height = spec.magnitude.max() ?? 0
      log.check(
        "baseband line at −Δf for protons, height A·T₂*",
        abs(spec.peakFrequency - (-10)) <= 1000.0 / 4096 && abs(height - 0.2) < 0.02,
        "peak \(fmt(spec.peakFrequency, 5)) Hz, |S| \(fmt(height, 4)) (clockwise species shows f_ref − f_L)")
    } else {
      log.check("baseband line", false, "transform failed")
    }
    let lz = FIDSpectrum.lorentzian(p, referenceHz: ref, frequencies: [-10, -10 + 1 / (2 * .pi * 0.2)])
    log.check(
      "Lorentzian: peak A·T₂*, half height at ±1/(2πT₂*)",
      abs(lz.real[0] - 0.2) < 1e-12 && abs(lz.real[1] - 0.1) < 1e-12 && abs(p.linewidthHz - 1 / (.pi * 0.2)) < 1e-12,
      "peak \(fmt(lz.real[0], 6)), FWHM \(fmt(p.linewidthHz, 5)) Hz")
    let env = FIDSignal.envelope(p, at: 0.2)
    log.check("T₂* envelope", abs(env - exp(-1)) < 1e-15 && FIDSignal.envelope(p, at: -1) == 0, "A e^(−t/T₂*) at T₂*: \(fmt(env, 8))")

    var osc = FIDOscillator(sampleRate: fs, frequency: fL, t2Star: 0.075)
    osc.trigger()
    let ring = osc.render(Int(0.075 * fs))
    let pitch = SpinAnalysis.toneFrequency(ring.map(Double.init), sampleRate: fs, in: 2000...2300)
    log.check(
      "FID voice ring-down and pitch", abs(osc.envelope - exp(-1)) < 1e-3 && abs(pitch - fL) < 0.5,
      "envelope at T₂* \(fmt(osc.envelope, 5)), pitch \(fmt(pitch, 7)) Hz")
    var follow = FIDOscillator(sampleRate: fs, frequency: fL, mode: .follow)
    follow.envelopeTarget = 0.6
    _ = follow.render(4800)
    log.check(
      "FID voice follows a control-rate envelope", abs(follow.envelope - 0.6) < 1e-4, "envelope \(fmt(follow.envelope, 6)) → 0.6")

    var src = SpinFIDSource(field: 50 * uT, t2Star: 0.5)
    src.pulse()
    let iq = src.renderBaseband(count: 4096, sampleRate: 1000, referenceHz: fL - 20)
    let line = SpinAnalysis.toneFrequency(iq: iq, sampleRate: 1000, in: -100...100)
    let heard = src.renderAudio(24_000)
    let heardPitch = SpinAnalysis.toneFrequency(heard.map(Double.init), sampleRate: fs, in: 2000...2300)
    log.check(
      "Spin FID source: true pitch, heterodyned IQ",
      src.voice.mode == .truePitch && abs(heardPitch - fL) < 0.05 && abs(line + 20) < 0.01,
      "plays \(fmt(heardPitch, 7)) Hz; IQ line \(fmt(line, 6)) Hz at f_ref = f_L − 20 Hz")
    src.follow(envelope: 0.4)
    _ = src.renderAudio(4800)
    let followed = src.envelope
    let followedIQ = src.renderBaseband(count: 64, sampleRate: 1000, referenceHz: fL).map { simd_length($0) }
    src.pulse()
    log.check(
      "Spin FID source follows a simulation, pulse returns to ring-down",
      abs(followed - 0.4) < 1e-4 && followedIQ.allSatisfy { abs($0 - 0.4) < 1e-12 } && !src.isFollowing
        && abs(src.envelope) < 1e-12,
      "envelope \(fmt(followed, 5)) while following (audio and IQ)")
    src.updateField(60 * uT, dt: 0.25)
    let smoothed = src.field / uT
    log.check(
      "field smoothing τ = 0.25 s", abs(smoothed - (50 + 10 * (1 - exp(-1)))) < 1e-9, "\(fmt(smoothed, 7)) µT after one τ")
    var strong = SpinFIDSource(field: 1.0)
    log.check(
      "mapped pitch above 20 kHz",
      strong.voice.mode == .mapped && abs(LarmorSonification.truePitchCeilingField(species: water) / uT - 469.7) < 0.1,
      "1 T → \(fmt(strong.voice.audibleHz, 5)) Hz MAPPED; true pitch up to \(fmt(LarmorSonification.truePitchCeilingField(species: water) / uT, 4)) µT")
    strong.setField(50 * uT)
    let maps: [(Double, Double)] = [(60, 57.7), (1.40125e6, 123.0), (2.44e9, 215.7), (545e12, 545.1)]
    let worst = maps.map { abs(LarmorSonification.mappedPitch(forFrequency: $0.0) - $0.1) }.max() ?? 1
    log.check(
      "spectra-lab mapped pitch", worst < 0.05 && strong.voice.mode == .truePitch,
      "60 Hz, 1.40125 MHz, 2.44 GHz, 545 THz → 57.7/123.0/215.7/545.1 Hz (worst |Δ| \(fmt(worst, 2)))")
    return log.checks
  }

  // MARK: - Earth field (§5.3), chemical shift (§4.1), readouts

  static func earthField() -> [SpinCheck] {
    var log = SpinCheckLog()
    let lat = EarthField.magneticLatitude(dipAngle: 66 * .pi / 180) * 180 / .pi
    let lat60 = EarthField.magneticLatitude(dipAngle: 60 * .pi / 180) * 180 / .pi
    let b = EarthField.dipoleMagnitude(magneticLatitude: lat * .pi / 180) / uT
    let back = EarthField.dipAngle(magneticLatitude: lat * .pi / 180) * 180 / .pi
    log.check(
      "magnetic latitude from dip (tan I = 2 tan λₘ)",
      abs(lat - 48.316) < 1e-3 && abs(lat60 - 40.89) < 0.01 && abs(b - 49.05) < 0.01 && abs(back - 66) < 1e-12,
      "I 66° → λₘ \(fmt(lat, 6))°, dipole |B| \(fmt(b, 4)) µT; I 60° → \(fmt(lat60, 4))°")
    let ef = EarthField(microtesla: SIMD3(0, 22, -40), gravity: SIMD3(0, 0, -1))
    log.check(
      "Gyre's field (0, 22, −40) µT",
      abs(ef.magnitude / uT - 45.65) < 0.01 && abs(ef.larmorHz(water) - 1943.65) < 0.01 && abs(ef.dipAngle * 180 / .pi - 61.19) < 0.01,
      "|B| \(fmt(ef.magnitude / uT, 6)) µT, I \(fmt(ef.dipAngle * 180 / .pi, 5))°, ¹H \(fmt(ef.larmorHz(water), 6)) Hz")
    // Gravity and field in any frame: rotate both and the answers must not change.
    let q = simd_quatd(angle: 0.7, axis: simd_normalize(SIMD3(1, -2, 0.5)))
    let turned = EarthField(field: q.act(ef.field), gravity: q.act(ef.gravity))
    log.check(
      "dip angle is frame independent", abs(turned.dipAngle - ef.dipAngle) < 1e-12 && abs(turned.horizontal - ef.horizontal) < 1e-18,
      "phone frame vs world frame: ΔI \(fmt(turned.dipAngle - ef.dipAngle, 2))")
    let p = SpinSpecies.proton
    let hi = ChemicalShift.separationHz(ppm: 2.47, protonHz: p.larmorHz(field: 9.4))
    let mid = ChemicalShift.separationHz(ppm: 2.47, protonHz: p.larmorHz(field: 1.41))
    let earth = ChemicalShift.separationHz(ppm: 2.47, protonHz: p.larmorHz(field: 50 * uT))
    let r = ChemicalShift.couplingRatio(ppm: 2.47, couplingHz: 7.1, protonHz: p.larmorHz(field: 50 * uT))
    let r400 = ChemicalShift.couplingRatio(ppm: 2.47, couplingHz: 7.1, protonHz: p.larmorHz(field: 9.4))
    log.check(
      "ethanol: shifts shrink, J doesn't",
      abs(hi - 988.6) < 0.05 && abs(mid - 148.3) < 0.05 && abs(earth * 1e3 - 5.26) < 0.005 && abs(r - 7.4e-4) < 0.05e-4
        && abs(r400 - 139) < 0.5,
      "Δν \(fmt(hi, 5)) / \(fmt(mid, 4)) Hz / \(fmt(earth * 1e3, 3)) mHz; Δν/J \(fmt(r400, 3)) at 9.4 T, \(fmt(r, 2)) at Earth")
    var smooth = FieldSmoother(timeConstant: 0.25)
    smooth.update(50 * uT, dt: 0)
    for _ in 0..<100 { smooth.update(60 * uT, dt: 0.01) }
    log.check(
      "field smoother", abs((smooth.value ?? 0) / uT - (60 - 10 * exp(-4))) < 1e-9, "\(fmt((smooth.value ?? 0) / uT, 8)) µT after 4τ")

    let readout = SpinFieldReadout(field: 50 * uT)
    log.check(
      "field readout chips (50 µT)",
      rel(readout.protonHz, 2128.8192715) < 1e-9 && rel(readout.electronHz, 1.401247569305e6) < 1e-9
        && rel(readout.electronCyclotronHz, 1.3996244917e6) < 1e-9 && abs(readout.anomalyBeatHz - 1623.08) < 0.01
        && readout.electronInAMBand && !SpinFieldReadout(field: 65 * uT).electronInAMBand
        && readout.protonVoice.mode == .truePitch && readout.electronVoice.mode == .mapped
        && abs(readout.electronVoice.audibleHz - 123.0) < 0.05 && abs(readout.protonJitterHz(fieldNoise: 0.1 * uT) - 4.258) < 1e-3,
      "¹H \(fmt(readout.protonHz, 6)) Hz · e⁻ \(fmt(readout.electronHz / 1e6, 5)) MHz · AM band · cyclotron \(fmt(readout.electronCyclotronHz / 1e6, 5)) MHz")
    let drive = SpinDriveReadout(species: water, b1: 1 * uT, offsetHz: 10)
    log.check(
      "drive readout (B₁ 1 µT, Δf 10 Hz)",
      abs(drive.rabiHz - 42.576) < 0.001 && rel(drive.ninetyDuration, 5.872e-3) < 1e-4 && abs(drive.effectiveHz - 43.735) < 0.001
        && abs(drive.effectiveTilt * 180 / .pi - 76.8) < 0.05 && abs(drive.maxInversionProbability - 0.9477) < 1e-4,
      "f₁ \(fmt(drive.rabiHz, 5)) Hz, Ω₁ \(fmt(drive.rabiAngular, 5)) rad/s, t_π/2 \(fmt(drive.ninetyDuration * 1e3, 4)) ms")
    return log.checks
  }

  // MARK: - Gyre physcheck, ported verbatim to HeavyTop

  static func quiet(_ p: inout HeavyTopParams) {
    p.friction = 0
    p.air = 0
  }

  static let frame = 1.0 / 120.0

  static func physcheck() -> [SpinCheck] {
    var log = SpinCheckLog()
    let dt = frame

    do {  // 1. Steady precession matches the slow root of I₁cosθΩ² − L₃Ω + mgℓ = 0.
      var p = HeavyTopParams()
      quiet(&p)
      p.motorRPM = 3000
      var sim = HeavyTop()
      sim.launch(params: p, tilt: 0.5)
      let env = HeavyTopEnvironment()
      var turned = 0.0
      var last = atan2(sim.axis.y, sim.axis.x)
      for i in 0..<(120 * 12) {
        sim.step(dtReal: dt, env: env, params: p)
        let az = atan2(sim.axis.y, sim.axis.x)
        if i > 120 { turned += SpinMath.wrapAngle(az - last) }
        last = az
      }
      let measured = turned / (Double(120 * 12 - 122) * dt)
      let theory = HeavyTop.steadyPrecession(
        spinMomentum: sim.I3 * sim.spinRate, transverseInertia: sim.I1, offset: sim.offset, gravity: 1, tilt: sim.tilt)
      log.check(
        "physcheck 1 steady precession", rel(measured, theory) < 0.02,
        "measured \(fmt(measured, 5)) rad/s, theory \(fmt(theory, 5)) (Gyre: 1.2201)")
    }

    do {  // 2. A balanced, frictionless gyro keeps its axis fixed in space while the phone tumbles.
      var p = HeavyTopParams()
      quiet(&p)
      p.balance = 0
      p.motorRPM = 0
      var sim = HeavyTop()
      sim.launch(params: p, tilt: 0.7, rpm: 5000)
      let start = sim.axis
      var env = HeavyTopEnvironment()
      for i in 0..<(120 * 10) {
        let t = Double(i) * dt
        env.deviceRate = SIMD3(2 * sin(t), 3 * cos(0.7 * t), 1.5)
        sim.step(dtReal: dt, env: env, params: p)
      }
      let drift = acos(SpinMath.clamp(simd_dot(start, sim.axis), -1, 1)) * 180 / .pi
      log.check("physcheck 2 free gyro holds its axis", drift < 0.01, "drift \(fmt(drift, 3))° over 10 s of tumbling")
    }

    do {  // 3. Without motor, friction or air, the energy of a nutating top is conserved.
      var p = HeavyTopParams()
      quiet(&p)
      p.motorRPM = 0
      p.balance = 0.8
      var sim = HeavyTop()
      sim.launch(params: p, tilt: 0.6, rpm: 1500)
      sim.applyImpulse(SIMD3(0.002, -0.001, 0))
      let env = HeavyTopEnvironment()
      sim.step(dtReal: 0, env: env, params: p)
      let e0 = sim.energy
      var worst = 0.0
      for _ in 0..<(120 * 20) {
        sim.step(dtReal: dt, env: env, params: p)
        worst = max(worst, abs(sim.energy - e0) / abs(e0))
      }
      log.check("physcheck 3 energy conservation", worst < 1e-4, "max relative drift \(fmt(worst, 3)) over 20 s")
    }

    do {  // 4. A vertical top sleeps above the critical spin and falls below it.
      func sleeps(rpm: Double) -> Bool {
        var p = HeavyTopParams()
        quiet(&p)
        p.motorRPM = rpm
        p.balance = 0.5
        var sim = HeavyTop()
        sim.launch(params: p, tilt: 0.02, rpm: rpm)
        let env = HeavyTopEnvironment()
        var maxTilt = 0.0
        for _ in 0..<(120 * 8) {
          sim.step(dtReal: dt, env: env, params: p)
          maxTilt = max(maxTilt, sim.tilt)
        }
        return maxTilt < 0.2
      }
      var probe = HeavyTop()
      var p = HeavyTopParams()
      p.balance = 0.5
      probe.launch(params: p)
      let critical = (4 * HeavyTop.mass * HeavyTop.g0 * probe.offset * probe.I1).squareRoot() / probe.I3 * 60 / (2 * .pi)
      let above = sleeps(rpm: critical * 1.25)
      let below = sleeps(rpm: critical * 0.8)
      log.check(
        "physcheck 4 sleeping-top threshold", above && !below,
        "critical \(Int(critical)) rpm: sleeps at 1.25× = \(above), at 0.8× = \(below)")
    }

    do {  // 5. A magnetized, balanced rotor precesses about the field at μB/L (Larmor); both signs.
      func larmor(magnet: Double) -> (measured: Double, theory: Double) {
        var p = HeavyTopParams()
        quiet(&p)
        p.balance = 0
        p.magnet = magnet
        p.motorRPM = 4000
        p.gravity = 0
        var sim = HeavyTop()
        sim.launch(params: p, tilt: 0.8, rpm: 4000)
        var env = HeavyTopEnvironment()
        env.magneticField = SIMD3(0, 0, 50e-6)
        var turned = 0.0
        var last = atan2(sim.axis.y, sim.axis.x)
        let steps = 120 * 10
        for _ in 0..<steps {
          sim.step(dtReal: dt, env: env, params: p)
          let az = atan2(sim.axis.y, sim.axis.x)
          turned += SpinMath.wrapAngle(az - last)
          last = az
        }
        return (turned / (Double(steps) * dt), sim.larmorRate(magnet: magnet, field: 50e-6))
      }
      let (m, t) = larmor(magnet: 1)
      log.check(
        "physcheck 5 Larmor precession", rel(m, t) < 0.03 && m < 0,
        "measured \(fmt(m, 4)) rad/s, theory \(fmt(t, 4)) (clockwise about B; Gyre −0.2652 vs −0.2653)")
      let (me, te) = larmor(magnet: -1)
      log.check(
        "Electron-like magnet (−1) precesses the other way", rel(me, te) < 0.03 && me > 0,
        "measured \(fmt(me, 4)) rad/s, theory \(fmt(te, 4))")
    }

    do {  // 6. Doubling inertia with the motor off halves the spin.
      var p = HeavyTopParams()
      quiet(&p)
      p.motorRPM = 0
      p.balance = 0
      var sim = HeavyTop()
      sim.launch(params: p, tilt: 0.3, rpm: 4000)
      let env = HeavyTopEnvironment()
      p.inertia = 2
      for _ in 0..<(120 * 4) { sim.step(dtReal: dt, env: env, params: p) }
      log.check("physcheck 6 skater effect", abs(sim.rpm - 2000) < 20, "spin \(Int(sim.rpm)) rpm after doubling inertia from 4000")
    }

    do {  // 7. With air and friction and no motor, the top winds down and falls within a minute or two.
      var p = HeavyTopParams()
      p.motorRPM = 0
      p.air = 1
      p.friction = 0.25
      var sim = HeavyTop()
      sim.tipOutputEnabled = false
      sim.launch(params: p, tilt: 0.3, rpm: 3000)
      let env = HeavyTopEnvironment()
      var fellAt: Double?
      for i in 0..<(120 * 240) {
        sim.step(dtReal: dt, env: env, params: p)
        if fellAt == nil, sim.tilt > .pi / 2 {
          fellAt = Double(i) * dt
          break
        }
      }
      log.check(
        "physcheck 7 wind-down", (fellAt ?? 999) > 20 && (fellAt ?? 999) < 200,
        "fell after \(fellAt.map { "\(Int($0)) s" } ?? "never")")
    }

    do {  // 8. Cost: substeps for a fast spin (with the 960 Hz tip output on).
      var p = HeavyTopParams()
      p.motorRPM = 12_000
      p.inertia = 3
      p.balance = 0
      var sim = HeavyTop()
      sim.launch(params: p, rpm: 12_000)
      let t0 = Date()
      for _ in 0..<1200 {
        sim.step(dtReal: dt, env: HeavyTopEnvironment(), params: p)
        _ = sim.drainTip()
      }
      let ms = Date().timeIntervalSince(t0) * 1000 / 1200
      #if DEBUG
        let budget = 10.0  // unoptimized test builds
      #else
        let budget = 1.0  // Gyre's budget, -O
      #endif
      log.check(
        "physcheck 8 step cost", ms < budget,
        "\(fmt(ms, 3)) ms per frame at 12000 rpm (\(sim.lastSubsteps) substeps; budget \(fmt(budget, 2)) ms)")
    }
    return log.checks
  }

  // MARK: - Heavy top: §4.1, §4.8, §10 worked values

  /// Nod frequency of a kicked top from its tilt record at 4 kHz, and the closed form.
  static func measuredNod(
    gravity: Double, tilt: Double, rpm: Double, balance: Double, magnet: Double = 0, field: SIMD3<Double> = .zero
  ) -> (measured: Double, formula: Double) {
    var p = HeavyTopParams()
    quiet(&p)
    p.motorRPM = 0
    p.gravity = gravity
    p.balance = balance
    p.magnet = magnet
    var sim = HeavyTop()
    sim.tipOutputEnabled = false
    sim.launch(params: p, tilt: tilt, azimuth: 0, rpm: rpm)
    sim.applyImpulse(2e-5 * SpinMath.perpendicular(to: sim.axis))
    var env = HeavyTopEnvironment()
    env.magneticField = field
    sim.step(dtReal: 0, env: env, params: p)
    let formula = sim.nodRate(field: field, magnet: magnet)
    let fs = 4000.0
    var x = [Double]()
    x.reserveCapacity(16_000)
    for _ in 0..<16_000 {
      sim.step(dtReal: 1 / fs, env: env, params: p)
      x.append(sim.tilt)
    }
    return (2 * .pi * SpinAnalysis.toneFrequency(x, sampleRate: fs, in: 20...60), formula)
  }

  static func heavyTopWorkedValues() -> [SpinCheck] {
    var log = SpinCheckLog()
    var p = HeavyTopParams()
    p.balance = 0.5
    p.motorRPM = 3000
    var sim = HeavyTop()
    sim.launch(params: p, tilt: 0.3, rpm: 3000)
    let l3 = sim.spinMomentum
    let fast = sim.fastTopPrecession()
    let slow = HeavyTop.steadyPrecession(spinMomentum: l3, transverseInertia: sim.I1, offset: sim.offset, gravity: 1, tilt: 0.3)
    log.check(
      "3000 rpm top: L₃, I₃, I₁, Ω_p",
      rel(l3, 8.482e-3) < 1e-3 && rel(sim.I3, 2.7e-5) < 1e-12 && rel(sim.I1, 3.4375e-5) < 1e-9 && abs(fast - 1.2139) < 1e-4
        && abs(slow - 1.2197) < 1e-4,
      "L₃ \(fmt(l3, 4)) J·s, I₁ \(fmt(sim.I1, 5)), fast-top \(fmt(fast, 5)), slow root \(fmt(slow, 5)) rad/s (\(fmt(slow / (2 * .pi), 3)) Hz)")

    let g0 = measuredNod(gravity: 0, tilt: 0.3, rpm: 3000, balance: 0.5)
    log.check(
      "nutation, gravity 0", rel(g0.measured, 246.76) < 1e-3 && rel(g0.formula, 246.76) < 1e-3,
      "measured \(fmt(g0.measured, 6)) rad/s, L₃/I₁ \(fmt(g0.formula, 6)) vs 246.76 (39.27 Hz)")
    let g1 = measuredNod(gravity: 1, tilt: 0.3, rpm: 3000, balance: 0.5)
    log.check(
      "nutation, 1 g at tilt 0.3", rel(g1.measured, 244.43) < 1e-3 && rel(g1.formula, 244.43) < 1e-3,
      "measured \(fmt(g1.measured, 6)) rad/s, √((L₃/I₁)² − 4mgℓcosθ/I₁) \(fmt(g1.formula, 6)) vs 244.43 (L₃/I₁ is 1 % off)")
    let mf = measuredNod(gravity: 0, tilt: 0.34, rpm: 1500, balance: 0, magnet: 1, field: SIMD3(0, 0, 50e-6))
    log.check(
      "nod stiffened by the field (42.40 Hz)",
      rel(mf.measured, mf.formula) < 2e-3 && abs(mf.measured / (2 * .pi) - 42.40) < 0.05,
      "1500 rpm, magnet 1, 50 µT: \(fmt(mf.measured / (2 * .pi), 5)) Hz measured, \(fmt(mf.formula / (2 * .pi), 5)) Hz formula (42.19 Hz free)")

    func nodHz(rpm: Double, inertia: Double) -> Double {
      var q = HeavyTopParams()
      q.balance = 0
      q.inertia = inertia
      var top = HeavyTop()
      top.launch(params: q, tilt: 0.3, rpm: rpm)
      return top.nutationRate / (2 * .pi)
    }
    let n4 = nodHz(rpm: 4000, inertia: 1)
    let n12 = nodHz(rpm: 12_000, inertia: 1)
    let n12x3 = nodHz(rpm: 12_000, inertia: 3)
    log.check(
      "balanced nod table", abs(n4 - 112.5) < 0.05 && abs(n12 - 337.5) < 0.05 && abs(n12x3 - 376.7) < 0.05,
      "4000 rpm \(fmt(n4, 5)) Hz, 12 000 rpm \(fmt(n12, 5)) Hz, ×3 inertia \(fmt(n12x3, 5)) Hz")
    let a1 = SpinTiming.apparentFrequency(n4, frameRate: 120)
    let a2 = SpinTiming.aliasedFrequency(337.5, sampleRate: 120)
    let a3 = SpinTiming.aliasedFrequency(337.5, sampleRate: 60)
    let a4 = SpinTiming.aliasedFrequency(60, sampleRate: 99.8)
    log.check(
      "display and magnetometer aliasing (exact)",
      abs(a1 - 7.5) < 1e-6 && a2 == 22.5 && a3 == 22.5 && abs(a4 - 39.8) < 1e-12
        && SpinTiming.isAliased(337.5, frameRate: 120) && !SpinTiming.isAliased(22.5, frameRate: 120),
      "112.5 → \(fmt(a1, 4)) Hz, 337.5 → \(fmt(a2, 4)) Hz at 120 and 60 fps; 60 Hz at fs 99.8 → \(fmt(a4, 6)) Hz")
    let wall = SpinTiming.apparentFrequency(376.7, timeScale: 2, frameRate: 960)
    log.check(
      "κ display rate, slowdown, Time knob",
      rel(SpinTiming.kappaRate(kappa: 1, referenceHz: 545e12), 1.8349e-15) < 1e-4
        && rel(SpinTiming.slowdownFactor(kappa: 1, referenceHz: 545e12), 5.45e14) < 1e-9
        && rel(SpinTiming.kappaRate(kappa: 1, referenceHz: Gyration.cyclotronHz(.electron, field: 50 * uT)), 7.145e-7) < 1e-3
        && abs(wall - 206.6) < 0.01,
      "545 THz κ 1: D \(fmt(SpinTiming.kappaRate(kappa: 1, referenceHz: 545e12), 4)), slowed \(fmt(SpinTiming.slowdownFactor(kappa: 1, referenceHz: 545e12), 3))×; 376.7 Hz nod at 2× on a 960 Hz wall clock folds to \(fmt(wall, 4)) Hz")
    return log.checks
  }

  // MARK: - Rotor γ and the Purcell/Feynman resonance (§4.1, §10)

  /// First time the tilt reaches π/2 and the largest tilt in 40 s, with B₁ co-rotating
  /// (`sense` +1) or counter-rotating (−1), driven through `GyroscopeEngine`.
  static func rotorResonanceRun(sense: Double) -> (firstQuarter: Double?, maxTilt: Double) {
    var engine = GyroscopeEngine()
    engine.apply(HeavyTopPreset.all.first { $0.id == "resonance" } ?? HeavyTopPreset.all[0])
    engine.launch(tilt: 0, rpm: 1500)
    if var drive = engine.resonance {
      drive.omega *= sense
      engine.resonance = drive
    }
    var first: Double?
    var maxTilt = 0.0
    for i in 0..<(40 * 120) {
      engine.advance(dtReal: frame, environment: HeavyTopEnvironment())
      maxTilt = max(maxTilt, engine.top.tilt)
      if first == nil, engine.top.tilt >= .pi / 2 { first = Double(i + 1) * frame }
    }
    return (first, maxTilt)
  }

  static func rotorResonance() -> [SpinCheck] {
    var log = SpinCheckLog()
    var p = HeavyTopParams()
    p.balance = 0
    p.gravity = 0
    p.magnet = 1
    p.motorRPM = 1500
    var sim = HeavyTop()
    sim.launch(params: p, tilt: 0, rpm: 1500)
    let g = sim.rotorGamma(magnet: 1)
    let w0 = abs(sim.larmorRate(magnet: 1, field: 50e-6))
    let t90 = RotorResonanceDrive.quarterTurnTime(rotorGamma: g, b1: 10e-6)
    let link = water.gamma / g
    log.check(
      "rotor γ, Ω₀, t₉₀, κ link",
      rel(sim.spinMomentum, 4.2412e-3) < 1e-4 && rel(g, 14_147) < 1e-3 && rel(w0, 0.7074) < 1e-3 && abs(2 * .pi / w0 - 8.88) < 0.005
        && abs(t90 - 11.10) < 0.005 && rel(link, 1.89e4) < 2e-3,
      "L \(fmt(sim.spinMomentum, 5)) J·s, γ_rotor \(fmt(g, 6)) rad/s/T, Ω₀ \(fmt(w0, 4)) rad/s (\(fmt(2 * .pi / w0, 3)) s), t₉₀ \(fmt(t90, 4)) s, γ′ₚ/γ_rotor \(fmt(link, 3))")
    let mu = HeavyTop.ndfebDipole()
    let detent = HeavyTopParams.realNdFeBMagnet
    let period = 2 * .pi / abs(sim.larmorRate(magnet: detent, field: 50e-6))
    log.check(
      "Real NdFeB rotor (Bᵣ 1.3 T, 60 g, 7500 kg/m³)",
      rel(mu, 8.276) < 1e-3 && abs(detent - 0.138) < 0.0005 && abs(period - 64.4) < 0.05,
      "μ \(fmt(mu, 5)) A·m², detent \(fmt(detent, 4)), Larmor period \(fmt(period, 4)) s at 1500 rpm in 50 µT")
    let co = rotorResonanceRun(sense: 1)
    log.check(
      "rotor resonance, co-rotating B₁ (tilt 0)", co.firstQuarter.map { abs($0 - 11.10) / 11.10 < 0.02 } ?? false,
      "tilt π/2 first at \(co.firstQuarter.map { fmt($0, 4) } ?? "never") s vs 11.10 s (review's verbatim sim: 11.14 s)")
    let counter = rotorResonanceRun(sense: -1)
    let deg = counter.maxTilt * 180 / .pi
    log.check(
      "rotor resonance, wrong sense (negative test)", counter.firstQuarter == nil && deg > 10.5 && deg < 12,
      "max tilt \(fmt(deg, 4))° (2·atan(10/100) = 11.4°)")
    return log.checks
  }

  // MARK: - Tip IQ (§4.8)

  static func tipIQ() -> [SpinCheck] {
    var log = SpinCheckLog()
    var p = HeavyTopParams()
    quiet(&p)
    p.motorRPM = 3000
    var sim = HeavyTop()
    sim.launch(params: p, tilt: 0.5, rpm: 3000)
    sim.applyImpulse(2e-4 * SpinMath.perpendicular(to: sim.axis))
    let env = HeavyTopEnvironment()
    var tip = [SIMD2<Double>]()
    for _ in 0..<(120 * 8) {
      sim.step(dtReal: frame, env: env, params: p)
      tip += sim.drainTip()
    }
    let fs = HeavyTop.tipSampleRate
    let plus = SpinAnalysis.peakPower(iq: tip, sampleRate: fs, in: 30...50)
    let minus = SpinAnalysis.peakPower(iq: tip, sampleRate: fs, in: -50...(-30))
    let carrier = SpinAnalysis.peakPower(iq: tip, sampleRate: fs, in: -1...1)
    let fPlus = SpinAnalysis.toneFrequency(iq: tip, sampleRate: fs, in: 30...50)
    let fCarrier = SpinAnalysis.toneFrequency(iq: tip, sampleRate: fs, in: -1...1)
    let ssb = 10 * log10(plus / minus)
    log.check(
      "tip IQ at 960 Hz: carrier Ω_p and a single nod sideband",
      abs(tip.count - 7680) <= 1 && ssb > 15 && fCarrier > 0.15 && fCarrier < 0.25 && fPlus > 35 && fPlus < 42,
      "\(tip.count) samples in 8 s; carrier \(fmt(fCarrier, 3)) Hz, nod +\(fmt(fPlus, 4)) Hz at \(fmt(10 * log10(plus / carrier), 3)) dBc, mirror \(fmt(ssb, 3)) dB lower")

    // Sample n must be the axis at simulated time (n + 1)/960 s: compare a 120 fps run's tip
    // stream with the same top stepped at exactly 1/960 s. Linear interpolation between
    // substeps is good to ~3e-5 here; taking the substep end instead is off by 2.5e-3.
    var p960 = HeavyTopParams()
    p960.motorRPM = 3000
    var framed = HeavyTop()
    framed.launch(params: p960, tilt: 0.5, rpm: 3000)
    var reference = framed
    reference.tipOutputEnabled = false
    let nodKick = 2e-4 * SpinMath.perpendicular(to: framed.axis)
    framed.applyImpulse(nodKick)
    reference.applyImpulse(nodKick)
    var framedTips = [SIMD2<Double>]()
    for _ in 0..<120 {
      framed.step(dtReal: frame, env: HeavyTopEnvironment(), params: p960)
      framedTips += framed.drainTip()
    }
    var tipError = 0.0
    for i in 0..<min(framedTips.count, 960) {
      reference.step(dtReal: 1.0 / 960, env: HeavyTopEnvironment(), params: p960)
      tipError = max(tipError, simd_distance(framedTips[i], reference.tip))
    }
    log.check(
      "tip samples sit on the trajectory at (n + 1)/960 s",
      framedTips.count >= 959 && framedTips.count <= 960 && tipError < 2e-4,
      "\(framedTips.count) samples in 1 s at 120 fps; worst |Δtip| \(fmt(tipError, 2)) against stepping at 1/960 s")

    var engine = GyroscopeEngine(params: HeavyTopParams(timeScale: 0.5), tilt: 0.5)
    var n = 0
    var blocks = 0
    for _ in 0..<240 {
      engine.advance(dtReal: frame, environment: HeavyTopEnvironment())
      while let block = engine.popTipBlock(size: 64) {
        n += block.count
        blocks += 1
      }
    }
    n += engine.pendingTipCount
    log.check(
      "tip samples run on simulated time (Time 0.5×)",
      abs(n - 960) <= 1 && blocks == n / 64 && engine.wallClockTipRate == 480 && engine.trail.count == 240,
      "\(n) samples in 2 wall s (\(blocks) blocks of 64), wall-clock rate \(fmt(engine.wallClockTipRate, 3)) Hz")
    var idle = GyroscopeEngine()
    for _ in 0..<(120 * 12) { idle.advance(dtReal: frame, environment: HeavyTopEnvironment()) }
    log.check(
      "an undrained tip stream is bounded", idle.pendingTipCount == 8192 && idle.top.tipSamples.isEmpty,
      "\(idle.pendingTipCount) waiting after 12 s with nobody pulling")
    return log.checks
  }

  // MARK: - Charges (§4.10, §10 Boris)

  static func charges() -> [SpinCheck] {
    var log = SpinCheckLog()
    let e = ChargedSpecies.electron
    let field = SIMD3<Double>(0, 0, 50e-6)
    let v = Gyration.perpendicularRMSSpeed(e, temperature: 300)  // √(2kT/m) = 9.536e4 m/s
    let r0 = Gyration.gyroradius(e, perpendicularSpeed: v, field: 50e-6)
    let T0 = Gyration.period(e, field: 50e-6)
    log.check(
      "gyroradius and period (v⊥ = √(2kT/m), 300 K)", rel(r0, 1.08438e-2) < 1e-5 && rel(T0, 0.714477e-6) < 1e-5 && abs(v - 9.536e4) < 5,
      "v⊥ \(fmt(v, 6)) m/s, r \(fmt(r0 * 100, 6)) cm, T \(fmt(T0 * 1e6, 6)) µs")

    func orbit(stepsPerOrbit: Int, orbits: Int, exact: Bool) -> (radius: Double, period: Double, drift: Double) {
      var particle = ChargedParticle(species: e, velocity: SIMD3(v, 0, 0))
      let h = T0 / Double(stepsPerOrbit)
      let k0 = particle.kineticEnergy
      var drift = 0.0
      var swept = 0.0
      var sum = SIMD3<Double>.zero
      var points = [SIMD3<Double>]()
      points.reserveCapacity(stepsPerOrbit * orbits)
      for _ in 0..<(stepsPerOrbit * orbits) {
        let before = particle.velocity
        particle.borisStep(h: h, magnetic: field, exactPhase: exact)
        swept += atan2(simd_cross(before, particle.velocity).z, simd_dot(before, particle.velocity))
        drift = max(drift, abs(particle.kineticEnergy - k0) / k0)
        points.append(particle.position)
        sum += particle.position
      }
      let centre = sum / Double(points.count)
      let radius = points.map { simd_distance($0, centre) }.reduce(0, +) / Double(points.count)
      let w = abs(swept) / (h * Double(stepsPerOrbit * orbits))
      return (radius, 2 * .pi / w, drift)
    }
    let plain = orbit(stepsPerOrbit: 1000, orbits: 10, exact: false)
    log.check(
      "Boris at h = T/1000 (10⁴ steps)",
      rel(plain.radius, 1.08438e-2) < 1e-5 && rel(plain.period, 0.714477e-6) < 1e-5 && plain.drift < 1e-12,
      "r \(fmt(plain.radius * 100, 7)) cm, T \(fmt(plain.period * 1e6, 7)) µs, energy drift \(fmt(plain.drift, 2))")
    let coarse = orbit(stepsPerOrbit: 100, orbits: 10, exact: false)
    let fixed = orbit(stepsPerOrbit: 100, orbits: 10, exact: true)
    log.check(
      "plain Boris at 100 steps/orbit is phase-slow",
      abs(rel(coarse.period, T0) - 3.3e-4) < 0.3e-4 && abs(rel(coarse.radius, r0) - 4.9e-4) < 0.3e-4,
      "period +\(fmt(rel(coarse.period, T0), 2)), radius +\(fmt(rel(coarse.radius, r0), 2)) (review: 3.3e-4, 4.9e-4)")
    // The tan correction makes the turn per step exactly ω_c h; the drift x += v h still walks
    // a chord, so the orbit radius stays high by (θ/2)/sin(θ/2) − 1 ≈ θ²/24 (θ = 2π/100: 1.6e-4).
    let theta = 2 * Double.pi / 100
    let chordExcess = (theta / 2) / sin(theta / 2) - 1
    log.check(
      "tan-corrected Boris is phase-exact",
      rel(fixed.period, T0) < 1e-10 && abs(rel(fixed.radius, r0) - chordExcess) < 0.05 * chordExcess && fixed.drift < 1e-12,
      "period error \(fmt(rel(fixed.period, T0), 2)); radius +\(fmt(rel(fixed.radius, r0), 2)) = θ²/24 chord excess (plain: θ²/8)")

    let rRMS = Gyration.gyroradius(e, perpendicularSpeed: v, field: 50e-6)
    let rMP = Gyration.gyroradius(e, perpendicularSpeed: Gyration.perpendicularMostProbableSpeed(e, temperature: 300), field: 50e-6)
    let r390 = Gyration.gyroradius(e, perpendicularSpeed: v, field: 390e-6)
    let rp = Gyration.gyroradius(.proton, perpendicularSpeed: Gyration.perpendicularRMSSpeed(.proton, temperature: 300), field: 50e-6)
    log.check(
      "thermal gyroradii",
      abs(rRMS * 100 - 1.08) < 0.005 && abs(rMP * 100 - 0.77) < 0.005 && abs(r390 * 1000 - 1.39) < 0.005 && abs(rp - 0.46) < 0.01
        && abs(Gyration.cyclotronHz(e, field: 390e-6) / 1e6 - 10.92) < 0.005,
      "RMS v⊥ \(fmt(rRMS * 100, 3)) cm, most probable \(fmt(rMP * 100, 2)) cm; 390 µT: \(fmt(r390 * 1000, 3)) mm, \(fmt(Gyration.cyclotronHz(e, field: 390e-6) / 1e6, 4)) MHz; proton \(fmt(rp * 100, 3)) cm")

    let vd = Gyration.driftVelocity(electric: SIMD3(1, 0, 0), magnetic: field)
    var particle = ChargedParticle(species: e, velocity: .zero)
    let h = T0 / 200
    for _ in 0..<(200 * 50) { particle.borisStep(h: h, electric: SIMD3(1, 0, 0), magnetic: field, exactPhase: true) }
    let simDrift = particle.position / (h * 200 * 50)
    log.check(
      "E × B drift (1 V/m, 50 µT)", abs(simd_length(vd) - 2e4) < 1e-6 && rel(simd_length(simDrift), 2e4) < 2e-3 && simd_dot(simDrift, vd) > 0,
      "E/B \(fmt(simd_length(vd), 6)) m/s; simulated guiding centre \(fmt(simd_length(simDrift), 5)) m/s")

    let n = 101_325 / (SpinConstants.kB * 288.15)
    let nuM = Gyration.collisionFrequency(e, pressure: 101_325)
    let nuH = Gyration.collisionFrequency(e, pressure: 101_325, model: .hardSphere(crossSection: 1e-19))
    let pM = Gyration.gyrationPressure(e, field: 50e-6)
    let pH = Gyration.gyrationPressure(e, field: 50e-6, model: .hardSphere(crossSection: 1e-19))
    let ratio = Gyration.magnetizationParameter(e, field: 50e-6, pressure: 101_325)
    log.check(
      "collisions: gyration needs the D layer (~5 Pa)",
      rel(n, 2.55e25) < 0.01 && rel(Gyration.meanSpeed(e, temperature: 300), 1.08e5) < 0.01 && rel(nuM, 1.6e11) < 0.05
        && abs(pM - 5.5) < 0.3 && rel(nuH, 2.7e11) < 0.05 && pH > 2.5 && pH < 3.5 && abs(ratio - 5e-5) < 1e-5
        && rel(Gyration.cyclotronAngular(e, field: 50e-6), 8.79e6) < 1e-3,
      "measured rates: ν \(fmt(nuM, 3)) s⁻¹, ω_c/ν \(fmt(ratio, 2)), ω_c = ν at \(fmt(pM, 3)) Pa; σ = 10⁻¹⁹ m²: ν \(fmt(nuH, 3)), \(fmt(pH, 3)) Pa")

    var cloud = ChargeCloud(count: 40, pressure: 0, seed: 7)
    let speeds = cloud.particles.map { simd_length($0.velocity) }
    let D = SpinTiming.kappaRate(kappa: 1, referenceHz: Gyration.cyclotronHz(e, field: 50e-6))
    for _ in 0..<600 { cloud.advance(D / 60 * 50, magnetic: SIMD3(0, 20e-6, 45e-6)) }
    let after = cloud.particles.map { simd_length($0.velocity) }
    let worstSpeed = zip(speeds, after).map { rel($1, $0) }.max() ?? 1
    let inside = cloud.particles.allSatisfy { simd_length($0.position) <= cloud.radius * (1 + 1e-12) }
    log.check(
      "charge cloud in vacuum keeps |v| through gyration and wall bounces", worstSpeed < 1e-9 && inside,
      "worst |Δv|/v \(fmt(worstSpeed, 2))")
    // Spawned hot (3000 K) in sea-level air held at 300 K: collisions (ν ≈ 1.6e11 s⁻¹, so
    // 0.1 ns is 16 collision times) must cool it to 3/2 kT at 300 K, not to zero.
    var gas = ChargeCloud(count: 400, temperature: 3000, pressure: 101_325, seed: 3)
    let hot = gas.particles.map(\.kineticEnergy).reduce(0, +) / Double(gas.particles.count)
    gas.temperature = 300
    for _ in 0..<2 { gas.advance(0.05e-9, magnetic: field) }
    let ke = gas.particles.map(\.kineticEnergy).reduce(0, +) / Double(gas.particles.count)
    let kT = 1.5 * SpinConstants.kB * 300
    // The spawn is Maxwellian at 3000 K: ⟨½mv²⟩ = 10 × (3/2 kT₃₀₀) within 3σ of 400 draws (12 %).
    log.check(
      "charge cloud thermalizes in air (fluctuation–dissipation)", rel(ke, kT) < 0.1 && abs(hot / kT - 10) < 1.2,
      "⟨½mv²⟩ / (3/2 kT₃₀₀) from \(fmt(hot / kT, 3)) to \(fmt(ke / kT, 4)) in 0.1 ns at sea level")

    // Exact Langevin flight: at sea level the cloud diffuses with D = kT/(mν) and drifts at the
    // mobility velocity qE/(mν), with one substep per κ-slowed frame (was 4000, ~16 ms).
    // From a Maxwellian start, ⟨|Δx|²⟩ = 6D(t − (1 − e^(−νt))/ν) and ⟨Δx⟩ = (qE/mν)(t − (1 − e^(−νt))/ν).
    var air = ChargeCloud(count: 400, radius: 1, pressure: 101_325, seed: 11)
    let start = air.particles.map(\.position)
    let nuAir = air.collisionFrequency
    let tAir = 1e-9
    let eField = SIMD3<Double>(1e5, 0, 0)
    for _ in 0..<4 { air.advance(tAir / 4, magnetic: .zero, electric: eField) }
    let offsets = zip(air.particles, start).map { $0.position - $1 }
    let meanShift = offsets.reduce(SIMD3<Double>.zero, +) / Double(offsets.count)
    let msd = offsets.map { simd_length_squared($0 - meanShift) }.reduce(0, +) / Double(offsets.count)
    let lag = tAir - (1 - exp(-nuAir * tAir)) / nuAir
    let diffusion = SpinConstants.kB * 300 / (e.mass * nuAir)
    let mobility = e.chargeToMass / nuAir * eField.x
    let substeps = air.lastSubsteps
    // One flight step at νh = 1 from rest: the joint moments ⟨ξ_x²⟩ = σ²h²(2a − 3 + 4E − E²)/a²,
    // ⟨ξ_v²⟩ = σ²(1 − E²) and ⟨ξ_xξ_v⟩ = σ²h(1 − E)²/a (2·10⁴ draws, ~1 % sampling error).
    var rng = SpinRandom(seed: 5)
    let hOne = 1 / nuAir
    let s2 = SpinConstants.kB * 300 / e.mass
    var mxx = 0.0
    var mvv = 0.0
    var mxv = 0.0
    let draws = 20_000
    for _ in 0..<draws {
      var q = ChargedParticle(species: e, velocity: .zero)
      q.flight(h: hOne, collisionFrequency: nuAir, temperature: 300, rng: &rng)
      mxx += q.position.x * q.position.x
      mvv += q.velocity.x * q.velocity.x
      mxv += q.position.x * q.velocity.x
    }
    let eOne = exp(-1.0)
    let wantXX = s2 * hOne * hOne * (2 - 3 + 4 * eOne - eOne * eOne)
    let wantVV = s2 * (1 - eOne * eOne)
    let wantXV = s2 * hOne * (1 - eOne) * (1 - eOne)
    let moments = (mxx / Double(draws) / wantXX, mvv / Double(draws) / wantVV, mxv / Double(draws) / wantXV)
    var frameCloud = ChargeCloud(count: 48, pressure: 101_325, seed: 1)
    let kappaD = SpinTiming.kappaRate(kappa: 1, referenceHz: Gyration.cyclotronHz(e, field: 50e-6))
    let tFrame = Date()
    frameCloud.advance(kappaD / 60, magnetic: field)
    let frameMs = Date().timeIntervalSince(tFrame) * 1000
    log.check(
      "sea-level cloud: diffusion kT/(mν), mobility qE/(mν), one substep per frame",
      rel(msd, 6 * diffusion * lag) < 0.15 && rel(meanShift.x, mobility * lag) < 0.03 && substeps == 1
        && frameCloud.lastSubsteps == 1 && frameMs < 5
        && abs(moments.0 - 1) < 0.05 && abs(moments.1 - 1) < 0.05 && abs(moments.2 - 1) < 0.05,
      "⟨|Δx|²⟩/6Dt′ \(fmt(msd / (6 * diffusion * lag), 4)), ⟨Δx⟩/(μE t′) \(fmt(meanShift.x / (mobility * lag), 4)); flight moments at νh = 1: \(fmt(moments.0, 3)) / \(fmt(moments.1, 3)) / \(fmt(moments.2, 3)); κ frame \(frameCloud.lastSubsteps) substep, \(fmt(frameMs, 2)) ms")
    return log.checks
  }

  // MARK: - Optics, air, turntable (§5.1, §5.2, §4.5, §4.2 rows of §10)

  static func opticsAirTurntable() -> [SpinCheck] {
    var log = SpinCheckLog()
    let n = 1.33
    let r450 = BubbleOptics.filmReflectance(index: n, thickness: 420e-9, wavelength: 450e-9)
    let r530 = BubbleOptics.filmReflectance(index: n, thickness: 420e-9, wavelength: 530e-9)
    let r640 = BubbleOptics.filmReflectance(index: n, thickness: 420e-9, wavelength: 640e-9)
    let black = [450e-9, 530e-9, 640e-9].map { BubbleOptics.filmReflectance(index: n, thickness: 10e-9, wavelength: $0) }.max() ?? 1
    let r = (n - 1) / (n + 1)
    let rmax = 4 * r * r / ((1 + r * r) * (1 + r * r))
    log.check(
      "thin film (Airy), n 1.33, 420 nm",
      abs(r450 - 0.0769) < 1e-4 && abs(r530 - 0.0092) < 1e-4 && abs(r640 - 0.0412) < 1e-4 && black <= 0.003 && abs(rmax - 0.0771) < 1e-4,
      "R \(fmt(r640, 3)) / \(fmt(r530, 3)) / \(fmt(r450, 3)) at 640/530/450 nm; 10 nm black film ≤ \(fmt(black, 2)); max \(fmt(rmax, 4))")
    let si = [450e-9, 530e-9, 640e-9].map { BubbleOptics.index(.fusedSilica, wavelength: $0) }
    let bk = [450e-9, 530e-9, 640e-9].map { BubbleOptics.index(.nbk7, wavelength: $0) }
    let siRef = [1.46557, 1.46080, 1.45681]
    let bkRef = [1.52532, 1.51958, 1.51485]
    let worst = (zip(si, siRef).map { abs($0 - $1) } + zip(bk, bkRef).map { abs($0 - $1) }).max() ?? 1
    log.check(
      "Sellmeier fused silica / N-BK7", worst < 1e-5,
      "530 nm: \(fmt(si[1], 6)) / \(fmt(bk[1], 6)); worst |Δ| \(fmt(worst, 2)) over 450/530/640 nm")
    let w = [640e-9, 530e-9, 450e-9].map { BubbleOptics.waterIndex(wavelength: $0) }
    log.check(
      "water Cauchy fit", abs(w[0] - 1.3323) < 5e-5 && abs(w[1] - 1.3356) < 5e-5 && abs(w[2] - 1.3396) < 5e-5,
      "\(fmt(w[0], 5)) / \(fmt(w[1], 5)) / \(fmt(w[2], 5)) at 640/530/450 nm")

    let dry = AirHere.refractivity(pressureHPa: 1013.25, tempC: 15, humidity: 0).total
    let wet = AirHere.refractivity(pressureHPa: 1013.25, tempC: 15, humidity: 50).total
    let approx = AirHere.refractivityApproximation(pressureHPa: 1013.25, tempC: 15, humidity: 50)
    let e = AirHere.vaporPressure(tempC: 15, humidity: 50, pressureHPa: 1013.25)
    log.check(
      "P.453 refractivity", abs(dry - 272.87) < 0.01 && abs(wet - 311.37) < 0.01 && abs(approx - 311.36) < 0.01 && abs(e - 8.561) < 0.001,
      "N \(fmt(dry, 5)) dry, \(fmt(wet, 5)) at 50 % RH (eq. 7: \(fmt(approx, 5))), e \(fmt(e, 4)) hPa")
    let k = AirHere.kFactor(gradientPerKm: -40)
    let hz = AirHere.radioHorizon(height: 1.5)
    let zhd = AirHere.zenithHydrostaticDelay(pressureHPa: 1013.25, latitude: .pi / 4, height: 0)
    log.check(
      "k-factor, radio horizon, ZHD",
      abs(k - 1.34199) < 1e-5 && rel(hz, 5048) < 1e-3 && abs(zhd - 2.30697) < 1e-5 && abs(AirHere.ductingGradient + 157) < 0.1
        && abs(AirHere.metresPerHPa() - 8.32) < 0.01,
      "k \(fmt(k, 6)), horizon \(fmt(hz / 1000, 4)) km at 1.5 m, ZHD \(fmt(zhd, 6)) m, ducting \(fmt(AirHere.ductingGradient, 4)) N/km, \(fmt(AirHere.metresPerHPa(), 3)) m/hPa")

    let sigma = TurntableStatistics.simulatedDecibelSpread(count: 1_000_000, seed: 1)
    log.check(
      "Rayleigh RSSI σ (10⁶ samples, seed 1, ±0.03 dB)",
      abs(TurntableStatistics.rayleighDecibelSpread - 5.570) < 1e-3 && abs(sigma - 5.570) < 0.03,
      "analytic \(fmt(TurntableStatistics.rayleighDecibelSpread, 5)) dB, simulated \(fmt(sigma, 5)) dB")
    let plf = TurntableModel.polarizationLossDB(misalignment: 80 * .pi / 180)
    let dip = TurntableModel.halfWaveDipolePatternDB(theta: 30 * .pi / 180)
    let af60 = TurntableModel.uniformArrayFactor(elements: 8, spacingWavelengths: 0.5, phaseStep: 0, theta: 60 * .pi / 180)
    let af75 = TurntableModel.uniformArrayFactor(elements: 8, spacingWavelengths: 0.5, phaseStep: 0, theta: acos(0.25))
    log.check(
      "PLF, λ/2 dipole, ULA nulls",
      abs(plf + 15.2066) < 1e-4 && abs(dip + 7.5808) < 1e-4 && abs(af60) < 1e-12 && abs(af75) < 1e-12
        && abs(acos(0.25) * 180 / .pi - 75.52) < 0.005,
      "PLF(80°) \(fmt(plf, 6)) dB, F²(30°) \(fmt(dip, 5)) dB, AF(60°) \(fmt(af60, 2)): the second null; the first is at 75.52°")
    return log.checks
  }

  // MARK: - Knobs, blocks, sound

  static func knobsAndBlocks() -> [SpinCheck] {
    var log = SpinCheckLog()
    let m = SpinKnobs.magnet
    let roundTrip = (0...20).map { Double($0) / 20 }.map { abs(m.position(of: m.value(at: $0)) - $0) }.max() ?? 1
    let b0 = SpinKnobs.b0
    let mid = b0.value(at: b0.position(of: 50e-6))
    let mod = SpinKnobs.b1.modulated(base: 1e-6, depth: 0.5, control: 1)
    log.check(
      "knob maths (Gyre KnobSpec), signed magnet detents",
      m.detent(at: 0.138)?.label == "Real NdFeB" && m.detent(at: -1)?.label == "Electron-like" && roundTrip < 1e-12
        && rel(mid, 50e-6) < 1e-12 && rel(mod, 1e-6 * pow(10, 0.5 * 2)) < 1e-9 && SpinKnobs.motor.value(at: 0.501) == 6000,
      "NdFeB detent at \(fmt(HeavyTopParams.realNdFeBMagnet, 4)); log modulation 1 µT + ½ → \(fmt(mod / 1e-6, 4)) µT")
    let ranges =
      SpinKnobs.gyroscope + [
        SpinKnobs.b0, SpinKnobs.b1, SpinKnobs.offset, SpinKnobs.phase, SpinKnobs.t1, SpinKnobs.t2, SpinKnobs.gradient,
        SpinKnobs.isochromats, SpinKnobs.chargeAir, SpinKnobs.temperature, SpinKnobs.electricField,
      ]
    let defaultsInside = ranges.allSatisfy { knob in
      knob.range.contains(knob.defaultValue) && knob.detents.allSatisfy { knob.range.contains($0.value) }
    }
    log.check(
      "every knob default and detent is in range", defaultsInside && SpinKnobs.chargeAir.detent(at: 5)?.label == "D layer ~5 Pa",
      "\(ranges.count) knobs")
    var q = IQBlockQueue(capacity: 100)
    q.append(contentsOf: (0..<70).map { SIMD2(Double($0), 0) })
    let b1 = q.popBlock(size: 64)
    let b2 = q.popBlock(size: 64)
    q.append(contentsOf: (0..<200).map { SIMD2(Double($0), 0) })
    log.check(
      "IQ block queue",
      b1?.first?.x == 0 && b1?.last?.x == 63 && b1?.count == 64 && b2 == nil && q.count == 100 && q.samples.first?.x == 100,
      "fixed blocks in order, oldest dropped past capacity")
    let telemetry = HeavyTopTelemetry(
      rpm: 3000, precessionRate: 1.2, nutationRate: 2 * .pi * 39, freeNutationRate: 246.76, angularMomentum: 8.5e-3,
      momentum: .zero, torque: 0, torqueVector: .zero, strain: 0, tilt: 0.3, rotorGamma: 0)
    let sound = SpinSoundParameters(species: water, field: 50e-6, t2Star: 0.1, pitch: .truePitch, rotor: telemetry, timeScale: 0.25)
    log.check(
      "sound parameters", abs(sound.rotorNodHz - 9.75) < 1e-9 && abs(sound.rotorBladePassHz - 75) < 1e-9 && sound.fid.mode == .truePitch,
      "nod AM \(fmt(sound.rotorNodHz, 4)) Hz at D 0.25 (not 2·Ω_p + 1.5 Hz), blade pass \(fmt(sound.rotorBladePassHz, 3)) Hz")
    let presets = HeavyTopPreset.all
    log.check(
      "field trips", presets.count == 12 && Set(presets.map(\.id)).count == 12 && presets.contains { $0.resonance },
      "Gyre's nine + Real NdFeB, Electron-like, Magnetic resonance")
    return log.checks
  }

  // MARK: - Robustness: NaN, zero and negative inputs never trap or poison the state

  static func finite(_ v: SIMD3<Double>) -> Bool { v.x.isFinite && v.y.isFinite && v.z.isFinite }

  static func robustness() -> [SpinCheck] {
    var log = SpinCheckLog()

    // A negative flip angle turns the other way (it used to be dropped as a negative duration).
    var neg = BlochSimulator(b0: 50 * uT, drive: BlochDrive(b1: 1 * uT), relaxation: .none)
    neg.startPulse(RFPulse(degrees: -90))
    neg.step(0.05)
    var negEnsemble = SpinEnsemble(count: 1, relaxation: .none)
    negEnsemble.drive.b1 = 1 * uT
    negEnsemble.startPulse(RFPulse(degrees: -90))
    negEnsemble.advance(0.05)
    log.check(
      "negative flip angle (finite pulse)",
      simd_distance(neg.magnetization, SIMD3(0, -1, 0)) < 1e-9 && simd_distance(negEnsemble.meanMagnetization, SIMD3(0, -1, 0)) < 1e-9
        && rel(RFPulse(degrees: -90).duration(species: water, b1: 1 * uT), water.ninetyDuration(b1: 1 * uT)) < 1e-12,
      "−90° about x: M = (\(fmt(neg.magnetization.x, 2)), \(fmt(neg.magnetization.y, 9)), \(fmt(neg.magnetization.z, 2))), +90° gives +y")

    // T = 0 is instant relaxation, not "no relaxation".
    var instant = BlochSimulator(b0: 50 * uT, relaxation: BlochRelaxation(t1: 0, t2: 0, m0: 1))
    instant.applyHardPulse(.ninety)
    instant.step(1e-3)
    var noRelax = BlochSimulator(b0: 50 * uT, relaxation: BlochRelaxation(t1: .infinity, t2: .infinity, m0: 1))
    noRelax.applyHardPulse(.ninety)
    noRelax.step(1e-3)
    log.check(
      "T₁ = T₂ = 0 relaxes instantly, ∞ never",
      simd_distance(instant.magnetization, SIMD3(0, 0, 1)) < 1e-12 && abs(noRelax.transverseMagnitude - 1) < 1e-12,
      "M after 1 ms: \(fmt(instant.magnetization.z, 6)) along z (T = 0), |M⊥| \(fmt(noRelax.transverseMagnitude, 6)) (T = ∞)")

    // A NaN field holds M instead of poisoning it; the next good field carries on.
    var held = BlochSimulator(b0: 50 * uT, drive: BlochDrive(b1: 1 * uT, continuous: true), relaxation: BlochRelaxation())
    held.step(1e-3)
    let before = held.magnetization
    held.b0 = .nan
    held.step(1.0 / 60)
    let during = held.magnetization
    held.b0 = 50 * uT
    held.step(1.0 / 60)
    var ens = SpinEnsemble(count: 8, spread: .gradient(teslaPerMetre: 1 * uT, length: 0.1))
    ens.apply(.ninety)
    ens.offsetHz = .nan
    ens.advance(0.01)
    log.check(
      "NaN field leaves the spins finite",
      during == before && finite(held.magnetization) && held.frameAngle.isFinite && ens.magnetizations.allSatisfy(finite),
      "M held at (\(fmt(during.x, 3)), \(fmt(during.y, 3)), \(fmt(during.z, 3))) through a NaN |B|")

    // The gyroscope never traps on NaN knobs, NaN sensors or zero inertia (Int(NaN) used to).
    var gyro = GyroscopeEngine()
    var bad = gyro.params
    bad.timeScale = .nan
    bad.balance = .nan
    bad.magnet = .nan
    gyro.params = bad
    gyro.advance(dtReal: frame, environment: HeavyTopEnvironment(deviceRate: SIMD3(.nan, 0, 0), magneticField: SIMD3(0, .infinity, 0)))
    gyro.params = HeavyTopParams()
    gyro.advance(dtReal: frame, environment: HeavyTopEnvironment())
    var zero = HeavyTopParams()
    zero.inertia = 0
    var light = HeavyTop()
    light.launch(params: zero)
    for _ in 0..<120 { light.step(dtReal: frame, env: HeavyTopEnvironment(), params: zero) }
    light.applyImpulse(SIMD3(.nan, 0, 0))
    light.step(dtReal: frame, env: HeavyTopEnvironment(), params: zero)
    log.check(
      "gyroscope survives NaN knobs, NaN sensors, zero inertia",
      finite(gyro.top.axis) && finite(gyro.top.momentum) && gyro.top.time > 0 && gyro.wallClockTipRate == 960
        && finite(light.axis) && finite(light.momentum) && light.rpm.isFinite && light.time > 0.9,
      "after NaN inputs: tilt \(fmt(gyro.top.tilt, 4)) rad, rpm \(fmt(gyro.top.rpm, 5)); inertia 0 → clamped to 0.01×: \(fmt(light.rpm, 5)) rpm")

    var cloud = ChargeCloud(count: 8)
    cloud.advance(1e-9, magnetic: SIMD3(.nan, 0, 0))
    cloud.pressure = .nan
    cloud.temperature = .nan
    cloud.advance(1e-9, magnetic: SIMD3(0, 0, 50e-6))
    log.check(
      "charge cloud survives NaN field, pressure, temperature",
      cloud.particles.allSatisfy { finite($0.position) && finite($0.velocity) } && cloud.time == 1e-9,
      "a NaN field skips the frame; NaN air is vacuum")

    var src = SpinFIDSource(field: 50 * uT)
    src.pulse()
    src.updateField(.nan, dt: 0.01)
    src.setField(.infinity)
    src.follow(envelope: .nan)
    let audio = src.renderAudio(512)
    var osc = FIDOscillator(frequency: 2000)
    osc.trigger()
    osc.targetFrequency = .infinity
    osc.envelopeTarget = .nan
    let a1 = osc.render(64)
    osc.targetFrequency = 2000
    let a2 = osc.render(64)
    log.check(
      "audio voices ignore NaN and ∞ controls",
      abs(src.field - 50 * uT) < 1e-15 && audio.allSatisfy(\.isFinite) && a1.allSatisfy(\.isFinite) && a2.allSatisfy(\.isFinite)
        && a2.contains { $0 != 0 } && osc.phase.isFinite,
      "field stays \(fmt(src.field / uT, 4)) µT; oscillator keeps ringing")

    // Stiff relaxation (T₂ ≪ the frame, T₂ = 0 → 10¹² s⁻¹): the scaling-and-squaring
    // exponential needs ~37 squarings there; evolved as an affine 4 × 4 system its rounding
    // pushed M_z to 1.00024 (T₂ = 0) and 1.0021 (T₂ = 1 ps, T₁ = 5 s). Against the textbook CW
    // steady state M_z = (1 + Δ²T₂²)/(1 + Δ²T₂² + Ω₁²T₁T₂), and |M| ≤ M₀ throughout.
    func stiff(t1: Double, t2: Double) -> (error: Double, worstLength: Double) {
      let b1 = 10 * uT
      var s = BlochSimulator(b0: 50 * uT, drive: BlochDrive(b1: b1, offsetHz: 2, continuous: true), relaxation: BlochRelaxation(t1: t1, t2: t2, m0: 1))
      s.setMagnetization(SIMD3(0.3, 0.2, 0.5))
      var worst = 0.0
      for _ in 0..<(60 * 40) {
        s.step(1.0 / 60)
        worst = max(worst, simd_length(s.magnetization))
      }
      let w1 = 2 * Double.pi * water.gammaHzPerT * b1
      let dw = 2 * Double.pi * 2
      let t2e = max(t2, 1 / Bloch.maxRelaxationRate)
      let want = (1 + dw * dw * t2e * t2e) / (1 + dw * dw * t2e * t2e + w1 * w1 * t1 * t2e)
      return (abs(s.magnetization.z - want), worst)
    }
    let stiffZero = stiff(t1: 1, t2: 0)
    let stiffPico = stiff(t1: 1, t2: 1e-11)
    log.check(
      "stiff relaxation keeps the steady state and |M| ≤ M₀",
      stiffZero.error < 1e-9 && stiffPico.error < 1e-9 && stiffZero.worstLength <= 1 + 1e-12 && stiffPico.worstLength <= 1 + 1e-12,
      "T₂ = 0: |ΔM_z| \(fmt(stiffZero.error, 2)), max |M| − 1 \(fmt(stiffZero.worstLength - 1, 2)); T₂ = 10 ps: |ΔM_z| \(fmt(stiffPico.error, 2))")

    // A runaway Time knob (a mis-wired κ) is capped: D = 10⁷ used to append 1.6 × 10⁸ tip
    // samples (2.5 GB) and spend ~2 s in one frame.
    var runaway = GyroscopeEngine()
    var fast = runaway.params
    fast.timeScale = 1e7
    runaway.params = fast
    let tRun = Date()
    runaway.advance(dtReal: 1.0 / 60, environment: HeavyTopEnvironment())
    let runMs = Date().timeIntervalSince(tRun) * 1000
    log.check(
      "runaway time scale is capped",
      runaway.pendingTipCount <= Int(HeavyTop.tipSampleRate * HeavyTopParams.maxTimeScale / 60) + 1
        && runaway.wallClockTipRate == HeavyTop.tipSampleRate * HeavyTopParams.maxTimeScale && runMs < 50
        && finite(runaway.top.axis),
      "D 10⁷ → \(fmt(HeavyTopParams.maxTimeScale, 2))×: \(runaway.pendingTipCount) tip samples in one frame, \(fmt(runMs, 2)) ms")

    // Charges spawned hot keep their speed in vacuum after the Temperature knob drops; substeps
    // sized by the knob alone let them cross the bubble in one step and the wall reflection
    // parked them at the centre (770 times in 200 frames here). Also: a NaN temperature spawns
    // finite charges, and switching species respawns the cloud.
    var hotCloud = ChargeCloud(count: 48, temperature: 3000, pressure: 0, seed: 2)
    hotCloud.temperature = 30
    var parked = 0
    var hotSpeedDrift = 0.0
    let hotSpeeds = hotCloud.particles.map { simd_length($0.velocity) }
    for _ in 0..<200 {
      hotCloud.advance(1e-6, magnetic: SIMD3(0, 0, 0.1 * uT))
      parked += hotCloud.particles.filter { simd_length($0.position) < 1e-9 }.count
    }
    hotSpeedDrift = zip(hotSpeeds, hotCloud.particles).map { rel(simd_length($1.velocity), $0) }.max() ?? 1
    let nanSpawn = ChargeCloud(count: 4, temperature: .nan)
    var switched = ChargeCloud(count: 6)
    switched.species = .proton
    log.check(
      "charge cloud: hot charges after a cooler knob, NaN spawn, species switch",
      parked == 0 && hotSpeedDrift < 1e-9 && hotCloud.particles.allSatisfy { simd_length($0.position) <= hotCloud.radius * (1 + 1e-12) }
        && nanSpawn.particles.allSatisfy { finite($0.velocity) && finite($0.position) }
        && switched.particles.count == 6 && switched.particles.allSatisfy { $0.species == .proton },
      "\(parked) parked at the centre, |Δv|/v \(fmt(hotSpeedDrift, 2)), \(hotCloud.lastSubsteps) substeps per frame")

    var acq = SpinEnsemble(count: 2)
    let none = acq.acquire(.fid, duration: .infinity, sampleRate: 1000)
    let x = (0..<480).map { sin(2 * .pi * 50 * Double($0) / 480) }
    let tone = SpinAnalysis.toneFrequency(x, sampleRate: 480, in: 0...(.infinity))
    let shortWindow = SpinAnalysis.power(x, sampleRate: 480, at: 50, window: [1, 1])
    log.check(
      "open-ended inputs are bounded (acquire ∞, band to ∞, short window)",
      none.isEmpty && abs(tone - 50) < 1e-4 && shortWindow.isFinite && shortWindow > 0,
      "tone \(fmt(tone, 8)) Hz in 0…∞")
    return log.checks
  }
}

#if !SPECTRA_HARNESS
  /// XCTest runner for the oracle suite: one test per group, one failure per failing check.
  final class SpinTests: XCTestCase {
    private func assertOracles(_ checks: [SpinCheck], file: StaticString = #filePath, line: UInt = #line) {
      XCTAssertFalse(checks.isEmpty, "no checks ran", file: file, line: line)
      for c in checks where !c.passed { XCTFail("\(c.name) — \(c.detail)", file: file, line: line) }
    }

    func testLarmorCyclotronAndGMinusTwo() { assertOracles(SpinOracleSuite.larmorCyclotronAndGMinusTwo()) }
    func testRabiAndBloch() { assertOracles(SpinOracleSuite.rabiAndBloch()) }
    func testLabFrame() { assertOracles(SpinOracleSuite.labFrame()) }
    func testEnsembleDephasingAndEcho() { assertOracles(SpinOracleSuite.ensemble()) }
    func testFIDSignalAndSpectrum() { assertOracles(SpinOracleSuite.fidSignal()) }
    func testEarthFieldAndReadouts() { assertOracles(SpinOracleSuite.earthField()) }
    func testGyrePhyscheck() { assertOracles(SpinOracleSuite.physcheck()) }
    func testHeavyTopWorkedValues() { assertOracles(SpinOracleSuite.heavyTopWorkedValues()) }
    func testRotorMagneticResonance() { assertOracles(SpinOracleSuite.rotorResonance()) }
    func testGyroscopeTipIQ() { assertOracles(SpinOracleSuite.tipIQ()) }
    func testChargedParticles() { assertOracles(SpinOracleSuite.charges()) }
    func testOpticsAirTurntable() { assertOracles(SpinOracleSuite.opticsAirTurntable()) }
    func testKnobsBlocksSound() { assertOracles(SpinOracleSuite.knobsAndBlocks()) }
    func testRobustnessAtTheEdges() { assertOracles(SpinOracleSuite.robustness()) }

    /// Every group in the suite has a test method above.
    func testSuiteIsFullyWired() { XCTAssertEqual(SpinOracleSuite.groups.count, 14) }
  }
#endif
