#Requires -Version 7.2
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = Split-Path $PSScriptRoot -Parent
$productionScriptPath = Join-Path $repositoryRoot 'scripts/remote/Set-AuthentikLdap.ps1'
$fixturePath = Join-Path $PSScriptRoot 'fixtures/authentik-group-responses.json'
$fixture = Get-Content -LiteralPath $fixturePath -Raw | ConvertFrom-Json

# Load the production Get-SingleResult implementation without executing the
# production script's entry point.
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
        $node.Name -eq 'Get-SingleResult'
}, $true)
if ($null -eq $functionAst) { throw 'Get-SingleResult was not found in the production script.' }
Invoke-Expression $functionAst.Extent.Text

function Invoke-AuthentikApi {
    param([string] $Method, [string] $Path)
    if ($Method -ne 'GET') { throw "Unexpected fixture method: $Method" }
    if ($Path -like '*vcf-admins*') { return $fixture.admin.get }
    if ($Path -like '*vcf-users*') { return $fixture.user.get }
    throw "Unexpected fixture path: $Path"
}

# Exercise the same exact-name selection and direct pk extraction now used at
# the production group-to-user boundary.
$productionText = Get-Content -LiteralPath $productionScriptPath -Raw
if ($productionText -match '(?im)^\s*\$adminGroup\s*=') {
    throw 'Production assigns an API object to $adminGroup, which collides case-insensitively with the typed $AdminGroup parameter.'
}
if ($productionText -match '(?im)^\s*\$userGroup\s*=') {
    throw 'Production assigns an API object to $userGroup, which collides case-insensitively with the typed $UserGroup parameter.'
}

# Reproduce the original defect: PowerShell variables are case-insensitive, so
# assigning an API object to $adminGroup coerces it through [string]$AdminGroup.
[string] $AdminGroup = 'vcf-admins'
$adminGroup = $fixture.admin.get.results[0]
if ($adminGroup -isnot [string] -or $adminGroup -notlike '@{pk=*') {
    throw 'The typed variable-collision regression was not reproduced.'
}

$adminGroupObject = Get-SingleResult '/core/groups/?name=vcf-admins' "group 'vcf-admins' after mutation"
$userGroupObject = Get-SingleResult '/core/groups/?name=vcf-users' "group 'vcf-users' after mutation"

if ($adminGroupObject.GetType().FullName -ne 'System.Management.Automation.PSCustomObject') {
    throw "Admin group type was $($adminGroupObject.GetType().FullName)."
}
if ($userGroupObject.GetType().FullName -ne 'System.Management.Automation.PSCustomObject') {
    throw "User group type was $($userGroupObject.GetType().FullName)."
}

$adminGroupPk = [string] $adminGroupObject.pk
$userGroupPk = [string] $userGroupObject.pk
if ($adminGroupPk -ne '99e8a343-053b-4d38-8fe5-b2649ff2b1ae') { throw 'Admin group pk did not match the supplied payload.' }
if ($userGroupPk -ne 'e6859b39-c488-4b38-90ff-0794ee81fdd6') { throw 'User group pk did not match the supplied payload.' }

$vcfAdminBody = @{ username = 'vcfadmin'; groups = @($adminGroupPk) }
$vcfUserBody = @{ username = 'vcfuser01'; groups = @($userGroupPk) }
if ($vcfAdminBody.groups.Count -ne 1 -or $vcfAdminBody.groups[0] -ne $adminGroupPk) {
    throw 'The vcfadmin user payload did not contain the supplied admin group pk.'
}
if ($vcfUserBody.groups.Count -ne 1 -or $vcfUserBody.groups[0] -ne $userGroupPk) {
    throw 'The vcfuser user payload did not contain the supplied user group pk.'
}

[ordered]@{
    Result = 'Passed'
    ProductionFunction = 'Get-SingleResult'
    CollisionReproduced = $true
    AdminGroupType = $adminGroupObject.GetType().FullName
    AdminGroupPk = $adminGroupPk
    UserGroupType = $userGroupObject.GetType().FullName
    UserGroupPk = $userGroupPk
    VcfAdminGroups = @($vcfAdminBody.groups)
    VcfUserGroups = @($vcfUserBody.groups)
} | ConvertTo-Json -Depth 5
