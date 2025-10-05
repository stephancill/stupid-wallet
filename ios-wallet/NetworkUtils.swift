//
//  NetworkUtils.swift
//  ios-wallet
//
//  Created by AI Assistant on 2025/10/05.
//

import Foundation
import BigInt

enum NetworkUtils {
    /// Returns networks that are included in balance calculations (not excluded) and have balance > 0
    static func includedNetworksWithBalance(
        balances: [String: BigUInt?]
    ) -> [(name: String, chainId: BigUInt, url: String)] {
        // Load excluded chains
        let defaults = UserDefaults(suiteName: Constants.appGroupId)
        let excludedChains = Set((defaults?.array(forKey: "excludedFromBalance") as? [String] ?? []).map { $0.lowercased() })
        
        return Constants.Networks.networksList
            .filter { net in
                let chainIdHex = "0x" + String(net.chainId, radix: 16).lowercased()
                
                // Skip if excluded
                if excludedChains.contains(chainIdHex) {
                    return false
                }
                
                // Only include if balance has been loaded and is greater than 0
                // Handle double optional properly
                if let balance = balances[chainIdHex] ?? nil {
                    return balance > 0
                }
                return false
            }
            .sorted { lhs, rhs in
                let lhsChainIdHex = "0x" + String(lhs.chainId, radix: 16).lowercased()
                let rhsChainIdHex = "0x" + String(rhs.chainId, radix: 16).lowercased()
                
                // Handle double optional: Dictionary returns BigUInt??, need to flatten
                let lBalance = (balances[lhsChainIdHex] ?? nil) ?? BigUInt(0)
                let rBalance = (balances[rhsChainIdHex] ?? nil) ?? BigUInt(0)
                return lBalance > rBalance
            }
    }
    
    /// Returns the set of chain IDs (as hex strings) that are excluded from balance calculations
    static func getExcludedChainIds() -> Set<String> {
        let defaults = UserDefaults(suiteName: Constants.appGroupId)
        return Set((defaults?.array(forKey: "excludedFromBalance") as? [String] ?? []).map { $0.lowercased() })
    }
    
    /// Checks if a specific chain ID is excluded from balance calculations
    static func isChainExcluded(chainIdHex: String) -> Bool {
        let excluded = getExcludedChainIds()
        return excluded.contains(chainIdHex.lowercased())
    }
    
    /// Checks if any included (non-excluded) network is still loading (has nil balance)
    static func areIncludedBalancesLoading(balances: [String: BigUInt?]) -> Bool {
        let excludedChains = getExcludedChainIds()
        
        return Constants.Networks.networksList.contains { net in
            let chainIdHex = "0x" + String(net.chainId, radix: 16).lowercased()
            
            // Skip excluded chains
            if excludedChains.contains(chainIdHex) {
                return false
            }
            
            // Check if this included network is still loading (nil)
            return balances[chainIdHex] == nil
        }
    }
}
