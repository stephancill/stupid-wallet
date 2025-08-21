//
//  Constants.swift
//  ios-wallet
//
//  Created by Stephan on 2025/08/20.
//


import Foundation
import BigInt

enum Constants {
    // TODO: Dynamically get this from the entitlements
    static let accessGroup = "6JKMV57Y77.co.za.stephancill.stupid-wallet"
    static let appGroupId = "group.co.za.stephancill.stupid-wallet"

    enum Networks {
        private static let defaultsKey = "customChains"
        private static let currentChainKey = "chainId"

        static var defaultNetworksByChainId: [BigUInt: (name: String, url: String)] = [
            BigUInt(1): ("Ethereum", "https://eth.llamarpc.com"),
            BigUInt(8453): ("Base", "https://mainnet.base.org"),
            BigUInt(42161): ("Arbitrum One", "https://arb1.arbitrum.io/rpc"),
            BigUInt(10): ("Optimism", "https://mainnet.optimism.io")
        ]

        static func loadCustomNetworks() -> [BigUInt: (name: String, url: String)] {
            let defaults = UserDefaults(suiteName: Constants.appGroupId)
            guard let stored = defaults?.dictionary(forKey: defaultsKey) as? [String: [String: Any]] else {
                return [:]
            }
            var out: [BigUInt: (name: String, url: String)] = [:]
            for (k, meta) in stored {
                let hex = k.hasPrefix("0x") ? String(k.dropFirst(2)) : k
                guard let cid = BigUInt(hex, radix: 16) else { continue }
                let name = (meta["chainName"] as? String) ?? "Chain \(cid)"
                let rpcUrls = (meta["rpcUrls"] as? [String]) ?? []
                let url = rpcUrls.first ?? defaultNetworksByChainId[cid]?.url ?? "https://eth.llamarpc.com"
                out[cid] = (name, url)
            }
            return out
        }

        static func saveCustomChain(chainIdHex: String, meta: [String: Any]) {
            let defaults = UserDefaults(suiteName: Constants.appGroupId)
            var stored = defaults?.dictionary(forKey: defaultsKey) as? [String: [String: Any]] ?? [:]
            stored[chainIdHex.lowercased()] = meta
            defaults?.set(stored, forKey: defaultsKey)
        }

        static var networksList: [(name: String, chainId: BigUInt, url: String)] {
            let merged = defaultNetworksByChainId.merging(loadCustomNetworks()) { _, custom in custom }
            return merged.map { (key: BigUInt, value: (name: String, url: String)) in
                (name: value.name, chainId: key, url: value.url)
            }.sorted { $0.name < $1.name }
        }

        static func rpcURL(forChainId chainId: BigUInt) -> String {
            let merged = defaultNetworksByChainId.merging(loadCustomNetworks()) { _, custom in custom }
            return merged[chainId]?.url ?? "https://eth.llamarpc.com"
        }

        static func getCurrentChainIdHex() -> String {
            let defaults = UserDefaults(suiteName: Constants.appGroupId)
            return defaults?.string(forKey: currentChainKey) ?? "0x1"
        }

        static func setCurrentChainIdHex(_ hex: String) {
            let defaults = UserDefaults(suiteName: Constants.appGroupId)
            defaults?.set(hex.lowercased(), forKey: currentChainKey)
        }

        static func getCurrentChainId() -> BigUInt {
            let hex = getCurrentChainIdHex()
            let clean = hex.hasPrefix("0x") ? String(hex.dropFirst(2)) : hex
            return BigUInt(clean, radix: 16) ?? BigUInt(1)
        }

        static func currentNetwork() -> (rpcURL: String, chainId: BigUInt) {
            let id = getCurrentChainId()
            let url = rpcURL(forChainId: id)
            return (url, id)
        }

        static func chainName(forChainId chainId: BigUInt) -> String {
            let merged = defaultNetworksByChainId.merging(loadCustomNetworks()) { _, custom in custom }
            return merged[chainId]?.name ?? "Chain \(chainId)"
        }
    }
}
