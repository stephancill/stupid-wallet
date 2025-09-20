import Foundation

class ENSData: Codable {
    let ens: String?
    let avatar: String?
    
    init(ens: String?, avatar: String?) {
        self.ens = ens
        self.avatar = avatar
    }
}

class ENSService {
    static let shared = ENSService()
    private let cache = NSCache<NSString, ENSData>()
    
    private init() {}
    
    func resolveENS(for address: String) async -> ENSData? {
        if let cached = cache.object(forKey: address as NSString) {
            return cached
        }
        
        guard let url = URL(string: "https://ensdata.net/\(address)") else { return nil }
        
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let ensData = try JSONDecoder().decode(ENSData.self, from: data)
            cache.setObject(ensData, forKey: address as NSString)
            return ensData
        } catch {
            let emptyData = ENSData(ens: nil, avatar: nil)
            cache.setObject(emptyData, forKey: address as NSString)
            return emptyData
        }
    }
}