# Generic SAML 2.0 Integration Guide

Any SAML 2.0 identity provider can be used with Spooktacular.

## Standards

- [SAML 2.0 Core](http://docs.oasis-open.org/security/saml/v2.0/saml-core-2.0-os.pdf): Assertions and Protocols (OASIS)
- [SAML 2.0 Bindings](http://docs.oasis-open.org/security/saml/v2.0/saml-bindings-2.0-os.pdf): HTTP POST, Redirect
- [XML Signature (W3C)](https://www.w3.org/TR/xmldsig-core1/): XML digital signatures
- [NIST SP 800-63C](https://pages.nist.gov/800-63-3/sp800-63c.html): Federation and Assertions
- [OWASP SAML Security Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/SAML_Security_Cheat_Sheet.html)

## Requirements

Your SAML IdP must provide:
- Entity ID (unique identifier for the IdP)
- SSO URL (where to redirect for authentication)
- X.509 signing certificate (for assertion signature verification)
- NameID in assertions (unique user identifier)
- Attribute statements with group/role memberships

## Configuration

```json
{
  "type": "saml",
  "config": {
    "entityID": "https://your-idp.example.com/saml/metadata",
    "ssoURL": "https://your-idp.example.com/saml/sso",
    "certificate": "BASE64_ENCODED_X509_CERTIFICATE",
    "groupScopeMapping": {},
    "groupTenantMapping": {},
    "groupRoleMapping": {
      "CI-Team": ["ci-operator"],
      "Admins": ["platform-admin"]
    }
  }
}
```

## Verification Flow

1. Client presents base64-encoded SAML Response
2. Spooktacular decodes XML and extracts Issuer, NameID, Attributes
3. Verifies XML signature using IdP's X.509 certificate per [XML Signature](https://www.w3.org/TR/xmldsig-core1/)
4. Validates issuer matches configured `entityID`
5. Checks `SessionNotOnOrAfter` for expiry
6. Extracts `groups`/`role`/`memberOf` attributes → maps to roles
7. Converts to `FederatedIdentity` for unified authorization

## Security Considerations (OWASP)

Per [OWASP SAML Security Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/SAML_Security_Cheat_Sheet.html):
- Always verify XML signatures before trusting assertions
- Validate the `Destination` attribute matches your SP endpoint
- Check `Audience` restriction contains your entity ID
- Use `InResponseTo` to prevent replay attacks
- Reject assertions with expired `NotOnOrAfter` conditions
