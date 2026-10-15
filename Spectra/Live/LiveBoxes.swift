import Foundation
import Synchronization

// Small `Sendable` boxes shared by the sources and the fakes. Pure Foundation (no device
// frameworks), so the analysis and the fakes can be checked outside the app.

/// The newest value of something a sensor callback or a simulated generator produces, read
/// by the main actor at its own pace (`Mutex`, never blocks the sensor thread for long).
nonisolated final class Latest<Value: Sendable>: Sendable {
  private let storage: Mutex<Value>

  init(_ value: Value) { storage = Mutex(value) }

  var value: Value { storage.withLock { $0 } }

  func set(_ value: Value) { storage.withLock { $0 = value } }

  func update(_ body: (inout Value) -> Void) { storage.withLock { body(&$0) } }
}

/// Shared state of the simulated world (`gyre-integration.md` §8): the fakes all read one
/// clock and one pose, so the simulated phone turning on the "turntable" turns for the motion
/// fake and the Bluetooth fake alike.
nonisolated final class SimWorld: Sendable {
  private struct State {
    var turntableSince: Double?
  }

  private let state = Mutex(State())

  init() {}

  /// Starts (or stops) the simulated phone spinning flat on a turntable, one turn per 24 s.
  func setTurntable(_ on: Bool, at time: Double = SignalClock.now()) {
    state.withLock { $0.turntableSince = on ? ($0.turntableSince ?? time) : nil }
  }

  /// Time the turntable started (nil when off).
  var turntableSince: Double? { state.withLock { $0.turntableSince } }

  /// Seconds per simulated turntable revolution.
  static let turntablePeriod = 24.0
}
