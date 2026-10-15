# Phase

Owner: **phase-engine**. The pure phase-space engine: Wigner distributions in time–frequency,
space–wavenumber and 1+1-D spacetime, built on **Utkarsh's convention (C)** and his spacetime
Wigner distribution Φ(ν,k;x,t) (`Docs/research/wigner-spacetime.md`). Analytic signal and 2×
oversampling, exact/pseudo/smoothed Wigner, spectrogram, exact discrete marginals, aperture far
field and Fresnel shear, Gaussian packets on dispersion shells (vacuum, Core media, plasma,
waveguide), closed-form oracles and the one-call Phase space scene.

Foundation + Accelerate + simd only (uses Core's `Matter.Medium` and `SI`); every type is a
`nonisolated` `Sendable` value (the DFT wrapper is an immutable `@unchecked Sendable` class).
Public API: `Docs/API-phase.md`. Oracles: `SpectraTests/PhaseTests.swift`, run on macOS by
`Tools/check-phase.sh`.
