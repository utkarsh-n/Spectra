import SwiftUI

/// The Spectrum tab (SPEC-features §1, §3c): the web prototype's five instruments, native.
/// Band jump, instrument chips, the numbered instrument panel (Align, full screen), status
/// line, readouts and aux area; Field controls in the Dials sheet.
struct SpectrumTab: View {
  @Environment(AppModel.self) private var app
  @Environment(\.scenePhase) private var scenePhase

  /// The tab's field notes (kept for callers of the stage-1 API).
  static let notes = SpectrumNotes.notes

  var body: some View {
    let model = app.spectrum
    InstrumentScreen(
      tab: .spectrum, subtitle: "Gamma rays to radio", notes: SpectrumNotes.notes, transport: model.transport()
    ) {
      SpectrumFieldSheet()
    } content: {
      SpectrumBandBar()
      SpectrumInstrumentChips()
      SpectrumInstrumentPanel(fullscreen: false)
    }
    .fullScreenCover(isPresented: Binding(get: { model.fullscreen }, set: { model.fullscreen = $0 })) {
      SpectrumFullscreen().environment(app)
    }
    .background { SpectrumHumDriver() }
    .onChange(of: scenePhase) { _, phase in if phase != .active { model.flush() } }
    #if DEBUG
      .modifier(SpectrumSnapshotSheets())
    #endif
  }
}

/// Band jump (γ X UV Vis IR µW Radio): moves the active source to the band's representative
/// wavelength. The segment of the current band is lit in its colour.
struct SpectrumBandBar: View {
  @Environment(AppModel.self) private var app

  var body: some View {
    let model = app.spectrum
    let current = Spectrum.band(at: model.active.lambda)
    GlassSegmented(
      items: Spectrum.bands, selected: current, id: "spectrum-band",
      tint: { BandPalette.color(forWavelength: Spectrum.bandJump[$0.key] ?? 550e-9) }, title: { $0.short },
      accessibilityTitle: { $0.name }
    ) { model.jump(to: $0.key) }
  }
}

/// The five instrument chips (01 Wave scope … 05 Spectroscopy lab).
struct SpectrumInstrumentChips: View {
  @Environment(AppModel.self) private var app

  var body: some View {
    let model = app.spectrum
    ChoiceChips(
      items: SpectraState.Instrument.allCases,
      selection: Binding(get: { model.state.instrument }, set: { model.select($0) }), id: "spectrum-instrument"
    ) { i in
      ChipLabel(number: i.number, title: i.name)
    }
    .padding(.horizontal, -Theme.gutter)
  }
}

/// The numbered instrument panel: detail line, toolbar, stage, status line, readouts and aux.
struct SpectrumInstrumentPanel: View {
  @Environment(AppModel.self) private var app
  @Environment(\.dynamicTypeSize) private var typeSize
  let fullscreen: Bool
  var stageHeight: CGFloat? = nil

  var body: some View {
    let model = app.spectrum
    let inst = model.state.instrument
    let status = model.statusLine
    // At accessibility sizes the title needs the whole header row; Align and Full screen move
    // to the first row of the panel.
    let large = typeSize.isAccessibilitySize
    InstrumentPanel(inst.name, number: inst.number, provenance: provenance(model)) {
      if !large { headerButtons(model) }
    } content: {
      if large { headerButtons(model) }
      Text(inst == .tuner ? "One dial, twenty-one decades" : inst.detail).font(.caption).foregroundStyle(Theme.dim).padding(.top, -8)
      toolbar(inst, model)
      stage(inst, model)
      SpectrumStatusLine(left: status.left, right: status.right, rightColor: status.color)
      SpectrumReadoutGrid(rows: model.readoutRows)
      aux(inst, model)
    }
  }

  private func headerButtons(_ model: SpectrumModel) -> some View {
    HStack(spacing: 6) {
      if model.canAlign {
        SpectrumIconButton(title: "Align", symbol: "viewfinder", id: "spectrum-align", hint: alignHint(model)) {
          model.align()
        }
      }
      if !fullscreen {
        SpectrumIconButton(
          title: "Full screen", symbol: "arrow.up.left.and.arrow.down.right", id: "spectrum-fullscreen",
          hint: "Shows this instrument on its own."
        ) { model.fullscreen = true }
      }
    }
  }

  private func provenance(_ model: SpectrumModel) -> [Provenance] {
    switch model.state.instrument {
    case .bench: return [.table, .model]
    case .lab:
      if model.extras.labEarth { return Provenance.union([.model, model.earthProvenance]) }
      return [Provenance(rawValue: model.state.lab.sample.source.rawValue) ?? .model]
    default: return [.model]
    }
  }

  private func alignHint(_ model: SpectrumModel) -> String {
    switch model.state.instrument {
    case .scope: "Returns the camera to the home view."
    case .tuner: "Shows the web range, 0.1 pm to 1 km."
    case .decompose: model.decomposePage == .phase ? "Recenters the cube and its slices." : "Polarizer back to 30°, a₀ back to 1.5."
    case .lab: "Cursor back to the start of the scan."
    case .bench: ""
    }
  }

  @ViewBuilder private func toolbar(_ inst: SpectraState.Instrument, _ model: SpectrumModel) -> some View {
    switch inst {
    case .scope: WaveScopeToolbar()
    case .tuner: SpectrumTunerToolbar()
    case .bench: SpectrumBenchToolbar()
    case .decompose: SpectrumDecomposeToolbar()
    case .lab: SpectrumLabToolbar()
    }
  }

  @ViewBuilder private func stage(_ inst: SpectraState.Instrument, _ model: SpectrumModel) -> some View {
    switch inst {
    case .scope: WaveScopeStage(height: stageHeight ?? 300)
    case .tuner: SpectrumTunerStage(height: stageHeight ?? 470)
    case .bench: SpectrumBenchStage(height: stageHeight ?? 260)
    case .decompose:
      if model.decomposePage == .phase {
        SpectrumPhaseSpaceStage(cubeHeight: stageHeight.map { max(260, $0 * 0.6) } ?? 260)
      } else {
        SpectrumDecomposeStage(height: stageHeight ?? 300)
      }
    case .lab: SpectrumLabStage(height: stageHeight ?? 260)
    }
  }

  @ViewBuilder private func aux(_ inst: SpectraState.Instrument, _ model: SpectrumModel) -> some View {
    switch inst {
    case .scope: WaveScopeAux()
    case .tuner: SpectrumTunerAux()
    case .bench: SpectrumBenchCards()
    case .decompose:
      if model.decomposePage == .phase { SpectrumPhaseSpaceAux() } else { SpectrumDecomposeAux() }
    case .lab: SpectrumLabAux()
    }
  }
}

/// The full-screen pop-out of the current instrument: its own top bar (Dials · title · ⓘ ⚙ ·
/// Close), the instrument panel with a taller stage, and the transport.
struct SpectrumFullscreen: View {
  @Environment(AppModel.self) private var app
  @State private var sheet: ScreenSheet?

  var body: some View {
    let model = app.spectrum
    GeometryReader { geo in
      VStack(spacing: 0) {
        TopBar(
          title: model.state.instrument.name, subtitle: "Full screen", rootIdentifier: "spectrum-fullscreen-title",
          onDials: { sheet = .dials }, onNotes: { sheet = .notes }, onSettings: { sheet = .settings },
          trailing: [
            TopBarButton(id: "fullscreen-close", title: "Close", symbol: "arrow.down.right.and.arrow.up.left") {
              model.fullscreen = false
            }
          ]
        )
        .padding(.horizontal, Theme.gutter)
        .padding(.vertical, 6)
        ScrollView {
          VStack(alignment: .leading, spacing: Theme.stackSpacing) {
            SpectrumInstrumentPanel(fullscreen: true, stageHeight: max(300, geo.size.height * 0.62))
          }
          .padding(.horizontal, Theme.gutter)
          .padding(.bottom, 28)
        }
        .scrollIndicators(.hidden)
        .accessibilityIdentifier("spectrum-fullscreen-scroll")
      }
    }
    .safeAreaInset(edge: .bottom, spacing: 0) { Transport(config: model.transport()) }
    .background(Theme.background.ignoresSafeArea())
    .sheet(item: $sheet) { which in
      Group {
        switch which {
        case .dials: SpectrumFieldSheet()
        case .notes: FieldNotesSheet(notes: SpectrumNotes.notes)
        case .settings: SettingsSheet()
        }
      }
      .environment(app)
    }
  }
}

/// With Sound on, each enabled source hums at a pitch mapped from its real frequency while
/// the tab is visible and the clock runs (spectra-lab `setTones`).
private struct SpectrumHumDriver: View {
  @Environment(AppModel.self) private var app

  private struct Key: Equatable {
    var sound: Bool
    var playing: Bool
    var tab: AppTab
    var lambdas: [Double]
  }

  var body: some View {
    let model = app.spectrum
    let key = Key(
      sound: app.settings.soundOn, playing: app.clock.playing, tab: app.selectedTab,
      lambdas: model.state.enabledIndices.map { model.state.sources[$0].lambda })
    Color.clear
      .frame(width: 0, height: 0)
      .onChange(of: key, initial: true) { model.updateHums(visible: true) }
      .onDisappear { model.updateHums(visible: false) }
      .accessibilityHidden(true)
  }
}
