import SwiftUI

/// Radio → Fourier: the RF engine's end-to-end baseband simulation of the selected system at
/// frame rate while visible (I/Q trace, constellation with EVM/BER against theory, spectrum with
/// the channel mask, waterfall, Wigner–Ville vs spectrogram), the channel knobs, and the message
/// source: random bits, text, or your voice with push-to-talk.
struct RadioFourierPage: View {
  let model: RadioModel
  @Environment(AppModel.self) private var app
  @Environment(\.dynamicTypeSize) private var typeSize

  private var engine: RadioFourierEngine { model.fourierEngine }

  /// The simulation's frame rate (60 Hz, 30 on Low Power Mode) while the clock runs; 10 Hz while
  /// paused (to catch Step).
  private var frameInterval: Double { RadioFourierDriver.interval(playing: app.clock.playing) }

  var body: some View {
    let band = BandPalette.color(forFrequency: model.carrier)
    Group {
      signalPanel(band: band)
      tracePanel(band: band)
      constellationPanel
      spectrumPanel(band: band)
      timeFrequencyPanel
      channelPanel
      ViewThatFits(in: .horizontal) {
        HStack(spacing: 10) { actions }
        VStack(alignment: .leading, spacing: 10) { actions }
      }
    }
    .onAppear { model.setVisible(.fourier, true) }
    .onDisappear { model.setVisible(.fourier, false) }
  }

  @ViewBuilder
  private var actions: some View {
    ActionButton("Open in Scope", symbol: "waveform.path.ecg") { model.openInScope() }
      .accessibilityIdentifier("radio-fourier-open-scope")
    ActionButton("Add to Patch", symbol: "point.3.connected.trianglepath.dotted") { model.addToPatch() }
      .accessibilityIdentifier("radio-fourier-add-patch")
    ActionButton("Tune Spectrum here", symbol: "waveform") { model.tuneSpectrum() }
      .accessibilityIdentifier("radio-fourier-tune-spectrum")
  }

  // MARK: 01 Signal

  private func signalPanel(band: Color) -> some View {
    let s = model.system
    let waveform = s.waveform
    return InstrumentPanel("Signal", number: "01", provenance: [.model]) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Text(s.generation).font(.system(.title3, design: .monospaced).weight(.semibold)).foregroundStyle(band)
        Text(s.name).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.text).lineLimit(2)
        Spacer(minLength: 0)
        if s.isSpeculative { RadioSpeculativeBadge() }
      }
      .accessibilityElement(children: .combine)
      Button {
        Haptics.shared.tap()
        model.showSelectedSystemCard()
      } label: {
        Label("Change system", systemImage: "antenna.radiowaves.left.and.right").font(.subheadline.weight(.semibold))
          .frame(minHeight: 32)
      }
      .buttonStyle(.glass)
      .accessibilityIdentifier("radio-change-system")
      VisibleTimeline(minimumInterval: 0.25) { _ in
        let snap = engine.snapshot
        ReadoutGrid(columns: 2) {
          Readout("Waveform", value: snap.waveformName.isEmpty ? waveform.displayName : snap.waveformName, color: band, provenance: .model)
          Readout("Sample rate", value: SpectraFormat.frequency(snap.sampleRate), provenance: .model)
          Readout("Symbol rate", value: snap.symbolRate > 0 ? "\(SpectraFormat.si(snap.symbolRate, unit: "Bd"))" : "—", provenance: .model)
          Readout("Occupied BW", value: snap.occupiedBandwidth > 0 ? SpectraFormat.frequency(snap.occupiedBandwidth) : "CW", provenance: .model)
        }
      }
      if waveform.dataModulation != nil, model.fourier.message != .voice {
        modulationChips(waveform)
      }
      messageChips(waveform)
      switch model.fourier.message {
      case .text where RadioModel.supportsText(waveform): textControls
      case .voice where RadioModel.supportsVoice(waveform): voiceControls(waveform)
      default:
        Text(autoCaption(waveform)).panelCaption()
      }
    }
  }

  private func autoCaption(_ w: RF.Waveform) -> String {
    switch w {
    case .tone: "An unmodulated carrier (wireless power transfer): one line in the spectrum, one dot in I/Q."
    case .chirp: "FMCW radar: the frequency sweeps linearly across the band, chirp after chirp. Range resolution is c/2B."
    case .analogAM, .analogFM: "A 1 kHz test tone at 80 % of full scale modulates the carrier."
    default: "Seeded random bits, mapped to symbols with Gray coding."
    }
  }

  private enum ModulationChoice: Hashable, Identifiable {
    case system
    case override(RF.DigitalModulation)
    var id: String {
      switch self {
      case .system: "system"
      case .override(let m): m.rawValue
      }
    }
  }

  private func modulationChips(_ w: RF.Waveform) -> some View {
    let own = w.dataModulation
    let options: [ModulationChoice] =
      [.system] + RF.DigitalModulation.allCases.filter { $0 != .ook && $0 != own }.map { .override($0) }
    return VStack(alignment: .leading, spacing: 6) {
      Text("MODULATION").font(Theme.readoutTitleFont).foregroundStyle(Theme.muted)
      ChoiceChips(
        items: options,
        selection: Binding(
          get: { model.fourier.modulation.map { ModulationChoice.override($0) } ?? .system },
          set: { choice in
            switch choice {
            case .system: model.fourier.modulation = nil
            case .override(let m): model.fourier.modulation = m
            }
          }),
        id: "radio-modulation"
      ) { choice in
        switch choice {
        case .system: ChipLabel(title: "\(own?.displayName ?? "System") (system)")
        case .override(let m): ChipLabel(title: m.displayName)
        }
      }
      .padding(.horizontal, -Theme.panelPadding)
    }
  }

  private func messageChips(_ w: RF.Waveform) -> some View {
    let analog = RadioModel.isAnalog(w)
    let autoTitle: String =
      switch w {
      case .tone: "Carrier"
      case .chirp: "Chirps"
      default: analog ? "Tone" : "Random"
      }
    let autoSymbol: String =
      switch w {
      case .tone: "dot.radiowaves.right"
      case .chirp: "waveform.path"
      default: analog ? "tuningfork" : "dice"
      }
    let items: [(RadioMessage, String, String, Bool)] = [
      (.auto, autoTitle, autoSymbol, true),
      (.text, "Text", "textformat", RadioModel.supportsText(w)),
      (.voice, "Voice", "mic.fill", RadioModel.supportsVoice(w)),
    ]
    return VStack(alignment: .leading, spacing: 6) {
      Text("MESSAGE").font(Theme.readoutTitleFont).foregroundStyle(Theme.muted)
      GlassEffectContainer(spacing: 8) {
        HStack(spacing: 8) {
          ForEach(items.indices, id: \.self) { index in
            let item = items[index]
            let selected = model.fourier.message == item.0
            Button {
              guard !selected else { return }
              Haptics.shared.selection()
              model.fourier.message = item.0
            } label: {
              Label(item.1, systemImage: item.2)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(selected ? Theme.text : (item.3 ? Theme.muted : Theme.dim))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .padding(.horizontal, 10)
                .frame(minHeight: 40)
            }
            .buttonStyle(.plain)
            .glassEffect(
              selected ? .regular.tint(Theme.phosphor.opacity(0.28)).interactive() : .regular.interactive(),
              in: .rect(cornerRadius: Theme.chipRadius)
            )
            .disabled(!item.3)
            .accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityIdentifier("radio-message-\(item.0.rawValue)")
          }
        }
      }
      if !RadioModel.supportsText(w) {
        RadioDisabledReason(
          RadioModel.supportsVoice(w)
            ? "Text needs a digital system; AM and FM carry audio."
            : "This system carries no message: text and voice need a modulated system.")
      }
    }
  }

  private var textControls: some View {
    VStack(alignment: .leading, spacing: 8) {
      TextField(
        "Message to send", text: Binding(get: { model.fourier.text }, set: { model.fourier.text = String($0.prefix(200)) })
      )
      .textFieldStyle(.plain)
      .font(.system(.body, design: .monospaced))
      .padding(10)
      .background(Theme.plotWell, in: .rect(cornerRadius: 12))
      .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.phosphor.opacity(0.25)) }
      .submitLabel(.done)
      .accessibilityIdentifier("radio-text-field")
      VisibleTimeline(minimumInterval: 0.2) { _ in
        let snap = engine.snapshot
        VStack(alignment: .leading, spacing: 4) {
          HStack(spacing: 6) {
            Text("RECEIVED").font(Theme.readoutTitleFont).foregroundStyle(Theme.muted)
            ProvenanceBadge(.model, compact: true)
          }
          Text(snap.decodedText.isEmpty ? "…" : snap.decodedText)
            .font(.system(.callout, design: .monospaced))
            .foregroundStyle(Theme.amber)
            .lineLimit(3)
            .truncationMode(.head)  // keep the newest characters in view
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("radio-decoded-text")
        }
        .accessibilityElement(children: .combine)
      }
      Text("The text's UTF-8 bits repeat through the channel and are decoded byte by byte. Lower the SNR to watch characters break.")
        .panelCaption()
    }
  }

  @ViewBuilder
  private func voiceControls(_ w: RF.Waveform) -> some View {
    let mic = app.live.channel(.microphone)
    PermissionGate(
      title: "Microphone", symbol: "mic.fill", state: mic.state, startTitle: "Use the microphone",
      explanation: "Spectra listens only while this page shows Voice, and nothing is recorded or sent.",
      start: { app.live.acquire(.microphone, by: RadioFourierEngine.micOwner) }
    ) {
      VStack(alignment: .leading, spacing: 10) {
        HStack(spacing: 8) {
          // Sound is not electromagnetic: the voice carries ANALOGY next to the mic's own badge.
          ProvenanceBadges([mic.provenance, .analogy])
          Text(RadioModel.isAnalog(w) ? "Your voice modulates the carrier directly." : "Your voice → 8 kHz µ-law PCM (64 kbit/s) → QPSK at 32 kBd.")
            .font(.caption)
            .foregroundStyle(Theme.muted)
            .fixedSize(horizontal: false, vertical: true)
        }
        pushToTalk
        if !app.settings.soundOn {
          HStack(spacing: 10) {
            Label("Sound is off, so you will not hear the result.", systemImage: "speaker.slash.fill")
              .font(.caption)
              .foregroundStyle(Theme.amber)
              .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button("Turn on") {
              Haptics.shared.success()
              app.settings.soundOn = true
            }
            .buttonStyle(.glass)
            .accessibilityIdentifier("radio-sound-on")
          }
        }
        Text(
          "Push to talk: while you hold the button the demodulated audio is collected, and it plays when you let go, so the speaker never feeds the microphone. With headphones it plays live."
        )
        .panelCaption()
      }
    }
  }

  private var pushToTalk: some View {
    let talking = engine.talking
    return HStack(spacing: 12) {
      Label(talking ? "Talking…" : "Hold to talk", systemImage: talking ? "waveform.badge.mic" : "mic.fill")
        .font(.headline)
        .foregroundStyle(talking ? Theme.background : Theme.text)
        .frame(maxWidth: .infinity, minHeight: 52)
        .background(talking ? Theme.phosphor : Color.clear, in: .capsule)
        .glassEffect(talking ? .regular.tint(Theme.phosphor.opacity(0.6)) : .regular.interactive(), in: .capsule)
        .contentShape(.capsule)
        .gesture(
          DragGesture(minimumDistance: 0)
            .onChanged { _ in if !engine.talking { engine.setTalking(true) } }
            .onEnded { _ in engine.setTalking(false) }
        )
        .accessibilityElement()
        .accessibilityLabel(talking ? "Stop talking" : "Talk")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { engine.setTalking(!engine.talking) }
        .accessibilityIdentifier("radio-push-to-talk")
      VisibleTimeline(minimumInterval: 0.2) { _ in
        VStack(alignment: .trailing, spacing: 2) {
          Text(AudioRoute.isPrivateOutput ? "LIVE" : "BUFFER").font(Theme.readoutTitleFont).foregroundStyle(Theme.muted)
          Text("\(SpectraFormat.significant(engine.bufferedSeconds, 2)) s")
            .font(Theme.readoutValueFont).monospacedDigit().foregroundStyle(Theme.amber)
        }
        .frame(minWidth: 60)
        .accessibilityElement(children: .combine)
      }
      .fixedSize()
    }
  }

  // MARK: 02 I/Q trace

  private func tracePanel(band: Color) -> some View {
    InstrumentPanel("I/Q trace", number: "02", provenance: [.model]) {
      ChoiceChips(
        items: RadioTraceSource.allCases, selection: Binding(get: { model.traceSource }, set: { model.traceSource = $0 }),
        id: "radio-trace"
      ) { ChipLabel(title: $0.title) }
      .padding(.horizontal, -Theme.panelPadding)
      PlotWell(height: 170, grid: 0) {
        VisibleTimeline(minimumInterval: frameInterval) { _ in
          let snap = engine.advance()
          LinePlot(
            series: [
              PlotSeries(id: "i", values: snap.traceI, color: Theme.phosphor, width: 1.3, label: "I"),
              PlotSeries(id: "q", values: snap.traceQ, color: Theme.amber, width: 1.3, label: "Q"),
            ],
            yRange: traceRange(snap), accessibilityLabel: "In-phase and quadrature trace")
          .accessibilityIdentifier("radio-iq-trace")
          .padding(.horizontal, 6)
          .overlay(alignment: .bottomTrailing) {
            Text("\(SpectraFormat.si(snap.traceDuration, unit: "s")) shown")
              .font(Theme.annotationFont).foregroundStyle(Theme.dim).padding(6)
          }
        }
      }
      HStack(spacing: 12) {
        legendItem("I (in-phase)", Theme.phosphor)
        legendItem("Q (quadrature)", Theme.amber)
      }
      Text("Complex baseband: the carrier is removed (heterodyned at \(SpectraFormat.frequency(model.carrier))), so I and Q are the slow envelope that rides on it. Every frame is a fresh stretch of the signal; the transport pauses or steps it.")
        .panelCaption()
    }
  }

  private func traceRange(_ s: RadioFourierSnapshot) -> ClosedRange<Double> {
    let m = max(s.traceI.map(abs).max() ?? 1, s.traceQ.map(abs).max() ?? 1)
    let r = max(0.2, m * 1.1)
    return -r...r
  }

  private func legendItem(_ title: String, _ color: Color) -> some View {
    HStack(spacing: 5) {
      Capsule().fill(color).frame(width: 14, height: 3)
      Text(title).font(.caption2).foregroundStyle(Theme.muted)
    }
  }

  // MARK: 03 Constellation

  private var constellationPanel: some View {
    InstrumentPanel("Constellation", number: "03", provenance: [.model]) {
      PlotWell(height: 280, grid: 0) {
        VisibleTimeline(minimumInterval: frameInterval) { _ in
          let snap = engine.advance()
          ConstellationPlot(
            points: snap.received, ideal: snap.ideal, range: snap.constellationRange,
            color: Theme.phosphor, accessibilityLabel: snap.isTrajectory ? "I/Q trajectory" : "Received constellation")
          .accessibilityIdentifier("radio-constellation")
          .padding(10)
        }
      }
      VisibleTimeline(minimumInterval: 0.25) { _ in
        let snap = engine.snapshot
        if snap.isTrajectory {
          if snap.bitsCounted > 0 {
            ReadoutGrid(columns: 2) {
              Readout("BER measured", value: ber(snap.measuredBER, bits: snap.bitsCounted), color: Theme.phosphor, provenance: .model)
              Readout("Bits counted", value: SpectraFormat.scientific(Double(snap.bitsCounted), digits: 3), provenance: .model)
            }
          }
          Text(trajectoryCaption).panelCaption()
        } else {
          ReadoutGrid(columns: 3) {
            Readout("EVM", value: snap.evm.map { "\(SpectraFormat.significant($0.percent, 3)) %" } ?? "—", provenance: .model)
            Readout("EVM dB", value: snap.evm.map { SpectraFormat.decibels($0.dB, decimals: 1) } ?? "—", provenance: .model)
            Readout("SNR (EVM)", value: snap.evm.map { SpectraFormat.decibels($0.estimatedSNRDB, decimals: 1) } ?? "—", provenance: .model)
            Readout("BER meas.", value: ber(snap.measuredBER, bits: snap.bitsCounted), color: Theme.phosphor, provenance: .model)
            Readout("BER theory", value: snap.berTheory.map(Self.theoryBER) ?? "—", color: Theme.text, provenance: .model)
            Readout("Bits", value: SpectraFormat.scientific(Double(snap.bitsCounted), digits: 3), provenance: .model)
          }
          Text("\(Self.idealCaption(snap)) Theory is the AWGN bit error rate at this Es/N0; multipath, fading and Doppler push the measurement above it.")
            .panelCaption()
        }
      }
    }
  }

  private var trajectoryCaption: String {
    switch model.system.waveform {
    case .analogAM: "AM has no symbols: the I/Q point slides along the real axis as the envelope 1 + m·x(t) breathes."
    case .analogFM: "FM has no symbols: the I/Q point runs round a circle of constant amplitude; its speed is the frequency."
    case .tone: "A pure carrier is one still point; noise blurs it into a cloud."
    case .chirp: "An FMCW chirp traces a circle whose speed ramps up from −B/2 to +B/2."
    case .fsk: "FSK has no fixed constellation: these are the samples at each symbol's center, where the phase has turned by ±πh."
    default: "This waveform has no ideal constellation."
    }
  }

  /// What the dots and rings are. Constellations above 256 points draw no rings (they would
  /// cover the plot), so the caption says so instead of promising them.
  static func idealCaption(_ s: RadioFourierSnapshot) -> String {
    let name = s.modulationName.map { " of \($0)" } ?? ""
    return s.ideal.isEmpty
      ? "Dots are the receiver's decisions; the ideal points\(name) are too dense to ring one by one, so they are left out."
      : "Dots are the receiver's decisions; amber rings the ideal points\(name)."
  }

  /// Theory below 10⁻¹⁵ reads "< 10⁻¹⁵": QPSK at 30 dB is 10⁻²²⁰, a number no measurement here
  /// could ever reach (a frame counts about 10⁴ bits).
  static func theoryBER(_ p: Double) -> String {
    guard p.isFinite else { return "—" }
    return p < 1e-15 ? "< 10⁻¹⁵" : SpectraFormat.scientific(p, digits: 2)
  }

  private func ber(_ v: Double?, bits: Int) -> String {
    guard let v else { return "—" }
    if v == 0 { return bits > 0 ? "< \(SpectraFormat.scientific(1 / Double(bits), digits: 1))" : "—" }
    return SpectraFormat.scientific(v, digits: 2)
  }

  // MARK: 04 Spectrum

  private func spectrumPanel(band: Color) -> some View {
    InstrumentPanel("Spectrum", number: "04", provenance: [.model]) {
      PlotWell(height: 190, grid: 0) {
        VisibleTimeline(minimumInterval: frameInterval) { _ in
          let snap = engine.advance()
          RadioSpectrumView(
            bins: snap.spectrum, sampleRate: snap.sampleRate, carrier: model.carrier, occupied: snap.occupiedBandwidth,
            channelWidth: max(model.system.maxChannelWidth ?? 0, snap.occupiedBandwidth), color: band)
          .accessibilityIdentifier("radio-spectrum-plot")
          .padding(.horizontal, 6)
        }
      }
      PlotWell(height: 96, grid: 0) {
        VisibleTimeline(minimumInterval: frameInterval) { _ in
          let _ = engine.advance()
          let image = engine.waterfallImage()
          Canvas { ctx, size in
            if let image { ctx.draw(Image(decorative: image, scale: 1), in: CGRect(origin: .zero, size: size)) }
          }
          .accessibilityElement()
          .accessibilityLabel("Waterfall of the received spectrum")
          .accessibilityValue("Time runs downward, newest at the top.")
          .accessibilityIdentifier("radio-waterfall")
        }
      }
      Text("Hann-windowed FFT of the received baseband, averaged (Welch) and shown relative to its peak. The amber band is the occupied channel; dashed boxes are the neighboring channels. The waterfall scrolls down, newest on top.")
        .panelCaption()
    }
  }

  // MARK: 05 Time–frequency

  private var timeFrequencyPanel: some View {
    InstrumentPanel("Time–frequency", number: "05", provenance: [.model]) {
      ChoiceChips(
        items: RadioTFView.allCases, selection: Binding(get: { model.tfView }, set: { model.tfView = $0 }), id: "radio-tf"
      ) { ChipLabel(title: $0.title) }
      .padding(.horizontal, -Theme.panelPadding)
      VisibleTimeline(minimumInterval: 0.25) { _ in
        let _ = engine.advance()
        Color.clear.frame(height: 0)
      }
      if let tf = engine.tf {
        let wv = RadioHeatImage.make(tf.wigner, rows: tf.rows, columns: tf.columns, map: .diverging, timeAcross: true)
        let sg = RadioHeatImage.make(tf.spectrogram, rows: tf.rows, columns: tf.columns, map: .sequential, timeAcross: true)
        let y = [
          "+\(SpectraFormat.frequency(tf.frequencyEnd, digits: 2))", "carrier",
          "−\(SpectraFormat.frequency(abs(tf.frequencyStart), digits: 2))",
        ]
        let x = ["0", "time →", SpectraFormat.si(tf.duration, unit: "s")]
        let layout =
          typeSize.isAccessibilitySize || model.tfView != .both
          ? AnyLayout(VStackLayout(spacing: 8)) : AnyLayout(HStackLayout(spacing: 8))
        layout {
          if model.tfView != .spectrogram {
            PlotWell(height: 200, grid: 0) {
              RadioHeatMapView(
                image: wv, title: "Wigner–Ville", yLabels: y, xLabels: x, accessibilityLabel: "Wigner–Ville distribution",
                accessibilityValue: "Time across, frequency up; orange positive, blue negative")
              .accessibilityIdentifier("radio-tf-wigner")
            }
          }
          if model.tfView != .wignerVille {
            PlotWell(height: 200, grid: 0) {
              RadioHeatMapView(
                image: sg, title: "Spectrogram", yLabels: y, xLabels: x, accessibilityLabel: "Spectrogram",
                accessibilityValue: "Time across, frequency up; brighter is stronger")
              .accessibilityIdentifier("radio-tf-spectrogram")
            }
          }
        }
        if model.tfView != .spectrogram { RadioDivergingLegend() }
        ReadoutGrid(columns: 2) {
          Readout("Time marginal error", value: SpectraFormat.scientific(tf.marginalError, digits: 1), color: Theme.phosphor, provenance: .model)
          Readout("Most negative W", value: "\(SpectraFormat.significant(tf.negativeFraction * 100, 2)) % of max", color: RadioColorMap.cool.color, provenance: .model)
        }
      } else {
        PlotWell(height: 200) { ProgressView().tint(Theme.phosphor) }
      }
      Text(tfCaption).panelCaption()
      Text("Spacetime Wigner distribution: Utkarsh's construction and convention (C); this is its time–frequency slice.")
        .font(.caption2)
        .foregroundStyle(Theme.dim)
    }
  }

  private var tfCaption: String {
    if case .chirp = model.system.waveform {
      return "A linear chirp's Wigner–Ville distribution is a straight line ν(t) = f₀ + αt: sharp in time and frequency at once, which the spectrogram's window cannot do."
    }
    return "Wigner–Ville (the Phase engine's time slice of Utkarsh's Φ) of the sent signal against a spectrogram on the same grid. The Wigner is sharper but signed: where two components overlap it paints oscillating cross terms, orange and blue. Summed over frequency it gives |z(t)|² exactly (the time-marginal error is round-off)."
  }

  // MARK: 06 Channel

  private var channelPanel: some View {
    let f = model.fourier
    let analog = RadioModel.isAnalog(model.system.waveform)
    return InstrumentPanel("Channel", number: "06", provenance: [.model]) {
      ChoiceChips(
        items: RadioFading.allCases, selection: Binding(get: { model.fourier.fading }, set: { model.fourier.fading = $0 }),
        id: "radio-fading"
      ) { ChipLabel(title: $0.title) }
      .padding(.horizontal, -Theme.panelPadding)
      RadioKnobRow(
        items: [
          (RadioKnobs.snr(analog: analog), true),
          (RadioKnobs.delaySpread, true),
          (RadioKnobs.doppler(carrier: model.carrier), f.fading != .none),
          (RadioKnobs.ricianK, f.fading == .rician),
        ],
        value: { RadioKnobs.fourierBinding($0, model) })
      if f.fading == .none {
        RadioDisabledReason("Doppler moves fading taps: choose Rayleigh or Rician to use it.")
      } else if f.fading != .rician {
        RadioDisabledReason("K is the Rician line-of-sight ratio: choose Rician to use it.")
      }
      Text(analog
        ? "AWGN at this carrier-to-noise ratio, an exponential multipath profile with this RMS delay spread, and Rayleigh or Rician fading moving at the Doppler rate (Clarke/Jakes)."
        : "AWGN at this Es/N0, an exponential multipath profile with this RMS delay spread, and Rayleigh or Rician fading moving at the Doppler rate (Clarke/Jakes). Single-carrier receivers here have no equalizer, so long echoes show as ISI; OFDM equalizes them.")
      .panelCaption()
    }
  }
}

/// A row of knobs where some may be disabled (with the floating readout card while held).
/// Like `KnobGrid`, a long press on an enabled knob offers "Modulate from…" (a Patch Knob
/// target aimed at it, SPEC-features §5) and a live Patch drive shows as its dashed arc.
struct RadioKnobRow: View {
  let items: [(KnobSpec, Bool)]
  let value: (KnobSpec) -> Binding<Double>
  var columns = 4
  /// The linear slider under each knob (the Dials sheets).
  var showsSliders = false
  @Environment(\.dynamicTypeSize) private var typeSize
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(AppModel.self) private var app: AppModel?
  @Environment(\.dismiss) private var dismiss
  @State private var active: String?

  var body: some View {
    let count = typeSize.isAccessibilitySize ? min(2, columns) : columns
    GlassEffectContainer(spacing: 18) {
      LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: count), spacing: 12) {
        ForEach(items.indices, id: \.self) { index in
          let (spec, enabled) = items[index]
          GlassKnob(
            spec: spec, value: value(spec), modulation: drive(spec), showsSlider: showsSliders,
            onActive: { on in active = on ? spec.id : (active == spec.id ? nil : active) },
            onModulate: enabled ? modulateAction(spec) : nil)
            .disabled(!enabled)
            .opacity(enabled ? 1 : 0.4)
        }
      }
    }
    .overlay(alignment: .top) {
      if let id = active, let spec = items.first(where: { $0.0.id == id })?.0 {
        KnobReadout(spec: spec, value: value(spec).wrappedValue, modulation: drive(spec))
          .offset(y: -86)
          .transition(.opacity.combined(with: .scale(scale: 0.92, anchor: .bottom)))
      }
    }
    .animation(Theme.animation(reduceMotion, .spring(duration: 0.3, bounce: 0.25)), value: active)
  }

  /// A live Patch drive aimed at this knob (its dashed arc), or nil.
  private func drive(_ spec: KnobSpec) -> KnobModulation? {
    app?.patch.externalModulation(for: spec.id, spec: spec)
  }

  /// "Modulate from…": a Patch Knob target that moves this knob through its binding.
  private func modulateAction(_ spec: KnobSpec) -> (() -> Void)? {
    guard let app, !spec.isSwitch else { return nil }
    let binding = value(spec)
    return {
      // A Dials sheet would stay over the Patch tab: close it first (no-op outside a sheet).
      dismiss()
      app.patch.modulate(
        knobID: spec.id, title: "\(app.selectedTab.title) · \(spec.title)", scale: spec.scale,
        get: { binding.wrappedValue }, set: { binding.wrappedValue = $0 })
    }
  }
}
