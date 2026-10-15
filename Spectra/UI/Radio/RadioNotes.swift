import Foundation

/// Field notes for the Radio tab: what is modelled, what is live, and where it comes from.
enum RadioNotes {
  static let notes = FieldNotes(
    title: "Radio",
    intro: "An antenna and radio-system simulator. Every number here comes from the RF engine's formulas and tables (or the Phase engine for the Wigner views); only Follow phone, the microphone and the Live check use your iPhone's sensors.",
    sections: [
      FieldNoteSection(
        number: "01", title: "Antenna",
        paragraphs: [
          "The 3D lobe is the far-field pattern |E(θ, φ)| on a latitude–longitude mesh, colored by the carrier's band. Directivity is the pattern integral; the headline gain uses the reference's own formula or table where one exists (horn ε·4πAB/λ², dish η(πD/λ)², Yagi NBS TN 688, helix Kraus) and says so.",
          "Impedance, VSWR and mismatch loss to 50 Ω appear only where the reference gives an impedance. When only the resistance is known (short dipole, small loop, off-resonance dipole) VSWR and mismatch loss are lower bounds (≥). Patch, Yagi, horn, dish, array and PIFA are assumed matched (*).",
          "Follow phone turns the antenna with your phone's attitude. The antenna is mounted with its axis along the phone's long side. Beam lock re-steers a phased array ten times a second so its beam stays on a fixed direction in the room, the way a phone's mmWave module tracks a base station.",
        ],
        items: [
          FieldNoteItem(.model, "Patterns and directivity", "Closed forms and numerical integration over the sphere (Balanis)."),
          FieldNoteItem(.table, "Yagi gain", "NBS Technical Note 688 optimized designs, set by boom length."),
          FieldNoteItem(.inferred, "PIFA efficiency", "Phones reach 40–70 %; the model takes 55 % unless you set it."),
          FieldNoteItem(.live, "Follow phone", "Attitude from Core Motion (SIM in the Simulator)."),
        ],
        sources: [
          FieldNoteSource("C. A. Balanis, Antenna Theory: Analysis and Design, 4th ed. (2016)"),
          FieldNoteSource("P. P. Viezbicke, Yagi Antenna Design, NBS Technical Note 688 (1976)"),
          FieldNoteSource("J. D. Kraus, Antennas, 2nd ed. (1988), helical antennas"),
        ]),
      FieldNoteSection(
        number: "02", title: "Aperture phase space",
        paragraphs: [
          "The spatial Wigner distribution W(x, kₓ) of the source behind the pattern (the aperture field, the wire current, or the array's element excitations). Summed over x it gives the far-field power at kₓ = k·sinθ, which the panel checks against the RF engine's pattern factor. A distance knob shears it as the beam travels (Fresnel): W_z(x, kₓ) = W₀(x − z·kₓ/k, kₓ).",
          "Spacetime Wigner distribution: **Utkarsh's construction and convention (C)**. The aperture view is its spatial slice; the Fourier page's time–frequency view is its temporal slice.",
        ],
        items: [FieldNoteItem(.model, "Wigner and Fresnel shear", "Phase engine, exact discrete Wigner (marginals to round-off).")],
        sources: [
          FieldNoteSource("E. Wigner, On the quantum correction for thermodynamic equilibrium, Phys. Rev. 40, 749 (1932)"),
          FieldNoteSource("M. J. Bastiaans, Wigner distribution function and its application to first-order optics, JOSA 69 (1979)"),
        ]),
      FieldNoteSection(
        number: "03", title: "Systems",
        paragraphs: [
          "Cards for each generation and system: bands, channel widths, modulation and multiple access, the largest QAM, a peak rate and whether your iPhone 15 Pro Max has the radio. 6G is marked SPECULATIVE: IMT-2030 is not standardized. Raw peak rates are subcarriers × symbol rate × bits × layers from the published numerology, before coding and overhead.",
          "The FMCW radar presets (77 GHz automotive, 24 GHz ISM) sit under Navigation; their sweep lengths are scaled so one chirp fits a simulated frame.",
        ],
        items: [
          FieldNoteItem(.table, "Bands and numerology", "3GPP, IEEE 802.11, Bluetooth SIG, GPS ICDs, ITU (as collected in the RF reference)."),
          FieldNoteItem(.inferred, "Years", "General history, not physics."),
        ],
        sources: [
          FieldNoteSource("3GPP TS 38.101 / 38.211 (5G NR) and TS 36.211 (LTE)", "https://www.3gpp.org/specifications-technologies"),
          FieldNoteSource("IEEE 802.11-2020 and 802.11be"),
          FieldNoteSource("Bluetooth Core Specification 5.3"),
          FieldNoteSource("ITU-R M.2160 (IMT-2030 framework)"),
        ]),
      FieldNoteSection(
        number: "04", title: "Fourier",
        paragraphs: [
          "A real baseband simulation of the selected system at a scaled frame size: symbols are Gray-mapped, pulse-shaped (or put on OFDM subcarriers with a cyclic prefix), sent through AWGN, an exponential multipath profile and Rayleigh/Rician fading with a Clarke/Jakes Doppler spectrum, then received. Single-carrier receivers have no equalizer, so multipath shows as ISI; OFDM equalizes with pilots or a training symbol.",
          "Es/N0 is per data symbol, so the measured bit error rate lands on the AWGN theory curve when the channel is clean. The view is heterodyned: the carrier is removed and you see offsets from it.",
          "Voice: AM and FM carry the microphone directly. Digital systems carry it as 8-bit µ-law PCM at 8 kHz (64 kbit/s) on a 32 kBd QPSK link through the same channel. Push to talk: the received audio plays when you let go, so the speaker never feeds the microphone. Nothing is recorded or kept.",
        ],
        items: [
          FieldNoteItem(.model, "Waveforms, channel and receivers", "RF engine; frame sizes and OFDM FFT sizes are scaled, real spacing and rates label the axes."),
          FieldNoteItem(.live, "Voice", "The microphone (ANALOGY: sound) modulates the simulated carrier."),
        ],
        sources: [
          FieldNoteSource("J. G. Proakis and M. Salehi, Digital Communications, 5th ed. (2008)"),
          FieldNoteSource("T. S. Rappaport, Wireless Communications, 2nd ed. (2002)"),
          FieldNoteSource("ITU-T G.711 (µ-law companding)"),
        ]),
      FieldNoteSection(
        number: "05", title: "Link",
        paragraphs: [
          "Pᵣ = Pₜ + Gₜ + Gᵣ − path loss − walls − rain − gas − polarization. Path loss is free space (Friis), log-distance, or a 3GPP TR 38.901 median model; walls use the TR 38.901 material losses; rain is ITU-R P.838 and gas ITU-R P.676. The noise floor is k(T + Tₑ)B, −174 dBm/Hz + 10·log B + NF at 290 K, and capacity is Shannon's B·log₂(1 + SNR).",
          "The Live check takes a nearby Bluetooth device's RSSI (the 2-second mean), and solves the log-distance model for distance. RSSI depends on the other device's transmit power, both antennas' patterns, your hand and the walls, so the distance is an estimate.",
        ],
        items: [
          FieldNoteItem(.model, "Budget", "RF engine (Friis, TR 38.901, P.676, P.838, Shannon)."),
          FieldNoteItem(.live, "RSSI", "Core Bluetooth advertisements (SIM in the Simulator)."),
          FieldNoteItem(.inferred, "Distance", "Solved from RSSI with the exponent knob."),
        ],
        sources: [
          FieldNoteSource("H. T. Friis, A note on a simple transmission formula, Proc. IRE 34 (1946)"),
          FieldNoteSource("3GPP TR 38.901, Study on channel model for frequencies from 0.5 to 100 GHz"),
          FieldNoteSource("ITU-R P.838-3 (rain) and P.676-13 (gases)", "https://www.itu.int/rec/R-REC-P/en"),
          FieldNoteSource("C. E. Shannon, A mathematical theory of communication (1948)"),
        ]),
      FieldNoteSection(
        number: "06", title: "Streams",
        paragraphs: [
          "Radio publishes radio.i and radio.q (the received baseband played κ-slowed at 2.4 kHz so a scope can follow the symbols) and radio.audio (the demodulated AM/FM tone or your voice, real time at 48 kHz). Open them in the Scope or add them to a Patch."
        ],
        items: [FieldNoteItem(.model, "radio.i, radio.q, radio.audio", "Simulated streams.")]),
    ])
}
