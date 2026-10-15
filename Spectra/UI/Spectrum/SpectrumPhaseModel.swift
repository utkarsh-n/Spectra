import CoreGraphics
import Foundation
import Observation
import simd

/// Runs the phase-space computation off the main actor (debounced), then extracts the Φ cube
/// points for the Metal volume. Everything it publishes is computed by `Phase`.
@Observable @MainActor
final class SpectrumPhaseModel {
  private(set) var scene: Phase.PhaseSpaceScene?
  private(set) var built: PhaseSpaceRequestBuilder.Built?
  private(set) var computing = false
  /// Wall time of the last computation, s.
  private(set) var computeSeconds: Double?
  /// The k column the cube shows (nil: k-integrated).
  private(set) var cubeColumn: Int?
  /// Bumped when the cube points change (the paused canvas redraws on it).
  private(set) var cubeRevision = 0

  @ObservationIgnored private var pending: PhaseSpaceRequestBuilder.Built?
  @ObservationIgnored private var latest = PhaseSpaceSettings()
  @ObservationIgnored private weak var target: WignerScene?
  @ObservationIgnored private var task: Task<Void, Never>?
  /// The detached Φ computation in flight (or the last one), awaited before the next starts.
  @ObservationIgnored private var compute: Task<Phase.PhaseSpaceScene, Never>?
  @ObservationIgnored private var cubeTask: Task<Void, Never>?
  @ObservationIgnored private var cubeKey: Int?

  init() {}

  /// Asks for the scene of `b`. Identical requests are ignored; a changed request replaces
  /// the one in flight after a short debounce. `settings` (cube mode, k column) and `scene`
  /// receive the cube points.
  func request(_ b: PhaseSpaceRequestBuilder.Built, cube settings: PhaseSpaceSettings, scene: WignerScene) {
    latest = settings
    target = scene
    if b == pending {
      if !computing { updateCube() }
      return
    }
    pending = b
    task?.cancel()
    guard !b.request.packets.isEmpty else {
      built = b
      self.scene = nil
      computing = false
      scene.points = []
      cubeRevision &+= 1
      return
    }
    computing = true
    let previous = compute
    task = Task { [weak self] in
      try? await Task.sleep(for: .milliseconds(140))
      guard !Task.isCancelled else { return }
      // A detached computation cannot be cancelled, so let the one in flight finish before
      // starting the next: dragging a slider never stacks several Φ computations at once.
      if let previous { _ = await previous.value }
      guard !Task.isCancelled, let self else { return }
      let request = b.request
      let started = Date()
      let job = Task.detached(priority: .userInitiated) { Phase.phaseSpaceScene(request) }
      self.compute = job
      let result = await job.value
      guard !Task.isCancelled else { return }
      self.scene = result
      self.built = b
      self.computeSeconds = Date().timeIntervalSince(started)
      self.computing = false
      self.cubeKey = nil
      self.updateCube()
    }
  }

  /// Re-extracts the cube points when the cube mode or k column changed.
  private func updateCube() {
    guard let scene, let target else { return }
    let w = scene.wigner
    let column: Int? =
      latest.kSlice && w.full != nil ? min(w.nk - 1, max(0, Int((latest.kFraction * Double(w.nk - 1)).rounded()))) : nil
    var hasher = Hasher()
    hasher.combine(scene.wigner.elapsed)
    hasher.combine(scene.wigner.total)
    hasher.combine(column)
    let key = hasher.finalize()
    guard key != cubeKey else { return }
    cubeKey = key
    cubeColumn = column
    cubeTask?.cancel()
    cubeTask = Task { [weak self] in
      let points = await Task.detached(priority: .userInitiated) { () -> [SIMD4<Float>] in
        if let column, let slice = w.kSliceCube(column: column) {
          // One k column, on the scale of the whole Φ.
          return WignerCubePoints.extract(slice, peak: max(abs(w.minValue), abs(w.maxValue)))
        }
        return WignerCubePoints.extract(w.kIntegrated)
      }.value
      guard !Task.isCancelled, let self else { return }
      target.points = points
      self.cubeRevision &+= 1
    }
  }

  /// Where the k column starts (0…1 along the k axis): the first packet's carrier k̂₀ for one
  /// packet; for two or more, k̂₀ + π/d (d = packet spacing in λ), where the in-phase cross
  /// term between neighbouring packets is most negative. Nil before the first scene.
  func startKFraction(spacing: Double) -> Double? {
    guard let scene, let c = scene.carriers.first ?? nil else { return nil }
    let w = scene.wigner
    guard w.nk > 1 else { return nil }
    let packets = scene.carriers.compactMap { $0 }.count
    let k = packets > 1 && spacing > 0 ? c.x + Double.pi / spacing : c.x
    return Double(w.kAxis.nearestIndex(k)) / Double(w.nk - 1)
  }

  // MARK: Slices and images (main actor; 2-D grids are small)

  /// The fixed-t row index and fixed-x row index for the current fractions.
  func sliceIndices(_ s: PhaseSpaceSettings) -> (t: Int, x: Int)? {
    guard let w = scene?.wigner else { return nil }
    let nt = w.tAxis.count, nx = w.xAxis.count
    guard nt > 0, nx > 0 else { return nil }
    return (
      min(nt - 1, max(0, Int((s.tFraction * Double(nt - 1)).rounded()))),
      min(nx - 1, max(0, Int((s.xFraction * Double(nx - 1)).rounded())))
    )
  }

  @ObservationIgnored private var imageCache: [String: CGImage] = [:]
  @ObservationIgnored private var imageScene: Double = -1

  /// Heat-map images, cached per scene and slice.
  func image(_ kind: PhaseImageKind, settings s: PhaseSpaceSettings) -> CGImage? {
    guard let scene else { return nil }
    let stamp = scene.wigner.elapsed + scene.wigner.total
    if stamp != imageScene {
      imageCache = [:]
      imageScene = stamp
    }
    let idx = sliceIndices(s)
    let key: String
    switch kind {
    case .spacetime: key = "st"
    case .momentum: key = "kv"
    case .spatialSlice: key = "sx\(idx?.t ?? 0)"
    case .temporalSlice: key = "tn\(idx?.x ?? 0)"
    }
    if let cached = imageCache[key] { return cached }
    let made: CGImage?
    switch kind {
    case .spacetime:
      // Rows x (drawn upward), columns t.
      let g = scene.intensity
      let peak = Float(max(g.maxValue, 1e-300))
      let nx = g.rowAxis.count, nt = g.columnAxis.count
      made = SpectrumHeatMap.image(rows: nx, columns: nt, map: .phosphor) { r, c in
        Float(g.value(row: nx - 1 - r, column: c)) / peak
      }
    case .momentum:
      // |ψ̃(k, ν)|²: k across, ν up (rows of the grid are k, columns ν).
      let g = scene.spectrum.power
      let peak = Float(max(g.maxValue, 1e-300))
      let nk = g.rowAxis.count, nn = g.columnAxis.count
      made = SpectrumHeatMap.image(rows: nn, columns: nk, map: .phosphor) { r, c in
        Float(g.value(row: c, column: nn - 1 - r)) / peak
      }
    case .spatialSlice:
      // W(x, k) at fixed t: x across, k up (the plane's rows are x, its columns k).
      guard let i = idx else { return nil }
      let p = scene.wigner.spatialWigner(atT: i.t)
      made = Self.planeImage(p, transpose: true)
    case .temporalSlice:
      // W(t, ν) at fixed x: t across, ν up.
      guard let i = idx else { return nil }
      let p = scene.wigner.temporalWigner(atX: i.x)
      made = Self.planeImage(p, transpose: true)
    }
    if let made { imageCache[key] = made }
    return made
  }

  /// A signed plane (rows × columns) as a diverging image; `transpose` puts the plane's rows
  /// across and its columns upward.
  private static func planeImage(_ p: Phase.Plane, transpose: Bool) -> CGImage? {
    let peak = Float(max(p.absMax, 1e-300))
    let rows = p.rows, cols = p.columns
    guard rows > 0, cols > 0 else { return nil }
    if transpose {
      return SpectrumHeatMap.image(rows: cols, columns: rows, map: .diverging) { r, c in
        Float(p.value(row: c, column: cols - 1 - r)) / peak
      }
    }
    return SpectrumHeatMap.image(rows: rows, columns: cols, map: .diverging) { r, c in
      Float(p.value(row: rows - 1 - r, column: c)) / peak
    }
  }
}

enum PhaseImageKind {
  case spacetime, momentum, spatialSlice, temporalSlice
}
