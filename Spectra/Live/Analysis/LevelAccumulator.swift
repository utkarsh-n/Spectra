import Foundation
import Synchronization

/// Collects microphone samples into 1024-sample blocks and writes each block's RMS level
/// (dBFS) stamped at its last sample. Touched only on the audio tap's thread, guarded anyway.
nonisolated final class LevelAccumulator: Sendable {
  private let pending = Mutex<[Float]>([])
  static let block = 1024

  func feed(_ values: [Float], start: Double, interval: Double, into level: SignalStream) {
    pending.withLock { buf in
      var i = 0
      while i < values.count {
        let take = min(Self.block - buf.count, values.count - i)
        buf.append(contentsOf: values[i..<(i + take)])
        i += take
        if buf.count == Self.block {
          level.append(LiveAnalysis.levelDBFS(buf[...]), at: start + Double(i - 1) * interval)
          buf.removeAll(keepingCapacity: true)
        }
      }
    }
  }
}
