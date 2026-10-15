import SwiftUI

/// An I/Q constellation: received symbols as phosphor dots over the ideal points (hollow
/// amber rings), on a square grid with I across and Q up.
///
/// ```swift
/// ConstellationPlot(points: rx.symbols, ideal: QAM16.points, range: 1.4)
/// ```
struct ConstellationPlot: View {
  var points: [SIMD2<Float>]
  var ideal: [SIMD2<Float>] = []
  /// Half-width of the plotted square in signal units.
  var range: Float = 1.5
  var color: Color = Theme.phosphor
  var accessibilityLabel = "Constellation"

  var body: some View {
    Canvas { ctx, size in
      let side = min(size.width, size.height)
      let rect = CGRect(x: (size.width - side) / 2, y: (size.height - side) / 2, width: side, height: side)
      ctx.plotGrid(in: rect, columns: 8, rows: 8, centre: true)
      ctx.annotation("I", at: CGPoint(x: rect.maxX - 6, y: rect.midY - 8), color: Theme.muted)
      ctx.annotation("Q", at: CGPoint(x: rect.midX + 8, y: rect.minY + 7), color: Theme.muted)
      let r = max(range, 1e-6)
      func map(_ p: SIMD2<Float>) -> CGPoint {
        CGPoint(
          x: rect.midX + CGFloat(p.x / r) * rect.width / 2, y: rect.midY - CGFloat(p.y / r) * rect.height / 2)
      }
      var dots = Path()
      for p in points where p.x.isFinite && p.y.isFinite {
        let c = map(p)
        dots.addEllipse(in: CGRect(x: c.x - 1.4, y: c.y - 1.4, width: 2.8, height: 2.8))
      }
      ctx.fill(dots, with: .color(color.opacity(0.75)))
      var rings = Path()
      for p in ideal {
        let c = map(p)
        rings.addEllipse(in: CGRect(x: c.x - 4, y: c.y - 4, width: 8, height: 8))
      }
      ctx.phosphorStroke(rings, color: Theme.amber, width: 1, glow: 0.6)
    }
    .aspectRatio(1, contentMode: .fit)
    .accessibilityElement()
    .accessibilityLabel(accessibilityLabel)
    .accessibilityValue("\(points.count) received symbols, \(ideal.count) ideal points")
  }
}

/// A polar radiation cut: gain in dB against angle (0° at the top, clockwise), rings every
/// 10 dB down to `floor`, spokes every 30°. An optional reference pattern is dashed.
///
/// ```swift
/// PolarPlot(gains: pattern.ePlane, floor: -30, color: BandPalette.color(forFrequency: f))
/// ```
struct PolarPlot: View {
  /// Gain in dB (relative to the maximum, ≤ 0) at angles 2π·i/count.
  var gains: [Double]
  var reference: [Double]? = nil
  var floor: Double = -30
  var color: Color = Theme.phosphor
  var accessibilityLabel = "Radiation pattern"

  var body: some View {
    Canvas { ctx, size in
      let radius = min(size.width, size.height) / 2 - 26
      let c = CGPoint(x: size.width / 2, y: size.height / 2)
      var grid = Path()
      var ring = 0.0
      while ring >= floor {
        let r = radius * CGFloat(1 - ring / floor)
        grid.addEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
        ring -= 10
      }
      for k in 0..<12 {
        let a = Double(k) * .pi / 6
        grid.move(to: c)
        grid.addLine(to: CGPoint(x: c.x + radius * sin(a), y: c.y - radius * cos(a)))
      }
      ctx.stroke(grid, with: .color(Theme.phosphor.opacity(0.09)), lineWidth: 0.6)
      // Labels sit centred just outside the outer ring, inside the canvas.
      for deg in [0, 90, 180, 270] {
        let a = Double(deg) * .pi / 180
        ctx.annotation("\(deg)°", at: CGPoint(x: c.x + (radius + 13) * sin(a), y: c.y - (radius + 10) * cos(a)))
      }
      ctx.annotation("\(Int(floor)) dB", at: CGPoint(x: c.x + 3, y: c.y - 6), anchor: .leading)
      if let reference { ctx.phosphorStroke(path(reference, c, radius), color: Theme.muted, width: 1, glow: 0, dash: [4, 4]) }
      let main = path(gains, c, radius)
      ctx.fill(main, with: .color(color.opacity(0.12)))
      ctx.phosphorStroke(main, color: color, width: 1.5)
    }
    .aspectRatio(1, contentMode: .fit)
    .accessibilityElement()
    .accessibilityLabel(accessibilityLabel)
    .accessibilityValue(summary)
  }

  private func path(_ gains: [Double], _ c: CGPoint, _ radius: CGFloat) -> Path {
    var p = Path()
    let n = gains.count
    guard n > 2 else { return p }
    for i in 0...n {
      let g = gains[i % n]
      let r = radius * CGFloat(max(0, 1 - max(g.isFinite ? g : floor, floor) / floor))
      let a = 2 * Double.pi * Double(i) / Double(n)
      let pt = CGPoint(x: c.x + r * sin(a), y: c.y - r * cos(a))
      if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
    }
    p.closeSubpath()
    return p
  }

  private var summary: String {
    guard let best = gains.indices.max(by: { gains[$0] < gains[$1] }) else { return "No pattern" }
    let deg = Int((360 * Double(best) / Double(max(1, gains.count))).rounded())
    return "Strongest toward \(deg) degrees"
  }
}
