import MetalKit
import Observation
import SwiftUI

/// Hands rendering to one canvas at a time (Orbitals rule 9): the most recently shown
/// visible canvas draws; the others pause and show the plot-well colour. A full-screen
/// view's canvas therefore takes over from the embedded one and hands back on dismissal.
@Observable @MainActor
final class CanvasArbiter {
  static let shared = CanvasArbiter()

  /// Canvases that are on screen, oldest first; the last one renders.
  private(set) var stack: [UUID] = []

  var activeID: UUID? { stack.last }

  func claim(_ id: UUID) {
    stack.removeAll { $0 == id }
    stack.append(id)
  }

  func release(_ id: UUID) {
    stack.removeAll { $0 == id }
  }
}

/// A Metal canvas showing a `SceneBuilder` with Spectra's HDR renderer. Pass a camera
/// binding to get Orbitals' gestures and accessibility (rotate, pan, pinch, double-tap
/// align; VoiceOver and keyboard alternatives).
///
/// It draws at 60 fps (30 on Low Power Mode or thermal pressure) while the clock runs or
/// the scene asks for continuous redraws, redraws on demand while paused, and costs nothing
/// when off screen, covered by another canvas, or in the background.
///
/// ```swift
/// PlotWell(height: 300) {
///   MetalCanvas(scene: model.waveScene, camera: $model.waveScene.camera, home: .init(yaw: 30, pitch: 15),
///               label: "Wave scope")
/// }
/// ```
struct MetalCanvas: View {
  let scene: any SceneBuilder
  var camera: Binding<OrbitCamera>? = nil
  var home = OrbitCamera()
  /// One-finger drag pans instead of rotating (2D scenes).
  var panWithOneFinger = false
  /// Up to 120 for live spin scenes; the power policy may lower it.
  var maximumFramesPerSecond = 60
  /// Bump to request a redraw while paused (model edits that the camera binding does not see).
  var redrawKey = 0
  var label = "3D view"

  @Environment(AppModel.self) private var app
  @Environment(\.scenePhase) private var scenePhase
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var id = UUID()
  @State private var error: RendererError?

  var body: some View {
    let arbiter = CanvasArbiter.shared
    let active = arbiter.activeID == id && scenePhase == .active
    ZStack {
      if let error {
        ContentUnavailableView(
          "Renderer unavailable", systemImage: "exclamationmark.triangle", description: Text(error.localizedDescription))
      } else {
        MetalCanvasRepresentable(
          scene: scene, clock: app.clock, active: active,
          animating: app.clock.isAnimating || scene.needsContinuousRedraw,
          reduceMotion: reduceMotion, maximumFramesPerSecond: maximumFramesPerSecond,
          redrawKey: redrawKey &+ (camera?.wrappedValue.hashValue ?? 0), error: $error)
      }
    }
    .modifier(CanvasGestureModifier(camera: camera, home: home, panWithOneFinger: panWithOneFinger, label: label))
    .onAppear { arbiter.claim(id) }
    .onDisappear { arbiter.release(id) }
  }
}

private struct CanvasGestureModifier: ViewModifier {
  let camera: Binding<OrbitCamera>?
  let home: OrbitCamera
  let panWithOneFinger: Bool
  let label: String

  func body(content: Content) -> some View {
    if let camera {
      content.orbitGestures(camera, home: home, panWithOneFinger: panWithOneFinger, label: label)
    } else {
      content.accessibilityElement(children: .ignore).accessibilityLabel(label)
    }
  }
}

/// The `MTKView` wrapper (Gyre `HoloView`, Orbitals `OrbitMetalView`).
private struct MetalCanvasRepresentable: UIViewRepresentable {
  let scene: any SceneBuilder
  let clock: AppClock
  let active: Bool
  let animating: Bool
  let reduceMotion: Bool
  let maximumFramesPerSecond: Int
  let redrawKey: Int
  @Binding var error: RendererError?

  final class Coordinator {
    var renderer: HoloRenderer?
  }

  func makeCoordinator() -> Coordinator { Coordinator() }

  func makeUIView(context: Context) -> MTKView {
    let view = CanvasMTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
    view.colorPixelFormat = HoloRenderer.sceneFormat
    view.depthStencilPixelFormat = .invalid
    view.framebufferOnly = true
    view.isOpaque = true
    view.backgroundColor = UIColor(red: 0.016, green: 0.031, blue: 0.027, alpha: 1)
    view.isUserInteractionEnabled = false
    view.accessibilityElementsHidden = true
    view.autoResizeDrawable = true
    view.preferredFramesPerSecond = HoloRenderer.framesPerSecond(maximum: maximumFramesPerSecond)
    if let layer = view.layer as? CAMetalLayer {
      layer.wantsExtendedDynamicRangeContent = true
      layer.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)
    }
    do {
      let renderer = try HoloRenderer(view: view)
      context.coordinator.renderer = renderer
      view.delegate = renderer
    } catch {
      let failure = (error as? RendererError) ?? .unavailable
      let report = self.$error
      // Not during the view update that is making this view.
      Task { @MainActor in report.wrappedValue = failure }
    }
    configure(view, context: context)
    return view
  }

  func updateUIView(_ view: MTKView, context: Context) {
    configure(view, context: context)
  }

  private func configure(_ view: MTKView, context: Context) {
    guard let renderer = context.coordinator.renderer else { return }
    renderer.scene = scene
    renderer.clock = clock
    renderer.isActive = active
    renderer.reduceMotion = reduceMotion
    renderer.maximumFramesPerSecond = maximumFramesPerSecond
    // Continuous while the clock runs (or the scene is live); otherwise draw on demand:
    // every SwiftUI update (camera, redrawKey, model edits it reads) requests one frame.
    let continuous = active && animating
    view.enableSetNeedsDisplay = !continuous
    view.isPaused = !continuous
    if active, !continuous { view.setNeedsDisplay() }
  }

  static func dismantleUIView(_ view: MTKView, coordinator: Coordinator) {
    view.isPaused = true
    view.delegate = nil
    coordinator.renderer = nil
    view.releaseDrawables()
  }
}

/// Requests a first draw when it joins a window (a paused canvas would otherwise stay blank).
private final class CanvasMTKView: MTKView {
  override func didMoveToWindow() {
    super.didMoveToWindow()
    if window != nil { setNeedsDisplay() }
  }
}
