Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-Sen2RancherdEndpointDecision {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ObservedRancherdServerUrl,
        [Parameter(Mandatory = $true)][string]$ExpectedRancherdServerUrl,
        [Parameter(Mandatory = $true)][string]$KnownDriftedRancherdServerUrl,
        [Parameter(Mandatory = $true)][bool]$AllowKnownDriftCorrection
    )

    foreach ($value in @(
        $ObservedRancherdServerUrl,
        $ExpectedRancherdServerUrl,
        $KnownDriftedRancherdServerUrl
    )) {
        if ([string]::IsNullOrWhiteSpace($value)) {
            throw 'Rancherd endpoint decision inputs must not be empty.'
        }
        $uri = $null
        if (-not [Uri]::TryCreate($value, [UriKind]::Absolute, [ref]$uri)) {
            throw "Invalid absolute rancherd endpoint URL: $value"
        }
        if ($uri.Scheme -cne 'https' -or $uri.Port -ne 443 -or $uri.AbsolutePath -cne '/') {
            throw "Rancherd endpoint must be an HTTPS origin on port 443: $value"
        }
    }
    if ($ExpectedRancherdServerUrl -ceq $KnownDriftedRancherdServerUrl) {
        throw 'Expected and known-drifted rancherd endpoints must differ.'
    }

    if ($ObservedRancherdServerUrl -ceq $ExpectedRancherdServerUrl) {
        return [pscustomobject][ordered]@{
            decision = 'ALREADY_EXPECTED'
            accepted = $true
            correctionRequired = $false
            rejectionExitCode = 0
            observedRancherdServerUrl = $ObservedRancherdServerUrl
            expectedRancherdServerUrl = $ExpectedRancherdServerUrl
            knownDriftedRancherdServerUrl = $KnownDriftedRancherdServerUrl
        }
    }

    if (
        $ObservedRancherdServerUrl -ceq $KnownDriftedRancherdServerUrl -and
        $AllowKnownDriftCorrection
    ) {
        return [pscustomobject][ordered]@{
            decision = 'CORRECT_KNOWN_DRIFT'
            accepted = $true
            correctionRequired = $true
            rejectionExitCode = 0
            observedRancherdServerUrl = $ObservedRancherdServerUrl
            expectedRancherdServerUrl = $ExpectedRancherdServerUrl
            knownDriftedRancherdServerUrl = $KnownDriftedRancherdServerUrl
        }
    }

    return [pscustomobject][ordered]@{
        decision = 'REJECT_UNEXPECTED_ENDPOINT'
        accepted = $false
        correctionRequired = $false
        rejectionExitCode = 64
        observedRancherdServerUrl = $ObservedRancherdServerUrl
        expectedRancherdServerUrl = $ExpectedRancherdServerUrl
        knownDriftedRancherdServerUrl = $KnownDriftedRancherdServerUrl
    }
}

Export-ModuleMember -Function Resolve-Sen2RancherdEndpointDecision
