import SwiftUI
import UIKit
import Security
import LocalAuthentication
import Web3
import Web3PromiseKit
import PromiseKit
import BigInt
import Wallet
import Model
import CoreGraphics

private let appGroupId = "group.co.za.stephancill.stupid-wallet" // TODO: set your App Group ID in project capabilities

// Bridge PromiseKit to async/await
extension Promise {
    func async() async throws -> T {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
            self.done { value in
                continuation.resume(returning: value)
            }.catch { error in
                continuation.resume(throwing: error)
            }
        }
    }
}

final class WalletViewModel: ObservableObject {
    @Published var hasWallet: Bool = false
    @Published var addressHex: String = ""
    @Published var privateKeyInput: String = ""
    @Published var isSaving: Bool = false
    @Published var errorMessage: String?
    @Published var balances: [String: BigUInt?] = [:] // network name -> raw balance in wei (nil for loading/error)
    @Published var biometryAvailable: Bool = false

    // Private key reveal functionality
    @Published var showPrivateKeySheet: Bool = false
    @Published var revealedPrivateKey: String = ""
    @Published var isRevealingPrivateKey: Bool = false
    @Published var privateKeyError: String?
    @Published var didCopyPrivateKey: Bool = false

    // ENS properties
    @Published var ensName: String?
    @Published var ensAvatarURL: String?

    init() {
        loadPersistedAddress()
        biometryAvailable = isBiometrySupported()
                    // Ensure ciphertext is available to the Safari extension on first run after updates
            if hasWallet, !addressHex.isEmpty {
                KeyManagement.syncCiphertextToSharedGroupIfNeeded(addressHex: addressHex)
                // Preflight to surface auth prompt on app open
                _ = KeyManagement.preflightAuthentication(addressHex: addressHex)
            }
        // Optimistically load persisted ENS before first render to avoid address flash
        if hasWallet, !addressHex.isEmpty, let persisted = ENSService.shared.loadPersistedENS(for: addressHex) {
            ensName = persisted.ens
            ensAvatarURL = persisted.avatar
        }
        if hasWallet {
            Task {
                await refreshAllBalances()
                await resolveENS()
            }
        }
    }

    func loadPersistedAddress() {
        let defaults = UserDefaults(suiteName: appGroupId)
        if defaults == nil {
            print("[Wallet] ERROR: Failed to open UserDefaults for app group: \(appGroupId)")
        }
        let addr = defaults?.string(forKey: "walletAddress")
        if let addr = addr, !addr.isEmpty {
            print("[Wallet] Loaded address from app group store")
            addressHex = addr
            hasWallet = true
        } else {
            print("[Wallet] No address stored under key 'walletAddress'")
            hasWallet = false
            addressHex = ""
        }
    }



    func isBiometrySupported() -> Bool {
        let ctx = LAContext()
        var err: NSError?
        let ok = ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &err)
        return ok
    }

    func savePrivateKey() {
        errorMessage = nil
        isSaving = true
        defer { isSaving = false }

        let trimmed = privateKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            errorMessage = "Private key is empty"
            return
        }

        do {
            // Convert hex string to bytes
            let hexNoPrefix = trimmed.lowercased().hasPrefix("0x") ? String(trimmed.dropFirst(2)) : trimmed
            var rawBytes: [UInt8] = []
            rawBytes.reserveCapacity(hexNoPrefix.count / 2)
            var idx = hexNoPrefix.startIndex
            while idx < hexNoPrefix.endIndex {
                let next = hexNoPrefix.index(idx, offsetBy: 2)
                let byteStr = hexNoPrefix[idx..<next]
                if let b = UInt8(byteStr, radix: 16) { rawBytes.append(b) }
                idx = next
            }

            // Encrypt and store securely via KeyManagement helper
            try KeyManagement.encryptPrivateKey(rawBytes: rawBytes, requireBiometricsOnly: false)

            // Derive address from the raw bytes using Web3
            let privateKeyData = Data(rawBytes)
            let privateKey = try EthereumPrivateKey(privateKeyData)
            let address = privateKey.address
            let addr = address.hex(eip55: true)
            addressHex = addr
            hasWallet = true
            if let defaults = UserDefaults(suiteName: appGroupId) {
                defaults.set(addr, forKey: "walletAddress")
                print("[Wallet] Saved address to app group store")
            } else {
                print("[Wallet] ERROR: Could not open app group defaults to save address")
            }
            Task {
                await refreshAllBalances()
                await resolveENS()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func createNewWallet() {
        errorMessage = nil
        isSaving = true
        defer { isSaving = false }

        do {
            let wallet = try KeyManagement.createWallet(requireBiometricsOnly: false)
            addressHex = try wallet.address.eip55Description
            hasWallet = true
            if let defaults = UserDefaults(suiteName: appGroupId) {
                defaults.set(addressHex, forKey: "walletAddress")
                print("[Wallet] Saved address to app group store (new wallet)")
            } else {
                print("[Wallet] ERROR: Could not open app group defaults to save new wallet")
            }
            Task {
                await refreshAllBalances()
                await resolveENS()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }



    func clearWallet() {
        // Clear persisted ENS for this address first
        let currentAddress = addressHex
        if !currentAddress.isEmpty {
            ENSService.shared.clearPersistedENS(for: currentAddress)
        }

        if let defaults = UserDefaults(suiteName: appGroupId) {
            defaults.removeObject(forKey: "walletAddress")
            print("[Wallet] Cleared saved address from app group store")
        } else {
            print("[Wallet] ERROR: Could not open app group defaults to clear address")
        }
        addressHex = ""
        hasWallet = false
        balances.removeAll()
        ensName = nil
        ensAvatarURL = nil
        errorMessage = nil
    }

    func revealPrivateKey() {
        privateKeyError = nil
        isRevealingPrivateKey = true
        revealedPrivateKey = ""

        Task {
            do {
                let account = EthereumAccount(address: try Model.EthereumAddress(hex: addressHex))
                let hexKey = try account.accessPrivateKey(accessGroup: Constants.accessGroup) { privateKeyBytes in
                    return "0x" + privateKeyBytes.map { String(format: "%02x", $0) }.joined()
                }

                await MainActor.run {
                    revealedPrivateKey = hexKey
                    showPrivateKeySheet = true
                    isRevealingPrivateKey = false
                }
            } catch {
                await MainActor.run {
                    privateKeyError = error.localizedDescription
                    isRevealingPrivateKey = false
                }
            }
        }
    }

    func copyPrivateKey() {
        guard !revealedPrivateKey.isEmpty else { return }
        UIPasteboard.general.string = revealedPrivateKey
        didCopyPrivateKey = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            self.didCopyPrivateKey = false
        }
    }

    @MainActor
    func refreshAllBalances() async {
        for (name, _, _) in Constants.Networks.networksList { balances[name] = nil } // nil indicates loading

        await withTaskGroup(of: (String, BigUInt?).self) { group in
            for (name, _, url) in Constants.Networks.networksList {
                group.addTask { (name, await self.fetchBalance(rpcURL: url)) }
            }

            for await (network, balance) in group {
                balances[network] = balance
            }
        }
    }

    func fetchBalance(rpcURL: String) async -> BigUInt? {
        do {
            let web3 = Web3(rpcURL: rpcURL)
            let address = try EthereumAddress(hex: addressHex, eip55: true)
            let qty: EthereumQuantity = try await web3.eth.getBalance(address: address, block: .latest).async()
            return qty.quantity
        } catch {
            return nil // nil indicates error
        }
    }

    func formatWeiToEth(_ wei: BigUInt) -> String {
        let divisor = BigUInt(1_000_000_000_000_000_000)
        let integer = wei / divisor
        let remainder = wei % divisor
        let remainderStr = String(remainder).leftPadded(to: 18)
        let decimals = String(remainderStr.prefix(6))
        return "\(integer).\(decimals)"
    }

    func formatBalanceForDisplay(_ balance: BigUInt?) -> String {
        guard let balance = balance else {
            return "Loading..."
        }
        return formatWeiToEth(balance)
    }

    @MainActor
    func resolveENS() async {
        guard !addressHex.isEmpty else { return }

        // Optimistically load from persisted storage
        if let persisted = ENSService.shared.loadPersistedENS(for: addressHex) {
            ensName = persisted.ens
            ensAvatarURL = persisted.avatar
        }

        // Refresh from network and persist
        let ensData = await ENSService.shared.resolveENS(for: addressHex)
        ensName = ensData?.ens
        ensAvatarURL = ensData?.avatar
    }


}

private extension String {
    func leftPadded(to length: Int, with pad: Character = "0") -> String {
        if count >= length { return self }
        return String(repeating: String(pad), count: length - count) + self
    }
}
