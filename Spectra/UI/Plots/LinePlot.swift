import SwiftUI

/// One trace in a `LinePlot`.
struct PlotSeries: Identifiable {
  let id: String
  var values: [Double]
  /// Optional x positions (same count as `values`); otherwise the index.
  var x: [Double]? = nil
  var color: Color = Theme.phosphor
  var width: CGFloat = 1.5
  var glow: CGFloat = 1
  var dashed = false
  /// Draw as sample-and-hold steps (irregular streams such as BLE RSSI).
  var steps = false
  /// Accessibility name ("E field").
  var label: String = ""
}

/// A phosphor line plot in a Canvas: grid, zero line, one or more glowing traces.
///
/// ```swift
/// PlotWell(height: 160) {
///   LinePlot(series: [PlotSeries(id: "E", values: e, color: Theme.fieldE, label: "E")],
///            yRange: -1...1, accessibilityLabel: "E and B against distance")
/// }
/// ```
struct LinePlot: View {
  var series: [PlotSeries]
  var xRange: ClosedRange<Double>? = nil
  var yRange: ClosedRange<Double>? = nil
  var columns = 10
  var rows = 8
  var showsGrid = true
  /// y tick labels at the left edge ("+1", "0", "−1").
  var yLabel: ((Double) -> String)? = nil
  var accessibilityLabel: String = "Plot"

  var body: some View {
    Canvas { ctx, size in
      let rect = CGRect(origin: .zero, size: size).insetBy(dx: 1, dy: 4)
      if showsGrid { ctx.plotGrid(in: rect, columns: columns, rows: rows, centre: false) }
      let y = PlotScale(yRange ?? PlotScale.padded(series.flatMap(\.values)))
      let xDomain = xRange ?? Self.xDomain(series)
      let x = PlotScale(xDomain)
      // Zero line.
      let zf = y.fraction(0)
      if zf > 0, zf < 1 {
        var zero = Path()
        let zy = rect.maxY - rect.height * zf
        zero.move(to: CGPoint(x: rect.minX, y: zy))
        zero.addLine(to: CGPoint(x: rect.maxX, y: zy))
        ctx.stroke(zero, with: .color(Theme.axis), lineWidth: 0.75)
      }
      if let yLabel {
        for t in y.ticks(target: 4) {
          let py = rect.maxY - rect.height * y.fraction(t)
          ctx.annotation(yLabel(t), at: CGPoint(x: rect.minX + 3, y: py), anchor: .leading)
        }
      }
      for s in series where s.values.count > 1 {
        var path = Path()
        var started = false
        var last = CGPoint.zero
        for (i, v) in s.values.enumerated() where v.isFinite {
          let xv = s.x?[safe: i] ?? Double(i)
          let p = CGPoint(
            x: rect.minX + rect.width * x.fraction(xv), y: rect.maxY - rect.height * y.fraction(v))
          if !started {
            path.move(to: p)
            started = true
          } else if s.steps {
            path.addLine(to: CGPoint(x: p.x, y: last.y))
            path.addLine(to: p)
          } else {
            path.addLine(to: p)
          }
          last = p
        }
        ctx.phosphorStroke(path, color: s.color, width: s.width, glow: s.glow, dash: s.dashed ? [5, 4] : [])
      }
    }
    .accessibilityElement()
    .accessibilityLabel(accessibilityLabel)
    .accessibilityValue(summary)
  }

  private var summary: String {
    series.compactMap { s -> String? in
      guard let last = s.values.last(where: \.isFinite) else { return nil }
      let name = s.label.isEmpty ? s.id : s.label
      return "\(name) \(SpectraFormat.significant(last, 3))"
    }.joined(separator: ", ")
  }

  private static func xDomain(_ series: [PlotSeries]) -> ClosedRange<Double> {
    var lo = Double.infinity
    var hi = -Double.infinity
    for s in series {
      if let xs = s.x, let first = xs.first, let last = xs.last {
        lo = min(lo, first)
        hi = max(hi, last)
      } else if s.values.count > 1 {
        lo = min(lo, 0)
        hi = max(hi, Double(s.values.count - 1))
      }
    }
    guard lo.isFinite, hi.isFinite, hi > lo else { return 0...1 }
    return lo...hi
  }
}

/// A small inline trend line (Live cards, node previews): newest value at the right, an
/// optional soft fill underneath.
struct Sparkline: View {
  var values: [Double]
  var color: Color = Theme.phosphor
  var range: ClosedRange<Double>? = nil
  var fill = true
  var steps = false

  var body: some View {
    Canvas { ctx, size in
      let finite = values.filter(\.isFinite)
      guard finite.count > 1 else { return }
      let y = PlotScale(range ?? PlotScale.padded(finite, fraction: 0.12))
      let n = values.count
      var path = Path()
      var started = false
      var last = CGPoint.zero
      for (i, v) in values.enumerated() where v.isFinite {
        let p = CGPoint(
          x: size.width * CGFloat(i) / CGFloat(max(1, n - 1)),
          y: size.height * (1 - min(1, max(0, y.fraction(v)))))
        if !started {
          path.move(to: p)
          started = true
        } else if steps {
          path.addLine(to: CGPoint(x: p.x, y: last.y))
          path.addLine(to: p)
        } else {
          path.addLine(to: p)
        }
        last = p
      }
      if fill {
        var area = path
        area.addLine(to: CGPoint(x: last.x, y: size.height))
        area.addLine(to: CGPoint(x: 0, y: size.height))
        area.closeSubpath()
        ctx.fill(
          area,
          with: .linearGradient(
            Gradient(colors: [color.opacity(0.22), color.opacity(0)]), startPoint: .zero,
            endPoint: CGPoint(x: 0, y: size.height)))
      }
      ctx.phosphorStroke(path, color: color, width: 1.25, glow: 0.7)
      ctx.phosphorDot(at: last, color: color, radius: 2)
    }
    .accessibilityHidden(true)
  }
}

fileprivate extension Array {
  /// The element at `index`, or nil when out of bounds.
  subscript(safe index: Int) -> Element? {
    indices.contains(index) ? self[index] : nil
  }
}
