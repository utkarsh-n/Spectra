import Foundation
import Observation

/// The Live tab's sources: one `SensorChannel` per `SensorID`, started on demand by whoever
/// shows them (a Live card, a Scope channel, a Patch node) and stopped when nobody does or
/// the app leaves the foreground.
///
/// Each channel runs the real sensor or radio where it exists and, in DEBUG builds, a
/// simulated stand-in (SIM) where it does not (the Simulator) or when a `-fake…` argument
/// asks for one (`gyre-integration.md` §8). Both write the same timestamped streams into
/// `AppModel.streams`. Public API unchanged from the foundation (`Docs/API.md` → Sensors,
/// additions in `Docs/API-live.md`).
///
/// ```swift
/// app.live.acquire(.magnetometer, by: "scope")          // starts it if needed
/// let x = app.streams.stream("mag.x")                    // read its ring
/// app.live.release(.magnetometer, by: "scope")           // stops when the last owner leaves
/// ```
@Observable @MainActor
final class SensorHub: TabModel {
  /// Where channels publish their streams (`AppModel.streams`).
  let streams: StreamRegistry
  let launch: LaunchOptions
  /// Shared by every channel: registry, motion manager, simulated world, Live preferences.
  let context: LiveContext

  let motion: MotionChannel
  let magnetometer: MagnetometerChannel
  let barometer: BarometerChannel
  let microphone: MicrophoneChannel
  let bluetooth: BluetoothChannel
  let network: NetworkChannel
  let location: LocationChannel
  let light: LightChannel
  let charging: ChargingChannel
  let uwb: UWBChannel
  let nfc: NFCChannel

  /// Every channel, in `SensorID.allCases` order.
  let channels: [any SensorChannel]
  /// The Live preferences (knobs and assumptions), persisted under `Spectra.live.v1`.
  var settings: LiveSettings { context.settings }
  /// A radio row of the antenna map the user asked to see on the strip.
  var highlightedRadio: RadioMaps.PhoneRadio?

  /// Which owners hold each sensor.
  private var owners: [SensorID: Set<String>] = [:]
  /// Sensors switched off in Settings → Sensors.
  private var disabled: Set<SensorID> = []
  private var active = true
  @ObservationIgnored private var refreshTask: Task<Void, Never>?

  init(streams: StreamRegistry, launch: LaunchOptions = .current) {
    self.streams = streams
    self.launch = launch
    let context = LiveContext(registry: streams, launch: launch)
    self.context = context
    motion = MotionChannel(context: context)
    magnetometer = MagnetometerChannel(context: context)
    barometer = BarometerChannel(context: context)
    microphone = MicrophoneChannel(context: context)
    bluetooth = BluetoothChannel(context: context)
    network = NetworkChannel(context: context)
    location = LocationChannel(context: context)
    light = LightChannel(context: context)
    charging = ChargingChannel(context: context)
    uwb = UWBChannel(context: context)
    nfc = NFCChannel(context: context)
    channels = [motion, magnetometer, barometer, microphone, bluetooth, network, location, light, charging, uwb, nfc]
    // The persisted analysis window applies from launch, not only after the chip is touched.
    magnetometer.fftCount = context.settings.prefs.magnetometerFFT
    for id in launch.startLive { acquire(id, by: "launch") }
    if launch.startMic { acquire(.microphone, by: "launch") }
  }

  /// The channel for `id`.
  func channel(_ id: SensorID) -> any SensorChannel { source(id) }

  /// The channel for `id` with its Live extras (capabilities, refresh, silent start).
  func source(_ id: SensorID) -> any LiveSource {
    switch id {
    case .motion: motion
    case .magnetometer: magnetometer
    case .barometer: barometer
    case .microphone: microphone
    case .bluetooth: bluetooth
    case .network: network
    case .location: location
    case .light: light
    case .charging: charging
    case .uwb: uwb
    case .nfc: nfc
    }
  }

  /// Starts `id` for `owner` (reference counted). Permission prompts happen inside the
  /// channel's `start()`, i.e. on the tap that led here.
  func acquire(_ id: SensorID, by owner: String) {
    var set = owners[id] ?? []
    let wasEmpty = set.isEmpty
    set.insert(owner)
    owners[id] = set
    if wasEmpty || !source(id).state.isRunning { startIfAllowed(id) }
  }

  /// Releases `owner`'s hold on `id`; the channel stops when nobody holds it.
  func release(_ id: SensorID, by owner: String) {
    guard var set = owners[id], set.remove(owner) != nil else { return }
    owners[id] = set
    if set.isEmpty { source(id).stop() }
    refreshLoop()
  }

  /// Releases everything `owner` holds.
  func releaseAll(by owner: String) {
    for id in SensorID.allCases where owners[id]?.contains(owner) == true { release(id, by: owner) }
  }

  /// Owners currently holding `id`.
  func holders(of id: SensorID) -> Set<String> { owners[id] ?? [] }

  /// Scene phase: inactive stops every channel (owners are kept); active restarts them.
  func setActive(_ isActive: Bool) {
    guard active != isActive else { return }
    active = isActive
    for id in SensorID.allCases where !(owners[id] ?? []).isEmpty {
      if isActive { startIfAllowed(id) } else { source(id).stop() }
    }
    if !isActive { settings.flush() }
    refreshLoop()
  }

  /// Applies Settings → Sensors (per-source switches and, in DEBUG, simulation Always).
  func apply(_ settings: AppSettings) {
    disabled = settings.disabledSensors
    let always = settings.simulation == .always
    let modeChanged = always != context.simulationAlways
    context.simulationAlways = always
    for id in SensorID.allCases {
      let channel = source(id)
      if disabled.contains(id) {
        channel.stop()
      } else if !(owners[id] ?? []).isEmpty {
        if modeChanged, channel.state.isRunning { channel.stop() }
        if !channel.state.isRunning { startIfAllowed(id) }
      }
    }
  }

  func isEnabled(_ id: SensorID) -> Bool { !disabled.contains(id) }

  /// Every running channel's markers (radios, mains hum, sound, …), plus a highlighted
  /// antenna-map row.
  var markers: [SpectrumMarker] {
    var out = channels.flatMap { $0.state.isRunning ? $0.markers : [] }
    if let r = highlightedRadio {
      out.append(
        SpectrumMarker(id: "live.antenna", label: "Your iPhone: \(r.title)", frequency: r.frequency, provenance: .table, tab: .live))
    }
    return out
  }

  /// Applies changed Live preferences to the running channels that use them.
  func preferencesChanged() {
    if light.applyPreferences() {
      // The camera switches side: stop, and start again only for whoever still holds it.
      light.stop()
      if !(owners[.light] ?? []).isEmpty { startIfAllowed(.light) }
    }
    charging.applyPreferences()
    magnetometer.fftCount = settings.prefs.magnetometerFFT
  }

  /// Starts or stops the simulated turntable (only the fakes turn; on a device you turn).
  func setSimulatedTurntable(_ on: Bool) { context.world.setTurntable(on) }

  private func startIfAllowed(_ id: SensorID) {
    guard active, !disabled.contains(id) else { return }
    let channel = source(id)
    Task {
      await channel.start()
      // Released (or backgrounded) while it was asking for permission: stop again.
      if (self.owners[id] ?? []).isEmpty || !self.active || self.disabled.contains(id) { channel.stop() }
      self.refreshLoop()
    }
    refreshLoop()
  }

  /// While anything runs, refresh measured rates and readouts at 2 Hz (never per frame).
  private func refreshLoop() {
    let busy = channels.contains { $0.state.isRunning || $0.state == .requesting } || owners.values.contains { !$0.isEmpty }
    if busy, active {
      guard refreshTask == nil else { return }
      refreshTask = Task { [weak self] in
        while !Task.isCancelled {
          try? await Task.sleep(for: .milliseconds(500))
          guard let self else { return }
          self.refreshAll()
        }
      }
    } else {
      refreshTask?.cancel()
      refreshTask = nil
    }
  }

  /// Pulls every running channel's newest readings now.
  func refreshAll() {
    for id in SensorID.allCases {
      let s = source(id)
      if s.state.isRunning || s.state == .requesting { s.refresh() }
    }
  }
}
