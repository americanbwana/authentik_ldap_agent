# Agent instructions: Holodeck Authentik LDAP automation

## Purpose

This repository contains the validated PowerShell automation for exposing the
embedded Holodeck Authentik deployment as LDAP and, optionally, integrating it
with a VCF Automation 9.1 organization.

Before changing or deploying the solution, read:

1. `README.md`
2. `docs/peer-setup-guide.md`
3. `docs/design.md`
4. `docs/development-findings-summary.md`

Treat the scripts as the executable source of truth when documentation and code
differ. Update the documentation whenever behavior or required settings change.

## Validated environment

The solution was live-tested with:

- local development host: macOS with PowerShell 7;
- HoloRouter SSH endpoint: `root@172.20.41.120`;
- SSH identity: `~/.ssh/holodeck_agent_ed25519`;
- embedded Authentik: `https://auth.vcf.lab`, version 2026.2.1;
- VCF Automation: `https://auto-a.site-a.vcf.lab`, version 9.1;
- organization: `all-apps-org-01`;
- organization administrator: `configadmin`;
- LDAP base DN: `dc=vcf,dc=lab`;
- router VCF-facing address: `10.1.1.1`.

These values describe the validated Site A lab and may drift. Run read-only
discovery before relying on them in a rebuilt or upgraded environment.

## Entry point and deployment modes

Use `scripts/Invoke-HolodeckLdapSetup.ps1` from the repository root.

Read-only discovery:

```powershell
./scripts/Invoke-HolodeckLdapSetup.ps1
```

Prepare Authentik LDAP without requiring a VCF organization:

```powershell
./scripts/Invoke-HolodeckLdapSetup.ps1 -Apply -AuthentikOnly -Confirm
```

Full Authentik and VCF Automation integration:

```powershell
./scripts/Invoke-HolodeckLdapSetup.ps1 -Apply -Confirm
```

`-AuthentikOnly` must stop after the LDAP endpoint is reachable. It must not
create a VCF session, inspect an organization, change organization LDAP
settings, or import VCF groups. It returns a password-free
`IdentityProviderHandoff` object for a later manual configuration.

The full mode must test the connection and every VCF LDAP attribute before
enabling organization LDAP. It must then import/update groups, assign roles,
and authenticate the three LDAP users as an end-to-end check.

## Security requirements

Never put a password, private key, Authentik token, or session token in:

- source code or configuration files;
- command-line arguments;
- Git history;
- transcripts or diagnostic artifacts;
- normal output or error messages.

The shared lab password is stored in macOS Keychain using:

- service: `holodeck-standard-password`;
- account: `holodeck`.

The local entry point may also accept a `SecureString`. It converts the value
only in process memory, transports the payload through encrypted SSH stdin, and
clears plaintext/token variables in a `finally` block.

Use key-authenticated SSH. Do not request, record, or automate the router root
password. Do not read or print the private SSH key. API error handling must
redact the shared password before returning details.

Preserve `SupportsShouldProcess`, `-Apply`, and the high-impact confirmation.
Read-only discovery must remain the default when `-Apply` is absent.

## Network and Kubernetes design

Authentik runs in Kubernetes on the HoloRouter. The managed LDAP outpost service
must expose both addresses as Kubernetes `externalIPs`:

```yaml
spec:
  externalIPs:
    - 172.20.41.120
    - 10.1.1.1
```

VCF Automation connects directly to `10.1.1.1:389` using plain LDAP in this
isolated lab. Squid is not an LDAP or LDAPS proxy and is not in the LDAP data
path. Do not redirect LDAP through Squid.

Keep `auth.vcf.lab:636` exposed with the imported lab certificate for future
LDAPS hardening, but do not change the active VCF endpoint to port 636 without
first validating routing and certificate trust from the VCF appliance.

The LDAP outpost backchannel must use the in-cluster Authentik service:

```text
http://authentik-server.default.svc.cluster.local/
```

Keep the browser-facing host as:

```text
https://auth.vcf.lab/
```

This avoids making the outpost backchannel depend on ingress, external DNS, or
Squid.

## Authentik objects and invariants

`scripts/remote/Set-AuthentikLdap.ps1` owns these named objects:

- groups: `vcf-admins`, `vcf-users`;
- users: `vcfadmin`, `vcfuser01`, `vcfuser02`, `ldapservice`;
- flow: `holodeck-ldap-authentication`;
- password stage: `holodeck-ldap-password`;
- identification stage: `holodeck-ldap-identification`;
- login stage: `holodeck-ldap-login`;
- LDAP provider/application: `Holodeck VCF Automation LDAP`;
- application slug: `holodeck-vcf-automation-ldap`;
- certificate: `Holodeck auth.vcf.lab LDAPS`;
- RBAC role: `LDAP directory search`;
- outpost: `Holodeck LDAP Outpost`;
- automation token: `holodeck-ldap-agent`.

The LDAP provider's bind flow is represented by Authentik's API field
`authorization_flow`. Preserve this counterintuitive mapping:

```text
authentication_flow = null
authorization_flow  = holodeck-ldap-authentication
bind_mode            = direct
```

Putting the bind flow in `authentication_flow` causes LDAP bind failures such
as `Flow does not apply to current user`.

Do not bind the allow expression policy to the flow or application. A
flow-level policy can evaluate before LDAP identifies the user and make the
flow inapplicable. With no application policy binding, active users can bind.

The `ldapservice` account must remain separate from human users and must not be
an Authentik superuser. Grant it only
`authentik_providers_ldap.search_full_directory`, scoped to the LDAP provider.

The three human users must retain a `telephoneNumber` custom attribute because
VCF includes it in schema validation.

## Required group backlink compatibility

Do not remove or rename the custom Authentik group attribute `vcfBackLink`.

Each managed group must expose its own DN as a real attribute, for example:

```yaml
vcfBackLink: cn=vcf-admins,ou=groups,dc=vcf,dc=lab
```

VCF reads group DNs from the user's `memberOf` attribute and filters group
objects using the configured group backlink. Authentik exposes `dn` virtually
but does not match VCF filters on that virtual attribute. The following group
backlink mappings are known failures:

- `memberOf`: VCF searches group objects for `memberOf=<group DN>`;
- `dn`: VCF emits the logical `dn=<group DN>` filter, but Authentik returns no
  match.

The working mapping is:

```text
groupAttributes.backLinkIdentifier = vcfBackLink
```

If VCF fails only `GROUP_NAME` and `GROUP_OBJECT_IDENTIFIER`, verify the
`vcfBackLink` values and inspect LDAP outpost search filters before changing
networking or credentials.

## VCF LDAP mapping

The validated connection settings are:

```text
connectorType         = OPEN_LDAP
hostName              = 10.1.1.1
port                  = 389
SSL                   = false
authentication        = SIMPLE
searchBase            = dc=vcf,dc=lab
groupSearchBase       = ou=groups,dc=vcf,dc=lab
bind DN               = cn=ldapservice,ou=users,dc=vcf,dc=lab
```

Validated user mappings:

```text
objectClass               = user
objectIdentifier          = uid
userName                  = cn
email                     = mail
display/full name         = displayName
givenName                 = name
surname                   = name
telephone                 = telephoneNumber
groupMembershipIdentifier = dn
groupBackLinkIdentifier   = memberOf
```

Validated group mappings:

```text
objectClass          = groupOfNames
objectIdentifier     = uid
groupName            = cn
membership           = member
membershipIdentifier = dn
backLinkIdentifier   = vcfBackLink
```

The VCF LDAP test endpoint expects the display-name property as `fullName`.
The organization settings endpoint expects it as `displayName`. Preserve the
translation in `Set-VcfAutomationLdap.ps1`.

VCF group POST and PUT payloads are also different:

- POST must omit `nameInSource`; VCF derives it from LDAP.
- PUT must include the existing group URN, organization reference, source
  reference, and `nameInSource`.

Discover built-in role IDs by name rather than hard-coding IDs:

- `vcf-admins` -> `Organization Administrator`;
- `vcf-users` -> `Organization User`.

## Idempotency and failure behavior

Query named Authentik and VCF objects before creating them. Patch existing
owned objects to the desired state. Stop on duplicate matches rather than
guessing which object to update.

Do not enable VCF LDAP unless:

- the connection test succeeds; and
- no entry in `settingsTest` is unsuccessful.

All remote failures must result in a nonzero SSH/PowerShell exit code. Keep
diagnostics specific enough to distinguish connection, bind, schema, and API
payload failures while redacting secrets.

## Verification requirements

For changes affecting deployment logic:

1. Parse every PowerShell file with
   `System.Management.Automation.Language.Parser`.
2. Run `git diff --check`.
3. Scan tracked/untracked repository content for literal passwords and private
   key headers.
4. Run Pester tests when Pester is installed; explicitly report when it is not.
5. Run read-only discovery before live mutation.
6. For Authentik-only changes, verify the output reports `Mode` as
   `AuthentikOnly` and contains `IdentityProviderHandoff` without a password.
7. For full integration changes, verify all three users appear in
   `AuthenticatedUsers`:
   `vcfadmin`, `vcfuser01`, and `vcfuser02`.
8. Run the applicable deployment a second time when changing create/update
   behavior to prove idempotency.

Do not claim a live path works based only on parsing, mocks, or static tests.
Separate static validation from live-environment evidence in the final report.

## Repository ownership and scope

Preserve unrelated user changes in the working tree. Do not reset, discard, or
overwrite them. Do not commit unless explicitly requested.

Primary files:

- `scripts/Invoke-HolodeckLdapSetup.ps1`
- `scripts/remote/Set-AuthentikLdap.ps1`
- `scripts/remote/Set-VcfAutomationLdap.ps1`
- `config/holodeck.example.psd1`
- `tests/ProjectSecurity.Tests.ps1`
- `docs/peer-setup-guide.md`
- `docs/design.md`
- `docs/development-findings-summary.md`

OIDC scripts remain in the repository, but LDAP is the validated integration
described here. Do not alter OIDC behavior as part of an LDAP-only change unless
the user explicitly requests it.

