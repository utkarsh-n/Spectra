import SwiftUI

/// Canvas helpers for the 2-D instruments (spectra-lab `ui/draw.js` restyled with the
/// foundation's phosphor strokes).
enum SpectrumDraw {
  static let tau = 2 * Double.pi

  /// A text label; `anchor` follows the web's "left" (leading), "right" (trailing) and
  /// "center" alignments, vertically centred.
  static func label(
    _ ctx: GraphicsContext, _ text: String, _ p: CGPoint, color: Color = Theme.dim, anchor: UnitPoint = .leading,
    size: CGFloat = 9.5, weight: Font.Weight = .medium
  ) {
    ctx.draw(
      Text(text).font(.system(size: size, weight: weight, design: .monospaced)).foregroundStyle(color), at: p,
      anchor: anchor)
  }

  static func path(_ points: [CGPoint]) -> Path {
    var p = Path()
    guard let first = points.first else { return p }
    p.move(to: first)
    for q in points.dropFirst() { p.addLine(to: q) }
    return p
  }

  /// A glowing polyline (web `glowLine`).
  static func line(
    _ ctx: GraphicsContext, _ points: [CGPoint], color: Color, width: CGFloat = 1.5, glow: CGFloat = 0.6,
    dash: [CGFloat] = []
  ) {
    guard points.count > 1 else { return }
    ctx.phosphorStroke(path(points), color: color, width: width, glow: glow, dash: dash)
  }

  /// A plain stroked segment.
  static func segment(_ ctx: GraphicsContext, _ a: CGPoint, _ b: CGPoint, color: Color, width: CGFloat = 1, dash: [CGFloat] = []) {
    var p = Path()
    p.move(to: a)
    p.addLine(to: b)
    ctx.stroke(p, with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: .round, dash: dash))
  }

  /// An arrow from `a` to `b` with a filled head (web `arrow`).
  static func arrow(_ ctx: GraphicsContext, from a: CGPoint, to b: CGPoint, color: Color, width: CGFloat = 2, head: CGFloat = 8) {
    let dx = b.x - a.x, dy = b.y - a.y
    let len = max(0.001, (dx * dx + dy * dy).squareRoot())
    guard len > 1 else { return }
    let ux = dx / len, uy = dy / len
    let base = CGPoint(x: b.x - ux * head, y: b.y - uy * head)
    segment(ctx, a, base, color: color, width: width)
    var tip = Path()
    tip.move(to: b)
    tip.addLine(to: CGPoint(x: base.x - uy * head * 0.55, y: base.y + ux * head * 0.55))
    tip.addLine(to: CGPoint(x: base.x + uy * head * 0.55, y: base.y - ux * head * 0.55))
    tip.closeSubpath()
    ctx.fill(tip, with: .color(color))
  }

  static func dot(_ ctx: GraphicsContext, _ p: CGPoint, radius: CGFloat, color: Color) {
    ctx.fill(Path(ellipseIn: CGRect(x: p.x - radius, y: p.y - radius, width: 2 * radius, height: 2 * radius)), with: .color(color))
  }

  /// A travelling wave from x0 to x1 (web bench `wave`): one cycle per 60 pt, κ-slowed.
  static func wave(
    _ ctx: GraphicsContext, x0: CGFloat, x1: CGFloat, y: CGFloat, amp: CGFloat, color: Color, t: Double, k: Double,
    phase0: Double = 0, decay: Double = 0, width: CGFloat = 2.2
  ) {
    guard x1 > x0 else { return }
    var pts: [CGPoint] = []
    var x = x0
    while x <= x1 {
      let u = Double(x - x0) / 60
      let a = Double(amp) * exp(-decay * Double(x - x0))
      pts.append(CGPoint(x: x, y: y - CGFloat(a * cos(tau * (u - k * t) + phase0))))
      x += 2
    }
    line(ctx, pts, color: color, width: width, glow: 0.5)
  }

  /// Colour of a vacuum wavelength (hue = frequency, rule R2).
  static func color(_ lambda: Double) -> Color { BandPalette.color(forWavelength: lambda) }
}

/// Redraws its content from the app clock: every frame while the clock runs (and the view
/// is on screen), and on each Step while paused. `content` receives the display time.
struct SpectrumClocked<Content: View>: View {
  @Environment(AppModel.self) private var app
  @ViewBuilder var content: (Double) -> Content

  var body: some View {
    let clock = app.clock
    if clock.isAnimating {
      VisibleTimeline { _ in content(clock.time) }
    } else {
      // displayTime is observed: a Step (or reset) while paused redraws.
      let _ = clock.displayTime
      content(clock.time)
    }
  }
}

/// A short muted hint line under a stage ("Drag to rotate · pinch to zoom").
struct StageHint: View {
  let text: String
  init(_ text: String) { self.text = text }
  var body: some View {
    Text(text)
      .font(.system(.caption2, design: .monospaced))
      .foregroundStyle(Theme.dim)
      .multilineTextAlignment(.center)
      .frame(maxWidth: .infinity, alignment: .center)
      .fixedSize(horizontal: false, vertical: true)
      .accessibilityHidden(true)
  }
}

/// The Scope / Patch pair for an instrument whose signal exists.
struct SpectrumSignalButtons: View {
  let scopeTitle: String
  let patchTitle: String
  let idPrefix: String
  let openScope: () -> Void
  let addPatch: () -> Void

  var body: some View {
    GlassEffectContainer(spacing: 10) {
      ViewThatFits(in: .horizontal) {
        HStack(spacing: 10) { buttons }
        VStack(alignment: .leading, spacing: 10) { buttons }
      }
    }
  }

  @ViewBuilder private var buttons: some View {
    ActionButton(scopeTitle, symbol: "waveform.path.ecg", action: openScope)
      .accessibilityIdentifier("\(idPrefix)-open-scope")
    ActionButton(patchTitle, symbol: "point.3.connected.trianglepath.dotted", action: addPatch)
      .accessibilityIdentifier("\(idPrefix)-add-patch")
  }
}
