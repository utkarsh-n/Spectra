import Foundation

nonisolated extension RF {
  /// How the OFDM receiver learns the channel.
  enum OFDMChannelEstimation: String, Codable, Hashable, Sendable {
    /// Scattered pilots: least squares at the pilots, linear interpolation across frequency
    /// (LTE/NR reference signals, DVB-T scattered pilots).
    case pilots
    /// A training symbol at the start of every frame carries a known ±1 on every used
    /// subcarrier (Wi-Fi's long training field); pilots then only track the common phase.
    case preamble
  }

  /// OFDM numerology for a simulation: FFT size, cyclic prefix, which subcarriers carry data and
  /// which carry pilots (signed indices, DC = 0, negative = below the carrier). Δf = 1/T_u and the
  /// sample rate is N·Δf (rf-physics D.9).
  struct OFDMConfig: Hashable, Codable, Sendable {
    var name: String
    var fftSize: Int
    var cyclicPrefix: Int
    /// Data subcarriers (signed indices), sorted ascending.
    var dataSubcarriers: [Int]
    /// Pilot subcarriers (signed indices), sorted ascending; pilots carry +1 (BPSK).
    var pilotSubcarriers: [Int]
    /// Real-system subcarrier spacing this configuration stands for (for labels), Hz.
    var subcarrierSpacing: Double
    var estimation: OFDMChannelEstimation

    init(
      name: String, fftSize: Int, cyclicPrefix: Int, dataSubcarriers: [Int], pilotSubcarriers: [Int], subcarrierSpacing: Double,
      estimation: OFDMChannelEstimation = .pilots
    ) {
      self.name = name
      self.fftSize = fftSize
      self.cyclicPrefix = cyclicPrefix
      self.dataSubcarriers = dataSubcarriers.sorted()
      self.pilotSubcarriers = pilotSubcarriers.sorted()
      self.subcarrierSpacing = subcarrierSpacing
      self.estimation = estimation
    }

    private enum CodingKeys: String, CodingKey {
      case name, fftSize, cyclicPrefix, dataSubcarriers, pilotSubcarriers, subcarrierSpacing, estimation
    }

    init(from decoder: any Decoder) throws {
      let c = try decoder.container(keyedBy: CodingKeys.self)
      self.init(
        name: try c.decode(String.self, forKey: .name), fftSize: try c.decode(Int.self, forKey: .fftSize),
        cyclicPrefix: try c.decode(Int.self, forKey: .cyclicPrefix), dataSubcarriers: try c.decode([Int].self, forKey: .dataSubcarriers),
        pilotSubcarriers: try c.decode([Int].self, forKey: .pilotSubcarriers), subcarrierSpacing: try c.decode(Double.self, forKey: .subcarrierSpacing),
        estimation: try c.decodeIfPresent(OFDMChannelEstimation.self, forKey: .estimation) ?? .pilots)
    }

    /// Samples per OFDM symbol including the cyclic prefix.
    var symbolLength: Int { fftSize + cyclicPrefix }
    /// Used (data + pilot) subcarriers, sorted.
    var usedSubcarriers: [Int] { (dataSubcarriers + pilotSubcarriers).sorted() }
    /// Sample rate N·Δf for the real numerology, Hz.
    var sampleRate: Double { Double(fftSize) * subcarrierSpacing }
    /// Useful symbol time T_u = 1/Δf.
    var usefulDuration: Double { 1 / subcarrierSpacing }
    /// Cyclic-prefix time.
    var cyclicPrefixDuration: Double { Double(cyclicPrefix) / sampleRate }
    /// Occupied bandwidth ≈ (used subcarriers)·Δf.
    var occupiedBandwidth: Double { Double(usedSubcarriers.count) * subcarrierSpacing }
    /// OFDM symbols at the start of each frame that carry training instead of data.
    var trainingSymbols: Int { estimation == .preamble ? 1 : 0 }

    /// 802.11a/g: N = 64, CP 16 (0.8 µs), 48 data subcarriers ±1…±26 except pilots ±7, ±21,
    /// Δf = 312.5 kHz; channel from a training symbol, pilots track phase.
    static let wifiLegacy: OFDMConfig = {
      let pilots = [-21, -7, 7, 21]
      let data = (-26...26).filter { $0 != 0 && !pilots.contains($0) }
      return OFDMConfig(name: "802.11a/g", fftSize: 64, cyclicPrefix: 16, dataSubcarriers: data, pilotSubcarriers: pilots, subcarrierSpacing: 312_500, estimation: .preamble)
    }()

    /// A generic scaled numerology: `fftSize` points, the central `usedFraction` of subcarriers
    /// used (DC skipped), a pilot every `pilotSpacing` used subcarriers (edges included so the
    /// channel estimate never extrapolates far), CP = `cpFraction`·N.
    ///
    /// The FFT size is rounded up to a power of two in 8…65 536 (what `RF.FFT` runs; another size
    /// would make a modulator that cannot be built, so the Fourier page would go silent). The
    /// fractions are clamped to 0…1 (NaN → the defaults).
    static func scaled(
      name: String, fftSize requested: Int, usedFraction requestedUsed: Double = 0.8, pilotSpacing: Int = 6,
      cpFraction requestedCP: Double = 0.07, subcarrierSpacing: Double, estimation: OFDMChannelEstimation = .pilots
    ) -> OFDMConfig {
      let n = RF.DSP.nextPowerOfTwo(min(max(requested, 8), 65_536))
      let usedFraction = requestedUsed.isFinite ? min(max(requestedUsed, 0), 1) : 0.8
      let cpFraction = requestedCP.isFinite ? min(max(requestedCP, 0), 1) : 0.07
      // At least two used subcarriers each side of DC and a pilot spacing of 2 or more, so a
      // symbol always carries data next to its pilots.
      let half = min(max(2, Int(Double(n) * usedFraction / 2)), max(2, n / 2 - 1))
      let used = (-half...half).filter { $0 != 0 }
      let spacing = max(2, pilotSpacing)
      var pilots: [Int] = []
      for (k, sc) in used.enumerated() where k % spacing == 0 { pilots.append(sc) }
      if let last = used.last, pilots.last != last { pilots.append(last) }
      let data = used.filter { !pilots.contains($0) }
      return OFDMConfig(
        name: name, fftSize: n, cyclicPrefix: max(1, Int((Double(n) * cpFraction).rounded())),
        dataSubcarriers: data, pilotSubcarriers: pilots, subcarrierSpacing: subcarrierSpacing, estimation: estimation)
    }

    /// FFT bin of a signed subcarrier index.
    func bin(_ subcarrier: Int) -> Int { (subcarrier + fftSize) % fftSize }

    /// The known ±1 training value on used subcarrier number `u` (position in `usedSubcarriers`),
    /// taken from the 127-chip m-sequence so the training symbol has a noise-like spectrum.
    static func trainingValue(_ u: Int) -> Float { RF.SpreadingCode.mSequence127.chips[u % 127] }
  }

  /// OFDM transmitter: places data and pilots (after a training symbol in `.preamble` mode),
  /// IFFT, cyclic prefix. Output has unit mean power.
  struct OFDMModulator: Sendable {
    let config: OFDMConfig
    private let fft: RF.FFT
    private let scale: Float

    init?(config: OFDMConfig) {
      guard let fft = RF.FFT(count: config.fftSize) else { return nil }
      self.config = config
      self.fft = fft
      scale = 1 / Float(config.usedSubcarriers.count).squareRoot()
    }

    /// Data-carrying OFDM symbols needed for `dataSymbols` constellation points (0 when the
    /// configuration has no data subcarriers).
    func symbolCount(forDataSymbols n: Int) -> Int {
      let perSymbol = config.dataSubcarriers.count
      return perSymbol > 0 ? (n + perSymbol - 1) / perSymbol : 0
    }

    /// Modulates constellation points (zero-padded to whole OFDM symbols). The output holds
    /// `trainingSymbols + symbolCount(forDataSymbols:)` OFDM symbols.
    func modulate(_ data: IQBuffer) -> IQBuffer {
      let perSymbol = config.dataSubcarriers.count
      let dataSymbols = symbolCount(forDataSymbols: data.count)
      let training = config.trainingSymbols
      let n = config.fftSize
      let cp = config.cyclicPrefix
      let used = config.usedSubcarriers
      var out = IQBuffer(count: (training + dataSymbols) * config.symbolLength)
      var grid = IQBuffer(count: n)
      for s in 0..<(training + dataSymbols) {
        grid.zero()
        if s < training {
          for (u, sc) in used.enumerated() { grid.i[config.bin(sc)] = OFDMConfig.trainingValue(u) }
        } else {
          let d0 = (s - training) * perSymbol
          for (k, sc) in config.dataSubcarriers.enumerated() {
            let d = d0 + k
            guard d < data.count else { break }
            grid.i[config.bin(sc)] = data.i[d]
            grid.q[config.bin(sc)] = data.q[d]
          }
          for sc in config.pilotSubcarriers { grid.i[config.bin(sc)] = 1 }
        }
        fft.inverse(&grid, scaled: false)
        let base = s * config.symbolLength
        for t in 0..<n {
          out.i[base + cp + t] = grid.i[t] * scale
          out.q[base + cp + t] = grid.q[t] * scale
        }
        for t in 0..<cp {
          out.i[base + t] = out.i[base + n + t]
          out.q[base + t] = out.q[base + n + t]
        }
      }
      return out
    }
  }

  /// Smooths channel estimates across OFDM symbols (pilot mode) or frames (preamble mode). Each
  /// new estimate's common phase error (CFO, phase noise) against the running average can be
  /// removed first; then the average moves toward it with weight `alpha` (1 = no memory).
  struct PilotTracker: Sendable {
    var alpha: Float
    /// Remove the common phase error before averaging (needed with CFO or Doppler; with few
    /// pilots its own estimation noise costs a little at low SNR).
    var tracksCommonPhase: Bool
    private var re: [Float] = []
    private var im: [Float] = []
    private var updates = 0

    init(alpha: Float, tracksCommonPhase: Bool = true) {
      self.alpha = min(1, max(0.001, alpha))
      self.tracksCommonPhase = tracksCommonPhase
    }

    mutating func reset() {
      re = []
      im = []
      updates = 0
    }

    /// Replaces new estimates (re, im) with the tracked ones. The first 1/alpha updates form a
    /// plain running mean, so the average does not start from one noisy estimate.
    mutating func update(re yRe: inout [Float], im yIm: inout [Float]) {
      let n = yRe.count
      guard re.count == n else {
        re = yRe
        im = yIm
        updates = 1
        return
      }
      updates += 1
      let alpha = max(self.alpha, 1 / Float(updates))
      var sr: Float = 0
      var si: Float = 0
      for p in 0..<n {
        sr += yRe[p] * re[p] + yIm[p] * im[p]
        si += yIm[p] * re[p] - yRe[p] * im[p]
      }
      let mag = (sr * sr + si * si).squareRoot()
      let c = tracksCommonPhase && mag > 0 ? sr / mag : 1
      let s = tracksCommonPhase && mag > 0 ? si / mag : 0
      for p in 0..<n {
        let ar = re[p] * c - im[p] * s
        let ai = re[p] * s + im[p] * c
        re[p] = ar + alpha * (yRe[p] - ar)
        im[p] = ai + alpha * (yIm[p] - ai)
        yRe[p] = re[p]
        yIm[p] = im[p]
      }
    }
  }

  /// Result of OFDM reception.
  struct OFDMReception: Sendable {
    /// Equalized data-subcarrier points, symbol by symbol.
    var data: IQBuffer
    /// Channel estimate on every used subcarrier of the last symbol (sorted subcarrier order).
    var channelEstimate: IQBuffer
    /// Raw (unequalized) data-subcarrier points.
    var raw: IQBuffer
  }

  /// OFDM receiver: drops the CP, FFT, estimates the channel (pilots: least squares H = Y/X and
  /// linear interpolation across frequency; preamble: least squares on every used subcarrier of
  /// the training symbol, then per-symbol common-phase correction from the pilots), one-tap
  /// zero-forcing equalizer.
  struct OFDMDemodulator: Sendable {
    let config: OFDMConfig
    private let fft: RF.FFT
    private let scale: Float
    private let used: [Int]
    private let isPilot: [Bool]
    /// Positions (in `used`) of the pilots, ascending.
    private let pilotPositions: [Int]
    /// For each used subcarrier: the bracketing pilots (indices into `pilotPositions`) and the
    /// interpolation fraction between them (flat beyond the outermost pilots).
    private let interpolation: [(lo: Int, hi: Int, f: Float)]

    init?(config: OFDMConfig) {
      guard let fft = RF.FFT(count: config.fftSize), !config.pilotSubcarriers.isEmpty else { return nil }
      self.config = config
      self.fft = fft
      scale = Float(config.usedSubcarriers.count).squareRoot() / Float(config.fftSize)
      let usedList = config.usedSubcarriers
      used = usedList
      let pilotSet = Set(config.pilotSubcarriers)
      isPilot = usedList.map { pilotSet.contains($0) }
      let positions = usedList.indices.filter { pilotSet.contains(usedList[$0]) }
      pilotPositions = positions
      interpolation = usedList.indices.map { u in
        guard let hiIdx = positions.firstIndex(where: { $0 >= u }) else { return (positions.count - 1, positions.count - 1, 0) }
        if hiIdx == 0 || positions[hiIdx] == u { return (hiIdx, hiIdx, 0) }
        let loIdx = hiIdx - 1
        let f = Float(u - positions[loIdx]) / Float(positions[hiIdx] - positions[loIdx])
        return (loIdx, hiIdx, f)
      }
    }

    /// Demodulates `symbols` OFDM symbols (training included) starting at `offset` (the first
    /// sample of a CP). A timing offset within the CP only rotates the channel estimate, which
    /// the estimator removes. Plain per-symbol (or per-frame) LS estimates: noisy pilots cost up
    /// to 3 dB against perfect channel knowledge.
    func demodulate(_ rx: IQBuffer, symbols: Int? = nil, offset: Int = 0) -> OFDMReception {
      var none: PilotTracker?
      return demodulate(rx, symbols: symbols, offset: offset, tracker: &none)
    }

    /// Demodulates with estimates smoothed by `tracker` (across symbols for pilots, across
    /// frames for the preamble), which recovers most of the LS penalty when the channel changes
    /// slowly.
    func demodulate(_ rx: IQBuffer, symbols: Int? = nil, offset: Int = 0, tracker: inout PilotTracker?) -> OFDMReception {
      let n = config.fftSize
      let len = config.symbolLength
      let offset = max(0, offset)
      let available = max(0, (rx.count - offset) / len)
      let count = max(0, min(symbols ?? available, available))
      let training = min(config.trainingSymbols, count)
      let dataCount = count - training
      let perSymbol = config.dataSubcarriers.count
      var data = IQBuffer(count: dataCount * perSymbol)
      var raw = IQBuffer(count: dataCount * perSymbol)
      var h = IQBuffer(count: used.count)
      var grid = IQBuffer(count: n)
      var pilotRe = [Float](repeating: 0, count: pilotPositions.count)
      var pilotIm = [Float](repeating: 0, count: pilotPositions.count)
      var fullRe: [Float] = []
      var fullIm: [Float] = []
      let tracksPhase = tracker?.tracksCommonPhase ?? true
      for s in 0..<count {
        let base = offset + s * len + config.cyclicPrefix
        for t in 0..<n {
          grid.i[t] = rx.i[base + t] * scale
          grid.q[t] = rx.q[base + t] * scale
        }
        fft.forward(&grid)
        if s < training {
          // Least squares on every used subcarrier (training values are ±1, so H = Y·X).
          fullRe = [Float](repeating: 0, count: used.count)
          fullIm = [Float](repeating: 0, count: used.count)
          for u in used.indices {
            let b = config.bin(used[u])
            let x = OFDMConfig.trainingValue(u)
            fullRe[u] = grid.i[b] * x
            fullIm[u] = grid.q[b] * x
          }
          if tracker != nil { tracker!.update(re: &fullRe, im: &fullIm) }
          continue
        }
        if !fullRe.isEmpty {
          // Common phase error from the pilots against the training estimate.
          var c: Float = 1
          var sn: Float = 0
          if tracksPhase {
            var sr: Float = 0
            var si: Float = 0
            for pos in pilotPositions {
              let b = config.bin(used[pos])
              sr += grid.i[b] * fullRe[pos] + grid.q[b] * fullIm[pos]
              si += grid.q[b] * fullRe[pos] - grid.i[b] * fullIm[pos]
            }
            let mag = (sr * sr + si * si).squareRoot()
            if mag > 0 {
              c = sr / mag
              sn = si / mag
            }
          }
          for u in used.indices {
            h.i[u] = fullRe[u] * c - fullIm[u] * sn
            h.q[u] = fullRe[u] * sn + fullIm[u] * c
          }
        } else {
          // Least-squares estimates at the pilots (pilot value +1, so H = Y).
          for (p, pos) in pilotPositions.enumerated() {
            let b = config.bin(used[pos])
            pilotRe[p] = grid.i[b]
            pilotIm[p] = grid.q[b]
          }
          if tracker != nil { tracker!.update(re: &pilotRe, im: &pilotIm) }
          for u in used.indices {
            let (lo, hi, f) = interpolation[u]
            h.i[u] = pilotRe[lo] + (pilotRe[hi] - pilotRe[lo]) * f
            h.q[u] = pilotIm[lo] + (pilotIm[hi] - pilotIm[lo]) * f
          }
        }
        var k = 0
        let row = (s - training) * perSymbol
        for u in used.indices where !isPilot[u] {
          let b = config.bin(used[u])
          let yr = grid.i[b]
          let yi = grid.q[b]
          let hr = h.i[u]
          let hq = h.q[u]
          let d = max(hr * hr + hq * hq, 1e-12)
          let idx = row + k
          raw.i[idx] = yr
          raw.q[idx] = yi
          data.i[idx] = (yr * hr + yi * hq) / d
          data.q[idx] = (yi * hr - yr * hq) / d
          k += 1
        }
      }
      return OFDMReception(data: data, channelEstimate: h, raw: raw)
    }
  }
}
