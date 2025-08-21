//
//  ContentView.swift
//  ios-wallet
//
//  Created by Stephan on 2025/08/17.
//

import SwiftUI
import UIKit
import Security
import Web3
import Web3PromiseKit
import PromiseKit
import BigInt

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

    init() {
        loadPersistedAddress()
        if hasWallet {
            Task { await refreshAllBalances() }
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
            // Build Web3 key for address derivation
            let pk: EthereumPrivateKey
            if trimmed.lowercased().hasPrefix("0x") {
                pk = try EthereumPrivateKey(hexPrivateKey: trimmed)
            } else {
                pk = try EthereumPrivateKey(hexPrivateKey: "0x" + trimmed)
            }

            // Encrypt and store securely via KeyManagement helper
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
            try KeyManagement.encryptPrivateKey(rawBytes: rawBytes)

            let addr = pk.address.hex(eip55: true)
            addressHex = addr
            hasWallet = true
            if let defaults = UserDefaults(suiteName: appGroupId) {
                defaults.set(addr, forKey: "walletAddress")
                print("[Wallet] Saved address to app group store")
            } else {
                print("[Wallet] ERROR: Could not open app group defaults to save address")
            }
            Task { await refreshAllBalances() }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func createNewWallet() {
        errorMessage = nil
        isSaving = true
        defer { isSaving = false }

        do {
            let wallet = try KeyManagement.createWallet()
            addressHex = try wallet.address.eip55Description
            hasWallet = true
            if let defaults = UserDefaults(suiteName: appGroupId) {
                defaults.set(addressHex, forKey: "walletAddress")
                print("[Wallet] Saved address to app group store (new wallet)")
            } else {
                print("[Wallet] ERROR: Could not open app group defaults to save new wallet")
            }
            Task { await refreshAllBalances() }
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
        errorMessage = nil
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
            .toolbar {
                if vm.hasWallet {
                    Button("Refresh") { Task { await vm.refreshAllBalances() } }
                }
            }
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
                        Text(vm.addressHex)
                            .font(.system(.footnote, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button(action: {
                            UIPasteboard.general.string = vm.addressHex
                            didCopyAddress = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                                didCopyAddress = false
                            }
                        }) {
                            if didCopyAddress {
                                Label("Copied", systemImage: "checkmark")
                            } else {
                                Label("Copy", systemImage: "doc.on.doc")
                            }
                        }
                        .buttonStyle(.bordered)
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

                Button(role: .destructive, action: { vm.clearWallet() }) {
                    Text("Clear Wallet")
                }
            }
            .padding()
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
}

#Preview {
    ContentView()
}
