import CoreGraphics
import Foundation
import Observation
import simd

/// The Spin tab's holo scene (SPEC-features §4): Gyre's heavy top as a wireframe rotor in its
/// cage, driven by the phone's real motion, and protons or electrons as a magnetization arrow
/// on a Bloch sphere, each with its field vector, precession cone and trail. Compare shows
/// all three side by side: one equation, dL/dt = μ × B.
///
/// The physics world is z-up (Core Motion's reference frame); the renderer is y-up, so world
/// (x, y, z) draws at (x, z, −y). The rotor is mechanical and drawn in ANALOGY colours
/// (phosphor, amber); spins radiate at their Larmor frequency and take its band colour.
@Observable @MainActor
final class SpinScene: SceneBuilder {
  /// The framing Align and double-tap return to, per view.
  static func home(for view: SpinView) -> OrbitCamera {
    switch view {
    // The horizon ring and its north tick (radius 1.24) fit the well's width; the pivot sits
    // a little below centre so the rotor and the phone under it share the height.
    case .gyroscope: OrbitCamera(yaw: 32, pitch: 26, distance: 4.4, target: SIMD3(0, -0.1, 0))
    // Pitched enough that the equator and the sense-of-precession arc above B₀ read as rings.
    case .proton, .electron: OrbitCamera(yaw: 28, pitch: 22, distance: 4.9, target: SIMD3(0, 0.32, 0))
    case .compare: OrbitCamera(yaw: 0, pitch: 10, distance: 7.6, target: SIMD3(0, 0, 0))
    }
  }

  var camera = SpinScene.home(for: .gyroscope)
  @ObservationIgnored weak var model: SpinModel?
  /// Wall time of the last frame drawn (SignalClock), so the model's background loop knows
  /// the render loop is stepping.
  @ObservationIgnored private(set) var lastBuild = -Double.infinity
  /// Display frame rate assumed for motion blur (the canvas runs at up to 60 fps here).
  @ObservationIgnored private var frameRate = 60.0
  @ObservationIgnored private var phoneCorners = [SIMD3<Float>](repeating: .zero, count: 4)

  init() {}

  var home: OrbitCamera { Self.home(for: model?.saved.view ?? .gyroscope) }

  func resetCamera(for view: SpinView) { camera = Self.home(for: view) }

  /// Live sensors move the field and the rotor even while the transport is paused.
  var needsContinuousRedraw: Bool { model?.liveDriven ?? false }

  func build(into buffer: inout SceneBuffer, time: Double, size: CGSize) {
    guard let model else { return }
    let now = SignalClock.now()
    if lastBuild.isFinite, now - lastBuild > 0.004 {
      frameRate = min(120, max(20, 0.9 * frameRate + 0.1 / max(now - lastBuild, 1e-3)))
    }
    lastBuild = now
    model.advance(to: time)
    buffer.use(camera)
    buffer.background = .grid(pitch: 32)
    buffer.bloom = 0.62
    switch model.saved.view {
    case .gyroscope:
      drawGyro(&buffer, model, origin: .zero, scale: 1, details: true)
    case .proton:
      drawBloch(&buffer, model, model.proton, center: SIMD3(0, 0.05, 0), radius: 1, details: true)
    case .electron:
      drawBloch(&buffer, model, model.electron, center: SIMD3(0, 0.05, 0), radius: 1, details: true)
    case .compare:
      // A triangle: the rotor above, the two spins below (portrait well).
      drawGyro(&buffer, model, origin: SIMD3(0, 1.0, 0), scale: 0.95, details: false)
      drawBloch(&buffer, model, model.proton, center: SIMD3(-1.2, -1.15, 0), radius: 0.78, details: false)
      drawBloch(&buffer, model, model.electron, center: SIMD3(1.2, -1.15, 0), radius: 0.78, details: false)
    }
  }

  // MARK: Colours

  private static let rotor = GlowColor(Theme.phosphorRGB, intensity: 1.15)
  private static let rotorCore = GlowColor(Theme.amberRGB, intensity: 1.3)
  private static let cage = GlowColor(Theme.mutedRGB, intensity: 0.75)
  private static let axle = GlowColor(RGB(0.86, 0.96, 0.9), intensity: 1)
  private static let momentum = GlowColor(Theme.amberRGB, intensity: 1.6)
  private static let torque = GlowColor(Theme.roseRGB, intensity: 1.4)
  private static let gravity = GlowColor(Theme.mutedRGB, intensity: 1.1)
  private static let field = GlowColor(Theme.fieldBRGB, intensity: 1.5)
  private static let effective = GlowColor(Theme.violetRGB, intensity: 1.5)
  private static let horizon = GlowColor(Theme.mutedRGB, intensity: 0.6, alpha: 0.45)
  private static let phone = GlowColor(Theme.mutedRGB, intensity: 0.7, alpha: 0.55)

  // MARK: Gyroscope

  /// World (z up) → render (y up).
  private static func w(_ p: SIMD3<Double>) -> SIMD3<Float> { SIMD3(Float(p.x), Float(p.z), Float(-p.y)) }

  private func drawGyro(_ b: inout SceneBuffer, _ model: SpinModel, origin: SIMD3<Float>, scale: Float, details: Bool) {
    let engine = model.gyro
    let top = engine.top
    let params = model.saved.gyro
    let R: Float = 0.42 * scale
    let ell = Float(top.offset / HeavyTop.rotorRadius) * R
    let e = simd_normalize(Self.w(top.axis))
    let u = simd_normalize(Self.w(top.cageX))
    let v = simd_cross(e, u)
    let pivot = origin
    let center = pivot + e * ell
    let axleHalf = R * 1.25
    let thick = R * 0.12
    let psi = Float(top.spinAngle)
    // Angle the rotor sweeps per displayed frame (spin rate × D / frame rate): the honest blur.
    let sweep = Float(top.spinRate * max(params.sanitized.timeScale, 0.02) / frameRate)

    // The phone the pivot is fixed to: its outline, below the pivot along the screen normal.
    if let r = model.live.attitude {
      let normal = simd_normalize(Self.w(r * SIMD3(0, 0, 1)))
      let ax = Self.w(r * SIMD3(1, 0, 0))
      let ay = Self.w(r * SIMD3(0, 1, 0))
      let c = pivot - normal * 0.8 * scale
      let hx: Float = 0.24 * scale
      let hy: Float = 0.5 * scale
      // The outline's four corners go into a reused buffer (no array allocated per frame).
      phoneCorners[0] = c + ax * hx + ay * hy
      phoneCorners[1] = c - ax * hx + ay * hy
      phoneCorners[2] = c - ax * hx - ay * hy
      phoneCorners[3] = c + ax * hx - ay * hy
      b.polyline(phoneCorners, color: Self.phone, width: 1.1, glow: 0.4, closed: true)
      b.line(c + ay * (hy * 0.86) - ax * hx * 0.25, c + ay * (hy * 0.86) + ax * hx * 0.25, color: Self.phone, width: 1.6)
      b.line(pivot, c, color: Self.phone.alpha(0.35), width: 1, glow: 0.3, dash: 4)
    } else {
      b.ring(center: pivot - SIMD3(0, 0.95 * scale, 0), normal: SIMD3(0, 1, 0), radius: 0.36 * scale, color: Self.phone, width: 1, segments: 48)
      b.line(pivot, pivot - SIMD3(0, 0.95 * scale, 0), color: Self.phone.alpha(0.35), width: 1, dash: 4)
    }

    // World horizon at the pivot, fixed in space, with a tick toward magnetic north.
    let up = SIMD3<Float>(0, 1, 0)
    b.ring(center: pivot, normal: up, radius: 1.15 * scale, color: Self.horizon, width: 0.9, segments: 96, dash: 5)
    for k in 0..<12 {
      let a = Float(k) * .pi / 6
      let d = SIMD3<Float>(cos(a), 0, sin(a))
      b.line(pivot + d * 1.1 * scale, pivot + d * 1.17 * scale, color: Self.horizon, width: 0.9)
    }
    let field = model.rotorFieldApplied
    let fieldLength = simd_length(field)
    let horizontal = SIMD2(field.x, field.y)
    if simd_length(horizontal) > 1e-7 {
      let d = simd_normalize(Self.w(SIMD3(horizontal.x, horizontal.y, 0)))
      b.line(pivot + d * 1.05 * scale, pivot + d * 1.24 * scale, color: Self.field, width: 2)
      b.point(pivot + d * 1.24 * scale, color: Self.field, size: 4)
    }

    // Axle through the pivot, whichever side the rotor sits on.
    let lo = min(-ell, -axleHalf)
    let hi = max(-ell, axleHalf)
    b.line(center + e * lo, center + e * hi, color: Self.axle.alpha(0.85), width: 1.8)
    b.point(center + e * axleHalf, color: Self.axle, size: 5)
    b.point(pivot, color: Self.rotorCore, size: 6)

    // Rotor: rims, hub, spokes that blur as the spin outruns the display.
    arc(&b, center + e * thick, u, v, radius: R, from: 0, to: 2 * .pi, color: Self.rotor, width: 1.8)
    arc(&b, center - e * thick, u, v, radius: R, from: 0, to: 2 * .pi, color: Self.rotor, width: 1.8)
    arc(&b, center, u, v, radius: R * 0.62, from: 0, to: 2 * .pi, color: Self.rotor.alpha(0.45), width: 1)
    arc(&b, center, u, v, radius: R * 0.16, from: 0, to: 2 * .pi, color: Self.rotorCore, width: 1.4, segments: 24)
    let spokeAlpha = 1 - smoothstep(0.35, 1.4, abs(sweep))
    if spokeAlpha > 0.01, !b.reduceMotion || abs(sweep) < 0.35 {
      for k in 0..<6 {
        let a = psi + Float(k) * .pi / 3
        let d = cos(a) * u + sin(a) * v
        b.line(center + d * R * 0.16, center + d * R, color: Self.rotorCore.alpha(spokeAlpha), end: Self.rotor.alpha(spokeAlpha), width: 1.6)
      }
    }
    let blur = 1 - spokeAlpha
    if blur > 0.01 {
      for r in stride(from: Float(0.25), through: 0.9, by: 0.13) {
        arc(&b, center, u, v, radius: R * r, from: 0, to: 2 * .pi, color: Self.rotor.alpha(0.08 * blur), width: 1, segments: 48)
      }
    }
    let span = min(abs(sweep), 2 * .pi)
    if b.reduceMotion, abs(sweep) >= 0.35 {
      // Reduce Motion: a fast rotor's markers would jump around the rim every frame; draw the
      // smear they make as one still ring instead.
      arc(&b, center, u, v, radius: R * 0.9, from: 0, to: 2 * .pi, color: Self.rotorCore.alpha(0.12), width: 2.6, segments: 48)
    } else {
      let markerAlpha = SpinMath.clamp(0.45 / max(span, 0.01), 0.08, 0.9)
      for k in 0..<3 {
        let a = psi + Float(k) * 2 * .pi / 3
        let from = sweep < 0 ? a : a - max(span, 0.04)
        let to = sweep < 0 ? a + max(span, 0.04) : a
        arc(&b, center, u, v, radius: R * 0.9, from: from, to: to, color: Self.rotorCore.alpha(markerAlpha), width: 2.6, segments: 18)
      }
    }
    // Cage: two meridians and an equator; turns with the axis, does not spin.
    let cageR = R * 1.12
    arc(&b, center, u, e, radius: cageR, from: 0, to: 2 * .pi, color: Self.cage.alpha(0.8), width: 1.3)
    arc(&b, center, v, e, radius: cageR, from: 0, to: 2 * .pi, color: Self.cage.alpha(0.8), width: 1.3)
    arc(&b, center, u, v, radius: cageR, from: 0, to: 2 * .pi, color: Self.cage.alpha(0.5), width: 1.1)

    let reach = ell + (ell >= -0.001 ? axleHalf : -axleHalf)

    // Precession cone about whatever twists the axle hardest: gravity (vertical) or B.
    let gravityTorque = HeavyTop.mass * HeavyTop.g0 * abs(params.gravity) * abs(top.offset)
    let magnetTorque = abs(params.magnet) * HeavyTop.maxDipole * fieldLength
    let coneAxisWorld: SIMD3<Double> =
      magnetTorque > gravityTorque && fieldLength > 0 ? field / fieldLength : SIMD3(0, 0, params.gravity >= 0 ? 1 : -1)
    let coneAxis = simd_normalize(Self.w(coneAxisWorld))
    let cosT = SpinMath.clamp(simd_dot(e, coneAxis), -1, 1)
    let sinT = (1 - cosT * cosT).squareRoot()
    if sinT > 0.03 {
      b.ring(
        center: pivot + coneAxis * reach * cosT, normal: coneAxis, radius: abs(reach) * sinT,
        color: Self.rotor.alpha(0.3), width: 1, segments: 72, dash: 5)
      b.line(pivot, pivot + coneAxis * reach * cosT, color: Self.rotor.alpha(0.18), width: 0.9, dash: 4)
    }

    // Trail of the axle tip: precession with the inertial nod riding on it.
    if model.saved.showTrail, engine.trail.count > 2 {
      let n = Float(engine.trail.count)
      var previous: SIMD3<Float>?
      engine.trail.forEach { i, dir in
        let q = pivot + SIMD3(dir.x, dir.z, -dir.y) * reach
        // Skip points closer than ~1 % of the rotor: additive segments piled on one spot
        // would bloom into a blob.
        guard let a = previous else {
          previous = q
          return
        }
        guard simd_distance(a, q) > 0.012 * scale || i == Int(n) - 1 else { return }
        let k = Float(i) / n
        let c = GlowColor(simd_mix(Theme.phosphorRGB.linear, Theme.amberRGB.linear, SIMD3(repeating: k)), intensity: 1)
        b.line(a, q, color: c.alpha(pow(k, 1.6) * 0.85), width: 1.4, glow: 0.7)
        previous = q
      }
    }

    // Vectors: L, the torque at its tip, gravity on the centre of mass, the field B.
    if model.saved.showVectors {
      let l = top.momentum
      let lMag = simd_length(l)
      if lMag > 1e-9 {
        let tip = pivot + simd_normalize(Self.w(l)) * (0.3 + 0.45 * Float(tanh(lMag / 0.012))) * scale
        b.arrow(from: pivot, to: tip, color: Self.momentum, width: 2.3, head: 0.12 * scale)
        let tau = top.externalTorque
        let tauMag = simd_length(tau)
        if tauMag > 1e-6 {
          b.arrow(
            from: tip, to: tip + simd_normalize(Self.w(tau)) * 0.3 * Float(tanh(tauMag / 0.006)) * scale,
            color: Self.torque, width: 1.9, head: 0.09 * scale)
        }
      }
      let g = top.effectiveGravity
      let gMag = simd_length(g) / HeavyTop.g0
      if gMag > 0.02, abs(ell) > 0.02 {
        b.arrow(
          from: center, to: center + simd_normalize(Self.w(g)) * Float(min(0.24 * gMag, 0.55)) * scale,
          color: Self.gravity, width: 1.7, head: 0.08 * scale)
      }
      if fieldLength > 0 {
        let length = (0.3 + 0.35 * Float(tanh(fieldLength / 120e-6))) * scale
        let strength: Float = params.magnet == 0 ? 0.45 : 1
        b.arrow(
          from: pivot, to: pivot + simd_normalize(Self.w(field)) * length, color: Self.field.alpha(strength),
          width: 1.8, head: 0.1 * scale)
      }
    }
  }

  // MARK: Bloch sphere

  private func drawBloch(
    _ b: inout SceneBuffer, _ model: SpinModel, _ runner: SpinBenchRunner, center c: SIMD3<Float>, radius rho: Float,
    details: Bool
  ) {
    let species = runner.species
    let bench = model.bench(species)
    let band = GlowColor(BandPalette.rgb(forWavelength: species.larmorWavelength(field: model.fieldInUse)), intensity: 1.7)
    // The frame: z′ along B₀ (your field's direction when aligned), x′ and y′ across it.
    var z = SIMD3<Float>(0, 1, 0)
    if details, model.saved.alignToField, let f = model.live.fieldWorld, simd_length(f) > 0 {
      z = simd_normalize(Self.w(f))
    }
    var x = abs(z.y) < 0.95 ? simd_cross(SIMD3<Float>(0, 1, 0), z) : SIMD3<Float>(1, 0, 0)
    x = simd_normalize(x)
    let y = simd_cross(z, x)
    func map(_ m: SIMD3<Double>) -> SIMD3<Float> { c + rho * (Float(m.x) * x + Float(m.y) * y + Float(m.z) * z) }
    let lab = !model.saved.rotatingFrame
    func shown(_ m: SIMD3<Double>) -> SIMD3<Double> { lab ? runner.lab(m) : m }
    // How far the lab frame turns per displayed frame: past π the arrow strobes.
    let displayRate = 2 * Double.pi * runner.carrierHz * runner.timeUnit * bench.slowMotion
    let aliased = lab && displayRate / frameRate > .pi

    // Sphere: equator, two meridians, two latitudes.
    let wire = GlowColor(Theme.mutedRGB, intensity: 0.6, alpha: 0.3)
    b.ring(center: c, normal: z, radius: rho, color: wire, width: 1.1, segments: 96)
    b.ring(center: c, normal: x, radius: rho, color: wire.alpha(0.28), width: 0.9, segments: 96)
    b.ring(center: c, normal: y, radius: rho, color: wire.alpha(0.28), width: 0.9, segments: 96)
    b.ring(center: c + z * rho * 0.5, normal: z, radius: rho * 0.866, color: wire.alpha(0.16), width: 0.8, segments: 72, dash: 4)
    b.ring(center: c - z * rho * 0.5, normal: z, radius: rho * 0.866, color: wire.alpha(0.16), width: 0.8, segments: 72, dash: 4)
    b.line(c - z * rho, c + z * rho, color: wire.alpha(0.35), width: 0.9, dash: 4)
    // Frame axes x′ (ice) and y′ (muted, so it never reads as B_eff's violet); in the lab
    // frame they are the lab's own x and y.
    b.line(c + x * rho * 0.92, c + x * rho * 1.12, color: GlowColor(Theme.iceRGB, intensity: 1.2), width: 1.6)
    b.line(c + y * rho * 0.92, c + y * rho * 1.12, color: GlowColor(Theme.mutedRGB, intensity: 1.1), width: 1.6)
    // B₀ along z′.
    b.arrow(from: c + z * rho * 1.06, to: c + z * rho * 1.6, color: Self.field, width: 2.2, head: 0.13 * rho)

    // The sense of free precession about B, seen from B's tip: clockwise for protons.
    let sense = Float(species.precessionSense.sign)
    let senseCentre = c + z * rho * 1.32
    let a0: Float = 0.6
    let a1 = a0 + sense * 2.0
    arc(&b, senseCentre, x, y, radius: rho * 0.3, from: min(a0, a1), to: max(a0, a1), color: band.alpha(0.75), width: 1.4, segments: 28)
    let endPoint = senseCentre + rho * 0.3 * (cos(a1) * x + sin(a1) * y)
    let tangent = simd_normalize(sense * (-sin(a1) * x + cos(a1) * y))
    let side = simd_cross(z, tangent)
    b.line(endPoint, endPoint - tangent * 0.08 * rho + side * 0.05 * rho, color: band.alpha(0.75), width: 1.4)
    b.line(endPoint, endPoint - tangent * 0.08 * rho - side * 0.05 * rho, color: band.alpha(0.75), width: 1.4)

    // RF: B₁ in the transverse plane and B_eff (rotating frame; in the lab B₁ turns with the carrier).
    let sample = runner.sample
    if sample.isRFOn {
      let phi = bench.phase
      if aliased {
        b.ring(center: c, normal: z, radius: rho * 0.7, color: Self.field.alpha(0.35), width: 1.4, segments: 72)
      } else {
        let dir = shown(SIMD3(cos(phi), sin(phi), 0))
        b.arrow(from: c, to: map(dir * 0.72), color: Self.field.alpha(0.75), width: 1.8, head: 0.09 * rho)
      }
      if !lab {
        let beff = sample.effectiveField(isochromat: sample.count / 2)
        let n = simd_length(beff)
        if n > 0 { b.arrow(from: c, to: map(beff / n * 0.95), color: Self.effective, width: 1.9, head: 0.1 * rho) }
      }
    }

    // Isochromats: the sample's spin packets fanning out in the gradient. Bunched together
    // (|mean M| near |M|) they would pile up additively, so they fade as they bunch.
    let packets = sample.magnetizations
    let step = max(1, packets.count / (details ? 64 : 32))
    let mean = sample.meanMagnetization
    let typical = packets.isEmpty ? 1 : simd_length(packets[0])
    let spread = typical > 1e-6 ? max(0, 1 - simd_length(mean) / typical) : 0
    let packetAlpha = Float(0.6 * min(1, 0.08 + 4 * spread))
    var i = 0
    while i < packets.count {
      let p = map(shown(packets[i]))
      b.point(p, color: band.scaled(0.4).alpha(packetAlpha), size: details ? 3 : 2.4)
      i += step
    }

    // The mean magnetization M, its precession cone and its recent path.
    let m = sample.meanMagnetization
    let mPerp = simd_length(SIMD2(m.x, m.y))
    if mPerp > 0.02 {
      b.ring(
        center: c + z * rho * Float(m.z), normal: z, radius: rho * Float(mPerp), color: band.alpha(aliased ? 0.85 : 0.32),
        width: aliased ? 2.4 : 1.1, segments: 72, dash: aliased ? 0 : 5)
    }
    if model.saved.showTrail, !lab, runner.trail.count > 2 {
      let n = Float(runner.trail.count)
      var previous: SIMD3<Float>?
      runner.trail.forEach { i, t in
        let q = map(SIMD3(Double(t.x), Double(t.y), Double(t.z)))
        guard let a = previous else {
          previous = q
          return
        }
        guard simd_distance(a, q) > 0.01 * rho || i == Int(n) - 1 else { return }
        let k = Float(i) / n
        b.line(a, q, color: band.alpha(pow(k, 1.5) * 0.75), width: 1.4)
        previous = q
      }
    }
    let tip = map(shown(m))
    b.arrow(from: c, to: tip, color: aliased ? band.alpha(0.4) : band.scaled(1.3), width: 3.2, head: 0.16 * rho)
    b.point(tip, color: band.scaled(1.3), size: 7)
  }

  // MARK: Helpers

  /// An arc of `radius` about `center` in the plane spanned by unit vectors `u`, `v`.
  private func arc(
    _ b: inout SceneBuffer, _ center: SIMD3<Float>, _ u: SIMD3<Float>, _ v: SIMD3<Float>, radius: Float, from: Float,
    to: Float, color: GlowColor, width: Float, segments: Int = 72
  ) {
    let n = max(2, segments)
    var previous = center + radius * (cos(from) * u + sin(from) * v)
    for k in 1...n {
      let a = from + (to - from) * Float(k) / Float(n)
      let p = center + radius * (cos(a) * u + sin(a) * v)
      b.line(previous, p, color: color, width: width)
      previous = p
    }
  }

  private func smoothstep(_ e0: Float, _ e1: Float, _ x: Float) -> Float {
    let t = SpinMath.clamp((x - e0) / (e1 - e0), 0, 1)
    return t * t * (3 - 2 * t)
  }
}
