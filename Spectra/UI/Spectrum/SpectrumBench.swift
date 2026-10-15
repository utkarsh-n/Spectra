import SwiftUI

/// 03 Matter bench stage: the focused specimen animated (spectra-lab `bench.js` `draw`):
/// a slab with incoming, reflected and transmitted waves (and molecules, electrons, DNA or a
/// film behind a finger), the charge on a spring with its response curve, or the FM dipole.
struct SpectrumBenchStage: View {
  @Environment(AppModel.self) private var app
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  var height: CGFloat = 260

  var body: some View {
    let model = app.spectrum
    let src = model.active
    let focus = model.state.bench.focus
    let lambda0 = model.state.bench.lambda0
    let result = focus.evaluate(src.lambda, source: src, options: SpecimenOptions(lambda0: lambda0))
    let k = model.state.speed
    let d = Spectrum.describe(src.lambda)
    let decorative = !reduceMotion
    PlotWell(height: height, grid: 0) {
      SpectrumClocked { t in
        Canvas { ctx, size in
          let color = BandPalette.color(forWavelength: src.lambda)
          switch focus {
          case .oscillator:
            BenchDrawing.spring(ctx, size, result, color: color, t: t, k: k, lambda: src.lambda, lambda0: lambda0)
          case .antenna:
            BenchDrawing.antenna(ctx, size, result, color: color, t: t, k: k)
          default:
            BenchDrawing.slab(ctx, size, result, color: color, t: t, k: k, key: focus, decorative: decorative)
          }
        }
      }
    }
    .overlay(alignment: .top) {
      HStack(alignment: .top) {
        StageTag(focus.name)
        Spacer(minLength: 8)
        StageTag("\(d.text.lambda) \u{00B7} \(d.text.ev)")
      }
      .padding(10)
    }
    .accessibilityElement()
    .accessibilityLabel("Matter bench stage, \(focus.name)")
    .accessibilityValue(result.response.text)
    .accessibilityIdentifier("spectrum-bench-stage")
  }
}

/// The bench drawings (Canvas ports of `drawSlab`, `drawSpring`, `drawAntenna`).
enum BenchDrawing {
  private static let tau = SpectrumDraw.tau

  static func slab(
    _ ctx: GraphicsContext, _ size: CGSize, _ r: SpecimenResult, color: Color, t: Double, k: Double, key: SpecimenKey,
    decorative: Bool
  ) {
    let w = size.width, h = size.height
    let cy = h / 2, a = min(56, h * 0.16)
    let sx0 = w * 0.42, sx1 = w * 0.58
    let tr = r.transmission ?? 1, rf = r.reflection ?? 0
    SpectrumDraw.wave(ctx, x0: 16, x1: sx0, y: cy, amp: a, color: color, t: t, k: k)
    if rf > 0.01 {
      var pts: [CGPoint] = []
      var x = sx0
      while x >= 16 {
        let u = Double(sx0 - x) / 60
        pts.append(CGPoint(x: x, y: cy + a * 0.9 + 18 - a * 0.5 * CGFloat(rf.squareRoot() * cos(tau * (u - k * t)))))
        x -= 2
      }
      SpectrumDraw.line(ctx, pts, color: Theme.text.opacity(0.6), width: 1.4, glow: 0)
      SpectrumDraw.arrow(ctx, from: CGPoint(x: sx0 - 8, y: cy + a + 40), to: CGPoint(x: sx0 - 38, y: cy + a + 40), color: Theme.text.opacity(0.6), width: 1.4, head: 6)
      SpectrumDraw.label(
        ctx, "REFLECTED \(JSFormat.jsString(JSMath.round(rf * 100)))%", CGPoint(x: 16, y: cy + a + 40), color: Theme.muted)
    }
    let tint: Color =
      switch key {
      case .water: Theme.fieldE.opacity(0.10)
      case .glass: Color(red: 0.78, green: 0.94, blue: 1).opacity(0.08)
      case .zinc: Color(red: 0.59, green: 0.65, blue: 0.69).opacity(0.35)
      case .dna: Theme.dialPhi.opacity(0.10)
      case .hand: Color(red: 1, green: 0.67, blue: 0.59).opacity(0.12)
      default: Color.white.opacity(0.06)
      }
    let slabRect = CGRect(x: sx0, y: cy - h * 0.34, width: sx1 - sx0, height: h * 0.68)
    let slab = Path(roundedRect: slabRect, cornerRadius: 8)
    ctx.fill(slab, with: .color(tint))
    ctx.stroke(slab, with: .color(.white.opacity(0.25)), lineWidth: 1)
    // Inside: the wave decays toward the transmitted amplitude (display mapping of T).
    let inside = tr > 0 ? -log(max(tr, 1e-6)) / Double(sx1 - sx0) : 0.08
    SpectrumDraw.wave(
      ctx, x0: sx0, x1: sx1, y: cy, amp: a * CGFloat(max(0, 1 - rf).squareRoot()), color: color, t: t, k: k,
      phase0: tau * Double(sx0 - 16) / 60, decay: inside / 2, width: 1.6)
    if tr > 0.002 {
      SpectrumDraw.wave(
        ctx, x0: sx1, x1: w - 16, y: cy, amp: a * CGFloat(tr.squareRoot()), color: color, t: t, k: k,
        phase0: tau * Double(sx1 - 16) / 60)
    } else {
      SpectrumDraw.label(ctx, "NOTHING GETS THROUGH", CGPoint(x: (sx1 + w) / 2, y: cy), anchor: .center)
    }
    let tText = tr >= 0.995 ? ">99" : (tr < 0.005 && tr > 0 ? "<1" : JSFormat.jsString(JSMath.round(tr * 100)))
    SpectrumDraw.label(ctx, "TRANSMITTED \(tText)%", CGPoint(x: (sx1 + w) / 2, y: cy - a - 22), color: color, anchor: .center, size: 10, weight: .semibold)
    SpectrumDraw.label(ctx, "INCOMING", CGPoint(x: (16 + sx0) / 2, y: cy - a - 22), color: Theme.muted, anchor: .center)

    let kind = r.response.kind
    if kind == .twist || kind == .stretch {
      // Molecules inside the slab respond, lagging the field.
      let heat = min(1, (r.response.heating ?? 0) / 30)
      ctx.fill(Path(slabRect.insetBy(dx: 1, dy: 1)), with: .color(Color(red: 1, green: 0.47, blue: 0.31).opacity(0.12 * heat)))
      let drive = cos(tau * (k * t) - 1.1)
      for i in 0..<4 {
        for j in 0..<5 {
          let mx = sx0 + (CGFloat(i) + 0.5) * (sx1 - sx0) / 4
          let my = cy - h * 0.27 + CGFloat(j) * h * 0.54 / 4
          let ang = kind == .twist ? 0.8 * drive : 0
          let stretch = kind == .stretch ? 1 + 0.25 * drive : 1
          var m = ctx
          m.translateBy(x: mx, y: my)
          m.rotate(by: .radians(ang))
          for s in [-1.0, 1.0] {
            SpectrumDraw.segment(m, .zero, CGPoint(x: s * 7 * stretch, y: 6 * stretch), color: Theme.text.opacity(0.5), width: 1.2)
          }
          SpectrumDraw.dot(m, .zero, radius: 3.6, color: Theme.fieldB)
          for s in [-1.0, 1.0] { SpectrumDraw.dot(m, CGPoint(x: s * 7 * stretch, y: 6 * stretch), radius: 2.2, color: Theme.text) }
        }
      }
    }
    if kind == .eject, let ke = r.response.ejectKeMax {
      let v = min(1, 0.25 + ke.squareRoot() / 4)
      for i in 0..<9 {
        let life = decorative ? (t * 0.7 + Double(i) / 9).truncatingRemainder(dividingBy: 1) : Double(i) / 9
        let ang = -1.2 + Double(i) * 2.4 / 9
        let x = sx0 - CGFloat(life * 140 * v * cos(ang) * 0.9)
        let y = cy + CGFloat(life * 140 * v * sin(ang))
        SpectrumDraw.dot(ctx, CGPoint(x: x, y: y), radius: 3.2, color: Theme.phosphor.opacity(1 - life))
      }
      SpectrumDraw.label(ctx, "e\u{207B}", CGPoint(x: sx0 - 40, y: cy - h * 0.3), color: Theme.phosphor, anchor: .center, size: 12, weight: .semibold)
    }
    if kind == .dimer || key == .dna {
      let flash = r.response.resonance == true ? 0.5 + 0.5 * cos(tau * k * t) : 0
      let mx = (sx0 + sx1) / 2
      for i in 0...16 {
        let yy = cy - h * 0.3 + CGFloat(i) * h * 0.6 / 16
        let ph = Double(i) * 0.7 + (decorative ? t : 0)
        let xa = mx + 14 * CGFloat(sin(ph)), xb = mx - 14 * CGFloat(sin(ph))
        let rung = i % 4 == 2
        SpectrumDraw.segment(
          ctx, CGPoint(x: xa, y: yy), CGPoint(x: xb, y: yy), color: rung ? Theme.amber.opacity(0.25 + 0.75 * flash) : .white.opacity(0.3),
          width: rung && flash > 0 ? 2.4 : 1.2)
        SpectrumDraw.dot(ctx, CGPoint(x: xa, y: yy), radius: 2.2, color: Theme.dialPhi)
        SpectrumDraw.dot(ctx, CGPoint(x: xb, y: yy), radius: 2.2, color: Theme.fieldE)
      }
    }
    if key == .hand {
      // Film behind the finger: soft-tissue shade vs bone shade.
      let fx = w - 56, fy = cy - h * 0.3, fh = h * 0.6
      ctx.fill(Path(CGRect(x: fx, y: fy, width: 36, height: fh)), with: .color(Theme.text.opacity(0.08 + 0.85 * tr)))
      ctx.fill(
        Path(CGRect(x: fx, y: fy + fh * 0.35, width: 36, height: fh * 0.3)),
        with: .color(Theme.text.opacity(0.08 + 0.85 * (r.boneT ?? tr))))
      ctx.stroke(Path(CGRect(x: fx, y: fy, width: 36, height: fh)), with: .color(.white.opacity(0.3)), lineWidth: 1)
      SpectrumDraw.label(ctx, "FILM", CGPoint(x: fx + 18, y: fy - 10), color: Theme.muted, anchor: .center)
      let bone = Path(roundedRect: CGRect(x: sx0 + 12, y: cy - h * 0.1, width: sx1 - sx0 - 24, height: h * 0.2), cornerRadius: 10)
      ctx.fill(bone, with: .color(Color(red: 0.92, green: 0.88, blue: 0.82).opacity(0.35)))
      SpectrumDraw.label(ctx, "BONE", CGPoint(x: (sx0 + sx1) / 2, y: cy), color: Color(hex: 0x0B110F), anchor: .center, size: 9, weight: .bold)
    }
  }

  static func spring(
    _ ctx: GraphicsContext, _ size: CGSize, _ r: SpecimenResult, color: Color, t: Double, k: Double, lambda: Double, lambda0: Double
  ) {
    let w = size.width, h = size.height
    let amplitude = r.response.amplitude ?? 0, lag = r.response.lag ?? 0
    let cy = h * 0.48, a = min(54, h * 0.16)
    // Driving field (left), the spring and charge (centre), the response curve (right).
    let drive = cos(tau * k * t)
    let ex = w * 0.12
    SpectrumDraw.arrow(ctx, from: CGPoint(x: ex, y: cy), to: CGPoint(x: ex, y: cy - a * CGFloat(drive)), color: Theme.fieldE, width: 2.6, head: 9)
    SpectrumDraw.label(ctx, "E drives", CGPoint(x: ex, y: cy + a + 26), color: Theme.fieldE, anchor: .center)
    let x = min(1.6, amplitude) * cos(tau * k * t - lag * .pi / 180)
    let cx = w * 0.34, top = cy - a * 2.1 + 10, by = cy - a * 0.9 * CGFloat(x)
    ctx.fill(Path(CGRect(x: cx - 30, y: top - 8, width: 60, height: 8)), with: .color(.white.opacity(0.12)))
    var coil = Path()
    coil.move(to: CGPoint(x: cx, y: top))
    for i in 1...14 {
      let yy = top + (by - 14 - top) * CGFloat(i) / 14
      coil.addLine(to: CGPoint(x: cx + (i % 2 == 1 ? 10 : -10), y: yy))
    }
    coil.addLine(to: CGPoint(x: cx, y: by - 14))
    ctx.stroke(coil, with: .color(Theme.text.opacity(0.6)), lineWidth: 1.4)
    SpectrumDraw.dot(ctx, CGPoint(x: cx, y: by), radius: 12, color: color)
    SpectrumDraw.label(ctx, "\u{2212}", CGPoint(x: cx, y: by + 0.5), color: Color(hex: 0x04140A), anchor: .center, size: 14, weight: .bold)
    SpectrumDraw.label(ctx, "lags \(JSFormat.jsString(JSMath.round(lag)))\u{00B0}", CGPoint(x: cx, y: cy + a + 26), color: Theme.amber, anchor: .center)
    // Response curve: amplitude vs drive wavelength over λ₀ ×/÷ 10 (Core's oscillator).
    let gx0 = w * 0.55, gx1 = w - 14, gy0 = h * 0.2, gy1 = h * 0.78
    ctx.stroke(Path(CGRect(x: gx0, y: gy0, width: gx1 - gx0, height: gy1 - gy0)), with: .color(Theme.axis), lineWidth: 1)
    let q = SpecimenOptions().q
    var pts: [CGPoint] = []
    for i in 0...120 {
      let u = Double(i) / 120
      let l = lambda0 * pow(10, 1 - 2 * u)
      let amp = SpecimenKey.oscillator.evaluate(l, options: SpecimenOptions(lambda0: lambda0)).response.amplitude ?? 0
      pts.append(CGPoint(x: gx0 + CGFloat(u) * (gx1 - gx0), y: gy1 - CGFloat(min(1, amp / q)) * (gy1 - gy0)))
    }
    SpectrumDraw.line(ctx, pts, color: Theme.amber, width: 1.8, glow: 0.4)
    let u = (1 - log10(lambda / lambda0)) / 2
    if u >= 0 && u <= 1 {
      let mx = gx0 + CGFloat(u) * (gx1 - gx0)
      SpectrumDraw.segment(ctx, CGPoint(x: mx, y: gy0), CGPoint(x: mx, y: gy1), color: color, width: 1.4)
    } else {
      SpectrumDraw.label(ctx, u < 0 ? "\u{25C0} far longer" : "far shorter \u{25B6}", CGPoint(x: (gx0 + gx1) / 2, y: gy0 + 14), color: Theme.muted, anchor: .center)
    }
    SpectrumDraw.label(ctx, "RESPONSE", CGPoint(x: gx0, y: gy0 - 10), color: Theme.muted)
    SpectrumDraw.label(ctx, "longer \u{03BB}", CGPoint(x: gx0, y: gy1 + 12))
    SpectrumDraw.label(ctx, "shorter \u{03BB}", CGPoint(x: gx1, y: gy1 + 12), anchor: .trailing)
  }

  static func antenna(_ ctx: GraphicsContext, _ size: CGSize, _ r: SpecimenResult, color: Color, t: Double, k: Double) {
    let w = size.width, h = size.height
    let cx = w * 0.55, cy = h / 2, length = h * 0.32
    let current = r.response.value ?? 0
    SpectrumDraw.wave(ctx, x0: 16, x1: cx - 40, y: cy, amp: min(50, h * 0.15), color: color, t: t, k: k)
    var rods = Path()
    rods.move(to: CGPoint(x: cx, y: cy - length))
    rods.addLine(to: CGPoint(x: cx, y: cy - 6))
    rods.move(to: CGPoint(x: cx, y: cy + 6))
    rods.addLine(to: CGPoint(x: cx, y: cy + length))
    ctx.stroke(rods, with: .color(Color(hex: 0xB8C4CC)), style: StrokeStyle(lineWidth: 5, lineCap: .round))
    let slosh = current * cos(tau * k * t)
    for i in 0..<10 {
      let base = -length + (CGFloat(i) + 0.5) * 2 * length / 10
      let yy = cy + base + CGFloat(slosh) * length * 0.18 * CGFloat(cos(Double(base / length) * .pi / 2))
      SpectrumDraw.dot(ctx, CGPoint(x: cx + 9, y: yy), radius: 2.6, color: Theme.phosphor.opacity(0.5 + 0.5 * current))
    }
    SpectrumDraw.dot(
      ctx, CGPoint(x: cx + 60, y: cy), radius: 14, color: Theme.amber.opacity(0.15 + 0.85 * current * abs(sin(tau * k * t))))
    SpectrumDraw.label(ctx, "RECEIVER", CGPoint(x: cx + 60, y: cy + 30), color: Theme.muted, anchor: .center)
    SpectrumDraw.label(
      ctx, "CURRENT \(JSFormat.jsString(JSMath.round(current * 100)))%", CGPoint(x: cx, y: cy - length - 16),
      color: current > 0.5 ? Theme.amber : Theme.muted, anchor: .center, size: 10, weight: .semibold)
  }
}

/// Bench toolbar: side by side / in series, and the TABLE / MODEL legend.
struct SpectrumBenchToolbar: View {
  @Environment(AppModel.self) private var app

  var body: some View {
    let model = app.spectrum
    VStack(alignment: .leading, spacing: 8) {
      GlassSegmented(
        items: SpectraState.BenchSettings.Arrangement.allCases, selected: model.state.bench.arrangement,
        id: "spectrum-bench-arrangement", title: { $0 == .side ? "Side by side" : "In series" }
      ) { model.state.bench.arrangement = $0 }
      HStack(spacing: 6) {
        ProvenanceBadge(.table, compact: true)
        Text("measured").font(.caption2).foregroundStyle(Theme.muted)
        ProvenanceBadge(.model, compact: true)
        Text("physics").font(.caption2).foregroundStyle(Theme.muted)
      }
      .accessibilityElement(children: .combine)
    }
  }
}

/// Bench aux: one card per specimen (tap to focus), with its answer, bar and numbers; the
/// oscillator card carries the λ₀ slider.
struct SpectrumBenchCards: View {
  @Environment(AppModel.self) private var app

  var body: some View {
    let model = app.spectrum
    let src = model.active
    let results = model.benchResults()
    let series: [SpecimenKey: Specimens.SeriesStep]? =
      model.state.bench.arrangement == .series
      ? Dictionary(uniqueKeysWithValues: Specimens.inSeries(src.lambda, source: src).map { ($0.key, $0) }) : nil
    let resonant = Set(SpecimenKey.allCases.filter { k in results[k].map { SpectrumModel.resonant(k, $0) } ?? false })
    VStack(spacing: 10) {
      ForEach(SpecimenKey.allCases) { key in
        if let r = results[key] {
          SpecimenCard(
            key: key, result: r, series: series?[key], resonant: resonant.contains(key), focused: model.state.bench.focus == key,
            color: BandPalette.color(forWavelength: src.lambda))
        }
      }
    }
    .onChange(of: resonant, initial: true) { _, keys in model.noteResonances(keys) }
  }
}

private struct SpecimenCard: View {
  @Environment(AppModel.self) private var app
  let key: SpecimenKey
  let result: SpecimenResult
  let series: Specimens.SeriesStep?
  let resonant: Bool
  let focused: Bool
  let color: Color

  var body: some View {
    let model = app.spectrum
    VStack(alignment: .leading, spacing: 8) {
      Button {
        guard !focused else { return }
        Haptics.shared.selection()
        model.state.bench.focus = key
      } label: {
        VStack(alignment: .leading, spacing: 6) {
          HStack(spacing: 6) {
            Text(key.name).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.text)
            ProvenanceBadge(Provenance(rawValue: result.source.rawValue) ?? .model, compact: true)
            if resonant {
              Text("RESONANCE").font(.system(size: 9, weight: .bold, design: .monospaced)).foregroundStyle(Theme.amber)
                .padding(.horizontal, 5).padding(.vertical, 2)
                .background(Theme.amber.opacity(0.15), in: .capsule)
            }
            Spacer(minLength: 0)
            if focused { Image(systemName: "scope").foregroundStyle(Theme.phosphor).accessibilityHidden(true) }
          }
          Text(key.sub).font(.caption).foregroundStyle(Theme.dim)
          Text(result.response.text).font(.footnote).foregroundStyle(Theme.text.opacity(0.85))
            .fixedSize(horizontal: false, vertical: true).multilineTextAlignment(.leading)
          if result.transmission != nil { bar }
          if !numbers.isEmpty {
            Text(numbers).font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundStyle(Theme.muted)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect)
      }
      .buttonStyle(.plain)
      .accessibilityElement(children: .combine)
      .accessibilityAddTraits(focused ? [.isSelected, .isButton] : .isButton)
      .accessibilityHint(focused ? "On the stage." : "Shows it on the stage.")
      .accessibilityIdentifier("spectrum-specimen-\(key.rawValue)")
      if key == .oscillator {
        GlassSlider(
          title: "Resonance \u{03BB}\u{2080}",
          value: Binding(get: { log10(model.state.bench.lambda0) }, set: { model.state.bench.lambda0 = pow(10, $0) }),
          range: SpectrumDisplay.lambda0LogRange, step: 0.01, color: Theme.amber,
          format: { Spectrum.describe(pow(10, $0)).text.lambda }
        )
        .accessibilityIdentifier("spectrum-bench-lambda0")
      }
    }
    .padding(14)
    .background(Color.white.opacity(focused ? 0.05 : 0.025), in: .rect(cornerRadius: Theme.cardRadius))
    .overlay {
      RoundedRectangle(cornerRadius: Theme.cardRadius)
        .strokeBorder(focused ? Theme.phosphor.opacity(0.5) : (resonant ? Theme.amber.opacity(0.4) : Theme.hairline), lineWidth: 1)
        .allowsHitTesting(false)
    }
  }

  private var bar: some View {
    let t = series?.after ?? (result.transmission ?? 0)
    let r = series == nil ? (result.reflection ?? 0) : 0
    let a = max(0, 1 - t - r)
    return GeometryReader { geo in
      HStack(spacing: 0) {
        Rectangle().fill(color).frame(width: geo.size.width * CGFloat(min(1, max(0, t))))
        Rectangle().fill(Theme.text.opacity(0.45)).frame(width: geo.size.width * CGFloat(min(1, max(0, r))))
        Rectangle().fill(Theme.amber.opacity(0.55)).frame(width: geo.size.width * CGFloat(min(1, a)))
        Spacer(minLength: 0)
      }
    }
    .frame(height: 6)
    .background(Color.white.opacity(0.06))
    .clipShape(.capsule)
    .accessibilityHidden(true)
  }

  /// The card's number line (web `bench.update`).
  private var numbers: String {
    let x = result
    let pct = SpectrumPercent.text
    var num = ""
    if let t = x.transmission {
      if let s = series {
        num = "BEAM LEFT \(pct(s.after)) \u{00B7} THIS ONE PASSES \(pct(t))"
      } else {
        num = "T \(pct(t)) \u{00B7} R \(pct(x.reflection ?? 0)) \u{00B7} A \(pct(x.absorption))"
      }
    }
    switch key {
    case .oscillator:
      num =
        "AMPLITUDE \(JSFormat.toFixed(x.response.amplitude ?? 0, 2))\u{00D7} \u{00B7} LAG \(JSFormat.jsString(JSMath.round(x.response.lag ?? 0)))\u{00B0}"
    case .antenna:
      num = "INDUCED CURRENT \(JSFormat.jsString(JSMath.round((x.response.value ?? 0) * 100)))% OF PEAK"
    case .water:
      if let heat = x.response.heating, heat > 1e-6 {
        let text = heat >= 0.01 && heat < 1000 ? JSFormat.toPrecision(heat, 2) : JSFormat.sci(heat)
        num += " \u{00B7} HEATS \(text) \u{00B0}C/MIN AT SURFACE"
      }
    case .zinc:
      if let ke = x.response.ejectKeMax {
        let text = ke < 1e3 ? JSFormat.toFixed(ke, 2) + " eV" : JSFormat.toFixed(ke / 1e3, 1) + " keV"
        num += " \u{00B7} e\u{207B} KE \u{2264} \(text)"
      }
    case .hand:
      let contrast = x.contrast ?? 0
      num =
        "SOFT \(pct(x.transmission)) \u{00B7} THROUGH BONE \(pct(x.boneT))\(contrast > 0.02 ? " \u{00B7} CONTRAST \(JSFormat.jsString(JSMath.round(contrast * 100)))%" : "")"
    case .dna:
      if let a = x.absorbance, a > 0.01 { num += " \u{00B7} A \(JSFormat.toFixed(a, 2))" }
    case .glass:
      break
    }
    return num
  }
}
