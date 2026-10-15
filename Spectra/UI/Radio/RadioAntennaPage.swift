import SwiftUI
import simd

/// Radio → Antenna: style chips, the holo 3D lobe with Follow phone and Beam lock, the knobs,
/// E/H polar cuts, the RF readouts, polarization toward a target, and the aperture phase space.
struct RadioAntennaPage: View {
  let model: RadioModel
  @Environment(AppModel.self) private var app
  @Environment(\.dynamicTypeSize) private var typeSize
  @State private var solidPlane: RF.PatternPlane = .e

  var body: some View {
    @Bindable var scene = model.scene
    let build = model.antennaBuild
    let band = BandPalette.color(forFrequency: model.carrier)
    Group {
      InstrumentPanel("Antenna", number: "01", provenance: lobeProvenance) {
        ChoiceChips(
          items: RF.AntennaStyle.allCases, selection: styleBinding, id: "radio-style"
        ) { ChipLabel(title: $0.displayName) }
        .padding(.horizontal, -Theme.panelPadding)
        Text(RadioCopy.us(model.antenna.style.summary)).panelCaption()
        PlotWell(height: typeSize.isAccessibilitySize ? 300 : 340, grid: 0) {
          MetalCanvas(
            scene: scene, camera: $scene.camera, home: AntennaScene.home, redrawKey: scene.revision,
            label: "\(model.antenna.style.displayName) radiation pattern in 3D")
        }
        .overlay(alignment: .topLeading) {
          // The follow chips read the attitude streams (not observed): refresh them while following.
          VisibleTimeline(minimumInterval: 0.25, paused: !model.followPhone) { _ in lobeChips(band: band) }
            .padding(10)
            .allowsHitTesting(false)
        }
        .overlay(alignment: .bottomLeading) { legend.padding(.leading, 12).padding(.bottom, 16).allowsHitTesting(false) }
        .overlay(alignment: .topTrailing) {
          CameraControls(camera: $scene.camera, home: AntennaScene.home, id: "radio-camera")
            .scaleEffect(0.85, anchor: .topTrailing)
            .padding(8)
        }
        followControls
        ChoiceChips(
          items: RadioLobeScale.allCases, selection: Binding(get: { model.lobeScale }, set: { model.lobeScale = $0 }),
          id: "radio-lobe-scale"
        ) { ChipLabel(title: $0.title) }
        .padding(.horizontal, -Theme.panelPadding)
        KnobGrid(
          specs: [RadioKnobs.carrier(model)] + RadioKnobs.antenna(model.antenna.style, lambda: model.lambda),
          value: { RadioKnobs.antennaBinding($0, model) }, columns: 4)
        if model.beamLock, model.followPhone, model.antenna.style == .phasedArray {
          RadioDisabledReason("Beam lock is steering: the steer and azimuth knobs follow the target.")
        }
        ViewThatFits(in: .horizontal) {
          HStack(spacing: 10) { actions }
          VStack(alignment: .leading, spacing: 10) { actions }
        }
      }
      cutsPanel(build)
      numbersPanel(build)
      polarizationPanel(build)
      RadioAperturePanel(model: model)
    }
    .onAppear { model.setVisible(.antenna, true) }
    .onDisappear { model.setVisible(.antenna, false) }
  }

  // MARK: Pieces

  private var styleBinding: Binding<RF.AntennaStyle> {
    Binding(
      get: { model.antenna.style },
      set: { style in
        var p = model.antenna
        p.style = style
        model.antenna = p
        if style != .phasedArray { model.beamLock = false }
      })
  }

  private var motionProvenance: Provenance { app.live.channel(.motion).provenance }

  private var lobeProvenance: [Provenance] {
    model.followPhone ? [.model, motionProvenance] : [.model]
  }

  @ViewBuilder
  private func lobeChips(band: Color) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      StatusChip(
        text: SpectraFormat.frequency(model.carrier), detail: "λ \(SpectraFormat.wavelength(model.lambda))", color: band)
      if model.followPhone {
        StatusChip(
          text: model.waitingForAttitude ? "WAITING FOR MOTION" : "FOLLOWING · \(motionProvenance.badge)",
          color: Theme.phosphor, symbol: "iphone")
      }
      if model.followPhone, model.beamLock, model.antenna.style == .phasedArray {
        StatusChip(text: model.targetBehind ? "TARGET BEHIND ARRAY" : "BEAM LOCKED", color: Theme.amber, symbol: "target")
      }
    }
  }

  private var legend: some View {
    HStack(spacing: 10) {
      legendItem("E-plane", Theme.fieldE)
      legendItem("H-plane", Theme.fieldB)
      legendItem("Beam", Theme.amber)
    }
    .accessibilityElement(children: .combine)
  }

  private func legendItem(_ title: String, _ color: Color) -> some View {
    HStack(spacing: 4) {
      Capsule().fill(color).frame(width: 12, height: 3)
      Text(title.instrumentCaps).font(Theme.annotationFont).foregroundStyle(Theme.muted)
    }
  }

  @ViewBuilder
  private var followControls: some View {
    let isArray = model.antenna.style == .phasedArray
    GlassEffectContainer(spacing: 10) {
      ViewThatFits(in: .horizontal) {
        HStack(spacing: 10) {
          followToggles(isArray: isArray)
          aimButton
        }
        VStack(alignment: .leading, spacing: 10) {
          HStack(spacing: 10) { followToggles(isArray: isArray) }
          aimButton
        }
        VStack(alignment: .leading, spacing: 10) {
          followToggles(isArray: isArray)
          aimButton
        }
      }
    }
    if !isArray {
      RadioDisabledReason("Beam lock steers a phased array; pick Phased array to use it.")
    } else if !model.followPhone {
      RadioDisabledReason("Beam lock needs Follow phone: it re-steers as the phone turns.")
    }
  }

  @ViewBuilder
  private func followToggles(isArray: Bool) -> some View {
    toggleButton(
      "Follow phone", symbol: "iphone.radiowaves.left.and.right", isOn: model.followPhone, id: "radio-follow"
    ) { model.followPhone.toggle() }
    toggleButton("Beam lock", symbol: "target", isOn: model.beamLock, id: "radio-beam-lock") { model.beamLock.toggle() }
      .disabled(!isArray || !model.followPhone)
  }

  @ViewBuilder
  private var aimButton: some View {
    if model.followPhone {
      Button {
        model.aimAtBeam()
      } label: {
        Label("Aim here", systemImage: "scope").font(.subheadline.weight(.semibold)).frame(minHeight: 32)
      }
      .buttonStyle(.glass)
      .accessibilityHint("Makes the beam's current direction the target the readouts and Beam lock use.")
      .accessibilityIdentifier("radio-aim")
    }
  }

  private func toggleButton(_ title: String, symbol: String, isOn: Bool, id: String, action: @escaping () -> Void) -> some View {
    Button {
      Haptics.shared.selection()
      action()
    } label: {
      Label(title, systemImage: symbol)
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(isOn ? Theme.text : Theme.muted)
        .frame(minHeight: 32)
        .padding(.horizontal, 4)
    }
    .buttonStyle(.plain)
    .padding(.horizontal, 10)
    .padding(.vertical, 4)
    .glassEffect(isOn ? .regular.tint(Theme.phosphor.opacity(0.3)).interactive() : .regular.interactive(), in: .capsule)
    .accessibilityAddTraits(isOn ? .isSelected : [])
    .accessibilityValue(isOn ? "On" : "Off")
    .accessibilityIdentifier(id)
  }

  @ViewBuilder
  private var actions: some View {
    ActionButton("Tune Spectrum here", symbol: "waveform") { model.tuneSpectrum() }
      .accessibilityIdentifier("radio-antenna-tune-spectrum")
    ActionButton("Link budget", symbol: "chart.bar.xaxis") { model.page = .link }
      .accessibilityIdentifier("radio-antenna-open-link")
  }

  // MARK: 02 Cuts

  private func cutsPanel(_ build: RadioAntennaBuild?) -> some View {
    InstrumentPanel("Pattern cuts", number: "02", provenance: [.model]) {
      ChoiceChips(
        items: RadioChoice.items(RF.PatternPlane.allCases), selection: RadioChoice.binding({ solidPlane }, { solidPlane = $0 }),
        id: "radio-cut-plane"
      ) { plane in
        ChipLabel(title: plane.value.displayName)
      }
      .padding(.horizontal, -Theme.panelPadding)
      PlotWell(height: 300, grid: 0) {
        if let build {
          let e = RadioAntennaBuild.polar(build.eCut, floorDB: -40)
          let h = RadioAntennaBuild.polar(build.hCut, floorDB: -40)
          PolarPlot(
            gains: solidPlane == .e ? e : h, reference: solidPlane == .e ? h : e, floor: -40,
            color: solidPlane == .e ? Theme.fieldE : Theme.fieldB,
            accessibilityLabel: "\(solidPlane.displayName) cut, the other plane dashed")
            .accessibilityIdentifier("radio-cut-plot")
            .padding(8)
        } else {
          ProgressView().tint(Theme.phosphor)
        }
      }
      if let m = build?.model {
        ReadoutGrid(columns: 2) {
          Readout("HPBW E-plane", value: hpbw(m.ePlaneHPBWDeg), color: Theme.fieldE, provenance: .model)
          Readout("HPBW H-plane", value: hpbw(m.hPlaneHPBWDeg), color: Theme.fieldB, provenance: .model)
        }
      }
      Text("0° is the beam peak, angles run clockwise; rings every 10 dB down to −40 dB. The \(solidPlane == .e ? "H" : "E")-plane is dashed. E-plane contains the electric field at the peak; H-plane is at right angles to it.")
        .panelCaption()
    }
  }

  private func hpbw(_ deg: Double?) -> String {
    guard let deg else { return "Omni" }
    return "\(SpectraFormat.significant(deg, 3))°"
  }

  // MARK: 03 Numbers

  private func numbersPanel(_ build: RadioAntennaBuild?) -> some View {
    InstrumentPanel("Pattern numbers", number: "03", provenance: [.model]) {
      if let m = build?.model {
        let gainProvenance = Self.gainProvenance(m)
        ReadoutGrid(columns: 3) {
          Readout("Directivity", value: RadioKnobs.dBi(m.directivityDBi), provenance: .model)
            .accessibilityIdentifier("radio-readout-directivity")
          Readout("Gain", value: RadioKnobs.dBi(m.gainDBi), color: Theme.phosphor, provenance: gainProvenance)
          Readout("Efficiency", value: RadioKnobs.percent(m.radiationEfficiency), provenance: m.parameters.style == .pifa ? .inferred : .model)
          Readout("R rad", value: m.radiationResistance.map { ohms($0.value) } ?? "—", provenance: .model)
          Readout("Z in", value: impedance(m), provenance: .model)
          Readout("VSWR 50 Ω", value: vswr(m), provenance: .model)
          Readout("Mismatch", value: mismatchLoss(m), provenance: .model)
          Readout("Aperture", value: area(m.effectiveAperture), provenance: .model)
          Readout("Far field", value: RF.Units.format(distance: Self.farFieldStart(m.fieldRegions)), provenance: .model)
        }
        VStack(alignment: .leading, spacing: 8) {
          Text("R rad is the radiation resistance, Z in the feed impedance, mismatch the loss into a 50 Ω line, aperture the effective area Aₑ = Gλ²/4π, far field where the far-field region starts: the Fraunhofer distance 2D²/λ, but never closer than λ/2π.")
            .panelCaption()
          if m.inputImpedance == nil || m.mismatch == nil {
            Text("* Assumed matched: the reference gives no feed impedance for the \(Self.styleNoun(m.parameters.style)), so it is taken as matched to 50\u{00A0}Ω.")
              .panelCaption()
          } else if m.mismatch?.isResistiveOnly == true {
            Text("≥: only the radiation resistance is known, so VSWR and mismatch are lower bounds.")
              .panelCaption()
          }
          textRow("Polarization", m.polarizationDescription)
          textRow("Bandwidth", m.bandwidthNote ?? "Not modeled for this style (the reference gives no figure).")
          textRow("Gain basis", "\(m.gainBasis.source)" + (m.referenceGain.map { r in r.source == m.gainBasis.source ? "" : " · reference \(RadioKnobs.dBi(r.value)) (\(r.source))" } ?? ""))
          if m.fieldRegions.isElectricallySmall {
            textRow("Field regions", "Electrically small: the far field starts near λ/2π = \(RF.Units.format(distance: m.fieldRegions.smallAntennaBoundary)), not at 2D²/λ.")
          } else {
            let r = m.fieldRegions
            textRow("Field regions", "Reactive near field inside \(RF.Units.format(distance: max(r.reactiveNearField, r.smallAntennaBoundary))); far field beyond \(RF.Units.format(distance: Self.farFieldStart(r))).")
          }
          ForEach(Array(m.notes.enumerated()), id: \.offset) { _, note in
            Label(RadioCopy.us(note), systemImage: "info.circle").font(.caption).foregroundStyle(Theme.muted)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
      } else {
        ProgressView().tint(Theme.phosphor)
      }
    }
  }

  /// Where the far field starts, by RF's own region rule (`FieldRegions.region(at:)`): λ/2π for
  /// an electrically small antenna, else 2D²/λ but not closer than λ/2π. (2D²/λ alone gave
  /// 614 µm for a 0.05λ dipole at 2.44 GHz, against "far field near λ/2π = 1.96 cm" below it.)
  static func farFieldStart(_ r: RF.FieldRegions) -> Double {
    r.isElectricallySmall ? r.smallAntennaBoundary : max(r.farField, r.smallAntennaBoundary)
  }

  /// A table gain is TABLE; an estimated one (PIFA: D × an assumed efficiency) is INFERRED.
  static func gainProvenance(_ m: RF.AntennaModel) -> Provenance {
    switch m.gainBasis.basis {
    case .table: .table
    case .estimate: .inferred
    default: .model
    }
  }

  private func textRow(_ title: String, _ text: String) -> some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(title.instrumentCaps).font(Theme.readoutTitleFont).foregroundStyle(Theme.muted)
      Text(RadioCopy.us(text)).font(.footnote).foregroundStyle(Theme.text).fixedSize(horizontal: false, vertical: true)
    }
    .accessibilityElement(children: .combine)
  }

  private func ohms(_ r: Double) -> String {
    r.isFinite ? "\(SpectraFormat.significant(r, 3)) Ω" : "∞ Ω"
  }

  private func impedance(_ m: RF.AntennaModel) -> String {
    guard let z = m.inputImpedance else { return "Matched*" }
    if z.resistiveOnly { return "R \(ohms(z.z.re))" }
    let x = z.z.im
    return "\(SpectraFormat.significant(z.z.re, 3)) \(x < 0 ? "−" : "+") j\(SpectraFormat.significant(abs(x), 3)) Ω"
  }

  private func vswr(_ m: RF.AntennaModel) -> String {
    guard let mm = m.mismatch else { return "Matched*" }
    let v = mm.vswr
    let text = v.isFinite ? SpectraFormat.significant(v, 3) : "∞"
    return mm.isResistiveOnly ? "≥ \(text)" : text
  }

  private func mismatchLoss(_ m: RF.AntennaModel) -> String {
    guard let mm = m.mismatch else { return "0 dB*" }
    let l = mm.mismatchLossDB
    let text = l.isFinite ? SpectraFormat.decibels(l, decimals: 2) : "∞ dB"
    return mm.isResistiveOnly ? "≥ \(text)" : text
  }

  private func area(_ a: Double) -> String {
    guard a.isFinite, a > 0 else { return "—" }
    if a >= 1 { return "\(SpectraFormat.significant(a, 3)) m²" }
    if a >= 1e-4 { return "\(SpectraFormat.significant(a * 1e4, 3)) cm²" }
    return "\(SpectraFormat.significant(a * 1e6, 3)) mm²"
  }

  // MARK: 04 Polarization

  private func polarizationPanel(_ build: RadioAntennaBuild?) -> some View {
    InstrumentPanel("Polarization", number: "04", provenance: model.followPhone ? [.model, motionProvenance] : [.model]) {
      ChoiceChips(
        items: RadioChoice.items(RF.ReferencePolarization.allCases),
        selection: RadioChoice.binding({ model.reference }, { model.reference = $0 }), id: "radio-reference"
      ) { ChipLabel(title: $0.value.displayName).accessibilityLabel(RadioAntennaPage.receiverName($0.value)) }
      .padding(.horizontal, -Theme.panelPadding)
      VisibleTimeline(minimumInterval: 0.1, paused: !model.followPhone) { _ in
        let f = model.linkFactor()
        ReadoutGrid(columns: 3) {
          Readout("Pattern", value: f.map { SpectraFormat.decibels($0.patternDB, decimals: 1) } ?? "—", provenance: .model)
          Readout("PLF", value: f.map { Self.plf($0.polarizationDB) } ?? "—", color: Theme.dialTheta, provenance: .model)
          Readout(
            "Gain", value: f.map { RadioKnobs.dBi($0.gainDB) } ?? "—", color: Theme.phosphor,
            provenance: build.map { Self.gainProvenance($0.model) } ?? .model)
        }
      }
      Text(
        model.followPhone
          ? "The target is a fixed direction in the room (Aim here sets it to the beam's current direction). Turn the phone: the pattern and the polarization toward it change, and so does the polarization loss factor PLF\u{00A0}=\u{00A0}|\u{2060}êₜ·êᵣ\u{2060}|² against a \(Self.receiverName(model.reference)) receiver."
          : "Toward the beam peak, with the phone upright: PLF\u{00A0}=\u{00A0}|\u{2060}êₜ·êᵣ\u{2060}|² against a \(Self.receiverName(model.reference)) receiver (vertical = along gravity). Turn on Follow phone to measure toward a fixed direction while you turn the phone."
      )
      .panelCaption()
    }
  }

  /// The style as a noun inside a sentence ("the phased array", "the Yagi", "the PIFA").
  static func styleNoun(_ style: RF.AntennaStyle) -> String {
    switch style {
    case .yagi: "Yagi"
    case .pifa: "PIFA"
    default: style.displayName.lowercased()
    }
  }

  /// The receiver polarization in words (the chips show RF's short names: V, H, +45°…).
  static func receiverName(_ p: RF.ReferencePolarization) -> String {
    switch p {
    case .vertical: "vertical"
    case .horizontal: "horizontal"
    case .slant45: "+45° slant"
    case .slantMinus45: "−45° slant"
    case .rhcp: "right-hand circular"
    case .lhcp: "left-hand circular"
    }
  }

  /// PLF as a ratio and in dB, short enough for one readout line. RF floors a cross-polarized
  /// match at −60 dB, which reads as "≈ 0".
  static func plf(_ db: Double) -> String {
    guard db.isFinite, db > -59.95 else { return "≈ 0 (≤ −60 dB)" }
    let linear = pow(10, db / 10)
    let ratio = linear >= 0.01 ? SpectraFormat.significant(linear, 2) : SpectraFormat.scientific(linear, digits: 1)
    return "\(ratio) (\(SpectraFormat.decibels(db, decimals: 1)))"
  }
}
