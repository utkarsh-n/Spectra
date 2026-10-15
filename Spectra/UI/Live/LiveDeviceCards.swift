import SwiftUI

// MARK: - 09 Charging

/// Battery state, thermal state, proximity, and the INFERRED wireless-charging marker:
/// charging that starts with a large static magnetic step is probably MagSafe/Qi.
struct ChargingCard: View {
  @Environment(AppModel.self) private var app

  var body: some View {
    let ch = app.live.charging
    let qi = RF.Numerology.Qi.bppEppRange
    let qiCentre = (qi.lowerBound + qi.upperBound) / 2
    let mpp = RF.Numerology.Qi.qi2MPP
    LiveCard(
      .charging, badges: [.inferred],
      actions: LiveCardActions(
        marker: ch.markers.first ?? SpectrumMarker(id: "live.qi", label: "Qi charging band", frequency: qiCentre, provenance: .table, tab: .live),
        scope: [LiveStreams.batteryLevel.id, LiveStreams.thermal.id], preset: nil, patch: (LiveStreams.batteryLevel.id, "Battery level"))
    ) {
      // Stacked at accessibility sizes (three across truncate to "BATT…", "Charg…").
      AdaptiveStack(spacing: 14) {
        VStack(alignment: .leading, spacing: 6) {
          Readout("Battery", value: ch.level.map { "\(Int($0.rounded())) %" } ?? "—", provenance: ch.provenance)
          LevelMeter(level: (ch.level ?? 0) / 100, color: ch.isCharging ? Theme.phosphor : Theme.amber)
            .frame(width: 120)
        }
        Readout("State", value: ["Unknown", "Unplugged", "Charging", "Full"][min(3, max(0, ch.batteryState))], provenance: ch.provenance)
        Readout("Thermal", value: ["Nominal", "Fair", "Serious", "Critical"][min(3, ch.thermal)], provenance: ch.provenance)
      }
      .fixedSize(horizontal: false, vertical: true)
      VStack(alignment: .leading, spacing: 4) {
        FactRow(title: "Qi power transfer", value: "\(Int(qi.lowerBound / 1000))–\(Int(qi.upperBound / 1000)) kHz", provenance: .table)
        FactRow(title: "Qi2 / MagSafe (MPP)", value: "≈ \(Int(mpp / 1000)) kHz", provenance: .table)
        FactRow(title: "Wavelength at \(Int(qiCentre / 1000)) kHz", value: SpectraFormat.wavelength(SpectrumMarker.lambda(forFrequency: qiCentre)), provenance: .table)
        FactRow(
          title: "Wireless charging", value: ch.isCharging ? (ch.magsafeLikely ? "Likely (field step + charging)" : "Can't tell") : "Not charging",
          provenance: .inferred)
      }
      // The simulated phone has no proximity sensor to switch on, and a phone without one
      // refuses monitoring: either way the switch is visibly off with its reason.
      let noProximity = ch.isSimulated || ch.proximitySupported == false
      GlassToggle(
        "Proximity sensor", isOn: proximityBinding(available: !noProximity), symbol: "hand.raised",
        subtitle: ch.isSimulated
          ? "The simulated phone has no proximity sensor to switch on."
          : ch.proximitySupported == false
            ? "This device has no proximity sensor."
            : "Blanks the screen while something covers the top of the phone.")
        .disabled(noProximity)
        .accessibilityIdentifier("live-charging-proximity")
      if let covered = ch.proximityCovered {
        FactRow(title: "Proximity", value: covered ? "Covered" : "Clear", provenance: ch.provenance)
      }
      Text(
        "iOS says only whether the battery is charging, never whether power comes by cable or by coil. A coil 4 cm across is about a fifty-thousandth of a 2 km wavelength: it couples through the near magnetic field, it does not radiate. Spectra calls it wireless only when charging starts with a ≥ 20 µT jump in the magnetometer (the MagSafe magnet ring), and badges that INFERRED."
      )
      .panelCaption()
    }
  }

  private func proximityBinding(available: Bool) -> Binding<Bool> {
    Binding(
      get: { available && app.live.settings.prefs.proximity },
      set: {
        app.live.settings.prefs.proximity = $0
        app.live.preferencesChanged()
      })
  }
}

// MARK: - 10 Motion

struct MotionCard: View {
  @Environment(AppModel.self) private var app

  var body: some View {
    let m = app.live.motion
    LiveCard(
      .motion, badges: [.analogy],
      actions: LiveCardActions(
        marker: nil, scope: LiveStreams.userAccel.map(\.id) + [LiveStreams.gyro[2].id], preset: "Vibration",
        patch: (LiveStreams.accel[2].id, "Accelerometer Z"))
    ) {
      ReadoutGrid(columns: 3) {
        Readout("Tilt", value: m.tilt.map { "\(Int($0.rounded()))°" } ?? "—", color: Theme.analogy, provenance: m.provenance)
        Readout("Pitch / roll", value: m.pitch.map { p in "\(liveWhole(p))° / \(liveWhole(m.roll ?? 0))°" } ?? "—", color: Theme.analogy, provenance: m.provenance)
        Readout("Vibration", value: m.vibrationRMS.map { "\(SpectraFormat.significant($0 * 1000, 2)) mg" } ?? "—", color: Theme.analogy, provenance: m.provenance)
      }
      StreamSparkline(stream: app.streams.stream(LiveStreams.userAccel[2].id), seconds: 5, color: Theme.analogy)
        .frame(height: 40)
      Text(
        "Accelerometer and gyroscope samples carry their own timestamps at the highest rate Core Motion honors (measured: \(liveRate(m.measuredRate))). Motion is mechanical, not electromagnetic; it steers the antenna patterns and the turntable experiment."
      )
      .panelCaption()
    }
  }
}

// MARK: - 11 Ultra wideband (NEEDS PEER)

struct UWBCard: View {
  @Environment(AppModel.self) private var app

  var body: some View {
    let u = app.live.uwb
    let caps = u.capabilities
    // NEEDS PEER comes from the channel while no peer answers; with the simulated peer
    // ranging, the card is SIM, not "needs a peer".
    LiveCard(
      .uwb, badges: [.table],
      actions: LiveCardActions(
        marker: u.markers.first, scope: [LiveStreams.uwbDistance.id, LiveStreams.uwbAzimuth.id], preset: nil,
        patch: (LiveStreams.uwbDistance.id, "UWB distance"))
    ) {
      ReadoutGrid(columns: 3) {
        Readout("Distance", value: liveValue(u.distance, 3, unit: "m"), provenance: u.provenance)
        Readout("Direction", value: u.azimuth.map { "\(liveWhole($0))°" } ?? "—", provenance: u.provenance)
        Readout("ToF", value: u.distance.map { "\(SpectraFormat.significant(RF.Numerology.UWB.timeOfFlight(distance: $0) * 1e9, 3)) ns" } ?? "—", provenance: .model)
      }
      if !u.converged { StatusChip(text: "SWEEP THE PHONE SIDEWAYS", detail: "not converged", color: Theme.amber) }
      StreamSparkline(stream: app.streams.stream(LiveStreams.uwbDistance.id), seconds: 20)
        .frame(height: 36)
    } model: {
      UWBModelFacts(caps: caps)
    }
  }
}

/// What UWB is, from the RF engine, plus this phone's capability flags.
private struct UWBModelFacts: View {
  let caps: [CapabilityFlag]

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      FactRow(title: "Channel 5 / 9", value: "\(SpectraFormat.frequency(RF.Numerology.UWB.channel5, digits: 5)) / \(SpectraFormat.frequency(RF.Numerology.UWB.channel9, digits: 5))", provenance: .table)
      FactRow(title: "Bandwidth", value: SpectraFormat.frequency(RF.Numerology.UWB.bandwidth, digits: 4), provenance: .table)
      FactRow(title: "Light time per meter", value: "\(SpectraFormat.significant(RF.Numerology.UWB.timeOfFlight(distance: 1) * 1e9, 4)) ns", provenance: .model)
      FactRow(title: "Range resolution c/2B", value: "\(SpectraFormat.significant(RF.Numerology.UWB.rangeResolution * 100, 3)) cm", provenance: .model)
      ForEach(caps.prefix(4)) { flag in
        FactRow(title: flag.name, value: flag.text)
      }
    }
    Text(
      "Ultra wideband times nanosecond pulses: a 499.2 MHz-wide channel resolves about 30 cm. Measuring needs a second UWB radio, such as an Apple Watch or another iPhone, running a peer session (NEEDS PEER). The flags above are what this iPhone reports."
    )
    .panelCaption()
  }
}

// MARK: - 12 NFC (LOCKED)

struct NFCCard: View {
  @Environment(AppModel.self) private var app

  var body: some View {
    let n = app.live.nfc
    let carrier = RF.Numerology.NFC.carrier
    LiveCard(
      .nfc, badges: [.table, .model],
      actions: LiveCardActions(marker: n.markers.first, scope: [LiveStreams.nfcTap.id], preset: nil, patch: nil)
    ) {
      Readout("Simulated tag", value: n.taps == 0 ? "Waiting" : "\(n.taps) tap\(n.taps == 1 ? "" : "s")", color: BandPalette.color(forFrequency: carrier), provenance: .sim)
    } model: {
      NFCModelFacts()
    }
  }
}

private struct NFCModelFacts: View {
  var body: some View {
    let carrier = RF.Numerology.NFC.carrier
    VStack(alignment: .leading, spacing: 4) {
      FactRow(title: "Carrier", value: SpectraFormat.frequency(carrier, digits: 4), provenance: .table)
      FactRow(title: "Wavelength", value: SpectraFormat.wavelength(SpectrumMarker.lambda(forFrequency: carrier)), provenance: .table)
      FactRow(title: "Bit rate (fc/128)", value: SpectraFormat.si(RF.Numerology.NFC.bitRate, unit: "bit/s", digits: 4), provenance: .table)
      FactRow(title: "Load-modulation subcarrier", value: SpectraFormat.frequency(RF.Numerology.NFC.subcarrier, digits: 4), provenance: .table)
    }
    Text(
      "NFC is a 13.56 MHz magnetic near field: the reader's loop and the tag's loop are a loosely coupled transformer a few centimeters apart, far inside the 22 m wavelength, so the coupling dies off within a hand's width. Reading tags needs a paid Apple developer team, so this card stays LOCKED and shows the model."
    )
    .panelCaption()
  }
}
