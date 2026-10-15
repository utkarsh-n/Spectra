import SwiftUI
import UIKit

/// Shows `content` while a sensor runs, and otherwise the honest state (house rules: ask on
/// the tap that needs it, never at launch; on denial explain and offer Open Settings):
/// - idle → a "Start …" button whose tap requests permission;
/// - requesting → "Asking…";
/// - denied → `ContentUnavailableView` with Open Settings (`.glassProminent`);
/// - unavailable / locked → `ContentUnavailableView` with the one-line reason.
///
/// ```swift
/// PermissionGate(channel: app.live.channel(.microphone), startTitle: "Listen") { MicSpectrum() }
/// ```
struct PermissionGate<Content: View>: View {
  let title: String
  let symbol: String
  let state: SensorState
  var startTitle = "Start"
  /// Plain sentence of what starting does ("Spectra listens to draw a live spectrum.").
  var explanation: String = ""
  /// The source waits for another device (UWB): `.locked` reads "needs a peer", not "locked".
  var needsPeer = false
  let start: () async -> Void
  @ViewBuilder var content: Content

  @Environment(\.openURL) private var openURL

  var body: some View {
    switch state {
    case .running:
      content
    case .idle:
      ContentUnavailableView {
        Label(title, systemImage: symbol)
      } description: {
        if !explanation.isEmpty { Text(explanation) }
      } actions: {
        Button(startTitle) {
          Haptics.shared.tap()
          Task { await start() }
        }
        .buttonStyle(.glassProminent)
        .accessibilityIdentifier("permission-start")
      }
    case .requesting:
      ContentUnavailableView {
        Label("Asking…", systemImage: symbol)
      } description: {
        Text("Answer the system prompt to continue.")
      }
    case .denied:
      ContentUnavailableView {
        Label("\(title) is off", systemImage: symbol)
      } description: {
        Text("Spectra needs access to show this live. You can turn it on in Settings; the simulated view keeps working.")
      } actions: {
        Button("Open Settings") {
          Haptics.shared.tap()
          if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
        }
        .buttonStyle(.glassProminent)
        .accessibilityIdentifier("permission-open-settings")
      }
    case .unavailable(let reason):
      ContentUnavailableView {
        Label("\(title) unavailable", systemImage: "exclamationmark.triangle")
      } description: {
        Text(reason)
      }
    case .locked(let reason) where needsPeer:
      ContentUnavailableView {
        Label("\(title) needs a peer", systemImage: "person.2.fill")
      } description: {
        Text(reason)
      }
    case .locked(let reason):
      ContentUnavailableView {
        Label("\(title) is locked", systemImage: "lock.fill")
      } description: {
        Text(reason)
      }
    }
  }
}

extension PermissionGate {
  /// Gate on a channel: uses its title, symbol and state, and starts it.
  init(channel: any SensorChannel, startTitle: String = "Start", explanation: String = "", @ViewBuilder content: () -> Content) {
    self.init(
      title: channel.title, symbol: channel.symbol, state: channel.state, startTitle: startTitle,
      explanation: explanation, needsPeer: channel.provenance == .needsPeer, start: { await channel.start() },
      content: content)
  }
}
