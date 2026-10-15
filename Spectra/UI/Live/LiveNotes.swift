import Foundation

/// Field notes for the Live tab: what is measured, what is inferred or modelled, how each
/// source is sampled, where the numbers come from, and what stays private.
enum LiveNotes {
  @MainActor static let notes = FieldNotes(
    title: "Live",
    intro:
      "The iPhone's own radios and sensors as instruments. Every card says whether its numbers are measured (LIVE), worked out from a measurement (INFERRED), computed from a model or a table, or simulated (SIM). Cards run only while they are on screen.",
    sections: [
      FieldNoteSection(
        number: "01", title: "What iOS lets an app measure",
        paragraphs: [
          "Bluetooth LE advertisements are the only true live radio power reading: each advert arrives with its RSSI in dBm. Cellular and Wi-Fi give only their generation, a link-quality bucket and the data path's radio type; no public API gives their signal strength. GNSS gives the fix quality, not the satellites.",
          "Every sample keeps the sensor's own timestamp (Core Motion log time, audio host time, Bluetooth callback time), so spectra use the true sample rate, and each card shows the rate it measures. The sensor census (transport ⋯ menu, the Dials, or the last card) lists every rate and capability this iPhone reports.",
        ],
        items: [
          FieldNoteItem(.live, "Bluetooth RSSI", "Per advertisement, scanning with duplicates, one stream per radio."),
          FieldNoteItem(.live, "Magnetometer", "Raw push at the hardware's top rate (about 100 Hz) plus the calibrated field."),
          FieldNoteItem(.live, "Microphone", "48 kHz through the iOS 27 audio tap; nothing is recorded."),
          FieldNoteItem(.inferred, "Wireless charging", "Charging plus a large static field step means MagSafe or Qi."),
          FieldNoteItem(.inferred, "Magnetic latitude", "From the dip angle with the dipole relation tan I = 2 tan λ."),
          FieldNoteItem(.inferred, "Mains hum", "A line at the folded 50 or 60 Hz position is attributed to the mains."),
          FieldNoteItem(.model, "Lux", "EV₁₀₀ from the camera's exposure, E = 2.5·2^EV (C = 250), ±30–50 %."),
          FieldNoteItem(.model, "Bluetooth distance", "Log-distance path loss on the averaged RSSI with your exponent n; fading makes it rough."),
          FieldNoteItem(.locked, "NFC and Wi-Fi name", "Need a paid Apple developer team; the cards show the model instead."),
          FieldNoteItem(.needsPeer, "Ultra wideband", "Ranging needs a second UWB device such as an Apple Watch."),
        ],
        sources: [
          FieldNoteSource("Apple, Core Bluetooth: centralManager(_:didDiscover:advertisementData:rssi:)", "https://developer.apple.com/documentation/corebluetooth"),
          FieldNoteSource("Apple, Core Motion: CMLogItem.timestamp", "https://developer.apple.com/documentation/coremotion"),
          FieldNoteSource("Apple, Network: NWPath and NWConnection reports", "https://developer.apple.com/documentation/network"),
        ]),
      FieldNoteSection(
        number: "02", title: "Aliasing on the magnetometer",
        paragraphs: [
          "A sensor sampled at fs shows nothing above fs/2. Faster fields fold back to |f − fs·round(f/fs)|. Near a power brick, 60 Hz mains sampled at 99.8 Hz appears at 39.8 Hz and its 120 Hz harmonic at 20.2 Hz; 50 Hz mains sits right at Nyquist. The phone may also filter the field internally, so a missing line is not proof of a quiet room.",
          "The same magnetometer gives Spin its field: water protons precess at γ′ₚ·|B| = 42.576 MHz/T × |B|, about 2 kHz in Earth's field, which Spin plays at true pitch.",
        ],
        sources: [
          FieldNoteSource("C. E. Shannon, Communication in the presence of noise, Proc. IRE 37, 10 (1949)", "https://doi.org/10.1109/JRPROC.1949.232969"),
          FieldNoteSource("CODATA 2022, shielded proton gyromagnetic ratio", "https://physics.nist.gov/cuu/Constants/"),
        ]),
      FieldNoteSection(
        number: "03", title: "The turntable experiment",
        paragraphs: [
          "One RSSI stream cannot separate an antenna pattern from multipath. Spectra bins one radio's adverts by the phone's yaw (36 bins of 10°, at least 8 adverts each, three turns) and compares the per-bin spread with pure Rayleigh fading (5.57 dB). If the spread is that large, the shape mostly shows the room, not the antenna. The dashed curve is a λ/2 dipole along the phone (MODEL), aligned to the strongest bin because the direction to the radio is unknown."
        ],
        sources: [
          FieldNoteSource("A. Goldsmith, Wireless Communications (2005), ch. 3: Rayleigh fading"),
          FieldNoteSource("C. A. Balanis, Antenna Theory, 4th ed. (2016), the half-wave dipole"),
        ]),
      FieldNoteSection(
        number: "04", title: "Light meter and flicker (experimental)",
        paragraphs: [
          "The camera meters the scene and reports its own ISO, exposure time, aperture and metering offset. Spectra turns them into EV₁₀₀ = log₂(N²/t) − log₂(S/100) + offset and an approximate illuminance with the incident-meter constant C = 250. The color temperature is the camera's white balance; its Wien peak goes on the strip as INFERRED.",
          "A phone camera reads its rows one after another (a rolling shutter), so the average of each band of rows samples the light a few thousand times a second. Lamps on mains dim twice per cycle, so 100 or 120 Hz shows as bands and as a line in the row signal's spectrum. The row readout time is not published: the frequency axis assumes the rows span one frame time (MODEL).",
        ],
        sources: [
          FieldNoteSource("ISO 2720:1974, general purpose photographic exposure meters (calibration constant C)"),
          FieldNoteSource("Apple, AVCaptureDevice exposure and white balance", "https://developer.apple.com/documentation/avfoundation/avcapturedevice"),
        ]),
      FieldNoteSection(
        number: "05", title: "Air as a radio medium",
        paragraphs: [
          "The barometer gives pressure; temperature and humidity are your knobs, because no public iOS API measures them. Radio refractivity N = 77.6·P_d/T + 72·e/T + 3.75·10⁵·e/T² (P.453, with P_d = P − e the dry pressure and e the vapor pressure, in hPa and K; close to the classic 77.6/T·(P + 4810·e/T)), so n − 1 = N ppm. The gradient dN/dh (N-units per km) sets the effective Earth radius factor k = 1/(1 + a·dN/dh·10⁻⁶) with a = 6371 km, and the radio horizon is √(2·k·a·h) for antenna height h; past −157 N/km rays follow the Earth (ducting).",
          "The same pressure sets the GNSS zenith hydrostatic delay (Saastamoinen, about 2.3 m at sea level), and oxygen absorbs about 15 dB/km near 60 GHz at the ground (P.676).",
        ],
        sources: [
          FieldNoteSource("ITU-R P.453-14, the radio refractive index", "https://www.itu.int/rec/R-REC-P.453"),
          FieldNoteSource("ITU-R P.676-13, attenuation by atmospheric gases", "https://www.itu.int/rec/R-REC-P.676"),
          FieldNoteSource("IERS Conventions 2010, ch. 9 (zenith hydrostatic delay)", "https://iers-conventions.obspm.fr/content/chapter9/icc9.pdf"),
        ]),
      FieldNoteSection(
        number: "06", title: "Satellites, charging, NFC and UWB",
        paragraphs: [
          "GPS L1 (1575.42 MHz = 154 × 10.23 MHz) arrives at no less than −128.5 dBm, about 20 dB below the noise in its 2 MHz band; correlating 1023-chip codes over each 50 bit/s bit gains 43 dB. The constellation orbits 20,200 km up, 67 ms away at the speed of light.",
          "Qi charging runs at 87–205 kHz and Qi2 / MagSafe near 360 kHz: wavelengths of kilometers, so the coils couple through the near magnetic field. NFC at 13.56 MHz (λ ≈ 22 m) is also near-field coupling. Ultra wideband channel 9 sits at 7987.2 MHz, 499.2 MHz wide, which resolves about 30 cm of range.",
        ],
        sources: [
          FieldNoteSource("IS-GPS-200 and IS-GPS-705 (L1 C/A and L5 signals)", "https://www.gps.gov/technical/icwg/"),
          FieldNoteSource("Wireless Power Consortium, the Qi specification", "https://www.wirelesspowerconsortium.com"),
          FieldNoteSource("ISO/IEC 14443 (13.56 MHz proximity cards)"),
          FieldNoteSource("IEEE 802.15.4z-2020 (UWB channels and ranging)"),
        ]),
      FieldNoteSection(
        number: "07", title: "Privacy",
        paragraphs: [
          "Everything stays on this iPhone. Audio and camera frames are reduced to numbers as they arrive and never recorded. Bluetooth identifiers are the random ones iOS gives each app and are forgotten when you leave the card. Your position is never shown, stored or sent; the GNSS card shows only its quality.",
          "The round-trip time is a TCP handshake to Apple's connectivity-check host (captive.apple.com, port 80) once a second while the Cellular & Wi-Fi card is on screen. The connection closes as soon as it opens; no request is made and no data is sent.",
        ]),
      FieldNoteSection(
        number: "08", title: "Simulated sensors",
        paragraphs: [
          "In the Simulator, and wherever hardware is missing in a debug build, Spectra makes up realistic data at the real sample rate with real timestamps and badges it SIM: Earth's field through a swaying phone with 60 Hz hum sampled at 99.8 Hz, a room of Bluetooth radios with path loss, a dipole chassis and Rayleigh fading, an open fifth on G (196, 294 and 392 Hz) with a clap on the microphone, a 3100 K lamp flickering at 120 Hz. Release builds never simulate: missing hardware says so."
        ]),
    ])
}
