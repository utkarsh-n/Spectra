import Foundation
import simd

// The Patch node graph's value types (SPEC.md §3.6). Pure: Foundation, simd and the pure
// engines (RF, Phase, Spin, Core) only, every type `nonisolated` and `Sendable`, so the graph
// compiles in the app (default MainActor isolation) and in a plain macOS harness.

/// What a port carries. The first seven are SPEC.md §3.6; `bits` and `image` are additive:
/// `bits` is the digital message a modulator maps to symbols, `image` the time–frequency
/// plane of the Wigner node (SPEC-features §3c).
nonisolated enum PortType: String, CaseIterable, Codable, Sendable, Hashable, Identifiable {
  /// Real sample blocks with their own rate: 48 kHz audio in audio-rate graphs, or a
  /// sensor's samples at its native rate (magnetometer ≈ 100 Hz).
  case audio
  /// Complex baseband blocks (I + jQ) at a node-declared rate, with the carrier as a label.
  case iq
  /// A power spectrum: bins on a frequency axis.
  case spectrum
  /// One scalar per evaluation step (frame rate).
  case control
  /// A device attitude quaternion (local → world).
  case attitude
  /// Impulses (onsets, kicks, pulses) with times.
  case event
  /// A Spectra source description: vacuum λ, E₀ and polarization.
  case em
  /// Message bits (0/1).
  case bits
  /// A signed time–frequency plane (Wigner, pseudo-Wigner, spectrogram).
  case image

  var id: String { rawValue }

  var title: String {
    switch self {
    case .audio: "Samples"
    case .iq: "I/Q"
    case .spectrum: "Spectrum"
    case .control: "Control"
    case .attitude: "Attitude"
    case .event: "Events"
    case .em: "EM wave"
    case .bits: "Bits"
    case .image: "Time–frequency"
    }
  }

  /// One plain sentence for VoiceOver and the field notes.
  var meaning: String {
    switch self {
    case .audio: "Real samples at their own rate: 48 kHz audio, or a sensor at its native rate."
    case .iq: "Complex baseband I + jQ around a carrier, at the rate the node declares."
    case .spectrum: "Power against frequency."
    case .control: "One number per step, at frame rate."
    case .attitude: "The phone's orientation as a quaternion."
    case .event: "Impulses such as onsets, kicks and pulses."
    case .em: "A light or radio wave: wavelength, amplitude and polarization."
    case .bits: "A digital message, one bit at a time."
    case .image: "A time–frequency picture (Wigner or spectrogram)."
    }
  }
}

/// One end of a cable: a node and one of its port names.
nonisolated struct PortRef: Codable, Sendable, Hashable, CustomStringConvertible {
  var node: String
  var port: String

  init(_ node: String, _ port: String) {
    self.node = node
    self.port = port
  }

  var description: String { "\(node).\(port)" }
}

// MARK: - Payloads

/// Real samples (`audio` ports): 48 kHz audio, or sensor samples at their native rate.
/// `sampleRate == 0` marks an irregular, event-driven stream (BLE adverts): `times` then holds
/// each sample's own timestamp.
nonisolated struct RealBlock: Sendable, Hashable {
  var samples: [Float]
  /// Hz; 0 = irregular (see `times`).
  var sampleRate: Double
  /// Time of `samples[0]`, seconds on the signal clock.
  var startTime: Double
  /// Physical unit as drawn ("FS", "µT", "dBm").
  var unit: String
  /// Per-sample times for irregular streams (empty for uniform blocks).
  var times: [Double]

  init(samples: [Float], sampleRate: Double, startTime: Double, unit: String = "FS", times: [Double] = []) {
    self.samples = samples
    self.sampleRate = sampleRate
    self.startTime = startTime
    self.unit = unit
    self.times = times
  }

  var count: Int { samples.count }
  var isIrregular: Bool { sampleRate <= 0 }
  /// Seconds the block spans (0 for irregular blocks of one sample).
  var duration: Double {
    if isIrregular { return (times.last ?? startTime) - (times.first ?? startTime) }
    return Double(samples.count) / sampleRate
  }

  /// Timestamp of sample `k`.
  func time(of k: Int) -> Double {
    if isIrregular, k < times.count { return times[k] }
    return startTime + (sampleRate > 0 ? Double(k) / sampleRate : 0)
  }

  /// Root-mean-square value (0 for an empty block).
  var rms: Double {
    guard !samples.isEmpty else { return 0 }
    var s = 0.0
    for x in samples where x.isFinite { s += Double(x) * Double(x) }
    return (s / Double(samples.count)).squareRoot()
  }
}

/// Complex baseband (`iq` ports). The carrier is a label: the samples are the complex
/// envelope around it (HETERODYNED), so a 5 GHz Wi-Fi signal and a 462 MHz voice radio share
/// one representation.
nonisolated struct IQBlock: Sendable, Hashable {
  var iq: RF.IQBuffer
  /// Rate of the samples, Hz.
  var sampleRate: Double
  /// Time of the first sample, seconds on the signal clock.
  var startTime: Double
  /// Carrier the envelope sits on, Hz (nil: not an RF signal, e.g. the gyroscope tip).
  var carrierHz: Double?
  /// Occupied bandwidth, Hz (0 = the whole sample rate). The Channel adds noise for the
  /// link budget's SNR in this bandwidth.
  var bandwidth: Double
  /// True when these are receiver decision points (one per symbol), not a waveform.
  var isSymbols: Bool
  /// The ideal constellation points for decision samples (amber rings in the Constellation sink).
  var ideal: [SIMD2<Float>]
  /// Data modulation of a digital signal, for the Demodulator and the readouts.
  var modulation: RF.DigitalModulation?
  /// How the Modulator made this signal, so a Demodulator set to "Match the signal" can
  /// build the matching receiver (nil: not a modulated signal).
  var scheme: ModemScheme?
  /// The bits the Modulator put in this block, in order (simulation knows what was sent:
  /// the Demodulator counts bit errors against them).
  var sentBits: [UInt8]
  /// Antenna gain toward the far end accumulated along the cable, dBi (Antenna nodes add
  /// theirs; the Channel's link budget uses it). The samples themselves stay unit power.
  var antennaGainDBi: Double
  /// Polarization mismatch along the cable, dB (≤ 0).
  var polarizationDB: Double

  init(
    iq: RF.IQBuffer, sampleRate: Double, startTime: Double, carrierHz: Double? = nil, bandwidth: Double = 0,
    isSymbols: Bool = false, ideal: [SIMD2<Float>] = [], modulation: RF.DigitalModulation? = nil,
    scheme: ModemScheme? = nil, sentBits: [UInt8] = [], antennaGainDBi: Double = 0, polarizationDB: Double = 0
  ) {
    self.iq = iq
    self.sampleRate = sampleRate
    self.startTime = startTime
    self.carrierHz = carrierHz
    self.bandwidth = bandwidth
    self.isSymbols = isSymbols
    self.ideal = ideal
    self.modulation = modulation
    self.scheme = scheme
    self.sentBits = sentBits
    self.antennaGainDBi = antennaGainDBi
    self.polarizationDB = polarizationDB
  }

  var count: Int { iq.count }
  /// Bandwidth used for in-band SNR (the whole sample rate when unknown).
  var noiseBandwidth: Double { bandwidth > 0 ? min(bandwidth, sampleRate) : sampleRate }
  /// Seconds the block spans.
  var duration: Double { sampleRate > 0 ? Double(iq.count) / sampleRate : 0 }
}

/// How a Modulator built its signal: everything a matching receiver needs.
nonisolated enum ModemScheme: Sendable, Hashable {
  /// Built by `RF.Transmitter` (AM/FM at 48 kHz audio, keyed, QAM and OFDM).
  case waveform(RF.WaveformSettings, mode: String, payload: Payload)
  /// Analog modulation at the message's own rate (PM, or sensor-rate messages).
  case analog(RF.AnalogSettings, mode: String)

  /// What the bits of a digital scheme carry.
  enum Payload: String, Sendable, Hashable {
    /// Plain data bits (text or random).
    case data
    /// 8 kHz, 8-bit µ-law voice (64 kb/s), from an audio message on a digital mode.
    case voice
  }

  /// The Modulator mode key ("am", "qpsk", "ofdm" …).
  var mode: String {
    switch self {
    case .waveform(_, let m, _), .analog(_, let m): m
    }
  }

  var payload: Payload {
    if case .waveform(_, _, let p) = self { return p }
    return .data
  }

  var isAnalog: Bool { NodeCatalog.analogModes.contains(mode) }
}

/// A power spectrum (`spectrum` ports). Bin k sits at `startFrequency + k·binWidth`.
nonisolated struct SpectrumFrame: Sendable, Hashable {
  var values: [Float]
  var startFrequency: Double
  var binWidth: Double
  /// dB (FFT node) or linear power (Marginal node).
  var isDB: Bool
  /// Rate of the analysed signal (its Nyquist bounds the axis), Hz.
  var sampleRate: Double
  /// Strongest bin, Hz (nil when unknown).
  var peakHz: Double?
  /// Carrier the axis is relative to (I/Q spectra are two-sided around it).
  var carrierHz: Double?

  var endFrequency: Double { startFrequency + binWidth * Double(max(0, values.count - 1)) }

  /// Values in dB whatever the storage (linear power floors at −200 dB).
  var decibels: [Float] {
    isDB ? values : values.map { 10 * log10f(max($0, 1e-20)) }
  }
}

/// Impulses (`event` ports): times on the signal clock and strengths 0…1.
nonisolated struct EventBlock: Sendable, Hashable {
  var times: [Double] = []
  var strengths: [Double] = []

  var isEmpty: Bool { times.isEmpty }
}

/// A Spectra source description (`em` ports).
nonisolated struct EMWave: Sendable, Hashable, Codable {
  /// Vacuum wavelength, m.
  var lambda: Double
  /// Peak field, V/m.
  var e0: Double
  /// Linear polarization angle θ, degrees.
  var polarization: Double

  var frequency: Double { SpectrumMarker.frequency(forLambda: lambda) }
}

/// Message bits (`bits` ports), with the text they spell when the source is text.
nonisolated struct BitsBlock: Sendable, Hashable {
  var bits: [UInt8]
  /// The message text when the bits are UTF-8 text (preview only).
  var text: String?
}

/// A time–frequency picture (`image` ports).
nonisolated struct TFImage: Sendable, Hashable {
  var image: Phase.TimeFrequencyImage
  var mode: Phase.TimeFrequencyMode
  /// Rate of the analysed record, Hz.
  var sampleRate: Double
  /// Whether the record was complex (two-sided band) or real (0 … fs/2).
  var complex: Bool
  /// Seconds the record spans.
  var duration: Double
}

/// The value on a port for one step.
nonisolated enum SignalPayload: Sendable, Hashable {
  case audio(RealBlock)
  case iq(IQBlock)
  case spectrum(SpectrumFrame)
  case control(Double)
  case attitude(simd_quatd)
  case event(EventBlock)
  case em(EMWave)
  case bits(BitsBlock)
  case image(TFImage)

  var type: PortType {
    switch self {
    case .audio: .audio
    case .iq: .iq
    case .spectrum: .spectrum
    case .control: .control
    case .attitude: .attitude
    case .event: .event
    case .em: .em
    case .bits: .bits
    case .image: .image
    }
  }

  var audio: RealBlock? { if case .audio(let b) = self { b } else { nil } }
  var iqBlock: IQBlock? { if case .iq(let b) = self { b } else { nil } }
  var spectrum: SpectrumFrame? { if case .spectrum(let s) = self { s } else { nil } }
  var control: Double? { if case .control(let v) = self { v } else { nil } }
  var attitude: simd_quatd? { if case .attitude(let q) = self { q } else { nil } }
  var events: EventBlock? { if case .event(let e) = self { e } else { nil } }
  var em: EMWave? { if case .em(let w) = self { w } else { nil } }
  var bits: BitsBlock? { if case .bits(let b) = self { b } else { nil } }
  var image: TFImage? { if case .image(let i) = self { i } else { nil } }
}

/// A port's value and where it comes from (rule R4: a graph output carries the union of its
/// inputs' badges and its node's own).
nonisolated struct PortValue: Sendable, Hashable {
  var payload: SignalPayload
  var provenance: [Provenance]

  init(_ payload: SignalPayload, provenance: [Provenance]) {
    self.payload = payload
    self.provenance = Provenance.union(provenance)
  }

  var type: PortType { payload.type }
}

/// Why connecting two ports failed.
nonisolated enum GraphError: Error, Equatable, Sendable, CustomStringConvertible {
  case unknownNode(String)
  case unknownPort(PortRef)
  /// The output's types and the input's accepted types do not meet.
  case typeMismatch(from: [PortType], to: [PortType])
  /// The cable would close a loop through these nodes.
  case cycle([String])
  case selfLoop
  /// Both ends are outputs or both are inputs.
  case direction

  var description: String {
    switch self {
    case .unknownNode(let id): "No node \(id)."
    case .unknownPort(let ref): "No port \(ref)."
    case .typeMismatch(let a, let b):
      "\(a.map(\.title).joined(separator: "/")) cannot feed \(b.map(\.title).joined(separator: "/"))."
    case .cycle: "That cable would make a loop. Feedback goes through a Knob target instead."
    case .selfLoop: "A node cannot feed itself."
    case .direction: "Cables run from an output to an input."
    }
  }
}

/// A one-line status a node shows on its card ("Waiting for Microphone").
nonisolated struct NodeStatus: Sendable, Hashable {
  enum Level: String, Sendable, Hashable { case info, waiting, warning }
  var text: String
  var level: Level

  init(_ text: String, _ level: Level = .info) {
    self.text = text
    self.level = level
  }
}
