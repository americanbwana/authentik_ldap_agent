# OpenLDAP attribute mappings for VCF Automation

These are the validated mappings for the Authentik LDAP outpost used by the
Holodeck VCF Automation organization.

## Connection and search settings

| Setting | Value |
|---|---|
| Connector type | `OPEN_LDAP` |
| Host | `10.1.1.1` |
| Port | `389` |
| SSL | Disabled |
| Authentication | `SIMPLE` |
| Search base | `dc=vcf,dc=lab` |
| Group search base | `ou=groups,dc=vcf,dc=lab` |
| Bind DN | `cn=ldapservice,ou=users,dc=vcf,dc=lab` |

Supply the bind account password interactively or through the VCF Automation
interface. Do not store it in this repository.

## User attributes

| VCF Automation field | OpenLDAP attribute |
|---|---|
| Object class | `user` |
| Object identifier | `uid` |
| Username | `cn` |
| Email | `mail` |
| Display name / full name | `displayName` |
| Given name | `name` |
| Surname | `name` |
| Telephone | `telephoneNumber` |
| Group membership identifier | `dn` |
| Group backlink identifier | `memberOf` |

Authentik exposes `uid` as a stable hashed identifier. The interactive login
name is `cn`; do not map the username field to `uid`.

VCF's LDAP test API calls the display-name field `fullName`. The persisted
organization LDAP settings call the same field `displayName`. In the UI, map
the display/full-name field to the LDAP attribute `displayName`.

## Group attributes

| VCF Automation field | OpenLDAP attribute |
|---|---|
| Object class | `groupOfNames` |
| Object identifier | `uid` |
| Group name | `cn` |
| Membership | `member` |
| Membership identifier | `dn` |
| Backlink identifier | `vcfBackLink` |

`vcfBackLink` is required. Each managed Authentik group must expose its own DN
as a real custom attribute:

```yaml
vcfBackLink: cn=vcf-admins,ou=groups,dc=vcf,dc=lab
```

```yaml
vcfBackLink: cn=vcf-users,ou=groups,dc=vcf,dc=lab
```

Do not map the group backlink to `dn` or `memberOf`. Authentik exposes `dn`
virtually but does not match the group lookup filter VCF issues against that
virtual attribute. `memberOf` is present on user objects, not as the required
group-side backlink.

## Expected group role assignments

| LDAP group | VCF Automation role |
|---|---|
| `vcf-admins` | `Organization Administrator` |
| `vcf-users` | `Organization User` |

