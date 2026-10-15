import Foundation
import Synchronization

/// Every Bluetooth LE advertiser heard recently, with one irregular RSSI stream each
/// (`ble.<uuid>.rssi`, dBm). Written from the scanner's queue (or the fake) per advert; the
/// main actor publishes new streams and drops quiet radios about twice a second. Identifiers
/// are the random per-app UUIDs iOS assigns; nothing is stored beyond this session.
nonisolated final class BLEDeviceTable: Sendable {
  struct Device: Sendable, Identifiable {
    let id: UUID
    var name: String?
    /// Advertised Tx power (dBm), when present.
    var txPower: Double?
    var connectable: Bool
    /// Apple manufacturer data (company 0x004C).
    var apple: Bool
    var firstSeen: Double
    var lastSeen: Double
    var lastRSSI: Double
    /// RSSI averaged over the last few adverts (exponential, α = 0.25): fading moves single
    /// adverts by ±5–10 dB, so the list order and the distance estimate use this.
    var averageRSSI: Double
    var adverts: Int
    let stream: SignalStream
  }

  /// Weight of the newest advert in `averageRSSI`.
  static let averaging = 0.25

  private let devices = Mutex<[UUID: Device]>([:])
  let provenance: Provenance
  /// Most radios tracked at once (the strongest are kept).
  static let capacity = 40

  init(provenance: Provenance) { self.provenance = provenance }

  /// Records one advertisement. RSSI 127 means "not available" and is ignored.
  func heard(id: UUID, rssi: Double, time: Double, name: String?, txPower: Double?, connectable: Bool, apple: Bool) {
    guard rssi.isFinite, rssi < 20, rssi > -127 else { return }
    devices.withLock { table in
      if var d = table[id] {
        d.lastSeen = time
        d.lastRSSI = rssi
        d.averageRSSI += Self.averaging * (rssi - d.averageRSSI)
        d.adverts += 1
        if let name, !name.isEmpty { d.name = name }
        if let txPower { d.txPower = txPower }
        d.apple = d.apple || apple
        d.connectable = connectable
        table[id] = d
        d.stream.append(Float(rssi), at: time)
        return
      }
      if table.count >= Self.capacity {
        // Make room by forgetting the weakest radio, unless this one is weaker still.
        guard let weakest = table.values.min(by: { $0.averageRSSI < $1.averageRSSI }), weakest.averageRSSI < rssi else { return }
        table[weakest.id] = nil
      }
      let label = (name?.isEmpty == false ? name! : Self.anonymousName(id: id, apple: apple)) + " RSSI"
      let stream = SignalStream(
        id: LiveStreams.bleRSSI(id), label: label, unit: "dBm", nominalRate: 0, provenance: provenance, isEM: true,
        lambda: SpectrumMarker.lambda(forFrequency: LiveStreams.bleCarrier), group: StreamGroup.bluetooth)
      stream.append(Float(rssi), at: time)
      table[id] = Device(
        id: id, name: name, txPower: txPower, connectable: connectable, apple: apple, firstSeen: time, lastSeen: time,
        lastRSSI: rssi, averageRSSI: rssi, adverts: 1, stream: stream)
    }
  }

  /// A readable stand-in for radios that do not advertise a name.
  static func anonymousName(id: UUID, apple: Bool) -> String {
    (apple ? "Apple device " : "Device ") + String(id.uuidString.prefix(4))
  }

  /// Every device, strongest (averaged RSSI) first, so the list does not reshuffle on every
  /// faded advert.
  func snapshot() -> [Device] {
    devices.withLock { Array($0.values) }.sorted {
      $0.averageRSSI == $1.averageRSSI ? $0.id.uuidString < $1.id.uuidString : $0.averageRSSI > $1.averageRSSI
    }
  }

  /// Forgets radios not heard for `quiet` seconds and returns their streams.
  func prune(quiet: Double, now: Double) -> [SignalStream] {
    devices.withLock { table in
      let gone = table.values.filter { now - $0.lastSeen > quiet }
      for d in gone { table[d.id] = nil }
      return gone.map(\.stream)
    }
  }

  func clear() { devices.withLock { $0.removeAll() } }
}
