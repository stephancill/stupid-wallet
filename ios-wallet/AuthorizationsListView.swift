//
//  AuthorizationsListView.swift
//  ios-wallet
//
//  Created by Stephan Cilliers on 2025/01/14.
//

import SwiftUI
import UIKit
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
    @State private var showingResetConfirmation = false
    @State private var chainToReset: AuthorizationsUtil.AuthorizationStatus?
    @State private var showingUpgradeConfirmation = false
    @State private var chainToUpgrade: AuthorizationsUtil.AuthorizationStatus?
    @State private var showingInfo = false

    private var upgradedChains: [AuthorizationsUtil.AuthorizationStatus] {
        authorizationStatuses.filter { $0.hasAuthorization }
    }

    private var notUpgradedChains: [AuthorizationsUtil.AuthorizationStatus] {
        authorizationStatuses.filter { !$0.hasAuthorization && $0.error == nil }
    }

    var body: some View {
        Form {
            if isLoading {
                Section {
                    HStack {
                        Spacer()
                        VStack(spacing: 12) {
                            ProgressView()
                                .scaleEffect(1.2)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 20)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
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
                    Section("Upgraded") {
                        ForEach(upgradedChains, id: \.chainId) { status in
                            chainRow(for: status, isUpgraded: true)
                        }
                    }
                }

                // Not upgraded section
                if !notUpgradedChains.isEmpty {
                    Section("Not upgraded yet") {
                        ForEach(notUpgradedChains, id: \.chainId) { status in
                            chainRow(for: status, isUpgraded: false)
                        }
                    }
                }
            }
        }
        .navigationTitle("Authorizations")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(action: {
                    showingInfo = true
                }) {
                    Image(systemName: "info.circle")
                }
            }
        }
        .confirmationDialog(
            "Downgrade Account",
            isPresented: $showingResetConfirmation,
            titleVisibility: .visible
        ) {
            Button("Downgrade", role: .destructive) {
                if let chain = chainToReset {
                    Task {
                        await resetAuthorization(for: chain.chainId)
                    }
                }
                chainToReset = nil
            }
            Button("Cancel", role: .cancel) {
                chainToReset = nil
            }
        } message: {
            if let chain = chainToReset {
                Text("This will remove the smart account functionality for your account on \(chain.chainName). You can always upgrade your account again later.")
            }
        }
        .confirmationDialog(
            "Upgrade Account",
            isPresented: $showingUpgradeConfirmation,
            titleVisibility: .visible
        ) {
            Button("Upgrade") {
                if let chain = chainToUpgrade {
                    Task {
                        await upgradeAuthorization(for: chain.chainId)
                    }
                }
                chainToUpgrade = nil
            }
            Button("Cancel", role: .cancel) {
                chainToUpgrade = nil
            }
        } message: {
            if let chain = chainToUpgrade {
                Text("This will upgrade your account on \(chain.chainName) to use smart account functionality and will require a transaction on the network.")
            }
        }
        .task {
            await loadAuthorizations()
        }
        .onAppear {
            // Ensure loading happens even if .task doesn't trigger reliably
            // Only load if we haven't loaded anything yet (empty results) and not currently loading
            if authorizationStatuses.isEmpty && !isLoading {
                Task {
                    await loadAuthorizations()
                }
            }
        }
        .refreshable {
            await loadAuthorizations()
        }
        .sheet(isPresented: $showingInfo) {
            NavigationView {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        Text("What are Account Authorizations?")
                            .font(.title2)
                            .fontWeight(.bold)

                        Text("Account authorizations allow your wallet to use smart account functionality on different blockchain networks. stupid wallet uses this for transaction batching.")
                            .font(.body)

                        Text("Automatic Upgrades")
                            .font(.headline)
                            .padding(.top, 10)

                        Text("Your account will automatically be upgraded at transaction time when an app requests batched transactions.")
                            .font(.body)

                        Text("Each blockchain network needs to be authorized separately. You can upgrade or reset authorizations for individual networks as needed.")
                            .font(.body)
                            .padding(.top, 10)

                        Text("Technical Details")
                            .font(.headline)
                            .padding(.top, 10)

                        VStack(alignment: .leading, spacing: 8) {
                            Text("Accounts are delegated to:")
                                .font(.body)

                            Text(AuthorizationsUtil.simple7702AccountAddress)
                                .font(.system(.body, design: .monospaced))

                            Button(action: {
                                if let url = URL(string: "https://basescan.org/address/\(AuthorizationsUtil.simple7702AccountAddress)#code") {
                                    UIApplication.shared.open(url)
                                }
                            }) {
                                Text("Learn more")
                                    .font(.body)
                                    .foregroundColor(.blue)
                            }
                        }

                        Spacer()
                    }
                    .padding()
                }
                .navigationTitle("About Authorizations")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button("Done") {
                            showingInfo = false
                        }
                    }
                }
            }
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
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            guard resettingChainId == nil && upgradingChainId == nil else { return }

            if isUpgraded {
                // Show confirmation dialog for reset
                chainToReset = status
                showingResetConfirmation = true
            } else {
                // Show confirmation dialog for upgrade
                chainToUpgrade = status
                showingUpgradeConfirmation = true
            }
        }
    }


    private func loadAuthorizations() async {
        isLoading = true
        errorMessage = nil
        authorizationStatuses = await AuthorizationsUtil.checkAllAuthorizations(for: address)

        // Ensure loading state is properly updated on the main thread
        await MainActor.run {
            isLoading = false
        }
    }

    private func resetAuthorization(for chainId: BigUInt) async {
        // Ensure spinner shows immediately on main thread
        await MainActor.run {
            resettingChainId = chainId
        }

        do {
            let txHash = try await AuthorizationsUtil.resetAuthorization(for: address, on: chainId)
            // Wait for transaction confirmation before refreshing
            try await waitForTransactionConfirmation(txHash: txHash, chainId: chainId)
            // Reload authorizations to show updated status
            await loadAuthorizations()
        } catch is CancellationError {
            // User cancelled the operation - don't show error
        } catch {
            // Check if this is an authentication cancellation error
            if isAuthenticationCancellation(error) {
                // User cancelled authentication - don't show error
            } else {
                errorMessage = "Failed to reset authorization: \(error.localizedDescription)"
            }
        }

        // Ensure spinner is hidden on main thread
        await MainActor.run {
            resettingChainId = nil
        }
    }

    private func upgradeAuthorization(for chainId: BigUInt) async {
        // Ensure spinner shows immediately on main thread
        await MainActor.run {
            upgradingChainId = chainId
        }

        do {
            let txHash = try await AuthorizationsUtil.upgradeAuthorization(for: address, on: chainId)
            // Wait for transaction confirmation before refreshing
            try await waitForTransactionConfirmation(txHash: txHash, chainId: chainId)
            // Reload authorizations to show updated status
            await loadAuthorizations()
        } catch is CancellationError {
            // User cancelled the operation - don't show error
        } catch {
            // Check if this is an authentication cancellation error
            if isAuthenticationCancellation(error) {
                // User cancelled authentication - don't show error
            } else {
                errorMessage = "Failed to upgrade authorization: \(error.localizedDescription)"
            }
        }

        // Ensure spinner is hidden on main thread
        await MainActor.run {
            upgradingChainId = nil
        }
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

    /// Check if an error is due to user cancelling authentication (biometrics/passcode)
    private func isAuthenticationCancellation(_ error: Error) -> Bool {
        // Check for Security framework errors (biometric/face ID cancellation)
        if let nsError = error as NSError? {
            // errSecUserCanceled = -128 (user cancelled the operation)
            if nsError.domain == NSOSStatusErrorDomain && nsError.code == -128 {
                return true
            }

            // Check for LocalAuthentication errors
            if nsError.domain == "com.apple.LocalAuthentication" {
                // LAError.userCancel = -2, LAError.userFallback = -3, etc.
                if nsError.code == -2 || nsError.code == -3 || nsError.code == -4 {
                    return true
                }
            }

            // Check for other authentication-related errors
            if nsError.domain == "com.apple.security" && nsError.code == -25293 {
                // errSecAuthFailed - authentication failed
                return true
            }
        }

        // Check error description for common cancellation/auth failure messages
        let description = error.localizedDescription.lowercased()
        let cancellationKeywords = [
            "cancelled",
            "canceled",
            "authentication cancelled",
            "authentication canceled",
            "user cancelled",
            "user canceled",
            "biometric authentication cancelled",
            "biometric authentication canceled",
            "face id cancelled",
            "face id canceled",
            "touch id cancelled",
            "touch id canceled",
            "passcode cancelled",
            "passcode canceled"
        ]

        return cancellationKeywords.contains { description.contains($0) }
    }
}


#Preview {
    NavigationView {
        AuthorizationsListView(address: "0x742d35Cc6634C0532925a3b844Bc454e4438f44e")
    }
}
