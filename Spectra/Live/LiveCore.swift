import Foundation
import Observation
import Synchronization

/// What every channel shares: the stream bus, launch options, the simulated world, the one
/// `CMMotionManager`, and whether simulation is forced (Settings → Sensors, DEBUG).
@MainActor
final class LiveContext {
  let registry: StreamRegistry
  let launch: LaunchOptions
  let world = SimWorld()
  let motion: MotionHardware
  /// The Live tab's persisted knobs and assumptions.
  let settings: LiveSettings
  /// Settings → Sensors → Simulated sensors = Always (DEBUG builds only).
  var simulationAlways = false

  init(registry: StreamRegistry, launch: LaunchOptions) {
    self.registry = registry
    self.launch = launch
    motion = MotionHardware()
    settings = LiveSettings(launch: launch)
  }

  /// Whether `sensor` runs simulated: a `-fake…` argument, Settings → Always, or (DEBUG only)
  /// hardware that does not exist here, such as the Simulator. Release builds never simulate.
  func simulates(_ sensor: SensorID, hardwareAvailable: Bool) -> Bool {
    #if DEBUG
      if launch.isFaked(sensor) || simulationAlways { return true }
      return !hardwareAvailable
    #else
      return false
    #endif
  }

  /// The simulated pose every fake shares (`-simPose`, the sway, or the turntable).
  var pose: SimPose { SimPose(fixed: launch.simPose, world: world) }

  /// Deterministic seed per sensor (`-seed N`).
  func seed(for sensor: SensorID) -> UInt64 {
    (launch.seed ?? 7) &+ UInt64(SensorID.allCases.firstIndex(of: sensor) ?? 0) &* 0x9E37
  }
}

/// The observable bookkeeping every channel needs: state, provenance, its published streams,
/// the measured rate and headline reading, plus the simulated-generator task.
@Observable @MainActor
final class ChannelCore {
  let id: SensorID
  let context: LiveContext
  var state: SensorState = .idle
  var provenance: Provenance
  private(set) var streams: [SignalStream] = []
  var measuredRate: Double?
  var primaryReadout: String?
  /// True while the channel runs on simulated data.
  private(set) var simulated = false
  @ObservationIgnored private var simTask: Task<Void, Never>?

  init(id: SensorID, context: LiveContext, provenance: Provenance = .live) {
    self.id = id
    self.context = context
    self.provenance = provenance
  }

  var registry: StreamRegistry { context.registry }
  var group: String { id.streamGroup }

  /// Decides LIVE or SIM for the run about to start (before any stream is made, so the
  /// streams carry the right badge).
  func prepare(simulated: Bool) {
    self.simulated = simulated
    provenance = simulated ? .sim : .live
  }

  /// A stream for `spec` with this channel's provenance and group.
  func make(_ spec: LiveStreamSpec, rate: Double? = nil, capacity: Int? = nil) -> SignalStream {
    spec.make(provenance: simulated ? .sim : .live, group: group, rate: rate, capacity: capacity)
  }

  func make(_ specs: [LiveStreamSpec], rate: Double? = nil) -> [SignalStream] { specs.map { make($0, rate: rate) } }

  /// Registers streams on the bus (in one observation change).
  func publish(_ list: [SignalStream]) {
    guard !list.isEmpty else { return }
    let ids = Set(list.map(\.id))
    streams = streams.filter { !ids.contains($0.id) } + list
    registry.register(list)
  }

  /// Removes some of this channel's streams from the bus.
  func withdraw(_ list: [SignalStream]) {
    guard !list.isEmpty else { return }
    for s in list { registry.unregister(s) }
    streams.removeAll { s in list.contains { $0 === s } }
  }

  /// Removes every stream this channel published.
  func withdrawAll() {
    for s in streams { registry.unregister(s) }
    streams = []
  }

  func stream(_ id: StreamID) -> SignalStream? { streams.first { $0.id == id } }

  /// Runs a simulated source: the generator emits every sample due on a background task
  /// (every 20 ms), each at its own timestamp, so FFTs and aliasing behave as on the device.
  func runSimulation(_ generator: any SimGenerator) {
    simTask?.cancel()
    simTask = Task.detached(priority: .userInitiated) {
      var generator = generator
      while !Task.isCancelled {
        generator.produce(until: SignalClock.now())
        try? await Task.sleep(for: .milliseconds(20))
      }
    }
  }

  func stopSimulation() {
    simTask?.cancel()
    simTask = nil
  }

  /// Everything off: generator, streams, rate and readout.
  func reset(to next: SensorState = .idle) {
    stopSimulation()
    withdrawAll()
    measuredRate = nil
    primaryReadout = nil
    simulated = false
    state = next
  }

  /// Rate of `spec`'s stream (or the first regular stream), from its timestamps.
  func refreshRate(from spec: LiveStreamSpec? = nil) {
    let s = spec.flatMap { stream($0.id) } ?? streams.first { !$0.isIrregular }
    // Slow streams (battery at 0.2 Hz) need a window that holds a few samples.
    measuredRate = s.flatMap { $0.ring.measuredRate(window: $0.nominalRate > 0 ? max(2, 3 / $0.nominalRate) : 2) }
  }

  /// The newest value of a published stream.
  func latest(_ spec: LiveStreamSpec) -> Double? {
    stream(spec.id)?.ring.latest.map { Double($0.value) }
  }
}

/// A channel the hub can refresh: readouts, rates and dynamic streams are pulled from the
/// sensor boxes about twice a second, never per sample.
@MainActor
protocol LiveSource: SensorChannel {
  var core: ChannelCore { get }
  /// Pulls the newest readings into observable properties (called at about 2 Hz while running).
  func refresh()
  /// Capability flags for the Sensor census (`sdk-sensors.md` §7).
  var capabilities: [CapabilityFlag] { get }
  /// True when starting shows no system prompt (no permission needed, already granted, or
  /// simulated), so a card may start it as soon as it scrolls into view.
  var startsSilently: Bool { get }
}

extension LiveSource {
  var id: SensorID { core.id }
  var provenance: Provenance { core.provenance }
  var state: SensorState { core.state }
  var measuredRate: Double? { core.measuredRate }
  var streams: [SignalStream] { core.streams }
  var primaryReadout: String? { core.primaryReadout }
  var isSimulated: Bool { core.simulated }
}

/// A reading rounded to a whole number, with the typographic minus the rest of the app's
/// readouts use ("−52 dBm", not "-52 dBm"; `SpectraFormat` does the same for decimals).
nonisolated func liveWhole(_ x: Double) -> String {
  guard x.isFinite else { return "—" }
  let n = Int(x.rounded())
  return n < 0 ? "−\(-n)" : "\(n)"
}

/// One line of the Sensor census: a capability and what this phone answered.
nonisolated struct CapabilityFlag: Hashable, Sendable, Identifiable {
  enum Value: Hashable, Sendable {
    case yes, no, unknown
    case text(String)
  }

  let name: String
  let value: Value
  /// Where the answer comes from ("CMMotionManager.isMagnetometerAvailable").
  var source: String = ""

  var id: String { name }

  init(_ name: String, _ value: Value, source: String = "") {
    self.name = name
    self.value = value
    self.source = source
  }

  init(_ name: String, _ flag: Bool, source: String = "") {
    self.init(name, flag ? .yes : .no, source: source)
  }

  var text: String {
    switch value {
    case .yes: "Yes"
    case .no: "No"
    case .unknown: "Not yet measured"
    case .text(let t): t
    }
  }
}
