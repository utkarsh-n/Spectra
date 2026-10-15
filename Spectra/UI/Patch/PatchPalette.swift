import SwiftUI

/// The add-node palette: every catalogue node and the sensor shortcuts, grouped as Sources,
/// Process and Sinks. Tapping one adds it near the middle of the canvas.
struct PatchPalette: View {
  var onAdd: (PaletteItem) -> Void

  @Environment(AppModel.self) private var app
  @Environment(\.dismiss) private var dismiss
  /// The icon column grows with Dynamic Type (a fixed 28 pt let large icons cover the titles).
  @ScaledMetric(relativeTo: .body) private var iconWidth = 28.0

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: Theme.stackSpacing) {
          ForEach(NodeCategory.allCases) { category in
            VStack(alignment: .leading, spacing: 8) {
              Eyebrow(category.title.instrumentCaps)
              ForEach(NodeCatalog.palette.filter { $0.category == category }) { item in
                row(item)
              }
            }
          }
        }
        .padding(Theme.gutter)
      }
      .accessibilityIdentifier("patch-palette-scroll")
      .background(Theme.background)
      .navigationTitle("Add a node")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") {
            Haptics.shared.tap()
            dismiss()
          }
          .accessibilityIdentifier("patch-palette-cancel")
        }
      }
    }
    .presentationDetents([.medium, .large])
    .presentationDragIndicator(.visible)
  }

  /// Why an item cannot be added, if it cannot (LOCKED / NEEDS PEER sensors).
  private func blocked(_ item: PaletteItem) -> String? {
    guard let stream = item.stream, let sensor = PatchModel.sensor(forStream: stream) else { return nil }
    switch app.live.channel(sensor).state {
    case .locked(let why), .unavailable(let why): return why
    default: return nil
    }
  }

  /// The badges a new node of this kind will carry: a sensor shortcut is LIVE (SIM in the
  /// Simulator or under fakes), plus ANALOGY for sound, motion and air (SPEC-features §5:
  /// "Microphone (audio, LIVE/ANALOGY)"), not the empty badges of a bare Live stream node.
  private func badges(_ item: PaletteItem) -> [Provenance] {
    var sensor: SensorID?
    if let stream = item.stream { sensor = PatchModel.sensor(forStream: stream) }
    if item.kind == .motion || item.kind == .gyroscope { sensor = .motion }
    guard let sensor else { return item.kind.spec.provenance }
    var out = item.kind.spec.provenance + [app.live.channel(sensor).provenance]
    if [SensorID.microphone, .motion, .barometer].contains(sensor) { out.append(.analogy) }
    return Provenance.union([out])
  }

  private func row(_ item: PaletteItem) -> some View {
    let reason = blocked(item)
    return Button {
      Haptics.shared.success()
      onAdd(item)
      dismiss()
    } label: {
      HStack(alignment: .top, spacing: 12) {
        Image(systemName: item.symbol)
          .font(.body)
          .foregroundStyle(item.category == .sinks ? Theme.amber : Theme.phosphor)
          .frame(width: iconWidth)
        VStack(alignment: .leading, spacing: 3) {
          HStack(spacing: 6) {
            Text(item.title).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.text)
            ProvenanceBadges(badges(item), compact: true)
          }
          Text(reason ?? item.summary)
            .font(.caption)
            .foregroundStyle(reason == nil ? Theme.muted : Theme.ionizing)
            .fixedSize(horizontal: false, vertical: true)
        }
        Spacer(minLength: 0)
        Image(systemName: "plus.circle.fill").foregroundStyle(Theme.phosphor.opacity(reason == nil ? 0.9 : 0.3))
      }
      .padding(12)
      .frame(maxWidth: .infinity, alignment: .leading)
      .contentShape(.rect)
    }
    .buttonStyle(.plain)
    .glassEffect(.regular.interactive(), in: .rect(cornerRadius: Theme.chipRadius))
    .disabled(reason != nil)
    .accessibilityLabel(item.title)
    .accessibilityHint(reason ?? item.summary)
    .accessibilityIdentifier("patch-palette-\(item.id)")
  }
}
