import CoreLocation
import Foundation
import Observation

/// Heading from `CLLocationManager` (true north needs a location fix), written straight into
/// the heading streams from the delegate (main run loop), with the sample's own timestamp.
nonisolated final class HeadingSource: NSObject, CLLocationManagerDelegate, @unchecked Sendable {
  // The manager is created on the main thread and only used there (its delegate runs there).
  private let manager = CLLocationManager()
  private let trueStream: SignalStream
  private let magneticStream: SignalStream
  let accuracy = Latest<Double?>(nil)

  init(trueStream: SignalStream, magneticStream: SignalStream) {
    self.trueStream = trueStream
    self.magneticStream = magneticStream
    super.init()
    manager.delegate = self
    manager.headingFilter = kCLHeadingFilterNone
  }

  static var available: Bool { CLLocationManager.headingAvailable() }

  func start() { manager.startUpdatingHeading() }

  func stop() {
    manager.stopUpdatingHeading()
    manager.delegate = nil
  }

  func locationManager(_ manager: CLLocationManager, didUpdateHeading heading: CLHeading) {
    let t = LocationChannel.uptime(of: heading.timestamp)
    if heading.headingAccuracy >= 0 {
      magneticStream.append(Float(heading.magneticHeading), at: t)
      accuracy.set(heading.headingAccuracy)
    }
    if heading.trueHeading >= 0 { trueStream.append(Float(heading.trueHeading), at: t) }
  }
}

/// Satellites (GNSS): `CLLocationUpdate.liveUpdates` for the fix, ±accuracy, ellipsoidal
/// altitude and speed, plus compass heading. No satellite count or SNR exists in any public
/// API (`sdk-sensors.md` §4.6). The position itself is never shown, stored or sent; only its
/// quality and, for the air card's zenith delay, the latitude in memory.
@Observable @MainActor
final class LocationChannel: LiveSource {
  let core: ChannelCore
  private(set) var horizontalAccuracy: Double?
  private(set) var verticalAccuracy: Double?
  /// WGS-84 ellipsoidal altitude (m).
  private(set) var ellipsoidalAltitude: Double?
  /// Altitude above mean sea level (m).
  private(set) var seaLevelAltitude: Double?
  private(set) var speed: Double?
  private(set) var trueHeading: Double?
  private(set) var magneticHeading: Double?
  /// Latitude (degrees), kept in memory only, for the GNSS zenith delay.
  private(set) var latitude: Double?
  /// The system limits this app to approximate location.
  private(set) var accuracyLimited = false
  /// Seconds since the last fix.
  private(set) var fixAge: Double?
  @ObservationIgnored private var updates: Task<Void, Never>?
  @ObservationIgnored private var serviceSession: CLServiceSession?
  @ObservationIgnored private var heading: HeadingSource?
  @ObservationIgnored private var lastFix: Double?

  /// `CLLocationManager.locationServicesEnabled()`, asked off the main actor (Apple: it can
  /// block the UI there) and cached for the census.
  private(set) var servicesEnabled: Bool?

  init(context: LiveContext) {
    core = ChannelCore(id: .location, context: context)
    core.provenance = context.simulates(.location, hardwareAvailable: true) ? .sim : .live
    checkServices()
  }

  private func checkServices() {
    Task.detached(priority: .utility) { [weak self] in
      let enabled = CLLocationManager.locationServicesEnabled()
      await MainActor.run { self?.servicesEnabled = enabled }
    }
  }

  /// A `CLLocation`/`CLHeading` timestamp (wall clock) on the `SignalClock` (uptime) base.
  nonisolated static func uptime(of date: Date) -> Double {
    SignalClock.now() - max(0, Date().timeIntervalSince(date))
  }

  /// Reads the authorization only (never asks); one manager instead of a new one per check.
  private let authorizationReader = CLLocationManager()

  private var authorization: CLAuthorizationStatus { authorizationReader.authorizationStatus }

  var startsSilently: Bool {
    let a = authorization
    return core.context.simulates(.location, hardwareAvailable: true) || a == .authorizedWhenInUse || a == .authorizedAlways
  }

  func start() async {
    guard core.state != .running, core.state != .requesting else { return }
    let sim = core.context.simulates(.location, hardwareAvailable: true)
    if !sim {
      switch authorization {
      case .denied, .restricted:
        core.state = .denied
        return
      default: break
      }
    }
    checkServices()
    core.prepare(simulated: sim)
    let specs = [
      LiveStreams.hacc, LiveStreams.vacc, LiveStreams.speed, LiveStreams.altitude, LiveStreams.headingTrue,
      LiveStreams.headingMagnetic,
    ]
    let made = specs.map { core.make($0) }
    core.publish(made)
    if sim {
      runFake(made)
      core.state = .running
    } else {
      let a = authorization
      core.state = (a == .authorizedWhenInUse || a == .authorizedAlways) ? .running : .requesting
      serviceSession = CLServiceSession(authorization: .whenInUse)
      let streams = made
      updates = Task { [weak self] in
        do {
          for try await update in CLLocationUpdate.liveUpdates(.default) {
            guard !Task.isCancelled else { return }
            self?.received(update, streams: streams)
          }
        } catch {
          // Cancellation (the card scrolled away) is not a failure, and a stopped run must
          // not reset a newer one.
          guard !Task.isCancelled, !(error is CancellationError) else { return }
          self?.core.reset(to: .unavailable("Location updates stopped: \(error.localizedDescription)"))
        }
      }
      if HeadingSource.available {
        let h = HeadingSource(trueStream: made[4], magneticStream: made[5])
        h.start()
        heading = h
      }
    }
    refresh()
  }

  private func received(_ update: CLLocationUpdate, streams: [SignalStream]) {
    if update.authorizationDenied || update.authorizationDeniedGlobally {
      stop()
      core.state = .denied
      return
    }
    accuracyLimited = update.accuracyLimited
    guard let loc = update.location else { return }
    if core.state == .requesting { core.state = .running }
    let t = Self.uptime(of: loc.timestamp)
    lastFix = t
    latitude = loc.coordinate.latitude
    if loc.horizontalAccuracy >= 0 { streams[0].append(Float(loc.horizontalAccuracy), at: t) }
    if loc.verticalAccuracy >= 0 {
      streams[1].append(Float(loc.verticalAccuracy), at: t)
      streams[3].append(Float(loc.ellipsoidalAltitude), at: t)
      seaLevelAltitude = loc.altitude
    }
    if loc.speed >= 0 { streams[2].append(Float(loc.speed), at: t) }
  }

  private func runFake(_ s: [SignalStream]) {
    let t0 = SignalClock.now()
    let seed = core.context.seed(for: .location)
    let pose = core.context.pose
    func slow(_ i: Int, rate: Double, walk: Double, _ f: @escaping @Sendable (Double, inout Double, inout SimRandom) -> Double)
      -> SlowGenerator
    {
      SlowGenerator(
        stream: s[i], t0: t0, grid: SampleGrid(rate: rate, start: t0, seed: seed &+ UInt64(i)), rng: SimRandom(seed: seed &+ UInt64(i)),
        walk: walk, value: f)
    }
    core.runSimulation(
      GeneratorGroup(members: [
        // Horizontal accuracy wanders 3–15 m (gyre-integration §8).
        slow(0, rate: 1, walk: 6) { _, w, rng in
          w = min(15, max(3, w + 0.8 * rng.gaussian()))
          return w
        },
        slow(1, rate: 1, walk: 8) { _, w, rng in
          w = min(24, max(4, w + 0.8 * rng.gaussian()))
          return w
        },
        slow(2, rate: 1, walk: 0) { s, _, rng in max(0, 0.6 + 0.6 * sin(0.05 * s) + 0.1 * rng.gaussian()) },
        slow(3, rate: 1, walk: 0) { _, _, rng in 152 + 1.5 * rng.gaussian() },
        // Heading follows the simulated phone's yaw (true = magnetic + 3° declination).
        slow(4, rate: 5, walk: 0) { s, _, _ in
          let yaw = pose.angles(at: t0 + s).y * 180 / .pi
          return ((-yaw + 3).truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
        },
        slow(5, rate: 5, walk: 0) { s, _, _ in
          let yaw = pose.angles(at: t0 + s).y * 180 / .pi
          return ((-yaw).truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
        },
      ]))
    latitude = 30
    seaLevelAltitude = 125
  }

  func stop() {
    updates?.cancel()
    updates = nil
    serviceSession?.invalidate()
    serviceSession = nil
    heading?.stop()
    heading = nil
    horizontalAccuracy = nil
    verticalAccuracy = nil
    ellipsoidalAltitude = nil
    seaLevelAltitude = nil
    speed = nil
    trueHeading = nil
    magneticHeading = nil
    latitude = nil
    lastFix = nil
    fixAge = nil
    core.reset()
  }

  func refresh() {
    guard core.state == .running || core.state == .requesting else { return }
    horizontalAccuracy = core.latest(LiveStreams.hacc)
    verticalAccuracy = core.latest(LiveStreams.vacc)
    ellipsoidalAltitude = core.latest(LiveStreams.altitude)
    speed = core.latest(LiveStreams.speed)
    trueHeading = core.latest(LiveStreams.headingTrue)
    magneticHeading = core.latest(LiveStreams.headingMagnetic)
    let newest = core.stream(LiveStreams.hacc.id)?.ring.latest?.time
    fixAge = newest.map { SignalClock.now() - $0 }
    core.refreshRate(from: LiveStreams.hacc)
    if let h = horizontalAccuracy {
      core.primaryReadout = "±\(SpectraFormat.significant(h, 2)) m" + (ellipsoidalAltitude.map { " · \(liveWhole($0)) m" } ?? "")
    } else {
      core.primaryReadout = "Waiting for a fix"
    }
  }

  /// A fix arrived in the last 10 s.
  var hasFix: Bool { (fixAge ?? .infinity) < 10 }

  var markers: [SpectrumMarker] {
    guard core.state == .running, hasFix else { return [] }
    let p: Provenance = core.simulated ? .sim : .live
    return [
      SpectrumMarker(id: "live.gps.l1", label: "GPS L1 1575.42 MHz", frequency: RadioMaps.gpsL1, provenance: p, tab: .live),
      SpectrumMarker(id: "live.gps.l5", label: "GPS L5 1176.45 MHz", frequency: RadioMaps.gpsL5, provenance: p, tab: .live),
    ]
  }

  var capabilities: [CapabilityFlag] {
    [
      CapabilityFlag(
        "Location services", servicesEnabled.map { $0 ? .yes : .no } ?? .unknown, source: "CLLocationManager.locationServicesEnabled"),
      CapabilityFlag("Heading", CLLocationManager.headingAvailable(), source: "CLLocationManager.headingAvailable"),
      CapabilityFlag("Authorization", .text(Self.describe(authorization)), source: "CLLocationManager.authorizationStatus"),
      CapabilityFlag("Precise location", accuracyLimited ? .no : (horizontalAccuracy == nil ? .unknown : .yes), source: "CLLocationUpdate.accuracyLimited"),
      CapabilityFlag("Satellite count or SNR", .text("Not exposed by any public API"), source: "CoreLocation headers"),
    ]
  }

  private static func describe(_ a: CLAuthorizationStatus) -> String {
    switch a {
    case .authorizedAlways, .authorizedWhenInUse: "Allowed while in use"
    case .denied: "Denied"
    case .restricted: "Restricted"
    default: "Not asked yet"
    }
  }
}
