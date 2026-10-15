# API — RF engine (`Spectra/RF/`)

Owner: **rf-engine**. Pure Swift (Foundation, Accelerate, simd only). Everything lives under one namespace, `RF`, declared `nonisolated`, so every type and function is callable from the main actor, from detached tasks and from audio/sensor threads. Every value type is `Sendable`; `RF.FFT` is a `final class` marked `@unchecked Sendable` because its vDSP setups are immutable after `init`.

Physics comes from `Docs/research/rf-physics.md` (with its `[corrected in review]` fixes) and the "Verified reference" in `rf-physics-review.md`, plus the RF rows of `gyre-integration.md`'s test table. Every worked value there is an oracle in `SpectraTests/RFTests.swift`, which `Tools/check-rf.sh` also runs on macOS (1116 checks in 18 groups; see `Docs/notes/rf-engine-verify.md`).

**Units.** SI everywhere: Hz, m, s, W. Power levels are dBm or dBW as named. Antenna lengths are in wavelengths when the parameter says so (`L/λ`, `D/λ`). `f_c` in GHz and distances in km appear only where a standard defines the formula that way, and the parameter name says so (`frequencyGHz:`, `distanceKm:`).

**Provenance.** Readouts carry an `RF.ValueBasis`: `.formula` or `.numeric` → badge **MODEL**; `.table` → **TABLE**; `.estimate` → **MODEL** with the caveat from `notes`. `RadioSystem.isSpeculative` → **SPECULATIVE** badge.

## Folder map

| Folder | Contents |
|---|---|
| `Core/` | `RF` namespace, `RF.Const`, `RF.Units` (dB, λ, photon energy, formatting), `RF.Complex`, `RF.SeededRandom`, `RF.Special` (Q, Φ⁻¹, Bessel J/I₀, Si/Ci/Cin, Fresnel C/S, sinc), `RF.Numerics` (Gauss–Legendre, bisection, golden section) |
| `Antennas/` | Closed forms (`RF.Antennas`), `RF.Mismatch`, `RF.Arrays`, polarization vectors, `RF.AntennaStyle` / `AntennaParameters` / `AntennaModel`, `RF.PatternMesh`, cuts, pose (`linkFactor`) |
| `Propagation/` | `RF.Propagation` (FSPL, Friis, log-distance, TR 38.901, two-ray, Hata/COST-231, knife edge), `RF.Atmosphere` (P.676 gas, P.838 rain), `RF.Building` (38.901 O2I, P.2109), `RF.Fading` |
| `Noise/` | `RF.Noise` (kTB, NF cascade, SNR, C/N₀, Shannon, MIMO), `RF.ErrorRates` (BER/SER, EVM) |
| `Systems/` | `RF.Numerology` (NR, LTE, Wi-Fi, Bluetooth, GSM, GPS, UWB, NFC, Qi, broadcast), `RF.Band`, `RF.RadioSystem`, `RF.SystemsCatalog` |
| `Link/` | `RF.PropagationModel`, `RF.LinkBudgetInput`, `RF.LinkBudget` |
| `Signal/` | `RF.IQBuffer`, constellations, pulse shaping, FSK/GFSK/GMSK, DSSS, OFDM, analog AM/FM/PM, channel simulator, EVM/BER, `WaveformSettings` / `Transmitter` / `Receiver`, `BasebandLink` |
| `DSP/` | `RF.FFT` (vDSP) and `RF.ReferenceFFT` (pure Swift), windows, `RF.SpectrumAnalyzer`, FIR/biquad/DC blocker, decimate/resample, streaming interpolator/decimator, NCO, envelope follower, `RF.Bits` |

## Core

```swift
RF.Const.c, .kB, .h, .e, .eta0 (376.730 313 412 Ω), .eta120pi, .T0 (290 K)
RF.Const.fsplConstantDB   // −147.552 2168 dB  (20·log10(4π/c))
RF.Const.kT0dBmPerHz      // −173.975 19 dBm/Hz

RF.Units.dB(power:) / dB(amplitude:) / powerRatio(dB:) / amplitudeRatio(dB:)
RF.Units.dBm(watts:) / watts(dBm:) / dBW(watts:)
RF.Units.wavelength(frequency:) / frequency(wavelength:) / wavenumber(frequency:)
RF.Units.photonEnergyJ(frequency:) / photonEnergyEV(frequency:) / lightTime(distance:)
RF.Units.dBi(fromDBd:), RF.Units.dBdToDBi (2.1509), RF.Units.ituBand(frequency:) ("UHF"; V.431 upper limits inclusive: 3 GHz is UHF)
RF.Units.format(frequency:) "2.45 GHz", format(distance:) "20,200 km", format(time:), format(bitRate:), format(dB:unit:decimals:) "−40.2 dBm"
    // NaN formats as "—", ±∞ as "∞ <largest unit>"; distances beyond 10¹⁵ km in light-years (no Int overflow)

RF.Complex(re, im)        // + − × ÷, magnitude, phase, conjugate, expj(θ), polar(r, θ)
var rng = RF.SeededRandom(seed: 7)   // xoshiro256**; uniform(), gaussian(), gaussianPair(), bits(n)
RF.Special.Q(x), normalCDF, inverseNormalCDF, inverseQ, besselJ(n, x), besselI0, besselI0Scaled, sici, cin, fresnel, sinc
```

## Antennas

### Closed forms (`RF.Antennas`)

| Function | Reference |
|---|---|
| `hertzianRadiationResistance(lengthWavelengths:eta:)`, `shortDipoleRadiationResistance(lengthWavelengths:)` | A.1, A.2 |
| `ThinDipole(lengthWavelengths:)` → `radiationIntegral`, `patternMax`, `thetaMaxDeg`, `radiationResistance(eta:)`, `inputResistance(eta:)`, `directivity`, `hpbwDeg`, `normalizedPower(theta:)` | A.3 (numerical; searches F_max, so L > 1.44λ is right) |
| `halfWaveDipoleReactance` (+42.5 Ω), `quarterWaveMonopoleImpedance` (36.5 + j21.25 Ω) | A.3, A.4 |
| `smallLoopRadiationResistance(areaOverLambdaSquared:turns:muEffective:eta:)` and `(area:frequency:…)` | A.5 |
| `PatchDesign(epsilonR:height:frequency:)` → `width`, `epsilonEffective`, `deltaL`, `length`, `effectiveLength` | A.6 |
| `yagiNBSTable`, `yagiGainDBd(boomWavelengths:)` | A.7 (TABLE) |
| `HelixEstimates(circumference:turns:spacing:)` → Kraus D/HPBW, Stutzman–Thiele, `inputResistance`, `axialRatio`, `emersonGainDBi`, `isAxialMode` | A.8 |
| `hornGain(apertureA:apertureB:efficiency:)`, `dishGain(diameter:efficiency:)`, `airyHalfPowerArgument`, `uniformApertureHPBWDeg(diameter:)`, `taperedDishHPBWDeg(diameter:)` | A.9, A.10 |
| `planarArrayGainDBi(elementGainDBi:nx:ny:)`, `arrayGainDB(elements:)` | A.12, D.10 |
| `pifaResonantFrequency(currentPath:)`, `phoneEfficiencyRange` | A.13 (estimate) |
| `effectiveAperture(gain:wavelength:)`, `eirpDBm(txPowerDBm:gainDBi:feedLossDB:)` | A.14 |
| `linearPLF(mismatchDeg:)`, `plfDB(_:floorDB:)` | A.15 |
| `reactiveNearFieldBoundary(size:wavelength:)`, `farFieldBoundary`, `smallAntennaBoundary` | A.17 |
| `halfPowerBeamwidth(peakDeg:rangeDeg:step:_:)` | helper |

`RF.Mismatch(load: RF.Complex, reference: 50)` → `gamma`, `gammaMagnitude`, `vswr`, `returnLossDB`, `mismatchLossDB`, `reflectionEfficiency`, `isResistiveOnly` (when only R is known the VSWR and mismatch loss are **lower bounds**; show "≥").

`RF.PolarizationVector` (complex 3-vector; `plf(with:)` is |e_w·e_a|² without conjugation, the receiver's vector being its own transmit polarization pointing back) and `RF.ReferencePolarization` (`.vertical .horizontal .slant45 .slantMinus45 .rhcp .lhcp`, `vector(propagation:up:)`).

### Arrays (`RF.Arrays`, θ from the array axis)

`normalizedAF(psi:elements:)`, `normalizedAF(theta:elements:spacing:beta:)`, `steeringPhase(spacing:steerTheta:)` (β = −kd·cosθ₀), `gratingFreeSpacing(steerTheta:)` / `(steerFromBroadside:)`, `lobeDirections`, `gratingLobes`, `beamPeakDeg`, `hpbwDeg`, `broadsideHPBWApproxDeg`, `broadsideDirectivityApprox`, `directivity(elements:spacing:beta:)`, `highestSidelobeDB`.

### The pattern model

```swift
var p = RF.AntennaParameters(style: .phasedArray, frequency: 28e9)
p.arrayNx = 8; p.arrayNy = 8; p.arraySpacing = 0.5; p.steerTheta = 30; p.arrayElement = .patch
let model = RF.AntennaModel(p)          // integrates the pattern: build when a knob changes, not per frame
model.parameters                        // p.sanitized(): every knob clamped into AntennaParameters.Limits, NaN → default
model.directivityDBi                    // numerical, from the pattern
model.gainDBi; model.gainBasis          // headline gain + where it comes from (Readout: value, basis, source)
model.referenceGain                     // the reference's own figure when it differs (horn/dish formula, NBS table, Kraus, G_el + 10logN)
model.ePlaneHPBWDeg; model.hPlaneHPBWDeg   // nil = never falls to half power (omni cut)
model.radiationResistance               // Readout? (short dipole, dipole, monopole, loop)
model.inputImpedance                    // (z, resistiveOnly, source)?  (dipole, monopole, loop, short dipole, helix)
model.mismatch                          // RF.Mismatch? vs parameters.referenceImpedance (nil = feed assumed matched)
model.radiationEfficiency, model.effectiveAperture, model.fieldRegions (FieldRegions: reactiveNearField, farField, smallAntennaBoundary, region(at:))
model.polarizationDescription, model.bandwidthNote, model.notes   // plain-language caveats for field notes
model.arrayGratingLobes, model.arrayGratingFreeSpacing, model.helix, model.patchDesign, model.pifaResonance
model.field(dir) / field(theta:phi:) / power(dir)        // normalized |F|, |F|² (0…1), local frame
model.polarization(dir)                 // unit transmit polarization toward dir
model.directivityDBi(toward:) / gainDBi(toward:)
model.polarizationLossFactor(toward:receiver:up:)
model.linkFactor(attitude:toward:reference:up:) // (patternDB, polarizationDB, gainDB) for Follow phone
RF.AntennaModel.localDirection(world:attitude:)  // attitude = local → world rotation (phone attitude)
RF.AntennaModel.steering(toward: localDir)       // (theta, phi) for Beam lock: put into steerTheta/steerPhi
model.apertureDistribution(plane: .e | .h, spacing: 1/32)  // RF.ApertureDistribution? for "Aperture phase space"
```

**Knob ranges.** `RF.AntennaParameters.Limits` holds every knob's range (frequency 1 Hz–3 THz, lengths, ε_r, patch height, element counts, spacing, steering, efficiencies, reference impedance). `AntennaModel` builds from `parameters.sanitized()`, so a knob driven out of range or to NaN (a Patch modulation, a sensor dropout) is clamped instead of trapping or integrating for seconds; `model.parameters` returns what was actually modelled.

**Aperture phase space** (SPEC-features §3c). `model.apertureDistribution(plane:spacing:)` returns the 1-D source behind the pattern: `positions` (λ, uniform), `spacing`, `samples` (`IQBuffer`, complex aₙ), `axis` (local), `isDiscrete`, `description`, and `factor(directionCosine: u)` = Σ aₙ·e^{j2πxₙu}·w. Its transform over u (k_x = k·u) is the model's principal-plane factor, so it is the k marginal of the spatial Wigner W(x, k_x); steering is the linear phase of aₙ. Phased array: elements with the steering phase (E along x, H along y); horn: uniform over B (E) or cos(πy/A) over A (H); dish: √(R² − x²); patch: the two slots ±L_e/2 (E) or the slot width W (H); dipole/monopole (with image)/short dipole: the wire current, E only; Yagi: the boom elements with the Hansen–Woodyard phase. Nil for helix, loop, PIFA and a wire's H-plane. Pad and sample it for the phase engine as needed; the oracles check every transform against the pattern.

**Local frame.** Wire antennas (short dipole, dipole, monopole, PIFA chassis mode) lie along +z; the small loop's normal is +z; directional antennas (patch, Yagi, helix, horn, dish, array) beam toward +z with their E-plane in xz (polarization x at broadside); the monopole's ground is the xy plane; array elements sit in xy (N_x along x, N_y along y). θ is from +z and φ from +x.

**Styles and their models.**

| Style | Pattern | Directivity / gain shown | Impedance |
|---|---|---|---|
| Short dipole | sin θ | 1.5 (numeric) | R_r = 20π²(l/λ)², resistive only |
| Dipole (L/λ 0.1–3) | thin-wire sinusoidal current | numeric (matches A.3 table) | R_in = R_r/sin²(πL); λ/2: 73.08 + j42.5 |
| Monopole (H/λ) | dipole of 2H, z ≥ 0 | numeric (λ/4: 5.161 dBi) | half the 2H dipole; λ/4: 36.54 + j21.25 |
| Small loop (area, N, μ_eff) | sin θ, φ-polarized | 1.5 | R_r (8/3)ηπ³(A/λ²)²N²μ², resistive only |
| Patch (ε_r, h) | Balanis two-slot, designed resonant at the carrier | numeric (= the reference's two-slot integral) | assumed matched (inset feed) |
| Yagi (N 3–20, spacing) | Hansen–Woodyard end-fire array of λ/2 elements | gain = NBS TN 688 at boom (N−1)·s (TABLE) | assumed matched |
| Helix (N, C/λ, S/λ) | cos^q θ with 2(q+1) = Kraus D, RHCP with AR | Kraus D; Emerson "realistic" in notes | 140·C Ω |
| Horn (A, B in λ, ε_ap) | in-phase TE₁₀ aperture | gain = ε_ap·4πAB/λ² | assumed matched |
| Dish (D/λ, η) | uniform circular aperture | gain = η(πD/λ)²; uniform/tapered HPBW in notes | assumed matched |
| Phased array (N_x, N_y, d/λ, θ_s, φ_s, element) | AF_x·AF_y × element (isotropic or patch) | numeric; reference G_el + 10logN in `referenceGain` | assumed matched |
| PIFA (current path) | chassis short dipole along z | 1.5 × e_rad 0.55 (40–70 %, estimate) | assumed matched |

**3D lobe.** `RF.PatternMesh(model:rows:columns:focus:)` samples |F| on a latitude–longitude grid (row 0 = +z pole), `values` row-major `[Float]`, `direction(row:column:)`, `positions(scale: .field | .power | .decibel(floorDB:))`. `PatternMesh.suggestedFocus(for:)` crowds rows near +z for narrow beams (dish, horn). Polar cuts: `model.cut(.e | .h, count:)` → `RF.PatternCut(anglesDeg, values)` with `decibels(floorDB:)`.

**Cost** (Apple silicon, `-O`, thread CPU time): 0.2–1.3 ms per model at the default knobs; the worst the knobs allow (64 × 64 elements at 2λ) about 70 ms. Debounce knob drags or build in `Task.detached` (the model is `Sendable`).

## Propagation, atmosphere, buildings, fading

```swift
RF.Propagation.fsplDB(distance:frequency:)                      // 1 km, 1 GHz → 92.4478
RF.Propagation.friisReceivedPowerDBm(txPowerDBm:txGainDBi:rxGainDBi:distance:frequency:)
RF.Propagation.logDistanceDB(distance:frequency:exponent:referenceDistance:) / logDistanceRange / distanceFromRSSI
RF.Propagation.LogDistanceEnvironment.all                       // Andersen 1995 rows + Rappaport ranges (n, σ)
RF.Propagation.TR38901.indoorOfficeLOS / .indoorOfficeNLOS / .urbanMacroNLOS / .urbanMicroNLOS
    .pathLossDB(distance3D:frequencyGHz:), .shadowSigmaDB, .validDistance
RF.Propagation.TwoRay(txHeight:rxHeight:frequency:reflection:) → exactLossDB, asymptoticLossDB,
    crossoverDistance (4πh_th_r/λ), criticalDistance (4h_th_r/λ, the LAST MAXIMUM), lastNull, lastNullEstimate
RF.Propagation.hataDB(frequencyMHz:baseHeight:mobileHeight:distanceKm:environment:), cost231DB(…metropolitan:)
RF.Propagation.knifeEdgeNu(height:d1:d2:wavelength:), knifeEdgeLossApproxDB(nu:), knifeEdgeLossExactDB(nu:)

RF.Atmosphere.AirState(pressure:temperatureC:waterVapourDensity:convention: .total | .dry)   // .standard
RF.Atmosphere.gasSpecificAttenuation(frequencyGHz:air:) -> (oxygen, waterVapour)  // P.676-13 line-by-line, 1–1000 GHz
RF.Atmosphere.gasAttenuationDBPerKm(frequencyGHz:air:), gasLossDB(frequency:distance:air:)
RF.Atmosphere.rainCoefficients(frequencyGHz:) -> RainCoefficients (kH, αH, kV, αV; combined(elevationDeg:tiltDeg:))
RF.Atmosphere.rainAttenuationDBPerKm(frequencyGHz:rainRate:elevationDeg:tiltDeg:), rainLossDB(…), rainPresets

RF.Building.Material (.glass .irrGlass .concrete .plywood .wood).lossDB(frequencyGHz:)
RF.Building.O2IModel (.lowLoss .highLoss .lowLossA).wallLossDB(frequencyGHz:), .sigmaDB
RF.Building.indoorLossDB(indoorDistance:), wallsLossDB(_:frequencyGHz:)
RF.Building.entryLossDB(frequencyGHz:probability:elevationDeg:building: .traditional | .thermallyEfficient)   // P.2109-2
    // f clamped to entryLossValidGHz (0.08–100 GHz), P to 10⁻⁶…1 − 10⁻⁶, θ to ±90°

RF.Fading.rayleighOutage(belowMeanDB:), rayleighPDF, ricianPDF, ricianParameters(k:), rmsDelaySpread,
    coherenceBandwidth50/90, isFrequencySelective, maxDoppler(speed:frequency:), dopplerShift, coherenceTime (0.423/f_m),
    coherenceTimeHalfCorrelation (9/16πf_m), clarkeSpectrum, rayleighDBStandardDeviation (5.57 dB),
    tr38901ScalingDelaySpreadsNs, tr38901ExampleDelaySpreads
```

**Pressure convention (P.676).** State it. `.total` (the reference's tables: dry = total − e) gives 14.656 dB/km at 60 GHz; `.dry` gives 14.778 dB/km. The Live "Air" card should pass the barometer as `.total`.

## Noise, capacity, error rates

```swift
RF.Noise.densityDBmPerHz(temperature:), floorDBm(bandwidth:noiseFigureDB:temperature:)   // 20 MHz, NF 7 → −93.9649 dBm
    // floor = k(T + T_e)B, T_e = (F − 1)·290 K; `temperature` is the source (antenna) temperature, so a 3 K sky
    // with NF 1 dB in 1 MHz is −119.673 dBm (kTB·F would wrongly give −132.8). At T = 290 K it is kT₀B·F.
RF.Noise.cascadeNoiseFigureDB([Stage("LNA", noiseFigureDB: 1, gainDB: 20), …]), equivalentTemperature, noiseFigureDB(equivalentTemperature:)
RF.Noise.snrDB(receivedPowerDBm:bandwidth:noiseFigureDB:), cn0DBHz(receivedPowerDBm:noiseFigureDB:)
RF.Noise.shannonCapacity(bandwidth:snrDB:), spectralEfficiency, requiredSNRDB(rate:bandwidth:), shannonLimitEbN0DB
RF.Noise.ebN0DB(snrDB:bandwidth:bitRate:), snrDB(ebN0DB:…), esN0DB(ebN0DB:bitsPerSymbol:), ebN0DB(esN0DB:…)
RF.Noise.mimoCapacity(channel: [[RF.Complex]], snrDB:), mimoCapacity(realChannel:snrDB:)

RF.ErrorRates.bpskBER(ebN0DB:), mpskSER(order:esN0DB:), mqamSERApprox / mqamSERExact(order:esN0DB:)
RF.ErrorRates.ser(_ modulation, ebN0DB:), ber(_ modulation, ebN0DB:)    // nil for OOK (no reference formula)
RF.ErrorRates.requiredEbN0DB(_:targetBER:), evmDB(fromRatio:), evmRatio(fromDB:), nrEVMRequirement(_:carrierFrequency:), wifi6EVM1024DB
RF.AnalogTheory.amPowerRatio, amSidebandEfficiency, carsonBandwidth, besselLine(s), fmPowerFraction, carrierNullBeta,
    fskModulationIndex, fskDeviation, gaussianDelta(bt:), broadcastFMDeviation
```

## Systems

`RF.Numerology.NR` (T_c, κ, SCS/T_u/CP/slot per µ, FR ranges, max RB, guard band, NR-ARFCN ↔ MHz, bands, power classes), `.LTE` (T_s, CPs, slot, RB table), `.WiFi` (subcarrier spacings, `phyRate(…)`, headline rates incl. `rateIPhone15ProMax`, 6 GHz bands), `.Bluetooth` (BR/LE channel maps, advertising channels, slot, sensitivities, h ranges), `.GSM` (symbol rate, slot/frame, EDGE rate, P-GSM ARFCN), `.GPS` (L1/L2/L5, codes, minimum powers), `.UWB` (channels 5/9, ToF, two-way ranging), `.NFC`, `.Qi`, `.Broadcast`; `RF.Numerology.processingGainDB(chipRate:bitRate:)`.

`RF.SystemsCatalog.all: [RF.RadioSystem]` (31 systems, Codable): `id`, `name`, `generation`, `category` (`.cellular .wifi .personal .navigation .broadcast` = the filter chips), `year` + `yearNote`, `bands: [RF.Band]`, `iPhoneBands`, `carrier` (representative, for the strip marker), `channelWidths`, `modulation`, `maxQAM`, `multiplexing`, `subcarrierSpacings`, `peakRate: PeakRate?` (value, basis, note), `iPhone: .yes/.partial/.no` + `iPhoneNote`, `isSpeculative`, `waveform: RF.Waveform` (the Fourier page's simulation profile), `facts`, `sources`. Lookups: `system(id:)`, `systems(in:)`, `systems(containing: frequency)`.

Ids: `amps gsm is95 edge umts lte nr-fr1 nr-fr2 6g wifi-b wifi-a wifi-g wifi-n wifi-ac wifi-ax wifi-6e wifi-be bt-classic ble nfc uwb-ch5 uwb-ch9 qi gps-l1 gps-l5 fmcw-77 fmcw-24 am fm dab tv`.

`fmcw-77` (76–81 GHz, 1 GHz sweep) and `fmcw-24` (24.05–24.25 GHz ISM, 200 MHz) are the FMCW radar presets of SPEC-features §3c (Fourier → time–frequency view: a straight-line Wigner). They are filed under the Navigation chip (radiodetermination, with GNSS), `iPhone: .no`; their bands and chirp lengths are marked [S] (not in the physics reference), the range resolution c/2B is the reference's E.4 rule. Each chirp is scaled to one 4096-sample frame at 2B samples/s.

## Link budget

```swift
var x = RF.LinkBudgetInput(frequency: 3.5e9, bandwidth: 100e6)
x.txPowerDBm = 23; x.txGainDBi = model.gainDBi; x.rxGainDBi = 0; x.distance = 500
x.model = .tr38901(.urbanMacroNLOS)            // .freeSpace, .logDistance(exponent:referenceDistance:), .twoRay, .hata, .cost231
x.walls = [RF.WallLayer(.concrete, count: 1)]; x.o2i = .lowLoss; x.indoorDistance = 5
x.rainRate = 25; x.includeGas = true; x.atmosphericPathLength = nil   // set for slant paths to space
x.obstructionHeight = 10; x.polarizationLossDB = 3; x.fadeMarginDB = 0; x.noiseFigureDB = 7
x.requiredSNRDB = 20; x.systemPeakRate = system.peakRate?.value
let r = RF.LinkBudget.evaluate(x)
r.receivedPowerDBm, r.noiseFloorDBm, r.snrDB, r.capacity, r.spectralEfficiency, r.marginDB, r.capacityToPeak
r.terms   // [LinkTerm(name, dB (gains +, losses −), kind)] — the bar chart; they sum to P_r
r.notes   // validity warnings (model range, shadow σ, atmosphere length, invalid inputs)
// Bandwidth 0 (a CW carrier, e.g. Qi): noise floor −∞, SNR +∞, capacity and spectral efficiency 0.
// x.noiseTemperature is the source (antenna) temperature of k(T + T_e)B.
RF.LinkBudget.distance(forReceivedPower: rssi, input: x)   // Live check: solve the model for distance
RF.LinkBudget.range(forSNR:input:)
```

## Signals and the Fourier page

- `RF.IQBuffer` — split complex `[Float]` I and Q (vDSP layout); `meanPower`, `scale`, `rotate`, `slice`, `append`, `resize`, `points` (`[SIMD2<Float>]` for `ConstellationPlot`), `points(stride:)`, `magnitudes()`, `phases()`.
- `RF.DigitalModulation` (`.ook .bpsk .qpsk .psk8 .qam16 … .qam4096`), `RF.Constellation(_:)` — 38.211 Gray mapping (`points`, `map(bits:)`, `demap(_:)`, `decisions(_:into:)`, `qamNormalization(order:)`).
- `RF.PulseShaper` (RRC or rectangular), `RF.DSP.rootRaisedCosine`, `RF.DSP.gaussianTaps(bt:samplesPerSymbol:)`.
- `RF.FSKSettings` (`.gmsk()`, `.bluetoothLE()`, `.bluetoothBR()`), `RF.FSKModulator`, `RF.FSKDemodulator`.
- `RF.SpreadingCode` (`.barker11`, `.mSequence127`, `.mSequence1023`, `mSequence(degree:taps:)`, `forLength(_:)`), `RF.DSSSSpreader`.
- `RF.OFDMConfig` (`.wifiLegacy`, `scaled(name:fftSize:usedFraction:pilotSpacing:cpFraction:subcarrierSpacing:estimation:)` — the FFT size is rounded up to a power of two in 8…65 536, `estimation: .pilots | .preamble`), `RF.OFDMModulator`, `RF.OFDMDemodulator` (`demodulate(_:symbols:offset:tracker:)`), `RF.PilotTracker`.
- `RF.AnalogSettings`, `RF.AnalogModulator` (AM 1 + m·x, FM, PM; real `[Float]` audio blocks in, IQ out), `RF.AnalogDemodulator`.
- `RF.ChannelConfig` (`snrDB` against unit power, `delaySpread`, `dopplerHz`, `fading: .none | .rayleigh | .rician(k:)`, `frequencyOffsetHz`, `seed`; `sanitized()`), `RF.ChannelSimulator(config:sampleRate:)` (stateful `process(_:)`; runs on `config.sanitized()`: NaN or negative spread/Doppler/CFO are off, a NaN SNR is noiseless, a non-positive sample rate reads as 1 Hz, the delay line is capped at 2²² samples), `RF.SumOfSinusoids`.
- `RF.Waveform.chirp(bandwidth:duration:)`: FMCW sweep −B/2 → +B/2 in T, repeated, sampled at 2B (`WaveformSettings.chirpSamples` per chirp); `Transmitter.sweep(count:)` continues it seamlessly; the receiver returns nothing (like `.tone`).
- Every demapper and receiver accepts NaN/∞ samples (they decide to a valid point instead of trapping); FM oversampling is capped at `WaveformSettings.maxAnalogOversampling` (64); `samplesPerSymbol`/`samplesPerChip` are used clamped to 2…64 / 1…64 and frames to 64…2²⁰ samples.
- `RF.EVMResult.measure(received:reference:)` (`rms`, `percent`, `dB`, `estimatedSNRDB`), `RF.BERCounter`.

**Separate stages (Patch Modulator → Channel → Demodulator).** Build both halves from the same settings:

```swift
let settings = RF.WaveformSettings(waveform: system.waveform, modulation: .qam64)
var tx = RF.Transmitter(settings)        // modulate(bits:) -> (samples, symbols); modulate(audio:) for AM/FM; carrier(count:); sweep(count:) for FMCW
var rx = RF.Receiver(settings)           // receive(_:) -> ReceivedBlock(symbols, bits, audio, channelEstimate); any block size
settings.sampleRate, .symbolRate, .occupiedBandwidth, .framePlan (symbols, samples, bits), .perSampleSNR(esN0)
```
Feed `tx.modulate(bits:)` exactly `settings.framePlan.bits` bits per call for OFDM (frames carry the training symbol). The receiver keeps partial symbols and frames for the next call; outputs come in transmit order with a fixed latency.

**End to end (Fourier page).**

```swift
var config = RF.BasebandLinkConfig(system: system)   // or (waveform:)
config.snrDB = 20                 // digital: Es/N0 per data symbol; analog/tone: CNR in the channel bandwidth
config.delaySpread = 100e-9; config.fading = .rayleigh; config.dopplerHz = 50; config.frequencyOffsetHz = 0
config.modulation = .qam256       // override; config.message = .text("Hello") or .random
var link = RF.BasebandLink(config)
let frame = link.next()                 // analog: link.next(audio: micBlock48k) → frame.audio (48 kHz)
frame.tx, frame.rx                      // IQ time traces (unit power)
frame.received.points, frame.ideal.points   // constellation: received vs ideal (FSK: centre samples, ideal empty)
frame.evm, frame.ber, frame.berTheory, frame.sentBits, frame.receivedBits (RF.Bits.toText for text mode)
frame.channelEstimate                   // OFDM, per used subcarrier
link.sampleRate, link.symbolRate, link.occupiedBandwidth   // spectrum axis and channel-mask width
```
Spectrum: `var a = RF.SpectrumAnalyzer(count: 4096)!; a.powerDB(frame.rx, into: &row)` (fftshifted, index N/2 = DC, `RF.DSP.shiftedFrequencies(count:sampleRate:)` for the axis), or `averagedPowerDB` (Welch, 50 % overlap) for a steady OFDM picture; waterfall = successive rows. Scaling `.tone` (a unit tone reads 0 dB) or `.density(sampleRate:)` (dB/Hz).

The receivers are honest: single-carrier has no equalizer (multipath shows as ISI, CFO rotates the constellation); OFDM equalizes with the training symbol (Wi-Fi, DAB) or scattered pilots (LTE, NR, DVB-T) and averages estimates over about a quarter of the coherence time; common-phase tracking switches on with CFO or Doppler. In AWGN the measured BER lands on `berTheory` (checked by Monte-Carlo oracles).

**Cost.** One 4096-sample frame + 4096-point spectrum: 0.15–0.45 ms of CPU time on Apple silicon (`-O`, measured by `Tools/check-rf.sh`), i.e. well inside the 2 ms iPhone budget.

## DSP

`RF.FFT(count:)` (power of two ≥ 8; `forward`/`inverse` in place or returning, unscaled forward, `inverse(scaled: true)` divides by N), `RF.ReferenceFFT.transform(re:im:inverse:)` (Double, pure Swift). `RF.DSP.window(.hann | .hamming | .blackman | .rectangular, count:)` (periodic, = vDSP), `coherentGain`, `equivalentNoiseBandwidth`, `scallopingLossDB`, `highestSidelobeDB`. Bin math: `binFrequency`, `resolution`, `windowDuration`, `aliasFrequency`, `isAliased`, `nextPowerOfTwo`, `shiftedFrequencies`, `oneSidedFrequencies`. `RF.SpectrumAnalyzer`: `powerDB`, `averagedPowerDB`, `realSpectrumDB` (one-sided), `peak(ofOneSided:sampleRate:count:)`. Filters: `firTaps(.lowpass | .highpass | .bandpass | .bandstop, cutoff:upper:taps:window:)`, `firMagnitude`, `FIRFilter` / `ComplexFIRFilter` (streaming, vDSP_conv), `Biquad(.lowpass…, frequency:sampleRate:q:)`, `DCBlocker`. Rate: `decimate` (one-shot, vDSP_desamp), `resampleLinear`, `zeroStuff`, streaming `Interpolator(factor:)` / `Decimator(factor:)`. Mixer: `NCO(frequency:sampleRate:)` (`generate(count:)`, `mix(_:)`, `mixReal(_:)`). `EnvelopeFollower(attack:release:sampleRate:)`. `RF.Bits.fromText`, `toText`, `errors`.

## Threading

All of `RF` is `nonisolated`; stateful pieces (`BasebandLink`, `Transmitter`, `Receiver`, `ChannelSimulator`, filters, `SpectrumAnalyzer`) are value types with `mutating` methods — keep one per consumer (one per view, one per Patch node, one per audio thread) and do not share a single instance across threads. They can be moved between isolation domains (`Sendable`). `Tools/harness/rf/IsolationProbe.swift` proves this under the app's Swift 6 / default-MainActor settings.

## Tests

`SpectraTests/RFTests.swift`: one XCTest per oracle group (constants, antennas, antenna-model, arrays, propagation, atmosphere, building, fading, noise, error-rates, analog, numerology, systems, dsp, modulation, channel, link, robustness) plus a loose frame-performance guard. The robustness group feeds NaN, ∞ and out-of-range values to every entry point that once trapped or returned NaN. `Tools/check-rf.sh` compiles the same file into a macOS harness and runs it (plus imports check, app-isolation typecheck and compile, iOS 27 SDK typecheck, XCTest-mode typecheck, and timings).
