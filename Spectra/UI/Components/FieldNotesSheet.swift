import SwiftUI

/// A tab's field notes: what is real and what is modelled, how to read the instrument, and
/// sources (honest copy, as in spectra-lab and Orbitals). Paragraphs are Markdown
/// (`**bold**`, `*italic*`, `[links](https://…)`).
///
/// ```swift
/// FieldNotes(title: "Radio", intro: "An antenna and frequency simulator.", sections: [
///   FieldNoteSection(number: "01", title: "Antennas", paragraphs: ["Patterns use the far-field formulas …"],
///     items: [FieldNoteItem(.model, "Directivity", "Computed from the pattern integral.")],
///     sources: [FieldNoteSource("Balanis, Antenna Theory", "https://…")])
/// ])
/// ```
struct FieldNotes {
  var title: String
  var intro: String
  var sections: [FieldNoteSection]
  /// Append the provenance badge legend as the last section.
  var includesBadgeLegend = true

  init(title: String, intro: String, sections: [FieldNoteSection], includesBadgeLegend: Bool = true) {
    self.title = title
    self.intro = intro
    self.sections = sections
    self.includesBadgeLegend = includesBadgeLegend
  }
}

/// One numbered panel of field notes.
struct FieldNoteSection: Identifiable {
  var id: String { number + title }
  var number: String
  var title: String
  var paragraphs: [String] = []
  var items: [FieldNoteItem] = []
  var sources: [FieldNoteSource] = []
}

/// A statement tagged with where it comes from.
struct FieldNoteItem: Identifiable {
  var id: String { title }
  var provenance: Provenance
  var title: String
  var detail: String

  init(_ provenance: Provenance, _ title: String, _ detail: String) {
    self.provenance = provenance
    self.title = title
    self.detail = detail
  }
}

/// A cited source.
struct FieldNoteSource: Identifiable {
  var id: String { title }
  var title: String
  var url: URL?

  init(_ title: String, _ url: String? = nil) {
    self.title = title
    self.url = url.flatMap(URL.init(string:))
  }
}

/// The ⓘ sheet: numbered phosphor panels in a scroll view, Done at the top right,
/// `[.medium, .large]` detents. Identifier `field-notes-scroll`.
struct FieldNotesSheet: View {
  let notes: FieldNotes
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 20) {
          Text(markdown(notes.intro))
            .font(.callout)
            .foregroundStyle(.white.opacity(0.85))
            .fixedSize(horizontal: false, vertical: true)
          ForEach(allSections) { section in
            InstrumentPanel(section.title, number: section.number) {
              VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(section.paragraphs.enumerated()), id: \.offset) { _, paragraph in
                  Text(markdown(paragraph))
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(section.items) { item in
                  HStack(alignment: .firstTextBaseline, spacing: 10) {
                    ProvenanceBadge(item.provenance)
                    VStack(alignment: .leading, spacing: 2) {
                      Text(item.title).font(.subheadline.weight(.medium)).foregroundStyle(Theme.phosphor)
                      Text(markdown(item.detail))
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.8))
                        .fixedSize(horizontal: false, vertical: true)
                    }
                  }
                  .accessibilityElement(children: .combine)
                }
                if !section.sources.isEmpty {
                  VStack(alignment: .leading, spacing: 6) {
                    Text("SOURCES").font(Theme.eyebrowFont).tracking(1.6).foregroundStyle(Theme.muted)
                    ForEach(section.sources) { source in
                      if let url = source.url {
                        Link(destination: url) {
                          Label(source.title, systemImage: "arrow.up.forward.app").font(.footnote)
                        }
                      } else {
                        Text(source.title).font(.footnote).foregroundStyle(Theme.muted)
                      }
                    }
                  }
                }
              }
            }
          }
        }
        .padding(Theme.gutter)
      }
      .accessibilityIdentifier("field-notes-scroll")
      .background(Theme.background)
      .navigationTitle(notes.title)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") {
            Haptics.shared.tap()
            dismiss()
          }
          .accessibilityIdentifier("field-notes-done")
        }
      }
    }
    .presentationDetents([.medium, .large])
    .presentationDragIndicator(.visible)
  }

  private var allSections: [FieldNoteSection] {
    guard notes.includesBadgeLegend else { return notes.sections }
    let number = String(format: "%02d", notes.sections.count + 1)
    return notes.sections + [
      FieldNoteSection(
        number: number, title: "Reading the badges",
        paragraphs: ["Every number in Spectra says where it comes from. A result built from several inputs carries all of their badges."],
        items: Provenance.allCases.map { FieldNoteItem($0, $0.badge.capitalized, $0.meaning) })
    ]
  }

  private func markdown(_ text: String) -> AttributedString {
    (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
      ?? AttributedString(text)
  }
}
