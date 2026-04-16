# Azure AD / Entra ID OIDC Integration Guide

## Prerequisites

- Azure AD tenant with admin access
- Spooktacular controller running with mTLS

## Step 1: Register an Application

1. In Azure Portal, go to **Microsoft Entra ID → App registrations → New registration**
2. Name: `Spooktacular`, Supported account types: **Single tenant**
3. Redirect URI: leave blank (we use client credentials flow)
4. Note the **Application (client) ID** and **Directory (tenant) ID**
5. Go to **Certificates & secrets → New client secret**, note the secret value

## Step 2: Configure Group Claims

1. Go to **Token configuration → Add groups claim**
2. Select **Security groups** and **Group ID** format
3. This adds group memberships to the JWT's `groups` claim

## Step 3: Configure Spooktacular

```json
{
  "providers": [
    {
      "type": "oidc",
      "config": {
        "issuerURL": "https://login.microsoftonline.com/YOUR-TENANT-ID/v2.0",
        "clientID": "YOUR-CLIENT-ID",
        "audience": "YOUR-CLIENT-ID",
        "groupRoleMapping": {
          "GROUP-OBJECT-ID-FOR-CI": ["ci-operator"],
          "GROUP-OBJECT-ID-FOR-ADMINS": ["platform-admin"]
        }
      }
    }
  ]
}
```

Note: Azure AD uses group Object IDs (GUIDs), not group names.

## Step 4: Verify

```bash
TOKEN=$(curl -s -X POST "https://login.microsoftonline.com/TENANT-ID/oauth2/v2.0/token" \
  -d "grant_type=client_credentials&client_id=CLIENT-ID&client_secret=SECRET&scope=CLIENT-ID/.default" \
  | jq -r '.access_token')

curl -H "Authorization: Bearer $TOKEN" https://spooktacular-host:8484/health
```

## Troubleshooting

- **Issuer mismatch**: Azure v2.0 issuer is `https://login.microsoftonline.com/TENANT-ID/v2.0`
- **No groups claim**: Ensure "Token configuration → Groups claim" is enabled
- **Group IDs not names**: Azure AD returns Object IDs — map those in `groupRoleMapping`
