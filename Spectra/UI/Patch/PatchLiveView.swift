import SwiftUI

/// The inspector's big live view of a node: the full plot of what it outputs (or, for a
/// sink, what it receives), drawn with the foundation plots.
struct PatchLiveView: View {
  let node: PatchNode
  @Environment(AppModel.self) private var app

  var body: some View {
    let model = app.patch
    // The evaluator is not observed; the preview revision (15 Hz) drives the redraw.
    let _ = model.revision
    let value = primary(model)
    Group {
      switch value?.payload {
      case .audio(let b)?:
        // A slow sensor (100 Hz magnetometer, BLE adverts) brings a few samples a step: draw
        // the node's rolling history, as its card does, not a two-point line.
        let history = model.histories(node.id)
        let slow = b.count < 64 && history.count > 1
        PlotWell(height: 170) {
          LinePlot(
            series: [
              PlotSeries(
                id: "x", values: slow ? history : PatchModel.decimate(b.samples, to: 400),
                color: PatchColors.color(PatchModel.tint(of: value)), steps: b.isIrregular, label: node.title)
            ],
            yLabel: { SpectraFormat.significant($0, 2) }, accessibilityLabel: "\(node.title) samples")
        }
        caption(
          slow
            ? "Recent history · \(b.isIrregular ? "irregular" : SpectraFormat.frequency(b.sampleRate)) · \(b.unit)"
            : "\(b.count) samples · \(b.isIrregular ? "irregular" : SpectraFormat.frequency(b.sampleRate)) · \(b.unit)")
      case .iq(let b)? where node.kind == .gyroscope && model.trail(node.id).count > 1:
        // One step of the tip is a few samples: the inspector draws its recent path, the
        // precession circle with the nod's wobble on it.
        let trail = model.trail(node.id)
        let r = max(0.05, (trail.map { max(abs($0.x), abs($0.y)) }.max() ?? 0.3) * 1.15)
        PlotWell(height: 220) {
          ConstellationPlot(
            points: trail, range: r, color: PatchColors.color(PatchModel.tint(of: value)),
            accessibilityLabel: "Gyroscope tip seen from above")
        }
        caption(
          "The tip seen from above over the last few seconds · \(SpectraFormat.frequency(b.sampleRate)) · the circle is the precession, its wobble the nod")
      case .iq(let b)?:
        if b.isSymbols {
          PlotWell(height: 220) {
            ConstellationPlot(
              points: Array(b.iq.points.suffix(1500)), ideal: b.ideal.count <= 256 ? b.ideal : [],
              range: Float(node.kind == .constellation ? node.number("range") : 1.5),
              color: PatchColors.color(PatchModel.tint(of: value)), accessibilityLabel: "Received symbols")
          }
          caption("\(b.iq.count) symbols\(b.modulation.map { " · \($0.displayName)" } ?? "") · ideal points in amber")
        } else {
          PlotWell(height: 170) {
            LinePlot(
              series: [
                PlotSeries(id: "i", values: PatchModel.decimate(b.iq.i, to: 400), color: PatchColors.color(PatchModel.tint(of: value)), label: "I"),
                PlotSeries(id: "q", values: PatchModel.decimate(b.iq.q, to: 400), color: Theme.amber, width: 1, glow: 0.5, label: "Q"),
              ],
              accessibilityLabel: "\(node.title) I and Q")
          }
          caption(
            "I (color) and Q (amber) · \(SpectraFormat.frequency(b.sampleRate)) · \(b.carrierHz.map { "around \(SpectraFormat.frequency($0)), HETERODYNED" } ?? "baseband")")
        }
      case .spectrum(let s)?:
        spectrum(s, value: value)
      case .image(let img)?:
        PlotWell(height: 220) {
          SignedHeatmap(values: img.image.plane.signedUnit(), rows: img.image.plane.rows, columns: img.image.plane.columns)
            .padding(6)
        }
        caption(
          "\(img.mode.title) · time down, frequency across (\(img.complex ? "−fs/2 … fs/2" : "0 … fs/2")) · warm positive, cool negative · \(SpectraFormat.si(img.duration, unit: "s")) record")
      case .em(let w)?:
        PlotWell(height: 90) { PatchPreviewView(preview: NodePreview(plot: .swatch(lambda: w.lambda), tint: .band(w.lambda))).padding(8) }
        caption("\(SpectraFormat.frequency(w.frequency)) · E₀ \(SpectraFormat.si(w.e0, unit: "V/m")) · θ \(String(format: "%.0f°", w.polarization))")
      case .bits(let b)?:
        PlotWell(height: 110) {
          Text(b.text ?? b.bits.prefix(256).map { $0 == 0 ? "0" : "1" }.joined())
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(Theme.phosphor)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(10)
        }
      case .control?, .attitude?, .event?:
        let trace = model.histories(node.id)
        PlotWell(height: 150) {
          LinePlot(
            series: [PlotSeries(id: "v", values: trace, color: Theme.amber, label: node.title)],
            yLabel: { SpectraFormat.significant($0, 3) }, accessibilityLabel: "\(node.title) over time")
        }
      case nil:
        PlotWell(height: 90) {
          Text(model.status(node.id)?.text ?? "Nothing has flowed yet.")
            .font(.footnote).foregroundStyle(Theme.muted).padding()
        }
      }
    }
  }

  @ViewBuilder private func spectrum(_ s: SpectrumFrame, value: PortValue?) -> some View {
    let model = app.patch
    let floor = node.kind == .spectrum ? node.number("floor") : -120
    let db = s.decibels
    let top = max(floor + 30, Double(db.max() ?? 0) + 6)
    if s.startFrequency >= 0 {
      PlotWell(height: 170) {
        SpectrumPlot(
          bins: db, binWidth: s.binWidth,
          frequencyRange: max(s.binWidth, s.startFrequency + s.binWidth)...max(s.endFrequency, s.binWidth * 2),
          logFrequency: node.kind == .spectrum && node.flag("log"), dbRange: floor...top,
          color: PatchColors.color(PatchModel.tint(of: value)), showsPeak: true, unit: s.isDB ? "dB" : "dB (lin)",
          accessibilityLabel: "\(node.title) spectrum")
      }
    } else {
      // Two-sided I/Q spectrum: frequency offset from the carrier.
      let freqs = (0..<db.count).map { s.startFrequency + Double($0) * s.binWidth }
      PlotWell(height: 170) {
        LinePlot(
          series: [PlotSeries(id: "p", values: db.map(Double.init), x: freqs, color: PatchColors.color(PatchModel.tint(of: value)), label: "Power")],
          yRange: floor...top, yLabel: { "\(Int($0)) dB" }, accessibilityLabel: "\(node.title) spectrum around the carrier")
      }
    }
    caption(
      s.startFrequency < 0
        ? "−\(SpectraFormat.frequency(-s.startFrequency)) … +\(SpectraFormat.frequency(-s.startFrequency)) around \(s.carrierHz.map { SpectraFormat.frequency($0) } ?? "the carrier") · \(SpectraFormat.frequency(s.binWidth)) bins"
        : "0 … \(SpectraFormat.frequency(s.endFrequency)) · \(SpectraFormat.frequency(s.binWidth)) bins")
    if node.kind == .spectrum, let buffer = model.waterfalls[node.id] {
      PlotWell(height: 110) { PatchWaterfall(buffer: buffer, label: "\(node.title) waterfall") }
    }
  }

  private func caption(_ text: String) -> some View {
    Text(text).font(.caption2.monospaced()).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
  }

  /// What the big view shows: a sink's input, or the node's main output.
  private func primary(_ model: PatchModel) -> PortValue? {
    let ev = model.snapshot
    if node.spec.category == .sinks {
      for p in node.spec.inputs { if let v = ev.value(into: PortRef(node.id, p.name)) { return v } }
      return nil
    }
    let order: [String] =
      switch node.kind {
      case .demodulator: ["symbols", "audio", "bits"]
      case .gyroscope: ["tip"]
      case .channel: ["signal"]
      case .antenna: ["signal", "gain"]
      case .marginal: ["frequency", "time"]
      case .spinFID: ["audio", "iq"]
      default: node.spec.outputs.map(\.name)
      }
    for p in order { if let v = ev.value(at: PortRef(node.id, p)) { return v } }
    return nil
  }
}

/// The Spectrum sink's waterfall. Draws the buffer's current image as an `Image` (read after
/// its observed `revision`), so every pushed row shows (a `Canvas` closure that only captures
/// the buffer can keep its first drawing; Docs/notes/live-requests.md #5).
struct PatchWaterfall: View {
  let buffer: WaterfallBuffer
  var label: String

  var body: some View {
    let _ = buffer.revision
    Group {
      if let image = buffer.image {
        Image(decorative: image, scale: 1).resizable().interpolation(.medium)
      } else {
        Color.clear
      }
    }
    .accessibilityElement()
    .accessibilityLabel(label)
    .accessibilityValue("Time runs downward, newest at the top.")
  }
}
