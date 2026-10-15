import SwiftUI
import UIKit

#if DEBUG
  /// DEBUG only: `-spinSnapshots` walks the Spin tab through its views, panels and sheets (the
  /// same model calls its controls make) and writes PNGs of the key window, Metal scene
  /// included, to the app's Documents folder as `spin-ui-<name>.png`, plus a log of what each
  /// shot showed (`spin-ui-snapshots.txt`). `-spinSnapshots=<name>,…` runs only those shots
  /// (a name also selects every shot it prefixes); `dtxl` and `rm` are the short sets for a
  /// launch at an accessibility text size or with Reduce Motion on. It exists because
  /// `simctl io screenshot` hangs when many simulators share the machine (the Spectrum tab's
  /// `SpectrumSnapshots` does the same).
  @MainActor
  enum SpinSnapshots {
    static var argument: String? {
      ProcessInfo.processInfo.arguments.first { $0.hasPrefix("-spinSnapshots") }
    }
    static var requested: Bool { argument != nil }

    static var filter: Set<String> {
      guard let a = argument, let eq = a.firstIndex(of: "=") else { return [] }
      return Set(a[a.index(after: eq)...].split(separator: ",").map(String.init))
    }

    static func run(app: AppModel) {
      Task { @MainActor in
        try? await Task.sleep(for: .seconds(3))
        let runner = SpinSnapshotRunner(app: app, filter: filter)
        await runner.all()
        runner.finish()
      }
    }
  }

  /// Sheets for the snapshot run (the foundation's `InstrumentScreen` keeps its own sheet
  /// state private): SpinTab presents the same Dials and Field notes content from here.
  @Observable @MainActor
  final class SpinSnapshotDriver {
    static let shared = SpinSnapshotDriver()
    var sheet: ScreenSheet?
  }

  @MainActor
  private final class SpinSnapshotRunner {
    let app: AppModel
    let filter: Set<String>
    let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    var log: [String] = []

    init(app: AppModel, filter: Set<String>) {
      self.app = app
      self.filter = filter
    }

    var model: SpinModel { app.spin }
    var driver: SpinSnapshotDriver { .shared }

    func wants(_ name: String) -> Bool {
      if filter.contains("dtxl") { return name.hasPrefix("dtxl-") }
      if filter.contains("rm") { return name.hasPrefix("rm-") }
      if name.hasPrefix("dtxl-") || name.hasPrefix("rm-") { return false }
      return filter.isEmpty || filter.contains(name) || filter.contains { name.hasPrefix($0 + "-") }
    }

    /// Runs `setup`, scrolls to a panel anchor (or a fraction of the frontmost sheet), waits
    /// and captures.
    func shot(
      _ name: String, anchor: String? = nil, sheetScroll: Double? = nil, wait: Double = 1.6,
      setup: () -> Void = {}
    ) async {
      guard wants(name) else { return }
      setup()
      if let anchor { model.scroll(to: anchor) }
      try? await Task.sleep(for: .seconds(wait))
      if let sheetScroll {
        Self.scrollSheet(to: sheetScroll)
        try? await Task.sleep(for: .seconds(0.6))
      }
      log.append(capture(name) + " · " + summary())
    }

    func reset() {
      driver.sheet = nil
      app.selectedTab = .spin
      app.clock.playing = true
      var s = SpinSaved()
      s.view = model.saved.view
      model.saved = s
      model.resetMagnetization(.protonWater)
      model.resetMagnetization(.electron)
    }

    func all() async {
      reset()
      try? await Task.sleep(for: .seconds(1))

      // Gyroscope.
      await shot("gyroscope", anchor: "top", wait: 3) { model.select(.gyroscope) }
      await shot("gyroscope-dials", anchor: "dials")
      await shot("gyroscope-readouts", anchor: "readouts")
      await shot("gyroscope-tip", anchor: "tip", wait: 2.5)
      await shot("gyroscope-field", anchor: "field")
      // The Free gyroscope trip spins at 6000 rpm: its nod (about 77 Hz) widens the tip spectrum.
      await shot("gyroscope-free-tip", anchor: "tip", wait: 3) {
        if let free = HeavyTopPreset.all.first(where: { $0.id == "free" }) { model.apply(preset: free) }
        model.kickRotor()
      }
      await shot("gyroscope-trip", anchor: "top", wait: 3) {
        if let trip = HeavyTopPreset.all.first(where: { $0.resonance }) { model.apply(preset: trip) }
      }

      // Compare.
      await shot("compare", anchor: "top", wait: 3) {
        reset()
        model.select(.compare)
      }
      await shot("compare-side", anchor: "readouts")

      // Proton.
      await shot("proton", anchor: "top", wait: 3) {
        model.select(.proton)
        model.runSequence(.protonWater)
      }
      await shot("proton-drive", anchor: "drive")
      await shot("proton-hear", anchor: "hear")
      await shot("proton-readouts", anchor: "readouts")
      await shot("proton-fid", anchor: "fid", wait: 2.2) { model.runSequence(.protonWater) }
      await shot("proton-wigner", anchor: "wigner", wait: 2.2)
      await shot("proton-echo", anchor: "fid", wait: 2.4) {
        model.setBench(.protonWater) {
          $0.sequence = .echo
          $0.gradient = 3e-6
        }
        model.runSequence(.protonWater)
      }
      // Inversion recovery records from its read pulse (π/2 at Tᵢ = 0.6 s): the held FID starts
      // at |1 − 2e^(−0.6/2.5)| = 0.57 of M₀.
      await shot("proton-inversion", anchor: "fid", wait: 2.6) {
        model.setBench(.protonWater) {
          $0.sequence = .inversion
          $0.echoTau = 0.6
          $0.gradient = 1e-6
        }
        model.runSequence(.protonWater)
      }
      // A late echo (τ 0.9 s, echo at 1.8 s) is recorded from 1.3 s, so its top sits mid-record.
      await shot("proton-echo-late", anchor: "fid", wait: 3.4) {
        model.setBench(.protonWater) {
          $0.sequence = .echo
          $0.echoTau = 0.9
          $0.gradient = 3e-6
        }
        model.runSequence(.protonWater)
      }
      // TR 0.5 s under a 1 s inversion time: the repeat is stretched to fit the sequence.
      await shot("proton-tr-stretched", anchor: "drive", wait: 3) {
        model.setBench(.protonWater) {
          $0.sequence = .inversion
          $0.echoTau = 1
          $0.gradient = 1e-6
          $0.repetition = 0.5
        }
        model.runSequence(.protonWater)
      }
      await shot("proton-lab", anchor: "top", wait: 2) {
        model.setBench(.protonWater) {
          $0.sequence = .fid
          $0.echoTau = 0.1
          $0.gradient = 1e-6
          $0.repetition = 3
        }
        model.saved.rotatingFrame = false
        model.runSequence(.protonWater)
      }
      await shot("chirp-wigner", anchor: "wigner", wait: 3) {
        model.saved.rotatingFrame = true
        // A uniform field, so the chirp lasts T₂ instead of dephasing in 164 ms.
        model.setBench(.protonWater) {
          $0.ramp = 1.5e-6
          $0.gradient = 0
        }
        model.runSequence(.protonWater)
      }
      await shot("chirp-fid", anchor: "fid", wait: 0.8)
      await shot("proton-cw", anchor: "top", wait: 2.5) {
        model.setBench(.protonWater) {
          $0.ramp = 0
          $0.gradient = 1e-6
          $0.continuous = true
          $0.offsetHz = 10
        }
      }
      await shot("proton-dial", anchor: "field", wait: 2) {
        model.setBench(.protonWater) {
          $0.continuous = false
          $0.offsetHz = 0
        }
        model.saved.fieldSource = .dial
        model.fieldTesla = 1.5
      }
      model.saved.fieldSource = .live
      model.fieldTesla = EarthField.typicalField

      // Electron.
      await shot("electron", anchor: "top", wait: 3) {
        model.select(.electron)
        model.runSequence(.electron)
      }
      await shot("electron-hear", anchor: "hear")
      await shot("electron-readouts", anchor: "readouts")
      await shot("electron-fid", anchor: "fid", wait: 2.2)
      await shot("loop", anchor: "loop")

      // Sheets.
      await shot("dials-gyroscope", anchor: "top", wait: 1.8) {
        model.select(.gyroscope)
        driver.sheet = .dials
      }
      await shot("dials-gyroscope-more", sheetScroll: 1, wait: 0.4)
      await shot("dials-proton", wait: 1.8) {
        driver.sheet = nil
        model.select(.proton)
        Task { @MainActor in
          try? await Task.sleep(for: .seconds(0.8))
          SpinSnapshotDriver.shared.sheet = .dials
        }
      }
      await shot("dials-proton-relax", sheetScroll: 0.5, wait: 0.4)
      await shot("dials-proton-display", sheetScroll: 1, wait: 0.4)
      // Compare's sheet: the carrier switch, no alignment (Compare's small spheres never tilt).
      await shot("dials-compare", wait: 1.8) {
        driver.sheet = nil
        model.select(.compare)
        Task { @MainActor in
          try? await Task.sleep(for: .seconds(0.8))
          SpinSnapshotDriver.shared.sheet = .dials
        }
      }
      await shot("notes", wait: 1.8) {
        driver.sheet = nil
        Task { @MainActor in
          try? await Task.sleep(for: .seconds(0.8))
          SpinSnapshotDriver.shared.sheet = .notes
        }
      }
      await shot("notes-wigner", sheetScroll: 0.85, wait: 0.4)
      driver.sheet = nil
      try? await Task.sleep(for: .seconds(1))

      // Hand-off: the Live tab's "Hear Earth-field NMR" lands on the proton bench.
      if wants("handoff-nmr") {
        reset()
        model.select(.gyroscope)
        app.selectedTab = .live
        try? await Task.sleep(for: .seconds(1.5))
        let f = SpinSpecies.protonWater.larmorHz(field: model.fieldInUse)
        app.focus(
          SpectrumMarker(
            id: "live.nmr", label: "Earth-field NMR \(SpectraFormat.frequency(f, digits: 5))", frequency: f,
            provenance: .sim, tab: .spin))
        await shot("handoff-nmr", wait: 2.5)
        // The same hand-off again, with an identical marker: it must land on the proton bench
        // at Hear it a second time (Observation skips setting an equal value).
        model.select(.gyroscope)
        model.scroll(to: "top")
        try? await Task.sleep(for: .seconds(1))
        app.selectedTab = .live
        try? await Task.sleep(for: .seconds(1.5))
        app.focus(
          SpectrumMarker(
            id: "live.nmr", label: "Earth-field NMR \(SpectraFormat.frequency(f, digits: 5))", frequency: f,
            provenance: .sim, tab: .spin))
        await shot("handoff-nmr-again", wait: 2.5)
      }

      // Compare in the lab frame: the spins' own mapping chip (SPINS ALIASED).
      await shot("compare-lab", anchor: "top", wait: 2.5) {
        reset()
        model.select(.compare)
        model.saved.rotatingFrame = false
      }
      if wants("compare-lab") { model.saved.rotatingFrame = true }

      // Accessibility XL Dynamic Type (launched with an accessibility content size).
      await shot("dtxl-gyroscope", anchor: "top", wait: 3) {
        reset()
        model.select(.gyroscope)
      }
      await shot("dtxl-gyroscope-readouts", anchor: "readouts")
      await shot("dtxl-proton-drive", anchor: "drive", wait: 2) { model.select(.proton) }
      await shot("dtxl-proton-hear", anchor: "hear")
      await shot("dtxl-proton-readouts", anchor: "readouts")
      await shot("dtxl-electron-readouts", anchor: "readouts", wait: 2) { model.select(.electron) }
      await shot("dtxl-compare-top", anchor: "top", wait: 2.5) { model.select(.compare) }
      await shot("dtxl-compare", anchor: "readouts", wait: 2)
      await shot("dtxl-loop", anchor: "loop")
      await shot("dtxl-dials", wait: 1.8) {
        model.select(.proton)
        driver.sheet = .dials
      }
      driver.sheet = nil

      // Reduce Motion (launched with the accessibility setting on).
      await shot("rm-gyroscope", anchor: "top", wait: 3) {
        reset()
        model.select(.gyroscope)
      }
      await shot("rm-proton-lab", anchor: "top", wait: 2.5) {
        model.select(.proton)
        model.saved.rotatingFrame = false
        model.runSequence(.protonWater)
      }
      if wants("rm-gyroscope") { model.saved.rotatingFrame = true }
    }

    func finish() {
      log.append("done")
      try? log.joined(separator: "\n").write(
        to: folder.appendingPathComponent("spin-ui-snapshots.txt"), atomically: true, encoding: .utf8)
    }

    private func summary() -> String {
      let r = model.readings
      let p = r.proton
      return
        "view \(model.saved.view.rawValue) visible \(model.isVisible) running \(model.running) field \(SpectraFormat.si(r.field, unit: "T")) (\(r.fieldProvenance.rawValue)) "
        + "fL \(SpectraFormat.frequency(p.larmorHz, digits: 5)) M⊥ \(SpectraFormat.significant(p.mPerp, 2)) "
        + "rpm \(Int(r.gyro?.rpm ?? 0)) Ωp \(SpectraFormat.frequency(abs(r.gyro?.precessionHz ?? 0))) "
        + "spectrum peak \(model.spectrum.map { SpectraFormat.frequency($0.peakFrequency) } ?? "none") wigner \(model.wigner != nil) streams \(app.streams.streams(in: StreamGroup.spin).map(\.id.rawValue)) "
        + "reduceMotion \(UIAccessibility.isReduceMotionEnabled) size \(UIApplication.shared.preferredContentSizeCategory.rawValue)"
    }

    // MARK: Capture

    /// The key window as the screen shows it (Metal layers and sheets included).
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
      try? data.write(to: folder.appendingPathComponent("spin-ui-\(name).png"))
      return "\(name) \(Int(image.size.width))x\(Int(image.size.height))"
    }

    /// Scrolls the largest vertical scroll view of the frontmost presented controller (a sheet)
    /// to a fraction of its range.
    static func scrollSheet(to fraction: Double) {
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

  /// SpinTab's snapshot-only sheet: the same Dials and Field notes content the top bar opens.
  struct SpinSnapshotSheets: ViewModifier {
    let model: SpinModel
    @Bindable var driver = SpinSnapshotDriver.shared
    @Environment(AppModel.self) private var app

    func body(content: Content) -> some View {
      content.sheet(item: $driver.sheet) { which in
        Group {
          switch which {
          case .dials: SpinDialsSheet(model: model)
          case .notes: FieldNotesSheet(notes: SpinNotes.notes)
          case .settings: SettingsSheet()
          }
        }
        .environment(app)
      }
    }
  }
#endif
