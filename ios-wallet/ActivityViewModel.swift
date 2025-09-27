import Foundation
import Combine
import BigInt

final class ActivityViewModel: ObservableObject {
    @Published var items: [ActivityStore.ActivityItem] = []
    @Published var isLoading: Bool = false

    private var pollTask: Task<Void, Never>? = nil
    private let maxConcurrentChecks = 5
    private let pageSize = 50

    func loadLatest(limit: Int? = nil, offset: Int = 0) {
        isLoading = true
        let l = limit ?? pageSize
        DispatchQueue.global(qos: .userInitiated).async {
            let result: [ActivityStore.ActivityItem]
            do {
                result = try ActivityStore.shared.fetchTransactions(limit: l, offset: offset)
            } catch {
                result = []
            }
            DispatchQueue.main.async {
                self.items = result
                self.isLoading = false
            }
        }
    }

    func startPolling() {
        stopPolling()
        pollTask = Task { [weak self] in
            guard let self = self else { return }
            // Backoff schedule in seconds: 5s (x12 -> 60s), 15s (x24 -> 6m), 30s thereafter
            var iterations = 0
            while !Task.isCancelled {
                await self.pollPendingOnce()
                iterations += 1
                let delay: UInt64
                if iterations <= 12 { delay = 5 }
                else if iterations <= 12 + 24 { delay = 15 }
                else { delay = 30 }
                try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    @MainActor
    private func updateItemStatus(txHash: String, newStatus: String) {
        if let idx = items.firstIndex(where: { $0.txHash == txHash }) {
            let old = items[idx]
            if old.status != newStatus {
                let updated = ActivityStore.ActivityItem(
                    txHash: old.txHash,
                    app: old.app,
                    chainIdHex: old.chainIdHex,
                    method: old.method,
                    fromAddress: old.fromAddress,
                    createdAt: old.createdAt,
                    status: newStatus
                )
                items[idx] = updated
            }
        }
    }

    private func pollPendingOnce() async {
        // Take a snapshot to avoid races with UI updates
        let snapshot = await MainActor.run { items }
        let pending = snapshot.filter { $0.status == "pending" }
        guard !pending.isEmpty else { return }

        // Group by chain for RPC URL selection
        let grouped = Dictionary(grouping: pending, by: { $0.chainIdHex.lowercased() })

        // Semaphore for bounded concurrency
        let semaphore = AsyncSemaphore(value: maxConcurrentChecks)
        await withTaskGroup(of: Void.self) { group in
            for (_, groupItems) in grouped {
                for item in groupItems {
                    group.addTask { [weak self] in
                        await semaphore.wait()
                        guard let self = self else { await semaphore.signal(); return }
                        do {
                            let newStatus = try await self.checkReceiptStatus(txHash: item.txHash, chainIdHex: item.chainIdHex)
                            if newStatus != "pending" {
                                // Persist and update UI
                                try? ActivityStore.shared.updateTransactionStatus(txHash: item.txHash, status: newStatus)
                            }
                            await MainActor.run {
                                self.updateItemStatus(txHash: item.txHash, newStatus: newStatus)
                            }
                        } catch {
                            // On transient errors, keep pending
                        }
                        await semaphore.signal()
                    }
                }
            }
        }
    }

    private func checkReceiptStatus(txHash: String, chainIdHex: String) async throws -> String {
        let clean = chainIdHex.hasPrefix("0x") ? String(chainIdHex.dropFirst(2)) : chainIdHex
        let chainId = BigUInt(clean, radix: 16) ?? BigUInt(1)
        let rpcURLString = Constants.Networks.rpcURL(forChainId: chainId)
        guard let rpcURL = URL(string: rpcURLString) else { return "pending" }

        // eth_getTransactionReceipt
        typealias Receipt = [String: Any]
        let params: [Any] = [txHash]
        do {
            let result: Any = try await JSONRPC.request(rpcURL: rpcURL, method: "eth_getTransactionReceipt", params: params, timeout: 20)
            // If result is NSNull or nil -> pending
            if result is NSNull { return "pending" }
            guard let dict = result as? [String: Any] else { return "pending" }
            // Read status field: 0x1 -> confirmed, 0x0 -> failed
            if let statusHex = dict["status"] as? String {
                let normalized = statusHex.lowercased()
                if normalized == "0x1" { return "confirmed" }
                if normalized == "0x0" { return "failed" }
            }
            // Some RPCs omit status for legacy chains; treat presence as confirmed
            return "confirmed"
        } catch {
            // Treat errors as pending unless clearly permanent
            return "pending"
        }
    }
}

// Lightweight async semaphore for bounded concurrency
private actor AsyncSemaphore {
    private let maxCount: Int
    private var value: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(value: Int) {
        self.maxCount = value
        self.value = value
    }

    func wait() async {
        if value > 0 { value -= 1; return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            waiters.append(continuation)
        }
    }

    func signal() {
        if let first = waiters.first {
            waiters.removeFirst()
            first.resume()
        } else {
            value = min(value + 1, maxCount)
        }
    }
}


