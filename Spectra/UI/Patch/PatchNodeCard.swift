import SwiftUI

/// One glass node card: header (symbol, title, badges), a live mini preview, typed ports on
/// the edges, and a value or status line. Its geometry is `PatchGeometry`, so cables meet
/// the port dots exactly.
struct PatchNodeCard: View {
  let node: PatchNode
  var selected: Bool
  var drag: CableDrag?
  var onTap: () -> Void
  var onMove: (PatchCanvasView.GesturePhase, CGSize) -> Void
  var onPortDrag: (String, Bool, PatchCanvasView.GesturePhase, CGPoint) -> Void

  @Environment(AppModel.self) private var app
  @State private var moveActive = false
  @State private var portActive: String?

  var body: some View {
    let model = app.patch
    let _ = model.revision
    let preview = model.preview(node.id)
    let status = model.status(node.id)
    let spec = node.spec
    VStack(alignment: .leading, spacing: 0) {
      header(spec: spec, preview: preview)
        .frame(height: PatchGeometry.headerHeight)
      PatchPreviewView(preview: preview)
        .frame(height: PatchGeometry.previewHeight)
        .padding(.horizontal, 10)
        .contentShape(.rect)
        .onTapGesture(perform: onTap)
      Spacer().frame(height: 8)
      ports(spec)
        .frame(height: Double(max(1, max(spec.inputs.count, spec.outputs.count))) * PatchGeometry.portRowHeight)
      footer(preview: preview, status: status)
        .frame(height: PatchGeometry.footerHeight)
    }
    .frame(width: PatchGeometry.cardWidth, height: PatchGeometry.height(of: node.kind), alignment: .topLeading)
    .background(Theme.panel.opacity(0.55), in: .rect(cornerRadius: 18))
    .glassEffect(.regular, in: .rect(cornerRadius: 18))
    .overlay {
      RoundedRectangle(cornerRadius: 18)
        .strokeBorder(selected ? Theme.phosphor.opacity(0.85) : Color.white.opacity(0.08), lineWidth: selected ? 1.5 : 0.75)
        .allowsHitTesting(false)
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("\(node.title) node")
    .accessibilityIdentifier("patch-node-\(node.id)")
  }

  // MARK: Header (tap = inspect, drag = move)

  private func header(spec: NodeSpec, preview: NodePreview) -> some View {
    VStack(alignment: .leading, spacing: 3) {
      HStack(spacing: 6) {
        Image(systemName: icon(spec))
          .font(.system(size: 12, weight: .semibold))
          .foregroundStyle(PatchColors.color(preview.tint == .idle ? .phosphor : preview.tint))
          .frame(width: 16)
        Text(node.title)
          .font(.system(size: 12.5, weight: .semibold))
          .foregroundStyle(Theme.text)
          .lineLimit(1)
          .minimumScaleFactor(0.75)
        Spacer(minLength: 0)
      }
      HStack(spacing: 3) {
        if preview.provenance.count < 3 {
          Text(spec.category.title.instrumentCaps)
            .font(.system(size: 7.5, weight: .medium, design: .monospaced))
            .tracking(1)
            .foregroundStyle(Theme.dim)
            .lineLimit(1)
        }
        Spacer(minLength: 2)
        ForEach(Array(preview.provenance.prefix(3)), id: \.self) { p in
          ProvenanceBadge(p, compact: true)
        }
      }
    }
    .padding(.horizontal, 10)
    .padding(.top, 8)
    .contentShape(.rect)
    .onTapGesture(perform: onTap)
    .gesture(
      DragGesture(minimumDistance: 3, coordinateSpace: .named(PatchCanvasView.space))
        .onChanged { g in
          if !moveActive {
            moveActive = true
            onMove(.began, .zero)
          }
          onMove(.changed, g.translation)
        }
        .onEnded { _ in
          moveActive = false
          onMove(.ended, .zero)
        }
    )
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(node.title)
    // Rule R4 for VoiceOver too: the value, then where it comes from, then the status.
    .accessibilityValue(
      [
        preview.value,
        preview.provenance.isEmpty ? nil : preview.provenance.map { $0.badge.capitalized }.joined(separator: ", "),
        status(of: preview),
      ].compactMap { $0 }.joined(separator: ". "))
    .accessibilityHint("Opens the inspector. Drag to move the card.")
    .accessibilityAddTraits(.isButton)
    .accessibilityAction { onTap() }
    .accessibilityIdentifier("patch-node-header-\(node.id)")
  }

  private func status(of preview: NodePreview) -> String? {
    app.patch.status(node.id)?.text
  }

  private func icon(_ spec: NodeSpec) -> String {
    if node.kind == .stream, let s = PatchModel.sensor(forStream: node.string("stream")) { return s.symbol }
    return spec.symbol
  }

  // MARK: Ports

  private func ports(_ spec: NodeSpec) -> some View {
    HStack(alignment: .top, spacing: 0) {
      VStack(alignment: .leading, spacing: 0) {
        ForEach(spec.inputs) { p in portRow(p, isInput: true) }
      }
      Spacer(minLength: 0)
      VStack(alignment: .trailing, spacing: 0) {
        ForEach(spec.outputs) { p in portRow(p, isInput: false) }
      }
    }
  }

  private func portRow(_ p: PortSpec, isInput: Bool) -> some View {
    let model = app.patch
    let ref = PortRef(node.id, p.name)
    let connected = isInput ? model.graph.cable(into: ref) != nil : !model.graph.cables(from: ref).isEmpty
    let types = isInput ? p.types : model.graph.outputTypes(ref)
    let color = PatchColors.port(types)
    let accepting = drag.map { isInput && model.graph.check(from: $0.from, to: ref) == nil } ?? false
    let target = drag?.target == ref
    let dot = PortDot(types: types, color: color, connected: connected, glow: accepting || target, strong: target)
      .frame(width: 30, height: PatchGeometry.portRowHeight)
      .contentShape(.rect)
      .offset(x: isInput ? -15 : 15)
      .gesture(
        DragGesture(minimumDistance: 2, coordinateSpace: .named(PatchCanvasView.space))
          .onChanged { g in
            if portActive != p.name {
              portActive = p.name
              onPortDrag(p.name, isInput, .began, g.location)
            }
            onPortDrag(p.name, isInput, .changed, g.location)
          }
          .onEnded { g in
            portActive = nil
            onPortDrag(p.name, isInput, .ended, g.location)
          }
      )
      .accessibilityElement()
      .accessibilityLabel("\(isInput ? "Input" : "Output") \(p.title), \(types.map(\.title).joined(separator: " or "))")
      .accessibilityValue(connected ? "Connected" : "Free")
      .accessibilityHint("Connect it in the node's inspector.")
      .accessibilityIdentifier("patch-port-\(node.id)-\(isInput ? "in" : "out")-\(p.name)")
    let label = Text(p.title)
      .font(.system(size: 9.5, weight: .medium, design: .monospaced))
      .foregroundStyle(accepting ? Theme.text : Theme.muted)
      .lineLimit(1)
      .minimumScaleFactor(0.7)
      .accessibilityHidden(true)
    return HStack(spacing: 0) {
      if isInput {
        dot
        label.padding(.leading, -10)
      } else {
        label.padding(.trailing, -10)
        dot
      }
    }
    .frame(height: PatchGeometry.portRowHeight)
    .frame(maxWidth: PatchGeometry.cardWidth / 2 + 15, alignment: isInput ? .leading : .trailing)
  }

  // MARK: Footer

  private func footer(preview: NodePreview, status: NodeStatus?) -> some View {
    let model = app.patch
    return HStack(spacing: 6) {
      if let s = model.sensorState(for: node), s.needsTap {
        Button {
          model.startSensor(s.sensor)
        } label: {
          Label("Start", systemImage: "play.fill").font(.system(size: 10.5, weight: .semibold)).labelStyle(.titleAndIcon)
        }
        .buttonStyle(.glassProminent)
        .tint(Theme.phosphor)
        .controlSize(.mini)
        .accessibilityLabel("Start the \(s.sensor.title)")
        .accessibilityIdentifier("patch-node-start-\(node.id)")
      }
      // The header already speaks the value and status; the Start button stays reachable.
      Group {
        if let status, status.level != .info || preview.value == nil {
          Text(status.text)
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(status.level == .warning ? Theme.ionizing : Theme.muted)
            .lineLimit(2)
            .minimumScaleFactor(0.8)
        } else if let v = preview.value {
          Text(v)
            .font(.system(size: 10.5, weight: .medium, design: .monospaced))
            .monospacedDigit()
            .foregroundStyle(Theme.amber)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
        }
      }
      .accessibilityHidden(true)
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 10)
    .padding(.bottom, 6)
  }
}

/// A port: shape by type (circle samples/I/Q, ring EM wave, square spectrum/image, diamond
/// control, triangle events), colour by family, ring when connected, glow while a cable that
/// fits is dragged near.
struct PortDot: View {
  let types: [PortType]
  let color: Color
  var connected: Bool
  var glow: Bool
  var strong: Bool

  var body: some View {
    ZStack {
      if glow {
        Circle().fill(color.opacity(strong ? 0.45 : 0.22)).frame(width: strong ? 24 : 18, height: strong ? 24 : 18)
      }
      shape
        .frame(width: 10, height: 10)
      if connected {
        Circle().strokeBorder(color.opacity(0.6), lineWidth: 1).frame(width: 15, height: 15)
      }
    }
  }

  @ViewBuilder private var shape: some View {
    switch types.first ?? .audio {
    case .em:
      Circle().strokeBorder(color, lineWidth: 2.2)
    case .spectrum, .image:
      RoundedRectangle(cornerRadius: 2).fill(color)
    case .control, .attitude, .bits:
      RoundedRectangle(cornerRadius: 1.5).fill(color).rotationEffect(.degrees(45)).scaleEffect(0.82)
    case .event:
      Triangle().fill(color)
    case .audio, .iq:
      Circle().fill(color)
    }
  }
}

nonisolated struct Triangle: Shape {
  func path(in rect: CGRect) -> Path {
    var p = Path()
    p.move(to: CGPoint(x: rect.minX, y: rect.minY))
    p.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
    p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
    p.closeSubpath()
    return p
  }
}

/// The mini preview inside a card (and, larger, in the inspector header).
struct PatchPreviewView: View {
  let preview: NodePreview

  var body: some View {
    let color = PatchColors.color(preview.tint == .idle ? .phosphor : preview.tint)
    ZStack {
      RoundedRectangle(cornerRadius: 10).fill(Theme.plotWell)
      RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.phosphor.opacity(0.12), lineWidth: 0.5)
      content(color)
        .padding(4)
        .clipShape(.rect(cornerRadius: 10))
    }
    .accessibilityHidden(true)
  }

  @ViewBuilder private func content(_ color: Color) -> some View {
    switch preview.plot {
    case .none:
      Text("—").font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.dim)
    case .trace(let values, let steps):
      Sparkline(values: values, color: color, fill: false, steps: steps)
    case .spectrum(let db, let floor):
      Canvas { ctx, size in
        guard db.count > 1 else { return }
        let lo = floor
        let hi = max(floor + 20, (db.max() ?? 0) + 3)
        var path = Path()
        for (i, v) in db.enumerated() {
          let x = size.width * CGFloat(i) / CGFloat(db.count - 1)
          let f = (min(max(v, lo), hi) - lo) / (hi - lo)
          let y = size.height * (1 - f)
          if i == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
        }
        ctx.phosphorStroke(path, color: color, width: 1.1, glow: 0.8)
      }
    case .points(let pts, let ideal, let range):
      Canvas { ctx, size in
        let side = min(size.width, size.height)
        let r = CGFloat(max(range, 1e-6))
        let cx = size.width / 2
        let cy = size.height / 2
        func map(_ p: SIMD2<Float>) -> CGPoint {
          CGPoint(x: cx + CGFloat(p.x) / r * side / 2, y: cy - CGFloat(p.y) / r * side / 2)
        }
        var axes = Path()
        axes.move(to: CGPoint(x: cx - side / 2, y: cy))
        axes.addLine(to: CGPoint(x: cx + side / 2, y: cy))
        axes.move(to: CGPoint(x: cx, y: cy - side / 2))
        axes.addLine(to: CGPoint(x: cx, y: cy + side / 2))
        ctx.stroke(axes, with: .color(Theme.phosphor.opacity(0.12)), lineWidth: 0.5)
        if ideal.count <= 64 {
          for q in ideal {
            let c = map(q)
            ctx.stroke(Path(ellipseIn: CGRect(x: c.x - 2, y: c.y - 2, width: 4, height: 4)), with: .color(Theme.amber.opacity(0.7)), lineWidth: 0.6)
          }
        }
        var dots = Path()
        for p in pts where p.x.isFinite && p.y.isFinite {
          let c = map(p)
          dots.addRect(CGRect(x: c.x - 0.6, y: c.y - 0.6, width: 1.2, height: 1.2))
        }
        ctx.fill(dots, with: .color(color.opacity(0.85)))
      }
    case .image(let values, let side):
      SignedHeatmap(values: values, rows: side, columns: side)
    case .swatch(let lambda):
      HStack(spacing: 8) {
        Circle().fill(BandPalette.color(forWavelength: lambda)).frame(width: 22, height: 22)
          .shadow(color: BandPalette.color(forWavelength: lambda).opacity(0.8), radius: 6)
        VStack(alignment: .leading, spacing: 1) {
          Text(SpectraFormat.wavelength(lambda)).font(.system(size: 11, weight: .semibold, design: .monospaced))
            .foregroundStyle(Theme.text)
          Text(BandPalette.band(forWavelength: lambda).name).font(.system(size: 9)).foregroundStyle(Theme.muted)
        }
        Spacer(minLength: 0)
      }
      .padding(.horizontal, 6)
    case .text(let t):
      Text(t)
        .font(.system(size: 9.5, design: .monospaced))
        .foregroundStyle(color)
        .lineLimit(3)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    case .level(let x):
      VStack {
        Spacer()
        LevelMeter(level: x, color: color)
        Spacer()
      }
      .padding(.horizontal, 8)
    }
  }
}

/// A signed heat map with Utkarsh's diverging colours: positive warm orange, negative cool
/// blue, black at zero (rows top to bottom).
struct SignedHeatmap: View {
  let values: [Float]
  let rows: Int
  let columns: Int

  static let warm = RGB(hex: 0xFF9A3C)
  static let cool = RGB(hex: 0x3C9BFF)

  var body: some View {
    // One bitmap per redraw, drawn as an image: the inspector's 128 × 128 picture as 16,384
    // Canvas rectangles cost the main thread tens of milliseconds at 15 Hz.
    Group {
      if let image = Self.image(values, rows: rows, columns: columns) {
        Image(decorative: image, scale: 1).resizable().interpolation(.none)
      } else {
        Color.clear
      }
    }
    .accessibilityHidden(true)
  }

  /// Premultiplied RGBA, one pixel per cell (rows top to bottom), transparent near zero.
  static func image(_ values: [Float], rows: Int, columns: Int) -> CGImage? {
    guard rows > 0, columns > 0, values.count == rows * columns else { return nil }
    var pixels = [UInt8](repeating: 0, count: rows * columns * 4)
    for k in values.indices {
      let v = Double(values[k])
      guard v.isFinite, abs(v) > 0.02 else { continue }
      let base = v > 0 ? warm : cool
      let a = min(1, pow(abs(v), 0.6))
      pixels[4 * k] = UInt8((base.r * a * 255).rounded())
      pixels[4 * k + 1] = UInt8((base.g * a * 255).rounded())
      pixels[4 * k + 2] = UInt8((base.b * a * 255).rounded())
      pixels[4 * k + 3] = UInt8((a * 255).rounded())
    }
    guard let provider = CGDataProvider(data: Data(pixels) as CFData),
      let space = CGColorSpace(name: CGColorSpace.sRGB)
    else { return nil }
    return CGImage(
      width: columns, height: rows, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: columns * 4, space: space,
      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider, decode: nil,
      shouldInterpolate: false, intent: .defaultIntent)
  }
}
