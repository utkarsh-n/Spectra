# API: Spin engine (`Spectra/Spin/`)

Owner: spin-engine. Consumers: spin-ui (`UI/Spin`, `Render/Scenes/Spin*`), patch (Spin FID and Gyroscope tip nodes), live (|B| and dip readouts), spectrum-ui (Earth-field NMR mode), scope ("spin.fid", "spin.tip" streams).

## Ground rules

- **Pure and portable.** Foundation, Accelerate and simd only. Every type is a `nonisolated` `Sendable` value type or a namespace enum, so it can be called from the main actor, the audio thread or a background task. There is no global mutable state and nothing to inject.
- **Ownership.** One `@MainActor` model owns each engine value (for example `SpinModel.gyro`) and steps it from the render loop. The audio thread owns its own *copy* of `SpinFIDSource` or `FIDOscillator` inside a `VoiceState: @unchecked Sendable` box, touched only on the render thread. Controls cross over through the synth's atomics (`gyre-integration.md` §4.9).
- **Units.** SI throughout: tesla, hertz, seconds, metres, kelvin, pascal. The one exception is `HeavyTopParams`, which keeps Gyre's knob units (rpm, g, ×).
- **Signs.** μ = γS and dM/dt = γ M × B, so M precesses with angular velocity −γB. Protons (γ > 0) turn clockwise about B, seen from its tip. Electrons, neutrons and ³He (γ < 0) turn counterclockwise. `PrecessionSense.sign` is −1 for clockwise.
- **Rotating frame.** The frame turns at the carrier in the species' own sense, so B_eff = (B₁ cos φ, B₁ sin φ, 2πΔf/|γ|) with Δf = f_L − f_rf for either sign of γ. The lab-frame drive this stands for is B₁(cos(ω t − φ), −sin(ω t − φ), 0) for γ > 0, the review's corrected sense.
- **Provenance.**
  - Everything here is **MODEL**.
  - Driven by the live magnetometer it becomes "MODEL · LIVE |B|"; driven by device motion, "MODEL · LIVE motion".
  - The rotor is mechanical and carries **ANALOGY** colours (rule R2).
  - Fixed caption: "Your phone measures the field. The spins are simulated."
- **Time.** `HeavyTop`, `GyroscopeEngine`, `BlochSimulator`, `SpinEnsemble` and `ChargeCloud` advance in *simulated* seconds. The gyroscope's step takes wall seconds and scales them by `params.timeScale`.
- **Naming.** Label the heavy top's nod "inertial nod" and NMR's driven rotation "Rabi nutation". They are different things.
- **Bad inputs.** Nothing here traps or latches NaN on non-finite input (a NaN sensor sample or a modulation source):
  - the Bloch solvers hold M through a non-finite field or step;
  - `HeavyTop`/`GyroscopeEngine` sanitize knobs and sensors (`HeavyTopParams.sanitized`, `HeavyTopEnvironment.sanitized`; Inertia is kept in 0.01…100×, Time at most 10×) and discard a step that would diverge;
  - `ChargeCloud` skips a frame with a non-finite field and spawns at rest for a non-finite temperature;
  - `FieldSmoother`, `SpinFIDSource` and `FIDOscillator` ignore non-finite controls;
  - `acquire` and `SpinAnalysis` bound open-ended durations and bands.
  The oracle group "Robustness at the edges" checks each of these.

## Species and constants

| Type | What |
|---|---|
| `SpinConstants` | CODATA 2022 (`c`, `h`, `hbar`, `e`, `kB`, `mu0`, `electronMass`, `protonMass`, `electronAnomaly`, `protonMomentNuclearMagnetons`, signed `gamma…HzPerT`). It is separate from `Core/SI`, which keeps the 2018 values for spectra-lab parity. |
| `SpinSpecies` | `.protonWater` (shielded γ′ₚ, the default), `.proton`, `.electron`, `.neutron`, `.helion`. |
| `PrecessionSense` | `.clockwise` / `.counterclockwise`, with `sign` (−1 / +1). |

`SpinSpecies` members:
- `gammaHzPerT`, `gamma` (both signed), `symbol`, `title`, `precessionSense`.
- `larmorHz(field:)`, `larmorAngular(field:)`, `larmorWavelength(field:)` (strip marker; water at 50 µT gives 140.8 km), `field(forLarmorHz:)`.
- `rabiHz(b1:)`, `rabiAngular(b1:)`, `ninetyDuration(b1:)`, `oneEightyDuration(b1:)`.
- `thermalPolarization(field:temperature:)`, `curieMagnetization(field:temperature:)`.

Worked values: water at 50 µT is 2128.8192715 Hz, the electron is 1.401247569305 MHz, and B₁ = 1 µT gives t_π/2 = 5.872 ms.

## Readouts (chips)

- `SpinFieldReadout(field:)`:
  - lines: `protonHz`, `electronHz`, `electronCyclotronHz`, `anomalyBeatHz` (1623.1 Hz at 50 µT);
  - `electronInAMBand` (append "AM band" only when true, i.e. 18.9–60.7 µT);
  - `protonWavelength`, `electronWavelength`;
  - `protonVoice`, `electronVoice` (`LarmorVoice`);
  - `protonJitterHz(fieldNoise:)` (42.58 Hz per µT).
- `SpinDriveReadout(species:b1:offsetHz:)`: `rabiHz`, `rabiAngular`, `ninetyDuration`, `oneEightyDuration`, `effectiveHz`, `effectiveTilt`, `maxInversionProbability`. The last is f₁²/(f₁² + Δf²); label it "max inversion", not "max transfer".

## Bloch equations

**`Bloch`** (namespace):
- `precess(_:gamma:field:duration:)`: exact Rodrigues rotation.
- `relax(_:duration:t1:t2:m0:)`: exact relaxation.
- `relaxationRate(_:)`: 1/T, with T = ∞ (or NaN) meaning no relaxation and T ≤ 0 meaning instant (`maxRelaxationRate`, 10¹² s⁻¹).
- `step(_:h:gamma:bEff:t1:t2:m0:)`: Strang split.
- `propagate(_:h:gamma:bEff:t1:t2:m0:)`: the **exact** solution for a field held constant over the step, M_ss + e^(Ah)(M − M_ss) (the affine e^(Gh) only when T₁ = ∞). Evolving the deviation from the steady state keeps stiff relaxation (T ≪ h, T = 0) on the textbook steady state with |M| ≤ M₀. This is what the simulators use.
- `exponential(_ simd_double4x4)`.
- `steadyState(gamma:bEff:t1:t2:m0:)`: CW steady state.
- `effectiveHz`, `effectiveFieldTilt`, `maxInversionProbability`, `minimumLongitudinal`.

**Supporting types:**
- `BlochRelaxation`:
  - fields `t1`, `t2`, `m0` (∞ = no relaxation, 0 = instant);
  - `.none` (lossless);
  - `effectiveT2` (clamped to ≤ 2T₁).
- `RFPulse`:
  - `flipAngle`, `phase`;
  - `.ninety`, `.oneEighty`, `.refocusing` (π about y), `init(degrees:phaseDegrees:)`;
  - `duration(species:b1:)` (|θ|/(|γ|B₁));
  - `normalized`: the same rotation with θ ≥ 0 (−θ about φ is +θ about φ + π); finite pulses play this form, so a negative flip angle turns the other way instead of being dropped;
  - `rotate(_:gamma:)`, a hard pulse that takes +z to +y for γ > 0.
- `BlochDrive`: `b1`, `phase`, `offsetHz` (Δf), `carrierHz` (nil locks the carrier to the line so a drifting live |B| stays on resonance), `continuous` (CW).

**`BlochSimulator`** (one isochromat, rotating frame):
- Created with `init(species:b0:drive:relaxation:)`. All of `species`, `b0`, `drive` and `relaxation` can be set between steps.
- `step(dt)` is exact at any dt.
- `startPulse(_:)` plays a finite pulse at `drive.b1`; it ends exactly on time and tips by less off resonance. `applyHardPulse(_:)` is instant.
- Other members: `reset()`, `setMagnetization(_:)`.
- Readouts:
  - `magnetization` (rotating frame), `labMagnetization`, `labField`;
  - `transverse` (heterodyned M⊥), `labTransverse`, `transverseMagnitude`;
  - `larmorHz`, `carrierHz`, `detuningHz`, `rabiHz`, `effectiveHz`, `effectiveField`, `frameAngle`;
  - `isRFOn`, `isPulsing`, `steadyState`.

**`LabFrameBloch`**:
- Direct lab-frame integration, with `step(_:field:)` and `run(duration:steps:field:)`.
- `circularField(b0:b1:frequencyHz:phase:sense:at:)` builds a circularly polarized drive.
- Use it for sense checks and for drives the rotating frame cannot express, such as a linear coil (Bloch–Siegert).

**`SpinEnsemble`** (the sample: `count` isochromats, rotating frame):
- Created with `init(species:count:spread:relaxation:)`, where `Spread` is `.none`, `.gradient(teslaPerMetre:length:)` or `.lorentzian(t2Star:)`.
- `drive: BlochDrive` sets B₁, phase, CW and `offsetHz`. `offsetHz` is also exposed directly.
- `advance(dt)` is real time: scheduled hard pulses fire exactly on time and finite pulses end exactly.
- Pulses:
  - `schedule(PulseProgram)`;
  - `apply(RFPulse)` (hard, instant);
  - `startPulse(RFPulse)` (finite, selective across the line).
- `acquire(program, duration:sampleRate:)` runs a batch and returns the signal samples (at most `maxAcquireSamples`, 2²²; a non-finite duration returns none). It plays only `program`'s pulses, not ones queued with `schedule`.
- Readouts:
  - `signal` (mean Mₓ + iM_y), `signalMagnitude`, `meanMagnetization`;
  - `magnetizations` and `isochromatOffsets` (for the Bloch-sphere cone);
  - `effectiveField(isochromat:)`, `isRFOn`, `isPulsing`.
- Statics:
  - `gradientSpreadHz(species:gradient:length:)` (4.258 Hz for 1 µT/m over 10 cm);
  - `dephasingTime(…)` (164 ms: a sinc, not T₂* = 75 ms, so label it "dephasing time");
  - `firstNull(…)` (235 ms);
  - `gradientEnvelope(spreadHz:at:)`.
- A one-isochromat ensemble with no spread is bit-for-bit the `BlochSimulator`.

**`PulseProgram`** (hard pulses with times):
- `.fid`;
- `.hahnEcho(tau:)`: the echo appears at 2τ with amplitude e^(−2τ/T₂);
- `.inversionRecovery(inversionTime:)`.

## FID signals, spectrum, sound

**`FIDParameters`**:
- Fields: `frequencyHz`, `amplitude`, `t2Star`, `phase`, `sense`.
- `init(species:field:t2Star:amplitude:phase:)`.
- `linewidthHz` = 1/(πT₂*).

**`FIDSignal`**:
- `envelope(_:at:)`.
- `baseband(_:referenceHz:sampleRate:count:startTime:)`: complex I + jQ with the line at s·(f_L − f_ref). For protons that puts it at −Δf.
- `audio(_:sampleRate:count:startTime:)`: real samples at the **true** frequency.
- `isRepresentable(frequency:sampleRate:)`: false above fs/2. Electrons are never audio-rate.

**`FIDSpectrum`**:
- `lorentzian(_:referenceHz:frequencies:)` is analytic: peak A·T₂*.
- `transform(_ iq:sampleRate:)` is a centred vDSP DFT scaled by 1/fs.
- `transform(real:sampleRate:)` is one-sided and Hann-windowed.
- Fields: `frequencies`, `real`, `imaginary`, `magnitude`, `peakFrequency`.

**`FIDOscillator`** (a streaming voice, value type):
- Envelope modes: `.ringDown`, `.sustained`, `.repeating(interval:)`, `.follow`.
- Control: `trigger(amplitude:)`, `targetFrequency` (with `glideTime`), `envelopeTarget` (control-rate envelope in `.follow` mode).
- Output: `render(_:)`, `render(into:)` (no allocation), `advance()`.

**`LarmorSonification`**:
- `voice(forFrequency:preferTrue:)` and `voice(species:field:preferTrue:)` return a `LarmorVoice` (`physicalHz`, `audibleHz`, `mode`, where `PitchMode` is `.truePitch` or `.mapped`).
  - True pitch between 20 Hz and 20 kHz; otherwise spectra-lab's `110·2^(4(log₁₀f − 5.5)/16)`, badged MAPPED.
- `mappedPitch(forFrequency:)`.
- `truePitchCeilingField(species:)`: 469.7 µT for water.
- `pitchJitterHz(species:fieldNoise:)`.
- `isInAMBroadcastBand(_:)`.
- `fieldSmoothingTime`: 0.25 s.

**`SpinSoundParameters(species:field:t2Star:pitch:rotor:timeScale:)`**: `fid`, `fidDecay`, `rotorBladePassHz` (rpm/60 × 6 × D) and `rotorNodHz` (the true inertial nod × D, replacing Gyre's 2·precession + 1.5 Hz).

## Patch / Scope sources

**`SpinFIDSource`** is the "Spin FID" node and Hear-it voice (MODEL · LIVE |B|):
- Created with `init(species:field:sampleRate:t2Star:level:repeatInterval:)`.
- Field input:
  - `updateField(_:dt:)` feeds live |B| through the 0.25 s smoother.
  - `setField(_:)` takes a knob value and skips the smoothing.
- Envelope:
  - `pulse(amplitude:)` starts the analytic ring-down.
  - `follow(envelope:)` follows a simulation's |M⊥| at control rate; check it with `isFollowing`.
- Output:
  - `renderAudio(_:)` / `renderAudio(into:)` (sample rate `sampleRate`): true pitch when audible, MAPPED otherwise.
  - `renderBaseband(count:sampleRate:referenceHz:)`: the `iq` port and the "spin.fid" stream. While following a simulation its envelope is the followed |M⊥| too, so the Scope shows the echo the speaker plays.
- Readouts: `larmorHz`, `voice`, `wavelength`, `envelope`, `field`.

**`GyroscopeEngine`** is the Spin tab's gyroscope *and* the "Gyroscope tip" node (MODEL · LIVE motion):
- Created with `init(params:tilt:trailCapacity:tipCapacity:)`.
- Configuration: `params`, `resonance: RotorResonanceDrive?`.
- Control:
  - `launch(tilt:azimuth:rpm:)`, `apply(HeavyTopPreset)`, `retuneResonance()`;
  - `advance(dtReal:environment:)`, `setPaused(_:)`;
  - `kick(strength:angle:)`, `addSpin(_:)`.
- Tip stream:
  - `popTipBlock(size:)` returns fixed blocks for Patch; `drainTip()` returns everything for Scope rings.
  - `tipSampleRate` is 960 per *simulated* second; `wallClockTipRate` is 960·D. Declare the latter on the port.
- Readouts: `pendingTipCount`, `telemetry`, `trail` (axle tip, Float, one point per advance), `tip`, `rotorGamma`, `appliedField`, `top`.

**`IQBlockQueue`**: a FIFO of complex samples. `append(contentsOf:)`, `popBlock(size:)`, `drain()`, `count`, `samples`; the oldest samples are dropped past `capacity`.

## Heavy top (Gyre `GyroSim`, ported)

**`HeavyTopParams`**:
- `motorRPM`, `inertia`, `gravity`, `balance`, `friction`, `air`, `timeScale`.
- `magnet` is **signed** (−1 … 1). `realNdFeBMagnet` is 0.138, i.e. 8.276 A·m²; `electronLikeMagnet` is −1.

**`HeavyTopEnvironment`** (world frame, Z up): `deviceRate`, `linearAccel`, `magneticField` (tesla), `pressureFactor` (P/101.325 kPa, from `AirHere.pressureFactor`), `extraTorque`. CoreMotion's `rotationRate` and `userAcceleration` are in the *device* frame: rotate them into the world frame with the attitude first, as Gyre's `MotionSample` does. `sanitized` zeroes non-finite vectors.

`HeavyTopParams.sanitized` replaces non-finite knobs with their defaults, keeps Inertia in 0.01…100× and caps the time scale at `HeavyTopParams.maxTimeScale` (10×, five times the Time knob's top, so one frame never covers more than 0.5 simulated seconds or 480 tip samples); `step` and `launch` apply it, and `GyroscopeEngine.wallClockTipRate` reports the capped rate.

**`HeavyTop`**:
- Stepping: `step(dtReal:env:params:)` is RK4 with substeps resolving the fastest motion.
- Interaction: `launch(params:tilt:azimuth:rpm:)` starts in steady precession; `applyImpulse`, `addSpin`, `kick(strength:angle:)`.
- State: `axis`, `momentum`, `cageX`, `spinAngle`, `spinSweep` (motion blur), `precessionRate`, `axisSpeed`, `I1`, `I3`, `rpm`, `tilt`, `energy`, `magneticEnergy(field:)`.
- Analysis:
  - `nodRate(field:magnet:)`: √((L₃/I₁)² − 4(mgℓcosθ − μB cosθ_B)/I₁), which gives 244.43 rad/s at 1 g and tilt 0.3;
  - `nutationRate`: L₃/I₁;
  - `fastTopPrecession(gravity:)`, `steadyPrecession(…)`: the slow root;
  - `rotorGamma(magnet:)`, `larmorRate(magnet:field:)`;
  - `ndfebDipole(…)`.
- Output: `telemetry` (`HeavyTopTelemetry`); `drainTip()` returns 960 Hz simulated-time samples, with at most `tipCapacity` kept.

**`HeavyTopTelemetry`**:
- `rpm`, `precessionRate`/`precessionHz`, `nutationRate`/`nutationHz` (in the field, with gravity), `freeNutationRate`;
- `angularMomentum`, `momentum`, `torque`, `torqueVector`;
- `strain` (|ω_phone × L|, for Feel), `tilt`, `rotorGamma`.

**`RotorResonanceDrive`**:
- `field(at:)`;
- `resonant(with:magnet:b0:b1:phase:)`: co-rotating, Ω = −γ_rotor B₀;
- `quarterTurnTime(rotorGamma:b1:)`: 11.10 s at 1500 rpm and 10 µT.

**`HeavyTopPreset.all`** holds 12 field trips: Gyre's nine plus "Real NdFeB rotor", "Electron-like rotor" and "Magnetic resonance with a gyroscope" (`resonance == true`).

## Charges (bubble "Charges" layer)

**`ChargedSpecies`** (`.electron`, `.proton`): `charge`, `mass`, `chargeToMass`, `symbol`, `title`.

**`Gyration`**:
- Orbit: `cyclotronHz`/`cyclotronAngular`, `period`, `gyroradius(_:perpendicularSpeed:field:)`.
- Speeds:
  - `perpendicularRMSSpeed`: √(2kT/m), giving 1.08 cm; say "RMS v⊥" on the readout.
  - `perpendicularMostProbableSpeed`: giving 0.77 cm.
  - `meanSpeed`.
- `driftVelocity(electric:magnetic:)`.
- Collisions:
  - `collisionFrequency(_:pressure:model:…)`, where `CollisionModel.measuredAir` uses Schunk & Nagy e–N₂/O₂ and `.hardSphere(crossSection:)` an assumed σ;
  - `gyrationPressure` (≈ 5.5 Pa: "D layer ~5 Pa");
  - `magnetizationParameter` (ω_c/ν).
- g − 2: `electronSpinHz`, `gMinusTwoBeatHz`, `electronSpinToCyclotronRatio` (1 + aₑ), `protonSpinToCyclotronRatio` (μₚ/μ_N).

**`ChargedParticle`**:
- `borisStep(h:electric:magnetic:exactPhase:)`:
  - `exactPhase` uses the tan-corrected rotation, so f_c is exact.
  - The radius stays high by (ω_c h)²/24.
- `borisKick(h:electric:magnetic:exactPhase:)`: the velocity half of a Boris step (position untouched).
- `flight(h:collisionFrequency:temperature:rng:)`: free flight with collisions, exact for any νh (Ornstein–Uhlenbeck velocity and position drawn jointly), so charges diffuse with D = kT/(mν) and drift at qE/(mν). ν = 0 is x += vh.
- `collide(frequency:temperature:h:rng:)`: the velocity-only Ornstein–Uhlenbeck update.

**`ChargeCloud`**:
- Created with `init(species:count:radius:temperature:pressure:collisionModel:seed:)`. Setting `species` to a different value respawns the cloud (same count, Maxwellian at `temperature`); `respawn(count:)` does it explicitly.
- Stepping: `advance(_ simulatedDt, magnetic:electric:)`: Boris kick then exact `flight`; substeps resolve 1/16 orbit and a quarter radius of flight at the larger of the thermal speed and the fastest particle's (charges spawned hot stay hot in vacuum after the Temperature knob drops), so sea-level air costs one substep per κ-slowed frame (`lastSubsteps`). Walls are elastic.
- Readouts: `readouts(field:)` returns (gyroradius, cyclotronHz, ω_c/ν); also `normalizedPositions` and `collisionFrequency`.
- Time is κ-slowed: pass wall dt × `SpinTiming.kappaRate(kappa:referenceHz: f_c)`.

## Earth field, timing, extras

- **`EarthField(field:gravity:)`** and `init(microtesla:gravity:)`, both in any one frame:
  - `magnitude`, `down`, `vertical`, `horizontal`;
  - `dipAngle` (+ when the field dips down);
  - `magneticLatitude` (from tan I = 2 tan λₘ; 66° gives 48.316°; INFERRED);
  - `dipoleMagnitude`, `larmorHz(_:)`;
  - statics `magneticLatitude(dipAngle:)`, `dipAngle(magneticLatitude:)`, `dipoleMagnitude(magneticLatitude:equatorialField:)`;
  - `typicalField` (50 µT), `dipoleEquatorialField` (30 µT).
- **`FieldSmoother(timeConstant:)`**: `update(_:dt:)`, `value`, `reset()`.
- **`ChemicalShift`**: `separationHz(ppm:protonHz:)`, `couplingRatio(ppm:couplingHz:protonHz:)`, ethanol constants. At Earth's field, ethanol is one line.
- **`SpinTiming`**:
  - `aliasedFrequency(_:sampleRate:)`: 60 Hz at fs 99.8 gives 39.8 Hz; 337.5 Hz at 120 fps gives 22.5 Hz;
  - `isAliased(_:frameRate:)`;
  - `kappaRate(kappa:referenceHz:)` (D = κ/f_ref);
  - `slowdownFactor` (print "slowed 5.5 × 10¹⁴×", not "1 : 1/D");
  - `apparentFrequency(_:timeScale:frameRate:)`.
- **`SpinKnobs`**: pure knob ranges (`SpinKnobRange`: `position(of:)`, `value(at:)`, `detent(at:)`, `modulated(base:depth:control:)`, `displayScale`, `unit`) for:
  - the gyroscope page;
  - `b0` (10 µT–9.4 T with Earth, fridge-magnet, MRI and NMR detents);
  - `b1`, `offset`, `phase`, `t1`, `t2`, `gradient`, `isochromats`;
  - `chargeAir` (Vacuum / D layer ~5 Pa / Sea level), `temperature`, `electricField`.

  The UI adds the title, SF Symbol, tint and key path.
- **`SpinAnalysis`**: `toneFrequency` (real or IQ), `power`, `peakPower`, `hann`. Use these for measured readouts such as a nod frequency from the trail.
- **`SpinMath`** helpers: `rotate`, `rotateZ`, `wrapAngle`, `unit`, `perpendicular`, `clamp`. **`SpinRandom`** is a seedable SplitMix64 (`-seed N`; `uniform`, `gaussian`, `gaussianPair`, `exponential`). **`SpinTrail`** is Gyre's `TrailBuffer`.
- **`SpinAnalysis`** clips a band to ±fs/2, so `0...(.infinity)` finds the tone (not a real record's mirror); a window of the wrong length falls back to Hann.
- **Also here, for the §10 oracles and the bubble skins:**
  - `BubbleOptics`: Airy film, Sellmeier silica/N-BK7, water Cauchy.
  - `AirHere`: P.453 N, k-factor, horizon, ZHD, m/hPa, the rotor's `pressureFactor`.
  - `TurntableStatistics` (Rayleigh σ 5.57 dB) and `TurntableModel` (PLF, λ/2 dipole F², ULA AF). The RF engine owns the general antenna models; these are the textbook special cases only.

## Typical use

```swift
// Spin tab, each frame (main actor). CoreMotion's rotationRate and userAcceleration are in the
// device frame: rotate them (and the magnetometer vector) into world axes with the attitude first.
gyro.advance(dtReal: dt, environment: HeavyTopEnvironment(
  deviceRate: worldRotationRate, linearAccel: worldUserAccel, magneticField: worldB, pressureFactor: AirHere.pressureFactor(kilopascals: kPa)))
var ens = sample                       // SpinEnsemble, in SpinModel
ens.drive.offsetHz = offsetKnob
ens.advance(dt * timeScale)
fidSource.updateField(liveBMagnitude, dt: dt)            // pitch follows live |B|, smoothed
fidSource.follow(envelope: ens.signalMagnitude)          // hear echoes and Rabi nutation
let chips = SpinFieldReadout(field: liveBMagnitude)

// Patch Gyroscope tip node (rate = gyro.wallClockTipRate):
while let block = gyro.popTipBlock(size: 1024) { emit(block) }
```

## Verification

`Tools/check-spin.sh` runs four steps:
1. Typecheck as the app compiles it: Swift 6, MainActor default, approachable concurrency, warnings as errors.
2. Typecheck against the iOS 27 SDK.
3. Typecheck `SpectraTests/SpinTests.swift` against the engine as `@testable` module `Spectra`, with macOS and iOS XCTest.
4. Build and run the 111 oracles on macOS (`-O`, about 0.3 s on an idle machine).

The same oracles run in XCTest as `SpinTests`: 14 test methods, one per group (plus the wiring check), about 9 s in a Debug build. They have also been run under the real XCTest runner on macOS (Debug, `@testable import Spectra`); see the verification notes. Verification notes: `Docs/notes/spin-engine-verify.md`.
