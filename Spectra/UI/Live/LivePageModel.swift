import Foundation
import Observation
import SwiftUI

/// The Live tab's two pages (`.pickerStyle(.tabs)`).
enum LivePage: String, CaseIterable, Identifiable {
  case sensors, scope
  var id: String { rawValue }
  var title: String { self == .sensors ? "Sensors" : "Scope" }
}

/// The cards of the Sensors page, in SPEC-features §3 order (Motion added before the two
/// radios that need a peer or a paid team).
enum LiveCardID: String, CaseIterable, Identifiable {
  case antennas, bluetooth, network, gnss, magnetometer, microphone, light, air, charging, motion, uwb, nfc

  var id: String { rawValue }

  var number: String { String(format: "%02d", (Self.allCases.firstIndex(of: self) ?? 0) + 1) }

  /// Scroll target (namespaced: rows inside cards use ids such as "gnss" too).
  var scrollID: String { "live-card-" + rawValue }

  var title: String {
    switch self {
    case .antennas: "Your iPhone's antennas"
    case .bluetooth: "Bluetooth"
    case .network: "Cellular & Wi-Fi"
    case .gnss: "Satellites (GNSS)"
    case .magnetometer: "Magnetometer (ELF)"
    case .microphone: "Microphone"
    case .light: "Light meter"
    case .air: "Air"
    case .charging: "Charging"
    case .motion: "Motion"
    case .uwb: "UWB"
    case .nfc: "NFC"
    }
  }

  /// The title when the full one cannot fit the header (large text).
  var shortTitle: String {
    switch self {
    case .antennas: "Antennas"
    case .network: "Cell & Wi-Fi"
    case .gnss: "Satellites"
    case .magnetometer: "Magnetometer"
    case .light: "Light"
    default: title
    }
  }

  /// The card's own source (nil for the antenna map).
  var sensor: SensorID? {
    switch self {
    case .antennas: nil
    case .bluetooth: .bluetooth
    case .network: .network
    case .gnss: .location
    case .magnetometer: .magnetometer
    case .microphone: .microphone
    case .light: .light
    case .air: .barometer
    case .charging: .charging
    case .motion: .motion
    case .uwb: .uwb
    case .nfc: .nfc
    }
  }

  /// Sources a card also reads while visible; they never prompt (Charging watches the
  /// magnetometer for the MagSafe step).
  var helpers: [SensorID] {
    switch self {
    case .charging: [.magnetometer]
    default: []
    }
  }

  /// `-open live/<path>` names: the card id or its sensor id.
  init?(path: String) {
    let key = path.lowercased()
    if let c = Self(rawValue: key) {
      self = c
      return
    }
    guard let c = Self.allCases.first(where: { $0.sensor?.rawValue == key }) else { return nil }
    self = c
  }
}

/// UI state of the Live tab: the page, which cards are on screen, which sources the user
/// started or stopped by hand, and the per-card instruments (turntable, audio spectrum).
/// The tab holds sources as the owner `live-tab` exactly while their card is visible.
@Observable @MainActor
final class LivePageModel {
  var page: LivePage = .sensors
  private(set) var visibleCards: Set<LiveCardID> = []
  /// Sources the user started with a tap (asked for permission); they run while visible.
  private(set) var userStarted: Set<SensorID> = []
  /// Sources the user paused; they stay off until started again.
  private(set) var userStopped: Set<SensorID> = []
  /// The Live tab is the selected tab and on screen.
  var tabVisible = false
  /// The Scope request already followed.
  var lastScopeRequest: UUID?
  /// The Bluetooth radio selected for the turntable and the Scope.
  var selectedRadio: UUID?

  let turntable = TurntableExperiment()
  let audio = AudioSpectrumModel()

  static let owner = "live-tab"

  @ObservationIgnored private var pendingHide: [LiveCardID: Task<Void, Never>] = [:]

  /// Called by each card as it scrolls in and out of view. Leaving is confirmed after 0.6 s,
  /// so a card scrolled briefly past (or a layout hiccup) does not restart its sensor.
  func setVisible(_ card: LiveCardID, _ visible: Bool, hub: SensorHub) {
    if visible {
      pendingHide[card]?.cancel()
      pendingHide[card] = nil
      if visibleCards.insert(card).inserted { sync(hub: hub) }
      return
    }
    guard visibleCards.contains(card), pendingHide[card] == nil else { return }
    pendingHide[card] = Task { [weak self, weak hub] in
      try? await Task.sleep(for: .milliseconds(600))
      guard !Task.isCancelled, let self, let hub else { return }
      self.pendingHide[card] = nil
      if self.visibleCards.remove(card) != nil { self.sync(hub: hub) }
    }
  }

  func isVisible(_ card: LiveCardID) -> Bool { tabVisible && page == .sensors && visibleCards.contains(card) }

  /// Starts a card's source on the user's tap (this is where a permission prompt appears).
  func userStart(_ id: SensorID, hub: SensorHub) {
    userStopped.remove(id)
    userStarted.insert(id)
    hub.acquire(id, by: Self.owner)
    sync(hub: hub)
  }

  /// Pauses a card's source until the user starts it again.
  func userStop(_ id: SensorID, hub: SensorHub) {
    userStarted.remove(id)
    userStopped.insert(id)
    // The turntable holds Bluetooth and motion too: pausing either ends the experiment, or the
    // pause button would do nothing.
    if turntable.running, id == .bluetooth || id == .motion { turntable.stop(hub: hub) }
    sync(hub: hub)
  }

  func isPaused(_ id: SensorID) -> Bool { userStopped.contains(id) }

  /// Clears every manual pause (Dials → Reset dials).
  func clearPauses(hub: SensorHub) {
    userStopped = []
    sync(hub: hub)
  }

  /// Acquires exactly the sources the visible cards need, as `live-tab`.
  func sync(hub: SensorHub) {
    var wanted = Set<SensorID>()
    if tabVisible, page == .sensors {
      for card in visibleCards {
        if let id = card.sensor, !userStopped.contains(id), userStarted.contains(id) || hub.source(id).startsSilently {
          wanted.insert(id)
        }
        for helper in card.helpers where !userStopped.contains(helper) && hub.source(helper).startsSilently {
          wanted.insert(helper)
        }
      }
    }
    for id in SensorID.allCases {
      let held = hub.holders(of: id).contains(Self.owner)
      if wanted.contains(id), !held {
        if case .locked = hub.source(id).state { continue }
        hub.acquire(id, by: Self.owner)
      } else if !wanted.contains(id), held {
        hub.release(id, by: Self.owner)
      }
    }
    if !tabVisible, turntable.running { turntable.stop(hub: hub) }
  }

  /// Everything off (the tab left the screen).
  func releaseAll(hub: SensorHub) {
    tabVisible = false
    sync(hub: hub)
    hub.releaseAll(by: Self.owner)
  }
}

/// The Bluetooth turntable experiment's bookkeeping: pairs each advert of one radio with the
/// phone's yaw at that advert's own timestamp (nearest attitude sample) and bins them.
@Observable @MainActor
final class TurntableExperiment {
  private(set) var running = false
  private(set) var binner = YawBinner()
  private(set) var device: UUID?
  private(set) var deviceName: String?
  @ObservationIgnored private var task: Task<Void, Never>?
  @ObservationIgnored private var lastTime = 0.0

  static let owner = "turntable"

  func start(device: UUID, name: String, hub: SensorHub) {
    stop(hub: hub)
    self.device = device
    deviceName = name
    binner.reset()
    running = true
    lastTime = SignalClock.now()
    hub.acquire(.motion, by: Self.owner)
    hub.acquire(.bluetooth, by: Self.owner)
    // Only the fakes turn by themselves (a phone on a virtual lazy Susan); on a device you turn.
    hub.setSimulatedTurntable(true)
    task = Task { [weak self, weak hub] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .milliseconds(200))
        guard let self, let hub else { return }
        self.ingest(registry: hub.streams)
      }
    }
  }

  func stop(hub: SensorHub) {
    task?.cancel()
    task = nil
    guard running else { return }
    running = false
    hub.setSimulatedTurntable(false)
    hub.release(.motion, by: Self.owner)
    hub.release(.bluetooth, by: Self.owner)
  }

  func reset() {
    binner.reset()
    lastTime = SignalClock.now()
  }

  private func ingest(registry: StreamRegistry) {
    guard let device, let rssi = registry.stream(LiveStreams.bleRSSI(device)),
      let yaw = registry.stream(LiveStreams.attitude[1].id)
    else { return }
    let adverts = rssi.ring.snapshot(since: lastTime)
    guard let first = adverts.times.first, let last = adverts.times.last else { return }
    let poses = yaw.ring.snapshot(since: first - 0.2)
    guard !poses.isEmpty else { return }
    var next = binner
    var j = 0
    for (t, v) in zip(adverts.times, adverts.values) {
      while j < poses.count - 1, abs(poses.times[j + 1] - t) <= abs(poses.times[j] - t) { j += 1 }
      guard abs(poses.times[j] - t) < 0.1 else { continue }
      next.add(yaw: Double(poses.values[j]), rssi: Double(v))
    }
    binner = next
    lastTime = last
  }
}

/// The microphone card's live spectrum and spectrogram: a 4096-point Hann FFT of the newest
/// samples (RF engine analyzer), redrawn while the card is visible.
@Observable @MainActor
final class AudioSpectrumModel {
  private(set) var bins: [Float] = []
  private(set) var sampleRate = 48_000.0
  let waterfall = WaterfallBuffer(width: 192, height: 90, dbRange: -110...(-10))
  @ObservationIgnored private var analyzer = RF.SpectrumAnalyzer(count: 4096)
  @ObservationIgnored private var lastNewest = 0.0

  static let count = 4096
  static let range = 20.0...24_000.0

  func update(_ stream: SignalStream?) {
    guard let stream, analyzer != nil, let latest = stream.ring.latest, latest.time > lastNewest else { return }
    lastNewest = latest.time
    let snap = stream.ring.snapshot(last: Self.count)
    guard snap.count >= Self.count / 2, let rate = snap.measuredRate, rate > 0 else { return }
    sampleRate = stream.nominalRate > 0 ? stream.nominalRate : rate
    // Mutated in place: a local copy would copy the analyzer's work buffers on every update.
    guard let db = analyzer?.realSpectrumDB(snap.values, scaling: .tone, floorDB: -140) else { return }
    bins = db
    waterfall.push(Self.logColumns(db, sampleRate: sampleRate, columns: waterfall.width))
  }

  func clear() {
    bins = []
    waterfall.clear()
    lastNewest = 0
  }

  /// Resamples linear-frequency bins onto log-spaced columns (max per column), so the
  /// spectrogram lines up with the log-frequency spectrum above it.
  static func logColumns(_ db: [Float], sampleRate: Double, columns: Int) -> [Float] {
    guard db.count > 2, columns > 0 else { return [] }
    let binWidth = sampleRate / Double((db.count - 1) * 2)
    let lo = log10(range.lowerBound)
    let hi = log10(min(range.upperBound, sampleRate / 2))
    return (0..<columns).map { c in
      let f0 = pow(10, lo + (hi - lo) * Double(c) / Double(columns))
      let f1 = pow(10, lo + (hi - lo) * Double(c + 1) / Double(columns))
      let a = min(db.count - 1, max(1, Int(f0 / binWidth)))
      let b = min(db.count - 1, max(a, Int(f1 / binWidth)))
      return db[a...b].max() ?? -140
    }
  }
}
