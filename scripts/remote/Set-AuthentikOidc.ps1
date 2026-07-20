[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$payload = ([Console]::In.ReadToEnd() | ConvertFrom-Json -AsHashtable)

function Invoke-AkApi {
    param([ValidateSet('GET','POST','PATCH')] [string] $Method, [string] $Path, [hashtable] $Body)
    $args = @{
        Uri = "https://auth.vcf.lab/api/v3$Path"
        Method = $Method
        Headers = @{ Authorization = "Bearer $($payload.AuthentikToken)"; Accept = 'application/json' }
        SkipCertificateCheck = $true
        ErrorAction = 'Stop'
    }
    if ($null -ne $Body) {
        $args.ContentType = 'application/json'
        $args.Body = $Body | ConvertTo-Json -Depth 20 -Compress
    }
    Invoke-RestMethod @args
}

function Get-ExactResult([string] $Path, [scriptblock] $Predicate, [string] $Description) {
    $matches = @((Invoke-AkApi GET $Path $null).results | Where-Object $Predicate)
    if ($matches.Count -gt 1) { throw "Multiple Authentik objects matched $Description." }
    if ($matches.Count -eq 1) { return $matches[0] }
    $null
}

function Get-Flow([string] $Slug) {
    $flow = Get-ExactResult '/flows/instances/?page_size=100' { $_.slug -eq $Slug } "flow '$Slug'"
    if ($null -eq $flow) { throw "Authentik flow '$Slug' was not found." }
    $flow
}

foreach ($username in 'vcfadmin','vcfuser01','vcfuser02') {
    $user = Get-ExactResult '/core/users/?page_size=100' { $_.username -eq $username } "user '$username'"
    if ($null -eq $user) { throw "Required Authentik user '$username' was not found." }
    $null = Invoke-AkApi PATCH "/core/users/$($user.pk)/" @{
        email = "$username@vcf.lab"
        is_active = $true
    }
}

$mappingName = 'Holodeck VCF Automation roles'
$mapping = Get-ExactResult '/propertymappings/provider/scope/?page_size=100' { $_.name -eq $mappingName } "scope mapping '$mappingName'"
$mappingBody = @{
    name = $mappingName
    scope_name = 'vcf'
    description = 'Map Authentik groups to VCF Automation organization roles'
    expression = @'
groups = [group.name for group in request.user.ak_groups.all()]
roles = []
if "vcf-admins" in groups:
    roles.append("Organization Administrator")
if "vcf-users" in groups:
    roles.append("Organization User")
return {"groups": groups, "roles": roles}
'@
}
if ($null -eq $mapping) { $mapping = Invoke-AkApi POST '/propertymappings/provider/scope/' $mappingBody }
else { $mapping = Invoke-AkApi PATCH "/propertymappings/provider/scope/$($mapping.pk)/" $mappingBody }

$scopeMappings = @((Invoke-AkApi GET '/propertymappings/provider/scope/?page_size=100').results |
    Where-Object { $_.scope_name -in @('openid','profile','email') })
if ($scopeMappings.Count -lt 3) { throw 'Authentik default openid, profile, and email scope mappings were not all found.' }
$propertyMappings = @($scopeMappings.pk) + @($mapping.pk)

$certificate = Get-ExactResult '/crypto/certificatekeypairs/?page_size=100' { $_.name -eq 'Holodeck auth.vcf.lab LDAPS' } 'Holodeck signing certificate'
if ($null -eq $certificate) { throw 'The existing Holodeck Authentik certificate was not found.' }

$name = 'Holodeck VCF Automation OIDC'
$provider = Get-ExactResult '/providers/oauth2/?page_size=100' { $_.name -eq $name } "OIDC provider '$name'"
$providerBody = @{
    name = $name
    authentication_flow = (Get-Flow 'default-authentication-flow').pk
    authorization_flow = (Get-Flow 'default-provider-authorization-implicit-consent').pk
    invalidation_flow = (Get-Flow 'default-provider-invalidation-flow').pk
    property_mappings = $propertyMappings
    client_type = 'confidential'
    client_id = 'holodeck-vcf-automation'
    client_secret = $payload.SharedPassword
    include_claims_in_id_token = $true
    signing_key = $certificate.pk
    redirect_uris = @(@{ matching_mode = 'strict'; url = $payload.RedirectUri })
    sub_mode = 'user_username'
    issuer_mode = 'per_provider'
}
if ($null -eq $provider) { $provider = Invoke-AkApi POST '/providers/oauth2/' $providerBody }
else { $provider = Invoke-AkApi PATCH "/providers/oauth2/$($provider.pk)/" $providerBody }

$slug = 'holodeck-vcf-automation-oidc'
$application = $null
try { $application = Invoke-AkApi GET "/core/applications/$slug/" $null } catch {
    if ($_.Exception.Response.StatusCode -ne 404) { throw }
}
$applicationBody = @{
    name = $name
    slug = $slug
    provider = $provider.pk
    policy_engine_mode = 'all'
    meta_launch_url = 'https://auto-a.site-a.vcf.lab/'
    meta_description = 'OIDC login for the Holodeck VCF Automation All Apps organization'
}
if ($null -eq $application) { $application = Invoke-AkApi POST '/core/applications/' $applicationBody }
else { $application = Invoke-AkApi PATCH "/core/applications/$slug/" $applicationBody }

[ordered]@{
    ApplicationSlug = $application.slug
    ClientId = $provider.client_id
    RedirectUri = $payload.RedirectUri
    Issuer = "https://auth.vcf.lab/application/o/$slug/"
    Users = @('vcfadmin','vcfuser01','vcfuser02')
} | ConvertTo-Json -Depth 5
