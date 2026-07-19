#Requires -Version 7.2
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter()]
    [string] $ConfigurationPath = (Join-Path $PSScriptRoot '../config/holodeck.example.psd1'),

    [Parameter()]
    [switch] $Apply,

    [Parameter()]
    [pscredential] $AuthentikCredential,

    [Parameter()]
    [pscredential] $AutomationCredential,

    [Parameter()]
    [securestring] $InitialUserPassword
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-RequiredCredential {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [pscredential] $Credential,
        [Parameter(Mandatory)] [string] $UserName,
        [Parameter(Mandatory)] [string] $Message
    )

    if ($null -ne $Credential) {
        return $Credential
    }

    return Get-Credential -UserName $UserName -Message $Message
}

function Invoke-RouterPowerShell {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [hashtable] $Configuration,
        [Parameter(Mandatory)] [scriptblock] $ScriptBlock
    )

    $sshArguments = @(
        '-T',
        '-i', $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Configuration.SshIdentityFile),
        '-o', 'BatchMode=yes',
        '-o', 'ConnectTimeout=10',
        ('{0}@{1}' -f $Configuration.RouterUser, $Configuration.RouterHost),
        'pwsh', '-NoLogo', '-NoProfile', '-NonInteractive', '-Command', '-'
    )

    $encodedScript = [Convert]::ToBase64String(
        [Text.Encoding]::Unicode.GetBytes($ScriptBlock.ToString())
    )
    $remoteBootstrap = "`$ErrorActionPreference='Stop'; try { `$decoded=[Text.Encoding]::Unicode.GetString([Convert]::FromBase64String('$encodedScript')); & ([scriptblock]::Create(`$decoded)) } catch { Write-Error `$_; exit 1 }"
    $remoteBootstrap | & ssh @sshArguments
    if ($LASTEXITCODE -ne 0) {
        throw "Remote PowerShell failed with SSH exit code $LASTEXITCODE."
    }
}

if (-not (Test-Path -LiteralPath $ConfigurationPath -PathType Leaf)) {
    throw "Configuration file not found: $ConfigurationPath"
}

$configuration = Import-PowerShellDataFile -LiteralPath $ConfigurationPath

Write-Information 'Running read-only Holodeck discovery.' -InformationAction Continue
Invoke-RouterPowerShell -Configuration $configuration -ScriptBlock {
    $result = [ordered]@{
        Hostname         = [Environment]::MachineName
        PowerShell       = $PSVersionTable.PSVersion.ToString()
        OperatingSystem  = $PSVersionTable.OS
        AuthentikDns     = @([Net.Dns]::GetHostAddresses('auth.vcf.lab').IPAddressToString)
        AutomationDns    = @([Net.Dns]::GetHostAddresses('auto-a.site-a.vcf.lab').IPAddressToString)
    }
    $result | ConvertTo-Json -Depth 4
}

if (-not $Apply) {
    Write-Information 'Dry run complete. No changes were requested.' -InformationAction Continue
    return
}

$authentikCredential = Get-RequiredCredential -Credential $AuthentikCredential -UserName $configuration.AuthentikUser -Message 'Authentik administrator credential'
$automationCredential = Get-RequiredCredential -Credential $AutomationCredential -UserName $configuration.AutomationUser -Message 'VCF Automation organization credential'
if ($null -eq $InitialUserPassword) {
    $InitialUserPassword = Read-Host 'Initial LDAP user password' -AsSecureString
}

if (-not $PSCmdlet.ShouldProcess(
    "Authentik and VCF Automation organization $($configuration.AutomationOrg)",
    'Create/update the LDAP service, users, group mappings, and identity integration'
)) {
    return
}

throw 'Apply mode is intentionally gated until live API discovery and tests are complete.'
