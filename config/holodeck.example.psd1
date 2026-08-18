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
    LdapHost            = '10.1.1.1'
    LdapPort            = 389
    LdapExternalIps     = @('172.20.41.120', '10.1.1.1')
    AllowUntrustedTls   = $false
}
