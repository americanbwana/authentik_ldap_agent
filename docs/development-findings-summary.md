# Authentik LDAP integration with Holodeck VCF Automation

## Executive summary

This effort produced a reusable PowerShell solution that exposes the embedded
Holodeck Authentik deployment as an LDAP directory and integrates it with a VCF
Automation 9.1 organization.

The completed solution:

- creates and maintains the Authentik LDAP users, groups, bind account, flow,
  provider, certificate, permissions, application, and Kubernetes outpost;
- exposes LDAP on the router's VCF-facing address, `10.1.1.1:389`;
- optionally configures LDAP and role mappings for `all-apps-org-01`;
- supports preparing Authentik before the VCF organization exists;
- securely retrieves the shared lab password from macOS Keychain;
- uses a dedicated SSH key instead of storing the router root password;
- tests the complete VCF LDAP schema before enabling it;
- verifies all three LDAP users by authenticating them to VCF Automation; and
- safely updates existing objects on subsequent runs.

## Development effort

Estimated effort for an experienced PowerShell and VMware engineer developing
the same solution without this implementation:

| Work area | Estimated effort |
|---|---:|
| Initial Authentik LDAP and outpost setup | 4–8 hours |
| Kubernetes exposure, routing, and Squid investigation | 3–6 hours |
| Authentik bind-flow and RBAC debugging | 4–8 hours |
| VCF LDAP schema and API troubleshooting | 4–10 hours |
| Group backlink compatibility investigation | 4–12 hours |
| Idempotent automation, secret handling, testing, and documentation | 6–12 hours |
| **Estimated total** | **25–55 engineering hours** |

For an engineer unfamiliar with Authentik internals or the Cloud
Director-derived VCF APIs, the investigation could reasonably take one to two
working weeks.

The active development time used to produce and validate this solution was
approximately **2–3 hours**, excluding pauses, user-response time, and
unattended deployment or outpost-refresh waits. This is an approximate active
work estimate rather than a formal time-tracking measurement.

## Final architecture

| Component | Configuration |
|---|---|
| Authentik | Embedded Holodeck Authentik 2026.2.1 |
| LDAP base DN | `dc=vcf,dc=lab` |
| Bind DN | `cn=ldapservice,ou=users,dc=vcf,dc=lab` |
| VCF-facing endpoint | `10.1.1.1:389` |
| Management-side endpoint | `172.20.41.120:389` |
| Retained secure endpoint | `auth.vcf.lab:636` |
| VCF Automation | `https://auto-a.site-a.vcf.lab` |
| Organization | `all-apps-org-01` |
| Admin group | `vcf-admins` |
| User group | `vcf-users` |

The Kubernetes LDAP outpost service has both router addresses configured as
`externalIPs`:

```yaml
spec:
  externalIPs:
    - 172.20.41.120
    - 10.1.1.1
```

VCF Automation connects directly to `10.1.1.1:389`. Squid is not part of the
LDAP data path because it proxies HTTP and HTTPS traffic, not native LDAP or
LDAPS connections.

## Directory and authorization model

| Identity | Membership or permission | VCF result |
|---|---|---|
| `vcfadmin` | `vcf-admins` | Organization Administrator |
| `vcfuser01` | `vcf-users` | Organization User |
| `vcfuser02` | `vcf-users` | Organization User |
| `ldapservice` | Provider-scoped full-directory search permission | LDAP bind/search account |

The `ldapservice` account is separate from human users and is not an Authentik
superuser. It receives only
`authentik_providers_ldap.search_full_directory`, scoped to the managed LDAP
provider.

## Important technical findings

### Squid was not the principal LDAP failure

Squid does not proxy LDAP or LDAPS, but it was not necessary in the final
design. Exposing the Authentik outpost on the router's VCF-facing IP created a
direct LDAP route from VCF Automation.

Once `10.1.1.1:389` was available, VCF successfully connected to Authentik.
Several earlier errors that appeared to be connection failures were actually
LDAP bind-flow or directory-schema failures.

### Authentik's LDAP bind flow uses an unexpected API field

For the Authentik LDAP provider, the flow used for LDAP binding must be assigned
to the API field named `authorization_flow`. The provider is configured with:

```text
authentication_flow = null
authorization_flow  = holodeck-ldap-authentication
bind_mode            = direct
```

Assigning the bind flow to `authentication_flow` caused LDAP authentication to
fail with `Flow does not apply to current user`.

Flow-level expression-policy bindings also had to be removed because they can
execute before LDAP identifies the user and make the flow inapplicable.

### The outpost backchannel should use the Kubernetes service

The LDAP outpost communicates with Authentik through the in-cluster address:

```text
http://authentik-server.default.svc.cluster.local/
```

The browser-facing host remains:

```text
https://auth.vcf.lab/
```

This keeps the outpost backchannel independent of external ingress, lab DNS
routing, and Squid.

### VCF and Authentik needed a searchable group backlink

Authentik users expose `memberOf` values containing group DNs. VCF reads those
values and searches for a group whose configured backlink attribute equals the
DN.

Authentik exposes `dn` as a virtual LDAP attribute, but it does not return a
match when VCF filters on that virtual attribute. Configuring `memberOf` as the
group backlink was also incorrect because it caused VCF to search group objects
for:

```text
memberOf=<group DN>
```

The compatible solution adds a real custom attribute to each managed group:

```yaml
vcfBackLink: cn=vcf-admins,ou=groups,dc=vcf,dc=lab
```

VCF then maps the group backlink identifier to `vcfBackLink`. This allows VCF
to resolve group membership and validate the group name and identifier.

### VCF uses different LDAP models for testing and persistence

The LDAP test endpoint expects the user display-name mapping as `fullName`.
The organization LDAP settings endpoint expects the same mapping as
`displayName`.

The automation translates between these API models before saving organization
settings.

### VCF group creation and updates require different payloads

For a new external LDAP group, VCF rejects a caller-supplied `nameInSource` and
derives it from LDAP. On subsequent updates, VCF requires the existing group
URN and entity references in the request body.

The automation handles both cases, allowing repeated runs without duplicate
groups or invalid update requests.

## Validated VCF LDAP attribute mappings

### User mappings

| VCF field | LDAP attribute |
|---|---|
| Object class | `user` |
| Object identifier | `uid` |
| Username | `cn` |
| Email | `mail` |
| Display name | `displayName` |
| Given name | `name` |
| Surname | `name` |
| Telephone | `telephoneNumber` |
| Group membership identifier | `dn` |
| Group backlink identifier | `memberOf` |

The human users have a custom `telephoneNumber` value because VCF treats that
attribute as part of its LDAP schema validation.

### Group mappings

| VCF field | LDAP attribute |
|---|---|
| Object class | `groupOfNames` |
| Object identifier | `uid` |
| Group name | `cn` |
| Membership | `member` |
| Membership identifier | `dn` |
| Backlink identifier | `vcfBackLink` |

## Security decisions

- The router root password is not stored by the solution.
- SSH uses a dedicated Ed25519 key.
- The shared lab password is stored in macOS Keychain.
- Passwords and the Authentik API token travel only through encrypted SSH
  standard input and process memory.
- Secrets are not included in command-line arguments, repository files, or
  normal output.
- API errors are redacted before being returned.
- VCF LDAP settings are not enabled unless the connection and complete
  attribute tests pass.

## Deployment modes

### Adjacent Ubuntu bastion

The LDAP implementation scripts can also be uploaded and run independently on
an adjacent PowerShell-enabled Ubuntu bastion. This removes the Mac and router
SSH transport from the execution path while preserving secure prompts,
read-only defaults, explicit confirmation, idempotent object management, and
the separation between Authentik preparation and optional VCF organization
configuration. Bastion mode requires an existing Authentik API token and reuses
the named LDAPS certificate unless protected PEM paths are explicitly supplied.

#### Bastion troubleshooting history

The first live bastion validation established the following boundaries:

1. The public Authentik discovery endpoint returned HTTP 200.
2. Initial API authentication failed because the copied token value was wrong;
   an independent, read-only `/api/v3/core/users/me/` request isolated the issue
   from the LDAP automation.
3. After correcting the copy/paste process, Authentik accepted the API token
   and created `vcf-admins` and `vcf-users`.
4. The subsequent user phase failed because the group PATCH result appeared in
   PowerShell as `System.String` rather than an object containing `pk`.
5. Treating empty and then all scalar PATCH results as no-content responses
   preserved the pre-update object, but the live result still presented as a
   string at the group-to-user boundary.

The current diagnostic adds `-TraceGroupApiResponses`. It records only group
API response method, path, runtime type, and a bounded response body. The
resolver also attempts `ConvertFrom-Json` when a response arrives as a string.
This distinguishes a JSON object serialized with an unexpected content type
from a true scalar response while keeping credentials and certificate material
out of diagnostics.

The trace subsequently proved both GET and PATCH returned proper
`PSCustomObject` values containing `pk`. Because the value observed at the
group-to-user boundary was nevertheless a string, the implementation no longer
uses mutation-function output for group identity. It discards the mutation
output, performs a fresh exact-name GET for each group, validates one object
with `pk`, and only then supplies those IDs to user creation.

The complete boundary trace then exposed the root cause: PowerShell variable
names are case-insensitive. The script parameters `[string] $AdminGroup` and
`[string] $UserGroup` collided with local variables named `$adminGroup` and
`$userGroup`. Assigning each API `PSCustomObject` to the corresponding local
name invoked the parameter's string coercion, producing the observed
`@{pk=...}` string. The API-object variables are now named
`$adminGroupObject` and `$userGroupObject`. The standalone regression test
reproduces the old coercion and rejects any reintroduction of those assignments.

### Authentik-only preparation

Use this when the VCF organization does not exist yet:

```powershell
./scripts/Invoke-HolodeckLdapSetup.ps1 -Apply -AuthentikOnly -Confirm
```

This creates and verifies the complete Authentik LDAP service, then returns a
password-free `IdentityProviderHandoff` object. It performs no VCF organization
operations.

### Full integration

Use this after the organization exists:

```powershell
./scripts/Invoke-HolodeckLdapSetup.ps1 -Apply -Confirm
```

The full mode reuses the existing Authentik objects, validates the VCF LDAP
schema, enables LDAP, imports both groups, assigns roles, and verifies user
authentication.

## Validation evidence

The final live deployment confirmed:

- the Authentik LDAP outpost was reachable at `10.1.1.1:389`;
- VCF's LDAP connection and complete attribute tests passed;
- LDAP was enabled for `all-apps-org-01`;
- `vcf-admins` was assigned Organization Administrator;
- `vcf-users` was assigned Organization User;
- `vcfadmin`, `vcfuser01`, and `vcfuser02` each authenticated successfully;
- the full deployment completed successfully on a subsequent idempotent run;
- Authentik-only mode completed without invoking VCF organization operations;
- PowerShell syntax, whitespace, and repository secret scans passed.

Pester was not installed in the local development environment, so the Pester
test suite was not executed.

## Reusable deliverables

- `scripts/Invoke-HolodeckLdapSetup.ps1`
- `scripts/remote/Set-AuthentikLdap.ps1`
- `scripts/remote/Set-VcfAutomationLdap.ps1`
- `config/holodeck.example.psd1`
- `docs/peer-setup-guide.md`
- `docs/design.md`

Together, these files provide the deployment implementation, security model,
manual configuration reference, and operational troubleshooting guidance.
