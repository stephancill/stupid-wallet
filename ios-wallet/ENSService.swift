import Foundation

class ENSData: Codable {
    let ens: String?
    let avatar: String?
    
    init(ens: String?, avatar: String?) {
        self.ens = ens
        self.avatar = avatar
    }
}

final class ENSService {
    static let shared = ENSService()
    private let cache = NSCache<NSString, ENSData>()
    private let ensKeyPrefix = "ensData:"
    private var defaults: UserDefaults? { UserDefaults(suiteName: Constants.appGroupId) }
    
    private init() {}
    
    // MARK: - Helpers
    private func normalizedAddress(_ address: String) -> String { address.lowercased() }
    private func ensDefaultsKey(for address: String) -> String { ensKeyPrefix + normalizedAddress(address) }

    // MARK: - ENS metadata persisted storage
    func loadPersistedENS(for address: String) -> ENSData? {
        let key = ensDefaultsKey(for: address)
        guard let data = defaults?.data(forKey: key) else {
            return nil
        }
        do {
            let decoded = try JSONDecoder().decode(ENSData.self, from: data)
            return decoded
        } catch {
            return nil
        }
    }

    func persistENS(_ ensData: ENSData, for address: String) {
        let key = ensDefaultsKey(for: address)
        if let encoded = try? JSONEncoder().encode(ensData) {
            defaults?.set(encoded, forKey: key)
        }
    }

    func clearPersistedENS(for address: String) {
        let key = ensDefaultsKey(for: address)
        defaults?.removeObject(forKey: key)
    }

    // MARK: - ENS network resolve
    func resolveENS(for address: String) async -> ENSData? {
        if let cached = cache.object(forKey: address as NSString) {
            return cached
        }
        
        guard let url = URL(string: "https://ensdata.net/\(address)") else { return nil }
        
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let ensData = try JSONDecoder().decode(ENSData.self, from: data)
            cache.setObject(ensData, forKey: address as NSString)
            persistENS(ensData, for: address)
            return ensData
        } catch {
            let emptyData = ENSData(ens: nil, avatar: nil)
            cache.setObject(emptyData, forKey: address as NSString)
            persistENS(emptyData, for: address)
            return emptyData
        }
    }
}