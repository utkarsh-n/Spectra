import SwiftUI

/// A vertical line on a spectrum plot: a channel edge, a known source, an alias.
struct FrequencyMarker: Identifiable, Hashable {
  var id: String { "\(label)@\(frequency)" }
  var frequency: Double
  var label: String
  var color: Color = Theme.amber
  var dashed = true
}

/// A power spectrum in dB against frequency (linear or log), drawn as a glowing phosphor
/// line over a soft fill, with frequency and dB labels, an optional peak marker and
/// vertical markers. Bin `i` sits at `i · binWidth` hertz (FFT bins 0…N/2).
///
/// ```swift
/// SpectrumPlot(bins: fft.db, binWidth: 48_000 / 4096, frequencyRange: 20...24_000,
///              logFrequency: true, dbRange: -110...0, color: Theme.analogy)
/// ```
struct SpectrumPlot: View {
  var bins: [Float]
  /// Hz per bin.
  var binWidth: Double
  var frequencyRange: ClosedRange<Double>
  var logFrequency = false
  var dbRange: ClosedRange<Double> = -120...0
  var color: Color = Theme.phosphor
  var showsPeak = true
  var markers: [FrequencyMarker] = []
  var unit = "dB"
  var accessibilityLabel = "Spectrum"

  var body: some View {
    Canvas { ctx, size in
      let rect = CGRect(x: 0, y: 4, width: size.width, height: size.height - 18)
      ctx.plotGrid(in: rect, columns: 10, rows: 6, centre: false)
      let fx = PlotScale(frequencyRange, logarithmic: logFrequency)
      let dy = PlotScale(dbRange)
      func point(_ f: Double, _ db: Double) -> CGPoint {
        CGPoint(
          x: rect.minX + rect.width * fx.fraction(f),
          y: rect.maxY - rect.height * min(1, max(0, dy.fraction(db))))
      }
      // Frequency labels.
      for f in fx.ticks(target: logFrequency ? 6 : 5) {
        let x = rect.minX + rect.width * fx.fraction(f)
        guard x > rect.minX + 12, x < rect.maxX - 12 else { continue }
        ctx.annotation(SpectraFormat.frequency(f, digits: 2), at: CGPoint(x: x, y: rect.maxY + 8))
      }
      for db in dy.ticks(target: 3) {
        ctx.annotation(
          "\(Int(db)) \(unit)", at: CGPoint(x: rect.minX + 3, y: rect.maxY - rect.height * dy.fraction(db) - 6),
          anchor: .leading)
      }
      // Vertical markers.
      for m in markers where frequencyRange.contains(m.frequency) {
        let x = rect.minX + rect.width * fx.fraction(m.frequency)
        var line = Path()
        line.move(to: CGPoint(x: x, y: rect.minY))
        line.addLine(to: CGPoint(x: x, y: rect.maxY))
        ctx.stroke(line, with: .color(m.color.opacity(0.7)), style: StrokeStyle(lineWidth: 1, dash: m.dashed ? [3, 3] : []))
        ctx.annotation(m.label, at: CGPoint(x: x + 3, y: rect.minY + 8), anchor: .leading, color: m.color)
      }
      guard bins.count > 1, binWidth > 0 else { return }
      var path = Path()
      var started = false
      var peak: (f: Double, db: Double)?
      for (i, v) in bins.enumerated() {
        let f = Double(i) * binWidth
        guard f >= frequencyRange.lowerBound, f <= frequencyRange.upperBound, v.isFinite else { continue }
        let db = Double(v)
        let p = point(f, db)
        if started { path.addLine(to: p) } else {
          path.move(to: p)
          started = true
        }
        if i > 0, db > (peak?.db ?? -.infinity) { peak = (f, db) }
      }
      guard started else { return }
      var area = path
      if let last = path.currentPoint {
        area.addLine(to: CGPoint(x: last.x, y: rect.maxY))
        area.addLine(to: CGPoint(x: rect.minX + rect.width * max(0, fx.fraction(max(binWidth, frequencyRange.lowerBound))), y: rect.maxY))
        area.closeSubpath()
      }
      ctx.fill(
        area,
        with: .linearGradient(
          Gradient(colors: [color.opacity(0.28), color.opacity(0.02)]), startPoint: CGPoint(x: 0, y: rect.minY),
          endPoint: CGPoint(x: 0, y: rect.maxY)))
      ctx.phosphorStroke(path, color: color, width: 1.25)
      if showsPeak, let peak {
        let p = point(peak.f, peak.db)
        ctx.phosphorDot(at: p, color: Theme.amber, radius: 2.5)
        ctx.annotation(
          SpectraFormat.frequency(peak.f, digits: 3), at: CGPoint(x: min(p.x + 5, rect.maxX - 40), y: max(p.y - 9, rect.minY + 6)),
          anchor: .leading, color: Theme.amber)
      }
    }
    .accessibilityElement()
    .accessibilityLabel(accessibilityLabel)
    .accessibilityValue(peakDescription)
  }

  private var peakDescription: String {
    var best: (Int, Float)?
    for (i, v) in bins.enumerated() where i > 0 && v.isFinite {
      let f = Double(i) * binWidth
      guard frequencyRange.contains(f) else { continue }
      if v > (best?.1 ?? -.infinity) { best = (i, v) }
    }
    guard let best else { return "No signal" }
    return "Peak at \(SpectraFormat.frequency(Double(best.0) * binWidth)), \(Int(best.1)) \(unit)"
  }
}

/// The scrolling image behind a `WaterfallView`: one row per spectrum, newest at the top,
/// coloured dark → phosphor → amber → white. Push rows from the main actor at any rate; the
/// `CGImage` is rebuilt once per push.
@Observable @MainActor
final class WaterfallBuffer {
  let width: Int
  let height: Int
  var dbRange: ClosedRange<Double>
  /// Bumped on every push (observed, so views redraw).
  private(set) var revision = 0
  @ObservationIgnored private(set) var image: CGImage?
  @ObservationIgnored private var pixels: [UInt8]
  private static let palette: [UInt32] = WaterfallBuffer.makePalette()

  init(width: Int = 256, height: Int = 160, dbRange: ClosedRange<Double> = -110...0) {
    self.width = max(2, width)
    self.height = max(2, height)
    self.dbRange = dbRange
    pixels = [UInt8](repeating: 0, count: max(2, width) * max(2, height) * 4)
  }

  /// Adds a spectrum row (dB values, resampled to `width` columns by max-hold).
  func push(_ db: [Float]) {
    guard !db.isEmpty else { return }
    let rowBytes = width * 4
    // Scroll down one row.
    pixels.withUnsafeMutableBytes { raw in
      guard let base = raw.baseAddress else { return }
      memmove(base + rowBytes, base, rowBytes * (height - 1))
    }
    let lo = dbRange.lowerBound
    let span = max(1e-9, dbRange.upperBound - dbRange.lowerBound)
    let palette = Self.palette
    for x in 0..<width {
      let a = x * db.count / width
      let b = max(a + 1, (x + 1) * db.count / width)
      var v = -Float.infinity
      for i in a..<min(b, db.count) where db[i] > v { v = db[i] }
      let t = v.isFinite ? min(1, max(0, (Double(v) - lo) / span)) : 0
      let c = palette[Int(t * 255)]
      let o = x * 4
      pixels[o] = UInt8(c >> 24)
      pixels[o + 1] = UInt8((c >> 16) & 0xFF)
      pixels[o + 2] = UInt8((c >> 8) & 0xFF)
      pixels[o + 3] = 255
    }
    image = makeImage()
    revision &+= 1
  }

  func clear() {
    for i in pixels.indices { pixels[i] = 0 }
    image = nil
    revision &+= 1
  }

  private func makeImage() -> CGImage? {
    let data = Data(pixels) as CFData
    guard let provider = CGDataProvider(data: data) else { return nil }
    return CGImage(
      width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
      space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: provider, decode: nil,
      shouldInterpolate: true, intent: .defaultIntent)
  }

  /// 256 colours: plot well → deep green → phosphor → amber → white.
  private static func makePalette() -> [UInt32] {
    let stops: [(Double, RGB)] = [
      (0, Theme.plotWellRGB), (0.35, RGB(0.05, 0.32, 0.17)), (0.62, Theme.phosphorRGB), (0.85, Theme.amberRGB),
      (1, RGB(1, 1, 1)),
    ]
    return (0..<256).map { i in
      let t = Double(i) / 255
      var k = 0
      while k < stops.count - 2, t > stops[k + 1].0 { k += 1 }
      let (t0, c0) = stops[k]
      let (t1, c1) = stops[k + 1]
      let c = c0.mix(c1, (t - t0) / max(1e-9, t1 - t0))
      func byte(_ x: Double) -> UInt32 { UInt32((min(1, max(0, x)) * 255).rounded()) }
      return byte(c.r) << 24 | byte(c.g) << 16 | byte(c.b) << 8 | 0xFF
    }
  }
}

/// A spectrogram: time runs downward (newest row at the top), frequency across.
struct WaterfallView: View {
  let buffer: WaterfallBuffer
  var accessibilityLabel = "Spectrogram"

  var body: some View {
    // Read the image outside any drawing closure: a `Canvas` that captured only the buffer
    // reference kept its first drawing (live-requests §5). A fresh `Image` per revision redraws.
    let revision = buffer.revision
    let image = buffer.image
    ZStack {
      Color.clear
      if let image {
        Image(decorative: image, scale: 1)
          .resizable()
          .interpolation(.medium)
          .id(revision)
      }
    }
    .accessibilityElement()
    .accessibilityLabel(accessibilityLabel)
    .accessibilityValue("Time runs downward, newest at the top.")
  }
}
