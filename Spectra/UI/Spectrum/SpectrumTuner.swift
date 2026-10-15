import SwiftUI

/// Column layout of the vertical tuner (spectra-lab `tuner.js` `layout`): log₁₀ λ runs down
/// the stage over the visible `window` (short waves at the top).
struct TunerGeometry {
  let size: CGSize
  let window: ClosedRange<Double>
  let top: CGFloat = 26
  let bottom: CGFloat
  let lam: CGFloat, strip: CGFloat, stripW: CGFloat, f: CGFloat, e: CGFloat, comp: CGFloat, compSize: CGFloat

  init(size: CGSize, window: ClosedRange<Double>) {
    self.size = size
    self.window = window
    bottom = max(60, size.height - 16)
    let narrow = size.width < 520
    lam = narrow ? 52 : 70
    strip = narrow ? 58 : 80
    stripW = narrow ? 44 : 70
    f = narrow ? 108 : 160
    e = narrow ? 148 : 214
    comp = narrow ? 192 : 290
    compSize = narrow ? 9.5 : 10.5
  }

  var span: Double { max(1e-9, window.upperBound - window.lowerBound) }
  /// Points per decade.
  var decade: CGFloat { (bottom - top) / CGFloat(span) }

  func y(_ lg: Double) -> CGFloat { top + CGFloat((lg - window.lowerBound) / span) * (bottom - top) }
  func lg(at y: CGFloat) -> Double { window.lowerBound + Double((y - top) / (bottom - top)) * span }
  func visible(_ py: CGFloat) -> Bool { py >= top - 2 && py <= bottom + 2 }
}

/// 02 Spectrum tuner: the poster as a draggable log ruler with λ, f and E axes, size
/// comparisons, the ionizing and pair-production lines, the long-wave landmarks, a cursor per
/// source, a dimmer marker for every other active frequency in the app, the thermal Planck
/// curve and the pulse bandwidth. Drag to tune (band edges are detents), pinch to zoom.
struct SpectrumTunerStage: View {
  @Environment(AppModel.self) private var app
  var height: CGFloat = 470

  @State private var dragging = false
  @State private var lastDecade: Int?
  @State private var pinchBase: CGFloat?
  /// The sources and active index when the touch began. The drag tunes on touch-down, so the
  /// first finger of a pinch has already moved a cursor when the pinch is recognized; the
  /// pinch puts it back.
  @State private var beforeTouch: (sources: [WaveSource], active: Int)?
  /// A pinch happened during this touch: when one finger lifts, the drag that is still
  /// tracking the other must not retune the cursor to it.
  @State private var pinched = false
  /// The drag gesture is tracking a finger, tuning or not (resets on end and on cancel).
  @GestureState private var touching = false

  var body: some View {
    let model = app.spectrum
    let state = model.state
    let window = model.tunerWindow
    let others = app.markers.filter { !$0.id.hasPrefix("spectrum.") }
    PlotWell(height: height, grid: 0) {
      GeometryReader { geo in
        let g = TunerGeometry(size: geo.size, window: window)
        Canvas { ctx, _ in
          TunerDrawing.draw(ctx, g, state: state, others: others)
        }
        .contentShape(.rect)
        .gesture(drag(g))
        .simultaneousGesture(pinch(g))
        .onChange(of: touching) { _, active in if !active { touchEnded() } }
      }
    }
    .accessibilityElement()
    .accessibilityLabel("Spectrum tuner")
    .accessibilityValue(accessibilityValue(state))
    .accessibilityHint("Swipe up or down to tune the active source by a tenth of a decade.")
    .accessibilityAdjustableAction { direction in
      let step = direction == .increment ? 0.1 : -0.1
      let lg = log10(model.active.lambda) + step
      model.setLambda(pow(10, Spectrum.clampRulerLog(lg)))
      model.follow()
    }
    .accessibilityIdentifier("spectrum-tuner")
  }

  private func accessibilityValue(_ state: SpectraState) -> String {
    state.enabledIndices.map { i in
      let s = state.sources[i]
      let d = Spectrum.describe(s.lambda)
      return "Source \(SpectraState.sourceNames[i]) \(d.text.lambda), \(d.text.f)\(i == state.active ? ", active" : "")"
    }.joined(separator: "; ")
  }

  private func drag(_ g: TunerGeometry) -> some Gesture {
    DragGesture(minimumDistance: 0)
      .updating($touching) { _, state, _ in state = true }
      .onChanged { v in
        guard pinchBase == nil, !pinched else { return }
        let model = app.spectrum
        if !dragging {
          dragging = true
          beforeTouch = (model.state.sources, model.state.active)
          // Grab the nearest cursor within 16 pt, otherwise move the active one.
          var best = -1
          var bestDistance: CGFloat = 16
          for i in model.state.enabledIndices {
            let d = abs(g.y(log10(model.state.sources[i].lambda)) - v.startLocation.y)
            if d < bestDistance {
              bestDistance = d
              best = i
            }
          }
          if best >= 0, best != model.state.active { model.selectSource(best) }
          Haptics.shared.grab()
        }
        let lg = Spectrum.clampRulerLog(min(g.window.upperBound, max(g.window.lowerBound, g.lg(at: v.location.y))))
        let decade = Int(floor(lg))
        if let lastDecade, lastDecade != decade { Haptics.shared.tick() }
        lastDecade = decade
        if model.active.kind == .thermal {
          model.edit(.temperature(SpectrumDisplay.thermalTemperature(atLog: lg)))
        } else {
          model.edit(.lambda(pow(10, lg)))
        }
      }
  }

  /// The end (or cancellation) of a touch: the next one starts fresh.
  private func touchEnded() {
    dragging = false
    lastDecade = nil
    beforeTouch = nil
    pinched = false
  }

  private func pinch(_ g: TunerGeometry) -> some Gesture {
    MagnifyGesture()
      .onChanged { v in
        let base = pinchBase ?? 1
        if pinchBase == nil {
          // Ignore the drag for the rest of this touch (reset when the touch ends).
          pinched = true
          Haptics.shared.grab()
          // Undo what the first finger's touch-down tuned: a pinch only zooms.
          if let b = beforeTouch {
            var s = app.spectrum.state
            s.sources = b.sources
            s.active = b.active
            app.spectrum.state = s
          }
        }
        let factor = v.magnification / base
        pinchBase = v.magnification
        guard factor.isFinite, factor > 0 else { return }
        let anchor = g.lg(at: v.startLocation.y)
        let model = app.spectrum
        let before = model.tunerWindow
        model.setTunerWindow(TunerWindow.zoomed(before, factor: Double(factor), anchor: anchor))
        if model.tunerWindow == before, factor != 1 { Haptics.shared.boundary() }
      }
      .onEnded { _ in
        pinchBase = nil
        if !touching { pinched = false }
      }
  }
}

/// The tuner drawing (Canvas), split out so the stage body stays small.
enum TunerDrawing {
  /// A label's footprint, so later labels can step aside.
  struct Box {
    var x: ClosedRange<CGFloat>
    var y: ClosedRange<CGFloat>
    func overlaps(_ o: Box) -> Bool { x.overlaps(o.x) && y.overlaps(o.y) }
  }

  /// Monospaced advance at `size` (SF Mono is 0.6 em).
  static func textWidth(_ text: String, size: CGFloat) -> CGFloat { CGFloat(text.count) * size * 0.6 }

  static func draw(_ ctx: GraphicsContext, _ g: TunerGeometry, state: SpectraState, others: [SpectrumMarker]) {
    let w = g.size.width
    // Column headers.
    SpectrumDraw.label(ctx, "\u{03BB}", CGPoint(x: g.lam, y: 12), anchor: .trailing)
    SpectrumDraw.label(ctx, "f (Hz)", CGPoint(x: g.f, y: 12))
    SpectrumDraw.label(ctx, "E", CGPoint(x: g.e, y: 12))
    SpectrumDraw.label(ctx, "ONE WAVE \u{2248}", CGPoint(x: g.comp, y: 12))

    bandStrip(ctx, g)
    lambdaTicks(ctx, g)
    frequencyAndEnergyTicks(ctx, g)
    let highlight = comparisons(ctx, g, active: state.activeSource.lambda)
    landmarkLines(ctx, g)
    thresholdLines(ctx, g)
    var boxes = landmarkLabels(g).map(\.box) + thresholdLabels(g).map(\.box)
    for m in others { otherMarker(ctx, g, m, width: w, boxes: &boxes) }
    sources(ctx, g, state: state, width: w)
    // Labels that must stay readable where a cursor crosses them, drawn last on a backing.
    if let highlight {
      backed(ctx, highlight.text, CGPoint(x: g.comp, y: highlight.y), color: Theme.text, size: g.compSize, weight: .bold)
    }
    for l in landmarkLabels(g) { backed(ctx, l.text, l.at, color: Theme.phosphor.opacity(0.85), size: l.size) }
    for l in thresholdLabels(g) { backed(ctx, l.text, l.at, color: l.color, size: l.size) }
  }

  /// A label on a plot-well backing.
  private static func backed(
    _ ctx: GraphicsContext, _ text: String, _ p: CGPoint, color: Color, size: CGFloat, weight: Font.Weight = .medium
  ) {
    ctx.fill(
      Path(roundedRect: CGRect(x: p.x - 3, y: p.y - 6.5, width: textWidth(text, size: size) + 6, height: 13), cornerRadius: 3),
      with: .color(Theme.plotWell.opacity(0.88)))
    SpectrumDraw.label(ctx, text, p, color: color, size: size, weight: weight)
  }

  /// A window edge: Core's length text, with thousands grouped past 1,000 km ("100,000 km"
  /// where the web would print "100000 km").
  static func windowText(_ lg: Double) -> String {
    let lambda = pow(10, lg)
    guard lambda >= 1e6 else { return Spectrum.describe(lambda).text.lambda }
    let km = (lambda / 1e3).formatted(.number.precision(.significantDigits(3)).locale(Locale(identifier: "en_US")))
    return km + " km"
  }

  /// Decade label: the web's "1 nm" … "100 km", then "10⁶ m" … "10⁸ m" on the long ruler
  /// (the web would print "100000 km", which does not fit the column).
  static func decadeText(_ e: Int) -> String {
    e > 5 ? "10" + SpectraFormat.superscript(e) + " m" : SpectrumDisplay.decadeLabel(e)
  }

  // MARK: Band strip

  private static let ituNames = ["LF", "VLF", "ULF", "SLF", "ELF"]

  private static func bandStrip(_ ctx: GraphicsContext, _ g: TunerGeometry) {
    let thresholds = thresholdYs(g)
    for b in Spectrum.bands {
      let lo = log10(max(b.lo, 1e-30)), hi = log10(min(b.hi, 1e30))
      let y0 = max(g.top, g.y(lo)), y1 = min(g.bottom, g.y(hi))
      guard y1 > y0 else { continue }
      if b.key == .visible {
        var py = y0
        while py < y1 {
          let nm = 1e9 * pow(10, g.lg(at: py + 0.5))
          let c = Spectrum.spectralRGB(nm: nm)
          let color = Color(red: max(c.x, 0.15), green: max(c.y, 0.15), blue: max(c.z, 0.15))
          ctx.fill(Path(CGRect(x: g.strip, y: py, width: g.stripW, height: min(1.2, y1 - py))), with: .color(color))
          py += 1
        }
      } else {
        let color = Color(spectraHex: b.colorHex)
        ctx.fill(Path(CGRect(x: g.strip, y: y0, width: g.stripW, height: y1 - y0)), with: .color(color.opacity(0.2)))
        // Radio is named over its first three decades; beyond 1 km the ITU bands take over.
        let labelEnd = b.key == .radio ? min(y1, g.y(3)) : y1
        if labelEnd - y0 > 16 {
          let text = b.key == .radio ? "RADIO" : b.key == .microwave ? "\u{00B5}WAVE" : b.short.instrumentCaps
          var ly = (y0 + labelEnd) / 2
          // Step off a threshold line that runs through the name (γ and the pair line).
          if let t = thresholds.first(where: { abs($0 - ly) < 7 }) { ly = min(labelEnd - 6, t + 9) }
          SpectrumDraw.label(ctx, text, CGPoint(x: g.strip + g.stripW / 2, y: ly), color: color, anchor: .center, size: 9)
        }
      }
    }
    // ITU names for the decades beyond 1 km (native long ruler), stepped off the dashed
    // landmark lines (mains, Schumann) that run through the strip.
    let landmarkYs = Spectrum.longWaveLandmarks.map { g.y(log10($0.lambda)) }
    for (i, name) in ituNames.enumerated() {
      let y0 = max(g.top, g.y(Double(3 + i))), y1 = min(g.bottom, g.y(Double(4 + i)))
      guard y1 - y0 > 12 else { continue }
      var ly = (y0 + y1) / 2
      if let l = landmarkYs.first(where: { abs($0 - ly) < 7 }) {
        ly = l > ly ? max(y0 + 5, l - 8) : min(y1 - 5, l + 8)
      }
      SpectrumDraw.label(
        ctx, name, CGPoint(x: g.strip + g.stripW / 2, y: ly), color: Color(spectraHex: Spectrum.band(.radio).colorHex).opacity(0.85),
        anchor: .center, size: 8.5)
    }
    let outline = Path(
      roundedRect: CGRect(x: g.strip + 0.5, y: g.top + 0.5, width: g.stripW - 1, height: g.bottom - g.top - 1), cornerRadius: 10)
    ctx.stroke(outline, with: .color(.white.opacity(0.14)), lineWidth: 1)
  }

  // MARK: Axes

  private static func lambdaTicks(_ ctx: GraphicsContext, _ g: TunerGeometry) {
    let every = g.decade < 9 ? 3 : (g.decade < 18 ? 2 : 1)
    let lo = Int(ceil(g.window.lowerBound)), hi = Int(floor(g.window.upperBound))
    guard lo <= hi else { return }
    for e in lo...hi {
      let py = g.y(Double(e))
      SpectrumDraw.segment(ctx, CGPoint(x: g.strip - 7, y: py), CGPoint(x: g.strip, y: py), color: Color(hex: 0x9CB5A6).opacity(0.45))
      if (e - Int(Spectrum.rulerLogMin)) % every == 0 {
        SpectrumDraw.label(ctx, TunerDrawing.decadeText(e), CGPoint(x: g.lam - 4, y: py), color: Theme.muted, anchor: .trailing, size: 9.5)
      }
    }
  }

  /// y of the two threshold lines (their labels sit just above them).
  private static func thresholdYs(_ g: TunerGeometry) -> [CGFloat] {
    [SI.ionizingEV, SI.pairThresholdEV].map { g.y(log10(Spectrum.wavelength(eV: $0))) }
  }

  /// True when a tick label at `py` would sit under a threshold label.
  private static func underThresholdLabel(_ py: CGFloat, _ g: TunerGeometry) -> Bool {
    thresholdYs(g).contains { py > $0 - 18 && py < $0 + 4 }
  }

  private static func frequencyAndEnergyTicks(_ ctx: GraphicsContext, _ g: TunerGeometry) {
    let logC = log10(SI.c)
    let step = g.decade < 8 ? 4 : 2
    for n in stride(from: 22, through: 0, by: -step) {
      let py = g.y(logC - Double(n))
      guard g.visible(py), !underThresholdLabel(py, g) else { continue }
      SpectrumDraw.label(ctx, "10" + SpectraFormat.superscript(n), CGPoint(x: g.f, y: py), color: Theme.dialTheta.opacity(0.85))
    }
    let energies: [(String, Double)] = [
      ("10 MeV", 1e7), ("1 MeV", 1e6), ("1 keV", 1e3), ("1 eV", 1), ("1 meV", 1e-3), ("1 \u{00B5}eV", 1e-6), ("1 neV", 1e-9),
      ("1 peV", 1e-12),
    ]
    for (text, ev) in energies {
      let py = g.y(log10(Spectrum.wavelength(eV: ev)))
      guard g.visible(py), !underThresholdLabel(py, g) else { continue }
      SpectrumDraw.label(ctx, text, CGPoint(x: g.e, y: py), color: Theme.amber.opacity(0.85))
    }
  }

  /// Size comparisons; the one nearest the active cursor is returned (drawn later, on top).
  private static func comparisons(_ ctx: GraphicsContext, _ g: TunerGeometry, active: Double) -> (text: String, y: CGFloat)? {
    guard g.comp < g.size.width - 40 else { return nil }
    let near = Spectrum.nearestComparison(active)
    var highlight: (text: String, y: CGFloat)?
    for c in Spectrum.sizeComparisons {
      let py = g.y(log10(c.size))
      guard py >= g.top, py <= g.bottom else { continue }
      let on = c.label == near.label && near.decades < 0.5
      SpectrumDraw.segment(ctx, CGPoint(x: g.comp - 10, y: py), CGPoint(x: g.comp - 4, y: py), color: on ? Theme.text : Color(hex: 0x4F6457))
      if on {
        highlight = (c.label, py)
      } else {
        SpectrumDraw.label(ctx, c.label, CGPoint(x: g.comp, y: py), color: Color(hex: 0x6F887B), size: g.compSize, weight: .regular)
      }
    }
    return highlight
  }

  // MARK: Landmarks and thresholds

  private struct Label {
    var text: String
    var at: CGPoint
    var size: CGFloat
    var color: Color = Theme.phosphor
    var box: Box { Box(x: (at.x - 3)...(at.x + TunerDrawing.textWidth(text, size: size) + 3), y: (at.y - 7)...(at.y + 7)) }
  }

  /// The long-wave landmarks of the native ruler (Earth-field NMR, mains 60/50 Hz, Schumann).
  private static func landmarkLines(_ ctx: GraphicsContext, _ g: TunerGeometry) {
    for lm in Spectrum.longWaveLandmarks {
      let py = g.y(log10(lm.lambda))
      guard py >= g.top, py <= g.bottom else { continue }
      SpectrumDraw.segment(
        ctx, CGPoint(x: g.strip, y: py), CGPoint(x: g.comp - 14, y: py), color: Theme.phosphor.opacity(0.4), dash: [2, 3])
    }
  }

  private static func landmarkLabels(_ g: TunerGeometry) -> [Label] {
    Spectrum.longWaveLandmarks.compactMap { lm in
      let py = g.y(log10(lm.lambda))
      guard py >= g.top, py <= g.bottom else { return nil }
      let (text, dy): (String, CGFloat) =
        switch lm.id {
        case "earthNMR": ("Earth-field NMR " + JSFormat.frequency(lm.frequency), 0)
        case "mains60": ("Mains 60 Hz", -5)
        case "mains50": ("Mains 50 Hz", 6)
        default: ("Schumann 7.83 Hz", 0)
        }
      return Label(text: text, at: CGPoint(x: g.comp, y: py + dy), size: g.compSize - 1)
    }
  }

  private static let thresholdTexts: [(ev: Double, text: String, color: Color)] = [
    (SI.ionizingEV, "\u{25B2} IONIZING 10 eV", Theme.ionizing),
    (SI.pairThresholdEV, "\u{25B2} PAIR 1.022 MeV", Theme.dialPhi),
  ]

  private static func thresholdLines(_ ctx: GraphicsContext, _ g: TunerGeometry) {
    for t in thresholdTexts {
      let py = g.y(log10(Spectrum.wavelength(eV: t.ev)))
      guard py >= g.top, py <= g.bottom else { continue }
      SpectrumDraw.segment(ctx, CGPoint(x: g.strip, y: py), CGPoint(x: g.comp - 14, y: py), color: t.color, width: 1.2, dash: [4, 3])
    }
  }

  /// Threshold labels sit just above their lines, sized to end before the comparison column.
  private static func thresholdLabels(_ g: TunerGeometry) -> [Label] {
    thresholdTexts.compactMap { t in
      let py = g.y(log10(Spectrum.wavelength(eV: t.ev)))
      guard py >= g.top, py <= g.bottom else { return nil }
      let room = g.comp - 12 - g.f
      let size = min(9, max(8, room / (CGFloat(t.text.count) * 0.6)))
      return Label(text: t.text, at: CGPoint(x: g.f, y: py - 8), size: size, color: t.color)
    }
  }

  /// Every other active frequency in the app: a dim line with its label at the right edge,
  /// above the line, or below it (or a step further) when another label is already there.
  private static func otherMarker(_ ctx: GraphicsContext, _ g: TunerGeometry, _ m: SpectrumMarker, width: CGFloat, boxes: inout [Box]) {
    let py = g.y(m.logLambda)
    guard m.logLambda.isFinite, py >= g.top, py <= g.bottom else { return }
    let color = BandPalette.color(for: m)
    SpectrumDraw.segment(ctx, CGPoint(x: g.strip, y: py), CGPoint(x: width, y: py), color: color.opacity(0.38), width: 1, dash: m.isEM ? [] : [2, 2])
    let size: CGFloat = 8.5
    let tw = textWidth(m.label, size: size)
    let xs = (width - 4 - tw)...(width - 4)
    let candidates: [CGFloat] = [py - 6, py + 7, py - 17, py + 18, py - 28, py + 29]
    let fits = { (c: CGFloat) in
      c > g.top - 4 && c < g.bottom + 4 && !boxes.contains { $0.overlaps(Box(x: xs, y: (c - 5)...(c + 5))) }
    }
    let ly = candidates.first(where: fits) ?? (py - 6)
    boxes.append(Box(x: xs, y: (ly - 5)...(ly + 5)))
    SpectrumDraw.label(ctx, m.label, CGPoint(x: width - 4, y: ly), color: color.opacity(0.75), anchor: .trailing, size: size)
  }

  // MARK: Sources

  private static func sources(_ ctx: GraphicsContext, _ g: TunerGeometry, state: SpectraState, width: CGFloat) {
    for i in state.sources.indices where state.sources[i].enabled {
      let s = state.sources[i]
      let color = BandPalette.color(forWavelength: s.lambda)
      let isActive = i == state.active
      if s.kind == .thermal { planck(ctx, g, s) }
      if s.kind == .pulse {
        let bw = Wave.pulseBandwidth(s)
        let y0 = g.y(log10(s.lambda / (1 + bw / 2))), y1 = g.y(log10(s.lambda / max(1e-9, 1 - bw / 2)))
        ctx.fill(
          Path(CGRect(x: g.strip - 4, y: min(y0, y1), width: g.stripW + 8, height: max(2, abs(y1 - y0)))),
          with: .color(Theme.amber.opacity(0.18)))
      }
      let py = g.y(log10(s.lambda))
      guard py >= g.top - 10, py <= g.bottom + 10 else { continue }
      SpectrumDraw.segment(ctx, CGPoint(x: 0, y: py), CGPoint(x: width, y: py), color: color.opacity(isActive ? 0.18 : 0.08), width: 6)
      SpectrumDraw.segment(ctx, CGPoint(x: 0, y: py), CGPoint(x: width, y: py), color: color.opacity(isActive ? 1 : 0.55), width: 1.5)
      let pillW = g.stripW + 26, px = g.strip - 13
      let pill = Path(roundedRect: CGRect(x: px, y: py - 10, width: pillW, height: 20), cornerRadius: 10)
      ctx.fill(pill, with: .color(Color(hex: 0x0B1210)))
      ctx.stroke(pill, with: .color(color), lineWidth: isActive ? 1.8 : 1)
      SpectrumDraw.label(
        ctx, "\(SpectraState.sourceNames[i]) \(Spectrum.describe(s.lambda).text.lambda)", CGPoint(x: px + pillW / 2, y: py + 0.5),
        color: color, anchor: .center, size: 9.5, weight: .semibold)
    }
  }

  /// Planck's law per log-wavelength bin, B_λ(T)·λ, normalized to its Wien peak.
  private static func planck(_ ctx: GraphicsContext, _ g: TunerGeometry, _ s: WaveSource) {
    let lw = Wave.wienPeak(s.temperature)
    let peak = Wave.planckLambda(lw, temperature: s.temperature) * lw
    guard peak > 0, peak.isFinite else { return }
    let x0 = g.strip + g.stripW
    let span = max(10, g.comp - g.strip - g.stripW - 24)
    var p = Path()
    p.move(to: CGPoint(x: x0, y: g.top))
    var py = g.top
    while py <= g.bottom {
      let l = pow(10, g.lg(at: py))
      let v = Wave.planckLambda(l, temperature: s.temperature) * l / peak
      p.addLine(to: CGPoint(x: x0 + CGFloat(v.isFinite ? min(1.2, max(0, v)) : 0) * span, y: py))
      py += 2
    }
    p.addLine(to: CGPoint(x: x0, y: g.bottom))
    p.closeSubpath()
    ctx.fill(p, with: .color(Theme.amber.opacity(0.13)))
    ctx.stroke(p, with: .color(Theme.amber.opacity(0.7)), lineWidth: 1)
  }
}

/// Tuner toolbar: zoom the visible decades, or jump to the full ruler / the web range.
struct SpectrumTunerToolbar: View {
  @Environment(AppModel.self) private var app

  var body: some View {
    let model = app.spectrum
    let w = model.tunerWindow
    ViewThatFits(in: .horizontal) {
      HStack(spacing: 8) {
        windowLabel(w)
        Spacer(minLength: 4)
        buttons(model)
      }
      VStack(alignment: .leading, spacing: 8) {
        windowLabel(w)
        buttons(model)
      }
    }
  }

  private func windowLabel(_ w: ClosedRange<Double>) -> some View {
      VStack(alignment: .leading, spacing: 2) {
        Text("WINDOW").font(Theme.eyebrowFont).tracking(1.4).foregroundStyle(Theme.muted)
        Text("\(TunerDrawing.windowText(w.lowerBound)) \u{2013} \(TunerDrawing.windowText(w.upperBound))")
          .font(.system(.caption, design: .monospaced)).foregroundStyle(Theme.text).lineLimit(1).minimumScaleFactor(0.7)
      }
      .accessibilityElement(children: .combine)
  }

  private func buttons(_ model: SpectrumModel) -> some View {
      GlassEffectContainer(spacing: 6) {
        HStack(spacing: 6) {
          SpectrumIconButton(title: "Zoom out", symbol: "minus.magnifyingglass", id: "spectrum-tuner-zoom-out") {
            zoom(model, 0.75)
          }
          SpectrumIconButton(title: "Zoom in", symbol: "plus.magnifyingglass", id: "spectrum-tuner-zoom-in") {
            zoom(model, 1.33)
          }
          windowButton("Full", "Whole ruler, 0.1 pm to 100,000 km", "spectrum-tuner-full") {
            model.setTunerWindow(TunerWindow.full)
          }
          windowButton("Web", "The web prototype's range, 0.1 pm to 1 km", "spectrum-tuner-web") {
            model.setTunerWindow(TunerWindow.web)
            model.follow()
          }
        }
      }
  }

  private func zoom(_ model: SpectrumModel, _ factor: Double) {
    let before = model.tunerWindow
    model.setTunerWindow(TunerWindow.zoomed(before, factor: factor, anchor: log10(model.active.lambda)))
    if model.tunerWindow == before { Haptics.shared.boundary() }
  }

  private func windowButton(_ title: String, _ hint: String, _ id: String, action: @escaping () -> Void) -> some View {
    Button {
      Haptics.shared.tap()
      action()
    } label: {
      Text(title).font(.caption.weight(.semibold)).lineLimit(1).fixedSize().padding(.horizontal, 2).frame(minHeight: 22)
    }
    .buttonStyle(.glass)
    .accessibilityHint(hint)
    .accessibilityIdentifier(id)
  }
}

/// Tuner aux: the whole ruler in miniature (foundation `LogRuler`) with the visible window
/// bracketed; tap it to move the window there.
struct SpectrumTunerAux: View {
  @Environment(AppModel.self) private var app
  private static let inset: CGFloat = 22

  var body: some View {
    let model = app.spectrum
    let full = TunerWindow.full
    let window = model.tunerWindow
    let cursors = model.state.enabledIndices.map { i in
      RulerCursor(
        id: "spectrum-\(i)", label: SpectraState.sourceNames[i], lambda: model.state.sources[i].lambda,
        color: BandPalette.color(forWavelength: model.state.sources[i].lambda))
    }
    VStack(alignment: .leading, spacing: 10) {
      PlotWell(height: 70, grid: 0) {
        GeometryReader { geo in
          // Inset so the end labels ("300 EHz", "300 Hz") stay inside the well.
          let rect = CGRect(origin: .zero, size: geo.size).insetBy(dx: Self.inset, dy: 0)
          ZStack(alignment: .topLeading) {
            LogRuler(range: full, markers: app.markers.filter { !$0.id.hasPrefix("spectrum.") }, cursors: cursors, showsFrequency: true)
              .padding(.horizontal, Self.inset)
              .padding(.top, 6)
            let x0 = LogRuler.x(window.lowerBound, in: rect, range: full)
            let x1 = LogRuler.x(window.upperBound, in: rect, range: full)
            RoundedRectangle(cornerRadius: 6)
              .strokeBorder(Theme.phosphor.opacity(0.7), lineWidth: 1.2)
              .background(Theme.phosphor.opacity(0.06), in: .rect(cornerRadius: 6))
              .frame(width: max(6, x1 - x0), height: geo.size.height - 6)
              .offset(x: x0, y: 3)
              .allowsHitTesting(false)
          }
          .contentShape(.rect)
          .onTapGesture { p in
            let lg = full.lowerBound + Double((p.x - rect.minX) / max(1, rect.width)) * (full.upperBound - full.lowerBound)
            let half = (window.upperBound - window.lowerBound) / 2
            Haptics.shared.selection()
            model.setTunerWindow(TunerWindow.clamp(low: lg - half, high: lg + half))
          }
        }
      }
      .accessibilityElement()
      .accessibilityLabel("Whole ruler")
      .accessibilityValue("Window \(TunerDrawing.windowText(window.lowerBound)) to \(TunerDrawing.windowText(window.upperBound))")
      .accessibilityHint("Tap to move the tuner's window there.")
      .accessibilityIdentifier("spectrum-tuner-overview")
      Text(
        "Drag the ruler to tune; each band edge is a detent and the ionizing line a firm stop. Pinch to zoom the decades. Dim lines are the other frequencies in the app: \(otherSummary(app.markers))."
      )
      .panelCaption()
    }
  }

  private func otherSummary(_ markers: [SpectrumMarker]) -> String {
    let names = markers.filter { !$0.id.hasPrefix("spectrum.") }.map(\.label)
    return names.isEmpty ? "none right now" : names.prefix(6).joined(separator: ", ")
  }
}
