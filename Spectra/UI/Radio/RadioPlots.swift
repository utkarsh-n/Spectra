import CoreGraphics
import SwiftUI

// Canvas plots specific to the Radio tab. Shared plots (PolarPlot, ConstellationPlot,
// LinePlot, WaterfallView, Sparkline) come from UI/Plots.

// MARK: - Heat maps

/// Colour maps for signed (Wigner) and non-negative (spectrogram, |ψ|²) images.
nonisolated enum RadioColorMap: Sendable {
  /// Phase-space quasi-distributions: positive warm orange, negative cool blue, zero = the
  /// plot well (Utkarsh's poster convention).
  case diverging
  /// Non-negative maps: well → deep green → phosphor → amber → white.
  case sequential

  static let warm = RGB(1.0, 0.58, 0.2)
  static let warmHot = RGB(1.0, 0.92, 0.72)
  static let cool = RGB(0.27, 0.55, 1.0)
  static let coolHot = RGB(0.78, 0.9, 1.0)

  /// 256-entry RGBA lookup (index 0 = −1 or 0, 255 = +1).
  var lut: [UInt32] {
    switch self {
    case .diverging: Self.divergingLUT
    case .sequential: Self.sequentialLUT
    }
  }

  private static func pack(_ c: RGB) -> UInt32 {
    func byte(_ x: Double) -> UInt32 { UInt32((min(1, max(0, x)) * 255).rounded()) }
    return byte(c.r) << 24 | byte(c.g) << 16 | byte(c.b) << 8 | 0xFF
  }

  private static let divergingLUT: [UInt32] = (0..<256).map { i in
    let v = Double(i) / 255 * 2 - 1
    let a = pow(abs(v), 0.65)
    let well = Theme.plotWellRGB
    let c: RGB
    if v >= 0 {
      c = a < 0.8 ? well.mix(warm, a / 0.8) : warm.mix(warmHot, (a - 0.8) / 0.2)
    } else {
      c = a < 0.8 ? well.mix(cool, a / 0.8) : cool.mix(coolHot, (a - 0.8) / 0.2)
    }
    return pack(c)
  }

  private static let sequentialLUT: [UInt32] = (0..<256).map { i in
    let t = pow(Double(i) / 255, 0.7)
    let stops: [(Double, RGB)] = [
      (0, Theme.plotWellRGB), (0.35, RGB(0.05, 0.32, 0.17)), (0.65, Theme.phosphorRGB), (0.88, Theme.amberRGB), (1, RGB(1, 1, 1)),
    ]
    var k = 0
    while k < stops.count - 2, t > stops[k + 1].0 { k += 1 }
    let (t0, c0) = stops[k]
    let (t1, c1) = stops[k + 1]
    return pack(c0.mix(c1, (t - t0) / max(1e-9, t1 - t0)))
  }
}

/// Builds a `CGImage` from a row-major value grid.
enum RadioHeatImage {
  /// - Parameters:
  ///   - values: rows × columns, row-major (−1…1 for `.diverging`, 0…1 for `.sequential`).
  ///   - timeAcross: true draws rows across (x = row) and columns up (top = last column), the
  ///     usual time–frequency layout; false draws the grid as stored (row 0 at the top).
  static func make(_ values: [Float], rows: Int, columns: Int, map: RadioColorMap, timeAcross: Bool) -> CGImage? {
    guard rows > 0, columns > 0, values.count >= rows * columns else { return nil }
    let width = timeAcross ? rows : columns
    let height = timeAcross ? columns : rows
    let lut = map.lut
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    for r in 0..<rows {
      for c in 0..<columns {
        let v = values[r * columns + c]
        let t: Double
        switch map {
        case .diverging: t = (Double(min(max(v.isFinite ? v : 0, -1), 1)) + 1) / 2
        case .sequential: t = Double(min(max(v.isFinite ? v : 0, 0), 1))
        }
        let color = lut[Int((t * 255).rounded())]
        let x = timeAcross ? r : c
        let y = timeAcross ? (columns - 1 - c) : r
        let o = (y * width + x) * 4
        pixels[o] = UInt8(color >> 24)
        pixels[o + 1] = UInt8((color >> 16) & 0xFF)
        pixels[o + 2] = UInt8((color >> 8) & 0xFF)
        pixels[o + 3] = 255
      }
    }
    guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
    return CGImage(
      width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
      space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: provider, decode: nil,
      shouldInterpolate: true, intent: .defaultIntent)
  }
}

/// A heat map with axis labels: the image fills the plot rect, the left edge carries
/// `yLabels` (top, middle, bottom) and the bottom edge `xLabels` (left, middle, right).
struct RadioHeatMapView: View {
  let image: CGImage?
  var title: String
  var yLabels: [String]
  var xLabels: [String]
  var accessibilityLabel: String
  var accessibilityValue: String = ""

  var body: some View {
    Canvas { ctx, size in
      let rect = CGRect(x: 2, y: 18, width: size.width - 4, height: size.height - 34)
      ctx.annotation(title, at: CGPoint(x: rect.minX + 4, y: 8), anchor: .leading, color: Theme.muted)
      if let image {
        ctx.draw(Image(decorative: image, scale: 1).interpolation(.medium), in: rect)
      }
      ctx.stroke(Path(rect), with: .color(Theme.phosphor.opacity(0.18)), lineWidth: 0.75)
      let ys = [rect.minY + 7, rect.midY, rect.maxY - 7]
      for (k, label) in yLabels.prefix(3).enumerated() {
        ctx.annotation(label, at: CGPoint(x: rect.minX + 4, y: ys[k]), anchor: .leading, color: Theme.text.opacity(0.75))
      }
      let xs: [(CGFloat, UnitPoint)] = [(rect.minX + 2, .leading), (rect.midX, .center), (rect.maxX - 3, .trailing)]
      for (k, label) in xLabels.prefix(3).enumerated() {
        ctx.annotation(label, at: CGPoint(x: xs[k].0, y: rect.maxY + 8), anchor: xs[k].1)
      }
    }
    .accessibilityElement()
    .accessibilityLabel(accessibilityLabel)
    .accessibilityValue(accessibilityValue)
  }
}

/// A small horizontal colour bar legend for the diverging map ("− 0 +").
struct RadioDivergingLegend: View {
  var body: some View {
    HStack(spacing: 6) {
      Text("−").font(Theme.annotationFont).foregroundStyle(RadioColorMap.cool.color)
      LinearGradient(
        colors: [RadioColorMap.coolHot.color, RadioColorMap.cool.color, Theme.plotWell, RadioColorMap.warm.color, RadioColorMap.warmHot.color],
        startPoint: .leading, endPoint: .trailing
      )
      .frame(height: 6)
      .clipShape(.capsule)
      Text("+").font(Theme.annotationFont).foregroundStyle(RadioColorMap.warm.color)
    }
    .frame(maxWidth: 160)
    .accessibilityElement()
    .accessibilityLabel("Color scale: blue negative, orange positive")
  }
}

// MARK: - Baseband spectrum with channel mask

/// A two-sided baseband spectrum (fftshifted bins, the carrier in the middle) labelled in
/// absolute frequency, with the occupied channel shaded between amber edges and the
/// neighbouring channels outlined.
struct RadioSpectrumView: View {
  /// dB relative to the peak, index count/2 = the carrier.
  var bins: [Float]
  var sampleRate: Double
  var carrier: Double
  var occupied: Double
  /// Channel raster for the adjacent-channel outlines (0 = none).
  var channelWidth: Double
  var color: Color
  var dbRange: ClosedRange<Double> = -80...4

  var body: some View {
    Canvas { ctx, size in
      let rect = CGRect(x: 0, y: 4, width: size.width, height: size.height - 20)
      ctx.plotGrid(in: rect, columns: 8, rows: 4, centre: false)
      let half = sampleRate / 2
      func x(_ offset: Double) -> CGFloat { rect.minX + rect.width * CGFloat((offset + half) / (2 * half)) }
      func y(_ db: Double) -> CGFloat {
        let f = (db - dbRange.lowerBound) / (dbRange.upperBound - dbRange.lowerBound)
        return rect.maxY - rect.height * CGFloat(min(1, max(0, f)))
      }
      // Adjacent channels.
      if channelWidth > 0, occupied > 0 {
        for k in [-1.0, 1.0] {
          let lo = k * channelWidth - occupied / 2
          let hi = k * channelWidth + occupied / 2
          guard hi > -half, lo < half else { continue }
          let r = CGRect(x: x(max(lo, -half)), y: rect.minY, width: x(min(hi, half)) - x(max(lo, -half)), height: rect.height)
          ctx.stroke(Path(r), with: .color(Theme.muted.opacity(0.35)), style: StrokeStyle(lineWidth: 0.75, dash: [3, 4]))
          ctx.annotation(k < 0 ? "ADJ −1" : "ADJ +1", at: CGPoint(x: r.midX, y: rect.minY + 8), color: Theme.dim)
        }
      }
      // The channel mask (occupied bandwidth).
      if occupied > 0 {
        let lo = max(-occupied / 2, -half)
        let hi = min(occupied / 2, half)
        let r = CGRect(x: x(lo), y: rect.minY, width: x(hi) - x(lo), height: rect.height)
        ctx.fill(Path(r), with: .color(Theme.amber.opacity(0.07)))
        var edges = Path()
        edges.move(to: CGPoint(x: r.minX, y: rect.minY))
        edges.addLine(to: CGPoint(x: r.minX, y: rect.maxY))
        edges.move(to: CGPoint(x: r.maxX, y: rect.minY))
        edges.addLine(to: CGPoint(x: r.maxX, y: rect.maxY))
        ctx.stroke(edges, with: .color(Theme.amber.opacity(0.7)), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
      }
      // dB labels.
      for db in stride(from: 0.0, through: dbRange.lowerBound, by: -20) {
        ctx.annotation(SpectraFormat.decibels(db, decimals: 0), at: CGPoint(x: rect.minX + 3, y: y(db) - 6), anchor: .leading)
      }
      // Trace.
      let n = bins.count
      if n > 1 {
        var path = Path()
        for k in 0..<n {
          let offset = -half + 2 * half * Double(k) / Double(n)
          let p = CGPoint(x: x(offset), y: y(Double(bins[k])))
          if k == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }
        var area = path
        area.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        area.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        area.closeSubpath()
        ctx.fill(area, with: .color(color.opacity(0.10)))
        ctx.phosphorStroke(path, color: color, width: 1.3, glow: 0.8)
      }
      // Frequency labels: the carrier in the middle and the band edges.
      ctx.annotation(SpectraFormat.frequency(carrier, digits: 4), at: CGPoint(x: rect.midX, y: rect.maxY + 9))
      ctx.annotation("−\(SpectraFormat.frequency(half, digits: 2))", at: CGPoint(x: rect.minX + 2, y: rect.maxY + 9), anchor: .leading)
      ctx.annotation("+\(SpectraFormat.frequency(half, digits: 2))", at: CGPoint(x: rect.maxX - 2, y: rect.maxY + 9), anchor: .trailing)
    }
    .accessibilityElement()
    .accessibilityLabel("Spectrum around the carrier")
    .accessibilityValue("Center \(SpectraFormat.frequency(carrier)), span \(SpectraFormat.frequency(sampleRate)), occupied \(SpectraFormat.frequency(occupied))")
  }
}

// MARK: - Link budget chart

/// The budget as a horizontal waterfall: each term moves the running level (gains phosphor,
/// losses rose), ending at the received power; the noise floor is a dashed white line and the
/// SNR the gap between them. (Neutral colours: blue is reserved for the E field.)
struct RadioBudgetChart: View {
  let terms: [RF.LinkTerm]
  let received: Double
  let noiseFloor: Double
  /// RF names the path-loss term after its model ("Indoor office (TR 38.901 NLOS)"); the bar
  /// says "Path loss" and VoiceOver reads the model's name.
  var pathModelName: String?
  /// Rows and label columns grow with Dynamic Type (the labels are caption-sized text).
  @ScaledMetric(relativeTo: .caption2) private var rowHeight: CGFloat = 22
  @ScaledMetric(relativeTo: .caption2) private var labelWidth: CGFloat = 92
  @ScaledMetric(relativeTo: .caption2) private var valueWidth: CGFloat = 64
  @Environment(\.dynamicTypeSize) private var typeSize

  private struct Bar: Identifiable {
    let id: Int
    let name: String
    let spoken: String
    let from: Double
    let to: Double
    let kind: RF.LinkTerm.Kind?
  }

  private var bars: [Bar] {
    var out: [Bar] = []
    var level = 0.0
    for (k, t) in terms.enumerated() {
      let from = t.kind == .power ? 0 : level
      let to = t.kind == .power ? t.dB : level + t.dB
      let isPath = t.kind == .loss && t.name == pathModelName
      out.append(Bar(id: k, name: isPath ? "Path loss" : Self.short(t.name), spoken: isPath ? "Path loss, \(t.name)," : t.name, from: from, to: to, kind: t.kind))
      level = to
    }
    out.append(Bar(id: out.count, name: "Received", spoken: "Received", from: 0, to: received, kind: nil))
    return out
  }

  static func short(_ name: String) -> String {
    switch name {
    case "Tx power": "Tx power"
    case "Tx antenna": "Tx antenna"
    case "Rx antenna": "Rx antenna"
    default: name.count > 16 ? String(name.prefix(15)) + "…" : name
    }
  }

  var body: some View {
    let bars = bars
    let levels = bars.flatMap { [$0.from, $0.to] } + (noiseFloor.isFinite ? [noiseFloor] : [])
    let lo = (levels.min() ?? -100) - 6
    let hi = (levels.max() ?? 0) + 6
    // Accessibility sizes: each term gets its own line (name left, value right) with the bar
    // under it across the full width, so large text never covers the bars.
    let stacked = typeSize.isAccessibilitySize
    let rowHeight = stacked ? self.rowHeight + 20 : self.rowHeight
    let labelWidth = stacked ? 0 : self.labelWidth
    let valueWidth = stacked ? 0 : self.valueWidth
    Canvas { ctx, size in
      let plot = CGRect(x: labelWidth, y: 0, width: size.width - labelWidth - valueWidth, height: CGFloat(bars.count) * rowHeight)
      func x(_ v: Double) -> CGFloat { plot.minX + plot.width * CGFloat((v - lo) / max(1e-9, hi - lo)) }
      // Vertical guides span the whole chart, or (stacked) only each row's bar band so they
      // never cross the text lines.
      func guide(at gx: CGFloat) -> Path {
        var p = Path()
        if stacked {
          for row in bars.indices {
            let barMid = CGFloat(row) * rowHeight + rowHeight - 10
            p.move(to: CGPoint(x: gx, y: barMid - 9))
            p.addLine(to: CGPoint(x: gx, y: barMid + 9))
          }
        } else {
          p.move(to: CGPoint(x: gx, y: 0))
          p.addLine(to: CGPoint(x: gx, y: plot.maxY))
        }
        return p
      }
      // Zero line.
      if lo < 0, hi > 0 {
        ctx.stroke(guide(at: x(0)), with: .color(Theme.muted.opacity(0.3)), lineWidth: 0.75)
      }
      for (row, bar) in bars.enumerated() {
        let top = CGFloat(row) * rowHeight
        // Stacked: text in the upper part of the row, the bar in its lowest 20 points.
        let textMid = stacked ? top + (rowHeight - 20) / 2 : top + rowHeight / 2
        let barMid = stacked ? top + rowHeight - 10 : top + rowHeight / 2
        let a = x(min(bar.from, bar.to))
        let b = x(max(bar.from, bar.to))
        let color: Color =
          switch bar.kind {
          case .power: Theme.amber
          case .gain: Theme.phosphor
          case .loss: Theme.roseRGB.color
          case nil: Theme.amber
          }
        let r = CGRect(x: a, y: barMid - 6, width: max(1.5, b - a), height: 12)
        ctx.fill(Path(roundedRect: r, cornerRadius: 3), with: .color(color.opacity(bar.kind == nil ? 0.9 : 0.6)))
        if row > 0, bar.kind != .power, !stacked {
          var link = Path()
          link.move(to: CGPoint(x: x(bar.from), y: barMid - rowHeight + 6))
          link.addLine(to: CGPoint(x: x(bar.from), y: barMid - 6))
          ctx.stroke(link, with: .color(Theme.muted.opacity(0.4)), lineWidth: 0.6)
        }
        ctx.draw(
          Text(bar.name).font(.caption2).foregroundStyle(bar.kind == nil ? Theme.text : Theme.muted),
          at: CGPoint(x: 0, y: textMid), anchor: .leading)
        let delta = bar.kind == .power || bar.kind == nil ? bar.to : bar.to - bar.from
        let text = SpectraFormat.decibels(delta, unit: bar.kind == .power || bar.kind == nil ? "dBm" : "dB", decimals: 1, signed: bar.kind == .gain || bar.kind == .loss)
        ctx.draw(
          Text(text).font(.system(.caption2, design: .monospaced)).foregroundStyle(color),
          at: CGPoint(x: size.width, y: textMid), anchor: .trailing)
      }
      if noiseFloor.isFinite {
        ctx.stroke(guide(at: x(noiseFloor)), with: .color(Theme.text.opacity(0.8)), style: StrokeStyle(lineWidth: 1.2, dash: [4, 3]))
        ctx.annotation("NOISE", at: CGPoint(x: x(noiseFloor) + 3, y: plot.maxY + 7), anchor: .leading, color: Theme.text)
      }
    }
    .frame(height: CGFloat(bars.count) * rowHeight + 16)
    .accessibilityElement()
    .accessibilityLabel("Link budget chart")
    .accessibilityValue(
      bars.map { bar in
        // Levels (transmit power, received power) are dBm; the terms between them are dB.
        let level = bar.kind == .power || bar.kind == nil
        return "\(bar.spoken) \(SpectraFormat.decibels(bar.to - (level ? 0 : bar.from), unit: level ? "dBm" : "dB", decimals: 1))"
      }
      .joined(separator: ", "))
  }
}

// MARK: - RSSI vs distance (Live check)

/// The log-distance model RSSI(d) across 0.1–30 m, the live RSSI as a horizontal line and the
/// solved distance where they meet.
struct RadioRSSIPlot: View {
  /// Model RSSI (dBm) at each distance in `distances`.
  let model: [Double]
  let distances: [Double]
  let liveRSSI: Double?
  let solved: Double?
  let color: Color

  var body: some View {
    Canvas { ctx, size in
      let rect = CGRect(x: 30, y: 6, width: size.width - 34, height: size.height - 24)
      ctx.plotGrid(in: rect, columns: 6, rows: 4, centre: false)
      let xs = PlotScale(0.1...30, logarithmic: true)
      let finite = model.filter(\.isFinite) + (liveRSSI.map { [$0] } ?? [])
      let ys = PlotScale(((finite.min() ?? -100) - 5)...((finite.max() ?? -30) + 5))
      func p(_ d: Double, _ r: Double) -> CGPoint {
        CGPoint(x: rect.minX + rect.width * xs.fraction(d), y: rect.maxY - rect.height * ys.fraction(r))
      }
      var path = Path()
      for (k, d) in distances.enumerated() where model[k].isFinite {
        if path.isEmpty { path.move(to: p(d, model[k])) } else { path.addLine(to: p(d, model[k])) }
      }
      ctx.phosphorStroke(path, color: Theme.muted, width: 1.2, glow: 0)
      if let liveRSSI {
        var line = Path()
        line.move(to: CGPoint(x: rect.minX, y: p(1, liveRSSI).y))
        line.addLine(to: CGPoint(x: rect.maxX, y: p(1, liveRSSI).y))
        ctx.phosphorStroke(line, color: color, width: 1.2, glow: 0.6, dash: [4, 3])
        ctx.annotation(SpectraFormat.decibels(liveRSSI, unit: "dBm", decimals: 0), at: CGPoint(x: rect.maxX - 2, y: p(1, liveRSSI).y - 7), anchor: .trailing, color: color)
      }
      if let solved, let liveRSSI, (0.1...30).contains(solved) {
        ctx.phosphorDot(at: p(solved, liveRSSI), color: Theme.amber, radius: 3.5)
      }
      for d in [0.1, 1.0, 10.0] {
        ctx.annotation(d < 1 ? "10 cm" : "\(Int(d)) m", at: CGPoint(x: rect.minX + rect.width * xs.fraction(d), y: rect.maxY + 9))
      }
      ctx.annotation("30 m", at: CGPoint(x: rect.maxX, y: rect.maxY + 9), anchor: .trailing)
      for r in ys.ticks(target: 3) {
        ctx.annotation(SpectraFormat.decibels(r, unit: "", decimals: 0).trimmingCharacters(in: .whitespaces), at: CGPoint(x: rect.minX - 3, y: rect.maxY - rect.height * ys.fraction(r)), anchor: .trailing)
      }
    }
    .accessibilityElement()
    .accessibilityLabel("RSSI against distance")
    .accessibilityValue(solved.map { "Model distance \(RF.Units.format(distance: $0))" } ?? "No live signal")
  }
}

// MARK: - Small labels

/// The SPECULATIVE label for not-yet-standardized systems (6G), styled like a provenance badge.
struct RadioSpeculativeBadge: View {
  /// 9 pt at the default text size, following Dynamic Type up to 15 pt like `ProvenanceBadge`.
  @ScaledMetric(relativeTo: .caption2) private var size: CGFloat = 9

  var body: some View {
    Text("SPECULATIVE")
      .font(.system(size: min(15, size), weight: .semibold, design: .monospaced))
      .tracking(0.8)
      .foregroundStyle(Theme.ionizing)
      .lineLimit(1)
      .fixedSize()
      .padding(.horizontal, 6)
      .padding(.vertical, 2.5)
      .background(Theme.ionizing.opacity(0.1), in: .capsule)
      .overlay { Capsule().strokeBorder(Theme.ionizing.opacity(0.45), lineWidth: 0.75) }
      .accessibilityLabel("Speculative: not yet standardized")
  }
}

/// A disabled-state note for a control: a lock glyph and one line.
struct RadioDisabledReason: View {
  let text: String
  init(_ text: String) { self.text = text }
  var body: some View {
    Label(text, systemImage: "lock.fill")
      .font(.caption2)
      .foregroundStyle(Theme.dim)
      .fixedSize(horizontal: false, vertical: true)
  }
}

/// Wraps a Hashable value that is not `Identifiable` (RF enums) for `ChoiceChips`.
struct RadioChoice<Value: Hashable>: Hashable, Identifiable {
  var value: Value
  var id: Value { value }

  static func items(_ values: [Value]) -> [RadioChoice<Value>] { values.map { RadioChoice(value: $0) } }

  static func binding(_ get: @escaping () -> Value, _ set: @escaping (Value) -> Void) -> Binding<RadioChoice<Value>> {
    Binding(get: { RadioChoice(value: get()) }, set: { set($0.value) })
  }
}
