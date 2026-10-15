import SwiftUI

/// The Patch tab (SPEC-features §5): a pan/zoom canvas of glass node cards joined by glowing
/// cables, an add-node palette, presets, and a node inspector. The graph evaluates only while
/// this tab is on screen and the clock plays.
struct PatchTab: View {
  @Environment(AppModel.self) private var app
  @Environment(\.scenePhase) private var scenePhase

  var body: some View {
    let model = app.patch
    InstrumentScreen(
      tab: .patch, subtitle: "Wire it together", notes: Self.notes,
      transport: TransportConfig(
        timeMapping: model.timeMapping,
        actions: [
          TransportAction(id: "patch-step-block", title: "Step one block", symbol: "forward.frame") { model.stepOnce() },
          TransportAction(id: "patch-fit-action", title: "Fit patch to screen", symbol: "viewfinder") {
            model.fit(in: model.lastViewport)
          },
        ]),
      scrolls: false
    ) {
      PatchDials()
    } content: {
      PatchCanvasView()
    }
    .task(id: scenePhase == .active) {
      guard scenePhase == .active else { return }
      await model.run()
    }
  }

  static let notes = FieldNotes(
    title: "Patch",
    intro:
      "A node graph where every source, process and sink in Spectra connects with cables: live sensors, simulated radios, spins and Spectra's own waves. Drag from an output dot to an input dot to connect; drag a plugged input away to unplug it.",
    sections: [
      FieldNoteSection(
        number: "01", title: "What runs, and when",
        paragraphs: [
          "The graph runs only while the clock plays and this tab is on screen, or the Live tab's Scope is showing signals that Open in Scope sent there. Nodes run in topological order, sources first; a cable that would close a loop is refused, because a loop has no first node. Feedback goes through a **Knob target**, which acts one step later.",
          "A graph with any audio-rate node (oscillator, noise, microphone, spin FID, speaker) steps in blocks of 1,024 samples at 48 kHz: 21.3 ms of sound, 46.875 blocks a second. Everything else steps once per display frame. **Step one block** in the transport's menu advances one step while paused.",
        ],
        items: [
          FieldNoteItem(.model, "Modulator, Channel, Demodulator", "The RF engine's transmitter, link budget, channel simulator and receiver, run as separate stages."),
          FieldNoteItem(.live, "Live stream nodes", "Any signal on the scope bus, read with its own timestamps at its own rate."),
          FieldNoteItem(.sim, "In the Simulator", "Sensors are simulated at their real rates, so aliasing and timing behave as on the phone."),
        ]),
      FieldNoteSection(
        number: "02", title: "Cables carry their badges",
        paragraphs: [
          "Every output carries the union of its inputs' badges and its node's own (rule R4). A spin precessing in your phone's measured field is MODEL · LIVE; voice through a simulated radio is MODEL · LIVE · ANALOGY.",
          "Cable color means frequency only where there is one: EM waves and radio carriers glow in their band's color; sound and samples are phosphor; control values, events and bits are amber.",
        ]),
      FieldNoteSection(
        number: "03", title: "Radio at baseband",
        paragraphs: [
          "A 5 GHz carrier cannot be sampled on a phone, so signals travel as their complex envelope (I + jQ) with the carrier as a label (HETERODYNED). The Channel computes a link budget (path loss, walls, noise floor −174 dBm/Hz + 10 log B + NF) and adds exactly that much noise in the signal's bandwidth.",
          "Receivers are honest: single-carrier modes have no equalizer, OFDM equalizes from its training symbol, and bit errors are counted against the bits that were actually sent. Voice on a digital mode is 8 kHz, 8-bit µ-law (64 kb/s).",
          "AM and FM receivers low-pass the recovered audio at 4.5 kHz, as real ones do. FM's discriminator noise rises with frequency, so this filter is most of FM's advantage over AM above the threshold (about 10 dB of carrier-to-noise); below it the voice breaks into noise.",
        ],
        sources: [FieldNoteSource("3GPP TR 38.901 channel models", "https://www.3gpp.org/dynareport/38901.htm")]),
      FieldNoteSection(
        number: "04", title: "Phase space nodes",
        paragraphs: [
          "The **Wigner** node draws a stream's time–frequency picture in Utkarsh's convention (C) for the spacetime Wigner distribution: positive frequency is e^(−2πiνt), real streams go through the analytic signal, and only the unsmoothed Wigner has exact marginals.",
          "The **Marginal** node integrates the picture back: over frequency it returns |x(t)|², over time |X(ν)|². Its M1 error is round-off for the Wigner–Ville and pseudo-Wigner views; smoothed views and spectrograms blur it, and the node says so.",
        ]),
      FieldNoteSection(
        number: "05", title: "Spins and the gyroscope",
        paragraphs: [
          "**Spin FID** makes protons in water precess at f = 42.576 MHz/T × |B|: 2,128.8 Hz in 50 µT, played at true pitch. Fed by your magnetometer, its pitch follows the field you are standing in.",
          "**Gyroscope tip** is Gyre's heavy top: the axle tip seen from above is an I/Q signal whose rotation is the precession. Its Time dial runs the top slower or faster than real time, and the transport's time chip says so.",
        ],
        items: [FieldNoteItem(.analogy, "The rotor", "A mechanical top precesses like a spin, but it is not electromagnetic; it carries the ANALOGY color.")],
        sources: [
          FieldNoteSource(
            "NIST CODATA 2022: shielded proton gyromagnetic ratio γ′p/2π = 42.576 385 43 MHz/T",
            "https://physics.nist.gov/cgi-bin/cuu/Value?gammapbar")
        ]),
      FieldNoteSection(
        number: "06", title: "Sound, touch and the loop",
        paragraphs: [
          "The **Speaker** plays through the synth when Sound is on in Settings. A live microphone upstream plays only through headphones or Bluetooth, so the speaker cannot feed back into the microphone.",
          "The **Haptics** sink drives the continuous hum when Settings → Continuous hum is on; events always tap. The **Spectrum ruler** puts a wave or a frequency on the strip above every tab and, on request, tunes the Spectrum tab to it.",
          "A **Knob target** turns any numeric knob from a control signal, in knob position, so log knobs move musically (gyre-integration §7).",
        ]),
    ])
}

/// The Dials sheet: view controls, presets and housekeeping.
struct PatchDials: View {
  @Environment(AppModel.self) private var app
  @State private var confirmClear = false

  var body: some View {
    let model = app.patch
    ControlSheet(
      title: "Patch controls",
      resetDials: {
        model.setZoom(0.8, around: nil)
        model.snapToGrid = true
        model.save()
      },
      resetAlignment: { model.fit(in: model.lastViewport) },
      resetDialsHint: "Restore the zoom and grid snapping.",
      resetAlignmentHint: "Fit the whole patch on screen."
    ) {
      InstrumentPanel("View", number: "01") {
        GlassSlider(
          title: "Zoom",
          value: Binding(
            get: { model.zoom },
            set: {
              model.setZoom($0, around: nil)
              model.save()
            }),
          range: PatchModel.zoomRange, step: 0.01, color: Theme.phosphor,
          format: { "\(Int(($0 * 100).rounded())) %" })
        .accessibilityIdentifier("patch-dials-zoom")
        GlassToggle(
          "Snap cards to grid",
          isOn: Binding(
            get: { model.snapToGrid },
            set: {
              model.snapToGrid = $0
              model.save()
            }), symbol: "square.grid.2x2",
          subtitle: "Cards land on an 8-point grid with a tick.")
        .accessibilityIdentifier("patch-dials-snap")
      }
      InstrumentPanel("Presets", number: "02") {
        PatchPresetList { preset in
          model.load(preset: preset)
        }
      }
      InstrumentPanel("Patch", number: "03") {
        if model.canRestore {
          ActionButton("Restore previous patch", symbol: "arrow.uturn.backward") { model.restorePrevious() }
            .accessibilityIdentifier("patch-dials-restore")
        }
        ActionButton("Clear the canvas", symbol: "trash", tint: Theme.ionizing) { confirmClear = true }
          .accessibilityIdentifier("patch-dials-clear")
          .disabled(model.graph.nodes.isEmpty)
        SheetCaption("Clearing keeps the old patch one step back: Restore brings it back.")
      }
    }
    .confirmationDialog("Clear every node and cable?", isPresented: $confirmClear, titleVisibility: .visible) {
      Button("Clear the canvas", role: .destructive) { model.clear() }
      Button("Cancel", role: .cancel) {}
    }
  }
}

/// The eight presets as tappable rows.
struct PatchPresetList: View {
  var onPick: (PatchPreset) -> Void
  @Environment(AppModel.self) private var app
  @ScaledMetric(relativeTo: .body) private var iconWidth = 28.0

  var body: some View {
    VStack(spacing: 8) {
      ForEach(PatchPreset.all) { preset in
        Button {
          onPick(preset)
        } label: {
          HStack(alignment: .top, spacing: 12) {
            Image(systemName: preset.symbol)
              .font(.body)
              .foregroundStyle(Theme.phosphor)
              .frame(width: iconWidth)
            VStack(alignment: .leading, spacing: 3) {
              Text(preset.title).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.text)
              Text(preset.summary).font(.caption).foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if app.patch.presetID == preset.id {
              Image(systemName: "checkmark").foregroundStyle(Theme.phosphor).accessibilityLabel("Loaded")
            }
          }
          .padding(12)
          .frame(maxWidth: .infinity, alignment: .leading)
          .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: Theme.chipRadius))
        .accessibilityIdentifier("patch-preset-\(preset.id)")
        .accessibilityHint(preset.summary)
      }
    }
  }
}
