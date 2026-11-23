#Requires -Version 7.0
# Guard for the "no company, lab or hardware name" tests (D129). The words and serial numbers that must never appear in a shipped
# file are kept only as the first 16 hex digits of their SHA-256 (of the lower-case text), so the guard itself names none of them.
# Find-AzlForbiddenToken returns every letter-and-digit run of the text (or a part of one) whose hash is on the list.
# Dot-source it: . (Join-Path $PSScriptRoot '..\fixtures\ForbiddenTokens.ps1')

$script:AzlForbiddenTokenHash = @{
    '9946829169d25843' = 'company name'
    '13c2755561067d5d' = 'lab name'
    '066e16acad321bee' = 'department name'
    '69d5243d139fd1cc' = 'private tenant name'
    '485f35493e6e3652' = 'lab server serial'
    'e8773e1d4ad7d311' = 'lab server serial'
    '5360b5ae328de732' = 'lab server serial'
    '4bb94ba585b123a3' = 'lab part number'
    '8edf0c5c1666f4a0' = 'lab part number'
    '2695fca85d819bcc' = 'lab part number'
    '984f7b4489f974f9' = 'lab domain name'
    '9d9a56afc96e056f' = 'lab domain name'
    '902096341b845150' = 'lab domain name'
    '15560a4f14a9096a' = 'personal account name'
    'cfa744f35fd5dcc4' = 'test probe'
}
# The lengths of the listed words: only parts of these lengths are hashed.
$script:AzlForbiddenTokenLength = @(5, 6, 7, 8, 9, 15)

function Find-AzlForbiddenToken {
    [CmdletBinding()]
    [OutputType([string[]])]
    param([AllowEmptyString()][AllowNull()][string]$Text, [switch]$WholeOnly)
    if (-not $Text) { return @() }
    $lower = $Text.ToLowerInvariant()
    # The candidates, each once: whole dotted or hyphenated names and every dot suffix of them (a domain), whole words of any length, and,
    # unless -WholeOnly, every part of a word that has the length of a listed word (a listed word inside a longer one).
    $candidates = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($m in [regex]::Matches($lower, '[a-z0-9]+(?:[.-][a-z0-9]+)*')) {
        $labels = $m.Value -split '\.'
        for ($i = 0; $i -lt $labels.Count; $i++) { $null = $candidates.Add(($labels[$i..($labels.Count - 1)]) -join '.') }
        foreach ($w in ($m.Value -split '[.-]')) {
            $null = $candidates.Add($w)
            if ($WholeOnly) { continue }
            foreach ($len in $script:AzlForbiddenTokenLength) {
                for ($j = 0; $j + $len -le $w.Length; $j++) { $null = $candidates.Add($w.Substring($j, $len)) }
            }
        }
    }
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $hits = [System.Collections.Generic.HashSet[string]]::new()
        foreach ($c in $candidates) {
            $hash = [Convert]::ToHexString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($c))).Substring(0, 16).ToLowerInvariant()
            if ($script:AzlForbiddenTokenHash.ContainsKey($hash)) { $null = $hits.Add("$($script:AzlForbiddenTokenHash[$hash]) ($hash)") }
        }
        return @($hits)
    }
    finally { $sha.Dispose() }
}
