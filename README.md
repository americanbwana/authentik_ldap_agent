# Holodeck Authentik LDAP automation

Idempotent PowerShell automation for exposing Authentik as an LDAP directory and
adding it to the VCF Automation organization `all-apps-org-01`.

## Security

No password is accepted as a normal command-line argument or stored in this
repository. Credentials are supplied as `PSCredential`/`SecureString` values at
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
```

Implementation of the Authentik and VCF API mutations will be completed after
read-only discovery establishes the versions and API shapes in the live lab.

