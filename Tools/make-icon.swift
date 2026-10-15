#!/usr/bin/env swift
// Draws Spectra's app icon with CoreGraphics at exactly 1024 × 1024 pixels (a bitmap context,
// not NSImage lockFocus, which renders at 2×), opaque, no text:
// a dark phosphor ground with a faint grid, a glowing electromagnetic wave whose wavelength
// shortens left to right while its hue sweeps radio → microwave → infrared → visible → UV →
// X-ray → gamma, its magnetic partner in rose, and a small precessing spin cone.
//
//   xcrun swift Tools/make-icon.swift [output.png]
//
// Default output: Spectra/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let size = 1024
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let output =
  CommandLine.arguments.count > 1
  ? URL(fileURLWithPath: CommandLine.arguments[1])
  : root.appendingPathComponent("Spectra/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png")

struct RGB {
  var r, g, b: Double
  init(_ r: Double, _ g: Double, _ b: Double) { (self.r, self.g, self.b) = (r, g, b) }
  init(hex: UInt32) {
    self.init(Double((hex >> 16) & 0xFF) / 255, Double((hex >> 8) & 0xFF) / 255, Double(hex & 0xFF) / 255)
  }
  func mix(_ o: RGB, _ t: Double) -> RGB { RGB(r + (o.r - r) * t, g + (o.g - g) * t, b + (o.b - b) * t) }
  func cg(_ a: Double = 1) -> CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }
}

// Band colours from spectra-lab (radio … gamma), with the visible band as spectral stops.
let stops: [(Double, RGB)] = [
  (0.00, RGB(hex: 0x9DB0CC)),  // radio
  (0.20, RGB(hex: 0x5FD3BC)),  // microwave
  (0.36, RGB(hex: 0xFF7A6B)),  // infrared
  (0.44, RGB(1.0, 0.24, 0.20)),  // red
  (0.49, RGB(1.0, 0.62, 0.16)),  // orange
  (0.53, RGB(0.98, 0.95, 0.30)),  // yellow
  (0.57, RGB(0.45, 1.0, 0.38)),  // green
  (0.61, RGB(0.30, 0.78, 1.0)),  // blue
  (0.65, RGB(0.55, 0.42, 1.0)),  // violet
  (0.74, RGB(hex: 0xB583FF)),  // UV
  (0.87, RGB(hex: 0x8FD3FF)),  // X-ray
  (1.00, RGB(hex: 0xE2D4FF)),  // gamma
]

func hue(_ t: Double) -> RGB {
  let x = min(1, max(0, t))
  var k = 0
  while k < stops.count - 2, x > stops[k + 1].0 { k += 1 }
  let (t0, c0) = stops[k]
  let (t1, c1) = stops[k + 1]
  return c0.mix(c1, (x - t0) / max(1e-9, t1 - t0))
}

guard
  let space = CGColorSpace(name: CGColorSpace.sRGB),
  let ctx = CGContext(
    data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space,
    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
else { fatalError("Could not make a 1024 × 1024 bitmap context.") }

let s = CGFloat(size)
// CoreGraphics' origin is bottom-left; draw in a top-left frame.
ctx.translateBy(x: 0, y: s)
ctx.scaleBy(x: 1, y: -1)
ctx.setLineCap(.round)
ctx.setLineJoin(.round)

// Ground: radial phosphor-dark gradient.
let ground = CGGradient(
  colorsSpace: space,
  colors: [RGB(0.055, 0.105, 0.088).cg(), RGB(0.025, 0.045, 0.04).cg(), RGB(0.010, 0.018, 0.016).cg()] as CFArray,
  locations: [0, 0.55, 1])!
ctx.drawRadialGradient(
  ground, startCenter: CGPoint(x: s * 0.5, y: s * 0.47), startRadius: 0, endCenter: CGPoint(x: s * 0.5, y: s * 0.5),
  endRadius: s * 0.75, options: [.drawsAfterEndLocation])

// Faint grid.
ctx.setStrokeColor(RGB(0.4, 0.96, 0.56).cg(0.055))
ctx.setLineWidth(2)
for i in stride(from: 64, to: size, by: 64) {
  ctx.move(to: CGPoint(x: CGFloat(i), y: 0))
  ctx.addLine(to: CGPoint(x: CGFloat(i), y: s))
  ctx.move(to: CGPoint(x: 0, y: CGFloat(i)))
  ctx.addLine(to: CGPoint(x: s, y: CGFloat(i)))
}
ctx.strokePath()
ctx.setStrokeColor(RGB(0.4, 0.96, 0.56).cg(0.10))
ctx.setLineWidth(3)
ctx.move(to: CGPoint(x: 0, y: s * 0.56))
ctx.addLine(to: CGPoint(x: s, y: s * 0.56))
ctx.strokePath()

// The wave: phase advances faster to the right (shorter wavelength), hue follows.
let left = s * 0.06
let right = s * 0.94
let axisY = s * 0.56
let n = 900
func phase(_ u: Double) -> Double { 2 * .pi * (1.1 * u + 6.4 * u * u * u) }

/// Strokes the wave displaced along `direction` (a unit-ish vector in the icon plane; E is
/// straight up, B points obliquely "out of the page"), in three passes: a wide faint halo,
/// a softer glow and a crisp core with a shadow in the local colour.
func strokeWave(amplitude: Double, direction: CGVector, width: CGFloat, glow: CGFloat, alpha: Double, color: (Double) -> RGB) {
  for pass in 0..<3 {
    let w: CGFloat = [width * 4.2, width * 2.0, width][pass]
    let a: Double = [0.07, 0.22, 1.0][pass] * alpha
    ctx.setLineWidth(w)
    var previous: CGPoint?
    for i in 0...n {
      let u = Double(i) / Double(n)
      // The amplitude tapers at both ends so the wave enters and leaves the icon softly.
      let envelope = pow(sin(.pi * (0.03 + 0.94 * u)), 0.35)
      let y = sin(phase(u)) * amplitude * envelope
      let p = CGPoint(
        x: left + (right - left) * u + direction.dx * CGFloat(y), y: axisY + direction.dy * CGFloat(y))
      if let q = previous {
        let c = color(u)
        ctx.setShadow(offset: .zero, blur: pass == 2 ? glow : 0, color: pass == 2 ? c.cg(0.85 * alpha) : nil)
        ctx.setStrokeColor(c.cg(a))
        ctx.move(to: q)
        ctx.addLine(to: p)
        ctx.strokePath()
      }
      previous = p
    }
  }
  ctx.setShadow(offset: .zero, blur: 0, color: nil)
}

// B (rose) seen obliquely, then E with the spectral sweep.
strokeWave(amplitude: Double(s) * 0.12, direction: CGVector(dx: 0.22, dy: 0.5), width: 5, glow: 16, alpha: 0.55) { _ in
  RGB(hex: 0xFF5C7A)
}
strokeWave(amplitude: Double(s) * 0.20, direction: CGVector(dx: 0, dy: -1), width: 10, glow: 26, alpha: 1, color: hue)

// A small precessing spin: cone, precession ellipse and the spin arrow (phosphor).
let apex = CGPoint(x: s * 0.24, y: s * 0.285)
let ringCentre = CGPoint(x: s * 0.24, y: s * 0.135)
let rx = s * 0.085
let ry = s * 0.026
let phosphor = RGB(0.4, 0.96, 0.56)
ctx.setShadow(offset: .zero, blur: 18, color: phosphor.cg(0.8))
ctx.setStrokeColor(phosphor.cg(0.55))
ctx.setLineWidth(5)
ctx.strokeEllipse(in: CGRect(x: ringCentre.x - rx, y: ringCentre.y - ry, width: 2 * rx, height: 2 * ry))
ctx.setStrokeColor(phosphor.cg(0.35))
ctx.setLineWidth(3)
for side in [-1.0, 1.0] {
  ctx.move(to: apex)
  ctx.addLine(to: CGPoint(x: ringCentre.x + CGFloat(side) * rx, y: ringCentre.y))
}
ctx.strokePath()
let tip = CGPoint(x: ringCentre.x + rx * 0.62, y: ringCentre.y + ry * 0.78)
ctx.setStrokeColor(phosphor.cg(1))
ctx.setLineWidth(9)
ctx.move(to: apex)
ctx.addLine(to: tip)
ctx.strokePath()
let dx = tip.x - apex.x
let dy = tip.y - apex.y
let len = (dx * dx + dy * dy).squareRoot()
let ux = dx / len
let uy = dy / len
ctx.setLineWidth(8)
for sign in [-1.0, 1.0] {
  let c = CGFloat(cos(0.5)), sn = CGFloat(sin(0.5) * sign)
  let hx = -(ux * c - uy * sn) * 34
  let hy = -(ux * sn + uy * c) * 34
  ctx.move(to: tip)
  ctx.addLine(to: CGPoint(x: tip.x + hx, y: tip.y + hy))
}
ctx.strokePath()
ctx.setFillColor(RGB(1, 1, 1).cg(0.95))
ctx.fillEllipse(in: CGRect(x: apex.x - 9, y: apex.y - 9, width: 18, height: 18))
ctx.setShadow(offset: .zero, blur: 0, color: nil)

guard let image = ctx.makeImage(), image.width == size, image.height == size else {
  fatalError("Icon render failed.")
}
try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
guard let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.png.identifier as CFString, 1, nil) else {
  fatalError("Could not write \(output.path).")
}
CGImageDestinationAddImage(destination, image, nil)
guard CGImageDestinationFinalize(destination) else { fatalError("Could not finalize \(output.path).") }
print("Wrote \(output.path) (\(image.width) × \(image.height), opaque)")
