import SwiftUI
import UIKit

extension View {
  /// Orbitals' canvas gestures on a 3D (or 2D) scene: one-finger drag rotates (or pans with
  /// `panWithOneFinger`), two-finger drag pans, pinch zooms about the fingers, double-tap
  /// aligns. Every gesture has an alternative: VoiceOver adjustable (yaw ±5°) and named
  /// actions (zoom, move, reset), arrow keys and +/−, and `CameraControls` buttons.
  ///
  /// ```swift
  /// MetalCanvas(scene: scene).orbitGestures($scene.camera, home: WaveScene.home)
  /// ```
  func orbitGestures(
    _ camera: Binding<OrbitCamera>, home: OrbitCamera, panWithOneFinger: Bool = false,
    label: String = "3D view"
  ) -> some View {
    modifier(OrbitGestureModifier(camera: camera, home: home, panWithOneFinger: panWithOneFinger, label: label))
  }
}

private struct OrbitGestureModifier: ViewModifier {
  @Binding var camera: OrbitCamera
  let home: OrbitCamera
  let panWithOneFinger: Bool
  let label: String
  @FocusState private var focused: Bool

  func body(content: Content) -> some View {
    content
      .overlay { OrbitGestureSurface(camera: $camera, home: home, panWithOneFinger: panWithOneFinger) }
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(label)
      .accessibilityValue(camera.accessibilityDescription)
      .accessibilityHint("Swipe up or down to turn the view. Use the actions to zoom, move or reset.")
      .accessibilityAdjustableAction { direction in
        switch direction {
        case .increment: camera.setAngles(yaw: camera.yaw + 5, pitch: camera.pitch)
        case .decrement: camera.setAngles(yaw: camera.yaw - 5, pitch: camera.pitch)
        @unknown default: break
        }
        Haptics.shared.selection()
      }
      .accessibilityAction(named: "Zoom in") { camera.zoom(by: 1.25) }
      .accessibilityAction(named: "Zoom out") { camera.zoom(by: 0.8) }
      .accessibilityAction(named: "Move left") { camera.pan(dx: -0.1, dy: 0) }
      .accessibilityAction(named: "Move right") { camera.pan(dx: 0.1, dy: 0) }
      .accessibilityAction(named: "Move up") { camera.pan(dx: 0, dy: -0.1) }
      .accessibilityAction(named: "Move down") { camera.pan(dx: 0, dy: 0.1) }
      .accessibilityAction(named: "Reset camera") { camera.reset(to: home) }
      .focusable()
      .focused($focused)
      .onKeyPress(.leftArrow) { camera.setAngles(yaw: camera.yaw - 5, pitch: camera.pitch); return .handled }
      .onKeyPress(.rightArrow) { camera.setAngles(yaw: camera.yaw + 5, pitch: camera.pitch); return .handled }
      .onKeyPress(.upArrow) { camera.setAngles(yaw: camera.yaw, pitch: camera.pitch + 5); return .handled }
      .onKeyPress(.downArrow) { camera.setAngles(yaw: camera.yaw, pitch: camera.pitch - 5); return .handled }
      .onKeyPress(characters: CharacterSet(charactersIn: "+=-")) { press in
        camera.zoom(by: press.characters == "-" ? 0.8 : 1.25)
        return .handled
      }
  }
}

/// Glass buttons for the camera (the non-gesture alternative): zoom out, zoom in, align.
/// Identifiers `<id>-zoom-out`, `<id>-zoom-in`, `<id>-align`.
struct CameraControls: View {
  @Binding var camera: OrbitCamera
  let home: OrbitCamera
  var id = "camera"

  var body: some View {
    GlassEffectContainer(spacing: 8) {
      HStack(spacing: 8) {
        button("Zoom out", "minus.magnifyingglass", "\(id)-zoom-out") { camera.zoom(by: 0.8) }
        button("Zoom in", "plus.magnifyingglass", "\(id)-zoom-in") { camera.zoom(by: 1.25) }
        button("Align", "viewfinder", "\(id)-align") { camera.reset(to: home) }
      }
    }
  }

  private func button(_ title: String, _ symbol: String, _ identifier: String, action: @escaping () -> Void)
    -> some View
  {
    Button {
      Haptics.shared.tap()
      action()
    } label: {
      Image(systemName: symbol).frame(width: 20, height: 20)
    }
    .buttonStyle(.glass)
    .buttonBorderShape(.circle)
    .accessibilityLabel(title)
    .accessibilityIdentifier(identifier)
  }
}

/// A transparent UIKit touch surface (Orbitals `OrbitCanvasGestures`): one pan recognizer
/// for one and two fingers (a separate one-finger recognizer would stop pinch from
/// beginning), a pinch, and a double tap. The Metal view underneath never takes touches.
struct OrbitGestureSurface: UIViewRepresentable {
  @Binding var camera: OrbitCamera
  let home: OrbitCamera
  var panWithOneFinger = false

  func makeCoordinator() -> Coordinator { Coordinator(camera: $camera, home: home, panWithOneFinger: panWithOneFinger) }

  func makeUIView(context: Context) -> UIView {
    let surface = UIView()
    surface.backgroundColor = .clear
    surface.isOpaque = false
    surface.isMultipleTouchEnabled = true
    surface.isAccessibilityElement = false
    surface.accessibilityElementsHidden = true
    context.coordinator.install(on: surface)
    return surface
  }

  func updateUIView(_ view: UIView, context: Context) {
    context.coordinator.camera = $camera
    context.coordinator.home = home
    context.coordinator.panWithOneFinger = panWithOneFinger
  }

  static func dismantleUIView(_ view: UIView, coordinator: Coordinator) {
    coordinator.cancel()
    for recognizer in view.gestureRecognizers ?? [] { view.removeGestureRecognizer(recognizer) }
  }

  final class Coordinator: NSObject, UIGestureRecognizerDelegate {
    var camera: Binding<OrbitCamera>
    var home: OrbitCamera
    var panWithOneFinger: Bool
    private weak var surface: UIView?
    private weak var panRecognizer: UIPanGestureRecognizer?
    private weak var pinchRecognizer: UIPinchGestureRecognizer?
    private var previousTouchCount = 0
    private var multitouchSequence = false
    private var pinchLocation: CGPoint?
    private var adjustments: Set<Adjustment> = []

    private enum Adjustment: Hashable { case pan, pinch }

    init(camera: Binding<OrbitCamera>, home: OrbitCamera, panWithOneFinger: Bool) {
      self.camera = camera
      self.home = home
      self.panWithOneFinger = panWithOneFinger
    }

    func install(on view: UIView) {
      surface = view
      let pan = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))
      pan.minimumNumberOfTouches = 1
      pan.maximumNumberOfTouches = 2
      pan.delegate = self
      let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinched(_:)))
      pinch.delegate = self
      let reset = UITapGestureRecognizer(target: self, action: #selector(doubleTapped(_:)))
      reset.numberOfTapsRequired = 2
      reset.delegate = self
      view.addGestureRecognizer(pan)
      view.addGestureRecognizer(pinch)
      view.addGestureRecognizer(reset)
      panRecognizer = pan
      pinchRecognizer = pinch
    }

    func cancel() {
      for recognizer in surface?.gestureRecognizers ?? [] {
        recognizer.isEnabled = false
        recognizer.isEnabled = true
      }
      if !adjustments.isEmpty { Haptics.shared.endAdjustment() }
      adjustments.removeAll()
      previousTouchCount = 0
      multitouchSequence = false
      pinchLocation = nil
    }

    func gestureRecognizer(
      _ gestureRecognizer: UIGestureRecognizer,
      shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
      (gestureRecognizer === panRecognizer && otherGestureRecognizer === pinchRecognizer)
        || (gestureRecognizer === pinchRecognizer && otherGestureRecognizer === panRecognizer)
    }

    private var pinching: Bool {
      pinchRecognizer?.state == .began || pinchRecognizer?.state == .changed
    }

    private func begin(_ adjustment: Adjustment) {
      if adjustments.isEmpty { Haptics.shared.beginAdjustment() }
      adjustments.insert(adjustment)
    }

    private func end(_ adjustment: Adjustment) {
      guard adjustments.remove(adjustment) != nil else { return }
      if adjustments.isEmpty { Haptics.shared.endAdjustment() }
    }

    @objc private func panned(_ recognizer: UIPanGestureRecognizer) {
      guard let surface, surface.bounds.width > 0, surface.bounds.height > 0 else { return }
      switch recognizer.state {
      case .began:
        begin(.pan)
        previousTouchCount = recognizer.numberOfTouches
        multitouchSequence = previousTouchCount > 1 || pinching
        recognizer.setTranslation(.zero, in: surface)
      case .changed:
        let count = recognizer.numberOfTouches
        let delta = recognizer.translation(in: surface)
        recognizer.setTranslation(.zero, in: surface)
        if count > 1 { multitouchSequence = true }
        // Adding or lifting a finger moves the centroid: rebase that event, and never
        // resume rotation with a leftover finger after a pinch.
        guard count == previousTouchCount else {
          previousTouchCount = count
          return
        }
        guard !pinching else { return }
        if count == 2 || (count == 1 && panWithOneFinger && !multitouchSequence) {
          camera.wrappedValue.pan(dx: Double(delta.x / surface.bounds.width), dy: Double(delta.y / surface.bounds.height))
          let c = camera.wrappedValue
          Haptics.shared.detent(normalized: ((abs(delta.x) >= abs(delta.y) ? c.panX : c.panY) + 1.5) / 3)
        } else if count == 1 && !multitouchSequence {
          camera.wrappedValue.rotate(dx: Double(delta.x), dy: Double(delta.y))
          let c = camera.wrappedValue
          Haptics.shared.detent(normalized: abs(delta.x) >= abs(delta.y) ? (c.yaw + 180) / 360 : (c.pitch + 85) / 170)
        }
      case .ended, .cancelled, .failed:
        recognizer.setTranslation(.zero, in: surface)
        previousTouchCount = 0
        multitouchSequence = pinching
        end(.pan)
      default:
        break
      }
    }

    @objc private func pinched(_ recognizer: UIPinchGestureRecognizer) {
      guard let surface, surface.bounds.width > 0, surface.bounds.height > 0 else { return }
      switch recognizer.state {
      case .began:
        begin(.pinch)
        multitouchSequence = true
        pinchLocation = recognizer.location(in: surface)
        panRecognizer?.setTranslation(.zero, in: surface)
        zoom(recognizer, in: surface)
      case .changed:
        zoom(recognizer, in: surface)
      case .ended, .cancelled, .failed:
        // After a finger lifts, location(in:) may jump to the remaining finger; never apply
        // that discontinuity as a pan.
        recognizer.scale = 1
        panRecognizer?.setTranslation(.zero, in: surface)
        pinchLocation = nil
        end(.pinch)
      default:
        break
      }
    }

    private func zoom(_ recognizer: UIPinchGestureRecognizer, in surface: UIView) {
      let location = recognizer.location(in: surface)
      let w = surface.bounds.width
      let h = surface.bounds.height
      if let previous = pinchLocation {
        // Translate before zooming so the same scene point follows the moving centroid.
        camera.wrappedValue.pan(dx: Double((location.x - previous.x) / w), dy: Double((location.y - previous.y) / h))
      }
      let anchor = SIMD2(Double(location.x / w) - 0.5, Double(location.y / h) - 0.5)
      camera.wrappedValue.zoom(by: Double(recognizer.scale), anchor: anchor)
      recognizer.scale = 1
      pinchLocation = location
      panRecognizer?.setTranslation(.zero, in: surface)
      let range = OrbitCamera.zoomRange
      Haptics.shared.detent(
        normalized: log(camera.wrappedValue.zoom / range.lowerBound) / log(range.upperBound / range.lowerBound))
    }

    @objc private func doubleTapped(_ recognizer: UITapGestureRecognizer) {
      guard recognizer.state == .ended else { return }
      camera.wrappedValue.reset(to: home)
      Haptics.shared.tap()
    }
  }
}
