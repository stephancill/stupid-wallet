//
//  ContentView.swift
//  ios-wallet
//
//  Created by Stephan on 2025/08/17.
//

import SwiftUI
import BigInt

struct ContentView: View {
    @StateObject private var vm = WalletViewModel()
    @State private var didCopyAddress = false
    @State private var showClearWalletConfirmation = false
    @State private var showSettingsSheet = false

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
            PersistentCachedImage(url: url, cacheKey: "ens-avatar:" + vm.addressHex.lowercased(), folderName: "ens-avatars") {
                if let blockies = blockiesImage(for: vm.addressHex, size: size) {
                    blockies
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    RoundedRectangle(cornerRadius: size/2)
                        .fill(Color.gray.opacity(0.3))
                }
            }
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size/2))
            .overlay(
                RoundedRectangle(cornerRadius: size/2)
                    .stroke(Color.gray.opacity(0.2), lineWidth: 1)
            )
        } else if let blockies = blockiesImage(for: vm.addressHex, size: size) {
            blockies
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: size/2))
                .overlay(
                    RoundedRectangle(cornerRadius: size/2)
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

    func copyAddress() {
        guard !vm.addressHex.isEmpty else { return }
        UIPasteboard.general.string = vm.addressHex
        didCopyAddress = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            self.didCopyAddress = false
        }
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
            .toolbar {
                if vm.hasWallet {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button(action: { showSettingsSheet = true }) {
                            Image(systemName: "gear")
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $showSettingsSheet) {
            SettingsView(vm: vm, showClearWalletConfirmation: $showClearWalletConfirmation)
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
            VStack {
                Spacer()
                VStack(alignment: .center, spacing: 24) {
                    HStack {
                        Spacer()
                        Menu {
                            if isBalancesLoading() {
                                Text("Loading balances...")
                                    .foregroundColor(.secondary)
                            } else if Constants.Networks.networksList.filter({ net in
                                if let balance = vm.balances[net.name], let value = balance { return value > 0 }
                                return false
                            }).isEmpty {
                                Text("No balances to show")
                                    .foregroundColor(.secondary)
                            } else {
                                ForEach(Constants.Networks.networksList
                                    .filter({ net in
                                        if let balance = vm.balances[net.name], let value = balance { return value > 0 }
                                        return false
                                    })
                                    .sorted(by: { lhs, rhs in
                                        let lBalance = vm.balances[lhs.name] ?? BigUInt(0)
                                        let rBalance = vm.balances[rhs.name] ?? BigUInt(0)
                                        return lBalance! > rBalance!
                                    }), id: \.name) { net in
                                    Text("\(net.name) • \(vm.formatBalanceForDisplay(vm.balances[net.name] ?? nil))")
                                        .font(.system(.footnote, design: .monospaced))
                                        .foregroundColor(.secondary)
                                    .disabled(true)
                                }
                            }
                        } label: {
                            HStack(alignment: .center, spacing: 8) {
                                if isBalancesLoading() {
                                    ProgressView()
                                        .scaleEffect(1.0)
                                } else {
                                    Text("♦ \(totalEthDisplay())")
                                        .font(.system(size: 48, weight: .bold))
                                        .foregroundColor(.primary)
                                }
                                Image(systemName: "chevron.down")
                                    .foregroundColor(.secondary)
                            }
                        }
                        .menuStyle(.borderlessButton)
                        Spacer()
                    }

                    Button(action: { copyAddress() }) {
                        HStack(spacing: 6) {
                            profileImage(size: 24)
                            if let ensName = vm.ensName, !ensName.isEmpty {
                                Text(ensName)
                                    .font(.title3)
                                    .frame(height: 24)
                            } else {
                                Text(truncatedAddress(vm.addressHex))
                                    .font(.system(.title3, design: .monospaced))
                                    .frame(height: 24)
                            }
                            Image(systemName: didCopyAddress ? "checkmark" : "doc.on.doc")
                                .foregroundColor(.secondary)
                                .frame(width: 20)
                        }
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity, alignment: .center)
                }
                .padding()
                Spacer()
            }
            .frame(minHeight: UIScreen.main.bounds.height - 200) // Account for navigation bar and safe areas
        }
        .refreshable {
            await vm.refreshAllBalances()
            await vm.resolveENS()
        }
    }

    private func balanceRow(name: String, balance: BigUInt?) -> some View {
        HStack {
            Text(name)
            Spacer()
            Text("♦ \(vm.formatBalanceForDisplay(balance))")
                .font(.system(.footnote, design: .monospaced))
        }
    }

    private func totalEthDisplay() -> String {
        var total = BigUInt(0)
        for (name, _, _) in Constants.Networks.networksList {
            if let maybe = vm.balances[name], let balance = maybe {
                total += balance
            }
        }
        return vm.formatWeiToEth(total)
    }

    private func isBalancesLoading() -> Bool {
        return Constants.Networks.networksList.contains(where: { net in
            vm.balances[net.name] == nil
        })
    }


    private var balancesEmptyState: some View {
        HStack(alignment: .center) {
            Image(systemName: "tray")
                .foregroundColor(.secondary)
            Text("No balances to show")
                .foregroundColor(.secondary)
                .font(.footnote)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, 8)
    }

    private var balancesLoadingState: some View {
        HStack(alignment: .center) {
            ProgressView()
                .scaleEffect(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, 8)
    }

}

// Lists balances per network


#Preview {
    ContentView()
}
