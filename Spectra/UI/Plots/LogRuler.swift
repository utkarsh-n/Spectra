import SwiftUI

/// A coloured cursor on a `LogRuler` (Spectra sources A/B/C).
struct RulerCursor: Identifiable, Hashable {
  let id: String
  var label: String
  var lambda: Double
  var color: Color
}

/// The wavelength ruler: log₁₀ λ in metres from `range.lowerBound` (short, gamma, at the
/// left) to `range.upperBound` (long, radio). Band colours follow `BandPalette`; the visible
/// band is drawn as a true spectral gradient.
///
/// Used full size by the Spectrum tuner and in miniature by `SpectrumStrip`.
struct LogRuler: View {
  /// Visible window in log₁₀ metres; the full app range is `SpectrumMarker.logRange`.
  var range: ClosedRange<Double> = SpectrumMarker.logRange
  var markers: [SpectrumMarker] = []
  var cursors: [RulerCursor] = []
  /// Label decades with frequency under the wavelength.
  var showsFrequency = true
  var accessibilityLabel = "Wavelength ruler"

  var body: some View {
    Canvas { ctx, size in
      let rect = CGRect(origin: .zero, size: size)
      let bar = CGRect(x: rect.minX, y: rect.minY + 18, width: rect.width, height: 10)
      LogRuler.drawBands(ctx, in: bar, range: range, opacity: 0.85)
      LogRuler.drawBandNames(ctx, above: bar, range: range)
      // Decade ticks with λ (and f) labels.
      let span = range.upperBound - range.lowerBound
      let every = span > 12 ? 3 : (span > 6 ? 2 : 1)
      var ticks = Path()
      for d in Int(ceil(range.lowerBound))...Int(floor(range.upperBound)) {
        let x = rect.minX + rect.width * (Double(d) - range.lowerBound) / span
        ticks.move(to: CGPoint(x: x, y: bar.maxY))
        ticks.addLine(to: CGPoint(x: x, y: bar.maxY + (d % every == 0 ? 6 : 3)))
        guard d % every == 0, x > 14, x < rect.maxX - 14 else { continue }
        ctx.annotation(SpectraFormat.wavelength(pow(10, Double(d)), digits: 2), at: CGPoint(x: x, y: bar.maxY + 13))
        if showsFrequency {
          ctx.annotation(
            SpectraFormat.frequency(SpectrumMarker.frequency(forLambda: pow(10, Double(d))), digits: 2),
            at: CGPoint(x: x, y: bar.maxY + 24), color: Theme.dim.opacity(0.75))
        }
      }
      ctx.stroke(ticks, with: .color(Theme.axis), lineWidth: 0.75)
      for m in markers {
        LogRuler.drawMarker(ctx, m, in: CGRect(x: rect.minX, y: bar.minY - 4, width: rect.width, height: bar.height + 8), range: range, emphasis: 0.6)
      }
      for c in cursors {
        let lg = log10(c.lambda)
        guard lg.isFinite, range.contains(lg) else { continue }
        let x = rect.minX + rect.width * (lg - range.lowerBound) / span
        var line = Path()
        line.move(to: CGPoint(x: x, y: rect.minY + 2))
        line.addLine(to: CGPoint(x: x, y: bar.maxY + 2))
        ctx.phosphorStroke(line, color: c.color, width: 2)
        ctx.annotation(c.label, at: CGPoint(x: x, y: rect.minY + 6), color: c.color)
      }
    }
    .accessibilityElement()
    .accessibilityLabel(accessibilityLabel)
    .accessibilityValue(
      cursors.map { "\($0.label) \(SpectraFormat.wavelength($0.lambda))" }.joined(separator: ", "))
  }

  // MARK: Shared drawing (also used by SpectrumStrip)

  /// x position (points) of log₁₀ λ `lg` across `rect` for `range`.
  static func x(_ lg: Double, in rect: CGRect, range: ClosedRange<Double>) -> CGFloat {
    rect.minX + rect.width * CGFloat((lg - range.lowerBound) / (range.upperBound - range.lowerBound))
  }

  /// The band bar: each band in its colour, the visible band as a spectral gradient.
  static func drawBands(_ ctx: GraphicsContext, in rect: CGRect, range: ClosedRange<Double>, opacity: Double) {
    let clip = Path(roundedRect: rect, cornerRadius: rect.height / 2)
    var inner = ctx
    inner.clip(to: clip)
    for band in BandPalette.bands {
      let lo = band.lo > 0 ? log10(band.lo) : range.lowerBound - 1
      let hi = band.hi.isFinite ? log10(band.hi) : range.upperBound + 1
      let x0 = max(rect.minX, x(lo, in: rect, range: range))
      let x1 = min(rect.maxX, x(hi, in: rect, range: range))
      guard x1 > x0 else { continue }
      let r = CGRect(x: x0, y: rect.minY, width: x1 - x0, height: rect.height)
      if band.key == "visible" {
        let stops = stride(from: 400.0, through: 700.0, by: 25).map { nm in
          Gradient.Stop(color: BandPalette.color(forWavelength: nm * 1e-9), location: (nm - 400) / 300)
        }
        inner.fill(Path(r), with: .linearGradient(Gradient(stops: stops), startPoint: CGPoint(x: r.minX, y: 0), endPoint: CGPoint(x: r.maxX, y: 0)))
      } else {
        inner.fill(Path(r), with: .color(band.color.opacity(opacity * 0.55)))
      }
    }
    inner.stroke(clip, with: .color(.white.opacity(0.08)), lineWidth: 0.5)
  }

  /// Short band names centred above the bar where they fit.
  static func drawBandNames(_ ctx: GraphicsContext, above rect: CGRect, range: ClosedRange<Double>, minimumWidth: CGFloat = 18) {
    for band in BandPalette.bands where band.key != "visible" {
      let lo = max(range.lowerBound, band.lo > 0 ? log10(band.lo) : range.lowerBound)
      let hi = min(range.upperBound, band.hi.isFinite ? log10(band.hi) : range.upperBound)
      guard hi > lo else { continue }
      let x0 = x(lo, in: rect, range: range)
      let x1 = x(hi, in: rect, range: range)
      guard x1 - x0 >= minimumWidth else { continue }
      ctx.draw(
        Text(band.short).font(.system(size: 8, weight: .semibold, design: .monospaced)).foregroundStyle(band.color.opacity(0.9)),
        at: CGPoint(x: (x0 + x1) / 2, y: rect.minY - 7))
    }
  }

  /// One marker: a glowing tick in its band colour (EM) or a dashed phosphor tick (analogy).
  static func drawMarker(_ ctx: GraphicsContext, _ m: SpectrumMarker, in rect: CGRect, range: ClosedRange<Double>, emphasis: Double) {
    let lg = m.logLambda
    guard lg.isFinite, lg >= range.lowerBound, lg <= range.upperBound else { return }
    let x = x(lg, in: rect, range: range)
    var line = Path()
    line.move(to: CGPoint(x: x, y: rect.minY))
    line.addLine(to: CGPoint(x: x, y: rect.maxY))
    let color = BandPalette.color(for: m)
    ctx.phosphorStroke(line, color: color.opacity(0.4 + 0.6 * emphasis), width: 1.25 + emphasis, glow: emphasis, dash: m.isEM ? [] : [2, 2])
    var head = Path()
    head.move(to: CGPoint(x: x - 3, y: rect.minY - 3))
    head.addLine(to: CGPoint(x: x + 3, y: rect.minY - 3))
    head.addLine(to: CGPoint(x: x, y: rect.minY + 1))
    head.closeSubpath()
    ctx.fill(head, with: .color(color))
  }
}
