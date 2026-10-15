import SwiftUI

/// The Spin tab's scrolling content: species picker, one shared scene panel, then the page
/// for the selected view.
struct SpinContent: View {
  let model: SpinModel
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    ScrollViewReader { proxy in
      VStack(alignment: .leading, spacing: Theme.stackSpacing) {
        // Titles only, so Gyroscope · Proton · Electron · Compare all fit on the phone's width
        // (the row still scrolls at large Dynamic Type sizes).
        ChoiceChips(items: SpinView.allCases, selection: model.viewBinding, id: "spin-view") { v in
          ChipLabel(title: v.title)
        }
        .padding(.horizontal, -Theme.gutter)
        .id("spin-anchor-top")
        SpinScenePanel(model: model)
        switch model.saved.view {
        case .gyroscope: SpinGyroscopePage(model: model)
        case .proton: SpinBenchPage(model: model, species: .protonWater)
        case .electron: SpinBenchPage(model: model, species: .electron)
        case .compare: SpinComparePage(model: model)
        }
        SpinLinksPanel(model: model).id("spin-anchor-loop")
      }
      .task(id: model.scrollRequest) {
        // `-open spin/<view>/<panel>` or a hand-off from another tab: scroll to a panel
        // (readouts, drive, hear, fid, wigner, tip, field, loop) once the layout exists.
        guard let request = model.scrollRequest else { return }
        try? await Task.sleep(for: .milliseconds(request.serial == 1 ? 700 : 350))
        guard !Task.isCancelled else { return }
        withAnimation(Theme.animation(reduceMotion)) { proxy.scrollTo("spin-anchor-\(request.anchor)", anchor: .top) }
      }
    }
  }
}

// MARK: - Scene panel

/// Panel 01: the holo scene with its chips, legend, camera buttons and the view's toggles.
struct SpinScenePanel: View {
  let model: SpinModel
  @Environment(AppModel.self) private var app
  @Environment(\.dynamicTypeSize) private var typeSize

  var body: some View {
    @Bindable var scene = model.scene
    let view = model.saved.view
    InstrumentPanel(title, number: "01", provenance: provenance) {
      PlotWell(height: typeSize.isAccessibilitySize ? 300 : 340, grid: 0) {
        MetalCanvas(
          scene: scene, camera: $scene.camera, home: scene.home, maximumFramesPerSecond: 60,
          redrawKey: model.saved.view.hashValue, label: label)
          .accessibilityIdentifier("spin-scene")
      }
      .overlay(alignment: .topLeading) {
        VStack(alignment: .leading, spacing: 5) { chips }
          .padding(10)
          .allowsHitTesting(false)
      }
      .overlay {
        if view == .compare {
          VStack {
            HStack {
              Spacer()
              compareLabel("Gyroscope")
            }
            Spacer()
            HStack {
              compareLabel("Proton")
              Spacer()
              compareLabel("Electron")
            }
          }
          .padding(10)
          // Labels on the plot, like its annotations: they keep their size, or at accessibility
          // sizes "PROTON" and "ELECTRON" run into each other and the spins' mapping chip. The
          // scene's VoiceOver label names all three.
          .dynamicTypeSize(...DynamicTypeSize.large)
          .allowsHitTesting(false)
          .accessibilityHidden(true)
        }
      }
      .overlay(alignment: .bottom) {
        // The spins' own time mapping sits between them (the top-left chips would cover the
        // rotor drawn above).
        if view == .compare {
          spinsMappingChip.padding(.bottom, 8).allowsHitTesting(false)
        }
      }
      // The legend wraps beside the camera buttons; at accessibility sizes it gets its own row.
      if typeSize.isAccessibilitySize {
        VStack(alignment: .leading, spacing: 10) {
          SpinLegend(items: legend)
          CameraControls(camera: $scene.camera, home: scene.home, id: "spin-camera")
        }
      } else {
        HStack(alignment: .center, spacing: 10) {
          SpinLegend(items: legend).frame(maxWidth: .infinity, alignment: .leading)
          CameraControls(camera: $scene.camera, home: scene.home, id: "spin-camera")
        }
      }
      toggles
      Text(caption).panelCaption()
    }
  }

  private func compareLabel(_ name: String) -> some View {
    Text(name.instrumentCaps).font(Theme.eyebrowFont).tracking(1.5).foregroundStyle(Theme.muted)
  }

  private var title: String {
    switch model.saved.view {
    case .gyroscope: "Heavy top"
    case .proton: "Proton spin"
    case .electron: "Electron spin"
    case .compare: "One equation"
    }
  }

  private var provenance: [Provenance] {
    let r = model.readings
    var list: [Provenance] = [.model]
    switch model.saved.view {
    case .gyroscope:
      if let m = r.motionProvenance { list.append(m) }
      // A magnetized rotor also precesses in your measured field (rule R4: the union of inputs).
      if model.saved.gyro.magnet != 0, !r.rotorResonance { list.append(r.fieldProvenance) }
      list.append(.analogy)
    case .proton, .electron:
      list.append(r.fieldProvenance)
    case .compare:
      list.append(r.fieldProvenance)
      if let m = r.motionProvenance { list.append(m) }
      list.append(.analogy)
    }
    return list
  }

  private var label: String {
    switch model.saved.view {
    case .gyroscope: "Gyroscope rotor precessing on its pivot; drag to rotate, pinch to zoom, double-tap to align"
    case .proton: "Proton magnetization on the Bloch sphere"
    case .electron: "Electron magnetization on the Bloch sphere"
    case .compare: "Gyroscope, proton and electron side by side"
    }
  }

  @ViewBuilder private var chips: some View {
    let r = model.readings
    switch model.saved.view {
    case .gyroscope:
      let d = model.saved.gyro.sanitized.timeScale
      if abs(d - 1) > 0.005 { SpinPhosphorChip(text: "TIME ×\(SpectraFormat.significant(d, 2))", color: RGB(0.72, 0.55, 1).color) }
      if r.rotorResonance {
        SpinPhosphorChip(text: "RESONANCE DRIVE", detail: "B₀ + rotating B₁, not your field", color: Theme.fieldB, symbol: "dot.radiowaves.left.and.right")
      }
    case .proton, .electron:
      let species = model.fidSpecies
      let reading = species == .electron ? r.electron : r.proton
      let pace = model.runner(species).timeUnit * model.bench(species).slowMotion
      if model.saved.rotatingFrame {
        SpinPhosphorChip(text: "HETERODYNED", detail: "@ \(SpectraFormat.frequency(reading.carrierHz, digits: 5))", color: Theme.iceRGB.color, symbol: "waveform")
      } else if reading.larmorHz * pace > app.clock.frameRate / 2 {
        // The same test as the transport's ALIASED chip and the scene's smeared cone: the
        // displayed rate past half the measured frame rate.
        SpinPhosphorChip(text: "ALIASED", detail: "lab frame strobes", color: Theme.ionizing, symbol: "exclamationmark.triangle.fill")
      }
      if abs(pace - 1) > 1e-6 {
        SpinPhosphorChip(text: "SLOWED", detail: "×\(SpectraFormat.scientific(1 / pace, digits: 3))", color: RGB(0.72, 0.55, 1).color, symbol: "tuningfork")
      }
      if species == .electron, r.fieldChips.electronInAMBand {
        SpinPhosphorChip(text: "AM BAND", detail: SpectraFormat.frequency(r.fieldChips.electronHz, digits: 4), color: BandPalette.color(forFrequency: r.fieldChips.electronHz), symbol: "antenna.radiowaves.left.and.right")
      }
    case .compare:
      SpinPhosphorChip(text: "ONE EQUATION", detail: "dL/dt = μ × B", color: Theme.phosphor)
    }
  }

  /// Rule R3 for Compare's two spins (the transport declares the rotor's mapping): heterodyned
  /// at each carrier with the electron also slowed, or the lab frame, aliased when its displayed
  /// rate passes half the measured frame rate.
  @ViewBuilder private var spinsMappingChip: some View {
    let r = model.readings
    let slowed = Int((1 / SpinModel.timeUnit(.electron)).rounded())
    if model.saved.rotatingFrame {
      SpinPhosphorChip(text: "SPINS HETERODYNED", detail: "e⁻ also slowed ×\(slowed)", color: Theme.iceRGB.color, symbol: "waveform")
    } else if max(labRate(.protonWater, r.proton), labRate(.electron, r.electron)) > app.clock.frameRate / 2 {
      SpinPhosphorChip(text: "SPINS ALIASED", detail: "lab frame strobes", color: Theme.ionizing, symbol: "exclamationmark.triangle.fill")
    } else {
      SpinPhosphorChip(text: "SPINS · LAB FRAME", detail: "e⁻ slowed ×\(slowed)", color: Theme.iceRGB.color, symbol: "waveform")
    }
  }

  /// The displayed lab-frame Larmor rate of one bench (Hz on screen): its line × the bench pace.
  private func labRate(_ species: SpinSpecies, _ reading: SpinBenchReading) -> Double {
    reading.larmorHz * model.runner(species).timeUnit * model.bench(species).slowMotion
  }

  private var legend: [(String, Color)] {
    switch model.saved.view {
    case .gyroscope:
      // Only what the scene draws: the vectors (L, τ, g, B) follow their toggle.
      var items: [(String, Color)] = [("Rotor", Theme.analogy)]
      if model.saved.showVectors {
        items += [("L", Theme.amber), ("τ", Theme.roseRGB.color), ("g", Theme.muted), ("B", Theme.fieldB)]
      }
      if model.saved.showTrail { items.append(("Trail", Theme.analogy.opacity(0.7))) }
      return items
    case .proton, .electron:
      let band = BandPalette.color(forWavelength: model.fidSpecies.larmorWavelength(field: model.readings.field))
      let rotating = model.saved.rotatingFrame
      var items: [(String, Color)] = [("M", band), ("B₀", Theme.fieldB), ("B₁", Theme.fieldB.opacity(0.7))]
      if rotating { items.append(("B_eff", Theme.violetRGB.color)) }
      items.append((rotating ? "x′" : "x", Theme.iceRGB.color))
      items.append((rotating ? "y′" : "y", Theme.muted))
      return items
    case .compare:
      let chips = model.readings.fieldChips
      return [
        ("Rotor", Theme.analogy), ("¹H", BandPalette.color(forFrequency: chips.protonHz)),
        ("e⁻", BandPalette.color(forFrequency: chips.electronHz)), ("B", Theme.fieldB),
      ]
    }
  }

  @ViewBuilder private var toggles: some View {
    switch model.saved.view {
    case .gyroscope:
      SpinFlowRow {
        ActionButton("Kick", symbol: "hand.tap", action: model.kickRotor).accessibilityIdentifier("spin-kick")
        ActionButton("Relaunch", symbol: "gyroscope", action: model.relaunchRotor).accessibilityIdentifier("spin-relaunch")
      }
      .dynamicTypeSize(...SpinFlowRow.largestButtonSize)
      GlassToggle("Trail", isOn: model.flag(\.showTrail), symbol: "scribble.variable").accessibilityIdentifier("spin-trail")
      GlassToggle("Vectors L, τ, g, B", isOn: model.flag(\.showVectors), symbol: "arrow.up.right").accessibilityIdentifier("spin-vectors")
    case .proton, .electron:
      GlassToggle(
        "Rotating frame", isOn: model.flag(\.rotatingFrame), symbol: "arrow.triangle.2.circlepath",
        subtitle: model.saved.rotatingFrame ? "Heterodyned at the carrier: you see Δf" : "Lab frame: the full Larmor rate, strobing"
      )
      .accessibilityIdentifier("spin-rotating-frame")
      GlassToggle(
        "Align with your field", isOn: model.flag(\.alignToField), symbol: "location.north.line",
        subtitle: model.readings.liveFieldAvailable ? "B₀ along the measured field's direction" : "Needs the live magnetometer"
      )
      .accessibilityIdentifier("spin-align-field")
      .disabled(!model.readings.liveFieldAvailable)
    case .compare:
      GlassToggle("Rotating frame for the spins", isOn: model.flag(\.rotatingFrame), symbol: "arrow.triangle.2.circlepath")
        .accessibilityIdentifier("spin-rotating-frame")
    }
  }

  private var caption: String {
    switch model.saved.view {
    case .gyroscope:
      "The pivot is fixed to your phone (outline). Turn the phone: the rotor keeps its direction in space. Gravity makes it precess, as B makes a spin precess."
    case .proton:
      "Your phone measures the field. The spins are simulated. Dots are spin packets across the 10 cm sample; the arrow is their mean M; the arc at the top shows the sense of free precession."
    case .electron:
      "Your phone measures the field. The spins are simulated. The electron turns the other way about B, 658 times faster than the proton, so it is shown slowed."
    case .compare:
      "Rotor, proton and electron each precess about their own field: the rotor about gravity (or B, with a magnet), the spins about B. Only γ and the inertia differ."
    }
  }
}

/// Coloured dots with names, wrapping.
struct SpinLegend: View {
  let items: [(String, Color)]

  var body: some View {
    SpinFlowRow(spacing: 10) {
      ForEach(Array(items.enumerated()), id: \.offset) { _, item in
        HStack(spacing: 5) {
          Circle().fill(item.1).frame(width: 7, height: 7)
          Text(item.0).font(Theme.annotationFont).foregroundStyle(Theme.muted)
        }
      }
    }
    .accessibilityElement(children: .combine)
  }
}

/// A status chip on the content layer: over the scene's plot well (time mapping, ALIASED, AM
/// BAND…) and in the Hear it panel. The same type as the foundation's `StatusChip`, but not
/// glass: glass is for controls and navigation only, never on plots or panels, and plots stay
/// dark and high contrast (SPEC §2, design-orbitals). A dark well-colored capsule with a
/// hairline in the chip's color keeps it legible over the bright scene.
struct SpinPhosphorChip: View {
  let text: String
  var detail: String? = nil
  var color: Color = Theme.amber
  var symbol: String? = nil
  /// Grows with Dynamic Type: on for a chip that is a panel's readout (Hear it's pitch); off
  /// for chips drawn on a plot, which keep their size like the plot's annotations.
  var scales = false

  var body: some View {
    HStack(spacing: 5) {
      if let symbol { Image(systemName: symbol).font(scales ? .caption2.weight(.bold) : .system(size: 9, weight: .bold)) }
      VStack(alignment: .leading, spacing: 0) {
        Text(text)
          .font(scales ? .system(.caption2, design: .monospaced, weight: .semibold) : .system(size: 9, weight: .semibold, design: .monospaced))
          .tracking(0.8)
        if let detail {
          Text(detail)
            .font(scales ? .system(.caption2, design: .monospaced) : .system(size: 9, design: .monospaced))
            .monospacedDigit().opacity(0.85)
        }
      }
      .lineLimit(1)
      .fixedSize()
    }
    .foregroundStyle(color)
    .padding(.horizontal, 8)
    .padding(.vertical, 4)
    .background(Capsule().fill(Theme.plotWell.opacity(0.8)))
    .overlay(Capsule().strokeBorder(color.opacity(0.45), lineWidth: 0.75))
    .accessibilityElement(children: .combine)
  }
}

/// A simple wrapping row (buttons, legend items). An item wider than the row (a button title
/// at an accessibility text size) is offered the row's width, so it wraps its label instead of
/// running past the panel.
struct SpinFlowRow: Layout {
  var spacing: CGFloat = 8

  /// The foundation's `ActionButton` keeps its title on one line, so a row of them stops growing
  /// at this text size: past it "Show on spectrum" or "Run Inversion recovery" is wider than a
  /// panel on a 402-pt phone. Readouts and captions keep growing.
  static let largestButtonSize = DynamicTypeSize.accessibility1

  private func size(of s: LayoutSubview, maxWidth: CGFloat) -> CGSize {
    let ideal = s.sizeThatFits(.unspecified)
    guard maxWidth.isFinite, ideal.width > maxWidth else { return ideal }
    return s.sizeThatFits(ProposedViewSize(width: maxWidth, height: nil))
  }

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let width = proposal.width ?? .infinity
    var x: CGFloat = 0
    var y: CGFloat = 0
    var line: CGFloat = 0
    var widest: CGFloat = 0
    for s in subviews {
      let size = size(of: s, maxWidth: width)
      if x > 0, x + size.width > width {
        y += line + spacing
        x = 0
        line = 0
      }
      x += size.width + spacing
      line = max(line, size.height)
      widest = max(widest, x - spacing)
    }
    return CGSize(width: min(widest, width), height: y + line)
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    var x = bounds.minX
    var y = bounds.minY
    var line: CGFloat = 0
    for s in subviews {
      let size = size(of: s, maxWidth: bounds.width)
      if x > bounds.minX, x + size.width > bounds.maxX {
        y += line + spacing
        x = bounds.minX
        line = 0
      }
      s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
      x += size.width + spacing
      line = max(line, size.height)
    }
  }
}

// MARK: - Gyroscope

struct SpinGyroscopePage: View {
  let model: SpinModel

  var body: some View {
    let r = model.readings
    let motion = r.motionProvenance ?? .model
    InstrumentPanel("Rotor dials", number: "02", provenance: [.model]) {
      KnobGrid(specs: SpinKnobSpecs.gyroscopeInline, value: model.gyroBinding)
      Text("Motor, Gravity (Zero-g, Moon, Mars, Earth, Jupiter), Magnet (Real NdFeB, Electron-like) and Time. Every dial is in Dials.")
        .panelCaption()
    }
    .id("spin-anchor-dials")
    InstrumentPanel("Readouts", number: "03", provenance: [.model, motion]) {
      ReadoutGrid(columns: 2) {
        if let g = r.gyro {
          Readout("Spin", value: "\(Int(g.rpm.rounded())) rpm", color: Theme.analogy, provenance: .model)
          Readout("Precession", value: periodText(g.precessionHz), provenance: .model)
          Readout("Inertial nod", value: SpectraFormat.frequency(g.nutationHz), provenance: .model)
          Readout("|L|", value: SpectraFormat.si(g.angularMomentum, unit: "J·s"), provenance: .model)
          Readout("Torque |τ|", value: SpectraFormat.si(g.torque, unit: "N·m"), color: Theme.roseRGB.color, provenance: .model)
          Readout("Tilt", value: "\(Int((g.tilt * 180 / .pi).rounded()))°", provenance: .model)
          Readout("Rotor γ", value: g.rotorGamma == 0 ? "0 (no magnet)" : "\(SpectraFormat.significant(g.rotorGamma, 4)) rad/s/T", color: Theme.fieldB, provenance: .model)
          Readout("Rotor Larmor", value: periodText(r.rotorLarmor / (2 * .pi)), color: Theme.fieldB, provenance: .model)
          Readout("Reaction you feel", value: SpectraFormat.si(g.strain, unit: "N·m"), provenance: motion)
          Readout(
            r.rotorResonance ? "Field on rotor (drive)" : "Field on rotor", value: SpectraFormat.si(r.rotorField, unit: "T"),
            color: Theme.fieldB,
            provenance: !r.rotorResonance && model.saved.fieldSource == .live ? r.fieldProvenance : .model)
        }
      }
      Text("Rates are in simulated time; with Time ≠ 1 the screen shows them × Time. The inertial nod is not NMR's nutation (the driven Rabi rotation).")
        .panelCaption()
    }
    .id("spin-anchor-readouts")
    SpinPresetChips(model: model, number: "04")
    InstrumentPanel("Axle tip as I/Q", number: "05", provenance: [.model, motion, .analogy]) {
      SpinTipView(model: model)
      Text("The tip seen from above, x + iy, is sampled 960 times per simulated second (gyro.tip.i, gyro.tip.q). Precession is one line near 0 Hz; the nod adds essentially one sideband, on the spin's side.")
        .panelCaption()
    }
    .id("spin-anchor-tip")
    SpinFieldControls(model: model, number: "06").id("spin-anchor-field")
  }

  private func periodText(_ hz: Double) -> String {
    guard abs(hz) > 1e-6 else { return "0 Hz" }
    let sign = hz < 0 ? "−" : ""
    return "\(sign)\(SpectraFormat.frequency(abs(hz))) · \(SpectraFormat.si(1 / abs(hz), unit: "s"))"
  }
}

// MARK: - Proton / electron bench

struct SpinBenchPage: View {
  let model: SpinModel
  let species: SpinSpecies
  @Environment(AppModel.self) private var app

  var body: some View {
    let specs = SpinKnobSpecs.bench(for: species)
    let bench = model.bench(species)
    InstrumentPanel("Drive", number: "02", provenance: [.model]) {
      KnobGrid(specs: specs.inline, value: { model.benchBinding(species, $0) })
      SpinFlowRow {
        ActionButton("π/2", symbol: "bolt.fill", prominent: true) { model.pulse(species, flip: .pi / 2) }
          .accessibilityIdentifier("spin-pulse-90")
        ActionButton("π", symbol: "bolt.fill") { model.pulse(species, flip: .pi) }
          .accessibilityIdentifier("spin-pulse-180")
        ActionButton("Run \(bench.sequence.title)", symbol: "play.fill") { model.runSequence(species) }
          .accessibilityIdentifier("spin-run-sequence")
        ActionButton("Reset M", symbol: "arrow.counterclockwise") { model.resetMagnetization(species) }
          .accessibilityIdentifier("spin-reset-m")
      }
      .dynamicTypeSize(...SpinFlowRow.largestButtonSize)
      ChoiceChips(items: SpinSequence.allCases, selection: model.sequenceBinding(species), id: "spin-sequence") {
        ChipLabel(title: $0.title)
      }
      .padding(.horizontal, -Theme.panelPadding)
      GlassToggle("CW drive", isOn: model.benchFlag(species, \.continuous), symbol: "waveform", subtitle: "B₁ stays on: Rabi nutation about B_eff")
        .accessibilityIdentifier("spin-cw")
      GlassToggle("Repeat every TR", isOn: model.flag(\.repeatPulses), symbol: "repeat", subtitle: Self.repeatSubtitle(model, species))
        .accessibilityIdentifier("spin-repeat")
      Text("π/2 and π are finite pulses at B₁ about the phase φ, so you can watch the Rabi nutation. Run plays the sequence as hard pulses at exact times.")
        .panelCaption()
    }
    .id("spin-anchor-drive")
    SpinHearPanel(model: model, species: species).id("spin-anchor-hear")
    SpinBenchReadouts(model: model, species: species).id("spin-anchor-readouts")
    InstrumentPanel("FID, spectrum, Wigner", number: "05", provenance: [.model, model.readings.fieldProvenance]) {
      SpinFIDPanel(model: model, species: species)
    }
    .id("spin-anchor-fid")
    SpinFieldControls(model: model, number: "06").id("spin-anchor-field")
  }

  /// "TR 3 s", or, when TR is shorter than the sequence, the interval the bench really uses.
  static func repeatSubtitle(_ model: SpinModel, _ species: SpinSpecies) -> String {
    let bench = model.bench(species)
    let runner = model.runner(species)
    let tr = "TR \(SpectraFormat.si(bench.repetition, unit: "s"))"
    let used = SpinBenchRunner.repeatInterval(bench, record: runner.recordSeconds, timeUnit: runner.timeUnit)
    guard used > bench.repetition * 1.001 else { return tr }
    return "\(tr), stretched to \(SpectraFormat.si(used, unit: "s")) to fit the \(bench.sequence.title.lowercased())"
  }
}

/// Hear it: the proton line at true pitch under the simulated envelope. The electron's line
/// (about 1.4 MHz in Earth's field) is far above hearing, so its button stays disabled and
/// says why: it is shown heterodyned only.
struct SpinHearPanel: View {
  let model: SpinModel
  let species: SpinSpecies
  @Environment(AppModel.self) private var app

  var body: some View {
    let voice = model.readings.protonVoice
    let soundOn = app.settings.soundOn
    let audible = species == .protonWater
    InstrumentPanel("Hear it", number: "03", provenance: audible ? [.model, model.readings.fieldProvenance, .analogy] : [.model]) {
      // Side by side, or stacked at large Dynamic Type sizes.
      ViewThatFits(in: .horizontal) {
        HStack(spacing: 10) {
          hearButton(enabled: soundOn && audible)
          Spacer(minLength: 4)
          pitchChip(voice)
        }
        VStack(alignment: .leading, spacing: 10) {
          hearButton(enabled: soundOn && audible)
          pitchChip(voice)
        }
      }
      Text(caption(voice: voice, soundOn: soundOn)).panelCaption()
    }
  }

  private func caption(voice: LarmorVoice, soundOn: Bool) -> String {
    if species == .electron {
      return "Heterodyned only: the electron's line at \(SpectraFormat.frequency(model.readings.fieldChips.electronHz, digits: 4)) is far above hearing, so there is nothing true to play. Open the proton view to hear its line."
    }
    guard soundOn else { return "Turn on Sound in Settings to hear protons precessing at their true pitch." }
    return voice.mode == .truePitch
      ? "Protons in this field precess at \(SpectraFormat.frequency(voice.physicalHz, digits: 5)); you hear that pitch, ringing down as the simulated FID dephases. It is never a measured signal."
      : "Above 20 kHz the line is out of hearing, so a mapped pitch stands in."
  }

  private func hearButton(enabled: Bool) -> some View {
    ActionButton(
      model.isHearing ? "Stop" : "Hear it", symbol: model.isHearing ? "speaker.slash.fill" : "speaker.wave.2.fill",
      prominent: !model.isHearing && enabled, action: model.toggleHearing
    )
    .disabled(!enabled)
    .accessibilityHint(species == .electron ? "Unavailable: the electron line is far above hearing." : "")
    .accessibilityIdentifier("spin-hear")
  }

  @ViewBuilder private func pitchChip(_ voice: LarmorVoice) -> some View {
    if species == .electron {
      SpinPhosphorChip(
        text: "HETERODYNED ONLY", detail: SpectraFormat.frequency(model.readings.fieldChips.electronHz, digits: 4),
        color: Theme.iceRGB.color, symbol: "waveform", scales: true)
    } else {
      SpinPhosphorChip(
        text: voice.mode == .truePitch ? "TRUE PITCH" : "MAPPED", detail: SpectraFormat.frequency(voice.audibleHz, digits: 5),
        color: voice.mode == .truePitch ? Theme.phosphor : Theme.amber, symbol: "tuningfork", scales: true)
    }
  }
}

/// The bench's readouts: field, Larmor line, drive, relaxation, M, and the electron extras.
struct SpinBenchReadouts: View {
  let model: SpinModel
  let species: SpinSpecies

  var body: some View {
    let r = model.readings
    let b = species == .electron ? r.electron : r.proton
    let fp = r.fieldProvenance
    InstrumentPanel("Readouts", number: "04", provenance: [.model, fp]) {
      ReadoutGrid(columns: 2) {
        Readout("|B₀|", value: SpectraFormat.si(r.field, unit: "T"), color: Theme.fieldB, provenance: fp)
        Readout("Larmor line", value: SpectraFormat.frequency(b.larmorHz, digits: 5), color: BandPalette.color(forFrequency: b.larmorHz), provenance: .model)
        if fp != .model, let calibration = r.calibration {
          // Next to f_L: 1 µT of magnetometer bias moves the proton line by 42.6 Hz.
          Readout(
            "Mag. calibration", value: SpinMagnetometerCalibration.title(calibration),
            color: calibration >= 1 ? Theme.phosphor : Theme.amber, provenance: fp)
        }
        Readout("Larmor ω", value: "\(SpectraFormat.scientific(b.omega, digits: 4)) rad/s", provenance: .model)
        Readout("λ of the line", value: SpectraFormat.wavelength(b.wavelength), provenance: .model)
        Readout("Rabi Ω = γB₁", value: "\(SpectraFormat.scientific(b.drive.rabiAngular, digits: 3)) rad/s", color: Theme.fieldB, provenance: .model)
        Readout("Rabi rate", value: SpectraFormat.frequency(b.drive.rabiHz), provenance: .model)
        Readout("π/2 pulse", value: SpectraFormat.si(b.drive.ninetyDuration, unit: "s"), provenance: .model)
        Readout("Offset now", value: signed(b.offsetHz), color: Theme.iceRGB.color, provenance: .model)
        Readout("Max inversion", value: "\(Int((b.drive.maxInversionProbability * 100).rounded())) %", provenance: .model)
        Readout(
          "Dephasing time", value: b.dephasing.isFinite ? SpectraFormat.si(b.dephasing, unit: "s") : "none · uniform B₀",
          provenance: .model)
        Readout("|M⊥|", value: SpectraFormat.significant(b.mPerp, 2), color: BandPalette.color(forFrequency: b.larmorHz), provenance: .model)
        Readout("Along B₀ (M∥)", value: SpectraFormat.significant(b.mz, 2), provenance: .model)
        if species == .electron {
          Readout("Cyclotron orbit", value: SpectraFormat.frequency(r.fieldChips.electronCyclotronHz, digits: 6), provenance: .model)
          Readout("Anomaly beat", value: SpectraFormat.frequency(r.fieldChips.anomalyBeatHz, digits: 4), color: Theme.amber, provenance: .model)
        } else if let noise = r.fieldNoise, fp != .model {
          Readout("Pitch jitter", value: "±\(SpectraFormat.frequency(r.fieldChips.protonJitterHz(fieldNoise: noise)))", provenance: fp)
          Readout("Field noise", value: SpectraFormat.si(noise, unit: "T"), provenance: fp)
        }
      }
      if species == .electron {
        Text(
          "g − 2: the electron's orbit (cyclotron) and its spin differ by 1 + aₑ = 1.00116, so in this field they beat at \(SpectraFormat.frequency(r.fieldChips.anomalyBeatHz, digits: 4)): the anomaly beat g − 2 experiments measure.\(r.fieldChips.electronInAMBand ? " The spin line sits inside the AM broadcast band." : " The spin line is outside the AM broadcast band at this field.")"
        )
        .panelCaption()
      } else {
        Text("The dephasing time is the 1/e point of the gradient FID, a sinc (not a Lorentzian T₂*): 164 ms for 1 µT/m over 10 cm.")
          .panelCaption()
      }
    }
  }

  private func signed(_ f: Double) -> String {
    abs(f) < 1e-9 ? "0 Hz" : (f < 0 ? "−" : "+") + SpectraFormat.frequency(abs(f), digits: 3)
  }
}

/// FID trace, spectrum and Wigner view with their pickers.
struct SpinFIDPanel: View {
  let model: SpinModel
  let species: SpinSpecies

  var body: some View {
    let runner = model.runner(species)
    let band = BandPalette.color(forFrequency: species.larmorHz(field: model.readings.field))
    let reading = species == .electron ? model.readings.electron : model.readings.proton
    Eyebrow("FID · rotating frame", color: band)
    PlotWell(height: 130, grid: 0) {
      SpinFIDTrace(model: model, species: species, color: band)
    }
    Text("I solid, Q dashed, |M⊥| dotted gray. Like a triggered scope, each pulse or a sequence's read pulse starts a one-record sweep that holds until the next; a late spin echo is recorded around its echo. With CW drive the trace rolls.")
      .panelCaption()
    Eyebrow("Spectrum · last record", color: band)
    PlotWell(height: 120, grid: 0) {
      SpinSpectrumView(
        spectrum: model.wignerSpecies == species ? model.spectrum : nil, zoom: model.saved.zoom,
        sampleRate: runner.sampleRate, expected: species.precessionSense.sign * reading.offsetHz, color: band)
    }
    ChoiceChips(items: SpinSpectrumZoom.allCases, selection: model.zoomBinding, id: "spin-zoom") { ChipLabel(title: $0.title) }
      .padding(.horizontal, -Theme.panelPadding)
    Text("The amber dashes mark where the line should sit: −Δf for protons, +Δf for electrons (I + jQ baseband). A gradient makes the line a flat-topped band.")
      .panelCaption()
    Eyebrow("Wigner view · last record", color: Theme.amber)
      .id("spin-anchor-wigner")
    PlotWell(height: 190, grid: 0) {
      SpinWignerView(
        image: model.wignerSpecies == species ? model.wigner : nil, zoom: model.saved.zoom, sampleRate: runner.sampleRate,
        busy: model.wignerBusy
      )
      .equatable()
    }
    ChoiceChips(items: SpinWignerModeItem.all, selection: model.wignerModeBinding, id: "spin-wigner-mode") {
      ChipLabel(title: $0.mode.title)
    }
    .padding(.horizontal, -Theme.panelPadding)
    Text(
      "Warm is positive, cool negative; the strips are the time and frequency marginals. Turn up Sweep to make the FID chirp: its Wigner becomes a straight sloped line. Spacetime Wigner distribution: Utkarsh's construction and convention (C)."
    )
    .panelCaption()
  }
}

// MARK: - Compare

struct SpinComparePage: View {
  let model: SpinModel

  var body: some View {
    let r = model.readings
    let rotorGamma = r.gyro?.rotorGamma ?? 0
    InstrumentPanel("Side by side", number: "02", provenance: [.model, r.fieldProvenance]) {
      VStack(alignment: .leading, spacing: 14) {
        row(
          "Gyroscope", color: Theme.analogy,
          gamma: rotorGamma == 0 ? "γ 0 (no magnet)" : "γ \(SpectraFormat.significant(rotorGamma, 4)) rad/s/T",
          frequency: "Ωp \(SpectraFormat.frequency(abs(r.gyro?.precessionHz ?? 0)))",
          detail: "Precesses about gravity (or B, with a magnet). \(timeNote); it nods at \(SpectraFormat.frequency(r.gyro?.nutationHz ?? 0)).",
          analogy: true)
        row(
          "Proton (water)", color: BandPalette.color(forFrequency: r.fieldChips.protonHz),
          gamma: "γ \(SpectraFormat.scientific(SpinSpecies.protonWater.gamma, digits: 4)) rad/s/T",
          frequency: "f_L \(SpectraFormat.frequency(r.fieldChips.protonHz, digits: 5))",
          detail: model.saved.rotatingFrame
            ? "Clockwise about B. Heterodyned: you see Δf."
            : "Clockwise about B. Lab frame: the full Larmor rate.")
        row(
          "Electron", color: BandPalette.color(forFrequency: r.fieldChips.electronHz),
          gamma: "γ \(SpectraFormat.scientific(SpinSpecies.electron.gamma, digits: 4)) rad/s/T",
          frequency: "f_L \(SpectraFormat.frequency(r.fieldChips.electronHz, digits: 5))",
          detail: model.saved.rotatingFrame
            ? "Counterclockwise about B. Heterodyned and slowed ×\(Int((1 / SpinModel.timeUnit(.electron)).rounded()))."
            : "Counterclockwise about B. Lab frame, slowed ×\(Int((1 / SpinModel.timeUnit(.electron)).rounded())).")
      }
      if rotorGamma != 0 {
        Text(
          "With this magnet the rotor is a proton slowed \(SpectraFormat.scientific(abs(SpinSpecies.protonWater.gamma / rotorGamma), digits: 3))-fold: its slowness is honest mechanics, not a display trick."
        )
        .panelCaption()
      } else {
        Text("Give the rotor a magnet (Dials → Magnet) to compare its γ with the spins'.").panelCaption()
      }
    }
    .id("spin-anchor-readouts")
    SpinPresetChips(model: model, number: "03")
    SpinFieldControls(model: model, number: "04").id("spin-anchor-field")
  }

  /// "Real time", or the rotor's Time knob when it is not 1.
  private var timeNote: String {
    let d = model.saved.gyro.sanitized.timeScale
    return abs(d - 1) < 0.005 ? "Real time" : "Time ×\(SpectraFormat.significant(d, 2))"
  }

  private func row(
    _ name: String, color: Color, gamma: String, frequency: String, detail: String, analogy: Bool = false
  ) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 8) {
        Circle().fill(color).frame(width: 8, height: 8)
        Text(name.instrumentCaps).font(Theme.panelTitleFont).foregroundStyle(Theme.text)
        ProvenanceBadges(analogy ? [.model, .analogy] : [.model], compact: true)
      }
      ViewThatFits(in: .horizontal) {
        HStack(spacing: 12) {
          Text(gamma)
          Text(frequency).foregroundStyle(color)
        }
        VStack(alignment: .leading, spacing: 2) {
          Text(gamma)
          Text(frequency).foregroundStyle(color)
        }
      }
      .font(Theme.readoutValueFont)
      .monospacedDigit()
      .foregroundStyle(Theme.amber)
      Text(detail).panelCaption()
    }
    .accessibilityElement(children: .combine)
  }
}

// MARK: - Links

struct SpinLinksPanel: View {
  let model: SpinModel

  var body: some View {
    let number: String =
      switch model.saved.view {
      case .gyroscope: "07"
      case .proton: "07"
      case .electron: "07"
      case .compare: "05"
      }
    InstrumentPanel("Loop", number: number, provenance: [.model]) {
      SpinFlowRow {
        ActionButton("Show on spectrum", symbol: "ruler", action: model.showOnSpectrum)
          .accessibilityIdentifier("spin-show-spectrum")
        ActionButton("Open in Lab", symbol: "flask", action: model.openInLab)
          .accessibilityIdentifier("spin-open-lab")
        ActionButton("Open in Scope", symbol: "waveform.path.ecg", action: model.openInScope)
          .accessibilityIdentifier("spin-open-scope")
        ActionButton("Add to Patch", symbol: "point.3.connected.trianglepath.dotted", action: model.addToPatch)
          .accessibilityIdentifier("spin-add-patch")
      }
      .dynamicTypeSize(...SpinFlowRow.largestButtonSize)
      GlassToggle(
        "Publish while hidden", isOn: model.flag(\.publishHidden), symbol: "dot.radiowaves.left.and.right",
        subtitle: "spin.fid, spin.fid.q, gyro.tip.i and gyro.tip.q keep streaming when this tab is not on screen")
        .accessibilityIdentifier("spin-publish-hidden")
      Text(
        "Show on spectrum tunes source A to the \(model.linkSpecies == .electron ? "electron" : "proton") line's wavelength. Your phone measures the field. The spins are simulated."
      )
      .panelCaption()
    }
  }
}
