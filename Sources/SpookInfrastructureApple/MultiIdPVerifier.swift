import Foundation
import SpookCore
import SpookApplication

/// Routes tokens to the correct IdP verifier based on the token's issuer.
///
/// Supports multiple identity providers simultaneously. For JWT (OIDC),
/// decodes the payload to extract `iss`. For SAML, decodes base64 XML
/// to extract the Issuer element.
public actor MultiIdPVerifier: FederatedIdentityVerifier {
    private var verifiers: [String: any FederatedIdentityVerifier] = [:]

    public init() {}

    /// Registers a verifier for a specific issuer.
    public func register(issuer: String, verifier: any FederatedIdentityVerifier) {
        verifiers[issuer] = verifier
    }

    public func verify(token: String) async throws -> FederatedIdentity {
        // Try JWT (three base64url segments separated by dots)
        let parts = token.split(separator: ".")
        if parts.count == 3 {
            if let payloadData = base64URLDecode(String(parts[1])),
               let claims = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any],
               let iss = claims["iss"] as? String {
                guard let verifier = verifiers[iss] else {
                    throw IdPError.issuerNotRegistered(iss)
                }
                return try await verifier.verify(token: token)
            }
        }

        // Try SAML (base64-encoded XML)
        if let data = Data(base64Encoded: token),
           let xml = String(data: data, encoding: .utf8),
           let issuer = extractSAMLIssuer(xml) {
            guard let verifier = verifiers[issuer] else {
                throw IdPError.issuerNotRegistered(issuer)
            }
            return try await verifier.verify(token: token)
        }

        throw IdPError.unrecognizedTokenFormat
    }

    private func base64URLDecode(_ string: String) -> Data? {
        var s = string.replacingOccurrences(of: "-", with: "+")
                      .replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s += "=" }
        return Data(base64Encoded: s)
    }

    private func extractSAMLIssuer(_ xml: String) -> String? {
        for prefix in ["", "saml:", "saml2:"] {
            let pattern = "<\(prefix)Issuer[^>]*>([^<]+)</\(prefix)Issuer>"
            if let regex = try? NSRegularExpression(pattern: pattern),
               let match = regex.firstMatch(in: xml, range: NSRange(xml.startIndex..., in: xml)),
               let range = Range(match.range(at: 1), in: xml) {
                return String(xml[range])
            }
        }
        return nil
    }
}

/// Errors from IdP routing.
public enum IdPError: Error, LocalizedError, Sendable {
    case issuerNotRegistered(String)
    case unrecognizedTokenFormat

    public var errorDescription: String? {
        switch self {
        case .issuerNotRegistered(let iss): "Identity provider not registered: \(iss)"
        case .unrecognizedTokenFormat: "Token format not recognized (expected JWT or base64 SAML)"
        }
    }
}
