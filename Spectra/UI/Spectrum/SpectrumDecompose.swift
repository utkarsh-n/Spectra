import SwiftUI

/// 04 Decompose toolbar: Polarization · Probe charge · Fourier · Phase space.
struct SpectrumDecomposeToolbar: View {
  @Environment(AppModel.self) private var app

  var body: some View {
    let model = app.spectrum
    GlassSegmented(
      items: DecomposePage.allCases, selected: model.decomposePage, id: "spectrum-decompose",
      title: { $0.short },
      accessibilityTitle: { $0.title }
    ) { model.decomposePage = $0 }
  }
}

/// The stage of the three web Decompose tabs (spectra-lab `decompose.js` `draw`).
struct SpectrumDecomposeStage: View {
  @Environment(AppModel.self) private var app
  var height: CGFloat = 300

  var body: some View {
    let model = app.spectrum
    let state = model.state
    let page = model.decomposePage
    let ds = model.waveScene.displaySources
    // Frame-independent parts, cached by the model: the canvas below runs at 60 fps.
    let probe = page == .probe ? model.probeGeometry() : ProbeGeometry()
    let stems = page == .fourier ? model.fourierStems() : nil
    VStack(spacing: 8) {
      well(page, state: state, ds: ds, probe: probe, stems: stems)
      switch page {
      case .polarization: StageHint("Looking down the beam \u{00B7} E = Ex + Ey")
      case .probe: StageHint("Starts at rest \u{00B7} equal axes in \u{03BB}/2\u{03C0}")
      default: EmptyView()
      }
    }
  }

  private func well(
    _ page: DecomposePage, state: SpectraState, ds: FieldView.DisplaySources, probe: ProbeGeometry, stems: FourierStems?
  ) -> some View {
    PlotWell(height: page == .probe ? max(220, height - 40) : height, grid: 0) {
      SpectrumClocked { t in
        Canvas { ctx, size in
          switch page {
          case .polarization: DecomposeDrawing.polarization(ctx, size, ds: ds, state: state, t: t)
          case .probe: DecomposeDrawing.probe(ctx, size, geometry: probe, state: state, t: t)
          default: DecomposeDrawing.fourier(ctx, size, ds: ds, stems: stems, state: state, t: t)
          }
        }
      }
    }
    .overlay(alignment: .topLeading) { tags(page, state: state, ds: ds) }
    .accessibilityElement()
    .accessibilityLabel(page.title)
    .accessibilityValue(accessibilityValue(page, state: state))
    .accessibilityIdentifier("spectrum-decompose-stage")
  }

  @ViewBuilder private func tags(_ page: DecomposePage, state: SpectraState, ds: FieldView.DisplaySources) -> some View {
    switch page {
    case .polarization:
      HStack(alignment: .top) {
        StageTag("Ex", color: Theme.fieldEx)
        StageTag("Ey", color: Theme.fieldEy)
        Spacer()
        StageTag("Polarizer \(JSFormat.jsString(state.decompose.polarizer))\u{00B0}", color: Theme.amber)
      }
      .padding(10)
    case .probe:
      HStack(alignment: .top) {
        StageTag("Side view \u{00B7} beam travels \u{2192}")
        Spacer()
        StageTag(SpectrumDisplay.driftTag(state), color: Theme.amber)
      }
      .padding(10)
    default:
      HStack(alignment: .top) {
        StageTag("Field at one point vs time")
        Spacer()
        let hidden = FieldView.hiddenNote(ds)
        if !hidden.isEmpty { StageTag(hidden, color: Theme.amber).frame(maxWidth: 160, alignment: .trailing) }
      }
      .padding(10)
    }
  }

  private func accessibilityValue(_ page: DecomposePage, state: SpectraState) -> String {
    switch page {
    case .polarization: SpectrumDisplay.polarizationNote(state)
    case .probe: SpectrumDisplay.probeNote(state)
    default: "The summed field over time above, its frequency components below."
    }
  }
}

/// Decompose aux: the polarizer slider, the probe forces and a₀, or the Fourier caption, and
/// the field's Scope / Patch buttons.
struct SpectrumDecomposeAux: View {
  @Environment(AppModel.self) private var app

  var body: some View {
    let model = app.spectrum
    let state = model.state
    VStack(alignment: .leading, spacing: 12) {
      switch model.decomposePage {
      case .polarization:
        GlassSlider(
          title: "Polarizer angle \u{03B1}",
          value: Binding(get: { state.decompose.polarizer }, set: { model.state.decompose.polarizer = $0 }),
          range: SpectrumDisplay.polarizerRange, step: 1, color: Theme.amber, format: { "\(Int($0.rounded()))\u{00B0}" }
        )
        .accessibilityIdentifier("spectrum-polarizer")
        Text(SpectrumDisplay.polarizationNote(state)).panelCaption()
      case .probe:
        GlassSegmented(
          items: Wave.ProbeMode.allCases, selected: state.decompose.probeMode, id: "spectrum-probe-mode",
          // Field colours: E blue, B rose; both forces together in phosphor.
          tint: { m in m == .electric ? Theme.fieldE : (m == .magnetic ? Theme.fieldB : Theme.phosphor) },
          title: { m in
            switch m {
            case .both: "E + v\u{00D7}B"
            case .electric: "E only"
            case .magnetic: "B only"
            }
          }
        ) { model.state.decompose.probeMode = $0 }
        GlassSlider(
          title: "Strength a\u{2080} = eE\u{2080} / m\u{03C9}c",
          value: Binding(get: { log10(state.decompose.a0) }, set: { model.state.decompose.a0 = pow(10, $0) }),
          range: SpectrumDisplay.a0LogRange, step: 0.01, color: Theme.amber,
          format: { JSFormat.toPrecision(pow(10, $0), 3) }
        )
        .accessibilityIdentifier("spectrum-a0")
        Text(SpectrumDisplay.probeNote(state)).panelCaption()
      default:
        Text(fourierNote(model)).panelCaption()
      }
      if model.decomposePage != .probe {
        SpectrumSignalButtons(
          scopeTitle: "Ex, Ey in Scope", patchTitle: "Add to Patch", idPrefix: "spectrum-decompose",
          openScope: model.openFieldInScope, addPatch: model.addFieldToPatch)
      }
    }
  }

  private func fourierNote(_ model: SpectrumModel) -> String {
    let ds = model.waveScene.displaySources
    let parts = ds.list.map { x -> String in
      let name = SpectraState.sourceNames[min(2, x.index)]
      let what =
        x.source.kind == .thermal
        ? "\(JSFormat.jsString(x.source.temperature)) K thermal" : Spectrum.describe(x.source.lambda).text.lambda
      let pulse = x.source.kind == .pulse ? " pulse (\(JSFormat.jsString(x.source.cycles)) cycles)" : ""
      return "\(name): \(what)\(pulse)"
    }
    return parts.joined(separator: " \u{00B7} ")
      + ". The top trace is the sum; the stems below show what it's made of."
      + (ds.inMedium ? " The prism inset bends each color by its own index." : "")
  }
}

/// Canvas ports of `drawPolarization`, `drawProbe` and `drawFourier`.
enum DecomposeDrawing {
  private static let tau = SpectrumDraw.tau

  static func polarization(_ ctx: GraphicsContext, _ size: CGSize, ds: FieldView.DisplaySources, state: SpectraState, t: Double) {
    let w = size.width, h = size.height, sp = state.speed
    let stripH = min(90, h * 0.24)
    // r keeps the axes (1.25 r) clear of the component strips below.
    let cx = w / 2, cy = (h - stripH) / 2 + 8
    let r = max(20, min(w * 0.36, (h - stripH) * 0.38, (h - stripH - 14 - cy) / 1.25))
    SpectrumDraw.segment(ctx, CGPoint(x: cx - r * 1.3, y: cy), CGPoint(x: cx + r * 1.3, y: cy), color: Theme.axis)
    SpectrumDraw.segment(ctx, CGPoint(x: cx, y: cy - r * 1.25), CGPoint(x: cx, y: cy + r * 1.25), color: Theme.axis)
    // Trace of the tip over one reference period.
    var trail: [CGPoint] = []
    for i in 0...SpectrumDisplay.polarizationTrailSamples {
      let f = FieldView.fieldAt(ds, z: 0, t: SpectrumDisplay.polarizationTrailTime(i, t: t, speed: sp), speed: sp)
      trail.append(CGPoint(x: cx + CGFloat(f.ex) * r, y: cy - CGFloat(f.ey) * r))
    }
    SpectrumDraw.line(ctx, trail, color: Theme.fieldE.opacity(0.5), width: 1.4, glow: 0, dash: [3, 4])
    // Polarizer.
    let a = Wave.rad(state.decompose.polarizer), ux = CGFloat(cos(a)), uy = CGFloat(sin(a))
    SpectrumDraw.segment(
      ctx, CGPoint(x: cx - ux * r * 1.2, y: cy + uy * r * 1.2), CGPoint(x: cx + ux * r * 1.2, y: cy - uy * r * 1.2),
      color: Theme.amber.opacity(0.8), width: 1.4, dash: [6, 5])
    let f = FieldView.fieldAt(ds, z: 0, t: t, speed: sp)
    let tx = cx + CGFloat(f.ex) * r, ty = cy - CGFloat(f.ey) * r
    SpectrumDraw.segment(ctx, CGPoint(x: tx, y: ty), CGPoint(x: tx, y: cy), color: Theme.text.opacity(0.25), dash: [2, 3])
    SpectrumDraw.segment(ctx, CGPoint(x: tx, y: ty), CGPoint(x: cx, y: ty), color: Theme.text.opacity(0.25), dash: [2, 3])
    SpectrumDraw.line(ctx, [CGPoint(x: cx, y: cy), CGPoint(x: tx, y: cy)], color: Theme.fieldEx, width: 3, glow: 0.3)
    SpectrumDraw.line(ctx, [CGPoint(x: cx, y: cy), CGPoint(x: cx, y: ty)], color: Theme.fieldEy, width: 3, glow: 0.3)
    SpectrumDraw.line(ctx, [CGPoint(x: cx, y: cy), CGPoint(x: tx, y: ty)], color: Theme.fieldE, width: 2.6, glow: 0.5)
    SpectrumDraw.dot(ctx, CGPoint(x: tx, y: ty), radius: 4.5, color: Theme.fieldE)
    let p = CGFloat(SpectrumDisplay.polarizerProjection(ex: f.ex, ey: f.ey, alphaDeg: state.decompose.polarizer))
    SpectrumDraw.line(ctx, [CGPoint(x: cx, y: cy), CGPoint(x: cx + p * ux * r, y: cy - p * uy * r)], color: Theme.amber, width: 3, glow: 0.2)
    // Component strips Ex(t), Ey(t), newest at the right.
    let y0 = h - stripH - 4, mid1 = y0 + stripH * 0.28, mid2 = y0 + stripH * 0.72, amp = stripH * 0.2
    let span = SpectrumDisplay.componentStripSpan(speed: sp)
    var ex: [CGPoint] = [], ey: [CGPoint] = []
    var x: CGFloat = 0
    while x <= w {
      let tt = t - Double((w - x) / w) * span
      let g = FieldView.fieldAt(ds, z: 0, t: tt, speed: sp)
      ex.append(CGPoint(x: x, y: mid1 - CGFloat(g.ex) * amp))
      ey.append(CGPoint(x: x, y: mid2 - CGFloat(g.ey) * amp))
      x += 3
    }
    SpectrumDraw.segment(ctx, CGPoint(x: 0, y: mid1), CGPoint(x: w, y: mid1), color: Color(hex: 0x9CB5A6).opacity(0.18))
    SpectrumDraw.segment(ctx, CGPoint(x: 0, y: mid2), CGPoint(x: w, y: mid2), color: Color(hex: 0x9CB5A6).opacity(0.18))
    SpectrumDraw.line(ctx, ex, color: Theme.fieldEx, width: 1.8, glow: 0)
    SpectrumDraw.line(ctx, ey, color: Theme.fieldEy, width: 1.8, glow: 0)
    SpectrumDraw.label(ctx, "Ex(t)", CGPoint(x: 8, y: mid1 - amp - 6), color: Theme.fieldEx)
    SpectrumDraw.label(ctx, "Ey(t)", CGPoint(x: 8, y: mid2 - amp - 6), color: Theme.fieldEy)
    SpectrumDraw.label(ctx, "NOW \u{203A}", CGPoint(x: w - 8, y: y0 - 6), anchor: .trailing)
  }

  static func probe(_ ctx: GraphicsContext, _ size: CGSize, geometry g: ProbeGeometry, state: SpectraState, t: Double) {
    let w = size.width, h = size.height
    let d = state.decompose
    let traj = g.points
    guard !traj.isEmpty, g.transverse.count == traj.count else { return }
    let mainW = w * 0.62, pad: CGFloat = 26
    let s = min((mainW - 2 * pad) / CGFloat(max(g.zMax, g.tMax * 0.5)), (h - 2 * pad) / CGFloat(2 * g.tMax + 1e-9))
    let ox = pad, oy = h / 2
    SpectrumDraw.segment(ctx, CGPoint(x: ox, y: oy), CGPoint(x: mainW, y: oy), color: Theme.axis)
    SpectrumDraw.arrow(ctx, from: CGPoint(x: mainW - 56, y: oy + h * 0.38), to: CGPoint(x: mainW - 10, y: oy + h * 0.38), color: Theme.amber, width: 1.6, head: 7)
    SpectrumDraw.label(ctx, "BEAM", CGPoint(x: mainW - 62, y: oy + h * 0.38), color: Theme.amber, anchor: .trailing)
    var path = Path()
    for k in traj.indices {
      let p = CGPoint(x: ox + CGFloat(traj[k].z) * s, y: oy - CGFloat(g.transverse[k]) * s)
      if k == 0 { path.move(to: p) } else { path.addLine(to: p) }
    }
    ctx.phosphorStroke(path, color: Theme.phosphor.opacity(0.55), width: 1.4, glow: 0)
    // The electron, animated along its path by phase.
    let i = SpectrumDisplay.probeIndex(t: t, speed: state.speed, count: traj.count)
    let e = traj[i]
    let ex = ox + CGFloat(e.z) * s, ey = oy - CGFloat(g.transverse[i]) * s
    SpectrumDraw.dot(ctx, CGPoint(x: ex, y: ey), radius: 6, color: Theme.phosphor)
    SpectrumDraw.label(ctx, "e\u{207B}", CGPoint(x: ex + 10, y: ey - 10), color: Theme.phosphor, size: 11, weight: .semibold)
    // The forces acting now: E transverse, v×B forward.
    if d.probeMode != .magnetic {
      SpectrumDraw.arrow(ctx, from: CGPoint(x: ex, y: ey), to: CGPoint(x: ex, y: ey - 26 * CGFloat(cos(e.eta))), color: Theme.fieldE, width: 2, head: 7)
    }
    if d.probeMode == .both, e.uz > 1e-6 {
      let len = min(40, 14 + 30 * e.uz / (d.a0 * d.a0 / 2 + 1e-9))
      SpectrumDraw.arrow(ctx, from: CGPoint(x: ex, y: ey), to: CGPoint(x: ex + CGFloat(len), y: ey), color: Theme.fieldB, width: 2, head: 7)
    }
    // Inset: the drift frame (figure eight), axes scaled independently and labelled.
    let ix0 = mainW + 16, iw = w - ix0 - 10, iy0 = h * 0.3, ih = h * 0.52
    let icx = ix0 + iw / 2, icy = iy0 + ih / 2
    ctx.stroke(Path(CGRect(x: ix0, y: iy0, width: iw, height: ih)), with: .color(.white.opacity(0.1)), lineWidth: 1)
    SpectrumDraw.label(ctx, "RIDING WITH", CGPoint(x: ix0, y: iy0 - 20), color: Theme.muted, size: 8.5)
    SpectrumDraw.label(ctx, "THE DRIFT", CGPoint(x: ix0, y: iy0 - 9), color: Theme.muted, size: 8.5)
    if d.probeMode == .both, !g.inset.isEmpty {
      // The drift frame rides with the forward and the sideways drift (`ProbeGeometry`),
      // centred, each axis scaled to the inset.
      let ax = iw * 0.42, ay = ih * 0.42
      var eight = Path()
      for (k, q) in g.inset.enumerated() {
        let p = CGPoint(x: icx + CGFloat(q.x) * ax, y: icy - CGFloat(q.y) * ay)
        if k == 0 { eight.move(to: p) } else { eight.addLine(to: p) }
      }
      ctx.phosphorStroke(eight, color: Theme.amber, width: 1.8, glow: 0.4)
      // Forward is drawn this many times larger than sideways.
      let stretch = (ax / CGFloat(g.insetHalf.x)) / (ay / CGFloat(g.insetHalf.y))
      SpectrumDraw.label(ctx, "forward \u{00D7}\(JSFormat.toPrecision(Double(stretch), 2))", CGPoint(x: ix0, y: iy0 + ih + 10), size: 8.5)
    } else {
      SpectrumDraw.label(ctx, "No forward", CGPoint(x: icx, y: icy - 6), anchor: .center, size: 8.5)
      SpectrumDraw.label(ctx, "motion", CGPoint(x: icx, y: icy + 6), anchor: .center, size: 8.5)
    }
  }

  static func fourier(
    _ ctx: GraphicsContext, _ size: CGSize, ds: FieldView.DisplaySources, stems: FourierStems?, state: SpectraState, t: Double
  ) {
    let w = size.width, h = size.height, sp = state.speed
    let topH = h * 0.46, mid = topH / 2 + 14, amp = topH * 0.36
    let window = SpectrumDisplay.fourierWindow(speed: sp)
    // Time trace: the field at z = 0, summed.
    if ds.list.count > 1 {
      for d in ds.list {
        var pts: [CGPoint] = []
        var x: CGFloat = 0
        while x <= w {
          let tt = t - Double((w - x) / w) * window
          let f = FieldView.fieldAt(ds, z: 0, t: tt, speed: sp, only: d.index)
          pts.append(CGPoint(x: x, y: mid - CGFloat(SpectrumDisplay.fourierTrace(f)) * amp))
          x += 3
        }
        SpectrumDraw.line(ctx, pts, color: Color(spectraHex: d.colorHex).opacity(0.4), width: 1, glow: 0)
      }
    }
    var total: [CGPoint] = []
    var x: CGFloat = 0
    while x <= w {
      let tt = t - Double((w - x) / w) * window
      let f = FieldView.fieldAt(ds, z: 0, t: tt, speed: sp)
      total.append(CGPoint(x: x, y: mid - CGFloat(SpectrumDisplay.fourierTrace(f)) * amp))
      x += 2
    }
    SpectrumDraw.line(ctx, total, color: Theme.text, width: 2, glow: 0.4)
    SpectrumDraw.segment(ctx, CGPoint(x: 0, y: topH + 6), CGPoint(x: w, y: topH + 6), color: .white.opacity(0.08))
    SpectrumDraw.label(ctx, "FREQUENCY CONTENT", CGPoint(x: 10, y: topH + 18), color: Theme.muted, size: 9)
    // Stems on a log-frequency axis spanning every component (cached by the model).
    guard let stems, !stems.stems.isEmpty, let axis = stems.axis, axis.upperBound > axis.lowerBound else { return }
    let base = h - 24, top = topH + 34
    let maxA = stems.maxA
    let dense = stems.stems.count > 20
    for c in stems.stems {
      let px = 16 + CGFloat((c.logF - axis.lowerBound) / (axis.upperBound - axis.lowerBound)) * (w - 32)
      let py = base - CGFloat(c.a / maxA) * (base - top)
      let color = BandPalette.color(forWavelength: c.lambda)
      SpectrumDraw.segment(ctx, CGPoint(x: px, y: base), CGPoint(x: px, y: py), color: color, width: dense ? 1.5 : 2.4)
      SpectrumDraw.dot(ctx, CGPoint(x: px, y: py), radius: dense ? 1.6 : 3.4, color: color)
    }
    SpectrumDraw.segment(ctx, CGPoint(x: 16, y: base), CGPoint(x: w - 16, y: base), color: Theme.axis)
    SpectrumDraw.label(ctx, Spectrum.describe(SI.c / pow(10, axis.lowerBound)).text.lambda, CGPoint(x: 16, y: base + 12))
    SpectrumDraw.label(ctx, Spectrum.describe(SI.c / pow(10, axis.upperBound)).text.lambda, CGPoint(x: w - 16, y: base + 12), anchor: .trailing)
    SpectrumDraw.label(ctx, "higher f \u{2192}", CGPoint(x: w / 2, y: base + 12), anchor: .center)
    // Prism inset: minimum deviation through a 60° prism of the medium, spread ×8.
    guard ds.inMedium else { return }
    let medium = state.medium
    let px = w - 84, py = topH * 0.55, s: CGFloat = 26
    let inset = CGRect(x: px - 80, y: py - s - 10, width: 160, height: 2 * s + 34)
    ctx.fill(Path(roundedRect: inset, cornerRadius: 8), with: .color(Theme.plotWell.opacity(0.9)))
    var prism = Path()
    prism.move(to: CGPoint(x: px, y: py - s))
    prism.addLine(to: CGPoint(x: px - s * 0.87, y: py + s * 0.5))
    prism.addLine(to: CGPoint(x: px + s * 0.87, y: py + s * 0.5))
    prism.closeSubpath()
    ctx.fill(prism, with: .color(Color(red: 0.78, green: 0.94, blue: 1).opacity(0.08)))
    ctx.stroke(prism, with: .color(Color(red: 0.78, green: 0.94, blue: 1).opacity(0.6)), lineWidth: 1)
    SpectrumDraw.line(ctx, [CGPoint(x: px - 76, y: py + 5), CGPoint(x: px - s * 0.45, y: py)], color: Theme.text, width: 1.4, glow: 0)
    let devs: [(color: Color, dev: Double)] = ds.list.compactMap { d in
      let nk = medium.index(d.source.lambda)
      guard nk.valid else { return nil }
      return (BandPalette.color(forWavelength: d.source.lambda), SpectrumDisplay.prismDeviation(n: nk.n))
    }
    guard !devs.isEmpty else { return }
    let mean = devs.map(\.dev).reduce(0, +) / Double(devs.count)
    for dv in devs {
      let ang = 0.25 + (dv.dev - mean) * SpectrumDisplay.prismSpreadExaggeration
      let a = CGPoint(x: px + s * 0.45, y: py)
      SpectrumDraw.line(ctx, [a, CGPoint(x: a.x + 52 * CGFloat(cos(ang)), y: a.y + 52 * CGFloat(sin(ang)))], color: dv.color, width: 1.6, glow: 0.4)
    }
    SpectrumDraw.label(
      ctx, "\(JSFormat.toFixed(mean * 180 / .pi, 1))\u{00B0} bend \u{00B7} spread \u{00D7}8", CGPoint(x: px, y: py + s + 14), anchor: .center,
      size: 8.5)
  }
}
