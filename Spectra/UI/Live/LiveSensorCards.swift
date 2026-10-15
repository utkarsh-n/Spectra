import SwiftUI

// MARK: - 05 Magnetometer (ELF)

/// The magnetometer as an ELF probe: |B| and its direction, dip angle → magnetic latitude
/// (Spin engine), the measured sample rate, an FFT of the raw axes, and the aliasing
/// explainer (60 Hz folds to ~40 Hz at ~100 Hz).
struct MagnetometerCard: View {
  @Environment(AppModel.self) private var app

  var body: some View {
    let mag = app.live.magnetometer
    let prefs = app.live.settings.prefs
    let earth = mag.earthField
    let fs = mag.measuredRate
    let virtual = prefs.virtualRate ?? fs ?? 100
    // Water protons in the measured field (Spin engine: γ′ₚ·|B|), the line Spin plays.
    let larmor = mag.field.map { SpinSpecies.protonWater.larmorHz(field: ($0 * $0).sum().squareRoot() * 1e-6) }
    LiveCard(
      .magnetometer, badges: [.inferred],
      actions: LiveCardActions(
        marker: mag.markers.first ?? SpectrumMarker(id: "live.mains", label: "Mains \(Int(prefs.mains)) Hz", frequency: prefs.mains, provenance: .table, tab: .live),
        scope: LiveStreams.mag.map(\.id) + [LiveStreams.magNorm.id], preset: "Magnetic scope",
        patch: (LiveStreams.magNorm.id, "Magnetic field |B|"))
    ) {
      AdaptiveStack {
        PlotWell(height: 150, grid: 0) {
          FieldArrow(field: mag.field, gravity: mag.gravity)
        }
        .sideWidth(140)
        VStack(alignment: .leading, spacing: 10) {
          Readout("|B|", value: liveValue(mag.field.map { ($0 * $0).sum().squareRoot() }, 3, unit: "µT"), color: Theme.fieldB, provenance: mag.provenance)
          Readout("Dip angle", value: earth.map { "\(SpectraFormat.significant($0.dipAngle * 180 / .pi, 3))°" } ?? "—", provenance: mag.provenance)
          Readout("Magnetic lat.", value: earth.map { "\(SpectraFormat.significant($0.magneticLatitude * 180 / .pi, 3))°" } ?? "—", provenance: .inferred)
        }
      }
      // Two columns: the badge-carrying titles do not fit three across a phone.
      ReadoutGrid(columns: 2) {
        Readout("Sample rate", value: liveRate(fs), provenance: mag.provenance)
        Readout("Calibration", value: mag.isSimulated ? "SIM" : (mag.isCalibrated ? ["low", "medium", "high"][max(0, min(2, mag.accuracy))] : "raw"), provenance: mag.provenance)
        Readout("Dipole |B|", value: earth.map { "\(SpectraFormat.significant($0.dipoleMagnitude * 1e6, 3)) µT" } ?? "—", provenance: .model)
        Readout("Larmor ¹H", value: larmor.map { SpectraFormat.frequency($0, digits: 3) } ?? "—", provenance: mag.provenance)
      }
      if let s = mag.spectrum {
        PlotWell(height: 150, grid: 0) {
          SpectrumPlot(
            bins: s.bins, binWidth: s.binWidth, frequencyRange: 1...s.nyquist, dbRange: -50...20,
            color: BandPalette.color(forFrequency: prefs.mains), showsPeak: true,
            markers: LiveAnalysis.mainsLines(mains: prefs.mains, sampleRate: s.sampleRate).map {
              FrequencyMarker(frequency: $0.alias, label: "\(Int($0.frequency)) Hz", color: Theme.amber)
            }, unit: "dBµT", accessibilityLabel: "Magnetometer spectrum")
            .padding(.horizontal, 4)
        }
        Text(
          mag.detectedMains.map {
            "A line at \(SpectraFormat.significant(RF.DSP.aliasFrequency($0, sampleRate: s.sampleRate), 3)) Hz: that is \(Int($0)) Hz mains, folded by sampling at \(SpectraFormat.significant(s.sampleRate, 3)) Hz."
          } ?? "No mains line stands out. Hold the phone a few centimeters from a power brick or a lamp cord to see it."
        )
        .panelCaption()
      }
      HStack(spacing: 8) {
        Text("FFT").font(.caption).foregroundStyle(Theme.muted)
        ChoiceChips(items: FFTWindow.allCases, selection: windowBinding, id: "live-mag-fft") { w in
          ChipLabel(title: "\(w.rawValue)")
        }
      }
      .padding(.trailing, -Theme.panelPadding)
      // Follows the mains chips and the rate the diagram shows (60 Hz → 39.8 Hz at 99.8 Hz).
      Eyebrow(
        "Why \(Int(prefs.mains)) Hz shows up at \(SpectraFormat.significant(RF.DSP.aliasFrequency(prefs.mains, sampleRate: virtual), 3)) Hz",
        color: Theme.amber)
      PlotWell(height: 96, grid: 0) {
        FoldingDiagram(mains: prefs.mains, sampleRate: virtual)
      }
      HStack(spacing: 8) {
        ChoiceChips(items: MainsChoice.allCases, selection: mainsBinding, id: "live-mag-mains") { ChipLabel(title: $0.title) }
          .padding(.leading, -Theme.gutter)
        if prefs.virtualRate != nil {
          ActionButton("Measured", symbol: "arrow.uturn.backward") { app.live.settings.prefs.virtualRate = nil }
            .accessibilityIdentifier("live-mag-virtual-reset")
        }
      }
      GlassSlider(
        title: "Sample rate (virtual)", value: virtualBinding(default: fs ?? 100), range: 20...200, step: 0.1, color: Theme.amber,
        format: { SpectraFormat.rate($0) })
        .accessibilityIdentifier("live-mag-virtual-rate")
      Text(
        "A sampled signal cannot show anything faster than half its sample rate (Nyquist). Faster tones fold back: f appears at |f − fs·round(f/fs)|. Scrub the rate to watch \(Int(prefs.mains)) Hz and its harmonic move."
      )
      .panelCaption()
      ActionButton("Hear Earth-field NMR", symbol: "waveform", prominent: true) {
        // Hand-off to Spin through a focused marker (`live.nmr`), like Radio's `live.system.<id>`.
        let f = larmor ?? SpinSpecies.protonWater.larmorHz(field: 50e-6)
        app.focus(
          SpectrumMarker(
            id: "live.nmr", label: "Proton precession in your |B| · \(SpectraFormat.frequency(f, digits: 3))", frequency: f,
            provenance: larmor == nil ? .model : mag.provenance, tab: .spin))
        app.showToast("Spin: protons precess at \(SpectraFormat.frequency(f, digits: 3)) in this field", symbol: "gyroscope")
      }
      .accessibilityHint("Opens the Spin tab, where water protons precess in the field the magnetometer reads.")
      .accessibilityIdentifier("live-mag-nmr")
      Text("Water protons precess in this field at f = γ′ₚ·|B| (42.576 MHz/T): about 2 kHz in Earth's field, a radio line low enough to hear in Spin.")
        .panelCaption()
    }
  }

  enum FFTWindow: Int, CaseIterable, Identifiable {
    case n256 = 256, n512 = 512, n1024 = 1024
    var id: Int { rawValue }
  }

  enum MainsChoice: Double, CaseIterable, Identifiable {
    case hz50 = 50, hz60 = 60
    var id: Int { Int(rawValue) }
    var title: String { "\(Int(rawValue)) Hz mains" }
  }

  private var windowBinding: Binding<FFTWindow> {
    Binding(
      get: { FFTWindow(rawValue: app.live.settings.prefs.magnetometerFFT) ?? .n512 },
      set: {
        app.live.settings.prefs.magnetometerFFT = $0.rawValue
        app.live.preferencesChanged()
      })
  }

  private var mainsBinding: Binding<MainsChoice> {
    Binding(get: { MainsChoice(rawValue: app.live.settings.prefs.mains) ?? .hz60 }, set: { app.live.settings.prefs.mains = $0.rawValue })
  }

  private func virtualBinding(default d: Double) -> Binding<Double> {
    Binding(get: { app.live.settings.prefs.virtualRate ?? min(200, max(20, d)) }, set: { app.live.settings.prefs.virtualRate = $0 })
  }
}

/// The field seen from above the screen: the in-plane component as an arrow (B colour), the
/// out-of-plane component as a bar.
private struct FieldArrow: View {
  let field: SIMD3<Double>?
  let gravity: SIMD3<Double>?

  var body: some View {
    Canvas { ctx, size in
      let c = CGPoint(x: size.width / 2 - 8, y: size.height / 2)
      let phone = CGRect(x: c.x - 22, y: c.y - 44, width: 44, height: 88)
      ctx.stroke(Path(roundedRect: phone, cornerRadius: 9), with: .color(Theme.dim.opacity(0.7)), lineWidth: 1)
      guard let b = field else { return }
      let norm = (b * b).sum().squareRoot()
      guard norm > 0 else { return }
      let scale = 50 / max(norm, 1)
      let tip = CGPoint(x: c.x + CGFloat(b.x * scale), y: c.y - CGFloat(b.y * scale))
      var arrow = Path()
      arrow.move(to: c)
      arrow.addLine(to: tip)
      ctx.phosphorStroke(arrow, color: Theme.fieldB, width: 2.2, glow: 1.2)
      ctx.phosphorDot(at: tip, color: Theme.fieldB, radius: 3)
      // Out-of-screen component.
      let barX = size.width - 14
      let zf = CGFloat(b.z / max(norm, 1))
      var bar = Path()
      bar.move(to: CGPoint(x: barX, y: c.y))
      bar.addLine(to: CGPoint(x: barX, y: c.y - zf * 50))
      ctx.phosphorStroke(bar, color: Theme.fieldB.opacity(0.8), width: 3, glow: 0.8)
      ctx.annotation("z", at: CGPoint(x: barX, y: c.y + 58))
      ctx.annotation("B in the screen plane", at: CGPoint(x: size.width / 2, y: size.height - 8))
    }
    .accessibilityElement()
    .accessibilityLabel("Magnetic field direction")
    .accessibilityValue(field.map { "x \(liveWhole($0.x)), y \(liveWhole($0.y)), z \(liveWhole($0.z)) microtesla" } ?? "No reading")
  }
}

/// The folding diagram: the frequency axis from 0 past fs, the band the sensor can show
/// (0…fs/2), and each mains line reflected to where the samples put it.
struct FoldingDiagram: View {
  let mains: Double
  let sampleRate: Double

  var body: some View {
    Canvas { ctx, size in
      let lines = LiveAnalysis.mainsLines(mains: mains, sampleRate: sampleRate)
      let fMax = max(lines.map(\.frequency).max() ?? mains, sampleRate) * 1.08
      let rect = CGRect(x: 10, y: 18, width: size.width - 20, height: size.height - 34)
      func x(_ f: Double) -> CGFloat { rect.minX + rect.width * CGFloat(f / fMax) }
      let nyquist = sampleRate / 2
      ctx.fill(Path(CGRect(x: rect.minX, y: rect.minY, width: x(nyquist) - rect.minX, height: rect.height)), with: .color(Theme.phosphor.opacity(0.07)))
      var axis = Path()
      axis.move(to: CGPoint(x: rect.minX, y: rect.maxY))
      axis.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
      ctx.stroke(axis, with: .color(Theme.axis), lineWidth: 1)
      for (f, label) in [(nyquist, "fs/2 \(SpectraFormat.significant(nyquist, 3))"), (sampleRate, "fs \(SpectraFormat.significant(sampleRate, 3))")] {
        var p = Path()
        p.move(to: CGPoint(x: x(f), y: rect.minY))
        p.addLine(to: CGPoint(x: x(f), y: rect.maxY))
        ctx.stroke(p, with: .color(Theme.muted.opacity(0.6)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
        ctx.annotation(label, at: CGPoint(x: x(f), y: rect.maxY + 8))
      }
      for line in lines {
        let top = rect.minY + rect.height * (line.harmonic == 1 ? 0.15 : 0.45)
        let tx = x(line.frequency)
        let ax = x(line.alias)
        var t = Path()
        t.move(to: CGPoint(x: tx, y: rect.maxY))
        t.addLine(to: CGPoint(x: tx, y: top))
        ctx.phosphorStroke(t, color: Theme.fieldB, width: 1.5, glow: 0.7)
        ctx.annotation("\(Int(line.frequency))", at: CGPoint(x: tx, y: top - 7), color: Theme.fieldB)
        var a = Path()
        a.move(to: CGPoint(x: ax, y: rect.maxY))
        a.addLine(to: CGPoint(x: ax, y: top))
        ctx.phosphorStroke(a, color: Theme.amber, width: 1.5, glow: 0.9)
        if line.isFolded {
          var arc = Path()
          arc.move(to: CGPoint(x: tx, y: top))
          arc.addQuadCurve(to: CGPoint(x: ax, y: top), control: CGPoint(x: (tx + ax) / 2, y: top - 14))
          ctx.stroke(arc, with: .color(Theme.amber.opacity(0.7)), style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
        }
        // A line folded next to DC (100 Hz at 99.9 Hz lands at 0.08 Hz) keeps its label inside
        // the well instead of centring it on the edge.
        // A line that barely folds (50 Hz at 99.8 Hz lands at 49.8 Hz) sits on its true line,
        // so its label moves beside the line instead of being struck through by it.
        let label = SpectraFormat.significant(line.alias, line.alias < 1 ? 1 : 3)
        let besideTrue = abs(tx - ax) < 16
        let edge: UnitPoint =
          ax < rect.minX + 24 ? .leading : (ax > rect.maxX - 24 || besideTrue ? .trailing : .center)
        let dx: CGFloat = edge == .leading ? 3 : (edge == .trailing ? -4 : 0)
        ctx.annotation(label, at: CGPoint(x: ax + dx, y: top + 9), anchor: edge, color: Theme.amber)
      }
    }
    .accessibilityElement()
    .accessibilityLabel("Aliasing diagram")
    .accessibilityValue(
      LiveAnalysis.mainsLines(mains: mains, sampleRate: sampleRate)
        .map { "\(Int($0.frequency)) hertz appears at \(SpectraFormat.significant($0.alias, 3)) hertz" }.joined(separator: ", "))
  }
}

// MARK: - 06 Microphone (ANALOGY)

struct MicrophoneCard: View {
  @Environment(AppModel.self) private var app
  @Environment(LivePageModel.self) private var page

  var body: some View {
    let mic = app.live.microphone
    let audio = page.audio
    let visible = page.isVisible(.microphone) && mic.state.isRunning
    LiveCard(
      .microphone, badges: [.analogy], startTitle: "Listen",
      explanation: "Spectra turns sound into a live Fourier spectrum. Audio stays on this phone and is never recorded.",
      actions: LiveCardActions(
        marker: mic.markers.first, scope: [LiveStreams.micLeft.id], preset: "Sound", patch: (LiveStreams.micLeft.id, "Microphone"))
    ) {
      ReadoutGrid(columns: 3) {
        Readout("Level", value: mic.level.map { SpectraFormat.decibels($0, unit: "dBFS") } ?? "—", color: Theme.analogy, provenance: mic.provenance)
        Readout("Loudest", value: mic.loudestHz.map { SpectraFormat.frequency($0, digits: 3) } ?? "—", color: Theme.analogy, provenance: mic.provenance)
        Readout("Sample rate", value: liveRate(mic.measuredRate), color: Theme.analogy, provenance: mic.provenance)
      }
      PlotWell(height: 140, grid: 0) {
        SpectrumPlot(
          bins: audio.bins, binWidth: audio.sampleRate / Double(AudioSpectrumModel.count), frequencyRange: AudioSpectrumModel.range,
          // The top of the range is not a tick, so no label is clipped at the well's edge; the
          // peak is the channel's interpolated loudest frequency (the same number as above).
          logFrequency: true, dbRange: -115...(-5), color: Theme.analogy, showsPeak: false,
          markers: mic.loudestHz.map { [FrequencyMarker(frequency: $0, label: SpectraFormat.frequency($0, digits: 3), color: Theme.amber)] } ?? [],
          unit: "dBFS", accessibilityLabel: "Sound spectrum")
          .padding(.horizontal, 4)
      }
      PlotWell(height: 90, grid: 0) {
        LiveWaterfall(buffer: audio.waterfall)
      }
      Text(
        "This is sound, not light: a pressure wave in air at about 343 m/s. Spectra puts it on the strip at λ = c/f only as an analogy (ANALOGY). Sampled at \(liveRate(mic.measuredRate)), analyzed with a 4096-point Hann FFT."
      )
      .panelCaption()
    }
    .task(id: visible && app.clock.playing) {
      guard visible, app.clock.playing else { return }
      while !Task.isCancelled {
        audio.update(app.streams.stream(LiveStreams.micLeft.id))
        try? await Task.sleep(for: .milliseconds(66))
      }
    }
    // A new run starts a new spectrogram, not one spliced onto the last run's rows.
    .onChange(of: mic.state.isRunning) { _, running in
      if !running { audio.clear() }
    }
  }
}

/// The spectrogram image drawn as an `Image` of the buffer's newest `CGImage`, so every push
/// shows (a `Canvas` that only captures the buffer reference may keep its first drawing).
private struct LiveWaterfall: View {
  let buffer: WaterfallBuffer

  var body: some View {
    let _ = buffer.revision
    Group {
      if let image = buffer.image {
        Image(decorative: image, scale: 1)
          .resizable()
          .interpolation(.medium)
      } else {
        Color.clear
      }
    }
    .accessibilityElement()
    .accessibilityLabel("Sound spectrogram")
    .accessibilityValue("Time runs downward, newest at the top; frequency across, log scale.")
  }
}

// MARK: - 07 Light meter

struct LightCard: View {
  @Environment(AppModel.self) private var app

  var body: some View {
    let light = app.live.light
    let prefs = app.live.settings.prefs
    let r = light.reading
    LiveCard(
      .light, badges: [.model], startTitle: "Use the camera",
      explanation: "Spectra reads the camera's exposure to estimate light level and color temperature. Frames are never recorded or saved.",
      actions: LiveCardActions(
        marker: light.markers.first, scope: [LiveStreams.flicker.id, LiveStreams.lux.id], preset: "Light flicker",
        patch: (LiveStreams.lux.id, "Illuminance"))
    ) {
      ReadoutGrid(columns: 3) {
        Readout("Illuminance", value: light.lux.map { "≈\(SpectraFormat.significant($0, 2)) lux" } ?? "—", provenance: .model)
        Readout("EV₁₀₀", value: liveValue(light.ev, 3), provenance: light.provenance)
        Readout("Color temp.", value: light.kelvin.map { "\(Int(($0 / 10).rounded() * 10)) K" } ?? "—", provenance: light.provenance)
        Readout("ISO", value: r.iso.map { "\(Int($0.rounded()))" } ?? "—", provenance: light.provenance)
        Readout("Shutter", value: r.exposure.map { $0 > 0 ? "1/\(Int((1 / $0).rounded())) s" : "—" } ?? "—", provenance: light.provenance)
        Readout("Aperture", value: r.aperture.map { "f/\(SpectraFormat.significant($0, 3))" } ?? "—", provenance: light.provenance)
      }
      if let lux = light.lux {
        Text(LightMeter.describe(lux: lux)).font(.caption.weight(.semibold)).foregroundStyle(Theme.text)
      }
      if let k = light.kelvin {
        let peak = LightMeter.wienPeak(kelvin: k)
        HStack {
          FactRow(title: "Blackbody peak (Wien)", value: SpectraFormat.wavelength(peak), provenance: .inferred)
          ActionButton("Tune", symbol: "sun.max") {
            app.sendToSpectrum(lambda: peak, label: "Lamp ≈ \(Int((k / 100).rounded() * 100)) K blackbody peak")
          }
          .accessibilityLabel("Tune the Spectrum to this blackbody")
          .accessibilityIdentifier("live-light-tune")
        }
      }
      HStack(spacing: 8) {
        ChoiceChips(items: CameraSide.allCases, selection: sideBinding, id: "live-light-camera") { ChipLabel(title: $0.title, symbol: $0.symbol) }
          .padding(.leading, -Theme.gutter)
      }
      GlassToggle(
        "Flicker probe (experimental)", isOn: flickerBinding, symbol: "lightbulb.max",
        subtitle: "Locks a 1/4000 s exposure so mains flicker shows as bands across the frame.")
        .accessibilityIdentifier("live-light-flicker")
      if let s = light.flickerSpectrum {
        PlotWell(height: 120, grid: 0) {
          SpectrumPlot(
            bins: s.bins, binWidth: s.binWidth, frequencyRange: 20...min(400, s.nyquist), dbRange: -90...(-10),
            // Only a real flicker line gets a peak label; without one it would name a noise spike.
            color: BandPalette.color(forWavelength: 580e-9), showsPeak: light.flickerLine != nil,
            markers: [FrequencyMarker(frequency: 100, label: "", color: Theme.amber), FrequencyMarker(frequency: 120, label: "", color: Theme.amber)],
            accessibilityLabel: "Row-signal spectrum")
            .padding(.horizontal, 4)
        }
        Text(
          (light.flickerLine.map { "A flicker line near \(Int($0.rounded())) Hz: twice the mains frequency, the lamp dimming on every half cycle. " }
            ?? (prefs.flickerProbe ? "No flicker line stands out: this light may be steady (daylight, a good LED driver). " : "Auto exposure averages whole flicker periods, so lamp flicker hardly shows: switch the probe on. "))
            + "Row means of a rolling-shutter frame sample the light at about \(liveRate(s.sampleRate)) (rows × frame rate, MODEL: the readout time is not published, so the axis is approximate)."
        )
        .panelCaption()
      }
      Text("Lux is estimated from EV₁₀₀ with the incident-meter constant C = 250 (±30–50 %). Color temperature is the camera's white balance.")
        .panelCaption()
    }
    .onChange(of: prefs.frontCamera) { app.live.preferencesChanged() }
    .onChange(of: prefs.flickerProbe) { app.live.preferencesChanged() }
  }

  enum CameraSide: String, CaseIterable, Identifiable {
    case back, front
    var id: String { rawValue }
    var title: String { self == .back ? "Back camera" : "Front camera" }
    var symbol: String { self == .back ? "camera" : "person.crop.circle" }
  }

  private var sideBinding: Binding<CameraSide> {
    Binding(get: { app.live.settings.prefs.frontCamera ? .front : .back }, set: { app.live.settings.prefs.frontCamera = $0 == .front })
  }

  private var flickerBinding: Binding<Bool> {
    Binding(get: { app.live.settings.prefs.flickerProbe }, set: { app.live.settings.prefs.flickerProbe = $0 })
  }
}

// MARK: - 08 Air

/// Barometer → radio refractivity, effective Earth radius, radio horizon, GNSS zenith delay
/// and 60 GHz oxygen absorption (engines: Spin `AirHere`, RF `Atmosphere`).
struct AirCard: View {
  @Environment(AppModel.self) private var app

  var body: some View {
    let baro = app.live.barometer
    let loc = app.live.location
    let prefs = app.live.settings.prefs
    let hPa = (baro.pressure ?? 101_325) / 100
    let height = prefs.antennaHeight + (baro.relativeAltitude ?? 0)
    let latitude = loc.latitude ?? 45
    let air = AirAnalysis.evaluate(
      pressureHPa: hPa, tempC: prefs.airTemperature, humidity: prefs.airHumidity, gradient: prefs.refractivityGradient,
      height: max(0, height), latitudeDegrees: latitude, ellipsoidalHeight: loc.ellipsoidalAltitude ?? 0)
    let p: Provenance = baro.pressure == nil ? .model : baro.provenance
    LiveCard(
      .air, badges: [.model], startTitle: "Read the barometer",
      explanation: "Spectra reads the barometer to show air pressure and how the air bends radio waves.",
      actions: LiveCardActions(
        // The radio line the air card is about: the 60 GHz oxygen absorption band (TABLE).
        marker: SpectrumMarker(id: "live.o2", label: "O₂ absorption 60 GHz", frequency: 60e9, provenance: .table, tab: .live),
        scope: [LiveStreams.pressure.id, LiveStreams.relativeAltitude.id], preset: "Air",
        patch: (LiveStreams.pressure.id, "Air pressure"))
    ) {
      ReadoutGrid(columns: 3) {
        Readout("Pressure", value: baro.pressure.map { "\(SpectraFormat.significant($0 / 1000, 5)) kPa" } ?? "—", provenance: baro.provenance)
        Readout("Rel. altitude", value: liveValue(baro.relativeAltitude, 2, unit: "m"), provenance: baro.provenance)
        Readout("N (P.453)", value: SpectraFormat.significant(air.refractivity, 4), provenance: .model)
        Readout("k-factor", value: air.kFactor > 0 ? SpectraFormat.significant(air.kFactor, 4) : "ducting", provenance: .model)
        Readout("Horizon", value: air.radioHorizon.isFinite ? SpectraFormat.si(air.radioHorizon, unit: "m", digits: 3) : "∞", provenance: .model)
        Readout("Zenith delay", value: "\(SpectraFormat.significant(air.zenithDelay, 4)) m", provenance: p)
      }
      VStack(alignment: .leading, spacing: 4) {
        FactRow(title: "n − 1", value: "\(SpectraFormat.significant(air.excessPPM, 4)) ppm", provenance: .model)
        FactRow(title: "Dry / wet N", value: "\(SpectraFormat.significant(air.dry, 4)) / \(SpectraFormat.significant(air.wet, 3))", provenance: .model)
        FactRow(title: "Geometric horizon (k = 1)", value: SpectraFormat.si(air.geometricHorizon, unit: "m", digits: 3), provenance: .model)
        FactRow(title: "Zenith delay in light time", value: "\(SpectraFormat.significant(air.zenithDelaySeconds * 1e9, 3)) ns", provenance: .model)
        FactRow(title: "O₂ absorption at 60 GHz", value: "\(SpectraFormat.significant(air.oxygen60GHz, 4)) dB/km", provenance: .model)
        FactRow(title: "Height per hPa", value: "\(SpectraFormat.significant(air.metresPerHPa, 3)) m", provenance: .model)
        FactRow(
          title: "Place for the delay", value: loc.latitude == nil ? "45°, sea level (assumed)" : "from GNSS",
          provenance: loc.latitude == nil ? .model : loc.provenance)
      }
      StreamSparkline(stream: app.streams.stream(LiveStreams.pressure.id), seconds: 120)
        .frame(height: 36)
      KnobGrid(specs: AirKnobs.specs, value: knobBinding, columns: 4)
        .padding(.top, 6)
      Text(
        "The barometer hardly moves N (0.27 N per hPa); humidity does (4.5 N per hPa of vapor), so temperature and humidity are knobs: no public iOS API measures them. Walk up a floor and the horizon for your antenna height grows."
      )
      .panelCaption()
    }
  }

  private func knobBinding(_ spec: KnobSpec) -> Binding<Double> {
    let s = app.live.settings
    switch spec.id {
    case "live-air-temp": return Binding(get: { s.prefs.airTemperature }, set: { s.prefs.airTemperature = $0 })
    case "live-air-humidity": return Binding(get: { s.prefs.airHumidity }, set: { s.prefs.airHumidity = $0 })
    case "live-air-gradient": return Binding(get: { s.prefs.refractivityGradient }, set: { s.prefs.refractivityGradient = $0 })
    default: return Binding(get: { s.prefs.antennaHeight }, set: { s.prefs.antennaHeight = $0 })
    }
  }
}

/// The Air card's knobs (static tables stay on the main actor: `KnobSpec` holds a Color).
/// All four are medium parameters of the n family, so all four wear the n / T / κ amber: the
/// E₀ blue, θ mint and φ violet accents are reserved for those dials (`Theme`, rule R2).
@MainActor
enum AirKnobs {
  static let specs: [KnobSpec] = [
    KnobSpec(
      id: "live-air-temp", title: "Temp", glyph: "T", tint: Theme.dialAmber, range: -20...45, defaultValue: 20,
      detents: [KnobDetent(15, "ISA 15 °C")], hint: "Air temperature (no sensor exposes it).", unit: "°C"),
    KnobSpec(
      id: "live-air-humidity", title: "Humidity", glyph: "RH", tint: Theme.dialAmber, range: 0...100, defaultValue: 50,
      detents: [KnobDetent(0, "Dry"), KnobDetent(50, "50 %")], hint: "Relative humidity.", unit: "%"),
    KnobSpec(
      id: "live-air-gradient", title: "Gradient", glyph: "dN", tint: Theme.dialAmber, range: -300...50, defaultValue: -40,
      detents: [KnobDetent(-40, "Standard, k ≈ 4/3"), KnobDetent(0, "k = 1"), KnobDetent(-157, "Ducting")],
      hint: "Refractivity gradient in N-units per km.", unit: "/km"),
    KnobSpec(
      id: "live-air-height", title: "Height", glyph: "h", tint: Theme.dialAmber, range: 0.5...1000, defaultValue: 1.5, logarithmic: true,
      detents: [KnobDetent(1.5, "In hand"), KnobDetent(11.5, "Three floors"), KnobDetent(30, "Mast")],
      hint: "Antenna height above the ground where the barometer started.", unit: "m"),
  ]
}
