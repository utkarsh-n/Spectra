import SwiftUI

/// A tab's control sheet (Orbitals `InstrumentControlSheet`): its own `NavigationStack` with
/// an inline title and Done, `[.medium, .large]` detents with the content beneath staying
/// live up to medium, and a pinned bottom bar with Reset dials / Reset alignment that is
/// always visible.
///
/// Identifiers: `dials-scroll`, `dials-done`, `dials-reset`, `dials-reset-alignment`.
///
/// ```swift
/// .sheet(isPresented: $showDials) {
///   ControlSheet(title: "Field controls", resetDials: model.resetDials, resetAlignment: model.align) {
///     KnobGrid(specs: model.knobs) { model.binding(for: $0) }
///   }
/// }
/// ```
struct ControlSheet<Content: View>: View {
  let title: String
  var resetDials: (() -> Void)? = nil
  var resetAlignment: (() -> Void)? = nil
  var resetDialsHint = "Restore every dial on this sheet to its default."
  var resetAlignmentHint = "Recenter the views and restore their original rotation and zoom."
  @ViewBuilder var content: Content

  @Environment(\.dismiss) private var dismiss
  @Environment(\.dynamicTypeSize) private var typeSize
  @State private var detent: PresentationDetent = .large

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: Theme.stackSpacing) { content }
          .padding(Theme.gutter)
      }
      .accessibilityIdentifier("dials-scroll")
      .background(Theme.background)
      .navigationTitle(title)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") {
            Haptics.shared.tap()
            dismiss()
          }
          .accessibilityIdentifier("dials-done")
        }
      }
      .safeAreaInset(edge: .bottom, spacing: 0) {
        if resetDials != nil || resetAlignment != nil { resetBar }
      }
    }
    .presentationDetents([.medium, .large], selection: $detent)
    .presentationDragIndicator(.visible)
    .presentationBackgroundInteraction(.enabled(upThrough: .medium))
  }

  private var resetBar: some View {
    GlassEffectContainer(spacing: 12) {
      let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 10)) : AnyLayout(HStackLayout(spacing: 12))
      layout {
        if let resetDials {
          resetButton("Reset dials", symbol: "arrow.counterclockwise", action: resetDials)
            .accessibilityHint(resetDialsHint)
            .accessibilityIdentifier("dials-reset")
        }
        if let resetAlignment {
          resetButton("Reset alignment", symbol: "viewfinder", action: resetAlignment)
            .accessibilityHint(resetAlignmentHint)
            .accessibilityIdentifier("dials-reset-alignment")
        }
      }
    }
    .padding(12)
    .frame(maxWidth: .infinity)
    .background(Theme.background.opacity(0.96))
  }

  private func resetButton(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
    Button {
      Haptics.shared.success()
      action()
    } label: {
      Label(title, systemImage: symbol)
        .font(.subheadline.weight(.semibold))
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, minHeight: 32)
        .padding(.vertical, 6)
    }
    .buttonStyle(.glass)
    .tint(Theme.phosphor)
    .accessibilityLabel(title)
  }
}

/// A short muted caption inside sheets and panels ("Drag a dial up or right.").
struct SheetCaption: View {
  let text: String
  init(_ text: String) { self.text = text }
  var body: some View { Text(text).panelCaption() }
}
