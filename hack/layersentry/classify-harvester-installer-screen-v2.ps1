[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string]$OcrJsonPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$basePath = Join-Path $PSScriptRoot 'classify-harvester-installer-screen.ps1'
$baseJson = & $basePath -OcrJsonPath $OcrJsonPath
$classification = $baseJson | ConvertFrom-Json
$ocr = Get-Content -LiteralPath $OcrJsonPath -Raw -Encoding UTF8 | ConvertFrom-Json
$text = (([string]$ocr.text) -replace '[\r\n\t]+', ' ' -replace '\s+', ' ').Trim()
$lower = $text.ToLowerInvariant()

function Set-Classification {
    param(
        [Parameter(Mandatory = $true)][string]$State,
        [Parameter(Mandatory = $true)][string]$Reason,
        [string]$Confidence = 'high'
    )
    $script:classification.state = $State
    $script:classification.reason = $Reason
    $script:classification.confidence = $Confidence
    $script:classification.normalizedText = $script:text
}

# Apply reviewed generic fallbacks only when the base classifier is uncertain.
# Review/progress/error patterns are evaluated first because those screens can
# repeat words such as password, NTP, proxy and token in their summaries.
if ([string]$classification.state -in @('UNKNOWN', 'INSTALLER_UNCLASSIFIED')) {
    if ($lower -match 'passwords?\s+(do\s+not|don.t)\s+match|invalid\s+(password|value|address|token)|validation\s+(failed|error)|unable\s+to\s+continue|installation\s+failed|\berror\b') {
        Set-Classification -State 'INSTALLER_ERROR' -Reason 'Installer validation or failure text is present.'
    }
    elseif ($lower -match 'review.*configuration|configuration.*review|confirm.*installation|start.*installation|install\s+now|are\s+you\s+sure') {
        Set-Classification -State 'REVIEW_OR_INSTALL_CONFIRMATION' -Reason 'Generic review or confirmation text matched.'
    }
    elseif ($lower -match 'installation.*(complete|successful)|successfully\s+installed|remove.*installation\s+media|reboot') {
        Set-Classification -State 'INSTALL_COMPLETE' -Reason 'Generic completion or reboot text matched.'
    }
    elseif ($lower -match 'installing|installation\s+in\s+progress|copying|writing.*(image|disk)|formatting|extracting|setting\s+up') {
        Set-Classification -State 'INSTALLING' -Reason 'Generic installation progress text matched.'
    }
    elseif ($lower -match 'confirm.*password|re[- ]?enter.*password|password.*again') {
        Set-Classification -State 'CONFIRM_PASSWORD' -Reason 'Generic password confirmation text matched.'
    }
    elseif ($lower -match '\bpassword\b') {
        Set-Classification -State 'PASSWORD' -Reason 'Generic password prompt text matched.'
    }
    elseif ($lower -match 'ssh.*(key|access)|authorized[_ ]keys?|public\s+key|cloud[- ]?init|remote\s+harvester|configuration\s+url') {
        Set-Classification -State 'SSH_KEY' -Reason 'Optional SSH, cloud-init, or remote configuration prompt matched; Enter safely skips it.'
    }
    elseif ($lower -match 'https?\s*proxy|no[_ -]?proxy|proxy') {
        Set-Classification -State 'PROXY' -Reason 'Generic proxy prompt text matched.'
    }
    elseif ($lower -match 'time\s*zone|timezone') {
        Set-Classification -State 'TIMEZONE' -Reason 'Generic timezone prompt text matched.'
    }
    elseif ($lower -match '\bntp\b|network\s+time|time\s+server') {
        Set-Classification -State 'NTP_SERVERS' -Reason 'Generic NTP prompt text matched.'
    }
    elseif ($lower -match 'cluster\s+token|enter.*token|token.*cluster') {
        Set-Classification -State 'CLUSTER_TOKEN' -Reason 'Generic cluster-token prompt text matched.'
    }
    elseif ($lower -match 'virtual\s+ip|\bvip\b|management\s+(address|url)|server\s+(address|url)') {
        Set-Classification -State 'VIP_OR_MANAGEMENT_ADDRESS' -Reason 'Generic VIP or cluster address prompt matched.'
    }
    elseif ($lower -match '\bdns\b|name\s+server') {
        Set-Classification -State 'DNS_SERVERS' -Reason 'Generic DNS prompt text matched.'
    }
    elseif ($lower -match 'host\s*name|hostname') {
        Set-Classification -State 'HOSTNAME' -Reason 'Generic hostname prompt text matched.'
    }
}

$classification | ConvertTo-Json -Depth 8
