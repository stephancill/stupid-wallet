//
//  ActivityDetailView.swift
//  ios-wallet
//
//  Phase 3: Activity detail screen with explorer link
//

import SwiftUI
import BigInt
import UIKit

struct ActivityDetailView: View {
    let item: ActivityStore.ActivityItem
    @State private var didCopyHash: Bool = false

    private func chainName(from hex: String) -> String {
        let clean = hex.hasPrefix("0x") ? String(hex.dropFirst(2)) : hex
        let id = BigUInt(clean, radix: 16) ?? BigUInt(1)
        return Constants.Networks.chainName(forChainId: id)
    }

    private func openExplorer() {
        guard let txHash = item.txHash else { return }
        let preferred = URL(string: "https://blockscan.com/tx/\(txHash)")
        if let url = preferred {
            UIApplication.shared.open(url, options: [:]) { success in
                if !success {
                    // Fallback to a more universal explorer (etherscan mainnet); still a useful link
                    if let fallback = URL(string: "https://etherscan.io/tx/\(txHash)") {
                        UIApplication.shared.open(fallback)
                    }
                }
            }
        }
    }

    var body: some View {
        Form {
            Section("Transaction") {
                Button(action: {
                    UIPasteboard.general.string = item.txHash
                    didCopyHash = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                        didCopyHash = false
                    }
                }) {
                    HStack {
                        Text("Hash")
                        Spacer()
                        HStack(spacing: 6) {
                            Text(item.txHash ?? "")
                                .font(.system(.body, design: .monospaced))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Image(systemName: didCopyHash ? "checkmark" : "doc.on.doc")
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .buttonStyle(.plain)

                HStack {
                    Text("Status")
                    Spacer()
                    Text((item.status ?? "pending").capitalized)
                        .foregroundColor(.secondary)
                }

                HStack {
                    Text("Network")
                    Spacer()
                    Text(chainName(from: item.chainIdHex))
                        .foregroundColor(.secondary)
                }

                HStack {
                    Text("Timestamp")
                    Spacer()
                    Text(item.createdAt.formatted(date: .abbreviated, time: .shortened))
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.trailing)
                }
            }
            Section {
                Button(action: { openExplorer() }) {
                    HStack {
                        Spacer()
                        Text("Open in Explorer")
                        Spacer()
                    }
                }
            }
        }
        .navigationTitle("Details")
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    let app = ActivityStore.AppMetadata(domain: "app.example", uri: nil, scheme: nil)
    let item = ActivityStore.ActivityItem(
        itemType: .transaction,
        txHash: "0x1234567890abcdef",
        status: "pending",
        app: app,
        chainIdHex: "0x1",
        method: "eth_sendTransaction",
        fromAddress: nil,
        createdAt: Date()
    )
    return NavigationView { ActivityDetailView(item: item) }
}


