[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$payload = ([Console]::In.ReadToEnd() | ConvertFrom-Json -AsHashtable)
$baseUri = 'https://auto-a.site-a.vcf.lab'
function New-VcfSessionToken {
    param(
        [Parameter(Mandatory)][string]$User,
        [Parameter(Mandatory)][string]$Organization,
        [Parameter(Mandatory)][string]$Password
    )
    $identity = "${User}@${Organization}:${Password}"
    $basic = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($identity))
    $response = Invoke-WebRequest -Uri "$baseUri/cloudapi/1.0.0/sessions" -Method POST -Headers @{
        Authorization = "Basic $basic"
        Accept = 'application/json;version=9.1.0'
    } -SkipCertificateCheck
    $sessionToken = [string] $response.Headers['X-VMWARE-VCLOUD-ACCESS-TOKEN']
    if ([string]::IsNullOrWhiteSpace($sessionToken)) {
        $sessionToken = [string] $response.Headers['x-vcloud-authorization']
    }
    if ([string]::IsNullOrWhiteSpace($sessionToken)) {
        throw "VCF login returned no session token for ${User}@${Organization}."
    }
    $sessionToken
}

$token = New-VcfSessionToken -User $payload.AutomationUser -Organization $payload.AutomationOrg `
    -Password $payload.SharedPassword
$siteConfigs = @(Get-ChildItem -LiteralPath '/holodeck-runtime/config' -Filter '*-site-a.json' -File |
    Sort-Object LastWriteTimeUtc -Descending)
if ($siteConfigs.Count -eq 0) { throw 'No Holodeck site-a configuration file was found.' }
$systemToken = $null
foreach ($siteConfig in $siteConfigs) {
    $providerPasswords = @(& jq -r `
        '.. | objects | select(has("vcfAutomationSpec")) | select(.vcfAutomationSpec.hostname == "auto-a.site-a.vcf.lab") | .vcfAutomationSpec.adminUserPassword // empty' `
        $siteConfig.FullName 2>$null | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
    foreach ($providerPassword in $providerPasswords) {
        foreach ($providerOrg in @('system', 'System')) {
            try {
                $systemToken = New-VcfSessionToken -User 'admin' -Organization $providerOrg -Password $providerPassword
                break
            }
            catch {
                # Try the other canonical organization spelling/config credential.
            }
        }
        $providerPassword = $null
        if (-not [string]::IsNullOrWhiteSpace($systemToken)) { break }
    }
    $providerPasswords = $null
    if (-not [string]::IsNullOrWhiteSpace($systemToken)) { break }
}
if ([string]::IsNullOrWhiteSpace($systemToken)) {
    $systemToken = $null
}
$headers = @{ Authorization = "Bearer $token" }
$orgId = $payload.OrganizationId
$wellKnown = 'https://auth.vcf.lab/application/o/holodeck-vcf-automation-oidc/.well-known/openid-configuration'

# VCF fetches the well-known document server-side, so its trust store must
# contain the Holodeck root CA.  The Authentik bundle contains leaf then root.
$certificateBundle = Get-Content -LiteralPath '/holodeck-runtime/authentik/ssl/auth.crt' -Raw
$certificateBlocks = @([regex]::Matches(
    $certificateBundle,
    '-----BEGIN CERTIFICATE-----[\s\S]*?-----END CERTIFICATE-----'
) | ForEach-Object { $_.Value })
if ($certificateBlocks.Count -lt 2) {
    throw 'The Authentik certificate bundle does not contain the expected leaf and root certificates.'
}
$rootCaPem = $certificateBlocks[-1]
$rootCa = [Security.Cryptography.X509Certificates.X509Certificate2]::new(
    [Convert]::FromBase64String(($rootCaPem -replace '-----[^-]+-----', '' -replace '\s', ''))
)
if ($rootCa.Subject -ne $rootCa.Issuer) {
    throw "The final Authentik certificate is not a self-signed root CA: $($rootCa.Subject)"
}
$trustedCertificatesUri = "$baseUri/cloudapi/1.0.0/ssl/trustedCertificates"
$cloudApiHeaders = $headers + @{ Accept = 'application/json;version=40.1' }
try {
    $trusted = Invoke-RestMethod -Uri "${trustedCertificatesUri}?page=1&pageSize=128" `
        -Method GET -Headers $cloudApiHeaders -SkipCertificateCheck
}
catch {
    throw "VCF trusted-certificate query failed for admin@system: $($_.Exception.Message)"
}
$trustedValues = if ($null -ne $trusted.values) { @($trusted.values) } else { @($trusted) }
$rootFingerprint = $rootCa.Thumbprint
$alreadyTrusted = $false
foreach ($entry in $trustedValues) {
    if ([string]::IsNullOrWhiteSpace([string]$entry.certificate)) { continue }
    try {
        $existingPem = [string]$entry.certificate
        $existingCertificate = [Security.Cryptography.X509Certificates.X509Certificate2]::new(
            [Convert]::FromBase64String(($existingPem -replace '-----[^-]+-----', '' -replace '\s', ''))
        )
        if ($existingCertificate.Thumbprint -eq $rootFingerprint) {
            $alreadyTrusted = $true
            break
        }
    }
    catch {
        # Ignore malformed/unrelated entries and continue comparing the store.
    }
}
if (-not $alreadyTrusted) {
    if ([string]::IsNullOrWhiteSpace($systemToken)) {
        throw 'The Holodeck root CA is absent and VCF provider login failed with every stored site-a provider credential.'
    }
    $providerCloudApiHeaders = @{
        Authorization = "Bearer $systemToken"
        Accept = 'application/json;version=40.1'
    }
    try {
        Invoke-RestMethod -Uri $trustedCertificatesUri -Method POST -Headers $providerCloudApiHeaders `
            -ContentType 'application/json;version=40.1' -Body (@{
                alias = 'Holodeck vcf.lab Root Authority'
                certificate = $rootCaPem
            } | ConvertTo-Json -Compress) -SkipCertificateCheck | Out-Null
    }
    catch {
        throw "VCF root-CA trust creation failed for admin@system: $($_.Exception.Message)"
    }
}

$discoveryType = 'application/vnd.vmware.vcloud.admin.openIdProviderInfo+json;version=40.1'
try {
    $discoveryResponse = Invoke-RestMethod -Uri "$baseUri/api/admin/org/$orgId/settings/oauth/openIdProviderConfig" `
        -Method POST -Headers ($headers + @{ Accept = 'application/vnd.vmware.vcloud.admin.openIdProviderConfiguration+json;version=40.1' }) `
        -ContentType $discoveryType -Body (@{ wellKnownEndpoint = $wellKnown } | ConvertTo-Json -Compress) -SkipCertificateCheck
    $settings = $discoveryResponse.orgOAuthSettings
}
catch {
    # Some VCF Automation builds return HTTP 500 from the convenience importer.
    # Build the same documented OrgOAuthSettings fields from the OIDC document.
    $providerConfiguration = Invoke-RestMethod -Uri $wellKnown -SkipCertificateCheck
    $oauthType = 'application/vnd.vmware.admin.organizationOAuthSettings+json;version=40.1'
    $settings = Invoke-RestMethod -Uri "$baseUri/api/admin/org/$orgId/settings/oauth" `
        -Headers ($headers + @{ Accept = $oauthType }) -SkipCertificateCheck
    $settings | Add-Member -NotePropertyName issuerId -NotePropertyValue $providerConfiguration.issuer -Force
    $settings | Add-Member -NotePropertyName userAuthorizationEndpoint -NotePropertyValue $providerConfiguration.authorization_endpoint -Force
    $settings | Add-Member -NotePropertyName accessTokenEndpoint -NotePropertyValue $providerConfiguration.token_endpoint -Force
    $settings | Add-Member -NotePropertyName userInfoEndpoint -NotePropertyValue $providerConfiguration.userinfo_endpoint -Force
    $settings | Add-Member -NotePropertyName jwksUri -NotePropertyValue $providerConfiguration.jwks_uri -Force
    $settings | Add-Member -NotePropertyName wellKnownEndpoint -NotePropertyValue $wellKnown -Force

    function ConvertFrom-Base64Url {
        param([Parameter(Mandatory)][string]$Value)
        $base64 = $Value.Replace('-', '+').Replace('_', '/')
        switch ($base64.Length % 4) {
            2 { $base64 += '==' }
            3 { $base64 += '=' }
        }
        [Convert]::FromBase64String($base64)
    }
    $jwks = Invoke-RestMethod -Uri $providerConfiguration.jwks_uri -SkipCertificateCheck
    $staticKeys = @()
    foreach ($jwk in @($jwks.keys | Where-Object { $_.kty -eq 'RSA' })) {
        $rsa = [Security.Cryptography.RSA]::Create()
        try {
            $rsa.ImportParameters([Security.Cryptography.RSAParameters]@{
                Modulus = ConvertFrom-Base64Url $jwk.n
                Exponent = ConvertFrom-Base64Url $jwk.e
            })
            $staticKeys += @{
                keyId = [string]$jwk.kid
                algorithm = 'RSA'
                key = $rsa.ExportSubjectPublicKeyInfoPem()
                expirationDate = [DateTime]::UtcNow.AddYears(5).ToString('o')
            }
        }
        finally { $rsa.Dispose() }
    }
    if ($staticKeys.Count -eq 0) { throw 'Authentik returned no RSA signing keys.' }
    $settings | Add-Member -NotePropertyName oauthKeyConfigurations -NotePropertyValue @{
        oauthKeyConfiguration = $staticKeys
    } -Force
}
if ($null -eq $settings) { throw 'VCF did not return interpreted OIDC settings from the Authentik well-known endpoint.' }
$settings.enabled = $true
$settings.clientId = 'holodeck-vcf-automation'
$settings.clientSecret = $payload.SharedPassword
$settings.scope = 'openid profile email vcf'
$settings.enableIdTokenClaims = $true
$settings.autoRefreshKey = $false
$settings.keyRefreshStrategy = 'REPLACE'
$settings.maxClockSkew = 60
$settings.usePKCE = $false
$settings.sendClientCredentialsAsAuthorizationHeader = $true
$settings.customUiButtonLabel = 'Holodeck Authentik'
$settings.oidcAttributeMapping = @{
    subjectAttributeName = 'preferred_username'
    emailAttributeName = 'email'
    fullNameAttributeName = 'name'
    firstNameAttributeName = 'given_name'
    lastNameAttributeName = 'family_name'
    groupsAttributeName = 'groups'
    rolesAttributeName = 'roles'
}
$oauthType = 'application/vnd.vmware.admin.organizationOAuthSettings+json;version=40.1'
$updated = Invoke-RestMethod -Uri "$baseUri/api/admin/org/$orgId/settings/oauth" -Method PUT `
    -Headers ($headers + @{ Accept = $oauthType }) -ContentType $oauthType `
    -Body ($settings | ConvertTo-Json -Depth 20 -Compress) -SkipCertificateCheck
[ordered]@{
    Organization = $payload.AutomationOrg
    OidcEnabled = [bool] $updated.enabled
    Issuer = $updated.issuerId
    RedirectUri = $updated.orgRedirectUri
    Scope = $updated.scope
    LoginLabel = $updated.customUiButtonLabel
    RootCaFingerprint = $rootFingerprint
    RootCaWasAlreadyTrusted = $alreadyTrusted
} | ConvertTo-Json -Depth 5
