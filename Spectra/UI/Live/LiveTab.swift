import SwiftUI

/// The Live tab (SPEC-features §3, §3b): a page picker **Sensors · Scope**. Sensors is the
/// stack of live cards, each running its source only while on screen; Scope hosts the
/// universal oscilloscope and comes forward whenever anything asks to "Open in Scope".
/// `-open live/scope` opens the Scope, `-open live/census` the sensor census,
/// `-open live/turntable` starts the turntable experiment, and `-open live/<card or sensor>`
/// scrolls to that card.
struct LiveTab: View {
  @Environment(AppModel.self) private var app
  @State private var page = LivePageModel()
  @State private var showCensus = false
  @State private var openedPath = false
  @State private var openedPage = false

  var body: some View {
    // The reader wraps the screen so its proxy reaches InstrumentScreen's scroll view.
    ScrollViewReader { proxy in
      screen
        .onAppear { scrollToOpenedCard(proxy) }
    }
    .environment(page)
  }

  private var screen: some View {
    InstrumentScreen(
      tab: .live, subtitle: page.page == .sensors ? "Radios and sensors" : "Oscilloscope",
      notes: LiveNotes.notes,
      // The Scope page has its own Run/Stop/Single and time chip; the Live transport there only
      // repeated (and could contradict) them and covered the display at large text sizes
      // (integration: scope-review).
      transport: page.page == .scope
        ? nil
        : TransportConfig(
          timeMapping: .realTime,
          actions: [TransportAction(id: "live-census", title: "Sensor census", symbol: "list.bullet.rectangle") { showCensus = true }])
    ) {
      LiveDials(page: page)
    } content: {
        VStack(alignment: .leading, spacing: Theme.stackSpacing) {
          Picker("Page", selection: pageBinding) {
            ForEach(LivePage.allCases) { Text($0.title).tag($0) }
          }
          .pickerStyle(.tabs)
          .accessibilityIdentifier("live-page")
          switch page.page {
          case .sensors:
            AntennaMapCard()
            BluetoothCard()
            NetworkCard()
            GNSSCard()
            MagnetometerCard()
            MicrophoneCard()
            LightCard()
            AirCard()
            ChargingCard()
            MotionCard()
            UWBCard()
            NFCCard()
            CensusLink { showCensus = true }
          case .scope:
            ScopeView()
          }
        }
    }
    .sheet(isPresented: $showCensus) {
      NavigationStack {
        LiveCensusView()
          .toolbar {
            ToolbarItem(placement: .confirmationAction) {
              Button("Done") {
                Haptics.shared.tap()
                showCensus = false
              }
              .accessibilityIdentifier("live-census-done")
            }
          }
      }
      .environment(app)
      // A tool sheet (house rule): medium keeps the cards live behind it.
      .presentationDetents([.medium, .large])
      .presentationDragIndicator(.visible)
    }
    .onAppear {
      // Its own flag: the order of this and the scroll reader's onAppear is not guaranteed.
      if app.launch.openTab == .live, page.lastScopeRequest == nil, !openedPage {
        openedPage = true
        switch app.launch.openPath?.lowercased() {
        case "scope": page.page = .scope
        case "census": showCensus = true
        default: break
        }
      }
      followScopeRequest()
      page.tabVisible = app.selectedTab == .live
      page.sync(hub: app.live)
    }
    .onDisappear { page.releaseAll(hub: app.live) }
    .onChange(of: app.selectedTab) { _, tab in
      page.tabVisible = tab == .live
      page.sync(hub: app.live)
    }
    .onChange(of: app.scopeRequest?.id) { followScopeRequest() }
    .onChange(of: page.page) { page.sync(hub: app.live) }
  }

  /// `-open live/<card>` (screenshots, UI tests): keep that card at the top while the cards
  /// above grow as their sensors start.
  private func scrollToOpenedCard(_ proxy: ScrollViewProxy) {
    guard !openedPath else { return }
    openedPath = true
    guard let path = app.launch.openPath?.lowercased() else { return }
    // `turntable` scrolls to Bluetooth and starts the experiment on the strongest radio.
    let turntable = path == "turntable"
    guard let card = turntable ? .bluetooth : LiveCardID(path: path) else { return }
    Task { @MainActor in
      for i in 0..<16 {
        try? await Task.sleep(for: .milliseconds(600))
        let section = turntable && app.live.bluetooth.state.isRunning
        proxy.scrollTo(section ? "live-turntable-section" : card.scrollID, anchor: .top)
        if turntable, i >= 3, !page.turntable.running, let radio = app.live.bluetooth.devices.first {
          page.selectedRadio = radio.id
          page.turntable.start(
            device: radio.id, name: radio.name ?? BLEDeviceTable.anonymousName(id: radio.id, apple: radio.apple), hub: app.live)
        }
      }
    }
  }

  private var pageBinding: Binding<LivePage> {
    Binding(
      get: { page.page },
      set: { next in
        guard next != page.page else { return }
        Haptics.shared.selection()
        page.page = next
      })
  }

  /// Any "Open in Scope" (here or from another tab) brings the Scope page forward.
  private func followScopeRequest() {
    guard let request = app.scopeRequest, request.id != page.lastScopeRequest else { return }
    page.lastScopeRequest = request.id
    page.page = .scope
  }
}

/// The census entry at the bottom of the Sensors page.
private struct CensusLink: View {
  let open: () -> Void

  var body: some View {
    InstrumentPanel("Sensor census", number: "13") {
      Text("Measured rates and the capability flags this iPhone reports, for every source. Run it first on a new device.")
        .panelCaption()
      ActionButton("Open sensor census", symbol: "list.bullet.rectangle", action: open)
        .accessibilityIdentifier("live-census-open")
    }
  }
}

/// The Live tab's dials: which sources may run, and the assumptions the cards use.
struct LiveDials: View {
  let page: LivePageModel
  @Environment(AppModel.self) private var app

  var body: some View {
    ControlSheet(
      title: "Live controls",
      resetDials: {
        app.live.settings.reset()
        app.live.preferencesChanged()
        page.clearPauses(hub: app.live)
      },
      resetDialsHint: "Restore the Live assumptions and let every paused source run again."
    ) {
      if page.page == .scope {
        // On the Scope page the Dials lead with the scope's probes (integration: scope-review).
        ScopeProbesPanel(model: ScopeModel.main, number: "00")
      }
      InstrumentPanel("Sources", number: "01") {
        ForEach(SensorID.allCases) { id in
          let channel = app.live.source(id)
          let locked: Bool = {
            if case .locked = channel.state { return true }
            return false
          }()
          // Switched off in Settings → Sensors: the hub refuses to start it, so this switch
          // cannot either (it reads off, disabled, with where to switch it back on).
          let off = app.live.isSwitchedOff(channel)
          GlassToggle(
            channel.title,
            // A LOCKED or NEEDS PEER source cannot run, so its (disabled) switch reads off.
            isOn: Binding(
              get: { !locked && !off && !page.isPaused(id) },
              set: { on in on ? page.userStart(id, hub: app.live) : page.userStop(id, hub: app.live) }),
            symbol: channel.symbol,
            subtitle: off ? SensorHub.switchedOffReason : channel.state.reason ?? "\(channel.stateLabel) · \(channel.provenance.badge)"
          )
          .disabled(locked || off)
          .accessibilityIdentifier("live-toggle-\(id.rawValue)")
        }
        SheetCaption("A source runs while its card is on screen. Switch one off here to keep it off; starting one that needs permission asks for it now.")
      }
      InstrumentPanel("Assumptions", number: "02", provenance: [.model]) {
        GlassSlider(
          title: "Bluetooth path-loss exponent", value: prefs(\.bleExponent), range: 1.5...6, step: 0.1, color: Theme.amber,
          format: { "n = " + SpectraFormat.significant($0, 2) })
          .accessibilityIdentifier("live-dials-ble-exponent")
        VStack(alignment: .leading, spacing: 6) {
          Text("Wi-Fi band").font(.subheadline)
          ChoiceChips(items: RadioMaps.WiFiBand.allCases, selection: prefs(\.wifiBand), id: "live-dials-wifi-band") { ChipLabel(title: $0.title) }
            .padding(.horizontal, -Theme.gutter)
        }
        KnobGrid(specs: AirKnobs.specs, value: airBinding, columns: 4)
          .padding(.top, 8)
        SheetCaption("No public API reports the Wi-Fi band, air temperature or humidity, so they are your assumptions (MODEL).")
      }
      InstrumentPanel("Census", number: "03") {
        NavigationLink {
          LiveCensusView()
        } label: {
          Label("Sensor census", systemImage: "list.bullet.rectangle")
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        }
        .accessibilityIdentifier("live-dials-census")
      }
    }
  }

  private func prefs<T>(_ key: WritableKeyPath<LivePreferences, T>) -> Binding<T> {
    Binding(get: { app.live.settings.prefs[keyPath: key] }, set: { app.live.settings.prefs[keyPath: key] = $0 })
  }

  private func airBinding(_ spec: KnobSpec) -> Binding<Double> {
    switch spec.id {
    case "live-air-temp": prefs(\.airTemperature)
    case "live-air-humidity": prefs(\.airHumidity)
    case "live-air-gradient": prefs(\.refractivityGradient)
    default: prefs(\.antennaHeight)
    }
  }
}
