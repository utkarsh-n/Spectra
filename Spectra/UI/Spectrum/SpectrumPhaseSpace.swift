import SwiftUI

/// What makes the phase-space scene recompute (the request) or re-extract the cube (the k
/// column).
private struct PhaseTrigger: Hashable {
  var built: PhaseSpaceRequestBuilder.Built
  var kFraction: Double
}

/// Decompose → Phase space: Utkarsh's spacetime Wigner distribution Φ(ν, k; x, t), laid out
/// like his poster: the spacetime view |ψ(x, t)|² and the momentum–frequency view |ψ̃(k, ν)|²
/// with the medium's dispersion curve, the Φ cube as a Metal volume (diverging map, drag to
/// rotate), the fixed-t and fixed-x slices, and the marginals strip. Φ is computed off the
/// main thread by `Phase.phaseSpaceScene`.
struct SpectrumPhaseSpaceStage: View {
  @Environment(AppModel.self) private var app
  @Environment(\.spectrumSketchScenes) private var sketch
  var cubeHeight: CGFloat = 260

  var body: some View {
    let model = app.spectrum
    let settings = model.extras.phase
    let built = PhaseSpaceRequestBuilder.build(state: model.state, settings: settings)
    let phase = model.phase
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 8) {
        heatPanel(
          title: "SPACETIME |\u{03C8}(x, t)|\u{00B2}", axes: "t \u{2192}  x \u{2191}",
          image: phase.image(.spacetime, settings: settings), id: "spectrum-phase-spacetime")
        momentumPanel(model)
      }
      cube(model)
      HStack(spacing: 8) {
        heatPanel(
          title: "W(x, k) AT FIXED t", axes: "x \u{2192}  k \u{2191}", image: phase.image(.spatialSlice, settings: settings),
          id: "spectrum-phase-slice-t", diverging: true)
        heatPanel(
          title: "W(t, \u{03BD}) AT FIXED x", axes: "t \u{2192}  \u{03BD} \u{2191}",
          image: phase.image(.temporalSlice, settings: settings), id: "spectrum-phase-slice-x", diverging: true)
      }
      sliceSliders(model)
      marginals(model)
    }
    .onChange(of: PhaseTrigger(built: built, kFraction: settings.kFraction), initial: true) { model.refreshPhase() }
  }

  // MARK: Heat maps

  private func heatPanel(title: String, axes: String, image: CGImage?, id: String, diverging: Bool = false) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(title).font(.system(size: 9, weight: .medium, design: .monospaced)).foregroundStyle(Theme.muted)
        .lineLimit(1).minimumScaleFactor(0.7)
      PlotWell(height: 140, grid: 0) {
        HeatMapImage(image: image)
        if image == nil { PhaseEmptyMark(computing: app.spectrum.phase.computing) }
      }
      .overlay(alignment: .bottomTrailing) { StageTag(axes).padding(4) }
      .accessibilityElement()
      .accessibilityLabel(title.capitalized)
      .accessibilityValue(diverging ? "Warm where positive, cool blue where negative." : "Brighter where the field is stronger.")
      .accessibilityIdentifier(id)
    }
    .frame(maxWidth: .infinity)
  }

  private func momentumPanel(_ model: SpectrumModel) -> some View {
    let scene = model.phase.scene
    let image = model.phase.image(.momentum, settings: model.extras.phase)
    return VStack(alignment: .leading, spacing: 4) {
      Text("MOMENTUM\u{2013}FREQUENCY |\u{03C8}\u{0303}(k, \u{03BD})|\u{00B2}")
        .font(.system(size: 9, weight: .medium, design: .monospaced)).foregroundStyle(Theme.muted)
        .lineLimit(1).minimumScaleFactor(0.6)
      PlotWell(height: 140, grid: 0) {
        HeatMapImage(image: image)
        if let scene {
          Canvas { ctx, size in PhaseDrawing.shell(ctx, size, scene: scene) }
            .allowsHitTesting(false)
        } else {
          PhaseEmptyMark(computing: model.phase.computing)
        }
      }
      .overlay(alignment: .bottomTrailing) { StageTag("k \u{2192}  \u{03BD} \u{2191}").padding(4) }
      .accessibilityElement()
      .accessibilityLabel("Momentum-frequency view")
      .accessibilityValue(
        "Dispersion curve: \(scene?.model.dispersion.title ?? "none"), \(scene?.model.dispersion.formula ?? ""). Dots mark each packet's carrier.")
      .accessibilityIdentifier("spectrum-phase-momentum")
    }
    .frame(maxWidth: .infinity)
  }

  // MARK: Cube

  private func cube(_ model: SpectrumModel) -> some View {
    let camera = Binding(get: { model.extras.phase.camera }, set: { model.extras.phase.camera = $0 })
    let p = model.extras.phase
    let key = model.phase.cubeRevision &+ Int(p.tFraction * 1000) &* 7 &+ Int(p.xFraction * 1000) &* 13
    return VStack(alignment: .leading, spacing: 8) {
      PlotWell(height: cubeHeight, grid: 0) {
        if sketch {
          SceneSketch(scene: model.wignerScene)
        } else {
          // The volume is static between computations: 30 fps is plenty for dragging it.
          MetalCanvas(
            scene: model.wignerScene, camera: camera, home: .wignerCubeHome, maximumFramesPerSecond: 30, redrawKey: key,
            label: "Phi cube: space, time and frequency. Warm points are positive, cool blue points negative.")
        }
      }
      .overlay(alignment: .topLeading) {
        VStack(alignment: .leading, spacing: 4) {
          StageTag(model.phase.cubeColumn == nil ? "\u{03A6} \u{222B}dk/2\u{03C0}  (x, t, \u{03BD})" : "\u{03A6} at one k  (x, t, \u{03BD})")
          HStack(spacing: 4) {
            StageTag("t", color: Theme.phosphor)
            StageTag("\u{03BD}", color: Theme.amber)
            StageTag("x", color: Theme.iceRGB.color)
          }
        }
        .padding(10)
      }
      .overlay(alignment: .topTrailing) {
        VStack(alignment: .trailing, spacing: 4) {
          StageTag("\u{03A6} > 0", color: WignerScene.positive.color)
          StageTag("\u{03A6} < 0", color: WignerScene.negative.color)
        }
        .padding(10)
      }
      .overlay {
        if model.phase.computing {
          HStack(spacing: 8) {
            ProgressView().tint(Theme.amber)
            Text("Computing \u{03A6}").font(.caption).foregroundStyle(Theme.amber)
          }
          .padding(10)
          .background(Theme.plotWell.opacity(0.8), in: .capsule)
          .allowsHitTesting(false)
        }
      }
      .accessibilityIdentifier("spectrum-phase-cube")
      HStack {
        StageHint("Drag to rotate \u{00B7} pinch to zoom")
        CameraControls(camera: camera, home: .wignerCubeHome, id: "wigner-camera")
      }
    }
  }

  // MARK: Slices

  private func sliceSliders(_ model: SpectrumModel) -> some View {
    let w = model.phase.scene?.wigner
    let idx = model.phase.sliceIndices(model.extras.phase)
    return VStack(alignment: .leading, spacing: 4) {
      GlassSlider(
        title: "Fixed t (green plane)",
        value: Binding(get: { model.extras.phase.tFraction }, set: { model.extras.phase.tFraction = $0 }), range: 0...1, step: 0.01,
        color: Theme.phosphor,
        format: { _ in
          guard let w, let i = idx?.t else { return "\u{2014}" }
          return "t = \(JSFormat.toFixed(w.tAxis.value(i), 1)) T"
        }
      )
      .accessibilityIdentifier("spectrum-phase-t")
      GlassSlider(
        title: "Fixed x (blue plane)",
        value: Binding(get: { model.extras.phase.xFraction }, set: { model.extras.phase.xFraction = $0 }), range: 0...1, step: 0.01,
        color: Theme.iceRGB.color,
        format: { _ in
          guard let w, let i = idx?.x else { return "\u{2014}" }
          return "x = \(JSFormat.toFixed(w.xAxis.value(i), 1)) \u{03BB}"
        }
      )
      .accessibilityIdentifier("spectrum-phase-x")
    }
  }

  // MARK: Marginals

  private func marginals(_ model: SpectrumModel) -> some View {
    let report = model.phase.scene?.report
    let color: Color =
      switch report?.status {
      case .consistent: Theme.phosphor
      case .aliased: Theme.amber
      case .inconsistent: Theme.ionizing
      default: Theme.muted
      }
    return HStack(alignment: .center, spacing: 10) {
      VStack(alignment: .leading, spacing: 3) {
        HStack(spacing: 6) {
          Text("MARGINALS").font(Theme.eyebrowFont).tracking(1.4).foregroundStyle(Theme.muted)
          ProvenanceBadge(.model, compact: true)
        }
        if let r = report {
          Text("M1 \(err(r.m1Error))  M2 \(err(r.m2Error))  P \(err(r.parsevalError))")
            .font(.system(.caption, design: .monospaced)).foregroundStyle(Theme.text).lineLimit(1).minimumScaleFactor(0.6)
          Text("alias \(err(r.aliasLevel)) \u{00B7} M2 identity \(err(r.m2IdentityError))")
            .font(.system(.caption2, design: .monospaced)).foregroundStyle(Theme.dim).lineLimit(1).minimumScaleFactor(0.6)
        } else {
          Text(model.phase.computing ? "Computing\u{2026}" : "No packets").font(.caption).foregroundStyle(Theme.dim)
        }
      }
      Spacer(minLength: 4)
      if let r = report { StatusChip(text: r.status.badge, color: color) }
    }
    .padding(12)
    .background(Theme.plotWell, in: .rect(cornerRadius: 14))
    .accessibilityElement(children: .combine)
    .accessibilityLabel("Marginals")
    .accessibilityIdentifier("spectrum-phase-marginals")
  }

  private func err(_ x: Double) -> String { x.isFinite ? SpectraFormat.scientific(x, digits: 2) : "\u{2014}" }
}

/// A spinner while Φ is computed, a dash when there is nothing to draw.
private struct PhaseEmptyMark: View {
  let computing: Bool
  var body: some View {
    if computing {
      ProgressView().tint(Theme.phosphor)
    } else {
      Text("\u{2014}").font(.title3).foregroundStyle(Theme.dim).accessibilityHidden(true)
    }
  }
}

/// The dispersion shell and packet carriers over the |ψ̃(k, ν)|² image.
enum PhaseDrawing {
  static func shell(_ ctx: GraphicsContext, _ size: CGSize, scene: Phase.PhaseSpaceScene) {
    let kAxis = scene.spectrum.power.rowAxis, nuAxis = scene.spectrum.power.columnAxis
    guard kAxis.count > 1, nuAxis.count > 1 else { return }
    func point(k: Double, nu: Double) -> CGPoint {
      let cx = (kAxis.fractionalIndex(k) + 0.5) / Double(kAxis.count)
      let cy = (nuAxis.fractionalIndex(nu) + 0.5) / Double(nuAxis.count)
      return CGPoint(x: CGFloat(cx) * size.width, y: size.height - CGFloat(cy) * size.height)
    }
    var path = Path()
    var started = false
    for s in scene.shell {
      guard s.valid, s.nu.isFinite, s.k.isFinite else {
        started = false
        continue
      }
      let p = point(k: s.k, nu: s.nu)
      guard p.y.isFinite, p.y > -size.height, p.y < 2 * size.height else {
        started = false
        continue
      }
      if started { path.addLine(to: p) } else { path.move(to: p) }
      started = true
    }
    var clipped = ctx
    clipped.clip(to: Path(CGRect(origin: .zero, size: size)))
    clipped.stroke(path, with: .color(Theme.text.opacity(0.85)), style: StrokeStyle(lineWidth: 1.2, dash: [4, 3]))
    for (i, c) in scene.carriers.enumerated() {
      guard let c else { continue }
      let p = point(k: c.x, nu: c.y)
      clipped.stroke(
        Path(ellipseIn: CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8)), with: .color(Theme.sources[min(2, i)]), lineWidth: 1.5)
    }
  }
}

/// Phase space controls: dispersion relation (medium, ionosphere plasma, waveguide), packet
/// spacing and chirps, the cube's k column, and the computation's notes.
struct SpectrumPhaseSpaceAux: View {
  @Environment(AppModel.self) private var app

  var body: some View {
    let model = app.spectrum
    let settings = model.extras.phase
    let nuRef = Spectrum.frequency(model.state.referenceSource.lambda)
    let built = model.phase.built
    let coherent = model.state.enabledIndices.filter { model.state.sources[$0].kind != .thermal }
    VStack(alignment: .leading, spacing: 12) {
      GlassSegmented(
        items: PhaseSpaceSettings.DispersionChoice.allCases, selected: settings.dispersion, id: "spectrum-phase-dispersion",
        tint: { _ in Theme.amber },
        title: { $0 == .medium ? model.state.medium.name.replacingOccurrences(of: " (BK7)", with: "") : $0.title }
      ) { model.extras.phase.dispersion = $0 }
      Text(dispersionNote(model)).panelCaption()
      switch settings.dispersion {
      case .plasma:
        GlassSlider(
          title: "Plasma frequency f\u{209A}",
          value: Binding(get: { model.extras.phase.plasmaRatio }, set: { model.extras.phase.plasmaRatio = $0 }),
          range: PhaseSpaceSettings.ratioRange, step: 0.01, color: Theme.amber,
          format: { "\(JSFormat.toFixed($0, 2)) \u{00D7} ref \u{00B7} \(SpectraFormat.frequency($0 * nuRef))" }
        )
        .accessibilityIdentifier("spectrum-phase-plasma")
      case .waveguide:
        GlassSlider(
          title: "Cut-off frequency",
          value: Binding(get: { model.extras.phase.cutoffRatio }, set: { model.extras.phase.cutoffRatio = $0 }),
          range: PhaseSpaceSettings.ratioRange, step: 0.01, color: Theme.amber,
          format: { "\(JSFormat.toFixed($0, 2)) \u{00D7} ref \u{00B7} \(SpectraFormat.frequency($0 * nuRef))" }
        )
        .accessibilityIdentifier("spectrum-phase-cutoff")
      case .medium:
        EmptyView()
      }
      GlassSlider(
        title: "Packet spacing",
        value: Binding(get: { model.extras.phase.spacing }, set: { model.extras.phase.spacing = $0 }),
        range: PhaseSpaceSettings.spacingRange, step: 0.1, color: Theme.dialAmber,
        format: { "\(JSFormat.toFixed($0, 1)) \u{03BB}" }
      )
      .accessibilityIdentifier("spectrum-phase-spacing")
      ForEach(coherent, id: \.self) { i in
        GlassSlider(
          title: "Chirp, source \(SpectraState.sourceNames[i])",
          value: Binding(
            get: { model.extras.phase.chirp.indices.contains(i) ? model.extras.phase.chirp[i] : 0 },
            set: { v in if model.extras.phase.chirp.indices.contains(i) { model.extras.phase.chirp[i] = v } }),
          range: PhaseSpaceSettings.chirpRange, step: 0.01, color: Theme.sources[i],
          format: { "\(JSFormat.toFixed($0, 2)) rad/\u{03BB}\u{00B2}" }
        )
        .accessibilityIdentifier("spectrum-phase-chirp-\(SpectraState.sourceNames[i])")
      }
      if coherent.count < 2 {
        // With only thermal light on there is no packet yet: the button adds the first one.
        ActionButton(coherent.isEmpty ? "Add a packet" : "Add a second packet", symbol: "plus.circle") { addSecondPacket(model) }
          .accessibilityHint(
            coherent.isEmpty
              ? "Turns on another source as a pulse, since thermal light has no Wigner picture."
              : "Turns on another source as a pulse at the same wavelength, to show the interference term.")
          .accessibilityIdentifier("spectrum-phase-two-packets")
        SheetCaption("One Gaussian packet stays positive everywhere (Hudson). Two packets add a cross term midway that swings negative.")
      } else {
        SheetCaption(
          "Two or more packets add an interference term midway between them that swings negative (cool blue): look in the fixed-t slice W(x, k), or in the cube with one k column. Integrating over k mostly cancels it. The min \u{03A6} / max \u{03A6} readout gives its depth."
        )
      }
      GlassToggle(
        "Cube shows one k column",
        isOn: Binding(
          get: { model.extras.phase.kSlice },
          set: { on in
            if on, let f = model.phase.startKFraction(spacing: model.extras.phase.spacing) { model.extras.phase.kFraction = f }
            model.extras.phase.kSlice = on
          }), symbol: "square.stack.3d.up",
        subtitle: "Off: \u{03A6} integrated over k (the temporal Wigner at every x). On: starts where two packets' cross term dips, or at the carrier for one."
      )
      .accessibilityIdentifier("spectrum-phase-kslice")
      if settings.kSlice {
        let w = model.phase.scene?.wigner
        GlassSlider(
          title: "k column",
          value: Binding(get: { model.extras.phase.kFraction }, set: { model.extras.phase.kFraction = $0 }), range: 0...1, step: 0.01,
          color: Theme.phosphor,
          format: { u in
            guard let w, w.nk > 1 else { return "\u{2014}" }
            let c = min(w.nk - 1, max(0, Int((u * Double(w.nk - 1)).rounded())))
            return "k\u{0302} = \(JSFormat.toFixed(w.kAxis.value(c), 2)) rad/\u{03BB}"
          }
        )
        .accessibilityIdentifier("spectrum-phase-k")
      }
      let notes = (built?.notes ?? []) + (model.phase.scene?.notes ?? [])
      if !notes.isEmpty {
        VStack(alignment: .leading, spacing: 4) {
          ForEach(Array(notes.enumerated()), id: \.offset) { _, n in
            Text("\u{2022} \(n)").panelCaption()
          }
        }
        .accessibilityIdentifier("spectrum-phase-notes")
      }
      Text(
        "Spacetime Wigner distribution: Utkarsh's construction and convention (C). \(PhaseSpaceRequestBuilder.gridSize) \u{00D7} \(PhaseSpaceRequestBuilder.gridSize) grid in x and t, units of the reference source: x in \u{03BB}, t in periods, k in rad per \u{03BB}, \u{03BD} in multiples of its frequency."
      )
      .panelCaption()
    }
  }

  private func dispersionNote(_ model: SpectrumModel) -> String {
    let d = PhaseSpaceRequestBuilder.dispersion(state: model.state, settings: model.extras.phase)
    return "\(d.title): \(d.formula). A free packet lives on this curve (dashed in the k\u{2013}\u{03BD} view)."
  }

  private func addSecondPacket(_ model: SpectrumModel) {
    var s = model.state
    // Copy the coherent packet that is already drawn (or the active source); turn on a source
    // that is off first, then a thermal one other than the active source.
    let coherent = s.enabledIndices.filter { s.sources[$0].kind != .thermal }
    let a = coherent.first.map { s.sources[$0] } ?? s.activeSource
    let free = s.sources.indices.filter { !coherent.contains($0) }
    guard let i = free.first(where: { !s.sources[$0].enabled }) ?? free.first(where: { $0 != s.active }) ?? free.first else { return }
    s.sources[i].enabled = true
    s.sources[i].kind = .pulse
    s.sources[i].lambda = a.kind == .thermal ? s.sources[i].lambda : a.lambda
    s.sources[i].cycles = a.kind == .pulse ? a.cycles : 4
    s.preset = nil
    s.sanitizeSources()
    model.state = s
  }
}
