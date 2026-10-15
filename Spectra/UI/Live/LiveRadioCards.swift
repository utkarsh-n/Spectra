import SwiftUI

// MARK: - 01 Your iPhone's antennas

/// A schematic of the iPhone 15 Pro Max with its antenna segments (general placement, MODEL)
/// and the list of its radios (bands from the RF catalog, TABLE). Tapping a radio puts its band
/// on the strip.
struct AntennaMapCard: View {
  @Environment(AppModel.self) private var app

  var body: some View {
    let radios = RadioMaps.phoneRadios
    let selected = app.live.highlightedRadio
    LiveCard(
      .antennas, badges: [.model, .table],
      actions: LiveCardActions(marker: selected.map(marker))
    ) {
      AdaptiveStack {
        PlotWell(height: 230, grid: 0) {
          PhoneOutline(radios: radios, selected: selected?.id)
            .padding(.vertical, 14)
        }
        .sideWidth(128)
        VStack(alignment: .leading, spacing: 4) {
          ForEach(radios) { radio in
            RadioRow(radio: radio, selected: radio.id == selected?.id) { toggle(radio) }
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      Text(
        selected.map { "\($0.title): \($0.bands). \($0.note)" }
          ?? "Tap a radio to light up its band on the strip. The outline is a schematic: antenna placement is general, not a teardown."
      )
      .panelCaption()
    }
  }

  private func marker(_ r: RadioMaps.PhoneRadio) -> SpectrumMarker {
    SpectrumMarker(id: "live.antenna", label: "Your iPhone: \(r.title)", frequency: r.frequency, provenance: .table, tab: .live)
  }

  private func toggle(_ radio: RadioMaps.PhoneRadio) {
    Haptics.shared.selection()
    if app.live.highlightedRadio?.id == radio.id {
      app.live.highlightedRadio = nil
      app.focusedMarker = nil
    } else {
      app.live.highlightedRadio = radio
      app.focusedMarker = marker(radio)
    }
  }
}

private struct RadioRow: View {
  let radio: RadioMaps.PhoneRadio
  let selected: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 8) {
        Circle().fill(BandPalette.color(forFrequency: radio.frequency)).frame(width: 7, height: 7)
        VStack(alignment: .leading, spacing: 1) {
          Text(radio.title).font(.caption.weight(.semibold)).foregroundStyle(selected ? Theme.text : Theme.muted)
          Text(radio.bands).font(.system(.caption2, design: .monospaced)).foregroundStyle(Theme.dim).lineLimit(2)
        }
        Spacer(minLength: 0)
      }
      .padding(.vertical, 3)
      .padding(.horizontal, 6)
      .frame(minHeight: 36)
      .background(selected ? Theme.phosphor.opacity(0.10) : .clear, in: .rect(cornerRadius: 8))
      .contentShape(.rect)
    }
    .buttonStyle(.plain)
    .accessibilityLabel("\(radio.title), \(radio.bands)")
    .accessibilityAddTraits(selected ? .isSelected : [])
    .accessibilityHint("Shows its band on the spectrum strip.")
    .accessibilityIdentifier("live-antenna-\(radio.id)")
  }
}

/// The phone's outline (77.6 × 159.9 mm, rounded) with rail segments and internal spots.
private struct PhoneOutline: View {
  let radios: [RadioMaps.PhoneRadio]
  let selected: String?

  var body: some View {
    Canvas { ctx, size in
      let aspect = 77.6 / 159.9
      let h = size.height - 18
      let w = min(size.width - 16, h * aspect)
      let rect = CGRect(x: (size.width - w) / 2, y: 0, width: w, height: h)
      let body = Path(roundedRect: rect, cornerRadius: w * 0.17)
      ctx.stroke(body, with: .color(Theme.muted.opacity(0.55)), lineWidth: 1.2)
      // Camera plateau (back view, top left).
      let cam = CGRect(x: rect.minX + w * 0.08, y: rect.minY + w * 0.08, width: w * 0.46, height: w * 0.46)
      ctx.stroke(Path(roundedRect: cam, cornerRadius: w * 0.1), with: .color(Theme.dim.opacity(0.6)), lineWidth: 0.8)
      func point(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: rect.minX + w * x, y: rect.minY + h * y) }
      for radio in radios {
        let isSel = radio.id == selected
        let color = BandPalette.color(forFrequency: radio.frequency)
        let alpha = selected == nil || isSel ? 1.0 : 0.25
        for s in radio.segments {
          var p = Path()
          p.move(to: point(s.x, s.y))
          p.addLine(to: point(s.z, s.w))
          ctx.phosphorStroke(p, color: color.opacity(alpha), width: isSel ? 3 : 2, glow: isSel ? 1.4 : 0.6)
        }
        if let spot = radio.spot {
          let c = point(spot.x, spot.y)
          let r = w * spot.z
          ctx.phosphorStroke(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)), color: color.opacity(alpha), width: isSel ? 2 : 1.2, glow: isSel ? 1.2 : 0.5)
        }
      }
      ctx.annotation("BACK · SCHEMATIC", at: CGPoint(x: size.width / 2, y: size.height - 5), color: Theme.dim)
    }
    .accessibilityElement()
    .accessibilityLabel("Schematic of the iPhone 15 Pro Max back with its antennas")
    .accessibilityValue(selected.map { "Highlighted: \($0)" } ?? "No radio highlighted")
  }
}

// MARK: - 02 Bluetooth

/// Live BLE advertisers: list with RSSI sparklines, Tx power and a log-distance estimate,
/// a radar of estimated distances, and the turntable experiment.
struct BluetoothCard: View {
  @Environment(AppModel.self) private var app
  @Environment(LivePageModel.self) private var page

  var body: some View {
    let ble = app.live.bluetooth
    let devices = Array(ble.devices.prefix(8))
    let n = app.live.settings.prefs.bleExponent
    let selected = devices.first { $0.id == page.selectedRadio } ?? devices.first
    let strongest = Array(ble.devices.prefix(3)).map { LiveStreams.bleRSSI($0.id) }
    LiveCard(
      .bluetooth, badges: [.model], startTitle: "Listen for radios",
      explanation: "Spectra listens to Bluetooth LE advertisements to show each radio's signal strength. Nothing is stored or sent.",
      actions: LiveCardActions(
        marker: ble.markers.first, scope: strongest + [LiveStreams.magNorm.id], preset: "Bluetooth / EMF",
        patch: selected.map { (LiveStreams.bleRSSI($0.id), ($0.name ?? BLEDeviceTable.anonymousName(id: $0.id, apple: $0.apple)) + " RSSI") })
    ) {
      ReadoutGrid(columns: 3) {
        Readout("Radios", value: "\(ble.devices.count)", provenance: ble.provenance)
        Readout("Strongest", value: devices.first.map { "\(liveWhole($0.lastRSSI)) dBm" } ?? "—", provenance: ble.provenance)
        Readout("Adverts/s", value: liveValue(ble.advertRate, 2), provenance: ble.provenance)
      }
      PlotWell(height: 190, grid: 0) {
        RadarView(devices: devices, exponent: n, selected: selected?.id)
      }
      VStack(spacing: 2) {
        ForEach(Array(devices.enumerated()), id: \.element.id) { index, d in
          BLERow(device: d, exponent: n, selected: d.id == selected?.id, index: index) {
            Haptics.shared.selection()
            page.selectedRadio = d.id
          }
        }
      }
      if devices.isEmpty {
        Text("No advertisements yet. Most phones, watches, earbuds and laptops advertise every 20 ms to 1 s.").panelCaption()
      }
      GlassSlider(
        title: "Path-loss exponent n", value: exponentBinding, range: 1.5...6, step: 0.1, color: Theme.amber,
        format: { "n = " + SpectraFormat.significant($0, 2) })
        .accessibilityIdentifier("live-ble-exponent")
      Text(
        "Distance is a log-distance MODEL on the averaged RSSI: RSSI(1 m) = Tx − 40.2 dB at 2.44 GHz (0 dBm assumed when a radio does not advertise Tx), then 10·n dB per decade. Fading moves RSSI by ±5–10 dB, so treat it as a rough guess. Adverts hop across channels 37, 38 and 39 (2402, 2426 and 2480 MHz, λ ≈ 12.4 cm). The radar angle only spreads the dots; Bluetooth does not give a direction."
      )
      .panelCaption()
      TurntableSection(device: selected)
    }
  }

  private var exponentBinding: Binding<Double> {
    Binding(get: { app.live.settings.prefs.bleExponent }, set: { app.live.settings.prefs.bleExponent = $0 })
  }
}

private struct BLERow: View {
  let device: BLEDeviceTable.Device
  let exponent: Double
  let selected: Bool
  let index: Int
  let action: () -> Void

  var body: some View {
    let name = device.name ?? BLEDeviceTable.anonymousName(id: device.id, apple: device.apple)
    // Distance from the averaged RSSI: one faded advert can be 10 dB off.
    let d = RadioMaps.bleDistance(rssi: device.averageRSSI, txPower: device.txPower, exponent: exponent)
    Button(action: action) {
      AdaptiveStack(spacing: 10) {
        VStack(alignment: .leading, spacing: 1) {
          Text(name).font(.caption.weight(.semibold)).foregroundStyle(selected ? Theme.text : Theme.muted).lineLimit(1)
          Text(
            "≈ \(SpectraFormat.significant(d, 2)) m" + (device.txPower.map { " · Tx \(liveWhole($0)) dBm" } ?? "")
              + (device.connectable ? " · connectable" : ""))
            .font(.system(.caption2, design: .monospaced)).foregroundStyle(Theme.dim).lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
        }
        Spacer(minLength: 4)
        HStack(spacing: 10) {
          StreamSparkline(stream: device.stream, seconds: 20)
            .frame(width: 84, height: 26)
          // An EM reading wears its band's hue (rule R2); amber is for non-EM signals.
          Text(liveWhole(device.lastRSSI))
            .font(.system(.callout, design: .monospaced).weight(.medium))
            .monospacedDigit()
            .foregroundStyle(BandPalette.color(forFrequency: RadioMaps.bleCarrier))
            .fixedSize()
        }
      }
      .padding(.horizontal, 8)
      .padding(.vertical, 4)
      .frame(minHeight: 44)
      .background(selected ? Theme.phosphor.opacity(0.10) : .clear, in: .rect(cornerRadius: 10))
      .contentShape(.rect)
    }
    .buttonStyle(.plain)
    .accessibilityLabel("\(name), \(liveWhole(device.lastRSSI)) dBm, about \(SpectraFormat.significant(d, 2)) meters")
    .accessibilityAddTraits(selected ? .isSelected : [])
    .accessibilityIdentifier("live-ble-device-\(index)")
  }
}

/// Estimated distances as a radar (log rings at 1, 3 and 10 m). Angles are arbitrary.
private struct RadarView: View {
  let devices: [BLEDeviceTable.Device]
  let exponent: Double
  let selected: UUID?

  var body: some View {
    Canvas { ctx, size in
      let c = CGPoint(x: size.width / 2, y: size.height / 2)
      let radius = min(size.width, size.height) / 2 - 14
      // Log radius: 0.3 m at the centre … 30 m at the edge.
      func r(_ d: Double) -> CGFloat { radius * CGFloat(min(1, max(0, (log10(max(d, 0.3)) + 0.523) / 2))) }
      for (d, label) in [(1.0, "1 m"), (3.0, "3 m"), (10.0, "10 m"), (30.0, "30 m")] {
        let rr = r(d)
        ctx.stroke(Path(ellipseIn: CGRect(x: c.x - rr, y: c.y - rr, width: 2 * rr, height: 2 * rr)), with: .color(Theme.phosphor.opacity(0.1)), lineWidth: 0.7)
        ctx.annotation(label, at: CGPoint(x: c.x + rr * 0.71 + 3, y: c.y - rr * 0.71 - 3), anchor: .bottomLeading)
      }
      ctx.phosphorDot(at: c, color: Theme.text, radius: 2.5)
      let color = BandPalette.color(forFrequency: RadioMaps.bleCarrier)
      for d in devices {
        let dist = RadioMaps.bleDistance(rssi: d.averageRSSI, txPower: d.txPower, exponent: exponent)
        let bytes = withUnsafeBytes(of: d.id.uuid) { Array($0) }
        let angle = Double(Int(bytes[0]) << 8 | Int(bytes[1])) / 65_536 * 2 * .pi
        let p = CGPoint(x: c.x + r(dist) * CGFloat(sin(angle)), y: c.y - r(dist) * CGFloat(cos(angle)))
        let isSel = d.id == selected
        // Selection is brightness and size, not another hue: every dot is the same 2.44 GHz.
        ctx.phosphorDot(at: p, color: isSel ? Theme.text : color, radius: isSel ? 4 : 3)
        if isSel {
          ctx.annotation(
            d.name ?? BLEDeviceTable.anonymousName(id: d.id, apple: d.apple), at: CGPoint(x: p.x + 7, y: p.y), anchor: .leading,
            color: Theme.text)
        }
      }
    }
    .accessibilityElement()
    .accessibilityLabel("Bluetooth radar")
    .accessibilityValue("\(devices.count) radios. Distance from the center is the log-distance estimate; the angle is arbitrary.")
  }
}

/// The turntable experiment (gyre-integration §4.2): RSSI binned by yaw against the λ/2
/// dipole MODEL, with the fading statistics that decide whether the pattern shows at all.
private struct TurntableSection: View {
  let device: BLEDeviceTable.Device?
  @Environment(AppModel.self) private var app
  @Environment(LivePageModel.self) private var page

  var body: some View {
    let t = page.turntable
    let b = t.binner
    VStack(alignment: .leading, spacing: 12) {
      Eyebrow("Turntable experiment", color: Theme.amber)
      Text(
        t.running
          ? "Lay the phone flat and turn it slowly, at least three full turns, keeping \(t.deviceName ?? "the radio") still."
          : "Measure your phone's own antenna pattern against one radio: lay the phone flat on a lazy Susan or a table and turn it through at least three turns."
      )
      .panelCaption()
      HStack(spacing: 10) {
        ActionButton(t.running ? "Stop" : "Start turntable", symbol: t.running ? "stop.fill" : "arrow.triangle.2.circlepath", prominent: !t.running) {
          if t.running {
            t.stop(hub: app.live)
          } else if let device {
            t.start(device: device.id, name: device.name ?? BLEDeviceTable.anonymousName(id: device.id, apple: device.apple), hub: app.live)
          }
        }
        .disabled(!t.running && device == nil)
        .accessibilityIdentifier("live-turntable")
        if t.running || b.sampleCount > 0 {
          ActionButton("Clear", symbol: "arrow.counterclockwise") { t.reset() }
            .accessibilityIdentifier("live-turntable-clear")
        }
      }
      if device == nil, !t.running {
        Text("Needs a radio: wait for one to appear in the list above.").font(.caption).foregroundStyle(Theme.dim)
      }
      if t.running || b.sampleCount > 0 {
        let stats = b.statistics
        let means = stats.map { $0?.mean }
        let peak = means.compactMap { $0 }.max() ?? 0
        // Relative to the strongest bin; nil where a bin has too few adverts to have a mean.
        let measured = means.map { m in m.map { $0 - peak } }
        let ftb = b.frontToBack
        let model = YawBinner.modelPattern(peakYaw: ftb?.frontYaw ?? 0)
        AdaptiveStack(spacing: 12) {
          PlotWell(height: 170, grid: 0) {
            TurntablePolar(measured: measured, model: model, color: BandPalette.color(forFrequency: RadioMaps.bleCarrier))
          }
          VStack(alignment: .leading, spacing: 8) {
            Readout("Turns", value: SpectraFormat.significant(b.turns, 2), provenance: app.live.motion.provenance)
            // Statistics of the measured adverts: they carry the Bluetooth source's badge (R4).
            let rssi = app.live.bluetooth.provenance
            Readout("Bins ≥ 8", value: "\(b.filledBins)/\(YawBinner.binCount)", provenance: rssi)
            Readout("Front/back", value: ftb.map { "\(SpectraFormat.significant($0.decibels, 2)) ± \(SpectraFormat.significant($0.sigma, 1)) dB" } ?? "—", provenance: rssi)
            Readout("Mean σ", value: b.meanDeviation.map { "\(SpectraFormat.significant($0, 2)) dB" } ?? "—", provenance: rssi)
          }
          .sideWidth(128)
        }
        Text(verdict(b)).panelCaption()
      }
    }
    .padding(.top, 4)
    .id("live-turntable-section")
  }

  private func verdict(_ b: YawBinner) -> String {
    let rayleigh = SpectraFormat.significant(TurntableStatistics.rayleighDecibelSpread, 3)
    guard b.meanDeviation != nil else { return "Solid line: measured mean per 10° bin (gaps where a bin has no adverts yet). Dashed: a λ/2 dipole along the phone, aligned to the strongest bin (MODEL)." }
    if b.isFadingDominated {
      return "The spread in each bin is about the \(rayleigh) dB of pure Rayleigh fading, so the shape here is mostly multipath, not the antenna. Move to a more open space or average more turns."
    }
    return b.isComplete
      ? "Every bin has enough adverts and the spread is below Rayleigh's \(rayleigh) dB: the measured shape says something about the antenna and your hand. Dashed: the λ/2 dipole MODEL."
      : "Keep turning: each 10° bin needs at least 8 adverts over three turns before the pattern is worth reading."
  }
}

/// The turntable result on polar axes (yaw clockwise from the top, 0 dB at the rim, −20 dB at
/// the centre): the measured mean of each 10° bin relative to the strongest, drawn only where
/// the bin has adverts, against the dashed λ/2 dipole MODEL. An empty bin leaves a gap: drawn
/// at the floor it would look like a deep antenna null that was never measured.
private struct TurntablePolar: View {
  let measured: [Double?]
  let model: [Double]
  let color: Color
  nonisolated static let floor = -20.0

  var body: some View {
    Canvas { ctx, size in
      let n = measured.count
      guard n > 2 else { return }
      let radius = min(size.width, size.height) / 2 - 24
      let c = CGPoint(x: size.width / 2, y: size.height / 2)
      func point(_ i: Int, _ db: Double) -> CGPoint {
        let r = radius * CGFloat(max(0, 1 - max(db, Self.floor) / Self.floor))
        let a = YawBinner.centre(of: i) * .pi / 180
        return CGPoint(x: c.x + r * CGFloat(sin(a)), y: c.y - r * CGFloat(cos(a)))
      }
      var grid = Path()
      for ring in [0.0, -10] {
        let r = radius * CGFloat(1 - ring / Self.floor)
        grid.addEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
      }
      for k in 0..<12 {
        let a = Double(k) * .pi / 6
        grid.move(to: c)
        grid.addLine(to: CGPoint(x: c.x + radius * CGFloat(sin(a)), y: c.y - radius * CGFloat(cos(a))))
      }
      ctx.stroke(grid, with: .color(Theme.phosphor.opacity(0.09)), lineWidth: 0.6)
      for deg in [0, 90, 180, 270] {
        let a = Double(deg) * .pi / 180
        ctx.annotation("\(deg)°", at: CGPoint(x: c.x + (radius + 13) * CGFloat(sin(a)), y: c.y - (radius + 10) * CGFloat(cos(a))))
      }
      ctx.annotation(SpectraFormat.decibels(-10, unit: "dB", decimals: 0), at: CGPoint(x: c.x + 3, y: c.y - radius / 2 - 6), anchor: .leading)
      var reference = Path()
      for i in 0...n {
        let p = point(i % n, model[i % n])
        if i == 0 { reference.move(to: p) } else { reference.addLine(to: p) }
      }
      ctx.phosphorStroke(reference, color: Theme.muted, width: 1, glow: 0, dash: [4, 4])
      // Runs of neighbouring measured bins as lines (wrapping past 360°), every bin as a dot.
      var line = Path()
      for i in 0..<n {
        guard let db = measured[i] else { continue }
        let p = point(i, db)
        if let next = measured[(i + 1) % n] {
          line.move(to: p)
          line.addLine(to: point((i + 1) % n, next))
        }
      }
      ctx.phosphorStroke(line, color: color, width: 1.5)
      for i in 0..<n {
        if let db = measured[i] { ctx.phosphorDot(at: point(i, db), color: color, radius: 1.8) }
      }
    }
    .aspectRatio(1, contentMode: .fit)
    .accessibilityElement()
    .accessibilityLabel("Measured RSSI by yaw against the dipole model")
    .accessibilityValue(summary)
  }

  private var summary: String {
    let filled = measured.indices.filter { measured[$0] != nil }
    guard let best = filled.max(by: { (measured[$0] ?? 0) < (measured[$1] ?? 0) }) else { return "No bins measured yet" }
    return "\(filled.count) of \(measured.count) bins measured; strongest toward \(Int(YawBinner.centre(of: best).rounded())) degrees"
  }
}

// MARK: - 03 Cellular & Wi-Fi

/// Generation and link quality of the phone's data path, mapped to the RF Systems cards.
struct NetworkCard: View {
  @Environment(AppModel.self) private var app

  var body: some View {
    let net = app.live.network
    let band = app.live.settings.prefs.wifiBand
    LiveCard(
      .network, badges: [.table, .model],
      actions: LiveCardActions(
        marker: net.markers.first, scope: [LiveStreams.rtt.id, LiveStreams.quality.id], preset: "Network",
        patch: (LiveStreams.rtt.id, "Round-trip time"))
    ) {
      ReadoutGrid(columns: 2) {
        Readout("Data path", value: net.dataPath?.label ?? net.interface, provenance: net.provenance)
        Readout("Link quality", value: ["Unknown", "Minimal", "Moderate", "Good"][min(3, net.quality)], provenance: net.provenance)
        Readout("Round trip", value: liveValue(net.rtt, 2, unit: "ms"), provenance: net.provenance)
        Readout("Light in ½ RTT", value: net.rtt.map { "\(Int((AirAnalysis.lightPath(roundTrip: $0 / 1000) / 1000).rounded())) km" } ?? "—", provenance: .model)
      }
      HStack(spacing: 10) {
        QualityBars(level: net.quality)
        StreamSparkline(stream: app.streams.stream(LiveStreams.rtt.id), seconds: 60)
          .frame(height: 34)
      }
      if !net.technologies.isEmpty {
        VStack(alignment: .leading, spacing: 6) {
          ForEach(net.technologies.keys.sorted(), id: \.self) { service in
            let cell = RadioMaps.cellular(net.technologies[service] ?? "")
            HStack {
              FactRow(title: service == net.dataService ? "Cellular · data line" : "Cellular line", value: cell.label, provenance: net.provenance)
              Button {
                openCard(cell.systemID, label: cell.label)
              } label: {
                Image(systemName: "arrow.up.right.square").frame(width: 30, height: 30)
              }
              .buttonStyle(.glass)
              .buttonBorderShape(.circle)
              .accessibilityLabel("Open the \(cell.label) card in Radio")
              .accessibilityIdentifier("live-network-open-\(cell.systemID)")
            }
          }
        }
      }
      if let path = net.dataPath {
        // Wi-Fi 6E reports 802.11ax: with the 6 GHz band assumed, the card to open is 6E.
        let sixE = path.systemID == "wifi-ax" && band == .ghz6
        let target = sixE ? "wifi-6e" : path.systemID
        let label = sixE ? "Wi-Fi 6E (802.11ax, 6 GHz assumed)" : path.label
        Button {
          Haptics.shared.tap()
          openCard(target, label: label)
        } label: {
          HStack(spacing: 10) {
            Image(systemName: "antenna.radiowaves.left.and.right")
            VStack(alignment: .leading, spacing: 1) {
              Text("You are on \(label)").font(.subheadline.weight(.semibold))
              Text("Open its card in Radio → Systems").font(.caption).foregroundStyle(Theme.muted)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.caption.weight(.semibold))
          }
          .multilineTextAlignment(.leading)
          .padding(.horizontal, 6)
          .padding(.vertical, 4)
          .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        }
        .buttonStyle(.glass)
        .tint(Theme.phosphor)
        .accessibilityIdentifier("live-network-open-card")
      }
      VStack(alignment: .leading, spacing: 6) {
        Text("Wi-Fi band (assumed)").font(.caption).foregroundStyle(Theme.muted)
        ChoiceChips(items: RadioMaps.WiFiBand.allCases, selection: bandBinding, id: "live-wifi-band", tint: BandPalette.color(forFrequency: band.frequency)) {
          ChipLabel(title: $0.title)
        }
        .padding(.horizontal, -Theme.gutter)
      }
      HStack(spacing: 8) {
        if net.isExpensive { StatusChip(text: "EXPENSIVE", color: Theme.amber) }
        if net.isConstrained { StatusChip(text: "LOW DATA", color: Theme.amber) }
        if net.isUltraConstrained { StatusChip(text: "ULTRA CONSTRAINED", color: Theme.amber) }
      }
      Text(
        "iOS gives no cellular or Wi-Fi signal strength in dBm. These are the generation, the link-quality bucket and a TCP handshake to Apple's connectivity host every second (nothing else is sent). Wi-Fi 6E still reports 802.11ax, so pick the band you think you are on."
      )
      .panelCaption()
    }
  }

  private var bandBinding: Binding<RadioMaps.WiFiBand> {
    Binding(get: { app.live.settings.prefs.wifiBand }, set: { app.live.settings.prefs.wifiBand = $0 })
  }

  /// Jumps to the Radio tab with this system's marker focused (`live.system.<id>`).
  private func openCard(_ systemID: String, label: String) {
    guard let system = RF.SystemsCatalog.system(id: systemID) else { return }
    app.focus(
      SpectrumMarker(id: "live.system.\(systemID)", label: "\(label) → \(system.name)", frequency: system.carrier, provenance: .table, tab: .radio))
  }
}

private struct QualityBars: View {
  let level: Int
  var body: some View {
    HStack(alignment: .bottom, spacing: 3) {
      ForEach(1...3, id: \.self) { i in
        RoundedRectangle(cornerRadius: 2)
          .fill(i <= level ? Theme.phosphor : Theme.dim.opacity(0.3))
          .frame(width: 7, height: CGFloat(8 + 8 * i))
      }
    }
    .accessibilityElement()
    .accessibilityLabel("Link quality \(level) of 3")
  }
}

// MARK: - 04 Satellites (GNSS)

struct GNSSCard: View {
  @Environment(AppModel.self) private var app

  var body: some View {
    let loc = app.live.location
    let noise = RF.Noise.floorDBm(bandwidth: 2 * RF.Numerology.GPS.caChipRate, noiseFigureDB: 2)
    let power = RadioMaps.gpsMinimumPowerDBm
    let gain = RF.Numerology.processingGainDB(chipRate: RF.Numerology.GPS.caChipRate, bitRate: RF.Numerology.GPS.navBitRate)
    LiveCard(
      .gnss, badges: [.table, .model], startTitle: "Read the fix",
      explanation: "Spectra reads how precisely satellites locate you. Your position is never shown, stored or sent.",
      actions: LiveCardActions(
        marker: loc.markers.first, scope: [LiveStreams.hacc.id, LiveStreams.speed.id, LiveStreams.altitude.id], preset: nil,
        patch: (LiveStreams.hacc.id, "GNSS accuracy"))
    ) {
      AdaptiveStack {
        PlotWell(height: 150, grid: 0) {
          AccuracyRings(accuracy: loc.horizontalAccuracy)
        }
        .sideWidth(150)
        VStack(alignment: .leading, spacing: 10) {
          Readout("Fix", value: loc.hasFix ? (loc.accuracyLimited ? "Approximate" : "Yes") : "Searching", provenance: loc.provenance)
          Readout("± horizontal", value: liveValue(loc.horizontalAccuracy, 2, unit: "m"), provenance: loc.provenance)
          Readout("± vertical", value: liveValue(loc.verticalAccuracy, 2, unit: "m"), provenance: loc.provenance)
        }
      }
      ReadoutGrid(columns: 3) {
        Readout("Ellipsoid h", value: loc.ellipsoidalAltitude.map { "\(liveWhole($0)) m" } ?? "—", provenance: loc.provenance)
        Readout(
          "Geoid height",
          value: (loc.ellipsoidalAltitude.flatMap { e in loc.seaLevelAltitude.map { e - $0 } }).map { "\(SpectraFormat.significant($0, 3)) m" } ?? "—",
          provenance: loc.provenance)
        Readout("Speed", value: liveValue(loc.speed, 2, unit: "m/s"), provenance: loc.provenance)
        Readout("True heading", value: loc.trueHeading.map { "\(Int($0.rounded()))°" } ?? "—", provenance: loc.provenance)
        Readout("Magnetic", value: loc.magneticHeading.map { "\(Int($0.rounded()))°" } ?? "—", provenance: loc.provenance)
        Readout("Light time", value: "\(SpectraFormat.significant(RF.Units.lightTime(distance: RadioMaps.gpsAltitude) * 1000, 3)) ms", provenance: .model)
      }
      VStack(alignment: .leading, spacing: 4) {
        FactRow(title: "L1 · λ \(SpectraFormat.wavelength(SpectrumMarker.lambda(forFrequency: RadioMaps.gpsL1)))", value: "1575.42 MHz", provenance: .table)
        FactRow(title: "L5 · λ \(SpectraFormat.wavelength(SpectrumMarker.lambda(forFrequency: RadioMaps.gpsL5)))", value: "1176.45 MHz", provenance: .table)
        FactRow(title: "Satellites", value: "20,200 km up", provenance: .table)
        FactRow(title: "Signal at the ground", value: SpectraFormat.decibels(power, unit: "dBm"), provenance: .table)
        FactRow(title: "Noise in 2.05 MHz (NF 2 dB)", value: SpectraFormat.decibels(noise, unit: "dBm"), provenance: .model)
        FactRow(title: "Despreading gain", value: SpectraFormat.decibels(gain, unit: "dB", decimals: 0, signed: true), provenance: .model)
      }
      Text(
        "The signal arrives \(SpectraFormat.significant(noise - power, 2)) dB below the noise; the receiver digs it out by correlating with the known code: 1023 chips repeating every millisecond, 20,460 chips per 50 bit/s data bit. iOS exposes the fix quality, not the satellites or their signal-to-noise."
      )
      .panelCaption()
    }
  }
}

/// ± horizontal accuracy as a circle on log rings (1, 5, 10, 50 m).
private struct AccuracyRings: View {
  let accuracy: Double?

  var body: some View {
    Canvas { ctx, size in
      let c = CGPoint(x: size.width / 2, y: size.height / 2)
      let radius = min(size.width, size.height) / 2 - 10
      func r(_ m: Double) -> CGFloat { radius * CGFloat(min(1, max(0, log10(max(m, 1)) / 2))) }
      // Each ring's label sits at its own angle: 5 and 10 m are close on a log scale.
      for (m, angle) in [(5.0, -0.25 * Double.pi), (10, 0.25 * Double.pi), (50, 0.75 * Double.pi)] {
        let rr = r(m)
        ctx.stroke(Path(ellipseIn: CGRect(x: c.x - rr, y: c.y - rr, width: 2 * rr, height: 2 * rr)), with: .color(Theme.phosphor.opacity(0.1)), lineWidth: 0.6)
        let p = CGPoint(x: c.x + rr * CGFloat(cos(angle)), y: c.y + rr * CGFloat(sin(angle)))
        ctx.annotation(
          "\(Int(m)) m", at: CGPoint(x: p.x + (cos(angle) > 0 ? 2 : -2), y: p.y + (sin(angle) > 0 ? 2 : -2)),
          anchor: cos(angle) > 0 ? (sin(angle) > 0 ? .topLeading : .bottomLeading) : (sin(angle) > 0 ? .topTrailing : .bottomTrailing))
      }
      let color = BandPalette.color(forFrequency: RadioMaps.gpsL1)
      if let a = accuracy {
        let rr = r(a)
        let circle = Path(ellipseIn: CGRect(x: c.x - rr, y: c.y - rr, width: 2 * rr, height: 2 * rr))
        ctx.fill(circle, with: .color(color.opacity(0.12)))
        ctx.phosphorStroke(circle, color: color, width: 1.5)
      }
      ctx.phosphorDot(at: c, color: Theme.text, radius: 2)
    }
    .accessibilityElement()
    .accessibilityLabel("Horizontal accuracy circle")
    .accessibilityValue(accuracy.map { "\(Int($0.rounded())) meters" } ?? "No fix")
  }
}
