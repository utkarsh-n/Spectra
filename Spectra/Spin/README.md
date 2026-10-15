# Spin

Owner: **spin-engine**. The pure spin engine: species and CODATA 2022 constants, the Bloch
solver (rotating and lab frame, exact per step), RF pulses and pulse programs, the isochromat
ensemble (dephasing, echo), FID signals and spectra, Earth-field helpers, the heavy top ported
from Gyre's `GyroSim` with the `GyroscopeEngine` wrapper (tip IQ at 960 Hz), charged particles
(Boris, collisions, g − 2), Larmor sonification, knob ranges and readout structs.

Foundation + Accelerate + simd only; every type is a `nonisolated` `Sendable` value. Public API:
`Docs/API-spin.md`. Oracles: `SpectraTests/SpinTests.swift`, run on macOS by `Tools/check-spin.sh`.
