@{
    RouterHost          = '172.20.41.120'
    RouterUser          = 'root'
    SshIdentityFile     = '~/.ssh/holodeck_agent_ed25519'
    AuthentikUri        = 'https://auth.vcf.lab'
    AuthentikUser       = 'akadmin'
    AutomationUri       = 'https://auto-a.site-a.vcf.lab'
    AutomationOrg       = 'all-apps-org-01'
    AutomationUser      = 'configadmin'
    LdapBaseDn          = 'dc=vcf,dc=lab'
    LdapAdminGroup      = 'vcf-admins'
    LdapUserGroup       = 'vcf-users'
    LdapUsers           = @('vcfadmin', 'vcfuser01', 'vcfuser02')
    AllowUntrustedTls   = $false
}

