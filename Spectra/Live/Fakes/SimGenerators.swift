import Foundation

// Simulated sensors (`gyre-integration.md` §8). Every fake writes into the same rings as the
// real source, with its own timestamps at the real rate, so downstream code (spectra,
// aliasing, the Scope) behaves exactly as on the device. They are selected only in DEBUG
// builds (`LiveContext.simulates`); the code itself is plain and deterministic (`-seed N`).

/// A deterministic random source for the fakes (`-seed N`): SplitMix64.
nonisolated struct SimRandom: Sendable {
  private var state: UInt64

  init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }

  mutating func next() -> UInt64 {
    state &+= 0x9E37_79B9_7F4A_7C15
    var z = state
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return z ^ (z >> 31)
  }

  /// Uniform in [0, 1).
  mutating func uniform() -> Double { Double(next() >> 11) / Double(1 << 53) }

  /// Uniform in [−1, 1).
  mutating func signed() -> Double { uniform() * 2 - 1 }

  /// Standard normal (Box–Muller).
  mutating func gaussian() -> Double {
    let u = max(uniform(), 1e-300)
    return (-2 * log(u)).squareRoot() * cos(2 * .pi * uniform())
  }
}

/// A simulated source writing timestamped samples into its streams. `produce(until:)` is
/// called every ~20 ms on a background task and emits every sample due up to `now`, each at
/// its own timestamp.
nonisolated protocol SimGenerator: Sendable {
  mutating func produce(until now: Double)
}

/// The simulated attitude shared by the fakes: Gyre's gentle sway (or a fixed `-simPose`),
/// or, while the turntable experiment runs, the phone lying flat and turning once per 24 s.
/// Angles are (pitch, yaw, roll) in radians; `t` is `SignalClock` time.
nonisolated struct SimPose: Sendable {
  var fixed: SIMD3<Double>?
  var world: SimWorld?

  init(fixed: SIMD3<Double>? = nil, world: SimWorld? = nil) {
    self.fixed = fixed
    self.world = world
  }

  func angles(at t: Double) -> SIMD3<Double> {
    if let since = world?.turntableSince {
      let yaw = 2 * Double.pi * (t - since) / SimWorld.turntablePeriod
      return SIMD3(0, atan2(sin(yaw), cos(yaw)), 0)
    }
    if let fixed { return fixed * (.pi / 180) }
    // Held tilted about 30° and swaying gently (Gyre: yaw 0.9 sin 0.31t).
    return SIMD3(0.52 + 0.08 * sin(0.41 * t), 0.9 * sin(0.31 * t), 0.12 * sin(0.53 * t + 1))
  }

  /// Rotates a world vector (x east, y north, z up) into the phone frame.
  func toPhone(_ v: SIMD3<Double>, at t: Double) -> SIMD3<Double> {
    let a = angles(at: t)
    let (p, y, r) = (a.x, a.y, a.z)
    // World → phone: undo yaw (about z), then pitch (about x), then roll (about y).
    let v1 = SIMD3(cos(y) * v.x + sin(y) * v.y, -sin(y) * v.x + cos(y) * v.y, v.z)
    let v2 = SIMD3(v1.x, cos(p) * v1.y + sin(p) * v1.z, -sin(p) * v1.y + cos(p) * v1.z)
    return SIMD3(cos(r) * v2.x - sin(r) * v2.z, v2.y, sin(r) * v2.x + cos(r) * v2.z)
  }

  /// The phone's long (y) axis in the world's horizontal plane, as a bearing (radians from
  /// north, clockwise): what the Bluetooth fake's chassis dipole points along.
  func axisBearing(at t: Double) -> Double { -angles(at: t).y }
}

/// Emits samples on a uniform (optionally jittered) grid.
nonisolated struct SampleGrid: Sendable {
  let interval: Double
  /// Fractional jitter of each interval (0.02 = ±2 %).
  var jitter = 0.0
  private(set) var next: Double
  private var jitterRNG: SimRandom

  init(rate: Double, jitter: Double = 0, start: Double, seed: UInt64 = 1) {
    interval = 1 / rate
    self.jitter = jitter
    next = start
    jitterRNG = SimRandom(seed: seed ^ 0x51ED)
  }

  /// Calls `body(t)` for each sample time ≤ `now` (at most `cap` per call: after a stall the
  /// grid skips ahead instead of catching up).
  mutating func emit(until now: Double, cap: Int = 4096, _ body: (Double) -> Void) {
    if now - next > Double(cap) * interval { next = now - Double(cap) * interval }
    while next <= now {
      body(next)
      next += interval * (1 + jitter * jitterRNG.signed())
    }
  }
}

// MARK: - Motion

/// Raw accelerometer (gravity + user acceleration), user acceleration, gravity, gyroscope
/// and attitude at 100 Hz from the simulated pose.
nonisolated struct MotionGenerator: SimGenerator {
  let accel: [SignalStream]
  let userAccel: [SignalStream]
  let gravity: [SignalStream]
  let gyro: [SignalStream]
  let attitude: [SignalStream]
  let pose: SimPose
  var grid: SampleGrid
  var rng: SimRandom

  mutating func produce(until now: Double) {
    let (accel, userAccel, gravity, gyro, attitude, pose) = (accel, userAccel, gravity, gyro, attitude, pose)
    var rng = rng
    grid.emit(until: now) { t in
      // Gravity points down: (0, 0, −1) g in the world, seen in the phone frame.
      let g = pose.toPhone(SIMD3(0, 0, -1), at: t)
      let a0 = pose.angles(at: t)
      let a1 = pose.angles(at: t + 0.01)
      var w = (a1 - a0) / 0.01
      w.y = atan2(sin(a1.y - a0.y), cos(a1.y - a0.y)) / 0.01
      // A hand's physiological tremor (~9 Hz, a few mg) plus sensor noise.
      let tremor = 0.004 * sin(2 * .pi * 9.2 * t)
      let user = SIMD3(tremor + 0.002 * rng.gaussian(), 0.6 * tremor + 0.002 * rng.gaussian(), 0.002 * rng.gaussian())
      for i in 0..<3 {
        accel[i].append(Float(g[i] + user[i] + 0.003 * rng.gaussian()), at: t)
        userAccel[i].append(Float(user[i]), at: t)
        gravity[i].append(Float(g[i]), at: t)
        gyro[i].append(Float(w[i] + 0.002 * rng.gaussian()), at: t)
        attitude[i].append(Float(a0[i] * 180 / .pi), at: t)
      }
    }
    self.rng = rng
  }
}

// MARK: - Magnetometer

/// Magnetometer in µT: Gyre's Earth field (0, 22, −40) µT seen through the simulated pose,
/// plus mains hum, an approaching magnet or a MagSafe step. The calibrated streams carry the
/// field; the raw streams add the phone's own hard-iron bias and more noise. With hum the
/// rate is 99.8 Hz ± 2 % (60 Hz then aliases to 39.8 Hz and 120 Hz to 20.2 Hz).
nonisolated struct MagnetometerGenerator: SimGenerator {
  /// Calibrated x, y, z, |B|.
  let calibrated: [SignalStream]
  /// Raw x, y, z, |B|.
  let raw: [SignalStream]
  let mode: LaunchOptions.MagnetometerFake
  let pose: SimPose
  let t0: Double
  var grid: SampleGrid
  var rng: SimRandom

  /// The simulated phone's hard-iron bias (µT), visible only in the raw streams.
  static let bias = SIMD3(14.0, -27.0, 33.0)

  /// The field (µT, phone frame) at time `t`, before noise.
  static func field(mode: LaunchOptions.MagnetometerFake, pose: SimPose, t: Double, t0: Double) -> SIMD3<Double> {
    let s = t - t0
    var b = pose.toPhone(SIMD3(0, 22, -40), at: t)
    switch mode {
    case .hum60:
      // A mains field along the phone's x axis: 1.6 µT at 60 Hz + 0.4 µT at 120 Hz.
      b.x += 1.6 * sin(2 * .pi * 60 * t) + 0.4 * sin(2 * .pi * 120 * t + 0.7)
    case .hum50:
      b.x += 1.6 * sin(2 * .pi * 50 * t) + 0.4 * sin(2 * .pi * 100 * t + 0.7)
    case .magnet:
      // A 0.244 A·m² disc approaching on axis from 30 to 5 cm over 10 s, then repeating:
      // B = (µ₀/2π)·m/r³ → 1.8 µT … 390 µT.
      let phase = s.truncatingRemainder(dividingBy: 14)
      let r = phase < 10 ? 0.30 - 0.025 * phase : 0.05
      b.z += 2e-7 * 0.2437 / (r * r * r) * 1e6
    case .magsafe:
      // The MagSafe ring snaps on for 10 s of every 20 (absolute clock, shared with the
      // charging fake so the INFERRED path sees both).
      b.z += SimClockPhase.magsafeAttached(at: t) ? 85 : 0
    case .earth:
      break
    }
    return b
  }

  mutating func produce(until now: Double) {
    let (calibrated, raw, mode, pose, t0) = (calibrated, raw, mode, pose, t0)
    var rng = rng
    grid.emit(until: now) { t in
      var b = Self.field(mode: mode, pose: pose, t: t, t0: t0)
      b += SIMD3(rng.gaussian(), rng.gaussian(), rng.gaussian()) * 0.3
      let r = b + Self.bias + SIMD3(rng.gaussian(), rng.gaussian(), rng.gaussian()) * 0.4
      for i in 0..<3 {
        calibrated[i].append(Float(b[i]), at: t)
        raw[i].append(Float(r[i]), at: t)
      }
      calibrated[3].append(Float((b * b).sum().squareRoot()), at: t)
      raw[3].append(Float((r * r).sum().squareRoot()), at: t)
    }
    self.rng = rng
  }
}

/// Shared absolute-clock phases so separate fakes agree (MagSafe step ↔ charging).
nonisolated enum SimClockPhase {
  static func magsafeAttached(at t: Double) -> Bool { t.truncatingRemainder(dividingBy: 20) >= 10 }
}

// MARK: - Barometer

/// Pressure (Pa) and relative altitude (m) at 1 Hz: still air, stairs (−36 Pa per 3 m floor
/// every 20 s; the scale height is 8.32 m/hPa), or weather (±15 hPa over 10 minutes).
nonisolated struct BarometerGenerator: SimGenerator {
  let pressure: SignalStream
  let altitude: SignalStream
  let mode: LaunchOptions.BarometerFake
  let t0: Double
  var grid: SampleGrid
  var rng: SimRandom

  mutating func produce(until now: Double) {
    let (pressure, altitude, mode, t0) = (pressure, altitude, mode, t0)
    var rng = rng
    grid.emit(until: now) { t in
      let s = t - t0
      var p = 101_325.0
      var h = 0.0
      switch mode {
      case .still:
        break
      case .stairs:
        // Up five floors and back down, one floor every 20 s.
        let step = Int(s / 20) % 10
        let floor = Double(step <= 5 ? step : 10 - step)
        h = 3 * floor
        p -= 36 * floor
      case .weather:
        p += 1500 * sin(2 * .pi * s / 600)
      }
      p += 1.5 * rng.gaussian()
      pressure.append(Float(p), at: t)
      altitude.append(Float(h + 0.1 * rng.gaussian()), at: t)
    }
    self.rng = rng
  }
}

// MARK: - Microphone

/// The microphone at 48 kHz (full-scale units) plus its level in dBFS per 1024-sample block.
/// `room`: Gyre's G3–D4–G4 open fifth (196/294/392 Hz) swelling at 0.18 Hz with a clap
/// every 1.6 s. `voice`: a glottal pulse train at 110–180 Hz through 700/1200 Hz formants.
/// `tone`: a calibration sine.
nonisolated struct MicrophoneGenerator: SimGenerator {
  let left: SignalStream
  let level: SignalStream
  let mode: LaunchOptions.MicrophoneFake
  let t0: Double
  var grid: SampleGrid
  var rng: SimRandom
  var phase = 0.0
  var block: [Float] = []
  var noise: UInt32 = 22_222

  mutating func produce(until now: Double) {
    var rng = rng
    var phase = phase
    var block = block
    var noise = noise
    let (left, level, mode, t0) = (left, level, mode, t0)
    var values: [Float] = []
    var start = -1.0
    grid.emit(until: now, cap: 9600) { t in
      if start < 0 { start = t }
      let s = t - t0
      var x = 0.0
      switch mode {
      case .room:
        let swell = 0.5 + 0.5 * sin(2 * .pi * 0.18 * s)
        x = 0.22 * swell * (sin(2 * .pi * 196 * s) + 0.6 * sin(2 * .pi * 294 * s + 0.4) + 0.25 * sin(2 * .pi * 392 * s))
        let beat = s.truncatingRemainder(dividingBy: 1.6)
        if beat < 0.05 {
          noise ^= noise << 13
          noise ^= noise >> 17
          noise ^= noise << 5
          x += (Double(noise) / Double(UInt32.max) * 2 - 1) * 0.7 * exp(-beat * 70)
        }
      case .voice:
        let f0 = 145 + 35 * sin(2 * .pi * 0.7 * s)
        phase += 2 * .pi * f0 / 48_000
        if phase > 2 * .pi { phase -= 2 * .pi }
        var sum = 0.0
        var k = 1
        while Double(k) * f0 < 4000 {
          let f = Double(k) * f0
          let gain =
            1 / (1 + pow((f - 700) / 110, 2)) + 0.6 / (1 + pow((f - 1200) / 140, 2)) + 0.04
          sum += gain / Double(k).squareRoot() * sin(Double(k) * phase)
          k += 1
        }
        let syllable = max(0, sin(2 * .pi * 2.6 * s))
        x = 0.16 * sum * syllable
      case .tone(let hz):
        x = 0.5 * sin(2 * .pi * hz * s)
      }
      x += 0.002 * rng.gaussian()
      values.append(Float(x))
    }
    if !values.isEmpty {
      left.ring.append(contentsOf: values, start: start, interval: grid.interval)
      // Level per 1024-sample block, stamped at the block's last sample.
      for (i, v) in values.enumerated() {
        block.append(v)
        if block.count == 1024 {
          let rms = (block.reduce(0) { $0 + Double($1) * Double($1) } / 1024).squareRoot()
          level.append(Float(20 * log10(max(rms, 1e-6))), at: start + Double(i) * grid.interval)
          block.removeAll(keepingCapacity: true)
        }
      }
    }
    self.rng = rng
    self.phase = phase
    self.block = block
    self.noise = noise
  }
}

// MARK: - Bluetooth

/// One simulated BLE advertiser in the virtual room.
nonisolated struct SimBeacon: Sendable {
  let id: UUID
  let name: String
  /// Mean distance, m.
  let distance: Double
  /// Advertising interval, s.
  let interval: Double
  /// Bearing from the phone, radians clockwise from north.
  let bearing: Double
  /// Advertised Tx power (dBm), if the device advertises it.
  let txPower: Double?
  let apple: Bool
  var next: Double
  /// Correlated complex fading gain (Rayleigh envelope).
  var fadeRe = 0.7
  var fadeIm = 0.7
}

/// BLE RSSI per advert, event-driven (`gyre-integration.md` §8): RSSI = Tx − 40.20 dB (free
/// space at 1 m, 2.44 GHz) − 10·n·log₁₀d with n = 3, plus the phone chassis as a λ/2 dipole
/// along its long axis (so the turntable experiment has a pattern to find, floored at
/// −15 dB), plus Rayleigh fading, quantized to 1 dB; about 2 % of adverts are missed.
nonisolated struct BluetoothGenerator: SimGenerator {
  let table: BLEDeviceTable
  var beacons: [SimBeacon]
  let pose: SimPose
  var rng: SimRandom

  /// The virtual room for `count` radios (Gyre's mix of advertising intervals).
  static func room(count: Int, start: Double, seed: UInt64) -> [SimBeacon] {
    let names = ["Headphones", "Watch", "Laptop", "Speaker", "Keyboard", "TV", "Beacon", "Tag", "Car", "Ring"]
    let distances = [0.6, 1.4, 2.2, 3.5, 5.0, 7.5, 11, 15]
    let intervals = [0.1, 0.2, 0.152, 0.3, 0.25, 0.5, 1.0, 0.18]
    var rng = SimRandom(seed: seed ^ 0xB1E)
    return (0..<max(0, count)).map { i in
      let uuid = UUID(
        uuidString: String(format: "%08X-0000-4000-8000-%012X", UInt32(truncatingIfNeeded: (i + 1) &* 2_654_435_761), i))!
      let name = "\(names[i % names.count])\(i >= names.count ? " \(i / names.count + 1)" : "")"
      return SimBeacon(
        id: uuid, name: name, distance: distances[i % distances.count] * (1 + 0.1 * Double(i / distances.count)),
        interval: intervals[i % intervals.count], bearing: 2 * .pi * rng.uniform(),
        txPower: i % 3 == 2 ? nil : 0, apple: i % 3 != 1, next: start + 0.05 * Double(i))
    }
  }

  mutating func produce(until now: Double) {
    for i in beacons.indices {
      var b = beacons[i]
      if now - b.next > 5 { b.next = now - 5 }
      while b.next <= now {
        let t = b.next
        // AR(1) complex Gaussian: ρ = 0.85 per advert.
        let rho = 0.85
        let k = (1 - rho * rho).squareRoot() / 2.0.squareRoot()
        b.fadeRe = rho * b.fadeRe + k * rng.gaussian()
        b.fadeIm = rho * b.fadeIm + k * rng.gaussian()
        let fadeDB = 10 * log10(max(b.fadeRe * b.fadeRe + b.fadeIm * b.fadeIm, 1e-4))
        let d = b.distance * (1 + 0.15 * sin(0.05 * t + Double(i)))
        // Angle between the chassis dipole and the line to the radio.
        let theta = pose.axisBearing(at: t) - b.bearing
        let pattern = max(TurntableModel.halfWaveDipolePatternDB(theta: theta), -15)
        let tx = b.txPower ?? 0
        let rssi = (tx - 40.20 - 30 * log10(d) + pattern + fadeDB).rounded()
        if rng.uniform() > 0.02 {
          table.heard(
            id: b.id, rssi: max(rssi, -100), time: t, name: b.name, txPower: b.txPower, connectable: b.apple,
            apple: b.apple)
        }
        b.next += b.interval * (0.9 + 0.2 * rng.uniform())
      }
      beacons[i] = b
    }
  }
}

// MARK: - Slow sources

/// A generic slow source: `value(s, walk, rng)` sampled at a fixed rate into one stream.
nonisolated struct SlowGenerator: SimGenerator {
  let stream: SignalStream
  let t0: Double
  var grid: SampleGrid
  var rng: SimRandom
  /// Random-walk state for sources that wander.
  var walk: Double
  let value: @Sendable (_ s: Double, _ walk: inout Double, _ rng: inout SimRandom) -> Double

  mutating func produce(until now: Double) {
    var rng = rng
    var walk = walk
    let (stream, t0, value) = (stream, t0, value)
    grid.emit(until: now, cap: 600) { t in
      stream.append(Float(value(t - t0, &walk, &rng)), at: t)
    }
    self.rng = rng
    self.walk = walk
  }
}

/// Several generators run as one.
nonisolated struct GeneratorGroup: SimGenerator {
  var members: [any SimGenerator]

  mutating func produce(until now: Double) {
    for i in members.indices { members[i].produce(until: now) }
  }
}
