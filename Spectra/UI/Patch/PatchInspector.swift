import SwiftUI

/// The node inspector sheet: a live view, readouts with badges, the node's knobs and
/// choices, its connections (the button alternative to dragging cables), and actions.
struct PatchInspector: View {
  let nodeID: String

  @Environment(AppModel.self) private var app
  @Environment(\.dismiss) private var dismiss
  @Environment(\.dynamicTypeSize) private var typeSize
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var confirmDelete = false
  /// The dial being turned (its readout floats above the dials).
  @State private var activeKnob: String?
  @State private var title = ""
  @State private var detent: PresentationDetent = .medium

  var body: some View {
    let model = app.patch
    // A dial a Knob target drives draws its live arc: while one does, the whole sheet follows
    // the running graph (15 Hz); otherwise only the Overview and Live panels redraw.
    let _ = model.isDriven(nodeID) ? model.revision : 0
    NavigationStack {
      Group {
        if let node = model.graph.node(nodeID) {
          ScrollViewReader { proxy in
            ScrollView {
              VStack(alignment: .leading, spacing: Theme.stackSpacing) {
                overview(node)
                live(node).id("live")
                parameters(node).id("dials")
                connections(node).id("cables")
                actions(node)
              }
              .padding(Theme.gutter)
            }
            .accessibilityIdentifier("patch-inspector-scroll")
            .onAppear {
              guard let focus = model.inspectorFocus else { return }
              model.inspectorFocus = nil
              detent = .large
              Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(600))
                proxy.scrollTo(focus, anchor: .top)
              }
            }
          }
        } else {
          ContentUnavailableView("Node removed", systemImage: "trash", description: Text("This node is no longer in the patch."))
        }
      }
      .background(Theme.background)
      .safeAreaInset(edge: .bottom, spacing: 0) {
        if let node = model.graph.node(nodeID), !node.spec.params.isEmpty { resetBar(node) }
      }
      .navigationTitle(model.graph.node(nodeID)?.title ?? "Node")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") {
            Haptics.shared.tap()
            dismiss()
          }
          .accessibilityIdentifier("patch-inspector-done")
        }
      }
    }
    .presentationDetents([.medium, .large], selection: $detent)
    .presentationDragIndicator(.visible)
    .presentationBackgroundInteraction(.enabled(upThrough: .medium))
    .confirmationDialog("Delete this node and its cables?", isPresented: $confirmDelete, titleVisibility: .visible) {
      Button("Delete node", role: .destructive) {
        model.remove(node: nodeID)
        dismiss()
      }
      Button("Cancel", role: .cancel) {}
    }
  }

  /// Reset dials, pinned at the bottom of the sheet like every control sheet's.
  private func resetBar(_ node: PatchNode) -> some View {
    Button {
      Haptics.shared.resetClick()
      app.patch.resetParameters(node.id)
    } label: {
      Label("Reset dials", systemImage: "arrow.counterclockwise")
        .font(.subheadline.weight(.semibold))
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, minHeight: 32)
        .padding(.vertical, 6)
    }
    .buttonStyle(.glass)
    .tint(Theme.phosphor)
    .accessibilityHint("Restore every dial and choice of this node to its default.")
    .accessibilityIdentifier("patch-inspector-reset")
    .padding(12)
    .frame(maxWidth: .infinity)
    .background(Theme.background.opacity(0.96))
  }

  // MARK: 01 Overview

  private func overview(_ node: PatchNode) -> some View {
    PatchInspectorOverview(node: node, title: $title)
  }

  // MARK: 02 Live view

  private func live(_ node: PatchNode) -> some View {
    // The panel, its badges included, redraws at 15 Hz while on screen; the rest of the
    // inspector (dials, cables, actions) redraws only when the patch changes.
    VisibleTimeline(minimumInterval: 1.0 / 15) { _ in
      let _ = app.patch.revision
      InstrumentPanel("Live", number: "02", provenance: app.patch.preview(node.id).provenance) {
        VStack(alignment: .leading, spacing: 12) {
          PatchLiveView(node: node)
          readouts(node)
        }
      }
    }
  }

  private func readouts(_ node: PatchNode) -> some View {
    let model = app.patch
    let values: [(String, String, [Provenance])] = node.spec.outputs.compactMap { p in
      guard let v = model.snapshot.value(at: PortRef(node.id, p.name)) else { return nil }
      var text: String
      switch v.payload {
      case .control(let x):
        text = Self.format(x, port: p.name, kind: node.kind)
        // A Live stream's value is in its stream's unit ("48.2 µT", "−62 dBm").
        if node.kind == .stream {
          let unit = model.streamUnit(node.id)
          if !unit.isEmpty { text += " \(unit)" }
        }
      case .em(let w): text = SpectraFormat.wavelength(w.lambda)
      case .audio(let b): text = b.isIrregular ? "\(b.count) events" : "\(b.count) @ \(SpectraFormat.frequency(b.sampleRate))"
      case .iq(let b): text = "\(b.count) @ \(SpectraFormat.frequency(b.sampleRate))"
      case .bits(let b): text = "\(b.bits.count) bits"
      case .spectrum(let s): text = s.peakHz.map { "peak \(SpectraFormat.frequency(abs($0)))" } ?? "\(s.values.count) bins"
      case .image(let i): text = "\(i.image.plane.rows)×\(i.image.plane.columns)"
      case .attitude: text = "quaternion"
      case .event(let e): text = "\(e.times.count) events"
      }
      return (p.title, text, v.provenance)
    }
    return Group {
      if !values.isEmpty {
        ReadoutGrid(columns: 2) {
          ForEach(values, id: \.0) { v in
            PatchReadout(title: v.0, value: v.1, provenance: v.2)
          }
        }
      }
    }
  }

  static func format(_ x: Double, port: String, kind: NodeKind) -> String {
    switch (kind, port) {
    case (_, "snr"), (.antenna, "gain"): String(format: "%.1f dB", x)
    case (_, "rxPower"): String(format: "%.1f dBm", x)
    case (_, "evm"): String(format: "%.2f %%", x)
    case (_, "ber"): x == 0 ? "0" : SpectraFormat.scientific(x, digits: 2)
    case (.blackbody, "peak"): SpectraFormat.wavelength(x)
    case (_, "frequency"), (_, "peak"): SpectraFormat.frequency(abs(x))
    case (_, "larmor"), (_, "precession"), (_, "nod"): SpectraFormat.frequency(abs(x))
    case (_, "spin"): String(format: "%.0f rpm", x)
    case (_, "yaw"), (_, "pitch"), (_, "roll"): String(format: "%.1f°", x)
    case (_, "transmission"): SpectraFormat.significant(x, 3)
    case (.marginal, "error"): SpectraFormat.scientific(max(x, 1e-18), digits: 1)
    default: SpectraFormat.significant(x, 4)
    }
  }

  // MARK: 03 Parameters

  @ViewBuilder private func parameters(_ node: PatchNode) -> some View {
    let params = visibleParams(node)
    if !params.isEmpty {
      InstrumentPanel("Dials", number: "03") {
        let numbers = params.filter { $0.isModulatable }
        if !numbers.isEmpty {
          GlassEffectContainer(spacing: 18) {
            // Like KnobGrid: fewer columns at accessibility sizes, so dial labels stay legible.
            LazyVGrid(
              columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: typeSize.isAccessibilitySize ? 2 : 3), spacing: 12
            ) {
              ForEach(numbers) { p in knob(p, node) }
            }
          }
          // Gyre's floating readout names the dial you are turning and what it does.
          .overlay(alignment: .top) {
            if let id = activeKnob, let p = numbers.first(where: { $0.id == id }) {
              let spec = Self.knobSpec(p, node: node)
              KnobReadout(spec: spec, value: node.number(p.id), modulation: modulation(p, node, spec: spec))
                .offset(y: -86)
                .transition(.opacity.combined(with: .scale(scale: 0.92, anchor: .bottom)))
            }
          }
          .animation(reduceMotion ? nil : .spring(duration: 0.3, bounce: 0.25), value: activeKnob)
          if let reason = lockReason(node) {
            Label(reason, systemImage: "lock").font(.footnote).foregroundStyle(Theme.muted)
          } else {
            SheetCaption("Drag a dial up or right. Long-press one to drive it from another node.")
          }
        }
        ForEach(params.filter { !$0.isModulatable }) { p in other(p, node) }
      }
    }
  }

  /// Parameters that matter in the node's current mode.
  private func visibleParams(_ n: PatchNode) -> [ParamSpec] {
    let mode = n.string("mode")
    return n.spec.params.filter { p in
      switch (n.kind, p.id) {
      case (.modulator, "depth"), (.demodulator, "depth"): return mode == "am"
      case (.modulator, "deviation"), (.demodulator, "deviation"): return mode == "fm"
      case (.modulator, "symbolRate"), (.demodulator, "symbolRate"):
        return !NodeCatalog.analogModes.contains(mode) && mode != "ofdm" && mode != "auto"
      case (.modulator, "order"), (.demodulator, "order"): return mode == "ofdm"
      case (.demodulator, "carrier"): return false
      case (.demodulator, "payload"): return mode != "auto" && !NodeCatalog.analogModes.contains(mode)
      case (.channel, "material"): return n.number("walls") >= 1
      case (.antenna, "elements"), (.antenna, "steer"), (.antenna, "beamLock"): return n.string("style") == "phasedArray"
      case (.bits, "text"): return n.string("mode") == "text"
      default: return true
      }
    }
  }

  private func lockReason(_ n: PatchNode) -> String? {
    switch n.kind {
    case .spectraSource where n.string("follow") == "A": "Wavelength follows Spectrum source A: choose Own dial to turn it."
    default: nil
    }
  }

  private func isLocked(_ p: ParamSpec, _ n: PatchNode) -> String? {
    let g = app.patch.graph
    switch (n.kind, p.id) {
    case (.spectraSource, "lambda"):
      return n.string("follow") == "A" ? "Following Spectrum source A" : nil
    case (.spinFID, "field"): return g.cable(into: PortRef(n.id, "field")) != nil ? "Driven by the B input" : nil
    case (.blackbody, "temperature"): return g.cable(into: PortRef(n.id, "temperature")) != nil ? "Driven by the T input" : nil
    case (.modulator, "carrier"): return g.cable(into: PortRef(n.id, "carrier")) != nil ? "Set by the carrier input" : nil
    case (.antenna, "steer"):
      if n.flag("beamLock") { return "Beam lock steers it" }
      return g.cable(into: PortRef(n.id, "steer")) != nil ? "Driven by the steer input" : nil
    default: return nil
    }
  }

  /// The live drive of one of the node's dials (a dashed arc and "Driven by …").
  private func modulation(_ p: ParamSpec, _ n: PatchNode, spec: KnobSpec) -> KnobModulation? {
    app.patch.snapshot.drives["\(n.id).\(p.id)"].map {
      KnobModulation(
        value: spec.scale.modulated(base: n.number(p.id), depth: $0.depth, cv: $0.cv), color: Theme.amber, source: $0.source,
        depth: abs($0.depth))
    }
  }

  private func knob(_ p: ParamSpec, _ n: PatchNode) -> some View {
    let model = app.patch
    let spec = Self.knobSpec(p, node: n)
    let locked = isLocked(p, n)
    // The linear slider under every dial is the precise, accessible alternative (house rule:
    // dials have a slider fallback), as on every other tab's knobs.
    return GlassKnob(
      spec: spec,
      value: Binding(get: { app.patch.graph.node(n.id)?.number(p.id) ?? spec.defaultValue }, set: { model.setNumber(n.id, p.id, $0) }),
      modulation: modulation(p, n, spec: spec), showsSlider: true,
      onActive: { on in activeKnob = on ? p.id : (activeKnob == p.id ? nil : activeKnob) },
      onModulate: { model.modulateParam(n.id, p.id) }
    )
    .disabled(locked != nil)
    .opacity(locked == nil ? 1 : 0.45)
    .accessibilityHint(locked ?? p.hint)
  }

  static func knobSpec(_ p: ParamSpec, node: PatchNode) -> KnobSpec {
    guard case .number(let scale, let def, let format, let detents) = p.kind else {
      return KnobSpec(id: "patch-\(node.id)-\(p.id)", title: p.title, range: 0...1, defaultValue: 0)
    }
    let tint: Color =
      switch format {
      case .wavelength: Theme.dialLambda(node.number(p.id))
      case .frequency where p.id == "carrier" || (node.kind == .antenna && p.id == "frequency"):
        BandPalette.color(forFrequency: node.number(p.id))
      case .degrees: Theme.dialTheta
      case .fieldStrength: Theme.dialE0
      default: Theme.amber
      }
    return KnobSpec(
      id: "patch-\(node.id)-\(p.id)", title: p.title, glyph: p.glyph, tint: tint, range: scale.range, defaultValue: def,
      logarithmic: scale.logarithmic, step: scale.step, detents: detents.map { KnobDetent($0.value, $0.label) }, hint: p.hint,
      format: Self.formatter(format))
  }

  static func formatter(_ f: ParamFormat) -> (Double) -> String {
    switch f {
    case .plain(let unit): { unit.isEmpty ? SpectraFormat.significant($0, 3) : "\(SpectraFormat.significant($0, 3)) \(unit)" }
    case .frequency: { SpectraFormat.frequency($0) }
    case .decibels(let unit): { SpectraFormat.decibels($0, unit: unit, decimals: 1) }
    case .percent: { "\(Int(($0 * 100).rounded())) %" }
    case .degrees: { String(format: "%.1f°", $0) }
    case .distance: { $0 >= 1000 ? "\(SpectraFormat.significant($0 / 1000, 3)) km" : "\(SpectraFormat.significant($0, 3)) m" }
    case .wavelength: { SpectraFormat.wavelength($0) }
    case .seconds: { SpectraFormat.si($0, unit: "s") }
    case .microtesla: { String(format: "%.1f µT", $0) }
    case .integer(let unit): { unit.isEmpty ? "\(Int($0.rounded()))" : "\(Int($0.rounded())) \(unit)" }
    case .fieldStrength: { SpectraFormat.si($0, unit: "V/m") }
    case .symbolRate: { SpectraFormat.si($0, unit: "Bd") }
    }
  }

  @ViewBuilder private func other(_ p: ParamSpec, _ n: PatchNode) -> some View {
    let model = app.patch
    switch p.kind {
    case .choice(let options, _):
      VStack(alignment: .leading, spacing: 6) {
        Eyebrow(p.title.instrumentCaps)
        if options.count <= 4 {
          ChoiceChips(
            items: options,
            selection: Binding(
              get: { options.first { $0.key == (app.patch.graph.node(n.id)?.string(p.id) ?? "") } ?? options[0] },
              set: { model.setString(n.id, p.id, $0.key) }),
            id: "patch-\(n.id)-\(p.id)"
          ) { o in Text(o.title) }
          .padding(.horizontal, -Theme.gutter)
        } else {
          Menu {
            ForEach(options) { o in
              Button(o.title) {
                Haptics.shared.selection()
                model.setString(n.id, p.id, o.key)
              }
            }
          } label: {
            HStack {
              Text(options.first { $0.key == n.string(p.id) }?.title ?? n.string(p.id))
                .font(.subheadline.weight(.medium))
              Spacer()
              Image(systemName: "chevron.up.chevron.down").font(.caption)
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 40)
            .foregroundStyle(Theme.text)
          }
          .glassEffect(.regular.interactive(), in: .rect(cornerRadius: Theme.chipRadius))
          .accessibilityLabel(p.title)
          .accessibilityValue(options.first { $0.key == n.string(p.id) }?.title ?? "")
          .accessibilityIdentifier("patch-\(n.id)-\(p.id)")
        }
        if !p.hint.isEmpty { SheetCaption(p.hint) }
      }
    case .toggle:
      GlassToggle(
        p.title, isOn: Binding(get: { app.patch.graph.node(n.id)?.flag(p.id) ?? false }, set: { model.setNumber(n.id, p.id, $0 ? 1 : 0) }),
        symbol: "switch.2", subtitle: p.hint.isEmpty ? nil : p.hint)
      .accessibilityIdentifier("patch-\(n.id)-\(p.id)")
    case .text:
      TextEntry(title: p.title, value: n.string(p.id), id: "patch-\(n.id)-\(p.id)") { model.setString(n.id, p.id, $0) }
    case .stream:
      StreamPicker(nodeID: n.id, current: n.string(p.id))
    case .target:
      TargetPicker(nodeID: n.id, current: n.string(p.id))
    case .number:
      EmptyView()
    }
  }

  /// Panels count on without a gap when a node has no dials (Marginal, Scope).
  private func panelNumber(_ base: Int, _ node: PatchNode) -> String {
    String(format: "%02d", base + (visibleParams(node).isEmpty ? 0 : 1))
  }

  // MARK: 04 Connections

  private func connections(_ node: PatchNode) -> some View {
    let model = app.patch
    let g = model.graph
    return InstrumentPanel("Cables", number: panelNumber(3, node)) {
      if !node.spec.inputs.isEmpty {
        Eyebrow("INPUTS")
        ForEach(node.spec.inputs) { p in
          let ref = PortRef(node.id, p.name)
          HStack(spacing: 8) {
            PortDot(types: p.types, color: PatchColors.port(p.types), connected: g.cable(into: ref) != nil, glow: false, strong: false)
              .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
              Text(p.title).font(.subheadline.weight(.medium)).foregroundStyle(Theme.text)
              Text(g.cable(into: ref).map { source($0.from) } ?? p.types.map(\.title).joined(separator: " or "))
                .font(.caption).foregroundStyle(Theme.muted)
            }
            Spacer(minLength: 4)
            if g.cable(into: ref) != nil {
              Button("Unplug") { model.disconnect(input: ref) }
                .buttonStyle(.glass)
                .accessibilityIdentifier("patch-unplug-\(node.id)-\(p.name)")
            } else {
              let options = candidates(into: ref)
              Menu {
                if options.isEmpty {
                  Text("No output fits this input yet")
                }
                ForEach(options, id: \.self) { from in
                  Button(source(from)) {
                    model.connect(from: from, to: ref)
                  }
                }
              } label: {
                Text("Connect…").font(.subheadline.weight(.medium)).padding(.horizontal, 6).frame(minHeight: 32)
              }
              .buttonStyle(.glass)
              .accessibilityIdentifier("patch-connect-\(node.id)-\(p.name)")
            }
          }
        }
      }
      if !node.spec.outputs.isEmpty {
        Eyebrow("OUTPUTS")
        ForEach(node.spec.outputs) { p in
          let ref = PortRef(node.id, p.name)
          let out = g.cables(from: ref)
          HStack(spacing: 8) {
            PortDot(
              types: g.outputTypes(ref), color: PatchColors.port(g.outputTypes(ref)), connected: !out.isEmpty, glow: false, strong: false
            )
            .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
              Text(p.title).font(.subheadline.weight(.medium)).foregroundStyle(Theme.text)
              Text(out.isEmpty ? "Not connected" : out.map { destination($0.to) }.joined(separator: ", "))
                .font(.caption).foregroundStyle(Theme.muted)
            }
            Spacer(minLength: 0)
          }
          .accessibilityElement(children: .combine)
        }
      }
    }
  }

  private func source(_ ref: PortRef) -> String {
    let g = app.patch.graph
    guard let n = g.node(ref.node) else { return ref.description }
    return "\(n.title) · \(n.spec.output(ref.port)?.title ?? ref.port)"
  }

  private func destination(_ ref: PortRef) -> String {
    let g = app.patch.graph
    guard let n = g.node(ref.node) else { return ref.description }
    return "\(n.title) · \(n.spec.input(ref.port)?.title ?? ref.port)"
  }

  /// Every output that may feed `input` (typed, no loop).
  private func candidates(into input: PortRef) -> [PortRef] {
    let g = app.patch.graph
    var out: [PortRef] = []
    for n in g.nodes where n.id != input.node {
      for p in n.spec.outputs {
        let ref = PortRef(n.id, p.name)
        if g.check(from: ref, to: input) == nil { out.append(ref) }
      }
    }
    return out
  }

  // MARK: 05 Actions

  @ViewBuilder private func actions(_ node: PatchNode) -> some View {
    let model = app.patch
    if node.kind == .scope {
      let ids = model.scopeStreamIDs(for: node.id)
      if ids.isEmpty {
        SheetCaption("Cable signals into CH1–CH4; each becomes a stream on the scope bus named after this node.")
      } else {
        ScopeView(fixedStreams: ids)
      }
    }
    InstrumentPanel("Actions", number: panelNumber(4, node)) {
      FlowLayout(spacing: 8) {
        if node.kind == .scope || node.kind == .stream || !model.scopeTaps(for: node).isEmpty {
          ActionButton("Open in Scope", symbol: "waveform.path.ecg") { model.openInScope(node.id) }
            .accessibilityIdentifier("patch-inspector-open-scope")
            .accessibilityHint("Shows this node's signals in the Live tab's Scope; the patch keeps running there.")
        }
        if node.kind == .ruler {
          ActionButton("Send to Spectrum", symbol: "ruler", prominent: true) { model.sendRuler(node.id) }
            .accessibilityIdentifier("patch-inspector-send")
            // The ruler's marker is observed; its value table is not.
            .disabled(model.liveMarkers[node.id] == nil)
        }
        ActionButton("Duplicate", symbol: "square.on.square") {
          if let id = model.duplicate(node: node.id) { model.inspecting = id }
        }
        .accessibilityIdentifier("patch-inspector-duplicate")
        ActionButton("Delete", symbol: "trash", tint: Theme.ionizing) { confirmDelete = true }
          .accessibilityIdentifier("patch-inspector-delete")
      }
    }
  }
}

/// The inspector's 01 panel: what the node is, its badges and status (they follow the running
/// graph at 15 Hz, so only this panel redraws, not the whole sheet), Start, and the title.
struct PatchInspectorOverview: View {
  let node: PatchNode
  @Binding var title: String
  @Environment(AppModel.self) private var app

  var body: some View {
    let model = app.patch
    // Badges and status follow the running graph (previews refresh at 15 Hz).
    let _ = model.revision
    let preview = model.preview(node.id)
    InstrumentPanel(
      node.spec.category.title, number: "01", provenance: preview.provenance.isEmpty ? node.spec.provenance : preview.provenance
    ) {
      Text(node.spec.summary).font(.callout).foregroundStyle(Theme.text).fixedSize(horizontal: false, vertical: true)
      if let s = model.status(node.id) {
        Label(s.text, systemImage: s.level == .warning ? "exclamationmark.triangle" : (s.level == .waiting ? "hourglass" : "info.circle"))
          .font(.footnote)
          .foregroundStyle(s.level == .warning ? Theme.ionizing : Theme.muted)
          .accessibilityIdentifier("patch-inspector-status")
      }
      if let s = model.sensorState(for: node), s.needsTap {
        ActionButton("Start the \(s.sensor.title)", symbol: "play.fill", prominent: true) { model.startSensor(s.sensor) }
          .accessibilityIdentifier("patch-inspector-start")
        SheetCaption("Spectra asks for access on this tap, then reads the sensor only while the Patch tab is open.")
      }
      HStack {
        TextField("Title", text: $title, prompt: Text(node.spec.title))
          .textFieldStyle(.roundedBorder)
          .font(.subheadline)
          .submitLabel(.done)
          .onSubmit { model.rename(node.id, title) }
          .accessibilityIdentifier("patch-inspector-title")
        Button("Rename") {
          Haptics.shared.tap()
          model.rename(node.id, title)
        }
        .buttonStyle(.glass)
        .disabled(title == (node.label ?? ""))
        .accessibilityIdentifier("patch-inspector-rename")
      }
      .onAppear { title = node.label ?? "" }
      // Picking a stream retitles the node: the field follows, so Rename does not undo it.
      .onChange(of: node.label) { _, label in title = label ?? "" }
    }
  }
}

/// A readout with every badge its value carries (rule R4: a graph output is the union of its
/// inputs' badges, so "MODEL · LIVE" must not shrink to "MODEL").
struct PatchReadout: View {
  let title: String
  let value: String
  let provenance: [Provenance]

  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      HStack(spacing: 4) {
        Text(title.instrumentCaps)
          .font(Theme.readoutTitleFont)
          .foregroundStyle(Theme.muted)
          .lineLimit(1)
          .minimumScaleFactor(0.75)
        ProvenanceBadges(provenance, compact: true)
      }
      Text(value)
        .font(Theme.readoutValueFont)
        .monospacedDigit()
        .foregroundStyle(Theme.amber)
        .lineLimit(1)
        .minimumScaleFactor(0.6)
    }
    .accessibilityElement(children: .combine)
  }
}

/// Wraps its children onto as many rows as they need.
nonisolated struct FlowLayout: Layout {
  var spacing: CGFloat = 8

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let width = proposal.width ?? 360
    var x: CGFloat = 0
    var y: CGFloat = 0
    var row: CGFloat = 0
    for s in subviews {
      let size = s.sizeThatFits(.unspecified)
      if x > 0, x + size.width > width {
        x = 0
        y += row + spacing
        row = 0
      }
      x += size.width + spacing
      row = max(row, size.height)
    }
    return CGSize(width: width, height: y + row)
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    var x = bounds.minX
    var y = bounds.minY
    var row: CGFloat = 0
    for s in subviews {
      let size = s.sizeThatFits(.unspecified)
      if x > bounds.minX, x + size.width > bounds.maxX {
        x = bounds.minX
        y += row + spacing
        row = 0
      }
      s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
      x += size.width + spacing
      row = max(row, size.height)
    }
  }
}

/// A text parameter with an explicit Set button (Return also sets it).
struct TextEntry: View {
  let title: String
  let value: String
  /// Identifier stem: the field is `<id>`, its button `<id>-set`.
  var id: String
  var onSet: (String) -> Void
  @State private var draft = ""

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Eyebrow(title.instrumentCaps)
      HStack {
        TextField(title, text: $draft)
          .textFieldStyle(.roundedBorder)
          .submitLabel(.done)
          .onSubmit { onSet(draft) }
          .accessibilityIdentifier(id)
        Button("Set") {
          Haptics.shared.tap()
          onSet(draft)
        }
        .buttonStyle(.glass)
        .disabled(draft == value)
        .accessibilityIdentifier("\(id)-set")
      }
    }
    .onAppear { draft = value }
    // Reset dials restores the default text: the field shows it.
    .onChange(of: value) { _, v in draft = v }
  }
}

/// Picks the stream a Live stream node reads, grouped as the scope bus groups them.
struct StreamPicker: View {
  let nodeID: String
  let current: String
  @Environment(AppModel.self) private var app

  var body: some View {
    let model = app.patch
    VStack(alignment: .leading, spacing: 6) {
      Eyebrow("STREAM")
      Menu {
        Button("Strongest Bluetooth device") {
          Haptics.shared.selection()
          model.setString(nodeID, "stream", "ble.*")
        }
        ForEach(app.streams.groups, id: \.name) { group in
          Section(group.name) {
            ForEach(group.streams.filter { !$0.id.rawValue.hasPrefix("patch.\(nodeID).") }) { s in
              Button("\(s.label) · \(s.unit)") {
                Haptics.shared.selection()
                model.setString(nodeID, "stream", s.id.rawValue)
              }
            }
          }
        }
        Section("Sensors not running yet") {
          // Sensor shortcuts whose stream is not on the bus yet (picking one starts it); the
          // strongest Bluetooth device is the first item above.
          ForEach(
            NodeCatalog.palette.filter { item in
              guard let s = item.stream, !s.isEmpty, s != "ble.*" else { return false }
              return app.streams.stream(StreamID(s)) == nil
            }
          ) { item in
            Button(item.title) {
              Haptics.shared.selection()
              model.setString(nodeID, "stream", item.stream ?? "")
            }
          }
        }
      } label: {
        HStack {
          Text(label).font(.subheadline.weight(.medium)).lineLimit(1)
          Spacer()
          Image(systemName: "chevron.up.chevron.down").font(.caption)
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 40)
        .foregroundStyle(Theme.text)
      }
      .glassEffect(.regular.interactive(), in: .rect(cornerRadius: Theme.chipRadius))
      .accessibilityLabel("Stream")
      .accessibilityValue(label)
      .accessibilityIdentifier("patch-\(nodeID)-stream")
      SheetCaption("Streams appear here while their sensor runs; picking one starts its sensor.")
    }
  }

  private var label: String {
    if current.isEmpty { return "Choose a stream" }
    if current == "ble.*" { return "Strongest Bluetooth device" }
    return app.streams.stream(StreamID(current)).map { "\($0.label) · \($0.unit)" } ?? current
  }
}

/// Picks the knob a Knob target drives.
struct TargetPicker: View {
  let nodeID: String
  let current: String
  @Environment(AppModel.self) private var app

  var body: some View {
    let model = app.patch
    let targets = model.targets(excluding: nodeID)
    VStack(alignment: .leading, spacing: 6) {
      Eyebrow("DRIVES")
      Menu {
        if targets.isEmpty { Text("Add a node with a dial first") }
        ForEach(targets, id: \.key) { t in
          Button(t.title) {
            Haptics.shared.selection()
            model.setString(nodeID, "target", t.key)
          }
        }
        if !current.isEmpty {
          Button("Drive nothing", role: .destructive) {
            Haptics.shared.resetClick()
            model.setString(nodeID, "target", "")
          }
        }
      } label: {
        HStack {
          Text(model.targetTitle(current) ?? "Pick a knob").font(.subheadline.weight(.medium)).lineLimit(1)
          Spacer()
          Image(systemName: "chevron.up.chevron.down").font(.caption)
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 40)
        .foregroundStyle(Theme.text)
      }
      .glassEffect(.regular.interactive(), in: .rect(cornerRadius: Theme.chipRadius))
      .accessibilityLabel("Drives")
      .accessibilityValue(model.targetTitle(current) ?? "Nothing")
      .accessibilityIdentifier("patch-\(nodeID)-target")
      SheetCaption("A full-scale signal (±1) turns the knob by the depth, in knob position, so log knobs move evenly.")
    }
  }
}
