import Foundation

/// Launch arguments for the Simulator, UI tests and screenshots (`gyre-integration.md` §8).
/// Every fake is compiled into DEBUG builds only; Release builds ignore them. `-open` and
/// `-ui-testing` work in every build.
///
/// ```
/// xcrun simctl launch booted com.utkarsh.spectra -fakeAll -open radio
/// xcrun simctl launch booted com.utkarsh.spectra -fakeMag=hum60 -fakeBLE=8 -seed 7
/// ```
nonisolated struct LaunchOptions: Sendable, Equatable {
  enum MagnetometerFake: String, Sendable, CaseIterable {
    /// Gyre's (0, 22, −40) µT rotated by the simulated attitude.
    case earth
    /// + 1.6 µT at 60 Hz + 0.4 µT at 120 Hz, sampled at 99.8 Hz ± 2 % → lines at 39.8 and 20.2 Hz.
    case hum60
    /// + 50 Hz mains (sits on Nyquist at ~100 Hz).
    case hum50
    /// A 0.244 A·m² dipole approaching from 30 to 5 cm over 10 s (1.8 → 390 µT).
    case magnet
    /// A static step plus charging (tests the INFERRED path).
    case magsafe
  }

  enum MicrophoneFake: Sendable, Equatable {
    /// Gyre's G-major chord (196/294/392 Hz, swell 0.18 Hz) + a clap every 1.6 s.
    case room
    /// Glottal pulse train 110–180 Hz through 700/1200 Hz formants.
    case voice
    /// A calibration tone at the given frequency (Hz).
    case tone(Double)
  }

  enum BarometerFake: String, Sendable, CaseIterable {
    case still
    /// −0.36 hPa per 3 m floor every 20 s.
    case stairs
    /// ±15 hPa over 10 minutes.
    case weather
  }

  enum Scenario: String, Sendable, CaseIterable {
    /// hum60, a 2.45 GHz "oven" burst in BLE, and a magnet.
    case kitchen
    /// earth field, 8 BLE devices, Wi-Fi good.
    case desk
    /// barometer stairs plus BLE fading.
    case stairwell
  }

  struct LightFake: Sendable, Equatable {
    var kelvin: Double = 3100
    var lux: Double = 300
  }

  // MARK: Fakes (DEBUG)

  var fakeAll = false
  var fakeMag: MagnetometerFake?
  /// Number of simulated BLE devices.
  var fakeBLE: Int?
  var fakeMic: MicrophoneFake?
  /// Radio access technologies the cellular fake steps through every 15 s.
  var fakeCell: [String]?
  var fakeWiFi = false
  var fakeNFC = false
  var fakeUWB = false
  var fakeBaro: BarometerFake?
  var fakeGNSS = false
  var fakeLight: LightFake?
  var fakeAR = false
  var simSway = false
  /// Fixed simulated pose in degrees: pitch, yaw, roll.
  var simPose: SIMD3<Double>?
  /// Seed for deterministic fakes.
  var seed: UInt64?
  var scenario: Scenario?
  var startMic = false
  var startAR = false
  /// `-startLive <sensor>` (repeatable): sensors to start at launch.
  var startLive: [SensorID] = []

  // MARK: Always available

  /// `-open <tab>[/<instrument>]`.
  var openTab: AppTab?
  /// The part after the tab, e.g. `antenna` in `-open radio/antenna`; read by the tab owner.
  var openPath: String?
  /// `-ui-testing`: fresh defaults, paused clock, no persisted state.
  var uiTesting = false

  /// Options for this process.
  static let current = LaunchOptions(arguments: ProcessInfo.processInfo.arguments)

  /// Defaults, with no fakes.
  init() {}

  /// Parses `-flag`, `-flag=value` and `-flag value` forms.
  init(arguments: [String]) {
    var i = 0
    let args = Array(arguments.dropFirst(arguments.first?.hasPrefix("-") == true ? 0 : 1))
    func next() -> String? {
      guard i + 1 < args.count, !args[i + 1].hasPrefix("-") else { return nil }
      i += 1
      return args[i]
    }
    while i < args.count {
      let raw = args[i]
      let parts = raw.split(separator: "=", maxSplits: 1).map(String.init)
      let flag = parts[0]
      let inline = parts.count > 1 ? parts[1] : nil
      switch flag {
      case "-open":
        if let value = inline ?? next() {
          openTab = AppTab(argument: value)
          let rest = value.split(separator: "/", maxSplits: 1)
          openPath = rest.count > 1 ? String(rest[1]) : nil
        }
      case "-ui-testing":
        uiTesting = true
      default:
        #if DEBUG
          parseFake(flag, inline: inline, next: next)
        #else
          break
        #endif
      }
      i += 1
    }
    #if DEBUG
      applyBundles()
    #endif
  }

  #if DEBUG
    private mutating func parseFake(_ flag: String, inline: String?, next: () -> String?) {
      switch flag {
      case "-fakeAll": fakeAll = true
      case "-fakeMag": fakeMag = inline.flatMap(MagnetometerFake.init(rawValue:)) ?? .earth
      case "-fakeBLE", "-fakeRadio": fakeBLE = inline.flatMap(Int.init).map { max(0, min($0, 64)) } ?? 6
      case "-fakeMic": fakeMic = Self.microphone(inline)
      case "-fakeCell": fakeCell = inline.map { $0.split(separator: ",").map(String.init) } ?? ["lte", "nsa"]
      case "-fakeWiFi": fakeWiFi = true
      case "-fakeNFC": fakeNFC = true
      case "-fakeUWB": fakeUWB = true
      case "-fakeBaro": fakeBaro = inline.flatMap(BarometerFake.init(rawValue:)) ?? .still
      case "-fakeGNSS": fakeGNSS = true
      case "-fakeLight":
        var light = LightFake()
        if let inline {
          let v = inline.split(separator: ",").compactMap { Double($0) }
          if v.count > 0 { light.kelvin = v[0] }
          if v.count > 1 { light.lux = v[1] }
        }
        fakeLight = light
      case "-fakeAR": fakeAR = true
      case "-simSway": simSway = true
      case "-simPose":
        if let value = inline ?? next() {
          let v = value.split(separator: ",").compactMap { Double($0) }
          if v.count == 3 { simPose = SIMD3(v[0], v[1], v[2]) }
        }
      case "-seed": seed = (inline ?? next()).flatMap(UInt64.init)
      case "-scenario": scenario = (inline ?? next()).flatMap(Scenario.init(rawValue:))
      case "-startMic": startMic = true
      case "-startAR": startAR = true
      case "-startLive":
        if let value = inline ?? next(), let id = SensorID(rawValue: value) { startLive.append(id) }
      default: break
      }
    }

    private static func microphone(_ value: String?) -> MicrophoneFake {
      guard let value else { return .room }
      if value == "voice" { return .voice }
      if value.hasPrefix("tone") {
        let hz = Double(value.split(separator: ":").last.map(String.init) ?? "") ?? 1000
        return .tone(hz)
      }
      return .room
    }

    /// `-fakeAll` and `-scenario` fill in every fake not set explicitly.
    private mutating func applyBundles() {
      switch scenario {
      case .kitchen:
        fakeMag = fakeMag ?? .hum60
        fakeBLE = fakeBLE ?? 6
      case .desk:
        fakeMag = fakeMag ?? .earth
        fakeBLE = fakeBLE ?? 8
        fakeWiFi = true
      case .stairwell:
        fakeBaro = fakeBaro ?? .stairs
        fakeBLE = fakeBLE ?? 4
      case nil:
        break
      }
      guard fakeAll || scenario != nil else { return }
      fakeMag = fakeMag ?? .hum60
      fakeBLE = fakeBLE ?? 6
      fakeMic = fakeMic ?? .room
      fakeCell = fakeCell ?? ["lte", "nsa"]
      fakeWiFi = true
      fakeNFC = true
      fakeUWB = true
      fakeBaro = fakeBaro ?? .still
      fakeGNSS = true
      fakeLight = fakeLight ?? LightFake()
      fakeAR = true
    }
  #endif

  /// Whether `sensor` should run simulated because of a launch argument.
  func isFaked(_ sensor: SensorID) -> Bool {
    switch sensor {
    case .motion: fakeAll || simSway || simPose != nil
    case .magnetometer: fakeMag != nil
    case .barometer: fakeBaro != nil
    case .microphone: fakeMic != nil
    case .bluetooth: fakeBLE != nil
    case .network: fakeCell != nil || fakeWiFi
    case .location: fakeGNSS
    case .light: fakeLight != nil
    case .charging: fakeAll || fakeMag == .magsafe
    case .uwb: fakeUWB
    case .nfc: fakeNFC
    }
  }

  /// True when any fake is active.
  var anyFake: Bool { SensorID.allCases.contains(where: isFaked) || fakeAR }
}
