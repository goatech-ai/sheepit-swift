import Foundation

/// Opaque receipt captured with one applied config; never decoded or refreshed during delivery.
struct AssignmentReceipt: Codable, Sendable, Equatable {
    let token: String?
    let status: String?

    private enum CodingKeys: String, CodingKey { case token, status }

    init(from decoder: Decoder) throws {
        guard let values = try? decoder.container(keyedBy: CodingKeys.self) else {
            self.init()
            return
        }
        let marked: Bool
        if values.contains(.status) {
            guard let value = try? values.decode(String.self, forKey: .status), value == "identity_changed" else {
                self.init()
                return
            }
            marked = true
        } else { marked = false }
        self.init(token: try? values.decode(String.self, forKey: .token), identityChanged: marked)
    }

    static func validToken(_ raw: Any?) -> String? {
        guard let token = raw as? String, !token.isEmpty, token.utf8.count <= 96, !token.contains("\0") else { return nil }
        return token
    }

    /// Preserve all config values while keeping only validated receipt state on disk.
    /// An absent key and an explicit `null` are both "no receipt": the server sends `null` on
    /// unresolved_device, scope_missing and key_unavailable. Only a present, unusable value is malformed.
    static func isMalformed(_ raw: AnyCodable?) -> Bool {
        guard let raw, !(raw.value is NSNull) else { return false }
        return validToken(raw.value) == nil
    }

    /// Never fails and never discards: if the receipt cannot be rewritten the original bytes are kept
    /// (a malformed receipt reads as unattributed again on load), so a decodable cache is never lost.
    static func cacheData(_ data: Data, config: SDKConfigResponse) -> Data {
        guard isMalformed(config.rawAssignmentToken) else { return data }
        guard var envelope = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              var body = envelope["data"] as? [String: Any] else { return data }
        body["assignment_token"] = NSNull()
        envelope["data"] = body
        return (try? JSONSerialization.data(withJSONObject: envelope)) ?? data
    }

    init(token: String? = nil, identityChanged: Bool = false) {
        // Reject an unusable alias whole; truncation could manufacture a different receipt.
        self.token = identityChanged ? nil : Self.validToken(token)
        self.status = identityChanged ? "identity_changed" : nil
    }
}
