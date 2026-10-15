import SwiftUI

/// Radio → Systems: a scrolling timeline of the RF catalog's cards (1G → 6G, Wi-Fi b → be,
/// Bluetooth, NFC, UWB, Qi, GNSS, FMCW radar, AM/FM/DAB/TV), filter chips, and whether this
/// iPhone has each radio. Selecting a card sets the shared system and opens Fourier.
struct RadioSystemsPage: View {
  let model: RadioModel
  @State private var expanded: Set<String> = []
  /// The timeline rail grows with the year label at large type sizes.
  @ScaledMetric(relativeTo: .caption2) private var railWidth = 38.0
  /// At accessibility sizes the rail keeps only its dots and the year moves into the card, so the
  /// cards keep the width.
  @Environment(\.dynamicTypeSize) private var typeSize
  /// The iPhone flag's text: 9 pt at the default size, up to 15 pt (like the provenance badges).
  @ScaledMetric(relativeTo: .caption2) private var flagSize: CGFloat = 9

  private var systems: [RF.RadioSystem] {
    RF.SystemsCatalog.all.filter { s in
      (model.filter.category.map { s.category == $0 } ?? true) && (!model.iPhoneOnly || s.iPhone != .no)
    }
  }

  var body: some View {
    // `RadioTab`'s ScrollViewReader, around the tab's ScrollView, scrolls to `systemsScrollTarget`.
    page
  }

  private var page: some View {
    let list = systems
    return VStack(alignment: .leading, spacing: Theme.stackSpacing) {
      VStack(alignment: .leading, spacing: 10) {
        ChoiceChips(
          items: RadioSystemFilter.allCases, selection: Binding(get: { model.filter }, set: { model.filter = $0 }),
          id: "radio-filter"
        ) { f in ChipLabel(title: f.title) }
        .padding(.horizontal, -Theme.gutter)
        GlassToggle(
          "Only radios in this iPhone", isOn: Binding(get: { model.iPhoneOnly }, set: { model.iPhoneOnly = $0 }),
          symbol: "iphone", subtitle: "iPhone 15 Pro Max (A2849), from the RF reference's §F")
        .accessibilityIdentifier("radio-iphone-only")
        Text("\(list.count) of \(RF.SystemsCatalog.all.count) systems · tap a card to simulate it in Fourier")
          .font(.caption)
          .foregroundStyle(Theme.muted)
      }
      ForEach(groups(list), id: \.0) { category, items in
        VStack(alignment: .leading, spacing: 0) {
          categoryTitle(category)
            .padding(.bottom, 12)
          ForEach(Array(items.enumerated()), id: \.element.id) { index, system in
            timelineRow(system, last: index == items.count - 1)
          }
        }
      }
      if list.isEmpty {
        ContentUnavailableView("No systems", systemImage: "antenna.radiowaves.left.and.right", description: Text("No system matches these filters."))
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .onAppear { model.setVisible(.systems, true) }
    .onDisappear { model.setVisible(.systems, false) }
  }

  /// A numbered timeline section title in the panel style ("02 WI-FI"); the number is the
  /// category's place in the catalog, so it stays put when a filter hides other sections.
  private func categoryTitle(_ c: RF.SystemCategory) -> some View {
    let index = (RF.SystemCategory.allCases.firstIndex(of: c) ?? 0) + 1
    return HStack(spacing: 8) {
      Text(String(format: "%02d", index)).foregroundStyle(Theme.phosphor)
      Text(c.displayName.instrumentCaps).tracking(2).lineLimit(1).minimumScaleFactor(0.7)
    }
    .font(Theme.panelTitleFont)
    .foregroundStyle(Theme.muted)
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(.isHeader)
  }

  private func groups(_ list: [RF.RadioSystem]) -> [(RF.SystemCategory, [RF.RadioSystem])] {
    RF.SystemCategory.allCases.compactMap { c in
      let items = list.filter { $0.category == c }
      return items.isEmpty ? nil : (c, items)
    }
  }

  // MARK: Timeline row

  private func timelineRow(_ s: RF.RadioSystem, last: Bool) -> some View {
    let selected = s.id == model.systemID
    let color = BandPalette.color(forFrequency: s.carrier)
    let compact = typeSize.isAccessibilitySize
    return HStack(alignment: .top, spacing: compact ? 8 : 10) {
      // The rail: year and a dot in the carrier's band colour.
      VStack(spacing: 4) {
        if !compact {
          Text(String(s.year))
            .font(.system(.caption2, design: .monospaced).weight(.semibold))
            .foregroundStyle(Theme.muted)
            .fixedSize()
        }
        Circle()
          .fill(selected ? Theme.phosphor : color)
          .frame(width: 9, height: 9)
          .shadow(color: (selected ? Theme.phosphor : color).opacity(0.7), radius: 4)
        if !last {
          Rectangle().fill(Theme.hairline).frame(width: 1).frame(maxHeight: .infinity)
        }
      }
      .frame(width: compact ? 10 : railWidth)
      .padding(.top, compact ? 18 : 0)
      card(s, selected: selected, color: color, showsYear: compact)
        .padding(.bottom, 12)
        // The scroll target sits inside the row: an explicit id on a ForEach's direct child is
        // not found by `ScrollViewProxy.scrollTo` (the ForEach's own identity wins).
        .id(Self.rowID(s.id))
    }
  }

  /// The scroll id of a system's timeline row.
  static func rowID(_ systemID: String) -> String { "radio-system-row-\(systemID)" }

  private func card(_ s: RF.RadioSystem, selected: Bool, color: Color, showsYear: Bool) -> some View {
    let isOpen = expanded.contains(s.id)
    return VStack(alignment: .leading, spacing: 10) {
      Button {
        model.select(system: s)
      } label: {
        VStack(alignment: .leading, spacing: 8) {
          if showsYear {
            Text(String(s.year))
              .font(.system(.caption2, design: .monospaced).weight(.semibold))
              .foregroundStyle(Theme.muted)
          }
          HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(s.generation)
              .font(.system(.title3, design: .monospaced).weight(.semibold))
              .foregroundStyle(color)
            Text(s.name).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.text)
              .lineLimit(2)
              .multilineTextAlignment(.leading)
            Spacer(minLength: 0)
            if selected {
              Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.phosphor)
                .accessibilityLabel("Selected")
            }
          }
          HStack(spacing: 6) {
            iPhoneFlag(s)
            if s.isSpeculative { RadioSpeculativeBadge() }
          }
          ReadoutGrid(columns: 2) {
            Readout("Carrier", value: SpectraFormat.frequency(s.carrier), color: color, provenance: .table)
            Readout("Channel", value: channels(s), provenance: s.channelWidths.contains { $0 > 0 } ? .table : nil)
            Readout("Simulated as", value: s.waveform.displayName, provenance: .model)
            Readout(
              "Peak rate", value: s.peakRate.map { RF.Units.format(bitRate: $0.value) } ?? "—", color: Theme.phosphor,
              provenance: s.peakRate.map { $0.basis == .table ? .table : .model })
          }
          Text(RadioCopy.us(s.modulation)).font(.caption).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
          Text(RadioCopy.us(s.multiplexing)).font(.caption).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            .lineLimit(isOpen ? nil : 2)
        }
        .contentShape(.rect)
      }
      .buttonStyle(.plain)
      .accessibilityHint("Selects \(s.name) and opens the Fourier page.")
      .accessibilityIdentifier("radio-system-\(s.id)")
      if isOpen { details(s) }
      Button {
        Haptics.shared.selection()
        if isOpen { expanded.remove(s.id) } else { expanded.insert(s.id) }
      } label: {
        Label(isOpen ? "Fewer details" : "Bands, facts and sources", systemImage: isOpen ? "chevron.up" : "chevron.down")
          .font(.caption.weight(.semibold))
          .foregroundStyle(Theme.muted)
          .frame(minHeight: 30)
      }
      .buttonStyle(.plain)
      .accessibilityIdentifier("radio-system-details-\(s.id)")
    }
    .padding(14)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Theme.panel, in: .rect(cornerRadius: Theme.cardRadius))
    .overlay {
      RoundedRectangle(cornerRadius: Theme.cardRadius)
        .strokeBorder(selected ? Theme.phosphor.opacity(0.55) : Theme.hairline, lineWidth: selected ? 1.2 : 1)
        .allowsHitTesting(false)
    }
  }

  private func channels(_ s: RF.RadioSystem) -> String {
    let w = s.channelWidths.filter { $0 > 0 }
    guard let lo = w.min(), let hi = w.max() else {
      // No listed width: an unmodulated carrier is CW; anything else is not standardized yet.
      if case .tone = s.waveform { return "CW" }
      return "—"
    }
    return lo == hi ? SpectraFormat.frequency(lo) : "\(SpectraFormat.frequency(lo))–\(SpectraFormat.frequency(hi))"
  }

  private func iPhoneFlag(_ s: RF.RadioSystem) -> some View {
    let (text, spoken, color): (String, String, Color) =
      switch s.iPhone {
      case .yes: ("IN YOUR IPHONE", "In your iPhone", Theme.phosphor)
      case .partial: ("PARTLY IN IPHONE", "Partly in your iPhone", Theme.amber)
      case .no: ("NOT IN IPHONE", "Not in your iPhone", Theme.dim)
      }
    return Label {
      Text(text).font(.system(size: min(15, flagSize), weight: .semibold, design: .monospaced)).tracking(0.6)
    } icon: {
      Image(systemName: "iphone").font(.system(size: min(15, flagSize), weight: .bold))
    }
    .foregroundStyle(color)
    .labelStyle(.titleAndIcon)
    .padding(.horizontal, 6)
    .padding(.vertical, 2.5)
    .background(color.opacity(0.1), in: .capsule)
    .overlay { Capsule().strokeBorder(color.opacity(0.45), lineWidth: 0.75) }
    .fixedSize()
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(spoken)
  }

  private func details(_ s: RF.RadioSystem) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      if !s.iPhoneNote.isEmpty { detail("This iPhone", s.iPhoneNote) }
      detail("Bands", s.bands.map { "\($0.name) \(SpectraFormat.significant($0.lowMHz, 6))–\(SpectraFormat.significant($0.highMHz, 6)) MHz" }.joined(separator: " · "))
      if !s.iPhoneBands.isEmpty { detail("iPhone bands", s.iPhoneBands.joined(separator: " ")) }
      if let q = s.maxQAM { detail("Largest QAM", "\(q)-QAM") }
      if !s.subcarrierSpacings.isEmpty {
        detail("Subcarrier spacing", s.subcarrierSpacings.map { SpectraFormat.frequency($0) }.joined(separator: ", "))
      }
      if let r = s.peakRate { detail("Peak rate", "\(RF.Units.format(bitRate: r.value)): \(r.note)") }
      detail("Year", "\(s.year) (\(s.yearNote))")
      ForEach(Array(s.facts.enumerated()), id: \.offset) { _, fact in
        Label(RadioCopy.us(fact), systemImage: "info.circle").font(.caption).foregroundStyle(Theme.text.opacity(0.85))
          .fixedSize(horizontal: false, vertical: true)
      }
      if !s.sources.isEmpty {
        Text("Sources: " + RadioCopy.us(s.sources.joined(separator: "; "))).font(.caption2).foregroundStyle(Theme.dim)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  private func detail(_ title: String, _ text: String) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(title.instrumentCaps).font(Theme.readoutTitleFont).foregroundStyle(Theme.muted)
      Text(RadioCopy.us(text)).font(.caption).foregroundStyle(Theme.text).fixedSize(horizontal: false, vertical: true)
    }
    .accessibilityElement(children: .combine)
  }
}
