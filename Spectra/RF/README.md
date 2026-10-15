# RF

Owner: **rf-engine**. The pure RF engine of the Radio tab and the Patch RF nodes: antennas (closed
forms, 3D pattern model, arrays, mesh, pose), propagation (FSPL, log-distance, TR 38.901, two-ray,
Hata, knife edge, P.676 gas, P.838 rain, O2I and P.2109 building entry, fading), noise and capacity,
error rates and EVM, numerology and the systems catalog, the link budget, and the signal chain
(constellations, pulse shaping, FSK/GMSK, DSSS, OFDM, AM/FM/PM, channel simulator, Transmitter /
Receiver, BasebandLink) on vDSP.

Foundation, Accelerate and simd only; everything is under the `nonisolated enum RF` namespace.
Public API: `Docs/API-RF.md`. Oracles: `SpectraTests/RFTests.swift`, run on macOS by
`Tools/check-rf.sh`. Physics: `Docs/research/rf-physics.md` (with its review fixes) and the
"Verified reference" in `rf-physics-review.md`.
