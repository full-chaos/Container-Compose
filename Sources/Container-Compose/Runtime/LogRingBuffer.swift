//===----------------------------------------------------------------------===//
// Copyright © 2026 Morris Richman and the Container-Compose project authors. All rights reserved.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//   https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//===----------------------------------------------------------------------===//

import Containerization
import Foundation

// MARK: - LogRingBuffer

/// Bounded ring buffer of timestamped log frames that conforms to
/// `Containerization.Writer`. Owned by CHAOS-1346 Phase 1 because the
/// upstream library has no native log replay — `Writer` is push-only at
/// process launch and there is no `since:` parameter on the emitted bytes.
/// Per the Phase 0 spike (`docs/plans/native-api-spike-report.md` §3.2),
/// this is the most significant observability work item we own.
///
/// Concurrency model:
/// - `write(_:)` and `close()` must be SYNCHRONOUS per the upstream
///   `Writer` contract; they cannot become `async` (would force every
///   in-VM byte through an actor hop). We use a small audited locked
///   region (`NSLock`) and mark the class `@unchecked Sendable`, which is
///   the recommended pattern for this constrained case (Oracle review,
///   2026-04-30).
/// - `replay(...)` snapshots a copy under the lock so callers iterate
///   without contending with concurrent writers.
///
/// Capacity is frame-count based (NOT byte-count) so a chatty container
/// cannot evict frames from a quiet one — there is one ring per container.
public final class LogRingBuffer: Writer, @unchecked Sendable {

    // MARK: - Sources

    public enum Source: Sendable, Hashable {
        case stdout
        case stderr
    }

    // MARK: - State (locked)

    private let lock = NSLock()
    private let capacity: Int
    private let source: Source
    private var frames: [RuntimeLogFrame] = []
    private var isClosed: Bool = false

    // MARK: - Init

    public init(source: Source, capacity: Int = 4_096) {
        self.source = source
        self.capacity = max(1, capacity)
        self.frames.reserveCapacity(self.capacity)
    }

    // MARK: - Containerization.Writer

    /// Append a chunk to the buffer. Each invocation produces one frame
    /// timestamped at receipt; we do NOT split on newlines because the
    /// upstream library hands us raw `Data` and the API server's
    /// streaming layer (Phase 2) is responsible for line semantics on the
    /// way out. After append, evict the oldest frames until count ≤
    /// capacity.
    ///
    /// Throws `RuntimeError.backendFailure` only if the writer was
    /// previously closed. The upstream `Writer.write` signature is
    /// `throws`, so propagation lets the runtime mark the container as
    /// errored on the rare write-after-close.
    public func write(_ data: Data) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !isClosed else {
            throw RuntimeError.backendFailure(
                message: "LogRingBuffer write after close"
            )
        }
        frames.append(RuntimeLogFrame(timestamp: Date(), source: source.toRuntimeFrameSource(), data: data))
        if frames.count > capacity {
            frames.removeFirst(frames.count - capacity)
        }
    }

    /// Mark the writer as closed. Subsequent `write` calls throw; replay
    /// keeps working. Called by the runtime when the container exits.
    public func close() throws {
        lock.lock()
        defer { lock.unlock() }
        isClosed = true
    }

    // MARK: - Replay

    /// Snapshot of frames matching `options`. Invoked by `Runtime.logs(...)`
    /// to seed an `AsyncStream` before live frames begin arriving.
    public func replay(options: RuntimeLogOptions = .default) -> [RuntimeLogFrame] {
        lock.lock()
        defer { lock.unlock() }
        var result = frames
        if let since = options.since {
            result = result.filter { $0.timestamp >= since }
        }
        if let tail = options.tail, tail >= 0, tail < result.count {
            result = Array(result.suffix(tail))
        }
        return result
    }

    /// Test affordance: current frame count. Snapshot under the lock.
    public var frameCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return frames.count
    }
}

// MARK: - Source → frame source mapping

private extension LogRingBuffer.Source {
    func toRuntimeFrameSource() -> RuntimeLogFrame.Source {
        switch self {
        case .stdout: return .stdout
        case .stderr: return .stderr
        }
    }
}
