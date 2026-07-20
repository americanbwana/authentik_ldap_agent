[CmdletBinding(SupportsShouldProcess)]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$payloadText = [Console]::In.ReadToEnd()
if ([string]::IsNullOrWhiteSpace($payloadText)) {
    throw 'A JSON payload is required on stdin.'
}
$payload = $payloadText | ConvertFrom-Json -AsHashtable

function Invoke-AuthentikApi {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [ValidateSet('GET', 'POST', 'PATCH', 'DELETE')] [string] $Method,
        [Parameter(Mandatory)] [string] $Path,
        [Parameter()] [hashtable] $Body
    )

    $parameters = @{
        Uri                = "https://auth.vcf.lab/api/v3$Path"
        Method             = $Method
        Headers            = @{
            Authorization = "Bearer $($payload.AuthentikToken)"
            Accept        = 'application/json'
        }
        SkipCertificateCheck = $true
        ErrorAction        = 'Stop'
    }
    if ($null -ne $Body) {
        $parameters.ContentType = 'application/json'
        $parameters.Body = $Body | ConvertTo-Json -Depth 20 -Compress
    }
    Invoke-RestMethod @parameters
}

function Get-SingleResult {
    param([string] $Path, [string] $Description)
    $response = Invoke-AuthentikApi -Method GET -Path $Path
    $results = @($response.results)
    if ($results.Count -gt 1) { throw "Multiple Authentik objects matched $Description." }
    if ($results.Count -eq 1) { return $results[0] }
    return $null
}

function Ensure-Group {
    param([string] $Name)
    $encoded = [Uri]::EscapeDataString($Name)
    $group = Get-SingleResult "/core/groups/?name=$encoded" "group '$Name'"
    $body = @{
        name = $Name
        is_superuser = $false
        # VCF follows a user's memberOf DN through a configurable group
        # backlink attribute. Authentik does not support filtering on its
        # virtual dn attribute, so expose the same DN as a real attribute.
        attributes = @{ vcfBackLink = "cn=$Name,ou=groups,$($payload.LdapBaseDn)" }
    }
    if ($null -eq $group) {
        $group = Invoke-AuthentikApi POST '/core/groups/' $body
    }
    else {
        $group = Invoke-AuthentikApi PATCH "/core/groups/$($group.pk)/" $body
    }
    $group
}

function Ensure-User {
    param([string] $Username, [string] $DisplayName, [string] $Type, [string[]] $Groups)
    $encoded = [Uri]::EscapeDataString($Username)
    $user = Get-SingleResult "/core/users/?username=$encoded" "user '$Username'"
    $body = @{
        username  = $Username
        name      = $DisplayName
        is_active = $true
        type      = $Type
        groups    = @($Groups)
        path      = 'users'
        attributes = @{ telephoneNumber = '555-0100' }
    }
    if ($null -eq $user) {
        $user = Invoke-AuthentikApi POST '/core/users/' $body
    }
    else {
        $user = Invoke-AuthentikApi PATCH "/core/users/$($user.pk)/" $body
    }
    $null = Invoke-AuthentikApi POST "/core/users/$($user.pk)/set_password/" @{ password = $payload.SharedPassword }
    $user
}

function Ensure-Role {
    param([string] $Name, [int] $UserPk)
    $encoded = [Uri]::EscapeDataString($Name)
    $role = Get-SingleResult "/rbac/roles/?name=$encoded" "role '$Name'"
    if ($null -eq $role) {
        $role = Invoke-AuthentikApi POST '/rbac/roles/' @{ name = $Name }
    }
    $null = Invoke-AuthentikApi POST "/rbac/roles/$($role.pk)/add_user/" @{ pk = $UserPk }
    $role
}

function Ensure-Certificate {
    $name = 'Holodeck auth.vcf.lab LDAPS'
    $encoded = [Uri]::EscapeDataString($name)
    $certificate = Get-SingleResult "/crypto/certificatekeypairs/?name=$encoded" "certificate '$name'"
    $body = @{
        name             = $name
        certificate_data = Get-Content -LiteralPath '/holodeck-runtime/authentik/ssl/auth.crt' -Raw
        key_data         = Get-Content -LiteralPath '/holodeck-runtime/authentik/ssl/auth.key' -Raw
    }
    if ($null -eq $certificate) {
        return Invoke-AuthentikApi POST '/crypto/certificatekeypairs/' $body
    }
    Invoke-AuthentikApi PATCH "/crypto/certificatekeypairs/$($certificate.pk)/" $body
}

function Remove-ObsoleteBindToken {
    $identifier = 'holodeck-ldap-bind'
    try {
        $null = Invoke-AuthentikApi DELETE "/core/tokens/$identifier/"
    }
    catch {
        if ($_.Exception.Response.StatusCode -ne 404) { throw }
    }
}

function Get-Flow([string] $Slug) {
    $encoded = [Uri]::EscapeDataString($Slug)
    $flow = Get-SingleResult "/flows/instances/?slug=$encoded" "flow '$Slug'"
    if ($null -eq $flow) { throw "Required Authentik flow '$Slug' was not found." }
    $flow
}

function Remove-PolicyBindings {
    param($Policy)
    $bindings = @((Invoke-AuthentikApi GET "/policies/bindings/?policy=$($Policy.pk)&page_size=100").results)
    foreach ($binding in $bindings) {
        $null = Invoke-AuthentikApi DELETE "/policies/bindings/$($binding.pk)/"
    }
}

function Get-ExactNamedResult {
    param([string] $Path, [string] $Name, [string] $Description)
    $matches = @((Invoke-AuthentikApi GET $Path).results | Where-Object { $_.name -eq $Name })
    if ($matches.Count -gt 1) { throw "Multiple Authentik objects matched $Description." }
    if ($matches.Count -eq 1) { return $matches[0] }
    return $null
}

function Ensure-AuthenticationFlow {
    $flowSlug = 'holodeck-ldap-authentication'
    $flow = Get-SingleResult "/flows/instances/?slug=$flowSlug" "flow '$flowSlug'"
    $flowBody = @{
        name        = 'Holodeck LDAP Authentication'
        slug        = $flowSlug
        title       = 'Holodeck LDAP Authentication'
        designation = 'authentication'
        policy_engine_mode = 'all'
    }
    if ($null -eq $flow) {
        $flow = Invoke-AuthentikApi POST '/flows/instances/' $flowBody
    }
    else {
        $flow = Invoke-AuthentikApi PATCH "/flows/instances/$flowSlug/" $flowBody
    }

    $passwordName = 'holodeck-ldap-password'
    $passwordStage = Get-ExactNamedResult '/stages/password/?page_size=100' $passwordName "password stage '$passwordName'"
    $passwordBody = @{
        name     = $passwordName
        backends = @('authentik.core.auth.InbuiltBackend')
    }
    if ($null -eq $passwordStage) {
        $passwordStage = Invoke-AuthentikApi POST '/stages/password/' $passwordBody
    }
    else {
        $passwordStage = Invoke-AuthentikApi PATCH "/stages/password/$($passwordStage.pk)/" $passwordBody
    }

    $identificationName = 'holodeck-ldap-identification'
    $identificationStage = Get-ExactNamedResult '/stages/identification/?page_size=100' $identificationName "identification stage '$identificationName'"
    $identificationBody = @{
        name           = $identificationName
        user_fields    = @('username', 'email')
        password_stage = $passwordStage.pk
    }
    if ($null -eq $identificationStage) {
        $identificationStage = Invoke-AuthentikApi POST '/stages/identification/' $identificationBody
    }
    else {
        $identificationStage = Invoke-AuthentikApi PATCH "/stages/identification/$($identificationStage.pk)/" $identificationBody
    }

    $loginName = 'holodeck-ldap-login'
    $loginStage = Get-ExactNamedResult '/stages/user_login/?page_size=100' $loginName "user login stage '$loginName'"
    $loginBody = @{ name = $loginName }
    if ($null -eq $loginStage) {
        $loginStage = Invoke-AuthentikApi POST '/stages/user_login/' $loginBody
    }
    else {
        $loginStage = Invoke-AuthentikApi PATCH "/stages/user_login/$($loginStage.pk)/" $loginBody
    }

    $desiredBindings = @(
        @{ Stage = $identificationStage.pk; Order = 10 },
        @{ Stage = $loginStage.pk; Order = 30 }
    )
    $existingBindings = @((Invoke-AuthentikApi GET "/flows/bindings/?target=$($flow.pk)&page_size=100").results |
        Where-Object { $_.target -eq $flow.pk })
    foreach ($desired in $desiredBindings) {
        $matches = @($existingBindings | Where-Object { $_.stage -eq $desired.Stage })
        if ($matches.Count -gt 1) { throw "Multiple bindings exist for stage $($desired.Stage) in flow '$flowSlug'." }
        $bindingBody = @{
            target = $flow.pk
            stage = $desired.Stage
            order = $desired.Order
            policy_engine_mode = 'all'
            evaluate_on_plan = $true
            re_evaluate_policies = $false
            invalid_response_action = 'retry'
        }
        if ($matches.Count -eq 0) {
            $null = Invoke-AuthentikApi POST '/flows/bindings/' $bindingBody
        }
        else {
            $null = Invoke-AuthentikApi PATCH "/flows/bindings/$($matches[0].pk)/" $bindingBody
        }
    }

    $policyName = 'holodeck-ldap-allow-authentication'
    $policy = Get-ExactNamedResult '/policies/expression/?page_size=100' $policyName "expression policy '$policyName'"
    $policyBody = @{
        name       = $policyName
        expression = 'return True'
    }
    if ($null -eq $policy) {
        $policy = Invoke-AuthentikApi POST '/policies/expression/' $policyBody
    }
    else {
        $policy = Invoke-AuthentikApi PATCH "/policies/expression/$($policy.pk)/" $policyBody
    }
    # Flow-level policies run before LDAP has identified the current user and
    # can make the flow inapplicable. Access is authorized on the application.
    Remove-PolicyBindings $policy
    [ordered]@{ Flow = $flow; AllowPolicy = $policy }
}

function Ensure-LdapProvider {
    param($Certificate, $BindFlow)
    $name = 'Holodeck VCF Automation LDAP'
    $encoded = [Uri]::EscapeDataString($name)
    $provider = Get-SingleResult "/providers/ldap/?name=$encoded" "LDAP provider '$name'"
    $body = @{
        name                = $name
        authentication_flow = $null
        authorization_flow  = $BindFlow.pk
        invalidation_flow   = (Get-Flow 'default-provider-invalidation-flow').pk
        base_dn             = $payload.LdapBaseDn
        certificate         = $Certificate.pk
        tls_server_name     = 'auth.vcf.lab'
        search_mode         = 'cached'
        bind_mode           = 'direct'
        mfa_support         = $false
    }
    if ($null -eq $provider) {
        return Invoke-AuthentikApi POST '/providers/ldap/' $body
    }
    Invoke-AuthentikApi PATCH "/providers/ldap/$($provider.pk)/" $body
}

function Ensure-Application {
    param([int] $ProviderPk)
    $slug = 'holodeck-vcf-automation-ldap'
    $application = $null
    try { $application = Invoke-AuthentikApi GET "/core/applications/$slug/" } catch {
        if ($_.Exception.Response.StatusCode -ne 404) { throw }
    }
    $body = @{
        name = 'Holodeck VCF Automation LDAP'
        slug = $slug
        provider = $ProviderPk
        policy_engine_mode = 'all'
        meta_description = 'LDAP directory for the Holodeck VCF Automation All Apps organization'
    }
    if ($null -eq $application) {
        return Invoke-AuthentikApi POST '/core/applications/' $body
    }
    Invoke-AuthentikApi PATCH "/core/applications/$slug/" $body
}

function Ensure-Outpost {
    param([int] $ProviderPk)
    $name = 'Holodeck LDAP Outpost'
    $outpostMatches = @((Invoke-AuthentikApi GET '/outposts/instances/?page_size=100').results |
        Where-Object { $_.name -eq $name -and $_.type -eq 'ldap' })
    if ($outpostMatches.Count -gt 1) { throw "Multiple LDAP outposts named '$name' exist." }
    $outpost = if ($outpostMatches.Count -eq 1) { $outpostMatches[0] } else { $null }
    $connections = Invoke-AuthentikApi GET '/outposts/service_connections/kubernetes/?name=Local%20Kubernetes%20Cluster'
    $connection = @($connections.results | Where-Object local)[0]
    if ($null -eq $connection) { throw 'Local Kubernetes service connection was not found.' }
    $body = @{
        name = $name
        type = 'ldap'
        providers = @($ProviderPk)
        service_connection = $connection.pk
        config = @{
            authentik_host = 'http://authentik-server.default.svc.cluster.local/'
            authentik_host_browser = 'https://auth.vcf.lab/'
            authentik_host_insecure = $true
            log_level = 'info'
            refresh_interval = 'seconds=10'
            kubernetes_namespace = 'default'
            kubernetes_service_type = 'ClusterIP'
            kubernetes_json_patches = @{
                service = @(
                    @{ op = 'add'; path = '/spec/externalIPs'; value = @('172.20.41.120', '10.1.1.1') }
                )
            }
        }
    }
    if ($null -eq $outpost) {
        return Invoke-AuthentikApi POST '/outposts/instances/' $body
    }
    Invoke-AuthentikApi PATCH "/outposts/instances/$($outpost.pk)/" $body
}

$adminGroup = Ensure-Group $payload.AdminGroup
$userGroup = Ensure-Group $payload.UserGroup
$vcfAdmin = Ensure-User 'vcfadmin' 'VCF Administrator' 'internal' @($adminGroup.pk)
$vcfUser01 = Ensure-User 'vcfuser01' 'VCF User 01' 'internal' @($userGroup.pk)
$vcfUser02 = Ensure-User 'vcfuser02' 'VCF User 02' 'internal' @($userGroup.pk)
$ldapService = Ensure-User 'ldapservice' 'VCF LDAP Bind Service' 'internal' @()
$null = Remove-ObsoleteBindToken

$certificate = Ensure-Certificate
$authentication = Ensure-AuthenticationFlow
$provider = Ensure-LdapProvider $certificate $authentication.Flow
$application = Ensure-Application $provider.pk
# With no application bindings, Authentik permits all active users to bind.
# Full-directory searches remain restricted by the provider-scoped RBAC grant.
Remove-PolicyBindings $authentication.AllowPolicy
$role = Ensure-Role 'LDAP directory search' $ldapService.pk
$null = Invoke-AuthentikApi POST "/rbac/permissions/assigned_by_roles/$($role.pk)/assign/" @{
    permissions = @('authentik_providers_ldap.search_full_directory')
    model       = 'authentik_providers_ldap.ldapprovider'
    object_pk   = [string] $provider.pk
}
$outpost = Ensure-Outpost $provider.pk

# Outposts receive provider and flow changes asynchronously. Give the managed
# outpost one refresh interval before VCF Automation performs its LDAP test.
Start-Sleep -Seconds 35

[ordered]@{
    Changed             = $true
    ProviderPk          = $provider.pk
    ApplicationSlug     = $application.slug
    OutpostPk           = $outpost.pk
    LdapBindDn          = "cn=ldapservice,ou=users,$($payload.LdapBaseDn)"
    AdminGroupDn        = "cn=$($payload.AdminGroup),ou=groups,$($payload.LdapBaseDn)"
    UserGroupDn         = "cn=$($payload.UserGroup),ou=groups,$($payload.LdapBaseDn)"
    Users               = @($vcfAdmin.username, $vcfUser01.username, $vcfUser02.username)
} | ConvertTo-Json -Depth 5
