[CmdletBinding()]
param(
    [string]$CredentialPath = 'C:\ProgramData\LayerSentry\bootstrap-credentials.json',
    [string]$EvidenceDirectory = (Join-Path $env:RUNNER_TEMP 'layersentry-bootstrap-credentials')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function New-CryptoString {
    param(
        [Parameter(Mandatory = $true)][int]$Length,
        [Parameter(Mandatory = $true)][string]$Alphabet
    )

    if ($Length -le 0 -or [string]::IsNullOrEmpty($Alphabet)) {
        throw 'Invalid cryptographic string parameters.'
    }
    $bytes = [byte[]]::new($Length)
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $rng.GetBytes($bytes)
    }
    finally {
        $rng.Dispose()
    }
    $characters = [char[]]::new($Length)
    for ($index = 0; $index -lt $Length; $index++) {
        $characters[$index] = $Alphabet[[int]($bytes[$index] % $Alphabet.Length)]
    }
    return -join $characters
}

function Protect-CredentialFile {
    param([Parameter(Mandatory = $true)][string]$Path)

    $acl = [System.Security.AccessControl.FileSecurity]::new()
    $acl.SetAccessRuleProtection($true, $false)
    $inheritance = [System.Security.AccessControl.InheritanceFlags]::None
    $propagation = [System.Security.AccessControl.PropagationFlags]::None
    $allow = [System.Security.AccessControl.AccessControlType]::Allow
    $fullControl = [System.Security.AccessControl.FileSystemRights]::FullControl
    $read = [System.Security.AccessControl.FileSystemRights]::Read
    $systemRule = [System.Security.AccessControl.FileSystemAccessRule]::new(
        'NT AUTHORITY\SYSTEM',
        $fullControl,
        $inheritance,
        $propagation,
        $allow
    )
    $adminRule = [System.Security.AccessControl.FileSystemAccessRule]::new(
        'BUILTIN\Administrators',
        $read,
        $inheritance,
        $propagation,
        $allow
    )
    [void]$acl.AddAccessRule($systemRule)
    [void]$acl.AddAccessRule($adminRule)
    Set-Acl -Path $Path -AclObject $acl
}

if (Test-Path -LiteralPath $EvidenceDirectory) {
    Remove-Item -LiteralPath $EvidenceDirectory -Recurse -Force
}
New-Item -Path $EvidenceDirectory -ItemType Directory -Force | Out-Null
$EvidenceDirectory = (Resolve-Path -LiteralPath $EvidenceDirectory).ProviderPath

$credentialDirectory = [System.IO.Path]::GetDirectoryName($CredentialPath)
if ([string]::IsNullOrWhiteSpace($credentialDirectory)) {
    throw "Credential path has no parent directory: $CredentialPath"
}
New-Item -Path $credentialDirectory -ItemType Directory -Force | Out-Null
$created = $false

if (Test-Path -LiteralPath $CredentialPath -PathType Leaf) {
    $credentials = Get-Content -LiteralPath $CredentialPath -Raw -Encoding UTF8 | ConvertFrom-Json
}
else {
    $safeAlphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789'
    $tokenAlphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789'
    $credentials = [pscustomobject]@{
        schemaVersion = '1.0'
        createdAtUtc = (Get-Date).ToUniversalTime().ToString('o')
        nodePassword = 'LSv1!' + (New-CryptoString -Length 19 -Alphabet $safeAlphabet)
        clusterToken = 'LS' + (New-CryptoString -Length 30 -Alphabet $tokenAlphabet)
        adminPassword = 'LSadm1!' + (New-CryptoString -Length 17 -Alphabet $safeAlphabet)
    }
    $temporary = "$CredentialPath.tmp"
    $credentials | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $temporary -Encoding UTF8
    Move-Item -LiteralPath $temporary -Destination $CredentialPath -Force
    $created = $true
}

$required = @('nodePassword', 'clusterToken', 'adminPassword')
$fieldLengths = @{}
foreach ($name in $required) {
    $property = $credentials.PSObject.Properties[$name]
    if ($null -eq $property -or [string]::IsNullOrWhiteSpace([string]$property.Value)) {
        throw "Credential file is missing required field: $name"
    }
    $length = ([string]$property.Value).Length
    if ($length -lt 16 -or $length -gt 128) {
        throw "Credential field $name has an invalid length: $length"
    }
    $fieldLengths[$name] = $length
}
Protect-CredentialFile -Path $CredentialPath

$acl = Get-Acl -Path $CredentialPath
$access = @(
    $acl.Access | ForEach-Object {
        [pscustomobject]@{
            Identity = $_.IdentityReference.Value
            Rights = [string]$_.FileSystemRights
            Type = [string]$_.AccessControlType
            Inherited = $_.IsInherited
        }
    }
)
$report = [pscustomobject]@{
    SchemaVersion = '1.1'
    GeneratedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
    CredentialPath = $CredentialPath
    CreatedThisRun = $created
    ReusedExistingCredentials = (-not $created)
    FieldLengths = $fieldLengths
    SecretsWrittenToLogs = $false
    ProtectedFromInheritance = $acl.AreAccessRulesProtected
    AccessRules = $access
    RetrievalCommand = "Get-Content -LiteralPath '$CredentialPath'"
}
$report | ConvertTo-Json -Depth 8 |
    Set-Content -LiteralPath (Join-Path $EvidenceDirectory 'bootstrap-credential-metadata.json') -Encoding UTF8
@(
    'LayerSentry bootstrap credential preparation'
    "Credential path: $CredentialPath"
    "Created this run: $created"
    "Secrets written to logs: False"
    "Node password length: $($fieldLengths.nodePassword)"
    "Cluster token length: $($fieldLengths.clusterToken)"
    "Admin password length: $($fieldLengths.adminPassword)"
    "Access rules protected: $($acl.AreAccessRulesProtected)"
) | Set-Content -LiteralPath (Join-Path $EvidenceDirectory 'bootstrap-credential-metadata.txt') -Encoding UTF8
Get-Content -LiteralPath (Join-Path $EvidenceDirectory 'bootstrap-credential-metadata.txt')
