import CoreGraphics
import Foundation
import simd

/// 01 Wave scope as a Metal holo scene: the port of spectra-lab `instruments/scope.js` on top of
/// `FieldView` (Core). The beam runs along world +X; spectra-lab's Ex is world −Z and Ey world +Y
/// (a proper rotation, so E × B still points along the beam).
///
/// Drawn per frame: the medium block on the far half (z > 0) when a medium is set, E (blue)
/// and B (red) traces with ribbon sheets when the field is planar and stems, faint per-source
/// traces when several sources superpose, the beam axis in the wave's display colour, and the
/// Poynting arrow S. Distances are in reference wavelengths, time is κ-slowed screen time,
/// amplitudes are normalized for drawing (`SpectrumDisplay.scopeAmplitude`).
@MainActor
final class WaveScene: SceneBuilder {
  var state = SpectraState()
  var camera = OrbitCamera.waveScopeHome

  private var display: FieldView.DisplaySources?
  private var ePoints: [SIMD3<Float>] = []
  private var bPoints: [SIMD3<Float>] = []
  private var axisPoints: [SIMD3<Float>] = []
  private var scratch: [SIMD3<Float>] = []

  init() {}

  /// The cached display sources for the current sources and medium (`FieldView`).
  var displaySources: FieldView.DisplaySources {
    if let d = display, d.isCurrent(sources: state.sources, medium: state.medium) { return d }
    let d = FieldView.displaySources(state)
    display = d
    return d
  }

  /// spectra-lab (x, y, z) → world.
  @inline(__always) private func world(_ x: Double, _ y: Double, _ z: Double) -> SIMD3<Float> {
    SIMD3(Float(z), Float(y), Float(-x))
  }

  func build(into buffer: inout SceneBuffer, time: Double, size: CGSize) {
    buffer.use(camera)
    buffer.background = .grid(pitch: 32)
    buffer.bloom = 0.6
    let ds = displaySources
    let sc = state.scope
    let speed = state.speed
    let z0 = SpectrumDisplay.scopeZRange.lowerBound
    let z1 = SpectrumDisplay.scopeZRange.upperBound
    let amp = SpectrumDisplay.scopeAmplitude
    let n = SpectrumDisplay.scopeSamples

    // Medium block on the far half.
    if ds.inMedium { drawMedium(&buffer, z1: z1) }

    // Sample the field once.
    ePoints.removeAll(keepingCapacity: true)
    bPoints.removeAll(keepingCapacity: true)
    axisPoints.removeAll(keepingCapacity: true)
    for i in 0...n {
      let z = z0 + (z1 - z0) * Double(i) / Double(n)
      let f = FieldView.fieldAt(ds, z: z, t: time, speed: speed)
      ePoints.append(world(f.ex * amp, f.ey * amp, z))
      // B = n ẑ × E in display units.
      bPoints.append(world(-f.ey * amp * f.n, f.ex * amp * f.n, z))
      axisPoints.append(world(0, 0, z))
    }
    let planar =
      ds.list.allSatisfy { $0.source.delta.truncatingRemainder(dividingBy: 180) == 0 }
      && ds.list.allSatisfy { $0.source.theta == ds.list.first?.source.theta }

    let eColor = GlowColor(Theme.fieldERGB, intensity: 1.55)
    let bColor = GlowColor(Theme.fieldBRGB, intensity: 1.35)
    let refRGB = BandPalette.rgb(forWavelength: ds.ref.lambda)

    // Ribbons (dense faint stems read as a sheet) and the brighter stems every 6 samples.
    if sc.showE { sheet(&buffer, ePoints, color: eColor, ribbon: planar) }
    if sc.showB { sheet(&buffer, bPoints, color: bColor.scaled(0.9), ribbon: planar) }

    // Beam axis in the wave's own colour.
    buffer.line(world(0, 0, z0 - 0.2), world(0, 0, z1), color: GlowColor(refRGB, intensity: 1.0), width: 1.6, glow: 0.6)

    // Individual sources when superposed.
    if ds.list.count > 1, sc.showE {
      for d in ds.list {
        scratch.removeAll(keepingCapacity: true)
        for i in stride(from: 0, through: n, by: 2) {
          let z = z0 + (z1 - z0) * Double(i) / Double(n)
          let f = FieldView.fieldAt(ds, z: z, t: time, speed: speed, only: d.index)
          scratch.append(world(f.ex * amp, f.ey * amp, z))
        }
        buffer.polyline(
          scratch, color: GlowColor(BandPalette.rgb(forWavelength: d.source.lambda), intensity: 0.75, alpha: 0.5),
          width: 1.1, glow: 0)
      }
    }
    if sc.showB { buffer.polyline(bPoints, color: bColor, width: 2.2, glow: 0.7) }
    if sc.showE { buffer.polyline(ePoints, color: eColor, width: 2.5, glow: 0.8) }
    if sc.showE, let last = ePoints.last { buffer.point(last, color: eColor, size: 6) }
    if sc.showB, let last = bPoints.last { buffer.point(last, color: bColor, size: 5) }

    // Energy flow S = E × B / μ₀ along the beam.
    if sc.showS {
      buffer.arrow(
        from: world(0, 0, z1 + 0.05), to: world(0, 0, z1 + 0.55), color: GlowColor(Theme.amberRGB, intensity: 1.6),
        width: 2.4, head: 0.16)
    }
    // Axis ticks at the near end: E (up) and B (sideways) directions, faint.
    if sc.showE {
      buffer.line(
        world(0, amp + 0.04, z0), world(0, amp + 0.2, z0), color: eColor.scaled(0.6), width: 1.2, glow: 0.3)
    }
    if sc.showB {
      buffer.line(
        world(-(amp + 0.04), 0, z0), world(-(amp + 0.2), 0, z0), color: bColor.scaled(0.6), width: 1.2, glow: 0.3)
    }
  }

  /// Ribbon sheet (every sample, faint) plus stems every 6 samples, from the beam axis.
  private func sheet(_ buffer: inout SceneBuffer, _ points: [SIMD3<Float>], color: GlowColor, ribbon: Bool) {
    if ribbon {
      for i in points.indices {
        buffer.line(axisPoints[i], points[i], color: color.scaled(0.11), width: 1.4, glow: 0)
      }
    }
    for i in stride(from: 0, to: points.count, by: 6) {
      buffer.line(axisPoints[i], points[i], color: color.scaled(0.42), width: 1.0, glow: 0.3)
    }
  }

  /// Half-size of the medium frame and its corners (static, so a frame allocates nothing).
  private static let mediumHalf = 0.9
  private static let mediumCorners: [(Double, Double)] = [(-0.9, -0.9), (0.9, -0.9), (0.9, 0.9), (-0.9, 0.9)]

  /// The medium: an amber frame at the interface z = 0, its edges running to the far end, and
  /// a faint hatch on the interface.
  private func drawMedium(_ buffer: inout SceneBuffer, z1: Double) {
    let frame = GlowColor(Theme.amberRGB, intensity: 0.55, alpha: 0.7)
    let edge = GlowColor(Theme.amberRGB, intensity: 0.25, alpha: 0.5)
    let h = Self.mediumHalf
    for k in 0..<4 {
      let (x0, y0) = Self.mediumCorners[k]
      let (x1, y1) = Self.mediumCorners[(k + 1) % 4]
      buffer.line(world(x0, y0, 0), world(x1, y1, 0), color: frame, width: 1.1, glow: 0.4)
      buffer.line(world(x0, y0, z1), world(x1, y1, z1), color: edge, width: 0.8, glow: 0.2)
      buffer.line(world(x0, y0, 0), world(x0, y0, z1), color: edge, width: 0.8, glow: 0.2)
    }
    for j in 1..<6 {
      let y = -h + 2 * h * Double(j) / 6
      buffer.line(world(-h, y, 0), world(h, y, 0), color: frame.scaled(0.18), width: 0.8, glow: 0)
    }
  }
}
