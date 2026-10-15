import SwiftUI

/// What a card offers below its instrument: show its frequency on the spectrum, open its
/// streams in the Scope, add one to the Patch.
struct LiveCardActions {
  var marker: SpectrumMarker?
  var scope: [StreamID] = []
  var preset: String?
  var patch: (id: StreamID, label: String)?
}

/// The frame every Live card shares (SPEC-features §3): numbered phosphor panel with
/// provenance badges, a run/pause button, the honest state line (state · measured rate ·
/// headline reading), a permission gate around the instrument, and the three loop actions.
/// The card reports its scroll visibility so the tab runs only what is on screen.
struct LiveCard<Content: View, Model: View>: View {
  let card: LiveCardID
  var extraBadges: [Provenance] = []
  var startTitle = "Start"
  var explanation = ""
  var actions: LiveCardActions?
  @ViewBuilder var content: Content
  /// Shown whatever the source's state (the model view of a LOCKED or NEEDS PEER card).
  @ViewBuilder var model: Model

  @Environment(AppModel.self) private var app
  @Environment(LivePageModel.self) private var page
  @Environment(\.dynamicTypeSize) private var typeSize
  /// Measured header widths (natural, unscaled): the panel's inner width, "05 MAGNETOMETER
  /// (ELF)", "05 MAGNETOMETER", and the badge row. They decide what the header can hold.
  @State private var panelWidth = CGFloat.infinity
  @State private var fullTitleWidth: CGFloat = 0
  @State private var shortTitleWidth: CGFloat = 0
  @State private var badgesWidth: CGFloat = 0

  init(
    _ card: LiveCardID, badges: [Provenance] = [], startTitle: String = "Start", explanation: String = "",
    actions: LiveCardActions? = nil, @ViewBuilder content: () -> Content, @ViewBuilder model: () -> Model
  ) {
    self.card = card
    extraBadges = badges
    self.startTitle = startTitle
    self.explanation = explanation
    self.actions = actions
    self.content = content()
    self.model = model()
  }

  var body: some View {
    let channel = card.sensor.map { app.live.source($0) }
    let badges = Provenance.union(([channel?.provenance].compactMap { $0 }) + extraBadges)
    // At accessibility sizes the panel wraps its title by word and sets the badges under it,
    // so the full title is kept and the run button moves beside the status line: in the header
    // it left "MAGNETOMETER" too little room ("MAGNETOME-TER") and pushed "(GNSS)" out.
    let accessible = typeSize.isAccessibilitySize
    // Otherwise the header never truncates its title: badges move under it when they would
    // crowd it (long titles, three badges, large text), and a title that cannot fit even alone
    // uses its short form ("Magnetometer" for "Magnetometer (ELF)").
    let header = HeaderFit(
      room: panelWidth - (channel.map { Self.isLocked($0.state) } == false ? Self.buttonAllowance : Self.gapAllowance),
      full: fullTitleWidth, short: shortTitleWidth, badges: badgesWidth)
    let title = !accessible && header.useShortTitle ? card.shortTitle : card.title
    let badgesBelow = !accessible && !header.badgesInHeader
    // The panel keeps its accessory out of the combined heading element, so the run button
    // reads (and taps) as its own control right after the card's heading.
    InstrumentPanel(title, number: card.number, provenance: badgesBelow ? [] : badges) {
      if let channel, !accessible { RunButton(channel: channel) }
    } content: {
      if badgesBelow { ProvenanceBadges(badges) }
      if let channel {
        if accessible {
          HStack(alignment: .top, spacing: 12) {
            StatusLine(channel: channel)
              .frame(maxWidth: .infinity, alignment: .leading)
            RunButton(channel: channel)
          }
        } else {
          StatusLine(channel: channel)
        }
        if app.live.isSwitchedOff(channel) {
          // Settings → Sensors switched it off: the hub never starts it, so a Start button here
          // would do nothing. Say where it was switched off instead.
          ContentUnavailableView {
            Label("\(channel.title) is switched off", systemImage: "nosign")
          } description: {
            Text(SensorHub.switchedOffReason)
          }
          .frame(maxWidth: .infinity)
          .accessibilityIdentifier("live-off-\(channel.id.rawValue)")
        } else if Self.needsPeer(channel) {
          // A source that waits for a second device is NEEDS PEER, not locked: it says so, with
          // the watch it would range against.
          ContentUnavailableView {
            Label("\(channel.title) needs a peer", systemImage: "applewatch.radiowaves.left.and.right")
          } description: {
            Text(channel.state.reason ?? "")
          }
          .frame(maxWidth: .infinity)
          .accessibilityIdentifier("live-needs-peer-\(channel.id.rawValue)")
        } else {
          PermissionGate(
            title: channel.title, symbol: channel.symbol, state: channel.state, startTitle: startTitle,
            explanation: explanation, start: { page.userStart(channel.id, hub: app.live) }
          ) {
            VStack(alignment: .leading, spacing: 16) { content }
              .frame(maxWidth: .infinity, alignment: .leading)
          }
          .frame(maxWidth: .infinity)
        }
        model
        if channel.state.isRunning, let actions {
          LiveActionsRow(card: card, actions: actions)
        } else if Self.isLocked(channel.state), let marker = actions?.marker {
          // A LOCKED or NEEDS PEER card still puts its carrier (TABLE) on the spectrum.
          LiveActionsRow(card: card, actions: LiveCardActions(marker: marker))
        }
      } else {
        VStack(alignment: .leading, spacing: 16) { content }
        if let actions { LiveActionsRow(card: card, actions: actions) }
      }
    }
    // Natural widths of the header's parts, measured hidden (they never take space).
    .background(alignment: .topLeading) {
      if !accessible {
        VStack(alignment: .leading, spacing: 0) {
          titleMeasure(card.title) { fullTitleWidth = $0 }
          titleMeasure(card.shortTitle) { shortTitleWidth = $0 }
          ProvenanceBadges(badges)
            .fixedSize()
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { badgesWidth = $0 }
        }
        .hidden()
        .accessibilityHidden(true)
        .allowsHitTesting(false)
      }
    }
    .onGeometryChange(for: CGFloat.self) { $0.size.width - 2 * Theme.panelPadding } action: { panelWidth = $0 }
    .id(card.scrollID)
    // A container: the card is findable by its id while its controls keep their own.
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("live-card-\(card.rawValue)")
    .onScrollVisibilityChange(threshold: 0.02) { visible in page.setVisible(card, visible, hub: app.live) }
    // Layout changes (a card above growing as its sensor starts) move cards without a scroll;
    // geometry catches those too.
    .onGeometryChange(for: Bool.self) { proxy in
      guard let viewport = proxy.bounds(of: .scrollView) else { return false }
      let overlap = CGRect(origin: .zero, size: proxy.size).intersection(viewport)
      return !overlap.isNull && overlap.height > 4
    } action: { visible in
      page.setVisible(card, visible, hub: app.live)
    }
  }
}

extension LiveCard {
  /// Header width taken by the run button (44 pt with its glass) and the gaps around the
  /// spacer before it; without a button only the gap before the spacer remains.
  static var buttonAllowance: CGFloat { 44 + 2 * 8 }
  static var gapAllowance: CGFloat { 8 }

  /// "05 MAGNETOMETER (ELF)" as the panel header sets it, at its natural width.
  private func titleMeasure(_ title: String, _ report: @escaping (CGFloat) -> Void) -> some View {
    HStack(spacing: 8) {
      Text(card.number)
      Text(title.instrumentCaps).tracking(2)
    }
    .font(Theme.panelTitleFont)
    .lineLimit(1)
    .fixedSize()
    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { report($0) }
  }

  static func isLocked(_ state: SensorState) -> Bool {
    if case .locked = state { return true }
    return false
  }

  /// Held back for want of a second device (UWB without a peer), not by a capability lock.
  static func needsPeer(_ channel: any LiveSource) -> Bool { channel.waitsForPeer }
}

extension LiveSource {
  /// `.locked` because a second device is missing (UWB), which the badge calls NEEDS PEER.
  var waitsForPeer: Bool {
    if case .locked = state { return provenance == .needsPeer }
    return false
  }

  /// The state word the Live UI shows: the shared "Locked" for a capability lock, "Needs
  /// peer" for a source that waits for a second device.
  var stateLabel: String { waitsForPeer ? "Needs peer" : state.label }
}

extension SensorHub {
  /// The source is switched off in Settings → Sensors (and so not running): the hub refuses
  /// every start, so the Live UI shows that instead of a Start control that does nothing.
  func isSwitchedOff(_ source: any LiveSource) -> Bool { !isEnabled(source.id) && !source.state.isRunning }

  static let switchedOffReason = "Switched off in Settings → Sensors (⚙ at the top). Switch it back on there to use it."
}

extension LiveSource {
  /// The measured rate; "event-driven" for a source whose samples come per event (Bluetooth
  /// adverts, even before the first radio is heard); "measuring rate" for a regular source
  /// whose timestamps do not yet span a measurement (a slow battery, a GNSS fix on its way).
  var rateText: String {
    if let r = measuredRate { return SpectraFormat.rate(r) }
    if id == .bluetooth || (!streams.isEmpty && streams.allSatisfy(\.isIrregular)) { return "event-driven" }
    return "measuring rate"
  }
}

extension LiveCard where Model == EmptyView {
  init(
    _ card: LiveCardID, badges: [Provenance] = [], startTitle: String = "Start", explanation: String = "",
    actions: LiveCardActions? = nil, @ViewBuilder content: () -> Content
  ) {
    self.init(
      card, badges: badges, startTitle: startTitle, explanation: explanation, actions: actions, content: content,
      model: { EmptyView() })
  }
}

/// What fits in a card's header row: the title may shrink to 90 % (the panel allows 70 %,
/// which reads as a different size from its neighbours) before the badges move under it or
/// the short title is used.
struct HeaderFit: Equatable {
  /// Width left for number, title and badges (pt).
  var room: CGFloat
  /// Natural widths of "NN TITLE", "NN SHORT" and the badge row.
  var full: CGFloat
  var short: CGFloat
  var badges: CGFloat

  static let shrink: CGFloat = 0.9

  private var budget: CGFloat { room / Self.shrink }
  /// Before the first measurement every width is 0 and everything fits.
  var useShortTitle: Bool { full > budget && short < full }
  var titleWidth: CGFloat { useShortTitle ? short : full }
  var badgesInHeader: Bool { titleWidth + 8 + badges <= budget }
}

/// Start/pause for a card's source (`live-start-<sensor>`). Locked sources have none.
private struct RunButton: View {
  let channel: any LiveSource
  @Environment(AppModel.self) private var app
  @Environment(LivePageModel.self) private var page

  var body: some View {
    let id = channel.id
    let locked: Bool = {
      if case .locked = channel.state { return true }
      return false
    }()
    // A source switched off in Settings cannot start: no button that would do nothing.
    if !locked, !app.live.isSwitchedOff(channel) {
      // Paused here means paused, even while another owner (Scope, Patch) keeps it running.
      let running = !page.isPaused(id) && (channel.state.isRunning || channel.state == .requesting)
      Button {
        Haptics.shared.tap()
        if running { page.userStop(id, hub: app.live) } else { page.userStart(id, hub: app.live) }
      } label: {
        Image(systemName: running ? "pause.fill" : "play.fill")
          .font(.caption.weight(.bold))
          // The header's muted ink, in the header or beside the status line.
          .foregroundStyle(Theme.muted)
          // With the glass padding this makes a 44 pt target (house minimum).
          .frame(width: 26, height: 26)
          .contentTransition(.symbolEffect(.replace))
      }
      .buttonStyle(.glass)
      .buttonBorderShape(.circle)
      .accessibilityLabel(running ? "Pause \(channel.title)" : "Start \(channel.title)")
      .accessibilityIdentifier("live-start-\(id.rawValue)")
    }
  }
}

/// "RUNNING · 99.8 Hz · |B| 48.2 µT": state, measured rate, headline reading.
private struct StatusLine: View {
  let channel: any LiveSource
  @Environment(AppModel.self) private var app
  @Environment(LivePageModel.self) private var page
  /// The state dot scales with the caption2 text and sits on its first line's x-height.
  @ScaledMetric(relativeTo: .caption2) private var dotSize = 6.0
  @ScaledMetric(relativeTo: .caption2) private var dotTop = 3.5

  var body: some View {
    let elsewhere = page.isPaused(channel.id) && channel.state.isRunning
      && !app.live.holders(of: channel.id).subtracting([LivePageModel.owner]).isEmpty
    let rate = channel.rateText
    // Top-aligned with the dot on the first line, so a wrapped line at large text sizes does
    // not centre the dot in the middle of the text.
    HStack(alignment: .top, spacing: 8) {
      Circle()
        .fill(channel.state.isRunning ? (channel.isSimulated ? Theme.amber : Theme.phosphor) : Theme.dim)
        .frame(width: dotSize, height: dotSize)
        .padding(.top, dotTop)
      Text(
        ([(app.live.isSwitchedOff(channel) ? "Off in Settings" : channel.stateLabel).instrumentCaps] + (channel.state.isRunning ? [rate, channel.primaryReadout ?? "—"] : [])
          + (elsewhere ? ["paused here, kept on by \(Self.describe(app.live.holders(of: channel.id)))"] : []))
          .joined(separator: " · "))
        .font(.system(.caption2, design: .monospaced))
        .monospacedDigit()
        .foregroundStyle(Theme.muted)
        .fixedSize(horizontal: false, vertical: true)
    }
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("live-status-\(channel.id.rawValue)")
  }

  /// Who else holds a source, in words ("the Scope", "the Patch", "the census").
  static func describe(_ holders: Set<String>) -> String {
    let names = holders.subtracting([LivePageModel.owner]).map { h -> String in
      if h.hasPrefix("scope") { return "the Scope" }
      if h.hasPrefix("patch") { return "the Patch" }
      if h == TurntableExperiment.owner { return "the turntable" }
      if h == LiveCensusView.owner { return "the census" }
      return h
    }
    return Array(Set(names)).sorted().joined(separator: ", ")
  }
}

/// Show on spectrum · Open in Scope · Add to Patch (identifiers `live-<card>-spectrum|scope|patch`).
struct LiveActionsRow: View {
  let card: LiveCardID
  let actions: LiveCardActions
  @Environment(AppModel.self) private var app

  var body: some View {
    GlassEffectContainer(spacing: 8) {
      ViewThatFits(in: .horizontal) {
        HStack(spacing: 8) { buttons }
        VStack(alignment: .leading, spacing: 8) { buttons }
      }
    }
  }

  @ViewBuilder private var buttons: some View {
    if let marker = actions.marker {
      compact(marker.isEM ? "Spectrum" : "On strip", symbol: "ruler", label: "Show on spectrum", id: "spectrum") { show(marker) }
        .accessibilityHint(marker.label)
    }
    if !actions.scope.isEmpty {
      compact("Scope", symbol: "waveform.path.ecg", label: "Open in Scope", id: "scope") {
        app.openScope(actions.scope, preset: actions.preset)
      }
    }
    if let patch = actions.patch {
      compact("Patch", symbol: "point.3.connected.trianglepath.dotted", label: "Add to Patch", id: "patch") {
        app.patch.addStreamSource(patch.id, label: patch.label)
        Haptics.shared.success()
      }
    }
  }

  /// A compact glass capsule (three fit across a phone-width card).
  private func compact(_ title: String, symbol: String, label: String, id: String, action: @escaping () -> Void) -> some View {
    Button {
      Haptics.shared.tap()
      action()
    } label: {
      Label(title, systemImage: symbol)
        .font(.footnote.weight(.semibold))
        .lineLimit(1)
        .fixedSize()
        .frame(minHeight: 32)
    }
    .buttonStyle(.glass)
    .buttonBorderShape(.capsule)
    .tint(Theme.phosphor)
    .accessibilityLabel(label)
    .accessibilityIdentifier("live-\(card.rawValue)-\(id)")
  }

  /// EM sources tune Spectrum source A to their wavelength; sound only marks the strip,
  /// because a sound wave is not light (ANALOGY).
  private func show(_ marker: SpectrumMarker) {
    if marker.isEM {
      app.sendToSpectrum(lambda: marker.lambda, label: marker.label)
    } else {
      app.focusedMarker = marker
      app.showToast("\(marker.label) marked on the strip at λ = c/f, an analogy", symbol: "ruler")
    }
  }
}

/// A sparkline of a stream's newest seconds, redrawn only while visible (and held while
/// the transport is paused). Irregular streams draw sample-and-hold.
struct StreamSparkline: View {
  let stream: SignalStream?
  var seconds: Double = 10
  var color: Color?
  var range: ClosedRange<Double>? = nil

  @Environment(AppModel.self) private var app

  var body: some View {
    VisibleTimeline(minimumInterval: 0.2, paused: !app.clock.playing) { _ in
      if let stream {
        let window = StreamWindow.read(stream, seconds: stream.isIrregular ? max(seconds, 30) : seconds, maxPoints: 160)
        Sparkline(values: window.values, color: color ?? Self.color(for: stream), range: range, steps: stream.isIrregular)
      } else {
        Color.clear
      }
    }
    .accessibilityHidden(true)
  }

  /// Band colour for EM streams, phosphor (ANALOGY) for everything else (rule R2).
  static func color(for stream: SignalStream) -> Color {
    stream.isEM ? BandPalette.color(forWavelength: stream.lambda ?? 1) : Theme.analogy
  }
}

/// A measured sample rate, or "—" before the first measurement (`SpectraFormat.rate` says
/// "irregular" for nil, which is not true of a stream that has not been measured yet).
func liveRate(_ hertz: Double?) -> String {
  guard let hertz, hertz.isFinite, hertz > 0 else { return "—" }
  return SpectraFormat.rate(hertz)
}

/// A readout value with its unit, or "—".
func liveValue(_ x: Double?, _ digits: Int = 3, unit: String = "") -> String {
  guard let x, x.isFinite else { return "—" }
  let text = SpectraFormat.significant(x, digits)
  return unit.isEmpty ? text : "\(text) \(unit)"
}

/// A short labelled fact row (caption on the left, monospaced value on the right).
struct FactRow: View {
  let title: String
  let value: String
  var provenance: Provenance?

  @Environment(\.dynamicTypeSize) private var typeSize

  var body: some View {
    // At accessibility sizes the value goes under its title: side by side, both wrap
    // word by word ("87–205 / kHz") and the badge floats between them.
    if typeSize.isAccessibilitySize {
      VStack(alignment: .leading, spacing: 2) {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          titleText
          if let provenance { ProvenanceBadge(provenance, compact: true) }
        }
        valueText
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .accessibilityElement(children: .combine)
    } else {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        titleText
        if let provenance { ProvenanceBadge(provenance, compact: true) }
        Spacer(minLength: 8)
        valueText.multilineTextAlignment(.trailing)
      }
      .accessibilityElement(children: .combine)
    }
  }

  private var titleText: some View { Text(title).font(.caption).foregroundStyle(Theme.muted) }

  private var valueText: some View {
    Text(value)
      .font(.system(.caption, design: .monospaced).weight(.medium))
      .monospacedDigit()
      .foregroundStyle(Theme.text)
  }
}

/// Side by side normally; stacked at accessibility text sizes (a plot beside readouts would
/// squeeze large text).
struct AdaptiveStack<Content: View>: View {
  var spacing: CGFloat = 14
  @ViewBuilder var content: Content
  @Environment(\.dynamicTypeSize) private var typeSize

  var body: some View {
    if typeSize.isAccessibilitySize {
      VStack(alignment: .leading, spacing: spacing) { content }
    } else {
      HStack(alignment: .top, spacing: spacing) { content }
    }
  }
}

extension View {
  /// A fixed width beside readouts, full width when stacked at accessibility sizes.
  func sideWidth(_ width: CGFloat) -> some View { modifier(SideWidth(width: width)) }
}

private struct SideWidth: ViewModifier {
  let width: CGFloat
  @Environment(\.dynamicTypeSize) private var typeSize

  func body(content: Content) -> some View {
    if typeSize.isAccessibilitySize {
      content.frame(maxWidth: .infinity)
    } else {
      content.frame(width: width)
    }
  }
}
