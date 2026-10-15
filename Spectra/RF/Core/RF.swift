import Foundation

/// The pure RF engine: antennas, propagation, noise, modulation, channels, DSP, the systems
/// catalog and the link budget. Everything here is a value type or an immutable reference type,
/// `Sendable`, `nonisolated`, and imports only Foundation, Accelerate and simd, so it compiles both
/// in the app (default MainActor isolation) and in the plain macOS harness (`Tools/check-rf.sh`).
///
/// Physics comes from `Docs/research/rf-physics.md` with its `[corrected in review]` fixes and the
/// "Verified reference" in `rf-physics-review.md`. Every worked value there is an oracle in
/// `SpectraTests/RFTests.swift`.
nonisolated enum RF {
  /// Antenna formulas and helpers (closed forms; the pattern model lives in `AntennaModel`).
  enum Antennas {}
  /// Uniform linear and planar array factors, steering and grating lobes.
  enum Arrays {}
  /// Path-loss models: free space, log-distance, 3GPP TR 38.901, two-ray, Hata, knife edge.
  enum Propagation {}
  /// ITU-R P.676 gas absorption and P.838 rain attenuation.
  enum Atmosphere {}
  /// Building entry and wall penetration (3GPP TR 38.901 O2I, ITU-R P.2109).
  enum Building {}
  /// Fading statistics, delay spread, coherence bandwidth, Doppler and coherence time.
  enum Fading {}
  /// Thermal noise, noise figure cascades, SNR, Shannon and MIMO capacity.
  enum Noise {}
  /// Bit and symbol error rates for coherent detection in AWGN, and EVM conversions.
  enum ErrorRates {}
  /// Analog AM/FM/PM theory (power, Carson bandwidth, Bessel sidebands).
  enum AnalogTheory {}
  /// Numerology of real systems (NR, LTE, Wi-Fi, GSM, Bluetooth, GNSS, UWB, NFC, broadcast).
  enum Numerology {}
  /// Signal-processing helpers (bin math, aliasing, filters, resampling).
  enum DSP {}
  /// Special functions: Q, erfc inverse, Bessel, sine/cosine integrals, Fresnel integrals.
  enum Special {}
  /// Numerical integration and root finding used by the pattern integrals.
  enum Numerics {}
}

// MARK: - Constants

nonisolated extension RF {
  /// Physical constants (SI, exact where the SI defines them) and RF reference values.
  enum Const {
    /// Speed of light in vacuum, m/s (exact).
    static let c = 299_792_458.0
    /// Boltzmann constant, J/K (exact).
    static let kB = 1.380_649e-23
    /// Planck constant, J·s (exact).
    static let h = 6.626_070_15e-34
    /// Elementary charge, C (exact); converts J to eV.
    static let e = 1.602_176_634e-19
    /// Impedance of free space η₀, Ω (CODATA 2022).
    static let eta0 = 376.730_313_412
    /// The textbook approximation η = 120π Ω (behind "73 Ω", "31 171", "80π²").
    static let eta120pi = 120 * Double.pi
    /// Noise reference temperature T₀, K.
    static let T0 = 290.0
    /// `20·log10(4π/c)`: FSPL constant for d in m and f in Hz (−147.552 2168 dB).
    static let fsplConstantDB = 20 * log10(4 * Double.pi / c)
    /// Thermal noise density kT₀ in dBm/Hz (−173.975 19).
    static let kT0dBmPerHz = 10 * log10(kB * T0 * 1000)
  }
}

// MARK: - Units and decibels

nonisolated extension RF {
  /// Decibel and unit conversions. Power quantities use 10·log10, field quantities 20·log10.
  enum Units {
    /// Power ratio → dB. Returns −∞ for 0.
    static func dB(power ratio: Double) -> Double { 10 * log10(ratio) }
    /// Amplitude (field, voltage) ratio → dB.
    static func dB(amplitude ratio: Double) -> Double { 20 * log10(ratio) }
    /// dB → power ratio.
    static func powerRatio(dB: Double) -> Double { pow(10, dB / 10) }
    /// dB → amplitude ratio.
    static func amplitudeRatio(dB: Double) -> Double { pow(10, dB / 20) }
    /// Watts → dBm.
    static func dBm(watts: Double) -> Double { 10 * log10(watts * 1000) }
    /// dBm → watts.
    static func watts(dBm: Double) -> Double { pow(10, dBm / 10) / 1000 }
    /// Watts → dBW.
    static func dBW(watts: Double) -> Double { 10 * log10(watts) }
    /// Directivity of the thin half-wave dipole, 4/Cin(2π) = 1.640 92 (the dBd reference).
    static let halfWaveDipoleDirectivity = 4 / RF.Special.cin(2 * Double.pi)
    /// dBi − dBd = 10·log10(1.640 92) = 2.1509 dB.
    static let dBdToDBi = 10 * log10(halfWaveDipoleDirectivity)
    /// Converts a gain in dBd to dBi.
    static func dBi(fromDBd dBd: Double) -> Double { dBd + dBdToDBi }

    /// Wavelength λ = c/f in metres.
    static func wavelength(frequency f: Double) -> Double { Const.c / f }
    /// Frequency f = c/λ in hertz.
    static func frequency(wavelength lambda: Double) -> Double { Const.c / lambda }
    /// Wavenumber k = 2π/λ (rad/m).
    static func wavenumber(frequency f: Double) -> Double { 2 * Double.pi * f / Const.c }
    /// Photon energy E = h·f in joules.
    static func photonEnergyJ(frequency f: Double) -> Double { Const.h * f }
    /// Photon energy E = h·f in electronvolts.
    static func photonEnergyEV(frequency f: Double) -> Double { Const.h * f / Const.e }
    /// One-way light (radio) time over a distance, s (GPS orbit 20 200 km → 67.4 ms).
    static func lightTime(distance d: Double) -> Double { d / Const.c }
    /// Degrees → radians.
    static func radians(_ degrees: Double) -> Double { degrees * Double.pi / 180 }
    /// Radians → degrees.
    static func degrees(_ radians: Double) -> Double { radians * 180 / Double.pi }

    /// ITU band designation (ITU-R V.431) for a frequency: ELF, SLF, ULF, VLF, LF, MF, HF,
    /// VHF, UHF, SHF, EHF, THF. Band N runs from 0.3·10ᴺ to 3·10ᴺ Hz, lower limit excluded and
    /// upper limit included (V.431 note), so 3 GHz is UHF and 300 MHz is VHF. Nil outside
    /// (3 Hz, 3 THz].
    static func ituBand(frequency f: Double) -> String? {
      let names = ["ELF", "SLF", "ULF", "VLF", "LF", "MF", "HF", "VHF", "UHF", "SHF", "EHF", "THF"]
      guard f > 3, f <= 3e12 else { return nil }
      let index = Int(ceil(log10(f / 3))) - 1
      return names.indices.contains(index) ? names[index] : nil
    }

    /// "2.45 GHz", "13.56 MHz", "540 kHz", "60 Hz": three significant figures, trailing zeros trimmed.
    static func format(frequency f: Double) -> String {
      engineering(f, units: [(1e12, "THz"), (1e9, "GHz"), (1e6, "MHz"), (1e3, "kHz"), (1, "Hz")])
    }
    /// "20,200 km", "1.5 km", "35 cm", "5.35 mm", "2.1 µm" ("∞ km" for an infinite distance).
    static func format(distance d: Double) -> String {
      if d.isInfinite { return (d < 0 ? "−" : "") + "∞ km" }
      if d >= 1e4 {
        // Grouped digits up to 10¹⁵ km; beyond that three significant figures in light-years.
        if d < 1e18 { return grouped(d / 1000) + " km" }
        return sig3(d / 9.460_730_472_580_8e15) + " ly"
      }
      return engineering(d, units: [(1e3, "km"), (1, "m"), (1e-2, "cm"), (1e-3, "mm"), (1e-6, "µm"), (1e-9, "nm")])
    }
    /// "66.7 µs", "4.69 ns", "1 ms".
    static func format(time t: Double) -> String {
      engineering(t, units: [(1, "s"), (1e-3, "ms"), (1e-6, "µs"), (1e-9, "ns"), (1e-12, "ps")])
    }
    /// "133 Mbit/s", "23.1 Gbit/s", "50 bit/s".
    static func format(bitRate r: Double) -> String {
      engineering(r, units: [(1e9, "Gbit/s"), (1e6, "Mbit/s"), (1e3, "kbit/s"), (1, "bit/s")])
    }
    /// "−40.2 dBm" style with one decimal and a true minus sign.
    static func format(dB value: Double, unit: String = "dB", decimals: Int = 1) -> String {
      guard value.isFinite else { return value < 0 ? "−∞ \(unit)" : "∞ \(unit)" }
      let s = String(format: "%.\(decimals)f", abs(value))
      return (value < 0 ? "−" : "") + s + " " + unit
    }

    private static func engineering(_ value: Double, units: [(Double, String)]) -> String {
      if value.isNaN { return "—" }
      if value.isInfinite { return (value < 0 ? "−" : "") + "∞ " + (units.first?.1 ?? "") }
      guard value != 0 else { return "0 " + (units.last?.1 ?? "") }
      let magnitude = abs(value)
      let (scale, unit) = units.first { magnitude >= $0.0 * 0.9995 } ?? units.last!
      return sig3(value / scale) + " " + unit
    }

    /// Three significant figures with trailing zeros removed ("2.45", "13.6", "540").
    static func sig3(_ x: Double) -> String {
      let a = abs(x)
      let decimals = a >= 100 ? 0 : (a >= 10 ? 1 : 2)
      var s = String(format: "%.\(decimals)f", a)
      if s.contains(".") {
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
      }
      return (x < 0 ? "−" : "") + s
    }

    private static func grouped(_ x: Double) -> String {
      let n = Int(x.rounded())
      var digits = String(abs(n))
      var out = ""
      while digits.count > 3 {
        out = "," + String(digits.suffix(3)) + out
        digits.removeLast(3)
      }
      return (n < 0 ? "−" : "") + digits + out
    }
  }
}

// MARK: - Complex numbers

nonisolated extension RF {
  /// A double-precision complex number for formulas (impedances, phasors, Jones vectors).
  /// Sample buffers use split Float arrays instead (see `IQBuffer`).
  struct Complex: Hashable, Codable, Sendable, CustomStringConvertible {
    var re: Double
    var im: Double

    init(_ re: Double, _ im: Double = 0) {
      self.re = re
      self.im = im
    }

    static let zero = Complex(0, 0)
    static let one = Complex(1, 0)
    static let j = Complex(0, 1)

    /// e^{jθ}.
    static func expj(_ theta: Double) -> Complex { Complex(cos(theta), sin(theta)) }
    /// r·e^{jθ}.
    static func polar(_ r: Double, _ theta: Double) -> Complex { Complex(r * cos(theta), r * sin(theta)) }

    var magnitude: Double { hypot(re, im) }
    var magnitudeSquared: Double { re * re + im * im }
    var phase: Double { atan2(im, re) }
    var conjugate: Complex { Complex(re, -im) }

    static func + (a: Complex, b: Complex) -> Complex { Complex(a.re + b.re, a.im + b.im) }
    static func - (a: Complex, b: Complex) -> Complex { Complex(a.re - b.re, a.im - b.im) }
    static prefix func - (a: Complex) -> Complex { Complex(-a.re, -a.im) }
    static func * (a: Complex, b: Complex) -> Complex {
      Complex(a.re * b.re - a.im * b.im, a.re * b.im + a.im * b.re)
    }
    static func * (a: Complex, s: Double) -> Complex { Complex(a.re * s, a.im * s) }
    static func * (s: Double, a: Complex) -> Complex { Complex(a.re * s, a.im * s) }
    static func / (a: Complex, s: Double) -> Complex { Complex(a.re / s, a.im / s) }
    static func / (a: Complex, b: Complex) -> Complex {
      let d = b.re * b.re + b.im * b.im
      return Complex((a.re * b.re + a.im * b.im) / d, (a.im * b.re - a.re * b.im) / d)
    }
    static func += (a: inout Complex, b: Complex) { a = a + b }
    static func -= (a: inout Complex, b: Complex) { a = a - b }
    static func *= (a: inout Complex, b: Complex) { a = a * b }

    var description: String {
      im >= 0 ? String(format: "%.6g + j%.6g", re, im) : String(format: "%.6g − j%.6g", re, -im)
    }
  }
}
