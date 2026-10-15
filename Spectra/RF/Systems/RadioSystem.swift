import Foundation

nonisolated extension RF {
  /// Filter chips of the Systems page.
  enum SystemCategory: String, CaseIterable, Codable, Hashable, Sendable, Identifiable {
    case cellular, wifi, personal, navigation, broadcast

    var id: String { rawValue }

    var displayName: String {
      switch self {
      case .cellular: "Cellular"
      case .wifi: "Wi-Fi"
      case .personal: "Personal"
      case .navigation: "Navigation"
      case .broadcast: "Broadcast"
      }
    }
  }

  /// Whether the user's iPhone 15 Pro Max has the radio (rf-physics §F).
  enum IPhoneSupport: String, Codable, Hashable, Sendable {
    /// Supported by every iPhone 15 Pro Max model.
    case yes
    /// Supported by some models or only partly (e.g. mmWave on the US A2849 only).
    case partial
    case no
  }

  /// A rate with its basis.
  struct PeakRate: Codable, Hashable, Sendable {
    /// Bit/s.
    var value: Double
    var basis: ValueBasis
    /// What the number is ("raw symbol-rate ceiling before coding", "headline PHY rate").
    var note: String
  }

  /// The pulse used by a linear modulation in the simulator.
  enum PulseShape: Codable, Hashable, Sendable {
    /// Root-raised cosine with roll-off β.
    case rootRaisedCosine(rolloff: Double)
    /// Rectangular (NRZ) chips/symbols.
    case rectangular
  }

  /// How the Fourier page simulates a system at baseband (scaled where needed).
  enum Waveform: Codable, Hashable, Sendable {
    /// Unmodulated carrier (Qi power transfer).
    case tone
    /// Analog AM with modulation depth m.
    case analogAM(depth: Double)
    /// Analog FM with peak deviation Δf (Hz) and audio bandwidth (Hz).
    case analogFM(deviation: Double, audioBandwidth: Double)
    /// A linear digital modulation at a symbol rate with a pulse shape.
    case linear(modulation: DigitalModulation, symbolRate: Double, pulse: PulseShape)
    /// Continuous-phase FSK (GFSK/GMSK when `bt` is set).
    case fsk(index: Double, bt: Double?, symbolRate: Double)
    /// Direct-sequence spread symbols: one code period of `chipsPerSymbol` chips per symbol.
    case dsss(modulation: DigitalModulation, chipsPerSymbol: Int, chipRate: Double)
    /// OFDM with a data modulation on a (possibly scaled) numerology.
    case ofdm(modulation: DigitalModulation, config: OFDMConfig)
    /// FMCW radar: a linear frequency sweep from −B/2 to +B/2 in `duration` seconds, repeated
    /// (sawtooth), complex baseband sampled at 2B. Its Wigner distribution is a straight line of
    /// slope B/T. The receiver demodulates nothing (like `tone`).
    case chirp(bandwidth: Double, duration: Double)

    /// Short name for the waveform chip ("OFDM 1024-QAM", "GFSK h 0.5").
    var displayName: String {
      switch self {
      case .tone: return "CW carrier"
      case .analogAM: return "AM"
      case .analogFM: return "FM"
      case .linear(let m, _, _): return m.displayName
      case .fsk(let h, let bt, _):
        guard let bt else { return String(format: "CPFSK h %.2f", h) }
        return (abs(h - 0.5) < 1e-9 && abs(bt - 0.3) < 1e-9) ? "GMSK BT 0.3" : String(format: "GFSK h %.2f BT %.1f", h, bt)
      case .dsss(let m, let n, _): return "DSSS \(n)-chip \(m.displayName)"
      case .ofdm(let m, _): return "OFDM \(m.displayName)"
      case .chirp: return "FMCW chirp"
      }
    }

    /// The digital modulation of the data symbols, if any.
    var dataModulation: DigitalModulation? {
      switch self {
      case .linear(let m, _, _), .dsss(let m, _, _), .ofdm(let m, _): m
      default: nil
      }
    }
  }

  /// One card of the Systems timeline: a radio generation or system with its bands, channel
  /// widths, modulation, multiplexing, peak rate, year and iPhone support.
  struct RadioSystem: Codable, Hashable, Sendable, Identifiable {
    var id: String
    var name: String
    /// Generation or family label ("1G", "2.75G", "Wi-Fi 6E", "BLE").
    var generation: String
    var category: SystemCategory
    /// Year of first commercial service or standard (general history, see `yearNote`).
    var year: Int
    var yearNote: String
    /// Allocations (MHz).
    var bands: [Band]
    /// Band numbers supported by the iPhone 15 Pro Max model(s), when the reference lists them.
    var iPhoneBands: [String]
    /// Representative carrier for the strip marker and the Antenna/Link pages, Hz.
    var carrier: Double
    /// Channel widths (Hz), narrowest first.
    var channelWidths: [Double]
    /// Modulations in plain words ("GMSK", "QPSK … 1024-QAM").
    var modulation: String
    /// Largest QAM order, if the system uses QAM.
    var maxQAM: Int?
    /// Multiple access / multiplexing ("FDMA", "TDMA", "OFDMA").
    var multiplexing: String
    /// Subcarrier spacings (Hz) for OFDM systems.
    var subcarrierSpacings: [Double]
    var peakRate: PeakRate?
    var iPhone: IPhoneSupport
    var iPhoneNote: String
    /// IMT-2030 / 6G and other not-yet-standardized entries.
    var isSpeculative: Bool
    /// Baseband simulation profile for the Fourier page.
    var waveform: Waveform
    /// Key facts (one line each) for the expanded card.
    var facts: [String]
    /// Short citations.
    var sources: [String]

    /// Widest channel, Hz.
    var maxChannelWidth: Double? { channelWidths.max() }
  }
}
