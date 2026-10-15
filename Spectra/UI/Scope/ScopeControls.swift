import SwiftUI

/// Knob tables for the Scope. Rotary switches step through 1-2-5 positions; the values the
/// knobs edit live in `ScopeModel.settings`.
@MainActor
enum ScopeKnobs {
  static let persistenceSteps: [Double] = [0, 0.05, 0.1, 0.25, 0.5, 1, 2, 5, 10, ScopeSettings.infinitePersistence]
  static let holdoffSteps: [Double] = [0, 0.001, 0.002, 0.005, 0.01, 0.02, 0.05, 0.1, 0.2, 0.5, 1, 2, 5]

  static func nearestIndex(_ value: Double, in list: [Double]) -> Double {
    guard !list.isEmpty else { return 0 }
    var best = 0
    for (i, v) in list.enumerated() where abs(v - value) < abs(list[best] - value) { best = i }
    return Double(best)
  }

  static func timebase(_ options: [Double]) -> KnobSpec {
    let list = options.isEmpty ? [0.05] : options
    return KnobSpec(
      id: "scope-timebase", title: "Time/div", glyph: "t", tint: Theme.phosphor,
      range: 0...Double(max(1, list.count - 1)), defaultValue: nearestIndex(0.05, in: list), step: 1,
      detents: list.enumerated().compactMap { $0.element == ScopeEngine.rollThreshold ? KnobDetent(Double($0.offset), "Roll from here") : nil },
      hint: "Seconds per division. It stops where the fastest channel has one sample per division; 0.5 s/div and slower roll.",
      format: { ScopeFormat.timebase(list[min(list.count - 1, max(0, Int($0.rounded())))]) })
  }

  static func scale(channel i: Int, unit: String, tint: Color) -> (KnobSpec, [Double]) {
    let list = ScopeEngine.scales(unit: unit)
    let name = i == 4 ? "math" : "ch\(i + 1)"
    let spec = KnobSpec(
      id: "scope-\(name)-scale", title: "Scale", glyph: "↕", tint: tint, range: 0...Double(max(1, list.count - 1)),
      defaultValue: nearestIndex(1, in: list), step: 1,
      hint: "Units per vertical division (1-2-5). Turning it stops auto-scale for this channel.",
      format: { ScopeFormat.scale(list[min(list.count - 1, max(0, Int($0.rounded())))], unit: unit) })
    return (spec, list)
  }

  static func offset(channel i: Int, tint: Color) -> KnobSpec {
    KnobSpec(
      id: "scope-\(i == 4 ? "math" : "ch\(i + 1)")-offset", title: "Offset", glyph: "↥", tint: tint, range: -4...4,
      defaultValue: 0, origin: 0, detents: [KnobDetent(0, "Center")],
      hint: "Moves the trace up or down, in divisions.",
      format: { String(format: "%+.1f div", $0).replacingOccurrences(of: "-", with: "−") })
  }

  static func level(range: ClosedRange<Double>, unit: String, centre: Double, tint: Color, id: String = "scope-level") -> KnobSpec {
    let r = range.upperBound > range.lowerBound ? range : (range.lowerBound - 1)...(range.lowerBound + 1)
    return KnobSpec(
      id: id, title: "Level", glyph: "⊤", tint: tint, range: r, defaultValue: centre, origin: centre,
      detents: [KnobDetent(centre, "Trace center")],
      hint: "The trigger fires when the source crosses this value in the chosen direction.",
      format: { ScopeFormat.value($0, unit: unit) })
  }

  static var persistence: KnobSpec {
    KnobSpec(
      id: "scope-persistence", title: "Persist", glyph: "τ", tint: Theme.amber,
      range: 0...Double(persistenceSteps.count - 1), defaultValue: 3, step: 1,
      hint: "How long the phosphor glows after the beam passes (e-folding time). ∞ keeps every sweep.",
      format: { ScopeFormat.persistence(persistenceSteps[min(persistenceSteps.count - 1, max(0, Int($0.rounded())))]) })
  }

  static var holdoff: KnobSpec {
    KnobSpec(
      id: "scope-holdoff", title: "Holdoff", glyph: "h", tint: Theme.amber,
      range: 0...Double(holdoffSteps.count - 1), defaultValue: 0, step: 1,
      hint: "After each sweep the trigger ignores edges for this long.",
      format: { v in
        let h = holdoffSteps[min(holdoffSteps.count - 1, max(0, Int(v.rounded())))]
        return h == 0 ? "Off" : SpectraFormat.si(h, unit: "s")
      })
  }

  static func cursorTime(_ id: String, title: String, timebase: Double) -> KnobSpec {
    KnobSpec(
      id: "scope-cursor-\(id)", title: "Cursor", glyph: title, tint: Theme.text, range: 0...10, defaultValue: id == "t1" ? 3 : 7,
      hint: "Vertical cursor, in divisions from the left edge.",
      format: { "\(SpectraFormat.significant($0, 2)) div · \(ScopeFormat.time($0 * timebase))" })
  }

  static func cursorLevel(_ id: String, title: String, unitsPerDiv: Double, unit: String) -> KnobSpec {
    KnobSpec(
      id: "scope-cursor-\(id)", title: "Cursor", glyph: title, tint: Theme.text, range: -4...4, defaultValue: id == "y1" ? 2 : -2,
      origin: 0, detents: [KnobDetent(0, "Center")],
      hint: "Horizontal cursor, in divisions from the center line.",
      format: { "\(SpectraFormat.significant($0, 2)) div · \(ScopeFormat.value($0 * unitsPerDiv, unit: unit))" })
  }

  static var corner: KnobSpec {
    KnobSpec(
      id: "scope-math-corner", title: "Corner", glyph: "f", tint: Theme.violetRGB.color, range: 0.01...100, defaultValue: 1,
      logarithmic: true, detents: [KnobDetent(0.1, "0.1 Hz"), KnobDetent(1, "1 Hz"), KnobDetent(10, "10 Hz")],
      hint: "The high-pass's −3 dB corner.", format: { SpectraFormat.frequency($0) })
  }
}

/// A channel button: colour, name, stream, scale, measured rate, badge. Tap to configure.
struct ScopeChannelButton: View {
  let model: ScopeModel
  let index: Int
  let action: () -> Void

  /// 128 pt at the default size, wider with Dynamic Type so the stream name stays readable.
  @ScaledMetric(relativeTo: .caption) private var width: CGFloat = 128

  var body: some View {
    let shown = model.isShown(index)
    let name = index == 4 ? "MATH" : "CH\(index + 1)"
    let enabled = index == 4 ? model.settings.math.enabled : model.settings.channels[index].enabled
    Button {
      Haptics.shared.tap()
      action()
    } label: {
      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 6) {
          Capsule().fill(model.color(index).opacity(enabled ? 1 : 0.3)).frame(width: 14, height: 4)
          Text(name).font(.system(.caption, design: .monospaced).weight(.bold)).foregroundStyle(model.color(index))
          if let p = model.provenance(index).first { ProvenanceBadge(p, compact: true) }
        }
        Text(enabled ? model.label(index) : "Off")
          .font(.caption2)
          .foregroundStyle(enabled ? Theme.text : Theme.muted)
          .lineLimit(1)
        Text(detail(shown: shown, enabled: enabled))
          .font(.system(.caption2, design: .monospaced))
          .monospacedDigit()
          .foregroundStyle(Theme.muted)
          .lineLimit(1)
      }
      .frame(width: min(width, 300), alignment: .leading)
      .padding(.horizontal, 10)
      .padding(.vertical, 8)
    }
    .buttonStyle(.plain)
    .glassEffect(.regular.tint(model.color(index).opacity(enabled ? 0.12 : 0.02)).interactive(), in: .rect(cornerRadius: Theme.chipRadius))
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(name), \(enabled ? model.label(index) : "off")")
    .accessibilityValue(enabled ? detail(shown: shown, enabled: enabled) : "")
    .accessibilityHint("Opens this channel's source, scale, coupling and offset.")
    .accessibilityIdentifier(index == 4 ? "scope-math" : "scope-channel-\(index + 1)")
  }

  private func detail(shown: Bool, enabled: Bool) -> String {
    guard enabled else { return "tap to set up" }
    guard shown else { return "waiting for stream" }
    let s = model.scale(index)
    let rate = model.isIrregular(index) ? "irregular" : SpectraFormat.rate(model.readout.rates[index])
    return "\(ScopeFormat.scale(s.unitsPerDiv, unit: model.unit(index))) · \(rate)"
  }
}

/// The channel sheet: source picker (grouped streams with badge, unit and rate), enable,
/// coupling, invert, scale, offset, auto-scale, Add to Patch.
struct ScopeChannelSheet: View {
  let model: ScopeModel
  let index: Int

  @Environment(AppModel.self) private var app

  var body: some View {
    let name = "CH\(index + 1)"
    let ch = model.settings.channels[index]
    ControlSheet(
      title: "\(name) · \(model.label(index))",
      resetDials: {
        model.mutate { s in
          s.channels[index].coupling = .dc
          s.channels[index].invert = false
          s.channels[index].position = 0
          s.channels[index].autoScale = true
        }
      }, resetDialsHint: "DC coupling, not inverted, centered and auto-scaled."
    ) {
      InstrumentPanel("Channel", number: "01", provenance: model.provenance(index)) {
        GlassToggle(
          "Show \(name)",
          isOn: Binding(get: { ch.enabled }, set: { on in model.mutate { $0.channels[index].enabled = on } }),
          // The rate the scope measures for this channel (the channel button shows the same).
          symbol: "eye",
          subtitle: model.stream(forChannel: index).map {
            "\($0.unit) · \($0.isIrregular ? "irregular" : SpectraFormat.rate(model.rate(index)))"
          })
          .accessibilityIdentifier("scope-enable")
        if model.isShown(index) {
          let (spec, list) = ScopeKnobs.scale(channel: index, unit: model.unit(index), tint: model.color(index))
          KnobGrid(
            specs: [spec, ScopeKnobs.offset(channel: index, tint: model.color(index))],
            value: { k in
              if k.id == spec.id {
                return Binding(
                  get: { ScopeKnobs.nearestIndex(model.settings.channels[index].unitsPerDiv, in: list) },
                  set: { v in
                    let upd = list[min(list.count - 1, max(0, Int(v.rounded())))]
                    model.mutate { s in
                      s.channels[index].unitsPerDiv = upd
                      s.channels[index].autoScale = false
                    }
                  })
              }
              return Binding(
                get: { model.settings.channels[index].position },
                set: { v in model.mutate { $0.channels[index].position = v } })
            }, columns: 2, showsSliders: true)
          GlassToggle(
            "Auto-scale",
            isOn: Binding(get: { ch.autoScale }, set: { on in model.mutate { $0.channels[index].autoScale = on } }),
            symbol: "arrow.up.and.down.text.horizontal", subtitle: "Refit units per division when the trace leaves the screen.")
            .accessibilityIdentifier("scope-autoscale")
        }
      }
      InstrumentPanel("Coupling", number: "02") {
        ChoiceChips(
          items: ScopeCoupling.allCases,
          selection: Binding(get: { ch.coupling }, set: { c in model.mutate { $0.channels[index].coupling = c } }),
          id: "scope-coupling"
        ) { c in ChipLabel(title: c.title) }
        .padding(.horizontal, -Theme.panelPadding)
        GlassToggle(
          "Invert",
          isOn: Binding(get: { ch.invert }, set: { on in model.mutate { $0.channels[index].invert = on } }),
          symbol: "arrow.up.arrow.down", subtitle: "Flip the trace (and the trigger slope it sees).")
          .accessibilityIdentifier("scope-invert")
        Text(couplingCaption(ch.coupling)).panelCaption()
      }
      InstrumentPanel("Source", number: "03") {
        if model.fixedStreams != nil {
          // An embedded scope (a Patch Scope sink) shows the streams it was given.
          Text(
            model.stream(forChannel: index).map { "\($0.label) (\($0.id.rawValue)), \($0.unit). This scope shows the streams cabled into it; rewire them in Patch." }
              ?? "Nothing is cabled into this channel; rewire it in Patch."
          )
          .panelCaption()
        } else {
          ScopeSourcePicker(model: model, selection: ch.stream) { id in
            model.mutate { s in
              s.channels[index].stream = id
              s.channels[index].query = nil
              s.channels[index].enabled = true
              s.channels[index].autoScale = true
              s.preset = nil
            }
          }
          if model.stream(forChannel: index) != nil {
            ActionButton("Add to Patch", symbol: "point.3.connected.trianglepath.dotted") { model.addToPatch(index) }
              .accessibilityIdentifier("scope-add-to-patch")
          }
        }
      }
    }
    .onDisappear { model.endBrowsing() }
  }

  private func couplingCaption(_ c: ScopeCoupling) -> String {
    let rate = model.stream(forChannel: index)?.nominalRate
    switch c {
    case .dc: return "DC: the signal as measured."
    case .ac:
      return "AC: a one-pole high-pass at \(SpectraFormat.frequency(ScopeEngine.acCorner(sampleRate: (rate ?? 0) > 0 ? rate : nil))) removes the steady part."
    case .removeGravity:
      if let s = model.stream(forChannel: index), (s.id.rawValue + " " + s.label).lowercased().contains("user") {
        return "No gravity: this stream is user acceleration, so Core Motion has already removed gravity; a 0.25 Hz high-pass also takes out its slow drift."
      }
      return model.gravityIsFiltered(index)
        ? "No gravity: no gravity stream for this axis, so a 0.25 Hz high-pass removes the steady 1 g (tilting slowly also fades)."
        : "No gravity: subtracts the device-motion gravity on this axis, sample by sample."
    case .removeEarthField:
      return "No Earth field: a 0.01 Hz high-pass removes the steady 25–65 µT; mains hum and a passing magnet stay."
    }
  }
}

/// Every registered stream grouped as the bus lists them, plus sensors that are not running
/// (tap to start them; a permission prompt, if any, belongs to that tap).
struct ScopeSourcePicker: View {
  let model: ScopeModel
  let selection: StreamID?
  let choose: (StreamID) -> Void

  @Environment(AppModel.self) private var app

  var body: some View {
    let groups = app.streams.groups
    VStack(alignment: .leading, spacing: 14) {
      ForEach(groups, id: \.name) { group in
        VStack(alignment: .leading, spacing: 6) {
          Eyebrow(group.name)
          ForEach(group.streams) { s in
            Button {
              Haptics.shared.selection()
              choose(s.id)
            } label: {
              HStack(spacing: 8) {
                Image(systemName: s.id == selection ? "largecircle.fill.circle" : "circle")
                  .foregroundStyle(s.id == selection ? Theme.phosphor : Theme.muted)
                VStack(alignment: .leading, spacing: 2) {
                  Text(s.label).font(.subheadline).foregroundStyle(Theme.text).lineLimit(2)
                  Text("\(s.id.rawValue) · \(s.unit) · \(s.isIrregular ? "irregular" : SpectraFormat.rate(s.measuredRate ?? s.nominalRate))")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(Theme.muted)
                    .lineLimit(1)
                }
                Spacer(minLength: 6)
                ProvenanceBadge(s.provenance, compact: true)
              }
              .frame(minHeight: 44)
              .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(s.id == selection ? .isSelected : [])
            .accessibilityIdentifier("scope-source-\(s.id.rawValue)")
          }
        }
      }
      let idle = SensorID.allCases.filter { id in
        !app.live.channel(id).state.isRunning && app.live.channel(id).streams.isEmpty
      }
      if !idle.isEmpty {
        VStack(alignment: .leading, spacing: 6) {
          Eyebrow("Sensors not running", color: Theme.amber)
          ForEach(idle) { id in
            let channel = app.live.channel(id)
            let locked: Bool = {
              if case .locked = channel.state { return true }
              if case .unavailable = channel.state { return true }
              return !app.live.isEnabled(id)
            }()
            HStack {
              Label(channel.title, systemImage: channel.symbol).font(.subheadline)
              Spacer()
              Button("Start") {
                Haptics.shared.tap()
                // Held while this sheet is open (and after, if a channel then shows it).
                model.startSensorForPicking(id)
              }
              .buttonStyle(.glass)
              .disabled(locked)
              .accessibilityIdentifier("scope-start-\(id.rawValue)")
            }
            .frame(minHeight: 44)
            if let reason = channel.state.reason ?? (app.live.isEnabled(id) ? nil : "Turned off in Settings → Sensors.") {
              Text(reason).font(.caption).foregroundStyle(Theme.muted)
            }
          }
        }
      }
      if groups.isEmpty, idle.isEmpty {
        Text("No streams are running yet.").panelCaption()
      }
    }
  }
}

/// The math sheet: operation, inputs, corner, scale and offset.
struct ScopeMathSheet: View {
  let model: ScopeModel

  @Environment(AppModel.self) private var app

  var body: some View {
    let m = model.settings.math
    ControlSheet(
      title: "Math · \(m.label ?? m.operation.formula)",
      resetDials: {
        model.mutate { s in
          s.math.position = 0
          s.math.autoScale = true
          s.math.cornerHz = 1
        }
      }, resetDialsHint: "Centered, auto-scaled, 1 Hz high-pass corner."
    ) {
      InstrumentPanel("Math channel", number: "01", provenance: model.provenance(4)) {
        GlassToggle(
          "Show math", isOn: Binding(get: { m.enabled }, set: { on in model.mutate { $0.math.enabled = on } }),
          symbol: "function", subtitle: pairing(m.operation))
          .accessibilityIdentifier("scope-math-enable")
        ChoiceChips(
          items: ScopeEngine.MathOperation.allCases,
          selection: Binding(
            get: { m.operation },
            set: { op in
              model.mutate { s in
                s.math.operation = op
                s.math.label = nil
                s.math.enabled = true
                s.math.autoScale = true
              }
            }), id: "scope-math-op"
        ) { op in ChipLabel(title: op.title) }
        .padding(.horizontal, -Theme.panelPadding)
        ForEach(0..<m.operation.inputs, id: \.self) { k in
          inputRow(k)
        }
        if m.operation == .highPass {
          KnobGrid(
            specs: [ScopeKnobs.corner],
            value: { _ in Binding(get: { model.settings.math.cornerHz }, set: { v in model.mutate { $0.math.cornerHz = v } }) },
            columns: 1)
        }
      }
      if m.enabled {
        InstrumentPanel("Scale", number: "02") {
          let (spec, list) = ScopeKnobs.scale(channel: 4, unit: model.unit(4), tint: model.color(4))
          KnobGrid(
            specs: [spec, ScopeKnobs.offset(channel: 4, tint: model.color(4))],
            value: { k in
              if k.id == spec.id {
                return Binding(
                  get: { ScopeKnobs.nearestIndex(model.settings.math.unitsPerDiv, in: list) },
                  set: { v in
                    let upd = list[min(list.count - 1, max(0, Int(v.rounded())))]
                    model.mutate { s in
                      s.math.unitsPerDiv = upd
                      s.math.autoScale = false
                    }
                  })
              }
              return Binding(get: { model.settings.math.position }, set: { v in model.mutate { $0.math.position = v } })
            }, columns: 2, showsSliders: true)
          GlassToggle(
            "Auto-scale",
            isOn: Binding(get: { m.autoScale }, set: { on in model.mutate { $0.math.autoScale = on } }),
            symbol: "arrow.up.and.down.text.horizontal")
            .accessibilityIdentifier("scope-math-autoscale")
        }
      }
    }
  }

  private func inputRow(_ k: Int) -> some View {
    let names = ["A", "B", "C"]
    let current: ScopeSource = [model.settings.math.a, model.settings.math.b, model.settings.math.c][k]
    return HStack {
      Text(names[k]).font(.system(.headline, design: .serif).italic()).foregroundStyle(Theme.violetRGB.color)
      Menu {
        ForEach(0..<4, id: \.self) { i in
          Button("CH\(i + 1) · \(model.label(i))") { set(k, .channel(i)) }
        }
        ForEach(app.streams.groups, id: \.name) { group in
          Section(group.name) {
            ForEach(group.streams) { s in
              Button(s.label) { set(k, .stream(s.id)) }
            }
          }
        }
      } label: {
        Text(describe(current)).font(.subheadline).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
      }
      .buttonStyle(.glass)
      .simultaneousGesture(TapGesture().onEnded { Haptics.shared.tap() })
      .accessibilityIdentifier("scope-math-input-\(names[k].lowercased())")
    }
    .frame(minHeight: 44)
  }

  /// How the operation's inputs line up in time (only the inputs it reads).
  private func pairing(_ op: ScopeEngine.MathOperation) -> String {
    switch op.inputs {
    case 1: "\(op.formula) on A's own timestamps."
    case 2: "\(op.formula) on A's timestamps; B is paired to them by time."
    default: "\(op.formula) on A's timestamps; B and C are paired to them by time."
    }
  }

  private func describe(_ s: ScopeSource) -> String {
    switch s {
    case .channel(let i): "CH\(i + 1) · \(model.label(i))"
    case .stream(let id): app.streams.stream(id)?.label ?? id.rawValue
    }
  }

  private func set(_ k: Int, _ source: ScopeSource) {
    Haptics.shared.selection()
    model.mutate { s in
      switch k {
      case 0: s.math.a = source
      case 1: s.math.b = source
      default: s.math.c = source
      }
      s.math.queries[k] = nil
      s.math.label = nil
      s.math.autoScale = true
    }
  }
}

/// A small chip row for picking a channel index (CH1…CH4, optionally M).
struct ScopeChannelChips: View {
  let model: ScopeModel
  @Binding var selection: Int
  var includesMath = true
  var onlyShown = false
  let id: String

  private struct Item: Identifiable, Hashable {
    let id: Int
  }

  var body: some View {
    let all = (0..<(includesMath ? 5 : 4)).filter { !onlyShown || model.isShown($0) || $0 == selection }
    ChoiceChips(
      items: all.map { Item(id: $0) },
      selection: Binding(get: { Item(id: selection) }, set: { selection = $0.id }), id: id, tint: model.color(selection)
    ) { item in
      HStack(spacing: 5) {
        Circle().fill(model.color(item.id)).frame(width: 7, height: 7)
        Text(item.id == 4 ? "M" : "CH\(item.id + 1)")
      }
    }
    .padding(.horizontal, -Theme.panelPadding)
  }
}
