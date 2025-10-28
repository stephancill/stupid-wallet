//
//  KeyManagement.swift
//  ios-wallet
//
//  Created by Build System.
//

import Foundation
import Security
import BigInt
import Wallet
import Model

enum KeyManagement {
    static func createWallet(requireBiometricsOnly: Bool = false) throws -> EthereumWallet  {
        let privateKeyBytes = try generateValidSecp256k1PrivateKey()
        let privateKey = Model.EthereumPrivateKey(rawBytes: privateKeyBytes)
        let wallet = Wallet.EthereumWallet(privateKey: privateKey)
        let addressHex = try wallet.address.eip55Description
        if requireBiometricsOnly {
            try provisionSecretForAddress(addressHex: addressHex, accessGroup: Constants.accessGroup, biometricsOnly: true)
        }
        let encrypted = try wallet.encryptWallet(accessGroup: Constants.accessGroup)
        try ensureCiphertextInSharedAccessGroup(addressHex: addressHex)
        preflightIfNeeded(addressHex: addressHex)
        return encrypted
    }
    
    static func encryptPrivateKey(rawBytes: [UInt8], requireBiometricsOnly: Bool = false) throws {
        let modelPk = Model.EthereumPrivateKey(rawBytes: rawBytes)
        let wallet = Wallet.EthereumWallet(privateKey: modelPk)
        let addressHex = try wallet.address.eip55Description
        if requireBiometricsOnly {
            try provisionSecretForAddress(addressHex: addressHex, accessGroup: Constants.accessGroup, biometricsOnly: true)
        }
        try wallet.encryptWallet(accessGroup: Constants.accessGroup)
        try ensureCiphertextInSharedAccessGroup(addressHex: addressHex)
        preflightIfNeeded(addressHex: addressHex)
    }
    
    static func importSeedPhrase(phrase: String, requireBiometricsOnly: Bool = false) throws {
        // Create HD wallet from seed phrase
        let hdWallet = try Wallet.HDEthereumWallet(mnemonicString: phrase)
        
        // Derive the first account (index 0) following standard Ethereum derivation path m/44'/60'/0'/0/0
        let privateKey = try hdWallet.generateExternalPrivateKey(at: 0)
        
        // Convert to regular wallet and encrypt
        let wallet = Wallet.EthereumWallet(privateKey: privateKey)
        let addressHex = try wallet.address.eip55Description
        
        if requireBiometricsOnly {
            try provisionSecretForAddress(addressHex: addressHex, accessGroup: Constants.accessGroup, biometricsOnly: true)
        }
        try wallet.encryptWallet(accessGroup: Constants.accessGroup)
        try ensureCiphertextInSharedAccessGroup(addressHex: addressHex)
        preflightIfNeeded(addressHex: addressHex)
    }
    
    static func getAddressFromSeedPhrase(phrase: String) throws -> String {
        // Create HD wallet from seed phrase
        let hdWallet = try Wallet.HDEthereumWallet(mnemonicString: phrase)
        
        // Derive the first account (index 0)
        let privateKey = try hdWallet.generateExternalPrivateKey(at: 0)
        
        // Get address
        let wallet = Wallet.EthereumWallet(privateKey: privateKey)
        return try wallet.address.eip55Description
    }

    /// Rewrap the existing ciphertext to a new authentication policy by decrypting and re-encrypting.
    /// Requires the existing policy's auth at call time.
    static func migrateToBiometricsOnly(addressHex: String) throws {
        let account = EthereumAccount(address: try Model.EthereumAddress(hex: addressHex))
        // Decrypt once to get the raw private key then re-encrypt with new requirement
        let rawBytes: [UInt8] = try account.accessPrivateKey(accessGroup: Constants.accessGroup) { key in
            return Array(key)
        }
        // Remove existing ciphertext and Secure Enclave secret
        try deleteExistingItems(addressHex: addressHex, accessGroup: Constants.accessGroup)
        // Pre-provision biometrics-only secret and re-encrypt
        try provisionSecretForAddress(addressHex: addressHex, accessGroup: Constants.accessGroup, biometricsOnly: true)
        try encryptPrivateKey(rawBytes: rawBytes, requireBiometricsOnly: false)
        try ensureCiphertextInSharedAccessGroup(addressHex: addressHex)
    }

    /// Rewrap to allow passcode fallback (.userPresence)
    static func migrateToPasscodeAllowed(addressHex: String) throws {
        let account = EthereumAccount(address: try Model.EthereumAddress(hex: addressHex))
        let rawBytes: [UInt8] = try account.accessPrivateKey(accessGroup: Constants.accessGroup) { key in
            return Array(key)
        }
        try deleteExistingItems(addressHex: addressHex, accessGroup: Constants.accessGroup)
        try provisionSecretForAddress(addressHex: addressHex, accessGroup: Constants.accessGroup, biometricsOnly: false)
        try encryptPrivateKey(rawBytes: rawBytes, requireBiometricsOnly: false)
        try ensureCiphertextInSharedAccessGroup(addressHex: addressHex)
    }
    /// Public: sync existing ciphertext (created previously) into the shared access group for the extension
    static func syncCiphertextToSharedGroupIfNeeded(addressHex: String) {
        try? ensureCiphertextInSharedAccessGroup(addressHex: addressHex)
    }

    /// Trigger a no-op private key access to prompt for device authentication early
    static func preflightAuthentication(addressHex: String) -> Bool {
        do {
            let account = EthereumAccount(address: try Model.EthereumAddress(hex: addressHex))
            let ok = try account.accessPrivateKey(accessGroup: Constants.accessGroup) { _ in true }
            return ok
        } catch {
            return false
        }
    }

    static func preflightIfNeeded(addressHex: String) {
        let defaults = UserDefaults(suiteName: Constants.appGroupId)
        let key = "authPreflightDone:" + addressHex.lowercased()
        if defaults?.bool(forKey: key) != true {
            if preflightAuthentication(addressHex: addressHex) {
                defaults?.set(true, forKey: key)
            }
        }
    }

    // MARK: - Private helpers

    /// Generates a cryptographically secure secp256k1 private key in the range [1, n-1]
    /// using SecRandomCopyBytes and rejects values outside the valid range.
    private static func generateValidSecp256k1PrivateKey() throws -> [UInt8] {
        // secp256k1 curve order n
        let orderHex = "FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141"
        guard let curveOrder = BigUInt(orderHex, radix: 16) else {
            throw NSError(domain: "KeyManagement", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to compute curve order"])
        }

        while true {
            var bytes = [UInt8](repeating: 0, count: 32)
            let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
            if status != errSecSuccess { continue }

            // Interpret as big-endian integer
            let candidate = BigUInt(Data(bytes))
            if candidate == 0 { continue }
            if candidate >= curveOrder { continue }
            return bytes
        }
    }

    private static func provisionSecretForAddress(addressHex: String, accessGroup: String, biometricsOnly: Bool) throws {
        // Build SecAccessControl
        let flags: SecAccessControlCreateFlags = biometricsOnly ? [.privateKeyUsage, .biometryCurrentSet] : [.privateKeyUsage, .userPresence]
        guard let access = SecAccessControlCreateWithFlags(kCFAllocatorDefault, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, flags, nil) else {
            throw NSError(domain: "KeyManagement", code: -2, userInfo: [NSLocalizedDescriptionKey: "Failed to create SecAccessControl"])
        }

        var query: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecPrivateKeyAttrs as String: [
                kSecAttrIsPermanent as String: true,
                kSecAttrApplicationTag as String: addressHex.data(using: .utf8) as Any,
                kSecAttrAccessControl as String: access as Any
            ]
        ]
        // Access group must be set at the top-level for SecKey items
        query[kSecAttrAccessGroup as String] = accessGroup

        #if !targetEnvironment(simulator)
        query[kSecAttrTokenID as String] = kSecAttrTokenIDSecureEnclave
        #endif

        var error: Unmanaged<CFError>?
        // If a secret already exists, SecKeyCreateRandomKey will fail with duplicate. That's fine for new/import flows.
        _ = SecKeyCreateRandomKey(query as CFDictionary, &error)
        if let error = error?.takeRetainedValue() {
            // Ignore duplicate errors, raise others
            let nsError = (error as Error) as NSError
            // -50 param? secure enclave not available? Ignore in simulator
            if nsError.domain != NSOSStatusErrorDomain || nsError.code != Int(errSecDuplicateItem) {
                // If duplicate, it means an existing secret already satisfies (or not) policy. For migration we delete first.
                // For other errors, throw
                #if !targetEnvironment(simulator)
                throw nsError
                #endif
            }
        }
    }

    private static func deleteExistingItems(addressHex: String, accessGroup: String) throws {
        // Delete ciphertext (generic password)
        let pwdQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword as String,
            kSecAttrAccount as String: addressHex
        ]
        SecItemDelete(pwdQuery as CFDictionary)

        // Delete Secure Enclave private key by tag
        let keyQuery: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrApplicationTag as String: addressHex.data(using: .utf8) as Any,
            kSecAttrAccessGroup as String: accessGroup
        ]
        SecItemDelete(keyQuery as CFDictionary)
    }

    /// Ensure the ciphertext is stored in a shared keychain access group so the Safari extension can read it
    private static func ensureCiphertextInSharedAccessGroup(addressHex: String) throws {
        // 1. Read ciphertext from current process keychain (no access group)
        let readQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: addressHex,
            kSecReturnData as String: kCFBooleanTrue as Any,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var dataRef: CFTypeRef?
        let status = SecItemCopyMatching(readQuery as CFDictionary, &dataRef)
        guard status == errSecSuccess, let ciphertext = dataRef as? Data else {
            return // Nothing to copy
        }

        // 2. Delete any existing group item to avoid duplicates
        let delQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: addressHex,
            kSecAttrAccessGroup as String: Constants.accessGroup
        ]
        SecItemDelete(delQuery as CFDictionary)

        // 3. Add item into shared access group
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: addressHex,
            kSecAttrAccessGroup as String: Constants.accessGroup,
            kSecValueData as String: ciphertext
        ]
        _ = SecItemAdd(addQuery as CFDictionary, nil)
    }
}
