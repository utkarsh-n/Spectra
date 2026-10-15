import SwiftUI

/// A 1-D axis mapping between data and points, linear or log₁₀.
nonisolated struct PlotScale: Hashable, Sendable {
  var domain: ClosedRange<Double>
  var logarithmic = false

  init(_ domain: ClosedRange<Double>, logarithmic: Bool = false) {
    self.logarithmic = logarithmic && domain.lowerBound > 0
    self.domain = domain
  }

  /// Fraction 0…1 across the axis (unclamped; non-finite → NaN).
  func fraction(_ value: Double) -> Double {
    guard value.isFinite else { return .nan }
    if logarithmic {
      guard value > 0 else { return -.infinity }
      return (log10(value) - log10(domain.lowerBound)) / (log10(domain.upperBound) - log10(domain.lowerBound))
    }
    let span = domain.upperBound - domain.lowerBound
    return span > 0 ? (value - domain.lowerBound) / span : 0.5
  }

  /// The value at fraction `f`.
  func value(at f: Double) -> Double {
    if logarithmic {
      return pow(10, log10(domain.lowerBound) + f * (log10(domain.upperBound) - log10(domain.lowerBound)))
    }
    return domain.lowerBound + f * (domain.upperBound - domain.lowerBound)
  }

  /// "Nice" tick values inside the domain: decades for log axes, 1-2-5 steps otherwise.
  func ticks(target: Int = 5) -> [Double] {
    if logarithmic {
      let lo = Int(floor(log10(domain.lowerBound)))
      let hi = Int(ceil(log10(domain.upperBound)))
      let every = max(1, (hi - lo) / max(1, target))
      return stride(from: lo, through: hi, by: every).map { pow(10, Double($0)) }.filter { domain.contains($0) }
    }
    let span = domain.upperBound - domain.lowerBound
    guard span > 0, span.isFinite else { return [] }
    let raw = span / Double(max(1, target))
    let magnitude = pow(10, floor(log10(raw)))
    let step = [1.0, 2, 5, 10].map { $0 * magnitude }.first { $0 >= raw } ?? magnitude * 10
    let first = ceil(domain.lowerBound / step) * step
    return stride(from: first, through: domain.upperBound + step * 1e-9, by: step).map { abs($0) < step * 1e-9 ? 0 : $0 }
  }

  /// A range padded by `fraction` on each side (for auto-scaled y axes); a flat range grows ±1.
  static func padded(_ values: some Sequence<Double>, fraction: Double = 0.08) -> ClosedRange<Double> {
    var lo = Double.infinity
    var hi = -Double.infinity
    for v in values where v.isFinite {
      lo = min(lo, v)
      hi = max(hi, v)
    }
    guard lo.isFinite, hi.isFinite else { return -1...1 }
    if hi - lo < 1e-12 { return (lo - 1)...(hi + 1) }
    let pad = (hi - lo) * fraction
    return (lo - pad)...(hi + pad)
  }
}

extension GraphicsContext {
  /// Orbitals' phosphor look in SwiftUI: a wide low-alpha glow under a crisp core stroke.
  func phosphorStroke(
    _ path: Path, color: Color, width: CGFloat = 1.5, glow: CGFloat = 1, dash: [CGFloat] = []
  ) {
    if glow > 0 {
      stroke(path, with: .color(color.opacity(0.10 * glow)), style: StrokeStyle(lineWidth: width * 6, lineCap: .round, lineJoin: .round, dash: dash))
      stroke(path, with: .color(color.opacity(0.22 * glow)), style: StrokeStyle(lineWidth: width * 2.6, lineCap: .round, lineJoin: .round, dash: dash))
    }
    stroke(path, with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round, dash: dash))
  }

  /// A glowing dot.
  func phosphorDot(at p: CGPoint, color: Color, radius: CGFloat = 3) {
    fill(Path(ellipseIn: CGRect(x: p.x - radius * 2.4, y: p.y - radius * 2.4, width: radius * 4.8, height: radius * 4.8)), with: .color(color.opacity(0.14)))
    fill(Path(ellipseIn: CGRect(x: p.x - radius, y: p.y - radius, width: radius * 2, height: radius * 2)), with: .color(color))
  }

  /// A 9 pt monospaced annotation (Orbitals' canvas labels).
  func annotation(_ text: String, at p: CGPoint, anchor: UnitPoint = .center, color: Color = Theme.dim) {
    draw(Text(text).font(Theme.annotationFont).foregroundStyle(color), at: p, anchor: anchor)
  }

  /// The plot-well grid: `columns` × `rows` divisions with a brighter centre cross.
  func plotGrid(in rect: CGRect, columns: Int = 10, rows: Int = 8, centre: Bool = true) {
    var grid = Path()
    for i in 0...max(1, columns) {
      let x = rect.minX + rect.width * CGFloat(i) / CGFloat(max(1, columns))
      grid.move(to: CGPoint(x: x, y: rect.minY))
      grid.addLine(to: CGPoint(x: x, y: rect.maxY))
    }
    for j in 0...max(1, rows) {
      let y = rect.minY + rect.height * CGFloat(j) / CGFloat(max(1, rows))
      grid.move(to: CGPoint(x: rect.minX, y: y))
      grid.addLine(to: CGPoint(x: rect.maxX, y: y))
    }
    stroke(grid, with: .color(Theme.phosphor.opacity(0.07)), lineWidth: 0.5)
    if centre {
      var cross = Path()
      cross.move(to: CGPoint(x: rect.midX, y: rect.minY))
      cross.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
      cross.move(to: CGPoint(x: rect.minX, y: rect.midY))
      cross.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
      stroke(cross, with: .color(Theme.phosphor.opacity(0.13)), lineWidth: 0.75)
    }
  }
}

/// Redraws its content every display frame only while it is on screen, the scene is
/// active and `paused` is false (Orbitals rule: instruments off screen cost nothing).
///
/// ```swift
/// VisibleTimeline { _ in LinePlot(series: model.liveSeries()) }
/// ```
struct VisibleTimeline<Content: View>: View {
  /// Seconds between redraws (nil = every frame).
  var minimumInterval: Double? = nil
  var paused = false
  @ViewBuilder var content: (Date) -> Content

  @Environment(\.scenePhase) private var scenePhase
  @State private var onScreen = false

  var body: some View {
    TimelineView(.animation(minimumInterval: minimumInterval, paused: paused || !onScreen || scenePhase != .active)) { context in
      content(context.date)
    }
    .onAppear { onScreen = true }
    .onDisappear { onScreen = false }
    .onScrollVisibilityChange(threshold: 0.01) { visible in onScreen = visible }
  }
}

/// Reads the newest `seconds` of a stream as plot values (sample-and-hold irregular streams
/// are returned as-is; the plot draws them as steps).
enum StreamWindow {
  /// Values and times of the newest `seconds`, decimated by min/max pairs to at most
  /// `maxPoints` so peaks survive.
  static func read(_ stream: SignalStream, seconds: Double, maxPoints: Int = 600) -> (values: [Double], times: [Double]) {
    let now = SignalClock.now()
    let snap = stream.ring.snapshot(since: now - seconds)
    let n = snap.count
    guard n > maxPoints, maxPoints >= 4 else {
      return (snap.values.map(Double.init), snap.times)
    }
    let buckets = maxPoints / 2
    var values: [Double] = []
    var times: [Double] = []
    values.reserveCapacity(buckets * 2)
    times.reserveCapacity(buckets * 2)
    for b in 0..<buckets {
      let lo = b * n / buckets
      let hi = max(lo + 1, (b + 1) * n / buckets)
      var minI = lo
      var maxI = lo
      for i in lo..<hi {
        if snap.values[i] < snap.values[minI] { minI = i }
        if snap.values[i] > snap.values[maxI] { maxI = i }
      }
      for i in [min(minI, maxI), max(minI, maxI)] {
        values.append(Double(snap.values[i]))
        times.append(snap.times[i])
      }
    }
    return (values, times)
  }
}
