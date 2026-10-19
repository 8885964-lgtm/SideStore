//
//  WiFiReachability.swift
//  SideStore
//
//  A one-shot check of whether the device's current network path uses Wi-Fi.
//

import Foundation
import Network

enum WiFiReachability
{
    private final class State: @unchecked Sendable
    {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Bool, Never>?
        let monitor = NWPathMonitor()

        init(continuation: CheckedContinuation<Bool, Never>)
        {
            self.continuation = continuation
        }

        func finish(_ isOnWiFi: Bool)
        {
            self.lock.lock()
            let continuation = self.continuation
            self.continuation = nil
            self.lock.unlock()

            guard let continuation else { return }
            self.monitor.cancel()
            continuation.resume(returning: isOnWiFi)
        }
    }

    /// Whether the current path uses Wi-Fi. If the path can't be read within `timeout`,
    /// this answers true so callers keep their usual (Wi-Fi) behavior.
    static func isOnWiFi(timeout: TimeInterval = 2) async -> Bool
    {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let state = State(continuation: continuation)
            let queue = DispatchQueue(label: "io.sidestore.WiFiReachability")

            state.monitor.pathUpdateHandler = { path in
                state.finish(path.usesInterfaceType(.wifi))
            }
            state.monitor.start(queue: queue)

            queue.asyncAfter(deadline: .now() + timeout) {
                state.finish(true)
            }
        }
    }
}
