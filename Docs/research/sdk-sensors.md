# Spectra: live radios and sensors on iPhone 15 Pro Max (iOS 27 SDK audit)

Date: 2026-10-03. Target: iPhone 15 Pro Max (iPhone16,2) on iOS 27.2, built with Xcode-beta and the iOS 27.0 SDK.

## How this was checked

| Tag | Meaning |
| --- | --- |
| **SDK** | Read in the headers or `.swiftinterface` under `Xcode-beta.app/.../iPhoneOS27.0.sdk/System/Library/Frameworks` (or `usr/lib/swift`). |
| **TC** | Every Swift spelling quoted below was type-checked against the iOS 27 SDK (`swiftc -target arm64-apple-ios27.0 -typecheck`, Swift 5 mode). The file: `scratchpad/probe/signatures.swift` (session scratchpad; copy it if you want to keep it). |
| **SIM** | Measured by running a probe binary with `xcrun simctl spawn` on the booted iPhone 17 Pro simulator (iOS 27.0, 24A5355p), then on the "Orbitals QA" iPhone 15 Pro Max simulator. Both gave the same values. |
| **DEV?** | Not checked on the physical phone. The rate or behavior comes from Apple documentation or field experience and must be measured on the device. |
| **SPEC** | A hardware fact from Apple's tech specs or a radio standard, not something an API exposes. |

No existing project files were modified, and no signing settings were changed.

---

## 1. Headline findings

1. **Team YOUR_TEAM_ID is a free Personal Team.** `defaults read com.apple.dt.Xcode` shows `isFreeProvisioningTeam = 1; teamType = "Personal Team"`. The team's cached capability list (`~/Library/Developer/Xcode/UserData/Capabilities/capabilities-27.0-YOUR_TEAM_ID-bundle.json`) holds only 11 capabilities, all development-only. None of the 16 profiles carries an NFC, Wi-Fi-info, Wi-Fi Aware, multicast or Thread entitlement. As a result, **NFC tag reading, SSID/BSSID (`NEHotspotNetwork`), Wi-Fi Aware, Thread credentials, SensorKit ambient light and UWB DL-TDoA are all off the table** until he joins the paid Apple Developer Program. Everything else in this document works with no entitlement at all.
2. **No public API gives cellular or Wi-Fi signal strength in dBm.** CoreTelephony gives only the radio access technology (RAT), and `NEHotspotNetwork.signalStrength` is documented as not populated. iOS 26 and 27 do add coarse and categorical radio data that needs no entitlement:
   - `NWPath.linkQuality` (iOS 26): `.unknown/.minimal/.moderate/.good`.
   - `NWConnection.DataTransferReport.PathReport.radioType` (iOS 15): Wi-Fi `a/b/g/n/ac/ax` and cellular `lte`, `dualConnectivity5G(.sub6GHz|.mmWave)`, `standalone5G(.sub6GHz|.mmWave)`, `wcdma`, `gsm`, `cdma`, `evdo`.
   - RTT per path: `transportSmoothedRTT`, `transportMinimumRTT`, `transportRTTVariance`.
3. **The only true live RF power readings come from Bluetooth LE**: per-advertisement RSSI in dBm through `CBCentralManagerScanOptionAllowDuplicatesKey`, plus iBeacon `CLBeacon.rssi` through CoreLocation. The **UWB** distance and direction measurements need a second UWB device. His paired Apple Watch (`Watch7,10`, seen in `devicectl`) is the obvious peer.
4. **iOS 27 is new for radios.** It adds Bluetooth **Channel Sounding** (`CBCentralManager.supports(.channelSounding)`, `CBPeripheral.startChannelSoundingSession(_:)`, `CBChannelSoundingProcedureResults.distance`, `NIDeviceCapability.supportsBluetoothChannelSounding`). Expect `false` on iPhone 15 Pro Max, which has Bluetooth 5.3 (SPEC). The simulator reports `false`.
5. **The magnetometer is the best fit for an "EMF sniffer"**, but the practical sample rate is about 100 Hz (DEV?). Mains fields therefore **alias**: 60 Hz shows up at 40 Hz and 50 Hz sits on Nyquist. Spectra can turn this into a teaching moment instead of hiding it (see §7).
6. **iOS 27 audio API change, correcting the Gyre memory note.** `AVAudioNode.installTap(onBus:bufferSize:format:block:)` is deprecated in iOS 27. Its Swift replacement is **`installAudioTap(onBus:bufferSize:format:tapProvider:) throws`**, which delivers an `AVReadOnlyAudioPCMBuffer` read through `channelData(_:) -> .float(Span<Float>)`. `connect(_:to:format:)` is replaced by `connectNode(_:to:format:) throws` (TC).
7. New iOS 27 conveniences, all TC:
   - `CMMotionManager.deviceMotionBody` and `CLLocationManager.headingBody` take any `UIView`, because UIView conforms to `CMBodyIdentifiable`/`CLBodyIdentifiable` in iOS 27. The old `headingOrientation` is deprecated in iOS 27.
   - `CMDeviceMotion.headingAccuracy` (degrees).
   - `CTTelephonyNetworkInfo.RadioAccessTechnologyDidChangeMessage`, a typed NotificationCenter message.

---

## 2. Signing reality (team YOUR_TEAM_ID)

Provisioning profiles: there are 16 in `~/Library/Developer/Xcode/UserData/Provisioning Profiles`, and the `~/Library/MobileDevice/...` folder is empty. All were decoded with `security cms -D -i`.
- They are all `iOS Team Provisioning Profile: <bundle>`, Xcode-managed, team "Utkarsh Nimavat", with 4 provisioned devices.
- They are `TimeToLive = 365`. For example, `com.utkarsh.gyre` was created 2026-10-03 and expires 2027-10-03. This contradicts the "7-day expiry" note in memory, so that note looks stale for profiles.
- The development certificate `Apple Development: Utkarsh Nimavat (TW6K68RYZM)` runs from 2026-02-08 to 2027-02-08.
- Extra entitlements seen: `com.apple.developer.healthkit(.access/.background-delivery)` on stupidapp and Signals, and `com.apple.security.application-groups` on several. No profile has any radio entitlement.

Capabilities this team can turn on (team cache): App Groups, AutoFill Credential Provider, Data Protection, Game Center, HealthKit, HomeKit, Increased Memory Limit, Inter-App Audio, Mac Catalyst, Maps, Wireless Accessory Configuration.

Radio entitlements that need the **paid** program. The source is `validTeamTypes` in `Xcode-beta.app/Contents/SharedFrameworks/DVTPortal.framework/.../DVTPortalCachedPortalCapabilities.json`, where none of these lists `XCODE_FREE_PROGRAM`:

| Entitlement | Capability | Who can get it |
| --- | --- | --- |
| `com.apple.developer.nfc.readersession.formats` (array of `NDEF`, `TAG`, `PACE`) | NFC Tag Reading | Paid, self-serve |
| `com.apple.developer.networking.wifi-info` (bool) | Access Wi-Fi Information | Paid, self-serve |
| `com.apple.developer.wifi-aware` (array of `Publish`, `Subscribe`) | Wi-Fi Aware | Paid, self-serve |
| `com.apple.developer.networking.multicast` | Multicast Networking | Paid, request form |
| `com.apple.developer.networking.HotspotHelper` | Hotspot Helper | Paid, request form |
| `com.apple.developer.networking.manage-thread-network-credentials` | Thread credentials | Paid |
| `com.apple.developer.nearbyinteraction.dltdoa` | NI DL-TDoA | Paid, development/ad hoc only |
| `com.apple.developer.sensorkit.reader.allow` (includes `ambient-light-sensor`) | SensorKit | Paid, request form (research) |

**What Spectra should do:** ship with **no radio entitlements**. Show NFC and Wi-Fi identity as **Locked** nodes whose explainer says "needs Apple Developer Program", and fall back to the model. Keep the code behind a `SpectraCapabilities` flag so it can be switched on later.

---

## 3. Feasibility matrix

| # | Item | Framework / key API | Live data | Permission (Info.plist) | Entitlement | Simulator (SIM) | Verdict |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | Cellular | CoreTelephony `serviceCurrentRadioAccessTechnology`; Network `PathReport.radioType` | RAT string per SIM; sub-6 vs mmWave on the data path | none | none | `[:]`, `dataServiceIdentifier = nil` | **Partial** (generation and type, no dBm) |
| 2 | Wi-Fi | Network `NWPathMonitor` (`linkQuality`, `isExpensive`, `isConstrained`, `isUltraConstrained`), `PathReport.radioType`; NetworkExtension `NEHotspotNetwork.fetchCurrent()` | 802.11 generation, link quality, RTT | none (NWPath); precise location for SSID | wifi-info (paid) for SSID/BSSID | `en0:wifi`, `linkQuality = unknown` | **Partial**; SSID locked |
| 3 | Bluetooth LE | CoreBluetooth scan with duplicates, `readRSSI()` | RSSI in dBm per advert, Tx power (if advertised) | `NSBluetoothAlwaysUsageDescription` | none | `state = 2 (.unsupported)`, no adverts | **Live** |
| 4 | UWB | NearbyInteraction `NISession` | Distance (m), direction (unit vector), angle | `NSNearbyInteractionUsageDescription` (+ camera for assist) | none (DL-TDoA paid) | caps: precise ✓, direction ✗, camera ✓, extended ✓ | **Live with a peer**, none solo |
| 5 | NFC | CoreNFC `NFCTagReaderSession` | Tag UID and type at 13.56 MHz | `NFCReaderUsageDescription` | nfc formats (paid) | `readingAvailable = false` | **Not available** to this team |
| 6 | GNSS | CoreLocation `CLLocationUpdate.liveUpdates()` | Fix, ±accuracy (m), ellipsoidal altitude | `NSLocationWhenInUseUsageDescription` | none | location services on; simulated fixes | **Partial** (no satellites or SNR) |
| 7 | Magnetometer | CoreMotion `startMagnetometerUpdates`, `CMDeviceMotion.magneticField` | µT, 3-axis, about 100 Hz (DEV?) | none (no prompt for CMMotionManager) | none | unavailable | **Live** |
| 8 | Camera as light meter | AVFoundation `iso`, `exposureDuration`, `lensAperture`, `deviceWhiteBalanceGains`; ARKit `ARLightEstimate` | EV, approximate lux, CCT in kelvin | `NSCameraUsageDescription` | none | no video device | **Live (estimated)** |
| 9 | Mic / speaker | AVFAudio `AVAudioEngine` + `installAudioTap` + `AVAudioSourceNode`; Accelerate FFT | PCM at 48 kHz | `NSMicrophoneUsageDescription` | none | works (Mac mic), `sampleRate = 48000` | **Live** |
| 10 | Accelerometer, gyro, barometer | CoreMotion | g, rad/s about 100 Hz; kPa about 1 Hz (DEV?) | `NSMotionUsageDescription` (barometer) | none | unavailable | **Live** |
| 11 | LiDAR depth | ARKit `.sceneDepth`; AVFoundation `.builtInLiDARDepthCamera` | Depth map (m) and confidence | `NSCameraUsageDescription` | none | `ARWorldTrackingConfiguration.isSupported = false` | **Live** |
| 12 | Charging | UIKit `UIDevice.batteryState/batteryLevel` | Charging, full or unplugged; level 0 to 1 | none | none | `0 (.unknown)`, `-1.0` | **Partial** (wired and wireless look the same) |
| 13a | Bluetooth Channel Sounding | CoreBluetooth iOS 27 | distance (m) | Bluetooth key | none | `supports(.channelSounding) = false` | **Not on 15 Pro Max** (hardware) |
| 13b | Wi-Fi Aware | WiFiAware (iOS 26) | `WAPerformanceReport.signalStrength`, throughput | `WiFiAwareServices` | wifi-aware (paid) + paired device | `supportedFeatures = []` | **Not available** to this team |
| 13c | Thread / Matter | ThreadNetwork, HomeKit | credentials only, no RF data | `NSHomeKitUsageDescription` | Thread creds (paid); HomeKit (free) | — | **Not available** as RF |
| 13d | iBeacon | CoreLocation `startRangingBeacons(satisfying:)` | `CLBeacon.rssi` (dB), `accuracy` (m) | location key | none | — | **Live** (needs a beacon) |

---

## 4. Item by item

### 4.1 Cellular (CoreTelephony and Network)

**API (SDK, TC)**
- `CTTelephonyNetworkInfo().serviceCurrentRadioAccessTechnology: [String: String]?`, available iOS 12+, keyed by service id (one entry per SIM or eSIM line). `dataServiceIdentifier: String?` (iOS 13) names the line that carries data.
- Constants, all `NSString`: `CTRadioAccessTechnologyGPRS`, `Edge`, `WCDMA`, `HSDPA`, `HSUPA`, `CDMA1x`, `CDMAEVDORev0`, `CDMAEVDORevA`, `CDMAEVDORevB`, `eHRPD` and `LTE` (iOS 7), plus `CTRadioAccessTechnologyNRNSA` and `CTRadioAccessTechnologyNR` (iOS 14.1).
- Change events in iOS 27 Swift (TC):
  ```swift
  NotificationCenter.default.addObserver(of: String.self, for: .radioAccessTechnologyDidChange) {
      (msg: CTTelephonyNetworkInfo.RadioAccessTechnologyDidChangeMessage) async in msg.serviceIdentifier }
  ```
  The message's `Subject` is `String`, so you observe `String.self`, not the info object. The legacy `CTServiceRadioAccessTechnologyDidChangeNotification` still exists (iOS 12).
- **Carrier info is dead.** `serviceSubscriberCellularProviders` and `CTCarrier.carrierName`, `mobileCountryCode`, `mobileNetworkCode`, `isoCountryCode` and `allowsVOIP` are `API_DEPRECATED(ios(4.0, 16.0))`. The header says they return `"--"` or `"65535"` "at some point in the future". Don't use them.
- **No signal-strength API.** A grep for `signal|rssi|rsrp|bars|strength` across the CoreTelephony headers returns nothing.
- `CTSlicingManager.shared` (iOS 26.3, Swift only) offers `availableSliceAppCategories` (async throws), `activatePreferredSliceForCategory(_:)` and `activeSlices`. This is 5G network slicing. It throws `POSIXError.ENOTSUP` where unsupported. It's a curiosity node and untested.
- **Better data from the Network framework (SDK, TC):**
  - Open any `NWConnection`, call `startDataTransferReport()`, then `.collect(queue:)`.
  - Each `report.pathReports[i].radioType: NWInterface.RadioType?` (iOS 15) is `.cell(.lte | .dualConnectivity5G(.sub6GHz|.mmWave) | .standalone5G(.sub6GHz|.mmWave) | .wcdma | .gsm | .cdma | .evdo)`.
  - The same report carries `transportSmoothedRTT`, `transportMinimumRTT` and `transportRTTVariance` (seconds).
  - This is the only public way to tell **mmWave from sub-6** (DEV? that it is populated).

**Rates.** Event-driven only, on RAT change. Data-transfer reports are produced each time you collect them.

**Simulator (SIM).** `serviceCurrentRadioAccessTechnology = [:]` and `dataServiceIdentifier = nil`.

**Verdict.** Partial. Live: generation (2G/3G/4G/5G-NSA/5G-SA) and, on the data path, sub-6 vs mmWave plus RTT. Not available: band, ARFCN, dBm, bars.

**How Spectra should show it**
- A "Cellular" node badged **LIVE · RAT**, for example "5G NSA · sub-6 GHz".
- On the spectrum ruler, light up the **typical band range for that generation**, badged **TABLE** (SPEC):
  - LTE and NR FR1 bands span about 600 MHz to 6 GHz.
  - On US models, NR FR2 mmWave covers n258 (26 GHz), n261 (28 GHz) and n260 (39 GHz).
- Never draw a dBm needle. Live RTT can drive a "speed of light" readout: light covers about 300 km per ms.

### 4.2 Wi-Fi (NetworkExtension and Network)

**`NEHotspotNetwork` (SDK, TC)**
- Signature: `class func fetchCurrent(completionHandler: @escaping (NEHotspotNetwork?) -> Void)`, iOS 14, with an async form `await NEHotspotNetwork.fetchCurrent()`. Properties are `ssid`, `bssid` and `securityType: NEHotspotNetworkSecurityType` (`.open/.WEP/.personal/.enterprise/.unknown`, iOS 15).
- The header says it returns nil **unless** the app has `com.apple.developer.networking.wifi-info` **and** one of these four:
  - precise location authorization,
  - the current network was configured through `NEHotspotConfiguration`,
  - an active VPN configuration,
  - an active `NEDNSSettingsManager` configuration.
- **`signalStrength` (0.0–1.0) is declared in the `NEHotspotNetwork (HotspotHelper)` category.** `fetchCurrent`'s docs say the returned object "contains only valid SSID, BSSID and security type values", so **signalStrength is not populated** for normal apps.
- The HotspotHelper path (`NEHotspotHelper.register…`, `supportedNetworkInterfaces`) is `API_DEPRECATED("Use NEHotspotManager API", ios(9.0, 26.0))`. Its replacement, `NEHotspotManager` plus the `NEHotspotEvaluationProvider` and `NEHotspotAuthenticationProvider` app extensions (iOS 26), still needs `com.apple.developer.networking.HotspotHelper`, which is paid and granted on request.
- **For this team: locked.** Even with the paid program, it gives only SSID/BSSID, never RSSI.

**`NWPathMonitor` (SDK, TC, SIM). No entitlement and no prompt.**
- `NWPath.status`, `availableInterfaces` (`name`, plus `type` as `.wifi/.cellular/.wiredEthernet/.loopback/.other`), `usesInterfaceType(_:)` and `gateways`.
- `isExpensive` and `isConstrained` (iOS 13).
- **`isUltraConstrained`** (iOS 26).
- **`linkQuality: NWPath.LinkQuality`** (iOS 26): `.unknown/.minimal/.moderate/.good`. The C enum values are 0/10/20/30. The header says it is "a representation of the expected capabilities of the link layer… Do not use this value to gate connection attempts".
- No numeric quality and no RSSI in the Network framework. A grep for `rssi|signal` finds only `WiFiAware`'s performance report.
- `PathReport.radioType` gives `.wifi(.b/.a/.g/.n/.ac/.ax)`. There is no `.be` case, and 6 GHz Wi-Fi 6E still reports `.ax`, so the band can't be derived.
- The AsyncSequence form, `for await path in NWPathMonitor()`, is available from iOS 17.

**Rates.** `pathUpdateHandler` fires on change, not periodically. `linkQuality` presumably changes with it (DEV?).

**Simulator (SIM).** `status = satisfied`, `[en0:wifi]`, not expensive or constrained, `linkQuality = unknown`.

**Verdict.** Partial and live: Wi-Fi generation, link quality bucket and RTT. SSID, BSSID and channel are locked or not exposed.

**How Spectra should show it**
- A "Wi-Fi" node: "Wi-Fi 6 (802.11ax) · link: good · RTT 12 ms", badged **LIVE**.
- The band (2.4, 5 or 6 GHz) is a **user-selectable assumption**, badged **MODEL**, that feeds the antenna simulator. Default to 5 GHz.
- Explain inline that iOS doesn't publish Wi-Fi dBm.

### 4.3 Bluetooth LE (CoreBluetooth)

**API (SDK, TC)**
- Scan: `CBCentralManager(delegate:queue:)`, then `scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])`.
- The callback is `centralManager(_:didDiscover:advertisementData:rssi:)`, with `RSSI: NSNumber` in **dBm**. The header says "A value of 127 is reserved and indicates the RSSI was not available."
- Without duplicates, repeat sightings are coalesced. With duplicates on, the header says you get an event "every time the peripheral is seen, which may be many times per second".
- `advertisementData[CBAdvertisementDataTxPowerLevelKey] as? NSNumber` holds the advertised Tx power in dBm. It is often absent. When present, path loss = Tx − RSSI, which feeds a log-distance model.
- Also useful: `CBAdvertisementDataIsConnectable`, `CBAdvertisementDataLocalNameKey`, `CBAdvertisementDataManufacturerDataKey` and service UUIDs.
- Connected link: `peripheral.readRSSI()` → `peripheral(_:didReadRSSI:error:)` (iOS 8). The `RSSI` property and `peripheralDidUpdateRSSI` are deprecated (iOS 5–8).
- Background (header): only with the `bluetooth-central` background mode. The scan must name service UUIDs, and **AllowDuplicates is ignored**. Spectra should scan in the foreground only.
- `CBCentralManager.supports(.extendedScanAndConnect)` and, new in iOS 27, `.channelSounding` (raw value `1 << 10`, "hardware and region supports channel sounding").
- Channel Sounding API (iOS 27): `CBPeripheral.startChannelSoundingSession(CBChannelSoundingSessionConfiguration(role: .initiator))`, then `peripheral(_:didReceive: CBChannelSoundingProcedureResults?, error:)`, where `.distance` is in metres. Also `cancelChannelSoundingSession()` and `peripheral(_:didCompleteChannelSoundingSession:)`, plus errors `CBError.channelSoundingConfigurationFailed` (19) and `…ProcedureFailed` (20).
- NearbyInteraction can use it too: `NINearbyAccessoryConfiguration(bluetoothChannelSoundingIdentifier:previousBluetoothIdentifier:)` (iOS 27).
- On iPhone 15 Pro Max (Bluetooth 5.3, SPEC), expect `supports(.channelSounding) == false`. Show it as a "next-generation" node, badged **MODEL**.

**Rates (DEV?).**
- Adverts arrive at the peripheral's advertising interval: about 20 ms to 10 s, with Apple Continuity devices advertising often.
- iOS's scan duty cycle is undocumented. Expect roughly 1 to 30 callbacks per second per nearby device in the foreground. RSSI has 1 dB resolution and is noisy (±5–10 dB multipath fading).

**Permission.** `NSBluetoothAlwaysUsageDescription`. The legacy `NSBluetoothPeripheralUsageDescription` also appears in Xcode's list, but iOS 13+ uses the Always key. No entitlement.

**Simulator (SIM).** `CBCentralManager.state == .unsupported` (raw value 2), no adverts, `CBManager.authorization = .allowedAlways`.

**iBeacon (SDK).** CoreBluetooth does not deliver iBeacon frames. Use `CLLocationManager.startRangingBeacons(satisfying: CLBeaconIdentityConstraint)`, which gives `CLBeacon.rssi` (an average in dB), `accuracy` (1σ metres, "heavily subject to variations in an RF environment") and `proximity`.

**Verdict.** **Live.** This is Spectra's best real RF power signal at 2.4 GHz.

**How Spectra should show it**
- A "2.4 GHz neighbourhood" node: a live list of nearby advertisers as dots, with radius from RSSI.
- An **RSSI time series feeding the Fourier visualizer**, which shows multipath fading as you move the phone.
- A tap-to-fit **path-loss exponent n** (log-distance model, n of about 2 in free space and 2.7–4 indoors) that ties into the antenna simulator.

### 4.4 UWB (NearbyInteraction)

**API (SDK, TC)**
- `NISession.deviceCapabilities` (iOS 16) conforms to `NIDeviceCapability`, which has:
  - `supportsPreciseDistanceMeasurement`
  - `supportsDirectionMeasurement`
  - `supportsCameraAssistance`
  - `supportsExtendedDistanceMeasurement` (iOS 17)
  - `supportsDLTDOAMeasurement` (iOS 26)
  - `supportsBluetoothChannelSounding` (iOS 27)
- `NISession.isSupported` is deprecated as of iOS 16.
- **Peer session:**
  1. Read `session.discoveryToken`, which is an `NIDiscoveryToken` that conforms to `NSSecureCoding`.
  2. Exchange tokens out of band.
  3. Run `NINearbyPeerConfiguration(peerToken:)`.
  4. Optionally set `.isCameraAssistanceEnabled` (iOS 16). This creates or uses an `ARSession` through `setARSession(_:)`.
  5. Optionally set `.isExtendedDistanceMeasurementEnabled` (iOS 17, both peers must be capable).
- **Accessory session:** `NINearbyAccessoryConfiguration(data:)` or `(accessoryData:bluetoothPeerIdentifier:)` (iOS 16), and iOS 27's Channel Sounding initializer.
- Delegate: `session(_:didUpdate: [NINearbyObject])`. Fields:
  - `distance: Float?` in metres
  - `direction: simd_float3?` as a unit vector
  - `horizontalAngle: Float?` in radians (iOS 16)
  - `verticalDirectionEstimate` (`.same/.above/.below/.aboveOrBelow/.unknown`)
- `session.worldTransform(for:) -> simd_float4x4?` works with camera assistance.
- Convergence: `session(_:didUpdateAlgorithmConvergence:for:)`, with `.notConverged([Reason])` reasons `insufficientSignalStrength/HorizontalSweep/VerticalSweep/Movement/Lighting`.
- `updateMotionState(_:forObjectWithToken:)` is new in iOS 27.
- DL-TDoA (iOS 26): `NIDLTDOAConfiguration(networkIdentifier:)`, with measurements that expose `signalStrength`, `carrierFrequencyOffset` and more. It needs the paid `nearbyinteraction.dltdoa` entitlement and a UWB anchor network, so it is out.

**Capabilities (SIM, both simulators):** precise ✓, direction ✗, camera assist ✓, extended distance ✓, DL-TDoA ✗, Channel Sounding ✗. On the real 15 Pro Max:
- `supportsDirectionMeasurement` is expected to be **false**. iPhone 14 and later get direction through camera assistance (`horizontalAngle` and `worldTransform`) instead of raw `direction`.
- Extended distance is expected to be true (second-generation UWB chip, SPEC).
- Read these flags at runtime (DEV?).

**Permission.** `NSNearbyInteractionUsageDescription`, plus `NSCameraUsageDescription` if using camera assistance. `NSNearbyInteractionAllowOnceUsageDescription` also exists (legacy). No entitlement for peer or accessory sessions.

**Demo without another device.** None is possible: UWB ranging needs a second UWB radio. Practical options:
1. **His Apple Watch** (`Watch7,10` in `devicectl`, a Series 9-or-later-class watch with UWB). Write a tiny watchOS companion that runs `NISession` (watchOS 7.3+) and swaps tokens over WatchConnectivity.
2. A second iPhone 11 or later, swapping tokens over MultipeerConnectivity. That needs `NSLocalNetworkUsageDescription` and `NSBonjourServices`, but no entitlement.
3. A UWB dev kit (Qorvo or NXP) that implements Apple's NI accessory protocol.
4. For development, the simulator reports capabilities, and Apple's NI peer sample is documented to run across two simulators (DEV?: not verified here).

**Rates (DEV?).** Typically about 10–30 Hz updates with roughly 10 cm-class distance precision.

**Verdict.** Live **with a peer**, otherwise capability-only.

**How Spectra should show it**
- A "UWB 6.5–8 GHz" node badged **NEEDS PEER**: SPEC channels 5 (6489.6 MHz) and 9 (7987.2 MHz), 499.2 MHz bandwidth.
- When live, show distance, time of flight (t = d/c, about 3.3 ns per metre) and an impulse-vs-narrowband Fourier comparison. That is the ideal bridge to the Fourier visualizer, because a short pulse has a wide spectrum.

### 4.5 NFC (CoreNFC)

**API (SDK, TC)**
- `NFCTagReaderSession(configuration: .init(pollingOption: [.iso14443, .iso15693, .iso18092]), delegate:queue:)`. This is iOS 26.4's `NFCTagReaderSession.Configuration`; `init?(pollingOption:delegate:queue:)` is deprecated in 26.4.
- Also `restartPolling(configuration:)` and `NFCNDEFReaderSession(delegate:queue:invalidateAfterFirstRead:)`.
- `NFCReaderSession.readingAvailable` is a class property.
- Exposed per tag (`NFCTag` enum):

  | Tag type | Fields |
  | --- | --- |
  | `.miFare` | `identifier` (UID), `mifareFamily` (`.ultralight/.plus/.desfire/.unknown`), `historicalBytes` |
  | `.iso7816` | `identifier`, `initialSelectedAID`, `historicalBytes`, `applicationData`, `supportsPACE` (iOS 26.4) |
  | `.iso15693` | `identifier`, `icManufacturerCode`, `icSerialNumber` |
  | `.feliCa` | `currentIDm`, `currentSystemCode` |

- No field strength, no RSSI and no carrier data. 13.56 MHz is implicit (SPEC).

**Permission.** `NFCReaderUsageDescription`. ISO 7816 also needs the Info.plist key `com.apple.developer.nfc.readersession.iso7816.select-identifiers`, and FeliCa needs `…felica.systemcodes`.

**Entitlement.** `com.apple.developer.nfc.readersession.formats` with `TAG` and/or `NDEF` (or `PACE`). The header says that without it the session invalidates with `NFCReaderErrorSecurityViolation`.

**Simulator (SIM).** `readingAvailable = false`.

**Verdict.** **Not available to this team** (paid-only capability). The hardware supports it.

**How Spectra should show it.** Show a **Locked** 13.56 MHz node. The simulator side should model inductive near-field coupling: a loop antenna, a 1/r³ field fall-off and load modulation. Unlock it if he enrolls.

### 4.6 GNSS (CoreLocation)

**API (SDK, TC)**
- `for try await update in CLLocationUpdate.liveUpdates(.default)`. Configurations are `.default/.automotiveNavigation/.otherNavigation/.fitness/.airborne`. Diagnostics include `accuracyLimited`, `locationUnavailable` and `authorizationDenied`.
- The classic `CLLocationManager` still works.
- `CLLocation` fields, now declared in `_LocationEssentials`:

  | Field | Notes |
  | --- | --- |
  | `coordinate` | |
  | `altitude` | above mean sea level |
  | `ellipsoidalAltitude` | WGS-84, iOS 15 |
  | `horizontalAccuracy`, `verticalAccuracy` | metres; negative means invalid |
  | `speed`, `speedAccuracy` | m/s |
  | `course`, `courseAccuracy` | degrees |
  | `floor` | |
  | `timestamp` | |
  | `sourceInformation` | `isSimulatedBySoftware`, `isProducedByAccessory` (iOS 15) |

- `accuracyAuthorization` (`.fullAccuracy/.reducedAccuracy`) and `requestTemporaryFullAccuracyAuthorization(withPurposeKey:)`, which uses the `NSLocationTemporaryUsageDescriptionDictionary` key.
- **No satellite count, constellation, SNR, or NMEA anywhere.** A grep for `satellite|gnss|nmea|constellation` in CoreLocation and `_LocationEssentials` returns nothing.

**Heading (SDK).**
- `CLLocationManager.headingAvailable()`, `startUpdatingHeading()` and `headingFilter = kCLHeadingFilterNone`.
- `CLHeading` fields: `magneticHeading`, `trueHeading` (needs location), `headingAccuracy` (degrees), raw geomagnetic `x/y/z` (the header says only "raw value"; Apple docs say µT), and `timestamp`.
- iOS 27: `headingOrientation` is deprecated in favour of `headingBody: CLBodyIdentifiable?`. Pass the SwiftUI host `UIView`.

**Rates (DEV?).** About 1 Hz GNSS fixes. Heading is event-driven, up to the motion rate.

**Permission.** `NSLocationWhenInUseUsageDescription`.

**Simulator (SIM).** `locationServicesEnabled = true` and `headingAvailable = false`. Fixes come from Xcode or `simctl location`.

**Verdict.** Partial and live: fix quality, altitude and geoid separation. Satellites aren't exposed.

**How Spectra should show it**
- An "L-band 1.2–1.6 GHz" node (SPEC: GPS L1 and Galileo E1 at 1575.42 MHz, L5 and E5a at 1176.45 MHz; 15 Pro Max is dual-frequency). It shows an uncertainty circle that follows `horizontalAccuracy` live.
- Show `ellipsoidalAltitude − altitude` as "geoid height".
- Any sky plot must be a **MODEL** badge (computed from almanac or TLE), never presented as receiver data.

### 4.7 Magnetometer (CoreMotion)

**API (SDK, TC)**

Raw stream:
- `CMMotionManager.isMagnetometerAvailable`, `magnetometerUpdateInterval: TimeInterval`, `startMagnetometerUpdates(to:withHandler:)`.
- Delivers `CMMagnetometerData.magneticField: CMMagneticField {x, y, z}` in **µT**. It is raw and *includes device bias*.

Calibrated stream:
- `startDeviceMotionUpdates(using: .xMagneticNorthZVertical, to:withHandler:)` delivers `CMDeviceMotion.magneticField: CMCalibratedMagneticField { field, accuracy }`. Accuracy is `.uncalibrated/.low/.medium/.high`.
- The header says it is the "total magnetic field … without device bias (Earth's magnetic field plus surrounding fields…)".

Also on `CMDeviceMotion`:
- `heading` (iOS 11)
- **`headingAccuracy`** (iOS 27)
- iOS 27's **`deviceMotionBody`**

**Max rate.** The header says the interval "is capped to certain minimum and maximum values. The maximum value is determined by the maximum frequency supported by the hardware… check the timestamps". No number is published.
- Plan for **about 100 Hz** (practical iPhone ceiling; DEV?).
- **Measure fs from `CMLogItem.timestamp` deltas and display it.**
- Gyre requests 1/120 s for device motion; whether 120 Hz is honoured isn't recorded.
- `CMBatchedSensorManager` (800 Hz accel, 200 Hz device motion) is **watchOS 10 only**, so it can't be used here.

**Mains aliasing, assuming fs = 100 Hz.** The alias is f_a = |f − k·fs| for the nearest integer k.

| Source (mains region) | Seen at | Why |
| --- | --- | --- |
| 60 Hz fundamental (US) | **40 Hz** | 100 − 60 |
| 120 Hz (US 2nd harmonic: rectifiers, LED drivers) | **20 Hz** | 120 − 100 |
| 180 Hz | **20 Hz** | 200 − 180 |
| 300 Hz | **0 Hz (DC)** | 300 − 300 |
| 50 Hz fundamental | **50 Hz, the Nyquist frequency** | Amplitude ∝ \|cos φ\|, phase-dependent. With fs or mains drift it becomes a slow beat at \|2·50 − fs\|. |
| 100 Hz (50 Hz region's 2nd harmonic) | **0 Hz (DC)** | 100 − 100 |

If the chip low-pass filters or decimates internally (unknown, DEV?), AC amplitude will be attenuated, possibly to invisibility.

Expected magnitudes (field physics, approximate):
- Earth's field: 25–65 µT.
- Room background AC: about 0.01–0.2 µT.
- A few cm from a transformer or power brick: 1–10+ µT.

So you'll see AC only right next to sources.

**Permission and entitlement.** None for `CMMotionManager`: no prompt and no Info.plist key.

**Simulator (SIM).** Accelerometer, gyro, magnetometer and device motion are all `false`, and `availableAttitudeReferenceFrames = 0`.

**Verdict.** **Live** for DC and quasi-static fields (compass, magnets, MagSafe). **Partial** for 50/60 Hz: a near-source detector whose spectral peak is aliased.

**How Spectra should show it**
- An "ELF / magnetostatic" node badged **LIVE · fs = 99.8 Hz (measured)**.
- The Fourier view puts the measured peak next to a **folding diagram**: the true 60 Hz reflected about Nyquist to 40 Hz. Label it "you're seeing 60 Hz folded by sampling". Let users scrub a virtual fs to watch the alias move, using the same aliasing math as the Decompose instrument.
- Also map the static |B| to a field-arrow overlay, the way Gyre does.
- **MagSafe heuristic (DEV?).** A sudden large static field step together with `batteryState` flipping to `.charging` reads as "wireless charger attached". Badge it **INFERRED**.

### 4.8 Camera as a light sensor (AVFoundation and ARKit)

**API (SDK, TC). All are KVO-observable and readable in any mode.**

| Property | Units / notes |
| --- | --- |
| `AVCaptureDevice.iso` | Float |
| `exposureDuration` | CMTime |
| `lensAperture` | f-number |
| `exposureTargetOffset` | EV |
| `exposureTargetBias` | EV |
| `activeFormat.minISO/maxISO/minExposureDuration/maxExposureDuration` | format limits |

White balance:
- `deviceWhiteBalanceGains: AVCaptureWhiteBalanceGains` (R, G, B ≥ 1).
- `grayWorldDeviceWhiteBalanceGains`.
- `maxWhiteBalanceGain`.
- `temperatureAndTintValues(for:) -> AVCaptureWhiteBalanceTemperatureAndTintValues {temperature (K), tint (−150…+150)}`.
- `chromaticityValues(for:)` gives CIE xy.
- iOS 26 adds presets `.tungsten/.fluorescent/.daylight/.cloudy/.shadow`.

Per-frame metadata: `kCGImagePropertyExifBrightnessValue` (APEX Bv) in sample-buffer EXIF attachments.

Torch as an emitter: `setTorchModeOn(level:) throws`, with `AVCaptureMaxAvailableTorchLevel`. Thermal limits can refuse the request.

ARKit `ARLightEstimate`:
- `ambientIntensity`, where the header says "close to 1000" in a well-lit room, ranging from 0 to about 2000.
- `ambientColorTemperature` in kelvin (6500 = white).

**Lux estimate (model).**
- EV100 = log2(N²/t) − log2(ISO/100) when `exposureTargetOffset ≈ 0`, or EV100 = Bv + 5.
- Then E ≈ 2.5·2^EV100 lux (incident-meter constant C = 250).
- Uncalibrated, expect ±30–50%. Offer a one-tap calibration against a known lamp. Read `lensAperture` at runtime; the main lens is about f/1.78 (SPEC, DEV?).

**Ambient-light sensor.** No public live API. SensorKit's `SRAmbientLightSample.lux` and `chromaticity` need the research entitlement (paid, by request), and the data is delayed. Not available.

**Near-IR (uncertain).**
- The rear cameras have IR-cut filters, so 850–940 nm (TV remotes, Face ID or LiDAR emitters) is mostly blocked.
- Front cameras on many iPhones show remote-control LEDs faintly. Whether the 15 Pro Max front camera does is **unverified**.
- The TrueDepth IR camera is **not** exposed as an image stream, only as depth data.
- Spectra should make it an **experiment** ("point a TV remote at the selfie camera and press a button. Do you see it?") with user confirmation, not a live claim.

**Flicker (technique, DEV?).** With a short exposure (≤ 1/1000 s), 2×-mains lamp flicker (100 or 120 Hz) appears as rolling-shutter bands. An FFT over row means detects it. Row readout time isn't published, so calibrate the frequency axis against a known 120 Hz source.

**Permission.** `NSCameraUsageDescription`.

**Simulator (SIM).** `AVCaptureDevice.default(for: .video) == nil`, and ARKit isn't supported.

**Verdict.** Live (estimated lux and CCT).

**How Spectra should show it.** A "Visible 380–750 nm" node.
- Live CCT drives a Planck-curve match on the Spectrum tuner, which already draws Planck curves for thermal sources: "your room ≈ 3100 K blackbody".
- Lux appears as a **MODEL**-badged estimate.

### 4.9 Microphone and speaker (AVFAudio and Accelerate)

**API (SDK, TC). iOS 27 deprecations are verified in the headers:**
- `installTap(onBus:bufferSize:format:block:)` is `API_DEPRECATED_WITH_REPLACEMENT(…, ios(8.0, 27.0))`.
  - Swift replacement (iOS 27): `try node.installAudioTap(onBus: 0, bufferSize: 1024, format: fmt) { (buf: AVReadOnlyAudioPCMBuffer, when: AVAudioTime) in … }`.
  - Read samples with `if case .float(let span) = buf.channelData(0) { … }`. `ChannelData` is `.int16/.int32/.float(Span<…>)` and non-escapable, so copy out inside the closure.
  - `AVAudioPCMBuffer(copying:)` converts.
- `connect(_:to:format:)` is deprecated in 27; use **`try engine.connectNode(_:to:format:)`**. Also `connectNode(_:to:fromBus:toBus:format:)` and `connectNode(_:to:fromBus:format:)`.
- `AVAudioNode.auAudioUnit` is deprecated in 27 in favour of `withAUAudioUnit { }`.
- Tone generation: `AVAudioSourceNode { … }` (TC).
- FFT:
  - `vDSP.FFT<DSPSplitComplex>(log2n:radix:ofType:)` (not deprecated).
  - `vDSP.DiscreteFourierTransform<Float>(count:direction:transformType:ofType:) throws` (iOS 15).
  - `vDSP.DFT` is deprecated in favour of `DiscreteFourierTransform`.

**Rates.** `AVAudioSession.sampleRate = 48000` (SIM; the device is expected to match), so Nyquist is 24 kHz. The built-in speaker and mic respond to roughly 20 Hz–20 kHz. 18–20 kHz chirps enable sonar or Doppler demos (DEV? for response).

**Permission.** `NSMicrophoneUsageDescription`. Use the `.playAndRecord` or `.measurement` mode for a flat response.

**Simulator.** Works through the Mac's mic.

**Verdict.** **Live**, and the most precise Fourier source.

**How Spectra should show it**
- An "Acoustic analogue" node. Sound isn't EM, so badge it "analogy".
- The live scope and FFT are the Fourier visualizer's reference input.
- A transformer's **120 Hz acoustic hum** (2× mains, magnetostriction) connects audio to the magnetometer's aliased 40 Hz.
- The speaker can play the antenna simulator's carrier, scaled down (spectra-lab already maps 15 decades onto 4 octaves).

### 4.10 Accelerometer, gyroscope, barometer (CoreMotion)

**API (SDK)**
- `accelerometerUpdateInterval` and `gyroUpdateInterval` are capped to hardware like the magnetometer. Data are `CMAcceleration` in g and `CMRotationRate` in rad/s.
- `startDeviceMotionUpdates(using:)` with `.xArbitraryZVertical`, `.xArbitraryCorrectedZVertical`, `.xMagneticNorthZVertical` or `.xTrueNorthZVertical`.
- Barometer:
  - `CMAltimeter.isRelativeAltitudeAvailable()` and `startRelativeAltitudeUpdates(to:withHandler:)` give `CMAltitudeData.pressure` (kPa) and `relativeAltitude` (m).
  - `isAbsoluteAltitudeAvailable()` and `startAbsoluteAltitudeUpdates` (iOS 15) give `altitude`, `accuracy` and `precision` (m).
  - `CMAmbientPressureData` (pressure plus temperature) and `CMRecordedPressureData` (iOS 12) are declared, but no public iOS method delivers them live. `CMAltimeter` and `CMSensorRecorder` have no pressure start call, so use `CMAltitudeData.pressure`.

**Rates (DEV?).** About 100 Hz for accelerometer and gyro. Barometer about 1 Hz.

**Permission.** `NSMotionUsageDescription` (CMAltimeter prompts; Gyre already uses it). Raw accelerometer and gyro need no prompt.

**Simulator (SIM).** All unavailable. Simulate them as Gyre does (`-simSway`).

**Verdict.** **Live.**

**How Spectra should show it.** These are mostly "tilt the antenna" inputs: phone attitude rotates the simulated dipole and its radiation pattern (polarization mismatch, cos²). Accelerometer vibration spectra are a second Fourier source.

### 4.11 LiDAR and ARKit depth

**API (SDK).**
- `ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)` / `.smoothedSceneDepth` (iOS 14). `ARFrame.sceneDepth: ARDepthData?` has `depthMap` (CVPixelBuffer, Float32 **metres**) and `confidenceMap` (`ARConfidenceLevel.low/.medium/.high`).
- `supportsSceneReconstruction(_:)` for meshes.
- AVFoundation `.builtInLiDARDepthCamera` (iOS 15.4) for `AVCaptureDepthDataOutput`.
- The resolution, 256×192 at frame rate, comes from Apple's docs (not stated in the header; DEV?).

**Permission.** `NSCameraUsageDescription`.

**Simulator (SIM).** `ARWorldTrackingConfiguration.isSupported = false`.

**Verdict.** **Live.**

**How Spectra should show it.** A "near-IR time-of-flight" node: point at a wall and show d plus the round trip 2d/c (1 m gives 6.67 ns). It's the optical twin of UWB ranging. The emitter wavelength is unpublished, so badge it "near-IR".

### 4.12 Charging state (MagSafe / Qi)

**API (SDK).**
- `UIDevice.current.isBatteryMonitoringEnabled = true`, then `batteryState` (`.unknown/.unplugged/.charging/.full`) and `batteryLevel` (0–1, or −1 if unknown).
- Notifications: `UIDevice.batteryStateDidChangeNotification` and `batteryLevelDidChangeNotification`.
- No wireless-vs-wired, MagSafe, Qi, or power API exists (grep across UIKit and Foundation). `ProcessInfo.thermalState` is the only other power-adjacent signal.

**Simulator (SIM).** State `.unknown` and level `-1.0`.

**Verdict.** Partial: the charging flag only.

**How Spectra should show it.** An "inductive power" node. Qi BPP runs at about 110–205 kHz; the MagSafe and Qi2 frequency is uncertain, so badge it TABLE with a caveat. The node goes **INFERRED** live when the magnetometer step and `.charging` coincide.

### 4.13 Other radio-related public APIs

**Wi-Fi Aware (`WiFiAware.framework`, iOS 26, Swift only; SDK).**
- `WACapabilities.supportedFeatures.contains(.wifiAware)`.
- Publish and subscribe through `NetworkListener` / `NetworkBrowser` with `.wifiAware(…)`, using paired devices only (pairing through DeviceDiscoveryUI's `DDDevicePairingAccess`).
- `WAPerformanceReport` has `signalStrength: Double?`, `throughputCeiling/Capacity` and `transmitLatency`. The iOS 27 `WAPerformanceForecast` has the same.
- Needs `com.apple.developer.wifi-aware` (paid), the `WiFiAwareServices` Info.plist dictionary (invalid names crash the app, per the swiftdoc), and a second device.
- SIM: `[]`, logging "The simulator does not support peer to peer Wi-Fi".
- **Not available.**

**WiFiInfrastructure.framework (iOS 26.2–26.4).** `WINetworkSharingProvider`, `WIChannel` (`.band24GHz/.band5GHz/.band6GHz`) and `AccessoryScanResult.signalStrength`. This is for sharing Wi-Fi credentials with an **AccessorySetupKit accessory**, the scan results come *from the accessory*, and it needs `com.apple.developer.wifi-infrastructure` (paid). **Not useful.**

**Thread.** `THClient` (iOS 15) has `allCredentials()`, `preferredCredentials()` and, new in iOS 27, `enableCredentialSharingMode`. `THCredentials` exposes `channel`, `panID`, `extendedPANID` and the network name. This needs `manage-thread-network-credentials` (paid). There's no radio telemetry. HomeKit is available to the free team, but it exposes no link or RF data. **Not available as RF.**

**SensorKit ambient light.** Paid and research-only, see §4.8.

**Proximity sensor.** `UIDevice.proximityMonitoringEnabled` and `proximityState: Bool` (an IR proximity sensor). Enabling it blanks the screen when covered, so it isn't worth using.

---

## 5. Live sources on the spectrum (for the node graph)

| Node | Frequency / wavelength | Live signal | Badge |
| --- | --- | --- | --- |
| Earth / static B | DC | \|B\| µT, vector | LIVE |
| Mains field | 50/60 Hz (aliased to 50/40 Hz at fs ≈ 100 Hz) | magnetometer PSD peak | LIVE (aliased) |
| Acoustic analogue | 20 Hz–24 kHz | mic FFT | LIVE (analogy) |
| Qi / MagSafe | ~110–205 kHz (SPEC; MagSafe and Qi2 uncertain) | charging + B step | INFERRED |
| NFC | 13.56 MHz | — | LOCKED (paid) |
| Cellular 4G/5G FR1 | ~0.6–6 GHz (SPEC) | RAT, sub-6 vs mmWave, RTT | LIVE (category) |
| GNSS | L5/E5a 1176.45 MHz, L1/E1 1575.42 MHz | ±accuracy, altitude | LIVE (quality) |
| BLE | 2402–2480 MHz, 40 × 2 MHz channels | RSSI dBm per device | LIVE |
| Thread | 2405–2480 MHz (802.15.4 ch 11–26) | — | NOT EXPOSED |
| Wi-Fi | 2.4 / 5 / 6 GHz | 802.11 generation, link quality, RTT | LIVE (category) |
| UWB | ch 5 6489.6 MHz, ch 9 7987.2 MHz | distance and direction with a peer | NEEDS PEER |
| 5G FR2 (US) | n258/n261/n260: 26/28/39 GHz | `.mmWave` path flag | LIVE (category) |
| Near-IR (LiDAR / Face ID) | ~850–940 nm (uncertain) | LiDAR depth → ToF | LIVE (depth) |
| Visible | 380–750 nm | lux estimate, CCT (K) | LIVE (estimated) |

The loop the request describes is: antenna simulator (generation and style) → its carrier frequency lands on this table → the matching **live** node (if any) streams into the Fourier visualizer → the result feeds back as the simulator's "observed" input. Use BLE RSSI fading, NI distance, mic audio or the magnetometer, depending on the band.

## 6. Info.plist / XcodeGen block (no entitlements file needed)

```yaml
info:
  properties:
    NSBluetoothAlwaysUsageDescription: "Spectra listens for nearby Bluetooth radios to show their signal strength live."
    NSLocationWhenInUseUsageDescription: "Spectra shows how precisely satellites are locating you, and true north."
    NSMotionUsageDescription: "Spectra reads the barometer to show air pressure."
    NSCameraUsageDescription: "Spectra uses the camera as a light meter and LiDAR to time light's round trip."
    NSMicrophoneUsageDescription: "Spectra turns sound into a live Fourier spectrum. Nothing is recorded or kept."
    NSNearbyInteractionUsageDescription: "Spectra measures distance to your other device with ultra wideband radio."
    NSLocalNetworkUsageDescription: "Spectra finds your other device on the local network to start ultra wideband ranging."  # only if peer UWB via Multipeer
    NSBonjourServices: ["_spectra-ni._tcp"]                                                  # only if peer UWB via Multipeer
    # Later, with a paid team: NFCReaderUsageDescription; entitlements nfc.readersession.formats [TAG], networking.wifi-info
```

None of the frameworks above needs a background mode. Start sensors only while `scenePhase == .active` and the relevant instrument is on screen, the same way spectra-lab renders only the selected instrument.

## 7. Presentation rules carried over from spectra-lab, Gyre and Orbitals

- Extend spectra-lab's **table / model** provenance badges with **live**, **inferred**, **sim**, **locked** and **needs peer**. Every number states which kind it is, and live readouts show their measured rate and units.
- **Simulator parity, Gyre-style.** Define a `SensorSource` protocol with `Live…` and `Simulated…` implementations, chosen when `isAvailable` is false or a launch argument is set. In the Simulator only the mic, NWPathMonitor and simulated location are real.
- **A "Sensor census" debug screen** to run first on the iPhone. It logs the achieved rate for the magnetometer, accelerometer, gyro and device motion (from timestamps); `NISession.deviceCapabilities`; `CBCentralManager.supports(.channelSounding)`; whether `PathReport.radioType` and `linkQuality` are populated; `AVAudioSession.sampleRate`; and `lensAperture`. This turns every **DEV?** in this file into a measured fact.

## 8. Open questions to settle on the device

1. The magnetometer's actual top rate, and whether 60 Hz near a power brick shows up at about 40 Hz or is filtered away.
2. Whether `NWPath.linkQuality` and `PathReport.radioType` are populated on iOS 27.2 for both Wi-Fi and cellular.
3. Whether `supportsDirectionMeasurement` is false and `supportsExtendedDistanceMeasurement` is true on the 15 Pro Max, and whether the paired Watch7,10 converges with camera assistance.
4. BLE callback rate per device with duplicates on (foreground).
5. Whether the front camera sees a TV remote's IR LED.
6. Whether `CTSlicingManager.availableSliceAppCategories` returns anything on his carrier, or throws.
