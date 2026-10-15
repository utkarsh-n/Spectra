import SwiftUI

/// Radio → Antenna → 05 Aperture phase space (SPEC-features §3c): the spatial Wigner
/// W(x, kₓ) of the antenna's source distribution (Phase engine, Utkarsh's convention C), its
/// x marginal (the field across the window) on the left and its k marginal — the far-field
/// pattern, kₓ = k·sinθ — underneath against RF's own pattern factor. The distance knob shears
/// it (Fresnel), from the aperture out to the far field; steering a phased array slides it in kₓ.
struct RadioAperturePanel: View {
  let model: RadioModel
  @Environment(\.dynamicTypeSize) private var typeSize

  var body: some View {
    InstrumentPanel("Aperture phase space", number: "05", provenance: [.model]) {
      ChoiceChips(
        items: RadioChoice.items(RF.PatternPlane.allCases),
        selection: RadioChoice.binding({ model.aperturePlane }, { model.aperturePlane = $0 }), id: "radio-aperture-plane"
      ) { ChipLabel(title: $0.value.displayName) }
      .padding(.horizontal, -Theme.panelPadding)
      if let a = model.apertureBuild {
        content(a)
      } else if model.apertureComputing || model.antennaBuild == nil {
        PlotWell(height: 220) { ProgressView().tint(Theme.phosphor) }
      } else {
        ContentUnavailableView {
          Label("No line source", systemImage: "square.stack.3d.up")
        } description: {
          Text(noSourceReason)
        }
        .accessibilityIdentifier("radio-aperture-none")
      }
    }
  }

  private var noSourceReason: String {
    switch model.antenna.style {
    case .helix, .smallLoop, .pifa:
      "The \(RadioAntennaPage.styleNoun(model.antenna.style)) model has no line source behind its pattern, so there is no aperture to take a Wigner of. Pick a dipole, horn, dish, patch, Yagi or phased array."
    default:
      "A wire antenna is a point source in its H-plane. Switch to the E-plane to see the current along the wire."
    }
  }

  @ViewBuilder
  private func content(_ a: RadioApertureBuild) -> some View {
    let image = RadioHeatImage.make(a.image, rows: a.rows, columns: a.columns, map: .diverging, timeAcross: false)
    let x = SpectraFormat.significant(a.xRange.upperBound, 3)
    let k = Self.wavenumberName(a.axisName)
    HStack(alignment: .top, spacing: 6) {
      nearFieldStrip(a)
        .frame(width: 38)
      VStack(spacing: 4) {
        PlotWell(height: 230, grid: 0) {
          RadioHeatMapView(
            image: image, title: "W(\(a.axisName), \(k))", yLabels: ["+\(x)λ", "0", "−\(x)λ"],
            xLabels: ["\(k) = −k", "0", "+k"],
            accessibilityLabel: "Spatial Wigner distribution of the aperture",
            accessibilityValue: "Position \(a.axisName) vertical, wavenumber across; orange positive, blue negative")
          .accessibilityIdentifier("radio-aperture-wigner")
        }
        farFieldStrip(a, k: k)
          .frame(height: 84)
      }
    }
    RadioDivergingLegend()
    KnobGrid(
      specs: [RadioKnobs.fresnel], value: { _ in Binding(get: { model.fresnelRatio }, set: { model.fresnelRatio = $0 }) },
      columns: typeSize.isAccessibilitySize ? 1 : 3)
    ReadoutGrid(columns: 3) {
      Readout("Distance z", value: "\(SpectraFormat.significant(a.distance, 3))λ", provenance: .model)
      Readout("2D²/λ", value: "\(SpectraFormat.significant(a.farFieldDistance, 3))λ", provenance: .model)
      Readout("Δ vs RF", value: SpectraFormat.scientific(a.maxDeviation, digits: 2), color: Theme.phosphor, provenance: .model)
      Readout("Extent", value: "\(SpectraFormat.significant(a.extent, 3))λ", provenance: .model)
      Readout("Samples", value: "\(a.samples)\(a.isDiscrete ? " elements" : "")", provenance: .model)
      Readout("Direction u", value: a.directionCosine, provenance: .model)
    }
    Text(
      "\(Self.sentence(a.description)). Each column is a direction \(k) = k·\(a.directionCosine); summing a column over \(a.axisName) gives the far-field power there (amber, bottom), which matches the RF engine's pattern factor (dashed; Δ vs RF is their largest difference, both scaled to 1). Turn the distance up and the picture shears: rays at \(k) drift sideways by z·\(k)/k, so the field across the window (left) spreads from the aperture into the beam. Orange is positive, blue negative: interference between parts of the aperture shows up as signed fringes."
    )
    .panelCaption()
    Text("Spacetime Wigner distribution: Utkarsh's construction and convention (C). This is its spatial slice.")
      .font(.caption2)
      .foregroundStyle(Theme.dim)
  }

  /// RF's description of the source as the start of a sentence (capitalized, American spelling).
  static func sentence(_ text: String) -> String {
    let s = RadioCopy.us(text)
    return s.prefix(1).uppercased() + s.dropFirst()
  }

  /// The wavenumber along the source axis: kₓ, or k_y / k_z written plainly ("ky", "kz").
  static func wavenumberName(_ axis: String) -> String { axis == "x" ? "kₓ" : "k\(axis)" }

  /// |ψ_z(x)|² across the window (top = +x), as a horizontal profile.
  private func nearFieldStrip(_ a: RadioApertureBuild) -> some View {
    Canvas { ctx, size in
      let rect = CGRect(x: 2, y: 18, width: size.width - 4, height: 230 - 34)
      ctx.stroke(Path(rect), with: .color(Theme.phosphor.opacity(0.18)), lineWidth: 0.75)
      ctx.annotation("|ψ|²", at: CGPoint(x: rect.midX, y: 8), color: Theme.muted)
      let n = a.nearField.count
      guard n > 1 else { return }
      var path = Path()
      for k in 0..<n {
        let p = CGPoint(x: rect.minX + rect.width * CGFloat(a.nearField[k]), y: rect.minY + rect.height * CGFloat(k) / CGFloat(n - 1))
        if k == 0 { path.move(to: p) } else { path.addLine(to: p) }
      }
      ctx.phosphorStroke(path, color: Theme.phosphor, width: 1.2, glow: 0.7)
    }
    .frame(height: 230)
    .background(Theme.plotWell, in: .rect(cornerRadius: 10))
    .accessibilityElement()
    .accessibilityLabel("Field intensity across the window")
  }

  /// The far field from the Wigner's k marginal (Phase, amber) and RF's |F(u)|² (dashed).
  private func farFieldStrip(_ a: RadioApertureBuild, k: String) -> some View {
    Canvas { ctx, size in
      let rect = CGRect(x: 2, y: 4, width: size.width - 4, height: size.height - 8)
      ctx.fill(Path(roundedRect: rect, cornerRadius: 8), with: .color(Theme.plotWell))
      func path(_ v: [Double]) -> Path {
        var p = Path()
        let n = v.count
        guard n > 1 else { return p }
        for k in 0..<n {
          let pt = CGPoint(
            x: rect.minX + rect.width * (CGFloat(k) + 0.5) / CGFloat(n),
            y: rect.maxY - 4 - (rect.height - 24) * CGFloat(min(1, max(0, v[k]))))
          if k == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
        }
        return p
      }
      ctx.phosphorStroke(path(a.rfFactor), color: Theme.muted, width: 1, glow: 0, dash: [4, 3])
      ctx.phosphorStroke(path(a.farField), color: Theme.amber, width: 1.4, glow: 0.8)
      ctx.annotation("FAR FIELD = Σ\(a.axisName == "x" ? "ₓ" : a.axisName) W", at: CGPoint(x: rect.minX + 6, y: rect.minY + 8), anchor: .leading, color: Theme.amber)
      ctx.annotation("RF |F|²", at: CGPoint(x: rect.maxX - 6, y: rect.minY + 8), anchor: .trailing, color: Theme.muted)
    }
    .accessibilityElement()
    .accessibilityLabel("Far-field pattern from the Wigner marginal, compared with the RF pattern")
    .accessibilityValue("Largest difference \(SpectraFormat.scientific(a.maxDeviation, digits: 2))")
  }
}
