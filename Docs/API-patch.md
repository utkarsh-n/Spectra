# API: Patch (`Spectra/Graph/`, `Spectra/UI/Patch/`)

Owner: **patch**. This is the node graph of SPEC-features §5 and the Patch bullet of §3c. It has three parts:

- a pure, `Sendable` engine in `Graph/Engine`, which compiles in the app and in a plain macOS `swiftc` harness;
- `PatchModel`, the `@MainActor` model in `Graph/Model`, which steps the engine on a `GraphRunner` actor off the main actor;
- the Patch tab in `UI/Patch`.

## What other slices call

All of these are on `app.patch` (`PatchModel`, `@Observable @MainActor`).

| Call | Effect |
|---|---|
| `addStreamSource(_ stream: StreamID, label: String)` | "Add to Patch" from any card, instrument or the Scope. It adds a **Live stream** node bound to `stream` below the others in the first column, selects it, scrolls the canvas to it, switches to the Patch tab and toasts "<label> added to Patch". `"ble.*"` means "the strongest Bluetooth device". If the stream has a quadrature partner on the bus (`x.i` + `x.q`, or `x` + `x.q`: `radio.i`/`radio.q`, `spin.fid`/`spin.fid.q`, `gyro.tip.i`/`gyro.tip.q`), the node's **I/Q** output carries both as one complex block, paired by timestamp. Its carrier label comes from the stream's λ. |
| `modulate(knobID: String, title: String)` | The "Modulate from…" menu of any `GlassKnob` (`onModulate`). Registers the knob, adds a **Knob target** aimed at `app.<knobID>`, opens its inspector and switches to Patch. |
| `registerKnob(id: String, title: String)` | Lists a knob of another tab in every Knob target's picker as `app.<id>`. |
| `modulation(for knobID: String, spec: KnobSpec, base: Double) -> KnobModulation?` | The live drive of a registered knob, for `GlassKnob(modulation:)`: a dashed arc and "Driven by … · depth …". Returns nil when nothing drives the knob. If the owner wants the modulated value, it applies `spec.scale.modulated(base:depth:cv:)` itself. |
| `markers` | The patch's frequencies on the Spectrum strip (`TabModel`). Ids are `patch.<nodeID>` and the tab is `.patch`. They are: own-dial Spectra sources, modulator carriers (the running carrier when the Carrier input is cabled, else the dial), unconnected antennas, Spin FID Larmor lines, oscillators (ANALOGY), blackbody peaks and Spectrum ruler values. A marker computed from a sensor carries its LIVE or SIM badge (`PatchModel.markerProvenance`), not plain MODEL. |
| `timeMapping` | Rule R3 for the transport chip: `.realTime`, or `.slowed(factor: 1/D)` while a Gyroscope tip's Time dial D is off 1 (the slowest one is declared; D > 1 reads as sped up). |

`app.<id>` drives are evaluated only while the graph runs. Patch applies one external target itself: `app.spectrum.lambda`, which is Spectrum source A's λ. It goes through `spectrum.tune(lambda:)` at most 10 times a second, and source A goes back to its base λ when the drive stops or the graph stops.

From Spectrum, Patch reads only the stable stage-1 API: `sourceALambda` and `tune(lambda:)`. A Spectra source node set to *Spectrum A* follows A's wavelength and keeps its own E₀ and θ dials.

Launch paths:

- `-open patch/<presetID>` loads a preset: `earthNMR`, `voiceAM`, `voiceFM`, `wifiOFDM`, `bleLive`, `mainsHum`, `gyroArray` or `lightSpectrum`.
- `-open patch/<presetID>/<nodeID>` also opens that node's inspector. `…/live`, `…/dials` or `…/cables` opens it large at that panel.
- `-open patch/<presetID>/palette` or `/presets` opens that sheet. These are for screenshots and UI tests.

Persistence uses `Spectra.patch.v1` (`PatchDocument`). It stores the graph, pan and zoom, grid snapping, the sensors started from a node, and the preset id. It is skipped under `-ui-testing`. A fresh install opens with **Earth-field NMR you can hear**, which needs no permission prompt.

## Streams Patch publishes

While the graph runs, every input of a **Scope** node becomes a stream on the scope bus. **Open in Scope** on any other node publishes up to four of its outputs:

| Id | Group | Unit | Rate |
|---|---|---|---|
| `patch.<node>.ch1` … `ch4` (Scope node) | Patch | The cable's unit ("FS", "µT", …; "" for controls) | The cable's sample rate. Control cables use the step rate: a nominal 60 Hz for frame-rate graphs, 46.875 Hz for audio-rate graphs. |
| `patch.<node>.<port>` (Open in Scope on a non-Scope node) | Patch | As above | As above |
| `….q` | Patch | "Q" | The I/Q cable's rate. An I/Q cable publishes I on the base id and Q on `.q`. |

- **Provenance**: LIVE if anything upstream is live, otherwise SIM, otherwise MODEL. An I/Q cable with a carrier carries its λ (`isEM`).
- **Capacity**: capped at 2¹⁸ samples.
- **Lifetime**: streams stay registered while the node exists and are unregistered when it is deleted. Data flows only while the graph runs.
- **Open in Scope**: switches to the Live tab's Scope (`app.openScope`). Tapped ports are sampled after every step, so a reply that caught up several blocks publishes every block, with no gaps. The graph keeps running while the Live tab is selected. This is the "node-dependent view" of §5. It stops when you leave the Live tab for any tab but Patch.
- `app.patch.scopeStreamIDs(for:)` lists a Scope node's streams. It is observed, so a view that reads it redraws when one registers or goes. The Scope node's inspector embeds `ScopeView(fixedStreams:)`.

## Engine (`Graph/Engine`, pure)

Types are `nonisolated` and `Sendable`. The engine uses only Foundation, simd and the pure engines (RF, Phase, Spin, Core).

### Ports (`PortType`)

- `audio`: real blocks at their own rate (48 kHz in audio-rate graphs).
- `iq` (`IQBlock`): complex baseband, with the carrier as a label, bandwidth, `ModemScheme`, the bits that were sent, and accumulated antenna gain.
- `spectrum` (`SpectrumFrame`).
- `control`: one Double per step.
- `attitude` (`simd_quatd`).
- `event` (`EventBlock`).
- `em` (`EMWave`: λ, E₀, θ).
- `bits`.
- `image` (`TFImage`): a time–frequency picture from the Phase engine.

### Document (`PatchGraph`, Codable)

- `nodes: [PatchNode]` (kind, label, x/y, `numbers`, `strings`) and `cables: [PatchCable]`.
- `connect(from:to:) throws(GraphError)` refuses type mismatches, wrong directions, self-loops and cycles (`GraphError.cycle(path)`). An input takes one cable; an output can feed many.
- Also: `topologicalOrder()` (Kahn; sources first; ties keep document order), `ancestors(of:)`, `outputTypes(_:)` (Gain, Filter and Mixer follow their input), `repaired()` and `isAudioRate`.

### Catalogue (`NodeKind`, `NodeCatalog.spec(_:)`, `NodeCatalog.palette`)

- Sources: `spectraSource, oscillator, noise, bits, stream, motion, gyroscope, spinFID`.
- Process: `modulator, demodulator, mixer, filter, gain, envelope, antenna, channel, medium, blackbody, fft, wigner, marginal`.
- Sinks: `scope, spectrum, constellation, speaker, haptics, ruler, knob`.

Raw values are persisted, so never rename one. Each `NodeSpec` lists its typed ports, its own provenance, and its parameters (`ParamSpec`): number (with `ParamScale` log or linear, and detents), choice, toggle, text, stream or target.

### Evaluator (`GraphEvaluator`, a value type)

- `load(_:)` keeps the state of each surviving node (phases, filters, receivers) and precomputes the cable tables.
- `step(_ world: GraphInputs) -> StepResult`:
  - runs the sinks' ancestors in order;
  - applies Knob-target drives in knob position (`ParamScale.modulated`);
  - returns `GraphEffect`s: `.play`, `.hum`, `.tap`, `.scope` and `.ruler`.
- Block payloads (audio, I/Q, bits, events) flow once. A process or sink node whose cables carried nothing this step holds: its status is kept and nothing is replayed.
- `value(at:)` / `value(into:)` return the latest value an output produced, which is what previews show.
- Also `statuses`, `drives`, `averageStepTime`, `nodeTimes` (seconds per node) and `snapshot` (`GraphSnapshot`).
- Outputs carry the `Provenance.union` of the node's own badges and every input's.

### Runner (`GraphRunner`, an actor)

- `run(GraphRequest) -> GraphReply`: an optional reset, then an optional load, then the steps, plus ports sampled after each step. The reply carries each step's effects and samples, and a `GraphSnapshot` for the views.
- `PatchModel` keeps one request in flight and queues edits behind it. Effects of replies that arrive after the graph stopped are dropped.

### Timing (`BlockScheduler`)

- A block is 1024 samples at 48 kHz, which is 21.33 ms.
- `due(at:)` returns contiguous block start times, at most `maxPerTick` (4) per tick, and drops the backlog after a stall.
- Non-audio graphs step once per frame with dt ≤ 0.1 s.

### Presets

`PatchPreset.all` has 8 presets. `PatchGeometry` gives card sizes, so cables meet the port dots without measuring views. In every preset each cable runs through the gaps between cards: none runs behind a card it does not plug into, and none passes within 12 pt of another cabled port (`testPresetCablesRunClearOfCards` checks the canvas's own Béziers). Node ids stay `n1`… in creation order, so `-open patch/<preset>/<node>` paths are stable.

## Threading

- The engine is pure and `Sendable`.
- `GraphRunner` steps it on its own executor.
- `PatchModel` (main actor) gathers the world (stream rings, attitude, Spectrum source A), sends requests, and carries out the effects: synth PCM, haptics, scope streams, ruler and drives.
- **Redraws.** The cards follow `revision`, which the model bumps when previews refresh (15 times a second while the tab is visible). The cables redraw with each refresh too, and at 30 frames a second while the graph runs for their travelling dashes (off under Reduce Motion). The status chip's step rate and step time change once a second. In the inspector, only the Overview and Live panels redraw at 15 Hz; the whole sheet does so only while a Knob target drives one of the node's dials (its arc moves).
- Measured per-step cost: about 0.1–1.5 ms at -O for the presets. Earth-field NMR with its Wigner node costs about 13 ms in a Debug build.

## Tests

`SpectraTests/GraphTests.swift` has 30 tests. 24 are engine tests that also run in the macOS harness; 6 model tests are compiled only where UIKit exists (`#if canImport(UIKit)`). They cover:

- topological order and ancestors;
- cycle rejection (connect, storage, repair, evaluator fallback);
- port types and directions;
- provenance union, including a Matter specimen's TABLE/MODEL;
- AM and FM voice round trips (output SNR with and without a long link);
- text over QPSK (BER 0, EVM), µ-law, and µ-law voice over QPSK;
- block timing (scheduler, exact 1024-sample blocks, phase continuity) and the real-time budget;
- the Wigner node's M1 marginal (exact) and peak;
- the Earth-field NMR node (2128.82 Hz at 50 µT, ruler λ, FFT peak);
- a 100 Hz sensor FFT that accumulates across 2-sample blocks with rate jitter and finds the 60 Hz alias at 39.8 Hz;
- presets build and run without warnings;
- document round trip and tolerant decoding;
- Knob target in position space;
- Motion angles in Core Motion's convention;
- a steady declared rate on Scope control channels;
- edits after load reach the next step;
- the runner matches the evaluator;
- a receive antenna feeds the Channel's Rx gain;
- quadrature pairing of a stream and its `.q` partner into one I/Q block;
- every preset's cables run clear of other cards and of other cabled ports;
- (iOS) "Open in Scope" publishes every block of a multi-block reply, and a waterfall takes a row only for a new spectrum;
- (iOS) strip markers name the sensor's LIVE or SIM badge;
- (iOS) a node added from the palette or "Modulate from…" lands clear of every card (`freeSpot(near:kind:)`);
- (iOS) stream ids map to their sensors exactly (`gyro.x` is motion, Spin's `gyro.tip.*` is no sensor), and the rotor is ANALOGY;
- (iOS) the transport's time mapping follows a Gyroscope tip's Time dial;
- (iOS) a Modulator whose carrier is cabled puts that carrier on the strip, not its idle dial.
