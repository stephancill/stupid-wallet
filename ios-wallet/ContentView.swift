//
//  ContentView.swift
//  ios-wallet
//
//  Created by Stephan on 2025/08/17.
//

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
    @Published var balances: [String: String] = [:] // network name -> formatted balance
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
        for (name, _, _) in Constants.Networks.networksList { balances[name] = "Loading..." }

        await withTaskGroup(of: (String, String).self) { group in
            for (name, _, url) in Constants.Networks.networksList {
                group.addTask { (name, await self.fetchBalance(rpcURL: url)) }
            }

            for await (network, balance) in group {
                balances[network] = balance
            }
        }
    }

    func fetchBalance(rpcURL: String) async -> String {
        do {
            let web3 = Web3(rpcURL: rpcURL)
            let address = try EthereumAddress(hex: addressHex, eip55: true)
            let qty: EthereumQuantity = try await web3.eth.getBalance(address: address, block: .latest).async()
            return formatWeiToEth(qty.quantity)
        } catch {
            return "Error"
        }
    }

    func formatWeiToEth(_ wei: BigUInt) -> String {
        let divisor = BigUInt(1_000_000_000_000_000_000)
        let integer = wei / divisor
        let remainder = wei % divisor
        let remainderStr = String(remainder).leftPadded(to: 18)
        let decimals = String(remainderStr.prefix(6))
        return "\(integer).\(decimals) ETH"
    }

    @MainActor
    func resolveENS() async {
        guard !addressHex.isEmpty else { return }
        
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

struct ContentView: View {
    @StateObject private var vm = WalletViewModel()
    @State private var didCopyAddress = false
    @State private var showClearWalletConfirmation = false

    // Generate blockies image for the address
    private func blockiesImage(for address: String, size: CGFloat = 24) -> Image? {
        guard !address.isEmpty else { return nil }

        let scale = max(5, Int(size) / 8)
        let blockies = Blockies(seed: address.lowercased(), size: 8, scale: scale)
        guard let uiImage = blockies.createImage() else { return nil }

        return Image(uiImage: uiImage)
    }

    // Profile image view that shows ENS avatar or falls back to blockies
    @ViewBuilder
    private func profileImage(size: CGFloat = 24) -> some View {
        if let avatarURL = vm.ensAvatarURL, let url = URL(string: avatarURL) {
            AsyncImage(url: url) { image in
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } placeholder: {
                if let blockies = blockiesImage(for: vm.addressHex, size: size) {
                    blockies
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.gray.opacity(0.3))
                }
            }
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(Color.gray.opacity(0.2), lineWidth: 1)
            )
        } else if let blockies = blockiesImage(for: vm.addressHex, size: size) {
            blockies
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color.gray.opacity(0.2), lineWidth: 1)
                )
        }
    }

    // Truncate address to show first and last 4 characters
    private func truncatedAddress(_ address: String) -> String {
        guard address.hasPrefix("0x") && address.count > 10 else { return address }
        let startIndex = address.index(address.startIndex, offsetBy: 2)
        let endIndex = address.index(address.endIndex, offsetBy: -4)
        let first4 = address[startIndex..<address.index(startIndex, offsetBy: 4)]
        let last4 = address[endIndex..<address.endIndex]
        return "0x\(first4)...\(last4)"
    }

    var body: some View {
        NavigationView {
            Group {
                if vm.hasWallet {
                    walletView
                } else {
                    setupView
                }
            }
            .navigationTitle("stupid wallet")
        }
        .sheet(isPresented: $vm.showPrivateKeySheet) {
            privateKeySheet
        }
    }

    private var setupView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Enter Private Key (hex)")
                .font(.headline)
            SecureField("0x...", text: $vm.privateKeyInput)
                .textInputAutocapitalization(.never)
                .disableAutocorrection(true)
                .textFieldStyle(.roundedBorder)
            Button(action: { vm.savePrivateKey() }) {
                if vm.isSaving { ProgressView() } else { Text("Save") }
            }
            .buttonStyle(.borderedProminent)

            Button(action: { vm.createNewWallet() }) {
                if vm.isSaving { ProgressView() } else { Text("Create New Wallet") }
            }
            .buttonStyle(.bordered)

            if let err = vm.errorMessage, !err.isEmpty {
                Text(err)
                    .foregroundColor(.red)
                    .font(.footnote)
            }
            Spacer()
        }
        .padding()
    }

    private var walletView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Group {
                    Text("Address")
                        .font(.headline)
                    HStack(alignment: .center, spacing: 8) {
                        profileImage(size: 32)
                        
                        VStack(alignment: .leading, spacing: 2) {
                            if let ensName = vm.ensName, !ensName.isEmpty {
                                Text(ensName)
                                    .font(.system(.body, design: .default))
                                    .foregroundColor(.primary)
                                Text(truncatedAddress(vm.addressHex))
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundColor(.secondary)
                            } else {
                                Text(truncatedAddress(vm.addressHex))
                                    .font(.system(.footnote, design: .monospaced))
                            }
                        }
                        Spacer()
                        Button(action: {
                            UIPasteboard.general.string = vm.addressHex
                            didCopyAddress = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                                didCopyAddress = false
                            }
                        }) {
                            Image(systemName: didCopyAddress ? "checkmark" : "doc.on.doc")
                        }
                    }
                    
                }

                Divider()

                Group {
                    Text("Balances")
                        .font(.headline)
                    ForEach(Constants.Networks.networksList, id: \.name) { net in
                        balanceRow(name: net.name, value: vm.balances[net.name])
                    }
                }

                Divider()

                VStack(spacing: 12) {
                    HStack {
                        Button(action: { vm.revealPrivateKey() }) {
                            if vm.isRevealingPrivateKey {
                                ProgressView()
                            } else {
                                Text("Show Private Key")
                            }
                        }
                        Spacer()
                    }
                    


                    HStack {
                        Button(role: .destructive, action: { showClearWalletConfirmation = true }) {
                            Text("Clear Wallet")
                        }
                        Spacer()
                    }
                    .confirmationDialog(
                        "Clear Wallet",
                        isPresented: $showClearWalletConfirmation,
                        titleVisibility: .visible
                    ) {
                        Button("Clear Wallet", role: .destructive) {
                            vm.clearWallet()
                        }
                        Button("Cancel", role: .cancel) { }
                    } message: {
                        Text("This will permanently delete your wallet and private key from this device. Make sure you have backed up your private key before proceeding.")
                    }
                }

                if let error = vm.privateKeyError, !error.isEmpty {
                    Text("Error: \(error)")
                        .foregroundColor(.red)
                        .font(.footnote)
                }
            }
            .padding()
        }
        .refreshable {
            await vm.refreshAllBalances()
            await vm.resolveENS()
        }
    }

    private func balanceRow(name: String, value: String?) -> some View {
        HStack {
            Text(name)
            Spacer()
            Text(value ?? "–")
                .font(.system(.footnote, design: .monospaced))
        }
    }

    private var privateKeySheet: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Label {
                        Text("Security Warning")
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                    }
                    .font(.headline)

                    Text("Your private key gives full access to your wallet and funds. Never share it with anyone, and keep it secure.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
            }

            Section("Private Key") {
                if !vm.revealedPrivateKey.isEmpty {
                    Text(vm.revealedPrivateKey)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(nil)
                        .padding(.vertical, 4)
                } else {
                    Text("No private key available")
                        .foregroundColor(.secondary)
                }

                Button(action: { vm.copyPrivateKey() }) {
                    Image(systemName: vm.didCopyPrivateKey ? "checkmark" : "doc.on.doc")
                }
                .frame(maxWidth: .infinity, alignment: .center)
            }

            if let error = vm.privateKeyError, !error.isEmpty {
                Section {
                    Text("Error: \(error)")
                        .foregroundColor(.red)
                }
            }
        }
        .navigationTitle("Private Key")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("Done") {
                    vm.showPrivateKeySheet = false
                    vm.revealedPrivateKey = "" // Clear for security
                }
            }
        }
    }
}

#Preview {
    ContentView()
}
