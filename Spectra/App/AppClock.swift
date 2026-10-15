import Foundation
import Observation
import QuartzCore
import SwiftUI

/// The one display clock (coherence rule R5). The visible Metal canvas calls `tick(at:)`
/// from its render loop; when no Metal scene is on screen, `ClockDriver` (a `TimelineView`)
/// does. Ticks from both arrive at most once per frame and are deduplicated.
///
/// `time` changes every frame and is not observed; SwiftUI observes `displayTime`, which is
/// refreshed at 10 Hz (Gyre/Orbitals discipline: the 60 Hz engine never invalidates views).
@Observable @MainActor
final class AppClock {
  /// Display time in seconds. Read by renderers each frame; not observed.
  @ObservationIgnored private(set) var time: Double = 0
  /// `time`, republished at 10 Hz for SwiftUI readouts.
  private(set) var displayTime: Double = 0
  /// Running or held. Editing while paused never starts playback.
  var playing = true {
    didSet { if playing != oldValue { lastTimestamp = nil } }
  }
  /// False while the scene is not active; the clock holds and rebases on return.
  private(set) var active = true
  /// Measured display frame rate (Hz), for ALIASED decisions. 60 until measured.
  private(set) var frameRate: Double = 60

  @ObservationIgnored private var lastTimestamp: Double?
  @ObservationIgnored private var lastReport: Double = -.infinity
  @ObservationIgnored private var frameInterval: Double = 1.0 / 60
  @ObservationIgnored private var lastRateReport: Double = 0

  /// Longest step one frame may take; longer frames are bounded, never caught up.
  static let maxStep = 0.1
  /// One `step()`.
  static let stepSize = 1.0 / 60

  init(playing: Bool = true) {
    self.playing = playing
  }

  /// True when the clock advances on ticks.
  var isAnimating: Bool { playing && active }

  /// Called with a frame timestamp (`CACurrentMediaTime()`). The first tick after a pause,
  /// a background or a scene change only rebases: there is no wall-clock catch-up.
  func tick(at timestamp: Double = CACurrentMediaTime()) {
    guard isAnimating, timestamp.isFinite else {
      lastTimestamp = nil
      return
    }
    guard let last = lastTimestamp else {
      lastTimestamp = timestamp
      return
    }
    let dt = timestamp - last
    // A second driver in the same frame (canvas + TimelineView) is ignored.
    guard dt >= 0.002 else { return }
    lastTimestamp = timestamp
    frameInterval += (min(dt, 0.1) - frameInterval) * 0.05
    advance(dt: dt)
  }

  /// Advances by `dt` seconds, clamped to 0…0.1 s, when playing.
  func advance(dt: Double) {
    guard playing, dt.isFinite else { return }
    time += min(max(dt, 0), Self.maxStep)
    publish()
  }

  /// Pauses and advances exactly 1/60 s.
  func step() {
    playing = false
    time += Self.stepSize
    publish(force: true)
  }

  func togglePlaying() { playing.toggle() }

  /// Scene phase: inactive holds the clock.
  func setActive(_ isActive: Bool) {
    guard active != isActive else { return }
    active = isActive
    lastTimestamp = nil
  }

  /// Back to zero (keeps play state).
  func reset() {
    time = 0
    lastTimestamp = nil
    publish(force: true)
  }

  private func publish(force: Bool = false) {
    if force || abs(time - lastReport) >= 0.1 {
      lastReport = time
      displayTime = time
    }
    let now = CACurrentMediaTime()
    if now - lastRateReport > 1, frameInterval > 0 {
      lastRateReport = now
      let measured = (1 / frameInterval).rounded()
      if abs(measured - frameRate) >= 2 { frameRate = measured }
    }
  }
}

/// Drives the clock from SwiftUI's animation timeline while it is animating. Placed once
/// behind the root view; harmless alongside a Metal canvas that also ticks.
struct ClockDriver: View {
  let clock: AppClock

  var body: some View {
    TimelineView(.animation(minimumInterval: nil, paused: !clock.isAnimating)) { context in
      Color.clear
        .onChange(of: context.date) { _, _ in clock.tick(at: CACurrentMediaTime()) }
    }
    .frame(width: 0, height: 0)
    .accessibilityHidden(true)
    .allowsHitTesting(false)
  }
}
