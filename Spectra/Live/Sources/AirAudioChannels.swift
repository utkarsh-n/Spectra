import AVFoundation
import CoreMotion
import Foundation
import Observation
import Synchronization

/// The barometer (`CMAltimeter`): pressure and relative altitude at about 1 Hz, each sample
/// with its own `CMLogItem.timestamp`. Asks for Motion & Fitness access on the first start.
@Observable @MainActor
final class BarometerChannel: LiveSource {
  let core: ChannelCore
  /// Pa.
  private(set) var pressure: Double?
  /// m, relative to where the updates started.
  private(set) var relativeAltitude: Double?
  @ObservationIgnored private var altimeter: CMAltimeter?
  @ObservationIgnored private let queue: OperationQueue = {
    let q = OperationQueue()
    q.name = "Spectra.altimeter"
    q.maxConcurrentOperationCount = 1
    return q
  }()

  init(context: LiveContext) {
    core = ChannelCore(id: .barometer, context: context)
    core.provenance = context.simulates(.barometer, hardwareAvailable: CMAltimeter.isRelativeAltitudeAvailable()) ? .sim : .live
  }

  private var hardwareAvailable: Bool { CMAltimeter.isRelativeAltitudeAvailable() }

  var startsSilently: Bool {
    core.context.simulates(.barometer, hardwareAvailable: hardwareAvailable) || CMAltimeter.authorizationStatus() == .authorized
  }

  var markers: [SpectrumMarker] { [] }

  func start() async {
    guard core.state != .running, core.state != .requesting else { return }
    let sim = core.context.simulates(.barometer, hardwareAvailable: hardwareAvailable)
    guard sim || hardwareAvailable else {
      core.state = .unavailable("This device reports no barometer.")
      return
    }
    if !sim {
      switch CMAltimeter.authorizationStatus() {
      case .denied, .restricted:
        core.state = .denied
        return
      default: break
      }
    }
    core.prepare(simulated: sim)
    let p = core.make(LiveStreams.pressure)
    let h = core.make(LiveStreams.relativeAltitude)
    core.publish([p, h])
    if sim {
      let t0 = SignalClock.now()
      let seed = core.context.seed(for: .barometer)
      core.runSimulation(
        BarometerGenerator(
          pressure: p, altitude: h, mode: core.context.launch.fakeBaro ?? .still, t0: t0,
          grid: SampleGrid(rate: 1, start: t0, seed: seed), rng: SimRandom(seed: seed)))
      core.state = .running
    } else {
      let altimeter = CMAltimeter()
      self.altimeter = altimeter
      let failed: @MainActor @Sendable () -> Void = { [weak self] in self?.permissionRefused() }
      // The prompt appears now; samples (and the running state) follow the answer.
      core.state = CMAltimeter.authorizationStatus() == .authorized ? .running : .requesting
      altimeter.startRelativeAltitudeUpdates(to: queue, withHandler: Self.handler(pressure: p, altitude: h, failed: failed))
    }
    refresh()
  }

  nonisolated private static func handler(
    pressure: SignalStream, altitude: SignalStream, failed: @escaping @MainActor @Sendable () -> Void
  ) -> CMAltitudeHandler {
    { data, error in
      if error != nil {
        Task { @MainActor in failed() }
        return
      }
      guard let data else { return }
      let t = data.timestamp
      pressure.append(Float(data.pressure.doubleValue * 1000), at: t)
      altitude.append(Float(data.relativeAltitude.doubleValue), at: t)
    }
  }

  private func permissionRefused() {
    altimeter?.stopRelativeAltitudeUpdates()
    altimeter = nil
    pressure = nil
    relativeAltitude = nil
    core.reset(to: CMAltimeter.authorizationStatus() == .denied ? .denied : .unavailable("The barometer stopped with an error."))
  }

  func stop() {
    altimeter?.stopRelativeAltitudeUpdates()
    altimeter = nil
    pressure = nil
    relativeAltitude = nil
    core.reset()
  }

  func refresh() {
    guard core.state == .running || core.state == .requesting else { return }
    if core.state == .requesting, core.stream(LiveStreams.pressure.id)?.ring.count ?? 0 > 0 { core.state = .running }
    core.refreshRate(from: LiveStreams.pressure)
    pressure = core.latest(LiveStreams.pressure)
    relativeAltitude = core.latest(LiveStreams.relativeAltitude)
    if let p = pressure {
      core.primaryReadout = "\(SpectraFormat.significant(p / 1000, 5)) kPa"
    }
  }

  var capabilities: [CapabilityFlag] {
    [
      CapabilityFlag("Relative altitude", CMAltimeter.isRelativeAltitudeAvailable(), source: "CMAltimeter.isRelativeAltitudeAvailable"),
      CapabilityFlag("Absolute altitude", CMAltimeter.isAbsoluteAltitudeAvailable(), source: "CMAltimeter.isAbsoluteAltitudeAvailable"),
      CapabilityFlag("Authorization", .text(Self.describe(CMAltimeter.authorizationStatus())), source: "CMAltimeter.authorizationStatus"),
      CapabilityFlag(
        "Pressure rate", core.measuredRate.map { .text(SpectraFormat.rate($0) + (core.simulated ? " (SIM)" : "")) } ?? .unknown,
        source: "CMLogItem.timestamp"),
    ]
  }

  private static func describe(_ s: CMAuthorizationStatus) -> String {
    switch s {
    case .authorized: "Allowed"
    case .denied: "Denied"
    case .restricted: "Restricted"
    default: "Not asked yet"
    }
  }
}

/// The tap's reusable sample buffer. The tap block runs serially on one audio thread and is
/// the only user, so no lock is needed (`@unchecked Sendable` for that reason).
nonisolated final class TapScratch: @unchecked Sendable {
  var values: [Float] = []
}

/// The microphone through `AVAudioEngine`'s input tap (iOS 27 `installAudioTap`), at the
/// hardware rate (48 kHz on iPhone), stamped with `AVAudioTime` host time. Sound is not light:
/// every number here is an ANALOGY. Audio is never recorded or kept (a 2 s ring).
@Observable @MainActor
final class MicrophoneChannel: LiveSource {
  let core: ChannelCore
  private(set) var sampleRate = 48_000.0
  /// dBFS of the newest block.
  private(set) var level: Double?
  /// Loudest frequency (Hz) and its level (dBFS), from a 4096-point FFT.
  private(set) var loudestHz: Double?
  private(set) var loudestDB: Double?
  @ObservationIgnored private var engine: AVAudioEngine?
  @ObservationIgnored private var analyzer = RF.SpectrumAnalyzer(count: 4096)
  @ObservationIgnored private var configObserver: (any NSObjectProtocol)?

  init(context: LiveContext) {
    core = ChannelCore(id: .microphone, context: context)
    core.provenance = context.simulates(.microphone, hardwareAvailable: AVAudioSession.sharedInstance().isInputAvailable) ? .sim : .live
  }

  private var hardwareAvailable: Bool { AVAudioSession.sharedInstance().isInputAvailable }

  var startsSilently: Bool {
    core.context.simulates(.microphone, hardwareAvailable: hardwareAvailable)
      || AVAudioApplication.shared.recordPermission == .granted
  }

  func start() async {
    guard core.state != .running, core.state != .requesting else { return }
    let sim = core.context.simulates(.microphone, hardwareAvailable: hardwareAvailable)
    if sim {
      core.prepare(simulated: true)
      sampleRate = 48_000
      let left = core.make(LiveStreams.micLeft)
      let level = core.make(LiveStreams.micLevel)
      core.publish([left, level])
      let t0 = SignalClock.now()
      let seed = core.context.seed(for: .microphone)
      core.runSimulation(
        MicrophoneGenerator(
          left: left, level: level, mode: core.context.launch.fakeMic ?? .room, t0: t0,
          grid: SampleGrid(rate: 48_000, start: t0, seed: seed), rng: SimRandom(seed: seed)))
      core.state = .running
      refresh()
      return
    }
    guard hardwareAvailable else {
      core.state = .unavailable("No microphone input is available right now.")
      return
    }
    switch AVAudioApplication.shared.recordPermission {
    case .denied:
      core.state = .denied
      return
    case .undetermined:
      core.state = .requesting
      let granted = await AVAudioApplication.requestRecordPermission()
      // Stopped while the prompt was up, or another start already took over: do nothing
      // (two starts racing through the prompt would otherwise build two engines).
      guard core.state == .requesting else { return }
      guard granted else {
        core.state = .denied
        return
      }
    default: break
    }
    core.prepare(simulated: false)
    beginEngine()
  }

  private func beginEngine() {
    AudioRoute.recording = true
    let engine = AVAudioEngine()
    let input = engine.inputNode
    let format = input.outputFormat(forBus: 0)
    guard format.sampleRate > 0, format.channelCount > 0 else {
      fail("The microphone reported no audio format.")
      return
    }
    sampleRate = format.sampleRate
    let left = core.make(LiveStreams.micLeft, rate: format.sampleRate)
    let level = core.make(LiveStreams.micLevel, rate: format.sampleRate / Double(LevelAccumulator.block))
    do {
      try input.installAudioTap(
        onBus: 0, bufferSize: 1024, format: format,
        tapProvider: Self.tap(left: left, level: level, accumulator: LevelAccumulator(), scratch: TapScratch()))
      try engine.start()
    } catch {
      input.removeTap(onBus: 0)
      fail("The microphone could not start (\(error.localizedDescription)).")
      return
    }
    self.engine = engine
    core.publish([left, level])
    core.state = .running
    // A route change (headphones in or out) reconfigures the engine: start again cleanly.
    configObserver = NotificationCenter.default.addObserver(
      forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
    ) { [weak self] _ in
      Task { @MainActor in self?.restartAfterConfigurationChange() }
    }
    refresh()
  }

  private func restartAfterConfigurationChange() {
    guard core.state == .running, !core.simulated else { return }
    teardownEngine()
    core.withdrawAll()
    beginEngine()
  }

  private func fail(_ reason: String) {
    teardownEngine()
    core.reset(to: .unavailable(reason))
  }

  private func teardownEngine() {
    if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
    configObserver = nil
    if let engine {
      engine.inputNode.removeTap(onBus: 0)
      engine.stop()
    }
    engine = nil
    AudioRoute.recording = false
  }

  nonisolated private static func tap(
    left: SignalStream, level: SignalStream, accumulator: LevelAccumulator, scratch: TapScratch
  ) -> @Sendable (AVReadOnlyAudioPCMBuffer, AVAudioTime) -> Void {
    { buffer, when in
      let n = buffer.frameLength
      let rate = buffer.format.sampleRate
      guard n > 0, rate > 0 else { return }
      let stride = max(1, buffer.stride)
      // Reused between callbacks: no allocation per buffer once the size settles.
      if scratch.values.count != n { scratch.values = [Float](repeating: 0, count: n) }
      let copied = scratch.values.withUnsafeMutableBufferPointer { out -> Bool in
        switch buffer.channelData(0) {
        case .float(let span):
          for i in 0..<n { out[i] = i * stride < span.count ? span[i * stride] : 0 }
        case .int16(let span):
          for i in 0..<n { out[i] = i * stride < span.count ? Float(span[i * stride]) / 32_768 : 0 }
        case .int32(let span):
          for i in 0..<n { out[i] = i * stride < span.count ? Float(span[i * stride]) / 2_147_483_648 : 0 }
        @unknown default:
          return false
        }
        return true
      }
      guard copied else { return }
      let start = when.isHostTimeValid ? AVAudioTime.seconds(forHostTime: when.hostTime) : SignalClock.now() - Double(n) / rate
      left.ring.append(contentsOf: scratch.values, start: start, interval: 1 / rate)
      accumulator.feed(scratch.values, start: start, interval: 1 / rate, into: level)
    }
  }

  func stop() {
    if !core.simulated { teardownEngine() }
    level = nil
    loudestHz = nil
    loudestDB = nil
    core.reset()
  }

  func refresh() {
    guard core.state == .running else { return }
    core.refreshRate(from: LiveStreams.micLeft)
    level = core.latest(LiveStreams.micLevel)
    if let left = core.stream(LiveStreams.micLeft.id), let count = analyzer?.count {
      let snap = left.ring.snapshot(last: count)
      // In place (`&analyzer!`): a local copy would copy the FFT work buffers every refresh.
      if let peak = LiveAnalysis.loudest(snap.values, sampleRate: sampleRate, count: count, analyzer: &analyzer!) {
        loudestHz = peak.frequency
        loudestDB = Double(peak.levelDB)
      } else {
        loudestHz = nil
        loudestDB = nil
      }
    }
    if let level {
      core.primaryReadout = SpectraFormat.decibels(level, unit: "dBFS") + (loudestHz.map { " · " + SpectraFormat.frequency($0, digits: 3) } ?? "")
    }
  }

  var markers: [SpectrumMarker] {
    guard let f = loudestHz, f > 0 else { return [] }
    return [
      SpectrumMarker(
        id: "live.sound", label: "Loudest sound \(SpectraFormat.frequency(f, digits: 3)) (analogy)", frequency: f,
        provenance: core.simulated ? .sim : .live, tab: .live, isEM: false)
    ]
  }

  var capabilities: [CapabilityFlag] {
    let session = AVAudioSession.sharedInstance()
    return [
      CapabilityFlag("Input available", session.isInputAvailable, source: "AVAudioSession.isInputAvailable"),
      CapabilityFlag("Session sample rate", .text(SpectraFormat.rate(session.sampleRate)), source: "AVAudioSession.sampleRate"),
      CapabilityFlag(
        "Measured rate", core.measuredRate.map { .text(SpectraFormat.rate($0) + (core.simulated ? " (SIM)" : "")) } ?? .unknown,
        source: "AVAudioTime host time"),
      CapabilityFlag("Permission", .text(Self.describe(AVAudioApplication.shared.recordPermission)), source: "AVAudioApplication.recordPermission"),
    ]
  }

  private static func describe(_ p: AVAudioApplication.recordPermission) -> String {
    switch p {
    case .granted: "Allowed"
    case .denied: "Denied"
    default: "Not asked yet"
    }
  }
}
