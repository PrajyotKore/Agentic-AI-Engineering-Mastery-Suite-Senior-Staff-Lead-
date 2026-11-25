# Modern, responsive Markdown -> HTML converter with full Code & Math (KaTeX + Prism) support
param(
    [Parameter(Mandatory = $true)][string]$InputPath,
    [Parameter(Mandatory = $true)][string]$OutputPath,
    [string]$Title = "",
    [string]$CurrentDoc = ""
)

$ErrorActionPreference = 'Stop'

function EscHtml([string]$s) {
    if ([string]::IsNullOrEmpty($s)) { return "" }
    return $s.Replace('&', '&amp;').Replace('<', '&lt;').Replace('>', '&gt;').Replace('"', '&quot;')
}

# The 10 documents in the suite for global sidebar navigation
$suiteDocs = @(
    @{ Id = "00_Job_Market_Analysis_and_Master_Syllabus"; File = "00_Agentic_AI_Job_Market_Analysis_and_Master_Syllabus.html"; Title = "00. Market Analysis & Syllabus"; Icon = "📊" },
    @{ Id = "01_Agent_Foundations_and_Cognitive_Architectures"; File = "01_Agent_Foundations_and_Cognitive_Architectures.html"; Title = "01. Foundations & Architectures"; Icon = "🧠" },
    @{ Id = "02_Tool_Use_Function_Calling_and_Protocols"; File = "02_Tool_Use_Function_Calling_and_Protocols.html"; Title = "02. Tool Use, MCP & Protocols"; Icon = "🔌" },
    @{ Id = "03_Memory_Context_Engineering_and_Agentic_RAG"; File = "03_Memory_Context_Engineering_and_Agentic_RAG.html"; Title = "03. Memory & Agentic RAG"; Icon = "💾" },
    @{ Id = "04_Multi_Agent_Systems_and_Orchestration"; File = "04_Multi_Agent_Systems_and_Orchestration.html"; Title = "04. Multi-Agent Orchestration"; Icon = "🤖" },
    @{ Id = "05_Evaluation_Observability_and_Reliability"; File = "05_Evaluation_Observability_and_Reliability.html"; Title = "05. Evals & Observability"; Icon = "📈" },
    @{ Id = "06_Security_Guardrails_and_Enterprise_Governance"; File = "06_Security_Guardrails_and_Enterprise_Governance.html"; Title = "06. Security & Governance"; Icon = "🛡️" },
    @{ Id = "07_Production_Architecture_Deployment_and_LLMOps"; File = "07_Production_Architecture_Deployment_and_LLMOps.html"; Title = "07. Production & LLMOps"; Icon = "⚙️" },
    @{ Id = "08_System_Design_Blueprints_and_Case_Studies"; File = "08_System_Design_Blueprints_and_Case_Studies.html"; Title = "08. System Design Case Studies"; Icon = "📐" },
    @{ Id = "09_Agentic_AI_Hard_Question_Bank_and_Solutions"; File = "09_Agentic_AI_Hard_Question_Bank_and_Solutions.html"; Title = "09. Hard Question Bank (120 Qs)"; Icon = "🎯" }
)

$lines = [System.IO.File]::ReadAllLines($InputPath, [System.Text.Encoding]::UTF8)
$htmlBody = New-Object System.Text.StringBuilder
$tocItems = New-Object System.Collections.Generic.List[psobject]

$i = 0
$n = $lines.Count

# Inline markdown formatter that respects code and math
function FormatInline([string]$text) {
    if ([string]::IsNullOrEmpty($text)) { return "" }
    
    # 1. Protect currency dollars: convert literal \$ to HTML entity &#36; so KaTeX doesn't mistake prices for math!
    $text = $text -replace '\\\$', '&#36;'
    
    # 2. Extract and protect display math blocks if any in-line: $$...$$
    $mathTokens = New-Object System.Collections.Generic.List[string]
    $text = [regex]::Replace($text, '(?s)\$\$(.+?)\$\$', {
        param($m)
        $idx = $mathTokens.Count
        $mathTokens.Add("<span class=""math-display"">`$`$$($m.Groups[1].Value)`$`$</span>")
        return "___MATH_DISP_${idx}___"
    })
    
    # 3. Extract and protect inline math: $...$ where not followed/preceded by whitespace or digit
    $text = [regex]::Replace($text, '(?<![\$\w])\$([^\s\$][^\$]*?[^\s\$]|[^\s\$])\$(?![\$\w])', {
        param($m)
        $idx = $mathTokens.Count
        $mathTokens.Add("<span class=""math-inline"">`$$($m.Groups[1].Value)`$</span>")
        return "___MATH_INL_${idx}___"
    })
    
    # 4. Extract inline code `...`
    $codeTokens = New-Object System.Collections.Generic.List[string]
    $text = [regex]::Replace($text, '`([^`]+)`', {
        param($m)
        $idx = $codeTokens.Count
        $codeTokens.Add("<code>$(EscHtml $m.Groups[1].Value)</code>")
        return "___CODE_${idx}___"
    })
    
    # 5. Escape general HTML
    $text = EscHtml $text
    
    # 6. Bold: **text**
    $text = [regex]::Replace($text, '\*\*([^*]+)\*\*', '<strong>$1</strong>')
    
    # 7. Italic: *text*
    $text = [regex]::Replace($text, '(?<!\*)\*([^*]+)\*(?!\*)', '<em>$1</em>')
    
    # 8. Links: [label](url)
    $text = [regex]::Replace($text, '\[([^\]]+)\]\(([^)]+)\)', '<a href="$2" target="_blank" rel="noopener">$1</a>')
    
    # 9. Restore code tokens
    for ($k = 0; $k -lt $codeTokens.Count; $k++) {
        $text = $text.Replace("___CODE_${k}___", $codeTokens[$k])
    }
    
    # 10. Restore math tokens
    for ($k = 0; $k -lt $mathTokens.Count; $k++) {
        $text = $text.Replace("___MATH_DISP_${k}___", $mathTokens[$k])
        $text = $text.Replace("___MATH_INL_${k}___", $mathTokens[$k])
    }
    
    return $text
}

while ($i -lt $n) {
    $line = $lines[$i]
    $trim = $line.Trim()

    if ($trim -eq '' -or $trim -eq '[TOC]') { $i++; continue }

    if ($trim -eq '---') {
        [void]$htmlBody.Append("<hr class=""doc-divider"">`n")
        $i++; continue
    }

    # Display math block: $$ on its own line or $$ ... $$
    if ($trim.StartsWith('$$')) {
        $mathLines = @($line)
        if (-not $trim.EndsWith('$$') -or $trim -eq '$$') {
            $i++
            while ($i -lt $n) {
                $mathLines += $lines[$i]
                if ($lines[$i].Trim().EndsWith('$$')) { $i++; break }
                $i++
            }
        } else {
            $i++
        }
        $mathContent = ($mathLines -join "`n")
        # Preserve currency escapes inside math
        $mathContent = $mathContent -replace '\\\$', '&#36;'
        [void]$htmlBody.Append("<div class=""math-block"">`n$mathContent`n</div>`n")
        continue
    }

    # Code block ```
    if ($trim.StartsWith('```')) {
        $lang = $trim.Substring(3).Trim()
        if ($lang -eq '') { $lang = 'text' }
        $i++
        $code = @()
        while ($i -lt $n -and -not $lines[$i].Trim().StartsWith('```')) {
            $code += $lines[$i]
            $i++
        }
        $i++
        $codeStr = EscHtml ($code -join "`n")
        $headerHtml = "<div class=""code-header""><span class=""code-lang"">$lang</span><button class=""copy-btn"" onclick=""copyCode(this)"">Copy</button></div>"
        [void]$htmlBody.Append("<div class=""code-container"">$headerHtml<pre><code class=""language-$lang"">$codeStr</code></pre></div>`n")
        continue
    }

    # Headings # .. ####
    if ($trim -match '^(#{1,4})\s+(.*)$') {
        $lvl = $matches[1].Length
        $htext = $matches[2]
        # Generate slug id
        $slug = ($htext -replace '[^\w\s-]', '' -replace '\s+', '-').ToLower()
        if ([string]::IsNullOrEmpty($slug)) { $slug = "heading-$i" }
        $slug = "$slug-$i"
        
        $renderedTitle = FormatInline $htext
        if ($lvl -le 3) {
            $tocItems.Add([PSCustomObject]@{ Level = $lvl; Title = $htext; Id = $slug })
        }
        [void]$htmlBody.Append("<h$lvl id=""$slug"" class=""doc-heading doc-h$lvl""><a href=""#$slug"" class=""heading-anchor"">#</a> $renderedTitle</h$lvl>`n")
        $i++; continue
    }

    # Callouts: > [!WARNING], > [!TIP], > [!IMPORTANT], > [!NOTE]
    if ($trim.StartsWith('>')) {
        $cbuf = @()
        while ($i -lt $n -and $lines[$i].Trim().StartsWith('>')) {
            $cbuf += ($lines[$i].Trim() -replace '^>\s?', '')
            $i++
        }
        $kind = 'NOTE'
        if ($cbuf.Count -gt 0 -and $cbuf[0] -match '^\[!(\w+)\]\s*(.*)$') {
            $kind = $matches[1].ToUpper()
            $rest = $matches[2]
            if ($rest) { $cbuf[0] = $rest } else { $cbuf = $cbuf[1..($cbuf.Count)] }
        }
        $icon = switch ($kind) { 'WARNING' { '⚠️' } 'CAUTION' { '🛑' } 'TIP' { '💡' } 'IMPORTANT' { '📌' } default { 'ℹ️' } }
        $calloutTitle = switch ($kind) { 'WARNING' { 'PRODUCTION PITFALL' } 'CAUTION' { 'CAUTION' } 'TIP' { 'STAFF-LEVEL TIP' } 'IMPORTANT' { 'KEY INSIGHT' } default { 'NOTE' } }
        $kindClass = "callout-" + $kind.ToLower()
        
        [void]$htmlBody.Append("<div class=""callout $kindClass"">`n")
        [void]$htmlBody.Append("<div class=""callout-header""><span class=""callout-icon"">$icon</span> <span class=""callout-title"">$calloutTitle</span></div>`n")
        [void]$htmlBody.Append("<div class=""callout-content"">`n")
        foreach ($cb in $cbuf) {
            if ($cb.Trim() -ne '') {
                [void]$htmlBody.Append("<p>$(FormatInline $cb)</p>`n")
            }
        }
        [void]$htmlBody.Append("</div>`n</div>`n")
        continue
    }

    # Tables |
    if ($trim.StartsWith('|')) {
        $rows = @()
        while ($i -lt $n -and $lines[$i].Trim().StartsWith('|')) {
            $rows += $lines[$i].Trim()
            $i++
        }
        $tableData = @()
        foreach ($r in $rows) {
            if ($r -match '^\|[\s:\-\|]+\|$') { continue } # separator line
            $cells = $r.Trim('|').Split('|') | ForEach-Object { $_.Trim() }
            $tableData += , @($cells)
        }
        if ($tableData.Count -gt 0) {
            [void]$htmlBody.Append("<div class=""table-responsive""><table class=""doc-table"">`n")
            # Header
            [void]$htmlBody.Append("<thead><tr>`n")
            foreach ($th in $tableData[0]) {
                [void]$htmlBody.Append("<th>$(FormatInline $th)</th>`n")
            }
            [void]$htmlBody.Append("</tr></thead>`n<tbody>`n")
            # Body rows
            for ($r = 1; $r -lt $tableData.Count; $r++) {
                [void]$htmlBody.Append("<tr>`n")
                foreach ($td in $tableData[$r]) {
                    [void]$htmlBody.Append("<td>$(FormatInline $td)</td>`n")
                }
                [void]$htmlBody.Append("</tr>`n")
            }
            [void]$htmlBody.Append("</tbody></table></div>`n")
        }
        continue
    }

    # Bullet lists - / *
    if ($line -match '^(\s*)[-*]\s+(.*)$') {
        [void]$htmlBody.Append("<ul class=""doc-list"">`n")
        while ($i -lt $n -and $lines[$i] -match '^(\s*)[-*]\s+(.*)$') {
            $indent = $matches[1].Length
            $content = FormatInline $matches[2]
            [void]$htmlBody.Append("<li>$content</li>`n")
            $i++
        }
        [void]$htmlBody.Append("</ul>`n")
        continue
    }

    # Numbered lists 1.
    if ($line -match '^\s*\d+[.)]\s+(.*)$') {
        [void]$htmlBody.Append("<ol class=""doc-list-ordered"">`n")
        while ($i -lt $n -and $lines[$i] -match '^\s*\d+[.)]\s+(.*)$') {
            $content = FormatInline $matches[1]
            [void]$htmlBody.Append("<li>$content</li>`n")
            $i++
        }
        [void]$htmlBody.Append("</ol>`n")
        continue
    }

    # Paragraph: consume consecutive plain text lines
    $pbuf = @($trim)
    $i++
    while ($i -lt $n) {
        $nx = $lines[$i].Trim()
        if ($nx -eq '' -or $nx -match '^(#{1,4}\s|```|>|\||[-*]\s|\d+[.)]\s|---$|\$\$|\[TOC\])') { break }
        $pbuf += $nx
        $i++
    }
    $paraText = ($pbuf -join ' ')
    [void]$htmlBody.Append("<p class=""doc-paragraph"">$(FormatInline $paraText)</p>`n")
}

# Generate in-page TOC HTML
$inPageToc = New-Object System.Text.StringBuilder
[void]$inPageToc.Append("<nav class=""toc-nav""><div class=""toc-header"">On This Page</div><ul class=""toc-list"">`n")
foreach ($item in $tocItems) {
    $indentClass = "toc-level-" + $item.Level
    $escapedTitle = EscHtml $item.Title
    [void]$inPageToc.Append("<li class=""$indentClass""><a href=""#$($item.Id)"">$escapedTitle</a></li>`n")
}
[void]$inPageToc.Append("</ul></nav>`n")

# Generate sidebar navigation links
$sidebarNav = New-Object System.Text.StringBuilder
[void]$sidebarNav.Append("<ul class=""nav-links"">`n")
foreach ($doc in $suiteDocs) {
    $isActive = if ($doc.Id -eq $CurrentDoc) { "active" } else { "" }
    [void]$sidebarNav.Append("<li class=""$isActive""><a href=""$($doc.File)""><span class=""nav-icon"">$($doc.Icon)</span> <span class=""nav-title"">$($doc.Title)</span></a></li>`n")
}
[void]$sidebarNav.Append("</ul>`n")

# Full HTML template
$fullHtml = @"
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>$(EscHtml $Title) | Agentic AI Study Suite</title>
    <!-- Fonts -->
    <link rel="preconnect" href="https://fonts.googleapis.com">
    <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
    <link href="https://fonts.googleapis.com/css2?family=Fira+Code:wght@400;500;600&family=Inter:wght@300;400;500;600;700&display=swap" rel="stylesheet">
    <!-- KaTeX CSS for LaTeX Math Formulas -->
    <link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/katex@0.16.9/dist/katex.min.css">
    <!-- Prism Syntax Highlighting -->
    <link rel="stylesheet" href="https://cdnjs.cloudflare.com/ajax/libs/prism/1.29.0/themes/prism-tomorrow.min.css">
    <style>
        :root {
            --bg-primary: #0f172a;
            --bg-secondary: #1e293b;
            --bg-tertiary: #334155;
            --text-primary: #f8fafc;
            --text-secondary: #94a3b8;
            --text-muted: #64748b;
            --accent: #38bdf8;
            --accent-hover: #0ea5e9;
            --border: #334155;
            --code-bg: #090d16;
            --callout-warn-bg: rgba(245, 158, 11, 0.12);
            --callout-warn-border: #f59e0b;
            --callout-tip-bg: rgba(16, 185, 129, 0.12);
            --callout-tip-border: #10b981;
            --callout-imp-bg: rgba(168, 85, 247, 0.12);
            --callout-imp-border: #a855f7;
            --callout-note-bg: rgba(56, 189, 248, 0.12);
            --callout-note-border: #38bdf8;
            --sidebar-width: 290px;
            --toc-width: 250px;
        }

        body.light-theme {
            --bg-primary: #ffffff;
            --bg-secondary: #f8fafc;
            --bg-tertiary: #f1f5f9;
            --text-primary: #0f172a;
            --text-secondary: #334155;
            --text-muted: #64748b;
            --accent: #0284c7;
            --accent-hover: #0369a1;
            --border: #e2e8f0;
            --code-bg: #1e293b;
            --callout-warn-bg: #fffbeb;
            --callout-tip-bg: #ecfdf5;
            --callout-imp-bg: #faf5ff;
            --callout-note-bg: #f0f9ff;
        }

        * { box-sizing: border-box; margin: 0; padding: 0; }
        body {
            font-family: 'Inter', -apple-system, BlinkMacSystemFont, sans-serif;
            background-color: var(--bg-primary);
            color: var(--text-primary);
            line-height: 1.68;
            font-size: 15px;
            display: flex;
            min-height: 100vh;
        }

        /* Sidebar */
        aside.sidebar {
            width: var(--sidebar-width);
            background-color: var(--bg-secondary);
            border-right: 1px solid var(--border);
            height: 100vh;
            position: fixed;
            top: 0;
            left: 0;
            overflow-y: auto;
            display: flex;
            flex-direction: column;
            z-index: 100;
        }
        .sidebar-header {
            padding: 20px 18px;
            border-bottom: 1px solid var(--border);
        }
        .sidebar-header h2 {
            font-size: 15px;
            font-weight: 700;
            color: var(--accent);
            display: flex;
            align-items: center;
            gap: 8px;
            letter-spacing: -0.3px;
        }
        .sidebar-header p {
            font-size: 11px;
            color: var(--text-muted);
            margin-top: 4px;
            text-transform: uppercase;
            letter-spacing: 0.5px;
            font-weight: 600;
        }
        .sidebar-search {
            padding: 12px 18px;
            border-bottom: 1px solid var(--border);
        }
        .sidebar-search input {
            width: 100%;
            padding: 7px 12px;
            background: var(--bg-tertiary);
            border: 1px solid var(--border);
            border-radius: 6px;
            color: var(--text-primary);
            font-size: 13px;
            outline: none;
        }
        .sidebar-search input:focus {
            border-color: var(--accent);
        }
        nav.nav-container {
            padding: 12px 8px;
            flex: 1;
        }
        .nav-links { list-style: none; }
        .nav-links li { margin-bottom: 3px; }
        .nav-links a {
            display: flex;
            align-items: center;
            gap: 10px;
            padding: 8px 12px;
            color: var(--text-secondary);
            text-decoration: none;
            border-radius: 6px;
            font-size: 13px;
            font-weight: 500;
            transition: all 0.15s ease;
        }
        .nav-links a:hover {
            background-color: var(--bg-tertiary);
            color: var(--text-primary);
        }
        .nav-links li.active a {
            background-color: rgba(56, 189, 248, 0.15);
            color: var(--accent);
            font-weight: 600;
        }
        .sidebar-footer {
            padding: 14px 18px;
            border-top: 1px solid var(--border);
            display: flex;
            align-items: center;
            justify-content: space-between;
            font-size: 12px;
            color: var(--text-muted);
        }
        .theme-toggle {
            background: none;
            border: 1px solid var(--border);
            color: var(--text-secondary);
            padding: 4px 8px;
            border-radius: 4px;
            cursor: pointer;
            font-size: 12px;
        }

        /* Main Content Layout */
        main.main-wrapper {
            margin-left: var(--sidebar-width);
            flex: 1;
            display: flex;
            justify-content: center;
            padding: 40px 48px 80px 48px;
            max-width: 1500px;
        }
        article.content-area {
            flex: 1;
            max-width: 860px;
            min-width: 0;
        }

        /* In-Page TOC (Right rail) */
        aside.toc-rail {
            width: var(--toc-width);
            margin-left: 40px;
            position: sticky;
            top: 40px;
            max-height: calc(100vh - 80px);
            overflow-y: auto;
            font-size: 12px;
            border-left: 1px solid var(--border);
            padding-left: 16px;
            display: none;
        }
        @media (min-width: 1240px) {
            aside.toc-rail { display: block; }
        }
        .toc-header {
            font-weight: 700;
            text-transform: uppercase;
            letter-spacing: 0.5px;
            color: var(--text-muted);
            margin-bottom: 12px;
            font-size: 11px;
        }
        .toc-list { list-style: none; }
        .toc-list li { margin-bottom: 6px; }
        .toc-list a {
            color: var(--text-muted);
            text-decoration: none;
            display: block;
            line-height: 1.4;
            transition: color 0.15s;
        }
        .toc-list a:hover { color: var(--accent); }
        .toc-level-1 { font-weight: 600; color: var(--text-secondary); }
        .toc-level-2 { padding-left: 10px; }
        .toc-level-3 { padding-left: 20px; font-size: 11px; }

        /* Typography */
        h1.doc-title {
            font-size: 32px;
            font-weight: 800;
            line-height: 1.25;
            letter-spacing: -0.7px;
            margin-bottom: 12px;
            color: var(--text-primary);
        }
        .doc-subtitle {
            font-size: 14px;
            color: var(--accent);
            font-weight: 600;
            text-transform: uppercase;
            letter-spacing: 0.5px;
            margin-bottom: 24px;
            padding-bottom: 16px;
            border-bottom: 1px solid var(--border);
        }
        .doc-heading {
            color: var(--text-primary);
            font-weight: 700;
            letter-spacing: -0.4px;
            position: relative;
        }
        .doc-h1 { font-size: 24px; margin-top: 48px; margin-bottom: 18px; padding-bottom: 8px; border-bottom: 1px solid var(--border); }
        .doc-h2 { font-size: 19px; margin-top: 36px; margin-bottom: 14px; color: var(--accent); }
        .doc-h3 { font-size: 16px; margin-top: 26px; margin-bottom: 10px; }
        .doc-h4 { font-size: 14px; margin-top: 20px; margin-bottom: 8px; color: var(--text-secondary); }
        .heading-anchor {
            position: absolute;
            left: -18px;
            color: var(--text-muted);
            opacity: 0;
            text-decoration: none;
            font-weight: 400;
        }
        .doc-heading:hover .heading-anchor { opacity: 0.8; }
        p.doc-paragraph { margin-bottom: 16px; color: var(--text-secondary); }
        strong { color: var(--text-primary); font-weight: 600; }
        a { color: var(--accent); text-decoration: none; }
        a:hover { text-decoration: underline; }
        hr.doc-divider { border: 0; border-top: 1px solid var(--border); margin: 36px 0; }

        /* Lists */
        ul.doc-list, ol.doc-list-ordered {
            margin-bottom: 18px;
            padding-left: 24px;
            color: var(--text-secondary);
        }
        ul.doc-list li, ol.doc-list-ordered li { margin-bottom: 6px; }

        /* Code Blocks */
        .code-container {
            background-color: var(--code-bg);
            border: 1px solid var(--border);
            border-radius: 8px;
            margin: 20px 0;
            overflow: hidden;
        }
        .code-header {
            background-color: rgba(255, 255, 255, 0.03);
            border-bottom: 1px solid var(--border);
            padding: 6px 14px;
            display: flex;
            justify-content: space-between;
            align-items: center;
            font-size: 11px;
            font-family: 'Fira Code', monospace;
            color: var(--text-muted);
            text-transform: uppercase;
            font-weight: 600;
        }
        .copy-btn {
            background: rgba(255, 255, 255, 0.06);
            border: 1px solid var(--border);
            border-radius: 4px;
            color: var(--text-secondary);
            font-size: 11px;
            padding: 2px 8px;
            cursor: pointer;
            transition: all 0.15s;
        }
        .copy-btn:hover {
            background: var(--accent);
            color: #000;
            border-color: var(--accent);
        }
        pre {
            padding: 16px;
            overflow-x: auto;
            font-family: 'Fira Code', Consolas, Monaco, monospace;
            font-size: 13px;
            line-height: 1.6;
        }
        code {
            font-family: 'Fira Code', Consolas, Monaco, monospace;
            font-size: 13px;
        }
        p code, li code, td code {
            background-color: var(--bg-tertiary);
            color: #f43f5e;
            padding: 2px 6px;
            border-radius: 4px;
            font-size: 12.5px;
            border: 1px solid rgba(255, 255, 255, 0.05);
        }

        /* Callouts */
        .callout {
            border-left: 4px solid;
            border-radius: 6px;
            padding: 16px 18px;
            margin: 22px 0;
            font-size: 14px;
        }
        .callout-header {
            display: flex;
            align-items: center;
            gap: 8px;
            font-weight: 700;
            margin-bottom: 8px;
            letter-spacing: 0.3px;
        }
        .callout-warning { background-color: var(--callout-warn-bg); border-color: var(--callout-warn-border); }
        .callout-warning .callout-title { color: var(--callout-warn-border); }
        .callout-tip { background-color: var(--callout-tip-bg); border-color: var(--callout-tip-border); }
        .callout-tip .callout-title { color: var(--callout-tip-border); }
        .callout-important { background-color: var(--callout-imp-bg); border-color: var(--callout-imp-border); }
        .callout-important .callout-title { color: var(--callout-imp-border); }
        .callout-note { background-color: var(--callout-note-bg); border-color: var(--callout-note-border); }
        .callout-note .callout-title { color: var(--callout-note-border); }
        .callout-content p { margin-bottom: 6px; color: var(--text-secondary); }
        .callout-content p:last-child { margin-bottom: 0; }

        /* Tables */
        .table-responsive {
            overflow-x: auto;
            margin: 24px 0;
            border: 1px solid var(--border);
            border-radius: 8px;
        }
        table.doc-table {
            width: 100%;
            border-collapse: collapse;
            font-size: 13.5px;
            text-align: left;
        }
        table.doc-table th {
            background-color: var(--bg-secondary);
            color: var(--text-primary);
            font-weight: 600;
            padding: 11px 14px;
            border-bottom: 1px solid var(--border);
            white-space: nowrap;
        }
        table.doc-table td {
            padding: 10px 14px;
            border-bottom: 1px solid var(--border);
            color: var(--text-secondary);
            line-height: 1.5;
        }
        table.doc-table tr:nth-child(even) { background-color: rgba(255, 255, 255, 0.015); }
        table.doc-table tr:hover { background-color: rgba(255, 255, 255, 0.03); }

        /* Math Styling */
        .math-block {
            overflow-x: auto;
            padding: 14px 18px;
            background-color: var(--bg-secondary);
            border: 1px solid var(--border);
            border-radius: 8px;
            margin: 20px 0;
            text-align: center;
        }
        .math-display {
            display: block;
            margin: 12px 0;
            overflow-x: auto;
        }

        /* Footer */
        .doc-footer {
            margin-top: 60px;
            padding-top: 24px;
            border-top: 1px solid var(--border);
            display: flex;
            justify-content: space-between;
            align-items: center;
            font-size: 13px;
            color: var(--text-muted);
        }
    </style>
</head>
<body>
    <!-- Left Navigation Sidebar -->
    <aside class="sidebar">
        <div class="sidebar-header">
            <a href="../index.html" style="text-decoration:none; color:inherit;">
                <h2>⚡ Agentic AI Suite</h2>
                <p>Senior · Staff · Lead Mastery &larr; Home</p>
            </a>
        </div>
        <div class="sidebar-search">
            <input type="text" id="searchInput" placeholder="Filter volumes..." onkeyup="filterNav()">
        </div>
        <nav class="nav-container">
            <ul class="nav-links">
                <li><a href="../index.html"><span class="nav-icon">🏠</span> <span class="nav-title">Home Portal</span></a></li>
            </ul>
            $($sidebarNav.ToString())
        </nav>
        <div class="sidebar-footer">
            <span>Suite v2.5</span>
            <button class="theme-toggle" onclick="toggleTheme()">🌓 Theme</button>
        </div>
    </aside>

    <!-- Main Content Area -->
    <main class="main-wrapper">
        <article class="content-area">
            <div class="doc-header">
                <div class="doc-subtitle">Senior / Staff / Lead Agentic AI Engineer Study Suite</div>
                <h1 class="doc-title">$(EscHtml $Title)</h1>
            </div>

            $($htmlBody.ToString())

            <div class="doc-footer">
                <span>Agentic AI Study Material · Production Engineering</span>
                <a href="#top">↑ Back to top</a>
            </div>
        </article>

        <!-- Right In-Page TOC Rail -->
        <aside class="toc-rail">
            $($inPageToc.ToString())
        </aside>
    </main>

    <!-- KaTeX Scripts for Mathematical Rendering -->
    <script defer src="https://cdn.jsdelivr.net/npm/katex@0.16.9/dist/katex.min.js"></script>
    <script defer src="https://cdn.jsdelivr.net/npm/katex@0.16.9/dist/contrib/auto-render.min.js"></script>
    <!-- Prism Syntax Highlighting -->
    <script src="https://cdnjs.cloudflare.com/ajax/libs/prism/1.29.0/prism.min.js"></script>
    <script src="https://cdnjs.cloudflare.com/ajax/libs/prism/1.29.0/components/prism-python.min.js"></script>
    <script src="https://cdnjs.cloudflare.com/ajax/libs/prism/1.29.0/components/prism-json.min.js"></script>
    <script src="https://cdnjs.cloudflare.com/ajax/libs/prism/1.29.0/components/prism-bash.min.js"></script>
    <script src="https://cdnjs.cloudflare.com/ajax/libs/prism/1.29.0/components/prism-sql.min.js"></script>

    <script>
        document.addEventListener("DOMContentLoaded", function() {
            // Render Math with KaTeX
            if (typeof renderMathInElement !== 'undefined') {
                renderMathInElement(document.body, {
                    delimiters: [
                        {left: '$$', right: '$$', display: true},
                        {left: '$', right: '$', display: false},
                        {left: '\\(', right: '\\)', display: false},
                        {left: '\\[', right: '\\]', display: true}
                    ],
                    throwOnError: false,
                    ignoredTags: ["script", "noscript", "style", "textarea", "pre", "code"]
                });
            }
        });

        // Copy Code Functionality
        function copyCode(button) {
            const pre = button.parentElement.nextElementSibling;
            const code = pre.querySelector('code').innerText;
            navigator.clipboard.writeText(code).then(() => {
                const originalText = button.innerText;
                button.innerText = 'Copied!';
                button.style.background = '#10b981';
                button.style.color = '#fff';
                setTimeout(() => {
                    button.innerText = originalText;
                    button.style.background = '';
                    button.style.color = '';
                }, 2000);
            });
        }

        // Filter Nav Links in Sidebar
        function filterNav() {
            const input = document.getElementById('searchInput');
            const filter = input.value.toLowerCase();
            const lis = document.querySelectorAll('.nav-links li');
            lis.forEach(li => {
                const text = li.innerText.toLowerCase();
                if (text.includes(filter)) {
                    li.style.display = '';
                } else {
                    li.style.display = 'none';
                }
            });
        }

        // Theme Toggle (Dark/Light)
        function toggleTheme() {
            document.body.classList.toggle('light-theme');
            const isLight = document.body.classList.contains('light-theme');
            localStorage.setItem('agentic_study_theme', isLight ? 'light' : 'dark');
        }
        if (localStorage.getItem('agentic_study_theme') === 'light') {
            document.body.classList.add('light-theme');
        }
    </script>
</body>
</html>
"@

$dir = Split-Path -Parent $OutputPath
if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
[System.IO.File]::WriteAllText($OutputPath, $fullHtml, [System.Text.Encoding]::UTF8)
Write-Output "OK: $OutputPath"
