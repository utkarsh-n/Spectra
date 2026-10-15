import Foundation

/// Every system and generation of the Radio tab's Systems page (SPEC-features §2), from the
/// verified reference (rf-physics §E, §F). Years are general history (not physics) and are marked
/// as such; "raw" peak rates are computed from the reference's numerology (subcarriers × symbol
/// rate × bits × layers) before coding and control overhead.
nonisolated extension RF {
  enum SystemsCatalog {
    /// All systems in timeline order (cellular generations first, then Wi-Fi, personal,
    /// navigation, broadcast).
    static let all: [RadioSystem] = {
      var s: [RadioSystem] = []
      s += cellular()
      s += wifi()
      s += personal()
      s += navigation()
      s += radar()
      s += broadcast()
      return s
    }()

    /// The system with an id.
    static func system(id: String) -> RadioSystem? { all.first { $0.id == id } }

    /// Systems of one filter chip.
    static func systems(in category: SystemCategory) -> [RadioSystem] { all.filter { $0.category == category } }

    /// Systems whose bands contain a frequency (Hz) — e.g. to label a live marker.
    static func systems(containing frequency: Double) -> [RadioSystem] {
      all.filter { sys in sys.bands.contains { $0.contains(frequency) } }
    }

    // MARK: iPhone 15 Pro Max band lists (rf-physics F.1, model A2849)

    static let iPhoneLTEBands: [String] = [1, 2, 3, 4, 5, 7, 8, 12, 13, 14, 17, 18, 19, 20, 25, 26, 28, 29, 30, 32, 34, 38, 39, 40, 41, 42, 46, 48, 53, 66, 71].map { "B\($0)" }
    static let iPhoneNRBands: [String] = [1, 2, 3, 5, 7, 8, 12, 14, 20, 25, 26, 28, 29, 30, 38, 40, 41, 48, 53, 66, 70, 71, 75, 76, 77, 78, 79].map { "n\($0)" }
    static let iPhoneMMWaveBands = ["n258", "n260", "n261"]

    // MARK: Builders

    private static let historyNote = "general history, not from the physics reference"

    private static func band(_ name: String, _ lo: Double, _ hi: Double, _ duplex: Band.Duplex = .simplex) -> Band {
      Band(name: name, lowMHz: lo, highMHz: hi, duplex: duplex)
    }

    // MARK: Cellular

    private static func cellular() -> [RadioSystem] {
      var out: [RadioSystem] = []
      let gsmBands = [
        band("GSM 850 UL", 824, 849, .uplink), band("GSM 850 DL", 869, 894, .downlink),
        band("P-GSM 900 UL", 890, 915, .uplink), band("P-GSM 900 DL", 935, 960, .downlink),
        band("DCS 1800 UL", 1710, 1785, .uplink), band("DCS 1800 DL", 1805, 1880, .downlink),
        band("PCS 1900 UL", 1850, 1910, .uplink), band("PCS 1900 DL", 1930, 1990, .downlink),
      ]
      out.append(RadioSystem(
        id: "amps", name: "AMPS", generation: "1G", category: .cellular, year: 1983, yearNote: historyNote,
        bands: [band("Mobile Tx", 824, 849, .uplink), band("Base Tx", 869, 894, .downlink)], iPhoneBands: [],
        carrier: 881.5e6, channelWidths: [30e3], modulation: "Analog FM voice, ±12 kHz peak deviation", maxQAM: nil,
        multiplexing: "FDMA, 832 channels (A/B blocks of 416), 45 MHz duplex", subcarrierSpacings: [], peakRate: nil,
        iPhone: .no, iPhoneNote: "Analog 1G networks are gone; the iPhone has no AMPS mode.", isSpeculative: false,
        waveform: .analogFM(deviation: 12e3, audioBandwidth: 3e3),
        facts: ["Carson: 2(12 + 3) kHz = 30 kHz, exactly the channel width.", "GSM 850 later reused the same band edges."],
        sources: ["rf-physics E.1 [S] Britannica, rfwireless-world; band edges TS 45.005"]))
      out.append(RadioSystem(
        id: "gsm", name: "GSM", generation: "2G", category: .cellular, year: 1991, yearNote: historyNote,
        bands: gsmBands, iPhoneBands: ["850", "900", "1800", "1900"],
        carrier: 947.5e6, channelWidths: [200e3], modulation: "GMSK, BT 0.3", maxQAM: nil,
        multiplexing: "TDMA (8 slots of 576.9 µs) on FDMA carriers", subcarrierSpacings: [],
        peakRate: PeakRate(value: RF.Numerology.GSM.symbolRate, basis: .formula, note: "gross channel rate per carrier, shared by 8 timeslots"),
        iPhone: .yes, iPhoneNote: "GSM/EDGE 850, 900, 1800, 1900 MHz.", isSpeculative: false,
        waveform: .fsk(index: 0.5, bt: 0.3, symbolRate: RF.Numerology.GSM.symbolRate),
        facts: ["Symbol rate 1625/6 ksym/s = 270.833 ksym/s.", "Frame of 8 slots = 4.615 ms.", "P-GSM uplink F(n) = 890 + 0.2n MHz, downlink +45 MHz."],
        sources: ["TS 45.005 §2, TS 45.002 §4.3, TS 45.004 §2"]))
      out.append(RadioSystem(
        id: "is95", name: "IS-95 cdmaOne", generation: "2G", category: .cellular, year: 1995, yearNote: historyNote,
        bands: [band("Cellular 800 UL", 824, 849, .uplink), band("Cellular 800 DL", 869, 894, .downlink)], iPhoneBands: [],
        carrier: 881.5e6, channelWidths: [1.25e6], modulation: "QPSK spreading, 1.2288 Mcps", maxQAM: nil,
        multiplexing: "CDMA (direct sequence)", subcarrierSpacings: [],
        peakRate: PeakRate(value: 9600, basis: .table, note: "voice/data rate set 1; processing gain 21.07 dB"),
        iPhone: .no, iPhoneNote: "Not listed for the iPhone 15 Pro Max (CDMA support was dropped).", isSpeculative: false,
        waveform: .dsss(modulation: .qpsk, chipsPerSymbol: 127, chipRate: 1.2288e6),
        facts: ["Processing gain 10·log10(1.2288 M / 9.6 k) = 21.07 dB.", "Simulated with a 127-chip m-sequence per symbol."],
        sources: ["rf-physics E.1, D.7 [S] Qualcomm, Pitt TELCOM 2720; band: deployed in the AMPS band [S]"]))
      out.append(RadioSystem(
        id: "edge", name: "EDGE", generation: "2.75G", category: .cellular, year: 2003, yearNote: historyNote,
        bands: gsmBands, iPhoneBands: ["850", "900", "1800", "1900"],
        carrier: 947.5e6, channelWidths: [200e3], modulation: "8PSK with 3π/8 rotation (EGPRS2 adds 16/32QAM)", maxQAM: nil,
        multiplexing: "TDMA on GSM carriers", subcarrierSpacings: [],
        peakRate: PeakRate(value: RF.Numerology.GSM.edgeGrossRate, basis: .formula, note: "gross rate per carrier, 3 bits × 270.833 ksym/s"),
        iPhone: .yes, iPhoneNote: "GSM/EDGE 850, 900, 1800, 1900 MHz.", isSpeculative: false,
        waveform: .linear(modulation: .psk8, symbolRate: RF.Numerology.GSM.symbolRate, pulse: .rootRaisedCosine(rolloff: 0.35)),
        facts: ["Same symbol rate as GSM, 3 bits per symbol.", "Simulated with an RRC pulse instead of EDGE's linearized GMSK pulse."],
        sources: ["TS 45.004 §3–4"]))
      out.append(RadioSystem(
        id: "umts", name: "UMTS / HSPA", generation: "3G", category: .cellular, year: 2001, yearNote: historyNote + "; HSDPA from 2005",
        bands: [
          band("Band V (850) UL", 824, 849, .uplink), band("Band V (850) DL", 869, 894, .downlink),
          band("Band VIII (900) UL", 880, 915, .uplink), band("Band VIII (900) DL", 925, 960, .downlink),
          band("Band IV (1700/2100) UL", 1710, 1755, .uplink), band("Band IV (1700/2100) DL", 2110, 2155, .downlink),
          band("Band II (1900) UL", 1850, 1910, .uplink), band("Band II (1900) DL", 1930, 1990, .downlink),
          band("Band I (2100) UL", 1920, 1980, .uplink), band("Band I (2100) DL", 2110, 2170, .downlink),
        ],
        iPhoneBands: ["850", "900", "1700/2100", "1900", "2100"],
        carrier: 2140e6, channelWidths: [5e6], modulation: "QPSK; HSDPA 16QAM (Rel-5), HSPA+ 64QAM (Rel-7)", maxQAM: 64,
        multiplexing: "WCDMA, 3.84 Mcps; DC-HSDPA (Rel-8) bonds two carriers", subcarrierSpacings: [],
        peakRate: PeakRate(value: 2 * 15 * 240e3 * 6, basis: .estimate, note: "raw DC-HSDPA ceiling: 2 carriers × 15 codes × SF16 (240 ksym/s) × 6 bits"),
        iPhone: .yes, iPhoneNote: "UMTS/HSPA+/DC-HSDPA 850, 900, 1700/2100, 1900, 2100 MHz.", isSpeculative: false,
        waveform: .dsss(modulation: .qam16, chipsPerSymbol: 15, chipRate: 3.84e6),
        facts: ["Chip rate 3.84 Mcps in a 5 MHz channel (TS 25.213 §4.4.1).", "WCDMA SF 256 processing gain: 24.08 dB.", "Apple lists 850, 900, 1700/2100, 1900 and 2100 MHz: UMTS operating bands V, VIII, IV, II and I."],
        sources: ["TS 25.213; release numbers [S]; Apple support 111828; band edges TS 25.101 Table 5.0 [S, not in the physics reference]"]))
      out.append(RadioSystem(
        id: "lte", name: "LTE", generation: "4G", category: .cellular, year: 2009, yearNote: historyNote,
        bands: [], iPhoneBands: iPhoneLTEBands,
        carrier: 1960e6, channelWidths: [1.4e6, 3e6, 5e6, 10e6, 15e6, 20e6], modulation: "QPSK … 256QAM (1024QAM defined in TS 36.211 §7.1.6)", maxQAM: 1024,
        multiplexing: "OFDMA downlink, 12-subcarrier resource blocks; 4×4 MIMO, carrier aggregation, LAA", subcarrierSpacings: [15e3],
        peakRate: PeakRate(value: 1200 * 14_000 * 8 * 4, basis: .estimate, note: "raw ceiling of one 20 MHz carrier: 1200 subcarriers × 14 000 sym/s × 8 bits × 4 layers; carrier aggregation multiplies it"),
        iPhone: .yes, iPhoneNote: "Gigabit LTE with 4×4 MIMO and LAA.", isSpeculative: false,
        waveform: .ofdm(modulation: .qam256, config: .scaled(name: "LTE (scaled)", fftSize: 256, usedFraction: 1200.0 / 2048, pilotSpacing: 6, cpFraction: 144.0 / 2048, subcarrierSpacing: 15e3)),
        facts: ["Δf = 15 kHz, T_u = 66.667 µs, normal CP 4.69 µs (5.21 µs on symbol 0).", "1.4/3/5/10/15/20 MHz → 6/15/25/50/75/100 RB.", "Slot: 160 + 2048 + 6 × (144 + 2048) = 15 360 T_s = 0.5 ms."],
        sources: ["TS 36.211 V19.3.0, TS 36.104 Table 5.6-1; Apple cellular page (A2849)"]))
      out.append(RadioSystem(
        id: "nr-fr1", name: "5G NR (FR1, sub-6 GHz)", generation: "5G", category: .cellular, year: 2019, yearNote: historyNote,
        bands: [band("FR1", 410, 7125)] + RF.Numerology.NR.bands.filter { $0.highMHz < 7125 }, iPhoneBands: iPhoneNRBands,
        carrier: 3550e6, channelWidths: [5e6, 10e6, 20e6, 40e6, 50e6, 60e6, 80e6, 100e6], modulation: "QPSK … 1024QAM (TS 38.211 §5.1)", maxQAM: 1024,
        multiplexing: "OFDMA, numerologies µ 0–2 (15/30/60 kHz); TDD in n41/n77/n78/n79", subcarrierSpacings: [15e3, 30e3, 60e3],
        peakRate: PeakRate(value: 3276 * 28_000 * 10 * 4, basis: .estimate, note: "raw ceiling: 273 RB × 12 subcarriers × 28 000 sym/s (30 kHz) × 10 bits × 4 layers"),
        iPhone: .yes, iPhoneNote: "5G sub-6 GHz with 4×4 MIMO; power class 3 (23 dBm).", isSpeculative: false,
        waveform: .ofdm(modulation: .qam256, config: .scaled(name: "NR 30 kHz (scaled)", fftSize: 512, usedFraction: 3276.0 / 4096, pilotSpacing: 6, cpFraction: 144.0 / 2048, subcarrierSpacing: 30e3)),
        facts: ["100 MHz at 30 kHz = 273 RB; guard band 845 kHz.", "SCS 15·2^µ kHz; slot 1/2^µ ms with 14 symbols.", "NR-ARFCN 633 333 = 3499.995 MHz."],
        sources: ["TS 38.211 V19.5.0, TS 38.104 V19.6.0, TS 38.101-1 V19.7.0"]))
      out.append(RadioSystem(
        id: "nr-fr2", name: "5G NR (FR2, mmWave)", generation: "5G", category: .cellular, year: 2019, yearNote: historyNote,
        bands: [band("FR2-1", 24_250, 52_600), band("FR2-2", 52_600, 71_000)] + RF.Numerology.NR.bands.filter { $0.lowMHz >= 24_250 },
        iPhoneBands: iPhoneMMWaveBands,
        carrier: 27.925e9, channelWidths: [50e6, 100e6, 200e6, 400e6, 2000e6], modulation: "QPSK … 256QAM", maxQAM: 256,
        multiplexing: "OFDMA, 120 kHz SCS (up to 960 kHz in FR2-2), beamformed arrays", subcarrierSpacings: [120e3, 480e3, 960e3],
        peakRate: PeakRate(value: 3168 * 112_000 * 8 * 2, basis: .estimate, note: "raw ceiling: 264 RB × 12 × 112 000 sym/s (120 kHz) × 8 bits × 2 layers"),
        iPhone: .partial, iPhoneNote: "US model A2849 only (n258, n260, n261); A3105, A3106 and A3108 have no mmWave.", isSpeculative: false,
        waveform: .ofdm(modulation: .qam64, config: .scaled(name: "NR 120 kHz (scaled)", fftSize: 512, usedFraction: 3168.0 / 4096, pilotSpacing: 6, cpFraction: 144.0 / 2048, subcarrierSpacing: 120e3)),
        facts: ["400 MHz at 120 kHz = 264 RB; FR2-2 2000 MHz at 960 kHz = 148 RB.", "λ/2 is 5.35 mm at 28 GHz: arrays fit in a phone's frame.", "1024QAM is FR1-only in Release 17 [S]."],
        sources: ["TS 38.104 Tables 5.1-1, 5.3.2-2/-3; Apple cellular page (A2849)"]))
      out.append(RadioSystem(
        id: "6g", name: "6G (IMT-2030)", generation: "6G", category: .cellular, year: 2030, yearNote: "target of the ITU IMT-2030 framework; first 3GPP specs about 2028–29 (Rel-21)",
        bands: [band("WRC-27 study", 4400, 4800), band("WRC-27 study", 7125, 8400), band("WRC-27 study", 14_800, 15_350),
                band("FR3 (study note)", 7000, 24_000), band("Sub-THz research", 100_000, 300_000)], iPhoneBands: [],
        carrier: 7.7625e9, channelWidths: [], modulation: "Not standardized (NR-like OFDM assumed here)", maxQAM: nil,
        multiplexing: "Not standardized", subcarrierSpacings: [], peakRate: nil,
        iPhone: .no, iPhoneNote: "6G does not exist yet.", isSpeculative: true,
        waveform: .ofdm(modulation: .qam256, config: .scaled(name: "6G placeholder: NR-like (scaled)", fftSize: 512, usedFraction: 0.8, pilotSpacing: 6, cpFraction: 144.0 / 2048, subcarrierSpacing: 30e3)),
        facts: ["ITU-R M.2160 framework (2023).", "WRC-27 agenda item 1.7 studies 4.4–4.8, 7.125–8.4 and 14.8–15.35 GHz.", "3GPP Rel-20 studies from 2025."],
        sources: ["rf-physics E.1 [S] ITU WRS-24, 3GPP Rel-20, Ericsson; TR 38.901 Table 7.4.3-1 note 2"]))
      return out
    }

    // MARK: Wi-Fi

    private static func wifi() -> [RadioSystem] {
      var out: [RadioSystem] = []
      let ism = band("2.4 GHz ISM", 2400, 2483.5)
      let fiveGHz = band("5 GHz", 5150, 5850)
      let sixUS = band("6 GHz (US)", 5925, 7125)
      let sixEU = band("6 GHz (Europe)", 5945, 6425)
      let iPhoneWiFi = "Wi-Fi 6E (802.11ax) 2×2: 160 MHz at 5 and 6 GHz (2400 Mb/s), 20 MHz at 2.4 GHz (229 Mb/s)."
      let ht20: OFDMConfig = {
        let pilots = [-21, -7, 7, 21]
        let data = (-28...28).filter { $0 != 0 && !pilots.contains($0) }
        return OFDMConfig(name: "802.11n HT20", fftSize: 64, cyclicPrefix: 16, dataSubcarriers: data, pilotSubcarriers: pilots, subcarrierSpacing: RF.Numerology.WiFi.legacySubcarrierSpacing, estimation: .preamble)
      }()
      out.append(RadioSystem(
        id: "wifi-b", name: "802.11b", generation: "Wi-Fi 1", category: .wifi, year: 1999, yearNote: historyNote,
        bands: [ism], iPhoneBands: [], carrier: 2.437e9, channelWidths: [22e6], modulation: "DBPSK/DQPSK with Barker-11, CCK at 11 Mb/s", maxQAM: nil,
        multiplexing: "DSSS, CSMA/CA", subcarrierSpacings: [],
        peakRate: PeakRate(value: 11e6, basis: .table, note: "headline PHY rate (CCK)"),
        iPhone: .yes, iPhoneNote: "Backward compatible: " + iPhoneWiFi, isSpeculative: false,
        waveform: .dsss(modulation: .qpsk, chipsPerSymbol: 11, chipRate: 11e6),
        facts: ["Barker-11 processing gain 10.41 dB.", "Carrier shown: 2.437 GHz (channel 6)."], sources: ["rf-physics E.2, D.7"]))
      out.append(RadioSystem(
        id: "wifi-a", name: "802.11a", generation: "Wi-Fi 2", category: .wifi, year: 1999, yearNote: historyNote,
        bands: [fiveGHz], iPhoneBands: [], carrier: 5.5e9, channelWidths: [20e6], modulation: "BPSK … 64QAM, OFDM", maxQAM: 64,
        multiplexing: "OFDM, 64-point FFT, 48 data + 4 pilot subcarriers; CSMA/CA", subcarrierSpacings: [RF.Numerology.WiFi.legacySubcarrierSpacing],
        peakRate: PeakRate(value: RF.Numerology.WiFi.rate11a, basis: .formula, note: "48 × 6 bits × 3/4 / 4 µs"),
        iPhone: .yes, iPhoneNote: "Backward compatible: " + iPhoneWiFi, isSpeculative: false,
        waveform: .ofdm(modulation: .qam64, config: .wifiLegacy),
        facts: ["Δf = 20 MHz/64 = 312.5 kHz, T_u 3.2 µs, GI 0.8 µs.", "5 GHz band edges shown are nominal [S]."], sources: ["rf-physics D.9, E.2"]))
      out.append(RadioSystem(
        id: "wifi-g", name: "802.11g", generation: "Wi-Fi 3", category: .wifi, year: 2003, yearNote: historyNote,
        bands: [ism], iPhoneBands: [], carrier: 2.437e9, channelWidths: [20e6], modulation: "BPSK … 64QAM, OFDM", maxQAM: 64,
        multiplexing: "OFDM (802.11a PHY at 2.4 GHz); CSMA/CA", subcarrierSpacings: [RF.Numerology.WiFi.legacySubcarrierSpacing],
        peakRate: PeakRate(value: RF.Numerology.WiFi.rate11a, basis: .formula, note: "48 × 6 bits × 3/4 / 4 µs"),
        iPhone: .yes, iPhoneNote: "Backward compatible: " + iPhoneWiFi, isSpeculative: false,
        waveform: .ofdm(modulation: .qam64, config: .wifiLegacy), facts: ["Same OFDM numerology as 802.11a."], sources: ["rf-physics E.2"]))
      out.append(RadioSystem(
        id: "wifi-n", name: "802.11n", generation: "Wi-Fi 4", category: .wifi, year: 2009, yearNote: historyNote,
        bands: [ism, fiveGHz], iPhoneBands: [], carrier: 5.5e9, channelWidths: [20e6, 40e6], modulation: "BPSK … 64QAM, OFDM, up to 4 streams", maxQAM: 64,
        multiplexing: "OFDM + MIMO (≤ 4 spatial streams); CSMA/CA", subcarrierSpacings: [RF.Numerology.WiFi.legacySubcarrierSpacing],
        peakRate: PeakRate(value: RF.Numerology.WiFi.rate11n, basis: .formula, note: "108 × 6 × 5/6 / 3.6 µs × 4 streams"),
        iPhone: .yes, iPhoneNote: "Backward compatible: " + iPhoneWiFi, isSpeculative: false,
        waveform: .ofdm(modulation: .qam64, config: ht20), facts: ["Short GI 0.4 µs gives a 3.6 µs symbol."], sources: ["rf-physics E.2"]))
      out.append(RadioSystem(
        id: "wifi-ac", name: "802.11ac", generation: "Wi-Fi 5", category: .wifi, year: 2013, yearNote: historyNote,
        bands: [fiveGHz], iPhoneBands: [], carrier: 5.5e9, channelWidths: [20e6, 40e6, 80e6, 160e6], modulation: "BPSK … 256QAM, OFDM, up to 8 streams", maxQAM: 256,
        multiplexing: "OFDM + MU-MIMO (≤ 8 spatial streams); CSMA/CA", subcarrierSpacings: [RF.Numerology.WiFi.legacySubcarrierSpacing],
        peakRate: PeakRate(value: RF.Numerology.WiFi.rate11ac, basis: .formula, note: "468 × 8 × 5/6 / 3.6 µs × 8 streams"),
        iPhone: .yes, iPhoneNote: "Backward compatible: " + iPhoneWiFi, isSpeculative: false,
        waveform: .ofdm(modulation: .qam256, config: .scaled(name: "VHT80 (scaled)", fftSize: 256, usedFraction: 242.0 / 256, pilotSpacing: 30, cpFraction: 0.25, subcarrierSpacing: RF.Numerology.WiFi.legacySubcarrierSpacing, estimation: .preamble)),
        facts: ["160 MHz channels, 256QAM."], sources: ["rf-physics E.2"]))
      out.append(RadioSystem(
        id: "wifi-ax", name: "802.11ax", generation: "Wi-Fi 6", category: .wifi, year: 2019, yearNote: historyNote,
        bands: [ism, fiveGHz], iPhoneBands: [], carrier: 5.5e9, channelWidths: [20e6, 40e6, 80e6, 160e6], modulation: "BPSK … 1024QAM, OFDMA", maxQAM: 1024,
        multiplexing: "OFDMA + MU-MIMO (≤ 8 streams), 78.125 kHz subcarriers", subcarrierSpacings: [RF.Numerology.WiFi.heSubcarrierSpacing],
        peakRate: PeakRate(value: RF.Numerology.WiFi.rate11ax, basis: .formula, note: "1960 × 10 × 5/6 / 13.6 µs × 8 streams"),
        iPhone: .yes, iPhoneNote: iPhoneWiFi, isSpeculative: false,
        waveform: .ofdm(modulation: .qam1024, config: .scaled(name: "HE20 (scaled)", fftSize: 256, usedFraction: 242.0 / 256, pilotSpacing: 30, cpFraction: 0.0625, subcarrierSpacing: RF.Numerology.WiFi.heSubcarrierSpacing, estimation: .preamble)),
        facts: ["Δf = 78.125 kHz, T_u 12.8 µs; GI 0.8/1.6/3.2 µs.", "1024QAM needs about −35 dB EVM."], sources: ["rf-physics D.9, E.2, C.7 (NI)"]))
      out.append(RadioSystem(
        id: "wifi-6e", name: "802.11ax in 6 GHz", generation: "Wi-Fi 6E", category: .wifi, year: 2021, yearNote: historyNote,
        bands: [sixUS, sixEU], iPhoneBands: [], carrier: 6.525e9, channelWidths: [20e6, 40e6, 80e6, 160e6], modulation: "BPSK … 1024QAM, OFDMA", maxQAM: 1024,
        multiplexing: "OFDMA + MU-MIMO in the 6 GHz band", subcarrierSpacings: [RF.Numerology.WiFi.heSubcarrierSpacing],
        peakRate: PeakRate(value: RF.Numerology.WiFi.rateIPhone15ProMax, basis: .formula, note: "this iPhone: 1960 × 10 × 5/6 / 13.6 µs × 2 streams (Apple lists 2400 Mb/s)"),
        iPhone: .yes, iPhoneNote: iPhoneWiFi, isSpeculative: false,
        waveform: .ofdm(modulation: .qam1024, config: .scaled(name: "HE20 (scaled)", fftSize: 256, usedFraction: 242.0 / 256, pilotSpacing: 30, cpFraction: 0.0625, subcarrierSpacing: RF.Numerology.WiFi.heSubcarrierSpacing, estimation: .preamble)),
        facts: ["US 5925–7125 MHz (FCC 20-51), Europe 5945–6425 MHz (ECC (20)01)."], sources: ["rf-physics E.2; Apple Wi-Fi deployment guide"]))
      out.append(RadioSystem(
        id: "wifi-be", name: "802.11be", generation: "Wi-Fi 7", category: .wifi, year: 2024, yearNote: historyNote,
        bands: [ism, fiveGHz, sixUS], iPhoneBands: [], carrier: 6.525e9, channelWidths: [20e6, 40e6, 80e6, 160e6, 320e6], modulation: "BPSK … 4096QAM, OFDMA", maxQAM: 4096,
        multiplexing: "OFDMA + MU-MIMO (≤ 8 streams), multi-link operation", subcarrierSpacings: [RF.Numerology.WiFi.heSubcarrierSpacing],
        peakRate: PeakRate(value: RF.Numerology.WiFi.rate11be, basis: .formula, note: "3920 × 12 × 5/6 / 13.6 µs × 8 streams"),
        iPhone: .no, iPhoneNote: "The iPhone 15 Pro Max tops out at Wi-Fi 6E.", isSpeculative: false,
        waveform: .ofdm(modulation: .qam4096, config: .scaled(name: "EHT (scaled)", fftSize: 256, usedFraction: 242.0 / 256, pilotSpacing: 30, cpFraction: 0.0625, subcarrierSpacing: RF.Numerology.WiFi.heSubcarrierSpacing, estimation: .preamble)),
        facts: ["8 spatial streams in the final amendment (not 16).", "Wi-Fi CERTIFIED 7 requires MLO; 320 MHz and 4096QAM are optional.", "4096QAM is commonly quoted at −38 dB EVM [S]."],
        sources: ["rf-physics E.2 (MathWorks, Juniper [S])"]))
      return out
    }

    // MARK: Personal-area and short-range

    private static func personal() -> [RadioSystem] {
      var out: [RadioSystem] = []
      out.append(RadioSystem(
        id: "bt-classic", name: "Bluetooth Classic (BR/EDR)", generation: "Bluetooth", category: .personal, year: 1999, yearNote: historyNote,
        bands: [band("2.4 GHz ISM", 2400, 2483.5)], iPhoneBands: [], carrier: 2441e6, channelWidths: [1e6],
        modulation: "GFSK (h 0.28–0.35, BT 0.5); EDR π/4-DQPSK and 8DPSK", maxQAM: nil,
        multiplexing: "FHSS over 79 × 1 MHz channels, 1600 hops/s, TDD 625 µs slots", subcarrierSpacings: [],
        peakRate: PeakRate(value: 3e6, basis: .table, note: "EDR 8DPSK at 1 Msym/s (BR 1 Mb/s)"),
        iPhone: .yes, iPhoneNote: "Bluetooth 5.3.", isSpeculative: false,
        waveform: .fsk(index: 0.32, bt: 0.5, symbolRate: 1e6),
        facts: ["Channels at 2402 + k MHz, k = 0…78.", "Slot 625 µs = 1/1600 s."], sources: ["Core 5.4 Vol 2 Part A/B"]))
      out.append(RadioSystem(
        id: "ble", name: "Bluetooth Low Energy", generation: "BLE", category: .personal, year: 2010, yearNote: historyNote,
        bands: [band("2.4 GHz ISM", 2400, 2483.5)], iPhoneBands: [], carrier: 2402e6, channelWidths: [2e6],
        modulation: "GFSK (h 0.45–0.55, BT 0.5); LE Coded S=2/S=8", maxQAM: nil,
        multiplexing: "40 × 2 MHz channels: 3 advertising (37, 38, 39) + 37 data with hopping", subcarrierSpacings: [],
        peakRate: PeakRate(value: 2e6, basis: .table, note: "LE 2M PHY (LE 1M 1 Mb/s, Coded 500/125 kb/s)"),
        iPhone: .yes, iPhoneNote: "Bluetooth 5.3; the Live tab reads BLE RSSI.", isSpeculative: false,
        waveform: .fsk(index: 0.5, bt: 0.5, symbolRate: 1e6),
        facts: ["Advertising: 37 = 2402, 38 = 2426, 39 = 2480 MHz.", "h = 0.5 at 1 Mb/s → Δf = 250 kHz.", "Sensitivity ≤ −70 / −75 / −82 dBm (1M / S2 / S8)."],
        sources: ["Core 5.4 Vol 6 Part A/B"]))
      out.append(RadioSystem(
        id: "nfc", name: "NFC (ISO/IEC 14443)", generation: "NFC", category: .personal, year: 2004, yearNote: historyNote,
        bands: [band("13.56 MHz ± subcarrier", 13.56 - 0.8475, 13.56 + 0.8475)], iPhoneBands: [], carrier: 13.56e6, channelWidths: [2 * 847.5e3],
        modulation: "Reader→card 100 % ASK (Type A, modified Miller); card→reader load modulation of an 847.5 kHz subcarrier", maxQAM: nil,
        multiplexing: "Half-duplex, inductive coupling", subcarrierSpacings: [],
        peakRate: PeakRate(value: RF.Numerology.NFC.bitRate, basis: .formula, note: "f_c/128 = 105.9375 kbit/s"),
        iPhone: .yes, iPhoneNote: "NFC with reader mode; apps on a free team cannot use it (LOCKED).", isSpeculative: false,
        waveform: .linear(modulation: .ook, symbolRate: RF.Numerology.NFC.bitRate, pulse: .rectangular),
        facts: ["λ = 22.1 m: a 4 cm coil is deep in the reactive near field (λ/2π = 3.52 m).", "Radiation resistance of a 40 × 30 mm, 4-turn coil: 3.0 µΩ."],
        sources: ["Atmel/Microchip doc2056; rf-physics A.5"]))
      out.append(RadioSystem(
        id: "uwb-ch5", name: "UWB channel 5", generation: "UWB", category: .personal, year: 2020, yearNote: historyNote + " (IEEE 802.15.4z)",
        bands: [band("Channel 5", 6489.6 - 249.6, 6489.6 + 249.6)], iPhoneBands: [], carrier: RF.Numerology.UWB.channel5, channelWidths: [499.2e6],
        modulation: "HRP pulses (~2 ns), burst-position + BPSK", maxQAM: nil, multiplexing: "Impulse radio, time-of-flight ranging", subcarrierSpacings: [],
        peakRate: nil, iPhone: .yes, iPhoneNote: "Second-generation Ultra Wideband chip (availability varies by region); needs a peer device.", isSpeculative: false,
        waveform: .linear(modulation: .bpsk, symbolRate: 499.2e6 / 1.5, pulse: .rootRaisedCosine(rolloff: 0.5)),
        facts: ["13 × 499.2 MHz = 6489.6 MHz.", "1 m of range = 3.3356 ns of flight; c/2B ≈ 0.30 m resolution (rule of thumb)."],
        sources: ["Keysight HRP overview, Qorvo [S]; Apple support 109512"]))
      out.append(RadioSystem(
        id: "uwb-ch9", name: "UWB channel 9", generation: "UWB", category: .personal, year: 2020, yearNote: historyNote + " (IEEE 802.15.4z)",
        bands: [band("Channel 9", 7987.2 - 249.6, 7987.2 + 249.6)], iPhoneBands: [], carrier: RF.Numerology.UWB.channel9, channelWidths: [499.2e6],
        modulation: "HRP pulses (~2 ns), burst-position + BPSK", maxQAM: nil, multiplexing: "Impulse radio, time-of-flight ranging", subcarrierSpacings: [],
        peakRate: nil, iPhone: .yes, iPhoneNote: "Second-generation Ultra Wideband chip (availability varies by region); needs a peer device.", isSpeculative: false,
        waveform: .linear(modulation: .bpsk, symbolRate: 499.2e6 / 1.5, pulse: .rootRaisedCosine(rolloff: 0.5)),
        facts: ["16 × 499.2 MHz = 7987.2 MHz."], sources: ["Keysight HRP overview, Qorvo [S]"]))
      out.append(RadioSystem(
        id: "qi", name: "Qi / Qi2 wireless charging", generation: "Qi", category: .personal, year: 2010, yearNote: historyNote + " (WPC v1.0)",
        bands: [band("BPP/EPP", 0.087, 0.205), band("Qi2 MPP", 0.36, 0.36)], iPhoneBands: [], carrier: 146e3, channelWidths: [],
        modulation: "Power carrier (in-band ASK/FSK messages not modeled)", maxQAM: nil, multiplexing: "Inductive power transfer", subcarrierSpacings: [],
        peakRate: nil, iPhone: .yes, iPhoneNote: "MagSafe and Qi2 up to 15 W, Qi up to 7.5 W.", isSpeculative: false,
        waveform: .tone,
        facts: ["Operating frequency typically 87–205 kHz (BPP/EPP); Qi2 MPP about 360 kHz [S].", "λ ≈ 2 km: pure near-field magnetic coupling."],
        sources: ["WPC Qi v1.3 §4.2; Granite River Labs [S]; Apple support 111828"]))
      return out
    }

    // MARK: Navigation

    private static func navigation() -> [RadioSystem] {
      var out: [RadioSystem] = []
      let gps = RF.Numerology.GPS.self
      out.append(RadioSystem(
        id: "gps-l1", name: "GPS L1 C/A", generation: "GNSS", category: .navigation, year: 1978, yearNote: historyNote + " (first satellite; full capability 1995)",
        bands: [band("L1 main lobe", (gps.l1 - gps.caChipRate) / 1e6, (gps.l1 + gps.caChipRate) / 1e6, .receiveOnly)], iPhoneBands: [],
        carrier: gps.l1, channelWidths: [2 * gps.caChipRate], modulation: "BPSK, 1.023 Mcps C/A code", maxQAM: nil,
        multiplexing: "CDMA (one code per satellite)", subcarrierSpacings: [],
        peakRate: PeakRate(value: gps.navBitRate, basis: .table, note: "LNAV message, 50 bit/s"),
        iPhone: .yes, iPhoneNote: "Precision dual-frequency GPS (L1 + L5) with GLONASS, Galileo, QZSS, BeiDou, NavIC.", isSpeculative: false,
        waveform: .dsss(modulation: .bpsk, chipsPerSymbol: 1023, chipRate: gps.caChipRate),
        facts: ["L1 = 154 × 10.23 MHz = 1575.42 MHz.", "Minimum received power −158.5 dBW (−128.5 dBm) at a 3 dBi antenna.", "Processing gain 1.023 M / 50 = 43.11 dB.", "FSPL at 20 200 km: 182.5 dB."],
        sources: ["IS-GPS-200N Table 3-Va, §3.3.1"]))
      out.append(RadioSystem(
        id: "gps-l5", name: "GPS L5", generation: "GNSS", category: .navigation, year: 2010, yearNote: historyNote + " (first L5 satellite)",
        bands: [band("L5 main lobe", (gps.l5 - gps.l5ChipRate) / 1e6, (gps.l5 + gps.l5ChipRate) / 1e6, .receiveOnly)], iPhoneBands: [],
        carrier: gps.l5, channelWidths: [2 * gps.l5ChipRate], modulation: "QPSK (I5 data, Q5 pilot), 10.23 Mcps", maxQAM: nil,
        multiplexing: "CDMA", subcarrierSpacings: [], peakRate: nil,
        iPhone: .yes, iPhoneNote: "Dual-frequency GPS receives L5.", isSpeculative: false,
        waveform: .dsss(modulation: .qpsk, chipsPerSymbol: 1023, chipRate: gps.l5ChipRate),
        facts: ["L5 = 115 × 10.23 MHz = 1176.45 MHz.", "10 230-chip codes (simulated with 1023 chips).", "Minimum −157.9 dBW (IIF) / −157.0 dBW (GPS III) per component."],
        sources: ["IS-GPS-705J §3.2.1.1, Table 3-III"]))
      return out
    }

    // MARK: Radar (radiodetermination, filed under Navigation)

    /// FMCW radar presets for the Fourier page's time–frequency view (SPEC-features §3c): a chirp
    /// whose Wigner distribution is a straight line. Bands and chirp numbers are not in the
    /// physics reference [S]; the range resolution c/2B is its E.4 rule of thumb. The simulated
    /// chirp is scaled to 4096 samples (one Fourier frame) at 2B samples per second.
    private static func radar() -> [RadioSystem] {
      let c = RF.Const.c
      func chirpTime(_ b: Double) -> Double { 4096 / (2 * b) }
      var out: [RadioSystem] = []
      out.append(RadioSystem(
        id: "fmcw-77", name: "Automotive radar (77 GHz FMCW)", generation: "Radar", category: .navigation, year: 1999,
        yearNote: "approximate: first 77 GHz adaptive cruise control in production cars (general history, not from the physics reference)",
        bands: [band("76–81 GHz automotive radar", 76_000, 81_000)], iPhoneBands: [], carrier: 77e9, channelWidths: [1e9],
        modulation: "FMCW: repeated linear frequency chirps", maxQAM: nil, multiplexing: "Radiolocation (no data); range from the beat frequency",
        subcarrierSpacings: [], peakRate: nil,
        iPhone: .no, iPhoneNote: "The iPhone has no radar; its LiDAR Scanner ranges with light.", isSpeculative: false,
        waveform: .chirp(bandwidth: 1e9, duration: chirpTime(1e9)),
        facts: [String(format: "Range resolution c/2B = %.0f cm for a 1 GHz sweep.", c / 2e9 * 100),
                "Simulated chirp: 1 GHz in 2.048 µs (4096 samples at 2 GS/s); production chirps last tens of µs [S].",
                "Its Wigner distribution is a straight line: the frequency rises at B/T.",
                "ITU radiolocation service, part of radiodetermination with GNSS."],
        sources: ["Range resolution: rf-physics E.4 (c/2B rule of thumb); band and chirp numbers [S, not in the physics reference]"]))
      out.append(RadioSystem(
        id: "fmcw-24", name: "24 GHz radar (FMCW)", generation: "Radar", category: .navigation, year: 2005,
        yearNote: "approximate: 24 GHz short-range car radars (general history, not from the physics reference)",
        bands: [band("24 GHz ISM", 24_050, 24_250)], iPhoneBands: [], carrier: 24.15e9, channelWidths: [200e6],
        modulation: "FMCW: repeated linear frequency chirps", maxQAM: nil, multiplexing: "Radiolocation (no data); range from the beat frequency",
        subcarrierSpacings: [], peakRate: nil,
        iPhone: .no, iPhoneNote: "The iPhone has no radar; its LiDAR Scanner ranges with light.", isSpeculative: false,
        waveform: .chirp(bandwidth: 200e6, duration: chirpTime(200e6)),
        facts: [String(format: "Range resolution c/2B = %.2f m across the 200 MHz ISM band.", c / 4e8),
                "Simulated chirp: 200 MHz in 10.24 µs (4096 samples at 400 MS/s).",
                "Narrow sweeps trade range resolution for a cheap, licence-free band."],
        sources: ["Range resolution: rf-physics E.4 (c/2B rule of thumb); band edges [S, not in the physics reference]"]))
      return out
    }

    // MARK: Broadcast

    private static func broadcast() -> [RadioSystem] {
      var out: [RadioSystem] = []
      out.append(RadioSystem(
        id: "am", name: "AM broadcast", generation: "AM", category: .broadcast, year: 1920, yearNote: historyNote,
        bands: [band("US MF", 0.535, 1.705), band("ITU Regions 1/3", 0.5265, 1.6065)], iPhoneBands: [], carrier: 1e6, channelWidths: [9e3, 10e3],
        modulation: "Double-sideband AM with carrier", maxQAM: nil, multiplexing: "FDMA, 10 kHz raster (US) / 9 kHz (ITU 1/3)", subcarrierSpacings: [],
        peakRate: nil, iPhone: .no, iPhoneNote: "The iPhone has no AM tuner.", isSpeculative: false,
        waveform: .analogAM(depth: 0.8),
        facts: ["US carriers 540–1700 kHz in 10 kHz steps (117 channels).", "m = 1: P_t/P_c = 1.5, only ⅓ of the power is in the sidebands."],
        sources: ["47 CFR §73.14; ITU broadcasting bands"]))
      out.append(RadioSystem(
        id: "fm", name: "FM broadcast", generation: "FM", category: .broadcast, year: 1941, yearNote: historyNote,
        bands: [band("US", 88, 108), band("ITU Band II", 87.5, 108)], iPhoneBands: [], carrier: 98.1e6, channelWidths: [200e3],
        modulation: "Wideband FM, ±75 kHz = 100 %", maxQAM: nil, multiplexing: "FDMA, 200 kHz channels (ch 201 = 88.1 MHz … ch 300 = 107.9 MHz)", subcarrierSpacings: [],
        peakRate: nil, iPhone: .no, iPhoneNote: "Not listed in Apple's specifications for this iPhone.", isSpeculative: false,
        waveform: .analogFM(deviation: 75e3, audioBandwidth: 15e3),
        facts: ["β = 75/15 = 5; Carson bandwidth 180 kHz.", "99.36 % of the power lies within ±6 Bessel sidebands at β = 5."],
        sources: ["47 CFR §73.201, §73.310; Stanford EE179 [S]"]))
      out.append(RadioSystem(
        id: "dab", name: "DAB digital radio", generation: "DAB", category: .broadcast, year: 1995, yearNote: historyNote,
        bands: [band("Band III", 174, 240)], iPhoneBands: [], carrier: 207e6, channelWidths: [1.536e6],
        modulation: "DQPSK on OFDM subcarriers", maxQAM: nil, multiplexing: "COFDM, 1536 carriers × 1 kHz (mode I)", subcarrierSpacings: [1e3],
        peakRate: nil, iPhone: .no, iPhoneNote: "No broadcast tuner.", isSpeculative: false,
        waveform: .ofdm(modulation: .qpsk, config: .scaled(name: "DAB mode I (scaled)", fftSize: 512, usedFraction: 0.75, pilotSpacing: 12, cpFraction: 0.246, subcarrierSpacing: 1e3, estimation: .preamble)),
        facts: ["Mode I: T_u = 1 ms, guard 246 µs [S]."], sources: ["EBU Tech 3391 / ETSI EN 300 401 [S]"]))
      out.append(RadioSystem(
        id: "tv", name: "Digital terrestrial TV", generation: "DTT", category: .broadcast, year: 1998, yearNote: historyNote,
        bands: [band("VHF I (Region 1)", 47, 68), band("VHF III", 174, 230), band("UHF", 470, 862)], iPhoneBands: [], carrier: 600e6, channelWidths: [6e6, 7e6, 8e6],
        modulation: "DVB-T: QPSK … 64QAM COFDM (ATSC 1.0 uses 8-VSB)", maxQAM: 64, multiplexing: "COFDM 2k/8k modes (DVB-T); 6 MHz ATSC channels in the US", subcarrierSpacings: [1116.07],
        peakRate: nil, iPhone: .no, iPhoneNote: "No broadcast tuner.", isSpeculative: false,
        waveform: .ofdm(modulation: .qam64, config: .scaled(name: "DVB-T 8k (scaled)", fftSize: 512, usedFraction: 6817.0 / 8192, pilotSpacing: 12, cpFraction: 0.25, subcarrierSpacing: 1116.07)),
        facts: ["DVB-T 8k mode: T_u 896 µs, 6817 carriers [S]."], sources: ["ITU bands page; channel widths and DVB-T numerology [S]"]))
      return out
    }
  }
}

nonisolated extension RF.SpreadingCode {
  /// A code of the requested length: Barker-11 for 11, a maximal-length sequence for 2ⁿ − 1
  /// (n = 2…10, primitive feedback polynomials), nil otherwise.
  static func forLength(_ length: Int) -> RF.SpreadingCode? {
    if length == 11 { return .barker11 }
    let taps: [Int: [Int]] = [2: [1, 2], 3: [2, 3], 4: [3, 4], 5: [3, 5], 6: [5, 6], 7: [6, 7], 8: [4, 5, 6, 8], 9: [5, 9], 10: [3, 10]]
    for (n, t) in taps where (1 << n) - 1 == length {
      if n == 10 { return .mSequence1023 }
      if n == 7 { return .mSequence127 }
      return .mSequence(degree: n, taps: t)
    }
    return nil
  }
}
