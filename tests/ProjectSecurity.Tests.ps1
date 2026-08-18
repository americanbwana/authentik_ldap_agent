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

    It 'keeps bastion secrets out of plaintext parameters' {
        foreach ($name in 'Set-AuthentikLdap.ps1', 'Set-VcfAutomationLdap.ps1') {
            $script = Get-Content -LiteralPath (Join-Path $PSScriptRoot "../scripts/remote/$name") -Raw
            $script | Should -Match '\[securestring\]\s+\$SharedPassword'
            $script | Should -Not -Match '\[string\]\s+\$SharedPassword'
        }
        $authentikScript = Get-Content -LiteralPath (Join-Path $PSScriptRoot '../scripts/remote/Set-AuthentikLdap.ps1') -Raw
        $authentikScript | Should -Match '\[securestring\]\s+\$AuthentikToken'
    }

    It 'retains existing Authentik objects when PATCH returns an empty body' {
        $script = Get-Content -LiteralPath (Join-Path $PSScriptRoot '../scripts/remote/Set-AuthentikLdap.ps1') -Raw
        $script | Should -Match '\$Response -isnot \[string\]'
        $script | Should -Match '\$resolved = if \(\$hasResponseObject\) \{ \$Response \} else \{ \$Existing \}'
    }

    It 'limits bastion API response tracing to group endpoints' {
        $script = Get-Content -LiteralPath (Join-Path $PSScriptRoot '../scripts/remote/Set-AuthentikLdap.ps1') -Raw
        $script | Should -Match '\[switch\]\s+\$TraceGroupApiResponses'
        $script | Should -Match "\$Path -like '/core/groups/\*'"
        $script | Should -Not -Match 'TRACE Authentik request'
    }
}
