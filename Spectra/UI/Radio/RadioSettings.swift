import Foundation

// Persisted value types of the Radio tab (`Spectra.radio.v1`). Every type here is
// `nonisolated` so its Codable conformance is not main-actor isolated.

/// The four pages of the Radio tab.
nonisolated enum RadioPage: String, CaseIterable, Identifiable, Codable, Sendable {
  case antenna, systems, fourier, link

  var id: String { rawValue }

  var title: String {
    switch self {
    case .antenna: "Antenna"
    case .systems: "Systems"
    case .fourier: "Fourier"
    case .link: "Link"
    }
  }

  var subtitle: String {
    switch self {
    case .antenna: "Antenna patterns"
    case .systems: "1G to 6G and friends"
    case .fourier: "Baseband simulation"
    case .link: "Link budget"
    }
  }
}

/// How the 3D lobe maps |F| to a radius.
nonisolated enum RadioLobeScale: String, CaseIterable, Identifiable, Codable, Sendable {
  case decibel, field, power

  var id: String { rawValue }

  var title: String {
    switch self {
    case .decibel: "dB (30 dB)"
    case .field: "Field |F|"
    case .power: "Power |F|²"
    }
  }

  var scale: RF.PatternScale {
    switch self {
    case .decibel: .decibel(floorDB: -30)
    case .field: .field
    case .power: .power
    }
  }
}

/// Systems page filter chips: everything, or one RF category.
nonisolated enum RadioSystemFilter: String, CaseIterable, Identifiable, Codable, Sendable {
  case all, cellular, wifi, personal, navigation, broadcast

  var id: String { rawValue }

  var category: RF.SystemCategory? {
    switch self {
    case .all: nil
    case .cellular: .cellular
    case .wifi: .wifi
    case .personal: .personal
    case .navigation: .navigation
    case .broadcast: .broadcast
    }
  }

  var title: String { category?.displayName ?? "All" }
}

/// Channel fading model of the Fourier page.
nonisolated enum RadioFading: String, CaseIterable, Identifiable, Codable, Sendable {
  case none, rayleigh, rician

  var id: String { rawValue }

  var title: String {
    switch self {
    case .none: "Static"
    case .rayleigh: "Rayleigh"
    case .rician: "Rician"
    }
  }
}

/// Message source of the Fourier page.
nonisolated enum RadioMessage: String, CaseIterable, Identifiable, Codable, Sendable {
  /// Random bits (digital), the 1 kHz test tone (AM/FM), nothing (CW, FMCW).
  case auto
  case text
  case voice

  var id: String { rawValue }
}

/// Which time–frequency picture the Fourier page draws.
nonisolated enum RadioTFView: String, CaseIterable, Identifiable, Codable, Sendable {
  case both, wignerVille, spectrogram

  var id: String { rawValue }

  var title: String {
    switch self {
    case .both: "Both"
    case .wignerVille: "Wigner–Ville"
    case .spectrogram: "Spectrogram"
    }
  }
}

/// Which signal the I/Q trace shows.
nonisolated enum RadioTraceSource: String, CaseIterable, Identifiable, Codable, Sendable {
  case sent, received

  var id: String { rawValue }

  var title: String { self == .sent ? "Sent" : "Received" }
}

/// Fourier page settings.
nonisolated struct RadioFourierSettings: Codable, Hashable, Sendable {
  /// Digital: Es/N0 per data symbol; analog: CNR in the channel bandwidth (dB).
  var snrDB = 30.0
  /// RMS delay spread of the exponential multipath profile, s (0 = none).
  var delaySpread = 0.0
  /// Maximum Doppler f_m, Hz (0 = none).
  var dopplerHz = 0.0
  var fading: RadioFading = .none
  /// Rician K in dB (LOS power over scattered power).
  var ricianKdB = 6.0
  var message: RadioMessage = .auto
  var text = "Hello from Spectra. "
  /// Replaces the data modulation of linear, DSSS and OFDM waveforms (nil = the system's own).
  var modulation: RF.DigitalModulation?
}

/// Link page environments (median path-loss models).
nonisolated enum RadioEnvironment: String, CaseIterable, Identifiable, Codable, Sendable {
  case freeSpace, logDistance, indoorLOS, indoorNLOS, urbanMicro, urbanMacro

  var id: String { rawValue }

  var title: String {
    switch self {
    case .freeSpace: "Free space"
    case .logDistance: "Log-distance"
    case .indoorLOS: "Office LOS"
    case .indoorNLOS: "Office NLOS"
    case .urbanMicro: "Street canyon"
    case .urbanMacro: "Urban macro"
    }
  }

  func model(exponent: Double) -> RF.PropagationModel {
    switch self {
    case .freeSpace: .freeSpace
    case .logDistance: .logDistance(exponent: exponent, referenceDistance: 1)
    case .indoorLOS: .tr38901(.indoorOfficeLOS)
    case .indoorNLOS: .tr38901(.indoorOfficeNLOS)
    case .urbanMicro: .tr38901(.urbanMicroNLOS)
    case .urbanMacro: .tr38901(.urbanMacroNLOS)
    }
  }
}

/// Link page settings.
nonisolated struct RadioLinkSettings: Codable, Hashable, Sendable {
  var txPowerDBm = 20.0
  /// Use the Antenna page's gain for the transmitter.
  var useAntennaGain = true
  var txGainDBi = 0.0
  var rxGainDBi = 0.0
  /// Path length, m.
  var distance = 10.0
  var environment: RadioEnvironment = .freeSpace
  /// Log-distance exponent n.
  var exponent = 3.0
  /// Walls crossed: material raw value → count.
  var walls: [String: Int] = [:]
  /// Rain rate, mm/h.
  var rainRate = 0.0
  var gas = false
  var noiseFigureDB = 7.0
  /// Receiver noise bandwidth, Hz (nil = the selected system's widest channel).
  var bandwidth: Double?
  /// Subtract the Antenna page's polarization mismatch.
  var includePLF = false
  /// Live check: the BLE device's transmit power and the path-loss exponent.
  var bleTxPowerDBm = 0.0
  var bleExponent = 2.0
  var bleDevice: String?
}

/// Everything `RadioModel` persists. Every field is optional so a save from an older build
/// (the stage-1 stub saved only `carrier`) still decodes.
nonisolated struct RadioSaved: Codable, Sendable {
  var carrier: Double?
  var page: RadioPage?
  var systemID: String?
  var antenna: RF.AntennaParameters?
  var followPhone: Bool?
  var beamLock: Bool?
  var lobeScale: RadioLobeScale?
  var reference: RF.ReferencePolarization?
  var aperturePlane: RF.PatternPlane?
  var fresnelRatio: Double?
  var filter: RadioSystemFilter?
  var iPhoneOnly: Bool?
  var fourier: RadioFourierSettings?
  var tfView: RadioTFView?
  var traceSource: RadioTraceSource?
  var link: RadioLinkSettings?
}
