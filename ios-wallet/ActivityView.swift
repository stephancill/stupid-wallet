//
//  ActivityView.swift
//  ios-wallet
//
//  Phase 3: Reverse-chronological activity list UI
//

import SwiftUI
import BigInt

struct ActivityView: View {
    @StateObject private var vm = ActivityViewModel()

    private func appLabel(_ app: ActivityStore.AppMetadata) -> String {
        if let d = app.domain, !d.isEmpty { return d }
        if let u = app.uri, !u.isEmpty { return u }
        if let s = app.scheme, !s.isEmpty { return s }
        return "Unknown App"
    }

    private func truncatedHash(_ hash: String) -> String {
        guard hash.hasPrefix("0x"), hash.count > 12 else { return hash }
        let start = hash.index(hash.startIndex, offsetBy: 2)
        let first4 = hash[start..<hash.index(start, offsetBy: 4)]
        let last4 = hash.suffix(4)
        return "0x\(first4)…\(last4)"
    }

    private func chainName(from hex: String) -> String {
        let clean = hex.hasPrefix("0x") ? String(hex.dropFirst(2)) : hex
        let id = BigUInt(clean, radix: 16) ?? BigUInt(1)
        return Constants.Networks.chainName(forChainId: id)
    }

    private func relativeTime(_ date: Date) -> String {
        let fmt = RelativeDateTimeFormatter()
        fmt.unitsStyle = .short
        return fmt.localizedString(for: date, relativeTo: Date())
    }

    var body: some View {
        List(vm.items, id: \.txHash) { item in
            NavigationLink(destination: ActivityDetailView(item: item)) {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(appLabel(item.app))
                            .lineLimit(1)
                            .truncationMode(.tail)
                        HStack(spacing: 6) {
                            if item.status == "pending" {
                                ProgressView()
                                    .controlSize(.small)
                                    .scaleEffect(0.7)
                                Text("Pending")
                                Text("•")
                                Text(chainName(from: item.chainIdHex))
                            } else if item.status != "confirmed" {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundColor(.red)
                                    .imageScale(.small)
                                Text("Failed")
                                Text("•")
                                Text(chainName(from: item.chainIdHex))
                            } else {
                                Text(truncatedHash(item.txHash))
                                    .font(.system(.body, design: .monospaced))
                                Text("•")
                                Text(chainName(from: item.chainIdHex))
                            }
                        }
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    }
                    Spacer()
                    Text(relativeTime(item.createdAt))
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.trailing)
                }
                .padding(.vertical, 4)
            }
            .onAppear { vm.loadMoreIfNeeded(currentItem: item) }
        }
        .overlay(alignment: .center) {
            if vm.isLoading {
                ProgressView()
            } else if vm.items.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "tray")
                        .foregroundColor(.secondary)
                    Text("No activity yet")
                        .foregroundColor(.secondary)
                        .font(.footnote)
                }
            }
        }
        .overlay(alignment: .top) {
            if let error = vm.errorMessage {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.yellow)
                    Text(error)
                        .foregroundColor(.primary)
                }
                .padding(8)
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .padding(.top, 8)
            }
        }
        .safeAreaInset(edge: .bottom) {
            if vm.isLoadingMore {
                HStack {
                    Spacer()
                    ProgressView().scaleEffect(0.9)
                    Spacer()
                }
                .padding(.vertical, 8)
            }
        }
        .navigationTitle("Activity")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { vm.loadInitial(); vm.startPolling() }
        .onDisappear { vm.stopPolling() }
        .refreshable { vm.loadInitial() }
    }
}

#Preview {
    NavigationView { ActivityView() }
}


