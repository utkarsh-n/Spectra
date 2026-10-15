import SwiftUI

/// 01 Wave scope: the Metal holo scene (`WaveScene`) with Orbitals' camera gestures, the
/// web prototype's corner tags, E/B/S toggles and camera buttons.
struct WaveScopeStage: View {
  @Environment(AppModel.self) private var app
  @Environment(\.spectrumSketchScenes) private var sketch
  var height: CGFloat = 300

  var body: some View {
    let model = app.spectrum
    let ds = model.waveScene.displaySources
    let camera = Binding(get: { model.extras.camera }, set: { model.extras.camera = $0 })
    VStack(spacing: 8) {
      well(model, ds: ds, camera: camera)
      StageHint("Drag to rotate \u{00B7} pinch to zoom \u{00B7} double-tap to align")
    }
  }

  private func well(_ model: SpectrumModel, ds: FieldView.DisplaySources, camera: Binding<OrbitCamera>) -> some View {
    PlotWell(height: height, grid: 0) {
      if sketch {
        SceneSketch(scene: model.waveScene, time: app.clock.time)
      } else {
        MetalCanvas(
          scene: model.waveScene, camera: camera, home: .waveScopeHome, redrawKey: model.revision,
          label: "Wave scope. E in blue and B in red at right angles, energy flow S in amber along the beam.")
      }
    }
    .overlay(alignment: .top) {
      // One row, so the scale tag and the medium tag share the width (and wrap) instead of
      // running into each other on a narrow phone.
      HStack(alignment: .top, spacing: 6) {
        StageTag(scaleTag(ds))
        Spacer(minLength: 4)
        let hidden = FieldView.hiddenNote(ds)
        if !hidden.isEmpty {
          StageTag(hidden, color: Theme.amber).frame(maxWidth: 170, alignment: .trailing)
        } else if ds.inMedium {
          StageTag("vacuum | \(model.state.medium.name)", color: Theme.amber)
        }
      }
      .padding(10)
    }
    .overlay(alignment: .bottomLeading) {
      HStack(spacing: 8) {
        if model.state.scope.showE { StageTag("E", color: Theme.fieldE) }
        if model.state.scope.showB { StageTag("B", color: Theme.fieldB) }
        if model.state.scope.showS { StageTag("S", color: Theme.poynting) }
      }
      .padding(10)
    }
    .accessibilityIdentifier("spectrum-wave-stage")
  }

  private func scaleTag(_ ds: FieldView.DisplaySources) -> String {
    let n = ds.list.count
    return "1 cycle = \(Spectrum.describe(ds.ref.lambda).text.lambda)\(n > 1 ? " \u{00B7} \(n) sources" : "")"
  }
}

/// Wave scope toolbar: E / B / S display toggles and the camera buttons.
struct WaveScopeToolbar: View {
  @Environment(AppModel.self) private var app

  var body: some View {
    let model = app.spectrum
    let camera = Binding(get: { model.extras.camera }, set: { model.extras.camera = $0 })
    HStack(spacing: 8) {
      GlassEffectContainer(spacing: 6) {
        HStack(spacing: 6) {
          toggle("E", "Electric field", Theme.fieldE, model.state.scope.showE, "spectrum-scope-e") { model.state.scope.showE.toggle() }
          toggle("B", "Magnetic field", Theme.fieldB, model.state.scope.showB, "spectrum-scope-b") { model.state.scope.showB.toggle() }
          toggle("S", "Energy flow", Theme.poynting, model.state.scope.showS, "spectrum-scope-s") { model.state.scope.showS.toggle() }
        }
      }
      Spacer(minLength: 4)
      CameraControls(camera: camera, home: .waveScopeHome, id: "wave-camera")
    }
  }

  private func toggle(_ glyph: String, _ name: String, _ color: Color, _ on: Bool, _ id: String, action: @escaping () -> Void)
    -> some View
  {
    Button {
      Haptics.shared.selection()
      action()
    } label: {
      Text(glyph)
        .font(.system(.subheadline, design: .serif).weight(.bold).italic())
        .foregroundStyle(on ? color : Theme.muted.opacity(0.6))
        .frame(width: 34, height: 34)
        .contentShape(.circle)
    }
    .buttonStyle(.plain)
    .glassEffect(on ? .regular.tint(color.opacity(0.25)).interactive() : .regular.interactive(), in: .circle)
    .accessibilityLabel(name)
    .accessibilityValue(on ? "shown" : "hidden")
    .accessibilityAddTraits(on ? .isSelected : [])
    .accessibilityIdentifier(id)
  }
}

/// Wave scope aux: the caption and the signal buttons.
struct WaveScopeAux: View {
  @Environment(AppModel.self) private var app

  var body: some View {
    let model = app.spectrum
    VStack(alignment: .leading, spacing: 12) {
      Text(
        model.state.medium == .vacuum
          ? "E and B rise and fall together, at right angles to each other and to the beam; S = E \u{00D7} B / \u{00B5}\u{2080} carries the energy forward."
          : "In the far half the wave enters \(model.state.medium.name.lowercased()): it slows to c/n, its wavelength shrinks, and the Fresnel factor 2/(1 + n) sets the amplitude that gets in."
      )
      .panelCaption()
      SpectrumSignalButtons(
        scopeTitle: "Open in Scope", patchTitle: "Add to Patch", idPrefix: "spectrum-scope",
        openScope: model.openFieldInScope, addPatch: model.addFieldToPatch)
    }
  }
}
