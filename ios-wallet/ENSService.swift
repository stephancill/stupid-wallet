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
    private func cacheKey(for address: String) -> NSString { normalizedAddress(address) as NSString }

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
        let key = cacheKey(for: address)
        if let cached = cache.object(forKey: key) {
            return cached
        }

        guard let url = URL(string: "https://ensdata.net/\(address)") else {
            if let persisted = loadPersistedENS(for: address) {
                cache.setObject(persisted, forKey: key)
                return persisted
            }
            return nil
        }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                throw URLError(.badServerResponse)
            }

            let ensData = try JSONDecoder().decode(ENSData.self, from: data)
            cache.setObject(ensData, forKey: key)
            persistENS(ensData, for: address)
            return ensData
        } catch {
            if let persisted = loadPersistedENS(for: address) {
                cache.setObject(persisted, forKey: key)
                return persisted
            }
            return cache.object(forKey: key)
        }
    }
}