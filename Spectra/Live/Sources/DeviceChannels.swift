import CoreNFC
import Foundation
import NearbyInteraction
import Observation
import UIKit

/// Charging and the device itself: battery level and state (`UIDevice`), thermal state
/// (`ProcessInfo`) and, when switched on, the proximity sensor. iOS does not say whether
/// power arrives by cable or by coil, so wireless charging is only INFERRED: charging that
/// starts together with a large static magnetic step (the MagSafe magnet ring).
@Observable @MainActor
final class ChargingChannel: LiveSource {
  let core: ChannelCore
  /// 0…100 %.
  private(set) var level: Double?
  /// 1 unplugged, 2 charging, 3 full (0 unknown).
  private(set) var batteryState = 0
  /// 0 nominal … 3 critical.
  private(set) var thermal = 0
  /// Proximity sensor covered (nil while monitoring is off).
  private(set) var proximityCovered: Bool?
  /// Whether enabling proximity monitoring stuck (false on devices without the sensor).
  private(set) var proximitySupported: Bool?
  /// Charging began within a few seconds of a ≥ 20 µT static field step.
  private(set) var magsafeLikely = false
  @ObservationIgnored private var sampler: Task<Void, Never>?
  @ObservationIgnored private var proximityObserver: (any NSObjectProtocol)?
  @ObservationIgnored private var lastState = 0
  @ObservationIgnored private var chargeStart: Double?
  @ObservationIgnored private var t0 = 0.0
  /// `device.proximity`, on the bus only while monitoring is on (an empty stream would sit in
  /// the Scope's picker with nothing to show).
  @ObservationIgnored private var proximityStream: SignalStream?

  init(context: LiveContext) {
    core = ChannelCore(id: .charging, context: context)
    core.provenance = context.simulates(.charging, hardwareAvailable: Self.hardwareAvailable) ? .sim : .live
  }

  var startsSilently: Bool { true }

  private static var hardwareAvailable: Bool {
    #if targetEnvironment(simulator)
      false
    #else
      true
    #endif
  }

  func start() async {
    guard core.state != .running else { return }
    let sim = core.context.simulates(.charging, hardwareAvailable: Self.hardwareAvailable)
    core.prepare(simulated: sim)
    let levelStream = core.make(LiveStreams.batteryLevel)
    let stateStream = core.make(LiveStreams.batteryState)
    let thermalStream = core.make(LiveStreams.thermal)
    let proximityStream = core.make(LiveStreams.proximity)
    self.proximityStream = proximityStream
    core.publish([levelStream, stateStream, thermalStream])
    if !sim { UIDevice.current.isBatteryMonitoringEnabled = true }
    t0 = SignalClock.now()
    core.state = .running
    let magsafe = core.context.launch.fakeMag == .magsafe
    let start = t0
    // Battery and thermal are slow: sample every 5 s (and once now).
    sampler = Task { [weak self] in
      while !Task.isCancelled {
        guard let self else { return }
        let t = SignalClock.now()
        var level: Double
        var state: Int
        if sim {
          (level, state) = ChargingFake.reading(at: t, since: start, magsafe: magsafe)
        } else {
          let device = UIDevice.current
          level = device.batteryLevel >= 0 ? Double(device.batteryLevel) * 100 : .nan
          state = Self.code(device.batteryState)
        }
        if level.isFinite { levelStream.append(Float(level), at: t) }
        stateStream.append(Float(state), at: t)
        thermalStream.append(Float(Self.code(ProcessInfo.processInfo.thermalState)), at: t)
        self.refresh()
        try? await Task.sleep(for: .seconds(sim && magsafe ? 1 : 5))
      }
    }
    applyProximity(proximityStream)
    refresh()
  }

  /// Turns proximity monitoring on or off per the Live preference.
  func applyPreferences() {
    guard core.state == .running, let s = proximityStream else { return }
    applyProximity(s)
  }

  private func applyProximity(_ stream: SignalStream) {
    let wanted = core.context.settings.prefs.proximity && !core.simulated
    let device = UIDevice.current
    if wanted, !device.isProximityMonitoringEnabled {
      device.isProximityMonitoringEnabled = true
      proximitySupported = device.isProximityMonitoringEnabled
      guard device.isProximityMonitoringEnabled else { return }
      proximityCovered = device.proximityState
      core.publish([stream])
      stream.append(device.proximityState ? 1 : 0, at: SignalClock.now())
      proximityObserver = NotificationCenter.default.addObserver(
        forName: UIDevice.proximityStateDidChangeNotification, object: nil, queue: .main
      ) { [weak self] _ in
        Task { @MainActor in
          let covered = UIDevice.current.proximityState
          self?.proximityCovered = covered
          stream.append(covered ? 1 : 0, at: SignalClock.now())
        }
      }
    } else if !wanted {
      if let proximityObserver { NotificationCenter.default.removeObserver(proximityObserver) }
      proximityObserver = nil
      if device.isProximityMonitoringEnabled { device.isProximityMonitoringEnabled = false }
      proximityCovered = nil
      if core.stream(stream.id) != nil { core.withdraw([stream]) }
    }
  }

  static func code(_ s: UIDevice.BatteryState) -> Int {
    switch s {
    case .unplugged: 1
    case .charging: 2
    case .full: 3
    default: 0
    }
  }

  static func code(_ s: ProcessInfo.ThermalState) -> Int {
    switch s {
    case .nominal: 0
    case .fair: 1
    case .serious: 2
    case .critical: 3
    @unknown default: 0
    }
  }

  func stop() {
    sampler?.cancel()
    sampler = nil
    proximityStream = nil
    if let proximityObserver { NotificationCenter.default.removeObserver(proximityObserver) }
    proximityObserver = nil
    if UIDevice.current.isProximityMonitoringEnabled { UIDevice.current.isProximityMonitoringEnabled = false }
    if !core.simulated { UIDevice.current.isBatteryMonitoringEnabled = false }
    level = nil
    batteryState = 0
    thermal = 0
    proximityCovered = nil
    magsafeLikely = false
    chargeStart = nil
    lastState = 0
    core.reset()
  }

  func refresh() {
    guard core.state == .running else { return }
    level = core.latest(LiveStreams.batteryLevel)
    batteryState = Int(core.latest(LiveStreams.batteryState) ?? 0)
    thermal = Int(core.latest(LiveStreams.thermal) ?? 0)
    let now = SignalClock.now()
    if batteryState == 2, lastState != 2 { chargeStart = now }
    if batteryState != 2, batteryState != 3 {
      chargeStart = nil
      magsafeLikely = false
    }
    lastState = batteryState
    if let start = chargeStart, !magsafeLikely { magsafeLikely = Self.fieldStep(around: start, registry: core.registry) }
    core.refreshRate(from: LiveStreams.batteryLevel)
    let words = ["Unknown", "Unplugged", "Charging", "Full"]
    core.primaryReadout = (level.map { "\(Int($0.rounded())) %" } ?? "—") + " · " + words[min(3, max(0, batteryState))]
  }

  /// A static |B| step of at least 20 µT within ±5 s of `time` in the magnetometer stream:
  /// the MagSafe magnet ring arriving (needs the magnetometer running).
  static func fieldStep(around time: Double, registry: StreamRegistry, threshold: Double = 20) -> Bool {
    guard let norm = registry.stream(LiveStreams.magNorm.id) ?? registry.stream(LiveStreams.magRawNorm.id) else { return false }
    let snap = norm.ring.snapshot(since: time - 5)
    let before = zip(snap.times, snap.values).filter { $0.0 < time - 0.5 }.map { Double($0.1) }
    let after = zip(snap.times, snap.values).filter { $0.0 > time + 0.5 && $0.0 < time + 5 }.map { Double($0.1) }
    guard before.count >= 5, after.count >= 5 else { return false }
    func median(_ v: [Double]) -> Double { v.sorted()[v.count / 2] }
    return abs(median(after) - median(before)) >= threshold
  }

  var isCharging: Bool { batteryState == 2 || batteryState == 3 }

  var markers: [SpectrumMarker] {
    guard core.state == .running, batteryState == 2 else { return [] }
    let qi = RF.Numerology.Qi.bppEppRange
    let centre = (qi.lowerBound + qi.upperBound) / 2
    return [
      SpectrumMarker(
        id: "live.qi",
        label: (magsafeLikely ? "Wireless charging likely · " : "If wireless: ")
          + "Qi \(Int(qi.lowerBound / 1000))–\(Int(qi.upperBound / 1000)) kHz (Qi2 / MagSafe ≈ \(Int(RF.Numerology.Qi.qi2MPP / 1000)) kHz)",
        // Inferred from a measured battery state; a simulated battery makes it SIM.
        frequency: centre, provenance: core.simulated ? .sim : .inferred, tab: .live)
    ]
  }

  var capabilities: [CapabilityFlag] {
    [
      CapabilityFlag("Battery level", level != nil ? .yes : (core.state == .running ? .no : .unknown), source: "UIDevice.batteryLevel"),
      CapabilityFlag("Wired vs wireless", .text("Not exposed: inferred from a magnetic step"), source: "UIDevice.batteryState"),
      CapabilityFlag("Thermal state", .text(["nominal", "fair", "serious", "critical"][min(3, thermal)]), source: "ProcessInfo.thermalState"),
      CapabilityFlag("Proximity sensor", proximitySupported.map { $0 ? .yes : .no } ?? .unknown, source: "UIDevice.isProximityMonitoringEnabled"),
    ]
  }
}

/// Ultra wideband: distance and direction to a peer need a second UWB device (an Apple Watch
/// or another iPhone running a peer session), so the card is NEEDS PEER. The capability flags
/// are real; `-fakeUWB` simulates a peer swinging around you.
@Observable @MainActor
final class UWBChannel: LiveSource {
  let core: ChannelCore
  private(set) var distance: Double?
  private(set) var azimuth: Double?
  private(set) var converged = true
  @ObservationIgnored private var t0 = 0.0

  static let peerReason =
    "Ultra wideband ranging needs a second device, such as an Apple Watch or another iPhone, running a peer session with Spectra."

  init(context: LiveContext) {
    core = ChannelCore(id: .uwb, context: context, provenance: context.launch.fakeUWB ? .sim : .needsPeer)
    if !context.launch.fakeUWB { core.state = .locked(Self.peerReason) }
  }

  var startsSilently: Bool { core.context.launch.fakeUWB }

  func start() async {
    guard core.context.launch.fakeUWB else {
      core.state = .locked(Self.peerReason)
      return
    }
    guard core.state != .running else { return }
    core.prepare(simulated: true)
    let d = core.make(LiveStreams.uwbDistance)
    let a = core.make(LiveStreams.uwbAzimuth)
    core.publish([d, a])
    t0 = SignalClock.now()
    let seed = core.context.seed(for: .uwb)
    let start = t0
    core.runSimulation(
      GeneratorGroup(members: [
        SlowGenerator(
          stream: d, t0: start, grid: SampleGrid(rate: 10, start: start, seed: seed), rng: SimRandom(seed: seed), walk: 0,
          value: { s, _, rng in UWBFake.distance(at: s) + 0.02 * rng.gaussian() }),
        SlowGenerator(
          stream: a, t0: start, grid: SampleGrid(rate: 10, start: start, seed: seed &+ 1), rng: SimRandom(seed: seed &+ 1), walk: 0,
          value: { s, _, rng in UWBFake.azimuth(at: s) + rng.gaussian() }),
      ]))
    core.state = .running
    refresh()
  }

  func stop() {
    distance = nil
    azimuth = nil
    core.reset(to: core.context.launch.fakeUWB ? .idle : .locked(Self.peerReason))
    core.provenance = core.context.launch.fakeUWB ? .sim : .needsPeer
  }

  func refresh() {
    guard core.state == .running else { return }
    distance = core.latest(LiveStreams.uwbDistance)
    azimuth = core.latest(LiveStreams.uwbAzimuth)
    converged = UWBFake.converged(at: SignalClock.now() - t0)
    core.refreshRate(from: LiveStreams.uwbDistance)
    if let distance {
      let tof = RF.Numerology.UWB.timeOfFlight(distance: distance)
      core.primaryReadout = "\(SpectraFormat.significant(distance, 3)) m · ToF \(SpectraFormat.significant(tof * 1e9, 3)) ns"
    }
  }

  var markers: [SpectrumMarker] {
    [
      SpectrumMarker(
        id: "live.uwb", label: "UWB channel 9 · 7.99 GHz", frequency: RF.Numerology.UWB.channel9,
        provenance: core.state == .running ? .sim : .needsPeer, tab: .live)
    ]
  }

  var capabilities: [CapabilityFlag] {
    let caps = NISession.deviceCapabilities
    return [
      CapabilityFlag("Precise distance", caps.supportsPreciseDistanceMeasurement, source: "NIDeviceCapability"),
      CapabilityFlag("Direction", caps.supportsDirectionMeasurement, source: "NIDeviceCapability"),
      CapabilityFlag("Camera assistance", caps.supportsCameraAssistance, source: "NIDeviceCapability"),
      CapabilityFlag("Extended distance", caps.supportsExtendedDistanceMeasurement, source: "NIDeviceCapability"),
      CapabilityFlag("DL-TDoA", caps.supportsDLTDOAMeasurement, source: "NIDeviceCapability (paid entitlement)"),
      CapabilityFlag("Bluetooth Channel Sounding", caps.supportsBluetoothChannelSounding, source: "NIDeviceCapability (iOS 27)"),
    ]
  }
}

/// NFC at 13.56 MHz: reading tags needs a paid Apple Developer Program team, so the card is
/// LOCKED and shows the coupling model. `-fakeNFC` taps a simulated tag every 8 s.
@Observable @MainActor
final class NFCChannel: LiveSource {
  let core: ChannelCore
  /// Simulated taps so far.
  private(set) var taps = 0
  private(set) var lastTap: Double?

  static let lockReason = "Reading NFC tags needs a paid Apple developer team. Spectra shows the 13.56 MHz model instead."

  init(context: LiveContext) {
    core = ChannelCore(id: .nfc, context: context, provenance: .locked)
    if !context.launch.fakeNFC { core.state = .locked(Self.lockReason) }
  }

  var startsSilently: Bool { core.context.launch.fakeNFC }

  func start() async {
    guard core.context.launch.fakeNFC else {
      core.state = .locked(Self.lockReason)
      return
    }
    guard core.state != .running else { return }
    core.prepare(simulated: true)
    // The tag itself stays a simulation of a locked capability.
    core.provenance = .locked
    let tap = core.make(LiveStreams.nfcTap)
    core.publish([tap])
    let t0 = SignalClock.now()
    let seed = core.context.seed(for: .nfc)
    core.runSimulation(
      SlowGenerator(
        stream: tap, t0: t0, grid: SampleGrid(rate: 1 / NFCFake.period, start: t0 + 2, seed: seed), rng: SimRandom(seed: seed),
        walk: 0, value: { _, _, _ in 1 }))
    core.state = .running
    refresh()
  }

  func stop() {
    taps = 0
    lastTap = nil
    core.reset(to: core.context.launch.fakeNFC ? .idle : .locked(Self.lockReason))
    core.provenance = .locked
  }

  func refresh() {
    guard core.state == .running, let s = core.stream(LiveStreams.nfcTap.id) else { return }
    // Every tap this run, not the ring's (capped) count.
    taps = Int(s.ring.totalAppended)
    lastTap = s.ring.latest?.time
    core.refreshRate(from: LiveStreams.nfcTap)
    core.primaryReadout = taps == 0 ? "Waiting for a simulated tag" : "\(taps) simulated tap\(taps == 1 ? "" : "s") · UID \(NFCFake.uid)"
  }

  var markers: [SpectrumMarker] {
    [SpectrumMarker(id: "live.nfc", label: "NFC 13.56 MHz", frequency: RF.Numerology.NFC.carrier, provenance: .locked, tab: .live)]
  }

  var capabilities: [CapabilityFlag] {
    [
      CapabilityFlag("Reader hardware", NFCReaderSession.readingAvailable, source: "NFCReaderSession.readingAvailable"),
      CapabilityFlag("Entitlement", .text("Locked: needs the paid NFC Tag Reading capability"), source: "com.apple.developer.nfc.readersession.formats"),
    ]
  }
}
