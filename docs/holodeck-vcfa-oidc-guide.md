# HoloDeck Authentik OIDC for VCF Automation 9.1

This guide configures the Authentik instance embedded in HoloDeck as an
organization-level OpenID Connect (OIDC) identity provider for VCF Automation
(VCFA) 9.1. The procedure was validated in the Site A lab by signing in to the
VCFA interface as `vcfadmin` with a fixed organization-role assignment.

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
| Optional deferred-role scope | `vcf` |

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

## 9. Configure identity and group claim mappings

Configure these mappings:

| VCFA field | Authentik claim |
|---|---|
| Subject | `preferred_username` |
| Email | `email` |
| Full Name | `name` |
| First Name | `given_name` |
| Last Name | Leave blank |
| Groups | `groups` |
| Roles | Leave blank for fixed roles; `roles` for deferred roles |
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

## 10. Choose the organization authorization model

VCFA supports either a fixed role on an imported OIDC user/group or the
predefined **Defer to Identity Provider** role. Use one model deliberately:

| Model | Authentik requirement | Imported VCFA group role |
|---|---|---|
| Fixed role | Matching value in `groups` | `Organization Administrator`, `Organization User`, or another organization role |
| Deferred role | Matching value in `groups` plus exact organization-role names in `roles` | `Defer to Identity Provider` |

The `groups` and `roles` claims serve different purposes. `groups` qualifies a
user through an imported external group. When that group is assigned **Defer
to Identity Provider**, VCFA obtains the session's organization rights from
the `roles` claim. Role names are case-sensitive and must exactly match roles
available in the target organization. If VCFA extracts no matching role, the
user can authenticate but receives no organization rights.

**Defer to Identity Provider applies to organization roles.** Do not return
`System Administrator` in an OIDC role claim as a provider-access workaround.
System-level/provider administrators must be imported or created in the
provider identity context and assigned `System Administrator` explicitly.

### 10.1 Fixed-role model

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

### 10.2 Create the Authentik deferred-role scope mapping

The router OIDC automation creates or updates a scope mapping named `Holodeck
VCF Automation roles`. If no property mappings are defined on the manually
created `holodeck` provider, create one in the Authentik Admin interface:

1. Open **Customization → Property Mappings**.
2. Click **Create**, select **Scope Mapping**, and continue.
3. Configure:

   | Setting | Value |
   |---|---|
   | Name | `VCFA role claims` |
   | Scope name | `vcf` |
   | Description | `Map Authentik groups to VCFA organization roles` |

4. Use this expression:

   ```python
   groups = [group.name for group in request.user.ak_groups.all()]
   roles = []

   if "vcf-admins" in groups or "VCF Administrators" in groups:
       roles.append("Organization Administrator")

   if "vcf-users" in groups or "VCFA Organization Users" in groups:
       roles.append("Organization User")

   return {
       "roles": roles,
   }
   ```

5. Save the mapping.
6. Open **Applications → Providers**, edit the OAuth2/OIDC provider used by
   VCFA, and add `VCFA role claims` under **Advanced protocol settings →
   Scopes** or **Selected scopes**.
7. Retain the existing `openid`, `profile`, and `email` mappings and **Include
   claims in ID token**.

Return only `roles` from the custom mapping. Authentik's standard `profile`
mapping already emits `groups`; returning groups again produces duplicate
values in the claim preview.

### 10.3 Enable deferred roles in VCFA

Edit the organization OIDC provider and configure:

```text
Scopes: openid profile email vcf
Groups: groups
Roles:  roles
```

Enable **Use ID token claims** or **Enable ID token claims** when that control
is present. Save the settings, reopen them, and confirm that the `vcf` scope and
`roles` mapping persisted.

Import exact external group names present in the Authentik preview and assign
each imported group **Defer to Identity Provider**. The Site A mappings are:

| Authentik group | Emitted role |
|---|---|
| `vcf-admins` or `VCF Administrators` | `Organization Administrator` |
| `vcf-users` or `VCFA Organization Users` | `Organization User` |

The imported group and emitted role are evaluated in the target organization.
`Organization User` does not grant provider-level access, and an organization
administrator should not test by landing in a provider/system context that
requires `System Administrator`.

### 10.4 Preview the deferred claims

In **Applications → Providers**, preview the claims for each test user. The
expected `vcfuser01` subset is:

```json
{
  "preferred_username": "vcfuser01",
  "groups": [
    "vcf-users",
    "VCFA Organization Users"
  ],
  "roles": [
    "Organization User"
  ]
}
```

Set a non-empty email such as `vcfuser01@vcf.lab` on the Authentik user before
testing. If VCFA reports `"user.roles":"[]"` while the Authentik preview
contains `roles`, verify the VCFA Roles mapping, the requested `vcf` scope, ID
token claims, and the exact organization context before changing the mapping
expression.

## 11. Validate login and authorization

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

For the deferred-role model, repeat the test in a new private window and verify
both identities in the target organization:

| User | Expected `roles` value | Expected result |
|---|---|---|
| `vcfadmin` | `Organization Administrator` | Organization-administrator capabilities |
| `vcfuser01` | `Organization User` | Organization-user capabilities; no provider-level access |

Closing browser windows does not delete normal-profile cookies. After changing
claims or mappings, remove site data for `auth.vcf.lab`,
`auto-a.site-a.vcf.lab`, and `vc-mgmt-a.site-a.vcf.lab`, or start a completely
new private-browser session. Never refresh a failed OAuth callback URL because
its authorization code and `state` are single-use.

## 12. Return logout to the VCFA login page

By default, VCFA logout can finish on Authentik's session-end page. Authentik
2026.2.1 can return the browser to VCFA by assigning a dedicated invalidation
flow to the VCFA OIDC provider. Do not change the shared
`default-provider-invalidation-flow`, because other Authentik applications can
use it.

### 12.1 Create the redirect stage

1. Open **Flows and Stages → Stages** and create a **Redirect Stage**.
2. Configure:

   | Setting | Value |
   |---|---|
   | Name | `VCFA login redirect` |
   | Mode | Static |
   | Target | `https://auto-a.site-a.vcf.lab/` |
   | Keep flow context | Disabled |

The root VCFA URL is preferred over an internal login-processing endpoint; it
renders the normal signed-out login page.

### 12.2 Create and populate a dedicated invalidation flow

1. Open **Flows and Stages → Flows** and create:

   | Setting | Value |
   |---|---|
   | Name | `VCFA provider invalidation` |
   | Slug | `vcfa-provider-invalidation` |
   | Designation | Invalidation |
   | Authentication | None |

2. Close the flow's edit dialog and return to the flow list.
3. Click the linked flow **name**, not its pencil/edit icon. The edit dialog
   contains only flow properties; the flow detail page contains stage
   bindings.
4. Open **Stage Bindings**, choose **Create or bind… → Existing stage**, bind
   `VCFA login redirect`, and assign order `20`.
5. To terminate the main Authentik browser session as well as the VCFA
   application session, create or reuse a **User Logout Stage** and bind it at
   order `10`.

The recommended order is:

| Order | Stage |
|---:|---|
| 10 | User Logout |
| 20 | `VCFA login redirect` |

Without the User Logout stage, the VCFA session ends but the Authentik SSO
session can remain active, so selecting Authentik again can immediately sign
the user back in.

### 12.3 Assign and validate the flow

1. Open **Applications → Providers** and edit the OAuth2/OIDC provider used by
   VCFA.
2. Set **Invalidation flow** to `VCFA provider invalidation` and save.
3. In a new private window, sign in to VCFA through Authentik and then log out.
4. Confirm the browser passes through Authentik and finishes at
   `https://auto-a.site-a.vcf.lab/` with the normal VCFA login page.
5. Select Authentik again. A credential prompt confirms that the User Logout
   stage ended the main Authentik session; immediate login means only the
   application session ended.

Do not set Authentik's provider **Logout URI** to the VCFA login page. That
field tells Authentik where to notify a relying party about an Authentik-side
logout; it is not the browser's post-logout landing-page setting.

## 13. Troubleshooting

| Observation | Check |
|---|---|
| Authentik rejects the authorization request | Both exact strict redirect URIs and client ID |
| Authentik succeeds but VCFA rejects the callback | Client secret, CA trust, issuer, and token exchange |
| VCFA says the authenticated user is unauthorized | `preferred_username` mappings, exact group import, and assigned role |
| Group is absent from VCFA | Authentik `groups` claim and exact group-name capitalization |
| VCFA reports `"user.roles":"[]"` | `roles` mapping, `vcf` scope, ID-token claims, and organization context |
| Deferred user authenticates but has no rights | Exact case-sensitive organization role and imported group assigned Defer to Identity Provider |
| Organization user cannot open provider context | Expected boundary; provider access requires explicit system-level assignment |
| Issuer validation fails | Per-provider issuer and trailing slash |
| Signature validation fails | JWKS reachability, signing key, and VCFA CA trust |
| Logout finishes at Authentik | Dedicated provider invalidation flow and final redirect-stage binding |

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

## 14. Validation boundary

Validated live in the Site A lab:

- HoloDeck configuration import and Authentik initialization;
- discovery and per-provider issuer;
- both strict redirect URIs;
- Authentik authentication and authorization response;
- the `preferred_username`, email, name, and group claims;
- VCFA claim mappings;
- imported-group authorization; and
- successful VCFA login as `vcfadmin` with a fixed imported-group
  `Organization Administrator` assignment.

Additionally validated live on 2026-08-20:

- Authentik generated `roles: ["Organization User"]` for `vcfuser01` from its
  group membership; and
- the dedicated invalidation flow, redirect stage, and stage binding were
  created successfully in the Authentik 2026.2.1 interface.

Not validated by this procedure:

- successful organization authorization for both `vcfadmin` and `vcfuser01`
  through **Defer to Identity Provider**;
- provider/system administration from a deferred OIDC role claim;
- browser confirmation that the dedicated invalidation flow returns VCFA
  logout to the normal VCFA login page and ends the intended Authentik session;
- the separate central VCF SSO/SCIM workflow;
- `Set-VCFSSOConfiguration` execution or idempotency; and
- production-grade certificate or client-secret rotation.

## References

- [Authentik OAuth2/OIDC provider documentation](https://docs.goauthentik.io/add-secure-apps/providers/oauth2/)
- [Authentik provider property mappings](https://docs.goauthentik.io/add-secure-apps/providers/property-mappings/)
- [Authentik stage bindings](https://docs.goauthentik.io/add-secure-apps/flows-stages/stages/)
- [Authentik OIDC logout](https://docs.goauthentik.io/add-secure-apps/providers/oauth2/frontchannel_and_backchannel_logout/)
- [Authentik OAuth2 provider API retrieval model](https://docs.goauthentik.io/docs/developer-docs/api/reference/providers-oauth-2-retrieve)
- [Broadcom OIDC attribute mapping model](https://developer.broadcom.com/xapis/vmware-cloud-director-api/latest/doc/types/OIDCAttributeMappingType.html)
- [Broadcom organization OAuth settings model](https://developer.broadcom.com/xapis/vmware-cloud-director-api/latest/doc/types/OrgOAuthSettingsType.html)
