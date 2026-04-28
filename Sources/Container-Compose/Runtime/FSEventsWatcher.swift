//===----------------------------------------------------------------------===//
// Copyright © 2025 Morris Richman and the Container-Compose project authors. All rights reserved.
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

import CoreServices
import Foundation

// MARK: - FSEvent

public enum ChangeKind: Sendable, Equatable {
    case created
    case modified
    case removed
    case renamed
    case rootChanged
}

public typealias FSEvent = (path: String, kind: ChangeKind)

// MARK: - FSWatcher

public protocol FSWatcher: Sendable {
    func watch(paths: [String]) -> AsyncStream<FSEvent>
}

// MARK: - FSWatcherEnvironment

public enum FSWatcherEnvironment {
    @TaskLocal public static var current: any FSWatcher = FSEventsWatcher()
}

// MARK: - FSEventsWatcher

public actor FSEventsWatcher: FSWatcher {
    /// FSEvents stream latency and the app-side burst coalescing window.
    /// 100ms keeps compose-watch visibly sub-second while collapsing common
    /// editor atomic-write bursts (create temp file, rename, metadata update)
    /// into one action per path.
    public static let coalesceInterval: TimeInterval = 0.1

    private var handles: [ObjectIdentifier: FSEventStreamHandle] = [:]

    public init() {}

    public nonisolated func watch(paths: [String]) -> AsyncStream<FSEvent> {
        AsyncStream { continuation in
            let handle = FSEventStreamHandle(
                paths: paths,
                coalesceInterval: Self.coalesceInterval,
                continuation: continuation
            )

            Task { await self.register(handle) }
            handle.start()

            continuation.onTermination = { _ in
                Task { await self.stop(handle) }
            }
        }
    }

    deinit {
        for handle in handles.values {
            handle.stop()
        }
    }

    private func register(_ handle: FSEventStreamHandle) {
        handles[ObjectIdentifier(handle)] = handle
    }

    private func stop(_ handle: FSEventStreamHandle) {
        handle.stop()
        handles.removeValue(forKey: ObjectIdentifier(handle))
    }
}

// MARK: - FSEventStreamHandle

private final class FSEventStreamHandle: @unchecked Sendable {
    private let paths: [String]
    private let coalesceInterval: TimeInterval
    private let queue = DispatchQueue(label: "container-compose.fsevents")
    private let lock = NSLock()

    private var continuation: AsyncStream<FSEvent>.Continuation?
    private var stream: FSEventStreamRef?
    private var pending: [String: ChangeKind] = [:]
    private var flushTask: Task<Void, Never>?
    private var stopped = false

    init(
        paths: [String],
        coalesceInterval: TimeInterval,
        continuation: AsyncStream<FSEvent>.Continuation
    ) {
        self.paths = paths
        self.coalesceInterval = coalesceInterval
        self.continuation = continuation
    }

    func start() {
        let watchedPaths = paths as CFArray
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagUseCFTypes |
                kFSEventStreamCreateFlagFileEvents |
                kFSEventStreamCreateFlagNoDefer
        )

        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            fseventsCallback,
            &context,
            watchedPaths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            coalesceInterval,
            flags
        ) else {
            continuation?.finish()
            return
        }

        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, queue)

        guard FSEventStreamStart(stream) else {
            stop()
            continuation?.finish()
            return
        }
    }

    func stop() {
        lock.lock()
        guard !stopped else {
            lock.unlock()
            return
        }
        stopped = true
        let stream = stream
        self.stream = nil
        let flushTask = flushTask
        self.flushTask = nil
        let continuation = continuation
        self.continuation = nil
        pending.removeAll()
        lock.unlock()

        flushTask?.cancel()

        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }

        continuation?.finish()
    }

    func enqueue(paths: [String], flags: [FSEventStreamEventFlags]) {
        guard !paths.isEmpty else { return }

        lock.lock()
        guard !stopped else {
            lock.unlock()
            return
        }

        for (index, path) in paths.enumerated() {
            let eventFlags = index < flags.count ? flags[index] : 0
            pending[path] = Self.kind(for: eventFlags)
        }

        if flushTask == nil {
            let nanoseconds = UInt64(coalesceInterval * 1_000_000_000)
            flushTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: nanoseconds)
                self?.flushPending()
            }
        }
        lock.unlock()
    }

    private func flushPending() {
        lock.lock()
        guard !stopped else {
            flushTask = nil
            lock.unlock()
            return
        }

        let events = pending
            .map { path, kind in FSEvent(path: path, kind: kind) }
            .sorted { $0.path < $1.path }
        pending.removeAll()
        flushTask = nil
        let continuation = continuation
        lock.unlock()

        for event in events {
            continuation?.yield(event)
        }
    }

    private static func kind(for flags: FSEventStreamEventFlags) -> ChangeKind {
        if flags.containsFSEventFlag(kFSEventStreamEventFlagItemRenamed) {
            return .renamed
        }
        if flags.containsFSEventFlag(kFSEventStreamEventFlagItemRemoved) {
            return .removed
        }
        if flags.containsFSEventFlag(kFSEventStreamEventFlagItemCreated) {
            return .created
        }
        if flags.containsFSEventFlag(kFSEventStreamEventFlagRootChanged) {
            return .rootChanged
        }
        return .modified
    }
}

private let fseventsCallback: FSEventStreamCallback = { _, clientCallBackInfo, eventCount, eventPaths, eventFlags, _ in
    guard let clientCallBackInfo else { return }

    let handle = Unmanaged<FSEventStreamHandle>
        .fromOpaque(clientCallBackInfo)
        .takeUnretainedValue()
    let cfPaths = Unmanaged<CFArray>
        .fromOpaque(eventPaths)
        .takeUnretainedValue()

    let pathCount = min(eventCount, CFArrayGetCount(cfPaths))
    var paths: [String] = []
    paths.reserveCapacity(pathCount)

    for index in 0..<pathCount {
        guard let rawValue = CFArrayGetValueAtIndex(cfPaths, index) else { continue }
        let cfString = unsafeBitCast(rawValue, to: CFString.self)
        paths.append(cfString as String)
    }

    let flags = (0..<eventCount).map { eventFlags[$0] }
    handle.enqueue(paths: paths, flags: flags)
}

private extension FSEventStreamEventFlags {
    func containsFSEventFlag(_ flag: Int) -> Bool {
        self & FSEventStreamEventFlags(flag) != 0
    }
}
