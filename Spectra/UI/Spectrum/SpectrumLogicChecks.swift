import Foundation
import simd

#if DEBUG
  /// Checks of the Spectrum tab's pure logic (`SpectrumLogic.swift`), runnable without a
  /// simulator: the macOS harness (see Docs/notes/spectrum-ui.md) compiles Core, Phase,
  /// `Render/OrbitCamera.swift`, `SpectrumLogic.swift` and this file, and calls `run()`. The
  /// DEBUG app runs them too with `-spectrumChecks` (results in the console and
  /// Documents/spectrum-ui-checks.txt). Physics values come from Core and Phase; these checks
  /// cover the mapping the tab adds on top.
  nonisolated enum SpectrumLogicChecks {
    struct Result: Sendable {
      var passed: [String] = []
      var failed: [String] = []
      var lines: [String] { passed.map { "PASS \($0)" } + failed.map { "FAIL \($0)" } }
    }

    static func run() -> Result {
      var r = Result()
      func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
        if ok { r.passed.append(name) } else { r.failed.append("\(name) \(detail())") }
      }
      func close(_ a: Double, _ b: Double, _ tol: Double) -> Bool { abs(a - b) <= tol * max(1, abs(b)) }

      // MARK: Tuner window
      let full = TunerWindow.full
      check("tuner.full is the long ruler −13…8", full == -13...8, "\(full)")
      check("tuner.web is the web dial −13…3", TunerWindow.web == -13...3, "\(TunerWindow.web)")
      let narrow = TunerWindow.clamp(low: 1, high: 1.5)
      check(
        "tuner.clamp widens to two decades about the center",
        close(narrow.upperBound - narrow.lowerBound, 2, 1e-12) && close((narrow.lowerBound + narrow.upperBound) / 2, 1.25, 1e-12),
        "\(narrow)")
      let edge = TunerWindow.clamp(low: -20, high: -15)
      check("tuner.clamp slides inside the ruler", edge == -13 ... -8, "\(edge)")
      let wide = TunerWindow.clamp(low: -40, high: 40)
      check("tuner.clamp caps at the whole ruler", wide == full, "\(wide)")
      let flipped = TunerWindow.clamp(low: 2, high: -6)
      check("tuner.clamp orders its edges", flipped == -6...2, "\(flipped)")
      check("tuner.clamp rejects NaN", TunerWindow.clamp(low: .nan, high: 1) == TunerWindow.web)
      let w = -10.0...0.0
      let anchor = -4.0
      let z = TunerWindow.zoomed(w, factor: 2, anchor: anchor)
      let before = (anchor - w.lowerBound) / (w.upperBound - w.lowerBound)
      let after = (anchor - z.lowerBound) / (z.upperBound - z.lowerBound)
      check(
        "tuner.zoom ×2 halves the span and keeps the anchor in place",
        close(z.upperBound - z.lowerBound, 5, 1e-12) && close(after, before, 1e-12), "\(z)")
      let tight = TunerWindow.zoomed(-4 ... -2, factor: 10, anchor: -3)
      check(
        "tuner.zoom stops at two decades", close(tight.lowerBound, -4, 1e-12) && close(tight.upperBound, -2, 1e-12), "\(tight)")
      check("tuner.zoom rejects a bad factor", TunerWindow.zoomed(w, factor: .nan, anchor: 0) == w)
      check("tuner.follow leaves a visible cursor alone", TunerWindow.following(w, lg: -5) == w)
      let f1 = TunerWindow.following(TunerWindow.web, lg: log10(Spectrum.longWaveLandmarks[0].lambda))
      check(
        "tuner.follow brings Earth-field NMR (140.8 km) into view",
        f1.contains(log10(Spectrum.longWaveLandmarks[0].lambda)) && close(f1.upperBound - f1.lowerBound, 16, 1e-12), "\(f1)")

      // MARK: Earth-field axis (Core supplies the line)
      let line50 = Samples.earthFieldLarmor(b0: 50e-6)
      check("earth.line at 50 µT is 2,128.82 Hz (Core, shielded γ′ₚ)", close(line50, 2128.82, 1e-5), "\(line50)")
      let lo = Samples.earthFieldLarmor(b0: EarthFieldAxis.fieldRange.lowerBound * 1e-6)
      let hi = Samples.earthFieldLarmor(b0: EarthFieldAxis.fieldRange.upperBound * 1e-6)
      check(
        "earth.axis holds every Earth field (25–65 µT)",
        EarthFieldAxis.fraction(of: lo) > 0 && EarthFieldAxis.fraction(of: hi) < 1, "\(lo) \(hi)")
      var roundTrip = true
      for u in stride(from: 0.0, through: 1, by: 0.125) where !close(EarthFieldAxis.fraction(of: EarthFieldAxis.frequency(at: u)), u, 1e-12) {
        roundTrip = false
      }
      check("earth.axis fraction ∘ frequency = identity", roundTrip)
      let u50 = EarthFieldAxis.fraction(of: line50)
      check(
        "earth.cursor on the line probes λ = 140.83 km",
        close(EarthFieldAxis.lambda(at: u50), Samples.earthFieldLambda(b0: 50e-6), 1e-9)
          && close(EarthFieldAxis.lambda(at: u50), 140.83e3, 1e-4), "\(EarthFieldAxis.lambda(at: u50))")
      check("earth.cursor clamps to the axis", EarthFieldAxis.frequency(at: 2) == EarthFieldAxis.to && EarthFieldAxis.frequency(at: -1) == EarthFieldAxis.from)

      // MARK: Phase-space request
      var s = SpectraState()
      s.extendedRange = true
      let settings = PhaseSpaceSettings()
      let one = PhaseSpaceRequestBuilder.build(state: s, settings: settings)
      check(
        "phase.plane wave A → one 10-cycle packet with a note",
        one.request.packets.count == 1 && one.sources == [0] && one.notes.contains { $0.contains("10-cycle") }, "\(one.notes)")
      var thermal = s
      thermal.sources[1].enabled = true
      thermal.sources[1].kind = .thermal
      let th = PhaseSpaceRequestBuilder.build(state: thermal, settings: settings)
      check(
        "phase.thermal light is left out with a note",
        th.request.packets.count == 1 && th.notes.contains { $0.contains("thermal") }, "\(th.notes)")
      var two = s
      two.medium = .glass
      two.sources[0].kind = .pulse
      two.sources[1].enabled = true
      two.sources[1].kind = .pulse
      two.sources[1].lambda = two.sources[0].lambda
      two.sources[1].cycles = two.sources[0].cycles
      let pair = PhaseSpaceRequestBuilder.build(state: two, settings: settings)
      let centers = pair.request.packets.map(\.center)
      check(
        "phase.two pulses sit ±spacing/2 about the center",
        centers.count == 2 && close(centers[0], -settings.spacing / 2, 1e-12) && close(centers[1], settings.spacing / 2, 1e-12),
        "\(centers)")
      var guide = settings
      guide.dispersion = .waveguide
      guide.cutoffRatio = 0.6
      var below = s
      below.sources[1].enabled = true
      below.sources[1].lambda = 2 * s.sources[0].lambda
      let cut = PhaseSpaceRequestBuilder.build(state: below, settings: guide)
      check(
        "phase.waveguide drops a source below cut-off with a note",
        cut.request.packets.count == 1 && cut.notes.contains { $0.contains("cut-off") }, "\(cut.notes)")
      var plasma = settings
      plasma.dispersion = .plasma
      plasma.plasmaRatio = 0.5
      if case .plasma(let fp) = PhaseSpaceRequestBuilder.dispersion(state: s, settings: plasma) {
        check("phase.plasma f_p = ratio × ν_ref", close(fp, 0.5 * Spectrum.frequency(s.sources[0].lambda), 1e-12), "\(fp)")
      } else {
        check("phase.plasma f_p = ratio × ν_ref", false, "not a plasma")
      }

      // MARK: Φ scenes (Phase engine, as the stage computes them)
      var single = s
      single.medium = .glass
      single.sources[0].kind = .pulse
      let sceneOne = Phase.phaseSpaceScene(PhaseSpaceRequestBuilder.build(state: single, settings: settings).request)
      let ratioOne = sceneOne.wigner.maxValue > 0 ? sceneOne.wigner.minValue / sceneOne.wigner.maxValue : -1
      check("phase.one pulse in glass is CONSISTENT", sceneOne.report.status == .consistent, "\(sceneOne.report.status)")
      check("phase.one Gaussian stays ≥ 0 (Hudson; ripple < 2 %)", ratioOne > -0.02, "\(ratioOne)")
      let scenePair = Phase.phaseSpaceScene(pair.request)
      let ratioPair = scenePair.wigner.maxValue > 0 ? scenePair.wigner.minValue / scenePair.wigner.maxValue : 0
      check("phase.two pulses show a negative cross term", ratioPair < -0.02, "\(ratioPair)")
      check("phase.two pulses are CONSISTENT", scenePair.report.status == .consistent, "\(scenePair.report.status)")

      // MARK: Φ cube points
      let points = WignerCubePoints.extract(scenePair.wigner.kIntegrated, budget: 4000)
      let inside = points.allSatisfy { abs($0.x) <= 1 && abs($0.y) <= 1 && abs($0.z) <= 1 && abs($0.w) <= 1 }
      check("cube.points stay inside the budget", !points.isEmpty && points.count <= 4000, "\(points.count)")
      check("cube.points lie in the −1…1 cube", inside)
      check("cube.points skip cells below 4 % of the peak", points.allSatisfy { abs($0.w) >= 0.04 })
      check(
        "cube.points carry both signs for two packets",
        points.contains { $0.w > 0.5 } && points.contains { $0.w < 0 }, "min \(points.map(\.w).min() ?? 0)")

      var keep = settings
      keep.kSlice = true
      let kept = Phase.phaseSpaceScene(PhaseSpaceRequestBuilder.build(state: two, settings: keep).request).wigner
      let globalPeak = max(abs(kept.minValue), abs(kept.maxValue))
      if let edge = kept.kSliceCube(column: 0) {
        let own = WignerCubePoints.extract(edge, budget: 4000)
        let scaled = WignerCubePoints.extract(edge, budget: 4000, peak: globalPeak)
        check(
          "cube.a k column far from the packets stays dark on the whole-Φ scale",
          scaled.count < 10 && own.count > scaled.count, "own \(own.count) scaled \(scaled.count)")
      } else {
        check("cube.a k column far from the packets stays dark on the whole-Φ scale", false, "no k column")
      }

      if let c = Phase.phaseSpaceScene(PhaseSpaceRequestBuilder.build(state: two, settings: keep).request).carriers.first ?? nil {
        // Two in-phase packets d apart: the cross term goes as cos((k − k₀) d), most negative at k₀ + π/d.
        let dip = kept.kSliceCube(column: kept.kAxis.nearestIndex(c.x + Double.pi / settings.spacing))
        let atCarrier = kept.kSliceCube(column: kept.kAxis.nearestIndex(c.x))
        let negDip = dip.map { WignerCubePoints.extract($0, peak: globalPeak).filter { $0.w < 0 }.count } ?? 0
        let negCarrier = atCarrier.map { WignerCubePoints.extract($0, peak: globalPeak).filter { $0.w < 0 }.count } ?? 0
        check(
          "cube.the k column at k̂₀ + π/d shows the negative cross term (none at k̂₀)", negDip > 100 && negCarrier == 0,
          "dip \(negDip) carrier \(negCarrier)")
      } else {
        check("cube.the k column at k̂₀ + π/d shows the negative cross term (none at k̂₀)", false, "no carrier")
      }

      // MARK: The device grid (48) for a plane wave
      for medium in [Matter.Medium.vacuum, .glass, .water] {
        var p = s
        p.medium = medium
        var request = PhaseSpaceRequestBuilder.build(state: p, settings: settings).request
        request.gridSize = 48
        let status = Phase.phaseSpaceScene(request).report.status
        check("phase.plane wave reads CONSISTENT on the 48-point grid (\(medium))", status == .consistent, "\(status)")
      }

      // MARK: Probe charge drawing geometry
      var elliptical = WaveSource()
      elliptical.theta = 45
      elliptical.delta = 60
      let probeTraj = SpectrumDisplay.probeTrajectory(elliptical, a0: 2, mode: .both)
      let probe = ProbeGeometry(probeTraj, thetaDeg: elliptical.theta, mode: .both)
      if let first = probe.inset.first, let last = probe.inset.last {
        check(
          "probe.drift inset is a closed orbit for elliptical light (θ 45°, δ 60°)",
          simd_length(first - last) < 0.02 && probe.inset.allSatisfy { abs($0.x) <= 1 + 1e-9 && abs($0.y) <= 1 + 1e-9 },
          "gap \(simd_length(first - last))")
      } else {
        check("probe.drift inset is a closed orbit for elliptical light (θ 45°, δ 60°)", false, "empty inset")
      }
      let electricOnly = ProbeGeometry(
        SpectrumDisplay.probeTrajectory(elliptical, a0: 2, mode: .electric), thetaDeg: elliptical.theta, mode: .electric)
      check(
        "probe.E only has no forward drift and no inset",
        electricOnly.inset.isEmpty && electricOnly.zMax < 1e-6 && electricOnly.transverse.count == electricOnly.points.count,
        "zMax \(electricOnly.zMax)")

      // MARK: Persistence (Spectra.spectrum.v1)
      var extras = SpectrumExtras()
      extras.tunerLow = -2
      extras.tunerHigh = 6
      extras.labEarth = true
      extras.phase.dispersion = .plasma
      extras.phase.chirp = [0.1, -0.2, 0.3]
      let saved = SpectrumSaved(state: two, extras: extras)
      if let data = try? JSONEncoder().encode(saved), let back = try? JSONDecoder().decode(SpectrumSaved.self, from: data) {
        // Core's decoder re-sanitizes λ through log₁₀ (JS parity), so λ comes back within an ulp or two.
        let sourcesMatch = zip(back.state.sources, two.sources).allSatisfy { a, b in
          a.kind == b.kind && a.enabled == b.enabled && a.cycles == b.cycles && close(a.lambda, b.lambda, 1e-13)
        }
        check(
          "persist.round trip keeps state and extras",
          sourcesMatch && back.state.medium == two.medium && back.state.extendedRange && back.extras == extras)
      } else {
        check("persist.round trip keeps state and extras", false, "encode/decode threw")
      }
      let bad = Data(
        #"{"state":{"medium":"glass"},"extras":{"tunerLow":"x","tunerHigh":-12.5,"earthSweep":7,"phase":{"plasmaRatio":9,"chirp":[1,2],"spacing":-3}}}"#
          .utf8)
      if let back = try? JSONDecoder().decode(SpectrumSaved.self, from: bad) {
        let e = back.extras
        check(
          "persist.lenient decode keeps defaults and clamps",
          e.tunerHigh - e.tunerLow >= TunerWindow.minimumSpan && e.earthSweep == 1 && e.phase.plasmaRatio == PhaseSpaceSettings.ratioRange.upperBound
            && e.phase.chirp == [0, 0, 0] && e.phase.spacing == 0,
          "\(e)")
      } else {
        check("persist.lenient decode keeps defaults and clamps", false, "decode threw")
      }
      if let back = try? JSONDecoder().decode(SpectrumSaved.self, from: Data("[]".utf8)) {
        check("persist.garbage gives the defaults", back.extras == SpectrumExtras())
      } else {
        check("persist.garbage gives the defaults", true)
      }
      return r
    }
  }
#endif
