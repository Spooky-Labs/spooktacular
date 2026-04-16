# PingFederate SAML Integration Guide

## Standards Referenced

- [SAML 2.0 Core (OASIS)](http://docs.oasis-open.org/security/saml/v2.0/saml-core-2.0-os.pdf)
- [NIST SP 800-63C: Federation and Assertions](https://pages.nist.gov/800-63-3/sp800-63c.html)
- [PingFederate SAML Documentation](https://docs.pingidentity.com/pingfederate)

## Step 1: Create SP Connection in PingFederate

1. In PingFederate Admin Console → **SP Connections → Create New**
2. Connection Type: **Browser SSO Profiles**
3. Partner's Entity ID: `https://spooktacular.app/saml`
4. ACS URL: `https://your-controller:8484/v1/auth/saml/callback`
5. Binding: **HTTP-POST**

## Step 2: Configure Attribute Contract

1. Under **Attribute Contract**, extend with:
   - `groups` (from LDAP memberOf or PingDirectory)
   - `email`
   - `displayName`
2. Map these from your user directory

## Step 3: Export Metadata

1. Go to **Server Settings → Server Info**
2. Export the signing certificate (Base64 X.509)
3. Note the Entity ID and SSO URL

## Step 4: Configure Spooktacular

```json
{
  "type": "saml",
  "config": {
    "entityID": "https://your-pingfederate.example.com",
    "ssoURL": "https://your-pingfederate.example.com/idp/SSO.saml2",
    "certificate": "PASTE_BASE64_CERTIFICATE",
    "groupRoleMapping": {
      "cn=ci-operators,ou=groups,dc=example,dc=com": ["ci-operator"],
      "cn=platform-admins,ou=groups,dc=example,dc=com": ["platform-admin"]
    }
  }
}
```

## Troubleshooting

- **Signature verification failed**: Ensure you exported the correct signing certificate (not the SSL cert)
- **Groups not appearing**: Check PingFederate's Attribute Contract includes `memberOf` or custom group attribute
- **NameID format**: PingFederate defaults to transient NameID — configure persistent or email format for stable actor identities
