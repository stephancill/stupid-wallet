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
    @State private var didCopyMessage: Bool = false
    @State private var didCopySignature: Bool = false
    @State private var showFullMessage: Bool = false

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

    private func decodePersonalMessage(_ content: String) -> String {
        if content.hasPrefix("0x") {
            if let data = Data(hexString: content),
               let text = String(data: data, encoding: .utf8) {
                return text
            }
        }
        return content
    }

    private func truncatedHex(_ hex: String) -> String {
        guard hex.hasPrefix("0x"), hex.count > 12 else { return hex }
        let start = hex.index(hex.startIndex, offsetBy: 2)
        let first6 = hex[start..<hex.index(start, offsetBy: 6)]
        let last6 = hex.suffix(6)
        return "0x\(first6)…\(last6)"
    }

    var body: some View {
        Form {
            switch item.itemType {
            case .transaction:
                transactionSections()
            case .signature:
                signatureSections()
            }
        }
        .navigationTitle("Details")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func transactionSections() -> some View {
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

    @ViewBuilder
    private func signatureSections() -> some View {
        Section("Signature") {
            messageContentView()

            Button(action: {
                UIPasteboard.general.string = item.signatureHash
                didCopyHash = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                    didCopyHash = false
                }
            }) {
                HStack {
                    Text("Hash")
                    Spacer()
                    HStack(spacing: 6) {
                        Text(truncatedHex(item.signatureHash ?? ""))
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

            Button(action: {
                UIPasteboard.general.string = item.signatureHex
                didCopySignature = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                    didCopySignature = false
                }
            }) {
                HStack {
                    Text("Signature")
                    Spacer()
                    HStack(spacing: 6) {
                        Text(truncatedHex(item.signatureHex ?? ""))
                            .font(.system(.body, design: .monospaced))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Image(systemName: didCopySignature ? "checkmark" : "doc.on.doc")
                            .foregroundColor(.secondary)
                    }
                }
            }
            .buttonStyle(.plain)
        }

        Section("Verification") {
            if let from = item.fromAddress {
                HStack {
                    Text("From")
                    Spacer()
                    Text(from)
                        .font(.system(.body, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
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
    }

    @ViewBuilder
    private func messageContentView() -> some View {
        let method = item.method ?? ""
        let content = item.messageContent ?? ""

        if method == "eth_signTypedData_v4" {
            typedDataMessageView(content: content)
        } else {
            personalMessageView(content: content)
        }
    }

    @ViewBuilder
    private func personalMessageView(content: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: {
                UIPasteboard.general.string = content
                didCopyMessage = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                    didCopyMessage = false
                }
            }) {
                HStack {
                    Text("Message")
                    Spacer()
                    Image(systemName: didCopyMessage ? "checkmark" : "doc.on.doc")
                        .foregroundColor(.secondary)
                }
            }
            .buttonStyle(.plain)

            Text(decodePersonalMessage(content))
                .font(.system(.body))
                .foregroundColor(.primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func typedDataMessageView(content: String) -> some View {
        if let data = content.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            VStack(alignment: .leading, spacing: 16) {
                Button(action: {
                    UIPasteboard.general.string = content
                    didCopyMessage = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                        didCopyMessage = false
                    }
                }) {
                    HStack {
                        Text("Message")
                        Spacer()
                        Image(systemName: didCopyMessage ? "checkmark" : "doc.on.doc")
                            .foregroundColor(.secondary)
                    }
                }
                .buttonStyle(.plain)

                // Domain section
                if let domain = json["domain"] as? [String: Any], !domain.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Domain")
                            .font(.subheadline)
                            .fontWeight(.medium)

                        VStack(alignment: .leading, spacing: 8) {
                            if let name = domain["name"] as? String {
                                domainField(label: "Name", value: name)
                            }
                            if let version = domain["version"] as? String {
                                domainField(label: "Version", value: version)
                            }
                            if let chainId = domain["chainId"] {
                                let chainIdStr = "\(chainId)"
                                domainField(label: "Chain", value: chainIdStr)
                            }
                            if let verifyingContract = domain["verifyingContract"] as? String {
                                domainField(label: "Verifying Contract", value: verifyingContract)
                            }
                        }
                    }
                }

                // Message section
                if let message = json["message"] as? [String: Any], !message.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Message")
                            .font(.subheadline)
                            .fontWeight(.medium)

                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(Array(message.keys.sorted()), id: \.self) { key in
                                messageField(label: key, value: message[key])
                            }
                        }
                    }
                }
            }
        } else {
            // Fallback if JSON parsing fails
            personalMessageView(content: content)
        }
    }

    @ViewBuilder
    private func domainField(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label.uppercased())
                .font(.caption2)
                .foregroundColor(.secondary)
            Text(value)
                .font(.system(.callout, design: value.hasPrefix("0x") ? .monospaced : .default))
                .foregroundColor(.primary)
                .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private func messageField(label: String, value: Any?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label.uppercased())
                .font(.caption2)
                .foregroundColor(.secondary)
            Text(formatValue(value))
                .font(.system(.callout, design: .default))
                .foregroundColor(.primary)
                .textSelection(.enabled)
        }
    }

    private func formatValue(_ value: Any?) -> String {
        if let str = value as? String {
            return str
        } else if let num = value as? NSNumber {
            return num.stringValue
        } else if let dict = value as? [String: Any],
                  let data = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted]),
                  let str = String(data: data, encoding: .utf8) {
            return str
        } else if let arr = value as? [Any],
                  let data = try? JSONSerialization.data(withJSONObject: arr, options: [.prettyPrinted]),
                  let str = String(data: data, encoding: .utf8) {
            return str
        }
        return "\(value ?? "")"
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


