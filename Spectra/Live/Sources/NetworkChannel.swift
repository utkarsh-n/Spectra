import CoreTelephony
import Foundation
import Network
import Observation
import Synchronization

/// Round-trip time to the network, measured without sending any data: a TCP handshake to
/// Apple's connectivity-check host (`captive.apple.com`, port 80, the host iOS itself uses to
/// detect captive portals), closed as soon as it is ready. The SYN/SYN-ACK time comes from
/// the connection's establishment report; the data-transfer report names the radio that
/// carried it (`PathReport.radioType`: Wi-Fi a…ax, LTE, 5G NSA/SA, sub-6 or mmWave). No
/// request is made and nothing is sent beyond the handshake (privacy note in the field notes).
nonisolated enum RTTProbe {
  static let host = "captive.apple.com"
  static let port: NWEndpoint.Port = 80

  struct Result: Sendable, Equatable {
    /// Handshake round trip (s).
    var rtt: Double?
    /// `RadioMaps.dataPath` code ("wifi.ax", "cell.nsa.sub6", …).
    var dataPath: String?
    /// "wifi", "cellular", "wired", "other".
    var interface: String?
  }

  static func measure(timeout: Double = 3) async -> Result {
    await withCheckedContinuation { (continuation: CheckedContinuation<Result, Never>) in
      let queue = DispatchQueue(label: "Spectra.rtt")
      let connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: .tcp)
      let done = Mutex(false)
      let started = SignalClock.now()
      let pending = connection.startDataTransferReport()
      @Sendable func finish(_ result: Result) {
        let first = done.withLock { flag in
          defer { flag = true }
          return !flag
        }
        guard first else { return }
        connection.cancel()
        continuation.resume(returning: result)
      }
      connection.stateUpdateHandler = { state in
        switch state {
        case .ready:
          let ready = SignalClock.now() - started
          connection.requestEstablishmentReport(queue: queue) { report in
            let handshake = report?.handshakes.map(\.handshakeRTT).first { $0 > 0 }
            pending.collect(queue: queue) { transfer in
              let path = transfer.pathReports.first
              finish(
                Result(
                  rtt: handshake ?? ready, dataPath: path?.radioType.map(code),
                  interface: path.map { describe($0.interface.type) }))
            }
          }
        case .failed, .cancelled, .waiting:
          finish(Result())
        default:
          break
        }
      }
      connection.start(queue: queue)
      queue.asyncAfter(deadline: .now() + timeout) { finish(Result()) }
    }
  }

  static func code(_ radio: NWInterface.RadioType) -> String {
    switch radio {
    case .wifi(let w):
      switch w {
      case .a: return "wifi.a"
      case .b: return "wifi.b"
      case .g: return "wifi.g"
      case .n: return "wifi.n"
      case .ac: return "wifi.ac"
      case .ax: return "wifi.ax"
      @unknown default: return "wifi"
      }
    case .cell(let c):
      switch c {
      case .lte: return "cell.lte"
      case .dualConnectivity5G(let v): return "cell.nsa." + (v == .mmWave ? "mmwave" : "sub6")
      case .standalone5G(let v): return "cell.sa." + (v == .mmWave ? "mmwave" : "sub6")
      case .wcdma: return "cell.wcdma"
      case .gsm: return "cell.gsm"
      case .cdma: return "cell.cdma"
      case .evdo: return "cell.evdo"
      @unknown default: return "cell"
      }
    @unknown default:
      return "other"
    }
  }

  static func describe(_ type: NWInterface.InterfaceType) -> String {
    switch type {
    case .wifi: "wifi"
    case .cellular: "cellular"
    case .wiredEthernet: "wired"
    case .loopback: "loopback"
    default: "other"
    }
  }
}

/// Cellular and Wi-Fi: the radio access technology per SIM (CoreTelephony, iOS 27 typed
/// change messages), the path's interface and `linkQuality` (iOS 26), the data path's radio
/// type and the handshake RTT. No public API gives cellular or Wi-Fi dBm.
@Observable @MainActor
final class NetworkChannel: LiveSource {
  let core: ChannelCore
  /// "Wi-Fi", "Cellular", "Wired", "No network".
  private(set) var interface = "—"
  /// `NWPath.linkQuality`: 0 unknown, 1 minimal, 2 moderate, 3 good.
  private(set) var quality = 0
  private(set) var isExpensive = false
  private(set) var isConstrained = false
  private(set) var isUltraConstrained = false
  /// RAT per cellular service (SIM line), as CoreTelephony names it.
  private(set) var technologies: [String: String] = [:]
  /// The line that carries data.
  private(set) var dataService: String?
  /// The data path's radio from the last handshake.
  private(set) var dataPath: RadioMaps.DataPath?
  /// Last handshake round trip (ms).
  private(set) var rtt: Double?
  /// Whether `linkQuality` / `radioType` have ever been populated (census).
  private(set) var sawLinkQuality = false
  private(set) var sawRadioType = false
  @ObservationIgnored private var monitor: NWPathMonitor?
  @ObservationIgnored private var probeTask: Task<Void, Never>?
  @ObservationIgnored private var ratToken: NotificationCenter.ObservationToken?
  /// Created only for a real run (the Simulator has no telephony service).
  @ObservationIgnored private var telephony: CTTelephonyNetworkInfo?
  @ObservationIgnored private var fake: NetworkFake?
  @ObservationIgnored private var fakeStart = 0.0

  init(context: LiveContext) {
    core = ChannelCore(id: .network, context: context)
    core.provenance = context.simulates(.network, hardwareAvailable: true) ? .sim : .live
  }

  var startsSilently: Bool { true }

  func start() async {
    guard core.state != .running else { return }
    let sim = core.context.simulates(.network, hardwareAvailable: true)
    core.prepare(simulated: sim)
    let rttStream = core.make(LiveStreams.rtt)
    let qualityStream = core.make(LiveStreams.quality)
    core.publish([rttStream, qualityStream])
    core.state = .running
    if sim {
      let launch = core.context.launch
      let fake = NetworkFake(technologies: launch.fakeCell ?? [], wifi: launch.fakeWiFi)
      self.fake = fake
      let t0 = SignalClock.now()
      fakeStart = t0
      let seed = core.context.seed(for: .network)
      core.runSimulation(
        GeneratorGroup(members: [
          SlowGenerator(
            stream: rttStream, t0: t0, grid: SampleGrid(rate: 1, start: t0, seed: seed), rng: SimRandom(seed: seed), walk: 35,
            value: { _, walk, rng in
              walk = min(60, max(20, walk + 3 * rng.gaussian()))
              return walk
            }),
          SlowGenerator(
            stream: qualityStream, t0: t0, grid: SampleGrid(rate: 1, start: t0, seed: seed &+ 1), rng: SimRandom(seed: seed &+ 1),
            walk: 0, value: { s, _, _ in Double(fake.quality(at: s)) }),
        ]))
    } else {
      let monitor = NWPathMonitor()
      let update: @MainActor @Sendable (NWPath) -> Void = { [weak self] path in self?.pathChanged(path) }
      monitor.pathUpdateHandler = { path in Task { @MainActor in update(path) } }
      monitor.start(queue: DispatchQueue(label: "Spectra.path"))
      self.monitor = monitor
      ratToken = NotificationCenter.default.addObserver(of: String.self, for: .radioAccessTechnologyDidChange) {
        [weak self] (_: CTTelephonyNetworkInfo.RadioAccessTechnologyDidChangeMessage) in
        Task { @MainActor in self?.readTechnologies() }
      }
      readTechnologies()
      probeTask = Task { [weak self] in
        while !Task.isCancelled {
          let result = await RTTProbe.measure()
          guard !Task.isCancelled, let self else { return }
          self.probed(result, rttStream: rttStream, qualityStream: qualityStream)
          try? await Task.sleep(for: .seconds(1))
        }
      }
    }
    refresh()
  }

  private func pathChanged(_ path: NWPath) {
    guard core.state == .running else { return }
    if path.status != .satisfied {
      interface = "No network"
    } else if path.usesInterfaceType(.wifi) {
      interface = "Wi-Fi"
    } else if path.usesInterfaceType(.cellular) {
      interface = "Cellular"
    } else if path.usesInterfaceType(.wiredEthernet) {
      interface = "Wired"
    } else {
      interface = "Other"
    }
    quality = Self.level(path.linkQuality)
    if quality > 0 { sawLinkQuality = true }
    isExpensive = path.isExpensive
    isConstrained = path.isConstrained
    isUltraConstrained = path.isUltraConstrained
  }

  private static func level(_ q: NWPath.LinkQuality) -> Int {
    switch q {
    case .minimal: 1
    case .moderate: 2
    case .good: 3
    default: 0
    }
  }

  private func readTechnologies() {
    let info = telephony ?? CTTelephonyNetworkInfo()
    telephony = info
    technologies = info.serviceCurrentRadioAccessTechnology ?? [:]
    dataService = info.dataServiceIdentifier
  }

  private func probed(_ result: RTTProbe.Result, rttStream: SignalStream, qualityStream: SignalStream) {
    guard core.state == .running else { return }
    let t = SignalClock.now()
    if let r = result.rtt {
      rtt = r * 1000
      rttStream.append(Float(r * 1000), at: t)
    }
    if let code = result.dataPath, let path = RadioMaps.dataPath(code) {
      dataPath = path
      sawRadioType = true
    }
    qualityStream.append(Float(quality), at: t)
    if let m = monitor { pathChanged(m.currentPath) }
  }

  func stop() {
    monitor?.cancel()
    monitor = nil
    probeTask?.cancel()
    probeTask = nil
    if let ratToken { NotificationCenter.default.removeObserver(ratToken) }
    ratToken = nil
    fake = nil
    telephony = nil
    rtt = nil
    dataPath = nil
    technologies = [:]
    dataService = nil
    interface = "—"
    quality = 0
    core.reset()
  }

  func refresh() {
    guard core.state == .running else { return }
    if let fake {
      let s = SignalClock.now() - fakeStart
      interface = fake.wifi ? "Wi-Fi" : "Cellular"
      quality = fake.quality(at: s)
      if let tech = fake.technology(at: s) { technologies = ["SIM 1": tech] }
      dataService = technologies.isEmpty ? nil : "SIM 1"
      dataPath = RadioMaps.dataPath(fake.dataPath(at: s))
      rtt = core.latest(LiveStreams.rtt)
      sawLinkQuality = true
      sawRadioType = true
    }
    core.measuredRate = core.stream(LiveStreams.rtt.id)?.measuredRate
    var parts: [String] = []
    if let dataPath { parts.append(dataPath.label) } else if let cell = cellular { parts.append(cell.label) } else { parts.append(interface) }
    if let rtt { parts.append("\(SpectraFormat.significant(rtt, 2)) ms") }
    core.primaryReadout = parts.joined(separator: " · ")
  }

  /// The data line's radio access technology, mapped to its Systems card.
  var cellular: RadioMaps.Cellular? {
    let key = dataService.flatMap { technologies[$0] != nil ? $0 : nil } ?? technologies.keys.sorted().first
    return key.flatMap { technologies[$0] }.map(RadioMaps.cellular)
  }

  /// Wi-Fi carries the data now.
  var onWiFi: Bool { dataPath?.isWiFi ?? (interface == "Wi-Fi") }

  var markers: [SpectrumMarker] {
    guard core.state == .running else { return [] }
    var out: [SpectrumMarker] = []
    let band = core.context.settings.prefs.wifiBand
    if onWiFi {
      out.append(
        SpectrumMarker(
          id: "live.wifi", label: "Wi-Fi, \(band.title) band assumed", frequency: band.frequency, provenance: .model, tab: .live))
    }
    if let cell = cellular, let system = RF.SystemsCatalog.system(id: dataPath.map { $0.isWiFi ? cell.systemID : $0.systemID } ?? cell.systemID) {
      out.append(
        SpectrumMarker(
          id: "live.cell", label: "\(cell.label) · typical \(system.name) band", frequency: system.carrier,
          provenance: core.simulated ? .sim : .inferred, tab: .live))
    }
    return out
  }

  var capabilities: [CapabilityFlag] {
    [
      CapabilityFlag("Link quality populated", sawLinkQuality ? .yes : (core.state == .running ? .no : .unknown), source: "NWPath.linkQuality (iOS 26)"),
      CapabilityFlag("Radio type populated", sawRadioType ? .yes : (core.state == .running ? .no : .unknown), source: "PathReport.radioType (iOS 15)"),
      CapabilityFlag(
        "Cellular lines", technologies.isEmpty ? .text("none reported") : .text(technologies.values.map { RadioMaps.cellular($0).label }.sorted().joined(separator: ", ")),
        source: "CTTelephonyNetworkInfo.serviceCurrentRadioAccessTechnology"),
      CapabilityFlag("Handshake RTT", rtt.map { .text("\(SpectraFormat.significant($0, 3)) ms") } ?? .unknown, source: "NWConnection establishment report"),
      CapabilityFlag("Wi-Fi name and dBm", .text("Locked: needs a paid team, and iOS never gives dBm"), source: "NEHotspotNetwork"),
    ]
  }
}
