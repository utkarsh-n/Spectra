import SwiftUI

/// One technique button of the lab: a sample's mode, or the NMR sample's Earth-field mode.
enum LabTechnique: Identifiable, Equatable {
  case mode(SampleMode)
  case earth

  var id: String {
    switch self {
    case .mode(let m): "mode-\(m.rawValue)"
    case .earth: "earth"
    }
  }

  var title: String {
    switch self {
    case .mode(let m): m.name
    case .earth: "Earth |B|"
    }
  }

  var accessibilityTitle: String {
    switch self {
    case .mode(let m): m.name
    case .earth: "Earth field, live magnetometer"
    }
  }
}

/// 05 Spectroscopy lab toolbar: samples, techniques (with the Earth-field mode for proton
/// NMR) and Sweep.
struct SpectrumLabToolbar: View {
  @Environment(AppModel.self) private var app

  var body: some View {
    let model = app.spectrum
    let sample = model.state.lab.sample
    let techniques = sample.modes.map(LabTechnique.mode) + (sample == .nmr ? [.earth] : [])
    let selected: LabTechnique = model.extras.labEarth ? .earth : .mode(model.state.lab.mode)
    VStack(alignment: .leading, spacing: 10) {
      GlassSegmented(items: SampleKey.allCases, selected: sample, id: "spectrum-lab-sample", title: { $0.name }) {
        model.selectSample($0)
      }
      HStack(spacing: 8) {
        GlassSegmented(
          items: techniques, selected: selected, id: "spectrum-lab-technique", tint: { _ in Theme.amber }, title: { $0.title },
          accessibilityTitle: { $0.accessibilityTitle }
        ) { t in
          switch t {
          case .mode(let m): model.selectMode(m)
          case .earth: model.selectEarthMode()
          }
        }
        ActionButton(
          model.state.lab.sweeping ? "Pause" : "Sweep", symbol: model.state.lab.sweeping ? "pause.fill" : "play.fill",
          prominent: !model.state.lab.sweeping
        ) { model.toggleSweep() }
        .accessibilityLabel(model.state.lab.sweeping ? "Pause sweep" : "Sweep")
        .accessibilityIdentifier("spectrum-lab-sweep")
      }
    }
  }
}

/// The lab stage: the sample's spectrum drawing itself behind the cursor (spectra-lab
/// `lab.js` `draw`), the hydrogen spectroscope strip, or the Earth-field line from the live
/// magnetometer. Drag to scan by hand.
struct SpectrumLabStage: View {
  @Environment(AppModel.self) private var app
  var height: CGFloat = 260

  var body: some View {
    let model = app.spectrum
    VStack(spacing: 8) {
      if model.extras.labEarth {
        EarthFieldStage(height: height)
        StageHint("Drag or Sweep to scan \u{00B7} Tune to line lands on it")
      } else {
        sampleStage(model)
        StageHint("Drag to scan by hand \u{00B7} or Sweep")
      }
    }
  }

  @ViewBuilder private func sampleStage(_ model: SpectrumModel) -> some View {
    let sample = model.state.lab.sample
    let mode = model.state.lab.mode
    let curve = model.labCurve(sample, mode)
    let sweep = model.state.lab.sweep
    let lambda = model.active.lambda
    let stripH: CGFloat = sample == .hydrogen ? 34 : 0
    PlotWell(height: height + stripH, grid: 0) {
      GeometryReader { geo in
        Canvas { ctx, size in
          LabDrawing.draw(ctx, size, sample: sample, mode: mode, curve: curve, sweep: sweep, cursorLambda: lambda)
        }
        .contentShape(.rect)
        .gesture(
          DragGesture(minimumDistance: 0)
            .onChanged { v in
              if model.state.lab.sweeping { model.state.lab.sweeping = false }
              let g = LabDrawing.plotX(width: geo.size.width)
              let u = Double((v.location.x - g.lowerBound) / (g.upperBound - g.lowerBound))
              let before = model.state.lab.sweep
              model.setLabSweep(u)
              if Int(before * 24) != Int(model.state.lab.sweep * 24) { Haptics.shared.tick() }
            }
        )
      }
    }
    .overlay(alignment: .topLeading) { StageTag(yLabel(sample, mode)).padding(10) }
    .overlay(alignment: .topTrailing) {
      StageTag(SpectrumDisplay.labAxisText(sample, x: sample.axis.x(at: sweep)), color: Theme.phosphor).padding(10)
    }
    .accessibilityElement()
    .accessibilityLabel("\(sample.name) spectrum, \(mode.name)")
    .accessibilityValue("Cursor at \(SpectrumDisplay.labAxisText(sample, x: sample.axis.x(at: sweep))), \(Int((sweep * 100).rounded())) percent scanned")
    .accessibilityAdjustableAction { direction in
      model.state.lab.sweeping = false
      model.setLabSweep(sweep + (direction == .increment ? 0.02 : -0.02))
    }
    .accessibilityIdentifier("spectrum-lab-stage")
  }

  private func yLabel(_ s: SampleKey, _ m: SampleMode) -> String {
    switch s {
    case .hydrogen: m == .emission ? "Emission intensity" : "Absorption"
    case .nmr: "Signal"
    default: m == .raman ? "Raman intensity" : "Absorbance"
    }
  }
}

/// Lab drawing (Canvas port of `lab.draw`).
enum LabDrawing {
  /// Plot x extent for a stage width.
  static func plotX(width: CGFloat) -> ClosedRange<CGFloat> { 34...max(35, width - 18) }

  static func draw(
    _ ctx: GraphicsContext, _ size: CGSize, sample s: SampleKey, mode: SampleMode, curve: [Double], sweep cu: Double, cursorLambda: Double
  ) {
    let w = size.width, h = size.height
    let xr = plotX(width: w)
    let x0 = xr.lowerBound, x1 = xr.upperBound, y0: CGFloat = 34
    let stripH: CGFloat = s == .hydrogen ? 34 : 0
    let y1 = h - 34 - stripH
    let n = max(1, curve.count - 1)
    var done: [CGPoint] = [], ahead: [CGPoint] = []
    for i in 0...n {
      let u = Double(i) / Double(n)
      let v = curve[min(i, curve.count - 1)]
      let p = CGPoint(x: x0 + CGFloat(u) * (x1 - x0), y: y1 - CGFloat(min(1.05, v)) * (y1 - y0))
      if u <= cu { done.append(p) } else { ahead.append(p) }
    }
    if let last = done.last { ahead.insert(last, at: 0) }
    SpectrumDraw.segment(ctx, CGPoint(x: x0, y: y1), CGPoint(x: x1, y: y1), color: Theme.axis)
    // Five ticks; on a phone-width plot long labels ("4000 cm⁻¹") would run into each other,
    // so only every other one is labeled when two neighbors cannot both fit (the end labels
    // hang inward from their ticks, the middle ones are centered).
    var widths: [CGFloat] = []
    for i in 0...4 { widths.append(TunerDrawing.textWidth(SpectrumDisplay.labAxisText(s, x: s.axis.x(at: Double(i) / 4)), size: 8.5)) }
    let reach = { (i: Int) -> (left: CGFloat, right: CGFloat) in
      i == 0 ? (0, widths[0]) : (i == 4 ? (widths[4], 0) : (widths[i] / 2, widths[i] / 2))
    }
    let crowded = (0..<4).contains { reach($0).right + reach($0 + 1).left + 3 > (x1 - x0) / 4 }
    let labelEvery = crowded ? 2 : 1
    for i in 0...4 {
      let u = Double(i) / 4, x = x0 + CGFloat(u) * (x1 - x0)
      SpectrumDraw.segment(ctx, CGPoint(x: x, y: y1), CGPoint(x: x, y: y1 + 4), color: Theme.axis)
      guard i % labelEvery == 0 else { continue }
      SpectrumDraw.label(
        ctx, SpectrumDisplay.labAxisText(s, x: s.axis.x(at: u)), CGPoint(x: x, y: y1 + 14),
        anchor: i == 0 ? .leading : (i == 4 ? .trailing : .center), size: 8.5)
    }
    SpectrumDraw.line(ctx, ahead, color: Color(hex: 0x9CB5A6).opacity(0.3), width: 1.1, glow: 0, dash: [2, 4])
    if done.count > 1 {
      var fill = SpectrumDraw.path(done)
      fill.addLine(to: CGPoint(x: done[done.count - 1].x, y: y1))
      fill.addLine(to: CGPoint(x: done[0].x, y: y1))
      fill.closeSubpath()
      ctx.fill(fill, with: .color(Theme.phosphor.opacity(0.08)))
      SpectrumDraw.line(ctx, done, color: Theme.phosphor, width: 1.8, glow: 0.4)
    }
    if s == .hydrogen { hydrogen(ctx, size, mode: mode, curve: curve, x0: x0, x1: x1, y0: y0, y1: y1, cu: cu) }
    // Cursor.
    let cx = x0 + CGFloat(cu) * (x1 - x0)
    let col = BandPalette.color(forWavelength: cursorLambda)
    SpectrumDraw.segment(ctx, CGPoint(x: cx, y: y0 - 10), CGPoint(x: cx, y: y1), color: col.opacity(0.2), width: 6)
    SpectrumDraw.segment(ctx, CGPoint(x: cx, y: y0 - 10), CGPoint(x: cx, y: y1), color: col, width: 1.4)
  }

  /// Hydrogen: the famous lines labelled and the spectroscope strip (visible window outlined).
  private static func hydrogen(
    _ ctx: GraphicsContext, _ size: CGSize, mode: SampleMode, curve: [Double], x0: CGFloat, x1: CGFloat, y0: CGFloat, y1: CGFloat,
    cu: Double
  ) {
    let h = size.height
    let axis = SampleKey.hydrogen.axis
    let span = log(axis.to / axis.from)
    for l in Samples.hydrogenLines(mode: mode) {
      let u = log(l.lambda / axis.from) / span
      guard u >= 0, u <= 1 else { continue }
      let x = x0 + CGFloat(u) * (x1 - x0)
      let col = BandPalette.color(forWavelength: l.lambda)
      let seen = u <= cu
      ctx.fill(
        Path(CGRect(x: x - 1, y: h - 32, width: 2, height: 26)),
        with: .color(seen ? col.opacity(0.35 + 0.65 * l.strength) : .white.opacity(0.05)))
      if seen, let name = Samples.lineName(n1: l.n1, n2: l.n2) {
        // Sit the name on the drawn peak (the curve's maximum within ±3 samples).
        let n = curve.count - 1
        let i = Int((u * Double(n)).rounded())
        let peak = (max(0, i - 3)...min(n, i + 3)).map { curve[$0] }.max() ?? l.strength
        SpectrumDraw.label(
          ctx, name, CGPoint(x: x, y: y1 - CGFloat(min(1.05, peak)) * (y1 - y0) - 10), color: col, anchor: .center, size: 9.5,
          weight: .semibold)
      }
    }
    SpectrumDraw.label(ctx, "SPECTROSCOPE", CGPoint(x: x0, y: h - 40), size: 8.5)
    let ua = log(400e-9 / axis.from) / span, ub = log(700e-9 / axis.from) / span
    ctx.stroke(
      Path(CGRect(x: x0 + CGFloat(ua) * (x1 - x0), y: h - 33, width: CGFloat(ub - ua) * (x1 - x0), height: 28)),
      with: .color(.white.opacity(0.15)), lineWidth: 1)
  }
}

/// Lab aux: the sample's badge and note (or the Earth-field explanation and links).
struct SpectrumLabAux: View {
  @Environment(AppModel.self) private var app

  var body: some View {
    let model = app.spectrum
    VStack(alignment: .leading, spacing: 12) {
      if model.extras.labEarth {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          ProvenanceBadges([model.earthProvenance, .model], compact: true)
          Text(
            "Your magnetometer sets B\u{2080}. Water protons precess at \u{03B3}\u{2032}\u{209A}\u{00B7}|B|, about 2.1 kHz in 50 \u{00B5}T, so the 'radio wave' is about 140 km long. At this field ethanol's shifts are millihertz and its multiplets collapse into one line. The line is drawn at the screen's resolution; the real one is about 1 Hz wide."
          )
          .panelCaption()
        }
        GlassEffectContainer(spacing: 10) {
          ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) { earthButtons(model) }
            VStack(alignment: .leading, spacing: 10) { earthButtons(model) }
          }
        }
        SpectrumSignalButtons(
          scopeTitle: "|B| in Scope", patchTitle: "Add |B| to Patch", idPrefix: "spectrum-lab", openScope: model.openLabInScope,
          addPatch: model.addLabToPatch)
      } else {
        let s = model.state.lab.sample
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          ProvenanceBadge(Provenance(rawValue: s.source.rawValue) ?? .model, compact: true)
          Text(s.note(mode: model.state.lab.mode)).panelCaption()
        }
        SpectrumSignalButtons(
          scopeTitle: "Open in Scope", patchTitle: "Add to Patch", idPrefix: "spectrum-lab", openScope: model.openLabInScope,
          addPatch: model.addLabToPatch)
      }
    }
  }

  @ViewBuilder private func earthButtons(_ model: SpectrumModel) -> some View {
    ActionButton("Tune to line", symbol: "scope") { model.tuneToEarthLine() }
      .disabled(model.earthLine == nil)
      .accessibilityHint(model.earthLine == nil ? "Waiting for the magnetometer." : "Moves the cursor onto the water-proton line.")
      .accessibilityIdentifier("spectrum-lab-earth-tune")
    ActionButton("Hear it in Spin", symbol: "gyroscope") {
      // Spin answers the `live.nmr` focus with its proton view on the live field (and Hear it
      // when Sound is on); see API-spin-ui.md, `handleFocus`.
      // Without a reading yet, the 50 µT landmark stands in (a model value, not a live one).
      let live = model.earthLine
      let f = live ?? Spectrum.longWaveLandmarks[0].frequency
      app.focus(
        SpectrumMarker(
          id: "live.nmr", label: "Earth-field NMR \(JSFormat.frequency(f))", frequency: f,
          provenance: live == nil ? .model : model.earthProvenance, tab: .spin))
    }
    .accessibilityHint("Opens the Spin tab's proton view on this field, which plays the precession at its true pitch.")
    .accessibilityIdentifier("spectrum-lab-earth-spin")
  }
}

/// The Earth-field NMR stage: 500 Hz – 4 kHz, the range of Earth's field shaded, the live
/// water-proton line and the cursor. Holds the magnetometer while on screen.
private struct EarthFieldStage: View {
  @Environment(AppModel.self) private var app
  let height: CGFloat
  /// One holder name per stage instance: the tab's stage and the full-screen copy are both
  /// alive while the full-screen view shows, and closing it must not release the tab's hold.
  @State private var owner = "spectrum.lab.earth.\(UUID().uuidString.prefix(8))"

  var body: some View {
    let model = app.spectrum
    let channel = app.live.channel(.magnetometer)
    PermissionGate(
      channel: channel, startTitle: "Start magnetometer",
      explanation: "Spectra reads the magnetometer so the lab can use Earth's own field as its magnet."
    ) {
      VisibleTimeline(minimumInterval: 0.1) { _ in
        let reading = Self.read(app)
        stage(model, field: reading)
          .onChange(of: reading, initial: true) { _, b in
            model.earthField = b
            if model.earthProvenance != channel.provenance { model.earthProvenance = channel.provenance }
          }
      }
    }
    .frame(minHeight: height)
    .onAppear {
      model.earthProvenance = channel.provenance
      app.live.acquire(.magnetometer, by: owner)
    }
    .onDisappear { app.live.release(.magnetometer, by: owner) }
  }

  /// Mean of the last half second of `mag.norm` (µT).
  private static func read(_ app: AppModel) -> Double? {
    guard let s = app.streams.stream("mag.norm") else { return nil }
    let snap = s.ring.snapshot(since: SignalClock.now() - 0.5)
    guard !snap.isEmpty else { return s.ring.latest.map { Double($0.value) } }
    let sum = snap.values.reduce(0) { $0 + Double($1) }
    let mean = sum / Double(snap.count)
    return mean.isFinite ? (mean * 100).rounded() / 100 : nil
  }

  private func stage(_ model: SpectrumModel, field: Double?) -> some View {
    let sweep = model.extras.earthSweep
    let line = field.flatMap { $0 > 0 ? Samples.earthFieldLarmor(b0: $0 * 1e-6) : nil }
    let lambda = model.active.lambda
    return PlotWell(height: height, grid: 0) {
      GeometryReader { geo in
        Canvas { ctx, size in
          EarthDrawing.draw(ctx, size, line: line, sweep: sweep, cursorLambda: lambda)
        }
        .contentShape(.rect)
        .gesture(
          DragGesture(minimumDistance: 0).onChanged { v in
            if model.state.lab.sweeping { model.state.lab.sweeping = false }
            let g = LabDrawing.plotX(width: geo.size.width)
            let before = model.extras.earthSweep
            model.setLabSweep(Double((v.location.x - g.lowerBound) / (g.upperBound - g.lowerBound)))
            if Int(before * 24) != Int(model.extras.earthSweep * 24) { Haptics.shared.tick() }
          })
      }
    }
    .overlay(alignment: .topLeading) { StageTag("Water protons \u{00B7} Earth field", color: Theme.phosphor).padding(10) }
    .overlay(alignment: .topTrailing) {
      StageTag(field.map { "|B| \(SpectraFormat.significant($0, 4)) \u{00B5}T \(model.earthProvenance.badge)" } ?? "|B| \u{2014}", color: Theme.fieldB)
        .padding(10)
    }
    .accessibilityElement()
    .accessibilityLabel("Earth-field NMR")
    .accessibilityValue(
      line.map { "Water line at \(JSFormat.frequency($0)); cursor at \(JSFormat.frequency(EarthFieldAxis.frequency(at: sweep)))" }
        ?? "Waiting for the magnetometer")
    .accessibilityAdjustableAction { direction in
      model.state.lab.sweeping = false
      model.setLabSweep(sweep + (direction == .increment ? 0.01 : -0.01))
    }
    .accessibilityIdentifier("spectrum-lab-earth-stage")
  }
}

/// Earth-field stage drawing.
enum EarthDrawing {
  static func draw(_ ctx: GraphicsContext, _ size: CGSize, line: Double?, sweep: Double, cursorLambda: Double) {
    let w = size.width, h = size.height
    let xr = LabDrawing.plotX(width: w)
    let x0 = xr.lowerBound, x1 = xr.upperBound, y0: CGFloat = 58, y1 = h - 34
    func x(_ f: Double) -> CGFloat { x0 + CGFloat(EarthFieldAxis.fraction(of: f)) * (x1 - x0) }
    // Earth's field range (25–65 µT) shaded.
    let fa = Samples.earthFieldLarmor(b0: EarthFieldAxis.fieldRange.lowerBound * 1e-6)
    let fb = Samples.earthFieldLarmor(b0: EarthFieldAxis.fieldRange.upperBound * 1e-6)
    ctx.fill(Path(CGRect(x: x(fa), y: y0, width: x(fb) - x(fa), height: y1 - y0)), with: .color(Theme.phosphor.opacity(0.05)))
    // The band's label (two short lines): inside the band at the top, left or right, else just
    // outside it, wherever the live line and its frequency label are not.
    let tagW: CGFloat = 50, tagH: CGFloat = 25
    let lineX = line.map(x)
    let clear = { (left: CGFloat) in
      left >= x0 - 1 && left + tagW <= x1 + 1 && (lineX.map { $0 < left - 8 || $0 > left + tagW + 8 } ?? true)
    }
    let slots = [x(fa) + 2, x(fb) - tagW - 2, x(fb) + 4, x(fa) - tagW - 4]
    let tagX = slots.first(where: clear) ?? slots[0]
    let tagY = slots.first(where: clear) == nil ? y1 - tagH - 4 : y0 + 4
    ctx.fill(Path(roundedRect: CGRect(x: tagX, y: tagY, width: tagW, height: tagH), cornerRadius: 3), with: .color(Theme.plotWell.opacity(0.85)))
    SpectrumDraw.label(ctx, "EARTH", CGPoint(x: tagX + 4, y: tagY + 7), color: Theme.phosphor.opacity(0.7), size: 8.5)
    SpectrumDraw.label(ctx, "25\u{2013}65 \u{00B5}T", CGPoint(x: tagX + 4, y: tagY + 18), color: Theme.phosphor.opacity(0.7), size: 8.5)
    // Axis.
    SpectrumDraw.segment(ctx, CGPoint(x: x0, y: y1), CGPoint(x: x1, y: y1), color: Theme.axis)
    for f in stride(from: 500.0, through: 4000, by: 500) {
      let px = x(f)
      SpectrumDraw.segment(ctx, CGPoint(x: px, y: y1), CGPoint(x: px, y: y1 + 4), color: Theme.axis)
      if Int(f) % 1000 == 0 || f == 500 {
        SpectrumDraw.label(ctx, f >= 1000 ? "\(Int(f / 1000)) kHz" : "500 Hz", CGPoint(x: px, y: y1 + 14), anchor: .center, size: 8.5)
      }
    }
    // The line, drawn at display resolution.
    if let f0 = line {
      var pts: [CGPoint] = []
      var px = x0
      while px <= x1 {
        let f = EarthFieldAxis.frequency(at: Double((px - x0) / (x1 - x0)))
        let v = Samples.lorentz(f, f0, EarthFieldAxis.displayHalfWidth)
        pts.append(CGPoint(x: px, y: y1 - CGFloat(v) * (y1 - y0)))
        px += 1
      }
      SpectrumDraw.line(ctx, pts, color: Theme.phosphor, width: 1.8, glow: 0.8)
      let lx = min(x1 - 30, max(x0 + 30, x(f0)))
      SpectrumDraw.label(ctx, JSFormat.frequency(f0), CGPoint(x: lx, y: y0 - 10), color: Theme.phosphor, anchor: .center, size: 10, weight: .semibold)
    } else {
      SpectrumDraw.label(ctx, "WAITING FOR |B|", CGPoint(x: (x0 + x1) / 2, y: (y0 + y1) / 2), anchor: .center)
    }
    // Cursor.
    let cx = x0 + CGFloat(min(1, max(0, sweep))) * (x1 - x0)
    let col = BandPalette.color(forWavelength: cursorLambda)
    // From the band top down, so the line's frequency label above it stays clear.
    SpectrumDraw.segment(ctx, CGPoint(x: cx, y: y0), CGPoint(x: cx, y: y1), color: col.opacity(0.2), width: 6)
    SpectrumDraw.segment(ctx, CGPoint(x: cx, y: y0), CGPoint(x: cx, y: y1), color: col, width: 1.4)
  }
}
