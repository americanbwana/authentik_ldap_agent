# Holodeck Authentik LDAP automation

Idempotent PowerShell automation for exposing Authentik as an LDAP directory and
adding it to the VCF Automation organization `all-apps-org-01`.

Future Codex sessions should read `AGENTS.md` before modifying or deploying the
solution; it records the validated invariants and recovery context.

For the complete peer-ready procedure and manual configuration reference, see
[the Holodeck Authentik LDAP setup guide](docs/peer-setup-guide.md).
For a presentation-oriented recap of the investigation, effort, architecture,
and validated findings, see [the development findings summary](docs/development-findings-summary.md).

## Security

No password is accepted as a normal command-line argument or stored in this
repository. Credentials are supplied as `SecureString` values at
runtime. The reusable entry point prompts securely unless a caller injects
credentials from an approved secret store.

The first deployment requires `-Apply -Confirm`. Runs without `-Apply` perform
discovery and validation only.

## Initial SSH setup

Use a dedicated SSH key protected by the macOS Keychain. Do not copy the router
password into a file or command argument.

```bash
ssh-keygen -t ed25519 -f ~/.ssh/holodeck_agent_ed25519 -C holodeck-ldap-agent
ssh-add --apple-use-keychain ~/.ssh/holodeck_agent_ed25519
ssh-copy-id -i ~/.ssh/holodeck_agent_ed25519.pub root@172.20.41.120
```

If macOS does not provide `ssh-copy-id`, append the displayed `.pub` key from an
interactive SSH session instead. Confirm setup with:

```bash
ssh -i ~/.ssh/holodeck_agent_ed25519 -o BatchMode=yes root@172.20.41.120 true
```

## Usage

```powershell
# Read-only discovery/dry run
./scripts/Invoke-HolodeckLdapSetup.ps1

# First deployment (prompts for explicit confirmation)
./scripts/Invoke-HolodeckLdapSetup.ps1 -Apply -Confirm

# Prepare Authentik LDAP before the VCF organization exists
./scripts/Invoke-HolodeckLdapSetup.ps1 -Apply -AuthentikOnly -Confirm
```

The implementation is validated against the live Authentik 2026.2.1 OpenAPI
schema and the VCF Automation 9.1 Provider Management APIs. It performs these
operations in dependency order:

1. Creates or updates the Authentik groups, users, LDAP bind service account,
   LDAPS certificate, provider, application, RBAC permission, and managed
   Kubernetes LDAP outpost.
2. Waits for the VCF-facing LDAP endpoint on `10.1.1.1:389`.
3. Uses VCF Automation's LDAP test operation before enabling the organization
   LDAP settings.
4. Imports `vcf-admins` and `vcf-users` and maps them to Organization
   Administrator and Organization User respectively.
5. Authenticates all three LDAP users to VCF Automation as an end-to-end check.

With `-AuthentikOnly`, processing stops after the Authentik LDAP outpost is
reachable. No VCF session, organization settings, or role mappings are touched.
The result includes the connection and directory values needed for a later
manual identity-provider setup.

VCF resolves a user's `memberOf` DN through a real group attribute. Authentik's
LDAP outpost exposes `dn` virtually but does not support filtering on it, so the
automation adds an equivalent `vcfBackLink` attribute to the managed groups.

Passwords and API tokens are transported only inside the encrypted SSH stdin
stream and retained only in process memory. They are never part of a process
argument, repository file, or normal output.

## First deployment

Store the shared lab password once in macOS Keychain without placing it in shell
history:

```bash
security add-generic-password \
  -U \
  -a holodeck \
  -s holodeck-standard-password \
  -w
```

The `security` command prompts for the secret. Then run:

```powershell
./scripts/Invoke-HolodeckLdapSetup.ps1 -Apply -Confirm
```

The script retrieves the item into process memory without printing it. It can
also accept a `SecureString` through `-SharedPassword` from another approved
secret manager. `-WhatIf` and `-Confirm` use PowerShell's standard
`ShouldProcess` behavior.

## Resulting directory layout

- Base DN: `dc=vcf,dc=lab`
- Users: `ou=users,dc=vcf,dc=lab`
- Groups: `ou=groups,dc=vcf,dc=lab`
- Bind DN: `cn=ldapservice,ou=users,dc=vcf,dc=lab`
- VCF Automation endpoint: `10.1.1.1:389` (plain LDAP, lab-only)
- Retained LDAPS endpoint: `auth.vcf.lab:636`
