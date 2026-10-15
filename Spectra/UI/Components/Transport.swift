import SwiftUI

/// An item in the transport's ⋯ menu.
struct TransportAction: Identifiable {
  /// Accessibility identifier and identity.
  let id: String
  let title: String
  let symbol: String
  var destructive = false
  let action: () -> Void
}

/// What a screen tells its transport: how displayed time relates to real time (rule R3) and
/// the fastest oscillation on screen (for the ALIASED chip).
struct TransportConfig {
  var timeMapping: TimeMapping = .realTime
  /// The highest frequency (Hz, before mapping) visibly oscillating, if any.
  var frequency: Double? = nil
  var actions: [TransportAction] = []

  init(timeMapping: TimeMapping = .realTime, frequency: Double? = nil, actions: [TransportAction] = []) {
    self.timeMapping = timeMapping
    self.frequency = frequency
    self.actions = actions
  }
}

/// The floating transport (Orbitals): Play/Pause (prominent), Step (pauses and advances
/// exactly 1/60 s), ⋯ menu, then the time-mapping chip, an ALIASED chip when the displayed
/// frequency exceeds half the frame rate, and the RUN/HOLD clock. Stacks at accessibility
/// sizes. Identifiers: `transport-play`, `transport-step`, `transport-more`,
/// `transport-time-mapping`, `transport-aliased`, `transport-clock`.
struct Transport: View {
  var config = TransportConfig()
  @Environment(AppModel.self) private var app
  @Environment(\.dynamicTypeSize) private var typeSize
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    let clock = app.clock
    let aliased =
      config.frequency.map { config.timeMapping.isAliased(frequency: $0, frameRate: clock.frameRate) } ?? false
    GlassEffectContainer(spacing: 10) {
      if typeSize.isAccessibilitySize {
        VStack(spacing: 6) {
          HStack(spacing: 8) {
            TimeMappingChip(mapping: config.timeMapping)
            if aliased { AliasedChip(frequency: config.frequency ?? 0, mapping: config.timeMapping, frameRate: clock.frameRate) }
          }
          ClockReadout(clock: clock)
          HStack(spacing: 16) { buttons(clock) }
        }
      } else {
        HStack(spacing: 10) {
          buttons(clock)
          Spacer(minLength: 4)
          VStack(alignment: .trailing, spacing: 4) {
            // ALIASED next to a wide HETERODYNED chip does not fit a 402-pt phone in one row
            // (spin-ui-requests §6): stack the chips instead of widening the whole screen.
            ViewThatFits(in: .horizontal) {
              HStack(spacing: 6) { chips(aliased: aliased, clock: clock) }
              VStack(alignment: .trailing, spacing: 4) { chips(aliased: aliased, clock: clock) }
            }
            ClockReadout(clock: clock)
          }
        }
      }
    }
    .padding(.horizontal, Theme.gutter)
    .padding(.top, 8)
    .padding(.bottom, 6)
    .background {
      LinearGradient(
        stops: [
          .init(color: .clear, location: 0), .init(color: Theme.background.opacity(0.82), location: 0.35),
          .init(color: Theme.background.opacity(0.96), location: 1),
        ], startPoint: .top, endPoint: .bottom
      )
      .padding(.top, -14)
      .ignoresSafeArea(edges: .bottom)
      .allowsHitTesting(false)
    }
    .onKeyPress(.space) {
      clock.togglePlaying()
      return .handled
    }
  }

  @ViewBuilder
  private func chips(aliased: Bool, clock: AppClock) -> some View {
    if aliased { AliasedChip(frequency: config.frequency ?? 0, mapping: config.timeMapping, frameRate: clock.frameRate) }
    TimeMappingChip(mapping: config.timeMapping)
  }

  @ViewBuilder
  private func buttons(_ clock: AppClock) -> some View {
    Button {
      Haptics.shared.tap()
      clock.togglePlaying()
    } label: {
      Label(clock.playing ? "Pause" : "Play", systemImage: clock.playing ? "pause.fill" : "play.fill")
        .labelStyle(.iconOnly)
        .contentTransition(.symbolEffect(.replace))
        .frame(width: 22, height: 22)
    }
    .buttonStyle(.glassProminent)
    .buttonBorderShape(.circle)
    .controlSize(.large)
    .accessibilityLabel(clock.playing ? "Pause" : "Play")
    .accessibilityIdentifier("transport-play")

    Button {
      Haptics.shared.tap()
      clock.step()
    } label: {
      Label("Step", systemImage: "forward.frame.fill").labelStyle(.iconOnly).frame(width: 22, height: 22)
    }
    .buttonStyle(.glass)
    .buttonBorderShape(.circle)
    .controlSize(.large)
    .accessibilityLabel("Step")
    .accessibilityHint("Pauses and advances one sixtieth of a second.")
    .accessibilityIdentifier("transport-step")

    Menu {
      ForEach(config.actions) { item in
        Button(role: item.destructive ? .destructive : nil) {
          item.action()
        } label: {
          Label(item.title, systemImage: item.symbol)
        }
        .accessibilityIdentifier(item.id)
      }
      if !config.actions.isEmpty { Divider() }
      Button {
        clock.reset()
        Haptics.shared.success()
      } label: {
        Label("Reset clock", systemImage: "arrow.counterclockwise")
      }
    } label: {
      Image(systemName: "ellipsis").frame(width: 22, height: 22)
    }
    .buttonStyle(.glass)
    .buttonBorderShape(.circle)
    .controlSize(.large)
    .simultaneousGesture(TapGesture().onEnded { Haptics.shared.tap() })
    .accessibilityLabel("More actions")
    .accessibilityIdentifier("transport-more")
  }
}

/// Rule R3's chip: REAL TIME 1 : 1, κ-SLOWED ×5.45 × 10¹⁴ slower, or HETERODYNED @ 2.13 kHz.
struct TimeMappingChip: View {
  let mapping: TimeMapping

  var body: some View {
    StatusChip(text: mapping.badge, detail: mapping.detail, color: color, symbol: symbol)
      .accessibilityLabel("\(mapping.badge.capitalized), \(mapping.detail)")
      .accessibilityIdentifier("transport-time-mapping")
  }

  private var color: Color {
    switch mapping {
    case .realTime: Theme.phosphor
    case .slowed: RGB(0.72, 0.55, 1.0).color
    case .heterodyned: Theme.iceRGB.color
    }
  }

  private var symbol: String {
    switch mapping {
    case .realTime: "timer"
    case .slowed: "tuningfork"
    case .heterodyned: "waveform"
    }
  }
}

/// Shown when the displayed oscillation exceeds half the frame rate: the picture strobes.
struct AliasedChip: View {
  let frequency: Double
  let mapping: TimeMapping
  let frameRate: Double

  var body: some View {
    StatusChip(
      text: "ALIASED", detail: SpectraFormat.frequency(mapping.displayedFrequency(of: frequency)),
      color: Theme.ionizing, symbol: "exclamationmark.triangle.fill"
    )
    .accessibilityLabel("Aliased")
    .accessibilityValue(
      "The display shows \(SpectraFormat.frequency(mapping.displayedFrequency(of: frequency))), above half the \(Int(frameRate)) hertz frame rate, so the motion strobes."
    )
    .accessibilityIdentifier("transport-aliased")
  }
}

/// RUN (phosphor) or HOLD (amber) over MM:SS.hh, refreshed at 10 Hz.
struct ClockReadout: View {
  let clock: AppClock

  var body: some View {
    HStack(spacing: 6) {
      Text(clock.playing ? "RUN" : "HOLD")
        .font(.system(.caption2, design: .monospaced).weight(.semibold))
        .foregroundStyle(clock.playing ? Theme.phosphor : Theme.amber)
      Text(SpectraFormat.clock(clock.displayTime))
        .font(.system(.caption, design: .monospaced))
        .monospacedDigit()
        .foregroundStyle(Theme.amber)
        .contentTransition(.numericText())
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Simulation \(clock.playing ? "running" : "paused"), \(SpectraFormat.clock(clock.displayTime))")
    .accessibilityIdentifier("transport-clock")
  }
}
