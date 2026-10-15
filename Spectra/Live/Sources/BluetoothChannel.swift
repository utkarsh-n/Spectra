import CoreBluetooth
import Foundation
import Observation
import Synchronization

/// The CoreBluetooth central, scanning with duplicates so every advert arrives with its RSSI.
/// Its delegate runs on a private queue and writes straight into the table; state changes hop
/// to the main actor.
nonisolated final class BLEScanner: NSObject, CBCentralManagerDelegate, @unchecked Sendable {
  // `central` is created and used only on `queue` (CoreBluetooth calls the delegate there).
  private let queue = DispatchQueue(label: "Spectra.ble", qos: .userInitiated)
  private var central: CBCentralManager?
  private let table: BLEDeviceTable
  private let onState: @MainActor @Sendable (CBManagerState) -> Void

  init(table: BLEDeviceTable, onState: @escaping @MainActor @Sendable (CBManagerState) -> Void) {
    self.table = table
    self.onState = onState
    super.init()
  }

  func start() {
    queue.async {
      guard self.central == nil else { return }
      self.central = CBCentralManager(
        delegate: self, queue: self.queue, options: [CBCentralManagerOptionShowPowerAlertKey: false])
    }
  }

  func stop() {
    queue.async {
      self.central?.stopScan()
      self.central?.delegate = nil
      self.central = nil
    }
  }

  func centralManagerDidUpdateState(_ central: CBCentralManager) {
    let state = central.state
    if state == .poweredOn {
      central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
    }
    let onState = onState
    Task { @MainActor in onState(state) }
  }

  func centralManager(
    _ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any],
    rssi RSSI: NSNumber
  ) {
    let t = SignalClock.now()
    var apple = false
    if let data = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data, data.count >= 2 {
      apple = data[data.startIndex] == 0x4C && data[data.startIndex + 1] == 0x00
    }
    let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name
    let tx = (advertisementData[CBAdvertisementDataTxPowerLevelKey] as? NSNumber)?.doubleValue
    let connectable = (advertisementData[CBAdvertisementDataIsConnectable] as? NSNumber)?.boolValue ?? false
    table.heard(
      id: peripheral.identifier, rssi: RSSI.doubleValue, time: t, name: name, txPower: tx, connectable: connectable,
      apple: apple)
  }
}

/// Bluetooth LE: per-advert RSSI (dBm) of every nearby advertiser, Tx power and names when
/// advertised, published as one stream per device. The phone's only true live RF power
/// reading (`sdk-sensors.md` §4.3).
@Observable @MainActor
final class BluetoothChannel: LiveSource {
  let core: ChannelCore
  /// Radios heard in the last 30 s, strongest first (refreshed at 2 Hz).
  private(set) var devices: [BLEDeviceTable.Device] = []
  /// Advertisements per second across all radios.
  private(set) var advertRate: Double?
  /// The CoreBluetooth state, for the census.
  private(set) var managerState: CBManagerState = .unknown
  @ObservationIgnored private var table: BLEDeviceTable?
  @ObservationIgnored private var scanner: BLEScanner?
  @ObservationIgnored private var lastCount = 0
  @ObservationIgnored private var lastCountTime = 0.0

  /// Radios unheard for this long leave the list and the bus.
  static let quietSeconds = 30.0

  init(context: LiveContext) {
    core = ChannelCore(id: .bluetooth, context: context)
    core.provenance = context.simulates(.bluetooth, hardwareAvailable: Self.hardwareAvailable) ? .sim : .live
  }

  var startsSilently: Bool {
    core.context.simulates(.bluetooth, hardwareAvailable: Self.hardwareAvailable) || CBManager.authorization == .allowedAlways
  }

  /// The Simulator reports `.unsupported`; on a device the radio exists.
  private static var hardwareAvailable: Bool {
    #if targetEnvironment(simulator)
      false
    #else
      true
    #endif
  }

  func start() async {
    guard core.state != .running, core.state != .requesting else { return }
    let sim = core.context.simulates(.bluetooth, hardwareAvailable: Self.hardwareAvailable)
    if !sim {
      switch CBManager.authorization {
      case .denied, .restricted:
        core.state = .denied
        return
      default: break
      }
    }
    core.prepare(simulated: sim)
    let table = BLEDeviceTable(provenance: sim ? .sim : .live)
    self.table = table
    lastCount = 0
    lastCountTime = SignalClock.now()
    if sim {
      let t0 = SignalClock.now()
      let seed = core.context.seed(for: .bluetooth)
      let count = max(1, core.context.launch.fakeBLE ?? 6)
      core.runSimulation(
        BluetoothGenerator(
          table: table, beacons: BluetoothGenerator.room(count: count, start: t0, seed: seed), pose: core.context.pose,
          rng: SimRandom(seed: seed)))
      core.state = .running
    } else {
      core.state = CBManager.authorization == .allowedAlways ? .running : .requesting
      let scanner = BLEScanner(table: table) { [weak self] state in self?.managerChanged(state) }
      self.scanner = scanner
      scanner.start()
    }
    refresh()
  }

  private func managerChanged(_ state: CBManagerState) {
    managerState = state
    guard scanner != nil else { return }
    switch state {
    case .poweredOn:
      core.state = .running
    case .unauthorized:
      shutDown(to: .denied)
    case .poweredOff:
      shutDown(to: .unavailable("Bluetooth is turned off in Control Center or Settings."))
    case .unsupported:
      shutDown(to: .unavailable("This device does not support Bluetooth LE scanning."))
    default:
      break
    }
  }

  private func shutDown(to next: SensorState) {
    scanner?.stop()
    scanner = nil
    table?.clear()
    table = nil
    devices = []
    advertRate = nil
    core.reset(to: next)
  }

  func stop() { shutDown(to: .idle) }

  func refresh() {
    guard core.state == .running, let table else { return }
    let now = SignalClock.now()
    let gone = table.prune(quiet: Self.quietSeconds, now: now)
    core.withdraw(gone)
    let list = table.snapshot()
    // Radios evicted to make room (the table keeps the strongest 40) leave the bus too.
    let current = Set(list.map { ObjectIdentifier($0.stream) })
    core.withdraw(core.streams.filter { !current.contains(ObjectIdentifier($0)) })
    let published = Set(core.streams.map { ObjectIdentifier($0) })
    let fresh = list.map(\.stream).filter { !published.contains(ObjectIdentifier($0)) }
    core.publish(fresh)
    devices = list
    let total = list.reduce(0) { $0 + $1.adverts }
    if now - lastCountTime >= 1 {
      advertRate = Double(max(0, total - lastCount)) / (now - lastCountTime)
      lastCount = total
      lastCountTime = now
    }
    core.measuredRate = nil  // event-driven
    if let strongest = list.first {
      core.primaryReadout = "\(list.count) radio\(list.count == 1 ? "" : "s") · \(liveWhole(strongest.lastRSSI)) dBm"
    } else {
      core.primaryReadout = "Listening…"
    }
  }

  var markers: [SpectrumMarker] {
    guard core.state == .running else { return [] }
    return [
      SpectrumMarker(
        id: "live.ble", label: "Bluetooth LE 2.44 GHz", frequency: LiveStreams.bleCarrier,
        provenance: core.simulated ? .sim : .live, tab: .live)
    ]
  }

  var capabilities: [CapabilityFlag] {
    [
      CapabilityFlag("Authorization", .text(Self.describe(CBManager.authorization)), source: "CBManager.authorization"),
      CapabilityFlag("Manager state", .text(Self.describe(managerState)), source: "CBCentralManager.state"),
      CapabilityFlag("Extended scan", CBCentralManager.supports(.extendedScanAndConnect), source: "CBCentralManager.supports"),
      CapabilityFlag("Channel Sounding (iOS 27)", CBCentralManager.supports(.channelSounding), source: "CBCentralManager.supports"),
      CapabilityFlag(
        "Adverts per second", advertRate.map { .text(SpectraFormat.significant($0, 3) + (core.simulated ? " (SIM)" : "")) } ?? .unknown,
        source: "didDiscover with AllowDuplicates"),
    ]
  }

  private static func describe(_ a: CBManagerAuthorization) -> String {
    switch a {
    case .allowedAlways: "Allowed"
    case .denied: "Denied"
    case .restricted: "Restricted"
    default: "Not asked yet"
    }
  }

  private static func describe(_ s: CBManagerState) -> String {
    switch s {
    case .poweredOn: "On"
    case .poweredOff: "Off"
    case .unauthorized: "Not allowed"
    case .unsupported: "Unsupported"
    case .resetting: "Resetting"
    default: "Unknown"
    }
  }
}
