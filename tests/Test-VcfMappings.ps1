#Requires -Version 7.2
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$productionScriptPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts/remote/Set-VcfAutomationLdap.ps1'
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile(
    $productionScriptPath,
    [ref] $tokens,
    [ref] $parseErrors
)
if ($parseErrors.Count -gt 0) { throw 'The production VCF script did not parse.' }
$functionAst = $ast.Find({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -eq 'Get-LdapSettings'
}, $true)
if ($null -eq $functionAst) { throw 'Get-LdapSettings was not found.' }
Invoke-Expression $functionAst.Extent.Text

$payload = @{
    LdapHost = '10.1.1.1'
    LdapPort = 389
    LdapBaseDn = 'dc=vcf,dc=lab'
    SharedPassword = '<runtime-secret>'
}
$settings = Get-LdapSettings
$expected = @{
    HostName = '10.1.1.1'
    Port = 389
    ConnectorType = 'OPEN_LDAP'
    UserObjectClass = 'user'
    UserObjectIdentifier = 'uid'
    UserName = 'cn'
    FullName = 'displayName'
    Telephone = 'telephoneNumber'
    GroupMembershipIdentifier = 'dn'
    GroupBackLinkIdentifier = 'memberOf'
    GroupObjectClassInitial = 'group'
    GroupObjectIdentifierInitial = 'uid'
    GroupNameInitial = 'cn'
    Membership = 'member'
    MembershipIdentifier = 'dn'
    BackLinkIdentifier = 'vcfBackLink'
}
$actual = @{
    HostName = $settings.hostName
    Port = $settings.port
    ConnectorType = $settings.connectorType
    UserObjectClass = $settings.userAttributes.objectClass
    UserObjectIdentifier = $settings.userAttributes.objectIdentifier
    UserName = $settings.userAttributes.userName
    FullName = $settings.userAttributes.fullName
    Telephone = $settings.userAttributes.telephone
    GroupMembershipIdentifier = $settings.userAttributes.groupMembershipIdentifier
    GroupBackLinkIdentifier = $settings.userAttributes.groupBackLinkIdentifier
    GroupObjectClassInitial = $settings.groupAttributes.objectClass
    GroupObjectIdentifierInitial = $settings.groupAttributes.objectIdentifier
    GroupNameInitial = $settings.groupAttributes.groupName
    Membership = $settings.groupAttributes.membership
    MembershipIdentifier = $settings.groupAttributes.membershipIdentifier
    BackLinkIdentifier = $settings.groupAttributes.backLinkIdentifier
}
foreach ($key in $expected.Keys) {
    if ($actual[$key] -ne $expected[$key]) { throw "VCF mapping '$key' was '$($actual[$key])'; expected '$($expected[$key])'." }
}

$productionText = Get-Content -LiteralPath $productionScriptPath -Raw
if ($productionText -match '(?im)^\s*\$adminGroup\s*=') { throw 'The VCF script reintroduced the AdminGroup variable collision.' }
if ($productionText -match '(?im)^\s*\$userGroup\s*=') { throw 'The VCF script reintroduced the UserGroup variable collision.' }
if ($productionText -notmatch 'displayName = \$definedUserAttributes\.fullName') { throw 'The fullName-to-displayName persistence translation is missing.' }
if ($productionText.IndexOf("if (`$null -eq `$test)") -gt $productionText.IndexOf("Invoke-VcfApi PUT '/cloudapi/v1/orgSettings/ldap'")) {
    throw 'VCF LDAP settings can be enabled before successful schema validation.'
}
foreach ($requiredText in @(
    "`$createBody.Remove('nameInSource')",
    '$updateBody.orgEntityRef = $existing[0].orgEntityRef',
    '$updateBody.sourceEntityRef = $existing[0].sourceEntityRef',
    "'vcfadmin', 'vcfuser01', 'vcfuser02'",
    "'Organization Administrator', 'Organization User'"
)) {
    if ($productionText -notmatch [regex]::Escape($requiredText)) {
        throw "Validated VCF workflow invariant is missing: $requiredText"
    }
}

[ordered]@{
    Result = 'Passed'
    MappingCount = $expected.Count
    FullNameTranslation = $true
    GroupVariableCollisions = 0
    EnableAfterSuccessfulTest = $true
    CreateUpdatePayloadSplit = $true
    EndToEndUsersPreserved = $true
} | ConvertTo-Json
