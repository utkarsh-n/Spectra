import SwiftUI

/// The loop made visible: a thin log ruler under every top bar (0.1 pm … 100,000 km, log₁₀ λ
/// −13…8) with a marker for every active frequency in the app (`AppModel.markers`). Tap a
/// marker to jump to its tab; long-press for "Tune Spectrum here". VoiceOver gets one named
/// action per marker.
struct SpectrumStrip: View {
  var height: CGFloat = 34
  @Environment(AppModel.self) private var app
  @State private var width: CGFloat = 1

  private let range = SpectrumMarker.logRange

  var body: some View {
    let markers = app.markers
    let focused = app.focusedMarker?.id
    Canvas { ctx, size in
      let rect = CGRect(origin: .zero, size: size)
      let bar = CGRect(x: 8, y: rect.midY - 1, width: rect.width - 16, height: 6)
      LogRuler.drawBands(ctx, in: bar, range: range, opacity: 0.8)
      LogRuler.drawBandNames(ctx, above: bar, range: range, minimumWidth: 20)
      // Decade ticks under the bar.
      var ticks = Path()
      for d in Int(range.lowerBound)...Int(range.upperBound) {
        let x = LogRuler.x(Double(d), in: bar, range: range)
        ticks.move(to: CGPoint(x: x, y: bar.maxY + 2))
        ticks.addLine(to: CGPoint(x: x, y: bar.maxY + (d % 3 == 0 ? 6 : 4)))
      }
      ctx.stroke(ticks, with: .color(Theme.axis), lineWidth: 0.6)
      for m in markers {
        LogRuler.drawMarker(
          ctx, m, in: CGRect(x: bar.minX, y: bar.minY - 6, width: bar.width, height: bar.height + 12), range: range,
          emphasis: m.id == focused ? 1 : 0.55)
      }
    }
    .frame(height: height)
    .background(Theme.plotWell.opacity(0.85), in: .rect(cornerRadius: 10))
    .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.phosphor.opacity(0.14), lineWidth: 0.75) }
    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    .contentShape(.rect)
    .gesture(
      SpatialTapGesture().onEnded { value in
        if let marker = nearest(to: value.location.x, in: markers) { app.focus(marker) }
      }
    )
    .contextMenu {
      if markers.isEmpty {
        Text("No active frequencies")
      }
      ForEach(markers) { m in
        Menu("\(m.label) · \(SpectraFormat.frequency(m.frequency))") {
          Button("Show in \(m.tab.title)", systemImage: m.tab.symbol) { app.focus(m) }
          Button("Tune Spectrum here", systemImage: "waveform") { app.sendToSpectrum(lambda: m.lambda, label: m.label) }
        }
      }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Spectrum strip")
    .accessibilityValue(markers.isEmpty ? "No active frequencies" : markers.map(\.label).joined(separator: ", "))
    .accessibilityHint("Shows every active frequency in Spectra on one wavelength ruler.")
    .accessibilityActions {
      ForEach(markers) { m in
        Button("Show \(m.label)") { app.focus(m) }
        Button("Tune Spectrum to \(m.label)") { app.sendToSpectrum(lambda: m.lambda, label: m.label) }
      }
    }
    .accessibilityIdentifier("spectrum-strip")
  }

  /// The marker closest to `x` within 22 pt.
  private func nearest(to x: CGFloat, in markers: [SpectrumMarker]) -> SpectrumMarker? {
    let bar = CGRect(x: 8, y: 0, width: width - 16, height: 1)
    return markers
      .map { ($0, abs(LogRuler.x($0.logLambda, in: bar, range: range) - x)) }
      .filter { $0.1 <= 22 }
      .min { $0.1 < $1.1 }?.0
  }
}
