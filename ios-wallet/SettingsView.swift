import SwiftUI

struct SettingsView: View {
    @ObservedObject var vm: WalletViewModel
    @Binding var showClearWalletConfirmation: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            List {
                Section {
                    NavigationLink(destination: AuthorizationsListView(address: vm.addressHex)) {
                        Text("Authorizations")
                    }
                    NavigationLink(destination: ConnectedAppsView()) {
                        Text("Connected Apps")
                    }
                    NavigationLink(destination: PrivateKeyView(vm: vm)) {
                        Text("Private Key")
                    }
                }

                Section {
                    Button(role: .destructive, action: { showClearWalletConfirmation = true }) {
                        Text("Clear Wallet")
                    }
                }
                .confirmationDialog(
                    "Clear Wallet",
                    isPresented: $showClearWalletConfirmation,
                    titleVisibility: .visible
                ) {
                    Button("Clear Wallet", role: .destructive) {
                        vm.clearWallet()
                        showClearWalletConfirmation = false
                        dismiss()
                    }
                    Button("Cancel", role: .cancel) { }
                } message: {
                    Text("This will permanently delete your wallet and private key from this device. Make sure you have backed up your private key before proceeding.")
                }

                if let error = vm.privateKeyError, !error.isEmpty {
                    Section {
                        Text("Error: \(error)")
                            .foregroundColor(.red)
                            .font(.footnote)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

struct PrivateKeyView: View {
    @ObservedObject var vm: WalletViewModel

    var body: some View {
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

                    Button(action: { vm.copyPrivateKey() }) {
                        Image(systemName: vm.didCopyPrivateKey ? "checkmark" : "doc.on.doc")
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                } else {
                    Button(action: { vm.revealPrivateKey() }) {
                        if vm.isRevealingPrivateKey {
                            ProgressView()
                        } else {
                            Text("Reveal")
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                }
            }

            if let error = vm.privateKeyError, !error.isEmpty {
                Section {
                    Text("Error: \(error)")
                        .foregroundColor(.red)
                        .font(.footnote)
                }
            }
        }
        .navigationTitle("Private Key")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear {
            vm.revealedPrivateKey = ""
        }
    }
}
