import MetalKit
import QuartzCore
import UIKit
import simd

/// Why a canvas cannot draw (shown as a `ContentUnavailableView`).
nonisolated enum RendererError: LocalizedError, Sendable, Equatable {
  case unavailable
  case shader
  case buffer

  var errorDescription: String? {
    switch self {
    case .unavailable: "Metal is unavailable on this device."
    case .shader: "Spectra could not load its shaders."
    case .buffer: "Spectra could not reserve its rendering buffers."
    }
  }
}

/// Per-frame uniforms; layout mirrors `FrameUniforms` in `Shaders.metal` (128 bytes).
nonisolated struct FrameUniforms {
  var viewProj: simd_float4x4
  /// Width px, height px, content scale, time.
  var viewport: SIMD4<Float>
  var eye: SIMD4<Float>
  /// Bloom, scanlines, EDR headroom, reduce motion.
  var post: SIMD4<Float>
  /// Mode (0 clear, 1 grid, 2 plain), grid pitch (pt), vignette, unused.
  var background: SIMD4<Float>
}

/// The one renderer (Gyre's `HoloRenderer` skeleton, Orbitals' frame discipline):
/// 1. scene pass into an rgba16Float target with depth: the instrument ground, then holo
///    lines (3D, depth-tested, additive), then phosphor capsules (2D, additive);
/// 2. bloom: soft-threshold prefilter, separable blur at ½ and ¼ resolution;
/// 3. composite into the extended-linear Display P3 drawable, soft-clipped into the EDR
///    headroom (≤ 3×).
///
/// Never blocks: with three frames in flight it drops the tick but still advances the clock.
/// Skips all GPU work when the view is off screen, hidden or the app is in the background.
@MainActor
final class HoloRenderer: NSObject, MTKViewDelegate {
  weak var scene: (any SceneBuilder)?
  weak var clock: AppClock?
  /// False while another canvas owns rendering (one canvas at a time).
  var isActive = true
  var reduceMotion = false
  /// Requested frame rate before the power policy (60, or 120 for live spin scenes).
  var maximumFramesPerSecond = 60

  private struct Targets {
    let size: CGSize
    let scene: MTLTexture
    let depth: MTLTexture
    let halfA: MTLTexture
    let halfB: MTLTexture
    let quarterA: MTLTexture
    let quarterB: MTLTexture
  }

  private let device: MTLDevice
  private let queue: MTLCommandQueue
  private let background: MTLRenderPipelineState
  private let holo: MTLRenderPipelineState
  private let phosphor: MTLRenderPipelineState
  private let prefilter: MTLRenderPipelineState
  private let copy: MTLRenderPipelineState
  private let blur: MTLRenderPipelineState
  private let composite: MTLRenderPipelineState
  private let depthTest: MTLDepthStencilState
  private let depthOff: MTLDepthStencilState
  private var instanceBuffers: [MTLBuffer?] = [nil, nil, nil]
  private var frameIndex = 0
  private let inFlight = DispatchSemaphore(value: 3)
  private var targets: Targets?
  private var buffer = SceneBuffer()

  static let sceneFormat: MTLPixelFormat = .rgba16Float
  static let depthFormat: MTLPixelFormat = .depth32Float

  /// The power policy (Orbitals): 30 fps on Low Power Mode or serious thermal state,
  /// otherwise `maximum`.
  static func framesPerSecond(maximum: Int) -> Int {
    let process = ProcessInfo.processInfo
    let limited = process.isLowPowerModeEnabled || process.thermalState == .serious || process.thermalState == .critical
    return limited ? 30 : maximum
  }

  init(view: MTKView) throws {
    guard let device = view.device ?? MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
      throw RendererError.unavailable
    }
    guard let library = device.makeDefaultLibrary() else { throw RendererError.shader }
    self.device = device
    self.queue = queue

    enum Blend { case none, add }
    func pipeline(_ label: String, _ vertex: String, _ fragment: String, format: MTLPixelFormat, blend: Blend, depth: Bool)
      throws -> MTLRenderPipelineState
    {
      guard let v = library.makeFunction(name: vertex), let f = library.makeFunction(name: fragment) else {
        throw RendererError.shader
      }
      let d = MTLRenderPipelineDescriptor()
      d.label = "Spectra · \(label)"
      d.vertexFunction = v
      d.fragmentFunction = f
      if depth { d.depthAttachmentPixelFormat = Self.depthFormat }
      let a = d.colorAttachments[0]!
      a.pixelFormat = format
      if blend == .add {
        a.isBlendingEnabled = true
        a.rgbBlendOperation = .add
        a.alphaBlendOperation = .add
        a.sourceRGBBlendFactor = .one
        a.destinationRGBBlendFactor = .one
        a.sourceAlphaBlendFactor = .zero
        a.destinationAlphaBlendFactor = .one
      }
      do { return try device.makeRenderPipelineState(descriptor: d) } catch { throw RendererError.shader }
    }

    let f = Self.sceneFormat
    background = try pipeline("instrument ground", "fullscreenVertex", "backgroundFragment", format: f, blend: .none, depth: true)
    holo = try pipeline("holo lines", "holoVertex", "holoFragment", format: f, blend: .add, depth: true)
    phosphor = try pipeline("phosphor capsules", "phosphorVertex", "phosphorFragment", format: f, blend: .add, depth: true)
    prefilter = try pipeline("bloom prefilter", "fullscreenVertex", "prefilterFragment", format: f, blend: .none, depth: false)
    copy = try pipeline("bloom copy", "fullscreenVertex", "copyFragment", format: f, blend: .none, depth: false)
    blur = try pipeline("bloom blur", "fullscreenVertex", "blurFragment", format: f, blend: .none, depth: false)
    composite = try pipeline(
      "composite", "fullscreenVertex", "compositeFragment", format: view.colorPixelFormat, blend: .none, depth: false)

    let test = MTLDepthStencilDescriptor()
    test.depthCompareFunction = .lessEqual
    test.isDepthWriteEnabled = false
    let off = MTLDepthStencilDescriptor()
    off.depthCompareFunction = .always
    off.isDepthWriteEnabled = false
    guard let depthTest = device.makeDepthStencilState(descriptor: test),
      let depthOff = device.makeDepthStencilState(descriptor: off)
    else { throw RendererError.buffer }
    self.depthTest = depthTest
    self.depthOff = depthOff
    super.init()
  }

  func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
    targets = nil
    view.setNeedsDisplay()
  }

  // MARK: Frame

  func draw(in view: MTKView) {
    // The clock advances even when the frame is skipped (the clock deduplicates ticks from
    // several drivers in one frame).
    clock?.tick(at: CACurrentMediaTime())
    guard isActive, let scene, let window = view.window, !view.isHidden, view.bounds.width > 1,
      view.bounds.height > 1, UIApplication.shared.applicationState != .background
    else { return }
    let fps = Self.framesPerSecond(maximum: maximumFramesPerSecond)
    if view.preferredFramesPerSecond != fps { view.preferredFramesPerSecond = fps }
    let visible = view.convert(view.bounds, to: window).intersection(window.bounds)
    guard !visible.isNull, !visible.isEmpty else { return }

    let size = view.drawableSize
    guard size.width > 8, size.height > 8 else { return }
    if targets?.size != size { targets = makeTargets(size) }
    guard let targets else { return }
    guard inFlight.wait(timeout: .now()) == .success else { return }
    guard let drawable = view.currentDrawable, let command = queue.makeCommandBuffer() else {
      inFlight.signal()
      return
    }

    let time = clock?.time ?? 0
    buffer.reset(size: view.bounds.size, reduceMotion: reduceMotion)
    scene.build(into: &buffer, time: time, size: view.bounds.size)

    frameIndex = (frameIndex + 1) % instanceBuffers.count
    let stride = MemoryLayout<GlowSegment>.stride
    let holoCount = buffer.holo.count
    let phosphorCount = buffer.phosphor.count
    let needed = max(1, holoCount + phosphorCount) * stride
    if (instanceBuffers[frameIndex]?.length ?? 0) < needed {
      instanceBuffers[frameIndex] = device.makeBuffer(length: needed * 2, options: .storageModeShared)
      instanceBuffers[frameIndex]?.label = "Spectra · lines \(frameIndex)"
    }
    guard let instances = instanceBuffers[frameIndex] else {
      inFlight.signal()
      return
    }
    buffer.holo.withUnsafeBytes { raw in
      if let base = raw.baseAddress, raw.count > 0 { instances.contents().copyMemory(from: base, byteCount: raw.count) }
    }
    buffer.phosphor.withUnsafeBytes { raw in
      if let base = raw.baseAddress, raw.count > 0 {
        (instances.contents() + holoCount * stride).copyMemory(from: base, byteCount: raw.count)
      }
    }

    let headroom = Float(window.windowScene?.screen.currentEDRHeadroom ?? 1)
    var uniforms = makeUniforms(view: view, time: time, headroom: headroom)
    let semaphore = inFlight
    command.addCompletedHandler { _ in semaphore.signal() }
    command.label = "Spectra · frame"

    // 1. Scene.
    let scenePass = pass(targets.scene, clear: true)
    scenePass.depthAttachment.texture = targets.depth
    scenePass.depthAttachment.loadAction = .clear
    scenePass.depthAttachment.clearDepth = 1
    scenePass.depthAttachment.storeAction = .dontCare
    if let enc = command.makeRenderCommandEncoder(descriptor: scenePass) {
      enc.label = "Spectra · scene"
      enc.setVertexBytes(&uniforms, length: MemoryLayout<FrameUniforms>.stride, index: 1)
      enc.setFragmentBytes(&uniforms, length: MemoryLayout<FrameUniforms>.stride, index: 1)
      if uniforms.background.x > 0 {
        enc.setDepthStencilState(depthOff)
        enc.setRenderPipelineState(background)
        enc.setFragmentBytes(&uniforms, length: MemoryLayout<FrameUniforms>.stride, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
      }
      enc.setCullMode(.none)
      if holoCount > 0 {
        enc.setDepthStencilState(depthTest)
        enc.setRenderPipelineState(holo)
        enc.setVertexBuffer(instances, offset: 0, index: 0)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: holoCount)
      }
      if phosphorCount > 0 {
        enc.setDepthStencilState(depthOff)
        enc.setRenderPipelineState(phosphor)
        enc.setVertexBuffer(instances, offset: holoCount * stride, index: 0)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: phosphorCount)
      }
      enc.endEncoding()
    }

    // 2. Bloom at ½ and ¼ resolution.
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

    // 3. Composite into the drawable.
    let final = pass(drawable.texture, clear: false)
    if let enc = command.makeRenderCommandEncoder(descriptor: final) {
      enc.label = "Spectra · composite"
      enc.setRenderPipelineState(composite)
      enc.setFragmentTexture(targets.scene, index: 0)
      enc.setFragmentTexture(targets.halfA, index: 1)
      enc.setFragmentTexture(targets.quarterA, index: 2)
      enc.setFragmentBytes(&uniforms, length: MemoryLayout<FrameUniforms>.stride, index: 0)
      enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
      enc.endEncoding()
    }
    command.present(drawable)
    command.commit()
  }

  private func makeUniforms(view: MTKView, time: Double, headroom: Float) -> FrameUniforms {
    let mode: SIMD4<Float>
    switch buffer.background {
    case .grid(let pitch): mode = SIMD4(1, pitch, 1, 0)
    case .plain: mode = SIMD4(2, 32, 1, 0)
    }
    return FrameUniforms(
      viewProj: buffer.camera.viewProj,
      viewport: SIMD4(
        Float(view.drawableSize.width), Float(view.drawableSize.height),
        Float(view.drawableSize.width / max(1, view.bounds.width)), Float(time.truncatingRemainder(dividingBy: 3600))),
      eye: SIMD4(buffer.camera.eye, 0),
      post: SIMD4(buffer.bloom, reduceMotion ? 0 : buffer.scanlines, max(1, headroom), reduceMotion ? 1 : 0),
      background: mode)
  }

  private func makeTargets(_ size: CGSize) -> Targets? {
    func texture(_ w: Int, _ h: Int, _ format: MTLPixelFormat = Self.sceneFormat) -> MTLTexture? {
      let d = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: format, width: max(w, 1), height: max(h, 1), mipmapped: false)
      d.usage = format == Self.depthFormat ? [.renderTarget] : [.renderTarget, .shaderRead]
      d.storageMode = .private
      return device.makeTexture(descriptor: d)
    }
    let w = Int(size.width)
    let h = Int(size.height)
    guard let scene = texture(w, h), let depth = texture(w, h, Self.depthFormat),
      let halfA = texture(w / 2, h / 2), let halfB = texture(w / 2, h / 2),
      let quarterA = texture(w / 4, h / 4), let quarterB = texture(w / 4, h / 4)
    else { return nil }
    return Targets(
      size: size, scene: scene, depth: depth, halfA: halfA, halfB: halfB, quarterA: quarterA, quarterB: quarterB)
  }

  private func pass(_ texture: MTLTexture, clear: Bool) -> MTLRenderPassDescriptor {
    let d = MTLRenderPassDescriptor()
    d.colorAttachments[0].texture = texture
    d.colorAttachments[0].loadAction = clear ? .clear : .dontCare
    d.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
    d.colorAttachments[0].storeAction = .store
    return d
  }

  private func fullscreen(_ command: MTLCommandBuffer, _ pipeline: MTLRenderPipelineState, from: MTLTexture, to: MTLTexture) {
    guard let enc = command.makeRenderCommandEncoder(descriptor: pass(to, clear: false)) else { return }
    enc.setRenderPipelineState(pipeline)
    enc.setFragmentTexture(from, index: 0)
    enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    enc.endEncoding()
  }

  private func blurPass(_ command: MTLCommandBuffer, from: MTLTexture, to: MTLTexture, step: SIMD2<Float>) {
    guard let enc = command.makeRenderCommandEncoder(descriptor: pass(to, clear: false)) else { return }
    var s = step
    enc.setRenderPipelineState(blur)
    enc.setFragmentTexture(from, index: 0)
    enc.setFragmentBytes(&s, length: MemoryLayout<SIMD2<Float>>.stride, index: 0)
    enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    enc.endEncoding()
  }
}
