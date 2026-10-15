import SwiftUI

/// Readout rows and the status line of each instrument (spectra-lab `app.js` `defaultReadouts`,
/// and each instrument's `readouts` / `status`), with a provenance badge on every number.
extension SpectrumModel {
  /// Converts a Core readout (JS-exact strings) into a row.
  static func row(_ r: SpectrumDisplay.Readout, _ provenance: [Provenance] = [.model]) -> SpectrumReadoutRow {
    SpectrumReadoutRow(key: r.key, value: r.value, sub: r.sub, color: Color(spectraHex: r.colorHex), provenance: provenance)
  }

  /// The default grid: λ, f, E photon, B₀, intensity (+ n in a medium). Values follow from the
  /// source settings (MODEL); the medium's index is a Sellmeier/Cauchy/Debye fit (MODEL).
  var defaultRows: [SpectrumReadoutRow] {
    SpectrumDisplay.readouts(state).map { Self.row($0) }
  }

  /// The rows for the instrument (and page) on screen.
  var readoutRows: [SpectrumReadoutRow] {
    switch state.instrument {
    case .scope, .tuner: return defaultRows
    case .bench: return benchRows
    case .decompose:
      switch decomposePage {
      case .polarization: return SpectrumDisplay.polarizationReadouts(state).map { Self.row($0) }
      case .probe: return SpectrumDisplay.probeReadouts(state).map { Self.row($0) }
      case .fourier: return defaultRows
      case .phase: return phaseRows
      }
    case .lab: return extras.labEarth ? earthRows : labRows
    }
  }

  /// The status line: (left, right, colour of the right side).
  var statusLine: (left: String, right: String, color: Color) {
    let d = Spectrum.describe(active.lambda)
    let ionColor: Color =
      switch d.ion {
      case .ionizing: Theme.ionizing
      case .bond: Theme.amber
      case .none: Theme.phosphor
      }
    let right = d.ion.label.uppercased()
    switch state.instrument {
    case .tuner:
      return (SpectrumDisplay.comparisonPhrase(active.lambda), right, ionColor)
    case .bench:
      let r = state.bench.focus.evaluate(active.lambda, source: active, options: SpecimenOptions(lambda0: state.bench.lambda0))
      let first = r.response.text.components(separatedBy: ". ").first ?? r.response.text
      return (first, right, ionColor)
    case .lab:
      let name: String
      if extras.labEarth {
        name = "Proton NMR \u{00B7} Earth field"
      } else {
        name = "\(state.lab.sample.name) \u{00B7} \(state.lab.mode.name)"
      }
      let progress = state.lab.sweeping ? "SWEEPING" : "\(Int((labSweep * 100).rounded()))% SCANNED"
      return (name, progress, ionColor)
    case .decompose where decomposePage == .phase:
      if phase.computing { return ("Computing \u{03A6} off the main thread", "WORKING", Theme.amber) }
      if let r = phase.scene?.report {
        let color: Color =
          switch r.status {
          case .consistent: Theme.phosphor
          case .aliased: Theme.amber
          case .smoothed: Theme.muted
          case .inconsistent: Theme.ionizing
          }
        return ("Spacetime Wigner \u{03A6}(\u{03BD}, k; x, t)", r.status.badge, color)
      }
      return ("No coherent source to draw", "\u{2014}", Theme.muted)
    default:
      let s = SpectrumDisplay.statusLine(state)
      return (s.left, s.right, ionColor)
    }
  }

  // MARK: Bench

  private var benchRows: [SpectrumReadoutRow] {
    var rows = defaultRows.prefix(3).map { $0 }
    let key = state.bench.focus
    let r = key.evaluate(active.lambda, source: active, options: SpecimenOptions(lambda0: state.bench.lambda0))
    let p = Provenance(rawValue: r.source.rawValue) ?? .model
    if let t = r.transmission {
      rows.append(
        SpectrumReadoutRow(
          key: "Transmitted", value: SpectrumPercent.text(t),
          sub: "\(key.name.lowercased()) \u{00B7} reflects \(SpectrumPercent.text(r.reflection ?? 0)) \u{00B7} absorbs \(SpectrumPercent.text(r.absorption))",
          color: Theme.text, provenance: [p]))
    } else if key == .oscillator, let a = r.response.amplitude, let lag = r.response.lag {
      rows.append(
        SpectrumReadoutRow(
          key: "Oscillator", value: JSFormat.toFixed(a, 2) + "\u{00D7}", sub: "lags " + JSFormat.jsString(JSMath.round(lag)) + "\u{00B0}",
          color: Theme.amber, provenance: [p]))
    } else if key == .antenna, let v = r.response.value {
      rows.append(
        SpectrumReadoutRow(
          key: "Antenna current", value: JSFormat.jsString(JSMath.round(v * 100)) + "%", sub: "of peak", color: Theme.amber,
          provenance: [p]))
    }
    return rows
  }

  // MARK: Lab

  private var labRows: [SpectrumReadoutRow] {
    let s = state.lab.sample
    let mode = state.lab.mode
    let x = s.axis.x(at: state.lab.sweep)
    let d = Spectrum.describe(s.toLambda(x, mode: mode))
    let p = Provenance(rawValue: s.source.rawValue) ?? .model
    var rows = [
      SpectrumReadoutRow(
        key: s.axis.label, value: SpectrumDisplay.labAxisText(s, x: x), sub: mode.name, color: Theme.phosphor, provenance: [p]),
      SpectrumReadoutRow(key: "\u{03BB}", value: d.text.lambda, sub: d.sub, color: Color(spectraHex: d.colorHex), provenance: [.model]),
      SpectrumReadoutRow(key: "f", value: d.text.f, sub: "", color: Theme.dialTheta, provenance: [.model]),
      SpectrumReadoutRow(key: "E photon", value: d.text.ev, sub: d.text.kcal, color: Theme.amber, provenance: [.model]),
    ]
    if s == .nmr {
      let b0 = Samples.nmrField(mode)
      let offset = Samples.larmor(b0: b0, ppm: x) - Samples.larmor(b0: b0, ppm: 0)
      rows.append(
        SpectrumReadoutRow(
          key: "Offset from TMS", value: JSFormat.toFixed(offset, 1) + " Hz", sub: "B\u{2080} " + JSFormat.jsString(b0) + " T",
          color: Theme.dialPhi, provenance: [.model]))
    }
    return rows
  }

  private var earthRows: [SpectrumReadoutRow] {
    let live = earthProvenance
    let f = EarthFieldAxis.frequency(at: extras.earthSweep)
    let d = Spectrum.describe(Spectrum.wavelength(frequency: f))
    var rows: [SpectrumReadoutRow] = []
    if let b = earthField {
      rows.append(
        SpectrumReadoutRow(
          key: "|B| field", value: SpectraFormat.significant(b, 4) + " \u{00B5}T", sub: "magnetometer, 0.5 s mean",
          color: Theme.fieldB, provenance: [live]))
    } else {
      rows.append(
        SpectrumReadoutRow(key: "|B| field", value: "\u{2014}", sub: "waiting for the magnetometer", color: Theme.muted, provenance: [live]))
    }
    if let fl = earthLine {
      rows.append(
        SpectrumReadoutRow(
          key: "Water line", value: JSFormat.frequency(fl), sub: "\u{03B3}\u{2032}\u{209A}\u{00B7}|B|, shielded protons",
          color: Theme.phosphor, provenance: Provenance.union([.model, live])))
      rows.append(
        SpectrumReadoutRow(
          key: "Line \u{03BB}", value: JSFormat.length(Spectrum.wavelength(frequency: fl)), sub: Spectrum.rulerSubBand(at: Spectrum.wavelength(frequency: fl)),
          color: Color(spectraHex: Spectrum.displayColorHex(Spectrum.wavelength(frequency: fl))),
          provenance: Provenance.union([.model, live])))
    }
    rows.append(
      SpectrumReadoutRow(key: "Cursor", value: d.text.f, sub: d.text.lambda, color: Theme.dialTheta, provenance: [.model]))
    rows.append(SpectrumReadoutRow(key: "E photon", value: d.text.ev, sub: d.text.kcal, color: Theme.amber, provenance: [.model]))
    return rows
  }

  // MARK: Phase space

  private var phaseRows: [SpectrumReadoutRow] {
    guard let scene = phase.scene else {
      return defaultRows.prefix(2).map { $0 }
    }
    let ref = state.referenceSource
    var rows = [
      SpectrumReadoutRow(
        key: "Unit length", value: JSFormat.length(ref.lambda), sub: "x in \u{03BB}, t in periods",
        color: Color(spectraHex: Spectrum.displayColorHex(ref.lambda)), provenance: [.model])
    ]
    if let first = phase.built?.sources.first, let carrier = scene.carriers.first ?? nil {
      let vg = scene.model.groupVelocity(carrier.y)
      rows.append(
        SpectrumReadoutRow(
          key: "Group speed \(SpectraState.sourceNames[first])", value: vg.map { JSFormat.toFixed($0, 3) + " c" } ?? "\u{2014}",
          sub: "k\u{0302}\u{2080} " + JSFormat.toFixed(carrier.x, 2) + " \u{00B7} \u{03BD}\u{0302}\u{2080} " + JSFormat.toFixed(carrier.y, 2),
          color: Theme.amber, provenance: [.model]))
    }
    let w = scene.wigner
    let ratio = w.maxValue > 0 ? w.minValue / w.maxValue : 0
    rows.append(
      SpectrumReadoutRow(
        key: "min \u{03A6} / max \u{03A6}", value: JSFormat.toFixed(ratio, 2),
        sub: ratio < -0.02
          ? "interference cross term"
          : (ratio < -1e-9 ? "\u{2248} non-negative; window ripple" : "non-negative (Hudson)"),
        color: ratio < -0.02 ? WignerScene.negative.color : WignerScene.positive.color,
        provenance: [.model]))
    rows.append(
      SpectrumReadoutRow(
        key: "Energy P", value: SpectraFormat.significant(scene.report.energy, 3), sub: "\u{03A3}|\u{03C8}|\u{00B2}\u{0394}x\u{0394}t (display units)",
        color: Theme.text, provenance: [.model]))
    return rows
  }
}
