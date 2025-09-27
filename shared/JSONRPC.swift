//
//  JSONRPC.swift
//  ios-wallet
//
//  Extracted common JSON-RPC request utility.
//

import Foundation

enum JSONRPC {
    /// Generic function to make JSON-RPC requests
    static func request<T>(rpcURL: URL, method: String, params: [Any], timeout: TimeInterval = 30.0) async throws -> T {
        return try await withCheckedThrowingContinuation { continuation in
            var request = URLRequest(url: rpcURL)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.timeoutInterval = timeout

            let requestBody: [String: Any] = [
                "jsonrpc": "2.0",
                "id": Int.random(in: 1...999999),
                "method": method,
                "params": params
            ]

            do {
                request.httpBody = try JSONSerialization.data(withJSONObject: requestBody, options: [])

                let task = URLSession.shared.dataTask(with: request) { data, response, error in
                    if let error = error {
                        continuation.resume(throwing: error)
                        return
                    }

                    guard let data = data else {
                        continuation.resume(throwing: NSError(domain: "RPC", code: 1, userInfo: [NSLocalizedDescriptionKey: "No data received"]))
                        return
                    }

                    do {
                        if let jsonResponse = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] {
                            if let result = jsonResponse["result"] {
                                // Try to cast the result to the expected type
                                if let typedResult = result as? T {
                                    continuation.resume(returning: typedResult)
                                } else {
                                    continuation.resume(throwing: NSError(domain: "RPC", code: 4, userInfo: [NSLocalizedDescriptionKey: "Unexpected result type for method \(method)"]))
                                }
                            } else if let errorResponse = jsonResponse["error"] as? [String: Any],
                                      let message = errorResponse["message"] as? String {
                                continuation.resume(throwing: NSError(domain: "RPC", code: 2, userInfo: [NSLocalizedDescriptionKey: message]))
                            } else {
                                continuation.resume(throwing: NSError(domain: "RPC", code: 3, userInfo: [NSLocalizedDescriptionKey: "Invalid RPC response"]))
                            }
                        } else {
                            continuation.resume(throwing: NSError(domain: "RPC", code: 5, userInfo: [NSLocalizedDescriptionKey: "Invalid JSON response"]))
                        }
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
                task.resume()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}

