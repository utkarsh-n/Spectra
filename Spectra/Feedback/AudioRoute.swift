import AVFoundation

/// The single owner of the audio session category (from Gyre). The synth alone plays as
/// `.ambient` (the silent switch mutes it, other audio keeps playing); while the microphone
/// listens the session is `.playAndRecord` in `.measurement` mode (no voice processing or
/// automatic gain), still mixing with others.
@MainActor
enum AudioRoute {
  /// Set by the microphone source while it listens.
  static var recording = false {
    didSet { if recording != oldValue { apply() } }
  }
  /// Set by `HumSynth` while it plays.
  static var playing = false

  /// Applies the category for the current state and activates the session.
  static func apply() {
    let session = AVAudioSession.sharedInstance()
    do {
      if recording {
        try session.setCategory(
          .playAndRecord, mode: .measurement, options: [.mixWithOthers, .defaultToSpeaker, .allowBluetoothA2DP])
      } else {
        try session.setCategory(.ambient, mode: .default, options: [.mixWithOthers])
      }
      if recording || playing { try session.setActive(true) }
    } catch {
      // The session can refuse while another app holds it; the next apply() retries.
    }
  }

  /// True when output goes to headphones or a Bluetooth A2DP device, so live duplex
  /// (mic in, speaker out) cannot feed back (`gyre-integration.md` §4.4).
  static var isPrivateOutput: Bool {
    AVAudioSession.sharedInstance().currentRoute.outputs.contains { output in
      [.headphones, .bluetoothA2DP, .bluetoothLE, .bluetoothHFP, .usbAudio].contains(output.portType)
    }
  }
}
