import SwiftUI
import UIKit

/// The Spin tab (SPEC-features §4): species picker (Gyroscope · Proton · Electron · Compare),
/// the holo scene, readouts, pulses, FID / spectrum / Wigner, Hear it, links, and the dials.
struct SpinTab: View {
  @Environment(AppModel.self) private var app
  @Environment(\.scenePhase) private var scenePhase

  var body: some View {
    let model = app.spin
    InstrumentScreen(
      tab: .spin, subtitle: "Precession in your field", notes: SpinNotes.notes, transport: transport(model)
    ) {
      SpinDialsSheet(model: model)
    } content: {
      SpinContent(model: model)
    }
    .onAppear {
      model.setVisible(true)
      model.handleFocus(app.focusedMarker)
    }
    .onDisappear { model.setVisible(false) }
    // A strip marker or the Live tab's "Hear Earth-field NMR" focusing something on Spin.
    .onChange(of: app.focusedMarker) { _, marker in
      if model.isVisible { model.handleFocus(marker) }
    }
    #if DEBUG
      .modifier(SpinSnapshotSheets(model: model))
    #endif
    // Write pending dial edits before the app can be suspended (the store debounces 400 ms).
    .onChange(of: scenePhase) { _, phase in if phase != .active { model.flush() } }
  }

  /// Rule R3: how the visible motion maps to real time, and the fastest visible oscillation.
  private func transport(_ model: SpinModel) -> TransportConfig {
    let r = model.readings
    switch model.saved.view {
    case .gyroscope, .compare:
      let d = model.saved.gyro.sanitized.timeScale
      let mapping: TimeMapping = abs(d - 1) < 0.005 ? .realTime : .slowed(factor: 1 / max(d, 1e-6))
      // The fastest thing on screen: the rotor's own turn or its inertial nod.
      let fastest = r.gyro.map { max(abs($0.rpm) / 60, $0.nutationHz) }
      return TransportConfig(
        timeMapping: mapping, frequency: fastest,
        actions: [
          TransportAction(id: "spin-transport-relaunch", title: "Relaunch rotor", symbol: "gyroscope", action: model.relaunchRotor),
          TransportAction(id: "spin-transport-kick", title: "Kick the axle", symbol: "hand.tap", action: model.kickRotor),
        ])
    case .proton, .electron:
      let species = model.fidSpecies
      let bench = model.bench(species)
      let reading = species == .electron ? r.electron : r.proton
      let pace = model.runner(species).timeUnit * bench.slowMotion
      // In the rotating frame M turns at |Δf| freely, or nutates at √(f₁² + Δf²) about B_eff.
      let visible = reading.isRFOn ? reading.drive.effectiveHz : abs(reading.offsetHz)
      let mapping: TimeMapping
      let frequency: Double
      if model.saved.rotatingFrame {
        if abs(pace - 1) < 1e-6 {
          mapping = .heterodyned(fRef: reading.carrierHz)
          frequency = reading.carrierHz + visible
        } else {
          mapping = .slowed(factor: 1 / pace)
          frequency = visible
        }
      } else {
        mapping = abs(pace - 1) < 1e-6 ? .realTime : .slowed(factor: 1 / pace)
        frequency = reading.larmorHz
      }
      return TransportConfig(
        timeMapping: mapping, frequency: frequency,
        actions: [
          TransportAction(id: "spin-transport-run", title: "Run \(bench.sequence.title)", symbol: "play.fill") {
            model.runSequence(species)
          },
          TransportAction(id: "spin-transport-reset-m", title: "Reset magnetization", symbol: "arrow.counterclockwise") {
            model.resetMagnetization(species)
          },
        ])
    }
  }
}

// MARK: - Bindings

extension SpinModel {
  /// A knob binding into the rotor's params (`spin-<id>` → `HeavyTopParams`).
  func gyroBinding(_ spec: KnobSpec) -> Binding<Double> {
    let key = String(spec.id.dropFirst("spin-".count))
    return Binding(
      get: { [unowned self] in
        let p = self.saved.gyro
        switch key {
        case "motor": return p.motorRPM
        case "inertia": return p.inertia
        case "gravity": return p.gravity
        case "balance": return p.balance
        case "friction": return p.friction
        case "air": return p.air
        case "magnet": return p.magnet
        default: return p.timeScale
        }
      },
      set: { [unowned self] v in
        guard v.isFinite else { return }
        switch key {
        case "motor": self.saved.gyro.motorRPM = (v / SpinKnobs.motor.step).rounded() * SpinKnobs.motor.step
        case "inertia": self.saved.gyro.inertia = v
        case "gravity": self.saved.gyro.gravity = v
        case "balance": self.saved.gyro.balance = v
        case "friction": self.saved.gyro.friction = v
        case "air": self.saved.gyro.air = v
        case "magnet": self.saved.gyro.magnet = v
        default: self.saved.gyro.timeScale = v
        }
      })
  }

  /// A knob binding into one species' bench (`spin-<p|e>-<id>` → `SpinBench`).
  func benchBinding(_ species: SpinSpecies, _ spec: KnobSpec) -> Binding<Double> {
    let key = String(spec.id.split(separator: "-").last ?? "")
    return Binding(
      get: { [unowned self] in
        let b = self.bench(species)
        switch key {
        case "b1": return b.b1
        case "offset": return b.offsetHz
        case "phase": return b.phase
        case "ramp": return b.ramp
        case "t1": return b.t1
        case "t2": return b.t2
        case "gradient": return b.gradient
        case "isochromats": return b.isochromats
        case "tau": return b.echoTau
        case "tr": return b.repetition
        default: return b.slowMotion
        }
      },
      set: { [unowned self] v in
        guard v.isFinite else { return }
        self.setBench(species) { b in
          switch key {
          case "b1": b.b1 = v
          case "offset": b.offsetHz = v
          case "phase": b.phase = v
          case "ramp": b.ramp = v
          case "t1": b.t1 = v
          case "t2": b.t2 = v
          case "gradient": b.gradient = v
          case "isochromats": b.isochromats = v.rounded()
          case "tau": b.echoTau = v
          case "tr": b.repetition = v
          default: b.slowMotion = v
          }
        }
      })
  }

  var fieldBinding: Binding<Double> {
    Binding(get: { [unowned self] in self.saved.fieldTesla }, set: { [unowned self] v in if v.isFinite, v > 0 { self.saved.fieldTesla = v } })
  }

  func flag(_ path: WritableKeyPath<SpinSaved, Bool>) -> Binding<Bool> {
    Binding(get: { [unowned self] in self.saved[keyPath: path] }, set: { [unowned self] in self.saved[keyPath: path] = $0 })
  }

  func benchFlag(_ species: SpinSpecies, _ path: WritableKeyPath<SpinBench, Bool>) -> Binding<Bool> {
    Binding(
      get: { [unowned self] in self.bench(species)[keyPath: path] },
      set: { [unowned self] v in self.setBench(species) { $0[keyPath: path] = v } })
  }

  func sequenceBinding(_ species: SpinSpecies) -> Binding<SpinSequence> {
    Binding(get: { [unowned self] in self.bench(species).sequence }, set: { [unowned self] v in self.setBench(species) { $0.sequence = v } })
  }

  var viewBinding: Binding<SpinView> {
    Binding(get: { [unowned self] in self.saved.view }, set: { [unowned self] in self.select($0) })
  }

  var fieldSourceBinding: Binding<SpinFieldSource> {
    Binding(get: { [unowned self] in self.saved.fieldSource }, set: { [unowned self] in self.saved.fieldSource = $0 })
  }

  var wignerModeBinding: Binding<SpinWignerModeItem> {
    Binding(
      get: { [unowned self] in SpinWignerModeItem(mode: self.saved.wignerMode) },
      set: { [unowned self] in self.saved.wignerMode = $0.mode })
  }

  var zoomBinding: Binding<SpinSpectrumZoom> {
    Binding(get: { [unowned self] in self.saved.zoom }, set: { [unowned self] in self.saved.zoom = $0 })
  }
}

/// A chip item for the Wigner view's mode (a local wrapper, so no conformance is added to the
/// Phase engine's type).
nonisolated struct SpinWignerModeItem: Identifiable, Hashable, Sendable {
  let mode: Phase.TimeFrequencyMode
  var id: String { mode.rawValue }
  static let all = Phase.TimeFrequencyMode.allCases.map(SpinWignerModeItem.init(mode:))
}

// MARK: - Dials sheet

/// Every Spin dial for the visible view, with Reset dials / Reset alignment pinned.
struct SpinDialsSheet: View {
  let model: SpinModel

  var body: some View {
    ControlSheet(
      title: "Spin controls", resetDials: model.resetDials, resetAlignment: model.resetAlignment,
      resetDialsHint: "Restore this view's dials and the B₀ dial to their defaults."
    ) {
      // The carrier drives both benches (Compare steps them too); alignment tilts only the large
      // Bloch sphere of the proton and electron views, so Compare's sheet leaves it out.
      SpinFieldControls(
        model: model, number: "01", showsCarrier: model.saved.view != .gyroscope,
        showsAlign: model.saved.view == .proton || model.saved.view == .electron)
      switch model.saved.view {
      case .gyroscope, .compare:
        InstrumentPanel("Rotor", number: "02", provenance: [.model, .analogy]) {
          KnobGrid(specs: SpinKnobSpecs.gyroscope, value: model.gyroBinding, showsSliders: true)
          SheetCaption("Drag a dial up or right; double-tap resets it. Gravity is the top's \"field\": it plays the part B plays for a spin.")
        }
        SpinPresetChips(model: model, number: "03")
        if model.saved.view == .compare {
          SheetCaption("The proton and electron benches keep their own drive and relaxation dials; open their views to change them.")
        }
      case .proton, .electron:
        let species = model.fidSpecies
        let specs = SpinKnobSpecs.bench(for: species)
        InstrumentPanel("Drive", number: "02", provenance: [.model]) {
          KnobGrid(specs: specs.drive, value: { model.benchBinding(species, $0) }, showsSliders: true)
          GlassToggle("CW drive", isOn: model.benchFlag(species, \.continuous), symbol: "waveform", subtitle: "B₁ stays on: Rabi nutation about B_eff")
            .accessibilityIdentifier("spin-dials-cw")
        }
        InstrumentPanel("Relaxation", number: "03", provenance: [.model]) {
          KnobGrid(specs: specs.relax, value: { model.benchBinding(species, $0) }, showsSliders: true)
          SheetCaption("A new gradient or isochromat count re-spreads the sample and returns it to equilibrium.")
        }
        InstrumentPanel("Sequence", number: "04", provenance: [.model]) {
          ChoiceChips(items: SpinSequence.allCases, selection: model.sequenceBinding(species), id: "spin-dials-sequence") {
            ChipLabel(title: $0.title)
          }
          .padding(.horizontal, -Theme.panelPadding)
          KnobGrid(specs: specs.timing, value: { model.benchBinding(species, $0) }, columns: 3, showsSliders: true)
          GlassToggle(
            "Repeat every TR", isOn: model.flag(\.repeatPulses), symbol: "repeat",
            subtitle: SpinBenchPage.repeatSubtitle(model, species))
            .accessibilityIdentifier("spin-dials-repeat")
        }
      }
      InstrumentPanel("Display", number: model.saved.view == .gyroscope || model.saved.view == .compare ? "04" : "05") {
        if model.saved.view != .gyroscope {
          GlassToggle("Rotating frame", isOn: model.flag(\.rotatingFrame), symbol: "arrow.triangle.2.circlepath", subtitle: "Watch from the frame turning with the RF carrier (HETERODYNED)")
            .accessibilityIdentifier("spin-dials-rotating")
        }
        GlassToggle("Trail", isOn: model.flag(\.showTrail), symbol: "scribble.variable")
          .accessibilityIdentifier("spin-dials-trail")
        if model.saved.view != .proton, model.saved.view != .electron {
          GlassToggle("Vectors L, τ, g, B", isOn: model.flag(\.showVectors), symbol: "arrow.up.right")
            .accessibilityIdentifier("spin-dials-vectors")
        }
        GlassToggle(
          "Publish while hidden", isOn: model.flag(\.publishHidden), symbol: "dot.radiowaves.left.and.right",
          subtitle: "Keep spin.fid and gyro.tip streaming to the Scope and Patch when this tab is not on screen")
          .accessibilityIdentifier("spin-dials-publish")
      }
    }
  }
}

/// The B₀ source, the dial (only while it is in use), and the carrier / alignment switches.
struct SpinFieldControls: View {
  let model: SpinModel
  let number: String
  var showsCarrier = false
  var showsAlign = false
  @Environment(\.openURL) private var openURL

  var body: some View {
    let r = model.readings
    let showsEarth = model.saved.fieldSource == .live && r.liveFieldAvailable && r.dip != nil
    InstrumentPanel("Field", number: number, provenance: showsEarth ? [r.fieldProvenance, .inferred] : [r.fieldProvenance]) {
      ChoiceChips(items: SpinFieldSource.allCases, selection: model.fieldSourceBinding, id: "spin-field-source", tint: Theme.fieldB) {
        ChipLabel(title: $0.title, symbol: $0 == .live ? "location.north.line" : "dial.low")
      }
      .padding(.horizontal, -Theme.panelPadding)
      if model.saved.fieldSource == .dial || !r.liveFieldAvailable {
        KnobGrid(specs: [SpinKnobSpecs.b0], value: { _ in model.fieldBinding }, columns: 1, showsSliders: true)
      }
      if showsEarth, let dip = r.dip {
        // Your field's dip and the magnetic latitude it implies (dipole: tan I = 2 tan λₘ).
        ReadoutGrid(columns: 2) {
          Readout("|B|", value: SpectraFormat.si(r.field, unit: "T"), color: Theme.fieldB, provenance: r.fieldProvenance)
          Readout("Dip", value: degrees(dip), provenance: r.fieldProvenance)
          if let latitude = r.latitude {
            Readout("Mag. latitude", value: degrees(latitude), provenance: .inferred)
          }
          if let calibration = r.calibration {
            Readout(
              "Calibration", value: SpinMagnetometerCalibration.title(calibration),
              color: calibration >= 1 ? Theme.phosphor : Theme.amber, provenance: r.fieldProvenance)
          }
        }
      }
      Text(status(r)).panelCaption()
      if model.saved.fieldSource == .live, !r.liveFieldAvailable, r.liveFieldState == .denied {
        ActionButton("Open Settings", symbol: "gear") {
          if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
        }
        .accessibilityIdentifier("spin-field-open-settings")
      }
      if showsCarrier {
        GlassToggle(
          "Carrier follows the line", isOn: model.flag(\.lockCarrier), symbol: "scope",
          subtitle: "Off: the RF carrier holds still, so a drifting field shows up as detuning")
          .accessibilityIdentifier("spin-lock-carrier")
      }
      if showsAlign {
        // Disabled controls say why (no dead UI).
        GlassToggle(
          "Align with your field", isOn: model.flag(\.alignToField), symbol: "location.north.line",
          subtitle: r.liveFieldAvailable
            ? "Tilt the Bloch sphere so B₀ points along the measured field" : "Needs the live magnetometer")
          .accessibilityIdentifier("spin-align-field")
          .disabled(!r.liveFieldAvailable)
      }
    }
  }

  private func degrees(_ radians: Double) -> String {
    guard radians.isFinite else { return "—" }
    let d = radians * 180 / .pi
    return (d < 0 ? "−" : "") + "\(SpectraFormat.significant(abs(d), 3))°"
  }

  private func status(_ r: SpinReadings) -> String {
    if model.saved.fieldSource == .dial {
      return "B₀ comes from the dial. The rotor feels at most 10 mT of it."
    }
    if r.liveFieldAvailable {
      let sim = r.fieldProvenance == .sim ? " (simulated in this build)" : ""
      return "B₀ is your magnetometer's |B|\(sim), smoothed over 0.25 s."
    }
    switch r.liveFieldState {
    case .denied: return "Motion access is off, so the dial stands in. Turn it on in Settings."
    case .unavailable(let why), .locked(let why): return "\(why) The dial stands in."
    case .requesting: return "Starting the magnetometer…"
    default: return "Waiting for the magnetometer; the dial stands in."
    }
  }
}

/// The rotor's field trips (Gyre's nine experiments and the Spin trips). Plain glass chips:
/// none is lit while the knobs are set by hand.
struct SpinPresetChips: View {
  let model: SpinModel
  let number: String

  var body: some View {
    InstrumentPanel("Field trips", number: number, provenance: [.model]) {
      ScrollViewReader { proxy in
        ScrollView(.horizontal) {
          GlassEffectContainer(spacing: 10) {
            HStack(spacing: 8) {
              ForEach(HeavyTopPreset.all) { preset in
                let selected = preset.id == model.saved.presetID
                Button {
                  Haptics.shared.selection()
                  model.apply(preset: preset)
                } label: {
                  Text(preset.title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(selected ? Theme.text : Theme.muted)
                    .lineLimit(1)
                    .padding(.horizontal, 12)
                    .frame(minHeight: 40)
                }
                .buttonStyle(.plain)
                .glassEffect(
                  selected ? .regular.tint(Theme.phosphor.opacity(0.28)).interactive() : .regular.interactive(),
                  in: .rect(cornerRadius: Theme.chipRadius)
                )
                .accessibilityAddTraits(selected ? .isSelected : [])
                .accessibilityHint(Self.subtitle(preset))
                .accessibilityIdentifier("spin-preset-\(preset.id)")
                .id(preset.id)
              }
            }
            .padding(.horizontal, Theme.gutter)
            .padding(.vertical, 4)
          }
        }
        .scrollIndicators(.hidden)
        .padding(.horizontal, -Theme.panelPadding)
        .onAppear { if !model.saved.presetID.isEmpty { proxy.scrollTo(model.saved.presetID, anchor: .center) } }
      }
      let current = HeavyTopPreset.all.first { $0.id == model.saved.presetID }
      Text(current.map(Self.subtitle) ?? "Knobs set by hand. Pick a trip to load its settings.").panelCaption()
    }
  }

  /// The trip's one-line description. Gyre's "Slow motion" line tells you to tap its bubble;
  /// here the axle is knocked with Kick.
  static func subtitle(_ preset: HeavyTopPreset) -> String {
    preset.id == "slow" ? "Press Kick and watch it nod" : preset.subtitle
  }
}
