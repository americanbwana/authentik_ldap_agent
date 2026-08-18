#Requires -Version 7.2
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$productionScriptPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts/remote/Set-AuthentikLdap.ps1'
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile(
    $productionScriptPath,
    [ref] $tokens,
    [ref] $parseErrors
)
if ($parseErrors.Count -gt 0) { throw 'The production Authentik script did not parse.' }
$functionAst = $ast.Find({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -eq 'Ensure-LdapProvider'
}, $true)
if ($null -eq $functionAst) { throw 'Ensure-LdapProvider was not found.' }
Invoke-Expression $functionAst.Extent.Text

$payload = @{ LdapBaseDn = 'dc=vcf,dc=lab' }
$capturedBodies = [Collections.Generic.List[hashtable]]::new()
function Get-SingleResult { return $null }
function Get-Flow { [pscustomobject]@{ pk = 'invalidation-flow-pk' } }
function Resolve-ApiObject { param($Response); $Response }
function Invoke-AuthentikApi {
    param([string] $Method, [string] $Path, [hashtable] $Body)
    $capturedBodies.Add($Body)
    [pscustomobject]@{ pk = 42; name = $Body.name; certificate = $Body.certificate }
}

$plainProvider = Ensure-LdapProvider $null ([pscustomobject]@{ pk = 'bind-flow-pk' })
$tlsProvider = Ensure-LdapProvider ([pscustomobject]@{ pk = 'certificate-pk' }) ([pscustomobject]@{ pk = 'bind-flow-pk' })

if ($null -ne $capturedBodies[0].certificate) { throw 'Plain LDAP unexpectedly included a certificate.' }
if ($capturedBodies[1].certificate -ne 'certificate-pk') { throw 'Optional LDAPS did not include the certificate pk.' }
if ($plainProvider.pk -ne 42 -or $tlsProvider.pk -ne 42) { throw 'Provider creation result was not preserved.' }

[ordered]@{
    Result = 'Passed'
    PlainLdapCertificate = $capturedBodies[0].certificate
    OptionalLdapsCertificate = $capturedBodies[1].certificate
    Host = '10.1.1.1'
    Port = 389
    LdapsEnabledType = ([bool] $false).GetType().FullName
} | ConvertTo-Json
