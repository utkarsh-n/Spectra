import SwiftUI

/// Redraws its content whenever the model's plot clock ticks: about 30 times a second while
/// the Spin tab is on screen and its engines move (`SpinModel.plotTick`), and only while this
/// plot is scrolled into view: off screen it stops reading the tick, so it is not redrawn.
struct SpinTimeline<Content: View>: View {
  let model: SpinModel
  @ViewBuilder var content: (Int) -> Content
  @State private var onScreen = true

  var body: some View {
    content(onScreen ? model.plotTick : -1)
      .onScrollVisibilityChange(threshold: 0.01) { visible in onScreen = visible }
  }
}

/// Axis text for frequencies in hertz: "−120 Hz", "+3.1 kHz".
private func signedFrequency(_ f: Double) -> String {
  abs(f) < 1e-9 ? "0" : (f < 0 ? "−" : "+") + SpectraFormat.frequency(abs(f), digits: 2)
}

/// The detected FID in the rotating frame: I (band colour), Q (dashed) and the envelope |M⊥|
/// (muted). Triggered like a scope in Normal mode: each pulse or sequence starts a one-record
/// sweep from the left, and the last one holds until the next; with CW drive (or before any
/// pulse) it rolls over the last bench second instead. Redrawn only while visible.
struct SpinFIDTrace: View {
  let model: SpinModel
  let species: SpinSpecies
  let color: Color

  var body: some View {
    SpinTimeline(model: model) { _ in
      let runner = model.runner(species)
      let triggered = model.bench(species).continuous ? nil : runner.recorder.triggeredSweep(maxPoints: 400)
      let signal = triggered?.signal ?? runner.recorder.orderedWindow(maxPoints: 400).signal
      let filled = triggered?.filled ?? 1
      let seconds = runner.recordSeconds
      Canvas { ctx, size in
        let rect = CGRect(x: 0, y: 6, width: size.width, height: size.height - 22)
        ctx.plotGrid(in: rect, columns: 10, rows: 4, centre: true)
        let n = signal.count
        guard n > 1 else {
          ctx.annotation("Waiting for samples", at: CGPoint(x: rect.midX, y: rect.midY))
          return
        }
        let span = rect.width * CGFloat(filled)
        func point(_ i: Int, _ v: Double) -> CGPoint {
          CGPoint(
            x: rect.minX + span * CGFloat(i) / CGFloat(max(n - 1, 1)),
            y: rect.midY - rect.height / 2 * CGFloat(max(-1, min(1, v))))
        }
        var iPath = Path()
        var qPath = Path()
        var ePath = Path()
        for (k, s) in signal.enumerated() {
          let pi = point(k, s.x)
          let pq = point(k, s.y)
          let pe = point(k, (s.x * s.x + s.y * s.y).squareRoot())
          if k == 0 {
            iPath.move(to: pi)
            qPath.move(to: pq)
            ePath.move(to: pe)
          } else {
            iPath.addLine(to: pi)
            qPath.addLine(to: pq)
            ePath.addLine(to: pe)
          }
        }
        // Dotted: in Earth's field both lines are radio, whose band color is a gray-blue close to
        // the muted gray, so the envelope is told from I by its dots, not its color.
        ctx.phosphorStroke(ePath, color: Theme.muted.opacity(0.8), width: 1.1, glow: 0.3, dash: [1.5, 3])
        ctx.phosphorStroke(qPath, color: color.opacity(0.65), width: 1.1, glow: 0.4, dash: [4, 3])
        ctx.phosphorStroke(iPath, color: color, width: 1.5, glow: 0.8)
        let baseline = size.height - 7
        if triggered != nil {
          ctx.annotation("trigger", at: CGPoint(x: rect.minX + 10, y: baseline), anchor: .leading)
          ctx.annotation("+\(SpectraFormat.si(seconds, unit: "s"))", at: CGPoint(x: rect.maxX - 10, y: baseline), anchor: .trailing)
        } else {
          ctx.annotation("−\(SpectraFormat.si(seconds, unit: "s"))", at: CGPoint(x: rect.minX + 10, y: baseline), anchor: .leading)
          ctx.annotation("now", at: CGPoint(x: rect.maxX - 10, y: baseline), anchor: .trailing)
        }
        ctx.annotation("+M₀", at: CGPoint(x: rect.minX + 8, y: rect.minY + 8), anchor: .leading)
      }
      // Inside the timeline, so VoiceOver's value follows the trace (the engines are not
      // observed; only the plot tick redraws this).
      .accessibilityElement()
      .accessibilityLabel("Free induction decay, rotating frame")
      .accessibilityValue(summary(triggered: triggered != nil))
    }
  }

  private func summary(triggered: Bool) -> String {
    let now = model.runner(species).sample.signalMagnitude
    return "Transverse magnetization \(SpectraFormat.significant(now, 2)) of M zero. "
      + (triggered ? "Showing the sweep since the last pulse." : "Rolling over the last second.")
  }
}

/// |S(f)| of the last FID record against baseband frequency f (the line sits at
/// s·Δf: −Δf for protons, +Δf for electrons), with the expected position marked.
struct SpinSpectrumView: View {
  let spectrum: FIDSpectrum?
  let zoom: SpinSpectrumZoom
  let sampleRate: Double
  let expected: Double
  let color: Color

  var body: some View {
    Canvas { ctx, size in
      let rect = CGRect(x: 0, y: 6, width: size.width, height: size.height - 22)
      ctx.plotGrid(in: rect, columns: 8, rows: 4, centre: true)
      let half = sampleRate / 2 * zoom.fraction
      func x(_ f: Double) -> CGFloat { rect.minX + rect.width * CGFloat((f + half) / (2 * half)) }
      if expected.isFinite, abs(expected) <= half {
        var marker = Path()
        marker.move(to: CGPoint(x: x(expected), y: rect.minY))
        marker.addLine(to: CGPoint(x: x(expected), y: rect.maxY))
        ctx.stroke(marker, with: .color(Theme.amber.opacity(0.6)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
      }
      ctx.annotation(signedFrequency(-half), at: CGPoint(x: rect.minX + 10, y: size.height - 7), anchor: .leading)
      ctx.annotation("0", at: CGPoint(x: rect.midX, y: size.height - 7))
      ctx.annotation(signedFrequency(half), at: CGPoint(x: rect.maxX - 10, y: size.height - 7), anchor: .trailing)
      guard let spectrum, spectrum.frequencies.count > 2 else {
        ctx.annotation("Run a sequence to record an FID", at: CGPoint(x: rect.midX, y: rect.midY))
        return
      }
      let magnitude = spectrum.magnitude
      let peak = magnitude.max() ?? 1
      guard peak > 0 else { return }
      var path = Path()
      var started = false
      for (k, f) in spectrum.frequencies.enumerated() where abs(f) <= half {
        let p = CGPoint(x: x(f), y: rect.maxY - rect.height * CGFloat(magnitude[k] / peak) * 0.94)
        if started { path.addLine(to: p) } else { path.move(to: p) }
        started = true
      }
      ctx.phosphorStroke(path, color: color, width: 1.5, glow: 0.9)
    }
    .accessibilityElement()
    .accessibilityLabel("FID spectrum")
    .accessibilityValue(
      spectrum.map { "Peak at \(signedFrequency($0.peakFrequency))" } ?? "No record yet")
  }
}

/// The Wigner view of the FID record (Phase engine; Utkarsh's convention C): time across,
/// frequency up, positive warm, negative cool, with the time marginal underneath and the
/// frequency marginal at the right.
struct SpinWignerView: View, Equatable {
  let image: Phase.TimeFrequencyImage?
  let zoom: SpinSpectrumZoom
  let sampleRate: Double
  let busy: Bool

  /// Equal inputs draw the same picture: the 10 Hz readout refresh of the panel around it
  /// does not rebuild the image (`.equatable()` at the use site).
  nonisolated static func == (a: SpinWignerView, b: SpinWignerView) -> Bool {
    a.zoom == b.zoom && a.sampleRate == b.sampleRate && a.busy == b.busy && a.image == b.image
  }

  var body: some View {
    let picture = image.flatMap { Self.render($0, zoom: zoom, sampleRate: sampleRate) }
    Canvas { ctx, size in
      let strip: CGFloat = 18
      let rect = CGRect(x: 0, y: 4, width: size.width - strip - 4, height: size.height - strip - 22)
      guard let image, let picture else {
        ctx.plotGrid(in: rect, columns: 8, rows: 6, centre: false)
        ctx.annotation(busy ? "Computing…" : "Run a sequence to record an FID", at: CGPoint(x: rect.midX, y: rect.midY))
        return
      }
      ctx.draw(Image(decorative: picture.image, scale: 1).interpolation(.medium), in: rect)
      ctx.plotGrid(in: rect, columns: 8, rows: 6, centre: false)
      // Zero-frequency line (the carrier).
      var zero = Path()
      zero.move(to: CGPoint(x: rect.minX, y: rect.midY))
      zero.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
      ctx.stroke(zero, with: .color(Theme.axis), lineWidth: 0.6)
      // Time marginal (|z(t)|², M1) under the image.
      let tm = image.timeMarginal
      if let peak = tm.max(), peak > 0, tm.count > 1 {
        var path = Path()
        let base = rect.maxY + strip
        for (k, v) in tm.enumerated() {
          let p = CGPoint(
            x: rect.minX + rect.width * CGFloat(k) / CGFloat(tm.count - 1), y: base - (strip - 3) * CGFloat(max(0, v) / peak))
          if k == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }
        ctx.phosphorStroke(path, color: Theme.amber, width: 1, glow: 0.4)
      }
      // Frequency marginal (M2) at the right, over the shown band.
      let fm = Array(image.frequencyMarginal[picture.columns])
      if let peak = fm.max(), peak > 0, fm.count > 1 {
        var path = Path()
        let base = rect.maxX + 4
        for (k, v) in fm.enumerated() {
          let p = CGPoint(
            x: base + (strip - 2) * CGFloat(max(0, v) / peak), y: rect.maxY - rect.height * CGFloat(k) / CGFloat(fm.count - 1))
          if k == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }
        ctx.phosphorStroke(path, color: Theme.amber, width: 1, glow: 0.4)
      }
      ctx.annotation(signedFrequency(picture.top), at: CGPoint(x: rect.minX + 3, y: rect.minY + 7), anchor: .leading, color: Theme.text)
      ctx.annotation(signedFrequency(picture.bottom), at: CGPoint(x: rect.minX + 3, y: rect.maxY - 7), anchor: .leading, color: Theme.text)
      ctx.annotation("t = 0", at: CGPoint(x: rect.minX + 10, y: size.height - 7), anchor: .leading)
      ctx.annotation(
        "\(SpectraFormat.si(picture.duration, unit: "s"))", at: CGPoint(x: rect.maxX - 2, y: size.height - 7), anchor: .trailing)
    }
    .accessibilityElement()
    .accessibilityLabel("Wigner distribution of the FID")
    .accessibilityValue(
      image == nil
        ? "No record yet"
        : "Time across, frequency up. Warm is positive, cool is negative. Edges show the time and frequency marginals.")
  }

  struct Picture {
    let image: CGImage
    let columns: Range<Int>
    let top: Double
    let bottom: Double
    let duration: Double
  }

  /// A diverging image of the zoomed band: rows (time) across, columns (frequency) up.
  static func render(_ tf: Phase.TimeFrequencyImage, zoom: SpinSpectrumZoom, sampleRate: Double) -> Picture? {
    let plane = tf.plane
    let rows = plane.rows
    let cols = plane.columns
    guard rows > 1, cols > 1 else { return nil }
    let half = sampleRate / 2 * zoom.fraction
    let axis = plane.columnAxis
    var lo = cols
    var hi = 0
    for c in 0..<cols where abs(axis.value(c)) <= half + axis.step / 2 {
      lo = min(lo, c)
      hi = max(hi, c)
    }
    guard hi > lo else { return nil }
    let shown = lo..<(hi + 1)
    var maxAbs = 0.0
    for r in 0..<rows { for c in shown { maxAbs = max(maxAbs, abs(plane.value(row: r, column: c))) } }
    guard maxAbs > 0 else { return nil }
    let width = rows
    let height = shown.count
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    let bg = (r: 0.016, g: 0.031, b: 0.027)
    let warm = (r: 1.0, g: 0.56, b: 0.18)
    let cool = (r: 0.3, g: 0.62, b: 1.0)
    for r in 0..<rows {
      for (j, c) in shown.enumerated() {
        let v = plane.value(row: r, column: c) / maxAbs
        let a = pow(min(1, abs(v)), 0.6)
        let tint = v >= 0 ? warm : cool
        let y = height - 1 - j
        let o = (y * width + r) * 4
        pixels[o] = UInt8(min(255, (bg.r + (tint.r - bg.r) * a) * 255))
        pixels[o + 1] = UInt8(min(255, (bg.g + (tint.g - bg.g) * a) * 255))
        pixels[o + 2] = UInt8(min(255, (bg.b + (tint.b - bg.b) * a) * 255))
        pixels[o + 3] = 255
      }
    }
    guard let provider = CGDataProvider(data: Data(pixels) as CFData),
      let image = CGImage(
        width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: provider, decode: nil,
        shouldInterpolate: true, intent: .defaultIntent)
    else { return nil }
    let rowAxis = plane.rowAxis
    return Picture(
      image: image, columns: shown, top: axis.value(hi), bottom: axis.value(lo),
      duration: rowAxis.value(rows - 1) - rowAxis.value(0))
  }
}

/// The axle tip seen from above, e_x + i e_y: an IQ plot (left) and its complex spectrum in
/// dB (right). Steady precession is one line near 0 Hz; the inertial nod adds essentially one
/// sideband, on the spin's side.
struct SpinTipView: View {
  let model: SpinModel

  var body: some View {
    HStack(spacing: 10) {
      PlotWell(height: 150, grid: 0) {
        SpinTimeline(model: model) { _ in
          // Read outside the Canvas so each tick hands the renderer new data (a renderer that
          // captures only the model compares equal and is not redrawn).
          let tips = Array(model.tipHistory.suffix(960))
          Canvas { ctx, size in
            let side = min(size.width, size.height) - 16
            let rect = CGRect(x: (size.width - side) / 2, y: (size.height - side) / 2, width: side, height: side)
            ctx.plotGrid(in: rect, columns: 4, rows: 4, centre: true)
            guard tips.count > 2 else { return }
            var reach = 0.05
            for t in tips { reach = max(reach, (t.x * t.x + t.y * t.y).squareRoot()) }
            var path = Path()
            for (k, t) in tips.enumerated() {
              let p = CGPoint(x: rect.midX + rect.width / 2 * CGFloat(t.x / reach), y: rect.midY - rect.height / 2 * CGFloat(t.y / reach))
              if k == 0 { path.move(to: p) } else { path.addLine(to: p) }
            }
            ctx.phosphorStroke(path, color: Theme.analogy, width: 1.1, glow: 0.6)
            if let last = tips.last {
              ctx.phosphorDot(
                at: CGPoint(x: rect.midX + rect.width / 2 * CGFloat(last.x / reach), y: rect.midY - rect.height / 2 * CGFloat(last.y / reach)),
                color: Theme.amber, radius: 2.5)
            }
            ctx.annotation("I", at: CGPoint(x: rect.maxX - 4, y: rect.midY - 7), anchor: .trailing)
            ctx.annotation("Q", at: CGPoint(x: rect.midX + 6, y: rect.minY + 5), anchor: .leading)
          }
        }
      }
      .frame(maxWidth: 150)
      .accessibilityElement()
      .accessibilityLabel("Axle tip from above, I against Q")
      .accessibilityValue(tipSummary)
      PlotWell(height: 150, grid: 0) {
        SpinTipSpectrum(
          spectrum: model.tipSpectrum, precessionHz: model.readings.gyro?.precessionHz ?? 0,
          nodHz: model.readings.gyro?.nutationHz ?? 0)
      }
    }
  }

  private var tipSummary: String {
    guard let g = model.readings.gyro else { return "No rotor yet" }
    return "Tilt \(Int((g.tilt * 180 / .pi).rounded())) degrees, circling at \(SpectraFormat.frequency(abs(g.precessionHz)))"
  }
}

/// The tip's complex spectrum in dB re its peak over ±60 Hz (simulated time), widened to
/// ±120, ±240 or ±480 Hz (the tip stream's Nyquist) when the inertial nod sits further out.
struct SpinTipSpectrum: View {
  let spectrum: FIDSpectrum?
  let precessionHz: Double
  let nodHz: Double

  /// The half-span that shows both lines: the nod is L₃/I₁, about 38 Hz at the default
  /// 3000 rpm but 77 Hz on the Free gyroscope trip and over 150 Hz at the motor's top.
  static func span(precessionHz: Double, nodHz: Double) -> Double {
    let need = 1.15 * max(abs(precessionHz.isFinite ? precessionHz : 0), abs(nodHz.isFinite ? nodHz : 0))
    return [60.0, 120, 240].first { need <= $0 } ?? HeavyTop.tipSampleRate / 2
  }

  var body: some View {
    let half = Self.span(precessionHz: precessionHz, nodHz: nodHz)
    Canvas { ctx, size in
      let rect = CGRect(x: 4, y: 6, width: size.width - 8, height: size.height - 22)
      ctx.plotGrid(in: rect, columns: 6, rows: 4, centre: false)
      func x(_ f: Double) -> CGFloat { rect.minX + rect.width * CGFloat((f + half) / (2 * half)) }
      for (f, label) in [(precessionHz, "Ωp"), (nodHz, "nod"), (-nodHz, "")] where abs(f) < half && f.isFinite {
        var m = Path()
        m.move(to: CGPoint(x: x(f), y: rect.minY))
        m.addLine(to: CGPoint(x: x(f), y: rect.maxY))
        ctx.stroke(m, with: .color(Theme.amber.opacity(label.isEmpty ? 0.25 : 0.5)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
        if !label.isEmpty { ctx.annotation(label, at: CGPoint(x: x(f) + 3, y: rect.minY + 6), anchor: .leading, color: Theme.amber) }
      }
      ctx.annotation("−\(Int(half)) Hz", at: CGPoint(x: rect.minX + 6, y: size.height - 7), anchor: .leading)
      ctx.annotation("+\(Int(half)) Hz", at: CGPoint(x: rect.maxX - 6, y: size.height - 7), anchor: .trailing)
      guard let spectrum, spectrum.frequencies.count > 2 else {
        ctx.annotation("Collecting…", at: CGPoint(x: rect.midX, y: rect.midY))
        return
      }
      let mag = spectrum.magnitude
      let peak = mag.max() ?? 1
      guard peak > 0 else { return }
      let floor = -70.0
      var path = Path()
      var started = false
      for (k, f) in spectrum.frequencies.enumerated() where abs(f) <= half {
        let db = max(floor, 20 * log10(max(mag[k], 1e-12) / peak))
        let p = CGPoint(x: x(f), y: rect.minY + rect.height * CGFloat(db / floor))
        if started { path.addLine(to: p) } else { path.move(to: p) }
        started = true
      }
      ctx.phosphorStroke(path, color: Theme.analogy, width: 1.3, glow: 0.7)
      ctx.annotation("0 dB", at: CGPoint(x: rect.minX + 4, y: rect.minY + 6), anchor: .leading)
      ctx.annotation("−70", at: CGPoint(x: rect.minX + 4, y: rect.maxY - 6), anchor: .leading)
    }
    .accessibilityElement()
    .accessibilityLabel("Axle tip spectrum")
    .accessibilityValue(
      "Precession \(SpectraFormat.frequency(abs(precessionHz))), inertial nod \(SpectraFormat.frequency(nodHz)), span plus or minus \(Int(half)) hertz")
  }
}
