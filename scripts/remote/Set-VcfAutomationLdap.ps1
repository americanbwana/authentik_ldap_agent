[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$payloadText = [Console]::In.ReadToEnd()
if ([string]::IsNullOrWhiteSpace($payloadText)) { throw 'A JSON payload is required on stdin.' }
$payload = $payloadText | ConvertFrom-Json -AsHashtable
$baseUri = 'https://auto-a.site-a.vcf.lab'
$accept = 'application/json;version=9.1.0'

function New-VcfSession {
    $identity = "$($payload.AutomationUser)@$($payload.AutomationOrg):$($payload.SharedPassword)"
    $basic = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($identity))
    $response = Invoke-WebRequest -Uri "$baseUri/cloudapi/1.0.0/sessions" -Method POST -Headers @{
        Authorization = "Basic $basic"
        Accept = $accept
    } -SkipCertificateCheck
    $token = [string] $response.Headers['X-VMWARE-VCLOUD-ACCESS-TOKEN']
    if ([string]::IsNullOrWhiteSpace($token)) {
        $token = [string] $response.Headers['x-vcloud-authorization']
    }
    if ([string]::IsNullOrWhiteSpace($token)) { throw 'VCF Automation login succeeded but returned no usable session token.' }
    $session = $response.Content | ConvertFrom-Json
    [ordered]@{ Token = $token; Session = $session }
}

$sessionInfo = New-VcfSession
$headers = @{
    Authorization = "Bearer $($sessionInfo.Token)"
    Accept = $accept
}

function Invoke-VcfApi {
    param(
        [ValidateSet('GET', 'POST', 'PUT', 'DELETE')] [string] $Method,
        [string] $Path,
        [hashtable] $Body
    )
    $parameters = @{
        Uri = "$baseUri$Path"
        Method = $Method
        Headers = $headers
        SkipCertificateCheck = $true
        ErrorAction = 'Stop'
    }
    if ($null -ne $Body) {
        $parameters.ContentType = $accept
        $parameters.Body = $Body | ConvertTo-Json -Depth 20 -Compress
    }
    try {
        Invoke-RestMethod @parameters
    }
    catch {
        $detail = [string] $_.ErrorDetails.Message
        if (-not [string]::IsNullOrEmpty($payload.SharedPassword)) {
            $detail = $detail.Replace([string] $payload.SharedPassword, '[REDACTED]')
        }
        throw "VCF API $Method $Path failed: $detail"
    }
}

function Get-LdapSettings {
    @{
        hostName = '10.1.1.1'
        port = 389
        isSsl = $false
        isSslAcceptAll = $false
        pagedSearchDisabled = $false
        pageSize = 100
        maxResults = 200
        maxUserGroups = 100
        searchBase = $payload.LdapBaseDn
        userName = "cn=ldapservice,ou=users,$($payload.LdapBaseDn)"
        password = $payload.SharedPassword
        authenticationMechanism = 'SIMPLE'
        groupSearchBase = "ou=groups,$($payload.LdapBaseDn)"
        isGroupSearchBaseEnabled = $true
        connectorType = 'OPEN_LDAP'
        useExternalKerberos = $false
        customUiButtonLabel = 'Holodeck LDAP'
        userAttributes = @{
            objectClass = 'user'
            objectIdentifier = 'uid'
            userName = 'cn'
            email = 'mail'
            fullName = 'displayName'
            givenName = 'name'
            surname = 'name'
            telephone = 'telephoneNumber'
            groupMembershipIdentifier = 'dn'
            groupBackLinkIdentifier = 'memberOf'
        }
        groupAttributes = @{
            objectClass = 'group'
            objectIdentifier = 'uid'
            groupName = 'cn'
            membership = 'member'
            membershipIdentifier = 'dn'
            backLinkIdentifier = 'vcfBackLink'
        }
    }
}

$ldapSettings = Get-LdapSettings
$mappingAttempts = @()
$test = $null
foreach ($testName in @('vcfadmin')) {
foreach ($objectClass in @('groupOfNames', 'group')) {
    foreach ($objectIdentifier in @('uid', 'cn', 'gidNumber')) {
        foreach ($groupName in @('cn', 'sAMAccountName')) {
            $candidate = $ldapSettings.Clone()
            $candidate.groupAttributes = $ldapSettings.groupAttributes.Clone()
            $candidate.groupAttributes.objectClass = $objectClass
            $candidate.groupAttributes.objectIdentifier = $objectIdentifier
            $candidate.groupAttributes.groupName = $groupName
            $candidateTest = Invoke-VcfApi POST "/cloudapi/1.0.0/ldap/test?username=$([Uri]::EscapeDataString($testName))" $candidate
            $failed = @($candidateTest.settingsTest | Where-Object { -not $_.successful })
            $mappingAttempts += @{
                testName = $testName
                objectClass = $objectClass
                objectIdentifier = $objectIdentifier
                groupName = $groupName
                connection = [bool]$candidateTest.connectionTest.successful
                failed = @($failed | ForEach-Object { $_.attribute })
            }
            if ($candidateTest.connectionTest.successful -and $failed.Count -eq 0) {
                $ldapSettings = $candidate
                $test = $candidateTest
                break
            }
        }
        if ($null -ne $test) { break }
    }
    if ($null -ne $test) { break }
}
    if ($null -ne $test) { break }
}
if ($null -eq $test) {
    throw "VCF Automation rejected every safe Authentik LDAP mapping: $($mappingAttempts | ConvertTo-Json -Depth 8 -Compress)"
}

$definedUserAttributes = $ldapSettings.userAttributes.Clone()
$definedUserAttributes.displayName = $definedUserAttributes.fullName
$definedUserAttributes.Remove('fullName')
$orgSettings = @{
    enabled = $true
    settingsSource = 'DEFINED'
    definedSettings = @{
        hostName = $ldapSettings.hostName
        port = $ldapSettings.port
        ssl = $ldapSettings.isSsl
        pagedSearchDisabled = $ldapSettings.pagedSearchDisabled
        pageSize = $ldapSettings.pageSize
        maxResults = $ldapSettings.maxResults
        maxUserGroups = $ldapSettings.maxUserGroups
        searchBase = $ldapSettings.searchBase
        userName = $ldapSettings.userName
        password = $ldapSettings.password
        groupSearchBase = $ldapSettings.groupSearchBase
        customUiButtonLabel = $ldapSettings.customUiButtonLabel
        userAttributes = $definedUserAttributes
        groupAttributes = $ldapSettings.groupAttributes
    }
}
$null = Invoke-VcfApi PUT '/cloudapi/v1/orgSettings/ldap' $orgSettings

$roles = (Invoke-VcfApi GET '/cloudapi/1.0.0/roles?page=1&pageSize=128').values
$roleByName = @{}
foreach ($role in $roles) { $roleByName[$role.name] = $role }
foreach ($requiredRole in 'Organization Administrator', 'Organization User') {
    if (-not $roleByName.ContainsKey($requiredRole)) { throw "VCF Automation role '$requiredRole' was not found." }
}

function Ensure-VcfLdapGroup {
    param([string] $Name, [string] $RoleName)
    $existing = @((Invoke-VcfApi GET '/cloudapi/1.0.0/groups?page=1&pageSize=128').values |
        Where-Object { $_.providerType -eq 'LDAP' -and $_.name -eq $Name })
    $search = @(Invoke-VcfApi GET "/cloudapi/1.0.0/ldap/search/group?q=$([Uri]::EscapeDataString($Name))" |
        Where-Object { $_.name -eq $Name -or $_.nameInSource -match "(?i)^cn=$([regex]::Escape($Name))," })
    if ($search.Count -ne 1) { throw "Expected one LDAP search result for '$Name'; found $($search.Count)." }
    $groupBody = @{
        name = $Name
        nameInSource = $search[0].nameInSource
        providerType = 'LDAP'
        roleEntityRefs = @(@{ name = $roleByName[$RoleName].name; id = $roleByName[$RoleName].id })
        description = "Managed Holodeck LDAP group mapped to $RoleName"
    }
    if ($existing.Count -eq 0) {
        $createBody = $groupBody.Clone()
        $createBody.Remove('nameInSource')
        return Invoke-VcfApi POST '/cloudapi/1.0.0/groups' $createBody
    }
    if ($existing.Count -gt 1) { throw "Multiple VCF LDAP groups named '$Name' exist." }
    $updateBody = $groupBody.Clone()
    $updateBody.id = $existing[0].id
    $updateBody.orgEntityRef = $existing[0].orgEntityRef
    $updateBody.sourceEntityRef = $existing[0].sourceEntityRef
    Invoke-VcfApi PUT "/cloudapi/1.0.0/groups/$([Uri]::EscapeDataString($existing[0].id))" $updateBody
}

$adminGroup = Ensure-VcfLdapGroup $payload.AdminGroup 'Organization Administrator'
$userGroup = Ensure-VcfLdapGroup $payload.UserGroup 'Organization User'

$null = Invoke-VcfApi DELETE '/cloudapi/1.0.0/sessions/current'

function Test-VcfLdapLogin {
    param([string] $Username)
    $identity = "$Username@$($payload.AutomationOrg):$($payload.SharedPassword)"
    $basic = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($identity))
    $response = Invoke-WebRequest -Uri "$baseUri/cloudapi/1.0.0/sessions" -Method POST -Headers @{
        Authorization = "Basic $basic"
        Accept = $accept
    } -SkipCertificateCheck
    $token = [string] $response.Headers['X-VMWARE-VCLOUD-ACCESS-TOKEN']
    if ([string]::IsNullOrWhiteSpace($token)) {
        $token = [string] $response.Headers['x-vcloud-authorization']
    }
    if ([string]::IsNullOrWhiteSpace($token)) { throw "LDAP login for '$Username' returned no session token." }
    $verifiedSession = $response.Content | ConvertFrom-Json
    $null = Invoke-RestMethod -Uri "$baseUri/cloudapi/1.0.0/sessions/current" -Method DELETE -Headers @{
        Authorization = "Bearer $token"
        Accept = $accept
    } -SkipCertificateCheck
    [string] $verifiedSession.user.name
}

$authenticatedUsers = @(@('vcfadmin', 'vcfuser01', 'vcfuser02') | ForEach-Object { Test-VcfLdapLogin $_ })
[ordered]@{
    Organization = $sessionInfo.Session.org.name
    LdapEnabled = $true
    LdapHost = '10.1.1.1'
    LdapPort = 389
    AdminGroup = $adminGroup.name
    AdminRole = 'Organization Administrator'
    UserGroup = $userGroup.name
    UserRole = 'Organization User'
    AuthenticatedUsers = $authenticatedUsers
} | ConvertTo-Json -Depth 5
