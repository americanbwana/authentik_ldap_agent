# HoloDeck Authentik OIDC for VCF Automation 9.1

This guide configures the Authentik instance embedded in HoloDeck as an
organization-level OpenID Connect (OIDC) identity provider for VCF Automation
(VCFA) 9.1. The procedure was validated in the Site A lab by signing in to the
VCFA Provider Portal as `vcfadmin`.

This is separate from the central VCF SSO and SCIM workflow implemented by
`Set-VCFSSOConfiguration`. That command is not required for this manual VCFA
OIDC exercise.

> Never save or print passwords, the OIDC client secret, bootstrap tokens,
> authorization codes, access tokens, or session tokens in this repository or
> in a PowerShell transcript.

## 1. Validated environment

| Component | Validated value |
|---|---|
| Authentik | `https://auth.vcf.lab` |
| Authentik application | `vcf` |
| Authentik OIDC provider | `holodeck` |
| VCF Automation | `https://auto-a.site-a.vcf.lab` |
| VCF management federation endpoint | `https://vc-mgmt-a.site-a.vcf.lab` |
| Test user | `vcfadmin` |
| Authorized Authentik group | `VCF Administrators` |
| Requested scopes | `openid profile email` |

These values are environment-specific. Run discovery again after rebuilding or
upgrading HoloDeck.

## 2. Prerequisites

- HoloDeck configuration ID and Site A are available.
- Authentik and VCFA resolve and are reachable from their respective clients.
- The Authentik administrator password, VCF user password, and HoloDeck
  bootstrap token are available from an approved runtime secret source.
- `vcfadmin` exists in Authentik and belongs to `VCF Administrators`.
- The operator can administer Authentik and the VCFA organization/provider
  context being configured.
- The HoloDeck CA chain for `auth.vcf.lab` is available for import into VCFA.

Do not run this procedure in a PowerShell session with transcription enabled.

## 3. Import the HoloDeck configuration

`Initialize-Authentik` depends on the HoloDeck configuration stored in the
global `$config` variable. Import the correct configuration and site first:

```powershell
Import-HoloDeckConfig -ConfigID '<configuration-ID>' -Site a
```

Confirm that the expected configuration is active before continuing. A missing
configuration produces errors such as a null `Join-Path`, a null `Test-Path`,
or `Network configuration file not found`.

## 4. Initialize Authentik

Collect secrets interactively so they do not appear as literal command-line
values. `Read-Host -MaskInput` masks the display but returns the string required
by the HoloDeck command:

```powershell
$authentikAdminPassword = Read-Host 'Authentik administrator password' -MaskInput
$vcfUserPassword = Read-Host 'VCF test-user password' -MaskInput
$bootstrapToken = Read-Host 'HoloDeck bootstrap token' -MaskInput

try {
    $oidcProvider = Initialize-Authentik `
        -AdminPassword $authentikAdminPassword `
        -Site a `
        -UserPassword $vcfUserPassword `
        -BootstrapToken $bootstrapToken
}
finally {
    Remove-Variable authentikAdminPassword, vcfUserPassword, bootstrapToken `
        -ErrorAction SilentlyContinue
}
```

The command creates or configures the following Authentik objects used by the
HoloDeck integration:

- the `VCF Administrators` group;
- the `vcfadmin` user;
- the `vcf` application;
- the `holodeck` confidential OAuth2/OIDC provider; and
- its client ID, client secret, signing key, flows, property mappings, issuer,
  and initial VCF federation redirect URI.

Keep `$oidcProvider` only in the current PowerShell process. Do not redirect the
complete object to a file because its output contains the client secret.

## 5. Obtain the client ID and secret safely

### Recommended: retrieve them from Authentik

The values remain available after the initialization session ends:

1. Sign in to the Authentik **Admin interface**.
2. Open **Applications → Providers**.
3. Edit the OAuth2/OpenID provider named `holodeck`.
4. Copy **Client ID** into the VCFA OIDC form.
5. Reveal or copy **Client Secret** only long enough to place it into the VCFA
   form or an approved secret manager.

Authentik's authenticated provider API also returns these fields, but using the
Admin interface avoids putting the secret in normal terminal output.

### Immediate-session alternative

If the `$oidcProvider` object returned by `Initialize-Authentik` is still in
memory, obtain the client ID from its named property:

```powershell
$oidcProvider.client_id
```

Reference `$oidcProvider.client_secret` only at the point where it is securely
transferred. Do not display the complete `$oidcProvider`, use `Format-List *`,
redirect it with `>`, serialize it, or store it in the repository.

To inspect the available property names without their values:

```powershell
$oidcProvider.PSObject.Properties.Name
```

## 6. Add both strict redirect URIs in Authentik

Edit the `holodeck` OAuth2/OpenID provider under **Applications → Providers**.
Configure both redirect URIs with matching mode **Strict**:

```text
https://vc-mgmt-a.site-a.vcf.lab/federation/t/CUSTOMER/auth/response/oauth2
https://auto-a.site-a.vcf.lab/login/oauth?service=provider
```

Important details:

- `CUSTOMER` is the VCF federation tenant name. It is not an All Apps
  Organization name.
- The VCFA callback's `?service=provider` query string is part of the URI and
  must be retained.
- Do not include quotation marks in either stored URI.
- Keep the original federation callback created by `Initialize-Authentik`; add
  the VCFA callback as the second entry.

The second callback can be confirmed from VCFA's browser authorization request
or from the read-only redirect URI shown by the VCFA OIDC configuration.

## 7. Confirm Authentik provider settings

The validated provider has these significant settings:

| Setting | Value |
|---|---|
| Client type | `Confidential` |
| Issuer mode | Per-provider |
| Application slug | `vcf` |
| Signing key | Configured |
| Scopes/property mappings | `openid`, `profile`, `email` |

The discovery document is:

```text
https://auth.vcf.lab/application/o/vcf/.well-known/openid-configuration
```

Its issuer must be exactly:

```text
https://auth.vcf.lab/application/o/vcf/
```

The trailing slash is significant. A workstation test with
`-SkipCertificateCheck` can demonstrate reachability, but it does not prove
that the VCFA backend trusts the `auth.vcf.lab` certificate chain.

## 8. Configure the VCFA OIDC provider

In the applicable VCFA organization/provider context, open:

```text
Administer → Connections → Identity Providers → OIDC
```

Configure:

| Setting | Value |
|---|---|
| Status | Active |
| Client ID | `holodeck` provider client ID |
| Client secret | `holodeck` provider client secret |
| Discovery | Enabled |
| Well-known endpoint | `https://auth.vcf.lab/application/o/vcf/.well-known/openid-configuration` |
| Scopes | `openid profile email` |
| Issuer | `https://auth.vcf.lab/application/o/vcf/` |

Supply the HoloDeck CA certificate chain when VCFA requests the identity
provider certificate. Browser trust does not establish backend trust for OIDC
discovery, token exchange, user information, or JWKS retrieval.

## 9. Use the validated claim mappings

Configure these mappings:

| VCFA field | Authentik claim |
|---|---|
| Subject | `preferred_username` |
| Email | `email` |
| Full Name | `name` |
| First Name | `given_name` |
| Last Name | Leave blank |
| Groups | `groups` |
| Roles | Leave blank initially |
| Name in Source | `preferred_username` |

Do not map **Subject** or **Name in Source** to `sub` for this HoloDeck
configuration. Authentik emits `sub` as an opaque hashed identifier, whereas
`preferred_username` contains the VCFA login name, such as `vcfadmin`.

The validated claim preview for `vcfadmin` contained:

```json
{
  "email": "vcfadmin@vcf.lab",
  "name": "VCF Administrator",
  "given_name": "VCF Administrator",
  "preferred_username": "vcfadmin",
  "groups": [
    "vcf-admins",
    "VCF Administrators"
  ]
}
```

Authentik reported `email_verified` as `false`, but VCFA accepted the login;
no email-verification customization was required. The Full Name mapping makes a
separate Last Name mapping unnecessary for this account.

## 10. Import and authorize the group

Confirm `vcfadmin` belongs to `VCF Administrators` in Authentik. In VCFA,
import the exact external group:

```text
VCF Administrators
```

Assign the role required for the exercise. The validated administrative test
used:

```text
Organization Administrator
```

Group names are case-sensitive identity data. The claim preview may include
both `vcf-admins` and `VCF Administrators`; the imported VCFA group must exactly
match a value delivered in the `groups` claim.

## 11. Validate the login

1. Sign out of VCFA or use a private browser window.
2. Select the configured OIDC identity provider.
3. Authenticate to Authentik as `vcfadmin`.
4. Confirm Authentik returns the browser to:

   ```text
   https://auto-a.site-a.vcf.lab/login/oauth?service=provider
   ```

5. Confirm VCFA opens successfully and recognizes `vcfadmin` with the assigned
   organization role.

The Site A validation completed all of these stages on 2026-08-20. The initial
attempt reached Authentik and returned to VCFA but reported that the user was
not authorized. Changing **Subject** and **Name in Source** from `sub` to
`preferred_username` resolved the failure.

## 12. Troubleshooting

| Observation | Check |
|---|---|
| Authentik rejects the authorization request | Both exact strict redirect URIs and client ID |
| Authentik succeeds but VCFA rejects the callback | Client secret, CA trust, issuer, and token exchange |
| VCFA says the authenticated user is unauthorized | `preferred_username` mappings, exact group import, and assigned role |
| Group is absent from VCFA | Authentik `groups` claim and exact group-name capitalization |
| Issuer validation fails | Per-provider issuer and trailing slash |
| Signature validation fails | JWKS reachability, signing key, and VCFA CA trust |

In Authentik, preview claims from **Applications → Providers → holodeck** for
`vcfadmin`. The minimum expected claims are:

```json
{
  "preferred_username": "vcfadmin",
  "email": "vcfadmin@vcf.lab",
  "groups": ["VCF Administrators"]
}
```

An `authorize_application` event proves that Authentik accepted the browser
authorization request. It does not by itself prove backend code exchange,
token validation, claim processing, group import, or role authorization.

When collecting evidence, redact authorization codes, access and refresh
tokens, client secrets, bootstrap tokens, cookies, `state`, and request/session
identifiers.

## 13. Validation boundary

Validated live in the Site A lab:

- HoloDeck configuration import and Authentik initialization;
- discovery and per-provider issuer;
- both strict redirect URIs;
- Authentik authentication and authorization response;
- the `preferred_username`, email, name, and group claims;
- VCFA claim mappings;
- imported-group authorization; and
- successful VCFA Provider Portal login as `vcfadmin`.

Not validated by this procedure:

- the separate central VCF SSO/SCIM workflow;
- `Set-VCFSSOConfiguration` execution or idempotency; and
- production-grade certificate or client-secret rotation.

## References

- [Authentik OAuth2/OIDC provider documentation](https://docs.goauthentik.io/add-secure-apps/providers/oauth2/)
- [Authentik OAuth2 provider API retrieval model](https://docs.goauthentik.io/docs/developer-docs/api/reference/providers-oauth-2-retrieve)
- [Broadcom OIDC attribute mapping model](https://developer.broadcom.com/xapis/vmware-cloud-director-api/latest/doc/types/OIDCAttributeMappingType.html)
- [Broadcom organization OAuth settings model](https://developer.broadcom.com/xapis/vmware-cloud-director-api/latest/doc/types/OrgOAuthSettingsType.html)
