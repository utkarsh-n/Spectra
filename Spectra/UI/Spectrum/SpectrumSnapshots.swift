import SwiftUI
import UIKit

#if DEBUG
  /// DEBUG only: `-spectrumSnapshots` walks every instrument of the Spectrum tab (the same model
  /// calls its controls make) and writes PNGs of the real key window to the app's Documents
  /// folder (`spectrum-ui-<name>.png`), Metal scenes included. `-spectrumSnapshots=<name>,…`
  /// runs only the named shots; `-spectrumSnapshots=page` renders the content column offscreen
  /// with `ImageRenderer` instead (for a Simulator whose render server shows no frames; the
  /// Metal scenes are then drawn as CPU sketches by `SceneSketch`). It exists because
  /// `simctl io screenshot` hangs when many simulators share the machine.
  @MainActor
  enum SpectrumSnapshots {
    static var argument: String? {
      ProcessInfo.processInfo.arguments.first { $0.hasPrefix("-spectrumSnapshots") }
    }
    static var requested: Bool { argument != nil }

    /// Names after `=` (empty: every shot).
    static var filter: Set<String> {
      guard let a = argument, let eq = a.firstIndex(of: "=") else { return [] }
      return Set(a[a.index(after: eq)...].split(separator: ",").map(String.init))
    }

    /// `-spectrumChecks`: runs `SpectrumLogicChecks` off the main thread and writes the result
    /// to the console and Documents/spectrum-ui-checks.txt.
    static func runChecksIfRequested() {
      guard ProcessInfo.processInfo.arguments.contains("-spectrumChecks") else { return }
      let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
      Task.detached(priority: .utility) {
        let r = SpectrumLogicChecks.run()
        let text = (r.lines + ["spectrum-ui logic checks: \(r.passed.count) passed, \(r.failed.count) failed"])
          .joined(separator: "\n")
        print(text)
        try? text.write(to: folder.appendingPathComponent("spectrum-ui-checks.txt"), atomically: true, encoding: .utf8)
      }
    }

    static func run(app: AppModel) {
      Task { @MainActor in
        try? await Task.sleep(for: .seconds(2))
        let runner = Runner(app: app, filter: filter)
        await runner.all()
        runner.finish()
      }
    }
  }

  /// The Spectrum tab's DEBUG-only presentation hooks (sheets the foundation's
  /// `InstrumentScreen` keeps private).
  @Observable @MainActor
  final class SpectrumSnapshotDriver {
    static let shared = SpectrumSnapshotDriver()
    var sheet: ScreenSheet?
    var tripsOpen = false
  }

  @MainActor
  private final class Runner {
    let app: AppModel
    let filter: Set<String>
    let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    var log: [String] = []
    var page: Bool { filter.contains("page") }

    init(app: AppModel, filter: Set<String>) {
      self.app = app
      self.filter = filter
    }

    var model: SpectrumModel { app.spectrum }

    func wants(_ name: String) -> Bool {
      let f = filter.subtracting(["page"])
      return f.isEmpty || f.contains(name) || f.contains { name.hasPrefix($0 + "-") }
    }

    /// Runs `setup`, waits, optionally scrolls the frontmost scroll view, and captures.
    func shot(_ name: String, wait: Double = 0.9, scroll: Double? = nil, setup: () -> Void = {}) async {
      guard wants(name) else { return }
      setup()
      try? await Task.sleep(for: .seconds(wait))
      if let scroll {
        Self.scroll(to: scroll)
        try? await Task.sleep(for: .seconds(0.5))
      }
      log.append(page ? renderPage(name) : capture(name))
    }

    func waitForPhase() async {
      // The stage asks for Φ on its next render, then debounces 140 ms.
      try? await Task.sleep(for: .milliseconds(700))
      for _ in 0..<120 where model.phase.computing || model.phase.scene == nil {
        try? await Task.sleep(for: .milliseconds(250))
      }
      try? await Task.sleep(for: .milliseconds(600))
    }

    func reset() {
      var s = SpectraState()
      s.extendedRange = true
      model.state = s
      model.extras = SpectrumExtras()
      model.fullscreen = false
      SpectrumSnapshotDriver.shared.sheet = nil
      SpectrumSnapshotDriver.shared.tripsOpen = false
      app.selectedTab = .spectrum
      app.clock.playing = true
    }

    func all() async {
      reset()
      try? await Task.sleep(for: .seconds(1))

      // 01 Wave scope.
      await shot("scope") { model.select(.scope) }
      await shot("scope-readouts", scroll: 1)
      await shot("scope-medium", scroll: 0) {
        var s = model.state
        s.medium = .glass
        s.sources[0].theta = 45
        s.sources[0].delta = 90
        s.sources[1].enabled = true
        model.state = s
      }

      // 02 Tuner.
      await shot("tuner", scroll: 0.32) {
        reset()
        model.select(.tuner)
      }
      await shot("tuner-aux", scroll: 1)
      await shot("tuner-long", scroll: 0.32) {
        model.setTunerWindow(TunerWindow.full)
        model.tune(lambda: Spectrum.longWaveLandmarks[0].lambda)
      }
      await shot("tuner-thermal", scroll: 0.32) {
        reset()
        model.select(.tuner)
        model.setKind(.thermal)
        model.selectSource(1)
        model.setActiveEnabled(true)
        model.setKind(.pulse)
        model.edit(.lambda(2e-6))
        model.edit(.cycles(2))
      }

      // 03 Matter bench.
      await shot("bench") {
        reset()
        model.select(.bench)
        model.state.bench.focus = .water
      }
      await shot("bench-cards", scroll: 0.55)
      await shot("bench-series", scroll: 1) { model.state.bench.arrangement = .series }
      await shot("bench-oscillator", scroll: 0) {
        model.state.bench.arrangement = .side
        model.state.bench.focus = .oscillator
        model.state.bench.lambda0 = 600e-9
      }
      await shot("bench-zinc-uv") {
        model.state.bench.focus = .zinc
        model.tune(lambda: 200e-9)
      }

      // 04 Decompose.
      await shot("polarization") {
        reset()
        model.select(.decompose)
        model.decomposePage = .polarization
        model.edit(.theta(45))
        model.edit(.delta(60))
      }
      await shot("polarization-aux", scroll: 1)
      await shot("probe", scroll: 0) {
        model.decomposePage = .probe
        model.state.decompose.a0 = 2
      }
      await shot("probe-aux", scroll: 1)
      await shot("fourier", scroll: 0) {
        model.decomposePage = .fourier
        model.state.medium = .glass
        model.setKind(.pulse)
        var s = model.state
        s.sources[1].enabled = true
        s.sources[1].lambda = 450e-9
        model.state = s
      }

      // 04 Decompose → Phase space (Utkarsh's spacetime Wigner).
      if wants("phase") {
        reset()
        model.select(.decompose)
        model.state.medium = .glass
        model.setKind(.pulse)
        model.decomposePage = .phase
        await waitForPhase()
        await shot("phase-one", wait: 0.2, scroll: 0.12)
        var s = model.state
        s.sources[1].enabled = true
        s.sources[1].kind = .pulse
        s.sources[1].lambda = s.sources[0].lambda
        s.sources[1].cycles = s.sources[0].cycles
        model.state = s
        await waitForPhase()
        await shot("phase-two", wait: 0.2, scroll: 0.12)
        model.extras.phase.kFraction = model.phase.startKFraction(spacing: model.extras.phase.spacing) ?? 0.5
        model.extras.phase.kSlice = true
        await waitForPhase()
        await shot("phase-kcolumn", wait: 0.2, scroll: 0.12)
        model.extras.phase.kSlice = false
        await waitForPhase()
        await shot("phase-slices", scroll: 0.5)
        await shot("phase-controls", scroll: 1)
        model.extras.phase.dispersion = .plasma
        await waitForPhase()
        await shot("phase-plasma", wait: 0.2, scroll: 0.12)
        model.extras.phase.dispersion = .medium
      }

      // 05 Spectroscopy lab.
      await shot("lab", scroll: 0) {
        reset()
        model.select(.lab)
        model.selectSample(.hydrogen)
        model.setLabSweep(0.62)
      }
      await shot("lab-readouts", scroll: 1)
      await shot("lab-co2", scroll: 0) {
        model.selectSample(.co2)
        model.setLabSweep(0.55)
      }
      await shot("lab-nmr", scroll: 0) {
        model.selectSample(.nmr)
        model.setLabSweep(0.4)
      }
      await shot("lab-earth", wait: 2.5, scroll: 0) { model.selectEarthMode() }
      await shot("lab-earth-tuned", wait: 1.2, scroll: 0.5) { model.tuneToEarthLine() }

      // Full screen, sheets.
      await shot("fullscreen-tuner", wait: 1.5) {
        reset()
        model.select(.tuner)
        model.fullscreen = true
      }
      await shot("fullscreen-scope", wait: 1.5) {
        model.fullscreen = true
        model.select(.scope)
      }
      model.fullscreen = false
      try? await Task.sleep(for: .seconds(1))
      await shot("dials", wait: 1.5) { SpectrumSnapshotDriver.shared.sheet = .dials }
      await shot("dials-knobs", scroll: 0.3)
      await shot("dials-medium", scroll: 1)
      await shot("dials-trips", scroll: 0) { SpectrumSnapshotDriver.shared.tripsOpen = true }
      SpectrumSnapshotDriver.shared.tripsOpen = false
      SpectrumSnapshotDriver.shared.sheet = nil
      try? await Task.sleep(for: .seconds(1))
      await shot("notes", wait: 1.5) { SpectrumSnapshotDriver.shared.sheet = .notes }
      await shot("notes-phase", scroll: 0.5)
      SpectrumSnapshotDriver.shared.sheet = nil
    }

    func finish() {
      try? log.joined(separator: "\n").write(
        to: folder.appendingPathComponent("spectrum-ui-snapshots.txt"), atomically: true, encoding: .utf8)
    }

    // MARK: Capture

    /// The key window as the screen shows it (Metal layers included).
    func capture(_ name: String) -> String {
      guard
        let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first,
        let window = scene.windows.first(where: \.isKeyWindow) ?? scene.windows.first
      else { return "\(name) NO WINDOW" }
      let format = UIGraphicsImageRendererFormat()
      format.scale = window.traitCollection.displayScale
      format.opaque = true
      let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
        _ = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
      }
      guard let data = image.pngData() else { return "\(name) FAILED" }
      try? data.write(to: folder.appendingPathComponent("spectrum-ui-\(name).png"))
      return "\(name) \(Int(image.size.width))x\(Int(image.size.height)) window"
    }

    /// The content column rendered offscreen (no window server needed).
    func renderPage(_ name: String) -> String {
      let view = SnapshotPage().environment(app)
      let renderer = ImageRenderer(content: view)
      renderer.scale = 3
      renderer.proposedSize = ProposedViewSize(width: 402, height: nil)
      guard let image = renderer.uiImage, let data = image.pngData() else { return "\(name) FAILED" }
      try? data.write(to: folder.appendingPathComponent("spectrum-ui-\(name).png"))
      return "\(name) \(Int(image.size.width))x\(Int(image.size.height)) page"
    }

    // MARK: Scrolling

    /// Scrolls the largest vertical scroll view of the frontmost presented screen to a
    /// fraction of its range.
    static func scroll(to fraction: Double) {
      guard
        let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first,
        let window = scene.windows.first(where: \.isKeyWindow) ?? scene.windows.first,
        var top = window.rootViewController
      else { return }
      while let next = top.presentedViewController, !next.isBeingDismissed { top = next }
      var best: UIScrollView?
      var bestArea: CGFloat = 0
      func visit(_ v: UIView) {
        if let s = v as? UIScrollView, !s.isHidden, s.alpha > 0.01, s.window != nil,
          s.contentSize.height > s.bounds.height + 20
        {
          let frame = s.convert(s.bounds, to: window).intersection(window.bounds)
          let area = frame.isNull ? 0 : frame.width * frame.height
          if area > bestArea {
            bestArea = area
            best = s
          }
        }
        for sub in v.subviews { visit(sub) }
      }
      visit(top.view)
      guard let s = best else { return }
      let minY = -s.adjustedContentInset.top
      let maxY = max(minY, s.contentSize.height - s.bounds.height + s.adjustedContentInset.bottom)
      let y = minY + (maxY - minY) * CGFloat(min(1, max(0, fraction)))
      s.setContentOffset(CGPoint(x: s.contentOffset.x, y: y), animated: false)
    }
  }

  /// The tab's content column as it scrolls: band bar, chips and the instrument panel.
  private struct SnapshotPage: View {
    var body: some View {
      VStack(alignment: .leading, spacing: Theme.stackSpacing) {
        SpectrumBandBar()
        SpectrumInstrumentChips()
        SpectrumInstrumentPanel(fullscreen: false)
      }
      .padding(.horizontal, Theme.gutter)
      .padding(.vertical, 16)
      .frame(width: 402)
      .background(Theme.background)
      .environment(\.spectrumSketchScenes, true)
      .environment(\.colorScheme, .dark)
    }
  }

  /// DEBUG presentation of the Dials and Field notes sheets for the snapshot run.
  struct SpectrumSnapshotSheets: ViewModifier {
    @Environment(AppModel.self) private var app

    func body(content: Content) -> some View {
      let driver = SpectrumSnapshotDriver.shared
      content.sheet(item: Binding(get: { driver.sheet }, set: { driver.sheet = $0 })) { which in
        Group {
          switch which {
          case .dials: SpectrumFieldSheet()
          case .notes: FieldNotesSheet(notes: SpectrumNotes.notes)
          case .settings: SettingsSheet()
          }
        }
        .environment(app)
      }
    }
  }
#endif
