import SwiftUI
import UIKit

/// The Scope's screen: the Metal phosphor display for YT, Roll and XY; the FFT plot; or the
/// time–frequency image with its marginals. Labels sit on top in SwiftUI (refreshed with the
/// readouts, about 5 Hz). Aspect 10 : 8 like the graticule.
struct ScopeDisplay: View {
  let model: ScopeModel
  var compact = false

  @Environment(AppModel.self) private var app
  @Environment(\.dynamicTypeSize) private var typeSize
  @Environment(\.openURL) private var openURL

  var body: some View {
    let mode = model.settings.mode
    VStack(alignment: .leading, spacing: 8) {
      PlotWell(grid: 0) {
        Group {
          switch mode {
          case .yt, .roll, .xy:
            // The cursors exist in YT and Roll only: elsewhere (XY) a drag must scroll the page,
            // not move cursors nobody can see.
            ScopeCanvas(source: model, redrawKey: model.revision, label: "Oscilloscope, \(mode.title)", value: accessibilitySummary)
              .gesture(cursorDrag, including: model.settings.cursors.mode != .off && mode != .xy ? .all : .subviews)
          case .fft:
            ScopeTicker(model: model, interval: 1.0 / 20)
            FFTView(model: model)
          case .spectrogram, .wignerVille, .pseudoWigner:
            ScopeTicker(model: model, interval: 1.0 / 10)
            TimeFrequencyView(model: model)
          }
        }
        statusBadge
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
          .padding(8)
          .allowsHitTesting(false)
        gate
      }
      .aspectRatio(10.0 / 8.0, contentMode: .fit)
      .frame(maxWidth: .infinity)
      .onGeometryChange(for: CGSize.self) { $0.size } action: { displaySize = $0 }
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier("scope-display")
      statusStrip(mode)
    }
  }

  private var accessibilitySummary: String {
    let r = model.readout
    var parts = [r.status.meaning, ScopeFormat.timebase(model.timebase)]
    for i in 0...4 where model.isShown(i) {
      let name = i == 4 ? "Math" : "Channel \(i + 1)"
      let m = r.measurements[i]
      parts.append(
        "\(name) \(model.label(i)): peak to peak \(ScopeFormat.value(m?.peakToPeak, unit: ScopeEngine.differenceUnit(model.unit(i)))), frequency \(ScopeFormat.frequency(m?.frequencyZeroCrossing ?? m?.frequencyFFT))")
    }
    return parts.joined(separator: ". ")
  }

  /// The trigger status in the display's corner (TRIG'D, AUTO, WAIT, STOP, ROLL…).
  private var statusBadge: some View {
    let r = model.readout
    return Text(r.status.text)
      .font(.system(.caption2, design: .monospaced).weight(.bold))
      // Scales with Dynamic Type, capped below the accessibility sizes: at Accessibility XL an
      // uncapped (or accessibility2) badge covered CH1's band in the display's corner. VoiceOver
      // reads the full meaning, and the probe captions and readouts keep scaling.
      .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
      .foregroundStyle(statusColor(r.status))
      .padding(.horizontal, 6)
      .padding(.vertical, 3)
      .background(Theme.plotWell.opacity(0.75), in: .capsule)
      .accessibilityLabel(r.status.meaning)
      .accessibilityIdentifier("scope-status")
  }

  /// Under the screen, like a bench scope's status line: ALIASED and time-mapping chips, then
  /// each channel's scale, the timebase and the trigger.
  @ViewBuilder
  private func statusStrip(_ mode: ScopeMode) -> some View {
    let r = model.readout
    // XY plots only its X and Y channels, so only their scales are listed.
    let xy = [model.settings.xChannel, model.settings.yChannel]
    let labels = (0...4).filter { model.isShown($0) && (mode != .xy || xy.contains($0)) }
    VStack(alignment: .leading, spacing: 6) {
      if r.aliasNotes.first != nil || !compact {
        HStack(spacing: 6) {
          if let note = r.aliasNotes.first {
            StatusChip(
              text: "ALIASED",
              detail: "\(SpectraFormat.frequency(note.frequency)) → \(SpectraFormat.frequency(note.alias, digits: 3))",
              color: Theme.ionizing, symbol: "exclamationmark.triangle.fill"
            )
            .accessibilityLabel("Aliased")
            .accessibilityValue(
              "\(note.source) is above half the \(SpectraFormat.frequency(note.sampleRate)) sampling rate and appears at \(SpectraFormat.frequency(note.alias)).")
            .accessibilityIdentifier("scope-aliased")
          }
          if !compact {
            switch model.timeNote {
            case .known(let mapping):
              TimeMappingChip(mapping: mapping).accessibilityIdentifier("scope-time-mapping")
            case .declared(let badge, let detail):
              // The colours and symbols of `TimeMappingChip`.
              let heterodyned = badge == TimeMapping.heterodyned(fRef: 0).badge
              StatusChip(
                text: badge, detail: detail, color: heterodyned ? Theme.iceRGB.color : RGB(0.72, 0.55, 1.0).color,
                symbol: heterodyned ? "waveform" : "tuningfork")
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(badge.capitalized), \(detail)")
                .accessibilityIdentifier("scope-time-mapping")
            }
          }
          Spacer(minLength: 0)
        }
      }
      // Each item at its natural width, wrapping like a bench scope's status line, so a long
      // scale ("CH1 500 mV/div (norm.)") is never squeezed into a fixed column and cut off.
      ScopeFlowLayout(spacing: typeSize.isAccessibilitySize ? 10 : 14, lineSpacing: 3) {
        if mode == .yt || mode == .roll || mode == .xy {
          ForEach(labels, id: \.self) { i in
            Text("\(i == 4 ? "M" : "CH\(i + 1)") \(ScopeFormat.scale(model.scale(i).unitsPerDiv, unit: model.unit(i)))")
              .foregroundStyle(model.color(i))
              .lineLimit(1)
          }
        }
        switch mode {
        case .yt:
          Text(ScopeFormat.timebase(model.timebase))
          let t = model.settings.trigger
          Text("\(t.source == 4 ? "M" : "CH\(t.source + 1)") \(t.slope == .rising ? "↑" : "↓") \(ScopeFormat.value(t.level, unit: model.unit(t.source)))")
            .foregroundStyle(model.color(t.source))
        case .roll:
          Text(ScopeFormat.timebase(model.timebase))
        case .xy:
          Text("X CH\(model.settings.xChannel + 1) · Y CH\(model.settings.yChannel + 1)")
          Text("\(SpectraFormat.si(model.timebase * 10, unit: "s")) shown")
        default:
          EmptyView()
        }
      }
      .font(.system(.caption2, design: .monospaced).weight(.medium))
      .monospacedDigit()
      .foregroundStyle(Theme.muted)
      .accessibilityElement(children: .combine)
      .accessibilityIdentifier("scope-scales")
      if mode == .fft || mode.isTimeFrequency {
        let i = model.settings.analysisChannel
        Text(
          "\(i == 4 ? "M" : "CH\(i + 1)") \(model.label(i)) · \(model.isIrregular(i) ? "irregular" : SpectraFormat.rate(model.readout.rates[i])) · \(SpectraFormat.si(model.timebase * 10, unit: "s")) window"
        )
        .font(.system(.caption2, design: .monospaced).weight(.medium))
        .foregroundStyle(model.color(i))
        .lineLimit(2)
        .accessibilityIdentifier("scope-analysis-source")
      }
    }
  }

  /// Sensors that would show a permission prompt wait for a tap here; sensors that were
  /// started but do not deliver (access denied, unavailable, locked, turned off in Settings,
  /// or still asking) say so along the bottom of the screen, with Open Settings on denial.
  @ViewBuilder
  private var gate: some View {
    if !model.blockedSensors.isEmpty {
      blockedGate
    } else {
      let stalled = stalledSensors
      if !stalled.isEmpty {
        VStack(alignment: .leading, spacing: 8) {
          ForEach(stalled) { id in
            let channel = app.live.channel(id)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
              // The state is one element; Open Settings stays its own button (combining it in
              // would hide its identifier and fold its action into the sentence).
              HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: channel.symbol).foregroundStyle(Theme.amber)
                Text("\(channel.title): \(stallReason(id))")
                  .font(.footnote)
                  .foregroundStyle(Theme.text)
                  .fixedSize(horizontal: false, vertical: true)
              }
              .accessibilityElement(children: .combine)
              .accessibilityIdentifier("scope-sensor-state-\(id.rawValue)")
              Spacer(minLength: 0)
              if channel.state == .denied {
                Button("Open Settings") {
                  Haptics.shared.tap()
                  if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
                .buttonStyle(.glassProminent)
                .tint(Theme.phosphor)
                .accessibilityIdentifier("scope-open-settings-\(id.rawValue)")
              }
            }
          }
        }
        .padding(12)
        .background(Theme.plotWell.opacity(0.88), in: .rect(cornerRadius: 12))
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
      }
    }
  }

  /// Needed sensors that are held but not delivering.
  private var stalledSensors: [SensorID] {
    model.neededSensors.filter { id in
      switch app.live.channel(id).state {
      case .running: false
      case .idle: !app.live.isEnabled(id)
      case .requesting, .denied, .unavailable, .locked: true
      }
    }
    .sorted { $0.rawValue < $1.rawValue }
  }

  private func stallReason(_ id: SensorID) -> String {
    let state = app.live.channel(id).state
    if case .idle = state, !app.live.isEnabled(id) { return "turned off in Settings → Sensors." }
    if case .requesting = state { return "asking for access…" }
    if case .denied = state { return "access is off. Spectra needs it to show this live; turn it on in Settings." }
    return state.reason ?? state.label
  }

  private var blockedGate: some View {
      VStack(spacing: 10) {
        Text("This probe needs \(model.blockedSensors.map(sentenceName).joined(separator: " and ")).")
          .font(.footnote)
          .foregroundStyle(Theme.text)
          .multilineTextAlignment(.center)
        ForEach(model.blockedSensors) { id in
          let channel = app.live.channel(id)
          Button {
            Haptics.shared.tap()
            model.startSensor(id)
          } label: {
            Label("Start \(channel.title)", systemImage: channel.symbol)
              .font(.subheadline.weight(.semibold))
              .frame(minHeight: 32)
          }
          .buttonStyle(.glassProminent)
          .tint(Theme.phosphor)
          .disabled(!app.live.isEnabled(id) || isLocked(channel.state))
          .accessibilityIdentifier("scope-start-\(id.rawValue)")
          if let reason = channel.state.reason ?? (app.live.isEnabled(id) ? nil : "Turned off in Settings → Sensors.") {
            Text(reason).font(.caption).foregroundStyle(Theme.muted).multilineTextAlignment(.center)
          }
        }
        Text("Spectra asks for permission on this tap, never at launch.")
          .font(.caption2)
          .foregroundStyle(Theme.muted)
      }
      .padding(16)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(Theme.plotWell.opacity(0.82))
  }

  /// A sensor as it reads in a sentence ("the microphone", "Bluetooth", "the camera").
  private func sentenceName(_ id: SensorID) -> String {
    switch id {
    case .microphone: "the microphone"
    case .bluetooth: "Bluetooth"
    case .barometer: "the barometer"
    case .location: "location (GNSS)"
    case .light: "the camera"
    case .uwb: "ultra wideband"
    case .nfc: "NFC"
    case .network: "the network"
    default: "the " + id.title.lowercased()
    }
  }

  private func isLocked(_ state: SensorState) -> Bool {
    if case .locked = state { return true }
    return false
  }

  private func statusColor(_ s: ScopeStatus) -> Color {
    switch s {
    case .triggered, .analysis: Theme.phosphor
    case .auto, .waiting, .single: Theme.amber
    case .stopped, .noSignal: Theme.ionizing
    case .roll, .xy: Theme.iceRGB.color
    }
  }

  /// Drag on the display moves the nearest cursor.
  private var cursorDrag: some Gesture {
    DragGesture(minimumDistance: 2, coordinateSpace: .local)
      .onChanged { g in
        let c = model.settings.cursors
        guard c.mode != .off, model.settings.mode == .yt || model.settings.mode == .roll else { return }
        // The canvas fills the well: map points to divisions via the well's size.
        let size = displaySize
        guard size.width > 0, size.height > 0 else { return }
        let tx = Double(g.location.x / size.width) * Double(ScopeEngine.divisionsX)
        let ty = (0.5 - Double(g.location.y / size.height)) * Double(ScopeEngine.divisionsY)
        // The same haptic answer as a knob: a grab, quantized detents while moving, a release.
        if !cursorDragging {
          cursorDragging = true
          Haptics.shared.grab()
        }
        Haptics.shared.detent(normalized: c.mode.showsTime ? tx / Double(ScopeEngine.divisionsX) : 0.5 + ty / Double(ScopeEngine.divisionsY))
        model.mutate { s in
          var cur = s.cursors
          let dt1 = abs(cur.t1 - tx)
          let dt2 = abs(cur.t2 - tx)
          let dy1 = abs(cur.y1 - ty) * Double(ScopeEngine.divisionsX) / Double(ScopeEngine.divisionsY)
          let dy2 = abs(cur.y2 - ty) * Double(ScopeEngine.divisionsX) / Double(ScopeEngine.divisionsY)
          var best = (cur.mode.showsTime ? min(dt1, dt2) : .infinity, 0)
          if cur.mode.showsAmplitude, min(dy1, dy2) < best.0 { best = (min(dy1, dy2), 1) }
          if best.1 == 0 {
            if dt1 <= dt2 { cur.t1 = min(10, max(0, tx)) } else { cur.t2 = min(10, max(0, tx)) }
          } else {
            if dy1 <= dy2 { cur.y1 = min(4, max(-4, ty)) } else { cur.y2 = min(4, max(-4, ty)) }
          }
          s.cursors = cur
        }
      }
      .onEnded { _ in
        guard cursorDragging else { return }
        cursorDragging = false
        Haptics.shared.endAdjustment()
      }
  }

  @State private var displaySize: CGSize = .zero
  @State private var cursorDragging = false
}

/// Lays its items out left to right at their natural widths and wraps onto new lines (the
/// status strip under the display). An item wider than a line is offered the line's width.
nonisolated struct ScopeFlowLayout: Layout {
  var spacing: CGFloat = 12
  var lineSpacing: CGFloat = 3

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    arrange(subviews, width: proposal.width ?? .infinity).size
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    let frames = arrange(subviews, width: bounds.width).frames
    for (s, f) in zip(subviews, frames) {
      s.place(at: CGPoint(x: bounds.minX + f.minX, y: bounds.minY + f.minY), proposal: ProposedViewSize(f.size))
    }
  }

  private func arrange(_ subviews: Subviews, width: CGFloat) -> (frames: [CGRect], size: CGSize) {
    var frames: [CGRect] = []
    var x: CGFloat = 0
    var y: CGFloat = 0
    var line: CGFloat = 0
    var widest: CGFloat = 0
    for s in subviews {
      var size = s.sizeThatFits(ProposedViewSize(width: width.isFinite ? width : nil, height: nil))
      if width.isFinite { size.width = min(size.width, width) }
      if x > 0, x + size.width > width {
        x = 0
        y += line + lineSpacing
        line = 0
      }
      frames.append(CGRect(x: x, y: y, width: size.width, height: size.height))
      widest = max(widest, x + size.width)
      x += size.width + spacing
      line = max(line, size.height)
    }
    return (frames, CGSize(width: widest, height: y + line))
  }
}

/// Drives the model at a fixed rate while an analysis view is on screen (the Metal display
/// drives it otherwise).
struct ScopeTicker: View {
  let model: ScopeModel
  var interval: Double

  var body: some View {
    VisibleTimeline(minimumInterval: interval, paused: !model.running) { date in
      Color.clear
        .onChange(of: date) { _, _ in model.tick() }
        .onAppear { model.tick() }
    }
    .accessibilityHidden(true)
  }
}

/// FFT mode: Hann-windowed spectrum of the analysis channel, peak marker and alias notes.
private struct FFTView: View {
  let model: ScopeModel

  var body: some View {
    let i = model.settings.analysisChannel
    if let s = model.spectrum, s.count > 0 {
      let peak = Double(s.peakDB ?? -60)
      let top = (peak / 10).rounded(.up) * 10 + 10
      let low = model.settings.logFrequency ? max(s.binWidth, s.nyquist / 2e4) : 0
      SpectrumPlot(
        bins: s.db, binWidth: s.binWidth, frequencyRange: low...s.nyquist, logFrequency: model.settings.logFrequency,
        dbRange: (top - 100)...top, color: model.color(i), showsPeak: true, markers: markers(s), unit: "dB",
        accessibilityLabel: "Spectrum of \(model.label(i))"
      )
      .padding(.top, 26)
      .padding(.horizontal, 4)
    } else {
      Text(model.isShown(i) ? "Collecting samples…" : "Choose a channel to analyze.")
        .font(.footnote)
        .foregroundStyle(Theme.muted)
    }
  }

  private func markers(_ s: ScopeEngine.Spectrum) -> [FrequencyMarker] {
    var out: [FrequencyMarker] = []
    // Only what the analyzed channel itself aliases (a magnetometer's 60 Hz → 40 Hz does not
    // belong on the microphone's spectrum), and only on its undecimated axis.
    let notes = model.readout.channelAliasNotes[model.settings.analysisChannel] ?? []
    for note in notes where note.sampleRate / 2 <= s.nyquist * 1.01 {
      // The marker sits where the source lands; its label names the source (short, so
      // neighbouring alias markers do not collide).
      out.append(FrequencyMarker(frequency: note.alias, label: "\(Int(note.frequency.rounded()))", color: Theme.ionizing))
    }
    return out
  }
}

/// Spectrogram, Wigner–Ville or pseudo-Wigner image with |x(t)|² along the bottom and |X(ν)|²
/// up the right edge (dashed: the references the marginals should equal).
private struct TimeFrequencyView: View {
  let model: ScopeModel

  var body: some View {
    if let tf = model.timeFrequency, tf.mode == model.settings.mode {
      Canvas { ctx, size in
        let strip: CGFloat = 26
        let top: CGFloat = 26
        let left: CGFloat = 4
        let image = CGRect(x: left, y: top, width: size.width - strip - left - 4, height: size.height - strip - top - 4)
        if let cg = tf.image {
          ctx.draw(Image(decorative: cg, scale: 1).interpolation(.medium), in: image)
        }
        ctx.stroke(Path(image), with: .color(Theme.phosphor.opacity(0.25)), lineWidth: 0.75)
        // Frequency ticks (0 … f_s/2) on the image.
        let nyquist = tf.sampleRate / 2
        for k in 1..<4 {
          let f = nyquist * Double(k) / 4
          let y = image.maxY - image.height * CGFloat(k) / 4
          ctx.annotation(SpectraFormat.frequency(f, digits: 3), at: CGPoint(x: image.minX + 3, y: y), anchor: .leading, color: Theme.muted)
        }
        // Time marginal along the bottom.
        let bottom = CGRect(x: image.minX, y: image.maxY + 3, width: image.width, height: strip - 6)
        ctx.stroke(curve(tf.intensity, in: bottom, vertical: false), with: .color(Theme.muted.opacity(0.7)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
        ctx.phosphorStroke(curve(tf.timeMarginal, in: bottom, vertical: false), color: Theme.phosphor, width: 1.1, glow: 0.6)
        // Frequency marginal up the right edge.
        let right = CGRect(x: image.maxX + 3, y: image.minY, width: strip - 6, height: image.height)
        ctx.stroke(curve(tf.spectrum, in: right, vertical: true), with: .color(Theme.muted.opacity(0.7)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
        ctx.phosphorStroke(curve(tf.frequencyMarginal, in: right, vertical: true), color: Theme.amber, width: 1.1, glow: 0.6)
        // The time strip's name sits on the image's corner, on a backing, not across the trace.
        let name = ctx.resolve(Text("|x(t)|²").font(Theme.annotationFont).foregroundStyle(Theme.phosphor))
        let nameSize = name.measure(in: CGSize(width: 120, height: 40))
        let nameRect = CGRect(
          x: image.maxX - nameSize.width - 6, y: image.maxY - nameSize.height - 4, width: nameSize.width + 4,
          height: nameSize.height + 2)
        ctx.fill(Path(roundedRect: nameRect, cornerRadius: 3), with: .color(Theme.plotWell.opacity(0.85)))
        ctx.draw(name, at: CGPoint(x: nameRect.midX, y: nameRect.midY), anchor: .center)
        ctx.annotation("|X(ν)|²", at: CGPoint(x: right.maxX, y: right.minY - 8), anchor: .trailing, color: Theme.amber)
        ctx.annotation(SpectraFormat.si(tf.duration, unit: "s"), at: CGPoint(x: image.minX + 3, y: image.maxY - 8), anchor: .leading, color: Theme.muted)
      }
      .accessibilityElement()
      .accessibilityLabel("\(tf.mode.title) of \(model.label(model.settings.analysisChannel))")
      .accessibilityValue("Time across \(SpectraFormat.si(tf.duration, unit: "s")), frequency up to \(SpectraFormat.frequency(tf.sampleRate / 2)).")
    } else {
      Text(model.isShown(model.settings.analysisChannel) ? "Computing…" : "Choose a channel to analyze.")
        .font(.footnote)
        .foregroundStyle(Theme.muted)
    }
  }

  private func curve(_ values: [Float], in rect: CGRect, vertical: Bool) -> Path {
    var path = Path()
    guard values.count > 1 else { return path }
    for (k, v) in values.enumerated() {
      let f = CGFloat(k) / CGFloat(values.count - 1)
      let a = CGFloat(min(1.2, max(0, v.isFinite ? v : 0)))
      let p =
        vertical
        ? CGPoint(x: rect.minX + a / 1.2 * rect.width, y: rect.maxY - f * rect.height)
        : CGPoint(x: rect.minX + f * rect.width, y: rect.maxY - a / 1.2 * rect.height)
      if k == 0 { path.move(to: p) } else { path.addLine(to: p) }
    }
    return path
  }
}
