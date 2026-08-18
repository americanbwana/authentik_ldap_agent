# Design and safety decisions

## Execution boundary

The Mac launches PowerShell locally and communicates only with the HoloRouter
over key-authenticated SSH. All calls to internal `vcf.lab` endpoints execute on
the router. Secrets are serialized to the remote PowerShell process through
SSH stdin; the encoded remote program contains no secrets.

An alternate execution boundary is supported for an adjacent Ubuntu bastion.
In that mode, the two LDAP implementation scripts execute locally on the
bastion and call Authentik and VCF Automation directly. They perform read-only
endpoint discovery by default and require `-Apply -Confirm` before mutation.
The bastion mode accepts the shared password and Authentik token only through
secure prompts or `SecureString` parameters. It does not bootstrap a token from
the Authentik container; the operator must provide an existing API token.

The bastion workflow defaults to plain LDAP for the isolated lab and does not
require a certificate. `-EnableLdaps` is optional and requires either the
existing named Authentik certificate or explicit bastion-local certificate and
private-key paths. The original router workflow continues enabling LDAPS to
preserve its validated behavior.

## Authentik

The live environment runs Authentik 2026.2.1 in Kubernetes. The automation uses
the REST API for supported CRUD operations and the existing local Kubernetes
service connection to manage the LDAP outpost. A dedicated API token named
`holodeck-ldap-agent` is bootstrapped from the local Authentik container only
after the first deployment confirmation.

The existing HoloRouter certificate for `auth.vcf.lab` is imported into
Authentik for LDAPS. It is issued by the lab CA and includes SANs for
`auth.vcf.lab` and `172.20.41.120`.

The outpost service receives both the router management IP and its VCF-facing
`10.1.1.1` address as Kubernetes `externalIP` values, exposing standard ports
389 and 636 without installing another host daemon. VCF Automation initially
uses plain LDAP on `10.1.1.1:389` because the lab appliance cannot route to the
router management network and Squid cannot proxy LDAP. LDAPS remains exposed
for later hardening.

The `ldapservice` account is separate from human users. An Authentik RBAC role
grants it only `authentik_providers_ldap.search_full_directory` on the managed
LDAP provider.

## VCF Automation

VCF Automation 9.1 uses its documented Provider Management API. The script:

- logs in as `configadmin@all-apps-org-01`;
- tests the complete OpenLDAP configuration before enabling it;
- enables organization-defined LDAPS settings;
- discovers the built-in role IDs rather than hard-coding them;
- imports LDAP groups found by the directory search endpoint; and
- updates existing imported groups on reruns.

## Idempotency and failure behavior

Named objects are queried before creation and patched to the desired state when
they already exist. Duplicate matches stop execution. VCF LDAP settings are not
enabled unless its connection and attribute tests pass. Failures return a
nonzero SSH/PowerShell exit code.
