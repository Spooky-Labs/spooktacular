# Okta OIDC Integration Guide

## Prerequisites

- Okta admin account
- Spooktacular controller running with mTLS
- `SPOOK_IDP_CONFIG` pointing to `identity-providers.json`

## Step 1: Create an Okta Application

1. In Okta Admin Console, go to **Applications → Create App Integration**
2. Select **OIDC - OpenID Connect** and **Web Application**
3. Set the sign-in redirect URI to your controller's callback URL
4. Under **Assignments**, assign the users/groups that need Spooktacular access
5. Note the **Client ID** and **Issuer URL** (e.g., `https://your-org.okta.com/oauth2/default`)

## Step 2: Configure Group Claims

1. Go to **Security → API → Authorization Servers → default**
2. Click **Claims → Add Claim**
3. Name: `groups`, Include in: **ID Token**, Value type: **Groups**, Filter: **Matches regex** `.*`
4. This ensures group memberships appear in the JWT token

## Step 3: Configure Spooktacular

Add to `/etc/spooktacular/identity-providers.json`:

```json
{
  "providers": [
    {
      "type": "oidc",
      "config": {
        "issuerURL": "https://your-org.okta.com/oauth2/default",
        "clientID": "your-client-id",
        "audience": "your-client-id",
        "groupScopeMapping": {},
        "groupTenantMapping": {},
        "groupRoleMapping": {
          "CI-Operators": ["ci-operator"],
          "Platform-Admins": ["platform-admin"],
          "Security-Team": ["security-admin"]
        }
      }
    }
  ]
}
```

Map your Okta groups to Spooktacular's built-in roles.

## Step 4: Configure RBAC

Add role assignments to `/etc/spooktacular/rbac.json`:

```json
{
  "roles": [],
  "assignments": [
    {"actor": "https://your-org.okta.com/oauth2/default/user@example.com", "tenant": "default", "role": "ci-operator"}
  ]
}
```

Or rely on group-to-role mapping (recommended for Okta).

## Step 5: Verify

```bash
# Get a token from Okta (use your preferred method)
TOKEN=$(curl -s -X POST "https://your-org.okta.com/oauth2/default/v1/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "grant_type=client_credentials&client_id=CLIENT_ID&client_secret=SECRET&scope=openid" \
  | jq -r '.access_token')

# Test against Spooktacular
curl -H "Authorization: Bearer $TOKEN" https://spooktacular-host:8484/v1/vms
```

## Troubleshooting

- **401 Unauthorized**: Check that `issuerURL` matches exactly (including `/oauth2/default`)
- **Groups not mapped**: Verify the `groups` claim appears in the JWT (`jwt.io` to decode)
- **JWKS fetch failed**: Ensure the controller can reach `https://your-org.okta.com/.well-known/openid-configuration`
