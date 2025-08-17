//
//  ContentView.swift
//  ios-wallet
//
//  Created by Stephan on 2025/08/17.
//

import SwiftUI
import UIKit
#if canImport(Web3)
import Web3
#if canImport(Web3PromiseKit)
import Web3PromiseKit
#endif
#endif
#if canImport(PromiseKit)
import PromiseKit
#if canImport(PromiseKit)
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
#endif
#endif
#if canImport(DawnKeyManagement)
import DawnKeyManagement
#endif
import BigInt

private let appGroupId = "group.co.za.stephancill.ios-wallet" // TODO: set your App Group ID in project capabilities

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
        if let defaults = UserDefaults(suiteName: appGroupId),
           let addr = defaults.string(forKey: "walletAddress"),
           !addr.isEmpty {
            addressHex = addr
            hasWallet = true
        } else {
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
            #if canImport(Web3)
            let pk: EthereumPrivateKey
            if trimmed.lowercased().hasPrefix("0x") {
                pk = try EthereumPrivateKey(hexPrivateKey: trimmed)
            } else {
                pk = try EthereumPrivateKey(hexPrivateKey: "0x" + trimmed)
            }

            #if canImport(DawnKeyManagement)
            let wallet = EthereumWallet(privateKey: pk)
            try wallet.encryptWallet() // stored in Keychain via Secure Enclave
            #endif

            let addr = pk.address.hex(eip55: true)
            addressHex = addr
            hasWallet = true
            if let defaults = UserDefaults(suiteName: appGroupId) {
                defaults.set(addr, forKey: "walletAddress")
            }
            Task { await refreshAllBalances() }
            #else
            errorMessage = "Missing Web3.swift package. Add dependency and rebuild."
            #endif
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func clearWallet() {
        #if canImport(DawnKeyManagement)
        // Optionally, implement a method in DawnKeyManagement to clear keychain entry if exposed
        #endif
        if let defaults = UserDefaults(suiteName: appGroupId) {
            defaults.removeObject(forKey: "walletAddress")
        }
        addressHex = ""
        hasWallet = false
        balances.removeAll()
        errorMessage = nil
    }

    @MainActor
    func refreshAllBalances() async {
        balances["Ethereum"] = "Loading..."
        balances["Base"] = "Loading..."
        balances["Arbitrum One"] = "Loading..."
        balances["Optimism"] = "Loading..."

        await withTaskGroup(of: (String, String).self) { group in
            group.addTask { ("Ethereum", await self.fetchBalance(rpcURL: "https://cloudflare-eth.com")) }
            group.addTask { ("Base", await self.fetchBalance(rpcURL: "https://mainnet.base.org")) }
            group.addTask { ("Arbitrum One", await self.fetchBalance(rpcURL: "https://arb1.arbitrum.io/rpc")) }
            group.addTask { ("Optimism", await self.fetchBalance(rpcURL: "https://mainnet.optimism.io")) }

            for await (network, balance) in group {
                balances[network] = balance
            }
        }
    }

    func fetchBalance(rpcURL: String) async -> String {
        #if canImport(Web3)
        do {
            let web3 = Web3(rpcURL: rpcURL)
            let address = try EthereumAddress(hex: addressHex, eip55: true)
            // Web3PromiseKit exposes Promise-returning API
            let qty: EthereumQuantity = try await web3.eth.getBalance(address: address, block: .latest).async()
            return formatWeiToEth(qty.quantity)
        } catch {
            return "Error"
        }
        #else
        return "Missing Web3.swift"
        #endif
    }

    func formatWeiToEth(_ wei: BigUInt) -> String {
        // 1 ETH = 1e18 wei
        let divisor = BigUInt(1_000_000_000_000_000_000)
        let integer = wei / divisor
        let remainder = wei % divisor

        // Format to 6 decimal places
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

    var body: some View {
        NavigationView {
            Group {
                if vm.hasWallet {
                    walletView
                } else {
                    setupView
                }
            }
            .navigationTitle("iOS Wallet")
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
                    Text(vm.addressHex)
                        .font(.system(.footnote, design: .monospaced))
                        .contextMenu { Button("Copy") { UIPasteboard.general.string = vm.addressHex } }
                }

                Divider()

                Group {
                    Text("Balances")
                        .font(.headline)
                    balanceRow(name: "Ethereum", value: vm.balances["Ethereum"])
                    balanceRow(name: "Base", value: vm.balances["Base"])
                    balanceRow(name: "Arbitrum One", value: vm.balances["Arbitrum One"])
                    balanceRow(name: "Optimism", value: vm.balances["Optimism"])
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
