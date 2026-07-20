#Requires -Version 7.2
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter()]
    [string] $ConfigurationPath = (Join-Path $PSScriptRoot '../config/holodeck.example.psd1'),

    [Parameter()]
    [switch] $Apply,

    [Parameter()]
    [securestring] $SharedPassword,

    [Parameter()]
    [switch] $OidcDiscovery,

    [Parameter()]
    [switch] $Oidc,

    [Parameter()]
    [switch] $AuthentikOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($AuthentikOnly -and ($Oidc -or $OidcDiscovery)) {
    throw '-AuthentikOnly applies only to LDAP and cannot be combined with -Oidc or -OidcDiscovery.'
}

function Invoke-RouterPowerShell {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [hashtable] $Configuration,
        [Parameter(Mandatory)] [scriptblock] $ScriptBlock,
        [Parameter()] [hashtable] $InputObject
    )

    $sshArguments = @(
        '-T',
        '-i', $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Configuration.SshIdentityFile),
        '-o', 'BatchMode=yes',
        '-o', 'ConnectTimeout=10',
        ('{0}@{1}' -f $Configuration.RouterUser, $Configuration.RouterHost)
    )

    $remoteScript = "`$ErrorActionPreference='Stop'; try { & { $($ScriptBlock.ToString()) } } catch { [Console]::Error.WriteLine(`$_.Exception.Message); exit 1 }"
    $encodedScript = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($remoteScript))
    $remoteCommand = "pwsh -NoLogo -NoProfile -NonInteractive -EncodedCommand $encodedScript"
    $output = if ($null -ne $InputObject) {
        $InputObject | ConvertTo-Json -Depth 20 -Compress | & ssh @sshArguments $remoteCommand
    }
    else {
        & ssh @sshArguments $remoteCommand
    }
    if ($LASTEXITCODE -ne 0) {
        throw "Remote PowerShell failed with SSH exit code $LASTEXITCODE."
    }
    $output
}

function ConvertFrom-SecureStringValue {
    param([Parameter(Mandatory)] [securestring] $Value)
    $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Value)
    try { [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer) }
}

if (-not (Test-Path -LiteralPath $ConfigurationPath -PathType Leaf)) {
    throw "Configuration file not found: $ConfigurationPath"
}

$configuration = Import-PowerShellDataFile -LiteralPath $ConfigurationPath

Write-Information 'Running read-only Holodeck discovery.' -InformationAction Continue
Invoke-RouterPowerShell -Configuration $configuration -ScriptBlock {
    function Test-TcpEndpoint {
        param([string] $HostName, [int] $Port)
        $client = [Net.Sockets.TcpClient]::new()
        try {
            $task = $client.ConnectAsync($HostName, $Port)
            if (-not $task.Wait([TimeSpan]::FromSeconds(3))) { return $false }
            return $client.Connected
        }
        catch { return $false }
        finally { $client.Dispose() }
    }

    function Get-WebEndpointProbe {
        param([string] $Uri)
        function Invoke-HttpProbe([bool] $SkipCertificateCheck) {
            $handler = [Net.Http.HttpClientHandler]::new()
            $handler.AllowAutoRedirect = $false
            if ($SkipCertificateCheck) {
                $handler.ServerCertificateCustomValidationCallback =
                    [Net.Http.HttpClientHandler]::DangerousAcceptAnyServerCertificateValidator
            }
            $client = [Net.Http.HttpClient]::new($handler)
            $client.Timeout = [TimeSpan]::FromSeconds(10)
            try {
                return $client.GetAsync($Uri).GetAwaiter().GetResult()
            }
            finally {
                $client.Dispose()
                $handler.Dispose()
            }
        }

        $strictTls = $false
        try {
            $strictResponse = Invoke-HttpProbe -SkipCertificateCheck $false
            $strictTls = $true
            $strictResponse.Dispose()
        }
        catch { $strictTls = $false }

        $response = Invoke-HttpProbe -SkipCertificateCheck $true
        try {
            [ordered]@{
                Uri       = $Uri
                Status    = [int] $response.StatusCode
                StrictTls = $strictTls
                Server    = [string] $response.Headers.Server
                Location  = [string] $response.Headers.Location
            }
        }
        finally { $response.Dispose() }
    }

    $availableCommands = 'docker', 'podman', 'kubectl', 'ldapsearch', 'openssl' |
        ForEach-Object { if (Get-Command $_ -ErrorAction SilentlyContinue) { $_ } }

    $containerRuntime = if (($availableCommands -contains 'docker') -and (Test-Path /var/run/docker.sock)) {
        @(& docker ps --format '{{.Names}}|{{.Image}}|{{.Ports}}')
    }
    elseif ($availableCommands -contains 'podman') {
        @(& podman ps --format '{{.Names}}|{{.Image}}|{{.Ports}}')
    }
    else { @() }

    $result = [ordered]@{
        Hostname         = [Environment]::MachineName
        PowerShell       = $PSVersionTable.PSVersion.ToString()
        OperatingSystem  = $PSVersionTable.OS
        AuthentikDns     = @([Net.Dns]::GetHostAddresses('auth.vcf.lab').IPAddressToString)
        AutomationDns    = @([Net.Dns]::GetHostAddresses('auto-a.site-a.vcf.lab').IPAddressToString)
        Commands         = @($availableCommands)
        Containers       = @($containerRuntime)
        LdapPorts        = [ordered]@{
            Port389 = Test-TcpEndpoint -HostName 'auth.vcf.lab' -Port 389
            Port636 = Test-TcpEndpoint -HostName 'auth.vcf.lab' -Port 636
        }
        WebEndpoints     = @(
            Get-WebEndpointProbe 'https://auth.vcf.lab/'
            Get-WebEndpointProbe 'https://auth.vcf.lab/api/v3/root/config/'
            Get-WebEndpointProbe 'https://auto-a.site-a.vcf.lab/'
            Get-WebEndpointProbe 'https://auto-a.site-a.vcf.lab/suite-api/api/versions/current'
        )
    }
    $result | ConvertTo-Json -Depth 4
}

if (-not $Apply) {
    Write-Information 'Dry run complete. No changes were requested.' -InformationAction Continue
    return
}

$identityAction = if ($Oidc) {
    'Create/update the OIDC application, users, group claims, CA trust, and organization identity integration'
}
elseif ($AuthentikOnly) {
    'Create/update only the Authentik LDAP service, users, groups, and Kubernetes outpost'
}
else {
    'Create/update the LDAP service, users, group mappings, and identity integration'
}
$identityTarget = if ($AuthentikOnly) {
    'Authentik LDAP in the Holodeck lab'
}
else {
    "Authentik and VCF Automation organization $($configuration.AutomationOrg)"
}
if (-not $PSCmdlet.ShouldProcess(
    $identityTarget,
    $identityAction
)) {
    return
}

if ($null -eq $SharedPassword -and $IsMacOS) {
    $keychainPassword = & /usr/bin/security find-generic-password `
        -a $configuration.KeychainAccount `
        -s $configuration.KeychainService `
        -w 2>$null
    if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($keychainPassword)) {
        $SharedPassword = ConvertTo-SecureString -String $keychainPassword -AsPlainText -Force
        $keychainPassword = $null
    }
}
if ($null -eq $SharedPassword) {
    $SharedPassword = Read-Host 'Shared Holodeck password' -AsSecureString
}
$plainPassword = ConvertFrom-SecureStringValue $SharedPassword

try {
    Write-Information 'Bootstrapping/reusing the dedicated Authentik automation token.' -InformationAction Continue
    $tokenOutput = @(Invoke-RouterPowerShell -Configuration $configuration -ScriptBlock {
        $container = @(& crictl ps --name server --quiet)[0]
        if ([string]::IsNullOrWhiteSpace($container)) { throw 'Authentik server container was not found.' }
        $python = "from authentik.core.models import Token, User; u=User.objects.get(username='akadmin'); t,c=Token.objects.get_or_create(identifier='holodeck-ldap-agent', defaults={'user':u,'intent':'api','expiring':False,'description':'Holodeck LDAP automation'}); t.user=u; t.intent='api'; t.expiring=False; t.description='Holodeck LDAP automation'; t.save(); print(t.key)"
        @(& crictl exec $container ak shell -c $python 2>$null)[-1]
    })
    $authentikToken = ([string] $tokenOutput[-1]).Trim()
    if ([string]::IsNullOrWhiteSpace($authentikToken)) { throw 'Authentik automation token bootstrap returned no token.' }

    $commonPayload = @{
        SharedPassword   = $plainPassword
        LdapBaseDn       = $configuration.LdapBaseDn
        AdminGroup       = $configuration.LdapAdminGroup
        UserGroup        = $configuration.LdapUserGroup
        AutomationUser   = $configuration.AutomationUser
        AutomationOrg    = $configuration.AutomationOrg
    }

    if ($OidcDiscovery) {
        Write-Information 'Discovering VCF Automation organization OIDC settings.' -InformationAction Continue
        $discoveryScript = [scriptblock]::Create((Get-Content -LiteralPath (Join-Path $PSScriptRoot 'remote/Get-VcfOidcDiscovery.ps1') -Raw))
        Invoke-RouterPowerShell -Configuration $configuration -ScriptBlock $discoveryScript -InputObject $commonPayload
        return
    }

    if ($Oidc) {
        Write-Information 'Discovering VCF Automation organization OIDC settings.' -InformationAction Continue
        $discoveryScript = [scriptblock]::Create((Get-Content -LiteralPath (Join-Path $PSScriptRoot 'remote/Get-VcfOidcDiscovery.ps1') -Raw))
        $discoveryOutput = @(Invoke-RouterPowerShell -Configuration $configuration -ScriptBlock $discoveryScript -InputObject $commonPayload)
        $oidcDetails = ($discoveryOutput -join "`n") | ConvertFrom-Json
        $oidcPayload = $commonPayload.Clone()
        $oidcPayload.AuthentikToken = $authentikToken
        $oidcPayload.RedirectUri = $oidcDetails.RedirectUri
        $oidcPayload.OrganizationId = $oidcDetails.OrganizationId

        Write-Information 'Creating/updating the Authentik OIDC application.' -InformationAction Continue
        $authentikOidcScript = [scriptblock]::Create((Get-Content -LiteralPath (Join-Path $PSScriptRoot 'remote/Set-AuthentikOidc.ps1') -Raw))
        $authentikOidcResult = Invoke-RouterPowerShell -Configuration $configuration -ScriptBlock $authentikOidcScript -InputObject $oidcPayload

        Write-Information 'Configuring OIDC for the VCF Automation organization.' -InformationAction Continue
        $vcfOidcScript = [scriptblock]::Create((Get-Content -LiteralPath (Join-Path $PSScriptRoot 'remote/Set-VcfAutomationOidc.ps1') -Raw))
        $vcfOidcResult = Invoke-RouterPowerShell -Configuration $configuration -ScriptBlock $vcfOidcScript -InputObject $oidcPayload
        [ordered]@{
            Authentik = (($authentikOidcResult -join "`n") | ConvertFrom-Json)
            VcfAutomation = (($vcfOidcResult -join "`n") | ConvertFrom-Json)
        } | ConvertTo-Json -Depth 10
        return
    }

    Write-Information 'Creating/updating the Authentik LDAP service.' -InformationAction Continue
    $authentikScript = [scriptblock]::Create((Get-Content -LiteralPath (Join-Path $PSScriptRoot 'remote/Set-AuthentikLdap.ps1') -Raw))
    $authentikPayload = $commonPayload.Clone()
    $authentikPayload.AuthentikToken = $authentikToken
    $authentikResult = Invoke-RouterPowerShell -Configuration $configuration -ScriptBlock $authentikScript -InputObject $authentikPayload

    Write-Information 'Waiting for the LDAP endpoint.' -InformationAction Continue
    $deadline = [DateTime]::UtcNow.AddMinutes(5)
    do {
        $ready = ([string](Invoke-RouterPowerShell -Configuration $configuration -ScriptBlock {
            $client = [Net.Sockets.TcpClient]::new()
            try {
                $task = $client.ConnectAsync('10.1.1.1', 389)
                [bool]($task.Wait([TimeSpan]::FromSeconds(3)) -and $client.Connected)
            }
            catch { $false }
            finally { $client.Dispose() }
        })).Trim() -eq 'True'
        if (-not $ready) { Start-Sleep -Seconds 10 }
    } until ($ready -or [DateTime]::UtcNow -ge $deadline)
    if (-not $ready) { throw 'Internal LDAP endpoint 10.1.1.1:389 did not become available within five minutes.' }

    if ($AuthentikOnly) {
        [ordered]@{
            Mode = 'AuthentikOnly'
            Authentik = ($authentikResult | ConvertFrom-Json)
            IdentityProviderHandoff = [ordered]@{
                ConnectorType = 'OPEN_LDAP'
                HostName = '10.1.1.1'
                Port = 389
                Ssl = $false
                SearchBase = $configuration.LdapBaseDn
                GroupSearchBase = "ou=groups,$($configuration.LdapBaseDn)"
                BindDn = "cn=ldapservice,ou=users,$($configuration.LdapBaseDn)"
                AdminGroup = $configuration.LdapAdminGroup
                UserGroup = $configuration.LdapUserGroup
            }
        } | ConvertTo-Json -Depth 10
        return
    }

    Write-Information 'Configuring LDAP and group roles in VCF Automation.' -InformationAction Continue
    $vcfScript = [scriptblock]::Create((Get-Content -LiteralPath (Join-Path $PSScriptRoot 'remote/Set-VcfAutomationLdap.ps1') -Raw))
    $vcfResult = Invoke-RouterPowerShell -Configuration $configuration -ScriptBlock $vcfScript -InputObject $commonPayload

    [ordered]@{
        Authentik = ($authentikResult | ConvertFrom-Json)
        VcfAutomation = ($vcfResult | ConvertFrom-Json)
    } | ConvertTo-Json -Depth 10
}
finally {
    $plainPassword = $null
    $authentikToken = $null
}
