#Requires -Version 7.2
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$productionScriptPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts/remote/Set-VcfAutomationLdap.ps1'
$listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
$listener.Start()
$port = ([Net.IPEndPoint] $listener.LocalEndpoint).Port

function Invoke-WebRequest {
    [pscustomobject]@{
        StatusCode = 200
        Headers = @{}
        Content = '{}'
    }
}

try {
    $output = @(& $productionScriptPath `
        -AutomationUri 'https://vcf.test.invalid' `
        -LdapHost '127.0.0.1' `
        -LdapPort $port `
        -AllowUntrustedTls `
        -InformationAction Continue 6>&1)
}
finally {
    $listener.Stop()
}

$text = $output -join "`n"
if ($text -notmatch 'VCF bastion script version: 2026\.08\.18\.2') { throw 'Direct mode did not report its version.' }
if ($text -notmatch 'VCF Automation discovery succeeded: HTTP 200') { throw 'Direct endpoint discovery did not run.' }
if ($text -notmatch 'LDAP endpoint discovery:.+reachable=True') { throw 'Direct LDAP discovery did not succeed.' }
if ($text -notmatch 'Dry run complete') { throw 'Direct dry run did not terminate at the non-mutating boundary.' }

[ordered]@{
    Result = 'Passed'
    ScriptVersion = '2026.08.18.2'
    DirectMode = $true
    WebProbe = $true
    LdapProbe = $true
    MutationAttempted = $false
} | ConvertTo-Json
