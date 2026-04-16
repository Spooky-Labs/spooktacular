# Generic OIDC Integration Guide

Any OpenID Connect provider that supports [RFC 6749](https://www.rfc-editor.org/rfc/rfc6749) (OAuth 2.0) and [OpenID Connect Core 1.0](https://openid.net/specs/openid-connect-core-1_0.html) can be used with Spooktacular.

## Standards

- [RFC 6749](https://www.rfc-editor.org/rfc/rfc6749): OAuth 2.0 Authorization Framework
- [RFC 7519](https://www.rfc-editor.org/rfc/rfc7519): JSON Web Token (JWT)
- [RFC 7517](https://www.rfc-editor.org/rfc/rfc7517): JSON Web Key (JWK)
- [OpenID Connect Discovery 1.0](https://openid.net/specs/openid-connect-discovery-1_0.html): `.well-known/openid-configuration`
- [NIST SP 800-63B](https://pages.nist.gov/800-63-3/sp800-63b.html): Digital Identity Guidelines (Authentication)

## Requirements

Your OIDC provider must support:
- `/.well-known/openid-configuration` discovery endpoint
- JWKS endpoint for RS256 public key retrieval
- `iss`, `sub`, `aud`, `exp` claims in ID tokens
- `groups` or `roles` claim for authorization mapping

## Configuration

```json
{
  "type": "oidc",
  "config": {
    "issuerURL": "https://your-provider.example.com",
    "clientID": "spooktacular-client-id",
    "audience": "spooktacular-client-id",
    "groupRoleMapping": {
      "your-group-name": ["ci-operator"]
    }
  }
}
```

## Verification Flow

1. Client presents JWT Bearer token
2. Spooktacular fetches `/.well-known/openid-configuration` from issuer
3. Fetches JWKS and caches (1-hour TTL per [RFC 7517](https://www.rfc-editor.org/rfc/rfc7517))
4. Verifies RS256 signature against matching key ID (`kid`)
5. Validates `iss`, `aud`, `exp` claims
6. Extracts `groups`/`roles` → maps to Spooktacular roles via `groupRoleMapping`
7. Builds `AuthorizationContext` with actor identity, tenant, and permissions
