[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string]$OcrJsonPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ocr = Get-Content -LiteralPath $OcrJsonPath -Raw -Encoding UTF8 | ConvertFrom-Json
$text = [string]$ocr.text
$normalized = ($text -replace '[\r\n\t]+', ' ' -replace '\s+', ' ').Trim()
$lower = $normalized.ToLowerInvariant()

function Test-AnyPattern {
    param([string[]]$Patterns)
    foreach ($pattern in $Patterns) {
        if ($script:lower -match $pattern) {
            return $true
        }
    }
    return $false
}

$state = 'UNKNOWN'
$confidence = 'low'
$reason = 'No reviewed installer prompt pattern matched.'

# Priority is important: review and progress screens repeat field labels such as
# NTP, proxy, password and VIP. They must be classified before individual forms.
if (Test-AnyPattern @(
    'installation\s+(is\s+)?(complete|completed|successful|succeeded)',
    'successfully\s+installed',
    'remove\s+the\s+installation\s+media',
    'reboot(ing|\s+the\s+system)?'
)) {
    $state = 'INSTALL_COMPLETE'
    $confidence = 'high'
    $reason = 'Installer reports completion or reboot.'
}
elseif (Test-AnyPattern @(
    'installing\s+(harvester|layersentry)',
    'installation\s+in\s+progress',
    'writing\s+(the\s+)?(image|disk)',
    'copying\s+(files|image)',
    'formatting\s+(the\s+)?disk',
    'setting\s+up\s+(the\s+)?system'
)) {
    $state = 'INSTALLING'
    $confidence = 'high'
    $reason = 'Installer progress text is present.'
}
elseif (Test-AnyPattern @(
    'review\s+(the\s+)?configuration',
    'configuration\s+summary',
    'confirm\s+(the\s+)?installation',
    'start\s+(the\s+)?installation',
    'install\s+now',
    'are\s+you\s+sure.*install'
)) {
    $state = 'REVIEW_OR_INSTALL_CONFIRMATION'
    $confidence = 'high'
    $reason = 'Review or installation confirmation screen is present.'
}
elseif (Test-AnyPattern @(
    'confirm\s+(the\s+)?password',
    're[- ]?enter\s+(the\s+)?password',
    'password\s+confirmation'
)) {
    $state = 'CONFIRM_PASSWORD'
    $confidence = 'high'
    $reason = 'Password confirmation prompt is present.'
}
elseif (Test-AnyPattern @(
    'set\s+(the\s+)?password',
    'enter\s+(a\s+)?password',
    'password\s+for\s+(the\s+)?(rancher|harvester|user|node)',
    'os\s+password'
)) {
    $state = 'PASSWORD'
    $confidence = 'high'
    $reason = 'Initial password prompt is present.'
}
elseif (Test-AnyPattern @(
    'ssh\s+(authorized\s+)?key',
    'public\s+ssh\s+key',
    'authorized_keys'
)) {
    $state = 'SSH_KEY'
    $confidence = 'high'
    $reason = 'Optional SSH-key prompt is present.'
}
elseif (Test-AnyPattern @(
    'http\s+proxy',
    'https\s+proxy',
    'proxy\s+(address|url|configuration|settings)',
    'no[_ -]?proxy'
)) {
    $state = 'PROXY'
    $confidence = 'high'
    $reason = 'Proxy configuration prompt is present.'
}
elseif (Test-AnyPattern @(
    'time\s*zone',
    'timezone'
)) {
    $state = 'TIMEZONE'
    $confidence = 'high'
    $reason = 'Timezone prompt is present.'
}
elseif (Test-AnyPattern @(
    '\bntp\b',
    'network\s+time\s+protocol',
    'time\s+server'
)) {
    $state = 'NTP_SERVERS'
    $confidence = 'high'
    $reason = 'NTP-server prompt is present.'
}
elseif (Test-AnyPattern @(
    'cluster\s+token',
    'token\s+for\s+(the\s+)?cluster',
    'enter\s+(the\s+)?token'
)) {
    $state = 'CLUSTER_TOKEN'
    $confidence = 'high'
    $reason = 'Cluster-token prompt is present.'
}
elseif (Test-AnyPattern @(
    'virtual\s+ip',
    '\bvip\b',
    'management\s+(address|url)',
    'server\s+(address|url)'
)) {
    $state = 'VIP_OR_MANAGEMENT_ADDRESS'
    $confidence = 'medium'
    $reason = 'VIP or existing-cluster address prompt is present.'
}
elseif (Test-AnyPattern @(
    '\bdns\b',
    'name\s+server'
)) {
    $state = 'DNS_SERVERS'
    $confidence = 'high'
    $reason = 'DNS-server prompt is present.'
}
elseif (Test-AnyPattern @(
    'host\s*name',
    'hostname'
)) {
    $state = 'HOSTNAME'
    $confidence = 'high'
    $reason = 'Hostname prompt is present.'
}
elseif (Test-AnyPattern @(
    'install(ation)?\s+(device|disk)',
    'select\s+(the\s+)?disk.*install'
)) {
    $state = 'INSTALL_DISK'
    $confidence = 'high'
    $reason = 'Installation-disk selection is present.'
}
elseif (Test-AnyPattern @(
    'data\s+(device|disk)',
    'select\s+(the\s+)?disk.*data'
)) {
    $state = 'DATA_DISK'
    $confidence = 'high'
    $reason = 'Data-disk selection is present.'
}
elseif (Test-AnyPattern @(
    'ip\s+address',
    'subnet\s+mask',
    'default\s+gateway',
    'network\s+interface',
    'static\s+ip',
    'dhcp'
)) {
    $state = 'NETWORK_CONFIGURATION'
    $confidence = 'medium'
    $reason = 'Network configuration prompt is present.'
}
elseif (Test-AnyPattern @(
    'create\s+(a\s+)?new\s+(harvester\s+)?cluster',
    'join\s+(an\s+)?existing\s+(harvester\s+)?cluster',
    'installation\s+mode'
)) {
    $state = 'INSTALLATION_MODE'
    $confidence = 'medium'
    $reason = 'Installation-mode selection is present.'
}
elseif (Test-AnyPattern @(
    'harvester\s+installer',
    'layersentry\s+installer'
)) {
    $state = 'INSTALLER_UNCLASSIFIED'
    $confidence = 'low'
    $reason = 'Installer is visible but the active prompt was not classified.'
}
elseif (Test-AnyPattern @(
    'login:',
    'welcome\s+to\s+(harvester|layersentry)',
    'kubernetes',
    'rancher'
)) {
    $state = 'BOOTED_OR_LOGIN'
    $confidence = 'medium'
    $reason = 'Installed-system or login text is visible.'
}

[ordered]@{
    schemaVersion = '1.0'
    state = $state
    confidence = $confidence
    reason = $reason
    normalizedText = $normalized
} | ConvertTo-Json -Depth 5
