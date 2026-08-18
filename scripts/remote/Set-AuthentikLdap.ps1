[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter()] [switch] $Apply,
    [Parameter()] [securestring] $SharedPassword,
    [Parameter()] [securestring] $AuthentikToken,
    [Parameter()] [string] $AuthentikUri = 'https://auth.vcf.lab',
    [Parameter()] [string] $LdapBaseDn = 'dc=vcf,dc=lab',
    [Parameter()] [string] $AdminGroup = 'vcf-admins',
    [Parameter()] [string] $UserGroup = 'vcf-users',
    [Parameter()] [string] $CertificatePath,
    [Parameter()] [string] $PrivateKeyPath,
    [Parameter()] [string[]] $ExternalIp = @('172.20.41.120', '10.1.1.1'),
    [Parameter()] [string] $LdapHost = '10.1.1.1',
    [Parameter()] [int] $LdapPort = 389,
    [Parameter()] [switch] $AllowUntrustedTls,
    [Parameter()] [switch] $TraceGroupApiResponses,
    [Parameter()] [switch] $EnableLdaps
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function ConvertFrom-SecureStringValue {
    param([Parameter(Mandatory)] [securestring] $Value)
    $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Value)
    try { [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer) }
}

$directMode = ($PSBoundParameters.Count -gt 0) -or (-not [Console]::IsInputRedirected)
if ($directMode) {
    $probeParameters = @{
        Uri = "$($AuthentikUri.TrimEnd('/'))/api/v3/root/config/"
        Method = 'GET'
        SkipCertificateCheck = [bool] $AllowUntrustedTls
        TimeoutSec = 10
    }
    $probe = Invoke-WebRequest @probeParameters
    Write-Information "Authentik discovery succeeded: HTTP $([int] $probe.StatusCode) from $AuthentikUri." -InformationAction Continue
    if (-not $Apply) {
        Write-Information 'Dry run complete. Use -Apply -Confirm to configure Authentik LDAP.' -InformationAction Continue
        return
    }
    if (-not $PSCmdlet.ShouldProcess($AuthentikUri, 'Create or update the Authentik LDAP directory and managed outpost')) { return }
    if ($null -eq $SharedPassword) { $SharedPassword = Read-Host 'Shared Holodeck password' -AsSecureString }
    if ($null -eq $AuthentikToken) {
        $AuthentikToken = Read-Host 'Authentik API token key (Intent: API Token; do not use an app password)' -AsSecureString
    }
    if (-not $EnableLdaps -and (-not [string]::IsNullOrWhiteSpace($CertificatePath) -or
        -not [string]::IsNullOrWhiteSpace($PrivateKeyPath))) {
        throw '-CertificatePath and -PrivateKeyPath require -EnableLdaps.'
    }
    if ($EnableLdaps -and ([string]::IsNullOrWhiteSpace($CertificatePath) -xor [string]::IsNullOrWhiteSpace($PrivateKeyPath))) {
        throw 'Specify both -CertificatePath and -PrivateKeyPath, or neither to reuse the existing Authentik certificate.'
    }
    $authentikTokenValue = (ConvertFrom-SecureStringValue $AuthentikToken).Trim()
    if ($authentikTokenValue.StartsWith('Bearer ', [StringComparison]::OrdinalIgnoreCase)) {
        $authentikTokenValue = $authentikTokenValue.Substring(7).Trim()
    }
    if ([string]::IsNullOrWhiteSpace($authentikTokenValue)) { throw 'The Authentik API token key was empty.' }
    $payload = @{
        SharedPassword = ConvertFrom-SecureStringValue $SharedPassword
        AuthentikToken = $authentikTokenValue
        AuthentikUri = $AuthentikUri.TrimEnd('/')
        LdapBaseDn = $LdapBaseDn
        AdminGroup = $AdminGroup
        UserGroup = $UserGroup
        CertificatePath = $CertificatePath
        PrivateKeyPath = $PrivateKeyPath
        ExternalIp = @($ExternalIp)
        LdapHost = $LdapHost
        LdapPort = $LdapPort
        AllowUntrustedTls = [bool] $AllowUntrustedTls
        TraceGroupApiResponses = [bool] $TraceGroupApiResponses
        EnableLdaps = [bool] $EnableLdaps
    }
}
else {
    $payloadText = [Console]::In.ReadToEnd()
    if ([string]::IsNullOrWhiteSpace($payloadText)) { throw 'A JSON payload is required on stdin.' }
    $payload = $payloadText | ConvertFrom-Json -AsHashtable
}
$authentikBaseUri = if ($payload.AuthentikUri) { ([string] $payload.AuthentikUri).TrimEnd('/') } else { 'https://auth.vcf.lab' }
$skipCertificateCheck = if ($payload.ContainsKey('AllowUntrustedTls')) { [bool] $payload.AllowUntrustedTls } else { $true }
$externalIps = if ($payload.ExternalIp) { @($payload.ExternalIp) } else { @('172.20.41.120', '10.1.1.1') }
$traceGroupResponses = $payload.ContainsKey('TraceGroupApiResponses') -and [bool] $payload.TraceGroupApiResponses
$enableLdaps = if ($payload.ContainsKey('EnableLdaps')) {
    [bool] $payload['EnableLdaps']
}
else { $false }

function Invoke-AuthentikApi {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [ValidateSet('GET', 'POST', 'PATCH', 'DELETE')] [string] $Method,
        [Parameter(Mandatory)] [string] $Path,
        [Parameter()] [hashtable] $Body
    )

    $parameters = @{
        Uri                = "$authentikBaseUri/api/v3$Path"
        Method             = $Method
        Headers            = @{
            Authorization = "Bearer $($payload.AuthentikToken)"
            Accept        = 'application/json'
        }
        SkipCertificateCheck = $skipCertificateCheck
        ErrorAction        = 'Stop'
    }
    if ($null -ne $Body) {
        $parameters.ContentType = 'application/json'
        $parameters.Body = $Body | ConvertTo-Json -Depth 20 -Compress
    }
    try {
        $response = Invoke-RestMethod @parameters
        if ($traceGroupResponses -and $Path -like '/core/groups/*') {
            $responseType = if ($null -eq $response) { 'null' } else { $response.GetType().FullName }
            $responsePayload = if ($null -eq $response) {
                '<null>'
            }
            elseif ($response -is [string]) {
                [string] $response
            }
            else {
                $response | ConvertTo-Json -Depth 10 -Compress
            }
            if ($responsePayload.Length -gt 4000) {
                $responsePayload = $responsePayload.Substring(0, 4000) + '<truncated>'
            }
            Write-Information "TRACE Authentik response: method=$Method path=$Path type=$responseType payload=$responsePayload" -InformationAction Continue
        }
        $response
    }
    catch {
        $statusCode = $null
        $responseProperty = $_.Exception.PSObject.Properties['Response']
        if ($null -ne $responseProperty -and $null -ne $responseProperty.Value) {
            $statusCodeProperty = $responseProperty.Value.PSObject.Properties['StatusCode']
            if ($null -ne $statusCodeProperty -and $null -ne $statusCodeProperty.Value) {
                $statusCode = [int] $statusCodeProperty.Value
            }
        }
        $detail = [string] $_.ErrorDetails.Message
        foreach ($secretName in 'SharedPassword', 'AuthentikToken') {
            $secret = [string] $payload[$secretName]
            if (-not [string]::IsNullOrEmpty($secret)) { $detail = $detail.Replace($secret, '[REDACTED]') }
        }
        $tokenGuidance = if ($detail -match 'Token invalid/expired') {
            ' Supply the copied token key from Directory > Tokens and App passwords with Intent set to API Token; do not use its identifier, an app password, or an OAuth client secret.'
        }
        else { '' }
        $apiException = [InvalidOperationException]::new("Authentik API $Method $Path failed: $detail$tokenGuidance")
        if ($null -ne $statusCode) { $apiException.Data['StatusCode'] = $statusCode }
        throw $apiException
    }
}

function Test-AuthentikApiStatusCode {
    param([Parameter(Mandatory)] $ErrorRecord, [Parameter(Mandatory)] [int] $ExpectedStatusCode)
    $recordedStatusCode = $ErrorRecord.Exception.Data['StatusCode']
    return $null -ne $recordedStatusCode -and [int] $recordedStatusCode -eq $ExpectedStatusCode
}

function Get-SingleResult {
    param([string] $Path, [string] $Description)
    $response = Invoke-AuthentikApi -Method GET -Path $Path
    $results = @($response.results)
    if ($results.Count -gt 1) { throw "Multiple Authentik objects matched $Description." }
    if ($results.Count -eq 1) { return $results[0] }
    return $null
}

function Resolve-ApiObject {
    param($Response, $Existing, [string] $Description)
    if ($Response -is [string] -and -not [string]::IsNullOrWhiteSpace($Response)) {
        try {
            $decodedResponse = $Response | ConvertFrom-Json -ErrorAction Stop
            if ($decodedResponse -isnot [string]) { $Response = $decodedResponse }
        }
        catch {
            # Keep the scalar response for the fallback decision below. The
            # opt-in group trace reports its exact value and runtime type.
        }
    }
    # Authentik PATCH endpoints can return an empty or non-empty scalar string
    # instead of the updated representation. A string is never a usable API
    # model here; retain the object fetched before PATCH. POST paths have no
    # existing object and will still fail the property validation below.
    $hasResponseObject = $null -ne $Response -and $Response -isnot [string]
    $resolved = if ($hasResponseObject) { $Response } else { $Existing }
    if ($null -eq $resolved -or $resolved.PSObject.Properties.Name -notcontains 'pk') {
        $properties = if ($null -eq $resolved) { 'none' } else { @($resolved.PSObject.Properties.Name) -join ', ' }
        throw "Authentik returned no usable $Description object. Response properties: $properties."
    }
    $resolved
}

function Get-RequiredProperty {
    param($InputObject, [string] $Property, [string] $Description)
    $objects = @($InputObject)
    if ($objects.Count -ne 1) {
        throw "Expected one $Description object but received $($objects.Count)."
    }
    $object = $objects[0]
    if ($null -eq $object -or $object.PSObject.Properties.Name -notcontains $Property) {
        $type = if ($null -eq $object) { 'null' } else { $object.GetType().FullName }
        $properties = if ($null -eq $object) { 'none' } else { @($object.PSObject.Properties.Name) -join ', ' }
        throw "The $Description object has no '$Property' property. Type: $type. Properties: $properties."
    }
    $object.$Property
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
        $group = Resolve-ApiObject (Invoke-AuthentikApi POST '/core/groups/' $body) $null "group '$Name'"
    }
    else {
        $group = Resolve-ApiObject (Invoke-AuthentikApi PATCH "/core/groups/$($group.pk)/" $body) $group "group '$Name'"
    }
    # Callers re-query the group after mutation. Do not make downstream
    # behavior depend on how PowerShell surfaces the PATCH response.
}

function Ensure-User {
    param([string] $Username, [string] $DisplayName, [string] $Type, [string[]] $Groups)
    $encoded = [Uri]::EscapeDataString($Username)
    Write-Information "Resolving Authentik user '$Username'." -InformationAction Continue
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
        Write-Information "Creating Authentik user '$Username'." -InformationAction Continue
        $user = Resolve-ApiObject (Invoke-AuthentikApi POST '/core/users/' $body) $null "user '$Username'"
    }
    else {
        $existingUserPk = Get-RequiredProperty $user 'pk' "user '$Username'"
        Write-Information "Updating Authentik user '$Username'." -InformationAction Continue
        $user = Resolve-ApiObject (Invoke-AuthentikApi PATCH "/core/users/$existingUserPk/" $body) $user "user '$Username'"
    }
    $userPk = Get-RequiredProperty $user 'pk' "user '$Username'"
    Write-Information "Setting the password for Authentik user '$Username'." -InformationAction Continue
    $null = Invoke-AuthentikApi POST "/core/users/$userPk/set_password/" @{ password = $payload.SharedPassword }
    $user
}

function Ensure-Role {
    param([string] $Name, [int] $UserPk)
    $encoded = [Uri]::EscapeDataString($Name)
    $role = Get-SingleResult "/rbac/roles/?name=$encoded" "role '$Name'"
    if ($null -eq $role) {
        $role = Resolve-ApiObject (Invoke-AuthentikApi POST '/rbac/roles/' @{ name = $Name }) $null "role '$Name'"
    }
    $null = Invoke-AuthentikApi POST "/rbac/roles/$($role.pk)/add_user/" @{ pk = $UserPk }
    $role
}

function Ensure-Certificate {
    $name = 'Holodeck auth.vcf.lab LDAPS'
    $encoded = [Uri]::EscapeDataString($name)
    $certificate = Get-SingleResult "/crypto/certificatekeypairs/?name=$encoded" "certificate '$name'"
    $certificateFilePath = if ($payload.CertificatePath) { [string] $payload.CertificatePath } else { '/holodeck-runtime/authentik/ssl/auth.crt' }
    $privateKeyFilePath = if ($payload.PrivateKeyPath) { [string] $payload.PrivateKeyPath } else { '/holodeck-runtime/authentik/ssl/auth.key' }
    $hasCertificateFiles = (Test-Path -LiteralPath $certificateFilePath -PathType Leaf) -and
        (Test-Path -LiteralPath $privateKeyFilePath -PathType Leaf)
    if (-not $hasCertificateFiles) {
        if ($null -ne $certificate) { return $certificate }
        throw 'The LDAPS certificate does not exist in Authentik. Supply bastion-local -CertificatePath and -PrivateKeyPath values.'
    }
    $body = @{
        name             = $name
        certificate_data = Get-Content -LiteralPath $certificateFilePath -Raw
        key_data         = Get-Content -LiteralPath $privateKeyFilePath -Raw
    }
    if ($null -eq $certificate) {
        return Resolve-ApiObject (Invoke-AuthentikApi POST '/crypto/certificatekeypairs/' $body) $null "certificate '$name'"
    }
    Resolve-ApiObject (Invoke-AuthentikApi PATCH "/crypto/certificatekeypairs/$($certificate.pk)/" $body) $certificate "certificate '$name'"
}

function Remove-ObsoleteBindToken {
    $identifier = 'holodeck-ldap-bind'
    try {
        $null = Invoke-AuthentikApi DELETE "/core/tokens/$identifier/"
    }
    catch {
        if (-not (Test-AuthentikApiStatusCode $_ 404)) { throw }
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
        $flow = Resolve-ApiObject (Invoke-AuthentikApi POST '/flows/instances/' $flowBody) $null "flow '$flowSlug'"
    }
    else {
        $flow = Resolve-ApiObject (Invoke-AuthentikApi PATCH "/flows/instances/$flowSlug/" $flowBody) $flow "flow '$flowSlug'"
    }

    $passwordName = 'holodeck-ldap-password'
    $passwordStage = Get-ExactNamedResult '/stages/password/?page_size=100' $passwordName "password stage '$passwordName'"
    $passwordBody = @{
        name     = $passwordName
        backends = @('authentik.core.auth.InbuiltBackend')
    }
    if ($null -eq $passwordStage) {
        $passwordStage = Resolve-ApiObject (Invoke-AuthentikApi POST '/stages/password/' $passwordBody) $null "password stage '$passwordName'"
    }
    else {
        $passwordStage = Resolve-ApiObject (Invoke-AuthentikApi PATCH "/stages/password/$($passwordStage.pk)/" $passwordBody) $passwordStage "password stage '$passwordName'"
    }

    $identificationName = 'holodeck-ldap-identification'
    $identificationStage = Get-ExactNamedResult '/stages/identification/?page_size=100' $identificationName "identification stage '$identificationName'"
    $identificationBody = @{
        name           = $identificationName
        user_fields    = @('username', 'email')
        password_stage = $passwordStage.pk
    }
    if ($null -eq $identificationStage) {
        $identificationStage = Resolve-ApiObject (Invoke-AuthentikApi POST '/stages/identification/' $identificationBody) $null "identification stage '$identificationName'"
    }
    else {
        $identificationStage = Resolve-ApiObject (Invoke-AuthentikApi PATCH "/stages/identification/$($identificationStage.pk)/" $identificationBody) $identificationStage "identification stage '$identificationName'"
    }

    $loginName = 'holodeck-ldap-login'
    $loginStage = Get-ExactNamedResult '/stages/user_login/?page_size=100' $loginName "user login stage '$loginName'"
    $loginBody = @{ name = $loginName }
    if ($null -eq $loginStage) {
        $loginStage = Resolve-ApiObject (Invoke-AuthentikApi POST '/stages/user_login/' $loginBody) $null "login stage '$loginName'"
    }
    else {
        $loginStage = Resolve-ApiObject (Invoke-AuthentikApi PATCH "/stages/user_login/$($loginStage.pk)/" $loginBody) $loginStage "login stage '$loginName'"
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
        $policy = Resolve-ApiObject (Invoke-AuthentikApi POST '/policies/expression/' $policyBody) $null "expression policy '$policyName'"
    }
    else {
        $policy = Resolve-ApiObject (Invoke-AuthentikApi PATCH "/policies/expression/$($policy.pk)/" $policyBody) $policy "expression policy '$policyName'"
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
        certificate         = if ($null -eq $Certificate) { $null } else { $Certificate.pk }
        tls_server_name     = 'auth.vcf.lab'
        search_mode         = 'cached'
        bind_mode           = 'direct'
        mfa_support         = $false
    }
    if ($null -eq $provider) {
        return Resolve-ApiObject (Invoke-AuthentikApi POST '/providers/ldap/' $body) $null "LDAP provider '$name'"
    }
    Resolve-ApiObject (Invoke-AuthentikApi PATCH "/providers/ldap/$($provider.pk)/" $body) $provider "LDAP provider '$name'"
}

function Ensure-Application {
    param([int] $ProviderPk)
    $slug = 'holodeck-vcf-automation-ldap'
    $application = $null
    try { $application = Invoke-AuthentikApi GET "/core/applications/$slug/" } catch {
        if (-not (Test-AuthentikApiStatusCode $_ 404)) { throw }
    }
    $body = @{
        name = 'Holodeck VCF Automation LDAP'
        slug = $slug
        provider = $ProviderPk
        policy_engine_mode = 'all'
        meta_description = 'LDAP directory for the Holodeck VCF Automation All Apps organization'
    }
    if ($null -eq $application) {
        return Resolve-ApiObject (Invoke-AuthentikApi POST '/core/applications/' $body) $null "application '$slug'"
    }
    Resolve-ApiObject (Invoke-AuthentikApi PATCH "/core/applications/$slug/" $body) $application "application '$slug'"
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
            authentik_host_browser = "$authentikBaseUri/"
            authentik_host_insecure = $true
            log_level = 'info'
            refresh_interval = 'seconds=10'
            kubernetes_namespace = 'default'
            kubernetes_service_type = 'ClusterIP'
            kubernetes_json_patches = @{
                service = @(
                    @{ op = 'add'; path = '/spec/externalIPs'; value = @($externalIps) }
                )
            }
        }
    }
    if ($null -eq $outpost) {
        return Resolve-ApiObject (Invoke-AuthentikApi POST '/outposts/instances/' $body) $null "outpost '$name'"
    }
    Resolve-ApiObject (Invoke-AuthentikApi PATCH "/outposts/instances/$($outpost.pk)/" $body) $outpost "outpost '$name'"
}

try {
    Write-Information 'Creating or updating Authentik LDAP groups.' -InformationAction Continue
    $null = Ensure-Group $payload.AdminGroup
    $null = Ensure-Group $payload.UserGroup
    Write-Information 'Re-querying Authentik LDAP groups after mutation.' -InformationAction Continue
    $adminGroupName = [Uri]::EscapeDataString([string] $payload.AdminGroup)
    $userGroupName = [Uri]::EscapeDataString([string] $payload.UserGroup)
    $adminGroupObject = Get-SingleResult "/core/groups/?name=$adminGroupName" "group '$($payload.AdminGroup)' after mutation"
    $userGroupObject = Get-SingleResult "/core/groups/?name=$userGroupName" "group '$($payload.UserGroup)' after mutation"
    if ($traceGroupResponses) {
        $adminBoundaryType = if ($null -eq $adminGroupObject) { 'null' } else { $adminGroupObject.GetType().FullName }
        $userBoundaryType = if ($null -eq $userGroupObject) { 'null' } else { $userGroupObject.GetType().FullName }
        Write-Information "TRACE group boundary: adminType=$adminBoundaryType userType=$userBoundaryType" -InformationAction Continue
        if ($adminGroupObject -is [string]) { Write-Information "TRACE group boundary adminValue=$adminGroupObject" -InformationAction Continue }
        if ($userGroupObject -is [string]) { Write-Information "TRACE group boundary userValue=$userGroupObject" -InformationAction Continue }
    }
    if ($null -eq $adminGroupObject -or $adminGroupObject.PSObject.Properties.Name -notcontains 'pk') {
        throw "The freshly queried group '$($payload.AdminGroup)' did not contain pk."
    }
    if ($null -eq $userGroupObject -or $userGroupObject.PSObject.Properties.Name -notcontains 'pk') {
        throw "The freshly queried group '$($payload.UserGroup)' did not contain pk."
    }
    $adminGroupPk = [string] $adminGroupObject.pk
    $userGroupPk = [string] $userGroupObject.pk
    Write-Information 'Creating or updating Authentik LDAP users.' -InformationAction Continue
    $vcfAdmin = Ensure-User 'vcfadmin' 'VCF Administrator' 'internal' @($adminGroupPk)
    $vcfUser01 = Ensure-User 'vcfuser01' 'VCF User 01' 'internal' @($userGroupPk)
    $vcfUser02 = Ensure-User 'vcfuser02' 'VCF User 02' 'internal' @($userGroupPk)
    $ldapService = Ensure-User 'ldapservice' 'VCF LDAP Bind Service' 'internal' @()
    $null = Remove-ObsoleteBindToken

    $certificate = $null
    if ($enableLdaps) {
        Write-Information 'Resolving the optional Authentik LDAPS certificate.' -InformationAction Continue
        $certificate = Ensure-Certificate
    }
    else {
        Write-Information 'LDAPS is disabled; configuring the lab for plain LDAP only.' -InformationAction Continue
    }
    Write-Information 'Creating or updating the LDAP authentication flow.' -InformationAction Continue
    $authentication = Ensure-AuthenticationFlow
    Write-Information 'Creating or updating the LDAP provider and application.' -InformationAction Continue
    $provider = Ensure-LdapProvider $certificate $authentication.Flow
    $application = Ensure-Application $provider.pk
    # With no application bindings, Authentik permits all active users to bind.
    # Full-directory searches remain restricted by the provider-scoped RBAC grant.
    Remove-PolicyBindings $authentication.AllowPolicy
    Write-Information 'Assigning provider-scoped LDAP search permission.' -InformationAction Continue
    $role = Ensure-Role 'LDAP directory search' $ldapService.pk
    $null = Invoke-AuthentikApi POST "/rbac/permissions/assigned_by_roles/$($role.pk)/assign/" @{
        permissions = @('authentik_providers_ldap.search_full_directory')
        model       = 'authentik_providers_ldap.ldapprovider'
        object_pk   = [string] $provider.pk
    }
    Write-Information 'Creating or updating the managed LDAP outpost.' -InformationAction Continue
    $outpost = Ensure-Outpost $provider.pk

    # Outposts receive provider and flow changes asynchronously. Give the managed
    # outpost one refresh interval before VCF Automation performs its LDAP test.
    Start-Sleep -Seconds 35

    $ldapEndpointReachable = $null
    if ($directMode) {
        Write-Information "Waiting for LDAP at $($payload.LdapHost):$($payload.LdapPort)." -InformationAction Continue
        $deadline = [DateTime]::UtcNow.AddMinutes(5)
        do {
            $client = [Net.Sockets.TcpClient]::new()
            try {
                $task = $client.ConnectAsync([string] $payload.LdapHost, [int] $payload.LdapPort)
                $ready = $task.Wait([TimeSpan]::FromSeconds(3)) -and $client.Connected
            }
            catch { $ready = $false }
            finally { $client.Dispose() }
            if (-not $ready) { Start-Sleep -Seconds 10 }
        } until ($ready -or [DateTime]::UtcNow -ge $deadline)
        if (-not $ready) { throw "LDAP endpoint $($payload.LdapHost):$($payload.LdapPort) did not become available within five minutes." }
        $ldapEndpointReachable = $true
    }

    $authentikResult = [ordered]@{
        Changed             = $true
        ProviderPk          = $provider.pk
        ApplicationSlug     = $application.slug
        OutpostPk           = $outpost.pk
        LdapsEnabled        = [bool] $enableLdaps
        LdapEndpointReachable = $ldapEndpointReachable
        LdapBindDn          = "cn=ldapservice,ou=users,$($payload.LdapBaseDn)"
        AdminGroupDn        = "cn=$($payload.AdminGroup),ou=groups,$($payload.LdapBaseDn)"
        UserGroupDn         = "cn=$($payload.UserGroup),ou=groups,$($payload.LdapBaseDn)"
        Users               = @($vcfAdmin.username, $vcfUser01.username, $vcfUser02.username)
    }
    if ($directMode) {
        [ordered]@{
            Mode = 'AuthentikOnly'
            Authentik = $authentikResult
            IdentityProviderHandoff = [ordered]@{
                ConnectorType = 'OPEN_LDAP'
                HostName = [string] $payload.LdapHost
                Port = [int] $payload.LdapPort
                Ssl = $false
                SearchBase = $payload.LdapBaseDn
                GroupSearchBase = "ou=groups,$($payload.LdapBaseDn)"
                BindDn = "cn=ldapservice,ou=users,$($payload.LdapBaseDn)"
                AdminGroup = $payload.AdminGroup
                UserGroup = $payload.UserGroup
            }
        } | ConvertTo-Json -Depth 8
    }
    else {
        $authentikResult | ConvertTo-Json -Depth 5
    }
}
finally {
    if ($directMode) {
        $payload.SharedPassword = $null
        $payload.AuthentikToken = $null
        $authentikTokenValue = $null
    }
}
