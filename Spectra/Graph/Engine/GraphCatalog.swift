import Foundation

// The node catalogue (SPEC-features §5, gyre-integration §6): every kind of node, its typed
// ports, its parameters and its own provenance. Pure data; the processors that run each kind
// live in Graph*Nodes.swift.

/// Where a node sits in the add-node palette.
nonisolated enum NodeCategory: String, CaseIterable, Codable, Sendable, Identifiable {
  case sources, process, sinks
  var id: String { rawValue }
  var title: String {
    switch self {
    case .sources: "Sources"
    case .process: "Process"
    case .sinks: "Sinks"
    }
  }
}

/// Every node kind. Raw values are persisted in `Spectra.patch.v1`: never rename one.
nonisolated enum NodeKind: String, CaseIterable, Codable, Sendable, Identifiable {
  // Sources
  case spectraSource, oscillator, noise, bits, stream, motion, gyroscope, spinFID
  // Process
  case modulator, demodulator, mixer, filter, gain, envelope, antenna, channel, medium, blackbody, fft, wigner, marginal
  // Sinks
  case scope, spectrum, constellation, speaker, haptics, ruler, knob

  var id: String { rawValue }
  var spec: NodeSpec { NodeCatalog.spec(self) }
}

/// One port of a node kind.
nonisolated struct PortSpec: Sendable, Hashable, Identifiable {
  /// Port name, unique per node and per direction ("message", "signal").
  let name: String
  let title: String
  /// Types this port accepts (inputs) or may produce (outputs).
  let types: [PortType]
  /// Outputs only: the output's type follows this input's (Gain, Filter).
  let follows: String?

  init(_ name: String, _ title: String, _ types: [PortType], follows: String? = nil) {
    self.name = name
    self.title = title
    self.types = types
    self.follows = follows
  }

  var id: String { name }
}

/// How a numeric parameter prints.
nonisolated enum ParamFormat: Sendable, Hashable {
  case plain(String)
  case frequency
  case decibels(String)
  case percent
  case degrees
  case distance
  case wavelength
  case seconds
  case microtesla
  case integer(String)
  case fieldStrength
  case symbolRate
}

/// A labelled detent with physical meaning.
nonisolated struct ParamDetent: Sendable, Hashable {
  let value: Double
  let label: String
  init(_ value: Double, _ label: String) {
    self.value = value
    self.label = label
  }
}

/// One option of a choice parameter.
nonisolated struct ParamOption: Sendable, Hashable, Identifiable {
  let key: String
  let title: String
  init(_ key: String, _ title: String) {
    self.key = key
    self.title = title
  }
  var id: String { key }
}

/// The value ↔ knob-position mapping of a numeric parameter (linear or log), with Gyre's
/// modulation rule applied in position space (`gyre-integration.md` §7).
nonisolated struct ParamScale: Sendable, Hashable {
  var range: ClosedRange<Double>
  var logarithmic: Bool
  /// Snap step (0 = continuous).
  var step: Double

  init(range: ClosedRange<Double>, logarithmic: Bool = false, step: Double = 0) {
    self.range = range
    self.logarithmic = logarithmic && range.lowerBound > 0 && range.upperBound > range.lowerBound
    self.step = max(0, step)
  }

  /// Position 0…1 of `value` (clamped; non-finite → 0).
  func position(of value: Double) -> Double {
    guard value.isFinite, range.upperBound > range.lowerBound else { return 0 }
    let v = min(max(value, range.lowerBound), range.upperBound)
    if logarithmic { return log(v / range.lowerBound) / log(range.upperBound / range.lowerBound) }
    return (v - range.lowerBound) / (range.upperBound - range.lowerBound)
  }

  /// Value at position `p` (clamped, snapped to `step`).
  func value(at position: Double) -> Double {
    let p = position.isFinite ? min(max(position, 0), 1) : 0
    var v =
      logarithmic
      ? range.lowerBound * pow(range.upperBound / range.lowerBound, p)
      : range.lowerBound + p * (range.upperBound - range.lowerBound)
    if step > 0 { v = range.lowerBound + ((v - range.lowerBound) / step).rounded() * step }
    return min(max(v, range.lowerBound), range.upperBound)
  }

  func clamp(_ value: Double) -> Double {
    guard value.isFinite else { return range.lowerBound }
    return min(max(value, range.lowerBound), range.upperBound)
  }

  /// p = clamp(position(base) + depth·cv); value = value(at: p).
  func modulated(base: Double, depth: Double, cv: Double) -> Double {
    value(at: position(of: base) + (depth.isFinite ? depth : 0) * (cv.isFinite ? cv : 0))
  }
}

/// A node parameter: a knob, a choice, a switch, a text, a stream or a knob target.
nonisolated struct ParamSpec: Sendable, Hashable, Identifiable {
  enum Kind: Sendable, Hashable {
    case number(scale: ParamScale, defaultValue: Double, format: ParamFormat, detents: [ParamDetent])
    case choice(options: [ParamOption], defaultKey: String)
    case toggle(defaultValue: Bool)
    case text(defaultValue: String)
    /// A `StreamID` from the scope bus.
    case stream
    /// "node.param" inside the graph, or an app knob (`PatchModel.externalTargets`).
    case target
  }

  let id: String
  let title: String
  /// Serif glyph of the physical quantity ("f", "λ", "Δf").
  let glyph: String
  let kind: Kind
  /// One line shown while turning and as the VoiceOver hint.
  let hint: String

  init(_ id: String, _ title: String, glyph: String = "", _ kind: Kind, hint: String = "") {
    self.id = id
    self.title = title
    self.glyph = glyph
    self.kind = kind
    self.hint = hint
  }

  static func number(
    _ id: String, _ title: String, glyph: String = "", range: ClosedRange<Double>, value: Double, log: Bool = false,
    step: Double = 0, format: ParamFormat, detents: [ParamDetent] = [], hint: String = ""
  ) -> ParamSpec {
    ParamSpec(
      id, title, glyph: glyph,
      .number(scale: ParamScale(range: range, logarithmic: log, step: step), defaultValue: value, format: format, detents: detents),
      hint: hint)
  }

  static func choice(_ id: String, _ title: String, _ options: [ParamOption], value: String, hint: String = "") -> ParamSpec {
    ParamSpec(id, title, .choice(options: options, defaultKey: value), hint: hint)
  }

  var scale: ParamScale? {
    if case .number(let s, _, _, _) = kind { s } else { nil }
  }

  var defaultNumber: Double? {
    switch kind {
    case .number(_, let v, _, _): v
    case .toggle(let b): b ? 1 : 0
    default: nil
    }
  }

  var defaultString: String? {
    switch kind {
    case .choice(_, let key): key
    case .text(let t): t
    case .stream, .target: ""
    default: nil
    }
  }

  var options: [ParamOption] {
    if case .choice(let o, _) = kind { o } else { [] }
  }

  /// Numeric parameters are the ones a Knob target can drive.
  var isModulatable: Bool {
    if case .number = kind { true } else { false }
  }
}

/// Everything the graph and the UI know about one node kind.
nonisolated struct NodeSpec: Sendable, Hashable {
  let kind: NodeKind
  let title: String
  let category: NodeCategory
  /// SF Symbol (checked in CoreGlyphs `name_availability.plist`).
  let symbol: String
  /// One sentence for the palette and the inspector.
  let summary: String
  let inputs: [PortSpec]
  let outputs: [PortSpec]
  let params: [ParamSpec]
  /// The node's own badges (its outputs add the union of its inputs').
  let provenance: [Provenance]
  /// True when the node produces 48 kHz audio blocks: the graph then steps in 1024-sample
  /// blocks instead of once per frame.
  let isAudioRate: Bool

  func input(_ name: String) -> PortSpec? { inputs.first { $0.name == name } }
  func output(_ name: String) -> PortSpec? { outputs.first { $0.name == name } }
  func param(_ id: String) -> ParamSpec? { params.first { $0.id == id } }
}

/// The catalogue.
nonisolated enum NodeCatalog {
  static let audioRate = 48_000.0
  static let blockSize = 1024

  static let analogModes: Set<String> = ["am", "fm", "pm"]

  static let modulationModes: [ParamOption] = [
    ParamOption("am", "AM"), ParamOption("fm", "FM"), ParamOption("pm", "PM"), ParamOption("ask", "ASK (OOK)"),
    ParamOption("fsk", "FSK"), ParamOption("bpsk", "BPSK"), ParamOption("qpsk", "QPSK"),
    ParamOption("qam16", "16-QAM"), ParamOption("qam64", "64-QAM"), ParamOption("qam256", "256-QAM"),
    ParamOption("qam1024", "1024-QAM"), ParamOption("ofdm", "OFDM (Wi-Fi 6)"),
  ]

  static let ofdmOrders: [ParamOption] = [
    ParamOption("qpsk", "QPSK"), ParamOption("qam16", "16-QAM"), ParamOption("qam64", "64-QAM"),
    ParamOption("qam256", "256-QAM"), ParamOption("qam1024", "1024-QAM"),
  ]

  static let carrierDetents = [
    ParamDetent(1e6, "AM band 1 MHz"), ParamDetent(100e6, "FM 100 MHz"), ParamDetent(462.6e6, "FRS 462.6 MHz"),
    ParamDetent(2.44e9, "BLE 2.44 GHz"), ParamDetent(5.5e9, "Wi-Fi 5.5 GHz"), ParamDetent(28e9, "5G mmWave 28 GHz"),
  ]

  static func spec(_ kind: NodeKind) -> NodeSpec {
    switch kind {
    // MARK: Sources
    case .spectraSource:
      NodeSpec(
        kind: kind, title: "Spectra source", category: .sources, symbol: "rainbow",
        summary: "A light or radio wave from the Spectrum tab: wavelength, amplitude and polarization.",
        inputs: [],
        outputs: [PortSpec("wave", "Wave", [.em]), PortSpec("frequency", "f", [.control])],
        params: [
          .choice(
            "follow", "Source",
            [ParamOption("A", "Spectrum A"), ParamOption("own", "Own dial")], value: "A",
            hint: "Follow Spectrum source A's wavelength, or use this node's own. Amplitude and polarization are always this node's."),
          .number(
            "lambda", "Wavelength", glyph: "λ", range: 1e-13...1e8, value: 550e-9, log: true, format: .wavelength,
            detents: [
              ParamDetent(400e-9, "Violet edge"), ParamDetent(550e-9, "Green"), ParamDetent(700e-9, "Red edge"),
              ParamDetent(0.1229, "BLE 2.44 GHz"), ParamDetent(140.83e3, "Earth-field NMR"),
            ], hint: "Vacuum wavelength when the node uses its own dial."),
          .number(
            "e0", "Amplitude", glyph: "E₀", range: 1e-3...1e12, value: 1, log: true, format: .fieldStrength,
            hint: "Peak electric field."),
          .number(
            "polarization", "Polarization", glyph: "θ", range: 0...180, value: 0, format: .degrees,
            hint: "Angle of the electric field."),
        ],
        provenance: [.model], isAudioRate: false)
    case .oscillator:
      NodeSpec(
        kind: kind, title: "Oscillator", category: .sources, symbol: "waveform.path",
        summary: "A sine, square, saw or triangle at 48 kHz. Below 20 Hz it is a slow control wobble.",
        inputs: [],
        outputs: [PortSpec("out", "Out", [.audio]), PortSpec("cv", "CV", [.control])],
        params: [
          .choice(
            "wave", "Shape",
            [ParamOption("sine", "Sine"), ParamOption("square", "Square"), ParamOption("saw", "Saw"), ParamOption("triangle", "Triangle")],
            value: "sine"),
          .number(
            "f", "Frequency", glyph: "f", range: 0.05...20_000, value: 440, log: true, format: .frequency,
            detents: [ParamDetent(1, "1 Hz wobble"), ParamDetent(60, "Mains 60 Hz"), ParamDetent(440, "A4"), ParamDetent(1000, "1 kHz")],
            hint: "Cycles per second."),
          .number("amp", "Level", glyph: "A", range: 0...1, value: 0.5, format: .percent, hint: "Peak amplitude, full scale 1."),
        ],
        provenance: [.model], isAudioRate: true)
    case .noise:
      NodeSpec(
        kind: kind, title: "Noise", category: .sources, symbol: "aqi.medium",
        summary: "Seeded random noise at 48 kHz, white or darker.",
        inputs: [],
        outputs: [PortSpec("out", "Out", [.audio])],
        params: [
          .number("level", "Level", glyph: "σ", range: 0...1, value: 0.3, format: .percent, hint: "RMS level."),
          .number("color", "Color", range: 0...1, value: 0, format: .percent, hint: "0 is white noise; higher is darker (low-passed)."),
        ],
        provenance: [.model], isAudioRate: true)
    case .bits:
      NodeSpec(
        kind: kind, title: "Text / bits", category: .sources, symbol: "textformat.abc",
        summary: "A digital message: the UTF-8 bits of a text, or seeded random bits.",
        inputs: [],
        outputs: [PortSpec("bits", "Bits", [.bits])],
        params: [
          .choice("mode", "Message", [ParamOption("text", "Text"), ParamOption("random", "Random bits")], value: "text"),
          ParamSpec("text", "Text", .text(defaultValue: "Hello from Spectra"), hint: "Sent as UTF-8, repeated."),
          .choice(
            "block", "Bits per step",
            [
              ParamOption("256", "256"), ParamOption("1024", "1,024"), ParamOption("4096", "4,096"),
              ParamOption("16384", "16,384"), ParamOption("32768", "32,768"),
            ],
            value: "1024", hint: "How many bits leave the node each step."),
        ],
        provenance: [.model], isAudioRate: false)
    case .stream:
      NodeSpec(
        kind: kind, title: "Live stream", category: .sources, symbol: "waveform.path.ecg",
        summary:
          "Any signal on the scope bus: a sensor axis, a Bluetooth device's RSSI, the microphone, a simulation. A stream with a quadrature partner (Radio I/Q, Spin FID, gyroscope tip) also comes out as I/Q.",
        inputs: [],
        outputs: [
          PortSpec("samples", "Samples", [.audio]), PortSpec("value", "Value", [.control]), PortSpec("iq", "I/Q", [.iq]),
        ],
        params: [ParamSpec("stream", "Stream", .stream, hint: "Which signal this node reads.")],
        provenance: [], isAudioRate: false)
    case .motion:
      NodeSpec(
        kind: kind, title: "Motion / attitude", category: .sources, symbol: "gyroscope",
        summary: "The phone's orientation from the motion sensors, as a quaternion and three angles.",
        inputs: [],
        outputs: [
          PortSpec("attitude", "Attitude", [.attitude]), PortSpec("yaw", "Yaw", [.control]),
          PortSpec("pitch", "Pitch", [.control]), PortSpec("roll", "Roll", [.control]),
        ],
        params: [],
        provenance: [.analogy], isAudioRate: false)
    case .gyroscope:
      NodeSpec(
        kind: kind, title: "Gyroscope tip", category: .sources, symbol: "gyroscope",
        summary: "Gyre's heavy top. Its axle tip seen from above is an I/Q signal: precession is the carrier, the nod a sideband.",
        inputs: [PortSpec("field", "B (µT)", [.control]), PortSpec("kick", "Kick", [.event])],
        outputs: [
          PortSpec("tip", "Tip I/Q", [.iq]), PortSpec("tipX", "Tip x", [.control]),
          PortSpec("precession", "Ωp (Hz)", [.control]), PortSpec("nod", "Nod (Hz)", [.control]),
          PortSpec("spin", "Spin (rpm)", [.control]),
        ],
        params: [
          .number(
            "rpm", "Motor", glyph: "ω", range: 0...12_000, value: 3000, format: .integer("rpm"),
            detents: [ParamDetent(3000, "3,000 rpm"), ParamDetent(12_000, "12,000 rpm")], hint: "Target spin of the rotor."),
          .number(
            "time", "Time", glyph: "D", range: 0.05...2, value: 1, log: true, format: .plain("×"),
            detents: [ParamDetent(0.25, "Slow motion"), ParamDetent(1, "Real time")], hint: "Simulated seconds per second."),
          .number(
            "gravity", "Gravity", glyph: "g", range: 0...3, value: 1, format: .plain("g"),
            detents: [ParamDetent(0.165, "Moon"), ParamDetent(0.38, "Mars"), ParamDetent(1, "Earth")],
            hint: "Local gravity in g."),
          .number(
            "magnet", "Magnet", glyph: "μ", range: -1...1, value: 0, format: .percent,
            detents: [ParamDetent(0.138, "Real NdFeB"), ParamDetent(-1, "Electron-like")],
            hint: "Rotor magnetization; it precesses in the field like a spin."),
        ],
        provenance: [.model, .analogy], isAudioRate: false)
    case .spinFID:
      NodeSpec(
        kind: kind, title: "Spin FID", category: .sources, symbol: "atom",
        summary: "Protons precessing in the field ring at the Larmor frequency, about 2.1 kHz in Earth's 50 µT. You can hear it.",
        inputs: [PortSpec("field", "B (µT)", [.control]), PortSpec("pulse", "Pulse", [.event])],
        outputs: [
          PortSpec("audio", "Audio", [.audio]), PortSpec("iq", "I/Q", [.iq]), PortSpec("larmor", "fL (Hz)", [.control]),
        ],
        params: [
          .choice(
            "species", "Species",
            [ParamOption("protonWater", "Water ¹H"), ParamOption("proton", "Free proton"), ParamOption("electron", "Electron")],
            value: "protonWater"),
          .number(
            "field", "Field", glyph: "B₀", range: 1...1000, value: 50, log: true, format: .microtesla,
            detents: [ParamDetent(50, "Earth 50 µT")], hint: "Used when nothing drives the B input."),
          .number("t2", "T₂*", glyph: "T₂*", range: 0.01...5, value: 0.5, log: true, format: .seconds, hint: "Ring-down time."),
          .number("repeat", "Repeat", glyph: "TR", range: 0.5...10, value: 2, log: true, format: .seconds, hint: "Seconds between pulses."),
          .number("level", "Level", glyph: "A", range: 0...1, value: 0.5, format: .percent),
        ],
        provenance: [.model], isAudioRate: true)

    // MARK: Process
    case .modulator:
      NodeSpec(
        kind: kind, title: "Modulator", category: .process, symbol: "wave.3.right",
        summary: "Puts a message on a carrier: AM, FM, PM, keyed and QAM symbols, or Wi-Fi 6 OFDM. Complex baseband out.",
        inputs: [PortSpec("message", "Message", [.audio, .bits]), PortSpec("carrier", "Carrier", [.em, .control])],
        outputs: [PortSpec("signal", "Signal", [.iq])],
        params: modemParams(includePayload: false),
        provenance: [.model], isAudioRate: false)
    case .demodulator:
      NodeSpec(
        kind: kind, title: "Demodulator", category: .process, symbol: "wave.3.left",
        summary: "Recovers the message: envelope (AM), phase discriminator (FM), matched filter and decisions (digital), equalized OFDM.",
        inputs: [PortSpec("signal", "Signal", [.iq])],
        outputs: [
          PortSpec("audio", "Audio", [.audio]), PortSpec("bits", "Bits", [.bits]), PortSpec("symbols", "Symbols", [.iq]),
          PortSpec("evm", "EVM (%)", [.control]), PortSpec("ber", "BER", [.control]),
        ],
        params: modemParams(includePayload: true),
        provenance: [.model], isAudioRate: false)
    case .mixer:
      NodeSpec(
        kind: kind, title: "Mixer", category: .process, symbol: "multiply.circle",
        summary: "Multiplies two signals, or shifts one by a local oscillator when B is empty.",
        inputs: [PortSpec("a", "A", [.audio, .iq]), PortSpec("b", "B", [.audio, .iq])],
        outputs: [PortSpec("out", "Out", [.audio, .iq], follows: "a")],
        params: [
          .number(
            "lo", "Local osc.", glyph: "f", range: -24_000...24_000, value: 1000, format: .frequency,
            detents: [ParamDetent(0, "Off")], hint: "Shift applied when B is empty (complex for I/Q).")
        ],
        provenance: [.model], isAudioRate: false)
    case .filter:
      NodeSpec(
        kind: kind, title: "Filter", category: .process, symbol: "line.3.horizontal.decrease.circle",
        summary: "A second-order low-pass, high-pass, band-pass or notch (RBJ biquad).",
        inputs: [PortSpec("in", "In", [.audio, .iq])],
        outputs: [PortSpec("out", "Out", [.audio, .iq], follows: "in")],
        params: [
          .choice(
            "response", "Response",
            [ParamOption("lowpass", "Low-pass"), ParamOption("highpass", "High-pass"), ParamOption("bandpass", "Band-pass"), ParamOption("bandstop", "Notch")],
            value: "lowpass"),
          .number(
            "f", "Corner", glyph: "fc", range: 0.1...1e7, value: 3000, log: true, format: .frequency,
            detents: [ParamDetent(60, "Mains 60 Hz"), ParamDetent(3000, "Voice 3 kHz")], hint: "Corner or center frequency."),
          .number("q", "Q", glyph: "Q", range: 0.3...20, value: 0.707, log: true, format: .plain(""), hint: "Sharpness."),
        ],
        provenance: [.model], isAudioRate: false)
    case .gain:
      NodeSpec(
        kind: kind, title: "Gain", category: .process, symbol: "plusminus.circle",
        summary: "Scales a signal or a control value.",
        inputs: [PortSpec("in", "In", [.audio, .iq, .control])],
        outputs: [PortSpec("out", "Out", [.audio, .iq, .control], follows: "in")],
        params: [
          .number(
            "gain", "Gain", glyph: "G", range: -60...40, value: 0, format: .decibels("dB"),
            detents: [ParamDetent(0, "Unity")], hint: "Amplitude gain in decibels.")
        ],
        provenance: [.model], isAudioRate: false)
    case .envelope:
      NodeSpec(
        kind: kind, title: "Envelope follower", category: .process, symbol: "scribble.variable",
        summary: "Gyre's conditioner: loudness above a slowly adapting floor, 0…1, plus onsets. Steady hums drive nothing.",
        inputs: [PortSpec("in", "In", [.audio])],
        outputs: [PortSpec("env", "Envelope", [.control]), PortSpec("onsets", "Onsets", [.event])],
        params: [
          .number("gain", "Input gain", glyph: "G", range: -20...40, value: 0, format: .decibels("dB"))
        ],
        provenance: [.model], isAudioRate: false)
    case .antenna:
      NodeSpec(
        kind: kind, title: "Antenna", category: .process, symbol: "antenna.radiowaves.left.and.right",
        summary:
          "Transmit: the signal leaves with this antenna's gain toward the far end. Receive: cable its Gain into a Channel's Rx gain. The pattern turns with the phone or a steering input.",
        inputs: [
          PortSpec("signal", "Signal", [.iq]), PortSpec("attitude", "Attitude", [.attitude]),
          PortSpec("steer", "Steer (sin θ)", [.control]),
        ],
        outputs: [PortSpec("signal", "Signal", [.iq]), PortSpec("gain", "Gain (dBi)", [.control])],
        params: [
          .choice(
            "style", "Style",
            [
              ParamOption("dipole", "Dipole"), ParamOption("patch", "Patch"), ParamOption("yagi", "Yagi"),
              ParamOption("horn", "Horn"), ParamOption("dish", "Dish"), ParamOption("phasedArray", "Phased array"),
              ParamOption("pifa", "PIFA (phone)"),
            ], value: "phasedArray"),
          .number(
            "frequency", "Carrier", glyph: "f", range: 1e6...1e11, value: 28e9, log: true, format: .frequency,
            detents: carrierDetents, hint: "Used when the signal carries no carrier of its own."),
          .number("elements", "Elements", glyph: "N", range: 2...32, value: 8, step: 1, format: .integer(""), hint: "Phased array elements."),
          .number(
            "steer", "Steer", glyph: "θ₀", range: -60...60, value: 0, format: .degrees, detents: [ParamDetent(0, "Broadside")],
            hint: "Phased array beam angle from broadside."),
          .number(
            "farEnd", "Far end", glyph: "θ", range: -90...90, value: 0, format: .degrees, detents: [ParamDetent(0, "Overhead")],
            hint: "Direction of the receiver, from straight up toward the phone's right."),
          ParamSpec("follow", "Follow phone", .toggle(defaultValue: false), hint: "Turn the pattern with the attitude input."),
          ParamSpec("beamLock", "Beam lock", .toggle(defaultValue: false), hint: "Re-steer the array to keep pointing at the far end."),
        ],
        provenance: [.model], isAudioRate: false)
    case .channel:
      NodeSpec(
        kind: kind, title: "Channel", category: .process, symbol: "building.2",
        summary: "The path between antennas: link budget (distance, environment, walls) sets the noise; multipath and fading shape the signal.",
        inputs: [PortSpec("signal", "Signal", [.iq]), PortSpec("rxGain", "Rx gain (dBi)", [.control])],
        outputs: [
          PortSpec("signal", "Signal", [.iq]), PortSpec("snr", "SNR (dB)", [.control]),
          PortSpec("rxPower", "Rx (dBm)", [.control]),
        ],
        params: [
          .number(
            "distance", "Distance", glyph: "d", range: 0.1...4e7, value: 10, log: true, format: .distance,
            detents: [
              ParamDetent(1, "1 m"), ParamDetent(5, "Room"), ParamDetent(15, "House"), ParamDetent(1000, "1 km"),
              ParamDetent(20_200e3, "GPS orbit"),
            ], hint: "Distance between the antennas."),
          .choice(
            "environment", "Environment",
            [
              ParamOption("freeSpace", "Free space"), ParamOption("indoor", "Indoor office"),
              ParamOption("urban", "Urban macro"), ParamOption("logDistance", "Log-distance n = 3"),
            ], value: "freeSpace"),
          .number("walls", "Walls", glyph: "n", range: 0...6, value: 0, step: 1, format: .integer(""), hint: "Walls in the way."),
          .choice(
            "material", "Wall material",
            [
              ParamOption("concrete", "Concrete"), ParamOption("glass", "Glass"), ParamOption("irrGlass", "IRR glass"),
              ParamOption("wood", "Wood"),
            ], value: "concrete"),
          .number("txPower", "Tx power", glyph: "Pt", range: -30...40, value: 20, format: .decibels("dBm")),
          .number("noiseFigure", "Noise figure", glyph: "NF", range: 0...20, value: 7, format: .decibels("dB")),
          .number(
            "spread", "Delay spread", glyph: "στ", range: 0...2e-6, value: 0, format: .seconds,
            detents: [ParamDetent(0, "Single path"), ParamDetent(50e-9, "Office 50 ns")], hint: "RMS multipath delay spread."),
          .number("doppler", "Doppler", glyph: "fm", range: 0...500, value: 0, format: .frequency, hint: "Maximum Doppler shift."),
          .choice(
            "fading", "Fading",
            [ParamOption("none", "None"), ParamOption("rayleigh", "Rayleigh"), ParamOption("rician", "Rician K = 5")],
            value: "none"),
        ],
        provenance: [.model], isAudioRate: false)
    case .medium:
      NodeSpec(
        kind: kind, title: "Medium", category: .process, symbol: "cube.transparent",
        summary: "Sends a Spectra wave through a Matter bench specimen and keeps what gets through.",
        inputs: [PortSpec("wave", "Wave", [.em])],
        outputs: [PortSpec("wave", "Wave", [.em]), PortSpec("transmission", "T", [.control])],
        params: [
          .choice(
            "specimen", "Specimen",
            [
              ParamOption("water", "Water 1 cm"), ParamOption("glass", "Glass 3 mm"), ParamOption("zinc", "Zinc 1 mm"),
              ParamOption("dna", "DNA"), ParamOption("hand", "Finger"),
            ], value: "water")
        ],
        provenance: [], isAudioRate: false)
    case .blackbody:
      NodeSpec(
        kind: kind, title: "Blackbody", category: .process, symbol: "flame",
        summary: "A color temperature in kelvin becomes the wave at the peak of that temperature's blackbody curve (Wien).",
        inputs: [PortSpec("temperature", "T (K)", [.control])],
        outputs: [PortSpec("wave", "Peak wave", [.em]), PortSpec("peak", "λ peak (m)", [.control])],
        params: [
          .number(
            "temperature", "Temperature", glyph: "T", range: 300...30_000, value: 5772, log: true, format: .plain("K"),
            detents: [ParamDetent(2700, "Warm lamp 2,700 K"), ParamDetent(5772, "Sun 5,772 K"), ParamDetent(6500, "Daylight 6,500 K")],
            hint: "Used when nothing drives the T input.")
        ],
        provenance: [.model], isAudioRate: false)
    case .fft:
      NodeSpec(
        kind: kind, title: "FFT", category: .process, symbol: "function",
        summary: "Hann-windowed Fourier transform: real signals one-sided to fs/2, I/Q two-sided around the carrier.",
        inputs: [PortSpec("in", "In", [.audio, .iq])],
        outputs: [PortSpec("spectrum", "Spectrum", [.spectrum]), PortSpec("peak", "Peak (Hz)", [.control])],
        params: [
          .choice(
            "size", "Size",
            [ParamOption("256", "256"), ParamOption("1024", "1,024"), ParamOption("4096", "4,096"), ParamOption("8192", "8,192")],
            value: "4096", hint: "Points per transform: more is finer in frequency, slower in time."),
          .number("average", "Averaging", glyph: "α", range: 0...0.95, value: 0.5, format: .percent, hint: "Smooths successive spectra."),
        ],
        provenance: [.model], isAudioRate: false)
    case .wigner:
      NodeSpec(
        kind: kind, title: "Wigner", category: .process, symbol: "square.grid.3x3.fill",
        summary: "Time–frequency picture of a stream in Utkarsh's convention (C): Wigner–Ville, pseudo-Wigner or spectrogram.",
        inputs: [PortSpec("in", "In", [.audio, .iq])],
        outputs: [PortSpec("image", "Image", [.image])],
        params: [
          .choice(
            "mode", "View",
            [
              ParamOption("wignerVille", "Wigner–Ville"), ParamOption("pseudoWigner", "Pseudo-Wigner"),
              ParamOption("smoothedPseudoWigner", "Smoothed"), ParamOption("spectrogram", "Spectrogram"),
            ], value: "wignerVille"),
          .choice(
            "length", "Record",
            [ParamOption("256", "256"), ParamOption("512", "512"), ParamOption("1024", "1,024"), ParamOption("2048", "2,048"), ParamOption("4096", "4,096")],
            value: "1024", hint: "Samples in the analyzed record."),
        ],
        provenance: [.model], isAudioRate: false)
    case .marginal:
      NodeSpec(
        kind: kind, title: "Marginal", category: .process, symbol: "chart.bar.doc.horizontal",
        summary: "Integrates a Wigner image: over frequency gives |x(t)|², over time gives |X(ν)|². Exact for the unsmoothed Wigner.",
        inputs: [PortSpec("image", "Image", [.image])],
        outputs: [
          PortSpec("time", "|x(t)|²", [.audio]), PortSpec("frequency", "|X(ν)|²", [.spectrum]),
          PortSpec("error", "M1 error", [.control]),
        ],
        params: [],
        provenance: [.model], isAudioRate: false)

    // MARK: Sinks
    case .scope:
      NodeSpec(
        kind: kind, title: "Scope", category: .sinks, symbol: "waveform.path.ecg",
        summary: "The oscilloscope, fed by up to four cables. Each input becomes a stream on the scope bus.",
        inputs: [
          PortSpec("ch1", "CH1", [.audio, .iq, .control]), PortSpec("ch2", "CH2", [.audio, .iq, .control]),
          PortSpec("ch3", "CH3", [.audio, .iq, .control]), PortSpec("ch4", "CH4", [.audio, .iq, .control]),
        ],
        outputs: [], params: [], provenance: [], isAudioRate: false)
    case .spectrum:
      NodeSpec(
        kind: kind, title: "Spectrum / waterfall", category: .sinks, symbol: "chart.bar.xaxis",
        summary: "Draws a spectrum with its waterfall, or a time–frequency image.",
        inputs: [PortSpec("in", "In", [.spectrum, .image])],
        outputs: [],
        params: [
          ParamSpec("log", "Log frequency", .toggle(defaultValue: false)),
          .number("floor", "Floor", glyph: "dB", range: -200...(-20), value: -120, format: .decibels("dB"), hint: "Bottom of the dB axis."),
        ],
        provenance: [], isAudioRate: false)
    case .constellation:
      NodeSpec(
        kind: kind, title: "Constellation", category: .sinks, symbol: "circle.grid.3x3",
        summary: "Received symbols as dots over the ideal points.",
        inputs: [PortSpec("in", "Symbols", [.iq])],
        outputs: [],
        params: [.number("range", "Range", range: 0.5...3, value: 1.5, format: .plain(""), hint: "Half-width of the plot.")],
        provenance: [], isAudioRate: false)
    case .speaker:
      NodeSpec(
        kind: kind, title: "Speaker", category: .sinks, symbol: "speaker.wave.2.fill",
        summary: "Plays audio through the synth. Sound must be on in Settings; a live microphone plays only through headphones or Bluetooth.",
        inputs: [PortSpec("in", "In", [.audio])],
        outputs: [],
        params: [.number("level", "Level", glyph: "A", range: 0...1, value: 0.7, format: .percent)],
        provenance: [], isAudioRate: false)
    case .haptics:
      NodeSpec(
        kind: kind, title: "Haptics (Feel)", category: .sinks, symbol: "iphone.radiowaves.left.and.right",
        summary: "Feel a signal: intensity drives the continuous hum (Settings → Continuous hum), events tap.",
        inputs: [PortSpec("intensity", "Intensity", [.control, .audio]), PortSpec("events", "Events", [.event])],
        outputs: [],
        params: [
          .number("gain", "Gain", glyph: "G", range: 0...4, value: 1, format: .plain("×")),
          .number("sharpness", "Sharpness", range: 0...1, value: 0.5, format: .percent),
        ],
        provenance: [], isAudioRate: false)
    case .ruler:
      NodeSpec(
        kind: kind, title: "Spectrum ruler", category: .sinks, symbol: "ruler",
        summary: "Places a wave or a frequency on the Spectrum strip, and tunes the Spectrum tab to it: the loop.",
        inputs: [PortSpec("in", "λ or f (Hz)", [.em, .control])],
        outputs: [],
        params: [ParamSpec("continuous", "Tune continuously", .toggle(defaultValue: false), hint: "Keep Spectrum source A on this value.")],
        provenance: [], isAudioRate: false)
    case .knob:
      NodeSpec(
        kind: kind, title: "Knob target", category: .sinks, symbol: "dial.medium",
        summary: "The modulation matrix: a control signal turns any knob, applied in knob position so log knobs move musically.",
        inputs: [PortSpec("cv", "CV", [.control])],
        outputs: [],
        params: [
          ParamSpec("target", "Target", .target, hint: "The knob this signal drives."),
          .number("depth", "Depth", glyph: "d", range: -1...1, value: 0.5, format: .percent, detents: [ParamDetent(0, "Off")],
            hint: "How far a full-scale signal turns the knob."),
        ],
        provenance: [], isAudioRate: false)
    }
  }

  /// Shared Modulator/Demodulator parameters (they must match on both ends of a link).
  static func modemParams(includePayload: Bool) -> [ParamSpec] {
    var p: [ParamSpec] = [
      includePayload
        ? .choice(
          "mode", "Mode", [ParamOption("auto", "Match the signal")] + modulationModes, value: "auto",
          hint: "Match the signal reads how the Modulator built it; any other mode forces that receiver.")
        : .choice("mode", "Mode", modulationModes, value: "am"),
      .number(
        "depth", "AM depth", glyph: "m", range: 0.05...1, value: 0.8, format: .percent,
        detents: [ParamDetent(0.8, "m = 0.8")], hint: "AM modulation index."),
      .number(
        "deviation", "FM deviation", glyph: "Δf", range: 100...75_000, value: 5000, log: true, format: .frequency,
        detents: [ParamDetent(2500, "FRS 2.5 kHz"), ParamDetent(5000, "Narrowband 5 kHz"), ParamDetent(75_000, "Broadcast 75 kHz")],
        hint: "Peak frequency deviation for a full-scale message."),
      .number(
        "symbolRate", "Symbol rate", glyph: "Rs", range: 300...1e6, value: 32_000, log: true, format: .symbolRate,
        hint: "Symbols per second (keyed and QAM modes)."),
      .choice("order", "OFDM QAM", ofdmOrders, value: "qam1024", hint: "Subcarrier modulation for OFDM."),
      .number(
        "carrier", "Carrier", glyph: "fc", range: 1e3...3e11, value: 462.6e6, log: true, format: .frequency,
        detents: carrierDetents, hint: "The carrier the baseband sits on (a label: GHz cannot be sampled)."),
    ]
    if includePayload {
      p.append(
        .choice(
          "payload", "Payload", [ParamOption("data", "Data bits"), ParamOption("voice", "Voice (µ-law 8 kHz)")], value: "data",
          hint: "Digital modes: decode the bits as µ-law voice."))
    }
    return p
  }

  /// The add-node palette: catalogue kinds plus sensor shortcuts that are Live stream nodes
  /// bound to a stream.
  static let palette: [PaletteItem] = [
    PaletteItem(id: "spectraSource", kind: .spectraSource),
    PaletteItem(id: "oscillator", kind: .oscillator),
    PaletteItem(id: "noise", kind: .noise),
    PaletteItem(id: "bits", kind: .bits),
    PaletteItem(
      id: "microphone", kind: .stream, title: "Microphone", symbol: "mic.fill", stream: "mic.left",
      summary: "48 kHz sound from the microphone (ANALOGY: sound, not light)."),
    PaletteItem(
      id: "magnetometer", kind: .stream, title: "Magnetometer", symbol: "location.north.line", stream: "mag.norm",
      summary: "|B| in µT at about 100 Hz: Earth's field plus mains hum, aliased."),
    PaletteItem(id: "motion", kind: .motion),
    PaletteItem(
      id: "barometer", kind: .stream, title: "Barometer", symbol: "barometer", stream: "baro.pressure",
      summary: "Air pressure in pascals, once a second."),
    PaletteItem(
      id: "ble", kind: .stream, title: "Bluetooth RSSI", symbol: "dot.radiowaves.left.and.right", stream: "ble.*",
      summary: "Received strength of the strongest nearby Bluetooth device, in dBm (event-driven)."),
    PaletteItem(
      id: "light", kind: .stream, title: "Light", symbol: "sun.max", stream: "light.lux",
      summary: "Illuminance in lux from the camera light meter."),
    PaletteItem(
      id: "anyStream", kind: .stream, title: "Any stream…", symbol: "waveform.path.ecg", stream: "",
      summary: "Pick any signal on the scope bus."),
    PaletteItem(id: "gyroscope", kind: .gyroscope),
    PaletteItem(id: "spinFID", kind: .spinFID),
    PaletteItem(id: "modulator", kind: .modulator),
    PaletteItem(id: "demodulator", kind: .demodulator),
    PaletteItem(id: "mixer", kind: .mixer),
    PaletteItem(id: "filter", kind: .filter),
    PaletteItem(id: "gain", kind: .gain),
    PaletteItem(id: "envelope", kind: .envelope),
    PaletteItem(id: "antenna", kind: .antenna),
    PaletteItem(id: "channel", kind: .channel),
    PaletteItem(id: "medium", kind: .medium),
    PaletteItem(id: "blackbody", kind: .blackbody),
    PaletteItem(id: "fft", kind: .fft),
    PaletteItem(id: "wigner", kind: .wigner),
    PaletteItem(id: "marginal", kind: .marginal),
    PaletteItem(id: "scope", kind: .scope),
    PaletteItem(id: "spectrum", kind: .spectrum),
    PaletteItem(id: "constellation", kind: .constellation),
    PaletteItem(id: "speaker", kind: .speaker),
    PaletteItem(id: "haptics", kind: .haptics),
    PaletteItem(id: "ruler", kind: .ruler),
    PaletteItem(id: "knob", kind: .knob),
  ]
}

/// One entry of the add-node palette.
nonisolated struct PaletteItem: Sendable, Hashable, Identifiable {
  let id: String
  let kind: NodeKind
  let title: String
  let symbol: String
  /// For Live stream shortcuts: the stream id ("ble.*" = strongest Bluetooth device).
  let stream: String?
  let summary: String

  init(id: String, kind: NodeKind, title: String? = nil, symbol: String? = nil, stream: String? = nil, summary: String? = nil) {
    self.id = id
    self.kind = kind
    self.title = title ?? kind.spec.title
    self.symbol = symbol ?? kind.spec.symbol
    self.stream = stream
    self.summary = summary ?? kind.spec.summary
  }

  var category: NodeCategory { kind.spec.category }
}
