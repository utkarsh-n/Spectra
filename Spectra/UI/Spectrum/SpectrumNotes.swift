import Foundation

/// Field notes for the Spectrum tab: spectra-lab's notes (`ui/notes.js`) ported, plus the
/// native additions (long-wave ruler, Earth-field NMR, Phase space).
enum SpectrumNotes {
  static let notes = FieldNotes(
    title: "Spectrum",
    intro:
      "One instrument for every electromagnetic wave, from gamma rays to the longest radio waves. Five instruments share three sources (A, B, C), one medium and one display speed κ. Readouts are real SI values; time, zoom and amplitude on the drawings are display choices, and each panel says which.",
    sections: [
      FieldNoteSection(
        number: "01", title: "Wave scope",
        paragraphs: [
          "The blue trace is the electric field E and the red trace is the magnetic field B. They rise and fall together, always at right angles to each other and to the direction of travel; the amber arrow is the energy flow **S = E × B / µ₀**. With δ ≠ 0 the E vector turns as the wave advances and the trace becomes a helix. When several sources are on, each is drawn faintly in its own color under their sum.",
          "With a medium selected, the far half of the scope is filled with it. The wave slows to c/n there and its wavelength shrinks by the same factor, while the frequency stays the same. If the medium absorbs at this wavelength (water at microwave frequencies, for example), the wave also fades as it goes. The amplitude that enters is the Fresnel transmission 2/(1 + n); the reflected wave is not drawn.",
          "Drag to rotate, pinch to zoom, double-tap or Align to return to the home view.",
        ],
        items: [
          FieldNoteItem(.model, "Fields", "Jones fields of each source summed in display units (spectra-lab `fieldview`), ported and parity-tested."),
          FieldNoteItem(.model, "Index n", "Sellmeier/Cauchy/Debye fits for glass, silica, diamond and water; outside their range the scope draws vacuum."),
        ]),
      FieldNoteSection(
        number: "02", title: "Spectrum tuner",
        paragraphs: [
          "The ruler is logarithmic. A cursor's height gives the wavelength, and frequency and photon energy are read off the same line, since c = fλ and E = hf. Band edges are conventions; the gamma/X-ray split at 10 pm follows the poster, though physically the two are named by where they come from (the nucleus or the electrons). The dashed line at 10 eV (124 nm) is the conventional start of ionizing radiation; the violet line at 1.022 MeV is where a photon can become an electron–positron pair.",
          "The native ruler reaches 100,000 km (3 Hz), past the web prototype's 1 km. That makes room for the signals the phone itself meets: Earth-field NMR of water protons (2.13 kHz in 50 µT, 140.8 km), mains hum (60 Hz ≈ 4,997 km, 50 Hz ≈ 5,996 km) and the Schumann resonance (7.83 Hz ≈ 38,000 km). Those landmarks are detents too. Pinch to zoom the decades; the window follows the active cursor.",
          "A thermal source draws its Planck curve (power per log-wavelength bin) and dragging it sets the temperature whose Wien peak sits under your finger. A pulse shows its bandwidth Δf/f = 2 ln 2/(π N) as an amber band. Every other active frequency in the app (Radio carrier, live radios, Larmor line, mains hum) appears as a dim marker.",
        ],
        items: [
          FieldNoteItem(.table, "Band edges", "Gamma | X-ray at 10 pm, X-ray | UV at 10 nm, visible 400–700 nm, IR | microwave at 1 mm, microwave | radio at 1 m; ITU LF, VLF, ULF, SLF and ELF beyond 1 km."),
          FieldNoteItem(.model, "Planck curve", "B_λ(T)·λ from Planck's law with CODATA constants; Wien b = 2.897771955 mm·K."),
        ]),
      FieldNoteSection(
        number: "03", title: "Matter bench",
        paragraphs: [
          "Every specimen gets the same beam. **TABLE** means the number is interpolated from measured data. **MODEL** means it comes from oscillator or free-electron physics, or from a smooth curve through published anchor values, so trust its shape more than its third digit. In series, the beam passes through each specimen in turn (Beer–Lambert); side by side, each sees the full beam.",
        ],
        items: [
          FieldNoteItem(.model, "Charge on a spring", "The Lorentz oscillator (Q = 8). Below its resonance it moves in step with the field, which slows light and gives the refractive index. On resonance it lags a quarter cycle and absorbs. Far above, it barely moves. Move λ₀ with its slider."),
          FieldNoteItem(.model, "FM dipole", "A 1.5 m half-wave dipole tuned to 100 MHz; odd harmonics resonate too."),
          FieldNoteItem(.table, "Water", "Segelstein's measured absorption from 10 nm to 10 m, and NIST attenuation for X-rays. Heating is α·I divided by water's heat capacity, at the surface."),
          FieldNoteItem(.model, "Glass", "NIST Pyrex for X-rays. Optical absorption follows typical 3 mm borosilicate curves, with reflection from the BK7 Sellmeier equation."),
          FieldNoteItem(.model, "Zinc", "A free-electron (Drude) metal whose plasma frequency comes from its electron density and whose damping comes from its DC conductivity. The photoelectric threshold is the 4.33 eV work function; X-rays use NIST data."),
          FieldNoteItem(.model, "DNA", "Two absorption bands fitted so that 50 µg/mL gives A260 = 1.0, A260/A280 ≈ 1.9 and A260/A230 ≈ 2.2, the standard lab values."),
          FieldNoteItem(.table, "Finger", "NIST soft tissue and cortical bone (ICRU-44) for X-rays and gamma rays. Elsewhere, tissue optics after Jacques (2013) and muscle permittivity after Gabriel (1996), both modeled."),
        ],
        sources: [
          FieldNoteSource("NIST X-Ray Mass Attenuation Coefficients (Hubbell & Seltzer)", "https://physics.nist.gov/PhysRefData/XrayMassCoef/"),
          FieldNoteSource("Segelstein (1981), water 10 nm–10 m, via OMLC", "https://omlc.org/spectra/water/"),
        ]),
      FieldNoteSection(
        number: "04", title: "Decompose",
        paragraphs: [
          "**Polarization**: any field can be split into Ex and Ey. The angle θ sets how the amplitude divides between them and δ sets how far Ey lags. The tip of E traces a line (δ = 0), a circle (θ = 45°, δ = ±90°) or an ellipse; this is the same Lissajous math as Orbitals. An ideal polarizer passes cos²ψ·cos²α + sin²ψ·sin²α + ½·sin 2ψ·sin 2α·cos δ of the intensity. Circular light has no major axis, so its orientation reads “—”.",
          "**Probe charge**: the exact motion of a free electron that starts at rest in the wave. The strength parameter a₀ = eE₀/(mωc) sets the size of the effect. E shakes the electron sideways; v×B then pushes it forward at twice the frequency, so it traces a figure eight while drifting at a₀²/(4 + a₀²) of c. Drop B and it only shakes. Drop E and nothing happens, because B can't push a charge that isn't moving.",
          "**Fourier**: the sum of every source's frequency components. A pulse needs a spread of frequencies; a thermal source is many components with random phases, weighted by Planck's law. With a medium set, the prism inset bends each color by its own index (minimum deviation through a 60° prism; the spread is drawn eight times larger).",
        ],
        items: [
          FieldNoteItem(.model, "Trajectory", "Light-front solution of the Lorentz force in a plane wave (u⊥ = A(η) − A(0), γ − u_z = 1), integrated with the midpoint rule over three cycles."),
        ]),
      FieldNoteSection(
        number: "05", title: "Phase space",
        paragraphs: [
          "**Spacetime Wigner distribution: Utkarsh's construction and convention (C).** For a field ψ(x, t) with ψ̃(k, ν) = ∫ ψ exp[−i(k·x − 2πνt)] dx dt, the distribution is Φ(ν, k; x, t) = ∫∫ ψ*(x − ξ/2, t − τ/2) ψ(x + ξ/2, t + τ/2) exp[−i(k·ξ − 2πντ)] dξ dτ. k is angular (rad per length, measure dk/2π) and ν is ordinary frequency (Hz, measure dν), so a plane wave exp[i(k₀x − 2πν₀t)] lands at (+k₀, +ν₀).",
          "Its marginals give back what you put in: integrating over ν and k gives |ψ(x, t)|² (**M1**), integrating over x and t gives |ψ̃(k, ν)|² (**M2**), and the total is the energy (**P**). The strip under the cube recomputes all three numerically and shows the largest error and a badge: CONSISTENT when every identity holds, ALIASED when part of the field reaches the edge of the window or band.",
          "The left panel is the spacetime view |ψ(x, t)|²; the right is the momentum–frequency view |ψ̃(k, ν)|² with the medium's dispersion curve: the light line in vacuum, a Sellmeier-curved line in glass, the hyperbola ω² = ω_p² + c²k² in a plasma (the ionosphere), the cut-off branch in a waveguide. A free packet lives on that curve. The cube is Φ integrated over k (the temporal Wigner at every x) or one k column; fixing t gives the spatial Wigner W(x, k), fixing x the temporal Wigner W(t, ν).",
          "Φ is real but not always positive. A single Gaussian packet stays positive everywhere (Hudson's theorem). Two packets add an interference term midway between them that oscillates and swings negative (cool blue): that is where Φ keeps the relative phase of the two. It is plainest in the fixed-t slice W(x, k) and in the cube when it shows one k column; integrating over k mostly cancels it. The min Φ / max Φ readout gives its depth, which depends on the spacing and the grid.",
          "Sources A, B and C become 1+1-D packets with their own carrier, pulse length and chirp; a plane wave is shown as a long 10-cycle packet (the longest that fits the window without aliasing), and thermal light is left out because it is incoherent. Axes are in units of the reference source: x in λ, t in periods, k in rad per λ, ν in multiples of its frequency, so the same picture serves any band. Φ is computed off the main thread on a 48 × 48 grid (40 × 40 in Debug builds).",
        ],
        items: [
          FieldNoteItem(.model, "Packets", "Chirped Gaussian packets propagated exactly on the dispersion shell; Hann observation window in time."),
          FieldNoteItem(.model, "Φ", "Discrete Wigner with half-lags inside half the padded grid and the positive-frequency band (no double-counted lags, no checkerboard). M1 holds to round-off; M2 holds once the alias partners are counted."),
        ],
        sources: [
          FieldNoteSource("Utkarsh, Spacetime Wigner Distribution (poster and derivation, 2026)"),
          FieldNoteSource("R. L. Hudson, When is the Wigner quasi-probability density non-negative? (1974)"),
        ]),
      FieldNoteSection(
        number: "06", title: "Spectroscopy lab",
        paragraphs: [
          "Sweeping moves the cursor across the sample's range and tunes the active source to match. Hydrogen line positions come exactly from the Rydberg formula with the reduced-mass correction (within 0.01 nm of NIST); the spectroscope strip under the plot shows the lines as a prism would, with the visible window outlined. CO₂ band centers are literature values; their rotational envelopes are modeled. The liquid-water infrared spectrum is measured (Segelstein). Chlorophyll peak positions follow Lichtenthaler (1987) in ether, with modeled shapes. The NMR spectrum uses the CODATA proton gyromagnetic ratio, textbook ethanol shifts and J = 7.1 Hz.",
          "**Earth field (live |B|)** replaces the spectrometer magnet with the planet. B₀ is the magnitude your magnetometer measures, and water protons precess at γ′ₚ·|B| (shielded γ′ₚ/2π = 42.576 MHz/T): about 2.1 kHz in 50 µT, a wavelength of about 140 km. At that field the chemical shifts are millihertz and the ethanol multiplets collapse into one line. The line wanders as the reading jitters; the Spin tab lets you hear it at its true pitch.",
        ],
        items: [
          FieldNoteItem(.table, "Water IR", "Segelstein (1981), a 1 µm film."),
          FieldNoteItem(.model, "Lines", "Rydberg, CO₂, chlorophyll and ethanol line positions from physics and the literature; shapes modeled."),
          FieldNoteItem(.live, "|B|", "The magnetometer's calibrated magnitude (SIM in the Simulator)."),
        ],
        sources: [
          FieldNoteSource("NIST Atomic Spectra Database (hydrogen)", "https://physics.nist.gov/asd"),
          FieldNoteSource("CODATA 2022 shielded proton gyromagnetic ratio", "https://physics.nist.gov/cgi-bin/cuu/Value?gammapp"),
        ]),
      FieldNoteSection(
        number: "07", title: "What's real and what's illustrative",
        paragraphs: [
          "Readouts are real SI values: wavelength, frequency, photon energy, B₀ = nE₀/c, intensity ½nε₀cE₀², photon flux, and how much passes or is absorbed. Three things are display choices: time runs slower by the factor on the transport (often 10¹⁴ or more), the camera zooms so about three wavelengths fill the scope, and field amplitudes are scaled to fit the screen.",
          "With Sound on (Settings), each source hums at a pitch mapped from its real frequency (15 decades onto four octaves) and band edges click; haptics mark band edges, give a firm stop at the ionizing line and a thump on resonances.",
        ]),
      FieldNoteSection(
        number: "08", title: "Dials",
        paragraphs: [
          "**λ** wavelength in vacuum, log scale from 0.1 pm to 100,000 km; its color follows the wave. **E₀** peak electric field: more field means more photons, not more energetic ones. **θ** the split between Ex and Ey (the tilt, for linear light), **δ** the lag of Ey behind Ex, **φ** the overall phase. **T** the temperature of a thermal source and **N** the length of a pulse in cycles. **Link** applies the same relative change to every source, so a chord keeps its shape. **κ** sets how many reference cycles the display shows per second.",
        ],
        sources: [
          FieldNoteSource("CODATA 2018 and SI 2019 constants (NIST)", "https://physics.nist.gov/cuu/Constants/"),
          FieldNoteSource("Schott N-BK7; Malitson (1965) fused silica; Kaatze (1989) water"),
          FieldNoteSource("OpenStax University Physics 2, ch. 16", "https://openstax.org/books/university-physics-volume-2/pages/16-introduction"),
        ]),
    ])
}
