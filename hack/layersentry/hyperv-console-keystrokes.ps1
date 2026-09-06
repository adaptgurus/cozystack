# Pure US-layout virtual-key mapping shared by Hyper-V console workflows.
function Get-CharacterStroke {
    param([Parameter(Mandatory = $true)][char]$Character)

    if ([char]::IsLetter($Character)) {
        $upper = [char]::ToUpperInvariant($Character)
        return [pscustomobject]@{
            Code = [uint32][int]$upper
            Shift = [char]::IsUpper($Character)
        }
    }
    if ([char]::IsDigit($Character)) {
        return [pscustomobject]@{
            Code = [uint32][int]$Character
            Shift = $false
        }
    }

    switch ([string]$Character) {
        ' ' { return [pscustomobject]@{ Code = [uint32]32; Shift = $false } }
        '!' { return [pscustomobject]@{ Code = [uint32]49; Shift = $true } }
        '@' { return [pscustomobject]@{ Code = [uint32]50; Shift = $true } }
        '#' { return [pscustomobject]@{ Code = [uint32]51; Shift = $true } }
        '$' { return [pscustomobject]@{ Code = [uint32]52; Shift = $true } }
        '%' { return [pscustomobject]@{ Code = [uint32]53; Shift = $true } }
        '^' { return [pscustomobject]@{ Code = [uint32]54; Shift = $true } }
        '&' { return [pscustomobject]@{ Code = [uint32]55; Shift = $true } }
        '*' { return [pscustomobject]@{ Code = [uint32]56; Shift = $true } }
        '(' { return [pscustomobject]@{ Code = [uint32]57; Shift = $true } }
        ')' { return [pscustomobject]@{ Code = [uint32]48; Shift = $true } }
        '-' { return [pscustomobject]@{ Code = [uint32]189; Shift = $false } }
        '_' { return [pscustomobject]@{ Code = [uint32]189; Shift = $true } }
        '=' { return [pscustomobject]@{ Code = [uint32]187; Shift = $false } }
        '+' { return [pscustomobject]@{ Code = [uint32]187; Shift = $true } }
        '[' { return [pscustomobject]@{ Code = [uint32]219; Shift = $false } }
        ']' { return [pscustomobject]@{ Code = [uint32]221; Shift = $false } }
        '{' { return [pscustomobject]@{ Code = [uint32]219; Shift = $true } }
        '}' { return [pscustomobject]@{ Code = [uint32]221; Shift = $true } }
        ';' { return [pscustomobject]@{ Code = [uint32]186; Shift = $false } }
        ':' { return [pscustomobject]@{ Code = [uint32]186; Shift = $true } }
        "'" { return [pscustomobject]@{ Code = [uint32]222; Shift = $false } }
        '"' { return [pscustomobject]@{ Code = [uint32]222; Shift = $true } }
        ',' { return [pscustomobject]@{ Code = [uint32]188; Shift = $false } }
        '<' { return [pscustomobject]@{ Code = [uint32]188; Shift = $true } }
        '.' { return [pscustomobject]@{ Code = [uint32]190; Shift = $false } }
        '>' { return [pscustomobject]@{ Code = [uint32]190; Shift = $true } }
        '/' { return [pscustomobject]@{ Code = [uint32]191; Shift = $false } }
        '?' { return [pscustomobject]@{ Code = [uint32]191; Shift = $true } }
        '\' { return [pscustomobject]@{ Code = [uint32]220; Shift = $false } }
        '|' { return [pscustomobject]@{ Code = [uint32]220; Shift = $true } }
        '`' { return [pscustomobject]@{ Code = [uint32]192; Shift = $false } }
        '~' { return [pscustomobject]@{ Code = [uint32]192; Shift = $true } }
        default { throw "Unsupported console text character: U+$([int]$Character).ToString('X4')" }
    }
}

