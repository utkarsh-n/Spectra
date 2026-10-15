import Foundation

/// Numerology of real systems from the verified reference (rf-physics D, E). Frequencies in Hz
/// unless the name says MHz/kHz; durations in seconds.
nonisolated extension RF.Numerology {
  // MARK: 5G NR (TS 38.211 / 38.104 / 38.101-1, rf-physics E.6)

  enum NR {
    /// Basic time unit T_c = 1/(Δf_max·N_f), Δf_max = 480 kHz, N_f = 4096 (0.508 626 ns).
    static let tc = 1 / (480_000.0 * 4096)
    /// κ = T_s/T_c = 64.
    static let kappa = 64.0
    /// Numerologies µ = 0…6.
    static let numerologies = 0...6

    /// Subcarrier spacing 15·2^µ kHz.
    static func subcarrierSpacing(mu: Int) -> Double { 15_000 * pow(2, Double(mu)) }

    /// Useful symbol time N_u·T_c = 2048κ·2^{−µ}·T_c (µ 0 → 66.6667 µs).
    static func usefulDuration(mu: Int) -> Double { 2048 * kappa * pow(2, -Double(mu)) * tc }

    /// Normal cyclic prefix 144κ·2^{−µ}·T_c, plus 16κ·T_c on the first symbol of each 0.5 ms
    /// (µ 0 → 4687.5 ns, µ 6 → 73.242 ns).
    static func normalCPDuration(mu: Int, firstInHalfSubframe: Bool = false) -> Double {
      (144 * kappa * pow(2, -Double(mu)) + (firstInHalfSubframe ? 16 * kappa : 0)) * tc
    }

    /// Extended cyclic prefix 512κ·2^{−µ}·T_c (defined only for µ = 2).
    static func extendedCPDuration(mu: Int) -> Double { 512 * kappa * pow(2, -Double(mu)) * tc }

    /// Slot duration: 14 symbols, 2^µ slots per 1 ms subframe (µ 0 → 1 ms, µ 6 → 15.625 µs).
    static func slotDuration(mu: Int) -> Double { 1e-3 / pow(2, Double(mu)) }

    /// Slots per subframe, 2^µ.
    static func slotsPerSubframe(mu: Int) -> Int { 1 << mu }

    /// Frequency ranges (TS 38.104 Table 5.1-1), MHz.
    static let fr1MHz: ClosedRange<Double> = 410...7125
    static let fr2_1MHz: ClosedRange<Double> = 24_250...52_600
    static let fr2_2MHz: ClosedRange<Double> = 52_600...71_000

    /// Maximum transmission bandwidth configurations carried by the reference:
    /// FR1 100 MHz / 30 kHz → 273 RB, 100 MHz / 60 kHz → 135 RB, FR2-1 400 MHz / 120 kHz → 264 RB,
    /// FR2-2 2000 MHz / 960 kHz → 148 RB.
    static let maxResourceBlocks: [(bandwidthMHz: Double, scsKHz: Double, rb: Int)] = [
      (100, 30, 273), (100, 60, 135), (400, 120, 264), (2000, 960, 148),
    ]

    /// Guard band (38.101-1 §5.3.3) GB = (BW·1000 − N_RB·SCS·12)/2 − SCS/2 kHz
    /// (100 MHz, 30 kHz, 273 RB → 845 kHz).
    static func guardBandKHz(bandwidthMHz bw: Double, resourceBlocks n: Int, scsKHz scs: Double) -> Double {
      (bw * 1000 - Double(n) * scs * 12) / 2 - scs / 2
    }

    /// Global frequency raster (TS 38.104 §5.4.2.1): F_REF = F_REF-Offs + ΔF_Global(N_REF − N_REF-Offs).
    /// N = 633 333 → 3499.995 MHz.
    static func arfcnToFrequencyMHz(_ n: Int) -> Double {
      switch n {
      case ..<600_000: return 0.005 * Double(n)
      case 600_000..<2_016_667: return 3000 + 0.015 * Double(n - 600_000)
      default: return 24_250.08 + 0.060 * Double(n - 2_016_667)
      }
    }

    /// Nearest NR-ARFCN of a frequency in MHz (the raster covers 0…100 000 MHz, N 0…3 279 165;
    /// the frequency is clamped to that range, NaN gives 0).
    static func frequencyToARFCN(_ requested: Double) -> Int {
      let mhz = requested.isNaN ? 0 : min(max(requested, 0), 100_000)
      if mhz < 3000 { return Int((mhz / 0.005).rounded()) }
      if mhz < 24_250 { return 600_000 + Int(((mhz - 3000) / 0.015).rounded()) }
      return min(3_279_165, 2_016_667 + Int(((mhz - 24_250.08) / 0.060).rounded()))
    }

    /// NR operating bands carried by the reference (TS 38.104 Tables 5.2-1/-2), MHz.
    static let bands: [RF.Band] = [
      RF.Band(name: "n41", lowMHz: 2496, highMHz: 2690, duplex: .tdd),
      RF.Band(name: "n77", lowMHz: 3300, highMHz: 4200, duplex: .tdd),
      RF.Band(name: "n78", lowMHz: 3300, highMHz: 3800, duplex: .tdd),
      RF.Band(name: "n79", lowMHz: 4400, highMHz: 5000, duplex: .tdd),
      RF.Band(name: "n71 UL", lowMHz: 663, highMHz: 698, duplex: .uplink),
      RF.Band(name: "n71 DL", lowMHz: 617, highMHz: 652, duplex: .downlink),
      RF.Band(name: "n257", lowMHz: 26_500, highMHz: 29_500, duplex: .tdd),
      RF.Band(name: "n258", lowMHz: 24_250, highMHz: 27_500, duplex: .tdd),
      RF.Band(name: "n260", lowMHz: 37_000, highMHz: 40_000, duplex: .tdd),
      RF.Band(name: "n261", lowMHz: 27_500, highMHz: 28_350, duplex: .tdd),
    ]

    /// UE power class 3: 23 dBm in all FR1 bands; class 2: 26 dBm (n41, n77, n78 …).
    static let powerClass3DBm = 23.0
    static let powerClass2DBm = 26.0
  }

  // MARK: LTE (TS 36.211 / 36.104, rf-physics D.9, E.1)

  enum LTE {
    /// Subcarrier spacing 15 kHz.
    static let subcarrierSpacing = 15_000.0
    /// T_s = 1/(15 000 × 2048) s = 32.552 ns.
    static let ts = 1 / (15_000.0 * 2048)
    /// Useful symbol time 2048·T_s = 66.667 µs.
    static let usefulDuration = 2048 * ts
    /// Normal CP: 160 T_s on the first symbol of a slot (5.208 µs), 144 T_s otherwise (4.6875 µs).
    static let normalCPFirst = 160 * ts
    static let normalCP = 144 * ts
    /// Extended CP 512 T_s (16.667 µs).
    static let extendedCP = 512 * ts
    /// Slot: 160 + 2048 + 6 × (144 + 2048) = 15 360 T_s = 0.5 ms.
    static let slotSamples = 160 + 2048 + 6 * (144 + 2048)
    /// Resource block: 12 subcarriers (180 kHz).
    static let subcarriersPerRB = 12
    /// Channel bandwidth (MHz) → resource blocks (TS 36.104 Table 5.6-1).
    static let resourceBlocks: [(bandwidthMHz: Double, rb: Int)] = [(1.4, 6), (3, 15), (5, 25), (10, 50), (15, 75), (20, 100)]

    /// Resource blocks of a channel bandwidth (nil if not a standard LTE width).
    static func resourceBlocks(bandwidthMHz bw: Double) -> Int? {
      resourceBlocks.first { abs($0.bandwidthMHz - bw) < 1e-9 }?.rb
    }
  }

  // MARK: Wi-Fi (rf-physics D.9, E.2)

  enum WiFi {
    /// 802.11a/g/n/ac subcarrier spacing 20 MHz/64 = 312.5 kHz (T_u 3.2 µs).
    static let legacySubcarrierSpacing = 20e6 / 64
    /// 802.11ax/be subcarrier spacing 20 MHz/256 = 78.125 kHz (T_u 12.8 µs).
    static let heSubcarrierSpacing = 20e6 / 256

    /// Headline PHY rate N_SD·bits·R/T_sym·N_SS (bit/s). 802.11a: 48·6·3/4/4 µs = 54 Mb/s.
    static func phyRate(dataSubcarriers nsd: Int, bitsPerSymbol bits: Int, codeRate r: Double, symbolDuration t: Double, streams: Int = 1) -> Double {
      Double(nsd) * Double(bits) * r / t * Double(streams)
    }

    /// The reference's headline rates (b/s): a/g 54 M, n 600 M, ac 6933.3 M, ax 9607.84 M,
    /// be 23 058.82 M; iPhone 15 Pro Max (ax, 160 MHz, 2 SS) 2401.96 M.
    static let rate11a = phyRate(dataSubcarriers: 48, bitsPerSymbol: 6, codeRate: 0.75, symbolDuration: 4e-6)
    static let rate11n = phyRate(dataSubcarriers: 108, bitsPerSymbol: 6, codeRate: 5.0 / 6, symbolDuration: 3.6e-6, streams: 4)
    static let rate11ac = phyRate(dataSubcarriers: 468, bitsPerSymbol: 8, codeRate: 5.0 / 6, symbolDuration: 3.6e-6, streams: 8)
    static let rate11ax = phyRate(dataSubcarriers: 1960, bitsPerSymbol: 10, codeRate: 5.0 / 6, symbolDuration: 13.6e-6, streams: 8)
    static let rate11be = phyRate(dataSubcarriers: 3920, bitsPerSymbol: 12, codeRate: 5.0 / 6, symbolDuration: 13.6e-6, streams: 8)
    static let rateIPhone15ProMax = phyRate(dataSubcarriers: 1960, bitsPerSymbol: 10, codeRate: 5.0 / 6, symbolDuration: 13.6e-6, streams: 2)

    /// US 6 GHz band 5925–7125 MHz (FCC 20-51) and Europe 5945–6425 MHz (ECC (20)01).
    static let sixGHzUSMHz: ClosedRange<Double> = 5925...7125
    static let sixGHzEuropeMHz: ClosedRange<Double> = 5945...6425
  }

  // MARK: Bluetooth (Core 5.4, rf-physics D.4, D.8, E.3)

  enum Bluetooth {
    /// BR/EDR channel k = 0…78 at 2402 + k MHz.
    static func brChannelMHz(_ k: Int) -> Double? { (0...78).contains(k) ? 2402 + Double(k) : nil }

    /// LE channel index 0…39 → MHz: data 0…10 at 2404 + 2i, 11…36 at 2428 + 2(i − 11);
    /// advertising 37 = 2402, 38 = 2426, 39 = 2480.
    static func leChannelMHz(_ i: Int) -> Double? {
      switch i {
      case 0...10: 2404 + 2 * Double(i)
      case 11...36: 2428 + 2 * Double(i - 11)
      case 37: 2402
      case 38: 2426
      case 39: 2480
      default: nil
      }
    }

    /// Primary advertising channels (index, MHz).
    static let advertisingChannels: [(index: Int, mhz: Double)] = [(37, 2402), (38, 2426), (39, 2480)]
    /// Slot 625 µs = 1/1600 s (connection-state hop rate 1600/s; inquiry/page 3200/s).
    static let slotDuration = 1.0 / 1600
    /// LE sensitivity requirements (dBm): uncoded −70, S = 2 −75, S = 8 −82.
    static let leSensitivityDBm: [(phy: String, dBm: Double)] = [("LE 1M/2M", -70), ("LE Coded S=2", -75), ("LE Coded S=8", -82)]
    /// Modulation-index ranges: BR 0.28–0.35, LE 0.45–0.55 (both BT = 0.5).
    static let brIndexRange: ClosedRange<Double> = 0.28...0.35
    static let leIndexRange: ClosedRange<Double> = 0.45...0.55
  }

  // MARK: GSM / EDGE (TS 45.00x, rf-physics D.5, E.1)

  enum GSM {
    /// Symbol rate 1625/6 ksym/s = 270.833 ksym/s.
    static let symbolRate = 1_625_000.0 / 6
    /// Bit (symbol) period 3.692 31 µs.
    static var symbolPeriod: Double { 1 / symbolRate }
    /// Timeslot 3/5200 s ≈ 576.9 µs = 156.25 symbol periods.
    static let slotDuration = 3.0 / 5200
    /// TDMA frame of 8 slots ≈ 4.615 ms.
    static let frameDuration = 8 * slotDuration
    /// GMSK Gaussian BT.
    static let bt = 0.3
    /// EDGE 8PSK gross rate per carrier, 3 bits × 270.833 ksym/s = 812.5 kbit/s.
    static var edgeGrossRate: Double { 3 * symbolRate }
    /// P-GSM uplink carrier F_l(n) = 890 + 0.2n MHz (n = 1…124); downlink F_u = F_l + 45.
    static func pgsmUplinkMHz(arfcn n: Int) -> Double? { (1...124).contains(n) ? 890 + 0.2 * Double(n) : nil }
    static func pgsmDownlinkMHz(arfcn n: Int) -> Double? { pgsmUplinkMHz(arfcn: n).map { $0 + 45 } }
  }

  // MARK: GNSS (IS-GPS-200N, IS-GPS-705J, rf-physics E.4)

  enum GPS {
    /// Fundamental f₀ = 10.23 MHz.
    static let f0 = 10.23e6
    /// L1 = 154 f₀ = 1575.42 MHz, L2 = 120 f₀ = 1227.6 MHz, L5 = 115 f₀ = 1176.45 MHz.
    static let l1 = 154 * f0
    static let l2 = 120 * f0
    static let l5 = 115 * f0
    /// C/A code: 1.023 Mcps, 1023 chips, 1 ms period; LNAV 50 bit/s.
    static let caChipRate = 1.023e6
    static let caCodeLength = 1023
    static let navBitRate = 50.0
    /// L5 code: 10.23 Mcps, 10 230 chips per 1 ms.
    static let l5ChipRate = 10.23e6
    static let l5CodeLength = 10_230
    /// Minimum received power L1 C/A −158.5 dBW (into a 3 dBi linear antenna, ≥ 5° elevation);
    /// L5 per component −157.9 dBW (IIF) / −157.0 dBW (GPS III).
    static let l1MinimumPowerDBW = -158.5
    static let l5MinimumPowerIIFDBW = -157.9
    static let l5MinimumPowerIIIDBW = -157.0
    /// Nominal orbit distance used by the Live card, 20 200 km.
    static let orbitDistance = 20_200e3
  }

  // MARK: UWB, NFC, Qi, broadcast (rf-physics E.4)

  enum UWB {
    /// IEEE 802.15.4z HRP channels: 5 = 13 × 499.2 MHz, 9 = 16 × 499.2 MHz; bandwidth 499.2 MHz.
    static let channel5 = 13 * 499.2e6
    static let channel9 = 16 * 499.2e6
    static let bandwidth = 499.2e6
    /// Time of flight d/c (1 m → 3.3356 ns).
    static func timeOfFlight(distance d: Double) -> Double { d / RF.Const.c }
    /// Two-way ranging d = c·(T_round − T_reply)/2.
    static func twoWayDistance(roundTrip: Double, reply: Double) -> Double { RF.Const.c * (roundTrip - reply) / 2 }
    /// Rule-of-thumb range resolution c/(2B) = 0.300 m.
    static var rangeResolution: Double { RF.Const.c / (2 * bandwidth) }
  }

  enum NFC {
    /// Carrier 13.56 MHz.
    static let carrier = 13.56e6
    /// 106 kbit/s class: f_c/128 = 105.9375 kbit/s (ETU 9.4395 µs).
    static var bitRate: Double { carrier / 128 }
    /// Card load-modulation subcarrier f_c/16 = 847.5 kHz.
    static var subcarrier: Double { carrier / 16 }
  }

  enum Qi {
    /// Baseline/Extended Power Profile operating frequency "typically 87 to 205 kHz".
    static let bppEppRange: ClosedRange<Double> = 87e3...205e3
    /// Qi2 Magnetic Power Profile ≈ 360 kHz [S].
    static let qi2MPP = 360e3
  }

  enum Broadcast {
    /// US AM: carriers 540–1700 kHz in 10 kHz steps (117 channels).
    static let amCarriersUS: [Double] = stride(from: 540, through: 1700, by: 10).map { Double($0) * 1e3 }
    /// US FM channel n (201…300) → MHz: 88.1 + 0.2(n − 201).
    static func fmChannelMHz(_ n: Int) -> Double? { (201...300).contains(n) ? 88.1 + 0.2 * Double(n - 201) : nil }
    /// ±75 kHz deviation is 100 % modulation (47 CFR §73.310).
    static let fmDeviation = 75e3
    /// DAB mode I: 1536 carriers × 1 kHz, T_u 1 ms, guard 246 µs [S].
    static let dabCarriers = 1536
    static let dabSubcarrierSpacing = 1e3
    static let dabGuard = 246e-6
  }

  // MARK: Spread spectrum (rf-physics D.7)

  /// Processing gain G_p = 10·log10(R_c/R_b) dB (GPS C/A 43.1091 dB; IS-95 21.0721 dB).
  static func processingGainDB(chipRate rc: Double, bitRate rb: Double) -> Double { 10 * log10(rc / rb) }
}

nonisolated extension RF {
  /// A frequency band or allocation.
  struct Band: Hashable, Codable, Sendable, Identifiable {
    enum Duplex: String, Codable, Hashable, Sendable {
      case uplink, downlink, tdd, simplex, receiveOnly
    }

    var name: String
    var lowMHz: Double
    var highMHz: Double
    var duplex: Duplex

    var id: String { name + "@\(lowMHz)" }
    /// Centre frequency in Hz.
    var center: Double { (lowMHz + highMHz) / 2 * 1e6 }
    /// Width in Hz.
    var width: Double { (highMHz - lowMHz) * 1e6 }

    init(name: String, lowMHz: Double, highMHz: Double, duplex: Duplex = .simplex) {
      self.name = name
      self.lowMHz = lowMHz
      self.highMHz = highMHz
      self.duplex = duplex
    }

    /// True if `frequency` (Hz) lies in the band.
    func contains(_ frequency: Double) -> Bool { frequency >= lowMHz * 1e6 && frequency <= highMHz * 1e6 }
  }
}
