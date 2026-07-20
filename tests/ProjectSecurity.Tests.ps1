Describe 'Repository credential safety' {
    It 'ignores secret-bearing artifacts' {
        $ignore = Get-Content -LiteralPath (Join-Path $PSScriptRoot '../.gitignore')
        $ignore | Should -Contain '.env'
        $ignore | Should -Contain 'secrets/'
        $ignore | Should -Contain '*.transcript'
    }

    It 'does not pass shared passwords as SSH arguments' {
        $script = Get-Content -LiteralPath (Join-Path $PSScriptRoot '../scripts/Invoke-HolodeckLdapSetup.ps1') -Raw
        $script | Should -Match 'ConvertTo-Json.+\|\s*& ssh'
        $script | Should -Not -Match 'sshArguments.+SharedPassword'
    }

    It 'supports Authentik-only LDAP setup without invoking the VCF LDAP script' {
        $script = Get-Content -LiteralPath (Join-Path $PSScriptRoot '../scripts/Invoke-HolodeckLdapSetup.ps1') -Raw
        $script | Should -Match '\[switch\]\s+\$AuthentikOnly'
        $script | Should -Match 'if \(\$AuthentikOnly\)[\s\S]+?IdentityProviderHandoff[\s\S]+?return'
        $script.IndexOf('if ($AuthentikOnly)') | Should -BeLessThan $script.IndexOf("Write-Information 'Configuring LDAP and group roles in VCF Automation.'")
    }
}
