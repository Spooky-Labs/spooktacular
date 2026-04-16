# Azure AD / Entra ID SAML Integration Guide

## Standards Referenced

- [SAML 2.0 Core (OASIS)](http://docs.oasis-open.org/security/saml/v2.0/saml-core-2.0-os.pdf)
- [NIST SP 800-63C: Federation and Assertions](https://pages.nist.gov/800-63-3/sp800-63c.html)
- [Microsoft Entra SAML Documentation](https://learn.microsoft.com/en-us/entra/identity/enterprise-apps/configure-saml-sso)

## Step 1: Create Enterprise Application

1. In Azure Portal → **Microsoft Entra ID → Enterprise Applications → New Application**
2. Select **Create your own application**
3. Name: `Spooktacular`, select **Non-gallery application**

## Step 2: Configure SAML SSO

1. Go to **Single sign-on → SAML**
2. Set **Identifier (Entity ID)**: `https://spooktacular.app/saml`
3. Set **Reply URL (ACS URL)**: `https://your-controller:8484/v1/auth/saml/callback`
4. Under **Attributes & Claims**, add a group claim (Security groups, sAMAccountName)
5. Download the **Certificate (Base64)** from the SAML Signing Certificate section

## Step 3: Configure Spooktacular

```json
{
  "type": "saml",
  "config": {
    "entityID": "https://sts.windows.net/YOUR-TENANT-ID/",
    "ssoURL": "https://login.microsoftonline.com/YOUR-TENANT-ID/saml2",
    "certificate": "PASTE_BASE64_CERTIFICATE_HERE",
    "groupRoleMapping": {
      "CI-Operators-Group": ["ci-operator"],
      "Platform-Admins-Group": ["platform-admin"]
    }
  }
}
```

## Step 4: Assign Users

1. Go to **Enterprise Application → Users and groups → Add user/group**
2. Assign the groups that should have Spooktacular access

## Verification

Test the SAML flow by initiating SSO from Azure AD and verifying the assertion is accepted by Spooktacular.
