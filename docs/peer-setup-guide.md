# Holodeck Authentik LDAP setup for VCF Automation 9.1

This runbook reproduces the validated lab configuration that exposes the
embedded Authentik deployment as an LDAP directory and enables it for the VCF
Automation organization `all-apps-org-01`.

The PowerShell automation is the recommended setup method. The manual settings
are included so a peer can review the resulting objects, troubleshoot them, or
recreate the configuration in another Holodeck site.

## 1. Resulting configuration

| Item | Value |
|---|---|
| Authentik URL | `https://auth.vcf.lab` |
| VCF Automation URL | `https://auto-a.site-a.vcf.lab` |
| Organization | `all-apps-org-01` |
| Organization administrator | `configadmin` |
| LDAP base DN | `dc=vcf,dc=lab` |
| User search location | `ou=users,dc=vcf,dc=lab` |
| Group search location | `ou=groups,dc=vcf,dc=lab` |
| Bind DN | `cn=ldapservice,ou=users,dc=vcf,dc=lab` |
| VCF-facing LDAP endpoint | `10.1.1.1:389` |
| Retained LDAPS endpoint | `auth.vcf.lab:636` |
| Router management address | `172.20.41.120` |
| Admin group | `vcf-admins` |
| User group | `vcf-users` |

The Kubernetes LDAP outpost service is bound to both router addresses:

- `172.20.41.120` for management-side access;
- `10.1.1.1` for VCF-side access.

VCF Automation uses `10.1.1.1:389`. This is intentional for the isolated lab:
the VCF appliance can route to the router's VCF-facing address, while Squid
does not proxy LDAP or LDAPS traffic. Port 636 remains available for a later
certificate-trust hardening exercise.

## 2. Prerequisites

On the local Mac, confirm the following:

- PowerShell 7.2 or newer is installed as `pwsh`.
- The repository is available locally.
- TCP/SSH access to `root@172.20.41.120` works.
- `pwsh`, `crictl`, `kubectl`, `ldapsearch`, and `openssl` exist on the router.
- The embedded Authentik and VCF Automation endpoints are healthy.
- The standard lab password is known, but is not placed in a script, shell
  argument, transcript, or repository file.

Run the read-only discovery before making changes:

```powershell
./scripts/Invoke-HolodeckLdapSetup.ps1
```

The output should show:

- `auth.vcf.lab` resolving to the router management address;
- `auto-a.site-a.vcf.lab` resolving to the Automation appliance;
- Authentik returning HTTP 200 from its API configuration endpoint;
- ports 389 and 636 reachable from the router.

## 3. Configure secure SSH access

Create a dedicated key on the Mac. Protect it with a passphrase and store that
passphrase in the macOS Keychain when prompted.

```bash
ssh-keygen -t ed25519 \
  -f ~/.ssh/holodeck_agent_ed25519 \
  -C holodeck-ldap-agent

ssh-add --apple-use-keychain ~/.ssh/holodeck_agent_ed25519
ssh-copy-id -i ~/.ssh/holodeck_agent_ed25519.pub root@172.20.41.120
```

If `ssh-copy-id` is unavailable, display only the public key and append it to
root's `authorized_keys` during an interactive SSH session.

Verify noninteractive access:

```bash
ssh -i ~/.ssh/holodeck_agent_ed25519 \
  -o BatchMode=yes \
  root@172.20.41.120 \
  true
```

When testing PowerShell through SSH from a POSIX shell, protect PowerShell's
`$` expressions from local-shell expansion. For example:

```bash
ssh -i ~/.ssh/holodeck_agent_ed25519 \
  -o BatchMode=yes \
  root@172.20.41.120 \
  'pwsh -NoLogo -NoProfile -Command "$PSVersionTable.PSVersion"'
```

## 4. Store the shared lab password

Store the password once in macOS Keychain. The command prompts securely; do not
put the password after `-w`.

```bash
security add-generic-password \
  -U \
  -a holodeck \
  -s holodeck-standard-password \
  -w
```

The automation retrieves this item into process memory, sends it through the
encrypted SSH standard-input stream, and clears its local plaintext variable in
a `finally` block. It does not place the password in SSH arguments or normal
output.

## 5. Review the site configuration

Review `config/holodeck.example.psd1` and adjust it if the peer's lab differs.
The validated Site A values are:

```powershell
@{
    RouterHost          = '172.20.41.120'
    RouterUser          = 'root'
    SshIdentityFile     = '~/.ssh/holodeck_agent_ed25519'
    AuthentikUri        = 'https://auth.vcf.lab'
    AuthentikUser       = 'akadmin'
    AutomationUri       = 'https://auto-a.site-a.vcf.lab'
    AutomationOrg       = 'all-apps-org-01'
    AutomationUser      = 'configadmin'
    KeychainService     = 'holodeck-standard-password'
    KeychainAccount     = 'holodeck'
    LdapBaseDn          = 'dc=vcf,dc=lab'
    LdapAdminGroup      = 'vcf-admins'
    LdapUserGroup       = 'vcf-users'
    LdapUsers           = @('vcfadmin', 'vcfuser01', 'vcfuser02')
}
```

## 6. Run the automated deployment

### Authentik-only preparation

If the VCF Automation organization does not exist yet, prepare only Authentik:

```powershell
./scripts/Invoke-HolodeckLdapSetup.ps1 -Apply -AuthentikOnly -Confirm
```

This mode creates or updates the complete Authentik directory, bind flow,
provider, certificate, permissions, and Kubernetes LDAP outpost. It waits for
`10.1.1.1:389`, then returns an `IdentityProviderHandoff` object containing the
host, port, bind DN, search bases, and group names. It does not authenticate to
VCF Automation, require the organization to exist, enable organization LDAP,
or import role mappings.

After the organization is created, either configure its identity provider
manually with sections 8 and 9, or run the normal full deployment command. The
full run reuses the existing Authentik objects and completes the VCF portion.

### Full Authentik and VCF Automation deployment

The first run requires explicit approval:

```powershell
./scripts/Invoke-HolodeckLdapSetup.ps1 -Apply -Confirm
```

Approve the single high-impact confirmation after reviewing the target. The
automation then performs these operations in dependency order:

1. Bootstraps or reuses the non-expiring Authentik API token
   `holodeck-ldap-agent` from the local Authentik server container.
2. Creates or updates groups, users, passwords, and the LDAP bind account.
3. Imports the existing `auth.vcf.lab` certificate and key for port 636.
4. Creates the LDAP bind flow, LDAP provider, application, RBAC role, and
   managed Kubernetes outpost.
5. Exposes the outpost service on both router IP addresses.
6. Waits for `10.1.1.1:389` to become reachable.
7. Tests the complete VCF LDAP schema before enabling it.
8. Enables organization-defined LDAP settings.
9. Imports the two LDAP groups and assigns their organization roles.
10. Authenticates all three LDAP users to VCF Automation.

The expected final result includes:

```text
Organization:       all-apps-org-01
LdapEnabled:        true
LdapHost:           10.1.1.1
LdapPort:           389
AdminGroup:         vcf-admins
AdminRole:          Organization Administrator
UserGroup:          vcf-users
UserRole:           Organization User
AuthenticatedUsers: vcfadmin, vcfuser01, vcfuser02
```

Run the same command a second time to confirm idempotency. Existing named
objects are patched instead of duplicated.

## 7. Authentik configuration reference

The automation creates or updates the following Authentik objects. These are
the settings to compare in the Authentik administration interface.

### 7.1 Groups

Create these non-superuser groups:

| Group | Custom attributes |
|---|---|
| `vcf-admins` | `vcfBackLink: cn=vcf-admins,ou=groups,dc=vcf,dc=lab` |
| `vcf-users` | `vcfBackLink: cn=vcf-users,ou=groups,dc=vcf,dc=lab` |

`vcfBackLink` is required for compatibility. VCF reads the user's `memberOf`
DN and searches the group backlink attribute for that value. Authentik exposes
`dn` as a virtual LDAP attribute but does not return a match when VCF filters on
it. The real `vcfBackLink` attribute provides the equivalent searchable value.

### 7.2 Users

Create active internal users under the `users` path:

| User | Group | Purpose |
|---|---|---|
| `vcfadmin` | `vcf-admins` | VCF organization administrator |
| `vcfuser01` | `vcf-users` | VCF organization user |
| `vcfuser02` | `vcf-users` | VCF organization user |
| `ldapservice` | none | Directory bind and search account |

Set the shared lab password on all four accounts. Add this custom user
attribute to the three human users so VCF's required telephone test succeeds:

```yaml
telephoneNumber: "555-0100"
```

Do not grant `ldapservice` an Authentik superuser role.

### 7.3 Authentication flow

Create flow `holodeck-ldap-authentication` with designation
`authentication`. Bind these stages in order:

| Order | Stage | Important setting |
|---:|---|---|
| 10 | `holodeck-ldap-identification` | User fields: username and email; password stage: `holodeck-ldap-password` |
| 30 | `holodeck-ldap-login` | User login stage |

The password stage uses the built-in Authentik backend. The automation also
maintains an allow expression policy but removes its flow/application bindings.
A flow-level policy executes before LDAP identifies the user and can cause the
bind flow to be reported as inapplicable.

### 7.4 LDAP provider

Create provider `Holodeck VCF Automation LDAP` with:

| Setting | Value |
|---|---|
| Base DN | `dc=vcf,dc=lab` |
| Bind mode | Direct |
| Search mode | Cached |
| Authentication flow | None |
| Authorization/Bind flow | `holodeck-ldap-authentication` |
| Invalidation flow | `default-provider-invalidation-flow` |
| Certificate | `Holodeck auth.vcf.lab LDAPS` |
| TLS server name | `auth.vcf.lab` |
| MFA support | Disabled |

The Authentik API calls the provider's bind-flow field
`authorization_flow`. Placing the bind flow in `authentication_flow` causes
LDAP bind attempts to fail with `Flow does not apply to current user`.

### 7.5 Application and search permission

Create application `Holodeck VCF Automation LDAP` with slug
`holodeck-vcf-automation-ldap` and attach the LDAP provider.

Leave the application without policy bindings so active directory users can
bind. Restrict full-directory searching separately:

1. Create RBAC role `LDAP directory search`.
2. Add only `ldapservice` to the role.
3. Assign permission
   `authentik_providers_ldap.search_full_directory`.
4. Scope it to the `Holodeck VCF Automation LDAP` provider.

### 7.6 Certificate

Create or update certificate/key pair `Holodeck auth.vcf.lab LDAPS` from the
router files:

```text
/holodeck-runtime/authentik/ssl/auth.crt
/holodeck-runtime/authentik/ssl/auth.key
```

The current VCF configuration uses plain LDAP on port 389, but retaining this
certificate keeps port 636 available for later use.

### 7.7 Managed LDAP outpost

Create outpost `Holodeck LDAP Outpost`:

| Setting | Value |
|---|---|
| Type | LDAP |
| Provider | `Holodeck VCF Automation LDAP` |
| Service connection | Local Kubernetes Cluster |
| Namespace | `default` |
| Service type | `ClusterIP` |
| Authentik host | `http://authentik-server.default.svc.cluster.local/` |
| Browser host | `https://auth.vcf.lab/` |
| Refresh interval | `seconds=10` |

The service patch must expose both IP addresses:

```yaml
spec:
  externalIPs:
    - 172.20.41.120
    - 10.1.1.1
```

In Authentik's outpost configuration JSON, the equivalent patch is:

```json
{
  "kubernetes_json_patches": {
    "service": [
      {
        "op": "add",
        "path": "/spec/externalIPs",
        "value": ["172.20.41.120", "10.1.1.1"]
      }
    ]
  }
}
```

Using the in-cluster Authentik service for `authentik_host` prevents the LDAP
outpost's backchannel from depending on external DNS, ingress, or Squid.

## 8. VCF Automation LDAP settings

Configure organization-defined LDAP for `all-apps-org-01` with these connection
settings:

| Setting | Value |
|---|---|
| Enabled | Yes |
| Connector type | OpenLDAP |
| Host | `10.1.1.1` |
| Port | `389` |
| SSL | No |
| Authentication | Simple |
| Base/search DN | `dc=vcf,dc=lab` |
| Bind user | `cn=ldapservice,ou=users,dc=vcf,dc=lab` |
| Group search base | `ou=groups,dc=vcf,dc=lab` |
| Group search base enabled | Yes |
| Page size | `100` |
| Maximum results | `200` |
| Maximum user groups | `100` |
| Login button label | `Holodeck LDAP` |

### 8.1 User attribute mappings

| VCF field | LDAP attribute |
|---|---|
| Object class | `user` |
| Object identifier | `uid` |
| Username | `cn` |
| Email | `mail` |
| Display/full name | `displayName` |
| Given name | `name` |
| Surname | `name` |
| Telephone | `telephoneNumber` |
| Group membership identifier | `dn` |
| Group backlink identifier | `memberOf` |

The VCF test endpoint names the display field `fullName`; the organization
settings endpoint names the same field `displayName`. The automation translates
between the two API models.

### 8.2 Group attribute mappings

The validated mapping is:

| VCF field | LDAP attribute |
|---|---|
| Object class | `groupOfNames` |
| Object identifier | `uid` |
| Group name | `cn` |
| Membership | `member` |
| Membership identifier | `dn` |
| Backlink identifier | `vcfBackLink` |

Authentik currently exposes both `groupOfNames` and `group` on these entries.
The automation tests a bounded set of valid combinations and persists the first
one for which VCF reports a successful connection and no failed attributes;
`groupOfNames`, `uid`, and `cn` is the preferred combination above.

### 8.3 Group-to-role mappings

Import the LDAP groups after enabling the directory:

| LDAP group | VCF role |
|---|---|
| `vcf-admins` | Organization Administrator |
| `vcf-users` | Organization User |

When using the API, omit `nameInSource` when creating a new group because VCF
derives it. Include the group's existing URN, organization reference, source
reference, and `nameInSource` when updating it.

## 9. Verification

### 9.1 Check the LDAP service

From the router:

```powershell
function Test-TcpPort([string] $HostName, [int] $Port) {
    $client = [Net.Sockets.TcpClient]::new()
    try {
        $task = $client.ConnectAsync($HostName, $Port)
        $task.Wait([TimeSpan]::FromSeconds(3)) -and $client.Connected
    }
    finally {
        $client.Dispose()
    }
}

Test-TcpPort 10.1.1.1 389
Test-TcpPort auth.vcf.lab 636
```

Use `ldapsearch` with the bind DN when deeper inspection is needed. Enter the
password interactively; do not put it on the command line:

```bash
ldapsearch -x -W \
  -H ldap://10.1.1.1:389 \
  -D 'cn=ldapservice,ou=users,dc=vcf,dc=lab' \
  -b 'dc=vcf,dc=lab' \
  '(|(cn=vcfadmin)(cn=vcf-admins))'
```

Confirm that:

- `vcfadmin` has `memberOf: cn=vcf-admins,ou=groups,dc=vcf,dc=lab`;
- `vcf-admins` has `member` containing the `vcfadmin` DN;
- `vcf-admins` exposes the matching `vcfBackLink` value.

### 9.2 Check VCF Automation

The automated run logs in as each user and returns all three names in
`AuthenticatedUsers`. A peer can additionally test the UI at:

```text
https://auto-a.site-a.vcf.lab
```

Select `Holodeck LDAP` and confirm:

- `vcfadmin` can sign in and has organization-administrator capabilities;
- `vcfuser01` and `vcfuser02` can sign in as organization users.

## 10. Troubleshooting

### VCF connection test fails before attribute checks

Check routing to `10.1.1.1:389`, the two Kubernetes `externalIPs`, the
`ldapservice` password, and its provider-scoped search permission. Do not try to
send LDAP through Squid.

### LDAP bind returns invalid credentials despite the correct password

Confirm the LDAP provider uses:

- `authorization_flow` for `holodeck-ldap-authentication`;
- `authentication_flow` set to null/None;
- Direct bind mode.

Also remove flow-level expression-policy bindings that run before user
identification.

### VCF fails only `GROUP_NAME` and `GROUP_OBJECT_IDENTIFIER`

Inspect the LDAP outpost search filters. If VCF searches groups using either of
these filters, the backlink is wrong:

```text
memberOf=<group DN>
dn=<group DN>
```

The working filter uses:

```text
vcfBackLink=<group DN>
```

Confirm the custom group attribute exists and VCF's group backlink mapping is
`vcfBackLink`.

### VCF fails the telephone attribute

Confirm each test user has the Authentik custom attribute
`telephoneNumber: "555-0100"` and VCF maps Telephone to `telephoneNumber`.

### VCF PUT rejects `fullName`

Use `fullName` only with `/cloudapi/1.0.0/ldap/test`. Use `displayName` in the
organization LDAP settings payload at `/cloudapi/v1/orgSettings/ldap`.

### New group creation rejects `nameInSource`

Omit `nameInSource` on POST. VCF derives it from LDAP. Preserve it on later PUT
updates along with the existing group URN and entity references.

## 11. Files used by the automation

- `scripts/Invoke-HolodeckLdapSetup.ps1`: local entry point, Keychain handling,
  SSH transport, discovery, confirmation, and orchestration.
- `scripts/remote/Set-AuthentikLdap.ps1`: Authentik users, groups, flow,
  provider, permission, certificate, and outpost.
- `scripts/remote/Set-VcfAutomationLdap.ps1`: LDAP schema test, organization
  settings, role mapping, idempotent group import, and login verification.
- `config/holodeck.example.psd1`: site-specific values without secrets.
