import Foundation

/// UI copy is American English (SPEC.md §2 house rules). spectra-lab, whose strings the Core
/// reproduces, writes British spellings; the Core now emits American ones, and the parity
/// vectors' expected strings pass through `us(_:)` when they are decoded, so parity still
/// compares the same sentences (integration, Docs/notes/integration.md).
nonisolated enum AmericanSpelling {
  /// Longest first, so "millimetres" is not half-replaced by a shorter key.
  private static let replacements: [(String, String)] = [
    ("neighbouring", "neighboring"), ("neighbours", "neighbors"), ("neighbour", "neighbor"),
    ("behaviour", "behavior"), ("modelling", "modeling"), ("modelled", "modeled"), ("labelled", "labeled"),
    ("Centre", "Center"), ("centre", "center"), ("Colour", "Color"), ("colour", "color"),
    ("metres", "meters"), ("metre", "meter"), ("vapour", "vapor"), ("optimise", "optimize"),
    ("analysed", "analyzed"), ("fibre", "fiber"),
  ]

  /// `text` with the British spellings above replaced by American ones.
  static func us(_ text: String) -> String {
    var out = text
    for (gb, us) in replacements where out.contains(gb) {
      out = out.replacingOccurrences(of: gb, with: us)
    }
    return out
  }
}
