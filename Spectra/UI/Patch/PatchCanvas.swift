import SwiftUI

/// A cable being dragged from an output port.
struct CableDrag: Equatable {
  var from: PortRef
  /// The finger, in canvas view coordinates.
  var point: CGPoint
  /// The input under the finger that would accept it.
  var target: PortRef?
}

/// Colours of the graph (rule R2: hue only for EM frequency).
enum PatchColors {
  static func color(_ tint: PatchTint) -> Color {
    switch tint {
    case .band(let lambda): BandPalette.color(forWavelength: lambda)
    case .phosphor: Theme.phosphor
    case .amber: Theme.amber
    case .idle: Theme.dim
    }
  }

  /// Port dot colour by type: EM and I/Q in the E-field blue, samples phosphor, control amber.
  static func port(_ types: [PortType]) -> Color {
    guard let t = types.first else { return Theme.dim }
    switch t {
    case .em, .iq: return Theme.fieldE
    case .audio, .spectrum, .image: return Theme.phosphor
    case .control, .event, .attitude, .bits: return Theme.amber
    }
  }
}

/// The pan/zoom canvas: grid, cables, cards, the live cable, and the floating toolbar.
struct PatchCanvasView: View {
  @Environment(AppModel.self) private var app
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var drag: CableDrag?
  @State private var panStart: CGSize?
  @State private var zoomStart: Double?
  @State private var moving: (id: String, start: CGPoint)?
  @State private var showPalette = false
  @State private var showPresets = false
  @State private var refusal: String?

  var body: some View {
    let model = app.patch
    GeometryReader { geo in
      ZStack(alignment: .topLeading) {
        background(model)
        cables(model)
        ForEach(model.graph.nodes) { node in
          PatchNodeCard(
            node: node, selected: model.selection == node.id, drag: drag,
            onTap: {
              Haptics.shared.selection()
              model.selection = node.id
              model.inspecting = node.id
            },
            onMove: { phase, translation in move(node, phase: phase, translation: translation, model: model) },
            onPortDrag: { port, isInput, phase, location in
              portDrag(node: node, port: port, isInput: isInput, phase: phase, location: location, model: model)
            })
          .frame(width: PatchGeometry.cardWidth, height: PatchGeometry.height(of: node.kind))
          .scaleEffect(model.zoom, anchor: .topLeading)
          .offset(x: node.x * model.zoom + model.offset.width, y: node.y * model.zoom + model.offset.height)
          .zIndex(model.selection == node.id ? 1 : 0)
        }
        if model.graph.nodes.isEmpty { emptyState(model) }
      }
      .frame(width: geo.size.width, height: geo.size.height)
      .clipped()
      .coordinateSpace(.named(PatchCanvasView.space))
      .contentShape(.rect)
      .simultaneousGesture(magnify(model))
      .overlay(alignment: .top) { toolbar(model) }
      .overlay(alignment: .bottomLeading) { statusChip(model) }
      .overlay(alignment: .bottom) {
        if let refusal {
          Text(refusal)
            .font(.footnote)
            .foregroundStyle(Theme.text)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .glassEffect(.regular.tint(Theme.ionizing.opacity(0.2)), in: .capsule)
            .padding(.bottom, 44)
            .transition(.opacity)
            .accessibilityIdentifier("patch-refusal")
        }
      }
      .onAppear {
        model.lastViewport = geo.size
        if model.needsFit || model.offset == .zero { model.fit(in: geo.size) }
        if let id = model.focusRequest {
          model.center(on: id)
          model.focusRequest = nil
        }
        switch model.launchSheet {
        case "palette": showPalette = true
        case "presets": showPresets = true
        default: break
        }
        model.launchSheet = nil
      }
      .onChange(of: geo.size) { _, size in
        model.lastViewport = size
        // The first layout passes can report a shorter canvas than the final one: a view the
        // automatic fit placed follows the size until you pan or zoom it yourself.
        if model.needsFit || model.autoFitted { model.fit(in: size) }
      }
      .onChange(of: model.focusRequest) { _, id in
        guard let id else { return }
        withAnimation(Theme.animation(reduceMotion)) { model.center(on: id) }
        model.focusRequest = nil
      }
      .accessibilityElement(children: .contain)
      .accessibilityLabel("Patch canvas")
      .accessibilityIdentifier("patch-canvas")
    }
    .sheet(isPresented: $showPalette) {
      PatchPalette { item in
        let id = model.add(item, at: model.freeSpot(kind: item.kind))
        model.focusRequest = id
      }
      .environment(app)
    }
    .sheet(isPresented: $showPresets) {
      NavigationStack {
        ScrollView {
          PatchPresetList { preset in
            model.load(preset: preset)
            showPresets = false
          }
          .padding(Theme.gutter)
        }
        .background(Theme.background)
        .navigationTitle("Presets")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
          ToolbarItem(placement: .confirmationAction) {
            Button("Done") {
              Haptics.shared.tap()
              showPresets = false
            }
            .accessibilityIdentifier("patch-presets-done")
          }
        }
      }
      .presentationDetents([.medium, .large])
      .environment(app)
    }
    .sheet(
      item: Binding(
        get: { model.inspecting.map(InspectorItem.init) },
        set: { model.inspecting = $0?.id })
    ) { item in
      PatchInspector(nodeID: item.id).environment(app)
    }
  }

  static let space = "patchCanvas"

  struct InspectorItem: Identifiable {
    let id: String
  }

  // MARK: Layers

  private func background(_ model: PatchModel) -> some View {
    Canvas { ctx, size in
      let pitch = 32 * model.zoom
      guard pitch > 6 else { return }
      var grid = Path()
      let ox = model.offset.width.truncatingRemainder(dividingBy: pitch)
      let oy = model.offset.height.truncatingRemainder(dividingBy: pitch)
      var x = ox
      while x < size.width {
        var y = oy
        while y < size.height {
          grid.addEllipse(in: CGRect(x: x - 0.8, y: y - 0.8, width: 1.6, height: 1.6))
          y += pitch
        }
        x += pitch
      }
      ctx.fill(grid, with: .color(Theme.phosphor.opacity(0.10)))
    }
    .background(Theme.plotWell)
    .contentShape(.rect)
    .gesture(pan(model))
    .onTapGesture {
      model.selection = nil
    }
    .accessibilityHidden(true)
  }

  private func cables(_ model: PatchModel) -> some View {
    VisibleTimeline(minimumInterval: 1.0 / 30, paused: reduceMotion || !model.isRunning) { date in
      let _ = model.revision
      Canvas { ctx, _ in
        let t = date.timeIntervalSinceReferenceDate
        for c in model.graph.cables {
          guard let a = portPoint(model, c.from, isInput: false), let b = portPoint(model, c.to, isInput: true) else { continue }
          let tint = model.tint(of: c)
          let color = PatchColors.color(tint)
          let path = Self.cablePath(a, b, zoom: model.zoom)
          let w = max(1.2, 2.2 * model.zoom)
          let highlighted = model.selection == c.from.node || model.selection == c.to.node
          ctx.phosphorStroke(path, color: color.opacity(tint == .idle ? 0.55 : 1), width: w, glow: highlighted ? 1.6 : 1)
          if model.isRunning, !reduceMotion, tint != .idle {
            // Signal flow: bright dashes travelling from output to input.
            ctx.stroke(
              path, with: .color(.white.opacity(0.55)),
              style: StrokeStyle(lineWidth: w * 0.7, lineCap: .round, dash: [3 * model.zoom, 15 * model.zoom], dashPhase: -t * 46 * model.zoom))
          }
        }
        if let drag, let a = portPoint(model, drag.from, isInput: false) {
          let path = Self.cablePath(a, drag.point, zoom: model.zoom)
          let color = PatchColors.port(model.graph.outputTypes(drag.from))
          ctx.phosphorStroke(path, color: color, width: max(1.4, 2.4 * model.zoom), glow: 1.4, dash: drag.target == nil ? [6, 5] : [])
          if let target = drag.target, let p = portPoint(model, target, isInput: true) {
            ctx.phosphorDot(at: p, color: color, radius: 6 * model.zoom)
          }
        }
      }
      .allowsHitTesting(false)
    }
  }

  static func cablePath(_ a: CGPoint, _ b: CGPoint, zoom: Double) -> Path {
    var p = Path()
    p.move(to: a)
    let (c1, c2) = PatchGeometry.cableControls(from: SIMD2(a.x, a.y), to: SIMD2(b.x, b.y), zoom: zoom)
    p.addCurve(to: b, control1: CGPoint(x: c1.x, y: c1.y), control2: CGPoint(x: c2.x, y: c2.y))
    return p
  }

  /// A port's centre in canvas view coordinates.
  private func portPoint(_ model: PatchModel, _ ref: PortRef, isInput: Bool) -> CGPoint? {
    guard let n = model.graph.node(ref.node),
      let o = PatchGeometry.portOffset(kind: n.kind, port: ref.port, isInput: isInput)
    else { return nil }
    return CGPoint(
      x: (n.x + o.x) * model.zoom + model.offset.width, y: (n.y + o.y) * model.zoom + model.offset.height)
  }

  // MARK: Gestures

  private func pan(_ model: PatchModel) -> some Gesture {
    DragGesture(minimumDistance: 4, coordinateSpace: .named(Self.space))
      .onChanged { g in
        if panStart == nil { panStart = model.offset }
        guard let s = panStart else { return }
        model.pan(to: CGSize(width: s.width + g.translation.width, height: s.height + g.translation.height))
      }
      .onEnded { _ in
        panStart = nil
        model.save()
      }
  }

  private func magnify(_ model: PatchModel) -> some Gesture {
    MagnifyGesture(minimumScaleDelta: 0.01)
      .onChanged { g in
        if zoomStart == nil {
          zoomStart = model.zoom
          Haptics.shared.grab()
        }
        guard let z0 = zoomStart else { return }
        let anchor = CGPoint(x: g.startAnchor.x * model.lastViewport.width, y: g.startAnchor.y * model.lastViewport.height)
        let before = model.zoom
        model.setZoom(z0 * g.magnification, around: anchor)
        if (before < 1) != (model.zoom < 1) { Haptics.shared.detent() }
      }
      .onEnded { _ in
        zoomStart = nil
        model.save()
      }
  }

  private func move(_ node: PatchNode, phase: GesturePhase, translation: CGSize, model: PatchModel) {
    switch phase {
    case .began:
      moving = (node.id, CGPoint(x: node.x, y: node.y))
      model.selection = node.id
      Haptics.shared.grab()
    case .changed:
      guard let m = moving, m.id == node.id else { return }
      var p = CGPoint(x: m.start.x + translation.width / model.zoom, y: m.start.y + translation.height / model.zoom)
      if model.snapToGrid {
        let snapped = CGPoint(x: (p.x / 8).rounded() * 8, y: (p.y / 8).rounded() * 8)
        if let cur = model.graph.node(node.id), abs(cur.x - snapped.x) >= 32 || abs(cur.y - snapped.y) >= 32 { Haptics.shared.tick() }
        p = snapped
      }
      model.move(node.id, to: p)
    case .ended:
      moving = nil
      model.endMove()
      Haptics.shared.detent()
    }
  }

  enum GesturePhase { case began, changed, ended }

  /// Drag from an output (new cable) or from a plugged input (unplug and re-plug its cable).
  private func portDrag(
    node: PatchNode, port: String, isInput: Bool, phase: GesturePhase, location: CGPoint, model: PatchModel
  ) {
    switch phase {
    case .began:
      if isInput {
        let input = PortRef(node.id, port)
        guard let cable = model.graph.cable(into: input) else {
          Haptics.shared.boundary()
          show("Drag from an output dot to an input dot.")
          return
        }
        model.disconnect(input: input)
        drag = CableDrag(from: cable.from, point: location)
      } else {
        drag = CableDrag(from: PortRef(node.id, port), point: location)
        Haptics.shared.grab()
      }
    case .changed:
      guard var d = drag else { return }
      d.point = location
      let next = nearestInput(model, to: location, from: d.from)
      if next != d.target, next != nil { Haptics.shared.tick() }
      d.target = next
      drag = d
    case .ended:
      guard let d = drag else { return }
      drag = nil
      if let target = d.target ?? nearestInput(model, to: location, from: d.from, accepting: false) {
        if let error = model.connect(from: d.from, to: target) { show(error.description) }
      } else {
        Haptics.shared.tick()
      }
    }
  }

  /// The input port within 30 pt of `point` that would accept a cable from `from`.
  private func nearestInput(_ model: PatchModel, to point: CGPoint, from: PortRef, accepting: Bool = true) -> PortRef? {
    var best: (PortRef, CGFloat)?
    for n in model.graph.nodes where n.id != from.node {
      for p in n.spec.inputs {
        let ref = PortRef(n.id, p.name)
        guard let c = portPoint(model, ref, isInput: true) else { continue }
        let d = hypot(c.x - point.x, c.y - point.y)
        guard d < max(30, 34 * model.zoom) else { continue }
        if accepting, model.graph.check(from: from, to: ref) != nil { continue }
        if best == nil || d < best!.1 { best = (ref, d) }
      }
    }
    return best?.0
  }

  private func show(_ text: String) {
    withAnimation(Theme.animation(reduceMotion)) { refusal = text }
    // The refusal is spoken too: a VoiceOver user connecting from the inspector or by drag
    // hears why the cable did not take.
    AccessibilityNotification.Announcement(text).post()
    Task {
      try? await Task.sleep(for: .seconds(2.6))
      withAnimation(Theme.animation(reduceMotion)) { if refusal == text { refusal = nil } }
    }
  }

  // MARK: Chrome

  private func toolbar(_ model: PatchModel) -> some View {
    let presetTitle = PatchPreset.named(model.presetID ?? "")?.title ?? "Custom patch"
    return GlassEffectContainer(spacing: 8) {
      HStack(spacing: 8) {
        Button {
          Haptics.shared.tap()
          showPresets = true
        } label: {
          HStack(spacing: 6) {
            Image(systemName: "rectangle.3.group")
            Text(presetTitle).lineLimit(1).truncationMode(.tail)
          }
          .font(.footnote.weight(.semibold))
          .padding(.horizontal, 6)
          .frame(minHeight: 30)
        }
        .buttonStyle(.glass)
        .accessibilityIdentifier("patch-presets")
        .accessibilityLabel("Presets")
        .accessibilityValue(presetTitle)
        Spacer(minLength: 0)
        iconButton("minus.magnifyingglass", "Zoom out", id: "patch-zoom-out") { model.setZoom(model.zoom / 1.25, around: nil) }
        iconButton("plus.magnifyingglass", "Zoom in", id: "patch-zoom-in") { model.setZoom(model.zoom * 1.25, around: nil) }
        iconButton("viewfinder", "Fit to screen", id: "patch-fit") { model.fit(in: model.lastViewport) }
        Button {
          Haptics.shared.tap()
          showPalette = true
        } label: {
          Image(systemName: "plus")
            .font(.body.weight(.bold))
            .frame(width: 30, height: 30)
        }
        .buttonStyle(.glassProminent)
        .buttonBorderShape(.circle)
        .tint(Theme.phosphor)
        .accessibilityIdentifier("patch-add")
        .accessibilityLabel("Add node")
      }
    }
    .padding(.horizontal, 12)
    .padding(.top, 8)
  }

  private func iconButton(_ symbol: String, _ label: String, id: String, action: @escaping () -> Void) -> some View {
    Button {
      Haptics.shared.tap()
      withAnimation(Theme.animation(reduceMotion)) { action() }
      app.patch.save()
    } label: {
      Image(systemName: symbol)
        .font(.footnote.weight(.semibold))
        .frame(width: 30, height: 30)
    }
    .buttonStyle(.glass)
    .buttonBorderShape(.circle)
    .accessibilityLabel(label)
    .accessibilityIdentifier(id)
  }

  private func statusChip(_ model: PatchModel) -> some View {
    let audio = model.graph.isAudioRate
    let text: String =
      model.isRunning
      ? (audio
        ? String(format: "RUN · %.1f blocks/s · %.1f ms", model.stepRate, model.stepMilliseconds)
        : String(format: "RUN · %.0f steps/s · %.1f ms", model.stepRate, model.stepMilliseconds))
      : (audio ? "HOLD · 1,024 @ 48 kHz" : "HOLD · frame rate")
    return StatusChip(text: text, color: model.isRunning ? Theme.phosphor : Theme.muted, symbol: model.isRunning ? "waveform" : "pause.fill")
      .padding(10)
      .accessibilityIdentifier("patch-status")
  }

  private func emptyState(_ model: PatchModel) -> some View {
    VStack(spacing: 14) {
      Image(systemName: "point.3.connected.trianglepath.dotted").font(.largeTitle).foregroundStyle(Theme.phosphor)
      Text("An empty patch").font(.headline).foregroundStyle(Theme.text)
      Text("Add a source, a process and a sink, then drag from an output dot to an input dot.")
        .font(.callout).foregroundStyle(Theme.muted).multilineTextAlignment(.center)
      HStack {
        ActionButton("Add a node", symbol: "plus", prominent: true) { showPalette = true }
          .accessibilityIdentifier("patch-empty-add")
        ActionButton("Load a preset", symbol: "rectangle.3.group") { showPresets = true }
          .accessibilityIdentifier("patch-empty-presets")
      }
    }
    .padding(24)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}
