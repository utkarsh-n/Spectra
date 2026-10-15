import Foundation
import simd

nonisolated extension RF {
  /// Where a readout's number comes from, so the UI can badge it (formula/numeric → MODEL,
  /// table → TABLE, estimate → MODEL with a caveat).
  enum ValueBasis: String, Codable, Hashable, Sendable {
    /// A closed-form formula from the verified reference.
    case formula
    /// Numerical integration or search over the pattern model.
    case numeric
    /// A published design table (NBS TN 688, standards tables).
    case table
    /// A rule of thumb or qualitative model ([S] in the reference).
    case estimate
  }

  /// A labelled number with its basis.
  struct Readout: Hashable, Sendable {
    var value: Double
    var basis: ValueBasis
    /// Short label of the formula or source ("Kraus D = 12C²NS", "NBS TN 688").
    var source: String
  }

  /// Antenna field regions (rf-physics A.17).
  struct FieldRegions: Hashable, Sendable {
    /// Largest dimension D of the radiating structure, m.
    let size: Double
    let wavelength: Double
    /// Reactive near-field boundary 0.62√(D³/λ), m.
    var reactiveNearField: Double { RF.Antennas.reactiveNearFieldBoundary(size: size, wavelength: wavelength) }
    /// Fraunhofer distance 2D²/λ, m.
    var farField: Double { RF.Antennas.farFieldBoundary(size: size, wavelength: wavelength) }
    /// λ/2π, the boundary for electrically small antennas, m.
    var smallAntennaBoundary: Double { RF.Antennas.smallAntennaBoundary(wavelength: wavelength) }
    /// True when D ≤ λ/2π: then λ/2π is the only meaningful boundary.
    var isElectricallySmall: Bool { size <= smallAntennaBoundary }

    enum Region: String, Sendable {
      case reactiveNear, radiatingNear, far
    }

    /// The region at distance r (m).
    func region(at r: Double) -> Region {
      if isElectricallySmall { return r < smallAntennaBoundary ? .reactiveNear : .far }
      if r < max(reactiveNearField, smallAntennaBoundary) { return .reactiveNear }
      return r < max(farField, smallAntennaBoundary) ? .radiatingNear : .far
    }
  }

  /// A configured antenna: its normalized far-field pattern F(θ, φ) with polarization, and every
  /// readout of the Antenna page. Building one integrates the pattern numerically (a few ms at
  /// most), so rebuild it when a knob changes, not per frame.
  ///
  /// Directions are unit vectors in the antenna's local frame (see `AntennaStyle`); θ is from +z
  /// and φ from +x.
  struct AntennaModel: Sendable {
    /// The parameters the model was built from: the caller's, clamped into
    /// `AntennaParameters.Limits` (`sanitized()`), so readouts match what is drawn.
    let parameters: AntennaParameters
    /// Carrier wavelength, m.
    let wavelength: Double
    /// Unit vector of the pattern maximum (one of them when several are equal).
    let peakDirection: SIMD3<Double>
    /// Directivity of the pattern model, linear (numerical integration over the sphere).
    let directivity: Double
    /// E-plane and H-plane half-power beamwidths through the peak, degrees (nil when the cut
    /// never falls to half power, e.g. a dipole's omnidirectional H-plane).
    let ePlaneHPBWDeg: Double?
    let hPlaneHPBWDeg: Double?
    /// In-plane unit vectors of the E- and H-plane cuts (each cut is cosα·peak + sinα·axis).
    let ePlaneAxis: SIMD3<Double>
    let hPlaneAxis: SIMD3<Double>

    private let kind: PatternKind
    private let normalization: Double

    // MARK: Building

    init(_ requested: AntennaParameters) {
      let parameters = requested.sanitized()
      self.parameters = parameters
      let lambda = parameters.wavelength
      wavelength = lambda
      let kind = PatternKind(parameters)
      self.kind = kind
      // Peak: analytic guess, refined for patterns whose maximum moves (dipoles > 1.25λ, arrays
      // with an element pattern).
      let guess = kind.peakGuess(parameters)
      let peak = AntennaModel.refinePeak(guess, kind: kind)
      peakDirection = peak
      let fmax = max(kind.raw(peak), 1e-300)
      normalization = 1 / fmax
      // Directivity D = 4π·F_max² / ∮F² dΩ.
      let integral = AntennaModel.integrate(kind: kind, parameters: parameters) { d in
        let f = kind.raw(d) / fmax
        return f * f
      }
      directivity = integral > 0 ? 4 * Double.pi / integral : 0
      // Cuts: E-plane contains the peak and the polarization at the peak.
      var e = kind.polarization(peak).re
      if simd_length(e) < 1e-9 { e = kind.polarization(peak).im }
      e -= simd_dot(e, peak) * peak
      if simd_length(e) < 1e-9 { e = AntennaModel.perpendicular(to: peak) }
      let eAxis = simd_normalize(e)
      let h = simd_normalize(simd_cross(peak, eAxis))
      ePlaneAxis = eAxis
      hPlaneAxis = h
      let step = AntennaModel.cutStep(kind: kind, parameters: parameters)
      let cutE: (Double) -> Double = { a in
        let r = a * Double.pi / 180
        let f = kind.raw(cos(r) * peak + sin(r) * eAxis) / fmax
        return f * f
      }
      let cutH: (Double) -> Double = { a in
        let r = a * Double.pi / 180
        let f = kind.raw(cos(r) * peak + sin(r) * h) / fmax
        return f * f
      }
      ePlaneHPBWDeg = RF.Antennas.halfPowerBeamwidth(peakDeg: 0, rangeDeg: -180...180, step: step, cutE)
      hPlaneHPBWDeg = RF.Antennas.halfPowerBeamwidth(peakDeg: 0, rangeDeg: -180...180, step: step, cutH)
    }

    // MARK: Pattern

    /// Normalized field magnitude |F| (0…1) toward a local direction (need not be unit length).
    func field(_ direction: SIMD3<Double>) -> Double {
      let n = simd_length(direction)
      guard n > 0 else { return 0 }
      return min(1, kind.raw(direction / n) * normalization)
    }

    /// Normalized field magnitude at spherical angles (radians; θ from +z, φ from +x).
    func field(theta: Double, phi: Double) -> Double {
      field(SIMD3(sin(theta) * cos(phi), sin(theta) * sin(phi), cos(theta)))
    }

    /// Normalized power pattern |F|².
    func power(_ direction: SIMD3<Double>) -> Double {
      let f = field(direction)
      return f * f
    }

    /// Transmit polarization toward a direction (unit-norm complex vector transverse to it).
    func polarization(_ direction: SIMD3<Double>) -> PolarizationVector {
      let d = simd_normalize(direction)
      var p = kind.polarization(d).transverse(to: d)
      let n = p.normSquared.squareRoot()
      if n < 1e-12 {
        p = PolarizationVector.linear(AntennaModel.perpendicular(to: d))
      } else {
        p = PolarizationVector(re: p.re / n, im: p.im / n)
      }
      return p
    }

    /// Directivity toward a direction in dBi (−∞ in a null).
    func directivityDBi(toward direction: SIMD3<Double>) -> Double {
      10 * log10(directivity * power(direction))
    }

    /// Realized gain toward a direction in dBi: peak gain, pattern, and mismatch loss when known
    /// (−∞ when the feed reflects everything, e.g. a thin-wire dipole at L = nλ).
    func gainDBi(toward direction: SIMD3<Double>) -> Double {
      gainDBi + 10 * log10(max(power(direction), 1e-30)) - (mismatch?.mismatchLossDB ?? 0)
    }

    /// Polarization loss factor between this antenna (transmitting toward `direction`) and a
    /// receiving antenna of reference polarization `receiver` at that direction, facing back.
    /// "Vertical" is the projection of `up` (local frame) on the receiver's aperture.
    func polarizationLossFactor(toward direction: SIMD3<Double>, receiver: ReferencePolarization, up: SIMD3<Double> = SIMD3(0, 0, 1)) -> Double {
      let d = simd_normalize(direction)
      let rx = receiver.vector(propagation: -d, up: up)
      return polarization(d).plf(with: rx)
    }

    // MARK: Readouts

    /// Directivity in dBi.
    var directivityDBi: Double { 10 * log10(directivity) }

    /// Radiation efficiency e_rad (style default 1; PIFA 0.55, mid of the 40–70 % range).
    var radiationEfficiency: Double {
      if let e = parameters.radiationEfficiency { return min(1, max(0.0001, e)) }
      return parameters.style == .pifa ? 0.55 : 1
    }

    /// The reference's own gain/directivity figure for this style, when it has one that differs
    /// from the pattern integral (aperture formulas, design tables, helix estimators).
    var referenceGain: Readout? {
      let p = parameters
      switch p.style {
      case .yagi:
        let boom = Double(clampedYagiElements - 1) * p.yagiSpacing
        let g = RF.Antennas.yagiGainDBd(boomWavelengths: boom)
        return Readout(value: RF.Units.dBi(fromDBd: g.gainDBd), basis: .table, source: g.insideTable ? "NBS TN 688 design gain" : "NBS TN 688 (boom outside table)")
      case .helix:
        return Readout(value: 10 * log10(helix.krausDirectivity), basis: .formula, source: "Kraus D = 12C²NS")
      case .horn:
        let g = RF.Antennas.hornGain(apertureA: p.hornA, apertureB: p.hornB, efficiency: p.hornEfficiency)
        return Readout(value: 10 * log10(g), basis: .formula, source: "G = ε_ap·4πAB/λ²")
      case .dish:
        let g = RF.Antennas.dishGain(diameter: p.dishDiameter, efficiency: p.dishEfficiency)
        return Readout(value: 10 * log10(g), basis: .formula, source: "G = η(πD/λ)²")
      case .phasedArray:
        let el = p.arrayElement == .isotropic ? 0 : AntennaModel.patchElementDirectivityDBi
        let n = max(1, p.arrayNx) * max(1, p.arrayNy)
        return Readout(value: RF.Antennas.planarArrayGainDBi(elementGainDBi: el, nx: max(1, p.arrayNx), ny: max(1, p.arrayNy)), basis: .formula,
                       source: n == 1 ? "single element" : "G_el + 10·log10(N)")
      default:
        return nil
      }
    }

    /// Headline gain in dBi: the reference formula or table where one exists (horn, dish, Yagi,
    /// helix, array), otherwise the pattern directivity times the radiation efficiency.
    var gainDBi: Double {
      switch parameters.style {
      case .yagi, .helix, .horn, .dish: return referenceGain?.value ?? directivityDBi
      default: return directivityDBi + 10 * log10(radiationEfficiency)
      }
    }

    /// Where `gainDBi` comes from.
    var gainBasis: Readout {
      switch parameters.style {
      case .yagi, .helix, .horn, .dish:
        if let r = referenceGain { return r }
        return Readout(value: directivityDBi, basis: .numeric, source: "pattern integral")
      case .pifa:
        return Readout(value: gainDBi, basis: .estimate, source: "D × e_rad (phones 40–70 %)")
      default:
        return Readout(value: gainDBi, basis: .numeric, source: "D × e_rad")
      }
    }

    /// Effective aperture A_e = G·λ²/4π (m²) of the headline gain.
    var effectiveAperture: Double {
      RF.Antennas.effectiveAperture(gain: pow(10, gainDBi / 10), wavelength: wavelength)
    }

    /// Radiation resistance (Ω) where the reference gives one: Hertzian/short dipole, thin
    /// dipole (at the current maximum), monopole, small loop.
    var radiationResistance: Readout? {
      let p = parameters
      switch p.style {
      case .shortDipole:
        return Readout(value: RF.Antennas.shortDipoleRadiationResistance(lengthWavelengths: clampedShortDipole), basis: .formula, source: "R_r = 20π²(l/λ)²")
      case .dipole:
        return Readout(value: thinDipole.radiationResistance(), basis: .numeric, source: "R_r = η𝓘/2π")
      case .monopole:
        return Readout(value: monopoleDipole.radiationResistance() / 2, basis: .numeric, source: "half of the 2H dipole")
      case .smallLoop:
        return Readout(
          value: RF.Antennas.smallLoopRadiationResistance(area: p.loopArea, frequency: p.frequency, turns: p.loopTurns, muEffective: p.loopMuEffective),
          basis: .formula, source: "R_r = (8/3)ηπ³(A/λ²)²N²μ²")
      default:
        return nil
      }
    }

    /// Input impedance at the feed (Ω) and whether only its resistance is known.
    var inputImpedance: (z: RF.Complex, resistiveOnly: Bool, source: String)? {
      let p = parameters
      switch p.style {
      case .shortDipole:
        return (RF.Complex(radiationResistance!.value), true, "radiation resistance only")
      case .dipole:
        let r = thinDipole.inputResistance()
        if abs(clampedDipole - 0.5) < 1e-9 { return (RF.Complex(r, RF.Antennas.halfWaveDipoleReactance), false, "73 + j42.5 Ω") }
        return (RF.Complex(r), true, "R_in = R_r/sin²(πL)")
      case .monopole:
        if abs(clampedMonopole - 0.25) < 1e-9 { return (RF.Complex(monopoleDipole.inputResistance() / 2, 21.25), false, "36.5 + j21.25 Ω") }
        return (RF.Complex(monopoleDipole.inputResistance() / 2), true, "half the 2H dipole R_in")
      case .smallLoop:
        return (RF.Complex(radiationResistance!.value), true, "radiation resistance only (coil reactance not modeled)")
      case .helix:
        return (RF.Complex(helix.inputResistance), false, "R_in ≈ 140·C Ω (axial mode, nearly resistive)")
      default:
        return nil
      }
    }

    /// Mismatch to the reference impedance (nil when the feed is assumed matched: patch, Yagi with
    /// its matching network, horn, dish, array, PIFA).
    var mismatch: Mismatch? {
      guard let z = inputImpedance else { return nil }
      return Mismatch(load: z.z, reference: parameters.referenceImpedance, resistiveOnly: z.resistiveOnly)
    }

    /// Field-region boundaries for the antenna's largest dimension.
    var fieldRegions: FieldRegions { FieldRegions(size: largestDimension, wavelength: wavelength) }

    /// Largest dimension of the radiating structure, m.
    var largestDimension: Double {
      let p = parameters
      let l = wavelength
      switch p.style {
      case .shortDipole: return clampedShortDipole * l
      case .dipole: return clampedDipole * l
      case .monopole: return 2 * clampedMonopole * l
      case .smallLoop: return (4 * p.loopArea / Double.pi).squareRoot()
      case .patch:
        let d = patchDesign
        return (d.width * d.width + d.length * d.length).squareRoot()
      case .yagi: return max(Double(clampedYagiElements - 1) * p.yagiSpacing, 0.5) * l
      case .helix: return max(p.helixTurns * p.helixSpacing, p.helixCircumference / Double.pi) * l
      case .horn: return (p.hornA * p.hornA + p.hornB * p.hornB).squareRoot() * l
      case .dish: return p.dishDiameter * l
      case .phasedArray:
        let ax = Double(max(1, p.arrayNx) - 1) * p.arraySpacing
        let ay = Double(max(1, p.arrayNy) - 1) * p.arraySpacing
        return max((ax * ax + ay * ay).squareRoot(), 0.5) * l
      case .pifa: return pifaPath
      }
    }

    /// Plain-language polarization of the main beam.
    var polarizationDescription: String {
      switch parameters.style {
      case .helix:
        return String(format: "Circular (RHCP), axial ratio %.2f", helix.axialRatio)
      case .smallLoop:
        return "Linear, in the plane of the loop"
      case .shortDipole, .dipole, .monopole:
        return "Linear, along the wire"
      case .pifa:
        return "Linear, mostly along the phone's long axis"
      default:
        return "Linear (E-plane)"
      }
    }

    /// Fractional bandwidth where the reference states one (Yagi ≤ 2 %).
    var bandwidthNote: String? {
      switch parameters.style {
      case .yagi: "≤ 2 % without broadbanding (SDSMT EE483)"
      case .pifa: "Narrow; tuned per band by the phone's antenna switch"
      default: nil
      }
    }

    /// Honest caveats for the field notes and readout footers.
    var notes: [String] {
      let p = parameters
      var out: [String] = []
      switch p.style {
      case .dipole:
        if clampedDipole > 1.25 {
          out.append(String(format: "Above 1.25λ the main lobe leaves broadside (here at %.1f° from the wire).", acos(abs(peakDirection.z)) * 180 / Double.pi))
        }
        if abs(sin(Double.pi * clampedDipole)) < 1e-6 {
          out.append("At L = nλ a thin center-fed dipole sits at a current null: its input resistance is infinite in the thin-wire model.")
        }
      case .monopole:
        out.append("Infinite perfect ground. A phone-sized ground lowers the gain and tilts the pattern.")
        if abs(sin(2 * Double.pi * clampedMonopole)) < 1e-6 {
          out.append("At H = nλ/2 the feed sits at a current null: the input resistance is infinite in the thin-wire model.")
        }
      case .smallLoop:
        let circumference = Double.pi * largestDimension / wavelength
        if circumference > 0.1 {
          out.append(String(format: "The small-loop formulas assume a uniform current, C ≲ λ/10; this coil's circumference is %.2fλ.", circumference))
        } else {
          out.append("The coil is far smaller than λ, so it couples through its near field; NFC works by transformer coupling, not radiation.")
        }
      case .patch:
        out.append("Two-slot transmission-line model (Balanis §14.2); input impedance assumed matched by an inset feed.")
        if let e = ePlaneHPBWDeg, e > 179 {
          out.append("In the two-slot model this patch's E-plane stays above half power down to the ground plane, so its E-plane beamwidth is the whole half-space.")
        }
        let d = patchDesign
        if d.width < p.patchHeight || d.length <= 0 {
          out.append(String(format: "The design equations assume W/h ≥ 1; here W/h = %.2f%@, so the substrate is too thick for this frequency.",
                            d.width / p.patchHeight, d.length <= 0 ? " and the fringing correction exceeds the patch length" : ""))
        }
      case .yagi:
        out.append("Pattern: Hansen–Woodyard end-fire array of λ/2 elements. Gain readout: NBS TN 688 optimized designs, which set gain by boom length.")
      case .helix:
        if let e = helix.emersonGainDBi {
          out.append(String(format: "Kraus is optimistic by up to 4–5 dB; measured designs reach about %.1f dBi (Emerson, NRAO).", e))
        } else {
          out.append("Kraus is optimistic by up to 4–5 dB (Emerson's realistic curve covers axial lengths 2–7λ).")
        }
        if !helix.isAxialMode { out.append("C/λ is outside 0.75–1.33, so the helix is not in axial mode.") }
        let pitch = atan2(p.helixSpacing, p.helixCircumference) * 180 / Double.pi
        if pitch < 11 || pitch > 15.5 {
          out.append(String(format: "Kraus's estimators assume a pitch of about 12–14° (S ≈ λ/4); this helix is wound at %.1f°.", pitch))
        }
        if helix.krausDirectivity < 2 {
          out.append("Kraus's D = 12C²NS is below 2 here, outside its range; the pattern shown is the broadest axial lobe (D = 2).")
        }
      case .horn:
        out.append("Pattern: in-phase TE₁₀ aperture. Gain uses the optimum horn's aperture efficiency, which includes flare phase error.")
      case .dish:
        out.append(String(format: "Uniform-aperture HPBW %.3f°; a typical tapered feed gives about %.3f° (70λ/D).",
                          RF.Antennas.uniformApertureHPBWDeg(diameter: p.dishDiameter), RF.Antennas.taperedDishHPBWDeg(diameter: p.dishDiameter)))
      case .phasedArray:
        if !arrayGratingLobes.isEmpty {
          out.append(String(format: "Grating lobes: d = %.2fλ exceeds the grating-free limit %.3fλ at this steering angle.", p.arraySpacing, arrayGratingFreeSpacing))
        }
      case .pifa:
        out.append("Qualitative model: resonance where the top-plate current path is about λ/4; phone efficiency 40–70 %, worst in the 600–960 MHz band and in the hand.")
      default:
        break
      }
      return out
    }

    // MARK: Style helpers (public for the readouts)

    /// The helix estimators for the current parameters.
    var helix: RF.Antennas.HelixEstimates {
      RF.Antennas.HelixEstimates(circumference: parameters.helixCircumference, turns: parameters.helixTurns, spacing: parameters.helixSpacing)
    }

    /// The patch dimensions designed for the carrier.
    var patchDesign: RF.Antennas.PatchDesign {
      RF.Antennas.PatchDesign(epsilonR: parameters.patchEpsilonR, height: parameters.patchHeight, frequency: parameters.frequency)
    }

    /// PIFA resonance for the current path (Hz).
    var pifaResonance: Double { RF.Antennas.pifaResonantFrequency(currentPath: pifaPath) }

    /// The array's grating-free spacing limit at the current steering angle (λ).
    var arrayGratingFreeSpacing: Double {
      RF.Arrays.gratingFreeSpacing(steerFromBroadside: parameters.steerTheta * Double.pi / 180)
    }

    /// Grating-lobe directions (local unit vectors) of the array at the current steering.
    var arrayGratingLobes: [SIMD3<Double>] {
      guard case .array(let a) = kind else { return [] }
      return a.gratingLobes()
    }

    /// Steering angles (θ from broadside, φ in the array plane; degrees) that point a phased
    /// array's beam at a local direction — the "Beam lock" knob. The direction is folded into the
    /// front half-space.
    static func steering(toward direction: SIMD3<Double>) -> (theta: Double, phi: Double) {
      let d = simd_normalize(direction)
      let theta = acos(min(1, abs(d.z))) * 180 / Double.pi
      let phi = atan2(d.y, d.x) * 180 / Double.pi
      return (theta, phi)
    }

    /// Expresses a world-frame direction in the antenna's local frame given the antenna's
    /// attitude (local → world rotation), e.g. the phone's attitude quaternion.
    static func localDirection(world: SIMD3<Double>, attitude: simd_quatd) -> SIMD3<Double> {
      attitude.inverse.act(world)
    }

    // MARK: Internals

    fileprivate static let patchElementDirectivityDBi: Double = {
      let p = AntennaParameters(style: .patch, frequency: 28e9)
      var q = p
      q.patchEpsilonR = 3
      q.patchHeight = 0.02 * RF.Const.c / 28e9
      return AntennaModel(q).directivityDBi
    }()

    private var clampedShortDipole: Double { AntennaModel.clamp(parameters.shortDipoleLength, AntennaParameters.Limits.shortDipoleLength) }
    private var clampedDipole: Double { AntennaModel.clamp(parameters.dipoleLength, AntennaParameters.Limits.dipoleLength) }
    private var clampedMonopole: Double { AntennaModel.clamp(parameters.monopoleHeight, AntennaParameters.Limits.monopoleHeight) }
    private var clampedYagiElements: Int { min(max(parameters.yagiElements, 3), 20) }
    private var thinDipole: RF.Antennas.ThinDipole { RF.Antennas.ThinDipole(lengthWavelengths: clampedDipole) }
    private var monopoleDipole: RF.Antennas.ThinDipole { RF.Antennas.ThinDipole(lengthWavelengths: 2 * clampedMonopole) }
    private var pifaPath: Double { parameters.pifaCurrentPath ?? wavelength / 4 }

    fileprivate static func clamp(_ x: Double, _ r: ClosedRange<Double>) -> Double { min(max(x, r.lowerBound), r.upperBound) }

    fileprivate static func perpendicular(to d: SIMD3<Double>) -> SIMD3<Double> {
      let a = abs(d.z) < 0.9 ? SIMD3<Double>(0, 0, 1) : SIMD3<Double>(1, 0, 0)
      return simd_normalize(a - simd_dot(a, d) * d)
    }

    /// The pattern maximum. Patterns whose maximum moves (a patch-element array steered off
    /// broadside) are refined from the analytic guess and from every grating lobe — with a patch
    /// element a grating lobe nearer broadside can outgrow the steered beam, and the pattern must
    /// be normalized to the true maximum so |F| ≤ 1 everywhere.
    private static func refinePeak(_ guess: SIMD3<Double>, kind: PatternKind) -> SIMD3<Double> {
      guard kind.needsPeakRefinement else { return guess }
      var candidates = [guess]
      if case .array(let a) = kind { candidates += a.gratingLobes() }
      var best = simd_normalize(guess)
      var bestValue = kind.raw(best)
      for c in candidates {
        let p = refine(simd_normalize(c), kind: kind)
        let v = kind.raw(p)
        if v > bestValue {
          best = p
          bestValue = v
        }
      }
      return best
    }

    /// Alternating golden-section searches along two perpendicular great circles through `start`.
    /// The search span stays inside the main lobe (`peakSearchSpan`), so a large array's narrow
    /// beam is not traded for a sidelobe.
    private static func refine(_ start: SIMD3<Double>, kind: PatternKind) -> SIMD3<Double> {
      var p = start
      var span = kind.peakSearchSpan
      for _ in 0..<4 {
        let u = perpendicular(to: p)
        let v = simd_normalize(simd_cross(p, u))
        for axis in [u, v] {
          let best = RF.Numerics.maximize(-span, span, tolerance: 1e-9) { a in kind.raw(cos(a) * p + sin(a) * axis) }
          let q = simd_normalize(cos(best) * p + sin(best) * axis)
          if kind.raw(q) >= kind.raw(p) { p = q }
        }
        span *= 0.5
      }
      return p
    }

    /// ∫ f dΩ over the half-space z ≥ 0 in spherical coordinates about the x axis:
    /// d = (sin s, cos s·sin t, cos s·cos t), s, t ∈ [−π/2, π/2], dΩ = cos s·ds·dt. Products of
    /// aperture or array factors in d.x and d.y then have lobes evenly spaced in sin s and in
    /// cos s·sin t, and nothing is singular: the lobe of a grating lobe at endfire (d = ±x) stays
    /// smooth in s, which it is not in u = d.x. Gauss–Legendre (8 nodes) on panels two lobes wide
    /// where lobes are narrowest (`lobesX` lobes across d.x ∈ [−1, 1], `lobesY` across d.y): against
    /// the exact sum formula for isotropic planar arrays up to 64 × 64 at 2λ the error is < 1e-5 dB.
    static func integrateFrontHemisphere(lobesX: Double, lobesY: Double, _ f: (SIMD3<Double>) -> Double) -> Double {
      let rule = RF.Numerics.GaussLegendre.order8
      // d.x = sin s: lobes are narrowest in s at s = 0, where d(d.x)/ds = 1.
      let panelsS = max(4, Int((Double.pi / 4 * lobesX).rounded(.up)))
      let hs = Double.pi / Double(panelsS)
      var total = 0.0
      for ps in 0..<panelsS {
        let midS = -Double.pi / 2 + (Double(ps) + 0.5) * hs
        for i in rule.nodes.indices {
          let s = midS + hs / 2 * rule.nodes[i]
          let u = sin(s)
          let a = cos(s)
          // d.y = a·sin t: lobes are narrowest in t at t = 0, where d(d.y)/dt = a.
          let panelsT = max(2, Int((Double.pi / 4 * lobesY * a).rounded(.up)))
          let ht = Double.pi / Double(panelsT)
          var ring = 0.0
          for pt in 0..<panelsT {
            let midT = -Double.pi / 2 + (Double(pt) + 0.5) * ht
            for j in rule.nodes.indices {
              let t = midT + ht / 2 * rule.nodes[j]
              ring += rule.weights[j] * f(SIMD3(u, a * sin(t), a * cos(t)))
            }
          }
          total += rule.weights[i] * a * ring * ht / 2
        }
      }
      return total * hs / 2
    }

    /// Integrates `f` over the unit sphere. Products of aperture/array factors in d.x and d.y
    /// (horn, planar and patch-element arrays) use direction cosines (`integrateFrontHemisphere`,
    /// doubled for patterns mirror-symmetric about the xy plane); the others composite
    /// Gauss–Legendre in μ = cosα about an axis suited to the pattern, trapezoid in azimuth
    /// (spectrally accurate for periodic integrands).
    private static func integrate(kind: PatternKind, parameters p: AntennaParameters, _ f: (SIMD3<Double>) -> Double) -> Double {
      if let lobes = kind.directionCosineLobes {
        let front = integrateFrontHemisphere(lobesX: lobes.x, lobesY: lobes.y, f)
        return lobes.frontOnly ? front : 2 * front
      }
      let size = kind.electricalSize
      let axis = kind.integrationAxis
      let u = perpendicular(to: axis)
      let v = simd_cross(axis, u)
      let panels = max(8, Int((size * 6).rounded(.up)))
      let azimuth = kind.isAxisymmetric ? 1 : max(48, Int((size * 12).rounded(.up)))
      let lowerMu = kind.frontOnlyAlongAxis ? 0.0 : -1.0
      let rule = RF.Numerics.GaussLegendre.order16
      let h = (1 - lowerMu) / Double(panels)
      var total = 0.0
      for panel in 0..<panels {
        let mid = lowerMu + (Double(panel) + 0.5) * h
        for i in rule.nodes.indices {
          let mu = mid + h / 2 * rule.nodes[i]
          let s = max(0, 1 - mu * mu).squareRoot()
          var ring = 0.0
          for j in 0..<azimuth {
            let b = 2 * Double.pi * (Double(j) + 0.5) / Double(azimuth)
            ring += f(mu * axis + s * (cos(b) * u + sin(b) * v))
          }
          total += rule.weights[i] * h / 2 * ring * (2 * Double.pi / Double(azimuth))
        }
      }
      return total
    }

    private static func cutStep(kind: PatternKind, parameters p: AntennaParameters) -> Double {
      min(0.25, max(0.002, 0.5 / max(kind.electricalSize, 1)))
    }
  }
}

// MARK: - Pattern kinds

nonisolated extension RF.AntennaModel {
  /// Precomputed constants of one style's pattern. `raw` returns an unnormalized |E|.
  fileprivate enum PatternKind: Sendable {
    /// |sinθ| about z (Hertzian/short dipole, small loop, PIFA chassis mode).
    case axialSine(magnetic: Bool)
    /// Thin dipole of length L: |cos(πL·cosθ) − cos(πL)|/|sinθ|; `frontOnly` for a monopole.
    case thinDipole(piL: Double, cosPiL: Double, thetaMax: Double, frontOnly: Bool)
    /// Two-slot patch: W along y, L_e along x, beam +z.
    case patch(halfKW: Double, halfKLe: Double)
    /// Hansen–Woodyard end-fire array of N λ/2 dipoles parallel to x, boom along z.
    case yagi(n: Int, kd: Double, beta: Double)
    /// cos^{q/2}θ field (power cos^qθ) with D = 2(q + 1), RHCP with the given axial ratio.
    case helix(halfQ: Double, axialRatio: Double)
    /// TE₁₀ aperture: A (H-plane) along y, B (E-plane) along x; `halfKA` = k·A/2 = π·A/λ.
    case horn(halfKA: Double, halfKB: Double)
    /// Uniform circular aperture of diameter D.
    case dish(halfKD: Double)
    case array(ArrayPattern)

    init(_ p: RF.AntennaParameters) {
      let lambda = p.wavelength
      switch p.style {
      case .shortDipole:
        self = .axialSine(magnetic: false)
      case .pifa:
        self = .axialSine(magnetic: false)
      case .smallLoop:
        self = .axialSine(magnetic: true)
      case .dipole:
        let l = RF.AntennaModel.clamp(p.dipoleLength, RF.AntennaParameters.Limits.dipoleLength)
        let d = RF.Antennas.ThinDipole(lengthWavelengths: l)
        self = .thinDipole(piL: Double.pi * l, cosPiL: cos(Double.pi * l), thetaMax: d.thetaMaxDeg * Double.pi / 180, frontOnly: false)
      case .monopole:
        let l = 2 * RF.AntennaModel.clamp(p.monopoleHeight, RF.AntennaParameters.Limits.monopoleHeight)
        let d = RF.Antennas.ThinDipole(lengthWavelengths: l)
        self = .thinDipole(piL: Double.pi * l, cosPiL: cos(Double.pi * l), thetaMax: d.thetaMaxDeg * Double.pi / 180, frontOnly: true)
      case .patch:
        let d = RF.Antennas.PatchDesign(epsilonR: p.patchEpsilonR, height: p.patchHeight, frequency: p.frequency)
        let k = 2 * Double.pi / lambda
        self = .patch(halfKW: k * d.width / 2, halfKLe: k * d.effectiveLength / 2)
      case .yagi:
        let n = min(max(p.yagiElements, 3), 20)
        let kd = 2 * Double.pi * p.yagiSpacing
        // Hansen–Woodyard: ψ = kd·cosθ + β with β = −(kd + 2.92/N) puts ψ = −2.92/N at end-fire.
        self = .yagi(n: n, kd: kd, beta: -(kd + 2.92 / Double(n)))
      case .helix:
        let h = RF.Antennas.HelixEstimates(circumference: p.helixCircumference, turns: p.helixTurns, spacing: p.helixSpacing)
        let q = max(0, h.krausDirectivity / 2 - 1)
        self = .helix(halfQ: q / 2, axialRatio: h.axialRatio)
      case .horn:
        self = .horn(halfKA: Double.pi * p.hornA, halfKB: Double.pi * p.hornB)
      case .dish:
        self = .dish(halfKD: Double.pi * p.dishDiameter)
      case .phasedArray:
        self = .array(ArrayPattern(p))
      }
    }

    /// Unnormalized field magnitude toward a unit direction.
    func raw(_ d: SIMD3<Double>) -> Double {
      switch self {
      case .axialSine:
        return (max(0, 1 - d.z * d.z)).squareRoot()
      case .thinDipole(let piL, let cosPiL, _, let frontOnly):
        if frontOnly, d.z < -1e-12 { return 0 }
        let s2 = 1 - d.z * d.z
        guard s2 > 1e-24 else { return 0 }
        return abs(cos(piL * d.z) - cosPiL) / s2.squareRoot()
      case .patch(let hw, let hl):
        return RF.AntennaModel.patchField(d, halfKW: hw, halfKLe: hl)
      case .yagi(let n, let kd, let beta):
        // Element: λ/2 dipole along x; array along z.
        let s2 = 1 - d.x * d.x
        let element = s2 > 1e-24 ? abs(cos(Double.pi / 2 * d.x)) / s2.squareRoot() : 0
        let af = abs(RF.Arrays.normalizedAF(psi: kd * d.z + beta, elements: n))
        return element * af
      case .helix(let halfQ, _):
        return d.z > 0 ? pow(d.z, halfQ) : 0
      case .horn(let ha, let hb):
        if d.z < 0 { return 0 }
        let u = ha * d.y
        let v = hb * d.x
        let x = 2 * u / Double.pi
        let hPlane = abs(1 - x * x) < 1e-9 ? Double.pi / 4 : abs(cos(u) / (1 - x * x))
        return (1 + d.z) / 2 * hPlane * abs(RF.Special.sinc(v))
      case .dish(let hd):
        if d.z < 0 { return 0 }
        let u = hd * (max(0, 1 - d.z * d.z)).squareRoot()
        let airy = u < 1e-8 ? 1 : abs(2 * RF.Special.besselJ(1, u) / u)
        return (1 + d.z) / 2 * airy
      case .array(let a):
        return a.raw(d)
      }
    }

    /// Transmit polarization (unnormalized, possibly with a radial part) toward a unit direction.
    func polarization(_ d: SIMD3<Double>) -> RF.PolarizationVector {
      let x = SIMD3<Double>(1, 0, 0)
      let y = SIMD3<Double>(0, 1, 0)
      let z = SIMD3<Double>(0, 0, 1)
      switch self {
      case .axialSine(let magnetic):
        return .linear(magnetic ? simd_cross(z, d) : z - d.z * d)
      case .thinDipole:
        return .linear(z - d.z * d)
      case .patch:
        return .linear(simd_cross(y, d))
      case .yagi, .horn, .dish:
        return .linear(x - d.x * d)
      case .helix(_, let ar):
        // RHCP about the local basis (ĥ, v̂) with v̂ the projection of x; axial ratio scales v̂.
        var v = x - d.x * d
        if simd_length(v) < 1e-9 { v = y - d.y * d }
        v = simd_normalize(v)
        let h = simd_cross(v, d)
        return RF.PolarizationVector(re: h, im: -v / ar)
      case .array(let a):
        return a.element == .patch ? .linear(simd_cross(y, d)) : .linear(x - d.x * d)
      }
    }

    func peakGuess(_ p: RF.AntennaParameters) -> SIMD3<Double> {
      switch self {
      case .axialSine:
        return SIMD3(1, 0, 0)
      case .thinDipole(_, _, let thetaMax, _):
        // Exactly horizontal at θ = 90° so cuts through the peak stay on the ground plane.
        let z = abs(cos(thetaMax)) < 1e-9 ? 0 : cos(thetaMax)
        return SIMD3(sin(thetaMax), 0, z)
      case .array(let a):
        return a.steerDirection
      default:
        return SIMD3(0, 0, 1)
      }
    }

    var needsPeakRefinement: Bool {
      if case .array(let a) = self { return a.element == .patch && a.steerDirection.z < 0.9999 }
      return false
    }

    /// Half-width (rad) of the local peak search: inside the main lobe, whose first nulls sit
    /// about 1/(N·d) away in direction cosine (64 × 2λ → 0.003 rad).
    var peakSearchSpan: Double {
      if case .array(let a) = self { return min(0.2, 0.4 / max(0.5, Double(max(a.nx, a.ny)) * a.kd / (2 * Double.pi))) }
      return 0.2
    }

    /// Lobe counts across d.x and d.y ∈ [−1, 1] for patterns that are products of aperture or
    /// array factors in the direction cosines (integrated with `integrateFrontHemisphere`), and
    /// whether the pattern is confined to z ≥ 0 (otherwise it is mirror-symmetric about z = 0).
    /// Nil for the others.
    var directionCosineLobes: (x: Double, y: Double, frontOnly: Bool)? {
      switch self {
      case .horn(let ha, let hb):
        // sinc(πB·d.x) has nulls every 1/B in d.x; the TE₁₀ H-plane factor every ~1/A in d.y.
        return (2 * hb / Double.pi + 4, 2 * ha / Double.pi + 4, true)
      case .array(let a) where !a.isAxisymmetricAboutX:
        let lobes = { (n: Int) -> Double in n > 1 ? 2 * Double(n) * a.kd / (2 * Double.pi) + 4 : 4 }
        return (lobes(a.nx), lobes(a.ny), a.element == .patch)
      default:
        return nil
      }
    }

    /// Largest aperture in wavelengths (sets integration and cut resolution).
    var electricalSize: Double {
      switch self {
      case .axialSine: return 1
      case .thinDipole(let piL, _, _, _): return max(1, piL / Double.pi)
      case .patch(let hw, let hl): return max(1, (hw + hl) / Double.pi)
      case .yagi(let n, let kd, _): return max(1, Double(n) * kd / (2 * Double.pi))
      case .helix(let halfQ, _): return max(1, (2 * halfQ).squareRoot())
      case .horn(let ha, let hb): return max(1, (ha + hb) / Double.pi)
      case .dish(let hd): return max(1, hd / Double.pi)
      case .array(let a): return a.electricalSize
      }
    }

    var isAxisymmetric: Bool {
      switch self {
      case .axialSine, .thinDipole, .helix, .dish: return true
      case .array(let a): return a.isAxisymmetricAboutX
      default: return false
      }
    }

    var integrationAxis: SIMD3<Double> {
      if case .array(let a) = self, a.isAxisymmetricAboutX { return SIMD3(1, 0, 0) }
      return SIMD3(0, 0, 1)
    }

    var frontOnlyAlongAxis: Bool {
      switch self {
      case .thinDipole(_, _, _, let front): return front
      case .patch, .helix, .horn, .dish: return true
      case .array(let a): return a.element == .patch
      default: return false
      }
    }
  }

  /// Two-slot patch field: |E| ∝ sinθ_B·|sinc(k₀W/2·cosθ_B)|·|cos(k₀L_e/2·sinθ_B sinφ_B)| in
  /// Balanis's frame, here with cosθ_B = d·ŷ and sinθ_B·sinφ_B = d·x̂; front half-space only.
  fileprivate static func patchField(_ d: SIMD3<Double>, halfKW: Double, halfKLe: Double) -> Double {
    if d.z < 0 { return 0 }
    let cy = d.y
    let sinB = (max(0, 1 - cy * cy)).squareRoot()
    return sinB * abs(RF.Special.sinc(halfKW * cy)) * abs(cos(halfKLe * d.x))
  }

  /// A planar (or linear) array of N_x × N_y elements in the xy plane.
  fileprivate struct ArrayPattern: Sendable {
    let nx: Int
    let ny: Int
    let kd: Double
    let betaX: Double
    let betaY: Double
    let element: RF.ArrayElement
    let steerDirection: SIMD3<Double>
    let patchHalfKW: Double
    let patchHalfKLe: Double

    init(_ p: RF.AntennaParameters) {
      nx = min(max(p.arrayNx, 1), 64)
      ny = min(max(p.arrayNy, 1), 64)
      kd = 2 * Double.pi * p.arraySpacing
      let ts = RF.AntennaModel.clamp(p.steerTheta, RF.AntennaParameters.Limits.steerTheta) * Double.pi / 180
      let ps = p.steerPhi * Double.pi / 180
      let dir = SIMD3(sin(ts) * cos(ps), sin(ts) * sin(ps), cos(ts))
      steerDirection = dir
      betaX = -kd * dir.x
      betaY = -kd * dir.y
      element = p.arrayElement
      // A λ/2-class patch element: ε_r 3, h = 0.02λ, designed for the carrier.
      let design = RF.Antennas.PatchDesign(epsilonR: 3, height: 0.02 * p.wavelength, frequency: p.frequency)
      let k = 2 * Double.pi / p.wavelength
      patchHalfKW = k * design.width / 2
      patchHalfKLe = k * design.effectiveLength / 2
    }

    func raw(_ d: SIMD3<Double>) -> Double {
      var f = abs(RF.Arrays.normalizedAF(psi: kd * d.x + betaX, elements: nx))
      if ny > 1 { f *= abs(RF.Arrays.normalizedAF(psi: kd * d.y + betaY, elements: ny)) }
      if element == .patch { f *= RF.AntennaModel.patchField(d, halfKW: patchHalfKW, halfKLe: patchHalfKLe) }
      return f
    }

    var electricalSize: Double { max(1, Double(max(nx, ny)) * kd / (2 * Double.pi)) }

    /// Isotropic ULA along x: the pattern depends only on the angle from x.
    var isAxisymmetricAboutX: Bool { element == .isotropic && ny == 1 }

    /// Directions of full-height lobes other than the steered beam (visible space; front
    /// half-space for a patch element).
    func gratingLobes() -> [SIMD3<Double>] {
      let twoPi = 2 * Double.pi
      func orders(_ beta: Double, _ n: Int) -> [Int] {
        guard n > 1 else { return [0] }
        let lo = Int(((-kd + beta) / twoPi).rounded(.down)) - 1
        let hi = Int(((kd + beta) / twoPi).rounded(.up)) + 1
        return Array(lo...hi)
      }
      var out: [SIMD3<Double>] = []
      for mx in orders(betaX, nx) {
        for my in orders(betaY, ny) where mx != 0 || my != 0 {
          // Direction cosines u = (2πm − β)/kd on each array axis (only constrained when N > 1).
          let u = nx > 1 ? (twoPi * Double(mx) - betaX) / kd : steerDirection.x
          let v = ny > 1 ? (twoPi * Double(my) - betaY) / kd : steerDirection.y
          if nx == 1, mx != 0 { continue }
          if ny == 1, my != 0 { continue }
          let w2 = 1 - u * u - v * v
          guard w2 >= -1e-12 else { continue }
          let w = max(0, w2).squareRoot()
          out.append(SIMD3(u, v, w))
          if element == .isotropic, w > 1e-9 { out.append(SIMD3(u, v, -w)) }
        }
      }
      return out
    }
  }
}
