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
        $node.Name -eq 'Test-AuthentikApiStatusCode'
}, $true)
if ($null -eq $functionAst) { throw 'Test-AuthentikApiStatusCode was not found.' }
Invoke-Expression $functionAst.Extent.Text

function New-TestErrorRecord([Nullable[int]] $StatusCode) {
    $exception = [InvalidOperationException]::new('redacted API failure')
    if ($null -ne $StatusCode) { $exception.Data['StatusCode'] = [int] $StatusCode }
    [Management.Automation.ErrorRecord]::new(
        $exception,
        'AuthentikApiFailure',
        [Management.Automation.ErrorCategory]::InvalidOperation,
        $null
    )
}

$notFound = New-TestErrorRecord 404
$serverError = New-TestErrorRecord 500
$missingStatus = New-TestErrorRecord $null

if (-not (Test-AuthentikApiStatusCode $notFound 404)) { throw 'A preserved 404 was not recognized.' }
if (Test-AuthentikApiStatusCode $serverError 404) { throw 'A 500 was incorrectly treated as 404.' }
if (Test-AuthentikApiStatusCode $missingStatus 404) { throw 'A missing status was incorrectly treated as 404.' }

[ordered]@{
    Result = 'Passed'
    Preserved404Recognized = $true
    ServerErrorPropagates = $true
    MissingStatusPropagates = $true
} | ConvertTo-Json
