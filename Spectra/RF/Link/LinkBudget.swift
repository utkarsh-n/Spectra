import Foundation

nonisolated extension RF {
  /// Median path-loss models the Link page can pick.
  enum PropagationModel: Hashable, Codable, Sendable {
    /// Friis free space.
    case freeSpace
    /// Log-distance with exponent n and PL(d₀) = FSPL(d₀).
    case logDistance(exponent: Double, referenceDistance: Double)
    /// A TR 38.901 formula (InH LOS/NLOS, UMa/UMi NLOS).
    case tr38901(RF.Propagation.TR38901)
    /// Two-ray ground reflection (Γ = −1), antenna heights in m.
    case twoRay(txHeight: Double, rxHeight: Double)
    /// Okumura–Hata (150–1500 MHz) for an environment, base and mobile heights in m.
    case hata(environment: RF.Propagation.HataEnvironment, baseHeight: Double, mobileHeight: Double)
    /// COST-231 Hata (1500–2000 MHz).
    case cost231(metropolitan: Bool, baseHeight: Double, mobileHeight: Double)

    var displayName: String {
      switch self {
      case .freeSpace: "Free space"
      case .logDistance(let n, _): String(format: "Log-distance n = %.1f", n)
      case .tr38901(let s): s.displayName
      case .twoRay: "Two-ray ground"
      case .hata: "Okumura–Hata"
      case .cost231: "COST-231 Hata"
      }
    }

    /// Median loss in dB at distance d (m) and frequency f (Hz).
    func lossDB(distance d: Double, frequency f: Double) -> Double {
      switch self {
      case .freeSpace:
        return RF.Propagation.fsplDB(distance: d, frequency: f)
      case .logDistance(let n, let d0):
        // Inside the reference distance the model falls back to free space.
        if d <= d0 { return RF.Propagation.fsplDB(distance: d, frequency: f) }
        return RF.Propagation.logDistanceDB(distance: d, frequency: f, exponent: n, referenceDistance: d0)
      case .tr38901(let s):
        return s.pathLossDB(distance3D: d, frequencyGHz: f / 1e9)
      case .twoRay(let ht, let hr):
        return RF.Propagation.TwoRay(txHeight: ht, rxHeight: hr, frequency: f).exactLossDB(distance: d)
      case .hata(let env, let hb, let hm):
        return RF.Propagation.hataDB(frequencyMHz: f / 1e6, baseHeight: hb, mobileHeight: hm, distanceKm: d / 1000, environment: env)
      case .cost231(let metro, let hb, let hm):
        return RF.Propagation.cost231DB(frequencyMHz: f / 1e6, baseHeight: hb, mobileHeight: hm, distanceKm: d / 1000, metropolitan: metro)
      }
    }

    /// Shadow-fading σ the model carries, dB (nil when it has none).
    var shadowSigmaDB: Double? {
      if case .tr38901(let s) = self { return s.shadowSigmaDB }
      return nil
    }

    /// Plain-language validity warnings for a distance and frequency.
    func validityNotes(distance d: Double, frequency f: Double) -> [String] {
      var out: [String] = []
      switch self {
      case .tr38901(let s):
        if let r = s.validDistance, !r.contains(d) { out.append(String(format: "%@ is specified for %.0f–%.0f m.", s.displayName, r.lowerBound, r.upperBound)) }
      case .hata:
        if f < 150e6 || f > 1500e6 { out.append("Hata is specified for 150–1500 MHz.") }
        if d < 1000 || d > 20_000 { out.append("Hata is specified for 1–20 km.") }
      case .cost231:
        if f < 1500e6 || f > 2000e6 { out.append("COST-231 is specified for 1500–2000 MHz.") }
        if d < 1000 || d > 20_000 { out.append("COST-231 is specified for 1–20 km.") }
      default:
        break
      }
      return out
    }
  }

  /// One layer kind and how many of them the signal crosses.
  struct WallLayer: Hashable, Codable, Sendable {
    var material: RF.Building.Material
    var count: Int

    init(_ material: RF.Building.Material, count: Int = 1) {
      self.material = material
      self.count = count
    }
  }

  /// Everything the Link page feeds into a budget.
  struct LinkBudgetInput: Hashable, Codable, Sendable {
    /// Carrier, Hz.
    var frequency: Double
    /// Receiver noise bandwidth, Hz.
    var bandwidth: Double
    var txPowerDBm: Double = 20
    var txGainDBi: Double = 0
    var rxGainDBi: Double = 0
    /// Feed/cable losses (positive dB).
    var txFeedLossDB: Double = 0
    var rxFeedLossDB: Double = 0
    /// Path length, m.
    var distance: Double = 10
    var model: PropagationModel = .freeSpace
    /// Walls crossed (TR 38.901 material losses, summed).
    var walls: [WallLayer] = []
    /// Optional building entry (TR 38.901 O2I wall model plus 0.5 dB/m indoors).
    var o2i: RF.Building.O2IModel?
    var indoorDistance: Double = 0
    /// Rain rate, mm/h (P.838, horizontal polarization, uniform rain).
    var rainRate: Double = 0
    /// Include P.676 gas absorption.
    var includeGas = false
    var air: RF.Atmosphere.AirState = .standard
    /// Length of the path inside rain and air, m (nil = the whole distance). Set it for slant
    /// paths to space: the atmosphere is only a few km thick.
    var atmosphericPathLength: Double?
    /// Knife-edge obstruction height above the direct ray (m) and its position along the path
    /// (fraction of the distance from the transmitter).
    var obstructionHeight: Double?
    var obstructionPosition: Double = 0.5
    /// Polarization mismatch loss (positive dB), e.g. −10·log10(PLF).
    var polarizationLossDB: Double = 0
    /// Extra fade margin subtracted from the received power (positive dB).
    var fadeMarginDB: Double = 0
    var noiseFigureDB: Double = 7
    /// Source (antenna) noise temperature, K: the floor is k(T + T_e)B with T_e = (F − 1)·290 K.
    var noiseTemperature: Double = RF.Const.T0
    /// SNR the receiver needs (for the margin readout).
    var requiredSNRDB: Double?
    /// Peak rate of the selected system (for "capacity vs peak").
    var systemPeakRate: Double?

    init(frequency: Double, bandwidth: Double) {
      self.frequency = frequency
      self.bandwidth = bandwidth
    }
  }

  /// One bar of the budget chart: gains positive, losses negative.
  struct LinkTerm: Hashable, Sendable, Identifiable {
    enum Kind: String, Sendable { case power, gain, loss }
    var id: String { name }
    var name: String
    var dB: Double
    var kind: Kind
  }

  /// Result of a budget.
  struct LinkBudgetResult: Sendable {
    var eirpDBm: Double
    /// Median propagation loss of the chosen model, dB.
    var pathLossDB: Double
    /// Free-space loss at the same distance, for comparison, dB.
    var freeSpaceLossDB: Double
    var wallsLossDB: Double
    var buildingEntryLossDB: Double
    var rainLossDB: Double
    var gasLossDB: Double
    var diffractionLossDB: Double
    var receivedPowerDBm: Double
    var noiseFloorDBm: Double
    var snrDB: Double
    /// Shannon capacity in the bandwidth, bit/s.
    var capacity: Double
    var spectralEfficiency: Double
    /// SNR minus the required SNR, dB.
    var marginDB: Double?
    /// Capacity divided by the system's peak rate.
    var capacityToPeak: Double?
    /// Bars for the budget chart, in order.
    var terms: [LinkTerm]
    var notes: [String]
  }

  enum LinkBudget {
    /// Evaluates a budget: P_r = P_t + G_t − L_tx + G_r − L_rx − PL − walls − O2I − rain − gas −
    /// diffraction − polarization − margin; noise kTB·F; SNR; Shannon capacity.
    ///
    /// A zero (or negative, or non-finite) bandwidth is a CW carrier: the noise floor is −∞, and
    /// capacity and spectral efficiency are 0. A non-positive or non-finite frequency is read as
    /// 1 Hz and a non-finite distance as 1 µm, with a note.
    static func evaluate(_ x: LinkBudgetInput) -> LinkBudgetResult {
      var inputNotes: [String] = []
      let f = x.frequency.isFinite && x.frequency > 0 ? x.frequency : 1
      if f != x.frequency { inputNotes.append("The carrier frequency must be positive; 1 Hz is used.") }
      let bandwidth = x.bandwidth.isFinite ? max(0, x.bandwidth) : 0
      let d = x.distance.isFinite ? max(x.distance, 1e-6) : 1e-6
      let fGHz = f / 1e9
      let eirp = RF.Antennas.eirpDBm(txPowerDBm: x.txPowerDBm, gainDBi: x.txGainDBi, feedLossDB: x.txFeedLossDB)
      // A passive path cannot amplify: below the distance where a model's loss would turn
      // negative (FSPL at d < λ/4π, deep in the near field) the loss is held at 0 dB.
      let modelLoss = x.model.lossDB(distance: d, frequency: f)
      let pl = max(0, modelLoss)
      let fspl = RF.Propagation.fsplDB(distance: d, frequency: f)
      let walls = RF.Building.wallsLossDB(x.walls.map { ($0.material, $0.count) }, frequencyGHz: fGHz)
      var entry = 0.0
      if let o2i = x.o2i { entry = o2i.wallLossDB(frequencyGHz: fGHz) + RF.Building.indoorLossDB(indoorDistance: x.indoorDistance) }
      let atmosphere = min(x.atmosphericPathLength ?? d, d)
      let rain = x.rainRate > 0 ? RF.Atmosphere.rainLossDB(frequency: f, rainRate: x.rainRate, distance: atmosphere) : 0
      let gas = x.includeGas ? RF.Atmosphere.gasLossDB(frequency: f, distance: atmosphere, air: x.air) : 0
      var diffraction = 0.0
      if let h = x.obstructionHeight {
        let p = min(max(x.obstructionPosition, 0.001), 0.999)
        let nu = RF.Propagation.knifeEdgeNu(height: h, d1: p * d, d2: (1 - p) * d, wavelength: RF.Const.c / f)
        diffraction = RF.Propagation.knifeEdgeLossExactDB(nu: nu)
      }
      let pr = eirp + x.rxGainDBi - x.rxFeedLossDB - pl - walls - entry - rain - gas - diffraction - x.polarizationLossDB - x.fadeMarginDB
      let floor = RF.Noise.floorDBm(bandwidth: bandwidth, noiseFigureDB: x.noiseFigureDB, temperature: x.noiseTemperature)
      let snr = pr - floor
      let capacity = RF.Noise.shannonCapacity(bandwidth: bandwidth, snrDB: snr)
      var terms: [LinkTerm] = [
        LinkTerm(name: "Tx power", dB: x.txPowerDBm, kind: .power),
        LinkTerm(name: "Tx antenna", dB: x.txGainDBi, kind: .gain),
      ]
      func loss(_ name: String, _ v: Double) { if v != 0 { terms.append(LinkTerm(name: name, dB: -v, kind: .loss)) } }
      loss("Tx feed", x.txFeedLossDB)
      loss(x.model.displayName, pl)
      loss("Walls", walls)
      loss("Building entry", entry)
      loss("Rain", rain)
      loss("Gas", gas)
      loss("Diffraction", diffraction)
      loss("Polarization", x.polarizationLossDB)
      loss("Fade margin", x.fadeMarginDB)
      terms.append(LinkTerm(name: "Rx antenna", dB: x.rxGainDBi, kind: .gain))
      loss("Rx feed", x.rxFeedLossDB)
      var notes = inputNotes + x.model.validityNotes(distance: d, frequency: f)
      let lambda = RF.Const.c / f
      if d < lambda / (2 * Double.pi) {
        notes.append(String(format: "%@ is inside λ/2π = %@ of the antenna, the reactive near field: the far-field budget does not apply (coupling there is inductive or capacitive)%@.",
                            RF.Units.format(distance: d), RF.Units.format(distance: lambda / (2 * Double.pi)), modelLoss < 0 ? ", and the path loss is held at 0 dB" : ""))
      }
      if x.atmosphericPathLength == nil, d > 100_000, x.rainRate > 0 || x.includeGas {
        notes.append("Rain and gas are applied over the whole path; set the atmospheric path length for a path to space.")
      }
      if x.rainRate > 0, !RF.Atmosphere.rainValidGHz.contains(fGHz) {
        notes.append(fGHz < 1
          ? "ITU-R P.838 rain covers 1–1000 GHz; below 1 GHz rain loss is negligible (the 1 GHz value is used as an upper bound)."
          : "ITU-R P.838 rain covers 1–1000 GHz; the 1000 GHz coefficients are used.")
      }
      if x.includeGas, !RF.Atmosphere.gasValidGHz.contains(fGHz) {
        notes.append("ITU-R P.676 gas absorption is specified for 1–1000 GHz.")
      }
      if let s = x.model.shadowSigmaDB { notes.append(String(format: "Median loss; shadow fading spreads it by σ = %.1f dB.", s)) }
      return LinkBudgetResult(
        eirpDBm: eirp, pathLossDB: pl, freeSpaceLossDB: fspl, wallsLossDB: walls, buildingEntryLossDB: entry, rainLossDB: rain,
        gasLossDB: gas, diffractionLossDB: diffraction, receivedPowerDBm: pr, noiseFloorDBm: floor, snrDB: snr, capacity: capacity,
        spectralEfficiency: bandwidth > 0 ? RF.Noise.spectralEfficiency(snrDB: snr) : 0, marginDB: x.requiredSNRDB.map { snr - $0 },
        capacityToPeak: x.systemPeakRate.map { capacity / $0 }, terms: terms, notes: notes)
    }

    /// The distance at which the budget's received power equals `rssiDBm` — the Link page's
    /// live BLE check. Monotonic models are solved by bisection over 1 mm … 40 000 km; returns
    /// nil if the RSSI is outside that range. (For two-ray the far, monotonic branch is used.)
    static func distance(forReceivedPower rssiDBm: Double, input: LinkBudgetInput) -> Double? {
      guard rssiDBm.isFinite else { return nil }
      var x = input
      let g: (Double) -> Double = { logD in
        x.distance = pow(10, logD)
        return evaluate(x).receivedPowerDBm - rssiDBm
      }
      var lo = -3.0
      if case .twoRay(let ht, let hr) = input.model {
        lo = log10(max(RF.Propagation.TwoRay(txHeight: ht, rxHeight: hr, frequency: input.frequency).criticalDistance, 1e-3))
      }
      let hi = log10(4e7)
      guard let root = RF.Numerics.bisect(lo, hi, tolerance: 1e-10, g) else { return nil }
      return pow(10, root)
    }

    /// The distance at which the SNR falls to `snrDB` (the range of the link), or nil.
    static func range(forSNR snrDB: Double, input: LinkBudgetInput) -> Double? {
      let floor = RF.Noise.floorDBm(bandwidth: input.bandwidth, noiseFigureDB: input.noiseFigureDB, temperature: input.noiseTemperature)
      guard floor.isFinite, snrDB.isFinite else { return nil }
      return distance(forReceivedPower: floor + snrDB, input: input)
    }
  }
}
