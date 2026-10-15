# Spectra (native) — build spec, part 3: stages, ownership, rules, tests

## 1. Golden rules for every builder
1. **Never run `xcodebuild` or `xcodegen` inside the iCloud project folder** (it hangs; resource-fork detritus breaks codesign). Build only with `Tools/build.sh` (whole project) or `Tools/agentbuild.sh` (your slice over the baseline). DerivedData always under `$TMPDIR`.
2. **Write only inside the paths you own** (table in §3). Shared files belong to the foundation/integration owner. If you need a change in someone else's file, write it in `Docs/notes/<your-name>-requests.md` and work around it with an extension in your own folder.
3. **Keep public APIs stable.** Additive changes only to types other stages consume. Document your module's public API in `Docs/API-<module>.md` (types, key functions, how to use, threading).
4. **Physics from the verified references** (`Docs/research/*-review.md` "Verified reference", `rf-physics.md` with `[corrected in review]` marks, `gyre-integration.md`). Every formula you implement gets an XCTest with the worked value from those documents.
5. **No dead UI.** Every visible control works, or is visibly disabled with a one-line reason (LOCKED / NEEDS PEER). No TODO text, no lorem, no placeholder numbers.
6. **SF Symbols**: check each name in `/System/Library/CoreServices/CoreGlyphs.bundle/Contents/Resources/name_availability.plist` before use (Gyre gotcha: `magnet` does not exist).
7. **iOS 27 API gotchas**: `AVAudioEngine.connectNode(_:to:format:)` (throws) replaces `connect`; `installAudioTap(onBus:bufferSize:format:tapProvider:) throws` replaces `installTap`; `.pickerStyle(.tabs)` is iOS 27; Liquid Glass APIs are the iOS 26 set (`glassEffect`, `GlassEffectContainer`, `glassEffectID`, `.glass`, `.glassProminent`). Verify anything else against `/Applications/Xcode-beta.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS27.0.sdk`.
8. **Concurrency**: app target defaults to MainActor isolation (Swift 6, approachable concurrency). Pure engines must also compile in the macOS harness with default nonisolated isolation: pure `Sendable` value types, `nonisolated` where needed, no global mutable state.
9. **Simulator fakes** behind `#if DEBUG`, launch arguments per `gyre-integration.md` §8 (`-fakeAll` must make every tab fully alive in the Simulator).
10. **Copy reuse is encouraged**: Orbitals and Gyre files listed as "directly reusable" in `design-orbitals.md` / `design-gyre.md` may be copied into your owned folders and renamed/adapted (never edit the originals).

## 2. Stages
| Stage | Who (parallel) | Output gate |
|---|---|---|
| 1 | **foundation**, **core-port**, **rf-engine**, **spin-engine** | foundation builds for the Simulator; each engine passes its own macOS harness (`Tools/check-<module>.sh`) |
| 1.5 | orchestrator | full build + tests green; snapshot baseline `$TMPDIR/SpectraBaseline` |
| 1b | **phase-engine** (+ adversarial verifier), first thing on stage-2 day | `Tools/check-phase.sh` passes: M1/M2/P pointwise, reality, Hudson positivity, chirp concentration, two-tone cross term, plane-wave sign check (lands at +k₀,+ν₀), Moyal identity |
| 2 | **spectrum-ui** (incl. Decompose → Phase space, `Render/Scenes/Wigner*.swift`), **radio-ui**, **live**, **scope**, **spin-ui**, **patch** | each slice builds via `agentbuild.sh` over the baseline; its tests pass |
| 3 | **integration** | whole app builds; all unit tests and UI smoke tests (`-fakeAll`) pass; screenshots of every tab/instrument in `Docs/screenshots/` |
| 4 | reviewers (physics, design conformance, concurrency/sensors, UX completeness) → fixers | verified findings fixed, re-tested |
| 5 | orchestrator | Release build installed on the iPhone; sensor census run; VERIFICATION.md |

## 3. Ownership
| Owner | Paths |
|---|---|
| foundation | `project.yml`, `Spectra/App/`, `Spectra/UI/Theme/`, `Spectra/UI/Components/`, `Spectra/UI/Plots/`, `Spectra/Feedback/`, `Spectra/Render/` (except `Render/Scenes/<Tab>*.swift` of later owners), `Spectra/AR/`, `Spectra/Resources/`, `Spectra/Info.plist` (generated), stubs in `Spectra/UI/{Spectrum,Radio,Live,Spin,Patch}/` and `Spectra/Live/` and `Spectra/Graph/Model/` (later replaced by their owners), `SpectraUITests/`, `SpectraTests/AppTests.swift`, `Tools/build.sh`, `Tools/agentbuild.sh`, `Tools/make-icon.swift`, `Docs/API.md` |
| core-port | `Spectra/Core/` (incl. `Core/Data/`, `Core/Display/`), `SpectraTests/CoreParityTests.swift`, `SpectraTests/ParityVectors.swift`, `SpectraTests/Fixtures/`, `Tools/gen-tables.mjs`, `Tools/check-core.sh`, `Tools/harness/core/` |
| rf-engine | `Spectra/RF/`, `SpectraTests/RFTests.swift`, `Tools/check-rf.sh`, `Tools/harness/rf/` |
| spin-engine | `Spectra/Spin/`, `SpectraTests/SpinTests.swift`, `Tools/check-spin.sh`, `Tools/harness/spin/` |
| spectrum-ui | `Spectra/UI/Spectrum/`, `Spectra/Render/Scenes/Wave*.swift` |
| radio-ui | `Spectra/UI/Radio/`, `Spectra/Render/Scenes/Antenna*.swift` |
| live | `Spectra/Live/` (replacing the foundation's simple sim internals, keeping its API), `Spectra/UI/Live/`, `SpectraTests/LiveTests.swift` |
| phase-engine | `Spectra/Phase/` (pure: analytic signal, discrete temporal/spatial Wigner, pseudo and smoothed variants, spectrogram, 1+1-D spacetime Φ(ν,k;x,t) on a grid, marginals, closed-form Gaussian packets propagated through dispersive media, dispersion relations), `SpectraTests/PhaseTests.swift`, `Tools/check-phase.sh`, `Tools/harness/phase/` |
| scope | `Spectra/UI/Scope/` (ScopeView, ScopeEngine: trigger, decimation, measurements, math, persistence), `Spectra/Render/Scenes/Scope*.swift` and its Metal shader file `Spectra/Render/Scope.metal`, `SpectraTests/ScopeTests.swift` |
| spin-ui | `Spectra/UI/Spin/`, `Spectra/Render/Scenes/Spin*.swift` |
| patch | `Spectra/Graph/` (Engine + Model), `Spectra/UI/Patch/`, `SpectraTests/GraphTests.swift` |
| integration | anything, to make it build and cohere; record every cross-owner change in `Docs/notes/integration.md` |

## 4. Build and test tooling (foundation writes 1–3; engines write their harness)
1. `Tools/build.sh sim|device|test|uitest [extra xcodebuild args]` — rsync the project (excluding `Docs/research/rf-physics-calc`, `*.xcodeproj/xcuserdata`, `build`) to `${SPECTRA_BUILD_DIR:-$TMPDIR/SpectraBuild}/src`, `xcodegen generate`, then `xcodebuild` with `-derivedDataPath …/dd`: `sim` = Debug for `iPhone 17 Pro` simulator; `test` = unit tests on the simulator; `uitest` = UI tests; `device` = Release `generic/platform=iOS -allowProvisioningUpdates`. Exit non-zero on failure; print the last 80 lines of errors (`grep -E "error:|warning: .*Spectra/"`).
2. `Tools/agentbuild.sh <name> <ownedPath>... [-- test]` — copy `${SPECTRA_BASELINE:-$TMPDIR/SpectraBaseline}` to `$TMPDIR/SpectraAgent-<name>/src`, overlay each owned path from the live project, generate, build for the simulator (and run unit tests with `-- test`), separate derived data per agent so parallel agents do not collide.
3. `Tools/make-icon.swift` — CoreGraphics at exactly 1024×1024 px (not NSImage lockFocus, which renders 2×): dark phosphor ground, a glowing E/B wave whose hue sweeps radio→gamma, a small precessing spin cone; no text.
4. Engine harnesses: `Tools/check-<module>.sh` compiles the module's Swift sources plus `Tools/harness/<module>/main.swift` with `xcrun swiftc -O` on macOS and runs oracle checks (exit 1 on failure). Same oracles also live in the XCTest files.

## 5. Tests
- `CoreParityTests`: every category of `vectors.json` with tolerances from `port-plan.md` §4 (≤1e-12 relative for arithmetic, documented looser for library calls), JS-exact formatting.
- `RFTests`: every worked value in the verified reference (antenna D/HPBW/Rr, Friis, FSPL, noise floor, Shannon, Carson, Bessel sidebands, BER formulas, OFDM numerology, system catalog sanity, FFT bin math, modulation round trips with zero noise).
- `SpinTests`: Larmor/Rabi/Bloch analytic cases (free precession phase, π/2 pulse, T₂ decay), heavy-top precession Ω_p = mgr/(Iω) within tolerance (port Gyre physcheck), Earth-field NMR frequency from |B|, g−2 beat.
- `ScopeTests`: trigger finds rising edges at the right level with holdoff, frequency measurement on a synthetic sine (zero crossing and FFT) within 0.5 %, Pk-Pk/RMS of known waveforms, decimation keeps peaks (min/max), roll mode ordering, XY pairing by timestamp.
- `GraphTests`: topo sort, cycle rejection, provenance union, AM/FM voice round trip SNR, block timing.
- `LiveTests`: fakes produce timestamped rings at the declared rate; magnetometer hum60 fake shows a 39.8 Hz alias in the FFT.
- `SpectraUITests/SmokeTests`: launch with `-fakeAll`, visit every tab and instrument, open each sheet, screenshot attachments; controls found by accessibility identifier.

## 6. Definition of done (per stage-2 slice)
Builds via `agentbuild.sh` with zero errors; no new warnings in owned files; owned tests pass; every screen reachable and alive with `-fakeAll` in the simulator; `Docs/API-<module>.md` written; a short `Docs/notes/<name>.md` listing what was built, what is MODEL vs LIVE, and anything unfinished.
