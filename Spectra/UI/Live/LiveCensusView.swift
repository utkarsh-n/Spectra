import SwiftUI

/// The sensor census (`sdk-sensors.md` §7, `gyre-integration.md` §11): every source's state,
/// badge, measured rate, streams, a Run switch, and the capability flags this iPhone
/// reports. Run it first on a new device: it turns every "measure on device" note into a
/// fact.
struct LiveCensusView: View {
  @Environment(AppModel.self) private var app

  static let owner = "census"

  var body: some View {
    List {
      Section {
        ForEach(SensorID.allCases) { id in
          CensusRow(source: app.live.source(id))
            .listRowBackground(Theme.panel)
        }
      } footer: {
        Text(
          "Rates are measured from the samples' own timestamps over the last two seconds. Switch a source on to measure it; flags marked “Not yet measured” fill in while it runs."
        )
      }
    }
    .scrollContentBackground(.hidden)
    .background(Theme.background)
    .navigationTitle("Sensor census")
    .navigationBarTitleDisplayMode(.inline)
    .accessibilityIdentifier("live-census")
    .onDisappear { app.live.releaseAll(by: Self.owner) }
  }
}

private struct CensusRow: View {
  let source: any LiveSource
  @Environment(AppModel.self) private var app

  var body: some View {
    let held = app.live.holders(of: source.id).contains(LiveCensusView.owner)
    let locked: Bool = {
      if case .locked = source.state { return true }
      return false
    }()
    // Switched off in Settings → Sensors: the hub refuses every start, so the Run switch would
    // flip and do nothing.
    let off = app.live.isSwitchedOff(source)
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 8) {
        Label(source.title, systemImage: source.symbol)
          .font(.subheadline.weight(.semibold))
        Spacer()
        ProvenanceBadge(source.provenance)
          .opacity(source.state == .idle ? 0.55 : 1)
        Toggle(
          "Run \(source.title)",
          isOn: Binding(
            get: { held },
            set: { on in
              Haptics.shared.selection()
              if on { app.live.acquire(source.id, by: LiveCensusView.owner) } else { app.live.release(source.id, by: LiveCensusView.owner) }
            })
        )
        .labelsHidden()
        .tint(Theme.phosphor)
        .disabled(locked || off)
        .accessibilityIdentifier("live-census-run-\(source.id.rawValue)")
      }
      Text(
        (source.state.isRunning
          // "event-driven" only for sources that are (Bluetooth), not for a rate not yet measured.
          ? [source.stateLabel, source.rateText, "\(source.streams.count) stream\(source.streams.count == 1 ? "" : "s")", source.primaryReadout]
          : [off ? "Off in Settings" : source.stateLabel])
          .compactMap { $0 }.joined(separator: " · ")
      )
      .font(.system(.caption, design: .monospaced))
      .monospacedDigit()
      .foregroundStyle(Theme.muted)
      if off {
        Text(SensorHub.switchedOffReason).font(.caption).foregroundStyle(Theme.muted)
      } else if let reason = source.state.reason {
        Text(reason).font(.caption).foregroundStyle(Theme.muted)
      }
      ForEach(source.capabilities) { flag in
        VStack(alignment: .leading, spacing: 1) {
          HStack(alignment: .firstTextBaseline) {
            Text(flag.name).font(.caption)
            Spacer(minLength: 8)
            Text(flag.text)
              .font(.system(.caption, design: .monospaced).weight(.medium))
              .foregroundStyle(color(flag.value))
              .multilineTextAlignment(.trailing)
          }
          if !flag.source.isEmpty {
            Text(flag.source).font(.system(.caption2, design: .monospaced)).foregroundStyle(Theme.dim)
          }
        }
        .accessibilityElement(children: .combine)
      }
    }
    .padding(.vertical, 4)
    // A container, so the row's id does not overwrite its Run switch's own id.
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("live-census-\(source.id.rawValue)")
  }

  private func color(_ v: CapabilityFlag.Value) -> Color {
    switch v {
    case .yes: Theme.phosphor
    case .no: Theme.ionizing
    case .unknown: Theme.dim
    case .text: Theme.text
    }
  }
}
