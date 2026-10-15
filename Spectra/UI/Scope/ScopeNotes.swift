import Foundation
import SwiftUI

/// Readout text for scope values in each stream's own unit ("12.4 µT", "3.2 mg", "101.3 kPa").
nonisolated enum ScopeFormat {
  /// Units that take SI prefixes; the others already carry one (µT, dBm, ms…) or are counts.
  private static let prefixable: Set<String> = ["Pa", "m", "s", "Hz", "V", "m/s", "rad/s"]

  static func value(_ v: Double?, unit: String, digits: Int = 3) -> String {
    guard let v, v.isFinite else { return "—" }
    // A unit with a note ("V (norm.)") is formatted by its base unit, note kept: "−5.42 µV
    // (norm.)" rather than "−0.00000542 V (norm.)".
    if let open = unit.range(of: " ("), open.lowerBound > unit.startIndex {
      return value(v, unit: String(unit[..<open.lowerBound]), digits: digits) + unit[open.lowerBound...]
    }
    if unit == "g" {
      return abs(v) < 0.1 ? "\(SpectraFormat.significant(v * 1000, digits)) mg" : "\(SpectraFormat.significant(v, digits)) g"
    }
    if prefixable.contains(unit) { return SpectraFormat.si(v, unit: unit, digits: digits) }
    if unit.isEmpty { return SpectraFormat.significant(v, digits) }
    if unit.hasPrefix("dB") { return SpectraFormat.decibels(v, unit: unit, decimals: abs(v) < 10 ? 2 : 1) }
    return "\(SpectraFormat.significant(v, digits)) \(unit)"
  }

  /// "50 ms/div".
  static func timebase(_ seconds: Double) -> String { SpectraFormat.si(seconds, unit: "s") + "/div" }

  /// "1 µT/div"; a unit with a note keeps the note after "/div" ("0.5 V/div (norm.)"); a
  /// division of a decibel level is a difference, so dBm and dBFS channels read "dB/div".
  static func scale(_ unitsPerDiv: Double, unit: String) -> String {
    if let open = unit.range(of: " (") {
      let base = String(unit[..<open.lowerBound])
      return value(unitsPerDiv, unit: base) + "/div" + unit[open.lowerBound...]
    }
    if ScopeEngine.isLogarithmic(unit) { return "\(SpectraFormat.significant(unitsPerDiv, 3)) dB/div" }
    return value(unitsPerDiv, unit: unit) + "/div"
  }

  static func time(_ seconds: Double?) -> String {
    guard let seconds, seconds.isFinite else { return "—" }
    return SpectraFormat.si(seconds, unit: "s")
  }

  static func frequency(_ hertz: Double?) -> String {
    guard let hertz, hertz.isFinite, hertz > 0 else { return "—" }
    return SpectraFormat.frequency(hertz, digits: 4)
  }

  static func persistence(_ tau: Double) -> String {
    if tau <= 0 { return "Off" }
    if tau >= ScopeSettings.infinitePersistence { return "∞" }
    return SpectraFormat.si(tau, unit: "s")
  }
}

/// Field notes for the Scope (the Live tab may also include these sections in its own notes).
enum ScopeNotes {
  static let notes = FieldNotes(
    title: "Scope",
    intro:
      "One oscilloscope for every signal in Spectra: the iPhone's sensors, its radios' signal strength, the microphone, and the simulated spins and radios. Every channel keeps its sensor's own timestamps and shows its measured sample rate.",
    sections: [
      FieldNoteSection(
        number: "01", title: "What you are looking at",
        paragraphs: [
          "The display is a phosphor screen: each sweep is written into a persistence buffer that fades with the time you set on the **Persist** knob, so a steady signal stays bright and a wandering one leaves a glow. Off shows only the latest sweep; ∞ keeps everything.",
          "**YT** sweeps start on the trigger, with the trigger instant on the center line. **Roll** scrolls the newest samples in from the right, like a seismograph; it takes over at 0.5 s per division. **XY** plots one channel against another, paired sample by sample by their timestamps. **FFT** is the Hann-windowed spectrum of the visible window in dB of the stream's own unit.",
          "Streams that arrive irregularly, such as Bluetooth advertisements, are drawn sample-and-hold with a dashed line: the value is only known when a packet arrives.",
        ],
        items: [
          FieldNoteItem(.live, "Sensor channels", "Measured on this iPhone when the badge says LIVE."),
          FieldNoteItem(.sim, "Simulated channels", "Realistic data at the real rate when a sensor is not available (the Simulator)."),
          FieldNoteItem(.model, "Spin FID and Radio I/Q", "Computed by the Spin and RF engines; the FID follows your live magnetic field."),
          FieldNoteItem(.analogy, "Sound", "The microphone measures air pressure, not light: an analogy for the waves elsewhere in the app."),
        ]),
      FieldNoteSection(
        number: "02", title: "Rates and honesty",
        paragraphs: [
          "The timebase stops at one sample per division of the fastest channel: the microphone (48 kHz) reaches 50 µs per division, motion and the magnetometer (about 100 Hz) 10 to 20 ms, Bluetooth 100 ms and slower. The switch itself goes down to 10 µs for streams fast enough to use it.",
          "A sensor sampled at f_s cannot show anything above f_s/2. The magnetometer samples at about 100 Hz, so 60 Hz mains hum appears near 40 Hz, while 50 Hz hum sits right at the 50 Hz limit, where its size depends on the sampling phase and it drifts as a slow beat; the **ALIASED** chip names the local mains source and where it lands.",
          "The phone has no broadband RF power meter. Bluetooth RSSI is one device's received strength at 2.4 GHz, and the magnetometer sees fields from DC to about 50 Hz only.",
        ],
        sources: [
          FieldNoteSource("C. E. Shannon, Communication in the presence of noise (Proc. IRE, 1949): the sampling theorem", "https://doi.org/10.1109/JRPROC.1949.232969"),
          FieldNoteSource("Apple, CMDeviceMotion: gravity and user acceleration", "https://developer.apple.com/documentation/coremotion/cmdevicemotion"),
        ]),
      FieldNoteSection(
        number: "03", title: "Coupling, trigger and math",
        paragraphs: [
          "**DC** shows the signal as measured. **AC** removes the steady part with a one-pole high-pass at f_s/50 (0.05 to 10 Hz; 2 Hz on the 100 Hz sensors, above the sway of a hand-held phone). **No gravity** subtracts the device-motion gravity on that axis when it is published, or high-passes at 0.25 Hz. **No Earth field** high-passes at 0.01 Hz, so the steady 25 to 65 µT goes while hum and a passing magnet stay.",
          "The trigger finds edges through the level with a hysteresis of 0.1 division, so noise riding on an edge cannot re-trigger, and waits for the holdoff after each sweep. Auto free-runs when no edge comes; Normal waits; Single captures one sweep and stops.",
          "Frequency is measured two ways: from the interpolated times of rising mean crossings, and from the strongest FFT line (Hann window, 4× zero padding, parabolic peak). They agree on a clean tone and disagree on a messy one, which is itself information.",
          "Math works on channel A's timestamps, with B and C paired to them by time: A + B, A − B, A · B, |vector| (√(A² + B² + C²)), d/dt, ∫ dt (trapezoidal) and a high-pass.",
        ]),
      FieldNoteSection(
        number: "04", title: "Time–frequency views",
        paragraphs: [
          "**Spectrogram** is short-time Fourier power. **Wigner–Ville** is the Wigner distribution of the analytic signal: chirps and lines are sharp, and two components make a signed cross term midway between them (blue is negative). **Pseudo-Wigner** applies a Hann lag window to weaken the cross terms at some cost in sharpness.",
          "The strips on the edges are the marginals. For Wigner–Ville and pseudo-Wigner the time strip equals |x(t)|² to rounding error; the frequency strip equals |X(ν)|² for Wigner–Ville and is smoothed for the pseudo-Wigner. The errors are printed under the picture.",
          "Spacetime Wigner distribution: Utkarsh's construction and convention (C). Spectra's Phase engine computes these views in his convention; for a stream in time it reduces to the familiar Wigner–Ville distribution.",
        ],
        items: [
          FieldNoteItem(.model, "Wigner image of a live stream", "The transform is exact, but the picture is a computed quasi-distribution: MODEL · LIVE.")
        ],
        sources: [
          FieldNoteSource("L. Cohen, Time-frequency distributions: a review (Proc. IEEE, 1989)", "https://doi.org/10.1109/5.30749"),
          FieldNoteSource("R. L. Hudson, When is the Wigner quasi-probability density non-negative? (1974)", "https://doi.org/10.1016/0034-4877(74)90007-X"),
        ]),
      FieldNoteSection(
        number: "05", title: "Probes",
        paragraphs: [
          "Each probe picks its streams by meaning (the magnetometer's X axis, the three strongest Bluetooth radios) rather than by a fixed name, starts the sensors it needs while the scope is on screen, and sets mode, timebase, coupling and trigger. Sensors that ask for permission start on your tap."
        ],
        items: [
          FieldNoteItem(.model, "Light flicker", "Experimental: the mean of each rolling-shutter row is a light sample a few kHz apart; the row time is a model until it is validated on the device."),
          FieldNoteItem(.live, "Bluetooth / EMF", "RSSI per device plus |B|, both measured; neither is a broadband RF power meter."),
        ]),
    ])
}
