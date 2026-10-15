import CoreHaptics
import QuartzCore
import UIKit

/// The one haptics service (coherence rule R5), merging Orbitals and Gyre:
/// - Orbitals' short causal transients (tap, selection, grab, detent, release, boundary,
///   success) with a global `strength`, a ≥ 35 ms rate limit and a stop on background;
/// - Gyre's knob ticks and detent entries, the spin-up curve, and the continuous looping
///   hum (`updateHum`), which runs only when the user enables Continuous hum and a live
///   instrument drives it.
///
/// Use `Haptics.shared` from views and gesture coordinators; `AppModel.haptics` is the same
/// object. Nothing runs continuously unless `updateHum` is being called.
@MainActor
final class Haptics {
  static let shared = Haptics()

  /// Settings → Feedback → Haptics.
  var enabled = true {
    didSet { if !enabled { stop() } }
  }
  /// Settings → Feedback → Haptic strength, 0…1.
  var strength = 0.85
  /// Settings → Feedback → Continuous hum. Off stops any hum.
  var humAllowed = false {
    didSet { if !humAllowed { stopHum() } }
  }
  /// Optional sound answer for ticks and detents (set by `AppModel` when sound is on).
  var soundTick: ((TickSound) -> Void)?

  /// What a tick should sound like when sound is on.
  enum TickSound: Sendable { case tick, detent, boundary }

  /// Named patterns (SPEC.md §6): `play(.tick)`.
  enum Pattern: Sendable, Equatable {
    case tap, selection, grab, tick, detent, boundary, success
    /// A low thump for resonances (matter bench), strength 0…1.
    case resonance(Double)
  }

  private struct Pulse: Hashable {
    let intensity: Float
    let sharpness: Float
    init(_ intensity: Float, _ sharpness: Float) {
      // Quantized so the player cache stays small.
      self.intensity = (min(1, max(0, intensity)) * 50).rounded() / 50
      self.sharpness = (min(1, max(0, sharpness)) * 50).rounded() / 50
    }
    static let touch = Pulse(0.64, 0.5)
    static let grab = Pulse(0.45, 0.7)
    static let tick = Pulse(0.32, 0.9)
    static let quantizedDetent = Pulse(0.43, 0.86)
    static let detentEntry = Pulse(0.9, 0.3)
    static let switchClick = Pulse(0.9, 0.35)
    static let reset = Pulse(0.7, 0.4)
    static let release = Pulse(0.34, 0.38)
    static let boundary = Pulse(0.95, 0.64)
  }

  /// Minimum gap between any two transients.
  static let minimumInterval: TimeInterval = 0.035

  private let selectionGenerator = UISelectionFeedbackGenerator()
  private let impactGenerator = UIImpactFeedbackGenerator(style: .rigid)
  private let notificationGenerator = UINotificationFeedbackGenerator()
  private let supportsCoreHaptics = CHHapticEngine.capabilitiesForHardware().supportsHaptics
  private var engine: CHHapticEngine?
  private var engineRunning = false
  private var players: [Pulse: any CHHapticPatternPlayer] = [:]
  private var hum: CHHapticAdvancedPatternPlayer?
  private var humRunning = false
  private var lastHumSend: CFTimeInterval = 0
  private var lastFeedbackTime: TimeInterval = -.infinity
  private var lastDetent: Int?
  private var backgroundObserver: NSObjectProtocol?

  private init() {
    backgroundObserver = NotificationCenter.default.addObserver(
      forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
    ) { [weak self] _ in
      Task { @MainActor [weak self] in self?.stop() }
    }
  }

  private var canPlay: Bool {
    enabled && strength.isFinite && strength > 0 && UIApplication.shared.applicationState == .active
  }

  private var gain: Float { Float(min(1, max(0, strength))) }

  private func admit(interval: TimeInterval = Haptics.minimumInterval) -> Bool {
    guard canPlay else { return false }
    let now = ProcessInfo.processInfo.systemUptime
    guard now - lastFeedbackTime >= max(interval, Self.minimumInterval) else { return false }
    lastFeedbackTime = now
    return true
  }

  // MARK: Named patterns

  func play(_ pattern: Pattern) {
    switch pattern {
    case .tap: tap()
    case .selection: selection()
    case .grab: grab()
    case .tick: tick()
    case .detent: detent()
    case .boundary: boundary()
    case .success: success()
    case .resonance(let s): resonance(s)
    }
  }

  /// Any button.
  func tap() {
    guard admit() else { return }
    fire(.touch)
  }

  /// Pickers, toggles, tabs, chips, VoiceOver adjustments.
  func selection() {
    guard admit() else { return }
    selectionGenerator.selectionChanged()
    selectionGenerator.prepare()
  }

  /// Grabbing a knob or starting a drag.
  func grab() {
    lastDetent = nil
    guard canPlay else { return }
    impactGenerator.prepare()
    guard admit() else { return }
    fire(.grab)
  }

  /// A light tick while turning (Gyre: every 1/24 of a knob's sweep).
  func tick() {
    guard admit() else { return }
    fire(.tick)
    soundTick?(.tick)
  }

  /// Entering a labelled detent (Gyre's heavier click).
  func detent() {
    guard admit() else { return }
    fire(.detentEntry)
    soundTick?(.detent)
  }

  /// A rotary switch position.
  func switchClick() {
    guard admit() else { return }
    fire(.switchClick)
    soundTick?(.detent)
  }

  /// Double-tap reset of a control.
  func resetClick() {
    guard admit() else { return }
    fire(.reset)
  }

  /// Orbitals' continuous-control begin (same pulse as `grab`, plus generator warm-up).
  func beginAdjustment() { grab() }

  /// Orbitals' quantized detent for continuous controls: 0…1 → 72 detents, boundary pulse
  /// at both ends. Dragging coalesces instead of queuing one pulse per frame.
  func detent(normalized: Double) {
    guard normalized.isFinite, canPlay else { return }
    let index = Int((min(1, max(0, normalized)) * 72).rounded())
    guard index != lastDetent else { return }
    lastDetent = index
    guard admit(interval: 0.045) else { return }
    fire(index == 0 || index == 72 ? Pulse.boundary : Pulse.quantizedDetent)
  }

  /// Releasing a continuous control.
  func endAdjustment() {
    lastDetent = nil
    guard admit() else { return }
    fire(.release)
  }

  /// An end stop or a refused action.
  func boundary() {
    guard admit(interval: 0.09) else { return }
    fire(.boundary)
    soundTick?(.boundary)
  }

  /// Presets loaded, Reset experiment, a successful placement.
  func success() {
    guard admit(interval: 0.06) else { return }
    notificationGenerator.notificationOccurred(.success)
  }

  /// A soft low thump whose weight follows `strength` (0…1).
  func resonance(_ strength: Double) {
    guard strength.isFinite, admit(interval: 0.08) else { return }
    let s = Float(min(1, max(0, strength)))
    fire(Pulse(0.35 + 0.6 * s, 0.12))
  }

  /// A raw transient (Gyre API). `minGap` throttles bursts (crackle, string pulls).
  func transient(intensity: Float, sharpness: Float, minGap: TimeInterval = 0) {
    guard admit(interval: minGap) else { return }
    fire(Pulse(intensity, sharpness))
  }

  /// One Geiger-style click (ELF probe crackle); call at Poisson-distributed times.
  func crackle(intensity: Float) {
    transient(intensity: intensity, sharpness: 1)
  }

  /// A rising buzz that ends in a click (Gyre's rotor spin-up).
  func spinUp() {
    guard supportsCoreHaptics, admit(interval: 0.6) else { return }
    let ramp = CHHapticEvent(
      eventType: .hapticContinuous,
      parameters: [
        CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.9 * gain),
        CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.3),
      ], relativeTime: 0, duration: 0.55)
    let click = CHHapticEvent(
      eventType: .hapticTransient,
      parameters: [
        CHHapticEventParameter(parameterID: .hapticIntensity, value: gain),
        CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.9),
      ], relativeTime: 0.56)
    let curve = CHHapticParameterCurve(
      parameterID: .hapticIntensityControl,
      controlPoints: [.init(relativeTime: 0, value: 0.1), .init(relativeTime: 0.5, value: 1)], relativeTime: 0)
    let sharp = CHHapticParameterCurve(
      parameterID: .hapticSharpnessControl,
      controlPoints: [.init(relativeTime: 0, value: -0.3), .init(relativeTime: 0.5, value: 0.4)], relativeTime: 0)
    do {
      let engine = try prepareEngine()
      let pattern = try CHHapticPattern(events: [ramp, click], parameterCurves: [curve, sharp])
      try engine.makePlayer(with: pattern).start(atTime: CHHapticTimeImmediate)
    } catch {
      engineRunning = false
    }
  }

  // MARK: Continuous hum (Gyre)

  /// Called every frame by a live instrument; parameters go out at most 40 times a second.
  /// Below intensity 0.02 the hum stops. Requires `humAllowed`.
  func updateHum(intensity: Float, sharpness: Float) {
    guard humAllowed, canPlay, supportsCoreHaptics, intensity.isFinite, sharpness.isFinite else {
      stopHum()
      return
    }
    guard intensity >= 0.02 else {
      stopHum()
      return
    }
    do {
      let engine = try prepareEngine()
      if hum == nil {
        let event = CHHapticEvent(
          eventType: .hapticContinuous,
          parameters: [
            CHHapticEventParameter(parameterID: .hapticIntensity, value: 1),
            CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.5),
          ], relativeTime: 0, duration: 30)
        let player = try engine.makeAdvancedPlayer(with: CHHapticPattern(events: [event], parameters: []))
        player.loopEnabled = true
        hum = player
      }
      if !humRunning {
        try hum?.start(atTime: CHHapticTimeImmediate)
        humRunning = true
      }
    } catch {
      hum = nil
      humRunning = false
      return
    }
    let now = CACurrentMediaTime()
    guard now - lastHumSend > 1.0 / 40 else { return }
    lastHumSend = now
    try? hum?.sendParameters(
      [
        CHHapticDynamicParameter(
          parameterID: .hapticIntensityControl, value: min(1, max(0, intensity)) * gain, relativeTime: 0),
        // Sharpness control is an offset from the event's 0.5.
        CHHapticDynamicParameter(
          parameterID: .hapticSharpnessControl, value: min(1, max(0, sharpness)) - 0.5, relativeTime: 0),
      ], atTime: CHHapticTimeImmediate)
  }

  func stopHum() {
    if humRunning { try? hum?.stop(atTime: CHHapticTimeImmediate) }
    humRunning = false
  }

  /// Stops everything (background, haptics off).
  func stop() {
    stopHum()
    players.values.forEach { try? $0.stop(atTime: CHHapticTimeImmediate) }
    engine?.stop(completionHandler: nil)
    engineRunning = false
    lastDetent = nil
    lastFeedbackTime = -.infinity
  }

  // MARK: Engine

  private func prepareEngine() throws -> CHHapticEngine {
    let current: CHHapticEngine
    if let engine {
      current = engine
    } else {
      current = try CHHapticEngine()
      current.playsHapticsOnly = true
      current.isAutoShutdownEnabled = true
      current.stoppedHandler = Self.makeStoppedHandler()
      current.resetHandler = Self.makeResetHandler()
      engine = current
    }
    if !engineRunning {
      try current.start()
      engineRunning = true
    }
    return current
  }

  // The engine calls these on its own queue. They are built in nonisolated functions so the
  // closures are not main-actor isolated (Swift 6 would trap on the off-main call), and hop
  // to the main actor themselves.
  nonisolated private static func makeStoppedHandler() -> (CHHapticEngine.StoppedReason) -> Void {
    { _ in
      Task { @MainActor in
        Haptics.shared.engineRunning = false
        Haptics.shared.humRunning = false
      }
    }
  }

  nonisolated private static func makeResetHandler() -> () -> Void {
    {
      Task { @MainActor in
        // Players belong to the old engine instance; rebuild lazily.
        let h = Haptics.shared
        h.players.removeAll()
        h.hum = nil
        h.humRunning = false
        h.engineRunning = false
      }
    }
  }

  private func fire(_ pulse: Pulse) {
    if supportsCoreHaptics {
      do {
        let engine = try prepareEngine()
        let player: any CHHapticPatternPlayer
        if let cached = players[pulse] {
          player = cached
        } else {
          let event = CHHapticEvent(
            eventType: .hapticTransient,
            parameters: [
              CHHapticEventParameter(parameterID: .hapticIntensity, value: pulse.intensity),
              CHHapticEventParameter(parameterID: .hapticSharpness, value: pulse.sharpness),
            ], relativeTime: 0)
          player = try engine.makePlayer(with: CHHapticPattern(events: [event], parameters: []))
          if players.count > 48 { players.removeAll() }
          players[pulse] = player
        }
        try player.sendParameters(
          [CHHapticDynamicParameter(parameterID: .hapticIntensityControl, value: gain, relativeTime: 0)],
          atTime: CHHapticTimeImmediate)
        try player.start(atTime: CHHapticTimeImmediate)
        return
      } catch {
        players.removeAll()
        engineRunning = false
      }
    }
    impactGenerator.impactOccurred(intensity: CGFloat(gain * pulse.intensity))
    impactGenerator.prepare()
  }
}
