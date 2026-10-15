import SwiftUI

/// The sheets every tab can open from its top bar.
enum ScreenSheet: String, Identifiable {
  case dials, notes, settings
  var id: String { rawValue }
}

/// The frame of every tab (SPEC-features.md, "Every tab"): its own `NavigationStack`, the
/// persistent `TopBar` (Dials · title · ⓘ ⚙), the `SpectrumStrip`, the content (scrolling by
/// default), the floating `Transport`, and the three sheets: the tab's dials, its field
/// notes, and Settings.
///
/// ```swift
/// InstrumentScreen(tab: .radio, subtitle: "RF lab", notes: RadioNotes.notes,
///                  transport: TransportConfig(timeMapping: .heterodyned(fRef: model.carrier))) {
///   ControlSheet(title: "Radio controls", resetDials: model.resetDials) { KnobGrid(...) }
/// } content: {
///   InstrumentPanel("Antenna", number: "01") { ... }
/// }
/// ```
struct InstrumentScreen<Dials: View, Content: View>: View {
  let tab: AppTab
  var title: String?
  var subtitle: String?
  var notes: FieldNotes
  /// nil hides the transport (screens with nothing that moves).
  var transport: TransportConfig?
  /// false: the content fills the space under the strip (full-bleed canvases, own scroll views).
  var scrolls: Bool
  @ViewBuilder var dials: () -> Dials
  @ViewBuilder var content: () -> Content

  @Environment(AppModel.self) private var app
  @State private var sheet: ScreenSheet?

  init(
    tab: AppTab, title: String? = nil, subtitle: String? = nil, notes: FieldNotes,
    transport: TransportConfig? = TransportConfig(), scrolls: Bool = true,
    @ViewBuilder dials: @escaping () -> Dials, @ViewBuilder content: @escaping () -> Content
  ) {
    self.tab = tab
    self.title = title
    self.subtitle = subtitle
    self.notes = notes
    self.transport = transport
    self.scrolls = scrolls
    self.dials = dials
    self.content = content
  }

  var body: some View {
    NavigationStack {
      VStack(spacing: 0) {
        VStack(spacing: 10) {
          TopBar(
            title: title ?? tab.title, subtitle: subtitle, rootIdentifier: tab.rootIdentifier,
            onDials: { sheet = .dials }, onNotes: { sheet = .notes }, onSettings: { sheet = .settings })
          SpectrumStrip()
        }
        .padding(.horizontal, Theme.gutter)
        .padding(.top, 4)
        .padding(.bottom, 8)
        if scrolls {
          ScrollView {
            VStack(alignment: .leading, spacing: Theme.stackSpacing) { content() }
              .padding(.horizontal, Theme.gutter)
              .padding(.top, 6)
              .padding(.bottom, 28)
          }
          .scrollIndicators(.hidden)
          .accessibilityIdentifier("\(tab.rawValue)-scroll")
        } else {
          content()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
      }
      .safeAreaInset(edge: .bottom, spacing: 0) {
        if let transport { Transport(config: transport) }
      }
      .background(Theme.background.ignoresSafeArea())
      .toolbar(.hidden, for: .navigationBar)
      .sheet(item: $sheet) { which in
        Group {
          switch which {
          case .dials: dials()
          case .notes: FieldNotesSheet(notes: notes)
          case .settings: SettingsSheet()
          }
        }
        .environment(app)
      }
    }
  }
}
