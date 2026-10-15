import SwiftUI

/// The Radio tab (RF lab, SPEC-features §2): a page picker (Antenna · Systems · Fourier · Link)
/// over one shared `RadioModel`. Each page is its own view; the Dials sheet carries the visible
/// page's knobs with linear sliders.
struct RadioTab: View {
  @Environment(AppModel.self) private var app
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    let model = app.radio
    InstrumentScreen(
      tab: .radio, subtitle: model.page.subtitle, notes: RadioNotes.notes, transport: transport(model), scrolls: false
    ) {
      RadioDialsSheet(model: model)
    } content: {
      VStack(spacing: 0) {
        Picker("Radio page", selection: pageBinding(model)) {
          ForEach(RadioPage.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.tabs)
        .accessibilityIdentifier("radio-page")
        .padding(.horizontal, Theme.gutter)
        .padding(.bottom, 8)
        ScrollViewReader { proxy in
          ScrollView {
            VStack(alignment: .leading, spacing: Theme.stackSpacing) {
              switch model.page {
              case .antenna: RadioAntennaPage(model: model)
              case .systems: RadioSystemsPage(model: model)
              case .fourier: RadioFourierPage(model: model)
              case .link: RadioLinkPage(model: model)
              }
            }
            .padding(.horizontal, Theme.gutter)
            .padding(.top, 6)
            .padding(.bottom, 28)
            .id(model.page)
          }
          .scrollIndicators(.hidden)
          .accessibilityIdentifier("radio-scroll")
          .onChange(of: model.page) { _, page in proxy.scrollTo(page, anchor: .top) }
          .task(id: model.systemsScrollTarget) { await scrollToSystem(proxy, model) }
        }
      }
      .background {
        if model.page == .fourier { RadioFourierDriver(engine: model.fourierEngine) }
      }
    }
    .onAppear { model.refreshDemand() }
    .onDisappear { model.refreshDemand() }
  }

  /// Scrolls to the Systems card another tab (or `-open radio/systems/<id>`) asked for, once
  /// the page has laid out (twice: the first layout pass can still be settling).
  private func scrollToSystem(_ proxy: ScrollViewProxy, _ model: RadioModel) async {
    guard let target = model.systemsScrollTarget else { return }
    for delay in [300, 450] {
      try? await Task.sleep(for: .milliseconds(delay))
      guard !Task.isCancelled else { return }
      guard model.page == .systems else { break }
      withAnimation(Theme.animation(reduceMotion)) { proxy.scrollTo(RadioSystemsPage.rowID(target), anchor: .center) }
    }
    model.clearSystemsScrollTarget()
  }

  private func pageBinding(_ model: RadioModel) -> Binding<RadioPage> {
    Binding(
      get: { model.page },
      set: { next in
        guard next != model.page else { return }
        Haptics.shared.selection()
        withAnimation(Theme.animation(reduceMotion)) { model.page = next }
      })
  }

  /// The transport appears where something oscillates: the Fourier page (a heterodyned
  /// baseband view of the carrier) and the phased array (its element phases roll κ-slowed).
  private func transport(_ model: RadioModel) -> TransportConfig? {
    switch model.page {
    case .fourier:
      return TransportConfig(
        timeMapping: .heterodyned(fRef: model.carrier), frequency: nil,
        actions: [
          TransportAction(id: "radio-open-scope", title: "Open I/Q in Scope", symbol: "waveform.path.ecg") { model.openInScope() },
          TransportAction(id: "radio-add-patch", title: "Add I/Q to Patch", symbol: "point.3.connected.trianglepath.dotted") {
            model.addToPatch()
          },
          TransportAction(id: "radio-tune-spectrum", title: "Tune Spectrum here", symbol: "waveform") { model.tuneSpectrum() },
        ])
    case .antenna where model.antenna.style == .phasedArray:
      return TransportConfig(
        timeMapping: .slowed(factor: model.carrier / AntennaScene.phaseRollHz), frequency: model.carrier,
        actions: [TransportAction(id: "radio-tune-spectrum", title: "Tune Spectrum here", symbol: "waveform") { model.tuneSpectrum() }])
    default:
      return nil
    }
  }
}

/// The Dials sheet: the visible page's knobs with linear sliders, and Reset dials (that page) /
/// Reset alignment (the 3D view).
struct RadioDialsSheet: View {
  let model: RadioModel

  var body: some View {
    let alignment: (() -> Void)? = model.page == .antenna ? { model.resetAlignment() } : nil
    ControlSheet(
      title: "Radio · \(model.page.title)", resetDials: { model.resetDials() }, resetAlignment: alignment,
      resetDialsHint: "Restore this page's dials to their defaults."
    ) {
      pageDials
    }
  }

  @ViewBuilder
  private var pageDials: some View {
    switch model.page {
    case .antenna: antennaDials
    case .systems: systemsDials
    case .fourier: fourierDials
    case .link: linkDials
    }
  }

  @ViewBuilder
  private var antennaDials: some View {
    let specs = [RadioKnobs.carrier(model)] + RadioKnobs.antenna(model.antenna.style, lambda: model.lambda)
    InstrumentPanel(model.antenna.style.displayName, number: "01", provenance: [.model]) {
      KnobGrid(specs: specs, value: { RadioKnobs.antennaBinding($0, model) }, columns: 2, showsSliders: true)
      SheetCaption("Drag a dial up or right to turn it up, or use the slider underneath. Double-tap a dial to reset it.")
    }
    InstrumentPanel("Aperture phase space", number: "02", provenance: [.model]) {
      KnobGrid(specs: [RadioKnobs.fresnel], value: { _ in fresnelBinding }, columns: 1, showsSliders: true)
    }
  }

  private var fresnelBinding: Binding<Double> {
    Binding(get: { model.fresnelRatio }, set: { model.fresnelRatio = $0 })
  }

  @ViewBuilder
  private var systemsDials: some View {
    InstrumentPanel("Filter", number: "01") {
      ChoiceChips(
        items: RadioSystemFilter.allCases, selection: Binding(get: { model.filter }, set: { model.filter = $0 }),
        id: "radio-dials-filter"
      ) { ChipLabel(title: $0.title) }
      .padding(.horizontal, -Theme.panelPadding)
      GlassToggle(
        "Only radios in this iPhone", isOn: Binding(get: { model.iPhoneOnly }, set: { model.iPhoneOnly = $0 }),
        symbol: "iphone", subtitle: "iPhone 15 Pro Max (A2849)")
      .accessibilityIdentifier("radio-dials-iphone-only")
    }
  }

  @ViewBuilder
  private var fourierDials: some View {
    let analog = RadioModel.isAnalog(model.system.waveform)
    let fading = model.fourier.fading
    // The same enabled states as the page's knob row: Doppler and K do nothing without fading.
    let items: [(KnobSpec, Bool)] = [
      (RadioKnobs.snr(analog: analog), true), (RadioKnobs.delaySpread, true),
      (RadioKnobs.doppler(carrier: model.carrier), fading != .none), (RadioKnobs.ricianK, fading == .rician),
    ]
    InstrumentPanel("Channel", number: "01", provenance: [.model]) {
      RadioKnobRow(items: items, value: { RadioKnobs.fourierBinding($0, model) }, columns: 2, showsSliders: true)
      if fading == .none {
        RadioDisabledReason("Doppler moves fading taps: choose Rayleigh or Rician on the Fourier page to use it.")
      } else if fading != .rician {
        RadioDisabledReason("K is the Rician line-of-sight ratio: choose Rician on the Fourier page to use it.")
      }
    }
  }

  @ViewBuilder
  private var linkDials: some View {
    let usesExponent = model.link.environment == .logDistance
    let items: [(KnobSpec, Bool)] = [
      (RadioKnobs.txPower, true), (RadioKnobs.txGain, true), (RadioKnobs.rxGain, true), (RadioKnobs.distance, true),
      (RadioKnobs.exponent, usesExponent), (RadioKnobs.rain, true), (RadioKnobs.noiseFigure, true),
      (RadioKnobs.bandwidth(model), true),
    ]
    let ble: [(KnobSpec, Bool)] = [(RadioKnobs.bleTxPower, true), (RadioKnobs.bleExponent, true)]
    InstrumentPanel("Budget", number: "01", provenance: [.model]) {
      RadioKnobRow(items: items, value: { RadioKnobs.linkBinding($0, model) }, columns: 2, showsSliders: true)
      if !usesExponent {
        RadioDisabledReason("The exponent belongs to the log-distance model; pick Log-distance on the Link page to use it.")
      }
    }
    InstrumentPanel("Live check", number: "02", provenance: [.model]) {
      RadioKnobRow(items: ble, value: { RadioKnobs.linkBinding($0, model) }, columns: 2, showsSliders: true)
    }
  }
}

/// Advances the Fourier simulation once per display frame while the Fourier page is shown,
/// whichever of its panels is scrolled into view (voice, BER counting and the streams depend
/// on it); 10 Hz while the clock is paused so Step still lands.
struct RadioFourierDriver: View {
  let engine: RadioFourierEngine
  @Environment(AppModel.self) private var app

  /// Seconds between simulated frames: 60 Hz while the clock runs, 30 Hz on Low Power Mode or
  /// when the phone is hot (the Metal scenes' rule, SPEC §3.3), 10 Hz while paused. Without a
  /// cap a ProMotion display would run the simulation and every plot at 120 Hz. The interval is
  /// a little under one frame (1/72 s) so a 60 Hz display never drops to 30 on jitter.
  static func interval(playing: Bool) -> Double {
    guard playing else { return 0.1 }
    return 1 / (1.2 * Double(HoloRenderer.framesPerSecond(maximum: 60)))
  }

  var body: some View {
    TimelineView(.animation(minimumInterval: Self.interval(playing: app.clock.playing), paused: !engine.running)) { _ in
      let _ = engine.advance()
      Color.clear
    }
    .accessibilityHidden(true)
    .allowsHitTesting(false)
  }
}
