import Foundation

nonisolated extension RF {
  /// The antenna styles of the Radio tab (SPEC-features §2).
  ///
  /// Local frame used by every pattern: wire antennas (short dipole, dipole, monopole, PIFA
  /// chassis mode) lie along +z; the small loop's normal is +z; directional antennas (patch,
  /// Yagi, helix, horn, dish, phased array) beam toward +z with their E-plane in the xz plane
  /// (linear polarization along x at broadside); a monopole's ground plane is the xy plane.
  enum AntennaStyle: String, CaseIterable, Codable, Hashable, Sendable, Identifiable {
    case shortDipole, dipole, monopole, smallLoop, patch, yagi, helix, horn, dish, phasedArray, pifa

    var id: String { rawValue }

    var displayName: String {
      switch self {
      case .shortDipole: "Short dipole"
      case .dipole: "Dipole"
      case .monopole: "Monopole"
      case .smallLoop: "Small loop"
      case .patch: "Patch"
      case .yagi: "Yagi"
      case .helix: "Helix"
      case .horn: "Horn"
      case .dish: "Dish"
      case .phasedArray: "Phased array"
      case .pifa: "PIFA (phone)"
      }
    }

    /// One plain sentence for the style chip's caption.
    var summary: String {
      switch self {
      case .shortDipole: "A wire much shorter than the wavelength: a doughnut pattern and a tiny radiation resistance."
      case .dipole: "A center-fed wire; at half a wavelength it is the 2.15 dBi reference antenna."
      case .monopole: "Half a dipole standing on a ground plane, which supplies the missing half as a mirror image."
      case .smallLoop: "A coil much smaller than the wavelength (NFC and Qi coils): a magnetic dipole that barely radiates."
      case .patch: "A resonant metal rectangle over a ground plane, radiating from its two open edges."
      case .yagi: "A driven dipole with a reflector behind and directors in front that pull the beam forward."
      case .helix: "A wire coiled about one wavelength per turn, radiating a circularly polarized beam along its axis."
      case .horn: "A flared waveguide whose aperture launches a clean, moderately narrow beam."
      case .dish: "A parabolic reflector: gain grows with the square of its diameter in wavelengths."
      case .phasedArray: "Many elements fed with a progressive phase, so the beam steers without moving parts."
      case .pifa: "The phone's planar inverted-F antenna; below 1 GHz the whole chassis radiates like a short dipole."
      }
    }

    /// Whether the pattern is confined to the front half-space z ≥ 0 (ground plane or aperture).
    var isFrontOnly: Bool {
      switch self {
      case .monopole, .patch, .helix, .horn, .dish: true
      default: false
      }
    }
  }

  /// Element used inside a phased array.
  enum ArrayElement: String, CaseIterable, Codable, Hashable, Sendable {
    /// An idealized point source (the reference's array-factor tests use it).
    case isotropic
    /// A λ/2 microstrip patch over ground (front half-space only), as in phone mmWave modules.
    case patch
  }

  /// Every knob of every antenna style. Lengths marked (λ) are in wavelengths of the carrier;
  /// those marked (m) are physical. Values outside a style's range are clamped by the model.
  struct AntennaParameters: Hashable, Codable, Sendable {
    var style: AntennaStyle
    /// Carrier frequency, Hz.
    var frequency: Double = 2.45e9
    /// Short dipole length l (λ), ≤ 0.1 for the triangular-current model.
    var shortDipoleLength = 0.05
    /// Dipole total length L (λ), 0.1…3.
    var dipoleLength = 0.5
    /// Monopole height H (λ) over an infinite perfect ground.
    var monopoleHeight = 0.25
    /// Small loop area (m²); the default is a 40 × 30 mm NFC coil.
    var loopArea = 1.2e-3
    /// Small loop turns N.
    var loopTurns = 4.0
    /// Effective ferrite permeability μ_eff (1 for an air coil).
    var loopMuEffective = 1.0
    /// Patch substrate ε_r (the patch is designed resonant at the carrier).
    var patchEpsilonR = 4.4
    /// Patch substrate height (m).
    var patchHeight = 1.6e-3
    /// Yagi element count N, 3…20.
    var yagiElements = 6
    /// Yagi element spacing (λ); 0.2λ reproduces the NBS TN 688 boom lengths for 3, 5, 12, 17 elements.
    var yagiSpacing = 0.2
    /// Helix turns N.
    var helixTurns = 10.0
    /// Helix circumference C (λ), axial mode for 0.75…1.33.
    var helixCircumference = 1.0
    /// Helix turn spacing S (λ).
    var helixSpacing = 0.25
    /// Horn aperture width A, H-plane (λ).
    var hornA = 3.3356
    /// Horn aperture height B, E-plane (λ).
    var hornB = 2.6685
    /// Horn aperture efficiency ε_ap (0.51 = optimum-gain horn).
    var hornEfficiency = 0.51
    /// Dish diameter D (λ).
    var dishDiameter = 24.02
    /// Dish aperture efficiency η (0.65 well designed).
    var dishEfficiency = 0.65
    /// Phased array elements along x and y (N_y = 1 is a uniform linear array).
    var arrayNx = 8
    var arrayNy = 1
    /// Element spacing d (λ), same along x and y.
    var arraySpacing = 0.5
    /// Steering angle from broadside (degrees, −90…90).
    var steerTheta = 0.0
    /// Steering azimuth in the array plane (degrees; 0 = along x).
    var steerPhi = 0.0
    var arrayElement: ArrayElement = .isotropic
    /// PIFA current path L₁ + L₂ (m); nil means resonant at the carrier (λ/4).
    var pifaCurrentPath: Double?
    /// Radiation efficiency override (0…1); nil uses the style default (1, PIFA 0.55).
    var radiationEfficiency: Double?
    /// Reference impedance for VSWR and mismatch, Ω.
    var referenceImpedance = 50.0

    init(style: AntennaStyle, frequency: Double = 2.45e9) {
      self.style = style
      self.frequency = frequency
    }

    /// Wavelength λ = c/f, m.
    var wavelength: Double { RF.Const.c / frequency }

    /// Knob ranges for the UI. `AntennaModel` clamps every knob into these (`sanitized()`).
    enum Limits {
      /// Carrier, Hz (ELF to the top of the THF band).
      static let frequency: ClosedRange<Double> = 1...3e12
      static let loopArea: ClosedRange<Double> = 1e-8...10
      static let loopMuEffective: ClosedRange<Double> = 1...10_000
      /// Patch substrate height, m (10 µm … 10 cm).
      static let patchHeight: ClosedRange<Double> = 1e-5...0.1
      static let steerPhi: ClosedRange<Double> = -360...360
      static let referenceImpedance: ClosedRange<Double> = 1...1000
      static let shortDipoleLength: ClosedRange<Double> = 0.001...0.1
      static let dipoleLength: ClosedRange<Double> = 0.1...3
      static let monopoleHeight: ClosedRange<Double> = 0.02...1.5
      static let loopTurns: ClosedRange<Double> = 1...200
      static let patchEpsilonR: ClosedRange<Double> = 1.0001...25
      static let yagiElements: ClosedRange<Int> = 3...20
      static let yagiSpacing: ClosedRange<Double> = 0.1...0.4
      static let helixTurns: ClosedRange<Double> = 1...40
      static let helixCircumference: ClosedRange<Double> = 0.75...(4.0 / 3.0)
      static let helixSpacing: ClosedRange<Double> = 0.1...0.4
      static let hornAperture: ClosedRange<Double> = 0.5...20
      static let dishDiameter: ClosedRange<Double> = 2...200
      static let arrayElements: ClosedRange<Int> = 1...64
      static let arraySpacing: ClosedRange<Double> = 0.1...2
      static let steerTheta: ClosedRange<Double> = -90...90
      static let efficiency: ClosedRange<Double> = 0.01...1
    }

    /// A copy with every knob inside its `Limits` range; NaN and ±∞ fall back to the default.
    /// The model is built from this, so a knob driven out of range (a Patch modulation, a NaN
    /// sensor sample) can neither crash it nor make it integrate for seconds.
    func sanitized() -> AntennaParameters {
      let d = AntennaParameters(style: style)
      func c(_ x: Double, _ r: ClosedRange<Double>, _ fallback: Double) -> Double {
        x.isFinite ? min(max(x, r.lowerBound), r.upperBound) : fallback
      }
      func ci(_ x: Int, _ r: ClosedRange<Int>) -> Int { min(max(x, r.lowerBound), r.upperBound) }
      var p = self
      p.frequency = c(frequency, Limits.frequency, d.frequency)
      p.shortDipoleLength = c(shortDipoleLength, Limits.shortDipoleLength, d.shortDipoleLength)
      p.dipoleLength = c(dipoleLength, Limits.dipoleLength, d.dipoleLength)
      p.monopoleHeight = c(monopoleHeight, Limits.monopoleHeight, d.monopoleHeight)
      p.loopArea = c(loopArea, Limits.loopArea, d.loopArea)
      p.loopTurns = c(loopTurns, Limits.loopTurns, d.loopTurns)
      p.loopMuEffective = c(loopMuEffective, Limits.loopMuEffective, d.loopMuEffective)
      p.patchEpsilonR = c(patchEpsilonR, Limits.patchEpsilonR, d.patchEpsilonR)
      p.patchHeight = c(patchHeight, Limits.patchHeight, d.patchHeight)
      p.yagiElements = ci(yagiElements, Limits.yagiElements)
      p.yagiSpacing = c(yagiSpacing, Limits.yagiSpacing, d.yagiSpacing)
      p.helixTurns = c(helixTurns, Limits.helixTurns, d.helixTurns)
      p.helixCircumference = c(helixCircumference, Limits.helixCircumference, d.helixCircumference)
      p.helixSpacing = c(helixSpacing, Limits.helixSpacing, d.helixSpacing)
      p.hornA = c(hornA, Limits.hornAperture, d.hornA)
      p.hornB = c(hornB, Limits.hornAperture, d.hornB)
      p.hornEfficiency = c(hornEfficiency, Limits.efficiency, d.hornEfficiency)
      p.dishDiameter = c(dishDiameter, Limits.dishDiameter, d.dishDiameter)
      p.dishEfficiency = c(dishEfficiency, Limits.efficiency, d.dishEfficiency)
      p.arrayNx = ci(arrayNx, Limits.arrayElements)
      p.arrayNy = ci(arrayNy, Limits.arrayElements)
      p.arraySpacing = c(arraySpacing, Limits.arraySpacing, d.arraySpacing)
      p.steerTheta = c(steerTheta, Limits.steerTheta, d.steerTheta)
      p.steerPhi = c(steerPhi, Limits.steerPhi, d.steerPhi)
      if let path = pifaCurrentPath { p.pifaCurrentPath = path.isFinite && path > 0 ? path : nil }
      if let e = radiationEfficiency { p.radiationEfficiency = e.isFinite ? min(max(e, Limits.efficiency.lowerBound), 1) : nil }
      p.referenceImpedance = c(referenceImpedance, Limits.referenceImpedance, d.referenceImpedance)
      return p
    }
  }
}
