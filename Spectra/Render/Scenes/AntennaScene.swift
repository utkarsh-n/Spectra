import CoreGraphics
import Foundation
import Observation
import simd

/// What the Antenna scene needs to draw an antenna's geometry glyph (not physics: sizes are
/// display sizes, chosen so every style fits inside the unit lobe).
nonisolated struct AntennaGlyph: Sendable, Equatable {
  var style: RF.AntennaStyle = .dipole
  var dipoleLength = 0.5
  var monopoleHeight = 0.25
  var loopTurns = 4
  var yagiElements = 6
  var yagiSpacing = 0.2
  var helixTurns = 10
  var helixCircumference = 1.0
  var helixSpacing = 0.25
  var hornA = 3.3
  var hornB = 2.7
  var nx = 8
  var ny = 1
  var spacing = 0.5
  var patchElements = false
  /// Element excitation phases of a phased array along x and y (from RF's aperture distribution).
  var phaseX: [Float] = []
  var phaseY: [Float] = []

  init() {}

  init(_ p: RF.AntennaParameters, phaseX: [Float] = [], phaseY: [Float] = []) {
    style = p.style
    dipoleLength = p.dipoleLength
    monopoleHeight = p.monopoleHeight
    loopTurns = Int(p.loopTurns.rounded())
    yagiElements = p.yagiElements
    yagiSpacing = p.yagiSpacing
    helixTurns = Int(p.helixTurns.rounded())
    helixCircumference = p.helixCircumference
    helixSpacing = p.helixSpacing
    hornA = p.hornA
    hornB = p.hornB
    nx = p.arrayNx
    ny = p.arrayNy
    spacing = p.arraySpacing
    patchElements = p.arrayElement == .patch
    self.phaseX = phaseX
    self.phaseY = phaseY
  }
}

/// The Radio tab's hero: a lit wire-mesh radiation lobe |E(θ, φ)| from `RF.PatternMesh`
/// (band colour of the carrier, brighter where the field is stronger), the E-plane (blue) and
/// H-plane (red) cuts, the beam-peak arrow (amber, the direction of the radiated power), the
/// antenna's geometry glyph and a "your phone" frame. With Follow phone the whole antenna turns
/// with the live attitude, and a dashed amber line marks the world direction the link is
/// measured toward (the "tower"; with Beam lock the array keeps its beam on it).
///
/// Frames: the antenna's local frame (RF: wires along +z, beams toward +z) is mounted in the
/// phone with local z along the phone's long axis. Display world is +Y up. Without Follow
/// phone the phone stands upright facing you.
@Observable @MainActor
final class AntennaScene: SceneBuilder {
  static let home = OrbitCamera(yaw: 34, pitch: 16, distance: 4.3)
  /// Display rate of the phased array's rolling excitation phase (κ-slowed carrier), Hz.
  static let phaseRollHz = 0.6

  var camera = AntennaScene.home
  /// Bumped when the lobe or the look changes, so a paused canvas redraws.
  private(set) var revision = 0
  /// Turn with the phone's attitude (live sensor, so the canvas redraws continuously).
  var follow = false

  /// The phone's attitude (device → CoreMotion world, z up), read every frame while following.
  @ObservationIgnored var attitude: () -> simd_quatd? = { nil }
  /// The world direction the link is measured toward (CoreMotion frame), shown while following.
  @ObservationIgnored var target: SIMD3<Double>?
  @ObservationIgnored var beamLocked = false

  @ObservationIgnored private var rows = 0
  @ObservationIgnored private var columns = 0
  @ObservationIgnored private var positions: [SIMD3<Float>] = []
  @ObservationIgnored private var values: [Float] = []
  @ObservationIgnored private var eCut: [SIMD3<Float>] = []
  @ObservationIgnored private var hCut: [SIMD3<Float>] = []
  @ObservationIgnored private var dbRings: [(normal: SIMD3<Float>, radius: Float)] = []
  @ObservationIgnored private var peak = SIMD3<Float>(0, 0, 1)
  @ObservationIgnored private var peakRadius: Float = 1
  @ObservationIgnored private var glyph = AntennaGlyph()
  @ObservationIgnored private var band = RGB(hex: 0x9DB0CC)
  @ObservationIgnored private var scratch: [SIMD3<Float>] = []
  /// The helix glyph's points (rebuilt when the glyph changes, not every frame).
  @ObservationIgnored private var helixPoints: [SIMD3<Float>] = []

  init() {}

  var needsContinuousRedraw: Bool { follow }

  /// Loads a new lobe (from a `RadioAntennaBuild`) in the given radius scale and band colour.
  func update(_ build: RadioAntennaBuild, scale: RF.PatternScale, band: RGB, glyph: AntennaGlyph) {
    rows = build.rows
    columns = build.columns
    values = build.values
    positions = zip(build.directions, build.values).map { d, v in d * Float(scale.radius(Double(v))) }
    let model = build.model
    let p = model.peakDirection
    func cut(_ samples: [Double], axis: SIMD3<Double>) -> [SIMD3<Float>] {
      samples.indices.map { k in
        let d = RadioAntennaBuild.cutDirection(k, count: samples.count, peak: p, axis: axis)
        return SIMD3<Float>(d) * Float(scale.radius(samples[k]))
      }
    }
    eCut = cut(build.eCut, axis: model.ePlaneAxis)
    hCut = cut(build.hCut, axis: model.hPlaneAxis)
    peak = SIMD3<Float>(simd_normalize(p))
    peakRadius = Float(scale.radius(1))
    // Reference rings in the E-plane at 0, −10 and −20 dB (dB scale) or |F| 1, ½ (field/power).
    let normal = SIMD3<Float>(simd_normalize(model.hPlaneAxis))
    switch scale {
    case .decibel(let floor):
      dbRings = [0.0, -10, -20].filter { $0 > floor }.map { (normal, Float(1 + $0 / abs(floor))) }
    case .field, .power:
      dbRings = [(normal, 1), (normal, 0.5)]
    }
    self.band = band
    if glyph != self.glyph || helixPoints.isEmpty { helixPoints = Self.helixPoints(glyph) }
    self.glyph = glyph
    revision &+= 1
  }

  func build(into buffer: inout SceneBuffer, time: Double, size: CGSize) {
    buffer.use(camera)
    buffer.background = .grid(pitch: 32)
    buffer.bloom = 0.45

    let w = Self.world
    var r = w
    var att: simd_float3x3?
    if follow, let q = attitude() {
      let m = simd_float3x3(simd_quatf(ix: Float(q.imag.x), iy: Float(q.imag.y), iz: Float(q.imag.z), r: Float(q.real)))
      att = m
      r = w * m * w
    }

    drawRings(&buffer, r)
    drawLobe(&buffer, r)
    let e = GlowColor(Theme.fieldERGB, intensity: 1.5)
    let h = GlowColor(Theme.fieldBRGB, intensity: 1.3)
    polyline(&buffer, eCut, r, color: e, width: 1.7)
    polyline(&buffer, hCut, r, color: h, width: 1.5)
    // The direction of the radiated power (Poynting, amber).
    let tip = r * (peak * (peakRadius + 0.24))
    buffer.arrow(from: r * (peak * 0.12), to: tip, color: GlowColor(Theme.amberRGB, intensity: 1.6), width: 2.2, head: 0.13)
    drawPhone(&buffer, r, emphasised: follow || glyph.style == .pifa)
    drawGlyph(&buffer, r, time: time)
    if att != nil, let target {
      let t = w * SIMD3<Float>(simd_normalize(target))
      let color = GlowColor(Theme.amberRGB, intensity: beamLocked ? 1.6 : 1.0, alpha: 0.9)
      buffer.line(t * 0.15, t * 1.55, color: color, width: 1.3, glow: 0.8, dash: 7)
      buffer.point(t * 1.55, color: color, size: 9)
      buffer.ring(center: t * 1.55, normal: t, radius: 0.07, color: color.scaled(0.8), width: 1, segments: 24)
    }
  }

  // MARK: Pieces

  /// CoreMotion world (x, y horizontal, z up) → display (+Y up): (x, z, −y). The same matrix
  /// mounts the antenna's local frame in the phone (local z → device y, local y → −device z).
  static let world = simd_float3x3(columns: (SIMD3(1, 0, 0), SIMD3(0, 0, -1), SIMD3(0, 1, 0)))

  /// The antenna metal (the theme's text colour, #E8F1EC).
  static let metalRGB = RGB(hex: 0xE8F1EC)

  private func drawRings(_ buffer: inout SceneBuffer, _ r: simd_float3x3) {
    let c = GlowColor(Theme.mutedRGB, intensity: 0.55, alpha: 0.55)
    for ring in dbRings where ring.radius > 0.02 {
      buffer.ring(center: .zero, normal: r * ring.normal, radius: ring.radius, color: c, width: 0.8, segments: 72, dash: 5)
    }
  }

  private func drawLobe(_ buffer: inout SceneBuffer, _ r: simd_float3x3) {
    guard rows > 2, columns > 2, positions.count == rows * columns else { return }
    if scratch.count != positions.count { scratch = [SIMD3<Float>](repeating: .zero, count: positions.count) }
    for k in positions.indices { scratch[k] = r * positions[k] }
    // Thousands of additive segments overlap, so each one is dim; brightness follows |E|.
    func color(_ v: Float) -> GlowColor { GlowColor(band, intensity: 0.05 + 0.5 * v * v, alpha: 0.18 + 0.45 * v) }
    // Rings of constant θ (skip the poles).
    for i in stride(from: 2, to: rows - 1, by: 2) {
      for j in 0..<columns {
        let a = i * columns + j
        let b = i * columns + (j + 1) % columns
        guard values[a] > 0.004 || values[b] > 0.004 else { continue }
        buffer.line(scratch[a], scratch[b], color: color(values[a]), end: color(values[b]), width: 0.8, glow: 0.3)
      }
    }
    // Meridians, every second column.
    for j in stride(from: 0, to: columns, by: 3) {
      for i in 0..<(rows - 1) {
        let a = i * columns + j
        let b = (i + 1) * columns + j
        guard values[a] > 0.004 || values[b] > 0.004 else { continue }
        buffer.line(scratch[a], scratch[b], color: color(values[a]), end: color(values[b]), width: 0.8, glow: 0.3)
      }
    }
  }

  private func polyline(_ buffer: inout SceneBuffer, _ points: [SIMD3<Float>], _ r: simd_float3x3, color: GlowColor, width: Float) {
    guard points.count > 1 else { return }
    for k in points.indices {
      let a = points[k]
      let b = points[(k + 1) % points.count]
      guard simd_length(a) > 0.003 || simd_length(b) > 0.003 else { continue }
      buffer.line(r * a, r * b, color: color, width: width, glow: 1)
    }
  }

  /// The phone outline in the device x–y plane (local x–z), 76 × 156 display units scaled.
  private static let phoneOutline: [SIMD3<Float>] = {
    let w: Float = 0.36
    let h: Float = 0.74
    let rad: Float = 0.1
    var outline: [SIMD3<Float>] = []
    let corners: [(SIMD2<Float>, Float)] = [
      (SIMD2(w - rad, h - rad), 0), (SIMD2(-w + rad, h - rad), .pi / 2), (SIMD2(-w + rad, -h + rad), .pi),
      (SIMD2(w - rad, -h + rad), 1.5 * .pi),
    ]
    for (center, start) in corners {
      for s in 0...6 {
        let a = start + Float(s) / 6 * .pi / 2
        outline.append(SIMD3(center.x + rad * cos(a), 0, center.y + rad * sin(a)))
      }
    }
    return outline
  }()

  private func drawPhone(_ buffer: inout SceneBuffer, _ r: simd_float3x3, emphasised: Bool) {
    let c = GlowColor(Theme.mutedRGB, intensity: emphasised ? 0.95 : 0.4, alpha: emphasised ? 0.85 : 0.45)
    let outline = Self.phoneOutline
    for k in outline.indices {
      buffer.line(r * outline[k], r * outline[(k + 1) % outline.count], color: c, width: 1.1, glow: 0.4, dash: emphasised ? 0 : 4)
    }
    if emphasised {
      // The camera island and the screen normal (a short tick out of the screen).
      buffer.ring(center: r * SIMD3(-0.2, 0.0, 0.56), normal: r * SIMD3(0, -1, 0), radius: 0.07, color: c.scaled(0.8), width: 0.9, segments: 20)
      buffer.line(r * SIMD3(0, 0, -0.5), r * SIMD3(0, -0.18, -0.5), color: c.scaled(0.7), width: 0.9)
    }
  }

  private func drawGlyph(_ buffer: inout SceneBuffer, _ r: simd_float3x3, time: Double) {
    let metal = GlowColor(Self.metalRGB, intensity: 0.85, alpha: 0.9)
    let feed = GlowColor(Theme.amberRGB, intensity: 1.4)
    let g = glyph
    func line(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: GlowColor = metal, _ width: Float = 2) {
      buffer.line(r * a, r * b, color: c, width: width, glow: 0.6)
    }
    switch g.style {
    case .shortDipole:
      line(SIMD3(0, 0, -0.1), SIMD3(0, 0, 0.1), metal, 2.4)
      buffer.point(.zero, color: feed, size: 6)
    case .dipole:
      let half = Float(min(0.9, 0.36 * g.dipoleLength))
      line(SIMD3(0, 0, 0.012), SIMD3(0, 0, half), metal, 2.4)
      line(SIMD3(0, 0, -0.012), SIMD3(0, 0, -half), metal, 2.4)
      buffer.point(.zero, color: feed, size: 6)
    case .monopole:
      let height = Float(min(0.9, 0.72 * g.monopoleHeight))
      line(SIMD3(0, 0, 0.01), SIMD3(0, 0, height), metal, 2.4)
      buffer.point(.zero, color: feed, size: 6)
      let ground = GlowColor(Theme.mutedRGB, intensity: 0.7, alpha: 0.6)
      buffer.ring(center: .zero, normal: r * SIMD3(0, 0, 1), radius: 0.55, color: ground, width: 1, segments: 64)
      for k in -2...2 {
        let o = Float(k) * 0.2
        let span = (0.55 * 0.55 - o * o).squareRoot()
        line(SIMD3(o, -span, 0), SIMD3(o, span, 0), ground, 0.8)
        line(SIMD3(-span, o, 0), SIMD3(span, o, 0), ground, 0.8)
      }
    case .smallLoop:
      let turns = max(1, min(g.loopTurns, 8))
      for t in 0..<turns {
        let z = (Float(t) - Float(turns - 1) / 2) * 0.018
        buffer.ring(center: r * SIMD3(0, 0, z), normal: r * SIMD3(0, 0, 1), radius: 0.17, color: metal, width: 1.6, segments: 48)
      }
      buffer.point(r * SIMD3(0.17, 0, 0), color: feed, size: 6)
    case .patch:
      let ground = GlowColor(Theme.mutedRGB, intensity: 0.7, alpha: 0.6)
      rect(&buffer, r, center: SIMD3(0, 0, -0.03), hx: 0.34, hy: 0.34, color: ground, width: 1)
      rect(&buffer, r, center: SIMD3(0, 0, 0), hx: 0.15, hy: 0.2, color: metal, width: 1.8)
      buffer.point(r * SIMD3(-0.07, 0, 0), color: feed, size: 6)
    case .yagi:
      let n = max(3, min(g.yagiElements, 20))
      let boom = Float(n - 1)
      let step = min(0.11, 1.0 / boom)
      let z0 = -step * boom * 0.42
      line(SIMD3(0, 0, z0 - 0.04), SIMD3(0, 0, z0 + step * boom + 0.04), metal, 1.4)
      for e in 0..<n {
        let z = z0 + step * Float(e)
        let half: Float = e == 0 ? 0.27 : (e == 1 ? 0.25 : 0.23 - 0.005 * Float(e))
        line(SIMD3(-half, 0, z), SIMD3(half, 0, z), metal, e == 1 ? 2.2 : 1.6)
        if e == 1 { buffer.point(r * SIMD3(0, 0, z), color: feed, size: 6) }
      }
    case .helix:
      let turns = max(1, min(g.helixTurns, 24))
      let radius = Float(0.11 * g.helixCircumference)
      let pitch = min(0.9 / Float(turns), Float(0.09 * g.helixSpacing / 0.25))
      let z0 = -pitch * Float(turns) / 2
      let points = helixPoints
      for k in 0..<max(0, points.count - 1) { line(points[k], points[k + 1], metal, 1.6) }
      let ground = GlowColor(Theme.mutedRGB, intensity: 0.7, alpha: 0.6)
      buffer.ring(center: r * SIMD3(0, 0, z0 - 0.02), normal: r * SIMD3(0, 0, 1), radius: radius * 2.2, color: ground, width: 1, segments: 40)
      buffer.point(r * SIMD3(radius, 0, z0), color: feed, size: 6)
    case .horn:
      let bx = Float(min(0.45, 0.075 * g.hornB + 0.06))
      let ay = Float(min(0.5, 0.075 * g.hornA + 0.06))
      let mouth = SIMD3<Float>(0, 0, 0.05)
      let throat = SIMD3<Float>(0, 0, -0.42)
      rect(&buffer, r, center: mouth, hx: bx, hy: ay, color: metal, width: 1.8)
      rect(&buffer, r, center: throat, hx: 0.05, hy: 0.08, color: metal, width: 1.4)
      for (sx, sy) in [(Float(1), Float(1)), (-1, 1), (-1, -1), (1, -1)] {
        line(SIMD3(sx * 0.05, sy * 0.08, throat.z), SIMD3(sx * bx, sy * ay, mouth.z), metal, 1.4)
        line(SIMD3(sx * 0.05, sy * 0.08, throat.z), SIMD3(sx * 0.05, sy * 0.08, throat.z - 0.16), metal, 1.2)
      }
      buffer.point(r * SIMD3(0, 0, throat.z - 0.08), color: feed, size: 6)
    case .dish:
      let rim: Float = 0.5
      let depth: Float = 0.2
      buffer.ring(center: r * SIMD3(0, 0, 0), normal: r * SIMD3(0, 0, 1), radius: rim, color: metal, width: 1.8, segments: 64)
      for k in 0..<12 {
        let a = Float(k) / 12 * 2 * .pi
        var prev = SIMD3<Float>(0, 0, -depth)
        for s in 1...8 {
          let rho = rim * Float(s) / 8
          let p = SIMD3<Float>(rho * cos(a), rho * sin(a), -depth + depth * (rho / rim) * (rho / rim))
          line(prev, p, metal.scaled(0.6), 1)
          prev = p
        }
      }
      let focus = SIMD3<Float>(0, 0, -depth + rim * rim / (4 * depth))
      for k in 0..<3 {
        let a = Float(k) / 3 * 2 * .pi
        line(SIMD3(rim * cos(a), rim * sin(a), 0), focus, metal.scaled(0.5), 0.9)
      }
      buffer.point(r * focus, color: feed, size: 7)
    case .phasedArray:
      drawArray(&buffer, r, time: time, metal: metal)
    case .pifa:
      // The top plate, its short and the feed near the top of the phone; the chassis carries the current.
      let top: Float = 0.62
      line(SIMD3(-0.2, -0.05, top), SIMD3(0.18, -0.05, top), metal, 2)
      line(SIMD3(-0.2, -0.05, top), SIMD3(-0.2, 0, top - 0.05), metal, 1.6)
      line(SIMD3(-0.12, -0.05, top), SIMD3(-0.12, 0, top - 0.05), feed, 1.6)
      buffer.point(r * SIMD3(-0.12, 0, top - 0.05), color: feed, size: 6)
    }
  }

  private func drawArray(_ buffer: inout SceneBuffer, _ r: simd_float3x3, time: Double, metal: GlowColor) {
    let g = glyph
    let nx = max(1, g.nx)
    let ny = max(1, g.ny)
    let largest = Float(max(nx, ny) - 1)
    let pitch = largest > 0 ? min(0.16, 0.9 / largest) : 0.16
    let hx = pitch * Float(nx - 1) / 2 + pitch * 0.6
    let hy = pitch * Float(ny - 1) / 2 + pitch * 0.6
    rect(&buffer, r, center: SIMD3(0, 0, -0.02), hx: hx, hy: hy, color: GlowColor(Theme.mutedRGB, intensity: 0.6, alpha: 0.6), width: 1)
    // Element brightness follows its excitation phase rolling in time (the steering gradient),
    // κ-slowed to `phaseRollHz`; Reduce Motion freezes it at t = 0.
    let omega = buffer.reduceMotion ? 0 : Float((2 * Double.pi * Self.phaseRollHz * time).truncatingRemainder(dividingBy: 2 * .pi))
    let count = nx * ny
    for i in 0..<nx {
      for j in 0..<ny {
        let x = (Float(i) - Float(nx - 1) / 2) * pitch
        let y = (Float(j) - Float(ny - 1) / 2) * pitch
        let phase = (i < g.phaseX.count ? g.phaseX[i] : 0) + (j < g.phaseY.count ? g.phaseY[j] : 0)
        let level = 0.55 + 0.45 * cos(phase - omega)
        // The excitation is the carrier's own phase, so it glows in the band colour (rule R2).
        let c = GlowColor(band, intensity: 0.5 + 1.1 * level)
        if g.patchElements, count <= 256 {
          rect(&buffer, r, center: SIMD3(x, y, 0), hx: pitch * 0.3, hy: pitch * 0.3, color: c, width: 1.1)
        } else {
          buffer.point(r * SIMD3(x, y, 0), color: c, size: count > 1024 ? 2.5 : 5)
        }
      }
    }
  }

  private func rect(
    _ buffer: inout SceneBuffer, _ r: simd_float3x3, center: SIMD3<Float>, hx: Float, hy: Float, color: GlowColor, width: Float
  ) {
    // Four corners without a per-call array (patch arrays draw up to 256 of these a frame).
    let a = r * (center + SIMD3(hx, hy, 0))
    let b = r * (center + SIMD3(-hx, hy, 0))
    let c = r * (center + SIMD3(-hx, -hy, 0))
    let d = r * (center + SIMD3(hx, -hy, 0))
    buffer.line(a, b, color: color, width: width, glow: 0.6)
    buffer.line(b, c, color: color, width: width, glow: 0.6)
    buffer.line(c, d, color: color, width: width, glow: 0.6)
    buffer.line(d, a, color: color, width: width, glow: 0.6)
  }

  /// The helix glyph as a polyline (24 points per turn), in the antenna's local frame.
  private static func helixPoints(_ g: AntennaGlyph) -> [SIMD3<Float>] {
    let turns = max(1, min(g.helixTurns, 24))
    let radius = Float(0.11 * g.helixCircumference)
    let pitch = min(0.9 / Float(turns), Float(0.09 * g.helixSpacing / 0.25))
    let z0 = -pitch * Float(turns) / 2
    let per = 24
    return (0...(turns * per)).map { s in
      let a = Float(s) / Float(per) * 2 * .pi
      return SIMD3(radius * cos(a), radius * sin(a), z0 + pitch * Float(s) / Float(per))
    }
  }
}
