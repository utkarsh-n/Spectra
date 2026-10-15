import SwiftUI

/// A glass action button (Orbitals `ActionButton`): `.glassProminent` for the one primary
/// action on a surface, `.glass` otherwise. Plays the tap haptic, then runs the action in a
/// short animation unless Reduce Motion is on.
struct ActionButton: View {
  let title: String
  let symbol: String
  var prominent = false
  var tint: Color = Theme.phosphor
  let action: () -> Void

  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  init(_ title: String, symbol: String, prominent: Bool = false, tint: Color = Theme.phosphor, action: @escaping () -> Void) {
    self.title = title
    self.symbol = symbol
    self.prominent = prominent
    self.tint = tint
    self.action = action
  }

  var body: some View {
    Group {
      if prominent {
        button.buttonStyle(.glassProminent)
      } else {
        button.buttonStyle(.glass)
      }
    }
    .tint(tint)
    .accessibilityLabel(title)
  }

  private var button: some View {
    Button {
      Haptics.shared.tap()
      if reduceMotion { action() } else { withAnimation(.smooth(duration: 0.2)) { action() } }
    } label: {
      Label {
        Text(title).lineLimit(1)
      } icon: {
        Image(systemName: symbol).contentTransition(.symbolEffect(.replace))
      }
      .font(.subheadline.weight(.semibold))
      .fixedSize(horizontal: true, vertical: false)
      .frame(minWidth: 24, minHeight: 32)
      .padding(.horizontal, 4)
      .padding(.vertical, 6)
    }
    .buttonBorderShape(.capsule)
    .symbolEffectsRemoved(reduceMotion)
    .transaction { if reduceMotion { $0.animation = nil } }
  }
}

/// A full-row toggle with a phosphor tint and a selection haptic on real changes only.
struct GlassToggle: View {
  let title: String
  @Binding var isOn: Bool
  let symbol: String
  var subtitle: String? = nil

  init(_ title: String, isOn: Binding<Bool>, symbol: String, subtitle: String? = nil) {
    self.title = title
    _isOn = isOn
    self.symbol = symbol
    self.subtitle = subtitle
  }

  var body: some View {
    Toggle(
      isOn: Binding(
        get: { isOn },
        set: { next in
          guard next != isOn else { return }
          Haptics.shared.selection()
          isOn = next
        })
    ) {
      Label {
        VStack(alignment: .leading, spacing: 2) {
          Text(title).font(.subheadline)
          if let subtitle { Text(subtitle).font(.caption).foregroundStyle(Theme.muted) }
        }
      } icon: {
        Image(systemName: symbol).symbolRenderingMode(.hierarchical)
      }
      .fixedSize(horizontal: false, vertical: true)
    }
    .tint(Theme.phosphor)
    .frame(minHeight: 44)
    .accessibilityLabel(title)
  }
}

/// A labelled linear slider with a monospaced reading (Orbitals `GlassSlider`): title and
/// reading on one row when they fit, stacked otherwise; detent haptics while dragging.
struct GlassSlider: View {
  let title: String
  @Binding var value: Double
  let range: ClosedRange<Double>
  var step = 0.01
  var color: Color = Theme.amber
  var format: (Double) -> String = { SpectraFormat.significant($0, 3) }

  @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      ViewThatFits(in: .horizontal) {
        HStack(alignment: .firstTextBaseline) {
          Text(title).font(.subheadline)
          Spacer(minLength: 12)
          reading
        }
        VStack(alignment: .leading, spacing: 4) {
          Text(title).font(.subheadline)
          reading
        }
      }
      Slider(value: tactile, in: range, step: max(step, .ulpOfOne)) { editing in
        if editing { Haptics.shared.beginAdjustment() } else { Haptics.shared.endAdjustment() }
      }
      .tint(color)
      .frame(minHeight: 44)
      .accessibilityLabel(title)
      .accessibilityValue(format(value))
    }
  }

  private var reading: some View {
    Text(format(value))
      .font(.system(.subheadline, design: .monospaced).weight(.medium))
      .foregroundStyle(color)
      .monospacedDigit()
      .fixedSize(horizontal: true, vertical: false)
      .contentTransition(.numericText())
      .accessibilityHidden(true)
  }

  private var tactile: Binding<Double> {
    Binding(
      get: { value },
      set: { proposed in
        guard proposed.isFinite else { return }
        let interval = max(step, .ulpOfOne)
        let snapped = range.lowerBound + ((proposed - range.lowerBound) / interval).rounded() * interval
        let next = min(range.upperBound, max(range.lowerBound, snapped))
        guard next != value else { return }
        value = next
        let p = range.upperBound > range.lowerBound ? (next - range.lowerBound) / (range.upperBound - range.lowerBound) : 0
        if voiceOverEnabled { Haptics.shared.selection() } else { Haptics.shared.detent(normalized: p) }
      })
  }
}

/// A horizontally scrolling row of explicit selection chips (Orbitals' motion chips: a Menu
/// hid which mode was active). The selected chip scrolls to the centre.
///
/// ```swift
/// ChoiceChips(items: Instrument.allCases, selection: $model.instrument, id: "instrument") { i in
///   ChipLabel(number: i.number, title: i.title)
/// }
/// ```
struct ChoiceChips<Item: Hashable & Identifiable, Label: View>: View {
  let items: [Item]
  @Binding var selection: Item
  /// Prefix for identifiers: each chip is `<id>-<item.id>`.
  var id: String
  var tint: Color = Theme.phosphor
  @ViewBuilder var label: (Item) -> Label

  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    ScrollViewReader { proxy in
      ScrollView(.horizontal) {
        GlassEffectContainer(spacing: 10) {
          HStack(spacing: 8) {
            ForEach(items) { item in
              let selected = item == selection
              Button {
                guard item != selection else { return }
                Haptics.shared.selection()
                withAnimation(Theme.animation(reduceMotion)) { selection = item }
              } label: {
                label(item)
                  .font(.subheadline.weight(.medium))
                  .foregroundStyle(selected ? Theme.text : Theme.muted)
                  .padding(.horizontal, 12)
                  .frame(minHeight: 40)
              }
              .buttonStyle(.plain)
              .glassEffect(
                selected ? .regular.tint(tint.opacity(0.28)).interactive() : .regular.interactive(),
                in: .rect(cornerRadius: Theme.chipRadius)
              )
              .accessibilityAddTraits(selected ? .isSelected : [])
              .accessibilityIdentifier("\(id)-\(String(describing: item.id))")
              .id(item.id)
            }
          }
          .padding(.horizontal, Theme.gutter)
          .padding(.vertical, 4)
        }
      }
      .scrollIndicators(.hidden)
      .onAppear { proxy.scrollTo(selection.id, anchor: .center) }
      .onChange(of: selection) { _, next in
        withAnimation(Theme.animation(reduceMotion)) { proxy.scrollTo(next.id, anchor: .center) }
      }
    }
  }
}

/// The standard chip label: a phosphor number and a title ("01 Wave scope").
struct ChipLabel: View {
  var number: String? = nil
  let title: String
  var symbol: String? = nil

  var body: some View {
    HStack(spacing: 6) {
      if let symbol { Image(systemName: symbol) }
      if let number {
        Text(number).font(.system(.caption, design: .monospaced).weight(.semibold)).foregroundStyle(Theme.phosphor)
      }
      Text(title).lineLimit(1)
    }
  }
}

/// A small status capsule ("ALIASED", "SIM", "REAL TIME"): tracked monospaced caption on a
/// tinted glass capsule. Not a button.
struct StatusChip: View {
  let text: String
  var detail: String? = nil
  var color: Color = Theme.amber
  var symbol: String? = nil

  var body: some View {
    HStack(spacing: 5) {
      if let symbol { Image(systemName: symbol).font(.system(size: 9, weight: .bold)) }
      VStack(alignment: .leading, spacing: 0) {
        Text(text).font(.system(size: 9, weight: .semibold, design: .monospaced)).tracking(0.8)
        if let detail {
          Text(detail).font(.system(size: 9, design: .monospaced)).monospacedDigit().opacity(0.85)
        }
      }
      .lineLimit(1)
      .fixedSize()
    }
    .foregroundStyle(color)
    .padding(.horizontal, 8)
    .padding(.vertical, 4)
    .glassEffect(.regular.tint(color.opacity(0.18)), in: .capsule)
    .accessibilityElement(children: .combine)
  }
}

/// Gyre's level meter: a 6 pt phosphor capsule bar.
struct LevelMeter: View {
  /// 0…1.
  let level: Double
  var color: Color = Theme.phosphor

  var body: some View {
    GeometryReader { geo in
      ZStack(alignment: .leading) {
        Capsule().fill(.white.opacity(0.08))
        Capsule()
          .fill(LinearGradient(colors: [color.opacity(0.6), color], startPoint: .leading, endPoint: .trailing))
          .frame(width: geo.size.width * min(1, max(0, level.isFinite ? level : 0)))
          .shadow(color: color.opacity(0.6), radius: 4)
      }
    }
    .frame(height: 6)
    .animation(.linear(duration: 0.1), value: level)
    .accessibilityElement()
    .accessibilityLabel("Level")
    .accessibilityValue("\(Int((min(1, max(0, level.isFinite ? level : 0)) * 100).rounded())) percent")
  }
}
