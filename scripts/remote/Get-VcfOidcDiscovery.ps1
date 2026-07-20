[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$payload = ([Console]::In.ReadToEnd() | ConvertFrom-Json -AsHashtable)
$baseUri = 'https://auto-a.site-a.vcf.lab'
$loginAccept = 'application/json;version=9.1.0'
$identity = "$($payload.AutomationUser)@$($payload.AutomationOrg):$($payload.SharedPassword)"
$basic = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($identity))
$response = Invoke-WebRequest -Uri "$baseUri/cloudapi/1.0.0/sessions" -Method POST -Headers @{
    Authorization = "Basic $basic"
    Accept = $loginAccept
} -SkipCertificateCheck
$token = [string] $response.Headers['X-VMWARE-VCLOUD-ACCESS-TOKEN']
if ([string]::IsNullOrWhiteSpace($token)) { $token = [string] $response.Headers['x-vcloud-authorization'] }
if ([string]::IsNullOrWhiteSpace($token)) { throw 'VCF login returned no session token.' }
$session = $response.Content | ConvertFrom-Json
$orgId = ([string] $session.org.id) -replace '^urn:vcloud:org:', ''
if ([string]::IsNullOrWhiteSpace($orgId)) { throw 'VCF session returned no organization ID.' }
$oauthAccept = 'application/vnd.vmware.admin.organizationOAuthSettings+json;version=40.1'
$oauth = Invoke-RestMethod -Uri "$baseUri/api/admin/org/$orgId/settings/oauth" -Headers @{
    Authorization = "Bearer $token"
    Accept = $oauthAccept
} -SkipCertificateCheck
[ordered]@{
    Organization = $session.org.name
    OrganizationId = $orgId
    RedirectUri = $oauth.orgRedirectUri
    OAuthEnabled = [bool] $oauth.enabled
    ExistingIssuer = $oauth.issuerId
    ExistingWellKnownEndpoint = $oauth.wellKnownEndpoint
} | ConvertTo-Json -Depth 4
