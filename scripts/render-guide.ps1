#Requires -Version 7.0
<#
.SYNOPSIS
    Renders the approved plan.md of a run as runs/<run-id>/guide.html (CLAUDE.md §8.3).

.DESCRIPTION
    The only writer of guide.html. Approval is enforced by state.ps1, not here:
      1. `state.ps1 start -Step render` refuses unless the approval is valid for exactly the
         current plan (approved, bound to its SHA-256, backed by consumed ledger evidence, no
         integrity violation, no open revision).
      2. This script converts plan.md to self-contained HTML (inline CSS, no scripts, no
         external resources) and writes guide.html atomically. Every piece of plan text is
         HTML-escaped; only http(s) links become anchors.
      3. `state.ps1 complete -Step render` checks the approval again and requires the
         embedded <meta name="plan-sha256"> to equal the approved hash, then records the
         guide's hash and snapshot (versions/render-v<N>.html).
    A plan that changes in between is caught by complete as stale and nothing is accepted.
    Prints state.ps1's JSON result; exit 0 only when the guide was accepted.

.EXAMPLE
    pwsh -NoProfile -File scripts/render-guide.ps1 -RunId <id>
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$RunId,
    [string]$RunsRoot = (Join-Path $PSScriptRoot '..' 'runs'),
    [string]$StateScript = (Join-Path $PSScriptRoot 'state.ps1')
)
$ErrorActionPreference = 'Stop'
if ($RunId -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') { throw "Invalid run id '$RunId'." }
$runDir = Join-Path $RunsRoot $RunId

function Invoke-State([string[]]$Arguments) {
    $output = & pwsh -NoProfile -NonInteractive -File $StateScript @Arguments -RunId $RunId -RunsRoot $RunsRoot 2>&1
    $code = $LASTEXITCODE
    $stdout = ($output | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] }) -join "`n"
    $stderr = (($output | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] }) -join "`n") -replace '\x1b\[[0-9;]*m', ''
    [pscustomobject]@{ ExitCode = $code; Stdout = $stdout; Stderr = $stderr }
}

function Get-Html([string]$Text) { [System.Net.WebUtility]::HtmlEncode($Text) }

# Inline Markdown: `code`, **bold**, [text](http(s) url) and bare http(s) URLs. Everything
# else is text. Each piece is escaped separately; no raw HTML from the plan is ever emitted.
function ConvertTo-InlineHtml([string]$Text) {
    $sb = [System.Text.StringBuilder]::new()
    $pattern = '`([^`]+)`|\[([^\]]+)\]\((https?://[^\s)"<>]+)\)|(https?://[^\s<>()\[\]"`|]+)|\*\*([^*]+)\*\*'
    $pos = 0
    foreach ($m in [regex]::Matches($Text, $pattern)) {
        [void]$sb.Append((Get-Html $Text.Substring($pos, $m.Index - $pos)))
        if ($m.Groups[1].Success) { [void]$sb.Append("<code>$(Get-Html $m.Groups[1].Value)</code>") }
        elseif ($m.Groups[2].Success) { [void]$sb.Append("<a href=`"$(Get-Html $m.Groups[3].Value)`">$(Get-Html $m.Groups[2].Value)</a>") }
        elseif ($m.Groups[4].Success) {
            # Trailing punctuation is not part of the URL (as in state.ps1's URL rules).
            $url = $m.Groups[4].Value.TrimEnd('.', ',', ';', ':', "'")
            [void]$sb.Append("<a href=`"$(Get-Html $url)`">$(Get-Html $url)</a>$(Get-Html $m.Groups[4].Value.Substring($url.Length))")
        }
        else { [void]$sb.Append("<strong>$(Get-Html $m.Groups[5].Value)</strong>") }
        $pos = $m.Index + $m.Length
    }
    [void]$sb.Append((Get-Html $Text.Substring($pos)))
    $sb.ToString()
}

function Get-Slug([string]$Text) { ($Text.ToLowerInvariant() -replace '[^a-z0-9]+', '-').Trim('-') }

function Split-TableRow([string]$Line) {
    $t = $Line.Trim()
    if ($t.StartsWith('|')) { $t = $t.Substring(1) }
    if ($t.EndsWith('|')) { $t = $t.Substring(0, $t.Length - 1) }
    @($t -split '\|' | ForEach-Object { $_.Trim() })
}

# Block Markdown as the study planner writes it: headings, pipe tables, nested lists,
# fenced code, and paragraphs. Returns the body HTML and the section list for navigation.
function ConvertTo-BodyHtml([string[]]$Lines) {
    $html = [System.Text.StringBuilder]::new()
    $sections = [System.Collections.Generic.List[object]]::new()
    $title = $null
    $para = [System.Collections.Generic.List[string]]::new()
    $lists = [System.Collections.Generic.Stack[object]]::new()   # { tag, indent }
    $flushPara = {
        if ($para.Count) { [void]$html.Append("<p>$(ConvertTo-InlineHtml ($para -join ' '))</p>`n"); $para.Clear() }
    }
    $closeLists = { param([int]$ToIndent = -1)
        while ($lists.Count -and $lists.Peek().indent -gt $ToIndent) { [void]$html.Append("</li></$($lists.Pop().tag)>`n") }
    }
    $i = 0
    while ($i -lt $Lines.Count) {
        $line = $Lines[$i]
        if ($line -match '^\s*```') {
            & $flushPara; & $closeLists
            $code = [System.Collections.Generic.List[string]]::new()
            $i++
            while ($i -lt $Lines.Count -and $Lines[$i] -notmatch '^\s*```') { $code.Add($Lines[$i]); $i++ }
            [void]$html.Append("<pre><code>$(Get-Html ($code -join "`n"))</code></pre>`n")
            $i++; continue
        }
        if ($line -match '^(#{1,6})\s+(.+?)\s*#*\s*$') {
            & $flushPara; & $closeLists
            $level = $Matches[1].Length; $text = $Matches[2]
            if ($level -eq 1 -and -not $title) { $title = $text; $i++; continue }
            $id = Get-Slug $text
            if ($level -eq 2) { $sections.Add([pscustomobject]@{ Id = $id; Text = $text }) }
            [void]$html.Append("<h$level id=`"$(Get-Html $id)`">$(ConvertTo-InlineHtml $text)</h$level>`n")
            $i++; continue
        }
        if ($line.TrimStart().StartsWith('|') -and $i + 1 -lt $Lines.Count -and $Lines[$i + 1] -match '^\s*\|?\s*:?-{3,}') {
            & $flushPara; & $closeLists
            $head = Split-TableRow $line
            [void]$html.Append("<div class=`"table`"><table>`n<thead><tr>$(($head | ForEach-Object { "<th>$(ConvertTo-InlineHtml $_)</th>" }) -join '')</tr></thead>`n<tbody>`n")
            $i += 2
            while ($i -lt $Lines.Count -and $Lines[$i].TrimStart().StartsWith('|')) {
                $cells = Split-TableRow $Lines[$i]
                [void]$html.Append("<tr>$(($cells | ForEach-Object { "<td>$(ConvertTo-InlineHtml $_)</td>" }) -join '')</tr>`n")
                $i++
            }
            [void]$html.Append("</tbody></table></div>`n")
            continue
        }
        if ($line -match '^(\s*)([-*]|\d+\.)\s+(.*)$') {
            & $flushPara
            # Take every capture before any other -match: a successful match replaces $Matches.
            $indent = $Matches[1].Length; $marker = $Matches[2]; $text = $Matches[3]
            $tag = if ($marker -match '^\d') { 'ol' } else { 'ul' }
            & $closeLists $indent
            if ($lists.Count -and $lists.Peek().indent -eq $indent -and $lists.Peek().tag -ne $tag) { [void]$html.Append("</li></$($lists.Pop().tag)>`n") }
            if ($lists.Count -and $lists.Peek().indent -eq $indent) { [void]$html.Append("</li>`n<li>") }
            else { [void]$html.Append("<$tag>`n<li>"); $lists.Push([pscustomobject]@{ tag = $tag; indent = $indent }) }
            [void]$html.Append((ConvertTo-InlineHtml $text))
            $i++; continue
        }
        if (-not $line.Trim()) { & $flushPara; & $closeLists; $i++; continue }
        if ($lists.Count -and $line -match '^\s+\S') { [void]$html.Append(' ' + (ConvertTo-InlineHtml $line.Trim())); $i++; continue }
        & $closeLists
        $para.Add($line.Trim())
        $i++
    }
    & $flushPara; & $closeLists
    [pscustomobject]@{ Title = $title; Body = $html.ToString(); Sections = $sections }
}

$css = @'
:root { color-scheme: light dark; --bg: #ffffff; --fg: #1f2328; --muted: #59636e; --line: #d1d9e0; --accent: #0969da; --panel: #f6f8fa; }
@media (prefers-color-scheme: dark) { :root { --bg: #0d1117; --fg: #e6edf3; --muted: #9198a1; --line: #3d444d; --accent: #4493f8; --panel: #151b23; } }
* { box-sizing: border-box; }
body { margin: 0; background: var(--bg); color: var(--fg); font: 16px/1.6 system-ui, -apple-system, "Segoe UI", sans-serif; }
header, main, footer, nav { max-width: 60rem; margin: 0 auto; padding: 0 1rem; }
header { padding-top: 2rem; border-bottom: 1px solid var(--line); }
header h1 { margin: 0 0 .5rem; font-size: 1.8rem; line-height: 1.25; }
.meta { color: var(--muted); font-size: .9rem; margin: 0 0 1rem; }
.meta code { font-size: .85rem; }
nav { padding-top: 1rem; }
nav ul { list-style: none; padding: 0; margin: 0; display: flex; flex-wrap: wrap; gap: .25rem 1rem; }
nav a { font-size: .95rem; }
h2 { margin-top: 2.5rem; padding-bottom: .3rem; border-bottom: 1px solid var(--line); }
h3 { margin-top: 1.75rem; }
a { color: var(--accent); overflow-wrap: anywhere; }
code { font-family: ui-monospace, "Cascadia Mono", Consolas, monospace; background: var(--panel); padding: .1rem .3rem; border-radius: 4px; }
pre { background: var(--panel); padding: 1rem; overflow-x: auto; border-radius: 6px; }
pre code { padding: 0; background: none; }
.table { overflow-x: auto; }
table { border-collapse: collapse; width: 100%; margin: 1rem 0; font-size: .95rem; }
th, td { border: 1px solid var(--line); padding: .4rem .6rem; text-align: left; vertical-align: top; }
th { background: var(--panel); }
li { margin: .2rem 0; }
footer { margin-top: 3rem; padding-bottom: 2rem; border-top: 1px solid var(--line); color: var(--muted); font-size: .85rem; }
'@

# 1. Approval gate (state.ps1): refuses unless the approval matches the current plan exactly.
$start = Invoke-State @('start', '-Step', 'render')
if ($start.ExitCode -ne 0) {
    # PowerShell's error view ends with the exception message, possibly wrapped over several
    # "| ..." lines, after the "~~~~" line that underlines the failing code.
    $errLines = @($start.Stderr -split "`n" | ForEach-Object { ($_ -replace '^\s*(\d+\s*)?\|\s?', '').Trim() } | Where-Object { $_ })
    $underline = -1
    for ($k = 0; $k -lt $errLines.Count; $k++) { if ($errLines[$k] -match '^~+$') { $underline = $k } }
    $reason = if ($underline -ge 0 -and $underline -lt $errLines.Count - 1) { ($errLines[($underline + 1)..($errLines.Count - 1)]) -join ' ' } else { "$($start.Stderr)$($start.Stdout)".Trim() }
    [ordered]@{ run_id = $RunId; result = 'refused'; reason = $reason } | ConvertTo-Json
    exit 1
}

# 2. Render the plan exactly as it is on disk now; its hash goes into the guide.
try {
    $planPath = Join-Path $runDir 'plan.md'
    $planBytes = [System.IO.File]::ReadAllBytes($planPath)
    $planSha = [System.Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData($planBytes)).ToLowerInvariant()
    $planText = [System.Text.UTF8Encoding]::new($false).GetString($planBytes).TrimStart([char]0xFEFF)
    $lines = @($planText -split "`n" | ForEach-Object { $_.TrimEnd("`r") })
    $front = [ordered]@{}
    if ($lines.Count -and $lines[0] -eq '---') {
        $end = [array]::IndexOf($lines, '---', 1)
        if ($end -gt 0) {
            foreach ($l in $lines[1..($end - 1)]) { if ($l -match '^([A-Za-z0-9_]+):\s*(\S.*)$') { $front[$Matches[1]] = $Matches[2].Trim() } }
            $lines = @($lines | Select-Object -Skip ($end + 1))
        }
    }
    $approval = Get-Content -LiteralPath (Join-Path $runDir 'approval.json') -Raw | ConvertFrom-Json -AsHashtable
    $doc = ConvertTo-BodyHtml $lines
    $title = if ($doc.Title) { $doc.Title } else { 'Study Plan' }
    $nav = ($doc.Sections | ForEach-Object { "<li><a href=`"#$(Get-Html $_.Id)`">$(Get-Html $_.Text)</a></li>" }) -join ''
    $metaLine = @("Run <code>$(Get-Html $RunId)</code>", "plan version $(Get-Html "$($approval['plan_version'])")")
    if ($front['planned_hours']) { $metaLine += "$(Get-Html $front['planned_hours']) of $(Get-Html "$($front['budget_hours'])") hours planned" }
    $metaLine += "approved as <code>$(Get-Html "$($approval['decision_id'])")</code> at $(Get-Html "$($approval['decided_at'])")"
    $page = @"
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'">
<meta name="plan-sha256" content="$planSha">
<title>$(Get-Html $title)</title>
<style>
$css</style>
</head>
<body>
<header>
<h1>$(ConvertTo-InlineHtml $title)</h1>
<p class="meta">$($metaLine -join ' &middot; ')</p>
</header>
<nav aria-label="Sections"><ul>$nav</ul></nav>
<main>
$($doc.Body)</main>
<footer>
<p>Rendered from <code>plan.md</code> (SHA-256 <code>$planSha</code>), the plan version the user approved. Sources are the ones cited in the validated research.</p>
</footer>
</body>
</html>
"@
    $guide = Join-Path $runDir 'guide.html'
    $tmp = "$guide.tmp-$([guid]::NewGuid().ToString('N'))"
    try {
        [System.IO.File]::WriteAllText($tmp, $page, [System.Text.UTF8Encoding]::new($false))
        [System.IO.File]::Move($tmp, $guide, $true)
    }
    finally { if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue } }
}
catch {
    # Never leave the step running: record the failed attempt and stop.
    Invoke-State @('fail', '-Step', 'render', '-Reason', "renderer error: $($_.Exception.Message)") | Out-Null
    [ordered]@{ run_id = $RunId; result = 'failed'; reason = "renderer error: $($_.Exception.Message)" } | ConvertTo-Json
    exit 1
}

# 3. Gate and record: approval re-checked, embedded hash verified, output hash recorded.
$complete = Invoke-State @('complete', '-Step', 'render', '-AgentId', 'render-guide.ps1')
if ($complete.Stdout) { $complete.Stdout } else { [ordered]@{ run_id = $RunId; result = 'failed'; reason = $complete.Stderr } | ConvertTo-Json }
exit $complete.ExitCode
