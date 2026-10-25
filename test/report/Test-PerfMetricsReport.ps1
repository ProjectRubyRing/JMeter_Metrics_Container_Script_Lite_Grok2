<#
.SYNOPSIS
    Regression test for report/New-PerfMetricsReport.ps1 (Windows PowerShell 5.1 / PowerShell 7).

.DESCRIPTION
    Runs the report against test/fixtures/perf_sample in several shapes and checks the results:
      1. a perf/ directory                      -> file name has the container / service names
      2. a parent directory with front/back and a duplicate mid/current copy
                                                -> two workbooks, the duplicate is skipped
      3. service / component name variants      -> sf_api / interapi / back are normalized
      4. a .tar made by perf-metrics.sh pack    -> extracted and reported
      5. -From / -To with -UseRecordedTime      -> the period is shown on the summary
      6. every workbook: all parts are well-formed XML, chart formulas and defined names point
         to existing sheets, rows / cells are in order, merged ranges do not overlap
      7. (-Excel) every workbook opens in Excel without a repair log
    This file is ASCII only on purpose (Windows PowerShell 5.1 reads a BOM-less file as ANSI);
    Japanese strings are built from character codes.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\test\report\Test-PerfMetricsReport.ps1 -Excel
#>
[CmdletBinding()]
param([switch]$Excel, [switch]$Keep)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$report = Join-Path $root 'report\New-PerfMetricsReport.ps1'
$fixture = Join-Path $root 'test\fixtures\perf_sample'
$work = Join-Path ([IO.Path]::GetTempPath()) ('perfrpt_test_' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work | Out-Null
$script:pass = 0; $script:fail = 0
function Ok([bool]$cond, [string]$name) {
    if ($cond) { $script:pass++; Write-Host ('  PASS  ' + $name) } else { $script:fail++; Write-Host ('  FAIL  ' + $name) -ForegroundColor Red }
}
$FRONT = -join [char[]](0x30D5, 0x30ED, 0x30F3, 0x30C8, 0x30B3, 0x30F3, 0x30C6, 0x30CA)   # front container
$BACK = -join [char[]](0x30D0, 0x30C3, 0x30AF, 0x30B3, 0x30F3, 0x30C6, 0x30CA)           # back container
$SVC = -join [char[]](0x30B5, 0x30FC, 0x30D3, 0x30B9)                                     # service
$LOGID = '20261024141140-6jlezcax'

function Invoke-Report([string[]]$argv) {
    $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $report @argv 2>&1
    return @{ Code = $LASTEXITCODE; Out = (@($out) -join "`n") }
}
function Copy-Perf([string]$dest, [string]$comp, [string]$svc, [string]$newId) {
    New-Item -ItemType Directory -Force -Path $dest | Out-Null
    Copy-Item -Path (Join-Path $fixture '*') -Destination $dest -Recurse -Force
    $meta = Join-Path $dest 'perf_meta.csv'
    $t = [IO.File]::ReadAllText($meta, (New-Object System.Text.UTF8Encoding($false)))
    $t = $t.Replace('/mnt/logs/front/logs/intra-web/mid/' + $LOGID + '/perf', "/mnt/logs/$comp/logs/$svc/mid/$newId/perf")
    $t = [regex]::Replace($t, '(?m)^container,log_id,.*$', 'container,log_id,"' + $newId + '"')
    [IO.File]::WriteAllText($meta, $t, (New-Object System.Text.UTF8Encoding($false)))
}

# ---- structural check of one .xlsx --------------------------------------------------------
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
function ColNum([string]$c) { $n = 0; foreach ($ch in $c.ToCharArray()) { $n = $n * 26 + ([int]$ch - 64) }; return $n }
function Test-Xlsx([string]$path) {
    $problems = New-Object System.Collections.Generic.List[string]
    $zip = [IO.Compression.ZipFile]::OpenRead($path)
    try {
        $xml = @{}
        foreach ($e in $zip.Entries) {
            if ($e.FullName -notmatch '\.(xml|rels)$') { continue }
            $sr = New-Object IO.StreamReader($e.Open(), [Text.Encoding]::UTF8)
            try { $d = New-Object Xml.XmlDocument; $d.LoadXml($sr.ReadToEnd()); $xml[$e.FullName] = $d } catch { $problems.Add('xml: ' + $e.FullName + ' ' + $_.Exception.Message) } finally { $sr.Dispose() }
        }
        $wb = $xml['xl/workbook.xml']
        $ns = New-Object Xml.XmlNamespaceManager($wb.NameTable)
        $ns.AddNamespace('m', 'http://schemas.openxmlformats.org/spreadsheetml/2006/main')
        $ns.AddNamespace('c', 'http://schemas.openxmlformats.org/drawingml/2006/chart')
        $sheets = @($wb.SelectNodes('//m:sheets/m:sheet', $ns) | ForEach-Object { $_.GetAttribute('name') })
        foreach ($s in $sheets) { if ($s.Length -gt 31 -or $s -match '[\[\]:*?/\\]') { $problems.Add('bad sheet name ' + $s) } }
        foreach ($k in @($xml.Keys | Where-Object { $_ -like 'xl/charts/chart*.xml' })) {
            $cd = $xml[$k]; $cns = New-Object Xml.XmlNamespaceManager($cd.NameTable); $cns.AddNamespace('c', 'http://schemas.openxmlformats.org/drawingml/2006/chart')
            foreach ($f in $cd.SelectNodes('//c:f', $cns)) { $m = [regex]::Match($f.InnerText, "^'(.+)'!"); if ($m.Success -and $sheets -notcontains $m.Groups[1].Value) { $problems.Add('chart ref ' + $f.InnerText) } }
        }
        foreach ($dn in $wb.SelectNodes('//m:definedNames/m:definedName', $ns)) {
            $m = [regex]::Match($dn.InnerText, "^'(.+)'!")
            if ($m.Success -and $sheets[[int]$dn.GetAttribute('localSheetId')] -ne $m.Groups[1].Value) { $problems.Add('defined name ' + $dn.InnerText) }
        }
        for ($i = 1; $i -le $sheets.Count; $i++) {
            $sd = $xml['xl/worksheets/sheet' + $i + '.xml']
            if ($null -eq $sd) { $problems.Add('missing sheet' + $i); continue }
            $sns = New-Object Xml.XmlNamespaceManager($sd.NameTable); $sns.AddNamespace('m', 'http://schemas.openxmlformats.org/spreadsheetml/2006/main')
            $lastR = 0
            foreach ($row in $sd.SelectNodes('//m:sheetData/m:row', $sns)) {
                $rn = [int]$row.GetAttribute('r'); if ($rn -le $lastR) { $problems.Add($sheets[$i - 1] + ' row order ' + $rn) }; $lastR = $rn
                $lastC = 0
                foreach ($c in $row.ChildNodes) {
                    $m = [regex]::Match($c.GetAttribute('r'), '^([A-Z]+)(\d+)$')
                    if ([int]$m.Groups[2].Value -ne $rn) { $problems.Add($sheets[$i - 1] + ' cell row ' + $c.GetAttribute('r')) }
                    $cn = ColNum $m.Groups[1].Value; if ($cn -le $lastC) { $problems.Add($sheets[$i - 1] + ' cell order ' + $c.GetAttribute('r')) }; $lastC = $cn
                }
            }
            $seen = @{}
            foreach ($mc in $sd.SelectNodes('//m:mergeCells/m:mergeCell', $sns)) {
                $p = $mc.GetAttribute('ref').Split(':'); $a = [regex]::Match($p[0], '^([A-Z]+)(\d+)$'); $b = [regex]::Match($p[1], '^([A-Z]+)(\d+)$')
                for ($r = [int]$a.Groups[2].Value; $r -le [int]$b.Groups[2].Value; $r++) {
                    for ($c = (ColNum $a.Groups[1].Value); $c -le (ColNum $b.Groups[1].Value); $c++) { $k = "$r,$c"; if ($seen.ContainsKey($k)) { $problems.Add($sheets[$i - 1] + ' merge overlap ' + $mc.GetAttribute('ref')) }; $seen[$k] = 1 }
                }
            }
        }
        return [pscustomobject]@{ Sheets = $sheets; Charts = @($xml.Keys | Where-Object { $_ -like 'xl/charts/chart*.xml' }).Count; Problems = $problems; Summary = $xml['xl/worksheets/sheet1.xml'].OuterXml }
    } finally { $zip.Dispose() }
}
function Test-Excel([string]$path) {
    $before = @(Get-ChildItem -Path $env:TEMP -Filter 'error*.xml' -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
    $xl = New-Object -ComObject Excel.Application
    $xl.Visible = $false; $xl.DisplayAlerts = $false
    try { $wb = $xl.Workbooks.Open($path, 0, $true); $n = $wb.Worksheets.Count; $wb.Close($false) } finally { $xl.Quit(); [void][Runtime.InteropServices.Marshal]::ReleaseComObject($xl) }
    $after = @(Get-ChildItem -Path $env:TEMP -Filter 'error*.xml' -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
    return [pscustomobject]@{ Sheets = $n; Repaired = (@($after | Where-Object { $before -notcontains $_ }).Count -gt 0) }
}
$created = New-Object System.Collections.Generic.List[string]

try {
    Write-Host '== 1. perf/ directory'
    $o1 = Join-Path $work 'out1'
    $r = Invoke-Report @($fixture, '-OutputPath', $o1)
    $name = 'perf_report_' + $FRONT + '_intra-web' + $SVC + '_' + $LOGID + '.xlsx'
    Ok ($r.Code -eq 0) 'exit code 0'
    Ok (Test-Path -LiteralPath (Join-Path $o1 $name)) ('file name ' + $name)
    $created.Add((Join-Path $o1 $name))

    Write-Host '== 2. parent directory: front + back + duplicate mid/current'
    $tree = Join-Path $work 'tree\logs'
    Copy-Perf (Join-Path $tree "front\logs\intra-web\mid\$LOGID\perf") 'front' 'intra-web' $LOGID
    Copy-Perf (Join-Path $tree 'front\logs\intra-web\mid\current\perf') 'front' 'intra-web' $LOGID
    Copy-Perf (Join-Path $tree "back\logs\intra-api\mid\$LOGID\perf") 'back' 'intra-api' $LOGID
    $o2 = Join-Path $work 'out2'
    $r = Invoke-Report @($tree, '-OutputPath', $o2)
    Ok ($r.Code -eq 0) 'exit code 0'
    $files = @(Get-ChildItem -LiteralPath $o2 -Filter '*.xlsx' | ForEach-Object { $_.Name } | Sort-Object)
    Ok ($files.Count -eq 2) ('two workbooks (' + ($files -join ', ') + ')')
    Ok ($files -contains ('perf_report_' + $BACK + '_intra-api' + $SVC + '_' + $LOGID + '.xlsx')) 'back container / intra-api service'
    Ok ($files -contains ('perf_report_' + $FRONT + '_intra-web' + $SVC + '_' + $LOGID + '.xlsx')) 'front container / intra-web service'
    Ok ($r.Out -match 'current') 'duplicate mid/current copy reported as skipped'
    foreach ($f in $files) { $created.Add((Join-Path $o2 $f)) }

    Write-Host '== 3. name variants (sf_api, interapi, Component_name = <service>-front / -back)'
    $o3 = Join-Path $work 'out3'
    $variants = @(
        @('back', 'sf_api', 'L1', $BACK, 'sf-api'),
        @('front', 'interapi', 'L2', $FRONT, 'inter-api'),
        @('interapi-front', 'interapi', 'L3', $FRONT, 'inter-api'),
        @('sfapi-back', 'sfapi', 'L4', $BACK, 'sf-api'),
        @('intra-api-back', 'intra-api', 'L5', $BACK, 'intra-api')
    )
    foreach ($v in $variants) {
        $p = Join-Path $work ('v\' + $v[2] + '\logs\' + $v[0] + '\logs\' + $v[1] + '\mid\' + $v[2] + '\perf')
        Copy-Perf $p $v[0] $v[1] $v[2]
        [void](Invoke-Report @($p, '-OutputPath', $o3))
        $expect = 'perf_report_' + $v[3] + '_' + $v[4] + $SVC + '_' + $v[2] + '.xlsx'
        Ok (Test-Path -LiteralPath (Join-Path $o3 $expect)) ('/mnt/logs/' + $v[0] + '/logs/' + $v[1] + ' -> ' + $expect)
    }

    Write-Host '== 4. tar archive (perf-metrics.sh pack)'
    $tarDir = Join-Path $work 'tar'; Copy-Perf (Join-Path $tarDir 'perf') 'front' 'intra-web' $LOGID
    $tarExe = Join-Path $env:SystemRoot 'System32\tar.exe'
    $tarFile = Join-Path $work ('perf_' + $LOGID + '_20261024_231417.tar')
    & $tarExe -cf $tarFile -C $tarDir perf
    $o4 = Join-Path $work 'out4\from_tar.xlsx'
    $r = Invoke-Report @($tarFile, '-OutputPath', $o4)
    Ok ($r.Code -eq 0 -and (Test-Path -LiteralPath $o4)) 'report from .tar'
    $created.Add($o4)

    Write-Host '== 5. -From / -To with -UseRecordedTime'
    $o5 = Join-Path $work 'out5\period.xlsx'
    $r = Invoke-Report @($fixture, '-OutputPath', $o5, '-From', '2026-10-24 23:12:00', '-To', '2026-10-24 23:13:30', '-UseRecordedTime')
    Ok ($r.Code -eq 0 -and (Test-Path -LiteralPath $o5)) 'report with period'
    $created.Add($o5)
    $chk = Test-Xlsx $o5
    Ok ($chk.Summary.Contains('-From 2026-10-24 23:12:00 -To 2026-10-24 23:13:30')) 'period shown on the summary'
    Ok ($chk.Summary.Contains('2026/10/24 23:12:00')) 'range starts at -From (recorded time)'

    Write-Host '== 6. workbook structure'
    foreach ($f in $created) {
        $chk = Test-Xlsx $f
        Ok ($chk.Problems.Count -eq 0) ([IO.Path]::GetFileName($f) + ': sheets=' + $chk.Sheets.Count + ' charts=' + $chk.Charts + $(if ($chk.Problems.Count) { ' ' + ($chk.Problems | Select-Object -First 3) -join '; ' } else { '' }))
        Ok ($chk.Sheets.Count -eq 29) 'all 29 sheets present'
    }
    $chk = Test-Xlsx $created[0]
    Ok ($chk.Summary.Contains('-XX:ActiveProcessorCount=1')) 'summary shows the ActiveProcessorCount recommendation'

    if ($Excel) {
        Write-Host '== 7. open in Excel'
        foreach ($f in $created) { $e = Test-Excel $f; Ok ($e.Sheets -eq 29 -and -not $e.Repaired) ([IO.Path]::GetFileName($f) + ' opens without repair') }
    }
} finally {
    if (-not $Keep) { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue } else { Write-Host "kept: $work" }
}
Write-Host ('PASS={0} FAIL={1}' -f $script:pass, $script:fail)
if ($script:fail -gt 0) { exit 1 }
