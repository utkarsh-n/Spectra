# API — Live (`Spectra/Live/`, `Spectra/UI/Live/`)

Owner: **live**. The foundation's `SensorHub` API (`Docs/API.md` §5) is unchanged; this file lists what was added, the stream ids every source publishes, and how to use the pure Live analysis from other slices. Everything here is `@MainActor` unless marked `nonisolated`.

## 1. SensorHub (unchanged contract, plus typed channels)

```swift
app.live.acquire(.magnetometer, by: "scope")   // reference counted; permission prompt happens in start()
app.live.release(.magnetometer, by: "scope")   // stops when the last holder leaves
app.live.releaseAll(by: "scope"); app.live.holders(of: .microphone)
app.live.channel(.bluetooth)                   // any SensorChannel (as before)
app.live.channels; app.live.markers; app.live.isEnabled(.nfc)
app.live.setActive(_:); app.live.apply(settings)   // AppModel calls these

// Added
app.live.source(.light)                        // any LiveSource: + capabilities, refresh(), startsSilently, isSimulated
app.live.motion / .magnetometer / .barometer / .microphone / .bluetooth / .network / .location / .light / .charging / .uwb / .nfc
app.live.settings.prefs                        // LivePreferences (persisted "Spectra.live.v1"): bleExponent, wifiBand, air T/RH/dN/dh, antenna height, camera, flicker, proximity, FFT N, mains, virtual fs
app.live.preferencesChanged()                  // apply camera/flicker/proximity/FFT changes to running channels
app.live.refreshAll()                          // pull readouts now (the hub does it at 2 Hz while anything runs)
app.live.highlightedRadio                      // antenna-map row shown on the strip ("live.antenna" marker)
app.live.setSimulatedTurntable(_:)             // spins the simulated phone (fakes only)
```

Real vs simulated: each channel decides at `start()` with `LiveContext.simulates(_:hardwareAvailable:)`. DEBUG builds simulate when a `-fake…` argument asks, when Settings → Sensors → Simulated is **Always**, or when the hardware is missing (the Simulator). Release builds never simulate (missing hardware → `.unavailable(reason)`). Streams carry `.live` or `.sim` provenance accordingly; `channel.isSimulated` tells the UI.

Typed readouts (observable, refreshed at 2 Hz):

| Channel | Members |
|---|---|
| `MotionChannel` | `tilt`, `pitch`, `roll`, `yaw` (°), `vibrationRMS` (g) |
| `MagnetometerChannel` | `field` (µT, calibrated or raw), `gravity` (g), `isCalibrated`, `accuracy`, `spectrum: LiveAnalysis.Spectrum?` (raw axes, AC power summed), `detectedMains` (50/60 or nil), `fftCount` (256/512/1024), `earthField: EarthField?` (Spin engine: dip, magnetic latitude) |
| `BarometerChannel` | `pressure` (Pa), `relativeAltitude` (m) |
| `MicrophoneChannel` | `sampleRate`, `level` (dBFS), `loudestHz`, `loudestDB` |
| `BluetoothChannel` | `devices: [BLEDeviceTable.Device]` (strongest averaged RSSI first: `id`, `name`, `txPower`, `connectable`, `apple`, `lastRSSI`, `averageRSSI` (exponential, α = 0.25 per advert), `adverts`, `stream`), `advertRate`, `managerState`. Radios evicted from the 40-radio table leave the bus at the next refresh. |
| `NetworkChannel` | `interface`, `quality` (0–3), `isExpensive`, `isConstrained`, `isUltraConstrained`, `technologies` (per SIM line), `dataService`, `cellular: RadioMaps.Cellular?`, `dataPath: RadioMaps.DataPath?`, `rtt` (ms), `onWiFi` |
| `LocationChannel` | `horizontalAccuracy`, `verticalAccuracy`, `ellipsoidalAltitude`, `seaLevelAltitude`, `speed`, `trueHeading`, `magneticHeading`, `latitude` (memory only), `accuracyLimited`, `hasFix` |
| `LightChannel` | `lux`, `ev`, `kelvin`, `reading: CameraReading` (ISO, exposure, aperture, offset, frame rate, rows), `flickerSpectrum`, `flickerLine` |
| `ChargingChannel` | `level` (%), `batteryState` (0 unknown, 1 unplugged, 2 charging, 3 full), `thermal` (0–3), `proximityCovered`, `proximitySupported`, `magsafeLikely`, `isCharging` |
| `UWBChannel` | `distance`, `azimuth`, `converged` (fake peer only; otherwise `.locked`, NEEDS PEER) |
| `NFCChannel` | `taps`, `lastTap` (fake only; always LOCKED) |

## 2. Stream ids (stable; `LiveStreams` holds the specs)

| Sensor (group) | Stream id | Unit | Nominal rate |
|---|---|---|---|
| motion (Motion) | `accel.x/y/z` raw (gravity included) | g | 100 Hz (push, requested 200 Hz; batched accelerometer when `CMBatchedSensorManager` supports it) |
| | `accel.user.x/y/z` (device motion) | g | 100 |
| | `gravity.x/y/z` | g | 100 |
| | `gyro.x/y/z` raw | rad/s | 100 |
| | `attitude.pitch/yaw/roll` | ° | 100 |
| magnetometer (Magnetometer) | `mag.x/y/z`, `mag.norm` (calibrated, device motion) | µT | 100 (99.8 with hum fakes) |
| | `mag.raw.x/y/z`, `mag.raw.norm` (raw push, bias included; FFT input) | µT | 100 (99.8) |
| barometer (Air) | `baro.pressure`, `baro.altitude` (relative) | Pa, m | 1 |
| microphone (Audio) | `mic.left` (2 s ring), `mic.level` (per 1024 samples) | FS, dBFS | hardware rate (48 kHz), 46.9 |
| bluetooth (Bluetooth) | `ble.<UUID>.rssi`, one per advertiser, λ of 2.44 GHz | dBm | irregular (0) |
| network (Network) | `net.rtt` (TCP handshake), `net.quality` (0 unknown … 3 good) | ms, level | 1 |
| location (Location) | `gnss.hacc`, `gnss.vacc` (λ of L1), `gnss.speed`, `gnss.altitude` (ellipsoidal) | m, m/s | 1 |
| | `gnss.heading.true`, `gnss.heading.magnetic` | ° | irregular |
| light (Light) | `light.lux`, `light.cct`, `light.ev` | lux, K, EV | 10 |
| | `light.flicker` (rolling-shutter row means) | rel. | rows × fps (≈ 3.6 kHz real, 2.4 kHz SIM) |
| charging (Device) | `battery.level`, `battery.state`, `device.thermal` | %, state, level | 0.2 |
| | `device.proximity` (only while monitoring is on) | state | irregular |
| uwb (Radio) | `uwb.distance` (λ of ch 9), `uwb.azimuth` | m, ° | 10 (fake peer only) |
| nfc (Radio) | `nfc.tap` (λ of 13.56 MHz) | event | 0.125 (fake only) |

`LiveStreams.catalog(sensor)` lists the fixed specs, `LiveStreams.bleRSSI(uuid)` builds a BLE id, `LiveStreams.sensor(for: id)` maps an id back to its sensor. Streams are registered when the source starts and removed when it stops; BLE streams appear per radio and leave after 30 s of silence. Samples carry the sensor's own timestamps (`CMLogItem.timestamp`, `AVAudioTime` host time, BLE callback time, capture presentation time, `CLLocation.timestamp` mapped onto uptime).

## 3. Markers the Live tab adds (while the source runs)

`live.mains` (50/60 Hz: SIM hum, or a detected line badged INFERRED on a device), `live.ble` (2.44 GHz), `live.wifi` (assumed band, MODEL), `live.cell` (the data line's RAT → catalog carrier, INFERRED), `live.gps.l1`, `live.gps.l5` (with a fix), `live.sound` (loudest frequency, `isEM: false`), `live.light` (Wien peak of the white-balance CCT, INFERRED), `live.qi` (while charging, INFERRED), `live.uwb`, `live.nfc`, `live.antenna` (antenna-map row, TABLE).

**Spin hand-off.** "Hear Earth-field NMR" on the Magnetometer card calls `app.focus(SpectrumMarker(id: "live.nmr", label: …, frequency: f_L, …, tab: .spin))`, where f_L = γ′ₚ·|B| (`SpinSpecies.protonWater.larmorHz(field:)`) of the measured field. The spin-ui owner can select the proton view when `app.focusedMarker?.id == "live.nmr"` (request in `Docs/notes/live-requests.md`).

**Show on spectrum without a running source.** LOCKED / NEEDS PEER cards (NFC, UWB) keep their TABLE carrier button; the Air card's button tunes to the 60 GHz oxygen line (`live.o2`, TABLE, not a strip marker).

**Radio hand-off.** "Open card" on the Cellular & Wi-Fi card calls `app.focus(SpectrumMarker(id: "live.system.<catalog id>", …, tab: .radio))`. The radio-ui owner can read `app.focusedMarker?.id` with prefix `live.system.` to select that Systems card (request in `Docs/notes/live-requests.md`).

## 4. Pure analysis (`nonisolated`, harness-safe; physics comes from the engines)

```swift
LiveAnalysis.resample(times:values:rate:count:)            // timestamped → uniform grid ending at the newest sample
LiveAnalysis.spectrum(axes: [TimedSamples<Float>], rate:, count:) -> Spectrum?   // RF.SpectrumAnalyzer, Hann, axes summed in power, dB re 1 unit
  Spectrum: bins, sampleRate, count, binWidth, nyquist, peak, floorDB, level(near:tolerance:)
LiveAnalysis.mainsLines(mains:sampleRate:harmonics:) -> [AliasLine]   // RF.DSP.aliasFrequency: 60 Hz @ 99.8 → 39.8, 120 → 20.2
LiveAnalysis.detectMains(in:margin:) -> Double?             // 60, 50 or nil
LiveAnalysis.loudest(_:sampleRate:count:analyzer:)          // audio peak; levelDBFS(_:)
LightMeter.ev100(aperture:exposure:iso:targetOffset:), lux(ev100:), ev100(lux:), wienPeak(kelvin:) (Core Wave), rowRate(rows:frameRate:)
LightChannel.simulatedReading(lux:flickerLocked:)            // SIM camera settings whose EV matches the SIM lux (ISO ≤ 3200, offset carries the rest)
AirAnalysis.evaluate(pressureHPa:tempC:humidity:gradient:height:latitudeDegrees:ellipsoidalHeight:) -> Result
  // N, dry/wet, k, radio + geometric horizon, ZHD (m, s), O₂ at 60 GHz (RF P.676, total pressure), m/hPa  (Spin AirHere + RF Atmosphere)
AirAnalysis.vapourDensity(...), airState(...), lightPath(roundTrip:)
RadioMaps.cellular("CTRadioAccessTechnologyNRNSA") -> Cellular(label, generation, systemID)
RadioMaps.dataPath("cell.nsa.mmwave") -> DataPath(label, systemID, isWiFi);  RadioMaps.WiFiBand
RadioMaps.bleDistance(rssi:txPower:exponent:)               // RF.Propagation.distanceFromRSSI with FSPL(1 m, 2.44 GHz)
RadioMaps.phoneRadios                                       // iPhone 15 Pro Max radios + schematic antenna segments (MODEL), catalog ids
YawBinner (turntable): add(yaw:rssi:), turns, filledBins, sampleCount, isComplete, statistics, meanDeviation, frontToBack, isFadingDominated, modelPattern(peakYaw:)
BLEDeviceTable (Mutex, Sendable): heard(...), snapshot(), prune(quiet:now:)
LevelAccumulator (Mutex, Sendable): feed(_:start:interval:into:)   // one dBFS level per 1024 samples, stamped at the block's last sample
Latest<T> (Mutex box), SimWorld (shared simulated turntable)    // Live/LiveBoxes.swift
```

## 5. UI pieces other slices may reuse

- `LiveTab()` — the tab root (page picker Sensors · Scope; follows `app.scopeRequest`). Launch paths: `-open live/scope`, `-open live/census` (census sheet), `-open live/turntable` (scrolls to Bluetooth and starts the turntable on the strongest radio), `-open live/<card or sensor>` scrolls to a card: `antennas bluetooth network gnss magnetometer microphone light air charging motion uwb nfc`.
- `LiveCensusView()` — the sensor census with capability flags (push it inside a `NavigationStack`). Settings' foundation `SensorCensusView` can link to it.
- `FoldingDiagram(mains:sampleRate:)` — the aliasing diagram (Scope's FFT aliasing note could reuse it).

## 6. Accessibility identifiers

`live-page` (page picker) · `live-card-<card>` (an accessibility container; its controls keep their own ids) · `live-start-<sensor>` (run/pause) · `live-status-<sensor>` · `live-<card>-spectrum|scope|patch` · `live-antenna-<radio>` · `live-ble-device-<i>` · `live-ble-exponent` · `live-turntable` · `live-turntable-clear` · `live-network-open-card` · `live-network-open-<system>` · `live-wifi-band-<band>` · `live-mag-fft-<N>` · `live-mag-mains-<hz>` · `live-mag-virtual-rate` · `live-mag-virtual-reset` · `live-mag-nmr` · `live-light-camera-<side>` · `live-light-flicker` · `live-light-tune` · `knob-live-air-temp|humidity|gradient|height` · `live-charging-proximity` · `live-census-open` · `live-census` · `live-census-<sensor>` · `live-census-run-<sensor>` · `live-census-done` · `live-toggle-<sensor>` (Dials) · `live-dials-ble-exponent` · `live-dials-wifi-band-<band>` · `live-dials-census` · transport action `live-census`.

## 7. Threading

Sensor callbacks (Core Motion queue, altimeter queue, CoreBluetooth queue, audio tap thread, capture queue, Network queues) write only to `Sendable` objects: `SignalStream` rings, `Latest<T>` boxes and the `BLEDeviceTable`, all `Mutex`-guarded. Their closures are built in `nonisolated static` factories so they never inherit main-actor isolation. State changes hop back with `Task { @MainActor in … }`. Channels, the hub and the UI models are `@MainActor`; readouts refresh at 2 Hz (never per sample), plots redraw through `VisibleTimeline` only while on screen.
