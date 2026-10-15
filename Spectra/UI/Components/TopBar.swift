import SwiftUI

/// The persistent top bar of every tab and every full-screen view (Orbitals' rule: the Dials
/// shortcut always sits top-left): a glass Dials button, the title, and a glass capsule with
/// Field notes (ⓘ) and Settings (⚙). `InstrumentScreen` places it; full-screen views put
/// one at the top of their own overlay.
///
/// Identifiers: `dials-open`, `field-notes-open`, `settings-open`, and the title carries
/// `rootIdentifier` when given (`tab-root-<tab>`).
struct TopBar: View {
  let title: String
  var subtitle: String? = nil
  var rootIdentifier: String? = nil
  let onDials: () -> Void
  let onNotes: () -> Void
  let onSettings: () -> Void
  /// Extra trailing buttons inside the capsule (e.g. Close on a full-screen view).
  var trailing: [TopBarButton] = []

  var body: some View {
    GlassEffectContainer(spacing: 12) {
      HStack(alignment: .center, spacing: 12) {
        Button {
          Haptics.shared.tap()
          onDials()
        } label: {
          Image(systemName: "dial.medium")
            .font(.body.weight(.semibold))
            .frame(width: 22, height: 22)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .controlSize(.large)
        .accessibilityLabel("Dials")
        .accessibilityHint("Opens this tab's controls.")
        .accessibilityIdentifier("dials-open")

        VStack(alignment: .leading, spacing: 1) {
          if let subtitle {
            Text(subtitle.instrumentCaps)
              .font(Theme.eyebrowFont)
              .tracking(1.6)
              .foregroundStyle(Theme.muted)
              .lineLimit(1)
          }
          Text(title)
            .font(.title3.weight(.semibold))
            .foregroundStyle(Theme.text)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier(rootIdentifier ?? "screen-title")
        }
        .frame(maxWidth: .infinity, alignment: .leading)

        HStack(spacing: 0) {
          ForEach(trailing) { item in
            iconButton(item.symbol, label: item.title, id: item.id, action: item.action)
          }
          iconButton("info.circle", label: "Field notes", id: "field-notes-open", action: onNotes)
          iconButton("gearshape", label: "Settings", id: "settings-open", action: onSettings)
        }
        .padding(.horizontal, 4)
        .glassEffect(.regular.interactive(), in: .capsule)
      }
    }
  }

  private func iconButton(_ symbol: String, label: String, id: String, action: @escaping () -> Void) -> some View {
    Button {
      Haptics.shared.tap()
      action()
    } label: {
      Image(systemName: symbol)
        .font(.body.weight(.semibold))
        .foregroundStyle(Theme.text)
        .frame(width: 42, height: 44)
        .contentShape(.rect)
    }
    .buttonStyle(.plain)
    .accessibilityLabel(label)
    .accessibilityIdentifier(id)
  }
}

/// An extra button in the top bar's capsule.
struct TopBarButton: Identifiable {
  /// Accessibility identifier and identity.
  let id: String
  let title: String
  let symbol: String
  let action: () -> Void
}

/// A transient glass capsule ("Source A tuned to …"). Tap to dismiss.
struct ToastView: View {
  let toast: Toast
  var onDismiss: () -> Void = {}

  var body: some View {
    Label {
      Text(toast.text).lineLimit(2).multilineTextAlignment(.leading)
    } icon: {
      Image(systemName: toast.symbol).foregroundStyle(Theme.phosphor)
    }
    .font(.footnote.weight(.medium))
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
    .glassEffect(.regular, in: .capsule)
    .padding(.horizontal, Theme.gutter)
    .onTapGesture(perform: onDismiss)
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(.isStaticText)
    .accessibilityIdentifier("toast")
  }
}
