import Foundation
import simd

/// Card geometry shared by the presets and the canvas, so cable ends can be computed without
/// measuring views (points, at zoom 1).
nonisolated enum PatchGeometry {
  static let cardWidth = 172.0
  static let headerHeight = 46.0
  static let previewHeight = 54.0
  static let portRowHeight = 24.0
  static let portsTop = headerHeight + previewHeight + 8
  static let footerHeight = 30.0
  static let columnPitch = 212.0
  static let rowPitch = 296.0
  /// Two port rows, in row pitches: a card set this much below its row's line keeps its ports
  /// from facing a neighbour's at the same height.
  static let portDrop = 2 * portRowHeight / rowPitch

  static func height(of kind: NodeKind) -> Double {
    let s = kind.spec
    return portsTop + Double(max(1, max(s.inputs.count, s.outputs.count))) * portRowHeight + footerHeight
  }

  /// The control points of a cable's Bézier from an output at `a` to an input at `b` (canvas
  /// points at `zoom`): it leaves and arrives horizontally, at least 48 pt out. The canvas draws
  /// this curve; `cablePoints` samples it (new cards keep clear of cables; tests check layouts).
  static func cableControls(from a: SIMD2<Double>, to b: SIMD2<Double>, zoom: Double = 1) -> (SIMD2<Double>, SIMD2<Double>) {
    let dx = max(48 * zoom, abs(b.x - a.x) * 0.5)
    return (SIMD2(a.x + dx, a.y), SIMD2(b.x - dx, b.y))
  }

  /// `count` points along a cable's Bézier (zoom 1), ends excluded.
  static func cablePoints(from a: SIMD2<Double>, to b: SIMD2<Double>, count: Int) -> [SIMD2<Double>] {
    let (c1, c2) = cableControls(from: a, to: b)
    return (1...max(1, count)).map { k in
      let t = Double(k) / Double(count + 1)
      let u = 1 - t
      return u * u * u * a + 3 * u * u * t * c1 + 3 * u * t * t * c2 + t * t * t * b
    }
  }

  /// Centre of a port relative to the card's top-left corner.
  static func portOffset(kind: NodeKind, port: String, isInput: Bool) -> (x: Double, y: Double)? {
    let s = kind.spec
    let list = isInput ? s.inputs : s.outputs
    guard let i = list.firstIndex(where: { $0.name == port }) else { return nil }
    return (isInput ? 0 : cardWidth, portsTop + (Double(i) + 0.5) * portRowHeight)
  }
}

/// A ready-made patch (SPEC-features §5).
nonisolated struct PatchPreset: Sendable, Identifiable {
  let id: String
  let title: String
  /// One plain sentence: what it shows.
  let summary: String
  let symbol: String
  let graph: PatchGraph
  /// Cables that failed to connect while building (always empty; tests check it).
  let problems: [String]

  static let all: [PatchPreset] = [
    earthNMR, voiceAM, voiceFM, wifiOFDM, bleLive, mainsHum, gyroArray, lightSpectrum,
  ]

  /// The patch a fresh install opens with (needs no permission prompt).
  static let starter = earthNMR

  static func named(_ id: String) -> PatchPreset? {
    all.first { $0.id.caseInsensitiveCompare(id) == .orderedSame }
  }

  // MARK: Builder

  private struct Builder {
    var graph = PatchGraph()
    var problems: [String] = []

    mutating func put(
      _ kind: NodeKind, _ col: Double, _ row: Double, label: String? = nil, numbers: [String: Double] = [:],
      strings: [String: String] = [:]
    ) -> String {
      var n = graph.add(kind, x: col * PatchGeometry.columnPitch, y: row * PatchGeometry.rowPitch)
      n.label = label
      n.numbers = numbers
      n.strings = strings
      if let i = graph.index(of: n.id) { graph.nodes[i] = n }
      return n.id
    }

    mutating func put(
      _ kind: NodeKind, _ col: Double, _ row: Double, label: String? = nil, strings: [String: String],
      numbers: [String: Double]
    ) -> String {
      put(kind, col, row, label: label, numbers: numbers, strings: strings)
    }

    mutating func wire(_ a: String, _ ap: String, _ b: String, _ bp: String) {
      do {
        try graph.connect(from: PortRef(a, ap), to: PortRef(b, bp))
      } catch {
        problems.append("\(a).\(ap) → \(b).\(bp): \(error)")
      }
    }

    func preset(_ id: String, _ title: String, _ summary: String, symbol: String) -> PatchPreset {
      PatchPreset(id: id, title: title, summary: summary, symbol: symbol, graph: graph, problems: problems)
    }
  }

  // MARK: The eight presets

  static let earthNMR: PatchPreset = {
    var b = Builder()
    let mag = b.put(.stream, 0, 0, label: "Magnetometer |B|", strings: ["stream": "mag.norm"])
    let fid = b.put(.spinFID, 1, 0, numbers: ["repeat": 2, "t2": 0.5, "level": 0.5])
    let speaker = b.put(.speaker, 2, 0, numbers: ["level": 0.7])
    // Every cable runs through a gap, none behind a card or past another card's port: the
    // Wigner sits under the spin, with its picture below it and the Marginal to its right;
    // the FFT and the ruler hang off the right-hand gap. (Ids stay n1…n9 in this order:
    // launch arguments and UI tests name them.)
    let ruler = b.put(.ruler, 2, 2)
    let fft = b.put(.fft, 2, 1, strings: ["size": "8192"], numbers: ["average": 0.3])
    let spectrum = b.put(.spectrum, 1, 2, numbers: ["floor": -120])
    let wigner = b.put(.wigner, 0, 1, strings: ["mode": "wignerVille", "length": "512"])
    let marginal = b.put(.marginal, 1, 1)
    let picture = b.put(.spectrum, 0, 2, label: "Time–frequency")
    b.wire(mag, "value", fid, "field")
    b.wire(fid, "audio", speaker, "in")
    b.wire(fid, "larmor", ruler, "in")
    b.wire(fid, "audio", fft, "in")
    b.wire(fft, "spectrum", spectrum, "in")
    b.wire(fid, "iq", wigner, "in")
    b.wire(wigner, "image", marginal, "image")
    b.wire(wigner, "image", picture, "in")
    return b.preset(
      "earthNMR", "Earth-field NMR you can hear",
      "Your magnetometer's |B| sets the precession of protons in water: about 2.1 kHz in Earth's field, played at true pitch; the Wigner picture shows each ring-down fade.",
      symbol: "atom")
  }()

  private static func voice(_ id: String, _ title: String, mode: String, carrier: Double, summary: String) -> PatchPreset {
    var b = Builder()
    // The link runs along the top row and swings back into the receiver below; each cable
    // runs through a gap, none behind a card it does not plug into (the microphone's cable to
    // CH2 used to run behind the Modulator and look like its output). Ids n1…n8 keep this order.
    let mic = b.put(.stream, 0, 0, label: "Microphone", strings: ["stream": "mic.left"])
    let mod = b.put(
      .modulator, 1, 0, strings: ["mode": mode],
      numbers: ["carrier": carrier, "depth": 0.8, "deviation": 5000])
    let scope = b.put(.scope, 1, 1)
    let channel = b.put(
      .channel, 2, 0, strings: ["environment": "logDistance"],
      numbers: mode == "am"
        ? ["distance": 30_000, "txPower": 36, "noiseFigure": 7]
        : ["distance": 2000, "txPower": 27, "noiseFigure": 7])
    let demod = b.put(.demodulator, 0, 1, strings: ["mode": "auto"])
    let speaker = b.put(.speaker, 0, 2, numbers: ["level": 0.7])
    let fft = b.put(.fft, 2, 1, strings: ["size": "4096"], numbers: ["average": 0.6])
    let spectrum = b.put(.spectrum, 2, 2, numbers: ["floor": -110])
    b.wire(mic, "samples", mod, "message")
    b.wire(mod, "signal", channel, "signal")
    b.wire(channel, "signal", demod, "signal")
    b.wire(demod, "audio", speaker, "in")
    b.wire(demod, "audio", scope, "ch1")
    b.wire(mic, "samples", scope, "ch2")
    b.wire(channel, "signal", fft, "in")
    b.wire(fft, "spectrum", spectrum, "in")
    return b.preset(id, title, summary, symbol: "mic.fill")
  }

  static let voiceAM = voice(
    "voiceAM", "Voice over AM", mode: "am", carrier: 27.185e6,
    summary: "Your voice rides a 27 MHz CB carrier as its envelope (m = 0.8), crosses 30 km, and an envelope detector brings it back.")

  static let voiceFM = voice(
    "voiceFM", "Voice over FM", mode: "fm", carrier: 462.6e6,
    summary: "Narrowband FM at 462.6 MHz (Δf 5 kHz): the voice becomes phase; past the threshold near 10 dB it breaks into noise.")

  static let wifiOFDM: PatchPreset = {
    var b = Builder()
    // The transmitter along the top; the Channel fans down into the receiver, the FFT and the
    // Scope. Every cable passes through a gap, clear of other cards and of other cabled ports,
    // and no two unrelated cabled ports face each other across a gap (the FFT sits half a
    // port row low for that). Ids n1…n8 keep this order.
    let bits = b.put(.bits, 0, 0, strings: ["mode": "random", "block": "32768"])
    let mod = b.put(.modulator, 1, 0, strings: ["mode": "ofdm", "order": "qam1024"], numbers: ["carrier": 5.5e9])
    let scope = b.put(.scope, 2, 1)
    let channel = b.put(
      .channel, 2, 0, strings: ["environment": "indoor", "material": "wood"],
      numbers: ["distance": 6, "walls": 2, "txPower": 20, "noiseFigure": 7])
    let demod = b.put(.demodulator, 1, 1, strings: ["mode": "auto"])
    let constellation = b.put(.constellation, 2, 2, numbers: ["range": 1.4])
    let fft = b.put(.fft, 0, 1 + PatchGeometry.portDrop, strings: ["size": "4096"], numbers: ["average": 0.7])
    let spectrum = b.put(.spectrum, 0, 2, numbers: ["floor": -90])
    b.wire(bits, "bits", mod, "message")
    b.wire(mod, "signal", channel, "signal")
    b.wire(channel, "signal", demod, "signal")
    b.wire(demod, "symbols", constellation, "in")
    b.wire(channel, "snr", scope, "ch1")
    b.wire(demod, "evm", scope, "ch2")
    b.wire(channel, "signal", fft, "in")
    b.wire(fft, "spectrum", spectrum, "in")
    return b.preset(
      "wifiOFDM", "Wi-Fi 6 OFDM through two walls",
      "1024-QAM on 242 subcarriers needs about 35 dB of SNR. Two wooden walls and a few meters decide whether it gets it.",
      symbol: "wifi")
  }()

  static let bleLive: PatchPreset = {
    var b = Builder()
    // The modelled link and the live RSSI meet at the Scope from the left: no cable comes back
    // past another card's ports (the model's cable used to hook into CH2 beside the RSSI's), and
    // the RSSI's Value runs straight across into CH2.
    let ble = b.put(.stream, 1, 0, label: "Bluetooth RSSI", strings: ["stream": "ble.*"])
    let scope = b.put(.scope, 2, 0)
    let bits = b.put(.bits, 0, 0, strings: ["mode": "random", "block": "1024"])
    let mod = b.put(.modulator, 0, 1, strings: ["mode": "fsk"], numbers: ["carrier": 2.44e9, "symbolRate": 1e6])
    let channel = b.put(
      .channel, 1, 1, strings: ["environment": "logDistance"], numbers: ["distance": 3, "txPower": 0, "noiseFigure": 7])
    let demod = b.put(.demodulator, 2, 1, strings: ["mode": "auto"])
    b.wire(channel, "rxPower", scope, "ch1")
    b.wire(ble, "value", scope, "ch2")
    b.wire(bits, "bits", mod, "message")
    b.wire(mod, "signal", channel, "signal")
    b.wire(channel, "signal", demod, "signal")
    return b.preset(
      "bleLive", "Live BLE link vs model",
      "CH1 is the log-distance model (n = 3) at the distance you set; CH2 is the strongest nearby Bluetooth device's live RSSI.",
      symbol: "dot.radiowaves.left.and.right")
  }()

  static let mainsHum: PatchPreset = {
    var b = Builder()
    let mag = b.put(.stream, 0, 0, label: "Magnetometer |B|", strings: ["stream": "mag.norm"])
    let hp = b.put(.filter, 1, 0, strings: ["response": "highpass"], numbers: ["f": 5, "q": 0.707])
    let scope = b.put(.scope, 2, 0)
    // The FFT under the filter, so its peak reaches CH2 through the gap (not behind the
    // spectrum's card).
    let fft = b.put(.fft, 1, 1, strings: ["size": "256"], numbers: ["average": 0.6])
    let spectrum = b.put(.spectrum, 2, 1, numbers: ["floor": -90])
    b.wire(mag, "samples", hp, "in")
    b.wire(hp, "out", scope, "ch1")
    b.wire(hp, "out", fft, "in")
    b.wire(fft, "spectrum", spectrum, "in")
    b.wire(fft, "peak", scope, "ch2")
    return b.preset(
      "mainsHum", "Mains hum on the magnetometer",
      "The magnetometer samples near 100 Hz, so 60 Hz mains shows up aliased near 40 Hz (50 Hz sits right on Nyquist).",
      symbol: "location.north.line")
  }()

  static let gyroArray: PatchPreset = {
    var b = Builder()
    // The link along the top two rows, the gyroscope's steering along the bottom row, up into
    // the antenna through the right-hand gap. (Ids stay n1…n9 in this order.)
    let gyro = b.put(.gyroscope, 0, 2, numbers: ["rpm": 3000, "time": 1])
    // Half a port row low, so its output does not face the Constellation's input.
    let gain = b.put(.gain, 1, 2 + PatchGeometry.portDrop, numbers: ["gain": 6])
    let scope = b.put(.scope, 2, 1)
    let bits = b.put(.bits, 0, 0, strings: ["mode": "random", "block": "1024"])
    let mod = b.put(.modulator, 1, 0, strings: ["mode": "qpsk"], numbers: ["carrier": 28e9, "symbolRate": 1e6])
    let antenna = b.put(
      .antenna, 2, 0, strings: ["style": "phasedArray"], numbers: ["elements": 8, "farEnd": 20, "frequency": 28e9])
    let channel = b.put(.channel, 0, 1, strings: ["environment": "freeSpace"], numbers: ["distance": 200, "txPower": 10])
    let demod = b.put(.demodulator, 1, 1, strings: ["mode": "auto"])
    let constellation = b.put(.constellation, 2, 2, numbers: ["range": 1.6])
    b.wire(gyro, "tipX", gain, "in")
    b.wire(gain, "out", antenna, "steer")
    b.wire(bits, "bits", mod, "message")
    b.wire(mod, "signal", antenna, "signal")
    b.wire(antenna, "signal", channel, "signal")
    b.wire(channel, "signal", demod, "signal")
    b.wire(demod, "symbols", constellation, "in")
    b.wire(antenna, "gain", scope, "ch1")
    // CH2 is the receiver's EVM, from the card beside the Scope: a cable from the Channel's SNR
    // would run behind the Demodulator. The Channel card shows the SNR itself.
    b.wire(demod, "evm", scope, "ch2")
    return b.preset(
      "gyroArray", "Gyroscope steers a phased array",
      "The precessing axle's tip steers an 8-element 28 GHz array. As the beam swings past the receiver at 20°, the gain, the link's SNR and the QPSK cloud breathe.",
      symbol: "gyroscope")
  }()

  static let lightSpectrum: PatchPreset = {
    var b = Builder()
    // The loop along the bottom row; the Scope above it takes both streams from the left (the
    // color temperature's cable used to climb past the light level's Value port).
    let cct = b.put(.stream, 0, 1, label: "Light color temperature", strings: ["stream": "light.cct"])
    let body = b.put(.blackbody, 1, 1)
    let ruler = b.put(.ruler, 2, 1, numbers: ["continuous": 1])
    let lux = b.put(.stream, 0, 0, label: "Light level", strings: ["stream": "light.lux"])
    let scope = b.put(.scope, 1, 0)
    b.wire(cct, "value", body, "temperature")
    b.wire(body, "wave", ruler, "in")
    b.wire(cct, "value", scope, "ch1")
    b.wire(lux, "value", scope, "ch2")
    return b.preset(
      "lightSpectrum", "Light meter → Spectrum",
      "The camera's color temperature picks the blackbody whose peak tunes Spectrum source A: a 3,100 K lamp peaks in the infrared.",
      symbol: "sun.max")
  }()
}
