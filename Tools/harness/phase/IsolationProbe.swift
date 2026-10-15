// Compiled only by Tools/check-phase.sh in the app's isolation mode (Swift 6, default MainActor):
// proves the phase-space engine is callable from nonisolated code and from detached tasks, and
// that its results are Sendable across isolation boundaries. Never part of the app target.
import Foundation
import simd

nonisolated func phaseProbeNonisolated() -> Double {
  let z = Phase.Signal.analytic(real: (0..<64).map { cos(0.3 * Double($0)) }, step: 1)
  var total = Phase.wigner(z).total + Phase.spectrogram(z, window: .hann(length: 16), bins: 32).total
  total += Phase.timeFrequency(real: [Float](repeating: 0.5, count: 128), sampleRate: 1000).plane.total
  total += Phase.timeFrequency(complex: Phase.Signal.fromIQ(i: [1, 0, -1, 0], q: [0, 1, 0, -1], sampleRate: 4)).plane.total
  let ap = Phase.Aperture.uniformArray(elements: 4, spacing: 0.5)
  let w = ap.wigner()
  total += Double(ap.farField(from: w).count) + Phase.fresnelShear(w, distance: 2, wavenumber: ap.wavenumber).total
  let field = Phase.Field(x: Phase.Axis(start: 0, step: 1, count: 8), t: Phase.Axis(start: 0, step: 1, count: 8)) { x, t in
    SIMD2(cos(0.5 * x - t), sin(0.5 * x - t))
  }
  let st = Phase.spacetimeWigner(field)
  total += st.total + Phase.marginalReport(st, field: field).m1Error
  total += Phase.Dispersion.medium(.glass).wavenumber(frequency: 5e14) ?? 0
  total += Phase.DisplayUnits(referenceWavelength: 550e-9).period
  return total
}

/// Results cross from a detached task back to the main actor: they must be Sendable.
@MainActor func phaseProbeMainActor() async -> Double {
  let scene = await Task.detached {
    Phase.phaseSpaceScene(
      Phase.PhaseSpaceRequest(
        packets: [Phase.GaussianPacket(carrierFrequency: 1, width: 1.5)], dispersion: .vacuum, referenceFrequency: 5e14,
        gridSize: 16))
  }.value
  let plane = await Task.detached { Phase.wignerVille(real: [1, 0, -1, 0, 1, 0, -1, 0], step: 1) }.value
  let dft = Phase.DFT(count: 16)
  let shared = await Task.detached { dft.transform(.negative, re: [Double](repeating: 1, count: 16), im: [Double](repeating: 0, count: 16)) }.value
  return scene.report.energy + plane.total + shared.re[0] + phaseProbeNonisolated()
}
