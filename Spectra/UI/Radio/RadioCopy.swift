import Foundation

/// The RF engine's sentences as the Radio tab shows them. UI copy is American English (house
/// rules): the RF strings are American at the source since integration, and this filter stays
/// as a guard through the shared `AmericanSpelling` table (Core). It also turns the engine's
/// plain-text notation into what the knobs and captions write ("R_r" → "Rᵣ", "log10" → "log₁₀"),
/// spells out the research notes' "[S]" marker ("secondary source") and names the internal
/// "rf-physics" document as the RF reference the field notes cite.
nonisolated enum RadioCopy {
  /// `text` with British spellings replaced by American ones and the engine's notation made
  /// readable.
  static func us(_ text: String) -> String { notation(AmericanSpelling.us(text)) }

  /// Plain-text notation in RF's strings → the symbols the rest of the tab uses. Longest first.
  private static let replacements: [(String, String)] = [
    ("[S, not in the physics reference]", "(secondary source, not in the RF reference)"),
    ("D × e_rad", "D × radiation efficiency"), ("P_t/P_c", "total/carrier power"), ("rf-physics ", "RF reference §"),
    ("[S]", "(secondary source)"), ("log10", "log₁₀"),
    ("ε_ap", "εₐₚ"), ("G_el", "Gₑₗ"), ("R_in", "Rᵢₙ"), ("R_r", "Rᵣ"), ("L_e", "Lₑ"), ("T_u", "Tᵤ"),
    ("T_s", "Tₛ"), ("f_c/128", "carrier / 128"),
  ]

  static func notation(_ text: String) -> String {
    guard text.contains("_") || text.contains("[S") || text.contains("log10") || text.contains("rf-physics") else { return text }
    var out = text
    for (plain, shown) in replacements where out.contains(plain) {
      out = out.replacingOccurrences(of: plain, with: shown)
    }
    return out
  }
}
