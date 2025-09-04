//
//  AuthorizationsListView.swift
//  ios-wallet
//
//  Created by Stephan Cilliers on 2025/01/14.
//

import SwiftUI
import BigInt
import Web3
import Web3PromiseKit

struct AuthorizationsListView: View {
    let address: String

    @State private var authorizationStatuses: [AuthorizationsUtil.AuthorizationStatus] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var resettingChainId: BigUInt?
    @State private var upgradingChainId: BigUInt?

    private var upgradedChains: [AuthorizationsUtil.AuthorizationStatus] {
        authorizationStatuses.filter { $0.hasAuthorization }
    }

    private var notUpgradedChains: [AuthorizationsUtil.AuthorizationStatus] {
        authorizationStatuses.filter { !$0.hasAuthorization && $0.error == nil }
    }

    var body: some View {
        List {
            if isLoading {
                HStack {
                    Spacer()
                    ProgressView("Checking authorizations...")
                    Spacer()
                }
            } else if let error = errorMessage {
                HStack {
                    Spacer()
                    Text("Error: \(error)")
                        .foregroundColor(.red)
                        .multilineTextAlignment(.center)
                    Spacer()
                }
            } else {
                // Upgraded section
                if !upgradedChains.isEmpty {
                    Section(header: Text("Upgraded").font(.headline)) {
                        ForEach(upgradedChains, id: \.chainId) { status in
                            chainRow(for: status, isUpgraded: true)
                        }
                    }
                }

                // Not upgraded section
                if !notUpgradedChains.isEmpty {
                    Section(header: Text("Not upgraded yet").font(.headline)) {
                        ForEach(notUpgradedChains, id: \.chainId) { status in
                            chainRow(for: status, isUpgraded: false)
                        }
                    }
                }
            }
        }
        .navigationTitle("EIP-7702 Authorizations")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await loadAuthorizations()
        }
        .refreshable {
            await loadAuthorizations()
        }
    }

    private func chainRow(for status: AuthorizationsUtil.AuthorizationStatus, isUpgraded: Bool) -> some View {
        HStack {
            Text(status.chainName)
                .font(.body)
            Spacer()
            if resettingChainId == status.chainId || upgradingChainId == status.chainId {
                ProgressView()
                    .scaleEffect(0.8)
            } else {
                Button(isUpgraded ? "Reset" : "Upgrade") {
                    Task {
                        if isUpgraded {
                            await resetAuthorization(for: status.chainId)
                        } else {
                            await upgradeAuthorization(for: status.chainId)
                        }
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }


    private func loadAuthorizations() async {
        isLoading = true
        errorMessage = nil

        do {
            authorizationStatuses = try await AuthorizationsUtil.checkAllAuthorizations(for: address)
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    private func resetAuthorization(for chainId: BigUInt) async {
        resettingChainId = chainId

        do {
            let txHash = try await AuthorizationsUtil.resetAuthorization(for: address, on: chainId)
            // Wait for transaction confirmation before refreshing
            try await waitForTransactionConfirmation(txHash: txHash, chainId: chainId)
            // Reload authorizations to show updated status
            await loadAuthorizations()
        } catch {
            errorMessage = "Failed to reset authorization: \(error.localizedDescription)"
        }

        resettingChainId = nil
    }

    private func upgradeAuthorization(for chainId: BigUInt) async {
        upgradingChainId = chainId

        do {
            let txHash = try await AuthorizationsUtil.upgradeAuthorization(for: address, on: chainId)
            // Wait for transaction confirmation before refreshing
            try await waitForTransactionConfirmation(txHash: txHash, chainId: chainId)
            // Reload authorizations to show updated status
            await loadAuthorizations()
        } catch {
            errorMessage = "Failed to upgrade authorization: \(error.localizedDescription)"
        }

        upgradingChainId = nil
    }

    private func waitForTransactionConfirmation(txHash: String, chainId: BigUInt, timeout: TimeInterval = 120.0) async throws {
        let rpcURLString = Constants.Networks.rpcURL(forChainId: chainId)
        guard let rpcURL = URL(string: rpcURLString) else {
            throw NSError(domain: "Authorization", code: 10, userInfo: [NSLocalizedDescriptionKey: "Invalid RPC URL: \(rpcURLString)"])
        }

        let startTime = Date()
        var consecutiveFailures = 0
        let maxConsecutiveFailures = 3

        print("Waiting for transaction confirmation: \(txHash) on chain \(chainId) using \(rpcURLString)")

        while Date().timeIntervalSince(startTime) < timeout {
            do {
                let receipt = try await AuthorizationsUtil.getTransactionReceipt(txHash: txHash, rpcURL: rpcURL, timeout: 15.0)

                consecutiveFailures = 0 // Reset failure counter on success
                if receipt != nil {
                    // Transaction is confirmed
                    print("✅ Transaction confirmed: \(txHash)")
                    // Wait 1 second before triggering refresh to allow blockchain state to propagate
                    try await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
                    return
                }
                // Transaction not yet mined, wait a bit longer between polls
                try await Task.sleep(nanoseconds: 5_000_000_000) // 5 seconds
            } catch {
                consecutiveFailures += 1
                print("⚠️ RPC call failed (\(consecutiveFailures)/\(maxConsecutiveFailures)): \(error.localizedDescription)")

                if consecutiveFailures >= maxConsecutiveFailures {
                    throw NSError(domain: "Authorization", code: 5, userInfo: [NSLocalizedDescriptionKey: "Failed to check transaction confirmation after \(consecutiveFailures) consecutive RPC failures: \(error.localizedDescription)"])
                }

                // Wait a bit longer before retrying after failure
                try await Task.sleep(nanoseconds: 3_000_000_000) // 3 seconds
            }
        }

        throw NSError(domain: "Authorization", code: 6, userInfo: [NSLocalizedDescriptionKey: "Transaction confirmation timeout after \(timeout) seconds"])
    }
}


#Preview {
    NavigationView {
        AuthorizationsListView(address: "0x742d35Cc6634C0532925a3b844Bc454e4438f44e")
    }
}
