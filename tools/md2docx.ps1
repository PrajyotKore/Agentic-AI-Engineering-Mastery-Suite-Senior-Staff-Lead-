# Minimal Markdown -> .docx converter (pure PowerShell / OpenXML, no dependencies)
# Supports: # .. #### headings, paragraphs, - / * bullets (2-space nesting), 1. numbered lists,
# ``` code blocks, | tables |, > callouts, **bold**, *italic*, `inline code`, --- page break,
# [TOC] placeholder -> Word TOC field.
param(
    [Parameter(Mandatory = $true)][string]$InputPath,
    [Parameter(Mandatory = $true)][string]$OutputPath,
    [string]$Title = ""
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

function Esc([string]$s) {
    $s = $s -replace '&', '&amp;' -replace '<', '&lt;' -replace '>', '&gt;' -replace '"', '&quot;'
    # strip invalid xml chars
    return ($s -replace '[\x00-\x08\x0B\x0C\x0E-\x1F]', '')
}

function Runs([string]$text, [string]$extraRPr = "") {
    $sb = New-Object System.Text.StringBuilder
    $pattern = '(\*\*[^*]+\*\*|`[^`]+`|\*[^*\s][^*]*\*|\[[^\]]+\]\([^)]+\))'
    $parts = [regex]::Split($text, $pattern)
    foreach ($p in $parts) {
        if ($p -eq '') { continue }
        $rpr = $extraRPr; $t = $p
        if ($p -match '^\*\*(.+)\*\*$') { $t = $matches[1]; $rpr += '<w:b/>' }
        elseif ($p -match '^`(.+)`$') { $t = $matches[1]; $rpr += '<w:rFonts w:ascii="Consolas" w:hAnsi="Consolas" w:cs="Consolas"/><w:color w:val="C7254E"/><w:sz w:val="19"/><w:shd w:val="clear" w:color="auto" w:fill="F3F3F3"/>' }
        elseif ($p -match '^\*([^*].*)\*$') { $t = $matches[1]; $rpr += '<w:i/>' }
        elseif ($p -match '^\[([^\]]+)\]\(([^)]+)\)$') { $t = "$($matches[1]) ($($matches[2]))"; $rpr += '<w:color w:val="1F5FBF"/><w:u w:val="single"/>' }
        [void]$sb.Append("<w:r><w:rPr>$rpr</w:rPr><w:t xml:space=`"preserve`">$(Esc $t)</w:t></w:r>")
    }
    return $sb.ToString()
}

function Para([string]$text, [string]$style = "", [string]$pPrExtra = "", [string]$rPr = "") {
    $ppr = ""
    if ($style) { $ppr += "<w:pStyle w:val=`"$style`"/>" }
    $ppr += $pPrExtra
    return "<w:p><w:pPr>$ppr</w:pPr>$(Runs $text $rPr)</w:p>"
}

$lines = [System.IO.File]::ReadAllLines($InputPath, [System.Text.Encoding]::UTF8)
$body = New-Object System.Text.StringBuilder
$i = 0
$n = $lines.Count

if ($Title) {
    [void]$body.Append((Para $Title "Title"))
    [void]$body.Append((Para "Senior / Staff / Lead Agentic AI Engineer - Study Suite" "Subtitle"))
}

while ($i -lt $n) {
    $line = $lines[$i]
    $trim = $line.Trim()

    if ($trim -eq '') { $i++; continue }

    if ($trim -eq '[TOC]') {
        [void]$body.Append('<w:p><w:pPr><w:pStyle w:val="TOCHeading"/></w:pPr><w:r><w:t>Table of Contents</w:t></w:r></w:p>')
        [void]$body.Append('<w:p><w:r><w:fldChar w:fldCharType="begin" w:dirty="true"/></w:r><w:r><w:instrText xml:space="preserve"> TOC \o "1-3" \h \z \u </w:instrText></w:r><w:r><w:fldChar w:fldCharType="separate"/></w:r><w:r><w:t>Right-click and choose "Update Field" to build the table of contents.</w:t></w:r><w:r><w:fldChar w:fldCharType="end"/></w:r></w:p>')
        [void]$body.Append('<w:p><w:r><w:br w:type="page"/></w:r></w:p>')
        $i++; continue
    }

    if ($trim -eq '---') {
        [void]$body.Append('<w:p><w:r><w:br w:type="page"/></w:r></w:p>'); $i++; continue
    }

    # code block
    if ($trim.StartsWith('```')) {
        $i++
        $code = @()
        while ($i -lt $n -and -not $lines[$i].Trim().StartsWith('```')) { $code += $lines[$i]; $i++ }
        $i++
        foreach ($c in $code) {
            $t = Esc ($c -replace "`t", '    ')
            [void]$body.Append("<w:p><w:pPr><w:pStyle w:val=`"Code`"/></w:pPr><w:r><w:t xml:space=`"preserve`">$t</w:t></w:r></w:p>")
        }
        [void]$body.Append('<w:p><w:pPr><w:spacing w:after="60"/></w:pPr></w:p>')
        continue
    }

    # heading
    if ($trim -match '^(#{1,4})\s+(.*)$') {
        $lvl = $matches[1].Length
        [void]$body.Append((Para $matches[2] "Heading$lvl"))
        $i++; continue
    }

    # callout (blockquote)
    if ($trim.StartsWith('>')) {
        $buf = @()
        while ($i -lt $n -and $lines[$i].Trim().StartsWith('>')) {
            $buf += ($lines[$i].Trim() -replace '^>\s?', ''); $i++
        }
        $kind = 'NOTE'
        if ($buf.Count -gt 0 -and $buf[0] -match '^\[!(\w+)\]\s*(.*)$') {
            $kind = $matches[1].ToUpper(); $rest = $matches[2]
            if ($rest) { $buf[0] = $rest } else { $buf = $buf[1..($buf.Count)] }
        }
        $fill = switch ($kind) { 'WARNING' { 'FFF4E5' } 'CAUTION' { 'FDECEA' } 'TIP' { 'E8F5E9' } 'IMPORTANT' { 'F3E8FD' } default { 'E8F0FE' } }
        $bord = switch ($kind) { 'WARNING' { 'F29900' } 'CAUTION' { 'D93025' } 'TIP' { '1E8E3E' } 'IMPORTANT' { '8430CE' } default { '1A73E8' } }
        $label = switch ($kind) { 'WARNING' { 'PRODUCTION PITFALL' } 'CAUTION' { 'CAUTION' } 'TIP' { 'STAFF-LEVEL TIP' } 'IMPORTANT' { 'KEY INSIGHT' } default { 'NOTE' } }
        $ppr = "<w:pBdr><w:left w:val=`"single`" w:sz=`"24`" w:space=`"8`" w:color=`"$bord`"/></w:pBdr><w:shd w:val=`"clear`" w:color=`"auto`" w:fill=`"$fill`"/><w:spacing w:before=`"0`" w:after=`"0`"/><w:ind w:left=`"200`" w:right=`"200`"/>"
        [void]$body.Append("<w:p><w:pPr>$ppr<w:spacing w:before=`"120`" w:after=`"0`"/></w:pPr><w:r><w:rPr><w:b/><w:color w:val=`"$bord`"/><w:sz w:val=`"18`"/></w:rPr><w:t>$label</w:t></w:r></w:p>")
        foreach ($b in $buf) {
            $bt = $b -replace '^[-*]\s+', ([char]0x2022 + ' ')
            [void]$body.Append((Para $bt "" $ppr))
        }
        [void]$body.Append('<w:p><w:pPr><w:spacing w:after="60"/></w:pPr></w:p>')
        continue
    }

    # table
    if ($trim.StartsWith('|')) {
        $rows = @()
        while ($i -lt $n -and $lines[$i].Trim().StartsWith('|')) { $rows += $lines[$i].Trim(); $i++ }
        $data = @()
        foreach ($r in $rows) {
            if ($r -match '^\|[\s:\-\|]+\|$') { continue }
            $cells = $r.Trim('|').Split('|') | ForEach-Object { $_.Trim() }
            $data += , @($cells)
        }
        if ($data.Count -eq 0) { continue }
        $cols = ($data | ForEach-Object { $_.Count } | Measure-Object -Maximum).Maximum
        $tw = [int](9360 / $cols)
        [void]$body.Append('<w:tbl><w:tblPr><w:tblStyle w:val="TableGrid"/><w:tblW w:w="5000" w:type="pct"/><w:tblBorders><w:top w:val="single" w:sz="4" w:color="BFBFBF"/><w:left w:val="single" w:sz="4" w:color="BFBFBF"/><w:bottom w:val="single" w:sz="4" w:color="BFBFBF"/><w:right w:val="single" w:sz="4" w:color="BFBFBF"/><w:insideH w:val="single" w:sz="4" w:color="BFBFBF"/><w:insideV w:val="single" w:sz="4" w:color="BFBFBF"/></w:tblBorders><w:tblCellMar><w:left w:w="80" w:type="dxa"/><w:right w:w="80" w:type="dxa"/></w:tblCellMar></w:tblPr><w:tblGrid>')
        for ($c = 0; $c -lt $cols; $c++) { [void]$body.Append("<w:gridCol w:w=`"$tw`"/>") }
        [void]$body.Append('</w:tblGrid>')
        for ($r = 0; $r -lt $data.Count; $r++) {
            $hdr = ($r -eq 0)
            [void]$body.Append('<w:tr>')
            if ($hdr) { [void]$body.Append('<w:trPr><w:tblHeader/></w:trPr>') }
            for ($c = 0; $c -lt $cols; $c++) {
                $txt = if ($c -lt $data[$r].Count) { $data[$r][$c] } else { '' }
                $fill = if ($hdr) { '1F3864' } elseif ($r % 2 -eq 0) { 'F2F6FC' } else { 'FFFFFF' }
                $rpr = if ($hdr) { '<w:b/><w:color w:val="FFFFFF"/><w:sz w:val="19"/>' } else { '<w:sz w:val="19"/>' }
                $txt = $txt -replace '<br\s*/?>', ' / '
                [void]$body.Append("<w:tc><w:tcPr><w:tcW w:w=`"$tw`" w:type=`"dxa`"/><w:shd w:val=`"clear`" w:color=`"auto`" w:fill=`"$fill`"/></w:tcPr>$(Para $txt '' '<w:spacing w:before="40" w:after="40"/>' $rpr)</w:tc>")
            }
            [void]$body.Append('</w:tr>')
        }
        [void]$body.Append('</w:tbl><w:p><w:pPr><w:spacing w:after="60"/></w:pPr></w:p>')
        continue
    }

    # bullet list
    if ($line -match '^(\s*)[-*]\s+(.*)$') {
        $lvl = [Math]::Min([int]([Math]::Floor($matches[1].Length / 2)), 3)
        [void]$body.Append((Para $matches[2] "ListBullet" "<w:numPr><w:ilvl w:val=`"$lvl`"/><w:numId w:val=`"1`"/></w:numPr>"))
        $i++; continue
    }

    # numbered list (rendered with literal numbers for robustness)
    if ($line -match '^(\s*)(\d+)[.)]\s+(.*)$') {
        $lvl = [Math]::Min([int]([Math]::Floor($matches[1].Length / 2)), 3)
        $ind = 360 + 360 * $lvl
        [void]$body.Append((Para "$($matches[2]). $($matches[3])" "" "<w:ind w:left=`"$($ind + 280)`" w:hanging=`"280`"/><w:spacing w:after=`"60`"/>"))
        $i++; continue
    }

    # paragraph (merge consecutive plain lines)
    $buf = $trim; $i++
    while ($i -lt $n) {
        $nx = $lines[$i]; $nt = $nx.Trim()
        if ($nt -eq '' -or $nt -match '^(#{1,4}\s|```|>|\||[-*]\s|\d+[.)]\s|---$|\[TOC\])') { break }
        $buf += ' ' + $nt; $i++
    }
    [void]$body.Append((Para $buf))
}

$footer = '<w:sectPr><w:footerReference w:type="default" r:id="rIdFooter"/><w:pgSz w:w="12240" w:h="15840"/><w:pgMar w:top="1300" w:right="1300" w:bottom="1300" w:left="1300" w:header="600" w:footer="600" w:gutter="0"/></w:sectPr>'

$document = @"
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><w:body>$($body.ToString())$footer</w:body></w:document>
"@

$styles = @'
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
<w:docDefaults><w:rPrDefault><w:rPr><w:rFonts w:ascii="Calibri" w:hAnsi="Calibri" w:eastAsia="Calibri" w:cs="Calibri"/><w:sz w:val="22"/><w:szCs w:val="22"/><w:lang w:val="en-US"/></w:rPr></w:rPrDefault><w:pPrDefault><w:pPr><w:spacing w:after="120" w:line="276" w:lineRule="auto"/></w:pPr></w:pPrDefault></w:docDefaults>
<w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/><w:qFormat/></w:style>
<w:style w:type="paragraph" w:styleId="Title"><w:name w:val="Title"/><w:basedOn w:val="Normal"/><w:qFormat/><w:pPr><w:spacing w:before="1800" w:after="200"/><w:jc w:val="center"/></w:pPr><w:rPr><w:rFonts w:ascii="Calibri Light" w:hAnsi="Calibri Light"/><w:b/><w:color w:val="1F3864"/><w:sz w:val="52"/></w:rPr></w:style>
<w:style w:type="paragraph" w:styleId="Subtitle"><w:name w:val="Subtitle"/><w:basedOn w:val="Normal"/><w:qFormat/><w:pPr><w:spacing w:after="600"/><w:jc w:val="center"/></w:pPr><w:rPr><w:i/><w:color w:val="595959"/><w:sz w:val="28"/></w:rPr></w:style>
<w:style w:type="paragraph" w:styleId="Heading1"><w:name w:val="heading 1"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:qFormat/><w:pPr><w:keepNext/><w:pageBreakBefore/><w:pBdr><w:bottom w:val="single" w:sz="12" w:space="4" w:color="2E74B5"/></w:pBdr><w:spacing w:before="240" w:after="200"/><w:outlineLvl w:val="0"/></w:pPr><w:rPr><w:rFonts w:ascii="Calibri Light" w:hAnsi="Calibri Light"/><w:b/><w:color w:val="1F3864"/><w:sz w:val="36"/></w:rPr></w:style>
<w:style w:type="paragraph" w:styleId="Heading2"><w:name w:val="heading 2"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:qFormat/><w:pPr><w:keepNext/><w:spacing w:before="320" w:after="120"/><w:outlineLvl w:val="1"/></w:pPr><w:rPr><w:rFonts w:ascii="Calibri Light" w:hAnsi="Calibri Light"/><w:b/><w:color w:val="2E74B5"/><w:sz w:val="30"/></w:rPr></w:style>
<w:style w:type="paragraph" w:styleId="Heading3"><w:name w:val="heading 3"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:qFormat/><w:pPr><w:keepNext/><w:spacing w:before="240" w:after="80"/><w:outlineLvl w:val="2"/></w:pPr><w:rPr><w:b/><w:color w:val="1F4E79"/><w:sz w:val="26"/></w:rPr></w:style>
<w:style w:type="paragraph" w:styleId="Heading4"><w:name w:val="heading 4"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:qFormat/><w:pPr><w:keepNext/><w:spacing w:before="200" w:after="60"/><w:outlineLvl w:val="3"/></w:pPr><w:rPr><w:b/><w:i/><w:color w:val="404040"/><w:sz w:val="23"/></w:rPr></w:style>
<w:style w:type="paragraph" w:styleId="TOCHeading"><w:name w:val="TOC Heading"/><w:basedOn w:val="Normal"/><w:pPr><w:spacing w:before="240" w:after="200"/></w:pPr><w:rPr><w:b/><w:color w:val="1F3864"/><w:sz w:val="32"/></w:rPr></w:style>
<w:style w:type="paragraph" w:styleId="ListBullet"><w:name w:val="List Bullet"/><w:basedOn w:val="Normal"/><w:pPr><w:spacing w:after="60"/></w:pPr></w:style>
<w:style w:type="paragraph" w:styleId="Code"><w:name w:val="Code"/><w:basedOn w:val="Normal"/><w:pPr><w:shd w:val="clear" w:color="auto" w:fill="F5F5F5"/><w:spacing w:after="0" w:line="240" w:lineRule="auto"/><w:ind w:left="200" w:right="200"/><w:pBdr><w:left w:val="single" w:sz="12" w:space="6" w:color="A6A6A6"/></w:pBdr></w:pPr><w:rPr><w:rFonts w:ascii="Consolas" w:hAnsi="Consolas" w:cs="Consolas"/><w:sz w:val="17"/><w:color w:val="1E1E1E"/></w:rPr></w:style>
<w:style w:type="paragraph" w:styleId="Footer"><w:name w:val="footer"/><w:basedOn w:val="Normal"/><w:pPr><w:jc w:val="center"/></w:pPr><w:rPr><w:color w:val="808080"/><w:sz w:val="18"/></w:rPr></w:style>
<w:style w:type="table" w:styleId="TableGrid"><w:name w:val="Table Grid"/><w:tblPr><w:tblBorders><w:top w:val="single" w:sz="4" w:color="auto"/><w:left w:val="single" w:sz="4" w:color="auto"/><w:bottom w:val="single" w:sz="4" w:color="auto"/><w:right w:val="single" w:sz="4" w:color="auto"/><w:insideH w:val="single" w:sz="4" w:color="auto"/><w:insideV w:val="single" w:sz="4" w:color="auto"/></w:tblBorders></w:tblPr></w:style>
</w:styles>
'@

$numbering = @'
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:numbering xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
<w:abstractNum w:abstractNumId="0"><w:multiLevelType w:val="hybridMultilevel"/>
<w:lvl w:ilvl="0"><w:start w:val="1"/><w:numFmt w:val="bullet"/><w:lvlText w:val="&#8226;"/><w:lvlJc w:val="left"/><w:pPr><w:ind w:left="720" w:hanging="360"/></w:pPr></w:lvl>
<w:lvl w:ilvl="1"><w:start w:val="1"/><w:numFmt w:val="bullet"/><w:lvlText w:val="&#9702;"/><w:lvlJc w:val="left"/><w:pPr><w:ind w:left="1080" w:hanging="360"/></w:pPr></w:lvl>
<w:lvl w:ilvl="2"><w:start w:val="1"/><w:numFmt w:val="bullet"/><w:lvlText w:val="&#9642;"/><w:lvlJc w:val="left"/><w:pPr><w:ind w:left="1440" w:hanging="360"/></w:pPr></w:lvl>
<w:lvl w:ilvl="3"><w:start w:val="1"/><w:numFmt w:val="bullet"/><w:lvlText w:val="-"/><w:lvlJc w:val="left"/><w:pPr><w:ind w:left="1800" w:hanging="360"/></w:pPr></w:lvl>
</w:abstractNum>
<w:num w:numId="1"><w:abstractNumId w:val="0"/></w:num>
</w:numbering>
'@

$footerXml = @"
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:ftr xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:p><w:pPr><w:pStyle w:val="Footer"/></w:pPr><w:r><w:t xml:space="preserve">$(Esc $Title)  |  Page </w:t></w:r><w:r><w:fldChar w:fldCharType="begin"/></w:r><w:r><w:instrText xml:space="preserve"> PAGE </w:instrText></w:r><w:r><w:fldChar w:fldCharType="separate"/></w:r><w:r><w:t>1</w:t></w:r><w:r><w:fldChar w:fldCharType="end"/></w:r></w:p></w:ftr>
"@

$settings = @'
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:settings xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:updateFields w:val="true"/><w:defaultTabStop w:val="720"/></w:settings>
'@

$contentTypes = @'
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/><Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/><Override PartName="/word/numbering.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.numbering+xml"/><Override PartName="/word/settings.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.settings+xml"/><Override PartName="/word/footer1.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.footer+xml"/><Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/></Types>
'@

$rels = @'
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/><Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/></Relationships>
'@

$docRels = @'
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rIdStyles" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/><Relationship Id="rIdNum" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/numbering" Target="numbering.xml"/><Relationship Id="rIdSettings" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/settings" Target="settings.xml"/><Relationship Id="rIdFooter" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/footer" Target="footer1.xml"/></Relationships>
'@

$core = @"
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:dcterms="http://purl.org/dc/terms/" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"><dc:title>$(Esc $Title)</dc:title><dc:creator>Agentic AI Study Suite</dc:creator><dcterms:created xsi:type="dcterms:W3CDTF">$((Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'))</dcterms:created></cp:coreProperties>
"@

if (Test-Path $OutputPath) { Remove-Item $OutputPath -Force }
$dir = Split-Path -Parent $OutputPath
if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
$zip = [System.IO.Compression.ZipFile]::Open($OutputPath, 'Create')
$enc = New-Object System.Text.UTF8Encoding($false)
function AddEntry($name, $content) {
    $e = $zip.CreateEntry($name)
    $s = $e.Open(); $bytes = $enc.GetBytes($content.Trim()); $s.Write($bytes, 0, $bytes.Length); $s.Close()
}
AddEntry '[Content_Types].xml' $contentTypes
AddEntry '_rels/.rels' $rels
AddEntry 'word/_rels/document.xml.rels' $docRels
AddEntry 'word/document.xml' $document
AddEntry 'word/styles.xml' $styles
AddEntry 'word/numbering.xml' $numbering
AddEntry 'word/settings.xml' $settings
AddEntry 'word/footer1.xml' $footerXml
AddEntry 'docProps/core.xml' $core
$zip.Dispose()

# validate XML well-formedness
[xml]$null = $document
Write-Output "OK: $OutputPath"
