import SwiftUI

extension Color {
  /// A spectra-lab THEME / Core hex string ("#61b3ff").
  init(spectraHex hex: String) {
    let v = Spectrum.rgb(hex: hex)
    self.init(red: v.x, green: v.y, blue: v.z)
  }
}

/// A glass segmented control with one button per item (explicit selection, a selection haptic,
/// an identifier per segment `<id>-<item.id>`). Wraps into a grid when the row does not fit
/// (large Dynamic Type).
struct GlassSegmented<Item: Identifiable & Equatable>: View {
  let items: [Item]
  let selected: Item?
  var id: String
  var tint: (Item) -> Color = { _ in Theme.phosphor }
  var dimmed: (Item) -> Bool = { _ in false }
  let title: (Item) -> String
  var accessibilityTitle: ((Item) -> String)? = nil
  let action: (Item) -> Void

  @Environment(\.dynamicTypeSize) private var typeSize

  var body: some View {
    GlassEffectContainer(spacing: 6) {
      if typeSize.isAccessibilitySize {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 6)], spacing: 6) { buttons }
      } else {
        ViewThatFits(in: .horizontal) {
          HStack(spacing: 4) { buttons }
          LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 6)], spacing: 6) { buttons }
        }
      }
    }
  }

  @ViewBuilder private var buttons: some View {
    ForEach(items) { item in
      let on = item == selected
      Button {
        guard item != selected else { return }
        Haptics.shared.selection()
        action(item)
      } label: {
        Text(title(item))
          .font(.subheadline.weight(on ? .semibold : .medium))
          .lineLimit(1)
          .minimumScaleFactor(0.7)
          .foregroundStyle(on ? Theme.text : (dimmed(item) ? Theme.muted.opacity(0.6) : Theme.muted))
          .frame(maxWidth: .infinity, minHeight: 36)
          .padding(.horizontal, 4)
          .contentShape(.rect)
      }
      .buttonStyle(.plain)
      .glassEffect(
        on ? .regular.tint(tint(item).opacity(0.32)).interactive() : .regular.interactive(),
        in: .rect(cornerRadius: 12)
      )
      .overlay {
        if on {
          RoundedRectangle(cornerRadius: 12).strokeBorder(tint(item).opacity(0.55), lineWidth: 1)
            .allowsHitTesting(false)
        }
      }
      .accessibilityLabel(accessibilityTitle?(item) ?? title(item))
      .accessibilityAddTraits(on ? .isSelected : [])
      .accessibilityIdentifier("\(id)-\(String(describing: item.id))")
    }
  }
}

/// One readout with a sub-line and its provenance badges (rule R4).
struct SpectrumReadoutRow: Identifiable, Equatable {
  var id: String { key }
  var key: String
  var value: String
  var sub: String
  var color: Color
  var provenance: [Provenance]
}

/// A readout cell: the foundation `Readout` look plus a muted sub-line and several badges.
struct SpectrumReadoutCell: View {
  let row: SpectrumReadoutRow

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 5) {
        Text(Self.caps(row.key))
          .font(Theme.readoutTitleFont)
          .foregroundStyle(Theme.muted)
          .lineLimit(1)
          .minimumScaleFactor(0.7)
        ProvenanceBadges(row.provenance, compact: true)
      }
      Text(row.value)
        .font(Theme.readoutValueFont)
        .monospacedDigit()
        .foregroundStyle(row.color)
        .lineLimit(1)
        .minimumScaleFactor(0.55)
      if !row.sub.isEmpty {
        Text(row.sub)
          .font(.caption2)
          .foregroundStyle(Theme.dim)
          .lineLimit(2)
          .minimumScaleFactor(0.8)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(row.key)
    .accessibilityValue(
      "\(row.value)\(row.sub.isEmpty ? "" : ", \(row.sub)"). \(Provenance.union(row.provenance).map { $0.badge.capitalized }.joined(separator: ", "))"
    )
  }
}

extension SpectrumReadoutCell {
  /// Instrument caps that keep a leading physics symbol as written: "f frequency" →
  /// "f FREQUENCY", "a₀ shown" → "a₀ SHOWN", "Ex₀" stays "Ex₀" (case carries meaning).
  static func caps(_ key: String) -> String {
    let parts = key.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
    guard let first = parts.first else { return key }
    let symbol = first.count <= 2 || first.unicodeScalars.contains { !($0.isASCII && CharacterSet.letters.contains($0)) }
    guard symbol else { return key.instrumentCaps }
    return parts.count > 1 ? "\(first) \(String(parts[1]).instrumentCaps)" : String(first)
  }
}

/// The readouts grid (two columns; one at accessibility sizes).
struct SpectrumReadoutGrid: View {
  let rows: [SpectrumReadoutRow]
  var columns = 2

  var body: some View {
    ReadoutGrid(columns: columns) {
      ForEach(rows) { SpectrumReadoutCell(row: $0) }
    }
    .accessibilityIdentifier("spectrum-readouts")
  }
}

/// The status line under the stage: the sub-band (or the instrument's own words) on the left,
/// the ionization class (or its state) on the right.
struct SpectrumStatusLine: View {
  let left: String
  let right: String
  var rightColor: Color = Theme.phosphor

  var body: some View {
    ViewThatFits(in: .horizontal) {
      HStack(alignment: .firstTextBaseline, spacing: 10) {
        leftText
        Spacer(minLength: 6)
        rightText
      }
      VStack(alignment: .leading, spacing: 4) {
        leftText
        rightText
      }
    }
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("spectrum-status")
  }

  private var leftText: some View {
    Text(left).font(.footnote).foregroundStyle(Theme.text.opacity(0.88)).fixedSize(horizontal: false, vertical: true)
  }

  private var rightText: some View {
    Text(right.instrumentCaps)
      .font(.system(.caption, design: .monospaced).weight(.semibold))
      .tracking(0.8)
      .foregroundStyle(rightColor)
      .lineLimit(1)
  }
}

/// A small monospaced tag drawn over a plot well (spectra-lab `.tag`).
struct StageTag: View {
  let text: String
  var color: Color = Theme.muted

  init(_ text: String, color: Color = Theme.muted) {
    self.text = text
    self.color = color
  }

  var body: some View {
    Text(text)
      .font(.system(size: 10, weight: .medium, design: .monospaced))
      .foregroundStyle(color)
      .lineLimit(2)
      .minimumScaleFactor(0.8)
      .padding(.horizontal, 6)
      .padding(.vertical, 3)
      .background(Theme.plotWell.opacity(0.72), in: .rect(cornerRadius: 6))
      .allowsHitTesting(false)
  }
}

/// A small glass icon button with a label for VoiceOver and an identifier.
struct SpectrumIconButton: View {
  let title: String
  let symbol: String
  let id: String
  var hint: String? = nil
  let action: () -> Void

  var body: some View {
    Button {
      Haptics.shared.tap()
      action()
    } label: {
      Image(systemName: symbol).font(.subheadline.weight(.semibold)).frame(width: 20, height: 20)
    }
    .buttonStyle(.glass)
    .buttonBorderShape(.circle)
    .accessibilityLabel(title)
    .accessibilityHint(hint ?? "")
    .accessibilityIdentifier(id)
  }
}

/// Identifiable wrappers for Core enums used by the segmented controls.
struct Choice<Value: Hashable>: Identifiable, Equatable {
  let value: Value
  let key: String
  var id: String { key }
}

extension SpectraState.Instrument {
  /// "01" … "05".
  var number: String {
    String(format: "%02d", (SpectraState.Instrument.allCases.firstIndex(of: self) ?? 0) + 1)
  }

  var symbol: String {
    switch self {
    case .scope: "waveform"
    case .tuner: "ruler"
    case .bench: "flask"
    case .decompose: "square.split.diagonal.2x2"
    case .lab: "chart.xyaxis.line"
    }
  }
}

/// Percent text for transmitted / reflected / absorbed fractions (spectra-lab `pct`).
enum SpectrumPercent {
  static func text(_ v: Double?) -> String {
    guard let v else { return "\u{2014}" }
    if v >= 0.995 && v < 1 { return ">99%" }
    if v > 0 && v < 0.005 { return "<1%" }
    return JSFormat.jsString(JSMath.round(v * 100)) + "%"
  }
}
