import SwiftUI

/// A numbered phosphor instrument panel (Orbitals): solid panel fill, radius 26, 7 % white
/// hairline, monospaced uppercase title "01 WAVE SCOPE". Never glass.
///
/// ```swift
/// InstrumentPanel("Wave scope", number: "01", provenance: [.model]) {
///   PlotWell { LinePlot(...) }
///   Text("E and B oscillate in phase.").panelCaption()
/// }
/// ```
struct InstrumentPanel<Content: View, Accessory: View>: View {
  let title: String
  let number: String
  var provenance: [Provenance] = []
  @ViewBuilder var accessory: Accessory
  @ViewBuilder var content: Content

  init(
    _ title: String, number: String, provenance: [Provenance] = [],
    @ViewBuilder accessory: () -> Accessory, @ViewBuilder content: () -> Content
  ) {
    self.title = title
    self.number = number
    self.provenance = provenance
    self.accessory = accessory()
    self.content = content()
  }

  @Environment(\.dynamicTypeSize) private var typeSize

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      HStack(alignment: typeSize.isAccessibilitySize ? .top : .center, spacing: 8) {
        // Only the title group is combined into the header element; the accessory stays a
        // separate element so its button keeps its own identifier and VoiceOver reaches it
        // (integration: live-review, scope-review).
        heading
          .accessibilityElement(children: .combine)
          .accessibilityAddTraits(.isHeader)
        Spacer(minLength: 0)
        accessory
      }
      .font(Theme.panelTitleFont)
      .foregroundStyle(Theme.muted)
      content
    }
    .padding(Theme.panelPadding)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Theme.panel, in: .rect(cornerRadius: Theme.panelRadius))
    .overlay {
      RoundedRectangle(cornerRadius: Theme.panelRadius).strokeBorder(Theme.hairline)
        .allowsHitTesting(false)
    }
  }
}

extension InstrumentPanel {
  /// Number, title and badges. At accessibility sizes the title may wrap and the badges move
  /// under it, so long titles are not truncated.
  @ViewBuilder fileprivate var heading: some View {
    if typeSize.isAccessibilitySize {
      VStack(alignment: .leading, spacing: 6) {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          Text(number).foregroundStyle(Theme.phosphor)
          Text(title.instrumentCaps).tracking(1)
            .lineLimit(3)
            .fixedSize(horizontal: false, vertical: true)
        }
        if !provenance.isEmpty { ProvenanceBadges(provenance) }
      }
    } else {
      HStack(spacing: 8) {
        Text(number).foregroundStyle(Theme.phosphor)
        Text(title.instrumentCaps).tracking(2)
          .lineLimit(1)
          .minimumScaleFactor(0.7)
        if !provenance.isEmpty { ProvenanceBadges(provenance) }
      }
    }
  }
}

extension InstrumentPanel where Accessory == EmptyView {
  init(_ title: String, number: String, provenance: [Provenance] = [], @ViewBuilder content: () -> Content) {
    self.init(title, number: number, provenance: provenance, accessory: { EmptyView() }, content: content)
  }
}

/// The dark plot well inside panels (`#040807`, radius 18, faint phosphor grid, 20 %
/// phosphor frame). Put a plot or a `MetalCanvas` inside.
struct PlotWell<Content: View>: View {
  var height: CGFloat? = nil
  var grid: CGFloat = 26
  @ViewBuilder var content: Content

  var body: some View {
    ZStack {
      Theme.plotWell
      if grid > 0 { PlotGrid(spacing: grid) }
      content
    }
    .frame(height: height)
    .clipShape(.rect(cornerRadius: Theme.wellRadius))
    .overlay {
      RoundedRectangle(cornerRadius: Theme.wellRadius)
        .strokeBorder(Theme.phosphor.opacity(0.2), lineWidth: 1)
        .allowsHitTesting(false)
    }
  }
}

/// The faint grid inside plot wells, centred (spectra-lab `clear()`).
struct PlotGrid: View {
  var spacing: CGFloat = 26

  var body: some View {
    Canvas { context, size in
      var path = Path()
      var x = (size.width / 2).truncatingRemainder(dividingBy: spacing)
      while x <= size.width {
        path.move(to: CGPoint(x: x.rounded() + 0.5, y: 0))
        path.addLine(to: CGPoint(x: x.rounded() + 0.5, y: size.height))
        x += spacing
      }
      var y = (size.height / 2).truncatingRemainder(dividingBy: spacing)
      while y <= size.height {
        path.move(to: CGPoint(x: 0, y: y.rounded() + 0.5))
        path.addLine(to: CGPoint(x: size.width, y: y.rounded() + 0.5))
        y += spacing
      }
      context.stroke(path, with: .color(Theme.grid), lineWidth: 1)
    }
    .accessibilityHidden(true)
    .allowsHitTesting(false)
  }
}

/// Eyebrow: a 5 pt phosphor dot and tracked monospaced caption ("LIVE · MAGNETOMETER").
struct Eyebrow: View {
  let text: String
  var color: Color = Theme.phosphor

  init(_ text: String, color: Color = Theme.phosphor) {
    self.text = text
    self.color = color
  }

  var body: some View {
    HStack(spacing: 7) {
      Circle().fill(color).frame(width: 5, height: 5)
      Text(text.instrumentCaps).font(Theme.eyebrowFont).tracking(2).foregroundStyle(Theme.muted)
    }
    .accessibilityElement(children: .combine)
  }
}

extension View {
  /// The muted explanatory caption every panel ends with.
  func panelCaption() -> some View {
    font(.caption).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
  }
}
