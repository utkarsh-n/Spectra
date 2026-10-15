import Foundation
import Observation

/// One live source (or its simulated stand-in). `SensorHub` owns one per `SensorID`.
///
/// Channels request permission on demand inside `start()` (on the tap that needs it, never at
/// launch), publish their `SignalStream`s into `AppModel.streams` while running and remove
/// them on `stop()`. Samples carry the sensor's own timestamps.
///
/// Refinements to SPEC.md §3.5 (additive): `streams`, `markers` and `primaryReadout`, so
/// cards, the census and the Spectrum strip can show a channel without knowing its type.
@MainActor
protocol SensorChannel: AnyObject, Observable {
  var id: SensorID { get }
  /// `.live` when real, `.sim` when faked, `.locked` / `.needsPeer` when unavailable.
  var provenance: Provenance { get }
  var state: SensorState { get }
  /// Hz, measured from sample timestamps (nil until there are samples, or for event streams).
  var measuredRate: Double? { get }
  /// Streams currently published by this channel (empty when stopped).
  var streams: [SignalStream] { get }
  /// Where this source sits on the spectrum while it runs (empty if it has no frequency).
  var markers: [SpectrumMarker] { get }
  /// The headline reading ("48.2 µT", "6 radios · −52 dBm"), refreshed at about 2 Hz.
  var primaryReadout: String? { get }
  /// Requests permission if needed, then starts updates.
  func start() async
  func stop()
}

extension SensorChannel {
  var title: String { id.title }
  var symbol: String { id.symbol }
}
