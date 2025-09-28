//
//  ConnectedAppsView.swift
//  ios-wallet
//
//  Created by AI Assistant on 2025/09/28.
//

import SwiftUI

private func formatExact(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.dateStyle = .medium
    formatter.timeStyle = .medium
    return formatter.string(from: date)
}

struct ConnectedAppsView: View {
    @State private var sites: [ConnectedSite] = []

    var body: some View {
        List {
            if sites.isEmpty {
                Section {
                    HStack {
                        Spacer()
                        VStack(spacing: 8) {
                            Image(systemName: "app.badge")
                                .font(.system(size: 28))
                                .foregroundColor(.secondary)
                            Text("No connected apps yet")
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 16)
                }
            } else {
                Section {
                    ForEach(sites) { site in
                        NavigationLink(destination: ConnectedAppDetailView(domain: site.domain)) {
                            HStack {
                                Text(site.domain)
                                Spacer()
                                Text(TimeUtils.abbreviatedRelative(from: site.connectedAt))
                                    .foregroundColor(.secondary)
                                    .font(.subheadline)
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Connected Apps")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: load)
        .refreshable { load() }
    }

    private func load() {
        let all = ConnectedSitesStore.loadAll()
        self.sites = all.sorted { a, b in a.connectedAt > b.connectedAt }
    }
}

struct ConnectedAppDetailView: View {
    let domain: String
    @State private var site: ConnectedSite?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            if let site = site {
                Section("App") {
                    HStack {
                        Text("Domain")
                        Spacer()
                        Text(site.domain)
                            .foregroundColor(.secondary)
                    }
                    HStack {
                        Text("Connected")
                        Spacer()
                        Text(formatExact(site.connectedAt))
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.trailing)
                    }
                }

                Section {
                    Button(role: .destructive, action: disconnect) {
                        Text("Disconnect")
                    }
                }
            } else {
                Section {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                }
            }
        }
        .navigationTitle(domain)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: load)
    }

    private func load() {
        self.site = ConnectedSitesStore.load(domain: domain)
    }

    private func disconnect() {
        ConnectedSitesStore.disconnect(domain: domain)
        dismiss()
    }
}

#Preview {
    NavigationView {
        ConnectedAppsView()
    }
}


