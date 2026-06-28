param(
    [string]$OutFile = '',
    [switch]$OpenInBrowser
)

$ErrorActionPreference = 'Stop'
$repoRoot = $PSScriptRoot

function Get-GitHubHeaders {
    $token = $env:GH_TOKEN
    if ([string]::IsNullOrWhiteSpace($token)) {
        $token = $env:GITHUB_TOKEN
    }
    if ([string]::IsNullOrWhiteSpace($token)) {
        $candidate = $env:CODEX_GITHUB_TOKEN_FILE
        if (![string]::IsNullOrWhiteSpace($candidate) -and (Test-Path -LiteralPath $candidate)) {
            $token = (Get-Content -LiteralPath $candidate -Raw).Trim()
        }
    }

    $headers = @{
        'Accept' = 'application/vnd.github+json'
        'User-Agent' = 'Clipman-CommunitySearch'
    }
    if (![string]::IsNullOrWhiteSpace($token)) {
        $headers['Authorization'] = "Bearer $token"
        $headers['X-GitHub-Api-Version'] = '2022-11-28'
    }
    return $headers
}

function Invoke-GitHubSearch([string]$kind, [string]$query) {
    $encoded = [Uri]::EscapeDataString($query)
    $uri = "https://api.github.com/search/${kind}?q=$encoded&per_page=10"
    try {
        $result = Invoke-RestMethod -Uri $uri -Headers (Get-GitHubHeaders)
        return @($result.items)
    }
    catch {
        return @([pscustomobject]@{
            Error = $_.Exception.Message
            Query = $query
            Kind = $kind
        })
    }
}

function SearchUrl([string]$query) {
    return 'https://www.google.com/search?q=' + [Uri]::EscapeDataString($query)
}

$queries = @(
    '"Clipman" "OnjLouis"',
    '"OnjLouis/Clipman"',
    '"Clipman" "Accessible Clipboard Management Tool"',
    '"Clipman" "Andre Louis" clipboard',
    '"Clipman" "NVDA"',
    '"Clipman" "JAWS"',
    '"Clipman" "screen reader"',
    'site:groups.io "Clipman" "clipboard"',
    'site:freelists.org "Clipman" "clipboard"',
    'site:reddit.com "Clipman" "clipboard manager"',
    'site:forum.audiogames.net "Clipman"',
    'site:applevis.com "Clipman"'
)

$lines = New-Object System.Collections.Generic.List[string]
$lines.Add("# Clipman community search")
$lines.Add("")
$lines.Add("Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
$lines.Add("")
$lines.Add("Purpose: check for public feedback that has not arrived as a GitHub issue. Expect false positives from Linux clipboard managers named clipman and unrelated uses of the word Clipman.")
$lines.Add("")
$lines.Add("## GitHub repository issues")
$repoIssues = Invoke-GitHubSearch 'issues' 'repo:OnjLouis/Clipman is:issue'
if ($repoIssues.Count -eq 0) {
    $lines.Add("- No GitHub issues found by search.")
} else {
    foreach ($item in $repoIssues) {
        if ($item.Error) {
            $lines.Add("- GitHub issue search failed: $($item.Error)")
        } else {
            $lines.Add("- #$($item.number) $($item.title) - $($item.html_url)")
        }
    }
}
$lines.Add("")
$lines.Add("## GitHub public mention search")
$mentionQueries = @(
    '"OnjLouis/Clipman"',
    '"Clipman" "OnjLouis"',
    '"Clipman" "Andre Louis"'
)
foreach ($query in $mentionQueries) {
    $lines.Add("### $query")
    $items = Invoke-GitHubSearch 'issues' $query
    if ($items.Count -eq 0) {
        $lines.Add("- No matching GitHub issues or discussions surfaced through issue search.")
    } else {
        foreach ($item in $items) {
            if ($item.Error) {
                $lines.Add("- Search failed: $($item.Error)")
            } else {
                $lines.Add("- $($item.repository_url -replace '^https://api.github.com/repos/','') #$($item.number) $($item.title) - $($item.html_url)")
            }
        }
    }
    $lines.Add("")
}

$lines.Add("## Web and community searches")
foreach ($query in $queries) {
    $url = SearchUrl $query
    $lines.Add("- $query")
    $lines.Add("  $url")
    if ($OpenInBrowser) {
        Start-Process $url
    }
}
$lines.Add("")
$lines.Add("## What to look for")
$lines.Add("- Accessibility complaints: screen-reader focus, menu behavior, keyboard traps, unannounced states, bad tab order.")
$lines.Add("- Data safety questions: encryption, shared databases, import/export, excluded apps, password manager handling.")
$lines.Add("- Sync/update problems: cloud services, network shares, stale paths, multiple running instances, updater failures.")
$lines.Add("- Clipboard-format gaps: files, HTML, images, audio-editor formats, rich text, URL cleanup, plain-text transforms.")
$lines.Add("- Workflow requests: faster search, pinning, groups, sorting, quick paste/copy shortcuts, startup behavior.")

if ([string]::IsNullOrWhiteSpace($OutFile)) {
    $OutFile = Join-Path $repoRoot 'CommunitySearch.md'
}

$lines | Set-Content -LiteralPath $OutFile -Encoding UTF8
Write-Host "Community search checklist written to $OutFile"
