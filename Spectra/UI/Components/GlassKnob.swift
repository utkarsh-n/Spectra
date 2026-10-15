import SwiftUI

/// A labelled detent with physical meaning ("Earth 1 g", "λ/2", "Wi-Fi 2.4").
nonisolated struct KnobDetent: Hashable, Sendable {
  let value: Double
  let label: String

  init(_ value: Double, _ label: String) {
    self.value = value
    self.label = label
  }
}

/// The pure mapping half of a knob (Gyre's `KnobSpec` maths): value ↔ position 0…1, linear
/// or logarithmic, optional step rounding, bipolar origin. Sendable and UI-free so tests and
/// engines can use it.
nonisolated struct KnobScale: Hashable, Sendable {
  var range: ClosedRange<Double>
  var logarithmic = false
  /// Values snap to multiples of this while dragging (0 = continuous). `step >= 1` on a
  /// knob makes it a rotary switch.
  var step: Double = 0
  /// Where the lit value arc starts; bipolar knobs light up from their zero.
  var origin: Double?

  init(range: ClosedRange<Double>, logarithmic: Bool = false, step: Double = 0, origin: Double? = nil) {
    // A log scale needs a positive lower bound; fall back to linear otherwise.
    self.range = range
    self.logarithmic = logarithmic && range.lowerBound > 0 && range.upperBound > range.lowerBound
    self.step = max(0, step)
    self.origin = origin
  }

  /// Position 0…1 of `value` (clamped; non-finite → 0).
  func position(of value: Double) -> Double {
    guard value.isFinite, range.upperBound > range.lowerBound else { return 0 }
    let v = min(max(value, range.lowerBound), range.upperBound)
    if logarithmic { return log(v / range.lowerBound) / log(range.upperBound / range.lowerBound) }
    return (v - range.lowerBound) / (range.upperBound - range.lowerBound)
  }

  /// The value at position `p` (clamped), rounded to `step` when set.
  func value(at position: Double) -> Double {
    let p = position.isFinite ? min(max(position, 0), 1) : 0
    var v =
      logarithmic
      ? range.lowerBound * pow(range.upperBound / range.lowerBound, p)
      : range.lowerBound + p * (range.upperBound - range.lowerBound)
    if step > 0 { v = range.lowerBound + ((v - range.lowerBound) / step).rounded() * step }
    return min(max(v, range.lowerBound), range.upperBound)
  }

  /// Position where the lit arc starts.
  var originPosition: Double { position(of: origin ?? range.lowerBound) }

  /// The value clamped into range (non-finite → lower bound).
  func clamp(_ value: Double) -> Double {
    guard value.isFinite else { return range.lowerBound }
    return min(max(value, range.lowerBound), range.upperBound)
  }

  /// Gyre's modulation rule, applied in position space so log knobs modulate musically:
  /// `p = clamp(position(base) + depth·cv)`, value = `value(at: p)` (`gyre-integration.md` §7).
  func modulated(base: Double, depth: Double, cv: Double) -> Double {
    let p = position(of: base) + (depth.isFinite ? depth : 0) * (cv.isFinite ? cv : 0)
    return value(at: p)
  }
}

/// A knob's range, mapping, detents and words (Gyre's `KnobSpec`, generalized). The words
/// teach at the moment of interaction: `hint` shows in the readout card while turning,
/// `detail` belongs in Field notes.
///
/// ```swift
/// let lambda = KnobSpec(
///   id: "lambda", title: "Wavelength", glyph: "λ", tint: Theme.dialLambda(550e-9),
///   range: 1e-12...1e3, defaultValue: 550e-9, logarithmic: true,
///   detents: [KnobDetent(550e-9, "Green"), KnobDetent(0.1229, "BLE 2.44 GHz")],
///   hint: "Vacuum wavelength of source A.", format: { SpectraFormat.wavelength($0) })
/// ```
struct KnobSpec: Identifiable {
  /// Stable id; the knob's accessibility identifier is `knob-<id>`.
  let id: String
  var title: String
  /// SF Symbol drawn in the puck ("" for none).
  var symbol: String
  /// Serif glyph for the physical quantity ("λ", "E₀", "θ"), shown before the title.
  var glyph: String
  /// Parameter identity colour (dial accents, `Theme.dial…`).
  var tint: Color
  var scale: KnobScale
  var defaultValue: Double
  var detents: [KnobDetent]
  /// One line for the readout card and the VoiceOver hint.
  var hint: String
  /// A paragraph for Field notes.
  var detail: String
  var format: (Double) -> String

  init(
    id: String, title: String, symbol: String = "", glyph: String = "", tint: Color = Theme.amber,
    range: ClosedRange<Double>, defaultValue: Double, logarithmic: Bool = false, origin: Double? = nil,
    step: Double = 0, detents: [KnobDetent] = [], hint: String = "", detail: String = "", unit: String = "",
    format: ((Double) -> String)? = nil
  ) {
    self.id = id
    self.title = title
    self.symbol = symbol
    self.glyph = glyph
    self.tint = tint
    scale = KnobScale(range: range, logarithmic: logarithmic, step: step, origin: origin)
    self.defaultValue = defaultValue
    self.detents = detents
    self.hint = hint
    self.detail = detail
    self.format =
      format ?? { value in
        let text = SpectraFormat.significant(value, 3)
        return unit.isEmpty ? text : "\(text) \(unit)"
      }
  }

  var range: ClosedRange<Double> { scale.range }
  /// A rotary switch: whole-number positions, each a named detent.
  var isSwitch: Bool { scale.step >= 1 }

  func position(of value: Double) -> Double { scale.position(of: value) }
  func value(at position: Double) -> Double { scale.value(at: position) }
  var originPosition: Double { scale.originPosition }

  /// The detent `value` sits on (position tolerance 0.004), if any.
  func detent(at value: Double) -> KnobDetent? {
    let p = position(of: value)
    return detents.first { abs(position(of: $0.value) - p) < 0.004 }
  }

  /// Label for a rotary switch position, or the detent label, or the formatted value.
  func label(for value: Double) -> String {
    detent(at: value)?.label ?? format(value)
  }
}

/// A live modulation of a knob (the Drives matrix, `gyre-integration.md` §7): drawn as a
/// dashed second arc to the modulated position in the cable's colour.
struct KnobModulation: Equatable {
  /// The modulated value this frame (already mapped with `KnobScale.modulated`).
  var value: Double
  /// The cable colour (band colour for EM, phosphor/amber for analogy and control).
  var color: Color
  /// "Microphone", "BLE RSSI".
  var source: String
  /// Depth 0…1 (shown as a percentage).
  var depth: Double

  /// "Driven by Microphone · depth 50 %".
  var caption: String { "Driven by \(source) · depth \(Int((depth * 100).rounded())) %" }
}

/// A rotary Liquid Glass knob: Gyre's mechanics (relative drag, 270° sweep, 24 ticks per
/// sweep, labelled detents that capture within ±0.02, rotary switches, double-tap reset)
/// with Orbitals' accessibility (adjustable action, arrow keys with `@FocusState`, an
/// optional linear slider underneath).
///
/// Drag up or right to turn it up; 230 pt of travel is the full sweep.
struct GlassKnob: View {
  let spec: KnobSpec
  @Binding var value: Double
  /// A dashed arc to the live modulated position.
  var modulation: KnobModulation? = nil
  /// Orbitals' precise linear alternative under the dial (in position space, so log knobs
  /// stay logarithmic).
  var showsSlider = false
  /// Called with true on grab and false on release (show a `KnobReadout`).
  var onActive: ((Bool) -> Void)? = nil
  /// Long-press → "Modulate from…" (the Patch tab supplies the menu).
  var onModulate: (() -> Void)? = nil

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
  @GestureState private var dragging = false
  @State private var startPosition: Double?
  @State private var lastTick = 0
  @State private var lastDetent: String?
  @State private var bump = 0
  @FocusState private var focused: Bool

  private let sweep = 270.0
  private var position: Double { spec.position(of: value) }

  var body: some View {
    VStack(spacing: 4) {
      dial
      HStack(spacing: 3) {
        if !spec.glyph.isEmpty {
          Text(spec.glyph)
            .font(.system(.caption, design: .serif).weight(.semibold).italic())
            .foregroundStyle(spec.tint)
        }
        Text(spec.title.instrumentCaps)
          .font(.caption2.weight(.semibold))
          .tracking(0.6)
          .foregroundStyle(.white.opacity(0.62))
          .lineLimit(1)
          .minimumScaleFactor(0.7)
      }
      Text(spec.isSwitch ? spec.label(for: value) : spec.format(value))
        .font(.system(.caption, design: .monospaced).weight(.medium))
        .monospacedDigit()
        .foregroundStyle(.white)
        .contentTransition(.numericText(value: value))
        .lineLimit(1)
        .minimumScaleFactor(0.6)
      if showsSlider { slider }
    }
    .frame(maxWidth: .infinity)
  }

  private var dial: some View {
    let lo = min(spec.originPosition, position)
    let hi = max(spec.originPosition, position)
    return ZStack {
      KnobArc(from: 0, to: 1, sweep: sweep)
        .stroke(.white.opacity(0.1), style: StrokeStyle(lineWidth: 3, lineCap: .round))
      KnobArc(from: lo, to: hi, sweep: sweep)
        .stroke(spec.tint, style: StrokeStyle(lineWidth: 3, lineCap: .round))
        .shadow(color: spec.tint.opacity(0.8), radius: 4)
      if let modulation {
        let m = spec.position(of: modulation.value)
        KnobArc(from: min(position, m), to: max(position, m), sweep: sweep)
          .stroke(modulation.color, style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [3, 4]))
          .padding(5)
          .shadow(color: modulation.color.opacity(0.7), radius: 3)
        Circle()
          .fill(modulation.color)
          .frame(width: 4, height: 4)
          .offset(y: -35)
          .rotationEffect(.degrees(-sweep / 2 + sweep * m))
      }
      ForEach(spec.detents, id: \.self) { d in
        Circle()
          .fill(.white.opacity(lastDetent == d.label || spec.detent(at: value) == d ? 1 : 0.45))
          .frame(width: 3, height: 3)
          .offset(y: -41)
          .rotationEffect(.degrees(-sweep / 2 + sweep * spec.position(of: d.value)))
      }
      ZStack {
        if !spec.symbol.isEmpty {
          Image(systemName: spec.symbol)
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(.white.opacity(0.9))
            .symbolEffect(.bounce, value: bump)
        } else if !spec.glyph.isEmpty {
          Text(spec.glyph)
            .font(.system(size: 17, weight: .semibold, design: .serif).italic())
            .foregroundStyle(.white.opacity(0.9))
        }
        Capsule()
          .fill(spec.tint)
          .frame(width: 3.5, height: 10)
          .shadow(color: spec.tint, radius: 3)
          .offset(y: -22)
          .rotationEffect(.degrees(-sweep / 2 + sweep * position))
      }
      .frame(width: 60, height: 60)
      .glassEffect(.regular.tint(spec.tint.opacity(startPosition == nil ? 0.1 : 0.32)).interactive(), in: .circle)
      .scaleEffect(startPosition == nil ? 1 : 1.07)
      .animation(reduceMotion ? nil : .spring(duration: 0.25, bounce: 0.4), value: startPosition == nil)
    }
    .frame(width: 84, height: 84)
    .contentShape(Circle())
    .gesture(turn)
    .simultaneousGesture(
      TapGesture(count: 2).onEnded {
        withAnimation(Theme.animation(reduceMotion, .smooth(duration: 0.5))) { value = spec.defaultValue }
        Haptics.shared.resetClick()
        bump += 1
      }
    )
    .simultaneousGesture(
      LongPressGesture(minimumDuration: 0.55, maximumDistance: 3).onEnded { _ in
        guard let onModulate, startPosition == nil else { return }
        Haptics.shared.success()
        onModulate()
      },
      including: onModulate == nil ? .subviews : .all
    )
    .onChange(of: dragging) { _, isDragging in
      // Also releases correctly when a scroll view or system gesture cancels the drag.
      if !isDragging { finish() }
    }
    .onDisappear { startPosition = nil }
    .focusable()
    .focused($focused)
    .onKeyPress(.upArrow) { nudge(1); return .handled }
    .onKeyPress(.rightArrow) { nudge(1); return .handled }
    .onKeyPress(.downArrow) { nudge(-1); return .handled }
    .onKeyPress(.leftArrow) { nudge(-1); return .handled }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(spec.glyph.isEmpty ? spec.title : "\(spec.title), \(spec.glyph)")
    .accessibilityValue(accessibilityValue)
    .accessibilityHint(
      "\(spec.hint) Swipe up or down to adjust. Drag the dial up or right to increase. Double-tap the dial to reset."
    )
    .accessibilityAdjustableAction { direction in
      switch direction {
      case .increment: nudge(1)
      case .decrement: nudge(-1)
      @unknown default: break
      }
    }
    .accessibilityAction(named: "Reset") {
      value = spec.defaultValue
      Haptics.shared.resetClick()
    }
    .accessibilityActions {
      if let onModulate {
        Button("Modulate from…") { onModulate() }
      }
    }
    .accessibilityIdentifier("knob-\(spec.id)")
  }

  private var accessibilityValue: String {
    var text = spec.isSwitch ? spec.label(for: value) : spec.format(value)
    if !spec.isSwitch, let d = spec.detent(at: value) { text += ", \(d.label)" }
    if let modulation { text += ". \(modulation.caption)" }
    return text
  }

  private var slider: some View {
    Slider(
      value: Binding(
        get: { position },
        set: { p in
          let next = spec.value(at: p)
          guard next != value else { return }
          value = next
          if voiceOverEnabled { Haptics.shared.selection() } else { Haptics.shared.detent(normalized: p) }
        }),
      in: 0...1
    ) { editing in
      if editing { Haptics.shared.beginAdjustment() } else { Haptics.shared.endAdjustment() }
    }
    .tint(spec.tint)
    .frame(minHeight: 44)
    .accessibilityLabel("\(spec.title), linear control")
    .accessibilityValue(accessibilityValue)
    .accessibilityIdentifier("knob-\(spec.id)-slider")
  }

  private var turn: some Gesture {
    DragGesture(minimumDistance: 2)
      .updating($dragging) { _, state, _ in state = true }
      .onChanged { g in
        if startPosition == nil {
          startPosition = position
          lastTick = tick(position)
          lastDetent = spec.detent(at: value)?.label
          focused = true
          onActive?(true)
          Haptics.shared.grab()
        }
        var p = min(max((startPosition ?? position) + Double(g.translation.width - g.translation.height) / 230, 0), 1)
        if spec.isSwitch {
          // A rotary switch clicks firmly into each position.
          let next = spec.value(at: p)
          if next != value {
            value = next
            Haptics.shared.switchClick()
            bump += 1
          }
          return
        }
        var next = spec.value(at: p)
        if let d = spec.detents.first(where: { abs(spec.position(of: $0.value) - p) < 0.02 }) {
          p = spec.position(of: d.value)
          next = d.value
          if lastDetent != d.label {
            lastDetent = d.label
            Haptics.shared.detent()
            bump += 1
          }
        } else {
          lastDetent = nil
          let t = tick(p)
          if t != lastTick {
            lastTick = t
            if p <= 0 || p >= 1 { Haptics.shared.boundary() } else { Haptics.shared.tick() }
          }
        }
        if next != value { value = next }
      }
  }

  private func finish() {
    guard startPosition != nil else { return }
    startPosition = nil
    onActive?(false)
    Haptics.shared.endAdjustment()
  }

  private func tick(_ p: Double) -> Int { Int((p * 24).rounded(.down)) }

  /// One VoiceOver or keyboard step: a switch position, a linear step, or 1/20 of travel.
  private func nudge(_ direction: Double) {
    let previous = value
    let next: Double
    if spec.isSwitch {
      next = spec.scale.clamp(value + direction * spec.scale.step)
    } else if spec.scale.step > 0, !spec.scale.logarithmic {
      next = spec.scale.clamp(value + direction * spec.scale.step)
    } else {
      next = spec.value(at: position + direction / 20)
    }
    guard next != previous else {
      Haptics.shared.boundary()
      return
    }
    value = next
    if spec.isSwitch { Haptics.shared.switchClick() } else { Haptics.shared.selection() }
  }
}

/// An arc clockwise from the knob's lowest point, by fractions of its sweep.
nonisolated struct KnobArc: Shape {
  var from: Double
  var to: Double
  var sweep: Double

  var animatableData: AnimatablePair<Double, Double> {
    get { AnimatablePair(from, to) }
    set {
      from = newValue.first
      to = newValue.second
    }
  }

  func path(in rect: CGRect) -> Path {
    var path = Path()
    let c = CGPoint(x: rect.midX, y: rect.midY)
    let r = min(rect.width, rect.height) / 2 - 2
    let start = -sweep / 2 + sweep * from
    let end = -sweep / 2 + sweep * to
    let n = max(2, Int(abs(end - start) / 4))
    for i in 0...n {
      let deg = start + (end - start) * Double(i) / Double(n)
      let a = deg * .pi / 180
      let p = CGPoint(x: c.x + sin(a) * r, y: c.y - cos(a) * r)
      if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
    }
    return path
  }
}

/// Gyre's floating card that names what you are turning and what it does physically:
/// symbol, title and detent label, value, then the hint (and the modulation caption).
struct KnobReadout: View {
  let spec: KnobSpec
  let value: Double
  var modulation: KnobModulation? = nil

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 8) {
        if !spec.glyph.isEmpty {
          Text(spec.glyph).font(.system(.headline, design: .serif).italic()).foregroundStyle(spec.tint)
        } else if !spec.symbol.isEmpty {
          Image(systemName: spec.symbol).foregroundStyle(spec.tint)
        }
        Text(spec.title).font(.headline)
        if let d = spec.detent(at: value) {
          Text(d.label).font(.subheadline.weight(.semibold)).foregroundStyle(spec.tint)
        }
        Spacer(minLength: 8)
        Text(spec.isSwitch ? spec.label(for: value) : spec.format(value))
          .font(.system(.headline, design: .monospaced))
          .monospacedDigit()
          .contentTransition(.numericText(value: value))
      }
      if !spec.hint.isEmpty {
        Text(spec.hint).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      }
      if let modulation {
        Text(modulation.caption).font(.footnote.weight(.medium)).foregroundStyle(modulation.color)
      }
    }
    .padding(14)
    .frame(maxWidth: 420, alignment: .leading)
    .glassEffect(.regular, in: .rect(cornerRadius: 22))
    .allowsHitTesting(false)
    .accessibilityElement(children: .combine)
  }
}

/// A grid of knobs (4 per row, 2 at accessibility sizes) in one `GlassEffectContainer`, with
/// Gyre's `KnobReadout` floating above while a knob is held.
///
/// ```swift
/// KnobGrid(specs: model.knobs) { spec in $model.values[spec.id] }
/// ```
struct KnobGrid: View {
  let specs: [KnobSpec]
  let value: (KnobSpec) -> Binding<Double>
  var modulation: (KnobSpec) -> KnobModulation? = { _ in nil }
  var columns = 4
  var showsSliders = false
  /// Long-press → "Modulate from…" (SPEC-features §5): adds a Patch Knob target aimed at
  /// this knob. On by default for every grid outside Patch (integration).
  var modulatable = true

  @Environment(\.dynamicTypeSize) private var typeSize
  @Environment(AppModel.self) private var app: AppModel?
  @Environment(\.dismiss) private var dismiss
  @State private var active: String?

  var body: some View {
    let count = typeSize.isAccessibilitySize ? 2 : max(1, columns)
    GlassEffectContainer(spacing: 18) {
      LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: count), spacing: 12) {
        ForEach(specs) { spec in
          GlassKnob(
            spec: spec, value: value(spec), modulation: drive(spec), showsSlider: showsSliders,
            onActive: { on in active = on ? spec.id : (active == spec.id ? nil : active) },
            onModulate: modulateAction(spec))
        }
      }
    }
    .overlay(alignment: .top) {
      if let id = active, let spec = specs.first(where: { $0.id == id }) {
        KnobReadout(spec: spec, value: value(spec).wrappedValue, modulation: drive(spec))
          .offset(y: -86)
          .transition(.opacity.combined(with: .scale(scale: 0.92, anchor: .bottom)))
      }
    }
    .animation(.spring(duration: 0.3, bounce: 0.25), value: active)
  }

  /// The caller's modulation, else a live Patch drive aimed at this knob.
  private func drive(_ spec: KnobSpec) -> KnobModulation? {
    modulation(spec) ?? app?.patch.externalModulation(for: spec.id, spec: spec)
  }

  private func modulateAction(_ spec: KnobSpec) -> (() -> Void)? {
    guard modulatable, let app, !spec.isSwitch else { return nil }
    let binding = value(spec)
    return {
      let title = "\(app.selectedTab.title) · \(spec.title)"
      // A Dials sheet would stay over the Patch tab: close it first (no-op outside a sheet).
      dismiss()
      app.patch.modulate(
        knobID: spec.id, title: title, scale: spec.scale, get: { binding.wrappedValue },
        set: { binding.wrappedValue = $0 })
    }
  }
}
