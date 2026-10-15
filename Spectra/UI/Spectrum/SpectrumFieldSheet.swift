import SwiftUI

/// The field-controls dials (spectra-lab `ui/controls.js`): λ (log, the native long ruler),
/// T, E₀ (log), θ, δ, φ, N. Accents follow the parameter-identity rule.
@MainActor
enum SpectrumKnobs {
  /// Band edges, green, and the long-wave landmarks (Earth-field NMR, mains, Schumann).
  static let lambdaDetents: [KnobDetent] =
    [
      KnobDetent(1e-11, "\u{03B3} | X-ray"), KnobDetent(1e-8, "X-ray | UV"), KnobDetent(400e-9, "Violet edge"),
      KnobDetent(550e-9, "Green"), KnobDetent(700e-9, "Red edge"), KnobDetent(1e-3, "IR | \u{00B5}W"),
      KnobDetent(1, "\u{00B5}W | radio"), KnobDetent(1e3, "1 km (web edge)"),
    ] + Spectrum.longWaveLandmarks.map { KnobDetent($0.lambda, $0.label) }

  static func lambdaText(_ v: Double) -> String {
    let d = Spectrum.describe(v)
    return "\(d.text.lambda) \u{00B7} \(d.text.f)"
  }

  static func lambda(_ current: Double) -> KnobSpec {
    KnobSpec(
      id: "spectrum-lambda", title: "Wavelength", glyph: "\u{03BB}", tint: Theme.dialLambda(current),
      range: pow(10, Spectrum.rulerLogMin)...pow(10, Spectrum.rulerLogMax), defaultValue: 550e-9, logarithmic: true,
      detents: lambdaDetents, hint: "Sets color, energy and what matter answers.",
      detail: "Vacuum wavelength, log scale from 0.1 pm to 100,000 km.", format: lambdaText)
  }

  static let temperature = KnobSpec(
    id: "spectrum-temperature", title: "Temperature", glyph: "T", tint: Theme.dialAmber, range: 1...1e7,
    defaultValue: 5772, logarithmic: true,
    detents: [
      KnobDetent(2.725, "Cosmic background"), KnobDetent(310, "Your body"), KnobDetent(2700, "Warm bulb"),
      KnobDetent(5772, "The Sun"),
    ],
    hint: "How hot the glowing body is.",
    format: { v in
      let t = v >= 1e4 ? JSFormat.sci(v) : JSFormat.toPrecision(v, 4)
      return "\(t) K \u{00B7} peak \(Spectrum.describe(Wave.wienPeak(v)).text.lambda)"
    })

  static let e0 = KnobSpec(
    id: "spectrum-e0", title: "Field", glyph: "E\u{2080}", tint: Theme.dialE0, range: 1e-3...1e13, defaultValue: 1000,
    logarithmic: true,
    detents: [
      KnobDetent(1000, "About sunlight"), KnobDetent(3e6, "Air breaks down"),
      KnobDetent(Wave.fieldForA0(1, lambda: 800e-9), "a\u{2080} = 1 at 800 nm"),
    ],
    hint: "Peak electric field. B\u{2080} = E\u{2080} / c.",
    // Short enough for the three-column grid; B₀ = E₀/c is the readouts' B₀ field.
    detail: "B\u{2080} = E\u{2080} / c in vacuum (n E\u{2080} / c in a medium); see the B\u{2080} readout.",
    format: { v in JSFormat.sci(v, unit: "V/m") })

  static let theta = KnobSpec(
    id: "spectrum-theta", title: "Polarization", glyph: "\u{03B8}", tint: Theme.dialTheta, range: -90...90, defaultValue: 90,
    origin: 0,
    detents: [KnobDetent(-45, "\u{2212}45\u{00B0}"), KnobDetent(0, "Ex only"), KnobDetent(45, "45\u{00B0}"), KnobDetent(90, "Ey only")],
    hint: "Tilts the E plane around the beam.", format: { "\(Int($0.rounded()))\u{00B0}" })

  static let delta = KnobSpec(
    id: "spectrum-delta", title: "Ellipticity", glyph: "\u{03B4}", tint: Theme.dialDelta, range: -180...180, defaultValue: 0,
    origin: 0,
    detents: [KnobDetent(-90, "Circular \u{2212}90\u{00B0}"), KnobDetent(0, "Linear"), KnobDetent(90, "Circular +90\u{00B0}")],
    hint: "Delay of Ey behind Ex.", format: { "\(Int($0.rounded()))\u{00B0}" })

  static let phi = KnobSpec(
    id: "spectrum-phi", title: "Phase", glyph: "\u{03C6}", tint: Theme.dialPhi, range: 0...360, defaultValue: 0,
    detents: [KnobDetent(90, "\u{00BC} cycle"), KnobDetent(180, "\u{00BD} cycle"), KnobDetent(270, "\u{00BE} cycle")],
    hint: "Shifts the wave along its path.",
    format: { "\(Int($0.rounded()))\u{00B0} \u{00B7} \(JSFormat.toFixed($0 / 360, 2)) \u{03BB}" })

  static let cycles = KnobSpec(
    id: "spectrum-cycles", title: "Pulse length", glyph: "N", tint: Theme.dialAmber, range: 1...12, defaultValue: 3,
    step: 0.5, detents: [KnobDetent(1, "Single cycle"), KnobDetent(3, "3 cycles")],
    hint: "Carrier cycles in the burst.", format: { "\(JSFormat.toFixed($0, 1)) cycles" })
}

/// One group of the sheet: a numbered phosphor panel.
private struct SheetGroup<Content: View>: View {
  let number: String
  let title: String
  @ViewBuilder var content: Content

  var body: some View {
    InstrumentPanel(title, number: number) {
      VStack(alignment: .leading, spacing: 14) { content }
    }
  }
}

/// Field controls (the Spectrum tab's Dials sheet): field trips, sources A/B/C with Link and
/// on/off, the source kind, the dials, medium and κ, display toggles and feedback, with Reset
/// dials / Reset alignment pinned at the bottom.
struct SpectrumFieldSheet: View {
  @Environment(AppModel.self) private var app
  @Environment(\.dismiss) private var dismiss
  @State private var tripsOpen = false

  var body: some View {
    let model = app.spectrum
    ControlSheet(
      title: "Field controls", resetDials: model.resetDials, resetAlignment: model.resetAlignment,
      resetDialsHint: "The active source (every source with Link on) back to its default.",
      resetAlignmentHint: "Scope camera, tuner window and the \u{03A6} cube back to their framing."
    ) {
      sourceGroup(model)
      mediumGroup(model)
      displayGroup(model)
      feedbackGroup
    }
    #if DEBUG
      .onChange(of: SpectrumSnapshotDriver.shared.tripsOpen, initial: true) { _, open in
        if SpectrumSnapshots.requested { tripsOpen = open }
      }
    #endif
  }

  // MARK: 01 Field source

  @ViewBuilder private func sourceGroup(_ model: SpectrumModel) -> some View {
    let src = model.active
    SheetGroup(number: "01", title: "Field source") {
      trips(model)
      SheetCaption("Field trips set every source and restart the clock.")
      HStack(spacing: 12) {
        GlassSegmented(
          items: [0, 1, 2].map { Choice(value: $0, key: SpectraState.sourceNames[$0]) },
          selected: Choice(value: model.state.active, key: SpectraState.sourceNames[min(2, max(0, model.state.active))]),
          id: "spectrum-source", tint: { Theme.sources[$0.value] }, dimmed: { !model.state.sources[$0.value].enabled },
          title: { $0.key }, accessibilityTitle: { c in "Source \(c.key)\(model.state.sources[c.value].enabled ? "" : ", off")" }
        ) { model.selectSource($0.value) }
        Toggle(
          isOn: Binding(
            get: { model.state.link },
            set: { on in
              Haptics.shared.selection()
              model.state.link = on
            })
        ) {
          Label("Link", systemImage: "link").font(.subheadline)
        }
        .toggleStyle(.switch)
        .tint(Theme.phosphor)
        .fixedSize()
        .accessibilityLabel("Link sources")
        .accessibilityHint("Edits apply the same relative change to every source that is on.")
        .accessibilityIdentifier("spectrum-link")
      }
      editingLine(model, src)
      GlassToggle(
        "Source \(SpectraState.sourceNames[min(2, max(0, model.state.active))]) on",
        isOn: Binding(get: { src.enabled }, set: { model.setActiveEnabled($0) }), symbol: "power",
        subtitle: "One source always stays on."
      )
      .accessibilityIdentifier("spectrum-source-enabled")
      GlassSegmented(
        items: WaveSource.Kind.allCases, selected: src.kind, id: "spectrum-kind",
        tint: { _ in BandPalette.color(forWavelength: src.lambda) }, title: { $0.name }
      ) { model.setKind($0) }
      Text(kindNote(src)).panelCaption()
      KnobGrid(specs: knobs(src), value: { binding(for: $0, model) }, columns: 3, showsSliders: true)
    }
  }

  private func trips(_ model: SpectrumModel) -> some View {
    let current = model.state.preset.flatMap(SpectraPreset.named)
    return VStack(alignment: .leading, spacing: 8) {
      Button {
        Haptics.shared.tap()
        tripsOpen.toggle()
      } label: {
        HStack(spacing: 12) {
          Image(systemName: "map").font(.title3).foregroundStyle(Theme.phosphor)
          VStack(alignment: .leading, spacing: 2) {
            Text("Field trips").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.text)
            Text(current.map { "\($0.name) \u{00B7} \($0.detail)" } ?? "Choose a real-world setup")
              .font(.caption).foregroundStyle(Theme.muted).lineLimit(2)
          }
          Spacer(minLength: 0)
          Image(systemName: tripsOpen ? "chevron.up" : "chevron.down").foregroundStyle(Theme.muted)
        }
        .padding(12)
        .contentShape(.rect)
      }
      .buttonStyle(.plain)
      .glassEffect(.regular.interactive(), in: .rect(cornerRadius: Theme.chipRadius))
      .accessibilityLabel("Field trips")
      .accessibilityValue(current?.name ?? "none")
      .accessibilityHint(tripsOpen ? "Hides the list." : "Shows fourteen real-world setups.")
      .accessibilityIdentifier("spectrum-trips")
      if tripsOpen {
        VStack(spacing: 6) {
          ForEach(SpectraPreset.all) { p in
            Button {
              tripsOpen = false
              model.apply(preset: p)
              dismiss()
            } label: {
              VStack(alignment: .leading, spacing: 2) {
                Text(p.name).font(.subheadline.weight(.medium)).foregroundStyle(Theme.text)
                Text(p.detail).font(.caption).foregroundStyle(Theme.muted).multilineTextAlignment(.leading)
              }
              .frame(maxWidth: .infinity, alignment: .leading)
              .padding(.horizontal, 12)
              .padding(.vertical, 8)
              .background(
                p.key == model.state.preset ? Theme.phosphor.opacity(0.12) : Color.white.opacity(0.03),
                in: .rect(cornerRadius: 12))
              .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("spectrum-trip-\(p.key)")
          }
        }
      }
    }
  }

  private func editingLine(_ model: SpectrumModel, _ src: WaveSource) -> some View {
    let d = Spectrum.describe(src.lambda)
    let i = min(2, max(0, model.state.active))
    return HStack(spacing: 8) {
      Circle().fill(Theme.sources[i]).frame(width: 7, height: 7)
      Text(
        "Editing \(SpectraState.sourceNames[i]) \u{00B7} \(d.text.lambda) \u{00B7} \(d.band.name.lowercased())\(model.state.link ? " \u{00B7} linked" : "")"
      )
      .font(.system(.caption, design: .monospaced))
      .foregroundStyle(Theme.muted)
    }
    .accessibilityElement(children: .combine)
  }

  private func kindNote(_ src: WaveSource) -> String {
    var extra = ""
    switch src.kind {
    case .pulse: extra = " Bandwidth \u{0394}f/f \u{2248} \(JSFormat.toFixed(Wave.pulseBandwidth(src) * 100, 0))%."
    case .thermal: extra = " Peak at \(Spectrum.describe(Wave.wienPeak(src.temperature)).text.lambda) (Wien)."
    case .plane: break
    }
    return "\(src.kind.name) \u{00B7} \(src.kind.note)\(extra)"
  }

  private func knobs(_ src: WaveSource) -> [KnobSpec] {
    var list: [KnobSpec] = []
    if src.kind == .thermal { list.append(SpectrumKnobs.temperature) } else { list.append(SpectrumKnobs.lambda(src.lambda)) }
    list.append(SpectrumKnobs.e0)
    list += [SpectrumKnobs.theta, SpectrumKnobs.delta, SpectrumKnobs.phi]
    if src.kind == .pulse { list.append(SpectrumKnobs.cycles) }
    return list
  }

  private func binding(for spec: KnobSpec, _ model: SpectrumModel) -> Binding<Double> {
    switch spec.id {
    case "spectrum-lambda":
      return Binding(
        get: { model.active.lambda },
        set: {
          model.edit(.lambda($0))
          model.follow()
        })
    case "spectrum-temperature":
      return Binding(
        get: { model.active.temperature },
        set: {
          model.edit(.temperature($0))
          model.follow()
        })
    case "spectrum-e0":
      return Binding(get: { model.active.e0 }, set: { model.edit(.e0($0)) })
    case "spectrum-theta":
      return Binding(get: { model.active.theta }, set: { model.edit(.theta($0.rounded())) })
    case "spectrum-delta":
      return Binding(get: { model.active.delta }, set: { model.edit(.delta($0.rounded())) })
    case "spectrum-phi":
      return Binding(get: { model.active.phi }, set: { model.edit(.phi($0.rounded())) })
    default:
      return Binding(get: { model.active.cycles }, set: { model.edit(.cycles(($0 * 2).rounded() / 2)) })
    }
  }

  // MARK: 02 Medium & time

  @ViewBuilder private func mediumGroup(_ model: SpectrumModel) -> some View {
    SheetGroup(number: "02", title: "Medium & time") {
      GlassSegmented(
        items: Matter.Medium.allCases, selected: model.state.medium, id: "spectrum-medium",
        tint: { _ in Theme.amber }, title: { $0.name.replacingOccurrences(of: " (BK7)", with: "") }
      ) { m in model.state.medium = m }
      Text(mediumNote(model)).panelCaption()
      GlassSlider(
        title: "\u{03BA} Display speed",
        value: Binding(get: { log10(model.state.speed) }, set: { model.state.speed = pow(10, $0) }),
        range: SpectrumDisplay.speedLogRange, step: 0.01, color: Theme.dialAmber,
        format: { JSFormat.toFixed(pow(10, $0), 2) + " cycles/s" }
      )
      .accessibilityIdentifier("spectrum-speed")
      SheetCaption(
        "Real light oscillates trillions of times a second. The display slows every source by the same factor, so the readouts stay real.")
    }
  }

  private func mediumNote(_ model: SpectrumModel) -> String {
    let m = model.state.medium.index(model.active.lambda)
    if model.state.medium == .vacuum {
      return "Light moves at c. Pick a medium to watch it slow down and its wavelength shrink."
    }
    guard m.valid else { return "No refractive-index data for this medium at this wavelength. The scope shows it as vacuum." }
    return
      "n = \(JSFormat.toFixed(m.n, 4)) at this wavelength: light moves at \(JSFormat.toFixed(1 / m.n, 3)) c and its wavelength shrinks by the same factor. The frequency doesn't change.\(m.k > 1e-3 ? " It is also absorbed as it goes." : "")"
  }

  // MARK: 03 Display, 04 Feedback

  private func displayGroup(_ model: SpectrumModel) -> some View {
    SheetGroup(number: "03", title: "Display") {
      GlassToggle(
        "Electric field E", isOn: Binding(get: { model.state.scope.showE }, set: { model.state.scope.showE = $0 }),
        symbol: "bolt.horizontal"
      )
      .accessibilityIdentifier("spectrum-show-e")
      GlassToggle(
        "Magnetic field B", isOn: Binding(get: { model.state.scope.showB }, set: { model.state.scope.showB = $0 }),
        symbol: "circle.dotted"
      )
      .accessibilityIdentifier("spectrum-show-b")
      GlassToggle(
        "Energy flow S (Poynting)", isOn: Binding(get: { model.state.scope.showS }, set: { model.state.scope.showS = $0 }),
        symbol: "arrow.right"
      )
      .accessibilityIdentifier("spectrum-show-s")
    }
  }

  private var feedbackGroup: some View {
    SheetGroup(number: "04", title: "Feedback") {
      GlassToggle(
        "Sound", isOn: Binding(get: { app.settings.soundOn }, set: { app.settings.soundOn = $0 }), symbol: "speaker.wave.2",
        subtitle: "Each source hums at a pitch set by its frequency; band edges click."
      )
      .accessibilityIdentifier("spectrum-sound")
      GlassToggle(
        "Haptics", isOn: Binding(get: { app.settings.hapticsOn }, set: { app.settings.hapticsOn = $0 }),
        symbol: "hand.tap", subtitle: "Detents at band edges, a firm stop at the ionizing line."
      )
      .accessibilityIdentifier("spectrum-haptics")
      SheetCaption("These are the app-wide settings; strength and the continuous hum are in Settings.")
    }
  }
}
