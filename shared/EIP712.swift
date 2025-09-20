//
//  EIP712.swift
//  Shared hashing utilities for EIP-712 (v4)
//

import Foundation
import CryptoSwift
import BigInt

// Minimal EIP-712 encoder for v4 (typedData JSON)
enum EIP712 {
    struct TypeDef { let name: String; let type: String }

    static func computeDigest(typedDataJSON: String) throws -> Data? {
        guard let jsonData = typedDataJSON.data(using: .utf8) else { return nil }
        let obj = try JSONSerialization.jsonObject(with: jsonData, options: []) as? [String: Any]
        guard let dict = obj,
              let types = dict["types"] as? [String: Any],
              let primaryType = dict["primaryType"] as? String,
              let domain = dict["domain"],
              let message = dict["message"]
        else { return nil }

        var typeMap: [String: [TypeDef]] = [:]
        for (k, v) in types {
            guard let arr = v as? [[String: Any]] else { continue }
            typeMap[k] = arr.compactMap { item in
                guard let n = item["name"] as? String, let t = item["type"] as? String else { return nil }
                return TypeDef(name: n, type: t)
            }
        }

        // Ensure EIP712Domain reflects provided domain keys only (aligned with viem behavior)
        if typeMap["EIP712Domain"] == nil {
            let domainDict = domain as? [String: Any] ?? [:]
            let allowed: [TypeDef] = [
                TypeDef(name: "name", type: "string"),
                TypeDef(name: "version", type: "string"),
                TypeDef(name: "chainId", type: "uint256"),
                TypeDef(name: "verifyingContract", type: "address"),
                TypeDef(name: "salt", type: "bytes32"),
            ]
            typeMap["EIP712Domain"] = allowed.filter { domainDict[$0.name] != nil }
        }

        let domainHash = try hashStruct(typeName: "EIP712Domain", value: domain, types: typeMap)
        let messageHash = try hashStruct(typeName: primaryType, value: message, types: typeMap)

        var prefix: [UInt8] = [0x19, 0x01]
        prefix.append(contentsOf: [UInt8](domainHash))
        prefix.append(contentsOf: [UInt8](messageHash))
        let digest = prefix.sha3(.keccak256)
        return Data(digest)
    }

    private static func encodeType(_ primaryType: String, types: [String: [TypeDef]]) -> String {
        func collectDependencies(of type: String, into set: inout Set<String>) {
            guard let fields = types[type] else { return }
            for f in fields {
                let base = baseType(of: f.type)
                if types[base] != nil && base != type {
                    if !set.contains(base) {
                        set.insert(base)
                        collectDependencies(of: base, into: &set)
                    }
                }
            }
        }
        var deps: Set<String> = []
        collectDependencies(of: primaryType, into: &deps)
        let ordered = [primaryType] + Array(deps).sorted()
        return ordered.compactMap { typeName in
            guard let fields = types[typeName] else { return nil }
            let inner = fields.map { "\($0.type) \($0.name)" }.joined(separator: ",")
            return "\(typeName)(\(inner))"
        }.joined()
    }

    private static func typeHash(_ type: String, types: [String: [TypeDef]]) -> Data {
        let enc = encodeType(type, types: types)
        return Data([UInt8](enc.utf8)).sha3(.keccak256)
    }

    private static func hashStruct(typeName: String, value: Any, types: [String: [TypeDef]]) throws -> Data {
        let tHash = typeHash(typeName, types: types)
        let fields: [TypeDef]
        if let f = types[typeName] {
            fields = f
        } else if typeName == "EIP712Domain" {
            // Derive fields from provided value
            let valDict = value as? [String: Any] ?? [:]
            let allowed: [TypeDef] = [
                TypeDef(name: "name", type: "string"),
                TypeDef(name: "version", type: "string"),
                TypeDef(name: "chainId", type: "uint256"),
                TypeDef(name: "verifyingContract", type: "address"),
                TypeDef(name: "salt", type: "bytes32"),
            ]
            let present = allowed.filter { valDict[$0.name] != nil }
            if present.isEmpty { return Data([UInt8](tHash)) }
            fields = present
        } else {
            return Data([UInt8](tHash))
        }
        var enc: [UInt8] = []
        enc.append(contentsOf: [UInt8](tHash))
        let valDict = value as? [String: Any] ?? [:]
        for field in fields {
            let v = valDict[field.name]
            let hashed = try encodeValue(fieldType: field.type, value: v, types: types)
            enc.append(contentsOf: [UInt8](hashed))
        }
        return Data(enc).sha3(.keccak256)
    }

    private static func encodeValue(fieldType: String, value: Any?, types: [String: [TypeDef]]) throws -> Data {
        if let (base, isArray) = parseArray(fieldType), isArray {
            let arr = value as? [Any] ?? []
            var out: [UInt8] = []
            for el in arr {
                let h = try encodeValue(fieldType: base, value: el, types: types)
                out.append(contentsOf: [UInt8](h))
            }
            return Data(out).sha3(.keccak256)
        }
        let base = baseType(of: fieldType)
        if let _ = types[base] {
            return try hashStruct(typeName: base, value: value ?? [:], types: types)
        }
        switch base.lowercased() {
        case "address":
            if let s = value as? String, let addr = hexToData(s), addr.count == 20 {
                return addr.leftPadded(to: 32)
            }
            return Data(count: 32)
        case let t where t.hasPrefix("uint"):
            let b = parseBigUInt(value)
            return b.serialize().leftPadded(to: 32)
        case let t where t.hasPrefix("int"):
            let b = parseBigInt(value)
            return twosComplement32Bytes(b)
        case "bool":
            let v = (value as? Bool) == true ? 1 : 0
            var data = Data(count: 31)
            data.append(UInt8(v))
            return data
        case "bytes":
            if let s = value as? String {
                let d = hexToData(s) ?? Data()
                return d.sha3(.keccak256)
            }
            if let d = value as? Data { return d.sha3(.keccak256) }
            return Data(count: 32)
        case let t where t.hasPrefix("bytes"):
            let lenStr = String(t.dropFirst("bytes".count))
            if let len = Int(lenStr), len >= 1 && len <= 32 {
                if let s = value as? String, let d = hexToData(s) { return d.rightPadded(to: 32) }
                if let d = value as? Data { return d.rightPadded(to: 32) }
            }
            return Data(count: 32)
        case "string":
            if let s = value as? String { return Data(s.utf8).sha3(.keccak256) }
            return Data(count: 32)
        default:
            return Data(count: 32)
        }
    }

    private static func parseArray(_ type: String) -> (String, Bool)? {
        if let range = type.range(of: "[") { return (String(type[..<range.lowerBound]), true) }
        return (type, false)
    }

    private static func baseType(of type: String) -> String {
        return String(type.split(separator: "[").first ?? Substring(type))
    }

    private static func parseBigUInt(_ value: Any?) -> BigUInt {
        if let n = value as? BigUInt { return n }
        if let i = value as? Int { return BigUInt(i) }
        if let s = value as? String {
            if s.hasPrefix("0x"), let n = BigUInt(s.dropFirst(2), radix: 16) { return n }
            if let n = BigUInt(s, radix: 10) { return n }
        }
        return BigUInt.zero
    }

    private static func parseBigInt(_ value: Any?) -> BigInt {
        if let n = value as? BigInt { return n }
        if let i = value as? Int { return BigInt(i) }
        if let s = value as? String {
            if s.hasPrefix("0x"), let n = BigInt(s.dropFirst(2), radix: 16) { return n }
            if let n = BigInt(s, radix: 10) { return n }
        }
        return BigInt.zero
    }

    private static func twosComplement32Bytes(_ value: BigInt) -> Data {
        let two256 = BigInt(1) << 256
        var normalized = value % two256
        if normalized < 0 { normalized += two256 }
        let mag = BigUInt(normalized)
        return mag.serialize().leftPadded(to: 32)
    }

    private static func hexToData(_ hexString: String) -> Data? {
        var s = hexString.lowercased()
        if s.hasPrefix("0x") { s.removeFirst(2) }
        guard s.count % 2 == 0 else { return nil }
        var data = Data(); data.reserveCapacity(s.count / 2)
        var idx = s.startIndex
        while idx < s.endIndex {
            let next = s.index(idx, offsetBy: 2)
            let byteStr = s[idx..<next]
            guard let b = UInt8(byteStr, radix: 16) else { return nil }
            data.append(b)
            idx = next
        }
        return data
    }
}

private extension Data {
    func leftPadded(to length: Int) -> Data { if count >= length { return self }; return Data(repeating: 0, count: length - count) + self }
    func rightPadded(to length: Int) -> Data { if count >= length { return self }; return self + Data(repeating: 0, count: length - count) }
}


