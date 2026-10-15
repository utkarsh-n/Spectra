import Foundation

/// What the radios report, mapped onto the RF engine's systems catalog (TABLE) so a live
/// reading lands on the right Systems card and the right place on the spectrum.
nonisolated enum RadioMaps {
  // MARK: Cellular

  /// One radio access technology as CoreTelephony names it.
  struct Cellular: Hashable, Sendable {
    /// "5G NR NSA", "LTE".
    var label: String
    /// "5G", "4G".
    var generation: String
    /// `RF.SystemsCatalog` id of the matching card.
    var systemID: String
  }

  /// Maps a `CTRadioAccessTechnology…` string (iOS 27: GPRS, Edge, WCDMA, HSDPA, HSUPA,
  /// CDMA1x, CDMAEVDORev0/A/B, eHRPD, LTE, NRNSA, NR) to its generation and Systems card.
  static func cellular(_ technology: String) -> Cellular {
    let t = technology.replacingOccurrences(of: "CTRadioAccessTechnology", with: "")
    switch t.lowercased() {
    case "nrnsa", "nsa": return Cellular(label: "5G NR NSA", generation: "5G", systemID: "nr-fr1")
    case "nr", "sa": return Cellular(label: "5G NR", generation: "5G", systemID: "nr-fr1")
    case "mmwave": return Cellular(label: "5G NR mmWave", generation: "5G", systemID: "nr-fr2")
    case "lte": return Cellular(label: "LTE", generation: "4G", systemID: "lte")
    case "wcdma", "hsdpa", "hsupa": return Cellular(label: t.uppercased() == "WCDMA" ? "UMTS" : t.uppercased(), generation: "3G", systemID: "umts")
    case "cdma1x", "cdmaevdorev0", "cdmaevdoreva", "cdmaevdorevb", "ehrpd": return Cellular(label: "CDMA", generation: "3G", systemID: "is95")
    case "edge": return Cellular(label: "EDGE", generation: "2.75G", systemID: "edge")
    case "gprs": return Cellular(label: "GPRS", generation: "2.5G", systemID: "gsm")
    default: return Cellular(label: t.isEmpty ? "Cellular" : t, generation: "—", systemID: "lte")
    }
  }

  /// The data path's radio as the Network framework reports it (`PathReport.radioType`),
  /// already reduced to a string by the source: "wifi.ax", "cell.lte", "cell.nsa.sub6",
  /// "cell.sa.mmwave", …
  struct DataPath: Hashable, Sendable {
    var label: String
    var systemID: String
    var isWiFi: Bool
  }

  static func dataPath(_ code: String) -> DataPath? {
    let parts = code.split(separator: ".").map(String.init)
    guard let kind = parts.first else { return nil }
    if kind == "wifi" {
      let std = parts.count > 1 ? parts[1] : ""
      switch std {
      case "ax": return DataPath(label: "Wi-Fi 6 (802.11ax)", systemID: "wifi-ax", isWiFi: true)
      case "ac": return DataPath(label: "Wi-Fi 5 (802.11ac)", systemID: "wifi-ac", isWiFi: true)
      case "n": return DataPath(label: "Wi-Fi 4 (802.11n)", systemID: "wifi-n", isWiFi: true)
      case "g": return DataPath(label: "802.11g", systemID: "wifi-g", isWiFi: true)
      case "a": return DataPath(label: "802.11a", systemID: "wifi-a", isWiFi: true)
      case "b": return DataPath(label: "802.11b", systemID: "wifi-b", isWiFi: true)
      default: return DataPath(label: "Wi-Fi", systemID: "wifi-ax", isWiFi: true)
      }
    }
    guard kind == "cell", parts.count > 1 else { return nil }
    let mmWave = parts.last == "mmwave"
    switch parts[1] {
    case "nsa": return DataPath(label: "5G NR NSA · \(mmWave ? "mmWave" : "sub-6 GHz")", systemID: mmWave ? "nr-fr2" : "nr-fr1", isWiFi: false)
    case "sa": return DataPath(label: "5G NR SA · \(mmWave ? "mmWave" : "sub-6 GHz")", systemID: mmWave ? "nr-fr2" : "nr-fr1", isWiFi: false)
    case "lte": return DataPath(label: "LTE", systemID: "lte", isWiFi: false)
    case "wcdma": return DataPath(label: "UMTS", systemID: "umts", isWiFi: false)
    case "gsm": return DataPath(label: "GSM", systemID: "gsm", isWiFi: false)
    case "cdma", "evdo": return DataPath(label: "CDMA", systemID: "is95", isWiFi: false)
    default: return DataPath(label: "Cellular", systemID: "lte", isWiFi: false)
    }
  }

  /// The Wi-Fi band the user assumes (iOS does not say which band the phone is on; 6E still
  /// reports 802.11ax). MODEL.
  enum WiFiBand: String, CaseIterable, Identifiable, Sendable, Codable {
    case ghz24, ghz5, ghz6
    var id: String { rawValue }
    var title: String {
      switch self {
      case .ghz24: "2.4 GHz"
      case .ghz5: "5 GHz"
      case .ghz6: "6 GHz"
      }
    }
    /// Band centre (Hz) from the catalog's Wi-Fi allocations.
    var frequency: Double {
      switch self {
      case .ghz24: 2.437e9
      case .ghz5: 5.5e9
      case .ghz6: 6.525e9
      }
    }
  }

  // MARK: Bluetooth

  /// BLE advertising band centre (Hz).
  static let bleCarrier = 2.44e9

  /// Free-space loss at 1 m and 2.44 GHz (dB), from the RF engine (40.2 dB).
  static var bleLossAt1m: Double { RF.Propagation.fsplDB(distance: 1, frequency: bleCarrier) }

  /// Distance (m) from an RSSI with the log-distance model: RSSI(1 m) = Tx − FSPL(1 m), and
  /// d = 10^((RSSI₁ₘ − RSSI)/(10n)). Tx defaults to 0 dBm when the radio does not advertise
  /// it (an assumption, MODEL). n = 2 in free space, 2.7–4 indoors.
  static func bleDistance(rssi: Double, txPower: Double?, exponent n: Double) -> Double {
    RF.Propagation.distanceFromRSSI(rssiDBm: rssi, rssiAt1mDBm: (txPower ?? 0) - bleLossAt1m, exponent: max(n, 0.5))
  }

  /// The three BLE primary advertising channels (MHz) from the RF engine's numerology.
  static var advertisingChannelsMHz: [Double] { RF.Numerology.Bluetooth.advertisingChannels.map(\.mhz) }

  // MARK: Satellites

  /// GPS L1 and L5 carriers (Hz), 154 f₀ and 115 f₀ (RF engine).
  static var gpsL1: Double { RF.Numerology.GPS.l1 }
  static var gpsL5: Double { RF.Numerology.GPS.l5 }
  /// Nominal GPS orbit distance used by the card (m), 20 200 km (RF engine).
  static var gpsAltitude: Double { RF.Numerology.GPS.orbitDistance }
  /// Minimum received L1 C/A power (dBm): −158.5 dBW = −128.5 dBm (RF engine, IS-GPS-200).
  static var gpsMinimumPowerDBm: Double { RF.Numerology.GPS.l1MinimumPowerDBW + 30 }

  // MARK: Your iPhone's antennas

  /// One radio of the iPhone 15 Pro Max, with where its antennas sit on a schematic outline
  /// (normalised 0…1, x right, y down; general placement, MODEL, not a teardown).
  struct PhoneRadio: Hashable, Sendable, Identifiable {
    var id: String
    var title: String
    /// Bands in plain words.
    var bands: String
    /// `RF.SystemsCatalog` id (TABLE) for the carrier, when there is one.
    var systemID: String?
    /// Representative frequency (Hz) for the strip marker.
    var frequency: Double
    /// Segments on the outline: (x0, y0, x1, y1) in 0…1.
    var segments: [SIMD4<Double>]
    /// A point feature (coil or module): centre and radius in 0…1 widths.
    var spot: SIMD3<Double>?
    /// Model note ("US model A2849 only").
    var note: String
  }

  /// The radios in SPEC-features §3 card 1. Frequencies come from the RF catalog where it
  /// has the system; Qi from its numerology.
  static var phoneRadios: [PhoneRadio] {
    func carrier(_ id: String, _ fallback: Double) -> Double { RF.SystemsCatalog.system(id: id)?.carrier ?? fallback }
    return [
      PhoneRadio(
        id: "cellular", title: "Cellular LTE / 5G FR1", bands: "600 MHz – 6 GHz, 4×4 MIMO", systemID: "nr-fr1",
        frequency: carrier("nr-fr1", 3.5e9),
        segments: [SIMD4(0, 0.86, 0, 1), SIMD4(0, 1, 0.3, 1), SIMD4(0.7, 1, 1, 1), SIMD4(1, 0.86, 1, 1), SIMD4(0, 0, 0, 0.1), SIMD4(1, 0, 1, 0.12)],
        spot: nil, note: "Main and diversity antennas use slots in the titanium rails at the corners."),
      PhoneRadio(
        id: "mmwave", title: "5G mmWave (FR2)", bands: "n258 26 GHz, n261 28 GHz, n260 39 GHz", systemID: "nr-fr2",
        frequency: carrier("nr-fr2", 28e9), segments: [SIMD4(1, 0.42, 1, 0.52)], spot: nil,
        note: "US model A2849 only: a window in the right rail plus internal modules."),
      PhoneRadio(
        id: "wifi", title: "Wi-Fi 6E", bands: "2.4, 5 and 6 GHz", systemID: "wifi-6e", frequency: carrier("wifi-6e", 6e9),
        segments: [SIMD4(0.55, 0, 1, 0)], spot: nil, note: "Shares the top rail with Bluetooth."),
      PhoneRadio(
        id: "bluetooth", title: "Bluetooth 5.3", bands: "2402 – 2480 MHz", systemID: "ble", frequency: carrier("ble", bleCarrier),
        segments: [SIMD4(0.55, 0, 1, 0)], spot: nil, note: "The Live tab reads BLE advertisements."),
      PhoneRadio(
        id: "gnss", title: "GPS L1 + L5", bands: "1575.42 and 1176.45 MHz", systemID: "gps-l1", frequency: gpsL1,
        segments: [SIMD4(0, 0.1, 0, 0.3)], spot: nil, note: "Dual-frequency GNSS (GPS, Galileo, BeiDou, GLONASS, QZSS, NavIC)."),
      PhoneRadio(
        id: "uwb", title: "Ultra wideband", bands: "Channels 5 and 9 (6.5 / 8 GHz)", systemID: "uwb-ch9",
        frequency: carrier("uwb-ch9", 7987.2e6), segments: [], spot: SIMD3(0.24, 0.12, 0.05),
        note: "Second-generation UWB chip near the cameras."),
      PhoneRadio(
        id: "nfc", title: "NFC", bands: "13.56 MHz", systemID: "nfc", frequency: carrier("nfc", 13.56e6), segments: [],
        spot: SIMD3(0.5, 0.2, 0.12), note: "A loop coil at the top of the back, for reading tags and Apple Pay."),
      PhoneRadio(
        id: "qi", title: "MagSafe / Qi2", bands: "Qi 87 – 205 kHz; Qi2 ≈ 360 kHz", systemID: "qi",
        frequency: carrier("qi", 150e3), segments: [], spot: SIMD3(0.5, 0.55, 0.3),
        note: "The charging coil and magnet ring in the middle of the back."),
    ]
  }
}
