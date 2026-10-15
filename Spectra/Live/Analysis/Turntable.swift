import Foundation

/// The Bluetooth turntable experiment (`gyre-integration.md` §4.2): lay the phone flat, turn
/// it slowly through at least three turns, and bin one radio's RSSI by yaw (36 bins of 10°,
/// at least 8 adverts each). Per-bin mean ± σ against the MODEL λ/2-dipole pattern. A single
/// RSSI stream cannot separate the pattern from multipath, so the result is reported as
/// statistics: if the per-bin σ is about the Rayleigh 5.57 dB, the pattern is buried in fading.
nonisolated struct YawBinner: Sendable, Equatable {
  static let binCount = 36
  static let binWidth = 360.0 / Double(binCount)
  static let minimumPerBin = 8
  static let minimumTurns = 3.0
  /// Newest samples kept per bin.
  static let capacityPerBin = 120

  /// RSSI (dBm) per 10° yaw bin, newest last.
  private(set) var bins: [[Double]] = Array(repeating: [], count: YawBinner.binCount)
  /// Accumulated rotation (degrees, signed), from unwrapped yaw.
  private(set) var rotation = 0.0
  private var lastYaw: Double?

  init() {}

  /// Bin index for a yaw in degrees (any range).
  static func bin(forYaw yaw: Double) -> Int {
    let wrapped = (yaw.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
    return min(binCount - 1, Int(wrapped / binWidth))
  }

  /// Centre yaw (degrees) of bin `i`.
  static func centre(of i: Int) -> Double { (Double(i) + 0.5) * binWidth }

  /// Adds one advert heard while the phone pointed at `yaw` degrees.
  mutating func add(yaw: Double, rssi: Double) {
    guard yaw.isFinite, rssi.isFinite else { return }
    if let last = lastYaw {
      var d = yaw - last
      d = (d + 540).truncatingRemainder(dividingBy: 360) - 180
      rotation += d
    }
    lastYaw = yaw
    let i = Self.bin(forYaw: yaw)
    bins[i].append(rssi)
    if bins[i].count > Self.capacityPerBin { bins[i].removeFirst(bins[i].count - Self.capacityPerBin) }
  }

  mutating func reset() { self = YawBinner() }

  /// Full turns so far.
  var turns: Double { abs(rotation) / 360 }

  /// Bins with enough adverts.
  var filledBins: Int { bins.filter { $0.count >= Self.minimumPerBin }.count }

  /// Adverts binned so far (all bins).
  var sampleCount: Int { bins.reduce(0) { $0 + $1.count } }

  /// Every bin has ≥ 8 adverts and the phone turned at least three times.
  var isComplete: Bool { filledBins == Self.binCount && turns >= Self.minimumTurns }

  /// Mean and σ (dB) per bin; nil where a bin has fewer than two adverts.
  var statistics: [(mean: Double, deviation: Double, count: Int)?] {
    bins.map { b in
      guard b.count >= 2 else { return nil }
      let s = TurntableStatistics.meanAndDeviation(b)
      return (s.mean, s.deviation, b.count)
    }
  }

  /// Mean per-bin σ over the filled bins (dB).
  var meanDeviation: Double? {
    let filled = statistics.compactMap { $0 }.filter { $0.count >= Self.minimumPerBin }
    guard !filled.isEmpty else { return nil }
    return filled.map(\.deviation).reduce(0, +) / Double(filled.count)
  }

  /// Front-to-back ratio: the strongest filled bin minus the bin opposite it (dB), with the
  /// standard error of that difference.
  var frontToBack: (decibels: Double, sigma: Double, frontYaw: Double)? {
    let stats = statistics
    var best: Int?
    for i in 0..<Self.binCount {
      guard let s = stats[i], s.count >= Self.minimumPerBin else { continue }
      if best == nil || s.mean > (stats[best!]?.mean ?? -.infinity) { best = i }
    }
    guard let front = best, let f = stats[front] else { return nil }
    let back = (front + Self.binCount / 2) % Self.binCount
    guard let b = stats[back], b.count >= Self.minimumPerBin else { return nil }
    let sigma = (f.deviation * f.deviation / Double(f.count) + b.deviation * b.deviation / Double(b.count)).squareRoot()
    return (f.mean - b.mean, sigma, Self.centre(of: front))
  }

  /// True when the per-bin spread is as large as pure Rayleigh fading (within 1 dB of
  /// 5.57 dB or more): the measured shape then says little about the antenna.
  var isFadingDominated: Bool {
    guard let d = meanDeviation else { return false }
    return d >= TurntableStatistics.rayleighDecibelSpread - 1
  }

  /// The MODEL curve for comparison: a λ/2 dipole along the phone's long axis, lying flat,
  /// seen from a radio in the horizontal plane (floored at −15 dB, the chassis is not a clean
  /// dipole). The direction to the radio is unknown, so the model's broadside is aligned with
  /// `peakYaw` (the strongest measured bin). Returns relative dB per bin (0 at the peak).
  static func modelPattern(peakYaw: Double) -> [Double] {
    (0..<binCount).map { i in
      // Broadside (θ = 90° from the dipole axis) faces the radio at peakYaw.
      let theta = (centre(of: i) - peakYaw + 90) * .pi / 180
      return max(TurntableModel.halfWaveDipolePatternDB(theta: theta), -15)
    }
  }
}
