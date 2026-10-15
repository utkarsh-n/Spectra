import SwiftUI

/// Radio → Link: a Friis / log-distance / TR 38.901 link budget from the RF engine (power,
/// antenna gains, distance, environment, walls, rain and gas, noise figure, bandwidth →
/// received power, noise floor, SNR, Shannon capacity against the system's peak) drawn as a
/// waterfall chart, and a Live check that compares a nearby Bluetooth device's RSSI with the
/// log-distance model and solves for its distance.
struct RadioLinkPage: View {
  let model: RadioModel
  @Environment(AppModel.self) private var app

  static let bleOwner = "radio.link"

  var body: some View {
    let result = model.linkResult
    Group {
      inputsPanel
      resultPanel(result)
      liveCheckPanel
    }
    .onAppear {
      model.setVisible(.link, true)
      if model.liveCheckWanted { app.live.acquire(.bluetooth, by: Self.bleOwner) }
    }
    .onDisappear {
      model.setVisible(.link, false)
      app.live.release(.bluetooth, by: Self.bleOwner)
    }
  }

  // MARK: 01 Inputs

  private var inputsPanel: some View {
    let s = model.system
    let usesExponent = model.link.environment == .logDistance
    return InstrumentPanel("Budget", number: "01", provenance: [.model]) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Text(s.generation).font(.system(.headline, design: .monospaced)).foregroundStyle(BandPalette.color(forFrequency: model.carrier))
        Text("\(s.name) · \(SpectraFormat.frequency(model.carrier))").font(.subheadline).foregroundStyle(Theme.text)
          .lineLimit(2)
      }
      .accessibilityElement(children: .combine)
      VStack(alignment: .leading, spacing: 6) {
        Text("ENVIRONMENT").font(Theme.readoutTitleFont).foregroundStyle(Theme.muted)
        ChoiceChips(
          items: RadioEnvironment.allCases, selection: Binding(get: { model.link.environment }, set: { model.link.environment = $0 }),
          id: "radio-environment"
        ) { ChipLabel(title: $0.title) }
        .padding(.horizontal, -Theme.panelPadding)
      }
      RadioKnobRow(
        items: [
          (RadioKnobs.txPower, true), (RadioKnobs.txGain, true), (RadioKnobs.rxGain, true), (RadioKnobs.distance, true),
          (RadioKnobs.exponent, usesExponent), (RadioKnobs.rain, true), (RadioKnobs.noiseFigure, true),
          (RadioKnobs.bandwidth(model), true),
        ],
        value: { RadioKnobs.linkBinding($0, model) })
      if !usesExponent {
        RadioDisabledReason("The exponent belongs to the log-distance model; pick Log-distance to use it.")
      }
      VStack(spacing: 4) {
        GlassToggle(
          "Use the antenna's gain", isOn: Binding(get: { model.link.useAntennaGain }, set: { model.link.useAntennaGain = $0 }),
          symbol: "antenna.radiowaves.left.and.right",
          subtitle: "\(model.antenna.style.displayName): \(RadioKnobs.dBi(model.antennaBuild?.model.gainDBi ?? 0)) from the Antenna page")
        .accessibilityIdentifier("radio-use-antenna-gain")
        GlassToggle(
          "Atmospheric gases", isOn: Binding(get: { model.link.gas }, set: { model.link.gas = $0 }), symbol: "wind",
          subtitle: "Oxygen and water vapor (ITU-R P.676); 15 dB/km at 60 GHz")
        .accessibilityIdentifier("radio-gas")
        GlassToggle(
          "Polarization loss", isOn: Binding(get: { model.link.includePLF }, set: { model.link.includePLF = $0 }),
          symbol: "arrow.triangle.2.circlepath",
          subtitle: "From the Antenna page: \(SpectraFormat.decibels(model.plfLossDB, decimals: 1)) against a \(RadioAntennaPage.receiverName(model.reference)) receiver")
        .accessibilityIdentifier("radio-plf")
      }
      wallsEditor
      if model.link.bandwidth != nil {
        Button {
          Haptics.shared.tap()
          model.link.bandwidth = nil
        } label: {
          Label(
            s.maxChannelWidth == nil ? "Use \(s.generation)'s default bandwidth" : "Use \(s.generation)'s channel width",
            systemImage: "arrow.counterclockwise"
          )
          .font(.subheadline.weight(.semibold))
            .frame(minHeight: 32)
        }
        .buttonStyle(.glass)
        .accessibilityIdentifier("radio-bandwidth-system")
      }
    }
  }

  private var wallsEditor: some View {
    let fGHz = model.carrier / 1e9
    return VStack(alignment: .leading, spacing: 6) {
      Text("WALLS CROSSED").font(Theme.readoutTitleFont).foregroundStyle(Theme.muted)
      ForEach(RF.Building.Material.allCases) { m in
        let n = model.link.walls[m.rawValue] ?? 0
        HStack(spacing: 10) {
          VStack(alignment: .leading, spacing: 1) {
            Text(m.displayName).font(.subheadline).foregroundStyle(Theme.text)
            Text("\(SpectraFormat.decibels(m.lossDB(frequencyGHz: fGHz), decimals: 1)) each at \(SpectraFormat.frequency(model.carrier))")
              .font(.caption2).foregroundStyle(Theme.muted)
          }
          Spacer(minLength: 4)
          stepButton("minus", id: "radio-wall-\(m.rawValue)-minus", label: "Fewer \(m.displayName) walls", enabled: n > 0) {
            setWalls(m, n - 1)
          }
          Text("\(n)").font(Theme.readoutValueFont).monospacedDigit().foregroundStyle(Theme.amber).frame(minWidth: 22)
            .accessibilityLabel("\(n) \(m.displayName) walls")
          stepButton("plus", id: "radio-wall-\(m.rawValue)-plus", label: "More \(m.displayName) walls", enabled: n < 8) {
            setWalls(m, n + 1)
          }
        }
      }
      Text("Penetration losses from 3GPP TR 38.901 (Table 7.4.3-1); they grow with frequency.").panelCaption()
    }
  }

  private func setWalls(_ m: RF.Building.Material, _ n: Int) {
    var l = model.link
    l.walls[m.rawValue] = max(0, min(8, n))
    model.link = l
  }

  private func stepButton(_ symbol: String, id: String, label: String, enabled: Bool, action: @escaping () -> Void) -> some View {
    Button {
      Haptics.shared.tick()
      action()
    } label: {
      Image(systemName: symbol).frame(width: 22, height: 22)
    }
    .buttonStyle(.glass)
    .buttonBorderShape(.circle)
    .disabled(!enabled)
    .accessibilityLabel(label)
    .accessibilityIdentifier(id)
  }

  // MARK: 02 Result

  private func resultPanel(_ r: RF.LinkBudgetResult) -> some View {
    let peak = model.system.peakRate
    return InstrumentPanel("Result", number: "02", provenance: [.model]) {
      ReadoutGrid(columns: 3) {
        Readout("Received", value: SpectraFormat.decibels(r.receivedPowerDBm, unit: "dBm"), color: Theme.amber, provenance: .model)
        Readout("Noise floor", value: SpectraFormat.decibels(r.noiseFloorDBm, unit: "dBm"), color: Theme.text, provenance: .model)
        Readout("SNR", value: SpectraFormat.decibels(r.snrDB), color: r.snrDB > 0 ? Theme.phosphor : Theme.amber, provenance: .model)
        Readout("Shannon", value: RF.Units.format(bitRate: r.capacity), color: Theme.phosphor, provenance: .model)
        Readout("System peak", value: peak.map { RF.Units.format(bitRate: $0.value) } ?? "—", provenance: peak?.basis == .table ? .table : .model)
        Readout("Of peak", value: r.capacityToPeak.map { "\(SpectraFormat.significant($0 * 100, 3)) %" } ?? "—", provenance: .model)
        Readout("EIRP", value: SpectraFormat.decibels(r.eirpDBm, unit: "dBm"), provenance: .model)
        Readout("Path loss", value: SpectraFormat.decibels(r.pathLossDB), provenance: .model)
        Readout("Free space", value: SpectraFormat.decibels(r.freeSpaceLossDB), provenance: .model)
      }
      if let c = r.capacityToPeak, c.isFinite {
        VStack(alignment: .leading, spacing: 4) {
          LevelMeter(level: min(1, c), color: Theme.phosphor)
          Text("Shannon capacity in \(SpectraFormat.frequency(model.linkBandwidth)) against \(model.system.generation)'s peak rate")
            .font(.caption2).foregroundStyle(Theme.muted)
        }
      }
      RadioBudgetChart(
        terms: r.terms, received: r.receivedPowerDBm, noiseFloor: r.noiseFloorDBm, pathModelName: model.linkInput.model.displayName)
        .accessibilityIdentifier("radio-budget-chart")
      Text("Each bar moves the level: gains up (green), losses down (rose), ending at the received power. The dashed white line is the noise floor −174 dBm/Hz + 10·log B + NF; the gap is the SNR.")
        .panelCaption()
      ForEach(Array(r.notes.enumerated()), id: \.offset) { _, note in
        Label(RadioCopy.us(note), systemImage: "info.circle").font(.caption).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
      }
      if model.linkBandwidthIsPlaceholder {
        Label(
          "\(model.system.name) lists no channel width yet, so the noise bandwidth is the Fourier page's placeholder waveform (\(SpectraFormat.frequency(model.linkBandwidth))). Turn the Bandwidth knob to try others.",
          systemImage: "info.circle"
        )
        .font(.caption).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
      } else if model.link.bandwidth == nil, model.linkBandwidth <= 0 {
        Label(
          "\(model.system.name) is an unmodulated carrier (CW): in zero bandwidth the noise floor is −∞ and the Shannon capacity 0. Turn the Bandwidth knob to give the receiver a bandwidth.",
          systemImage: "info.circle"
        )
        .font(.caption).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
      }
      if model.link.distance > 100_000, model.link.rainRate > 0 || model.link.gas {
        Label("A path this long leaves the atmosphere: rain and gas act over its lowest \(RF.Units.format(distance: RadioModel.atmosphereThickness)).", systemImage: "info.circle")
          .font(.caption).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  // MARK: 03 Live check

  private var liveCheckPanel: some View {
    let channel = app.live.channel(.bluetooth)
    return InstrumentPanel("Live check", number: "03", provenance: [channel.provenance, .model, .inferred]) {
      PermissionGate(
        title: "Bluetooth", symbol: "dot.radiowaves.left.and.right", state: channel.state, startTitle: "Start Bluetooth",
        explanation: "Spectra listens for nearby Bluetooth radios to compare their signal strength with the model. Nothing is stored or sent.",
        start: {
          model.liveCheckWanted = true
          app.live.acquire(.bluetooth, by: Self.bleOwner)
        }
      ) {
        VisibleTimeline(minimumInterval: 0.25) { _ in liveContent(channel) }
      }
      RadioKnobRow(
        items: [(RadioKnobs.bleTxPower, true), (RadioKnobs.bleExponent, true)], value: { RadioKnobs.linkBinding($0, model) })
      Text("RSSI is the 2-second mean of the device's advertisements. Log-distance model at 2.44 GHz: RSSI(d) = Pₜ − FSPL(1 m) − 10·n·log₁₀(d / 1 m), with FSPL(1 m) = 40.2 dB. Solving it for the measured RSSI gives the distance; walls, bodies and the phone's own antenna pattern move the answer by meters, so it is an estimate.")
        .panelCaption()
    }
  }

  private struct Device: Identifiable {
    let id: String
    let name: String
    let stream: SignalStream
    let mean: Double?
    let latest: Double?
  }

  private func devices(_ channel: any SensorChannel) -> [Device] {
    let now = SignalClock.now()
    return channel.streams.filter { $0.id.rawValue.hasPrefix("ble.") }.map { s in
      let snap = s.ring.snapshot(since: now - 2)
      let mean = snap.values.isEmpty ? nil : Double(snap.values.reduce(0, +)) / Double(snap.values.count)
      let name = s.label.hasSuffix(" RSSI") ? String(s.label.dropLast(5)) : s.label
      return Device(id: s.id.rawValue, name: name, stream: s, mean: mean, latest: s.ring.latest.map { Double($0.value) })
    }
    .sorted { ($0.mean ?? -200) > ($1.mean ?? -200) }
  }

  @ViewBuilder
  private func liveContent(_ channel: any SensorChannel) -> some View {
    let list = devices(channel)
    if list.isEmpty {
      ContentUnavailableView("Listening…", systemImage: "dot.radiowaves.left.and.right", description: Text("No Bluetooth advertisers heard yet."))
    } else {
      let selected = list.first { $0.id == model.link.bleDevice } ?? list[0]
      ScrollView(.horizontal) {
        HStack(spacing: 8) {
          ForEach(list.prefix(10)) { d in
            let on = d.id == selected.id
            Button {
              Haptics.shared.selection()
              model.link.bleDevice = d.id
            } label: {
              VStack(alignment: .leading, spacing: 1) {
                Text(d.name).font(.caption.weight(.semibold)).foregroundStyle(on ? Theme.text : Theme.muted).lineLimit(1)
                Text(d.mean.map { SpectraFormat.decibels($0, unit: "dBm", decimals: 0) } ?? "—").font(.caption2.monospacedDigit())
                  .foregroundStyle(Theme.amber)
              }
              .padding(.horizontal, 10)
              .frame(minHeight: 40)
            }
            .buttonStyle(.plain)
            .glassEffect(on ? .regular.tint(Theme.phosphor.opacity(0.28)).interactive() : .regular.interactive(), in: .rect(cornerRadius: Theme.chipRadius))
            .accessibilityAddTraits(on ? .isSelected : [])
            .accessibilityIdentifier("radio-ble-\(d.name)")
          }
        }
        .padding(.vertical, 2)
      }
      .scrollIndicators(.hidden)
      let input = model.bleInput
      let solved = selected.mean.flatMap { RF.LinkBudget.distance(forReceivedPower: $0, input: input) }
      let distances = (0..<48).map { 0.1 * pow(300, Double($0) / 47) }
      let curve = distances.map { d -> Double in
        var x = input
        x.distance = d
        return RF.LinkBudget.evaluate(x).receivedPowerDBm
      }
      let atOneMetre: Double = {
        var x = input
        x.distance = 1
        return RF.LinkBudget.evaluate(x).receivedPowerDBm
      }()
      PlotWell(height: 160, grid: 0) {
        RadioRSSIPlot(model: curve, distances: distances, liveRSSI: selected.mean, solved: solved, color: Theme.phosphor)
          .accessibilityIdentifier("radio-rssi-plot")
          .padding(.horizontal, 4)
      }
      ReadoutGrid(columns: 3) {
        Readout("RSSI", value: selected.mean.map { SpectraFormat.decibels($0, unit: "dBm") } ?? "—", color: Theme.phosphor, provenance: channel.provenance)
        Readout("Model 1 m", value: SpectraFormat.decibels(atOneMetre, unit: "dBm"), provenance: .model)
        Readout("Distance", value: solved.map { RF.Units.format(distance: $0) } ?? "—", color: Theme.amber, provenance: .inferred)
      }
      let history = StreamWindow.read(selected.stream, seconds: 20, maxPoints: 200).values
      Sparkline(values: history, color: Theme.phosphor, steps: true)
        .frame(height: 36)
        .accessibilityLabel("RSSI over the last 20 seconds")
    }
  }
}
