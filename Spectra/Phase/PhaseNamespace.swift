import Foundation

/// Phase space: Wigner distributions of time signals, spatial fields and 1+1-D spacetime fields.
///
/// ## Utkarsh's convention (C)
/// Everything in this module follows **Utkarsh's convention (C)** and his definition of the
/// spacetime Wigner distribution (`Docs/research/wigner-spacetime.md`, from his "Spacetime Wigner
/// Distribution" poster, 2026-10-03). Field notes must credit him.
///
///     ψ̃(k, ν) = ∫ ψ(x, t) e^{−i(k·x − 2πνt)} dx dt
///     ψ(x, t) = ∫ ψ̃(k, ν) e^{+i(k·x − 2πνt)} dν dk/2π
///     Φ(ν, k; x, t) = ∫∫ ψ*(x − ξ/2, t − τ/2) ψ(x + ξ/2, t + τ/2) e^{−i(k·ξ − 2πντ)} dξ dτ
///
/// - k is the **angular** wavenumber (rad/m) with measure dk/2π; ν is the **ordinary** frequency
///   (Hz) with measure dν.
/// - A plane wave e^{i(k₀x − 2πν₀t)} lands at (+k₀, +ν₀). In time alone a positive frequency is
///   e^{−2πiνt} (the physicist's sign); in space a positive wavenumber is e^{+ikx}.
/// - Marginals: (M1) ∫Φ dν dk/2π = |ψ(x,t)|², (M2) ∫Φ dx dt = |ψ̃(k,ν)|², (P) the totals agree.
///   Partial marginals: ∫Φ dν = W(x,k) at fixed t, ∫Φ dk/2π = W(t,ν) at fixed x.
///
/// ## Discrete rules (wigner-spacetime.md, "Implementation rules")
/// 1. *No double counting of lags.* Half-lags m use a lag DFT of length M and are restricted to
///    |m| < M/2 ("lag window ≤ half the padded grid": the full lag 2m spans less than the 2M grid).
///    Samples outside the record are zero, never wrapped.
/// 2. *2× oversampling or the analytic signal.* The half-lag Wigner repeats with **half** the grid
///    period (fs/2 in ν, π/Δx in k). `Band.positive` covers [0, period) for analytic fields;
///    `Band.centered` covers [−period/2, period/2) for 2× oversampled complex fields.
/// 3. *Real signals* go through `Phase.Signal.analytic(real:…)` (FFT Hilbert transform): the
///    Wigner–Ville distribution.
/// 4. Φ fixes ψ only up to a global phase.
/// 5. Exact Wigner, pseudo-Wigner (lag window), smoothed pseudo-Wigner (lag + time window) and the
///    spectrogram are all offered; only the unsmoothed Wigner has exact marginals.
/// 6. Free fields live on their dispersion shell (`Phase.Dispersion`); Fresnel diffraction shears
///    the spatial Wigner (`Phase.fresnelShear`); an aperture's far-field pattern is its k marginal.
///
/// With these rules the discrete marginals are exact identities:
/// - M1: Σ_ν W dν = |z[n]|² to round-off (any lag window with h(0) = 1, no time smoothing);
/// - M2: Σ_t W Δt = |Z(ν)|² + |Z(ν + fs/2)|² to round-off when the lag window covers the record
///   (M ≥ N, full lag) and every sample is a row. The second term is the alias of rule 2; it is
///   negligible for an analytic or 2× oversampled field, and `Phase.Spectrum.aliased` reports it.
/// - P: the totals equal Σ|z|²Δt to round-off.
///
/// Everything is a `nonisolated` `Sendable` value type (the DFT wrapper is an immutable final
/// class), Foundation + Accelerate only, so it runs on the main actor, a detached task or the
/// Patch evaluator. Double precision inside; `Float` only at the display boundary.
nonisolated enum Phase {}

nonisolated extension Phase {
  /// Which variable a 1-D signal is sampled in. It fixes the transform sign of convention (C):
  /// time uses e^{+2πiντ} (ν columns, Hz), space uses e^{−ikξ} (k columns, rad/m).
  enum Domain: String, Sendable, Hashable, Codable, CaseIterable {
    case time
    case space

    /// Sign s of the lag exponent e^{s·i·2π·(column)·(lag)}: +1 for time, −1 for space.
    var exponentSign: Double { self == .time ? 1 : -1 }

    /// Conjugate variable name for labels: "ν" or "k".
    var conjugateSymbol: String { self == .time ? "ν" : "k" }

    /// Converts a column period in "cycles per step" into the axis unit: Hz for time (ν = cycles
    /// per second), rad/m for space (k = 2π × cycles per metre).
    func axisScale(step: Double) -> Double { self == .time ? 1 / step : 2 * Double.pi / step }
  }

  /// Which period of the (periodic) discrete Wigner the columns show. The half-lag Wigner repeats
  /// every fs/2 in ν (π/Δx in k), half the grid period (rule 2).
  enum Band: String, Sendable, Hashable, Codable, CaseIterable {
    /// [0, period): the analytic signal of a real stream, or a positive-frequency field.
    case positive
    /// [−period/2, period/2): a complex field sampled at least 2× above its bandwidth.
    case centered

    /// Signed bin index s (column value = s·step) of column c out of M.
    @inline(__always) func signedIndex(column c: Int, bins m: Int) -> Int {
      self == .positive ? c : c - m / 2
    }

    /// Index into a length-M lag DFT for column c (s mod M).
    @inline(__always) func dftIndex(column c: Int, bins m: Int) -> Int {
      let s = signedIndex(column: c, bins: m)
      return ((s % m) + m) % m
    }

    /// Index into the 2M-point spectrum grid (period 2·Wigner period) for column c (s mod 2M).
    @inline(__always) func spectrumIndex(column c: Int, bins m: Int) -> Int {
      let s = signedIndex(column: c, bins: m)
      return ((s % (2 * m)) + 2 * m) % (2 * m)
    }
  }

  /// A uniform axis: value(i) = start + i·step.
  struct Axis: Sendable, Hashable, Codable {
    var start: Double
    var step: Double
    var count: Int

    init(start: Double, step: Double, count: Int) {
      self.start = start
      self.step = step
      self.count = max(0, count)
    }

    @inline(__always) func value(_ i: Int) -> Double { start + Double(i) * step }
    var values: [Double] { (0..<count).map(value) }
    /// Last sample value (start when empty).
    var end: Double { count > 0 ? value(count - 1) : start }
    /// Fractional index of value v (may be outside 0…count−1).
    func fractionalIndex(_ v: Double) -> Double { step != 0 ? (v - start) / step : 0 }
    /// Nearest index, clamped into the axis (0 for a non-finite value). The clamp happens in
    /// Double, so a value far outside the axis (1e300) cannot trap in the Int conversion.
    func nearestIndex(_ v: Double) -> Int {
      guard count > 0 else { return 0 }
      let i = fractionalIndex(v).rounded()
      guard i.isFinite else { return 0 }
      return Int(min(Double(count - 1), max(0, i)))
    }
    /// Values span [start − step/2, end + step/2] as pixel edges.
    var extent: ClosedRange<Double> {
      let a = start - step / 2
      let b = end + step / 2
      return min(a, b)...max(a, b)
    }
  }

  /// Exact-identity tolerance used by `MarginalReport.status` (relative to the peak value).
  static let identityTolerance = 1e-9
  /// Alias level (relative to the spectral peak) above which a view is flagged ALIASED.
  static let aliasTolerance = 1e-3

  /// Largest lag DFT (columns per Wigner period) any request gets: 2²⁰. Larger `bins` are
  /// clamped (an absurd request must neither trap in `bins + 1` nor allocate without bound).
  static let maxBins = 1 << 20
  /// Largest image a 1-D Wigner or spectrogram allocates, rows × columns (2²⁵ values, 268 MB).
  /// A longer record with `rows: .all` gets evenly spread rows instead (the image and M1 stay
  /// exact; the M2 identity then needs every sample as a row, so `coversRecord` is false).
  static let maxPlaneValues = 1 << 25
  /// Largest lag DFT per axis of the spacetime Φ (2¹²).
  static let maxSpacetimeBins = 1 << 12
  /// Largest 4-D Φ kept as Float by `SpacetimeOptions.keepFull` (2²⁶ values, 268 MB); beyond
  /// that `full` stays nil (use `kSlice`).
  static let maxFullValues = 1 << 26

  /// Even lag-DFT length for a requested bin count: at least 4, at most `cap` (no overflow for
  /// any Int, including negative and `Int.max`).
  static func evenBins(_ requested: Int, cap: Int = maxBins) -> Int {
    let b = min(max(requested, 4), cap)
    return b + (b & 1)
  }

  /// True for a usable sample step (finite and non-zero).
  static func isUsableStep(_ step: Double) -> Bool { step.isFinite && step != 0 }
}
