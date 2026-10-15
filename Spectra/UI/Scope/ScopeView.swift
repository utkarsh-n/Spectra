import SwiftUI

/// The universal oscilloscope (owner: **scope**; SPEC-features §3b, §3c).
///
/// - `ScopeView()`: the Live tab's Scope page. Follows `app.scopeRequest` (its streams go to
///   CH1…CH4, its preset is applied) and keeps its settings (`Spectra.scope.v1`).
/// - `ScopeView(fixedStreams:)`: an embedded scope for given streams (Patch Scope sink,
///   previews). Ignores `app.scopeRequest`, persists nothing.
///
/// It is scroll content (a stack of panels), to be placed inside an `InstrumentScreen`. While
/// visible it acquires the sensors its channels need with owner "scope" (embedded scopes use
/// their own owner) and releases them when it disappears.
struct ScopeView: View {
  var fixedStreams: [StreamID]? = nil

  init(fixedStreams: [StreamID]? = nil) {
    self.fixedStreams = fixedStreams.map { Array($0.prefix(4)) }
  }

  var body: some View {
    if let fixedStreams {
      // A new model whenever the stream list changes (a Patch sink is rewired, or the inspector
      // moves to another node), so the embedded scope never keeps showing the old streams.
      ScopeEmbeddedHost(fixedStreams: fixedStreams).id(fixedStreams)
    } else {
      ScopeScreen(model: ScopeModel.main, embedded: false)
    }
  }
}

/// Owns the embedded scope's model, made once per stream list when it first appears.
private struct ScopeEmbeddedHost: View {
  let fixedStreams: [StreamID]
  @State private var model: ScopeModel?

  var body: some View {
    if let model {
      ScopeScreen(model: model, embedded: true)
    } else {
      Color.clear
        .frame(maxWidth: .infinity, minHeight: 1)
        .onAppear {
          model = ScopeModel(
            owner: "scope.embedded.\(fixedStreams.map(\.rawValue).joined(separator: "+"))", persistent: false,
            fixedStreams: fixedStreams)
        }
    }
  }
}

/// The scope's panels for one model (the Live page's or an embedded one).
private struct ScopeScreen: View {
  let model: ScopeModel
  let embedded: Bool

  @Environment(AppModel.self) private var app
  @Environment(\.scenePhase) private var scenePhase
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var sheet: ScopeSheet?

  var body: some View {
    ScrollViewReader { proxy in
      VStack(alignment: .leading, spacing: Theme.stackSpacing) {
        ScopeDisplayPanel(model: model, embedded: embedded, sheet: $sheet).id(ScopeDebug.panelIDs[0])
        if !embedded {
          // The display and the measurements drive the model while they are on screen; these
          // tickers keep it acquiring and resolving streams (4 Hz) while only the probes or
          // the trigger panel shows, so their knobs read the right units and no data is lost
          // from short rings (the microphone keeps 2 s).
          ScopeProbesPanel(model: model).id(ScopeDebug.panelIDs[1])
            .background { ScopeTicker(model: model, interval: 0.25) }
          ScopeMeasurementsPanel(model: model).id(ScopeDebug.panelIDs[2])
          ScopeTriggerPanel(model: model).id(ScopeDebug.panelIDs[3])
            .background { ScopeTicker(model: model, interval: 0.25) }
        } else {
          ScopeMeasurementsPanel(model: model, compact: true)
        }
      }
      #if DEBUG
        .task {
          guard !embedded else { return }
          await ScopeDebug.run(model: model, scroll: { id in proxy.scrollTo(id, anchor: .top) }, present: { sheet = $0 })
        }
      #endif
      // "Open in Scope" from a card deep in the Sensors page shares that page's scroll view:
      // bring the display into view instead of landing on whatever panel sits at that offset.
      .onAppear { revealDisplay(proxy) }
      .onChange(of: app.scopeRequest?.id) { _, _ in revealDisplay(proxy) }
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(embedded ? "scope-embedded" : "scope-view")
    .onAppear { model.appear(app: app) }
    .onDisappear { model.disappear() }
    .onChange(of: scenePhase) { _, phase in
      if phase != .active { model.flushSettings() }
    }
    .onChange(of: app.scopeRequest?.id) { _, _ in
      guard !embedded else { return }
      model.applyPendingRequest()
    }
    .sheet(item: $sheet) { which in
      Group {
        switch which {
        case .channel(let i): ScopeChannelSheet(model: model, index: i)
        case .math: ScopeMathSheet(model: model)
        case .notes: FieldNotesSheet(notes: ScopeNotes.notes)
        }
      }
      .environment(app)
    }
  }

  /// Scrolls the display panel to the top once per new "Open in Scope" request.
  private func revealDisplay(_ proxy: ScrollViewProxy) {
    guard !embedded, let id = app.scopeRequest?.id, model.revealedRequest != id else { return }
    model.revealedRequest = id
    Task { @MainActor in
      // After the Live tab has switched pages and laid the scope out.
      try? await Task.sleep(for: .milliseconds(350))
      withAnimation(Theme.animation(reduceMotion, .smooth(duration: 0.35))) {
        proxy.scrollTo(ScopeDebug.panelIDs[0], anchor: .top)
      }
    }
  }
}

enum ScopeSheet: Identifiable, Hashable {
  case channel(Int), math, notes
  var id: String {
    switch self {
    case .channel(let i): "channel-\(i)"
    case .math: "math"
    case .notes: "notes"
    }
  }
}

/// 01 SCOPE: modes, Run/Stop/Single/Auto, the display, channels and the main knobs.
private struct ScopeDisplayPanel: View {
  let model: ScopeModel
  let embedded: Bool
  @Binding var sheet: ScopeSheet?

  @Environment(\.dynamicTypeSize) private var typeSize

  var body: some View {
    InstrumentPanel("Scope", number: "01", provenance: model.displayProvenance) {
      Button {
        Haptics.shared.tap()
        sheet = .notes
      } label: {
        // A plain button only hits its opaque pixels (the 12 pt glyph): the whole 28 pt frame
        // and 8 pt around it take the tap (44 pt), without making the panel header taller.
        Image(systemName: "info.circle")
          .frame(width: 28, height: 28)
          .contentShape(.interaction, Rectangle().inset(by: -8))
      }
      .buttonStyle(.plain)
      .foregroundStyle(Theme.muted)
      .accessibilityLabel("Scope field notes")
      .accessibilityIdentifier("scope-notes")
    } content: {
      ChoiceChips(
        // Embedded: XY only with two streams to plot (CH1 against CH2; it has no X/Y pickers).
        items: embedded ? ((model.fixedStreams?.count ?? 0) >= 2 ? [.yt, .roll, .xy, .fft] : [.yt, .roll, .fft]) : ScopeMode.allCases,
        selection: Binding(get: { model.settings.mode }, set: { model.setMode($0) }), id: "scope-mode"
      ) { mode in ChipLabel(title: mode.title, symbol: mode.symbol) }
      .padding(.horizontal, -Theme.panelPadding)

      transport

      ScopeDisplay(model: model, compact: embedded)

      ScrollView(.horizontal) {
        GlassEffectContainer(spacing: 8) {
          HStack(spacing: 8) {
            // Embedded: only the cabled channels (the others cannot be set up here; that is
            // done by cabling in Patch).
            ForEach(0..<channelCount, id: \.self) { i in
              ScopeChannelButton(model: model, index: i) { sheet = .channel(i) }
            }
            if !embedded {
              ScopeChannelButton(model: model, index: 4) { sheet = .math }
            }
          }
          .padding(.horizontal, Theme.panelPadding)
          .padding(.vertical, 2)
        }
      }
      .scrollIndicators(.hidden)
      .padding(.horizontal, -Theme.panelPadding)
      .accessibilityIdentifier("scope-channels")

      knobs

      Text(caption).panelCaption()
    }
  }

  private var channelCount: Int {
    embedded ? min(4, max(1, model.fixedStreams?.count ?? 4)) : 4
  }

  private var caption: String {
    var text = model.settings.mode.caption
    switch model.settings.mode {
    case .fft, .spectrogram, .wignerVille, .pseudoWigner:
      text += " Time/div sets the analyzed window (ten divisions, \(SpectraFormat.si(model.timebase * 10, unit: "s")))."
      if model.settings.mode == .fft, !(model.readout.channelAliasNotes[model.settings.analysisChannel] ?? []).isEmpty {
        text += " Dashed markers show where known sources above the Nyquist frequency land (labeled with their true frequency in Hz)."
      }
    case .roll:
      text += " Roll redraws every frame, so persistence applies to YT and XY only."
    case .xy:
      text += " Time/div sets how much history is drawn (ten divisions)."
    case .yt:
      break
    }
    if model.settings.mode == .fft, let r = model.spectrumResampledRate {
      text += " This channel is irregular, so it is held and resampled at \(SpectraFormat.frequency(r)) first."
    }
    if model.settings.mode.isTimeFrequency, let tf = model.timeFrequency {
      text +=
        " \(tf.samples) samples at \(SpectraFormat.rate(tf.sampleRate))\(tf.decimation > 1 ? " (averaged ×\(tf.decimation))" : "")\(tf.resampled ? ", held and resampled" : "")."
    }
    if model.isShown(0) || model.isShown(1) || model.isShown(2) || model.isShown(3) {
      if (0..<4).contains(where: { model.isShown($0) && model.isIrregular($0) }) {
        text += " Dashed traces are irregular streams, drawn sample-and-hold."
      }
    }
    return text
  }

  /// Run/Stop, Single and Auto. At accessibility sizes the three become icon buttons in one
  /// row (their labels stay for VoiceOver), so the screen is not pushed off the page.
  private var transport: some View {
    let compactRow = typeSize.isAccessibilitySize
    return GlassEffectContainer(spacing: 8) {
      HStack(spacing: compactRow ? 14 : 8) {
        Button {
          Haptics.shared.tap()
          model.toggleRun()
        } label: {
          Label(model.running ? "Stop" : "Run", systemImage: model.running ? "stop.fill" : "play.fill")
            .labelStyle(TransportLabelStyle(iconOnly: compactRow))
            .font(.subheadline.weight(.semibold))
            .frame(minWidth: compactRow ? 44 : nil, minHeight: compactRow ? 44 : 30)
            .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.glassProminent)
        .tint(model.running ? Theme.ionizing : Theme.phosphor)
        .accessibilityLabel(model.running ? "Stop" : "Run")
        .accessibilityHint(model.running ? "Freezes the display." : "Resumes acquisition.")
        .accessibilityIdentifier("scope-run")

        transportButton("Single", symbol: "1.circle", iconOnly: compactRow, hint: "Captures one triggered sweep, then stops.") {
          model.armSingle()
        }
        .accessibilityIdentifier("scope-single")
        transportButton("Auto", symbol: "wand.and.stars", iconOnly: compactRow, hint: "Fits every channel's scale to its signal.") {
          model.autoset()
        }
        .accessibilityIdentifier("scope-autoset")
        Spacer(minLength: 0)
      }
    }
  }

  private func transportButton(_ title: String, symbol: String, iconOnly: Bool, hint: String, action: @escaping () -> Void)
    -> some View
  {
    Button {
      Haptics.shared.tap()
      action()
    } label: {
      Label(title, systemImage: symbol)
        .labelStyle(TransportLabelStyle(iconOnly: iconOnly))
        .font(.subheadline.weight(.semibold))
        .frame(minWidth: iconOnly ? 44 : nil, minHeight: iconOnly ? 44 : 30)
    }
    .buttonStyle(.glass)
    .tint(Theme.phosphor)
    .accessibilityLabel(title)
    .accessibilityHint(hint)
  }

  @ViewBuilder
  private var knobs: some View {
    let options = model.timebaseOptions
    let tbSpec = ScopeKnobs.timebase(options)
    let src = model.settings.trigger.source
    let s = model.scale(src)
    let levelRange = (s.reference - (4 + s.position) * s.unitsPerDiv)...(s.reference + (4 - s.position) * s.unitsPerDiv)
    let levelSpec = ScopeKnobs.level(range: levelRange, unit: model.unit(src), centre: s.reference, tint: model.color(src))
    let specs: [KnobSpec] =
      switch model.settings.mode {
      case .yt: [tbSpec, levelSpec, ScopeKnobs.persistence]
      case .xy: [tbSpec, ScopeKnobs.persistence]
      default: [tbSpec]
      }
    KnobGrid(
      specs: specs,
      value: { spec in
        switch spec.id {
        case "scope-timebase":
          return Binding(
            get: { ScopeKnobs.nearestIndex(model.timebase, in: options) },
            set: { v in
              guard !options.isEmpty else { return }
              model.setTimebase(options[min(options.count - 1, max(0, Int(v.rounded())))])
            })
        case "scope-level":
          return Binding(get: { model.settings.trigger.level }, set: { v in model.mutate { $0.trigger.level = v } })
        default:
          return Binding(
            get: { ScopeKnobs.nearestIndex(model.settings.persistence, in: ScopeKnobs.persistenceSteps) },
            set: { v in
              let steps = ScopeKnobs.persistenceSteps
              model.mutate { $0.persistence = steps[min(steps.count - 1, max(0, Int(v.rounded())))] }
            })
        }
      }, columns: 3)
    .padding(.top, 4)
  }
}

/// 02 PROBES: the ten probe presets with their honest captions.
/// Internal (not private) so the Live tab's Dials sheet can offer the probes while the Scope
/// page shows (integration: scope-review "Dials on the Scope page").
struct ScopeProbesPanel: View {
  let model: ScopeModel
  var number = "02"
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    InstrumentPanel("Probes", number: number) {
      ScrollViewReader { proxy in
        ScrollView(.horizontal) {
          GlassEffectContainer(spacing: 8) {
            HStack(spacing: 8) {
              ForEach(ScopePreset.allCases) { p in
                let selected = model.settings.preset == p
                Button {
                  Haptics.shared.selection()
                  model.applyPreset(p, tapped: true)
                } label: {
                  ChipLabel(number: p.number, title: p.title, symbol: p.symbol)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(selected ? Theme.text : Theme.muted)
                    .padding(.horizontal, 12)
                    .frame(minHeight: 40)
                }
                .buttonStyle(.plain)
                .glassEffect(
                  selected ? .regular.tint(Theme.phosphor.opacity(0.28)).interactive() : .regular.interactive(),
                  in: .rect(cornerRadius: Theme.chipRadius)
                )
                .accessibilityAddTraits(selected ? .isSelected : [])
                .accessibilityIdentifier("scope-preset-\(p.rawValue)")
                .id(p)
              }
            }
            .padding(.horizontal, Theme.panelPadding)
            .padding(.vertical, 4)
          }
        }
        .scrollIndicators(.hidden)
        .padding(.horizontal, -Theme.panelPadding)
        // The chosen probe (from a saved session or "Open in Scope") is scrolled into view.
        .onAppear { if let p = model.settings.preset { proxy.scrollTo(p, anchor: .center) } }
        .onChange(of: model.settings.preset) { _, p in
          if let p { withAnimation(Theme.animation(reduceMotion, .smooth(duration: 0.25))) { proxy.scrollTo(p, anchor: .center) } }
        }
      }
      if let p = model.settings.preset {
        Text(p.caption).panelCaption()
      } else {
        Text("Your own setup. Pick a probe to load streams, mode, timebase, coupling and trigger for a ready-made experiment.")
          .panelCaption()
      }
    }
  }
}

/// 03 MEASUREMENTS: per-channel automatic measurements, cursors, CSV export.
private struct ScopeMeasurementsPanel: View {
  let model: ScopeModel
  var compact = false

  var body: some View {
    let i = model.settings.measureChannel
    let m = model.readout.measurements[i]
    let unit = model.unit(i)
    // Decibel levels: spreads are in dB and "RMS" is the mean power (ScopeEngine.powerMean).
    let logarithmic = ScopeEngine.isLogarithmic(unit)
    let spreadUnit = ScopeEngine.differenceUnit(unit)
    let badge = model.provenance(i).first
    InstrumentPanel("Measurements", number: compact ? "02" : "03", provenance: model.isShown(i) ? model.provenance(i) : []) {
      ScopeChannelChips(
        model: model,
        // Embedded: only the channels that carry a cabled stream.
        selection: Binding(get: { i }, set: { v in model.mutate { $0.measureChannel = v } }), includesMath: !compact,
        onlyShown: compact, id: "scope-measure")
        // Keeps the readouts alive while the display is scrolled away (deduplicated per frame).
        .background { ScopeTicker(model: model, interval: 0.2) }
      if model.isShown(i) {
        ReadoutGrid(columns: compact ? 2 : 3) {
          Readout("Freq · zero x", value: ScopeFormat.frequency(m?.frequencyZeroCrossing), provenance: badge)
          Readout("Freq · FFT", value: ScopeFormat.frequency(m?.frequencyFFT), provenance: badge)
          Readout("Period", value: ScopeFormat.time(m?.period), provenance: badge)
          Readout("Pk-Pk", value: ScopeFormat.value(m?.peakToPeak, unit: spreadUnit), provenance: badge)
          Readout(logarithmic ? "Mean power" : "RMS", value: ScopeFormat.value(m?.rms, unit: unit), provenance: badge)
          Readout("Mean", value: ScopeFormat.value(m?.mean, unit: unit), provenance: badge)
          if !compact {
            Readout(logarithmic ? "Std dev" : "AC RMS", value: ScopeFormat.value(m?.acRMS, unit: spreadUnit), provenance: badge)
            Readout("Min", value: ScopeFormat.value(m?.minimum, unit: unit), provenance: badge)
            Readout("Max", value: ScopeFormat.value(m?.maximum, unit: unit), provenance: badge)
          }
        }
        .accessibilityIdentifier("scope-measurements")
        if m == nil, [.waiting, .single].contains(model.readout.status) {
          // Normal and Single before their first edge: nothing is on screen to measure.
          Text("Waiting for a trigger edge; the measurements follow the first captured sweep.").panelCaption()
        } else {
          Text(
            "\(m?.count ?? 0) samples in the window · \(model.isIrregular(i) ? "irregular stream, no FFT frequency" : "measured \(SpectraFormat.rate(model.readout.rates[i]))")."
          )
          .panelCaption()
        }
      } else {
        Text("This channel is off or waiting for its stream.").panelCaption()
      }
      if !compact, let c = model.cursorReadout {
        let cursorBadge = model.provenance(c.channel).first ?? badge
        ReadoutGrid(columns: 3) {
          if c.dt != nil {
            Readout("Δt", value: ScopeFormat.time(c.dt), color: Theme.text, provenance: cursorBadge)
            Readout("1/Δt", value: ScopeFormat.frequency(c.frequency), color: Theme.text, provenance: cursorBadge)
          }
          if c.dy != nil {
            Readout(
              "ΔY · \(c.channel == 4 ? "M" : "CH\(c.channel + 1)")", value: ScopeFormat.value(c.dy, unit: c.unit), color: Theme.text,
              provenance: cursorBadge)
          }
        }
        .accessibilityIdentifier("scope-cursor-readouts")
      }
      if !compact {
        // One row, or a column at large text sizes.
        ViewThatFits(in: .horizontal) {
          HStack(spacing: 8) {
            exportButton
            addButton(i)
            Spacer(minLength: 0)
          }
          VStack(alignment: .leading, spacing: 8) {
            exportButton
            addButton(i)
          }
        }
        if i == 4 {
          Text("Math is computed by the scope, so it has no stream to add to Patch; add its input channels instead.").panelCaption()
        }
      }
    }
  }

  private var exportButton: some View {
    ShareLink(
      item: model.export,
      preview: SharePreview("Spectra scope window", image: Image(systemName: "waveform.path.ecg"))
    ) {
      // The same metrics as `ActionButton`, so the two buttons in this row match.
      Label("Export CSV", systemImage: "square.and.arrow.up")
        .font(.subheadline.weight(.semibold))
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
        .frame(minWidth: 24, minHeight: 32)
        .padding(.horizontal, 4)
        .padding(.vertical, 6)
    }
    .buttonStyle(.glass)
    .buttonBorderShape(.capsule)
    .tint(Theme.phosphor)
    .disabled(model.export.isEmpty)
    .simultaneousGesture(TapGesture().onEnded { Haptics.shared.tap() })
    .accessibilityHint("Shares the visible window as comma-separated values, one time and value column per channel.")
    .accessibilityIdentifier("scope-export-csv")
  }

  private func addButton(_ i: Int) -> some View {
    ActionButton("Add to Patch", symbol: "point.3.connected.trianglepath.dotted") { model.addToPatch(min(i, 3)) }
      .disabled(i == 4 || !model.isShown(i))
      .accessibilityIdentifier("scope-measure-add-to-patch")
  }
}

/// 04 TRIGGER · CURSORS · DISPLAY.
private struct ScopeTriggerPanel: View {
  let model: ScopeModel

  var body: some View {
    let t = model.settings.trigger
    let mode = model.settings.mode
    InstrumentPanel("Trigger · cursors · display", number: "04") {
      VStack(alignment: .leading, spacing: 10) {
        Eyebrow("Trigger")
        ChoiceChips(
          items: ScopeTriggerMode.allCases,
          selection: Binding(
            get: { t.mode },
            set: { m in
              if m == .single { model.armSingle() } else { model.mutate { $0.trigger.mode = m } }
            }), id: "scope-trigger-mode"
        ) { ChipLabel(title: $0.title) }
        .padding(.horizontal, -Theme.panelPadding)
        ScopeChannelChips(
          model: model, selection: Binding(get: { t.source }, set: { v in model.mutate { s in
            s.trigger.source = v
            s.trigger.level = model.scale(v).reference
          } }), id: "scope-trigger-source")
        ChoiceChips(
          items: ScopeEngine.Slope.allCases,
          selection: Binding(get: { t.slope }, set: { v in model.mutate { $0.trigger.slope = v } }), id: "scope-trigger-slope"
        ) { ChipLabel(title: $0.title, symbol: $0.symbol) }
        .padding(.horizontal, -Theme.panelPadding)
        let sc = model.scale(t.source)
        let levelRange = (sc.reference - (4 + sc.position) * sc.unitsPerDiv)...(sc.reference + (4 - sc.position) * sc.unitsPerDiv)
        KnobGrid(
          specs: [
            ScopeKnobs.level(
              range: levelRange, unit: model.unit(t.source), centre: sc.reference, tint: model.color(t.source), id: "scope-trigger-level"),
            ScopeKnobs.holdoff,
          ],
          value: { spec in
            if spec.id == "scope-trigger-level" {
              return Binding(get: { model.settings.trigger.level }, set: { v in model.mutate { $0.trigger.level = v } })
            }
            return Binding(
              get: { ScopeKnobs.nearestIndex(model.settings.trigger.holdoff, in: ScopeKnobs.holdoffSteps) },
              set: { v in
                let steps = ScopeKnobs.holdoffSteps
                model.mutate { $0.trigger.holdoff = steps[min(steps.count - 1, max(0, Int(v.rounded())))] }
              })
          }, columns: 2)
        if mode != .yt {
          Text("The trigger applies in YT; \(mode.title) runs continuously.").panelCaption()
        }
      }
      VStack(alignment: .leading, spacing: 10) {
        Eyebrow("Cursors")
        ChoiceChips(
          items: ScopeCursorMode.allCases,
          selection: Binding(get: { model.settings.cursors.mode }, set: { v in model.mutate { $0.cursors.mode = v } }),
          id: "scope-cursors"
        ) { ChipLabel(title: $0.title) }
        .padding(.horizontal, -Theme.panelPadding)
        .disabled(!(mode == .yt || mode == .roll))
        if mode == .yt || mode == .roll {
          if model.settings.cursors.mode != .off { cursorKnobs }
        } else {
          Text("Cursors measure YT and Roll traces.").panelCaption()
        }
      }
      VStack(alignment: .leading, spacing: 10) {
        Eyebrow("Display")
        switch mode {
        case .xy:
          Text("X channel").font(.caption).foregroundStyle(Theme.muted)
          ScopeChannelChips(
            model: model, selection: Binding(get: { model.settings.xChannel }, set: { v in model.mutate { $0.xChannel = v } }),
            includesMath: false, id: "scope-x")
          Text("Y channel").font(.caption).foregroundStyle(Theme.muted)
          ScopeChannelChips(
            model: model, selection: Binding(get: { model.settings.yChannel }, set: { v in model.mutate { $0.yChannel = v } }),
            includesMath: false, id: "scope-y")
        case .fft, .spectrogram, .wignerVille, .pseudoWigner:
          Text("Analyzed channel").font(.caption).foregroundStyle(Theme.muted)
          ScopeChannelChips(
            model: model,
            selection: Binding(get: { model.settings.analysisChannel }, set: { v in model.mutate { $0.analysisChannel = v } }),
            id: "scope-analysis")
          if mode == .fft {
            GlassToggle(
              "Logarithmic frequency",
              isOn: Binding(get: { model.settings.logFrequency }, set: { v in model.mutate { $0.logFrequency = v } }),
              symbol: "chart.xyaxis.line")
              .accessibilityIdentifier("scope-log-frequency")
          }
          if mode.isTimeFrequency, let tf = model.timeFrequency {
            ReadoutGrid(columns: 2) {
              Readout("M1 error", value: SpectraFormat.scientific(tf.m1Error, digits: 2), color: Theme.phosphor, provenance: .model)
              Readout(
                "M2 error", value: SpectraFormat.scientific(tf.m2Error, digits: 2),
                color: mode == .wignerVille ? Theme.phosphor : Theme.amber, provenance: .model)
            }
            .accessibilityIdentifier("scope-marginal-errors")
            Text(marginalNote(mode)).panelCaption()
          }
        case .yt, .roll:
          Text("YT and Roll show every enabled channel against time. Tap a channel above to change its source, scale or coupling.")
            .panelCaption()
        }
      }
    }
  }

  private func marginalNote(_ mode: ScopeMode) -> String {
    switch mode {
    case .wignerVille: "Wigner–Ville: the bottom strip is |x(t)|² and the right strip |X(ν)|², both exact up to rounding and the analytic signal's alias."
    case .pseudoWigner: "Pseudo-Wigner: the time strip stays exact; the frequency strip is smoothed by the lag window."
    default: "Spectrogram: both strips are smoothed by the analysis window."
    }
  }

  private var cursorKnobs: some View {
    let c = model.settings.cursors
    let tb = model.timebase
    let s = model.scale(c.channel)
    // The amplitude cursors read an offset from the center line: dB on a dBm channel.
    let unit = ScopeEngine.differenceUnit(model.unit(c.channel))
    var specs: [KnobSpec] = []
    if c.mode.showsTime {
      specs += [ScopeKnobs.cursorTime("t1", title: "t₁", timebase: tb), ScopeKnobs.cursorTime("t2", title: "t₂", timebase: tb)]
    }
    if c.mode.showsAmplitude {
      specs += [
        ScopeKnobs.cursorLevel("y1", title: "y₁", unitsPerDiv: s.unitsPerDiv, unit: unit),
        ScopeKnobs.cursorLevel("y2", title: "y₂", unitsPerDiv: s.unitsPerDiv, unit: unit),
      ]
    }
    return VStack(alignment: .leading, spacing: 8) {
      if c.mode.showsAmplitude {
        ScopeChannelChips(
          model: model, selection: Binding(get: { c.channel }, set: { v in model.mutate { $0.cursors.channel = v } }),
          id: "scope-cursor-channel")
      }
      KnobGrid(
        specs: specs,
        value: { spec in
          Binding(
            get: {
              switch spec.id {
              case "scope-cursor-t1": model.settings.cursors.t1
              case "scope-cursor-t2": model.settings.cursors.t2
              case "scope-cursor-y1": model.settings.cursors.y1
              default: model.settings.cursors.y2
              }
            },
            set: { v in
              model.mutate { s in
                switch spec.id {
                case "scope-cursor-t1": s.cursors.t1 = v
                case "scope-cursor-t2": s.cursors.t2 = v
                case "scope-cursor-y1": s.cursors.y1 = v
                default: s.cursors.y2 = v
                }
              }
            })
        }, columns: 4)
      Text("Drag on the display to move the nearest cursor.").panelCaption()
    }
  }
}

/// DEBUG launch options for screenshots and smoke tests (Release ignores them):
/// `-scopePreset <name>` applies a probe, `-scopeMode <yt|roll|xy|fft|spectrogram|wignerVille|pseudoWigner>`
/// sets the mode, `-scopeCursors <off|time|amplitude|both>` sets the cursors, `-scopeStop` stops
/// after 1.5 s, `-scopeScroll <1…4>` scrolls to a panel, `-scopeSheet <ch1…ch4|math|notes>`
/// opens a sheet, and `-scopeTour <seconds>` steps through probes, modes and panels every few
/// seconds (one launch, many screenshots).
enum ScopeDebug {
  static let panelIDs = ["scope-panel-1", "scope-panel-2", "scope-panel-3", "scope-panel-4"]

  #if DEBUG
    private static func value(_ flag: String) -> String? {
      let args = ProcessInfo.processInfo.arguments
      guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
      return args[i + 1]
    }

    private struct Step {
      var preset: ScopePreset
      var mode: ScopeMode?
      var panel: Int
      var cursors: ScopeCursorMode = .off
      var sheet: ScopeSheet?
    }

    /// The tour, in order: magnetic YT, FFT; sound YT, Wigner–Ville, pseudo-Wigner; compass XY;
    /// Bluetooth roll; spin FID; radio I/Q; vibration measurements with cursors; the trigger
    /// panel; the probes panel.
    private static let tour: [Step] = [
      Step(preset: .magnetic, mode: nil, panel: 0),
      Step(preset: .magnetic, mode: .fft, panel: 0),
      Step(preset: .sound, mode: nil, panel: 0),
      Step(preset: .sound, mode: .wignerVille, panel: 0),
      Step(preset: .sound, mode: .pseudoWigner, panel: 0),
      Step(preset: .compassXY, mode: nil, panel: 0),
      Step(preset: .bluetoothEMF, mode: nil, panel: 0),
      Step(preset: .spinFID, mode: nil, panel: 0),
      Step(preset: .radioIQ, mode: nil, panel: 0),
      Step(preset: .vibration, mode: nil, panel: 2, cursors: .both),
      Step(preset: .vibration, mode: nil, panel: 3, cursors: .both),
      Step(preset: .seismograph, mode: nil, panel: 1),
      Step(preset: .magnetic, mode: nil, panel: 0, sheet: .channel(0)),
      Step(preset: .vibration, mode: nil, panel: 0, sheet: .math),
      Step(preset: .sound, mode: .spectrogram, panel: 0),
      Step(preset: .network, mode: nil, panel: 0),
      Step(preset: .air, mode: nil, panel: 0),
      Step(preset: .lightFlicker, mode: nil, panel: 0),
      Step(preset: .magnetic, mode: nil, panel: 0, sheet: .notes),
    ]

    @MainActor
    static func run(model: ScopeModel, scroll: @escaping (String) -> Void, present: @escaping (ScopeSheet?) -> Void) async {
      // Not a tap: like a probe restored from a saved session, so sensors that ask for
      // permission wait on the display's Start button (the gate screenshot needs this).
      if let name = value("-scopePreset"), let preset = ScopePreset(name: name) { model.applyPreset(preset, tapped: false) }
      if let raw = value("-scopeMode"), let mode = ScopeMode(rawValue: raw) { model.setMode(mode) }
      if let raw = value("-scopeCursors"), let mode = ScopeCursorMode(rawValue: raw) { model.mutate { $0.cursors.mode = mode } }
      if let p = value("-scopeScroll").flatMap(Int.init), (1...4).contains(p) {
        try? await Task.sleep(for: .seconds(1))
        scroll(panelIDs[p - 1])
        // Again once the panels above have grown with their data, so the panel stays on top.
        try? await Task.sleep(for: .seconds(3))
        scroll(panelIDs[p - 1])
      }
      if ProcessInfo.processInfo.arguments.contains("-scopeStop") {
        try? await Task.sleep(for: .seconds(1.5))
        if model.running { model.toggleRun() }
      }
      if let raw = value("-scopeSheet") {
        try? await Task.sleep(for: .seconds(1))
        switch raw.lowercased() {
        case "math": present(.math)
        case "notes": present(.notes)
        case let ch where ch.hasPrefix("ch"):
          if let n = Int(ch.dropFirst(2)), (1...4).contains(n) { present(.channel(n - 1)) }
        default: break
        }
      }
      guard let seconds = value("-scopeTour").flatMap(Double.init), seconds > 0 else { return }
      for step in tour {
        model.applyPreset(step.preset, tapped: true)
        if let mode = step.mode { model.setMode(mode) }
        model.mutate { $0.cursors.mode = step.cursors }
        try? await Task.sleep(for: .milliseconds(300))
        scroll(panelIDs[step.panel])
        if let sheet = step.sheet { present(sheet) }
        try? await Task.sleep(for: .seconds(seconds))
        if step.sheet != nil { present(nil) }
        if Task.isCancelled { return }
      }
    }
  #endif
}

/// Title and icon, or the icon alone (accessibility sizes); the title stays the accessibility label.
private struct TransportLabelStyle: LabelStyle {
  var iconOnly: Bool

  func makeBody(configuration: Configuration) -> some View {
    if iconOnly {
      configuration.icon
    } else {
      HStack(spacing: 6) {
        configuration.icon
        configuration.title.lineLimit(1)
      }
      .fixedSize(horizontal: true, vertical: false)
    }
  }
}
