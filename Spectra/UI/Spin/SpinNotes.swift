import SwiftUI

/// Field notes for the Spin tab: what is measured, what is modelled, how to read it, sources.
@MainActor
enum SpinNotes {
  static let notes = FieldNotes(
    title: "Spin",
    intro:
      "A spinning gyroscope, a proton and an electron obey one equation: a torque turns the spin axis, dL/dt = μ × B (plus ℓê × mg for a top). Your phone measures the field and its own motion. The spins are simulated.",
    sections: [
      FieldNoteSection(
        number: "01", title: "The gyroscope",
        paragraphs: [
          "Gyre's heavy symmetric top on a ball pivot, integrated with RK4 and substeps that resolve the fastest motion. The pivot is fixed to your phone: turn the phone and the rotor keeps its direction in space; jolt it and the rotor feels the jolt.",
          "Gravity plays the part B plays for a spin. A fast top precesses at Ωₚ ≈ mgℓ/L₃. It also nods quickly at about L₃/I₁: the **inertial nod**, which a spin does not have, because a spin has no transverse inertia. The NMR word \"nutation\" means something else: the driven Rabi rotation about B₁.",
          "Seen from above, the axle tip is an I/Q signal. Steady precession is one line near 0 Hz. The nod is nearly circular, so it adds essentially one sideband on the spin's side, not the symmetric pair of FM.",
        ],
        items: [
          FieldNoteItem(.model, "Rotor", "60 g, 3 cm radius brass disc, Gyre's knobs. Its colors are the analogy colors: it is mechanical, not electromagnetic."),
          FieldNoteItem(.live, "Motion", "Device motion (rotation rate, acceleration, attitude) drives the pivot. In the Simulator the motion is a simulated sway, badged SIM."),
          FieldNoteItem(.model, "Magnet", "A signed rotor moment: plus is proton-like, minus electron-like. Real NdFeB (0.138) is what a solid magnet rotor of the same mass would carry: one turn about Earth's field takes about a minute."),
          FieldNoteItem(.analogy, "Nod on the strip", "The inertial nod frequency is a mechanical frequency, drawn where an electromagnetic wave of that frequency would sit."),
        ],
        sources: [
          FieldNoteSource("H. Goldstein, C. Poole, J. Safko, Classical Mechanics, 3rd ed., ch. 5 (the heavy symmetrical top)")
        ]),
      FieldNoteSection(
        number: "02", title: "Protons in your field",
        paragraphs: [
          "Protons in water precess about B at f = γ′ₚ/2π · |B|, 42.58 Hz per microtesla. In Earth's 50 µT that is 2128.8 Hz, inside the range of hearing: **Hear it** plays that true pitch under the simulated ring-down. Above about 470 µT the line passes 20 kHz and the sound switches to a mapped pitch, badged MAPPED.",
          "The bench is a 10 cm sample of isochromats in the rotating frame (Bloch equations, solved exactly each step). A gradient fans the packets out, so the FID dephases; its envelope is a sinc, so the readout says dephasing time rather than T₂*. A spin echo (π/2, τ, π) brings them back at 2τ, smaller by the factor exp(−2τ/T₂).",
          "Why the phone cannot do this for real: at 50 µT and room temperature the proton polarization is about 1.7 × 10⁻¹⁰. Earth-field NMR rigs prepolarize in about 20 mT and read microvolts from a coil with hundreds of turns; the phone has no coil, and its magnetometer samples near 100 Hz.",
        ],
        items: [
          FieldNoteItem(.live, "|B|", "The magnetometer's field magnitude, smoothed with τ = 0.25 s so sensor noise does not warble the pitch. A 1 µT error moves the proton line by 42.6 Hz, so the sensor's calibration accuracy is shown beside the line when it reports one."),
          FieldNoteItem(.model, "FID, spectrum, sound", "Simulated. The audio is never a measured FID."),
          FieldNoteItem(.inferred, "Magnetic latitude", "From your field's dip angle and the dipole relation tan I = 2 tan λₘ."),
          FieldNoteItem(.table, "γ′ₚ/2π", "42.576 385 43 MHz/T, shielded protons in water (CODATA 2022)."),
        ],
        sources: [
          FieldNoteSource("NIST CODATA 2022 fundamental constants", "https://physics.nist.gov/cuu/Constants/"),
          FieldNoteSource("F. Bloch, Nuclear induction, Phys. Rev. 70, 460 (1946)"),
          FieldNoteSource("E. L. Hahn, Spin echoes, Phys. Rev. 80, 580 (1950)"),
          FieldNoteSource("M. Packard and R. Varian, Free nuclear induction in the Earth's magnetic field, Phys. Rev. 93, 941 (1954)"),
        ]),
      FieldNoteSection(
        number: "03", title: "The electron",
        paragraphs: [
          "The free electron's |γ|/2π is 28.025 GHz/T, 658 times the proton's, so in Earth's field its spin turns at about 1.40 MHz. Between 18.9 and 60.7 µT that line sits inside the AM broadcast band (530–1700 kHz); the AM BAND chip appears only then.",
          "Its bench is the proton's picture played 658 times slower (times scaled by 1/658, frequencies by 658), so the transport says SLOWED and the frame is heterodyned. Nothing at 1.4 MHz is audible, so its Hear it stays disabled: heterodyned only.",
          "**g − 2.** The electron's orbit (cyclotron, eB/2πmₑ) and its spin precession differ by the factor 1 + aₑ = 1.00116. In 50 µT that is 1.39962 MHz against 1.40125 MHz, a 1623 Hz beat: the principle of the g − 2 experiments.",
        ],
        items: [
          FieldNoteItem(.table, "|γₑ|/2π", "28 024.951 386 MHz/T; aₑ = 1.159 652 180 46 × 10⁻³ (CODATA 2022)."),
          FieldNoteItem(.model, "Bench", "The same Bloch solver as the proton, with the electron's γ and sense of rotation (counterclockwise about B)."),
        ]),
      FieldNoteSection(
        number: "04", title: "Reading the picture",
        paragraphs: [
          "**Rotating frame.** NMR is watched from a frame turning with the RF carrier: you see only the difference Δf = f_L − f_rf. The transport and the HETERODYNED chip say so. Switch it off to see the lab frame: the arrow then turns at the full Larmor rate, far faster than the screen can show, so it strobes (ALIASED) and is drawn as a smeared cone.",
          "**Colors.** Spins radiate at their Larmor frequency, so M takes that line's band color. B is red, B₁ red and thinner, B_eff violet; the frame's x′ tick is ice and y′ gray. The rotor, its trail and its L are amber and phosphor: mechanical analogy colors; the torque τ keeps Gyre's rose and gravity g is gray.",
          "**FID trace.** It works like a triggered scope: each pulse starts a one-second sweep from the left, and the last one holds until the next. A sequence is recorded from its read pulse, as a spectrometer acquires: an inversion recovery from its π/2 at Tᵢ, and a spin echo whose echo (2τ) would come after 0.8 s from its π, or, once τ passes half a second, from half a second before the echo, so the whole echo sits in the record. A TR shorter than the sequence is stretched to fit it. With CW drive the trace rolls instead.",
          "**Sign of the baseband line.** The FID is recorded as I + jQ = Mₓ + iM_y. Protons turn clockwise about B, so a line above the carrier appears at negative baseband frequency; electrons turn the other way.",
        ]),
      FieldNoteSection(
        number: "05", title: "Wigner view of the FID",
        paragraphs: [
          "The FID record's time–frequency picture is the temporal Wigner distribution, from Spectra's phase-space engine. **Spacetime Wigner distribution: Utkarsh's construction and convention (C).** Positive values are warm and negative values cool; the strips show the time marginal |z(t)|² and the frequency marginal.",
          "With the Sweep knob a coil ramps B₀ through one record after each pulse, so the precession frequency changes linearly and the FID becomes a chirp: its Wigner is a straight sloped line. A gradient alone gives a band of frequencies that dephase and, after a π pulse, rephase.",
          "Wigner–Ville is exact but shows cross terms between components; the pseudo and smoothed pseudo-Wigner suppress them at the cost of resolution; the spectrogram is always positive and blurred.",
        ],
        items: [
          FieldNoteItem(.model, "Record", "One bench second (400 samples per proton second) from the latest pulse or read pulse."),
        ]),
      FieldNoteSection(
        number: "06", title: "Streams and links",
        paragraphs: [
          "Spin publishes spin.fid and spin.fid.q (the FID's I and Q) and gyro.tip.i and gyro.tip.q (the axle tip at 960 samples per simulated second) to the scope bus. Open in Scope and Add to Patch keep them running while the tab is hidden; switch off Publish while hidden to stop.",
          "Show on spectrum tunes the Spectrum tab's source A to the Larmor line's wavelength (140.8 km for protons in 50 µT). Open in Lab shows Earth-field NMR in the Spectroscopy lab.",
        ]),
    ])
}
