//
//  NetworksView.swift
//  ios-wallet
//
//  Created by AI Assistant on 2025/10/05.
//

import SwiftUI
import BigInt

struct NetworkInfo: Identifiable {
    let id: String // chainId hex
    let name: String
    let chainId: BigUInt
    let rpcUrls: [String]
    let isDefault: Bool
    let includeInBalance: Bool
}

struct NetworksView: View {
    @State private var networks: [NetworkInfo] = []
    
    var body: some View {
        List {
            if networks.isEmpty {
                Section {
                    HStack {
                        Spacer()
                        VStack(spacing: 8) {
                            Image(systemName: "network")
                                .font(.system(size: 28))
                                .foregroundColor(.secondary)
                            Text("No networks configured")
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 16)
                }
            } else {
                Section("Default Networks") {
                    ForEach(networks.filter { $0.isDefault }) { network in
                        NavigationLink(destination: NetworkDetailView(chainIdHex: network.id)) {
                            HStack {
                                Text(network.name)
                                    .font(.body)
                                Spacer()
                                if !network.includeInBalance {
                                    Image(systemName: "eye.slash")
                                        .foregroundColor(.secondary)
                                        .font(.caption)
                                }
                            }
                        }
                    }
                }
                
                let customNetworks = networks.filter { !$0.isDefault }
                if !customNetworks.isEmpty {
                    Section("Custom Networks") {
                        ForEach(customNetworks) { network in
                            NavigationLink(destination: NetworkDetailView(chainIdHex: network.id)) {
                                HStack {
                                    Text(network.name)
                                        .font(.body)
                                    Spacer()
                                    if !network.includeInBalance {
                                        Image(systemName: "eye.slash")
                                            .foregroundColor(.secondary)
                                            .font(.caption)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Networks")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: load)
        .refreshable { load() }
    }
    
    private func load() {
        var result: [NetworkInfo] = []
        
        // Load all networks from Constants
        let allNetworks = Constants.Networks.networksList
        let excludedChains = NetworkUtils.getExcludedChainIds()
        
        for (name, chainId, url) in allNetworks {
            let chainIdHex = "0x" + String(chainId, radix: 16)
            let isDefault = Constants.Networks.defaultNetworksByChainId[chainId] != nil
            let includeInBalance = !excludedChains.contains(chainIdHex.lowercased())
            
            // Get RPC URLs - check customChains for both default and custom networks
            var rpcUrls = [url]
            if let customMeta = loadCustomChainMetadata(chainIdHex: chainIdHex),
               let storedUrls = customMeta["rpcUrls"] as? [String], !storedUrls.isEmpty {
                rpcUrls = storedUrls
            }
            
            result.append(NetworkInfo(
                id: chainIdHex.lowercased(),
                name: name,
                chainId: chainId,
                rpcUrls: rpcUrls,
                isDefault: isDefault,
                includeInBalance: includeInBalance
            ))
        }
        
        // Sort: defaults first (by name), then custom (by name)
        self.networks = result.sorted { a, b in
            if a.isDefault != b.isDefault {
                return a.isDefault
            }
            return a.name < b.name
        }
    }
    
    private func loadCustomChainMetadata(chainIdHex: String) -> [String: Any]? {
        let defaults = UserDefaults(suiteName: Constants.appGroupId)
        guard let chains = defaults?.dictionary(forKey: "customChains") as? [String: [String: Any]] else {
            return nil
        }
        return chains[chainIdHex.lowercased()]
    }
}

struct NetworkDetailView: View {
    let chainIdHex: String
    
    @State private var networkName: String = ""
    @State private var chainId: BigUInt = 0
    @State private var rpcUrls: [String] = []
    @State private var includeInBalance: Bool = true
    @State private var isDefault: Bool = false
    @State private var newRpcUrl: String = ""
    @State private var showAddRpcSheet: Bool = false
    @State private var showEditNameSheet: Bool = false
    @State private var editedName: String = ""
    @State private var showRemoveConfirmation: Bool = false
    @State private var showChainIdAsHex: Bool = false
    
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        Form {
            Section("Network Information") {
                HStack {
                    Text("Name")
                    Spacer()
                    Text(networkName)
                        .foregroundColor(.secondary)
                }
                
                Button(action: { showChainIdAsHex.toggle() }) {
                    HStack {
                        Text("Chain ID")
                            .foregroundColor(.primary)
                        Spacer()
                        Text(showChainIdAsHex ? chainIdHex : String(chainId))
                            .foregroundColor(.secondary)
                            .font(.system(.body, design: .monospaced))
                    }
                }
                .buttonStyle(.plain)
            }
            
            Section {
                Toggle("Include in Total Balance", isOn: $includeInBalance)
                    .onChange(of: includeInBalance) { _, newValue in
                        saveIncludeInBalance(newValue)
                    }
            } footer: {
                Text("When enabled, balances on this network will be included in your total balance display.")
            }
            
            Section {
                ForEach(Array(rpcUrls.enumerated()), id: \.offset) { index, url in
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            if index == 0 {
                                Text("Primary RPC")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Text(url)
                                .font(.system(.body, design: .monospaced))
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        if rpcUrls.count > 1 {
                            Button(role: .destructive) {
                                removeRpcUrl(at: index)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
                
                Button(action: { showAddRpcSheet = true }) {
                    Label("Add RPC URL", systemImage: "plus")
                }
            } header: {
                Text("RPC URLs")
            } footer: {
                Text("Swipe left to delete RPC URLs. The first URL is used as primary.")
            }
            
            if !isDefault {
                Section {
                    Button("Edit Name") {
                        editedName = networkName
                        showEditNameSheet = true
                    }
                }
                
                Section {
                    Button(role: .destructive, action: { showRemoveConfirmation = true }) {
                        Text("Remove Network")
                    }
                }
            }
        }
        .navigationTitle(networkName)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: load)
        .sheet(isPresented: $showAddRpcSheet) {
            NavigationView {
                AddRpcUrlView(rpcUrl: $newRpcUrl, onSave: {
                    if !newRpcUrl.isEmpty {
                        addRpcUrl(newRpcUrl)
                        newRpcUrl = ""
                        showAddRpcSheet = false
                    }
                })
            }
        }
        .sheet(isPresented: $showEditNameSheet) {
            NavigationView {
                EditNetworkNameView(networkName: $editedName, onSave: {
                    if !editedName.isEmpty {
                        networkName = editedName
                        saveNetworkName()
                        showEditNameSheet = false
                    }
                })
            }
        }
        .confirmationDialog(
            "Remove Network",
            isPresented: $showRemoveConfirmation,
            titleVisibility: .visible
        ) {
            Button("Remove Network", role: .destructive) {
                removeNetwork()
                dismiss()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This will remove \(networkName) from your wallet. You can add it back later if needed.")
        }
    }
    
    private func load() {
        let cleanHex = chainIdHex.hasPrefix("0x") ? String(chainIdHex.dropFirst(2)) : chainIdHex
        guard let cid = BigUInt(cleanHex, radix: 16) else { return }
        
        chainId = cid
        isDefault = Constants.Networks.defaultNetworksByChainId[cid] != nil
        
        let defaults = UserDefaults(suiteName: Constants.appGroupId)
        let chains = defaults?.dictionary(forKey: "customChains") as? [String: [String: Any]]
        let meta = chains?[chainIdHex.lowercased()]
        
        // Load name
        if isDefault {
            networkName = Constants.Networks.defaultNetworksByChainId[cid]?.name ?? "Unknown"
            let defaultUrl = Constants.Networks.defaultNetworksByChainId[cid]?.url ?? ""
            
            // For default networks, check if there are additional RPC URLs stored in customChains
            if let urls = meta?["rpcUrls"] as? [String], !urls.isEmpty {
                rpcUrls = urls
            } else {
                rpcUrls = [defaultUrl]
            }
        } else {
            // Load from custom chains
            if let meta = meta {
                networkName = meta["chainName"] as? String ?? "Chain \(chainId)"
                if let urls = meta["rpcUrls"] as? [String], !urls.isEmpty {
                    rpcUrls = urls
                } else {
                    rpcUrls = [""]
                }
            }
        }
        
        // Load include in balance setting
        includeInBalance = !NetworkUtils.isChainExcluded(chainIdHex: chainIdHex)
    }
    
    private func saveNetworkName() {
        guard !isDefault else { return }
        let defaults = UserDefaults(suiteName: Constants.appGroupId)
        var chains = defaults?.dictionary(forKey: "customChains") as? [String: [String: Any]] ?? [:]
        
        if var meta = chains[chainIdHex.lowercased()] {
            meta["chainName"] = networkName
            chains[chainIdHex.lowercased()] = meta
            defaults?.set(chains, forKey: "customChains")
        }
    }
    
    private func saveIncludeInBalance(_ include: Bool) {
        let defaults = UserDefaults(suiteName: Constants.appGroupId)
        var excluded = defaults?.array(forKey: "excludedFromBalance") as? [String] ?? []
        let key = chainIdHex.lowercased()
        
        if include {
            // Remove from excluded list
            excluded.removeAll { $0 == key }
        } else {
            // Add to excluded list if not already there
            if !excluded.contains(key) {
                excluded.append(key)
            }
        }
        
        defaults?.set(excluded, forKey: "excludedFromBalance")
    }
    
    private func addRpcUrl(_ url: String) {
        guard !url.isEmpty else { return }
        
        rpcUrls.append(url)
        
        // Save to custom chains (works for both default and custom networks)
        let defaults = UserDefaults(suiteName: Constants.appGroupId)
        var chains = defaults?.dictionary(forKey: "customChains") as? [String: [String: Any]] ?? [:]
        
        // Get existing meta or create new one
        var meta = chains[chainIdHex.lowercased()] ?? [:]
        meta["rpcUrls"] = rpcUrls
        
        // For default networks, also save the chain name so the entry is valid
        if isDefault {
            meta["chainName"] = networkName
        }
        
        chains[chainIdHex.lowercased()] = meta
        defaults?.set(chains, forKey: "customChains")
    }
    
    private func removeRpcUrl(at index: Int) {
        // Can't remove the last RPC URL
        guard rpcUrls.count > 1 else { return }
        
        rpcUrls.remove(at: index)
        
        // Save to custom chains (works for both default and custom networks)
        let defaults = UserDefaults(suiteName: Constants.appGroupId)
        var chains = defaults?.dictionary(forKey: "customChains") as? [String: [String: Any]] ?? [:]
        
        // Get existing meta or create new one
        var meta = chains[chainIdHex.lowercased()] ?? [:]
        meta["rpcUrls"] = rpcUrls
        
        // For default networks, also save the chain name so the entry is valid
        if isDefault {
            meta["chainName"] = networkName
        }
        
        chains[chainIdHex.lowercased()] = meta
        defaults?.set(chains, forKey: "customChains")
    }
    
    private func removeNetwork() {
        guard !isDefault else { return }
        
        let defaults = UserDefaults(suiteName: Constants.appGroupId)
        var chains = defaults?.dictionary(forKey: "customChains") as? [String: [String: Any]] ?? [:]
        chains.removeValue(forKey: chainIdHex.lowercased())
        defaults?.set(chains, forKey: "customChains")
        
        // Also remove from excluded list if present
        var excluded = defaults?.array(forKey: "excludedFromBalance") as? [String] ?? []
        excluded.removeAll { $0 == chainIdHex.lowercased() }
        defaults?.set(excluded, forKey: "excludedFromBalance")
    }
}

struct AddRpcUrlView: View {
    @Binding var rpcUrl: String
    let onSave: () -> Void
    
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        Form {
            Section {
                TextField("https://", text: $rpcUrl)
                    .keyboardType(.URL)
                    .autocapitalization(.none)
                    .autocorrectionDisabled()
            } header: {
                Text("RPC URL")
            } footer: {
                Text("Enter the full RPC URL including https://")
            }
        }
        .navigationTitle("Add RPC URL")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                    dismiss()
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Add") {
                    onSave()
                }
                .disabled(rpcUrl.isEmpty || !isValidUrl(rpcUrl))
            }
        }
    }
    
    private func isValidUrl(_ string: String) -> Bool {
        guard let url = URL(string: string),
              let scheme = url.scheme,
              (scheme == "http" || scheme == "https"),
              url.host != nil else {
            return false
        }
        return true
    }
}

struct EditNetworkNameView: View {
    @Binding var networkName: String
    let onSave: () -> Void
    
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        Form {
            Section {
                TextField("Network Name", text: $networkName)
                    .autocorrectionDisabled()
            } header: {
                Text("Network Name")
            } footer: {
                Text("Enter a custom name for this network")
            }
        }
        .navigationTitle("Edit Network Name")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                    dismiss()
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    onSave()
                }
                .disabled(networkName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }
}

#Preview {
    NavigationView {
        NetworksView()
    }
}
