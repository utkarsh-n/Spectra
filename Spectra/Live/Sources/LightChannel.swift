import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import Observation

/// What the camera is doing, for the readouts (written on the capture queue).
nonisolated struct CameraReading: Sendable, Equatable {
  var iso: Double?
  /// Exposure time (s).
  var exposure: Double?
  var aperture: Double?
  /// `exposureTargetOffset` (EV).
  var targetOffset: Double?
  /// Measured frame rate (Hz).
  var frameRate: Double?
  /// Row bins per frame in the flicker signal.
  var rows: Int?
  /// True once the short flicker exposure is locked.
  var flickerLocked = false
}

/// The camera as a light meter and a rolling-shutter flicker probe. Every AVFoundation object
/// lives on `queue`; frames are reduced to one mean per band of rows (never stored) and the
/// exposure settings are read at about 10 Hz.
nonisolated final class CameraMeter: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
  struct Streams: Sendable {
    let lux: SignalStream
    let cct: SignalStream
    let ev: SignalStream
    let flicker: SignalStream
  }

  private let queue = DispatchQueue(label: "Spectra.camera", qos: .userInitiated)
  // Touched only on `queue`.
  private let session = AVCaptureSession()
  private var device: AVCaptureDevice?
  private var lastMeter = 0.0
  private var lastFrame: Double?
  private var frames = 0
  private var flickerWanted = false
  private var smoothedFrameDuration = 1.0 / 30
  private var lastRowTime = -Double.infinity
  /// Row-band means of the current frame, reused frame to frame (no per-frame allocation).
  private var means: [Float] = []
  private let streams: Streams
  let reading = Latest(CameraReading())

  /// Rows are averaged in bands of this many.
  static let rowBand = 4

  init(streams: Streams) {
    self.streams = streams
    super.init()
  }

  /// Configures and starts the session; reports a reason when it cannot.
  func start(front: Bool, flicker: Bool, completion: @escaping @Sendable (String?) -> Void) {
    queue.async {
      self.flickerWanted = flicker
      guard
        let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: front ? .front : .back),
        let input = try? AVCaptureDeviceInput(device: device)
      else {
        completion("No camera is available.")
        return
      }
      self.session.beginConfiguration()
      if self.session.canSetSessionPreset(.vga640x480) { self.session.sessionPreset = .vga640x480 }
      for i in self.session.inputs { self.session.removeInput(i) }
      for o in self.session.outputs { self.session.removeOutput(o) }
      guard self.session.canAddInput(input) else {
        self.session.commitConfiguration()
        completion("The camera is in use by another app.")
        return
      }
      self.session.addInput(input)
      let output = AVCaptureVideoDataOutput()
      output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
      output.alwaysDiscardsLateVideoFrames = true
      output.setSampleBufferDelegate(self, queue: self.queue)
      if self.session.canAddOutput(output) { self.session.addOutput(output) }
      self.session.commitConfiguration()
      self.device = device
      self.frames = 0
      self.lastFrame = nil
      self.lastRowTime = -Double.infinity
      self.session.startRunning()
      completion(nil)
    }
  }

  /// Turns the short-exposure flicker probe on or off without restarting.
  func setFlicker(_ on: Bool) {
    queue.async {
      self.flickerWanted = on
      if !on { self.restoreAutoExposure() }
      self.frames = min(self.frames, 15)
    }
  }

  func stop() {
    queue.async {
      self.restoreAutoExposure()
      self.session.stopRunning()
      self.device = nil
    }
  }

  private func restoreAutoExposure() {
    guard let device, device.exposureMode == .custom, (try? device.lockForConfiguration()) != nil else { return }
    if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
    device.unlockForConfiguration()
    reading.update { $0.flickerLocked = false }
  }

  /// Locks a short exposure (1/4000 s or the shortest the format allows), raising ISO to keep
  /// the brightness, so lamp flicker becomes bands across the frame.
  private func lockFlickerExposure() {
    guard let device, device.isExposureModeSupported(.custom), (try? device.lockForConfiguration()) != nil else { return }
    let format = device.activeFormat
    let shortest = CMTimeGetSeconds(format.minExposureDuration)
    let target = max(shortest, 1.0 / 4000)
    let current = CMTimeGetSeconds(device.exposureDuration)
    let iso = Float(min(Double(format.maxISO), max(Double(format.minISO), Double(device.iso) * current / target)))
    device.setExposureModeCustom(duration: CMTime(seconds: target, preferredTimescale: 1_000_000), iso: iso, completionHandler: nil)
    device.unlockForConfiguration()
    reading.update { $0.flickerLocked = true }
  }

  func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
    let pts = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
    guard pts.isFinite, let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
    frames += 1
    if let last = lastFrame, pts > last {
      smoothedFrameDuration += (min(0.2, pts - last) - smoothedFrameDuration) * 0.1
    }
    lastFrame = pts
    // Let auto exposure settle for about half a second before locking the short exposure.
    if flickerWanted, frames == 15 { lockFlickerExposure() }
    // Row means of the luma plane (every 8th column, bands of 4 rows).
    CVPixelBufferLockBaseAddress(pixels, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
    guard let base = CVPixelBufferGetBaseAddressOfPlane(pixels, 0) else { return }
    let width = CVPixelBufferGetWidthOfPlane(pixels, 0)
    let height = CVPixelBufferGetHeightOfPlane(pixels, 0)
    let stride = CVPixelBufferGetBytesPerRowOfPlane(pixels, 0)
    let luma = base.assumingMemoryBound(to: UInt8.self)
    let bands = height / Self.rowBand
    guard bands > 1, width > 8 else { return }
    if means.count != bands { means = [Float](repeating: 0, count: bands) }
    for b in 0..<bands {
      var sum = 0
      var n = 0
      for r in (b * Self.rowBand)..<((b + 1) * Self.rowBand) {
        let row = luma + r * stride
        var c = 0
        while c < width {
          sum += Int(row[c])
          n += 1
          c += 8
        }
      }
      means[b] = Float(sum) / Float(max(n, 1)) / 255
    }
    // The rolling shutter reads these bands one after another over about one frame time.
    let rowDt = smoothedFrameDuration / Double(bands)
    // Keep the ring's timestamps increasing even when the frame-time estimate runs long.
    let start = max(pts, lastRowTime + rowDt)
    streams.flicker.ring.append(contentsOf: means, start: start, interval: rowDt)
    lastRowTime = start + Double(bands - 1) * rowDt
    // Exposure settings → EV, lux, colour temperature at about 10 Hz.
    guard pts - lastMeter >= 0.1, let device else { return }
    lastMeter = pts
    let iso = Double(device.iso)
    let exposure = CMTimeGetSeconds(device.exposureDuration)
    let aperture = Double(device.lensAperture)
    let offset = Double(device.exposureTargetOffset)
    if let ev = LightMeter.ev100(aperture: aperture, exposure: exposure, iso: iso, targetOffset: offset) {
      streams.ev.append(Float(ev), at: pts)
      streams.lux.append(Float(LightMeter.lux(ev100: ev)), at: pts)
    }
    let gains = device.deviceWhiteBalanceGains
    if gains.redGain >= 1, gains.greenGain >= 1, gains.blueGain >= 1 {
      let kelvin = Double(device.temperatureAndTintValues(for: gains).temperature)
      if kelvin.isFinite, kelvin > 1000 { streams.cct.append(Float(kelvin), at: pts) }
    }
    let rate = 1 / smoothedFrameDuration
    reading.update {
      $0.iso = iso
      $0.exposure = exposure
      $0.aperture = aperture
      $0.targetOffset = offset
      $0.frameRate = rate
      $0.rows = bands
    }
  }
}

/// Light meter: EV₁₀₀, approximate lux (MODEL) and the white-balance colour temperature from
/// the camera's own exposure settings, plus the experimental rolling-shutter flicker signal
/// (`light.flicker`, one sample per band of rows). Camera frames are never recorded.
@Observable @MainActor
final class LightChannel: LiveSource {
  let core: ChannelCore
  private(set) var lux: Double?
  private(set) var ev: Double?
  private(set) var kelvin: Double?
  private(set) var reading = CameraReading()
  /// Spectrum of the row signal (relative brightness).
  private(set) var flickerSpectrum: LiveAnalysis.Spectrum?
  /// The camera in use.
  private(set) var usingFront = false
  @ObservationIgnored private var meter: CameraMeter?
  /// The simulated camera's flicker-probe switch (read by the fake's generator).
  @ObservationIgnored private var simProbe: Latest<Bool>?

  init(context: LiveContext) {
    core = ChannelCore(id: .light, context: context)
    core.provenance = context.simulates(.light, hardwareAvailable: Self.hardwareAvailable) ? .sim : .live
  }

  /// Looked up once: device discovery is not free and the cards ask on every visibility change.
  private static let hardwareAvailable: Bool = AVCaptureDevice.default(for: .video) != nil
  /// The back wide camera for the census flags, also looked up once (the census redraws at 2 Hz).
  private static let backCamera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)

  var startsSilently: Bool {
    core.context.simulates(.light, hardwareAvailable: Self.hardwareAvailable)
      || AVCaptureDevice.authorizationStatus(for: .video) == .authorized
  }

  private var prefs: LivePreferences { core.context.settings.prefs }

  func start() async {
    guard core.state != .running, core.state != .requesting else { return }
    let sim = core.context.simulates(.light, hardwareAvailable: Self.hardwareAvailable)
    if !sim {
      guard Self.hardwareAvailable else {
        core.state = .unavailable("This device has no camera.")
        return
      }
      switch AVCaptureDevice.authorizationStatus(for: .video) {
      case .denied, .restricted:
        core.state = .denied
        return
      case .notDetermined:
        core.state = .requesting
        let granted = await AVCaptureDevice.requestAccess(for: .video)
        // Stopped while the prompt was up, or another start already took over.
        guard core.state == .requesting else { return }
        guard granted else {
          core.state = .denied
          return
        }
      default: break
      }
    }
    core.prepare(simulated: sim)
    let lux = core.make(LiveStreams.lux)
    let cct = core.make(LiveStreams.cct)
    let ev = core.make(LiveStreams.ev)
    // The row signal's real rate is rows × frame rate (≈ 120 × 30 = 3.6 kHz at VGA).
    let flicker = core.make(LiveStreams.flicker, rate: sim ? 2400 : LightMeter.rowRate(rows: 480 / CameraMeter.rowBand, frameRate: 30))
    core.publish([lux, cct, ev, flicker])
    usingFront = prefs.frontCamera
    if sim {
      let light = core.context.launch.fakeLight ?? LaunchOptions.LightFake()
      let t0 = SignalClock.now()
      let seed = core.context.seed(for: .light)
      let probe = Latest(prefs.flickerProbe)
      simProbe = probe
      func slow(_ s: SignalStream, _ k: UInt64, _ f: @escaping @Sendable (Double, inout Double, inout SimRandom) -> Double) -> SlowGenerator {
        SlowGenerator(stream: s, t0: t0, grid: SampleGrid(rate: 10, start: t0, seed: seed &+ k), rng: SimRandom(seed: seed &+ k), walk: 0, value: f)
      }
      core.runSimulation(
        GeneratorGroup(members: [
          slow(lux, 0) { _, _, rng in light.lux * (1 + 0.01 * rng.gaussian()) },
          slow(cct, 1) { _, _, rng in light.kelvin + 15 * rng.gaussian() },
          slow(ev, 2) { _, _, rng in LightMeter.ev100(lux: light.lux) + 0.01 * rng.gaussian() },
          FlickerGenerator(
            stream: flicker, flickerHz: 120, probe: probe, grid: SampleGrid(rate: 2400, start: t0, seed: seed &+ 3),
            rng: SimRandom(seed: seed &+ 3)),
        ]))
      reading = Self.simulatedReading(lux: light.lux, flickerLocked: prefs.flickerProbe)
      core.state = .running
      refresh()
      return
    }
    let meter = CameraMeter(streams: .init(lux: lux, cct: cct, ev: ev, flicker: flicker))
    self.meter = meter
    core.state = .running
    let failed: @MainActor @Sendable (String) -> Void = { [weak self] reason in self?.cameraFailed(reason) }
    meter.start(front: prefs.frontCamera, flicker: prefs.flickerProbe) { reason in
      if let reason { Task { @MainActor in failed(reason) } }
    }
    refresh()
  }

  /// Camera settings the simulated scene would get: f/1.78 and an exposure, with the ISO
  /// that makes EV₁₀₀ match the simulated illuminance (so the readouts agree with each other).
  /// The flicker probe locks 1/4000 s; when the ISO needed exceeds the sensor's top (3200
  /// here) the frame is underexposed and the metering offset carries the difference.
  static func simulatedReading(lux: Double, flickerLocked: Bool) -> CameraReading {
    let aperture = 1.78
    let exposure = flickerLocked ? 1.0 / 4000 : 1.0 / 60
    let ev = LightMeter.ev100(lux: lux)
    let iso = min(3200, max(25, 100 * aperture * aperture / (exposure * pow(2, ev))))
    let settingsEV = LightMeter.ev100(aperture: aperture, exposure: exposure, iso: iso) ?? ev
    return CameraReading(
      iso: iso, exposure: exposure, aperture: aperture, targetOffset: ev - settingsEV, frameRate: 30,
      rows: 480 / CameraMeter.rowBand, flickerLocked: flickerLocked)
  }

  private func cameraFailed(_ reason: String) {
    meter?.stop()
    meter = nil
    core.reset(to: .unavailable(reason))
  }

  /// Applies the front/back and flicker switches. Returns true when the camera must restart
  /// on the other side (the hub does that, so the restart respects who still holds it).
  @discardableResult
  func applyPreferences() -> Bool {
    guard core.state == .running else { return false }
    if core.simulated {
      simProbe?.set(prefs.flickerProbe)
      let lux = core.context.launch.fakeLight?.lux ?? LaunchOptions.LightFake().lux
      reading = Self.simulatedReading(lux: lux, flickerLocked: prefs.flickerProbe)
      usingFront = prefs.frontCamera
      return false
    }
    if prefs.frontCamera != usingFront { return true }
    meter?.setFlicker(prefs.flickerProbe)
    return false
  }

  func stop() {
    meter?.stop()
    meter = nil
    simProbe = nil
    lux = nil
    ev = nil
    kelvin = nil
    flickerSpectrum = nil
    core.reset()
  }

  func refresh() {
    guard core.state == .running else { return }
    lux = core.latest(LiveStreams.lux)
    ev = core.latest(LiveStreams.ev)
    kelvin = core.latest(LiveStreams.cct)
    if let meter { reading = meter.reading.value }
    core.refreshRate(from: LiveStreams.lux)
    if let flicker = core.stream(LiveStreams.flicker.id), let rate = flicker.measuredRate, rate > 200 {
      let n = 2048
      let snap = flicker.ring.snapshot(last: n)
      flickerSpectrum = LiveAnalysis.spectrum(axes: [snap], rate: rate, count: n)
    }
    if let lux {
      core.primaryReadout = "≈\(SpectraFormat.significant(lux, 2)) lux" + (kelvin.map { " · \(Int(($0 / 10).rounded() * 10)) K" } ?? "")
    }
  }

  /// The strongest flicker line between 80 and 400 Hz, if it stands well clear of the noise
  /// (`LightMeter.flickerLine`, 20 dB above the floor).
  var flickerLine: Double? { flickerSpectrum.flatMap { LightMeter.flickerLine(in: $0) } }

  var markers: [SpectrumMarker] {
    guard core.state == .running, let kelvin, kelvin > 500 else { return [] }
    return [
      SpectrumMarker(
        id: "live.light", label: "Light ≈ \(Int((kelvin / 100).rounded() * 100)) K blackbody peak",
        lambda: LightMeter.wienPeak(kelvin: kelvin), provenance: core.simulated ? .sim : .inferred, tab: .live)
    ]
  }

  var capabilities: [CapabilityFlag] {
    let device = Self.backCamera
    return [
      CapabilityFlag("Camera", device != nil, source: "AVCaptureDevice.default(.builtInWideAngleCamera)"),
      CapabilityFlag("Lens aperture", device.map { .text("f/\(SpectraFormat.significant(Double($0.lensAperture), 3))") } ?? .unknown, source: "AVCaptureDevice.lensAperture"),
      CapabilityFlag("Custom exposure", device.map { $0.isExposureModeSupported(.custom) } ?? false, source: "isExposureModeSupported(.custom)"),
      CapabilityFlag(
        "Row signal rate", core.stream(LiveStreams.flicker.id)?.measuredRate.map { .text(SpectraFormat.rate($0) + (core.simulated ? " (SIM)" : "")) } ?? .unknown,
        source: "rows × frame rate (rolling-shutter model)"),
      CapabilityFlag("Ambient light sensor", .text("Locked: SensorKit research entitlement"), source: "SRAmbientLightSample"),
    ]
  }
}
