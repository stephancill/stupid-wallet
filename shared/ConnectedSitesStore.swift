//
//  ConnectedSitesStore.swift
//  ios-wallet
//
//  Created by AI Assistant on 2025/09/28.
//

import Foundation

struct ConnectedSite: Identifiable, Equatable {
    let domain: String
    let address: String?
    let connectedAt: Date

    var id: String { domain }
}

enum ConnectedSitesStore {
    private static let defaults = UserDefaults(suiteName: Constants.appGroupId)
    private static let key = Constants.Storage.connectedSitesKey

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let isoFormatterNoFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static func parseISODate(_ string: String?) -> Date {
        guard let string = string else { return Date.distantPast }
        if let d = isoFormatter.date(from: string) { return d }
        if let d = isoFormatterNoFraction.date(from: string) { return d }
        if let d = ISO8601DateFormatter().date(from: string) { return d }
        return Date.distantPast
    }

    static func loadAll() -> [ConnectedSite] {
        guard let dict = defaults?.dictionary(forKey: key) as? [String: [String: Any]] else {
            return []
        }
        var out: [ConnectedSite] = []
        out.reserveCapacity(dict.count)
        for (domain, meta) in dict {
            let lowerDomain = domain.lowercased()
            let address = meta["address"] as? String
            let date = parseISODate(meta["connectedAt"] as? String)
            out.append(ConnectedSite(domain: lowerDomain, address: address, connectedAt: date))
        }
        return out
    }

    static func load(domain: String) -> ConnectedSite? {
        let lower = domain.lowercased()
        guard let dict = defaults?.dictionary(forKey: key) as? [String: [String: Any]],
              let meta = dict[lower] else {
            return nil
        }
        let address = meta["address"] as? String
        let date = parseISODate(meta["connectedAt"] as? String)
        return ConnectedSite(domain: lower, address: address, connectedAt: date)
    }

    static func disconnect(domain: String) {
        let lower = domain.lowercased()
        var dict = defaults?.dictionary(forKey: key) as? [String: [String: Any]] ?? [:]
        dict.removeValue(forKey: lower)
        defaults?.set(dict, forKey: key)
    }
}


