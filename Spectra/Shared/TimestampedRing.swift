import Foundation
import Synchronization

/// The clock every sample timestamp uses: seconds of system uptime, the same base as
/// `CMLogItem.timestamp`, `CACurrentMediaTime()` and `AVAudioTime.seconds(forHostTime:)`.
nonisolated enum SignalClock {
  static func now() -> Double { ProcessInfo.processInfo.systemUptime }
}

/// Values with their own timestamps, oldest first. `values[i]` was taken at `times[i]`.
nonisolated struct TimedSamples<T: Sendable>: Sendable {
  var values: [T]
  var times: [Double]

  init(values: [T] = [], times: [Double] = []) {
    self.values = values
    self.times = times
  }

  var count: Int { values.count }
  var isEmpty: Bool { values.isEmpty }

  /// Seconds between the first and last sample (0 for fewer than two).
  var duration: Double {
    guard let first = times.first, let last = times.last else { return 0 }
    return last - first
  }

  /// Mean sample rate from the timestamps, nil for fewer than two samples or zero span.
  var measuredRate: Double? {
    guard count >= 2, duration > 0 else { return nil }
    return Double(count - 1) / duration
  }
}

/// A fixed-capacity ring of timestamped samples, safe to write from a sensor callback or the
/// audio thread and read from the main actor (a `Mutex` guards it).
///
/// Producers push samples with the sensor's own timestamps (never the render frame time);
/// consumers read incrementally with `snapshot(since:)` so FFTs see the true sample rate.
/// Timestamps must be non-decreasing per ring.
nonisolated final class TimestampedRing<T: Sendable>: Sendable {
  /// Maximum number of samples kept; the oldest is overwritten first.
  let capacity: Int

  private struct Storage {
    var values: [T] = []
    var times: [Double] = []
    /// Index of the oldest sample once the ring is full (0 before that).
    var head = 0
    var appended: UInt64 = 0
  }

  private let storage: Mutex<Storage>

  init(capacity: Int) {
    self.capacity = max(1, capacity)
    var s = Storage()
    s.values.reserveCapacity(min(self.capacity, 1 << 20))
    s.times.reserveCapacity(min(self.capacity, 1 << 20))
    storage = Mutex(s)
  }

  // MARK: Writing

  /// Appends one sample taken at `time` (seconds, `SignalClock`).
  func append(_ value: T, time: Double) {
    storage.withLock { s in Self.push(value, time, into: &s, capacity: capacity) }
  }

  /// Appends a batch; `values` and `times` must have equal counts.
  func append(contentsOf values: [T], times: [Double]) {
    let n = min(values.count, times.count)
    guard n > 0 else { return }
    storage.withLock { s in
      for i in 0..<n { Self.push(values[i], times[i], into: &s, capacity: capacity) }
    }
  }

  /// Appends a uniformly sampled block: sample i was taken at `start + i·interval`.
  func append(contentsOf values: [T], start: Double, interval: Double) {
    guard !values.isEmpty else { return }
    storage.withLock { s in
      for (i, v) in values.enumerated() {
        Self.push(v, start + Double(i) * interval, into: &s, capacity: capacity)
      }
    }
  }

  /// Removes every sample.
  func clear() {
    storage.withLock { s in
      s.values.removeAll(keepingCapacity: true)
      s.times.removeAll(keepingCapacity: true)
      s.head = 0
    }
  }

  private static func push(_ value: T, _ time: Double, into s: inout Storage, capacity: Int) {
    if s.values.count < capacity {
      s.values.append(value)
      s.times.append(time)
    } else {
      s.values[s.head] = value
      s.times[s.head] = time
      s.head = (s.head + 1) % capacity
    }
    s.appended &+= 1
  }

  // MARK: Reading

  /// Samples currently held.
  var count: Int { storage.withLock { $0.values.count } }

  /// Total samples ever appended (a sequence number; survives wrap-around, reset by nothing).
  var totalAppended: UInt64 { storage.withLock { $0.appended } }

  /// The newest sample and its time.
  var latest: (value: T, time: Double)? {
    storage.withLock { s in
      guard !s.values.isEmpty else { return nil }
      let i = s.values.count < capacity ? s.values.count - 1 : (s.head + capacity - 1) % capacity
      return (s.values[i], s.times[i])
    }
  }

  /// Every sample held, oldest first.
  func snapshot() -> TimedSamples<T> {
    storage.withLock { s in Self.ordered(s, from: 0, capacity: capacity) }
  }

  /// Samples taken strictly after `time`, oldest first. Pass the last time you read to get
  /// only new samples.
  func snapshot(since time: Double) -> TimedSamples<T> {
    storage.withLock { s in
      let n = s.values.count
      // Binary search over logical order for the first time > `time`.
      var lo = 0
      var hi = n
      while lo < hi {
        let mid = (lo + hi) / 2
        let t = s.times[Self.physical(mid, s, capacity)]
        if t > time { hi = mid } else { lo = mid + 1 }
      }
      return Self.ordered(s, from: lo, capacity: capacity)
    }
  }

  /// The newest `count` samples, oldest first.
  func snapshot(last count: Int) -> TimedSamples<T> {
    storage.withLock { s in
      let n = s.values.count
      return Self.ordered(s, from: max(0, n - max(0, count)), capacity: capacity)
    }
  }

  /// Mean sample rate over the newest `window` seconds, from timestamps (nil if unknown).
  func measuredRate(window: Double = 2) -> Double? {
    storage.withLock { s in
      let n = s.values.count
      guard n >= 2 else { return nil }
      let newest = s.times[Self.physical(n - 1, s, capacity)]
      var first = n - 1
      while first > 0, newest - s.times[Self.physical(first - 1, s, capacity)] <= window { first -= 1 }
      let span = newest - s.times[Self.physical(first, s, capacity)]
      guard n - 1 - first >= 1, span > 0 else { return nil }
      return Double(n - 1 - first) / span
    }
  }

  private static func physical(_ logical: Int, _ s: Storage, _ capacity: Int) -> Int {
    s.values.count < capacity ? logical : (s.head + logical) % capacity
  }

  private static func ordered(_ s: Storage, from logical: Int, capacity: Int) -> TimedSamples<T> {
    let n = s.values.count
    guard logical < n else { return TimedSamples() }
    if n < capacity || s.head == 0 {
      return TimedSamples(values: Array(s.values[logical..<n]), times: Array(s.times[logical..<n]))
    }
    let start = (s.head + logical) % capacity
    if start >= s.head {
      // Oldest part runs from `start` to the end, then wraps to `head`.
      let values = Array(s.values[start..<capacity]) + Array(s.values[0..<s.head])
      let times = Array(s.times[start..<capacity]) + Array(s.times[0..<s.head])
      return TimedSamples(values: values, times: times)
    }
    return TimedSamples(values: Array(s.values[start..<s.head]), times: Array(s.times[start..<s.head]))
  }
}
