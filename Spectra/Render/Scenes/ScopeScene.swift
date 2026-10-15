import MetalKit
import QuartzCore
import SwiftUI
import UIKit
import simd

/// One frame of the Scope's phosphor display (owner: scope).
///
/// - `accumulate`: segments the beam writes into the persistence buffer this frame (new sweeps,
///   new XY points). They fade with the persistence time constant.
/// - `overlay`: segments drawn crisply this frame only (the current sweep, cursors, level and
///   ground markers).
/// - `decay`: what the persistence buffer is multiplied by before this frame's beam is added
///   (exp(−Δt/τ); 0 clears it, 1 keeps everything: infinite persistence or a stopped scope).
///
/// Both buffers use `SceneBuffer`'s 2D phosphor helpers (`segment2D`, `trace`, `dot2D`) in
/// points with a top-left origin, so the look matches every other phosphor trace in the app.
nonisolated struct ScopeFrame: Sendable {
  var accumulate = SceneBuffer()
  var overlay = SceneBuffer()
  var decay: Float = 0
  /// Clears the persistence buffer before drawing (mode or scale changes).
  var clearAccumulation = false
  /// Graticule columns × rows (10 × 8) and brightness 0…1; 0 hides it.
  var graticule = SIMD3<Float>(10, 8, 1)
  /// Inset of the graticule from the view edge, in points.
  var inset: Float = 0
  var bloom: Float = 0.55
  /// Gain of the persistence buffer when it is added into the scene.
  var accumulationGain: Float = 1

  mutating func reset(size: CGSize, reduceMotion: Bool) {
    accumulate.reset(size: size, reduceMotion: reduceMotion)
    overlay.reset(size: size, reduceMotion: reduceMotion)
    decay = 0
    clearAccumulation = false
  }
}

/// Supplies the Scope's frames. Called once per displayed frame on the main actor.
@MainActor
protocol ScopeFrameSource: AnyObject {
  /// Fills `frame` (already reset to `size` points) for a frame `dt` seconds after the previous.
  func buildScopeFrame(_ frame: inout ScopeFrame, size: CGSize, dt: Double)
  /// True while the picture changes on its own (the scope is running).
  var scopeAnimating: Bool { get }
}

/// The Scope's Metal display: a phosphor persistence buffer, the 10 × 8 graticule and the
/// foundation's bloom. Like `MetalCanvas` it renders only while on screen and active, takes
/// part in `CanvasArbiter` (one canvas renders at a time), draws continuously while the scope
/// runs and on demand while it is stopped.
struct ScopeCanvas: View {
  let source: any ScopeFrameSource
  /// Bump to request a redraw while stopped.
  var redrawKey = 0
  var label = "Oscilloscope display"
  var value = ""

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
        ScopeCanvasRepresentable(
          source: source, active: active, animating: source.scopeAnimating, reduceMotion: reduceMotion,
          redrawKey: redrawKey, error: $error)
      }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(label)
    .accessibilityValue(value)
    .onAppear { arbiter.claim(id) }
    .onDisappear { arbiter.release(id) }
  }
}

private struct ScopeCanvasRepresentable: UIViewRepresentable {
  let source: any ScopeFrameSource
  let active: Bool
  let animating: Bool
  let reduceMotion: Bool
  let redrawKey: Int
  @Binding var error: RendererError?

  final class Coordinator {
    var renderer: ScopeRenderer?
  }

  func makeCoordinator() -> Coordinator { Coordinator() }

  func makeUIView(context: Context) -> MTKView {
    let view = ScopeMTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
    view.colorPixelFormat = ScopeRenderer.format
    view.depthStencilPixelFormat = .invalid
    view.framebufferOnly = true
    view.isOpaque = true
    view.backgroundColor = UIColor(red: 0.016, green: 0.031, blue: 0.027, alpha: 1)
    view.isUserInteractionEnabled = false
    view.accessibilityElementsHidden = true
    view.autoResizeDrawable = true
    view.preferredFramesPerSecond = HoloRenderer.framesPerSecond(maximum: 60)
    if let layer = view.layer as? CAMetalLayer {
      layer.wantsExtendedDynamicRangeContent = true
      layer.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)
    }
    do {
      let renderer = try ScopeRenderer(view: view)
      context.coordinator.renderer = renderer
      view.delegate = renderer
    } catch {
      let failure = (error as? RendererError) ?? .unavailable
      let report = self.$error
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
    renderer.source = source
    renderer.isActive = active
    renderer.reduceMotion = reduceMotion
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

private final class ScopeMTKView: MTKView {
  override func didMoveToWindow() {
    super.didMoveToWindow()
    if window != nil { setNeedsDisplay() }
  }
}

/// Per-frame uniforms; mirrors `ScopeUniforms` in `Scope.metal` (48 bytes).
nonisolated struct ScopeUniforms {
  var viewport: SIMD4<Float>
  var grid: SIMD4<Float>
  var post: SIMD4<Float>
}

/// The Scope's renderer: accumulation (persistence) → scene (graticule + accumulation +
/// overlay) → bloom → EDR composite. Triple-buffered; drops a frame rather than block.
@MainActor
final class ScopeRenderer: NSObject, MTKViewDelegate {
  weak var source: (any ScopeFrameSource)?
  var isActive = true
  var reduceMotion = false

  static let format: MTLPixelFormat = .rgba16Float

  private struct Targets {
    let size: CGSize
    let accumulation: MTLTexture
    let scene: MTLTexture
    let halfA: MTLTexture
    let halfB: MTLTexture
    let quarterA: MTLTexture
    let quarterB: MTLTexture
  }

  private let device: MTLDevice
  private let queue: MTLCommandQueue
  private let fade: MTLRenderPipelineState
  private let beam: MTLRenderPipelineState
  private let graticule: MTLRenderPipelineState
  private let addAccumulation: MTLRenderPipelineState
  private let prefilter: MTLRenderPipelineState
  private let copy: MTLRenderPipelineState
  private let blur: MTLRenderPipelineState
  private let composite: MTLRenderPipelineState
  private var instanceBuffers: [MTLBuffer?] = [nil, nil, nil]
  private var frameIndex = 0
  private let inFlight = DispatchSemaphore(value: 3)
  private var targets: Targets?
  private var frame = ScopeFrame()
  private var lastTime: CFTimeInterval?
  private var accumulationFresh = true

  init(view: MTKView) throws {
    guard let device = view.device ?? MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
      throw RendererError.unavailable
    }
    guard let library = device.makeDefaultLibrary() else { throw RendererError.shader }
    self.device = device
    self.queue = queue

    enum Blend { case none, add, fade }
    func pipeline(_ label: String, _ vertex: String, _ fragment: String, blend: Blend, format: MTLPixelFormat = ScopeRenderer.format)
      throws -> MTLRenderPipelineState
    {
      guard let v = library.makeFunction(name: vertex), let f = library.makeFunction(name: fragment) else {
        throw RendererError.shader
      }
      let d = MTLRenderPipelineDescriptor()
      d.label = "Spectra · scope · \(label)"
      d.vertexFunction = v
      d.fragmentFunction = f
      let a = d.colorAttachments[0]!
      a.pixelFormat = format
      switch blend {
      case .none: break
      case .add:
        a.isBlendingEnabled = true
        a.rgbBlendOperation = .add
        a.alphaBlendOperation = .add
        a.sourceRGBBlendFactor = .one
        a.destinationRGBBlendFactor = .one
        a.sourceAlphaBlendFactor = .zero
        a.destinationAlphaBlendFactor = .one
      case .fade:
        a.isBlendingEnabled = true
        a.rgbBlendOperation = .add
        a.alphaBlendOperation = .add
        a.sourceRGBBlendFactor = .zero
        a.destinationRGBBlendFactor = .blendColor
        a.sourceAlphaBlendFactor = .zero
        a.destinationAlphaBlendFactor = .one
      }
      do { return try device.makeRenderPipelineState(descriptor: d) } catch { throw RendererError.shader }
    }

    fade = try pipeline("fade", "scopeFullscreenVertex", "scopeFadeFragment", blend: .fade)
    beam = try pipeline("beam", "phosphorVertex", "phosphorFragment", blend: .add)
    graticule = try pipeline("graticule", "scopeFullscreenVertex", "scopeGraticuleFragment", blend: .none)
    addAccumulation = try pipeline("persistence", "scopeFullscreenVertex", "scopeAccumulationFragment", blend: .add)
    prefilter = try pipeline("bloom prefilter", "fullscreenVertex", "prefilterFragment", blend: .none)
    copy = try pipeline("bloom copy", "fullscreenVertex", "copyFragment", blend: .none)
    blur = try pipeline("bloom blur", "fullscreenVertex", "blurFragment", blend: .none)
    composite = try pipeline(
      "composite", "scopeFullscreenVertex", "scopeCompositeFragment", blend: .none, format: view.colorPixelFormat)
    super.init()
  }

  func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
    targets = nil
    view.setNeedsDisplay()
  }

  func draw(in view: MTKView) {
    let nowTime = CACurrentMediaTime()
    let dt = min(0.25, max(0, nowTime - (lastTime ?? nowTime)))
    lastTime = nowTime
    guard isActive, let source, let window = view.window, !view.isHidden, view.bounds.width > 1,
      view.bounds.height > 1, UIApplication.shared.applicationState != .background
    else { return }
    let fps = HoloRenderer.framesPerSecond(maximum: 60)
    if view.preferredFramesPerSecond != fps { view.preferredFramesPerSecond = fps }
    let visible = view.convert(view.bounds, to: window).intersection(window.bounds)
    guard !visible.isNull, !visible.isEmpty else { return }
    let size = view.drawableSize
    guard size.width > 8, size.height > 8 else { return }
    if targets?.size != size {
      targets = makeTargets(size)
      accumulationFresh = true
    }
    guard let targets else { return }
    guard inFlight.wait(timeout: .now()) == .success else { return }
    guard let drawable = view.currentDrawable, let command = queue.makeCommandBuffer() else {
      inFlight.signal()
      return
    }

    frame.reset(size: view.bounds.size, reduceMotion: reduceMotion)
    source.buildScopeFrame(&frame, size: view.bounds.size, dt: dt)

    frameIndex = (frameIndex + 1) % instanceBuffers.count
    let stride = MemoryLayout<GlowSegment>.stride
    let accumulateCount = frame.accumulate.phosphor.count
    let overlayCount = frame.overlay.phosphor.count
    let needed = max(1, accumulateCount + overlayCount) * stride
    if (instanceBuffers[frameIndex]?.length ?? 0) < needed {
      instanceBuffers[frameIndex] = device.makeBuffer(length: needed * 2, options: .storageModeShared)
      instanceBuffers[frameIndex]?.label = "Spectra · scope beam \(frameIndex)"
    }
    guard let instances = instanceBuffers[frameIndex] else {
      inFlight.signal()
      return
    }
    frame.accumulate.phosphor.withUnsafeBytes { raw in
      if let base = raw.baseAddress, raw.count > 0 { instances.contents().copyMemory(from: base, byteCount: raw.count) }
    }
    frame.overlay.phosphor.withUnsafeBytes { raw in
      if let base = raw.baseAddress, raw.count > 0 {
        (instances.contents() + accumulateCount * stride).copyMemory(from: base, byteCount: raw.count)
      }
    }

    let scale = Float(view.drawableSize.width / max(1, view.bounds.width))
    let headroom = Float(window.windowScene?.screen.currentEDRHeadroom ?? 1)
    var lines = FrameUniforms(
      viewProj: matrix_identity_float4x4,
      viewport: SIMD4(Float(size.width), Float(size.height), scale, 0), eye: .zero, post: .zero, background: .zero)
    var uniforms = ScopeUniforms(
      viewport: SIMD4(Float(size.width), Float(size.height), scale, 0),
      grid: SIMD4(frame.graticule.x, frame.graticule.y, frame.graticule.z, frame.inset),
      post: SIMD4(frame.bloom, frame.accumulationGain, max(1, headroom), reduceMotion ? 1 : 0))
    let semaphore = inFlight
    command.addCompletedHandler { _ in semaphore.signal() }
    command.label = "Spectra · scope frame"

    // 1. Persistence: fade, then the beam's new sweeps.
    let clear = accumulationFresh || frame.clearAccumulation || frame.decay <= 0
    accumulationFresh = false
    let accumulationPass = pass(targets.accumulation, load: clear ? .clear : .load)
    if let enc = command.makeRenderCommandEncoder(descriptor: accumulationPass) {
      enc.label = "Spectra · scope persistence"
      if !clear, frame.decay < 1 {
        let k = frame.decay
        enc.setRenderPipelineState(fade)
        enc.setBlendColor(red: k, green: k, blue: k, alpha: 1)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
      }
      if accumulateCount > 0 {
        enc.setRenderPipelineState(beam)
        enc.setVertexBuffer(instances, offset: 0, index: 0)
        enc.setVertexBytes(&lines, length: MemoryLayout<FrameUniforms>.stride, index: 1)
        enc.setFragmentBytes(&lines, length: MemoryLayout<FrameUniforms>.stride, index: 1)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: accumulateCount)
      }
      enc.endEncoding()
    }

    // 2. Scene: graticule, persistence, this frame's overlay.
    if let enc = command.makeRenderCommandEncoder(descriptor: pass(targets.scene, load: .clear)) {
      enc.label = "Spectra · scope scene"
      enc.setRenderPipelineState(graticule)
      enc.setFragmentBytes(&uniforms, length: MemoryLayout<ScopeUniforms>.stride, index: 0)
      enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
      enc.setRenderPipelineState(addAccumulation)
      enc.setFragmentTexture(targets.accumulation, index: 0)
      enc.setFragmentBytes(&uniforms, length: MemoryLayout<ScopeUniforms>.stride, index: 0)
      enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
      if overlayCount > 0 {
        enc.setRenderPipelineState(beam)
        enc.setVertexBuffer(instances, offset: accumulateCount * stride, index: 0)
        enc.setVertexBytes(&lines, length: MemoryLayout<FrameUniforms>.stride, index: 1)
        enc.setFragmentBytes(&lines, length: MemoryLayout<FrameUniforms>.stride, index: 1)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: overlayCount)
      }
      enc.endEncoding()
    }

    // 3. Bloom at ½ and ¼ resolution (the foundation's chain).
    fullscreen(command, prefilter, from: targets.scene, to: targets.halfA)
    let hw = Float(targets.halfA.width)
    let hh = Float(targets.halfA.height)
    blurPass(command, from: targets.halfA, to: targets.halfB, step: SIMD2(1.4 / hw, 0))
    blurPass(command, from: targets.halfB, to: targets.halfA, step: SIMD2(0, 1.4 / hh))
    fullscreen(command, copy, from: targets.halfA, to: targets.quarterA)
    let qw = Float(targets.quarterA.width)
    let qh = Float(targets.quarterA.height)
    blurPass(command, from: targets.quarterA, to: targets.quarterB, step: SIMD2(2.2 / qw, 0))
    blurPass(command, from: targets.quarterB, to: targets.quarterA, step: SIMD2(0, 2.2 / qh))

    // 4. Composite into the drawable.
    if let enc = command.makeRenderCommandEncoder(descriptor: pass(drawable.texture, load: .dontCare)) {
      enc.label = "Spectra · scope composite"
      enc.setRenderPipelineState(composite)
      enc.setFragmentTexture(targets.scene, index: 0)
      enc.setFragmentTexture(targets.halfA, index: 1)
      enc.setFragmentTexture(targets.quarterA, index: 2)
      enc.setFragmentBytes(&uniforms, length: MemoryLayout<ScopeUniforms>.stride, index: 0)
      enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
      enc.endEncoding()
    }
    command.present(drawable)
    command.commit()
  }

  private func makeTargets(_ size: CGSize) -> Targets? {
    func texture(_ w: Int, _ h: Int) -> MTLTexture? {
      let d = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: Self.format, width: max(w, 1), height: max(h, 1), mipmapped: false)
      d.usage = [.renderTarget, .shaderRead]
      d.storageMode = .private
      return device.makeTexture(descriptor: d)
    }
    let w = Int(size.width)
    let h = Int(size.height)
    guard let accumulation = texture(w, h), let scene = texture(w, h), let halfA = texture(w / 2, h / 2),
      let halfB = texture(w / 2, h / 2), let quarterA = texture(w / 4, h / 4), let quarterB = texture(w / 4, h / 4)
    else { return nil }
    accumulation.label = "Spectra · scope persistence"
    return Targets(
      size: size, accumulation: accumulation, scene: scene, halfA: halfA, halfB: halfB, quarterA: quarterA,
      quarterB: quarterB)
  }

  private func pass(_ texture: MTLTexture, load: MTLLoadAction) -> MTLRenderPassDescriptor {
    let d = MTLRenderPassDescriptor()
    d.colorAttachments[0].texture = texture
    d.colorAttachments[0].loadAction = load
    d.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
    d.colorAttachments[0].storeAction = .store
    return d
  }

  private func fullscreen(_ command: MTLCommandBuffer, _ pipeline: MTLRenderPipelineState, from: MTLTexture, to: MTLTexture) {
    guard let enc = command.makeRenderCommandEncoder(descriptor: pass(to, load: .dontCare)) else { return }
    enc.setRenderPipelineState(pipeline)
    enc.setFragmentTexture(from, index: 0)
    enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    enc.endEncoding()
  }

  private func blurPass(_ command: MTLCommandBuffer, from: MTLTexture, to: MTLTexture, step: SIMD2<Float>) {
    guard let enc = command.makeRenderCommandEncoder(descriptor: pass(to, load: .dontCare)) else { return }
    var s = step
    enc.setRenderPipelineState(blur)
    enc.setFragmentTexture(from, index: 0)
    enc.setFragmentBytes(&s, length: MemoryLayout<SIMD2<Float>>.stride, index: 0)
    enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    enc.endEncoding()
  }
}
