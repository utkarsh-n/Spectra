import SwiftUI

/// Every Radio knob: its `KnobSpec` (range, detents with physical meaning, words) and the
/// binding into `RadioModel`. Ranges are the RF engine's `AntennaParameters.Limits` (or a
/// narrower, more useful window of them). Knob identifiers are `knob-radio-…`.
@MainActor
enum RadioKnobs {
  // MARK: Formatting

  nonisolated static func lambdas(_ v: Double) -> String { "\(SpectraFormat.significant(v, 3))λ" }
  nonisolated static func degrees(_ v: Double) -> String { "\(SpectraFormat.significant(v, 3))°" }
  nonisolated static func dB(_ v: Double) -> String { SpectraFormat.decibels(v, decimals: 1) }
  nonisolated static func dBm(_ v: Double) -> String { SpectraFormat.decibels(v, unit: "dBm", decimals: 1) }
  nonisolated static func dBi(_ v: Double) -> String { SpectraFormat.decibels(v, unit: "dBi", decimals: 1) }
  nonisolated static func percent(_ v: Double) -> String { "\(Int((v * 100).rounded())) %" }
  nonisolated static func count(_ v: Double) -> String { "\(Int(v.rounded()))" }
  nonisolated static func area(_ v: Double) -> String {
    v >= 1e-4 ? "\(SpectraFormat.significant(v * 1e4, 3)) cm²" : "\(SpectraFormat.significant(v * 1e6, 3)) mm²"
  }
  nonisolated static func metres(_ v: Double) -> String { SpectraFormat.wavelength(v) }

  // MARK: Carrier

  static func carrier(_ model: RadioModel) -> KnobSpec {
    KnobSpec(
      id: "radio-carrier", title: "Carrier", glyph: "f", tint: BandPalette.color(forFrequency: model.carrier),
      range: RadioModel.carrierRange, defaultValue: model.system.carrier, logarithmic: true,
      detents: [
        KnobDetent(1e6, "AM 1 MHz"), KnobDetent(13.56e6, "NFC 13.56 MHz"), KnobDetent(100e6, "FM 100 MHz"),
        KnobDetent(1575.42e6, "GPS L1"), KnobDetent(2.44e9, "Wi-Fi / BLE 2.44 GHz"), KnobDetent(3.5e9, "5G n78"),
        KnobDetent(5.5e9, "Wi-Fi 5 GHz"), KnobDetent(28e9, "5G mmWave 28 GHz"), KnobDetent(77e9, "Radar 77 GHz"),
      ],
      hint: "Carrier frequency. The antenna is designed for it and its wavelength is c / f.",
      format: { SpectraFormat.frequency($0) })
  }

  // MARK: Antenna

  /// The knobs of the current style (the carrier comes first in the Dials sheet). Lengths in
  /// wavelengths take the carrier's band colour (λ follows band colour); the steering angles keep
  /// θ's mint and φ's violet (SPEC §2's fixed dial accents); everything else (physical sizes in
  /// metres, counts, efficiencies, permittivity, gains, noise figure, delay, Doppler) takes the
  /// neutral amber, since a hue there would claim a meaning it does not have.
  static func antenna(_ style: RF.AntennaStyle, lambda: Double = SpectrumMarker.lambda(forFrequency: RadioModel.defaultCarrier)) -> [KnobSpec] {
    typealias L = RF.AntennaParameters.Limits
    let length = Theme.dialLambda(lambda)
    switch style {
    case .shortDipole:
      return [
        KnobSpec(
          id: "radio-short-length", title: "Length", glyph: "l", tint: length, range: 0.001...0.1, defaultValue: 0.05,
          logarithmic: true, detents: [KnobDetent(0.01, "λ/100"), KnobDetent(0.1, "λ/10")],
          hint: "Wire length in wavelengths. Rᵣ = 20π²(l/λ)² falls with its square.", format: lambdas)
      ]
    case .dipole:
      return [
        KnobSpec(
          id: "radio-dipole-length", title: "Length", glyph: "L", tint: length, range: L.dipoleLength, defaultValue: 0.5,
          detents: [KnobDetent(0.5, "λ/2"), KnobDetent(1, "λ"), KnobDetent(1.25, "1.25λ"), KnobDetent(1.5, "3λ/2")],
          hint: "Total length in wavelengths. Past 1.25λ the main lobe leaves broadside.", format: lambdas)
      ]
    case .monopole:
      return [
        KnobSpec(
          id: "radio-monopole-height", title: "Height", glyph: "H", tint: length, range: L.monopoleHeight, defaultValue: 0.25,
          detents: [KnobDetent(0.25, "λ/4"), KnobDetent(0.5, "λ/2"), KnobDetent(0.625, "5λ/8")],
          hint: "Height above a perfect ground plane, in wavelengths.", format: lambdas)
      ]
    case .smallLoop:
      return [
        KnobSpec(
          id: "radio-loop-area", title: "Area", glyph: "A", tint: Theme.amber, range: 1e-6...0.1, defaultValue: 1.2e-3,
          logarithmic: true, detents: [KnobDetent(1.2e-3, "NFC coil 40 × 30 mm"), KnobDetent(1.45e-3, "Qi coil Ø 43 mm")],
          hint: "Coil area. Radiation resistance grows with the area squared.", format: area),
        KnobSpec(
          id: "radio-loop-turns", title: "Turns", glyph: "N", tint: Theme.amber, range: 1...50, defaultValue: 4, step: 1,
          hint: "Number of turns: Rᵣ grows with N².", format: count),
        KnobSpec(
          id: "radio-loop-mu", title: "Core", glyph: "μ", tint: Theme.dialAmber, range: L.loopMuEffective.lowerBound...1000,
          defaultValue: 1, logarithmic: true, detents: [KnobDetent(1, "Air"), KnobDetent(50, "Ferrite sheet")],
          hint: "Effective permeability of a ferrite core (1 for air).", format: { SpectraFormat.significant($0, 3) }),
      ]
    case .patch:
      return [
        KnobSpec(
          id: "radio-patch-er", title: "Substrate", glyph: "εᵣ", tint: Theme.dialAmber, range: 1.0001...12, defaultValue: 4.4,
          detents: [KnobDetent(2.2, "PTFE 2.2"), KnobDetent(3.0, "Rogers 3.0"), KnobDetent(4.4, "FR-4 4.4"), KnobDetent(10.2, "Ceramic 10.2")],
          hint: "Relative permittivity of the substrate; the patch is redesigned resonant at the carrier.",
          format: { SpectraFormat.significant($0, 3) }),
        KnobSpec(
          id: "radio-patch-h", title: "Height", glyph: "h", tint: Theme.amber, range: 1e-4...5e-3, defaultValue: 1.6e-3,
          logarithmic: true, detents: [KnobDetent(0.8e-3, "0.8 mm"), KnobDetent(1.6e-3, "1.6 mm board")],
          hint: "Substrate thickness.", format: metres),
      ]
    case .yagi:
      return [
        KnobSpec(
          id: "radio-yagi-n", title: "Elements", glyph: "N", tint: Theme.amber,
          range: Double(L.yagiElements.lowerBound)...Double(L.yagiElements.upperBound), defaultValue: 6, step: 1,
          hint: "Reflector, driven element and directors. Gain follows the boom length (NBS TN 688).", format: count),
        KnobSpec(
          id: "radio-yagi-spacing", title: "Spacing", glyph: "s", tint: length, range: L.yagiSpacing, defaultValue: 0.2,
          detents: [KnobDetent(0.2, "0.2λ (NBS)")], hint: "Element spacing in wavelengths.", format: lambdas),
      ]
    case .helix:
      return [
        KnobSpec(
          id: "radio-helix-n", title: "Turns", glyph: "N", tint: Theme.amber, range: L.helixTurns, defaultValue: 10, step: 1,
          hint: "Number of turns: Kraus D = 12C²NS grows with the axial length.", format: count),
        KnobSpec(
          id: "radio-helix-c", title: "Circumf.", glyph: "C", tint: length, range: L.helixCircumference, defaultValue: 1,
          detents: [KnobDetent(1, "C = λ")], hint: "Turn circumference in wavelengths; axial mode for 0.75–1.33λ.",
          format: lambdas),
        KnobSpec(
          id: "radio-helix-s", title: "Pitch", glyph: "S", tint: length, range: L.helixSpacing, defaultValue: 0.25,
          detents: [KnobDetent(0.25, "λ/4")], hint: "Spacing between turns in wavelengths.", format: lambdas),
      ]
    case .horn:
      return [
        KnobSpec(
          id: "radio-horn-a", title: "Width A", glyph: "A", tint: length, range: L.hornAperture, defaultValue: 3.3356,
          logarithmic: true, hint: "Aperture width (H-plane) in wavelengths.", format: lambdas),
        KnobSpec(
          id: "radio-horn-b", title: "Height B", glyph: "B", tint: length, range: L.hornAperture, defaultValue: 2.6685,
          logarithmic: true, hint: "Aperture height (E-plane) in wavelengths.", format: lambdas),
        KnobSpec(
          id: "radio-horn-eff", title: "Efficiency", glyph: "ε", tint: Theme.dialAmber, range: 0.2...1, defaultValue: 0.51,
          detents: [KnobDetent(0.51, "Optimum horn")], hint: "Aperture efficiency εₐₚ (0.51 for the optimum-gain horn).",
          format: percent),
      ]
    case .dish:
      return [
        KnobSpec(
          id: "radio-dish-d", title: "Diameter", glyph: "D", tint: length, range: L.dishDiameter, defaultValue: 24.02,
          logarithmic: true, detents: [KnobDetent(10, "10λ"), KnobDetent(100, "100λ")],
          hint: "Dish diameter in wavelengths: gain grows as (πD/λ)².", format: lambdas),
        KnobSpec(
          id: "radio-dish-eff", title: "Efficiency", glyph: "η", tint: Theme.dialAmber, range: 0.2...1, defaultValue: 0.65,
          detents: [KnobDetent(0.55, "Typical"), KnobDetent(0.65, "Well designed")], hint: "Aperture efficiency η.",
          format: percent),
      ]
    case .phasedArray:
      return [
        KnobSpec(
          id: "radio-array-nx", title: "Along x", glyph: "N", tint: Theme.amber, range: 1...32, defaultValue: 8, step: 1,
          hint: "Elements along x.", format: count),
        KnobSpec(
          id: "radio-array-ny", title: "Along y", glyph: "N", tint: Theme.amber, range: 1...32, defaultValue: 1, step: 1,
          hint: "Elements along y (1 = a line).", format: count),
        KnobSpec(
          id: "radio-array-d", title: "Spacing", glyph: "d", tint: length, range: L.arraySpacing, defaultValue: 0.5,
          detents: [KnobDetent(0.5, "λ/2"), KnobDetent(1, "λ")],
          hint: "Element spacing. Past the grating-free limit extra beams (grating lobes) appear.", format: lambdas),
        KnobSpec(
          id: "radio-array-steer", title: "Steer", glyph: "θ₀", tint: Theme.dialTheta, range: L.steerTheta, defaultValue: 0,
          origin: 0, detents: [KnobDetent(0, "Broadside"), KnobDetent(30, "30°"), KnobDetent(60, "60°")],
          hint: "Beam angle from broadside, set by a progressive phase across the elements.", format: degrees),
        KnobSpec(
          id: "radio-array-phi", title: "Azimuth", glyph: "φ₀", tint: Theme.dialPhi, range: -180...180, defaultValue: 0,
          origin: 0, detents: [KnobDetent(0, "Along x"), KnobDetent(90, "Along y")],
          hint: "Steering azimuth in the array plane.", format: degrees),
      ]
    case .pifa:
      return [
        KnobSpec(
          id: "radio-pifa-path", title: "Path", glyph: "L", tint: length, range: 0.05...1, defaultValue: 0.25,
          detents: [KnobDetent(0.25, "λ/4 resonant")],
          hint: "Top-plate current path in wavelengths; the PIFA resonates near λ/4.", format: lambdas),
        KnobSpec(
          id: "radio-pifa-eff", title: "Efficiency", glyph: "η", tint: Theme.dialAmber, range: 0.2...1, defaultValue: 0.55,
          detents: [KnobDetent(0.4, "In the hand"), KnobDetent(0.55, "Typical"), KnobDetent(0.7, "Best")],
          hint: "Radiation efficiency: phones manage 40–70 %, worst below 1 GHz and in the hand.", format: percent),
      ]
    }
  }

  /// The binding of an antenna knob into `model.antenna`.
  static func antennaBinding(_ spec: KnobSpec, _ model: RadioModel) -> Binding<Double> {
    let id = spec.id
    return Binding(
      get: {
        let p = model.antenna
        switch id {
        case "radio-carrier": return model.carrier
        case "radio-short-length": return p.shortDipoleLength
        case "radio-dipole-length": return p.dipoleLength
        case "radio-monopole-height": return p.monopoleHeight
        case "radio-loop-area": return p.loopArea
        case "radio-loop-turns": return p.loopTurns
        case "radio-loop-mu": return p.loopMuEffective
        case "radio-patch-er": return p.patchEpsilonR
        case "radio-patch-h": return p.patchHeight
        case "radio-yagi-n": return Double(p.yagiElements)
        case "radio-yagi-spacing": return p.yagiSpacing
        case "radio-helix-n": return p.helixTurns
        case "radio-helix-c": return p.helixCircumference
        case "radio-helix-s": return p.helixSpacing
        case "radio-horn-a": return p.hornA
        case "radio-horn-b": return p.hornB
        case "radio-horn-eff": return p.hornEfficiency
        case "radio-dish-d": return p.dishDiameter
        case "radio-dish-eff": return p.dishEfficiency
        case "radio-array-nx": return Double(p.arrayNx)
        case "radio-array-ny": return Double(p.arrayNy)
        case "radio-array-d": return p.arraySpacing
        case "radio-array-steer": return p.steerTheta
        case "radio-array-phi": return RadioModel.wrap(p.steerPhi)
        case "radio-pifa-path": return (p.pifaCurrentPath ?? p.wavelength / 4) / p.wavelength
        case "radio-pifa-eff": return p.radiationEfficiency ?? 0.55
        default: return spec.defaultValue
        }
      },
      set: { v in
        guard v.isFinite else { return }
        if id == "radio-carrier" {
          model.carrier = v
          return
        }
        var p = model.antenna
        switch id {
        case "radio-short-length": p.shortDipoleLength = v
        case "radio-dipole-length": p.dipoleLength = v
        case "radio-monopole-height": p.monopoleHeight = v
        case "radio-loop-area": p.loopArea = v
        case "radio-loop-turns": p.loopTurns = v.rounded()
        case "radio-loop-mu": p.loopMuEffective = v
        case "radio-patch-er": p.patchEpsilonR = v
        case "radio-patch-h": p.patchHeight = v
        case "radio-yagi-n": p.yagiElements = Int(v.rounded())
        case "radio-yagi-spacing": p.yagiSpacing = v
        case "radio-helix-n": p.helixTurns = v.rounded()
        case "radio-helix-c": p.helixCircumference = v
        case "radio-helix-s": p.helixSpacing = v
        case "radio-horn-a": p.hornA = v
        case "radio-horn-b": p.hornB = v
        case "radio-horn-eff": p.hornEfficiency = v
        case "radio-dish-d": p.dishDiameter = v
        case "radio-dish-eff": p.dishEfficiency = v
        case "radio-array-nx": p.arrayNx = Int(v.rounded())
        case "radio-array-ny": p.arrayNy = Int(v.rounded())
        case "radio-array-d": p.arraySpacing = v
        case "radio-array-steer": p.steerTheta = v
        case "radio-array-phi": p.steerPhi = v
        case "radio-pifa-path": p.pifaCurrentPath = v * p.wavelength
        case "radio-pifa-eff": p.radiationEfficiency = v
        default: return
        }
        model.antenna = p
      })
  }

  /// Fresnel distance of the aperture view, as a fraction of the far-field distance.
  static let fresnel = KnobSpec(
    id: "radio-fresnel", title: "Distance", glyph: "z", tint: Theme.dialAmber, range: RadioModel.fresnelRange, defaultValue: 0,
    detents: [KnobDetent(0, "At the aperture"), KnobDetent(0.25, "¼ of 2D²/λ"), KnobDetent(1, "Far field 2D²/λ")],
    hint: "Distance from the aperture as a fraction of 2D²/λ: the Wigner shears as the beam diffracts.",
    format: { "\(SpectraFormat.significant($0, 2)) × 2D²/λ" })

  // MARK: Fourier

  static func snr(analog: Bool) -> KnobSpec {
    KnobSpec(
      id: "radio-snr", title: analog ? "CNR" : "Es/N0", glyph: "γ", tint: Theme.dialAmber, range: -5...50, defaultValue: 30,
      detents: [KnobDetent(0, "0 dB"), KnobDetent(10, "10 dB"), KnobDetent(20, "20 dB"), KnobDetent(30, "30 dB")],
      hint: analog
        ? "Carrier-to-noise ratio in the channel bandwidth (Carson for FM, 2 × 5 kHz for AM)."
        : "Energy per data symbol over noise density, so the BER compares directly with theory.",
      format: dB)
  }

  /// Lowest knob position means "off" for the log delay-spread and Doppler knobs.
  static let delayFloor = 1e-9
  static let dopplerFloor = 0.1

  static let delaySpread = KnobSpec(
    id: "radio-delay-spread", title: "Delay", glyph: "τ", tint: Theme.dialAmber, range: delayFloor...5e-6,
    defaultValue: delayFloor, logarithmic: true,
    detents: [KnobDetent(delayFloor, "None"), KnobDetent(40e-9, "Office 40 ns"), KnobDetent(300e-9, "Urban 300 ns"), KnobDetent(1e-6, "Hilly 1 µs")],
    hint: "RMS delay spread of an exponential multipath profile. Echoes longer than a symbol smear it (ISI).",
    format: { $0 <= delayFloor * 1.0001 ? "None" : SpectraFormat.si($0, unit: "s") })

  static func doppler(carrier: Double) -> KnobSpec {
    let walk = RF.Fading.maxDoppler(speed: 1.4, frequency: carrier)
    let car = RF.Fading.maxDoppler(speed: 30, frequency: carrier)
    let train = RF.Fading.maxDoppler(speed: 100, frequency: carrier)
    let detents = [KnobDetent(dopplerFloor, "None"), KnobDetent(walk, "Walking 1.4 m/s"), KnobDetent(car, "Car 30 m/s"),
                   KnobDetent(train, "Train 100 m/s")].filter { (dopplerFloor...2000).contains($0.value) }
    return KnobSpec(
      id: "radio-doppler", title: "Doppler", glyph: "fᴅ", tint: Theme.dialAmber, range: dopplerFloor...2000, defaultValue: dopplerFloor,
      logarithmic: true, detents: detents,
      hint: "Maximum Doppler shift v·f/c of the fading taps, f the carrier (Clarke/Jakes spectrum).",
      format: { $0 <= dopplerFloor * 1.0001 ? "None" : SpectraFormat.frequency($0) })
  }

  static let ricianK = KnobSpec(
    id: "radio-rician-k", title: "Rician", glyph: "K", tint: Theme.amber, range: -10...20, defaultValue: 6,
    detents: [KnobDetent(0, "0 dB"), KnobDetent(6, "6 dB"), KnobDetent(10, "10 dB")],
    hint: "Line-of-sight power over scattered power. Large K approaches a clean channel; K → −∞ dB is Rayleigh.",
    format: dB)

  static func fourierBinding(_ spec: KnobSpec, _ model: RadioModel) -> Binding<Double> {
    let id = spec.id
    return Binding(
      get: {
        let f = model.fourier
        switch id {
        case "radio-snr": return f.snrDB
        case "radio-delay-spread": return max(f.delaySpread, delayFloor)
        case "radio-doppler": return max(f.dopplerHz, dopplerFloor)
        case "radio-rician-k": return f.ricianKdB
        default: return spec.defaultValue
        }
      },
      set: { v in
        guard v.isFinite else { return }
        var f = model.fourier
        switch id {
        case "radio-snr": f.snrDB = v
        case "radio-delay-spread": f.delaySpread = v <= delayFloor * 1.0001 ? 0 : v
        case "radio-doppler": f.dopplerHz = v <= dopplerFloor * 1.0001 ? 0 : v
        case "radio-rician-k": f.ricianKdB = v
        default: return
        }
        model.fourier = f
      })
  }

  // MARK: Link

  static let txPower = KnobSpec(
    id: "radio-tx-power", title: "Tx power", glyph: "Pₜ", tint: Theme.amber, range: -30...60, defaultValue: 20,
    detents: [KnobDetent(0, "BLE 0 dBm"), KnobDetent(20, "Wi-Fi 20 dBm"), KnobDetent(23, "Phone 23 dBm"), KnobDetent(46, "Macro cell 46 dBm")],
    hint: "Transmitter output power into the antenna.", format: dBm)

  static let txGain = KnobSpec(
    id: "radio-tx-gain", title: "Tx gain", glyph: "Gₜ", tint: Theme.dialAmber, range: -10...60, defaultValue: 0,
    detents: [KnobDetent(0, "Isotropic"), KnobDetent(2.15, "λ/2 dipole")], hint: "Transmit antenna gain.", format: dBi)

  static let rxGain = KnobSpec(
    id: "radio-rx-gain", title: "Rx gain", glyph: "Gᵣ", tint: Theme.dialAmber, range: -10...60, defaultValue: 0,
    detents: [KnobDetent(0, "Isotropic"), KnobDetent(2.15, "λ/2 dipole")], hint: "Receive antenna gain.", format: dBi)

  static let distance = KnobSpec(
    id: "radio-distance", title: "Distance", glyph: "d", tint: Theme.amber, range: 0.01...4e7, defaultValue: 10,
    logarithmic: true,
    detents: [
      KnobDetent(1, "1 m"), KnobDetent(5, "Room 5 m"), KnobDetent(20, "House 20 m"), KnobDetent(1000, "1 km"),
      KnobDetent(2000, "Cell edge 2 km"), KnobDetent(20_200_000, "GPS orbit 20,200 km"),
    ],
    hint: "Path length from transmitter to receiver.", format: { RF.Units.format(distance: $0) })

  static let exponent = KnobSpec(
    id: "radio-exponent", title: "Exponent", glyph: "n", tint: Theme.dialAmber, range: 1.6...6, defaultValue: 3,
    detents: [KnobDetent(1.8, "Corridor"), KnobDetent(2, "Free space"), KnobDetent(3, "Office"), KnobDetent(3.5, "Urban")],
    hint: "Path-loss exponent n: loss grows 10·n dB per decade of distance beyond 1 m.",
    format: { SpectraFormat.significant($0, 3) })

  static let rain = KnobSpec(
    id: "radio-rain", title: "Rain", glyph: "R", tint: Theme.dialAmber, range: 0...150, defaultValue: 0,
    detents: [KnobDetent(0, "Dry")] + RF.Atmosphere.rainPresets.map { KnobDetent($0.rate, "\($0.name) \(Int($0.rate)) mm/h") },
    hint: "Rain rate (ITU-R P.838). It matters above about 10 GHz.", format: { "\(SpectraFormat.significant($0, 3)) mm/h" })

  static let noiseFigure = KnobSpec(
    id: "radio-nf", title: "Noise fig.", glyph: "F", tint: Theme.dialAmber, range: 0...20, defaultValue: 7,
    detents: [KnobDetent(1, "LNA 1 dB"), KnobDetent(7, "Phone 7 dB")],
    hint: "Receiver noise figure: the floor is −174 dBm/Hz + 10·log B + NF.", format: dB)

  static func bandwidth(_ model: RadioModel) -> KnobSpec {
    let widths = model.system.channelWidths.filter { $0 > 0 }
    return KnobSpec(
      id: "radio-bandwidth", title: "Bandwidth", glyph: "B", tint: Theme.amber, range: 1e3...2e9,
      defaultValue: max(model.systemNoiseBandwidth, 1e3), logarithmic: true,
      detents: widths.map { KnobDetent($0, "\(model.system.generation) \(SpectraFormat.frequency($0))") },
      hint: "Receiver noise bandwidth; the system's widest channel by default.",
      format: { v in
        // A CW system (Qi) uses no bandwidth until the knob is turned; the knob bottoms out at 1 kHz.
        model.link.bandwidth == nil && model.linkBandwidth <= 0 ? "CW (0 Hz)" : SpectraFormat.frequency(v)
      })
  }

  static let bleTxPower = KnobSpec(
    id: "radio-ble-tx", title: "Tx power", glyph: "Pₜ", tint: Theme.amber, range: -20...10, defaultValue: 0,
    detents: [KnobDetent(0, "0 dBm (typical)")], hint: "The device's transmit power (many advertise it).", format: dBm)

  static let bleExponent = KnobSpec(
    id: "radio-ble-exponent", title: "Exponent", glyph: "n", tint: Theme.dialAmber, range: 1.5...5, defaultValue: 2,
    detents: [KnobDetent(2, "Free space"), KnobDetent(3, "Indoors")],
    hint: "Path-loss exponent used to turn RSSI into distance.", format: { SpectraFormat.significant($0, 3) })

  static func linkBinding(_ spec: KnobSpec, _ model: RadioModel) -> Binding<Double> {
    let id = spec.id
    return Binding(
      get: {
        let l = model.link
        switch id {
        case "radio-tx-power": return l.txPowerDBm
        case "radio-tx-gain": return l.useAntennaGain ? model.linkTxGainDBi : l.txGainDBi
        case "radio-rx-gain": return l.rxGainDBi
        case "radio-distance": return l.distance
        case "radio-exponent": return l.exponent
        case "radio-rain": return l.rainRate
        case "radio-nf": return l.noiseFigureDB
        case "radio-bandwidth": return max(model.linkBandwidth, 1e3)
        case "radio-ble-tx": return l.bleTxPowerDBm
        case "radio-ble-exponent": return l.bleExponent
        default: return spec.defaultValue
        }
      },
      set: { v in
        guard v.isFinite else { return }
        var l = model.link
        switch id {
        case "radio-tx-power": l.txPowerDBm = v
        case "radio-tx-gain":
          l.useAntennaGain = false
          l.txGainDBi = v
        case "radio-rx-gain": l.rxGainDBi = v
        case "radio-distance": l.distance = v
        case "radio-exponent": l.exponent = v
        case "radio-rain": l.rainRate = v
        case "radio-nf": l.noiseFigureDB = v
        case "radio-bandwidth": l.bandwidth = v
        case "radio-ble-tx": l.bleTxPowerDBm = v
        case "radio-ble-exponent": l.bleExponent = v
        default: return
        }
        model.link = l
      })
  }
}
