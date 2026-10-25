<#
.SYNOPSIS
    perf-metrics.sh (性能試験用メトリクス収集) が出力した perf/ ディレクトリを、
    モノトーンの Excel レポート (.xlsx) に変換します (Windows 11 / Windows PowerShell 5.1・PowerShell 7)。

.DESCRIPTION
    ① jboss-cli (DB 接続プール・HTTP・セッション・スレッドプール・IO ワーカー・トランザクション・JVM)
    ② jstat / jcmd / JFR (ヒープ・GC・コードキャッシュ・ネイティブメモリ・スレッド状態・GC 停止・ロック競合)
    ③ top / ps / proc (プロセス・スレッド別 CPU・JBoss のスレッド用途別 CPU・FD・TCP)
    ④ -XX:ActiveProcessorCount の要否 (判定結果と根拠・CPU の待ち・steal)
    の CSV を読み込み、サマリー・グラフ・各データのシートを持つブックを作成します。

    ・出力ファイル名には、ログの出力先 (/mnt/logs/<front|back>/logs/<サービス>/mid/...) から
      「フロントコンテナ / バックコンテナ」と「intra-webサービス / intra-apiサービス / inter-apiサービス / sf-apiサービス」を入れます。
        例: perf_report_フロントコンテナ_intra-webサービス_20261024141140-6jlezcax.xlsx
    ・フォント Meiryo UI、黒・グレーのモノトーン。グラフは線の種類で系列を区別します。
    ・Excel のインストールは不要です (Office Open XML を直接生成します)。
    ・時刻は既定で「この PC のタイムゾーン」に換算して表示します (JMeter の結果と突き合わせやすくするため)。
      コンテナで記録した時刻のまま表示する場合は -UseRecordedTime を指定します。

    ※ 保存時の文字コードは UTF-8 (BOM 付き・なしのどちらでも可) または ANSI (Shift_JIS) で動作します。

.PARAMETER InputPath
    次のいずれか
      ・perf/ ディレクトリ (perf_meta.csv・cli_datasource.csv・jvm_jstat_gc.csv などを含む)
      ・その親ディレクトリ (mid/ や logs/ など)。下にある perf/ をすべて探し、1 つずつブックを作成します
      ・perf-metrics.sh pack で作った .tar / .tar.gz、または perf/ を固めた .zip

.PARAMETER OutputPath
    出力先のディレクトリ (無ければ作成し、その中に perf_report_<コンテナ>_<サービス>_<LOG_ID>.xlsx を作成)。
    .xlsx で終わるパスを指定すると、そのファイル名で作成します (perf/ が 1 つのときだけ)。
    省略時はカレントディレクトリに作成します。

.PARAMETER Title
    レポートのタイトル (既定: 性能試験メトリクス レポート)。

.PARAMETER From
    この時刻以降のデータだけを使います (例: "2026-10-20 13:00")。JMeter の実行時間帯に絞るときに指定します。

.PARAMETER To
    この時刻以前のデータだけを使います。

.PARAMETER UseRecordedTime
    時刻を PC のタイムゾーンに換算せず、コンテナで記録した時刻 (perf_meta.csv の utc_offset) のまま表示します。

.PARAMETER ConvertJfr
    perf/jfr/ の .jfr を、この PC の JDK (17 以降) で CSV に変換してから読み込みます
    (コンテナで perf-metrics.sh jfr-csv を実行していない場合)。変換結果は一時ディレクトリに置き、入力は変更しません。

.PARAMETER JavaPath
    -ConvertJfr で使う java.exe (省略時は JAVA_HOME、PATH の順に探します)。

.PARAMETER MaxRows
    1 シートの最大行数 (既定: 200000)。超えた分は CSV を参照してください。

.PARAMETER Open
    作成後に Excel で開きます。

.EXAMPLE
    .\New-PerfMetricsReport.ps1 -InputPath .\perf

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\New-PerfMetricsReport.ps1 .\perf_20261024141140-6jlezcax_20261024_231417.tar -From "2026-10-24 23:12" -To "2026-10-24 23:14" -Open

.EXAMPLE
    .\New-PerfMetricsReport.ps1 \\fileserver\efs-copy\logs -OutputPath .\reports
#>
#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)][string]$InputPath,
    [Parameter(Position = 1)][string]$OutputPath = '',
    [string]$Title = '',
    [string]$From = '',
    [string]$To = '',
    [switch]$UseRecordedTime,
    [switch]$ConvertJfr,
    [string]$JavaPath = '',
    [int]$MaxRows = 200000,
    [switch]$Open
)

#------------------------------------------------------------------------------
# Bootstrap (ASCII only).
# Windows PowerShell 5.1 reads a .ps1 saved without a BOM in the ANSI code page
# (CP932 on Japanese Windows) and the Japanese text in the program would break it.
# The program is therefore kept in the block comment below and is read back from
# this file with the right encoding: UTF-8 (with or without BOM), otherwise ANSI.
#------------------------------------------------------------------------------
if (-not $PSCommandPath) { throw 'Run this script from a saved .ps1 file (e.g. powershell -ExecutionPolicy Bypass -File .\New-PerfMetricsReport.ps1 ...).' }
try {
    $BootText = [IO.File]::ReadAllText($PSCommandPath, (New-Object System.Text.UTF8Encoding($false, $true)))
} catch {
    $BootText = [IO.File]::ReadAllText($PSCommandPath, [System.Text.Encoding]::Default)
}
$BootMain = [regex]::Match($BootText, '(?s)<#PERFRPT-MAIN\r?\n(.*?)\r?\nPERFRPT-MAIN#>')
if (-not $BootMain.Success) { throw 'The program block (<#PERFRPT-MAIN ... PERFRPT-MAIN#>) was not found. Copy the whole script again.' }
& ([ScriptBlock]::Create($BootMain.Groups[1].Value)) @PSBoundParameters
return

<#PERFRPT-MAIN
[CmdletBinding()]
param(
    [string]$InputPath,
    [string]$OutputPath = '',
    [string]$Title = '',
    [string]$From = '',
    [string]$To = '',
    [switch]$UseRecordedTime,
    [switch]$ConvertJfr,
    [string]$JavaPath = '',
    [int]$MaxRows = 200000,
    [switch]$Open
)
if (-not $Title) { $Title = '性能試験メトリクス レポート' }
$ErrorActionPreference = 'Stop'
$Version = '3.0.0'
# perf-metrics.sh 3.0.0 が perf/jfr/ に書く PerfJfrCsv.java の SHA-256 (-ConvertJfr で実行してよいものか確かめる)
$JfrJavaSha256 = @('FF12E2218FF562D8E4F849FF0C749A757FC7E334F068121A845CC4A8BA5CCA7A')
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

$Inv = [Globalization.CultureInfo]::InvariantCulture
$Utf8 = New-Object System.Text.UTF8Encoding($false)
$XmlNeedRe = [regex]'[&<>"\x01-\x08\x0B\x0C\x0E-\x1F]'
$CtlRe = [regex]'[\x01-\x08\x0B\x0C\x0E-\x1F]'

function Write-Info([string]$Message) { Write-Host ('[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss'), $Message) }

#------------------------------------------------------------------------------
# スタイル (styles.xml の cellXfs の並び)
#------------------------------------------------------------------------------
$S_TITLE = 1; $S_NOTE = 2; $S_SEC = 3; $S_HDR = 4; $S_TEXT = 5; $S_TEXTC = 6; $S_INT = 7; $S_DEC1 = 8; $S_DEC2 = 9
$S_PCT = 10; $S_DT = 11; $S_KEY = 12; $S_SEVH = 13; $S_SEVM = 14; $S_SEVL = 15; $S_WRAP = 16; $S_BAND = 17; $S_MUTED = 18
$S_DEC3 = 19; $S_TEXTB = 20; $S_NOTEW = 21; $S_DEC1B = 22; $S_INTB = 23; $S_COLKEY = 24; $S_HEAD = 25; $S_PCTB = 26
$S_BIG = 27; $S_WRAPB = 28; $S_DEC2B = 29
$FMTS = @{ text = $S_TEXT; textc = $S_TEXTC; wrap = $S_WRAP; int = $S_INT; dec1 = $S_DEC1; dec2 = $S_DEC2; dec3 = $S_DEC3; pct = $S_PCT; dt = $S_DT }
# 値を丸める桁数 (ファイルを小さくするため。表示は書式に従う)
$ROUND = @{ int = 0; dec1 = 2; dec2 = 3; dec3 = 4; pct = 4 }
$NS = 'xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"'
$FONT = '<a:latin typeface="Meiryo UI"/><a:ea typeface="Meiryo UI"/><a:cs typeface="Meiryo UI"/>'

$StylesXml = @'
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><numFmts count="6">
<numFmt numFmtId="164" formatCode="yyyy/mm/dd hh:mm:ss"/>
<numFmt numFmtId="165" formatCode="yyyy/mm/dd hh:mm"/>
<numFmt numFmtId="166" formatCode="#,##0.0"/>
<numFmt numFmtId="167" formatCode="0.0%"/>
<numFmt numFmtId="170" formatCode="#,##0.00"/>
<numFmt numFmtId="171" formatCode="#,##0.000"/>
</numFmts>
<fonts count="9">
<font><sz val="10"/><color rgb="FF000000"/><name val="Meiryo UI"/><family val="3"/><charset val="128"/></font>
<font><b/><sz val="10"/><color rgb="FF000000"/><name val="Meiryo UI"/><family val="3"/><charset val="128"/></font>
<font><b/><sz val="10"/><color rgb="FFFFFFFF"/><name val="Meiryo UI"/><family val="3"/><charset val="128"/></font>
<font><b/><sz val="16"/><color rgb="FF000000"/><name val="Meiryo UI"/><family val="3"/><charset val="128"/></font>
<font><sz val="9"/><color rgb="FF595959"/><name val="Meiryo UI"/><family val="3"/><charset val="128"/></font>
<font><b/><sz val="11"/><color rgb="FF000000"/><name val="Meiryo UI"/><family val="3"/><charset val="128"/></font>
<font><i/><sz val="9"/><color rgb="FF808080"/><name val="Meiryo UI"/><family val="3"/><charset val="128"/></font>
<font><sz val="8"/><color rgb="FF7F7F7F"/><name val="Meiryo UI"/><family val="3"/><charset val="128"/></font>
<font><b/><sz val="12"/><color rgb="FF000000"/><name val="Meiryo UI"/><family val="3"/><charset val="128"/></font>
</fonts>
<fills count="8">
<fill><patternFill patternType="none"/></fill>
<fill><patternFill patternType="gray125"/></fill>
<fill><patternFill patternType="solid"><fgColor rgb="FF404040"/><bgColor indexed="64"/></patternFill></fill>
<fill><patternFill patternType="solid"><fgColor rgb="FFD9D9D9"/><bgColor indexed="64"/></patternFill></fill>
<fill><patternFill patternType="solid"><fgColor rgb="FFF2F2F2"/><bgColor indexed="64"/></patternFill></fill>
<fill><patternFill patternType="solid"><fgColor rgb="FF262626"/><bgColor indexed="64"/></patternFill></fill>
<fill><patternFill patternType="solid"><fgColor rgb="FFBFBFBF"/><bgColor indexed="64"/></patternFill></fill>
<fill><patternFill patternType="solid"><fgColor rgb="FFE7E7E7"/><bgColor indexed="64"/></patternFill></fill>
</fills>
<borders count="4">
<border><left/><right/><top/><bottom/><diagonal/></border>
<border><left style="thin"><color rgb="FFBFBFBF"/></left><right style="thin"><color rgb="FFBFBFBF"/></right><top style="thin"><color rgb="FFBFBFBF"/></top><bottom style="thin"><color rgb="FFBFBFBF"/></bottom><diagonal/></border>
<border><left style="thin"><color rgb="FF808080"/></left><right style="thin"><color rgb="FF808080"/></right><top style="thin"><color rgb="FF808080"/></top><bottom style="thin"><color rgb="FF808080"/></bottom><diagonal/></border>
<border><left/><right/><top/><bottom style="medium"><color rgb="FF000000"/></bottom><diagonal/></border>
</borders>
<cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>
<cellXfs count="30">
<xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>
<xf numFmtId="0" fontId="3" fillId="0" borderId="0" xfId="0" applyFont="1" applyAlignment="1"><alignment vertical="center"/></xf>
<xf numFmtId="0" fontId="4" fillId="0" borderId="0" xfId="0" applyFont="1" applyAlignment="1"><alignment vertical="center"/></xf>
<xf numFmtId="0" fontId="5" fillId="0" borderId="3" xfId="0" applyFont="1" applyBorder="1" applyAlignment="1"><alignment vertical="center"/></xf>
<xf numFmtId="0" fontId="2" fillId="2" borderId="2" xfId="0" applyFont="1" applyFill="1" applyBorder="1" applyAlignment="1"><alignment horizontal="center" vertical="center" wrapText="1"/></xf>
<xf numFmtId="0" fontId="0" fillId="0" borderId="1" xfId="0" applyBorder="1" applyAlignment="1"><alignment vertical="center"/></xf>
<xf numFmtId="0" fontId="0" fillId="0" borderId="1" xfId="0" applyBorder="1" applyAlignment="1"><alignment horizontal="center" vertical="center"/></xf>
<xf numFmtId="3" fontId="0" fillId="0" borderId="1" xfId="0" applyNumberFormat="1" applyBorder="1" applyAlignment="1"><alignment vertical="center"/></xf>
<xf numFmtId="166" fontId="0" fillId="0" borderId="1" xfId="0" applyNumberFormat="1" applyBorder="1" applyAlignment="1"><alignment vertical="center"/></xf>
<xf numFmtId="170" fontId="0" fillId="0" borderId="1" xfId="0" applyNumberFormat="1" applyBorder="1" applyAlignment="1"><alignment vertical="center"/></xf>
<xf numFmtId="167" fontId="0" fillId="0" borderId="1" xfId="0" applyNumberFormat="1" applyBorder="1" applyAlignment="1"><alignment vertical="center"/></xf>
<xf numFmtId="164" fontId="0" fillId="0" borderId="1" xfId="0" applyNumberFormat="1" applyBorder="1" applyAlignment="1"><alignment horizontal="center" vertical="center"/></xf>
<xf numFmtId="0" fontId="1" fillId="4" borderId="1" xfId="0" applyFont="1" applyFill="1" applyBorder="1" applyAlignment="1"><alignment vertical="center"/></xf>
<xf numFmtId="0" fontId="2" fillId="5" borderId="1" xfId="0" applyFont="1" applyFill="1" applyBorder="1" applyAlignment="1"><alignment horizontal="center" vertical="center"/></xf>
<xf numFmtId="0" fontId="1" fillId="6" borderId="1" xfId="0" applyFont="1" applyFill="1" applyBorder="1" applyAlignment="1"><alignment horizontal="center" vertical="center"/></xf>
<xf numFmtId="0" fontId="0" fillId="4" borderId="1" xfId="0" applyFill="1" applyBorder="1" applyAlignment="1"><alignment horizontal="center" vertical="center"/></xf>
<xf numFmtId="0" fontId="0" fillId="0" borderId="1" xfId="0" applyBorder="1" applyAlignment="1"><alignment vertical="center" wrapText="1"/></xf>
<xf numFmtId="0" fontId="1" fillId="3" borderId="2" xfId="0" applyFont="1" applyFill="1" applyBorder="1" applyAlignment="1"><alignment horizontal="center" vertical="center"/></xf>
<xf numFmtId="0" fontId="6" fillId="0" borderId="1" xfId="0" applyFont="1" applyBorder="1" applyAlignment="1"><alignment horizontal="center" vertical="center"/></xf>
<xf numFmtId="171" fontId="0" fillId="0" borderId="1" xfId="0" applyNumberFormat="1" applyBorder="1" applyAlignment="1"><alignment vertical="center"/></xf>
<xf numFmtId="0" fontId="1" fillId="0" borderId="1" xfId="0" applyFont="1" applyBorder="1" applyAlignment="1"><alignment vertical="center"/></xf>
<xf numFmtId="0" fontId="4" fillId="0" borderId="0" xfId="0" applyFont="1" applyAlignment="1"><alignment vertical="top" wrapText="1"/></xf>
<xf numFmtId="166" fontId="1" fillId="0" borderId="1" xfId="0" applyNumberFormat="1" applyFont="1" applyBorder="1" applyAlignment="1"><alignment vertical="center"/></xf>
<xf numFmtId="3" fontId="1" fillId="0" borderId="1" xfId="0" applyNumberFormat="1" applyFont="1" applyBorder="1" applyAlignment="1"><alignment vertical="center"/></xf>
<xf numFmtId="0" fontId="7" fillId="4" borderId="1" xfId="0" applyFont="1" applyFill="1" applyBorder="1" applyAlignment="1"><alignment horizontal="center" vertical="center" shrinkToFit="1"/></xf>
<xf numFmtId="0" fontId="8" fillId="0" borderId="0" xfId="0" applyFont="1" applyAlignment="1"><alignment vertical="center"/></xf>
<xf numFmtId="167" fontId="1" fillId="0" borderId="1" xfId="0" applyNumberFormat="1" applyFont="1" applyBorder="1" applyAlignment="1"><alignment vertical="center"/></xf>
<xf numFmtId="0" fontId="8" fillId="4" borderId="2" xfId="0" applyFont="1" applyFill="1" applyBorder="1" applyAlignment="1"><alignment horizontal="center" vertical="center" wrapText="1"/></xf>
<xf numFmtId="0" fontId="1" fillId="0" borderId="1" xfId="0" applyFont="1" applyBorder="1" applyAlignment="1"><alignment vertical="center" wrapText="1"/></xf>
<xf numFmtId="170" fontId="1" fillId="0" borderId="1" xfId="0" applyNumberFormat="1" applyFont="1" applyBorder="1" applyAlignment="1"><alignment vertical="center"/></xf>
</cellXfs>
<cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles>
<dxfs count="3">
<dxf><font><b/><color rgb="FFFFFFFF"/></font><fill><patternFill patternType="solid"><fgColor rgb="FF404040"/><bgColor rgb="FF404040"/></patternFill></fill></dxf>
<dxf><font><b/><color rgb="FF000000"/></font><fill><patternFill patternType="solid"><fgColor rgb="FFBFBFBF"/><bgColor rgb="FFBFBFBF"/></patternFill></fill></dxf>
<dxf><font><color rgb="FF000000"/></font><fill><patternFill patternType="solid"><fgColor rgb="FFE7E7E7"/><bgColor rgb="FFE7E7E7"/></patternFill></fill></dxf>
</dxfs>
<tableStyles count="0" defaultTableStyle="TableStyleMedium2" defaultPivotStyle="PivotStyleLight16"/>
</styleSheet>
'@

$COLN = New-Object 'string[]' 729
for ($i = 1; $i -le 728; $i++) {
    $n = $i; $s = ''
    while ($n -gt 0) { $rem = ($n - 1) % 26; $s = [string][char](65 + $rem) + $s; $n = [int][Math]::Floor(($n - 1) / 26) }
    $COLN[$i] = $s
}

#------------------------------------------------------------------------------
# 共通関数
#------------------------------------------------------------------------------
function X([string]$s) {
    if ([string]::IsNullOrEmpty($s) -or -not $XmlNeedRe.IsMatch($s)) { return $s }
    $s = $s.Replace('&', '&amp;').Replace('<', '&lt;').Replace('>', '&gt;').Replace('"', '&quot;')
    return $CtlRe.Replace($s, '')
}
function Split-Csv([string]$line) { return , [PerfRpt]::SplitCsv($line) }
function SerialText([double]$x) {
    $dt = [DateTime]::FromOADate($x)
    return $dt.ToString('yyyy/MM/dd HH:mm:ss', $Inv)
}
# 表示幅の目安 (全角 = 2、半角 = 1 に近い値)
function Units([string]$s) {
    if ([string]::IsNullOrEmpty($s)) { return 0.0 }
    $nb = $Utf8.GetByteCount($s); $asc = 0
    foreach ($ch in $s.ToCharArray()) { if ([int]$ch -lt 128) { $asc++ } }
    $na = $nb - $asc
    return ($nb - $na) + $na / 3 * 2
}
function WrapHt([string]$s, [double]$width) {
    if ([string]::IsNullOrEmpty($s)) { return 0 }
    $l = 0
    foreach ($part in $s.Split("`n")) { $l += [Math]::Truncate((Units $part) / ($width * 0.95)) + 1 }
    if ($l -le 1) { return 0 }
    return [Math]::Min(409, $l * 15 + 3)
}

# セル
function StrC([string]$ref, [string]$s, [int]$st) { return '<c r="' + $ref + '" s="' + $st + '" t="inlineStr"><is><t xml:space="preserve">' + (X $s) + '</t></is></c>' }
function NumC([string]$ref, $v, [int]$st) { $t = [PerfRpt]::NStr($v); if ($t -eq '') { return '<c r="' + $ref + '" s="' + $st + '"/>' }; return '<c r="' + $ref + '" s="' + $st + '"><v>' + $t + '</v></c>' }
function EmptyC([string]$ref, [int]$st) { return '<c r="' + $ref + '" s="' + $st + '"/>' }
function Row([int]$r, [string]$cells, [double]$ht) {
    if ($ht -gt 0) { return '<row r="' + $r + '" ht="' + $ht.ToString($Inv) + '" customHeight="1">' + $cells + '</row>' }
    return '<row r="' + $r + '">' + $cells + '</row>'
}
function Ws-Begin([string]$tab, [bool]$fit, [int]$xs, [int]$ys, [bool]$selected, [int]$zoom) {
    $s = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' + "`n" + '<worksheet ' + $NS + '>'
    $s += '<sheetPr><tabColor rgb="' + $tab + '"/>' + $(if ($fit) { '<pageSetUpPr fitToPage="1"/>' } else { '' }) + '</sheetPr>'
    $s += '<sheetViews><sheetView' + $(if ($selected) { ' tabSelected="1"' } else { '' }) + ' showGridLines="0" zoomScale="' + $zoom + '" zoomScaleNormal="' + $zoom + '" workbookViewId="0">'
    if ($xs -gt 0 -or $ys -gt 0) {
        $tl = $COLN[$xs + 1] + ($ys + 1)
        $pane = $(if ($xs -gt 0 -and $ys -gt 0) { 'bottomRight' } elseif ($ys -gt 0) { 'bottomLeft' } else { 'topRight' })
        $s += '<pane' + $(if ($xs -gt 0) { ' xSplit="' + $xs + '"' } else { '' }) + $(if ($ys -gt 0) { ' ySplit="' + $ys + '"' } else { '' }) + ' topLeftCell="' + $tl + '" activePane="' + $pane + '" state="frozen"/>'
        $s += '<selection pane="' + $pane + '" activeCell="' + $tl + '" sqref="' + $tl + '"/>'
    } else { $s += '<selection activeCell="A1" sqref="A1"/>' }
    $s += '</sheetView></sheetViews><sheetFormatPr defaultRowHeight="15"/>'
    return $s
}
function Ws-End([string]$orient, [bool]$fit, [bool]$drawing, [string]$repTitle, [string]$extra) {
    $s = $extra
    $s += '<pageMargins left="0.4" right="0.4" top="0.6" bottom="0.6" header="0.3" footer="0.3"/>'
    $s += '<pageSetup paperSize="9" orientation="' + $orient + '"' + $(if ($fit) { ' fitToWidth="1" fitToHeight="0"' } else { '' }) + '/>'
    $hf = '&L&"Meiryo UI,Regular"&9' + $repTitle + '&R&"Meiryo UI,Regular"&9&A'
    $s += '<headerFooter><oddHeader>' + (X $hf) + '</oddHeader><oddFooter>' + (X '&C&"Meiryo UI,Regular"&9&P / &N') + '</oddFooter></headerFooter>'
    if ($drawing) { $s += '<drawing r:id="rId1"/>' }
    return $s + '</worksheet>'
}
function Merges([System.Collections.Generic.List[string]]$m) {
    if ($m.Count -eq 0) { return '' }
    $s = '<mergeCells count="' + $m.Count + '">'; foreach ($x in $m) { $s += '<mergeCell ref="' + $x + '"/>' }; return $s + '</mergeCells>'
}
function Stat($list) {
    if ($null -eq $list -or $list.Count -eq 0) { return $null }
    $arr = $list.ToArray(); [Array]::Sort($arr)
    $n = $arr.Length; $sum = 0.0
    foreach ($v in $arr) { $sum += $v }
    $k = [int][Math]::Ceiling($n * 0.95) - 1; if ($k -lt 0) { $k = 0 }
    return [pscustomobject]@{ Max = $arr[$n - 1]; Min = $arr[0]; Avg = $sum / $n; P95 = $arr[$k]; N = $n; Sum = $sum }
}
function NewList() { return , (New-Object 'System.Collections.Generic.List[double]') }

#------------------------------------------------------------------------------
# 行ごとに何度も呼ぶ処理 (CSV の分解・数値化・列の計算・丸め・時刻・行の XML 出力)。
# PowerShell の関数は 1 回の呼び出しが重いため、クラスの静的メソッドにまとめる。
#------------------------------------------------------------------------------
class PerfRptTable { [string]$Name; [string[]]$H; [hashtable]$I; [System.Collections.Generic.List[string[]]]$Rows }
class PerfRpt {
    static [Globalization.CultureInfo]$Inv = [Globalization.CultureInfo]::InvariantCulture
    static [regex]$CsvRe = [regex]'(?:^|,)(?:"((?:[^"]|"")*)"|([^,]*))'
    static [regex]$XmlNeed = [regex]'[&<>"\x01-\x08\x0B\x0C\x0E-\x1F]'
    static [regex]$Ctl = [regex]'[\x01-\x08\x0B\x0C\x0E-\x1F]'
    # JBoss のスレッド名 (/proc の comm は 15 文字まで) → 用途 (perf-metrics.sh の分類と同じ)
    static [regex]$TgGc = [regex]'^(GC Thread|G1 |ZWorker|ZDirector|ZDriver|ZUncommit|ZStat|Shenandoah|ParGC|PSPromo|ConcGC)'
    static [regex]$TgJit = [regex]'^(C1 CompilerThre|C2 CompilerThre|JVMCI)'
    static [regex]$TgJfr = [regex]'^JFR '
    static [regex]$TgVm = [regex]'^(VM Thread|VM Periodic|Service Thread|Monitor Deflati|Signal Dispatch|Reference Handl|Finalizer|Common-Cleaner|Notification Th|Attach Listene|Sweeper)'
    static [regex]$TgJboss = [regex]'^(MSC service|ServerService|management|DeploymentScan|Transaction|Periodic Recov|IdleRemover|Reference Reape|Controller Boo|ElytronTimer)'
    static [regex]$TgIo = [regex]'( I/O-[0-9]*$| Accept$)'
    static [regex]$TgTask = [regex]' task-[0-9]*$'
    static [regex]$TgEe = [regex]'^(EE-Managed|EJB default|EJB )'
    static [hashtable]$Off = @{}
    static [bool]$UseRecorded = $false
    static [double]$RecOffset = 0
    static [void] ResetTz() { [PerfRpt]::Off = @{} }
    static [object] D([object]$s) {
        if ($null -eq $s) { return $null }
        if ($s -is [double]) { return $s }
        if ($s -is [int] -or $s -is [long] -or $s -is [decimal] -or $s -is [single]) { return [double]$s }
        $t = [string]$s
        if ($t.Length -eq 0 -or $t -eq '-') { return $null }
        $v = 0.0
        if ([double]::TryParse($t, [Globalization.NumberStyles]::Float, [PerfRpt]::Inv, [ref]$v)) {
            if ([double]::IsNaN($v) -or [double]::IsInfinity($v)) { return $null }
            return $v
        }
        return $null
    }
    static [string[]] SplitCsv([string]$line) {
        if ($line.IndexOf([char]34) -lt 0) { return $line.Split(',') }
        $list = New-Object System.Collections.Generic.List[string]
        foreach ($m in [PerfRpt]::CsvRe.Matches($line)) {
            if ($m.Groups[1].Success) { $list.Add($m.Groups[1].Value.Replace('""', '"')) } else { $list.Add($m.Groups[2].Value) }
        }
        return $list.ToArray()
    }
    static [int] Quotes([string]$s) {
        $n = 0; $i = $s.IndexOf([char]34)
        while ($i -ge 0) { $n++; $i = $s.IndexOf([char]34, $i + 1) }
        return $n
    }
    # CSV を読む。epoch で時間帯を絞り、途中で切れた行 (コンテナ停止時) は捨てる。
    # 値の中の改行 (引用符で囲まれたもの) は次の行とつなぐ。
    static [object] ReadCsv([string]$path, [string]$name, [double]$from, [double]$to) {
        if (-not [IO.File]::Exists($path)) { return $null }
        $t = [PerfRptTable]::new(); $t.Name = $name; $t.I = @{}; $t.Rows = New-Object 'System.Collections.Generic.List[string[]]'
        $first = $true; $ei = -1; $nh = 0; $pend = $null
        foreach ($raw in [IO.File]::ReadLines($path, (New-Object System.Text.UTF8Encoding($false)))) {
            $line = $raw
            if ($null -ne $pend) { $line = $pend + "`n" + $raw; $pend = $null }
            if ($line.IndexOf([char]34) -ge 0 -and ([PerfRpt]::Quotes($line) % 2) -eq 1) { $pend = $line; continue }
            if ($first) {
                $first = $false; $t.H = [PerfRpt]::SplitCsv($line)
                for ($i = 0; $i -lt $t.H.Length; $i++) { $t.I[$t.H[$i]] = $i }
                if ($t.I.ContainsKey('epoch')) { $ei = [int]$t.I['epoch'] }
                $nh = $t.H.Length
                continue
            }
            if ($line.Length -eq 0) { continue }
            $f = [PerfRpt]::SplitCsv($line)
            if ($f.Length -lt $nh) { continue }
            if ($ei -ge 0) {
                $e = 0.0
                if (-not [double]::TryParse($f[$ei], [Globalization.NumberStyles]::Float, [PerfRpt]::Inv, [ref]$e)) { continue }
                if ($e -lt $from -or $e -gt $to) { continue }
            }
            $t.Rows.Add($f)
        }
        if ($first) { return $null }
        return $t
    }
    static [string] G([object]$t, [object]$row, [string]$key) { $o = $t.I[$key]; if ($null -eq $o) { return $null }; return $row[[int]$o] }
    static [object] GD([object]$t, [object]$row, [string]$key) { return [PerfRpt]::D([PerfRpt]::G($t, $row, $key)) }
    # 累計カウンタの増分 (減った = 再起動・統計のクリアのときは、その回の値をそのまま増分とする)
    static [object] Dl([object]$cur, [object]$prev) {
        $c = [PerfRpt]::D($cur); $p = [PerfRpt]::D($prev)
        if ($null -eq $c -or $null -eq $p) { return $null }
        $d = $c - $p; if ($d -lt 0) { return $c }; return $d
    }
    static [object] Div([object]$a, [object]$b) {
        $x = [PerfRpt]::D($a); $y = [PerfRpt]::D($b)
        if ($null -eq $x -or $null -eq $y -or $y -eq 0) { return $null }; return $x / $y
    }
    static [object] Rnd([object]$v, [int]$n) { $x = [PerfRpt]::D($v); if ($null -eq $x) { return $null }; return [Math]::Round([double]$x, $n) }
    static [void] AddV([System.Collections.Generic.List[double]]$list, [object]$v) { $x = [PerfRpt]::D($v); if ($null -ne $x) { $list.Add([double]$x) } }
    # UNIX 秒 → Excel のシリアル値 (この PC のタイムゾーン、または記録時の UTC オフセット)
    static [double] XT([double]$ep) {
        if ([PerfRpt]::UseRecorded) { return ($ep + [PerfRpt]::RecOffset) / 86400.0 + 25569.0 }
        $h = [long][Math]::Floor($ep / 3600)
        if (-not [PerfRpt]::Off.ContainsKey($h)) {
            [PerfRpt]::Off[$h] = [TimeZoneInfo]::Local.GetUtcOffset([DateTimeOffset]::FromUnixTimeSeconds([long]$ep).UtcDateTime).TotalSeconds
        }
        return ($ep + [double][PerfRpt]::Off[$h]) / 86400.0 + 25569.0
    }
    static [string] ThreadGroup([string]$n) {
        if ([string]::IsNullOrEmpty($n)) { return 'other' }
        if ([PerfRpt]::TgGc.IsMatch($n)) { return 'gc' }
        if ([PerfRpt]::TgJit.IsMatch($n)) { return 'jit' }
        if ([PerfRpt]::TgJfr.IsMatch($n)) { return 'jfr' }
        if ([PerfRpt]::TgVm.IsMatch($n)) { return 'vm' }
        if ([PerfRpt]::TgJboss.IsMatch($n)) { return 'jboss' }
        if ([PerfRpt]::TgIo.IsMatch($n)) { return 'http-io' }
        if ([PerfRpt]::TgTask.IsMatch($n)) { return 'http-task' }
        if ([PerfRpt]::TgEe.IsMatch($n)) { return 'ee-ejb' }
        return 'other'
    }
    static [object] V([string[]]$r, [int]$i) { if ($i -lt 0 -or $i -ge $r.Length) { return $null }; return [PerfRpt]::D($r[$i]) }
    # [string] を返すメソッドは $null を '' に変えてしまうため [object] で返す
    static [object] T([string[]]$r, [int]$i) { if ($i -lt 0 -or $i -ge $r.Length) { return $null }; $s = $r[$i]; if ([string]::IsNullOrEmpty($s)) { return $null }; return $s }
    # 1 行分の列の値を計算する (列の定義は Build-Sheet を参照)
    #  op: 0 時刻  1 そのまま  2 倍率  3 合計  4 差  5 比  6 増分  7 毎秒  8 増分の比  9 既定値つき  10 定数  11 連結  12 時刻 (ミリ秒)  13 スレッドの用途
    static [object[]] Eval([string[]]$r, [string[]]$p, [int]$ei, [int[]]$op, [object[]]$src, [double[]]$f, [object[]]$dv, [bool[]]$tx, [int[]]$rd) {
        $n = $op.Length
        $out = New-Object 'object[]' $n
        $dt = 0.0
        if ($null -ne $p -and $ei -ge 0) {
            $a = [PerfRpt]::V($r, $ei); $b = [PerfRpt]::V($p, $ei)
            if ($null -ne $a -and $null -ne $b) { $dt = [double]$a - [double]$b }
        }
        for ($c = 0; $c -lt $n; $c++) {
            $s = [int[]]$src[$c]
            $s0 = -1; $s1 = -1
            if ($s.Length -gt 0) { $s0 = $s[0] }
            if ($s.Length -gt 1) { $s1 = $s[1] }
            $v = $null
            $k = $op[$c]
            if ($k -eq 1) {
                if ($tx[$c]) { $v = [PerfRpt]::T($r, $s0) } else { $v = [PerfRpt]::V($r, $s0) }
            } elseif ($k -eq 0) {
                $e = [PerfRpt]::V($r, $ei); if ($null -ne $e) { $v = [PerfRpt]::XT([double]$e) }
            } elseif ($k -eq 2) {
                $x = [PerfRpt]::V($r, $s0); if ($null -ne $x) { $v = [double]$x * $f[$c] }
            } elseif ($k -eq 3) {
                $sum = 0.0; $any = $false
                foreach ($i in $s) { $x = [PerfRpt]::V($r, $i); if ($null -ne $x) { $sum += [double]$x; $any = $true } }
                if ($any) { $v = $sum * $f[$c] }
            } elseif ($k -eq 4) {
                $x = [PerfRpt]::V($r, $s0); $y = [PerfRpt]::V($r, $s1)
                if ($null -ne $x -and $null -ne $y) { $v = ([double]$x - [double]$y) * $f[$c] }
            } elseif ($k -eq 5) {
                $x = [PerfRpt]::V($r, $s0); $y = [PerfRpt]::V($r, $s1)
                if ($null -eq $y -and $null -ne $dv[$c]) { $y = [double]$dv[$c] }
                if ($null -ne $x -and $null -ne $y -and [double]$y -ne 0) { $v = [double]$x / [double]$y * $f[$c] }
            } elseif ($k -eq 6) {
                if ($null -ne $p) { $x = [PerfRpt]::Dl(([PerfRpt]::V($r, $s0)), ([PerfRpt]::V($p, $s0))); if ($null -ne $x) { $v = [double]$x * $f[$c] } }
            } elseif ($k -eq 7) {
                if ($null -ne $p -and $dt -gt 0) { $x = [PerfRpt]::Dl(([PerfRpt]::V($r, $s0)), ([PerfRpt]::V($p, $s0))); if ($null -ne $x) { $v = [double]$x / $dt * $f[$c] } }
            } elseif ($k -eq 8) {
                if ($null -ne $p) {
                    $x = [PerfRpt]::Dl(([PerfRpt]::V($r, $s0)), ([PerfRpt]::V($p, $s0))); $y = [PerfRpt]::Dl(([PerfRpt]::V($r, $s1)), ([PerfRpt]::V($p, $s1)))
                    if ($null -ne $x -and $null -ne $y -and [double]$y -gt 0) { $v = [double]$x / [double]$y * $f[$c] }
                }
            } elseif ($k -eq 9) {
                $v = [PerfRpt]::V($r, $s0); if ($null -eq $v -and $null -ne $dv[$c]) { $v = [double]$dv[$c] }
            } elseif ($k -eq 10) {
                if ($null -ne $dv[$c]) { $v = [PerfRpt]::D($dv[$c]) }
            } elseif ($k -eq 11) {
                $parts = New-Object System.Collections.Generic.List[string]
                foreach ($i in $s) { $x = [PerfRpt]::T($r, $i); if ($null -ne $x) { $parts.Add([string]$x) } }
                if ($parts.Count -gt 0) { $v = [string]::Join(' / ', $parts.ToArray()) }
            } elseif ($k -eq 12) {
                $e = [PerfRpt]::V($r, $s0); if ($null -ne $e) { $v = [PerfRpt]::XT([double]$e / 1000.0) }
            } elseif ($k -eq 13) {
                $v = [PerfRpt]::ThreadGroup([string]([PerfRpt]::T($r, $s0)))
            }
            if ($null -ne $v -and $rd[$c] -ge 0 -and $v -is [double]) { $v = [Math]::Round([double]$v, $rd[$c]) }
            $out[$c] = $v
        }
        return $out
    }
    # 行の並び (src) をまとめて計算して out に足す。max 行に達したら止めて $false を返す
    static [bool] EvalAll([System.Collections.IList]$src, [System.Collections.Generic.List[object]]$out, [int]$max, [int]$ei, [int[]]$op, [object[]]$sp, [double[]]$f, [object[]]$dv, [bool[]]$tx, [int[]]$rd) {
        $p = $null
        foreach ($r in $src) {
            if ($out.Count -ge $max) { return $false }
            $out.Add([PerfRpt]::Eval([string[]]$r, $p, $ei, $op, $sp, $f, $dv, $tx, $rd))
            $p = [string[]]$r
        }
        return $true
    }
    static [string] X([string]$s) {
        if ([string]::IsNullOrEmpty($s) -or -not [PerfRpt]::XmlNeed.IsMatch($s)) { return $s }
        $s = $s.Replace('&', '&amp;').Replace('<', '&lt;').Replace('>', '&gt;').Replace('"', '&quot;')
        return [PerfRpt]::Ctl.Replace($s, '')
    }
    static [string] NStr([object]$v) {
        $x = [PerfRpt]::D($v); if ($null -eq $x) { return '' }
        $d = [double]$x
        if ([double]::IsNaN($d) -or [double]::IsInfinity($d)) { return '' }
        return $d.ToString('R', [PerfRpt]::Inv)
    }
    # 表の行を <row> の XML にして書き出す (fm / st は 0 始まりの列ごとの書式・スタイル番号)
    static [void] WriteRows([IO.TextWriter]$w, [System.Collections.IList]$rows, [string[]]$fm, [int[]]$st, [int]$textStyle, [int]$firstRow, [string[]]$coln) {
        $sb = New-Object System.Text.StringBuilder 8192
        $nc = $fm.Length
        for ($i = 0; $i -lt $rows.Count; $i++) {
            $vals = $rows[$i]
            $rs = [string]($firstRow + $i)
            [void]$sb.Clear(); [void]$sb.Append('<row r="').Append($rs).Append('">')
            for ($c = 0; $c -lt $nc; $c++) {
                $v = $null; if ($c -lt $vals.Length) { $v = $vals[$c] }
                $rf = $coln[$c + 1] + $rs
                if ($null -eq $v) { [void]$sb.Append('<c r="').Append($rf).Append('" s="').Append($st[$c]).Append('"/>'); continue }
                $f = $fm[$c]
                if ($f -eq 'text' -or $f -eq 'textc' -or $f -eq 'wrap') {
                    [void]$sb.Append('<c r="').Append($rf).Append('" s="').Append($st[$c]).Append('" t="inlineStr"><is><t xml:space="preserve">').Append([PerfRpt]::X([string]$v)).Append('</t></is></c>')
                } elseif ($v -is [string]) {
                    $d = [PerfRpt]::D($v)
                    if ($null -eq $d) { [void]$sb.Append('<c r="').Append($rf).Append('" s="').Append($textStyle).Append('" t="inlineStr"><is><t xml:space="preserve">').Append([PerfRpt]::X($v)).Append('</t></is></c>') }
                    else { [void]$sb.Append('<c r="').Append($rf).Append('" s="').Append($st[$c]).Append('"><v>').Append([PerfRpt]::NStr($d)).Append('</v></c>') }
                } else {
                    $t = [PerfRpt]::NStr($v)
                    if ($t.Length -eq 0) { [void]$sb.Append('<c r="').Append($rf).Append('" s="').Append($st[$c]).Append('"/>') }
                    else { [void]$sb.Append('<c r="').Append($rf).Append('" s="').Append($st[$c]).Append('"><v>').Append($t).Append('</v></c>') }
                }
            }
            [void]$sb.Append('</row>')
            $w.Write($sb.ToString())
        }
    }
}
$PerfRpt = [PerfRpt]

#------------------------------------------------------------------------------
# 入力 (ディレクトリ / 親ディレクトリ / .zip / .tar.gz / .tar)
#------------------------------------------------------------------------------
$TempDirs = New-Object System.Collections.Generic.List[string]
$DataFiles = @('perf_meta.csv', 'cli_datasource.csv', 'cli_jvm.csv', 'jvm_jstat_gc.csv', 'cpu_env.csv', 'cpu_sched.csv', 'os_top_summary.csv', 'os_jboss_threads.csv')
function Test-PerfDir([string]$d) {
    foreach ($f in $DataFiles) { if (Test-Path -LiteralPath (Join-Path $d $f)) { return $true } }
    return $false
}
function New-TempDir() {
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ('perfrpt_' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tmp | Out-Null
    $TempDirs.Add($tmp)
    return $tmp
}
function Resolve-PerfDirs([string]$path) {
    if (-not (Test-Path -LiteralPath $path)) { throw "入力が見つかりません: $path" }
    $item = Get-Item -LiteralPath $path
    $root = $item.FullName
    if (-not $item.PSIsContainer) {
        $nm = $item.Name.ToLowerInvariant()
        if ($nm.EndsWith('.csv')) { return , @($item.DirectoryName) }
        $tmp = New-TempDir
        if ($nm.EndsWith('.zip')) {
            [IO.Compression.ZipFile]::ExtractToDirectory($item.FullName, $tmp)
        } elseif ($nm.EndsWith('.tar.gz') -or $nm.EndsWith('.tgz') -or $nm.EndsWith('.tar')) {
            $tarExe = 'tar'
            if ($env:SystemRoot -and (Test-Path -LiteralPath (Join-Path $env:SystemRoot 'System32\tar.exe'))) { $tarExe = Join-Path $env:SystemRoot 'System32\tar.exe' }
            & $tarExe -xf $item.FullName -C $tmp
            if ($LASTEXITCODE -ne 0) { throw "展開に失敗しました: $($item.FullName)" }
        } else {
            throw "対応していない入力です (ディレクトリ / .zip / .tar.gz / .tar): $path"
        }
        $root = $tmp
    }
    if (Test-PerfDir $root) { return , @($root) }
    $found = New-Object System.Collections.Generic.List[string]
    foreach ($fn in $DataFiles) {
        foreach ($f in (Get-ChildItem -LiteralPath $root -Recurse -File -Filter $fn -ErrorAction SilentlyContinue)) {
            if (-not $found.Contains($f.DirectoryName)) { $found.Add($f.DirectoryName) }
        }
    }
    if ($found.Count -eq 0) { throw "perf-metrics の出力 (perf_meta.csv・cli_datasource.csv・jvm_jstat_gc.csv・cpu_env.csv など) が見つかりません: $path" }
    return , ($found.ToArray() | Sort-Object)
}

function Read-PerfCsv([string]$dir, [string]$name) {
    return $PerfRpt::ReadCsv((Join-Path $dir $name), $name, $script:FromEpoch, $script:ToEpoch)
}
# キーごとに行をまとめる (初出順)
function Group-By($t, [string[]]$keys) {
    $od = New-Object System.Collections.Specialized.OrderedDictionary
    if ($null -eq $t) { return $od }
    $ix = New-Object 'int[]' $keys.Count
    for ($i = 0; $i -lt $keys.Count; $i++) { $o = $t.I[$keys[$i]]; $ix[$i] = $(if ($null -eq $o) { -1 } else { [int]$o }) }
    foreach ($r in $t.Rows) {
        $parts = New-Object 'string[]' $ix.Length
        for ($i = 0; $i -lt $ix.Length; $i++) { if ($ix[$i] -ge 0) { $parts[$i] = $r[$ix[$i]] } }
        $k = [string]::Join("`t", $parts)
        if (-not $od.Contains($k)) { $od[$k] = New-Object System.Collections.Generic.List[object] }
        $od[$k].Add($r)
    }
    return $od
}
function New-Table([string]$name, [string[]]$h) {
    $nt = [PerfRptTable]::new(); $nt.Name = $name; $nt.H = $h; $nt.I = @{}
    for ($i = 0; $i -lt $h.Length; $i++) { $nt.I[$h[$i]] = $i }
    $nt.Rows = New-Object 'System.Collections.Generic.List[string[]]'
    return $nt
}
# 縦持ち (1 行 = 時刻 × グループ) を横持ち (1 行 = 時刻、列 = グループ.項目) にする。
# そのときに無かったグループは 0 とする (スレッド数・メモリの分類など、無い = 0 のもの)。
function Pivot-Table($t, [string]$colKey, [string[]]$fields, [string[]]$order) {
    if ($null -eq $t -or $t.Rows.Count -eq 0) { return $null }
    $ki = [int]$t.I[$colKey]; $ei = [int]$t.I['epoch']; $ti = [int]$t.I['timestamp']
    $seen = New-Object System.Collections.Generic.List[string]
    foreach ($r in $t.Rows) { $g = $r[$ki]; if (-not $seen.Contains($g)) { $seen.Add($g) } }
    $groups = New-Object System.Collections.Generic.List[string]
    foreach ($g in $order) { if ($seen.Contains($g)) { $groups.Add($g) } }
    foreach ($g in $seen) { if (-not $groups.Contains($g)) { $groups.Add($g) } }
    $h = New-Object System.Collections.Generic.List[string]; $h.Add('timestamp'); $h.Add('epoch')
    foreach ($g in $groups) { foreach ($fl in $fields) { $h.Add($g + '.' + $fl) } }
    $nt = New-Table ($t.Name + '#pivot') $h.ToArray()
    $fi = New-Object 'int[]' $fields.Count
    for ($j = 0; $j -lt $fields.Count; $j++) { $o = $t.I[$fields[$j]]; $fi[$j] = $(if ($null -eq $o) { -1 } else { [int]$o }) }
    $gi = @{}; for ($i = 0; $i -lt $groups.Count; $i++) { $gi[$groups[$i]] = 2 + $i * $fields.Count }
    $cur = $null; $curE = $null
    foreach ($r in $t.Rows) {
        $e = $r[$ei]
        if ($e -ne $curE) {
            if ($null -ne $cur) { $nt.Rows.Add($cur) }
            $cur = New-Object 'string[]' $nt.H.Length
            for ($i = 2; $i -lt $cur.Length; $i++) { $cur[$i] = '0' }
            $cur[0] = $r[$ti]; $cur[1] = $e; $curE = $e
        }
        $base = [int]$gi[$r[$ki]]
        for ($j = 0; $j -lt $fi.Length; $j++) { if ($fi[$j] -ge 0) { $cur[$base + $j] = $r[$fi[$j]] } }
    }
    if ($null -ne $cur) { $nt.Rows.Add($cur) }
    return [pscustomobject]@{ T = $nt; Groups = $groups }
}
# 時刻ごとに、分類 (map でまとめる) 別の合計を求める (例: top のプロセス別 CPU% → JBoss / 収集処理 / その他)
function Sum-ByEpoch($t, [string]$catKey, [string]$valKey, [hashtable]$map, [string[]]$cats) {
    if ($null -eq $t -or $t.Rows.Count -eq 0) { return $null }
    $ci = [int]$t.I[$catKey]; $vi = [int]$t.I[$valKey]; $ei = [int]$t.I['epoch']; $ti = [int]$t.I['timestamp']
    $h = @('timestamp', 'epoch') + $cats
    $nt = New-Table ($t.Name + '#sum') $h
    $cix = @{}; for ($i = 0; $i -lt $cats.Count; $i++) { $cix[$cats[$i]] = 2 + $i }
    $cur = $null; $curE = $null; $acc = $null
    foreach ($r in $t.Rows) {
        $e = $r[$ei]
        if ($e -ne $curE) {
            if ($null -ne $cur) { for ($i = 0; $i -lt $cats.Count; $i++) { $cur[2 + $i] = $acc[$i].ToString('R', $Inv) }; $nt.Rows.Add($cur) }
            $cur = New-Object 'string[]' $h.Length; $cur[0] = $r[$ti]; $cur[1] = $e; $curE = $e
            $acc = New-Object 'double[]' $cats.Count
        }
        $c = $map[$r[$ci]]; if ($null -eq $c) { $c = $cats[$cats.Count - 1] }
        $v = $PerfRpt::D($r[$vi]); if ($null -ne $v) { $acc[[int]$cix[$c] - 2] += [double]$v }
    }
    if ($null -ne $cur) { for ($i = 0; $i -lt $cats.Count; $i++) { $cur[2 + $i] = $acc[$i].ToString('R', $Inv) }; $nt.Rows.Add($cur) }
    return $nt
}
# base の各行に、同じ epoch の extra の列を付け足す
function Join-ByEpoch($base, $extra) {
    if ($null -eq $base) { return $null }
    if ($null -eq $extra) { return $base }
    $add = @(); foreach ($hh in $extra.H) { if ($hh -ne 'timestamp' -and $hh -ne 'epoch') { $add += $hh } }
    $nt = New-Table ($base.Name + '#join') (@($base.H) + $add)
    $map = @{}; $ee = [int]$extra.I['epoch']
    foreach ($r in $extra.Rows) { $map[$r[$ee]] = $r }
    $ai = @(); foreach ($a in $add) { $ai += [int]$extra.I[$a] }
    $be = [int]$base.I['epoch']
    foreach ($r in $base.Rows) {
        $nr = New-Object 'string[]' ($base.H.Length + $add.Count)
        [Array]::Copy($r, $nr, [Math]::Min($r.Length, $base.H.Length))
        $x = $map[$r[$be]]
        if ($null -ne $x) { for ($j = 0; $j -lt $ai.Count; $j++) { $nr[$base.H.Length + $j] = $x[$ai[$j]] } }
        $nt.Rows.Add($nr)
    }
    return $nt
}

#------------------------------------------------------------------------------
# シート (表) のモデル
#------------------------------------------------------------------------------
function New-Sheet([string]$name, [string]$title, [string]$note, [int]$freezeCols, [string]$tab) {
    return [pscustomobject]@{
        Name = $name; Title = $title; Note = $note; FreezeCols = $freezeCols; Tab = $tab
        Cols = (New-Object System.Collections.Generic.List[object])
        Rows = (New-Object System.Collections.Generic.List[object])
        Groups = (New-Object System.Collections.Generic.List[object])
        CF = (New-Object System.Collections.Generic.List[object])
        C = @{}
        Truncated = $false
    }
}
# 列を足して列番号 (1 始まり) を返す。 cat=分類 label=見出し key=元の CSV 列名 fmt=書式 w=列幅
function Add-Col($sh, [string]$cat, [string]$label, [string]$key, [string]$fmt, [double]$w) {
    $sh.Cols.Add([pscustomobject]@{ Cat = $cat; Label = $label; Key = $key; Fmt = $fmt; W = $w })
    return $sh.Cols.Count
}
function Add-Row($sh, [object[]]$vals, [string]$group) {
    if ($sh.Rows.Count -ge $MaxRows) { $sh.Truncated = $true; return }
    $n = $sh.Rows.Count
    if ($sh.Groups.Count -eq 0 -or $sh.Groups[$sh.Groups.Count - 1].Key -ne $group) {
        $sh.Groups.Add([pscustomobject]@{ Key = $group; Start = $n; End = $n; R1 = 0; R2 = 0 })
    } else { $sh.Groups[$sh.Groups.Count - 1].End = $n }
    $sh.Rows.Add($vals)
}
# 条件付き書式 (列 ID, 種類, 値, dxf)  種類: ge / gt / lt / eq (数値) / eqs (文字列) / bar
function Add-CF($sh, [string]$id, [string]$kind, [string]$val, [int]$dxf) { if ($sh.C.ContainsKey($id)) { $sh.CF.Add(@($sh.C[$id], $kind, $val, $dxf)) } }
$DATA_ROW = 7
function Fix-Ranges($sh) { foreach ($g in $sh.Groups) { $g.R1 = $DATA_ROW + $g.Start; $g.R2 = $DATA_ROW + $g.End } }

# 列の定義: C <ID> <分類> <見出し> <元の列名 (6 行目に表示)> <書式> <幅> <計算> <元の列 (カンマ区切り)> [倍率] [既定値]
#  計算: time 時刻 / raw そのまま / scale 倍率 / sum 合計 / diff 差 / ratio 比 (既定値 = 分母が無いとき) /
#        delta 前回からの増分 / rate 増分 ÷ 経過秒 / dratio 増分の比 / dflt 無ければ既定値 / const 定数 /
#        join 文字列の連結 / timems ミリ秒の UNIX 時刻 / tgroup スレッド名 → 用途
$OPS = @{ time = 0; raw = 1; scale = 2; sum = 3; diff = 4; ratio = 5; delta = 6; rate = 7; dratio = 8; dflt = 9; const = 10; join = 11; timems = 12; tgroup = 13 }
function C([string]$id, [string]$cat, [string]$label, [string]$key, [string]$fmt, [double]$w, [string]$op, [string]$src = '', [double]$f = 1.0, $dv = $null) {
    return [pscustomobject]@{ Id = $id; Cat = $cat; Label = $label; Key = $key; Fmt = $fmt; W = $w; Op = $op; Src = $src; F = $f; Dv = $dv }
}
# 時系列の基本列 (日時)
function CT() { return (C 't' '基本' '日時' 'timestamp' 'dt' 19 'time') }
function Has-Src($t, $spec) {
    if ($spec.Op -eq 'time' -or $spec.Op -eq 'const' -or $spec.Src -eq '') { return $true }
    foreach ($nm in ($spec.Src -split ',')) { if ($nm -ne '' -and $t.I.ContainsKey($nm)) { return $true } }
    return $false
}
# 値がひとつも無い列を除く (keep の列 ID は残す)
function Drop-EmptyCols($sh, [string[]]$keep) {
    $nc = $sh.Cols.Count; $use = New-Object 'bool[]' $nc
    $ids = @{}; foreach ($k in $sh.C.Keys) { $ids[[int]$sh.C[$k] - 1] = $k }
    for ($c = 0; $c -lt $nc; $c++) {
        if ($keep -contains $ids[$c]) { $use[$c] = $true; continue }
        foreach ($r in $sh.Rows) { if ($null -ne $r[$c]) { $use[$c] = $true; break } }
    }
    $idx = @(); for ($c = 0; $c -lt $nc; $c++) { if ($use[$c]) { $idx += $c } }
    if ($idx.Count -eq $nc) { return }
    $cols = New-Object System.Collections.Generic.List[object]; $C2 = @{}
    foreach ($c in $idx) { $cols.Add($sh.Cols[$c]); $C2[$ids[$c]] = $cols.Count }
    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($r in $sh.Rows) { $nr = New-Object 'object[]' $idx.Count; for ($j = 0; $j -lt $idx.Count; $j++) { $nr[$j] = $r[$idx[$j]] }; $rows.Add($nr) }
    $sh.Cols = $cols; $sh.Rows = $rows; $sh.C = $C2
    $cf = New-Object System.Collections.Generic.List[object]
    foreach ($x in $sh.CF) { $old = [int]$x[0] - 1; $k = $ids[$old]; if ($C2.ContainsKey($k)) { $cf.Add(@($C2[$k], $x[1], $x[2], $x[3])) } }
    $sh.CF = $cf
}
function Build-Sheet($t, [string]$name, [string]$title, [string]$note, [int]$freeze, [string]$tab, [object[]]$specs, [string[]]$groupBy = @()) {
    $sh = New-Sheet $name $title $note $freeze $tab
    # 元の CSV に無い列 (古い版・取得できなかった項目) は作らない
    $specs = @($specs | Where-Object { $null -ne $_ -and (Has-Src $t $_) })
    $n = $specs.Count
    $op = New-Object 'int[]' $n; $src = New-Object 'object[]' $n; $f = New-Object 'double[]' $n; $dv = New-Object 'object[]' $n
    $tx = New-Object 'bool[]' $n; $rd = New-Object 'int[]' $n
    for ($i = 0; $i -lt $n; $i++) {
        $s = $specs[$i]
        $sh.C[$s.Id] = Add-Col $sh $s.Cat $s.Label $s.Key $s.Fmt $s.W
        $o = $OPS[$s.Op]; if ($null -eq $o) { throw "未定義の計算: $($s.Op)" }
        $op[$i] = [int]$o
        $ix = New-Object System.Collections.Generic.List[int]
        foreach ($nm in ($s.Src -split ',')) { if ($nm -ne '') { $q = $t.I[$nm]; $ix.Add($(if ($null -eq $q) { -1 } else { [int]$q })) } }
        $src[$i] = $ix.ToArray()
        $f[$i] = $s.F; $dv[$i] = $s.Dv
        $tx[$i] = ($s.Fmt -eq 'text' -or $s.Fmt -eq 'textc' -or $s.Fmt -eq 'wrap')
        $r0 = $ROUND[$s.Fmt]; $rd[$i] = $(if ($null -eq $r0 -or $s.Op -eq 'time' -or $s.Op -eq 'timems') { -1 } else { [int]$r0 })
    }
    $ei = $(if ($t.I.ContainsKey('epoch')) { [int]$t.I['epoch'] } else { -1 })
    # 行ごとの計算はクラスの中でまとめて行う (PowerShell の関数を行ごとに呼ぶと遅いため)
    $rows = $sh.Rows
    if ($groupBy.Count -gt 0) {
        $grp = Group-By $t $groupBy
        foreach ($key in $grp.Keys) {
            $start = $rows.Count
            $ok = $PerfRpt::EvalAll($grp[$key], $rows, $MaxRows, $ei, $op, $src, $f, $dv, $tx, $rd)
            if ($rows.Count -gt $start) { $sh.Groups.Add([pscustomobject]@{ Key = $key; Start = $start; End = $rows.Count - 1; R1 = 0; R2 = 0 }) }
            if (-not $ok) { $sh.Truncated = $true; break }
        }
    } else {
        $ok = $PerfRpt::EvalAll($t.Rows, $rows, $MaxRows, $ei, $op, $src, $f, $dv, $tx, $rd)
        if ($rows.Count -gt 0) { $sh.Groups.Add([pscustomobject]@{ Key = ''; Start = 0; End = $rows.Count - 1; R1 = 0; R2 = 0 }) }
        if (-not $ok) { $sh.Truncated = $true }
    }
    Fix-Ranges $sh
    return $sh
}
# 列の値の統計 (グループを指定すると、その範囲だけ)
function ColVals($sh, [string]$id, $grp) {
    $l = NewList
    if ($null -eq $sh -or -not $sh.C.ContainsKey($id)) { return , $l }
    $c = [int]$sh.C[$id] - 1
    $a = 0; $b = $sh.Rows.Count - 1
    if ($null -ne $grp) { $a = $grp.Start; $b = $grp.End }
    for ($i = $a; $i -le $b; $i++) { $v = $sh.Rows[$i][$c]; if ($null -ne $v -and $v -isnot [string]) { $l.Add([double]$v) } }
    return , $l
}
function ColStat($sh, [string]$id, $grp = $null) { return Stat (ColVals $sh $id $grp) }
function ColSum($sh, [string]$id, $grp = $null) { $l = ColVals $sh $id $grp; if ($l.Count -eq 0) { return $null }; $s = 0.0; foreach ($v in $l) { $s += $v }; return $s }
function ColMax($sh, [string]$id, $grp = $null) { $st = ColStat $sh $id $grp; if ($null -eq $st) { return $null }; return $st.Max }
function ColLast($sh, [string]$id, $grp = $null) {
    if ($null -eq $sh -or -not $sh.C.ContainsKey($id)) { return $null }
    $c = [int]$sh.C[$id] - 1; $a = 0; $b = $sh.Rows.Count - 1
    if ($null -ne $grp) { $a = $grp.Start; $b = $grp.End }
    for ($i = $b; $i -ge $a; $i--) { $v = $sh.Rows[$i][$c]; if ($null -ne $v) { return $v } }
    return $null
}
# 条件を満たした行の数
function ColCount($sh, [string]$id, [scriptblock]$cond, $grp = $null) {
    $n = 0; foreach ($v in (ColVals $sh $id $grp)) { if (& $cond $v) { $n++ } }; return $n
}

function Write-TableSheet([System.IO.Compression.ZipArchive]$zip, $sh, [int]$sheetIdx) {
    $e = $zip.CreateEntry("xl/worksheets/sheet$sheetIdx.xml", [IO.Compression.CompressionLevel]::Optimal)
    $w = New-Object IO.StreamWriter($e.Open(), $Utf8)
    $nc = $sh.Cols.Count; $nr = $sh.Rows.Count
    $w.Write((Ws-Begin $sh.Tab $true $(if ($nr -gt 0) { $sh.FreezeCols } else { 0 }) $(if ($nr -gt 0) { 6 } else { 0 }) $false 90))
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('<cols>')
    for ($c = 1; $c -le $nc; $c++) { [void]$sb.Append('<col min="' + $c + '" max="' + $c + '" width="' + ([double]$sh.Cols[$c - 1].W).ToString($Inv) + '" customWidth="1"/>') }
    [void]$sb.Append('</cols><sheetData>')
    [void]$sb.Append((Row 1 (StrC 'A1' $sh.Title $S_TITLE) 24))
    $note = $sh.Note
    if ($sh.Truncated) { $note += '（行数が多いため先頭 ' + $MaxRows + ' 行だけを載せています。残りは CSV を参照してください）' }
    [void]$sb.Append((Row 2 (StrC 'A2' $note $S_NOTE) 0))
    $merges = New-Object System.Collections.Generic.List[string]
    # 4 行目: 分類 (同じ分類が続く列は結合)、5 行目: 見出し、6 行目: 元の CSV 列名
    $out = New-Object System.Text.StringBuilder
    $c = 1
    while ($c -le $nc) {
        $j = $c; while ($j -lt $nc -and $sh.Cols[$j].Cat -ceq $sh.Cols[$c - 1].Cat) { $j++ }
        [void]$out.Append((StrC ($COLN[$c] + '4') $sh.Cols[$c - 1].Cat $S_BAND))
        for ($i = $c + 1; $i -le $j; $i++) { [void]$out.Append((EmptyC ($COLN[$i] + '4') $S_BAND)) }
        if ($j -gt $c) { $merges.Add($COLN[$c] + '4:' + $COLN[$j] + '4') }
        $c = $j + 1
    }
    [void]$sb.Append((Row 4 $out.ToString() 18))
    [void]$out.Clear(); for ($c = 1; $c -le $nc; $c++) { [void]$out.Append((StrC ($COLN[$c] + '5') $sh.Cols[$c - 1].Label $S_HDR)) }
    [void]$sb.Append((Row 5 $out.ToString() 32))
    [void]$out.Clear(); for ($c = 1; $c -le $nc; $c++) { [void]$out.Append((StrC ($COLN[$c] + '6') $sh.Cols[$c - 1].Key $S_COLKEY)) }
    [void]$sb.Append((Row 6 $out.ToString() 13.5))
    $w.Write($sb.ToString())
    if ($nr -eq 0) {
        $w.Write((Row 7 (StrC 'A7' '（この期間のデータがありません）' $S_NOTE) 0))
    }
    $fm = New-Object 'string[]' $nc; $st = New-Object 'int[]' $nc
    for ($c = 0; $c -lt $nc; $c++) { $fm[$c] = $sh.Cols[$c].Fmt; $s2 = $FMTS[$fm[$c]]; if ($null -eq $s2) { $s2 = $S_TEXT }; $st[$c] = $s2 }
    $PerfRpt::WriteRows($w, $sh.Rows, $fm, $st, $S_TEXT, $DATA_ROW, $COLN)
    $w.Write('</sheetData>')
    $extra = ''
    $last = $DATA_ROW + [Math]::Max($nr, 1) - 1
    if ($nr -gt 0) {
        $extra += '<autoFilter ref="A6:' + $COLN[$nc] + $last + '"/>'
        Add-DefName $sheetIdx '_xlnm._FilterDatabase' ("'" + $sh.Name + "'!`$A`$6:`$" + $COLN[$nc] + '$' + $last)
    }
    $extra += Merges $merges
    if ($nr -gt 0 -and $sh.CF.Count -gt 0) {
        $prio = 1
        foreach ($cf in $sh.CF) {
            $col = $COLN[[int]$cf[0]]; $sq = $col + $DATA_ROW + ':' + $col + $last
            $extra += '<conditionalFormatting sqref="' + $sq + '">'
            switch ($cf[1]) {
                'ge' { $extra += '<cfRule type="cellIs" dxfId="' + $cf[3] + '" priority="' + $prio + '" operator="greaterThanOrEqual"><formula>' + $cf[2] + '</formula></cfRule>' }
                'gt' { $extra += '<cfRule type="cellIs" dxfId="' + $cf[3] + '" priority="' + $prio + '" operator="greaterThan"><formula>' + $cf[2] + '</formula></cfRule>' }
                'lt' { $extra += '<cfRule type="cellIs" dxfId="' + $cf[3] + '" priority="' + $prio + '" operator="lessThan"><formula>' + $cf[2] + '</formula></cfRule>' }
                'eq' { $extra += '<cfRule type="cellIs" dxfId="' + $cf[3] + '" priority="' + $prio + '" operator="equal"><formula>' + $cf[2] + '</formula></cfRule>' }
                'eqs' { $extra += '<cfRule type="cellIs" dxfId="' + $cf[3] + '" priority="' + $prio + '" operator="equal"><formula>' + (X ('"' + $cf[2] + '"')) + '</formula></cfRule>' }
                'bar' { $extra += '<cfRule type="dataBar" priority="' + $prio + '"><dataBar><cfvo type="num" val="0"/><cfvo type="num" val="' + $cf[2] + '"/><color rgb="FFA6A6A6"/></dataBar></cfRule>' }
            }
            $extra += '</conditionalFormatting>'
            $prio++
        }
    }
    Add-DefName $sheetIdx '_xlnm.Print_Titles' ("'" + $sh.Name + "'!`$4:`$6")
    $w.Write((Ws-End 'landscape' $true $false $sh.Title $extra))
    $w.Dispose()
}

$DefNames = New-Object System.Collections.Generic.List[object]
function Add-DefName([int]$sheetIdx, [string]$name, [string]$ref) { $DefNames.Add(@(($sheetIdx - 1), $name, $ref)) }

#------------------------------------------------------------------------------
# 見出しつきの小さな表を縦に並べるシート (④ CPU 判定・JFR 上位・JFR 記録・サマリーの一部)
#  書式: text / textc / wrap / key (見出し列) / bold / big (大きな文字) / int / dec1 / dec2 / dec3 / pct / dt
#        末尾に + を付けると、その列から右端までを結合する (長い文章)
#------------------------------------------------------------------------------
function New-Sec([string]$title, [string]$note, [string[]]$head, [string[]]$fmt) {
    return [pscustomobject]@{ Title = $title; Note = $note; Head = $head; Fmt = $fmt; Rows = (New-Object System.Collections.Generic.List[object]) }
}
function Sec-Add($sec, [object[]]$vals) { $sec.Rows.Add($vals) }
$SEC_STYLE = @{ text = $S_TEXT; textc = $S_TEXTC; wrap = $S_WRAP; key = $S_KEY; bold = $S_WRAPB; big = $S_BIG; int = $S_INT; dec1 = $S_DEC1; dec2 = $S_DEC2; dec3 = $S_DEC3; pct = $S_PCT; dt = $S_DT; intb = $S_INTB; dec1b = $S_DEC1B; dec2b = $S_DEC2B; pctb = $S_PCTB; muted = $S_MUTED; note = $S_NOTEW; sevh = $S_SEVH; sevm = $S_SEVM; sevl = $S_SEVL }
# 書式の末尾の +N は右へ N 列を結合 (+ だけなら右端まで)。値は @{ V = 値; F = 書式 } で 1 セルだけ書式を変えられる
function Sec-Span([string]$fm, [int]$pos, [int]$nc) {
    $m = [regex]::Match($fm, '^([a-z0-9]+)(\+([0-9]*))?$')
    $base = $m.Groups[1].Value; $span = 0
    if ($m.Groups[2].Success) { if ($m.Groups[3].Value -eq '') { $span = $nc - $pos } else { $span = [int]$m.Groups[3].Value } }
    if ($pos + $span -gt $nc) { $span = [Math]::Max(0, $nc - $pos) }
    return @($base, $span)
}
# セクションを XML の行にする。$r は開始行 ([ref])。結合範囲は $merges に足す
function Sec-Xml($sec, [double[]]$widths, [ref]$r, [System.Collections.Generic.List[string]]$merges) {
    $nc = $widths.Length
    $sb = New-Object System.Text.StringBuilder
    $row = $r.Value
    $total = 0.0; foreach ($x in $widths) { $total += $x }
    if ($sec.Title -ne '') { [void]$sb.Append((Row $row (StrC ('A' + $row) ('■ ' + $sec.Title) $S_SEC) 20)); $row++ }
    if ($sec.Note -ne '') {
        $cells = StrC ('A' + $row) $sec.Note $S_NOTEW
        for ($j = 2; $j -le $nc; $j++) { $cells += EmptyC ($COLN[$j] + $row) $S_NOTEW }
        [void]$sb.Append((Row $row $cells ([Math]::Max(15, (WrapHt $sec.Note ($total * 0.98)))))); $merges.Add('A' + $row + ':' + $COLN[$nc] + $row); $row++
    }
    if ($null -ne $sec.Head -and $sec.Head.Count -gt 0) {
        $cells = ''; $pos = 1; $hh = 20
        for ($i = 0; $i -lt $sec.Head.Count -and $pos -le $nc; $i++) {
            $sp = Sec-Span $sec.Fmt[$i] $pos $nc
            $cells += StrC ($COLN[$pos] + $row) $sec.Head[$i] $S_HDR
            for ($j = $pos + 1; $j -le $pos + $sp[1]; $j++) { $cells += EmptyC ($COLN[$j] + $row) $S_HDR }
            if ($sp[1] -gt 0) { $merges.Add($COLN[$pos] + $row + ':' + $COLN[$pos + $sp[1]] + $row) }
            # 見出しは太字のため少し広めに見積もって折り返しの行数を求める
            $wd = 0.0; for ($j = $pos; $j -le $pos + $sp[1]; $j++) { $wd += $widths[$j - 1] }
            $h = WrapHt $sec.Head[$i] ($wd * 0.85); if ($h -gt $hh) { $hh = $h }
            $pos += $sp[1] + 1
        }
        [void]$sb.Append((Row $row $cells $hh)); $row++
    }
    foreach ($vals in $sec.Rows) {
        $cells = ''; $ht = 0; $pos = 1
        for ($i = 0; $i -lt $sec.Fmt.Count -and $pos -le $nc; $i++) {
            $sp = Sec-Span $sec.Fmt[$i] $pos $nc
            $fm = $sp[0]
            $v = $null; if ($i -lt $vals.Count) { $v = $vals[$i] }
            if ($v -is [hashtable]) { if ($v.ContainsKey('F')) { $fm = $v['F'] }; $v = $v['V'] }
            $st = $SEC_STYLE[$fm]; if ($null -eq $st) { $st = $S_TEXT }
            $ref = $COLN[$pos] + $row
            if ($null -eq $v) { $cells += EmptyC $ref $st }
            elseif ($v -is [string] -or @('text', 'textc', 'wrap', 'key', 'bold', 'big', 'muted', 'sevh', 'sevm', 'sevl', 'note') -contains $fm) { $cells += StrC $ref ([string]$v) $st }
            else { $cells += NumC $ref $v $st }
            $wd = 0.0; for ($j = $pos; $j -le $pos + $sp[1]; $j++) { $wd += $widths[$j - 1] }
            for ($j = $pos + 1; $j -le $pos + $sp[1]; $j++) { $cells += EmptyC ($COLN[$j] + $row) $st }
            if ($sp[1] -gt 0) { $merges.Add($COLN[$pos] + $row + ':' + $COLN[$pos + $sp[1]] + $row) }
            if ($null -ne $v -and @('wrap', 'bold', 'big', 'key', 'text', 'note') -contains $fm) {
                # note は 9 ポイントのため 1 行に入る文字が多い
                $h = WrapHt ([string]$v) $(if ($fm -eq 'note') { $wd * 1.15 } else { $wd })
                if ($fm -eq 'big') { $h = [Math]::Max(30, $h * 1.25) }
                if ($fm -eq 'text' -or $fm -eq 'key') { $h = 0 }
                if ($h -gt $ht) { $ht = $h }
            }
            $pos += $sp[1] + 1
        }
        [void]$sb.Append((Row $row $cells $ht)); $row++
    }
    $r.Value = $row + 1
    return $sb.ToString()
}
function Write-SectionsSheet([int]$sheetIdx, [string]$name, [string]$title, [string]$note, [double[]]$widths, $secs, [string]$tab, [string]$orient, [bool]$selected, [string]$sub = '') {
    $nc = $widths.Length
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append((Ws-Begin $tab $true 0 0 $selected 90))
    [void]$sb.Append('<cols>')
    for ($c = 1; $c -le $nc; $c++) { [void]$sb.Append('<col min="' + $c + '" max="' + $c + '" width="' + $widths[$c - 1].ToString($Inv) + '" customWidth="1"/>') }
    [void]$sb.Append('</cols><sheetData>')
    [void]$sb.Append((Row 1 (StrC 'A1' $title $S_TITLE) 26))
    $merges = New-Object System.Collections.Generic.List[string]
    $total = 0.0; foreach ($x in $widths) { $total += $x }
    $r = 2
    if ($sub -ne '') { [void]$sb.Append((Row $r (StrC ('A' + $r) $sub $S_HEAD) 21)); $r++ }
    if ($note -ne '') { [void]$sb.Append((Row $r (StrC ('A' + $r) $note $S_NOTEW) ([Math]::Max(15, (WrapHt $note ($total * 0.98)))))); $merges.Add('A' + $r + ':' + $COLN[$nc] + $r); $r++ }
    $r++
    foreach ($sec in $secs) { if ($null -ne $sec) { [void]$sb.Append((Sec-Xml $sec $widths ([ref]$r) $merges)) } }
    [void]$sb.Append('</sheetData>')
    [void]$sb.Append((Ws-End $orient $true $false $title (Merges $merges)))
    Add-DefName $sheetIdx '_xlnm.Print_Area' ("'" + $name + "'!`$A`$1:`$" + $COLN[$nc] + '$' + [Math]::Max($r, 4))
    return $sb.ToString()
}

#------------------------------------------------------------------------------
# グラフ (DrawingML 散布図。時間軸は全グラフ共通)
#------------------------------------------------------------------------------
$LineStyles = @(
    @('000000', 22225, 'solid'), @('595959', 15875, 'dash'), @('8C8C8C', 15875, 'sysDot'),
    @('262626', 12700, 'lgDash'), @('A6A6A6', 15875, 'dashDot'), @('404040', 12700, 'sysDash'), @('7F7F7F', 12700, 'lgDashDot')
)
function C-Title([string]$t, [int]$sz) {
    return '<c:title><c:tx><c:rich><a:bodyPr/><a:lstStyle/><a:p><a:pPr><a:defRPr sz="' + $sz + '" b="1"><a:solidFill><a:srgbClr val="000000"/></a:solidFill>' + $FONT + '</a:defRPr></a:pPr><a:r><a:rPr lang="ja-JP" altLang="en-US" sz="' + $sz + '" b="1"><a:solidFill><a:srgbClr val="000000"/></a:solidFill>' + $FONT + '</a:rPr><a:t>' + (X $t) + '</a:t></a:r></a:p></c:rich></c:tx><c:overlay val="0"/></c:title>'
}
function Ax-Title([string]$t) {
    return '<c:title><c:tx><c:rich><a:bodyPr rot="-5400000" vert="horz"/><a:lstStyle/><a:p><a:pPr><a:defRPr sz="800" b="0"><a:solidFill><a:srgbClr val="404040"/></a:solidFill>' + $FONT + '</a:defRPr></a:pPr><a:r><a:rPr lang="ja-JP" altLang="en-US" sz="800" b="0"><a:solidFill><a:srgbClr val="404040"/></a:solidFill>' + $FONT + '</a:rPr><a:t>' + (X $t) + '</a:t></a:r></a:p></c:rich></c:tx><c:overlay val="0"/></c:title>'
}
function Tx-Pr([int]$sz, [string]$rot) {
    return '<c:txPr><a:bodyPr' + $(if ($rot -ne '') { ' rot="' + $rot + '" vert="horz"' } else { '' }) + '/><a:lstStyle/><a:p><a:pPr><a:defRPr sz="' + $sz + '"><a:solidFill><a:srgbClr val="404040"/></a:solidFill>' + $FONT + '</a:defRPr></a:pPr><a:endParaRPr lang="ja-JP"/></a:p></c:txPr>'
}
$AXLN = '<c:spPr><a:ln w="9525"><a:solidFill><a:srgbClr val="808080"/></a:solidFill></a:ln></c:spPr>'
$GRID = '<c:majorGridlines><c:spPr><a:ln w="6350"><a:solidFill><a:srgbClr val="E0E0E0"/></a:solidFill></a:ln></c:spPr></c:majorGridlines>'
function Rng([string]$sheet, [int]$col, [int]$r1, [int]$r2) { return "'" + $sheet + "'!`$" + $COLN[$col] + '$' + $r1 + ':$' + $COLN[$col] + '$' + $r2 }
function Ser-Sc([int]$i, $s) {
    $ln = $LineStyles[$i % $LineStyles.Count]
    $sp = '<c:spPr><a:ln w="' + $ln[1] + '" cap="rnd"><a:solidFill><a:srgbClr val="' + $ln[0] + '"/></a:solidFill><a:prstDash val="' + $ln[2] + '"/><a:round/></a:ln></c:spPr>'
    return '<c:ser><c:idx val="' + $i + '"/><c:order val="' + $i + '"/><c:tx><c:v>' + (X $s.N) + '</c:v></c:tx>' + $sp + '<c:marker><c:symbol val="none"/></c:marker><c:xVal><c:numRef><c:f>' + (X (Rng $s.S $s.X $s.R1 $s.R2)) + '</c:f></c:numRef></c:xVal><c:yVal><c:numRef><c:f>' + (X (Rng $s.S $s.Y $s.R1 $s.R2)) + '</c:f></c:numRef></c:yVal><c:smooth val="0"/></c:ser>'
}
function X-Scale() {
    $script:XSCL = ''; $script:XMAJ = ''; $script:XFMT = 'hh:mm'
    if ($null -eq $script:TMin -or $null -eq $script:TMax) { return }
    $x1 = $script:TMin; $x2 = $script:TMax; $span = $x2 - $x1
    if ($span -le 0) { $span = 1.0 / 1440 }
    $units = @((1 / 1440), (2 / 1440), (5 / 1440), (10 / 1440), (15 / 1440), (30 / 1440), (1 / 24), (2 / 24), (3 / 24), (6 / 24), (12 / 24), 1, 2, 7)
    $u = $units[$units.Count - 1]
    foreach ($cand in $units) { if ($span / $cand -le 12) { $u = $cand; break } }
    $lo = [Math]::Floor($x1 / $u + 1e-9) * $u
    $hi = [Math]::Ceiling($x2 / $u - 1e-9) * $u; if ($hi -le $lo) { $hi = $lo + $u }
    $script:XSCL = '<c:max val="' + $hi.ToString('R', $Inv) + '"/><c:min val="' + $lo.ToString('R', $Inv) + '"/>'
    $script:XMAJ = $u.ToString('R', $Inv)
    if ($span -ge 1.5) { $script:XFMT = 'm/d hh:mm' }
    if ($u -ge 1) { $script:XFMT = 'm/d' }
}
function Chart-Xml($ch, [int]$n) {
    $ax1 = 500000 + $n * 10 + 1; $ax2 = $ax1 + 1
    $plot = '<c:scatterChart><c:scatterStyle val="lineMarker"/><c:varyColors val="0"/>'
    $i = 0; foreach ($s in $ch.Series) { $plot += Ser-Sc $i $s; $i++ }
    $plot += '<c:axId val="' + $ax1 + '"/><c:axId val="' + $ax2 + '"/></c:scatterChart>'
    # X (時刻)
    $plot += '<c:valAx><c:axId val="' + $ax1 + '"/><c:scaling><c:orientation val="minMax"/>' + $script:XSCL + '</c:scaling><c:delete val="0"/><c:axPos val="b"/>'
    $plot += '<c:numFmt formatCode="' + (X $script:XFMT) + '" sourceLinked="0"/><c:majorTickMark val="out"/><c:minorTickMark val="none"/><c:tickLblPos val="low"/>' + $AXLN + (Tx-Pr 800 '-2700000')
    $plot += '<c:crossAx val="' + $ax2 + '"/><c:crosses val="min"/><c:crossBetween val="midCat"/>' + $(if ($script:XMAJ -ne '') { '<c:majorUnit val="' + $script:XMAJ + '"/>' } else { '' }) + '</c:valAx>'
    # Y
    $plot += '<c:valAx><c:axId val="' + $ax2 + '"/><c:scaling><c:orientation val="minMax"/>' + $(if ($null -ne $ch.YMax) { '<c:max val="' + ([double]$ch.YMax).ToString('R', $Inv) + '"/>' } else { '' }) + '<c:min val="0"/></c:scaling><c:delete val="0"/><c:axPos val="l"/>' + $GRID
    if ($ch.YTitle -ne '') { $plot += Ax-Title $ch.YTitle }
    $plot += '<c:numFmt formatCode="' + (X $ch.YFmt) + '" sourceLinked="0"/><c:majorTickMark val="out"/><c:minorTickMark val="none"/><c:tickLblPos val="nextTo"/>' + $AXLN + (Tx-Pr 800 '')
    $plot += '<c:crossAx val="' + $ax1 + '"/><c:crosses val="autoZero"/><c:crossBetween val="midCat"/>' + $(if ($null -ne $ch.YMajor) { '<c:majorUnit val="' + ([double]$ch.YMajor).ToString('R', $Inv) + '"/>' } else { '' }) + '</c:valAx>'
    return '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' + "`n" + '<c:chartSpace xmlns:c="http://schemas.openxmlformats.org/drawingml/2006/chart" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><c:date1904 val="0"/><c:lang val="ja-JP"/><c:roundedCorners val="0"/><c:chart>' + (C-Title $ch.Title 1000) + '<c:autoTitleDeleted val="0"/><c:plotArea><c:layout/>' + $plot + '<c:spPr><a:noFill/><a:ln><a:noFill/></a:ln></c:spPr></c:plotArea><c:legend><c:legendPos val="b"/><c:overlay val="0"/>' + (Tx-Pr 800 '') + '</c:legend><c:plotVisOnly val="1"/><c:dispBlanksAs val="gap"/></c:chart><c:spPr><a:solidFill><a:srgbClr val="FFFFFF"/></a:solidFill><a:ln w="9525"><a:solidFill><a:srgbClr val="A6A6A6"/></a:solidFill></a:ln></c:spPr><c:txPr><a:bodyPr/><a:lstStyle/><a:p><a:pPr><a:defRPr sz="900">' + $FONT + '</a:defRPr></a:pPr><a:endParaRPr lang="ja-JP"/></a:p></c:txPr></c:chartSpace>'
}
# 系列: 名前・シート・列 ID (X は 1 列目の日時)。グループ (データソース別など) の行範囲を使う
function Sr([string]$name, $sh, [string]$id, $grp = $null) {
    if ($null -eq $sh -or $sh.Rows.Count -eq 0 -or -not $sh.C.ContainsKey($id)) { return $null }
    if ($null -eq $grp) { $r1 = $DATA_ROW; $r2 = $DATA_ROW + $sh.Rows.Count - 1 } else { $r1 = $grp.R1; $r2 = $grp.R2 }
    # 値がひとつも無い列はグラフにしない
    $vals = ColVals $sh $id $grp
    if ($vals.Count -eq 0) { return $null }
    $mx = [double]::MinValue; foreach ($v in $vals) { if ($v -gt $mx) { $mx = $v } }
    return [pscustomobject]@{ N = $name; S = $sh.Name; X = 1; Y = [int]$sh.C[$id]; R1 = $r1; R2 = $r2; M = $mx }
}
$ChartSecs = New-Object System.Collections.Generic.List[object]
function Add-ChartSection([string]$title) { $ChartSecs.Add([pscustomobject]@{ Title = $title; Charts = (New-Object System.Collections.Generic.List[object]) }) }
function Add-Chart([string]$title, [string]$ytitle, [string]$yfmt, [object[]]$series, $ymax = $null) {
    $ss = @(); foreach ($s in $series) { if ($null -ne $s) { $ss += $s } }
    if ($ss.Count -eq 0) { return }
    # 値が小さい (0 だけなど) と Excel の自動の目盛りが 0.2 刻みになり、整数の書式で 0, 0, 0, 1, 1 のように重なるため、1 刻みにする
    $dmax = 0.0; foreach ($s in $ss) { if ($s.M -gt $dmax) { $dmax = $s.M } }
    $ymaj = $null
    if ($null -eq $ymax -and $dmax -lt 6) {
        if ($yfmt -eq '#,##0') { $ymax = [Math]::Max(1.0, [Math]::Ceiling($dmax)); $ymaj = 1.0 }
        elseif ($dmax -le 0) { $ymax = 1.0 }
    }
    $ChartSecs[$ChartSecs.Count - 1].Charts.Add([pscustomobject]@{ Title = $title; YTitle = $ytitle; YFmt = $yfmt; Series = $ss; YMax = $ymax; YMajor = $ymaj })
}

function Write-ChartsSheet([System.IO.Compression.ZipArchive]$zip, [int]$sheetIdx, [string]$sheetName, [string]$title, [string]$note) {
    X-Scale
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append((Ws-Begin 'FF262626' $true 0 0 $false 85))
    [void]$sb.Append('<cols><col min="1" max="18" width="9.5" customWidth="1"/></cols><sheetData>')
    [void]$sb.Append((Row 1 (StrC 'A1' $title $S_TITLE) 24))
    [void]$sb.Append((Row 2 (StrC 'A2' $note $S_NOTEW) ([Math]::Max(15, (WrapHt $note 160)))))
    $anch = New-Object System.Text.StringBuilder; $rels = New-Object System.Text.StringBuilder
    $n = 0; $r = 3; $brk = ''; $nbrk = 0
    foreach ($sec in $ChartSecs) {
        if ($sec.Charts.Count -eq 0) { continue }
        if ($r -gt 3) { $brk += '<brk id="' + ($r) + '" max="16383" man="1"/>'; $nbrk++ }
        $r++
        [void]$sb.Append((Row $r (StrC ('A' + $r) ('■ ' + $sec.Title) $S_HEAD) 21))
        $k = 0
        foreach ($ch in $sec.Charts) {
            $n++
            $col = $(if ($k % 2 -eq 0) { 0 } else { 9 })
            $top = $r + [int][Math]::Floor($k / 2) * 19
            # 印刷: 1 ページに 2 段 (4 グラフ) まで。グラフがページをまたがないよう改ページを入れる
            if ($k -gt 0 -and $k % 4 -eq 0) { $brk += '<brk id="' + $top + '" max="16383" man="1"/>'; $nbrk++ }
            $e = $zip.CreateEntry("xl/charts/chart$n.xml", [IO.Compression.CompressionLevel]::Optimal)
            $cw = New-Object IO.StreamWriter($e.Open(), $Utf8); $cw.Write((Chart-Xml $ch $n)); $cw.Dispose()
            [void]$anch.Append('<xdr:twoCellAnchor editAs="oneCell"><xdr:from><xdr:col>' + $col + '</xdr:col><xdr:colOff>0</xdr:colOff><xdr:row>' + $top + '</xdr:row><xdr:rowOff>60000</xdr:rowOff></xdr:from><xdr:to><xdr:col>' + ($col + 9) + '</xdr:col><xdr:colOff>0</xdr:colOff><xdr:row>' + ($top + 18) + '</xdr:row><xdr:rowOff>0</xdr:rowOff></xdr:to><xdr:graphicFrame macro=""><xdr:nvGraphicFramePr><xdr:cNvPr id="' + ($n + 1) + '" name="Chart ' + $n + '"/><xdr:cNvGraphicFramePr/></xdr:nvGraphicFramePr><xdr:xfrm><a:off x="0" y="0"/><a:ext cx="0" cy="0"/></xdr:xfrm><a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/chart"><c:chart xmlns:c="http://schemas.openxmlformats.org/drawingml/2006/chart" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" r:id="rId' + $n + '"/></a:graphicData></a:graphic></xdr:graphicFrame><xdr:clientData/></xdr:twoCellAnchor>')
            [void]$rels.Append('<Relationship Id="rId' + $n + '" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/chart" Target="../charts/chart' + $n + '.xml"/>')
            $k++
        }
        $r += [int][Math]::Ceiling($sec.Charts.Count / 2.0) * 19 + 1
    }
    if ($n -eq 0) { [void]$sb.Append((Row 4 (StrC 'A4' '（グラフに使える時系列データがありません）' $S_NOTE) 0)) }
    [void]$sb.Append('</sheetData>')
    $extra = ''
    if ($nbrk -gt 0) { $extra = '<rowBreaks count="' + $nbrk + '" manualBreakCount="' + $nbrk + '">' + $brk + '</rowBreaks>' }
    # rowBreaks は pageSetup の後ろに置く必要がある
    $end = Ws-End 'landscape' $true ($n -gt 0) $title '<mergeCells count="1"><mergeCell ref="A2:R2"/></mergeCells>'
    if ($extra -ne '') { $end = $end.Replace('</headerFooter>', '</headerFooter>' + $extra) }
    [void]$sb.Append($end)
    if ($n -gt 0) {
        Add-TextEntry $zip 'xl/drawings/drawing1.xml' ('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' + "`n" + '<xdr:wsDr xmlns:xdr="http://schemas.openxmlformats.org/drawingml/2006/spreadsheetDrawing" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">' + $anch.ToString() + '</xdr:wsDr>')
        Add-TextEntry $zip 'xl/drawings/_rels/drawing1.xml.rels' ('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' + "`n" + '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">' + $rels.ToString() + '</Relationships>')
    }
    Add-DefName $sheetIdx '_xlnm.Print_Area' ("'" + $sheetName + "'!`$A`$1:`$R`$" + [Math]::Max($r, 4))
    $script:NCH = $n
    return $sb.ToString()
}

function Add-TextEntry([System.IO.Compression.ZipArchive]$zip, [string]$name, [string]$content) {
    $e = $zip.CreateEntry($name, [IO.Compression.CompressionLevel]::Optimal)
    $w = New-Object IO.StreamWriter($e.Open(), $Utf8); $w.Write($content); $w.Dispose()
}

#------------------------------------------------------------------------------
# 収集情報 (perf_meta.csv) と、レポートの対象 (コンテナ・サービス)
#------------------------------------------------------------------------------
function Read-Meta([string]$dir) {
    $meta = [ordered]@{}
    $mp = Join-Path $dir 'perf_meta.csv'
    if (Test-Path -LiteralPath $mp) {
        foreach ($l in [IO.File]::ReadAllLines($mp, $Utf8)) {
            if ($l.Length -eq 0) { continue }
            $f = Split-Csv $l
            if ($f.Length -lt 3) { continue }
            $k = $f[0] + '.' + $f[1]
            if ($meta.Contains($k)) { $meta.Remove($k) }
            $meta[$k] = $f[2]
        }
    }
    return $meta
}
# ログの出力先 /mnt/logs/<front|back>/logs/<サービス>/mid/<LOG_ID>/perf から、コンテナ・サービスの名前を決める
#   front → フロントコンテナ、back → バックコンテナ
#   intra-web / intra-api / inter-api / sf-api → intra-webサービス / intra-apiサービス / inter-apiサービス / sf-apiサービス
function Get-Who($meta, [string]$dir) {
    $comp = ''; $svc = ''; $src = ''
    foreach ($p in @([string]$meta['perf.output_dir'], $dir)) {
        if ([string]::IsNullOrEmpty($p)) { continue }
        $m = [regex]::Match($p.Replace('\', '/'), '(?i)(?:^|/)([^/]+)/logs/([^/]+)/mid(?:/|$)')
        if ($m.Success) { $comp = $m.Groups[1].Value; $svc = $m.Groups[2].Value; $src = $p; break }
    }
    if ($comp -eq '') { $comp = [string]$meta['container.component_role'] }
    if ($comp -eq '') { $comp = [string]$meta['container.component_name'] }
    if ($svc -eq '') { $svc = [string]$meta['container.service_name'] }
    # Component_name は front / back のほか、pin 方式の設計書の例のように interapi-front・intra-web-back
    # (コンテナ名) の場合もあるため、末尾の front / back で判定する。分からなければ COMPONENT_ROLE を使う
    $c = $comp.Trim().ToLowerInvariant()
    $role = ([string]$meta['container.component_role']).Trim().ToLowerInvariant()
    if ($c -match '(^|[-_.])(front|frontend)$') { $c = 'front' } elseif ($c -match '(^|[-_.])(back|backend)$') { $c = 'back' }
    elseif ($role -eq 'front' -or $role -eq 'back') { $c = $role }
    $cl = $(if ($c -eq 'front') { 'フロントコンテナ' } elseif ($c -eq 'back') { 'バックコンテナ' } elseif ($c -ne '') { $comp.Trim() + 'コンテナ' } else { '' })
    $s = $svc.Trim().ToLowerInvariant().Replace('_', '-')
    $m = [regex]::Match($s, '^(intra|inter|sf)-?(web|api)$')
    if ($m.Success) { $s = $m.Groups[1].Value + '-' + $m.Groups[2].Value }
    $sl = $(if ($s -ne '') { $s + 'サービス' } else { '' })
    $lid = [string]$meta['container.log_id']
    if ($lid -eq '') { $lid = Split-Path -Leaf (Split-Path -Parent $dir) }
    $bad = '[' + [regex]::Escape(-join [IO.Path]::GetInvalidFileNameChars()) + ']'
    $parts = @('perf_report')
    foreach ($x in @($cl, $sl, $lid)) { if ($x -ne '') { $parts += [regex]::Replace($x, $bad, '_') } }
    return [pscustomobject]@{
        Comp = $c; CompLabel = $cl; Svc = $s; SvcLabel = $sl; LogId = $lid; From = $src
        Label = ((@($cl, $sl) | Where-Object { $_ -ne '' }) -join ' / ')
        FileName = ($parts -join '_') + '.xlsx'
        Key = ($c + '|' + $s + '|' + $lid)
    }
}

#------------------------------------------------------------------------------
# JFR (.jfr) → CSV (-ConvertJfr)。perf/jfr/PerfJfrCsv.java (perf-metrics.sh が書いたもの) を PC の JDK で実行する
#------------------------------------------------------------------------------
function Find-Java() {
    if ($JavaPath -ne '') { if (Test-Path -LiteralPath $JavaPath) { return (Resolve-Path -LiteralPath $JavaPath).ProviderPath }; throw "java が見つかりません: $JavaPath" }
    if ($env:JAVA_HOME) { $j = Join-Path $env:JAVA_HOME 'bin\java.exe'; if (Test-Path -LiteralPath $j) { return $j } }
    $c = Get-Command java -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
    return $null
}
function Convert-Jfr([string]$dir, [string]$interval) {
    $jd = Join-Path $dir 'jfr'
    $src = Join-Path $jd 'PerfJfrCsv.java'
    if (-not (Test-Path -LiteralPath $src)) { Write-Warning "JFR の変換プログラムがありません: $src"; return $null }
    # 入力に含まれるプログラムを実行するため、perf-metrics.sh 3.0.0 が書いたものと同じか確かめる
    $hash = (Get-FileHash -LiteralPath $src -Algorithm SHA256).Hash
    if ($JfrJavaSha256 -notcontains $hash) {
        Write-Warning ("$src が perf-metrics.sh $Version の PerfJfrCsv.java と一致しません (SHA-256 $hash)。安全のため変換しません。コンテナで perf-metrics.sh jfr-csv を実行してください")
        return $null
    }
    $files = @(Get-ChildItem -LiteralPath $jd -Recurse -File -Filter '*.jfr' -ErrorAction SilentlyContinue)
    if ($files.Count -eq 0) { Write-Warning "JFR のファイル (.jfr) がありません: $jd"; return $null }
    $java = Find-Java
    if (-not $java) { Write-Warning 'java (JDK 17 以降) が見つかりません。-JavaPath で java.exe を指定してください'; return $null }
    $out = New-TempDir
    if ($interval -notmatch '^[0-9]+$') { $interval = '10' }
    Write-Info ("JFR を CSV に変換しています ({0} ファイル、{1})..." -f $files.Count, $java)
    $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try {
        & $java -XX:+UseSerialGC -Xmx1g $src $out $interval $jd 2>&1 | ForEach-Object { Write-Info ('  ' + $_) }
        $rc = $LASTEXITCODE
    } finally { $ErrorActionPreference = $old }
    if ($rc -ne 0) { Write-Warning "JFR の変換に失敗しました (終了コード $rc)"; return $null }
    return $out
}

#------------------------------------------------------------------------------
# 1 つの perf/ ディレクトリからブックを作る
#------------------------------------------------------------------------------
$TsNames = @('cli_datasource', 'cli_undertow', 'cli_session', 'cli_threadpool', 'cli_io_worker', 'cli_transactions', 'cli_jvm',
    'jvm_jstat_gc', 'jvm_jcmd_heap', 'jvm_codecache', 'jvm_nmt', 'jvm_thread_states', 'jfr_gc', 'jfr_stats',
    'os_top_summary', 'os_top_process', 'os_top_threads', 'os_ps', 'os_jboss_threads', 'os_jboss_proc', 'cpu_sched')
$AllNames = @('cpu_env', 'jfr_hot_methods', 'jfr_contention', 'jfr_io', 'jfr_vm_operations', 'jfr_env', 'jfr_summary')
$TGL = [ordered]@{ 'all' = '全体'; 'http-task' = 'HTTP 処理'; 'http-io' = 'HTTP I/O'; 'ee-ejb' = 'EE・EJB'; 'jboss' = 'JBoss 内部'; 'gc' = 'GC'; 'jit' = 'JIT'; 'jfr' = 'JFR'; 'vm' = 'JVM 内部'; 'jvm' = 'JVM 内部'; 'other' = 'その他'; 'db-pool-wait' = 'DB 接続待ち' }
function TG([string]$g) { $x = $TGL[$g]; if ($null -eq $x) { return $g }; return $x }
$POOLL = @{ 'ejb3' = 'EJB'; 'ee-executor' = 'EE 管理エグゼキューター'; 'ee-scheduled' = 'EE スケジュール' }
$T1 = 'FF404040'; $T2 = 'FF595959'; $T3 = 'FF7F7F7F'; $T4 = 'FF262626'; $T0 = 'FFA6A6A6'
$MB = 1.0 / 1048576; $KM = 1.0 / 1024

function Build-Report([string]$dir, [string]$outPath, $who) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    Write-Info "入力: $dir"
    $DefNames.Clear(); $ChartSecs.Clear()

    # ---- 収集情報・時刻 ----
    $meta = Read-Meta $dir
    function M([string]$k) { if ($meta.Contains($k)) { return [string]$meta[$k] }; return '' }
    $script:RecOffset = 0
    $uo = M 'perf.utc_offset'
    if ($uo -match '^([+-])([0-9]{2})([0-9]{2})$') { $sg = $(if ($Matches[1] -eq '-') { -1 } else { 1 }); $script:RecOffset = $sg * ([int]$Matches[2] * 3600 + [int]$Matches[3] * 60) }
    $PerfRpt::UseRecorded = [bool]$UseRecordedTime; $PerfRpt::RecOffset = [double]$script:RecOffset; $PerfRpt::ResetTz()
    $script:FromEpoch = [double]::MinValue; $script:ToEpoch = [double]::MaxValue
    foreach ($pair in @(@($From, 'FromEpoch'), @($To, 'ToEpoch'))) {
        if ($pair[0] -eq '') { continue }
        $dt = [DateTime]::Parse($pair[0], $Inv)
        if ($UseRecordedTime) { $ep = ($dt - [DateTime]'1970-01-01').TotalSeconds - $script:RecOffset }
        else { $ep = ([DateTimeOffset]::new($dt, [TimeZoneInfo]::Local.GetUtcOffset($dt))).ToUnixTimeSeconds() }
        Set-Variable -Scope Script -Name $pair[1] -Value ([double]$ep)
    }
    $filtered = ($From -ne '' -or $To -ne '')

    # ---- JFR の CSV (無ければ -ConvertJfr で PC の JDK を使って変換) ----
    $jfrDir = $dir; $jfrNote = ''
    if ($ConvertJfr) {
        $cv = Convert-Jfr $dir (M 'perf.jfr_interval')
        if ($cv) { $jfrDir = $cv; $jfrNote = 'JFR の CSV はこの PC で変換しました (-ConvertJfr)' }
    }

    # ---- CSV ----
    $TB = @{}; $AT = @{}
    foreach ($n in $TsNames) {
        $src = $(if ($n.StartsWith('jfr_')) { $jfrDir } else { $dir })
        $t = Read-PerfCsv $src ($n + '.csv')
        if ($null -ne $t -and $t.Rows.Count -gt 0) { $TB[$n] = $t; Write-Info ("読み込み: {0}.csv ({1:N0} 行)" -f $n, $t.Rows.Count) }
    }
    foreach ($n in $AllNames) {
        $src = $(if ($n.StartsWith('jfr_')) { $jfrDir } else { $dir })
        $t = $PerfRpt::ReadCsv((Join-Path $src ($n + '.csv')), $n, [double]::MinValue, [double]::MaxValue)
        if ($null -ne $t -and $t.Rows.Count -gt 0) { $AT[$n] = $t; Write-Info ("読み込み: {0}.csv ({1:N0} 行)" -f $n, $t.Rows.Count) }
    }
    $logLines = @()
    $lp = Join-Path $dir 'collector.log'
    if (Test-Path -LiteralPath $lp) { $logLines = [IO.File]::ReadAllLines($lp, $Utf8) }
    if ($TB.Count -eq 0) { Write-Warning "この期間のデータがありません: $dir"; return }
    $hasJfrFiles = (Test-Path -LiteralPath (Join-Path $dir 'jfr')) -and (@(Get-ChildItem -LiteralPath (Join-Path $dir 'jfr') -Recurse -File -Filter '*.jfr' -ErrorAction SilentlyContinue).Count -gt 0)

    # 全体の時間範囲 (グラフの時間軸)
    $script:TMin = $null; $script:TMax = $null
    foreach ($t in $TB.Values) {
        $ei = [int]$t.I['epoch']
        $a = $PerfRpt::XT([double]$t.Rows[0][$ei]); $b = $PerfRpt::XT([double]$t.Rows[$t.Rows.Count - 1][$ei])
        if ($null -eq $script:TMin -or $a -lt $script:TMin) { $script:TMin = $a }
        if ($null -eq $script:TMax -or $b -gt $script:TMax) { $script:TMax = $b }
    }

    # ---- ④ CPU 環境 (cpu_env.csv。JBoss が再起動していれば最後の JVM) ----
    $CE = [ordered]@{}; $CEN = @{}
    if ($AT.ContainsKey('cpu_env')) {
        $t = $AT['cpu_env']; $lastPid = $PerfRpt::G($t, $t.Rows[$t.Rows.Count - 1], 'pid')
        foreach ($r in $t.Rows) {
            if ($PerfRpt::G($t, $r, 'pid') -ne $lastPid) { continue }
            $k = $PerfRpt::G($t, $r, 'category') + '.' + $PerfRpt::G($t, $r, 'key')
            $CE[$k] = $PerfRpt::G($t, $r, 'value'); $CEN[$k] = $PerfRpt::G($t, $r, 'note')
        }
    }
    function CE([string]$k) { if ($CE.Contains($k)) { return [string]$CE[$k] }; return '' }
    $share = $PerfRpt::D((CE 'judgement.share_vcpu')); $jvmCpus = $PerfRpt::D((CE 'judgement.jvm_cpus'))
    # 最大ヒープ (MB) と GC の種類。G1 は Old 領域の容量 (OC) が使用量に合わせて伸び縮みするため、
    # Old の逼迫は OU÷OC ではなく「OU ÷ 最大ヒープ」で見る
    $maxHeapMB = $null
    $x = $PerfRpt::D((CE 'jvm.MaxHeapSize')); if ($null -ne $x -and $x -gt 0) { $maxHeapMB = $x / 1048576 }
    if ($null -eq $maxHeapMB -and $TB.ContainsKey('cli_jvm')) {
        $t = $TB['cli_jvm']
        for ($i = $t.Rows.Count - 1; $i -ge 0; $i--) { $x = $PerfRpt::GD($t, $t.Rows[$i], 'heap_max'); if ($null -ne $x -and $x -gt 0) { $maxHeapMB = $x / 1048576; break } }
    }
    if ($null -eq $maxHeapMB -and $AT.ContainsKey('jfr_env')) {
        $t = $AT['jfr_env']; foreach ($r in $t.Rows) { if ($PerfRpt::G($t, $r, 'category') -eq 'heap' -and $PerfRpt::G($t, $r, 'key') -eq 'maxSize') { $x = $PerfRpt::GD($t, $r, 'value'); if ($null -ne $x -and $x -gt 0) { $maxHeapMB = $x / 1048576 } } }
    }
    $isG1 = ((CE 'jvm.gc') -eq 'G1')
    if (-not $isG1 -and $TB.ContainsKey('jvm_jcmd_heap')) { $t = $TB['jvm_jcmd_heap']; $isG1 = ($PerfRpt::G($t, $t.Rows[0], 'gc') -eq 'G1') }

    $Sheets = New-Object System.Collections.Generic.List[object]
    $SM = @{}
    function Put([string]$key, $sh) { if ($null -ne $sh) { $Sheets.Add($sh); $SM[$key] = $sh } }

    # ==================== ① jboss-cli ====================
    if ($TB.ContainsKey('cli_datasource')) {
        Write-Info '集計: ① DB 接続プール'
        $sh = Build-Sheet $TB['cli_datasource'] '①DB接続プール' 'DB 接続プール（データソース別の時系列）' ('① jboss-cli の /subsystem=datasources/data-source=*/statistics=pool (XA データソースも同じ)。「区間」は前回の取得からの増分です。平均待ちスレッド数 = 区間に空き接続を待った時間の合計 ÷ 経過時間 (例: 2.0 = 平均して 2 スレッドが待っていた)、平均使用接続数 = 区間に接続を使っていた時間の合計 ÷ 経過時間。最大プールが未設定のデータソースは IronJacamar の既定値 20 で使用率を計算しています (取得タイムアウトの空欄は既定値 30000 ms)。') 2 $T1 @(
            (CT), (C 'name' '基本' 'データソース' 'ds_name' 'text' 18 'raw' 'ds_name'), (C 'type' '基本' '種類' 'ds_type' 'textc' 6 'raw' 'ds_type'),
            (C 'in' '接続数' '使用中' 'InUseCount' 'int' 8 'raw' 'InUseCount'),
            (C 'ac' '接続数' 'アクティブ' 'ActiveCount' 'int' 9 'raw' 'ActiveCount'),
            (C 'id' '接続数' 'アイドル' 'IdleCount' 'int' 8 'raw' 'IdleCount'),
            (C 'av' '接続数' '取得可能' 'AvailableCount' 'int' 8 'raw' 'AvailableCount'),
            (C 'mx' '接続数' '最大プール' 'max_pool_size' 'int' 9 'dflt' 'max_pool_size' 1 20),
            (C 'us' '接続数' '使用率' 'InUse÷最大プール' 'pct' 9 'ratio' 'InUseCount,max_pool_size' 1 20),
            (C 'wd' '待ち・失敗（区間）' '待ち' 'Δ WaitCount' 'int' 8 'delta' 'WaitCount'),
            (C 'fd' '待ち・失敗（区間）' '取得失敗' 'Δ BlockingFailureCount' 'int' 9 'delta' 'BlockingFailureCount'),
            (C 'bw' '待ち・失敗（区間）' '平均待ちスレッド数' 'Δ TotalBlockingTime÷経過' 'dec2' 11 'rate' 'TotalBlockingTime' 0.001),
            (C 'uc' '待ち・失敗（区間）' '平均使用接続数' 'Δ TotalUsageTime÷経過' 'dec2' 10 'rate' 'TotalUsageTime' 0.001),
            (C 'gt' '待ち・失敗（区間）' '取得時間の合計(ms)' 'Δ TotalGetTime' 'int' 11 'delta' 'TotalGetTime'),
            (C 'wc' '累計' '待ち' 'WaitCount' 'int' 9 'raw' 'WaitCount'),
            (C 'fc' '累計' '取得失敗' 'BlockingFailureCount' 'int' 9 'raw' 'BlockingFailureCount'),
            (C 'mw' '累計' '最大同時待ち' 'MaxWaitCount' 'int' 9 'raw' 'MaxWaitCount'),
            (C 'mu' '累計' '最大使用数' 'MaxUsedCount' 'int' 9 'raw' 'MaxUsedCount'),
            (C 'ag' '時間（ms、累計）' '平均取得' 'AverageGetTime' 'int' 8 'raw' 'AverageGetTime'),
            (C 'mg' '時間（ms、累計）' '最大取得' 'MaxGetTime' 'int' 8 'raw' 'MaxGetTime'),
            (C 'ab' '時間（ms、累計）' '平均待ち' 'AverageBlockingTime' 'int' 8 'raw' 'AverageBlockingTime'),
            (C 'mwt' '時間（ms、累計）' '最大待ち' 'MaxWaitTime' 'int' 8 'raw' 'MaxWaitTime'),
            (C 'au' '時間（ms、累計）' '平均使用' 'AverageUsageTime' 'int' 8 'raw' 'AverageUsageTime'),
            (C 'mut' '時間（ms、累計）' '最大使用' 'MaxUsageTime' 'int' 8 'raw' 'MaxUsageTime'),
            (C 'mc' '時間（ms、累計）' '最大作成' 'MaxCreationTime' 'int' 8 'raw' 'MaxCreationTime'),
            (C 'cr' '物理接続（区間）' '作成' 'Δ CreatedCount' 'int' 7 'delta' 'CreatedCount'),
            (C 'de' '物理接続（区間）' '破棄' 'Δ DestroyedCount' 'int' 7 'delta' 'DestroyedCount'),
            (C 'to' '物理接続（区間）' 'アイドル破棄' 'Δ TimedOut' 'int' 9 'delta' 'TimedOut'),
            (C 'xc' 'XA（区間）' 'コミット' 'Δ XACommitCount' 'int' 8 'delta' 'XACommitCount'),
            (C 'xr' 'XA（区間）' 'ロールバック' 'Δ XARollbackCount' 'int' 9 'delta' 'XARollbackCount'),
            (C 'xp' 'XA（区間）' 'プリペア' 'Δ XAPrepareCount' 'int' 8 'delta' 'XAPrepareCount'),
            (C 'xcm' 'XA（ms、累計）' 'コミット最大' 'XACommitMaxTime' 'int' 12 'raw' 'XACommitMaxTime'),
            (C 'mn' '設定' '最小プール' 'min_pool_size' 'int' 8 'raw' 'min_pool_size'),
            (C 'bt' '設定' '取得タイムアウト(ms)' 'blocking_timeout_ms' 'int' 11 'raw' 'blocking_timeout_ms'),
            (C 'jn' '設定' 'JNDI 名' 'jndi_name' 'text' 30 'raw' 'jndi_name'),
            (C 'se' '設定' '統計' 'statistics_enabled' 'textc' 7 'raw' 'statistics_enabled')
        ) @('ds_type', 'ds_name')
        Add-CF $sh 'us' 'bar' '1' 0; Add-CF $sh 'us' 'ge' '0.8' 1; Add-CF $sh 'wd' 'gt' '0' 1; Add-CF $sh 'fd' 'gt' '0' 0; Add-CF $sh 'bw' 'ge' '1' 1
        Put 'ds' $sh
    }
    if ($TB.ContainsKey('cli_undertow')) {
        Write-Info '集計: ① HTTP'
        $sh = Build-Sheet $TB['cli_undertow'] '①HTTP' 'HTTP リスナー（Undertow、リスナー別の時系列）' ('① jboss-cli の /subsystem=undertow/server=*/http-listener=* など。エラーは 500 番台の応答の数 (error-count) です。平均・最大処理時間は、リスナーの record-request-start-time=true のときだけ値が入ります (既定は false のため空欄。応答時間は JMeter の結果で確認してください)。送受信バイト数は Container Insights のネットワーク転送量と重なるため取得していません。') 2 $T1 @(
            (CT), (C 'l' '基本' 'リスナー' 'server / type / listener' 'text' 30 'join' 'server,listener_type,listener'),
            (C 'rq' 'リクエスト（区間）' '件数' 'Δ request-count' 'int' 9 'delta' 'request-count'),
            (C 'rps' 'リクエスト（区間）' '毎秒' 'Δ request-count÷経過' 'dec2' 9 'rate' 'request-count'),
            (C 'er' 'リクエスト（区間）' 'エラー' 'Δ error-count' 'int' 8 'delta' 'error-count'),
            (C 'erp' 'リクエスト（区間）' 'エラー率' 'Δ error÷Δ request' 'pct' 8 'dratio' 'error-count,request-count'),
            (C 'avg' '処理時間（ms）' '平均（区間）' 'Δ processing-time÷Δ request' 'dec2' 10 'dratio' 'processing-time,request-count' 0.000001),
            (C 'max' '処理時間（ms）' '最大（累計）' 'max-processing-time' 'dec1' 10 'scale' 'max-processing-time' 0.000001),
            (C 'tot' '累計' 'リクエスト' 'request-count' 'int' 11 'raw' 'request-count'),
            (C 'etot' '累計' 'エラー' 'error-count' 'int' 9 'raw' 'error-count'),
            (C 'st' '設定' '統計' 'statistics_enabled' 'textc' 7 'raw' 'statistics_enabled'),
            (C 'rr' '設定' '処理時間の記録' 'record_request_start_time' 'textc' 10 'raw' 'record_request_start_time')
        ) @('server', 'listener_type', 'listener')
        # 処理時間を記録していないリスナーの 0 は「不明」なので空欄にする
        if ($sh.C.ContainsKey('rr')) {
            $ci = [int]$sh.C['rr'] - 1
            foreach ($row in $sh.Rows) { if ([string]$row[$ci] -ne 'true') { foreach ($id in @('avg', 'max')) { if ($sh.C.ContainsKey($id)) { $row[[int]$sh.C[$id] - 1] = $null } } } }
        }
        Add-CF $sh 'er' 'gt' '0' 0; Add-CF $sh 'erp' 'gt' '0' 1
        Put 'web' $sh
    }
    if ($TB.ContainsKey('cli_session')) {
        Write-Info '集計: ① セッション'
        $sh = Build-Sheet $TB['cli_session'] '①セッション' 'HTTP セッション（デプロイメント別の時系列）' '① jboss-cli の /deployment=*/subsystem=undertow。上限 -1 は無制限です。生存時間は期限切れになったセッションの値です (秒)。セッションはヒープを使うため、作成数が多いときはヒープ使用量と合わせて確認してください。' 2 $T1 @(
            (CT), (C 'dep' '基本' 'デプロイメント' 'deployment' 'text' 22 'raw' 'deployment'), (C 'ctx' '基本' 'コンテキスト' 'context-root' 'text' 14 'raw' 'context-root'),
            (C 'act' 'セッション数' 'アクティブ' 'active-sessions' 'int' 10 'raw' 'active-sessions'),
            (C 'hi' 'セッション数' '最大（累計）' 'highest-session-count' 'int' 10 'raw' 'highest-session-count'),
            (C 'mx' 'セッション数' '上限' 'max-active-sessions' 'int' 8 'raw' 'max-active-sessions'),
            (C 'cr' '区間' '作成' 'Δ sessions-created' 'int' 8 'delta' 'sessions-created'),
            (C 'crs' '区間' '作成 毎秒' 'Δ sessions-created÷経過' 'dec2' 9 'rate' 'sessions-created'),
            (C 'ex' '区間' '期限切れ' 'Δ expired-sessions' 'int' 8 'delta' 'expired-sessions'),
            (C 'rj' '区間' '拒否' 'Δ rejected-sessions' 'int' 7 'delta' 'rejected-sessions'),
            (C 'avg' '生存時間（秒）' '平均' 'session-avg-alive-time' 'int' 8 'raw' 'session-avg-alive-time'),
            (C 'max' '生存時間（秒）' '最大' 'session-max-alive-time' 'int' 8 'raw' 'session-max-alive-time'),
            (C 'ctot' '累計' '作成' 'sessions-created' 'int' 10 'raw' 'sessions-created')
        ) @('deployment')
        Add-CF $sh 'rj' 'gt' '0' 0
        Put 'ses' $sh
    }
    if ($TB.ContainsKey('cli_threadpool')) {
        Write-Info '集計: ① スレッドプール'
        $sh = Build-Sheet $TB['cli_threadpool'] '①スレッドプール' 'EE・EJB のスレッドプール（プール別の時系列）' '① jboss-cli の /subsystem=ejb3/thread-pool=* と /subsystem=ee/managed-executor-service=*・managed-scheduled-executor-service=*。EJB は「最大到達」= largest-thread-count、EE は max-thread-count です。拒否は EJB だけ、ハング (hung-task-threshold 超過) は EE だけの項目です。HTTP の処理スレッドは「①IOワーカー」を見てください。' 2 $T1 @(
            (CT), (C 'ty' '基本' '種類' 'pool_type' 'text' 12 'raw' 'pool_type'), (C 'pl' '基本' 'プール' 'pool' 'text' 16 'raw' 'pool'),
            (C 'ac' 'スレッド' '実行中' 'active' 'int' 8 'raw' 'active'), (C 'cu' 'スレッド' '現在' 'current' 'int' 7 'raw' 'current'),
            (C 'lg' 'スレッド' '最大到達' 'largest' 'int' 8 'raw' 'largest'), (C 'mx' 'スレッド' '上限' 'max' 'int' 7 'raw' 'max'),
            (C 'q' '待ち' 'キュー' 'queue' 'int' 7 'raw' 'queue'), (C 'hg' '待ち' 'ハング' 'hung' 'int' 7 'raw' 'hung'),
            (C 'cp' '区間' '完了' 'Δ completed' 'int' 8 'delta' 'completed'), (C 'rj' '区間' '拒否' 'Δ rejected' 'int' 7 'delta' 'rejected'),
            (C 'tk' '累計' 'タスク' 'tasks' 'int' 9 'raw' 'tasks')
        ) @('pool_type', 'pool')
        Add-CF $sh 'q' 'gt' '0' 1; Add-CF $sh 'rj' 'gt' '0' 0; Add-CF $sh 'hg' 'gt' '0' 1
        Put 'tp' $sh
    }
    if ($TB.ContainsKey('cli_io_worker')) {
        Write-Info '集計: ① IO ワーカー'
        $sh = Build-Sheet $TB['cli_io_worker'] '①IOワーカー' 'IO ワーカー（HTTP の処理スレッド、ワーカー別の時系列）' '① jboss-cli の /subsystem=io/worker=*。タスクスレッド = HTTP リクエストを処理するスレッド (スレッド名 default task-N)。使用中が上限に達するとリクエストはキューで待ちます。I/O スレッド数 (既定 CPU 数 × 2) と上限 (既定 CPU 数 × 16) は、JVM が認識した CPU 数から決まります (④ を参照)。' 2 $T1 @(
            (CT), (C 'wk' '基本' 'ワーカー' 'worker' 'text' 10 'raw' 'worker'),
            (C 'bt' 'タスクスレッド' '使用中' 'busy-task-thread-count' 'int' 8 'raw' 'busy-task-thread-count'),
            (C 'mp' 'タスクスレッド' '上限' 'max-pool-size' 'int' 7 'raw' 'max-pool-size'),
            (C 'tu' 'タスクスレッド' '使用率' '使用中÷上限' 'pct' 8 'ratio' 'busy-task-thread-count,max-pool-size'),
            (C 'cp' 'タスクスレッド' 'コア' 'core-pool-size' 'int' 7 'raw' 'core-pool-size'),
            (C 'q' 'タスクスレッド' 'キュー' 'queue-size' 'int' 7 'raw' 'queue-size'),
            (C 'io' 'I/O スレッド' '数' 'io-thread-count' 'int' 7 'raw' 'io-thread-count'),
            (C 'cc' '接続' '接続数' 'connection-count' 'int' 8 'raw' 'connection-count'),
            (C 'tmx' '設定' 'task-max-threads' 'task-max-threads' 'int' 11 'raw' 'task-max-threads'),
            (C 'tcr' '設定' 'task-core-threads' 'task-core-threads' 'int' 11 'raw' 'task-core-threads'),
            (C 'ios' '設定' 'io-threads' 'io-threads' 'int' 9 'raw' 'io-threads')
        ) @('worker')
        Add-CF $sh 'tu' 'bar' '1' 0; Add-CF $sh 'tu' 'ge' '0.9' 1; Add-CF $sh 'q' 'gt' '0' 1
        Put 'iow' $sh
    }
    if ($TB.ContainsKey('cli_transactions')) {
        Write-Info '集計: ① トランザクション'
        $sh = Build-Sheet $TB['cli_transactions'] '①トランザクション' 'トランザクション（Narayana、時系列）' '① jboss-cli の /subsystem=transactions。「区間」は前回の取得からの増分です。平均コミット時間は統計の有効化以降の平均 (ナノ秒の値をミリ秒に換算) です。タイムアウト・ヒューリスティックは濃淡で表示します。' 1 $T1 @(
            (CT),
            (C 'n' '区間' '開始' 'Δ number-of-transactions' 'int' 8 'delta' 'number-of-transactions'),
            (C 'c' '区間' 'コミット' 'Δ committed' 'int' 8 'delta' 'number-of-committed-transactions'),
            (C 'tps' '区間' 'コミット 毎秒' 'Δ committed÷経過' 'dec2' 9 'rate' 'number-of-committed-transactions'),
            (C 'a' '区間' '中断' 'Δ aborted' 'int' 7 'delta' 'number-of-aborted-transactions'),
            (C 'to' '区間' 'タイムアウト' 'Δ timed-out' 'int' 9 'delta' 'number-of-timed-out-transactions'),
            (C 'ar' '区間' 'ロールバック（アプリ）' 'Δ application-rollbacks' 'int' 11 'delta' 'number-of-application-rollbacks'),
            (C 'rr' '区間' 'ロールバック（リソース）' 'Δ resource-rollbacks' 'int' 11 'delta' 'number-of-resource-rollbacks'),
            (C 'sr' '区間' 'ロールバック（システム）' 'Δ system-rollbacks' 'int' 11 'delta' 'number-of-system-rollbacks'),
            (C 'hs' '区間' 'ヒューリスティック' 'Δ heuristics' 'int' 10 'delta' 'number-of-heuristics'),
            (C 'ns' '区間' 'ネスト' 'Δ nested' 'int' 7 'delta' 'number-of-nested-transactions'),
            (C 'inf' '現在' '実行中' 'number-of-inflight-transactions' 'int' 8 'raw' 'number-of-inflight-transactions'),
            (C 'act' '現在' '平均コミット時間(ms)' 'average-commit-time' 'dec3' 11 'scale' 'average-commit-time' 0.000001),
            (C 'tot' '累計' '開始' 'number-of-transactions' 'int' 11 'raw' 'number-of-transactions'),
            (C 'se' '設定' '統計' 'statistics_enabled' 'textc' 7 'raw' 'statistics_enabled')
        )
        Add-CF $sh 'to' 'gt' '0' 0; Add-CF $sh 'hs' 'gt' '0' 0; Add-CF $sh 'a' 'gt' '0' 1
        Put 'tx' $sh
    }
    if ($TB.ContainsKey('cli_jvm')) {
        Write-Info '集計: ① JVM（jboss-cli）'
        $sh = Build-Sheet $TB['cli_jvm'] '①JVM（CLI）' 'JVM・サーバーの状態（jboss-cli、時系列）' '① jboss-cli で読む platform-mbean (スレッド・クラス・メモリ・NIO バッファ) と、サーバーの状態・処理中のリクエスト数 (request-controller)。OS スレッドは同じ時刻の /proc/<pid>/status の Threads です。応答 0 の行は jboss-cli が応答しなかった回 (高負荷・GC 停止・停止中) で、OS スレッド数だけを記録しています。' 1 $T1 @(
            (CT),
            (C 'ok' '取得' '応答 (1=成功)' 'cli_ok' 'int' 7 'raw' 'cli_ok'),
            (C 'ms' '取得' '応答時間(ms)' 'cli_ms' 'int' 9 'raw' 'cli_ms'),
            (C 'ss' '状態' 'サーバー' 'server_state' 'textc' 10 'raw' 'server_state'),
            (C 'sus' '状態' '一時停止' 'suspend_state' 'textc' 10 'raw' 'suspend_state'),
            (C 'ar' '状態' '処理中のリクエスト' 'active_requests' 'int' 10 'raw' 'active_requests'),
            (C 'lt' 'スレッド' 'ライブ' 'live_threads' 'int' 7 'raw' 'live_threads'),
            (C 'dt' 'スレッド' 'デーモン' 'daemon_threads' 'int' 7 'raw' 'daemon_threads'),
            (C 'pt' 'スレッド' 'ピーク' 'peak_threads' 'int' 7 'raw' 'peak_threads'),
            (C 'os' 'スレッド' 'OS' 'os_threads' 'int' 7 'raw' 'os_threads'),
            (C 'st' 'スレッド' '開始（区間）' 'Δ started_threads' 'int' 9 'delta' 'started_threads'),
            (C 'cl' 'クラス' 'ロード中' 'loaded_classes' 'int' 9 'raw' 'loaded_classes'),
            (C 'clu' 'クラス' 'アンロード（区間）' 'Δ unloaded_classes' 'int' 10 'delta' 'unloaded_classes'),
            (C 'hu' 'ヒープ（MB）' '使用' 'heap_used' 'dec1' 8 'scale' 'heap_used' $MB),
            (C 'hc' 'ヒープ（MB）' '確保' 'heap_committed' 'dec1' 8 'scale' 'heap_committed' $MB),
            (C 'hm' 'ヒープ（MB）' '上限' 'heap_max' 'dec1' 8 'scale' 'heap_max' $MB),
            (C 'hp' 'ヒープ（MB）' '使用率' 'heap_used÷heap_max' 'pct' 8 'ratio' 'heap_used,heap_max'),
            (C 'nu' '非ヒープ（MB）' '使用' 'nonheap_used' 'dec1' 8 'scale' 'nonheap_used' $MB),
            (C 'nc' '非ヒープ（MB）' '確保' 'nonheap_committed' 'dec1' 8 'scale' 'nonheap_committed' $MB),
            (C 'dbc' 'NIO バッファ' 'ダイレクト 個数' 'direct_count' 'int' 9 'raw' 'direct_count'),
            (C 'dbu' 'NIO バッファ' 'ダイレクト(MB)' 'direct_used' 'dec2' 10 'scale' 'direct_used' $MB),
            (C 'mbc' 'NIO バッファ' 'マップド 個数' 'mapped_count' 'int' 9 'raw' 'mapped_count'),
            (C 'mbu' 'NIO バッファ' 'マップド(MB)' 'mapped_used' 'dec2' 10 'scale' 'mapped_used' $MB),
            (C 'ap' 'CPU' 'CPU 数（JVM）' 'available_processors' 'int' 8 'raw' 'available_processors'),
            (C 'la' 'CPU' 'ロードアベレージ' 'system_load_average' 'dec2' 9 'raw' 'system_load_average')
        )
        Add-CF $sh 'ok' 'eq' '0' 0; Add-CF $sh 'ms' 'ge' '5000' 1; Add-CF $sh 'hp' 'bar' '1' 0; Add-CF $sh 'hp' 'ge' '0.85' 1
        Put 'jvm' $sh
    }

    # ==================== ② jstat / jcmd / JFR ====================
    if ($TB.ContainsKey('jvm_jstat_gc')) {
        Write-Info '集計: ② ヒープ・GC（jstat）'
        $sh = Build-Sheet $TB['jvm_jstat_gc'] '②ヒープ・GC（jstat）' 'ヒープ・GC・セーフポイント・JIT（jstat、時系列）' ('② jstat (' + (M 'jvm.jstat_option') + ')。容量・使用量は MB、GC の「区間」は前回の行からの増分、GC 時間率 = 区間の GC 時間 ÷ 経過時間 (アプリが止まっていた割合の目安) です。セーフポイント停止は GC 以外 (コードの最適化の取り消し・スレッドダンプなど) の停止も含みます。Full GC・Old 使用率 85% 以上・GC 時間率 5% 以上は濃淡で表示します。') 1 $T2 @(
            (CT), (C 'up' '基本' 'JVM 稼働(秒)' 'uptime_s' 'dec1' 10 'raw' 'uptime_s'),
            (C 'hu' 'ヒープ（MB）' '使用（合計）' 'EU+S0U+S1U+OU' 'dec1' 10 'sum' 'EU,S0U,S1U,OU' $KM),
            (C 'hc' 'ヒープ（MB）' '容量（合計）' 'EC+S0C+S1C+OC' 'dec1' 10 'sum' 'EC,S0C,S1C,OC' $KM),
            (C 'eu' 'ヒープ（MB）' 'Eden 使用' 'EU' 'dec1' 9 'scale' 'EU' $KM),
            (C 'ec' 'ヒープ（MB）' 'Eden 容量' 'EC' 'dec1' 9 'scale' 'EC' $KM),
            (C 'su' 'ヒープ（MB）' 'Survivor 使用' 'S0U+S1U' 'dec1' 9 'sum' 'S0U,S1U' $KM),
            (C 'sc' 'ヒープ（MB）' 'Survivor 容量' 'S0C+S1C' 'dec1' 9 'sum' 'S0C,S1C' $KM),
            (C 'ou' 'ヒープ（MB）' 'Old 使用' 'OU' 'dec1' 9 'scale' 'OU' $KM),
            (C 'oc' 'ヒープ（MB）' 'Old 容量' 'OC' 'dec1' 9 'scale' 'OC' $KM),
            (C 'op' 'ヒープ（MB）' 'Old 使用率' 'OU÷OC' 'pct' 9 'ratio' 'OU,OC'),
            $(if ($null -ne $maxHeapMB) { (C 'opm' 'ヒープ（MB）' 'Old ÷ 最大ヒープ' ('OU÷' + ([double]$maxHeapMB).ToString('#,0', $Inv) + 'MB') 'pct' 10 'ratio' 'OU' 1 ($maxHeapMB * 1024)) }),
            (C 'mu' 'メタスペース（MB）' '使用' 'MU' 'dec1' 8 'scale' 'MU' $KM),
            (C 'mc' 'メタスペース（MB）' '容量' 'MC' 'dec1' 8 'scale' 'MC' $KM),
            (C 'cu' 'メタスペース（MB）' 'CCS 使用' 'CCSU' 'dec1' 8 'scale' 'CCSU' $KM),
            (C 'yn' 'GC（区間）' 'Young 回数' 'Δ YGC' 'int' 8 'delta' 'YGC'),
            (C 'yt' 'GC（区間）' 'Young 時間 ms' 'Δ YGCT' 'dec1' 9 'delta' 'YGCT' 1000),
            (C 'ya' 'GC（区間）' 'Young 平均停止 ms' 'Δ YGCT÷Δ YGC' 'dec1' 10 'dratio' 'YGCT,YGC' 1000),
            (C 'fn' 'GC（区間）' 'Full 回数' 'Δ FGC' 'int' 8 'delta' 'FGC'),
            (C 'ft' 'GC（区間）' 'Full 時間 ms' 'Δ FGCT' 'dec1' 9 'delta' 'FGCT' 1000),
            (C 'cn' 'GC（区間）' 'Concurrent 回数' 'Δ CGC' 'int' 10 'delta' 'CGC'),
            (C 'ct' 'GC（区間）' 'Concurrent 時間 ms' 'Δ CGCT' 'dec1' 10 'delta' 'CGCT' 1000),
            (C 'gt' 'GC（区間）' 'GC 時間 ms' 'Δ GCT' 'dec1' 9 'delta' 'GCT' 1000),
            (C 'gr' 'GC（区間）' 'GC 時間率' 'Δ GCT÷経過' 'pct' 9 'rate' 'GCT'),
            (C 'lc' 'GC（区間）' '最後の GC の原因' 'LGCC' 'text' 22 'raw' 'LGCC'),
            (C 'spn' 'セーフポイント（区間）' '回数' 'Δ SPN' 'int' 7 'delta' 'SPN'),
            (C 'spt' 'セーフポイント（区間）' '停止 ms' 'Δ SPT' 'dec1' 9 'delta' 'SPT' 1000),
            (C 'sps' 'セーフポイント（区間）' '同期待ち ms' 'Δ SPS' 'dec1' 9 'delta' 'SPS' 1000),
            (C 'spr' 'セーフポイント（区間）' '停止率' 'Δ SPT÷経過' 'pct' 8 'rate' 'SPT'),
            (C 'cmp' 'JIT（区間）' 'コンパイル数' 'Δ CMP' 'int' 9 'delta' 'CMP'),
            (C 'cmt' 'JIT（区間）' 'コンパイル時間 ms' 'Δ CMPT' 'dec1' 10 'delta' 'CMPT' 1000),
            (C 'thr' 'スレッド・クラス' 'ライブスレッド' 'THR' 'int' 9 'raw' 'THR'),
            (C 'cls' 'スレッド・クラス' 'ロード済みクラス' 'CLS' 'int' 10 'raw' 'CLS'),
            (C 'ucl' 'スレッド・クラス' 'アンロード（区間）' 'Δ UCLS' 'int' 10 'delta' 'UCLS'),
            (C 'yc' 'GC（累計）' 'YGC' 'YGC' 'int' 7 'raw' 'YGC'),
            (C 'fc' 'GC（累計）' 'FGC' 'FGC' 'int' 7 'raw' 'FGC'),
            (C 'cc' 'GC（累計）' 'CGC' 'CGC' 'int' 7 'raw' 'CGC'),
            (C 'gc' 'GC（累計）' 'GCT 秒' 'GCT' 'dec3' 8 'raw' 'GCT')
        )
        Add-CF $sh 'op' 'bar' '1' 0; Add-CF $sh 'opm' 'bar' '1' 0; Add-CF $sh 'opm' 'ge' '0.85' 1; Add-CF $sh 'fn' 'gt' '0' 0; Add-CF $sh 'gr' 'ge' '0.05' 1; Add-CF $sh 'spr' 'ge' '0.05' 1
        if (-not $isG1) { Add-CF $sh 'op' 'ge' '0.85' 1 }
        Put 'js' $sh
    }
    if ($TB.ContainsKey('jvm_jcmd_heap')) {
        Write-Info '集計: ② ヒープ（jcmd）'
        $sh = Build-Sheet $TB['jvm_jcmd_heap'] '②ヒープ（jcmd）' 'ヒープ・メタスペースの詳細（jcmd GC.heap_info、時系列）' ('② jcmd <pid> GC.heap_info (' + (M 'perf.jcmd_interval') + ' 秒間隔)。G1 はリージョン (区画) 単位で管理し、Young・Survivor に使っているリージョン数が分かります。クラス空間 (Compressed Class Space) はメタスペースの一部です。使っている GC に無い項目の列は省いています。') 1 $T2 @(
            (CT), (C 'gc' '基本' 'GC' 'gc' 'textc' 8 'raw' 'gc'),
            (C 'ht' 'ヒープ（MB）' '確保' 'heap_total_kb' 'dec1' 9 'scale' 'heap_total_kb' $KM),
            (C 'hu' 'ヒープ（MB）' '使用' 'heap_used_kb' 'dec1' 9 'scale' 'heap_used_kb' $KM),
            (C 'hcm' 'ヒープ（MB）' 'コミット' 'heap_committed_kb' 'dec1' 9 'scale' 'heap_committed_kb' $KM),
            (C 'hr' 'ヒープ（MB）' '予約' 'heap_reserved_kb' 'dec1' 9 'scale' 'heap_reserved_kb' $KM),
            (C 'rs' 'G1 リージョン' 'サイズ(KB)' 'region_size_kb' 'int' 9 'raw' 'region_size_kb'),
            (C 'yr' 'G1 リージョン' 'Young 数' 'young_regions' 'int' 8 'raw' 'young_regions'),
            (C 'yk' 'G1 リージョン' 'Young(MB)' 'young_kb' 'dec1' 9 'scale' 'young_kb' $KM),
            (C 'sr' 'G1 リージョン' 'Survivor 数' 'survivor_regions' 'int' 9 'raw' 'survivor_regions'),
            (C 'sk' 'G1 リージョン' 'Survivor(MB)' 'survivor_kb' 'dec1' 10 'scale' 'survivor_kb' $KM),
            (C 'ygt' '世代（MB）' 'Young 確保' 'young_gen_total_kb' 'dec1' 9 'scale' 'young_gen_total_kb' $KM),
            (C 'ygu' '世代（MB）' 'Young 使用' 'young_gen_used_kb' 'dec1' 9 'scale' 'young_gen_used_kb' $KM),
            (C 'ogt' '世代（MB）' 'Old 確保' 'old_gen_total_kb' 'dec1' 9 'scale' 'old_gen_total_kb' $KM),
            (C 'ogu' '世代（MB）' 'Old 使用' 'old_gen_used_kb' 'dec1' 9 'scale' 'old_gen_used_kb' $KM),
            (C 'mu' 'メタスペース（MB）' '使用' 'metaspace_used_kb' 'dec1' 8 'scale' 'metaspace_used_kb' $KM),
            (C 'mc' 'メタスペース（MB）' 'コミット' 'metaspace_committed_kb' 'dec1' 9 'scale' 'metaspace_committed_kb' $KM),
            (C 'mr' 'メタスペース（MB）' '予約' 'metaspace_reserved_kb' 'dec1' 9 'scale' 'metaspace_reserved_kb' $KM),
            (C 'cu' 'クラス空間（MB）' '使用' 'class_used_kb' 'dec1' 8 'scale' 'class_used_kb' $KM),
            (C 'cc' 'クラス空間（MB）' 'コミット' 'class_committed_kb' 'dec1' 9 'scale' 'class_committed_kb' $KM),
            (C 'cr' 'クラス空間（MB）' '予約' 'class_reserved_kb' 'dec1' 9 'scale' 'class_reserved_kb' $KM),
            (C 'jm' '取得' 'jcmd 応答(ms)' 'jcmd_ms' 'int' 9 'raw' 'jcmd_ms')
        )
        Drop-EmptyCols $sh @('t')
        Put 'jh' $sh
    }
    if ($TB.ContainsKey('jvm_codecache')) {
        Write-Info '集計: ② コードキャッシュ'
        $sh = Build-Sheet $TB['jvm_codecache'] '②コードキャッシュ' 'コードキャッシュ（JIT でコンパイルしたコードの置き場、セグメント別の時系列）' '② jcmd <pid> Compiler.codecache。満杯になると JIT コンパイルが止まり、処理が遅くなります (満杯の回数 > 0 は要対応)。profiled = 途中段階のコード、non-profiled = 最適化済みのコード、non-nmethods = JVM 内部のコードです。' 2 $T2 @(
            (CT), (C 'sg' '基本' 'セグメント' 'segment' 'text' 22 'raw' 'segment'),
            (C 'sz' '容量（MB）' 'サイズ' 'size_kb' 'dec1' 8 'scale' 'size_kb' $KM),
            (C 'us' '容量（MB）' '使用' 'used_kb' 'dec1' 8 'scale' 'used_kb' $KM),
            (C 'mu' '容量（MB）' '最大使用' 'max_used_kb' 'dec1' 8 'scale' 'max_used_kb' $KM),
            (C 'fr' '容量（MB）' '空き' 'free_kb' 'dec1' 8 'scale' 'free_kb' $KM),
            (C 'ur' '容量（MB）' '使用率' '使用÷サイズ' 'pct' 8 'ratio' 'used_kb,size_kb'),
            (C 'nm' 'コンパイル済み' 'nmethod 数' 'nmethods' 'int' 9 'raw' 'nmethods'),
            (C 'fc' 'コンパイル済み' '満杯の回数' 'full_count' 'int' 9 'raw' 'full_count')
        ) @('segment')
        Add-CF $sh 'ur' 'bar' '1' 0; Add-CF $sh 'ur' 'ge' '0.9' 1; Add-CF $sh 'fc' 'gt' '0' 0
        Put 'cc' $sh
    }
    $nmtOrder = @()
    if ($TB.ContainsKey('jvm_nmt')) {
        Write-Info '集計: ② ネイティブメモリ（NMT）'
        $t = $TB['jvm_nmt']
        # 最後の時刻のコミット量が大きい順に並べる
        $ei = [int]$t.I['epoch']; $ci = [int]$t.I['category']; $mi = [int]$t.I['committed_kb']
        $lastE = $t.Rows[$t.Rows.Count - 1][$ei]; $lastV = @{}
        foreach ($r in $t.Rows) { if ($r[$ei] -eq $lastE) { $lastV[$r[$ci]] = [double]$PerfRpt::D($r[$mi]) } }
        $nmtOrder = @($lastV.Keys | Where-Object { $_ -ne 'Total' } | Sort-Object -Property @{ Expression = { $lastV[$_] }; Descending = $true })
        $pv = Pivot-Table $t 'category' @('reserved_kb', 'committed_kb') (@('Total') + $nmtOrder)
        $specs = @((CT), (C 'tr' '合計（MB）' '予約' 'Total reserved' 'dec1' 9 'scale' 'Total.reserved_kb' $KM), (C 'tc' '合計（MB）' 'コミット' 'Total committed' 'dec1' 9 'scale' 'Total.committed_kb' $KM))
        $i = 0
        foreach ($cat in $nmtOrder) { $i++; $specs += C ('n' + $i) 'コミット（MB、大きい順）' $cat $cat 'dec1' ([Math]::Max(8, [Math]::Min(14, (Units $cat) * 0.9))) 'scale' ($cat + '.committed_kb') $KM }
        $sh = Build-Sheet $pv.T '②NMT' 'ネイティブメモリ（Native Memory Tracking、分類別の時系列）' '② jcmd <pid> VM.native_memory summary (PERF_NMT=summary のときだけ)。コミット = 実際に確保したメモリ。Java Heap = ヒープ、Class = クラスの情報 (メタスペース)、Thread = スレッドのスタック、Code = JIT のコード、GC = GC の管理領域、Internal・Other = JVM 内部・ダイレクトバッファなど。コンテナのメモリが足りなくなるとき、どこが増えているかを確認します。' 1 $T2 $specs
        $sh | Add-Member -NotePropertyName Order -NotePropertyValue $nmtOrder
        Put 'nmt' $sh
    }
    if ($TB.ContainsKey('jvm_thread_states')) {
        Write-Info '集計: ② スレッド状態（jcmd）'
        $pv = Pivot-Table $TB['jvm_thread_states'] 'group' @('total', 'runnable', 'blocked', 'waiting', 'timed_waiting', 'busy') @('all', 'http-task', 'http-io', 'ee-ejb', 'jboss', 'jvm', 'other', 'db-pool-wait')
        $specs = @((CT),
            (C 'at' '全体' '合計' 'all.total' 'int' 7 'raw' 'all.total'), (C 'ar' '全体' '実行可能' 'all.runnable' 'int' 8 'raw' 'all.runnable'),
            (C 'ab' '全体' 'ブロック' 'all.blocked' 'int' 8 'raw' 'all.blocked'), (C 'aw' '全体' '待機' 'all.waiting' 'int' 7 'raw' 'all.waiting'),
            (C 'atw' '全体' '時間待機' 'all.timed_waiting' 'int' 8 'raw' 'all.timed_waiting'), (C 'abz' '全体' '処理中' 'all.busy' 'int' 7 'raw' 'all.busy'),
            (C 'dbw' 'DB 接続待ち' 'スレッド' 'db-pool-wait.total' 'int' 9 'raw' 'db-pool-wait.total'))
        foreach ($g in @('http-task', 'http-io', 'ee-ejb', 'jboss', 'jvm', 'other')) {
            $specs += C ($g + '.t') (TG $g) '合計' ($g + '.total') 'int' 7 'raw' ($g + '.total')
            $specs += C ($g + '.b') (TG $g) '処理中' ($g + '.busy') 'int' 7 'raw' ($g + '.busy')
            if ($g -eq 'http-task' -or $g -eq 'ee-ejb') { $specs += C ($g + '.k') (TG $g) 'ブロック' ($g + '.blocked') 'int' 8 'raw' ($g + '.blocked') }
        }
        $sh = Build-Sheet $pv.T '②スレッド状態' 'Java スレッドの状態（jcmd Thread.print、用途別の時系列）' ('② jcmd <pid> Thread.print (' + (M 'perf.jcmd_interval') + ' 秒間隔) を用途別に数えたもの。処理中 = 仕事を待っていない (アイドルのスレッドプールの待ちを除いた) スレッド、ブロック = ロック (synchronized) の取得待ち、DB 接続待ち = IronJacamar のプールで空き接続を待っているスレッドです。用途はスレッド名で分類しています (HTTP 処理 = default task-N、HTTP I/O = default I/O-N)。') 1 $T2 $specs
        Add-CF $sh 'ab' 'gt' '0' 1; Add-CF $sh 'dbw' 'gt' '0' 0; Add-CF $sh 'http-task.k' 'gt' '0' 1
        Put 'ts' $sh
    }
    if ($TB.ContainsKey('jfr_gc')) {
        Write-Info '集計: ② GC（JFR）'
        $sh = Build-Sheet $TB['jfr_gc'] '②GC（JFR）' 'GC ごとの停止時間とヒープ（JFR jdk.GarbageCollection）' '② JFR (Flight Recorder) の GC イベント 1 件 = 1 行。停止 = アプリのスレッドが止まった時間 (最長 = 1 回の停止の最大)。所要 = GC の開始から終了まで (G1 の並行マーキングなど、アプリと並行して動く時間を含む)。最長停止 200 ms 以上は濃淡で表示します (G1 の停止目標 MaxGCPauseMillis の既定値 200 ms)。' 1 $T2 @(
            (C 't' '基本' '日時' 'epoch_ms' 'dt' 19 'timems' 'epoch_ms'),
            (C 'id' '基本' 'GC 番号' 'gc_id' 'int' 8 'raw' 'gc_id'),
            (C 'nm' '基本' '種類' 'name' 'text' 13 'raw' 'name'),
            (C 'cs' '基本' '原因' 'cause' 'text' 26 'raw' 'cause'),
            (C 'sp' '停止（ms）' '合計' 'sum_of_pauses_ms' 'dec2' 9 'raw' 'sum_of_pauses_ms'),
            (C 'lp' '停止（ms）' '最長' 'longest_pause_ms' 'dec2' 9 'raw' 'longest_pause_ms'),
            (C 'du' '所要（ms）' '開始〜終了' 'duration_ms' 'dec1' 10 'raw' 'duration_ms'),
            (C 'hb' 'ヒープ（MB）' 'GC 前' 'heap_before_mb' 'dec1' 9 'raw' 'heap_before_mb'),
            (C 'ha' 'ヒープ（MB）' 'GC 後' 'heap_after_mb' 'dec1' 9 'raw' 'heap_after_mb'),
            (C 'hf' 'ヒープ（MB）' '回収' 'GC 前 − GC 後' 'dec1' 9 'diff' 'heap_before_mb,heap_after_mb'),
            (C 'hc' 'ヒープ（MB）' '確保' 'heap_committed_mb' 'dec1' 9 'raw' 'heap_committed_mb'),
            $(if ($null -ne $maxHeapMB) { (C 'mh' 'ヒープ（MB）' '最大' 'MaxHeapSize' 'dec1' 8 'const' '' 1 $maxHeapMB) })
        )
        Add-CF $sh 'lp' 'ge' '200' 1
        Put 'jgc' $sh
    }
    if ($TB.ContainsKey('jfr_stats')) {
        Write-Info '集計: ② JVM 統計（JFR）'
        $sh = Build-Sheet $TB['jfr_stats'] '②JVM統計（JFR）' 'JVM の統計（JFR の定期イベント、時系列）' ('② JFR の定期イベント (' + (M 'perf.jfr_interval') + ' 秒間隔、' + (M 'perf.jfr_note') + ')。CPU は JVM プロセスの user / system (この JVM が見ている CPU 全体を 100%)、例外 = 作られた Throwable の数 (スタックトレースの作成は重い)、コンテキストスイッチ = OS 全体の 1 秒あたりの切り替え回数。CPU 制限の列は JVM がコンテナと判定したとき (cgroup に上限がある) だけ値が入ります。値の無い列は省いています。') 1 $T2 @(
            (CT),
            (C 'ju' 'CPU（%）' 'JVM user' 'jvm_user_pct' 'dec1' 8 'raw' 'jvm_user_pct'),
            (C 'js' 'CPU（%）' 'JVM system' 'jvm_system_pct' 'dec1' 8 'raw' 'jvm_system_pct'),
            (C 'jt' 'CPU（%）' 'JVM 合計' 'user + system' 'dec1' 8 'sum' 'jvm_user_pct,jvm_system_pct'),
            (C 'mt' 'CPU（%）' 'マシン全体' 'machine_total_pct' 'dec1' 9 'raw' 'machine_total_pct'),
            (C 'ta' 'スレッド' 'アクティブ' 'threads_active' 'int' 8 'raw' 'threads_active'),
            (C 'td' 'スレッド' 'デーモン' 'threads_daemon' 'int' 7 'raw' 'threads_daemon'),
            (C 'tp' 'スレッド' 'ピーク' 'threads_peak' 'int' 7 'raw' 'threads_peak'),
            (C 'tst' 'スレッド' '開始（区間）' 'Δ threads_accumulated' 'int' 9 'delta' 'threads_accumulated'),
            (C 'cl' 'クラス' 'ロード中' 'loaded − unloaded' 'int' 9 'diff' 'classes_loaded,classes_unloaded'),
            (C 'cld' 'クラス' 'ロード（区間）' 'Δ classes_loaded' 'int' 9 'delta' 'classes_loaded'),
            (C 'cmp' 'JIT（区間）' 'コンパイル' 'Δ compiles' 'int' 9 'delta' 'compiles'),
            (C 'osr' 'JIT（区間）' 'OSR' 'Δ osr_compiles' 'int' 7 'delta' 'osr_compiles'),
            (C 'bo' 'JIT（区間）' '中止' 'Δ bailouts' 'int' 7 'delta' 'bailouts'),
            (C 'inv' 'JIT（区間）' '無効化' 'Δ invalidated' 'int' 7 'delta' 'invalidated'),
            (C 'ctm' 'JIT（区間）' 'コンパイル時間 ms' 'Δ compile_time_ms' 'dec1' 10 'delta' 'compile_time_ms'),
            (C 'ccf' 'コードキャッシュ' '空き(MB)' 'code_cache_free_mb' 'dec1' 9 'raw' 'code_cache_free_mb'),
            (C 'ccu' 'コードキャッシュ' '満杯の回数' 'code_cache_full_count' 'int' 9 'raw' 'code_cache_full_count'),
            (C 'ex' '例外' '発生（区間）' 'Δ throwables' 'int' 9 'delta' 'throwables'),
            (C 'exs' '例外' '毎秒' 'Δ throwables÷経過' 'dec1' 8 'rate' 'throwables'),
            (C 'cs' 'OS' 'コンテキストスイッチ/秒' 'ctx_switch_per_sec' 'int' 11 'raw' 'ctx_switch_per_sec'),
            (C 'rss' 'メモリ（MB）' 'RSS' 'rss_mb' 'dec1' 8 'raw' 'rss_mb'),
            (C 'rsp' 'メモリ（MB）' 'RSS ピーク' 'rss_peak_mb' 'dec1' 9 'raw' 'rss_peak_mb'),
            (C 'dbc' 'メモリ（MB）' 'ダイレクト 個数' 'direct_buffer_count' 'int' 9 'raw' 'direct_buffer_count'),
            (C 'dbu' 'メモリ（MB）' 'ダイレクト' 'direct_buffer_used_mb' 'dec2' 9 'raw' 'direct_buffer_used_mb'),
            (C 'nr' 'メモリ（MB）' 'NMT 予約' 'nmt_reserved_mb' 'dec1' 9 'raw' 'nmt_reserved_mb'),
            (C 'nc' 'メモリ（MB）' 'NMT コミット' 'nmt_committed_mb' 'dec1' 9 'raw' 'nmt_committed_mb'),
            (C 'ths' 'CPU 制限（区間）' 'スロットリング回数' 'Δ throttled_slices' 'int' 11 'delta' 'throttled_slices'),
            (C 'tms' 'CPU 制限（区間）' 'スロットリング ms' 'Δ throttled_ms' 'dec1' 11 'delta' 'throttled_ms')
        )
        Drop-EmptyCols $sh @('t')
        Add-CF $sh 'ccu' 'gt' '0' 0
        Put 'jst' $sh
    }

    # ==================== ③ top / ps / proc ====================
    if ($TB.ContainsKey('os_top_summary')) {
        Write-Info '集計: ③ top（概要）'
        $roleSum = $null
        if ($TB.ContainsKey('os_top_process')) {
            $roleMap = @{ 'jboss' = 'cpu.jboss'; 'jboss-cli' = 'cpu.collect'; 'jstat' = 'cpu.collect'; 'jcmd' = 'cpu.collect'; 'perf-metrics' = 'cpu.collect' }
            $roleSum = Sum-ByEpoch $TB['os_top_process'] 'role' 'cpu_pct' $roleMap @('cpu.jboss', 'cpu.collect', 'cpu.other')
        }
        $t = Join-ByEpoch $TB['os_top_summary'] $roleSum
        $sh = Build-Sheet $t '③top概要' 'top の概要（ロードアベレージ・タスク・CPU の内訳、時系列）' ('③ ' + (M 'os.top_source') + '。CPU（%、全 CPU）は VM 全体の CPU 時間の内訳 (us = アプリ、sy = カーネル、wa = I/O 待ち、st = steal: ほかの VM に CPU を取られた時間)。プロセス別 CPU は top の %CPU の合計 (1 コア = 100%) で、収集処理 = jboss-cli・jstat・jcmd・perf-metrics (このレポートのための収集の負荷) です。メモリは参考 (Container Insights で確認できます)。') 1 $T3 @(
            (CT),
            (C 'l1' 'ロードアベレージ' '1 分' 'load1' 'dec2' 7 'raw' 'load1'), (C 'l5' 'ロードアベレージ' '5 分' 'load5' 'dec2' 7 'raw' 'load5'), (C 'l15' 'ロードアベレージ' '15 分' 'load15' 'dec2' 7 'raw' 'load15'),
            (C 'tt' 'タスク（プロセス）' '合計' 'tasks_total' 'int' 7 'raw' 'tasks_total'), (C 'tr' 'タスク（プロセス）' '実行中' 'tasks_running' 'int' 7 'raw' 'tasks_running'),
            (C 'ts' 'タスク（プロセス）' 'スリープ' 'tasks_sleeping' 'int' 8 'raw' 'tasks_sleeping'), (C 'tz' 'タスク（プロセス）' 'ゾンビ' 'tasks_zombie' 'int' 7 'raw' 'tasks_zombie'),
            (C 'us' 'CPU（%、全 CPU）' 'us' 'cpu_us' 'dec1' 6 'raw' 'cpu_us'), (C 'sy' 'CPU（%、全 CPU）' 'sy' 'cpu_sy' 'dec1' 6 'raw' 'cpu_sy'),
            (C 'ni' 'CPU（%、全 CPU）' 'ni' 'cpu_ni' 'dec1' 6 'raw' 'cpu_ni'), (C 'id' 'CPU（%、全 CPU）' 'id' 'cpu_id' 'dec1' 6 'raw' 'cpu_id'),
            (C 'wa' 'CPU（%、全 CPU）' 'wa' 'cpu_wa' 'dec1' 6 'raw' 'cpu_wa'), (C 'hi' 'CPU（%、全 CPU）' 'hi' 'cpu_hi' 'dec1' 6 'raw' 'cpu_hi'),
            (C 'si' 'CPU（%、全 CPU）' 'si' 'cpu_si' 'dec1' 6 'raw' 'cpu_si'), (C 'st' 'CPU（%、全 CPU）' 'st' 'cpu_st' 'dec1' 6 'raw' 'cpu_st'),
            (C 'pj' 'プロセス別 CPU（%、1 コア = 100）' 'JBoss' 'cpu_pct (role=jboss)' 'dec1' 8 'raw' 'cpu.jboss'),
            (C 'pc' 'プロセス別 CPU（%、1 コア = 100）' '収集処理' 'cpu_pct (収集処理)' 'dec1' 9 'raw' 'cpu.collect'),
            (C 'po' 'プロセス別 CPU（%、1 コア = 100）' 'その他' 'cpu_pct (その他)' 'dec1' 8 'raw' 'cpu.other'),
            (C 'mt' 'メモリ（MiB、VM 全体・参考）' '合計' 'mem_total_mib' 'dec1' 9 'raw' 'mem_total_mib'), (C 'mu' 'メモリ（MiB、VM 全体・参考）' '使用' 'mem_used_mib' 'dec1' 9 'raw' 'mem_used_mib'),
            (C 'ma' 'メモリ（MiB、VM 全体・参考）' '利用可能' 'mem_avail_mib' 'dec1' 9 'raw' 'mem_avail_mib'), (C 'swu' 'メモリ（MiB、VM 全体・参考）' 'スワップ使用' 'swap_used_mib' 'dec1' 10 'raw' 'swap_used_mib')
        )
        Add-CF $sh 'st' 'ge' '10' 1; Add-CF $sh 'wa' 'ge' '10' 1
        Put 'tops' $sh
    }
    if ($TB.ContainsKey('os_top_process')) {
        Write-Info '集計: ③ top（プロセス）'
        $sh = Build-Sheet $TB['os_top_process'] '③topプロセス' 'top のプロセス一覧（取得ごと）' ('③ ' + (M 'os.top_source') + '。CPU% は取得間隔の平均 (1 コア = 100%)。役割: jboss = JBoss の JVM、jboss-cli・jstat・jcmd・perf-metrics = 収集処理、standalone.sh = 起動スクリプト、other = その他。オートフィルターで役割・PID を絞り込めます。') 1 $T3 @(
            (CT), (C 'pid' '基本' 'PID' 'pid' 'int' 7 'raw' 'pid'), (C 'rl' '基本' '役割' 'role' 'textc' 12 'raw' 'role'), (C 'us' '基本' 'ユーザー' 'user' 'text' 9 'raw' 'user'),
            (C 'st' '状態' '状態' 'state' 'textc' 5 'raw' 'state'), (C 'pr' '状態' '優先度' 'pr' 'textc' 6 'raw' 'pr'), (C 'ni' '状態' 'nice' 'ni' 'int' 5 'raw' 'ni'),
            (C 'cpu' '使用量' 'CPU%' 'cpu_pct' 'dec1' 7 'raw' 'cpu_pct'), (C 'mem' '使用量' 'メモリ%' 'mem_pct' 'dec1' 7 'raw' 'mem_pct'),
            (C 'res' '使用量' 'RES(MB)' 'res_kb' 'dec1' 8 'scale' 'res_kb' $KM), (C 'shr' '使用量' 'SHR(MB)' 'shr_kb' 'dec1' 8 'scale' 'shr_kb' $KM),
            (C 'virt' '使用量' 'VIRT(MB)' 'virt_kb' 'dec1' 9 'scale' 'virt_kb' $KM), (C 'tm' '使用量' 'CPU 時間' 'time' 'textc' 10 'raw' 'time'),
            (C 'cmd' 'コマンド' 'コマンド' 'command' 'text' 90 'raw' 'command')
        )
        Put 'topp' $sh
    }
    if ($TB.ContainsKey('os_top_threads')) {
        Write-Info '集計: ③ top（スレッド）'
        $sh = Build-Sheet $TB['os_top_threads'] '③topスレッド' 'JBoss の CPU 使用率が高いスレッド（top -H、取得ごとの上位）' ('③ JBoss の JVM のスレッドを CPU 使用率の高い順に ' + (M 'perf.top_threads') + ' 件 (1 コア = 100%)。スレッド名は Linux の制限で 15 文字までです。用途はスレッド名から分類しています (C2 / C1 CompilerThre = JIT、GC Thread・G1 = GC、default task = HTTP 処理、default I/O = HTTP I/O)。スレッドダンプ (threaddump/) の nid (16 進) と TID (10 進) で突き合わせられます。') 1 $T3 @(
            (CT), (C 'rk' '基本' '順位' 'rank' 'int' 5 'raw' 'rank'), (C 'tid' '基本' 'TID' 'tid' 'int' 7 'raw' 'tid'),
            (C 'nm' '基本' 'スレッド名' 'thread' 'text' 18 'raw' 'thread'), (C 'gp' '基本' '用途' '(スレッド名から)' 'textc' 9 'tgroup' 'thread'),
            (C 'st' '状態' '状態' 'state' 'textc' 5 'raw' 'state'), (C 'cpu' '使用量' 'CPU%' 'cpu_pct' 'dec1' 7 'raw' 'cpu_pct'), (C 'tm' '使用量' 'CPU 時間' 'time' 'textc' 10 'raw' 'time')
        )
        Add-CF $sh 'cpu' 'ge' '50' 1
        Put 'topt' $sh
    }
    if ($TB.ContainsKey('os_ps')) {
        Write-Info '集計: ③ ps'
        $sh = Build-Sheet $TB['os_ps'] '③ps' 'ps のプロセス一覧（取得ごと）' ('③ ' + (M 'os.ps_source') + '。%CPU は ps の定義どおり「起動からの平均」です (今の負荷は ③topプロセス を見てください)。スレッド数 (NLWP)・経過秒・親プロセスで、収集処理やスクリプトの起動状況を確認できます。') 1 $T3 @(
            (CT), (C 'pid' '基本' 'PID' 'pid' 'int' 7 'raw' 'pid'), (C 'ppid' '基本' '親 PID' 'ppid' 'int' 7 'raw' 'ppid'), (C 'rl' '基本' '役割' 'role' 'textc' 12 'raw' 'role'),
            (C 'us' '基本' 'ユーザー' 'user' 'text' 9 'raw' 'user'), (C 'st' '状態' '状態' 'stat' 'textc' 6 'raw' 'stat'), (C 'nl' '状態' 'スレッド数' 'nlwp' 'int' 8 'raw' 'nlwp'),
            (C 'rss' '使用量' 'RSS(MB)' 'rss_kb' 'dec1' 8 'scale' 'rss_kb' $KM), (C 'vsz' '使用量' 'VSZ(MB)' 'vsz_kb' 'dec1' 9 'scale' 'vsz_kb' $KM),
            (C 'pc' '使用量' '%CPU（平均）' 'pcpu' 'dec1' 9 'raw' 'pcpu'), (C 'pm' '使用量' '%MEM' 'pmem' 'dec1' 7 'raw' 'pmem'),
            (C 'et' '時間' '経過(秒)' 'etimes' 'int' 9 'raw' 'etimes'), (C 'ct' '時間' 'CPU 時間(秒)' 'cpu_time_s' 'int' 9 'raw' 'cpu_time_s'),
            (C 'cmd' 'コマンド' 'コマンドライン' 'args' 'text' 90 'raw' 'args')
        )
        Put 'ps' $sh
    }
    if ($TB.ContainsKey('os_jboss_threads')) {
        Write-Info '集計: ③ JBoss スレッド（用途別）'
        $grpOrder = @('all', 'http-task', 'http-io', 'ee-ejb', 'jboss', 'gc', 'jit', 'jfr', 'vm', 'other')
        $pv = Pivot-Table $TB['os_jboss_threads'] 'group' @('threads', 'running', 'disk_wait', 'cpu_pct', 'nonvol_ctxsw_per_sec') $grpOrder
        $specs = @((CT),
            (C 'at' '全体' 'スレッド' 'all.threads' 'int' 8 'raw' 'all.threads'), (C 'ar' '全体' '実行中 (R)' 'all.running' 'int' 8 'raw' 'all.running'),
            (C 'ad' '全体' 'ディスク待ち (D)' 'all.disk_wait' 'int' 9 'raw' 'all.disk_wait'), (C 'ac' '全体' 'CPU（コア）' 'all.cpu_pct÷100' 'dec2' 9 'scale' 'all.cpu_pct' 0.01),
            (C 'av' '全体' '非自発的切替/秒' 'all.nonvol_ctxsw_per_sec' 'dec1' 10 'raw' 'all.nonvol_ctxsw_per_sec'))
        foreach ($g in $pv.Groups) { if ($g -ne 'all') { $specs += C ($g + '.c') 'CPU（コア、用途別）' (TG $g) ($g + '.cpu_pct÷100') 'dec2' 8 'scale' ($g + '.cpu_pct') 0.01 } }
        foreach ($g in $pv.Groups) { if ($g -ne 'all') { $specs += C ($g + '.n') 'スレッド数（用途別）' (TG $g) ($g + '.threads') 'int' 8 'raw' ($g + '.threads') } }
        foreach ($g in @('http-task', 'gc')) { if ($pv.Groups.Contains($g)) { $specs += C ($g + '.v') '非自発的切替/秒（用途別）' (TG $g) ($g + '.nonvol_ctxsw_per_sec') 'dec1' 10 'raw' ($g + '.nonvol_ctxsw_per_sec') } }
        $sh = Build-Sheet $pv.T '③JBossスレッド' 'JBoss のスレッドの用途別 CPU・状態（/proc、時系列）' ('③ /proc/<JBoss の PID>/task/* を ' + (M 'perf.proc_interval') + ' 秒ごとに読み、スレッド名で用途別に集計。CPU（コア）= 区間の CPU 時間 ÷ 経過時間 (1.0 = 1 コアを使い切り)。非自発的切替 = 実行中に CPU を取り上げられた回数 (多いと CPU 不足)。GC・JIT のスレッド数は JVM が認識した CPU 数から決まります (④ を参照)。') 1 $T3 $specs
        $sh | Add-Member -NotePropertyName TGroups -NotePropertyValue $pv.Groups
        Put 'jt' $sh
    }
    if ($TB.ContainsKey('os_jboss_proc')) {
        Write-Info '集計: ③ FD・TCP'
        $sh = Build-Sheet $TB['os_jboss_proc'] '③FD・TCP' 'JBoss のファイル記述子・TCP 接続・RSS（/proc、時系列）' '③ /proc/<pid>/fd・/proc/net/tcp(6)・/proc/<pid>/status。TCP は JBoss が持っているソケットだけを数えます (受信側 = JBoss が待ち受けているポートへの接続、送信側 = JBoss から DB などへの接続)。TIME_WAIT は持ち主のプロセスが無いためタスク全体の数です。CLOSE_WAIT = 相手が切断したのに JBoss 側でまだ閉じていない接続 (増え続けるならクローズ漏れ)。' 1 $T3 @(
            (CT), (C 'pid' '基本' 'PID' 'pid' 'int' 7 'raw' 'pid'), (C 'th' '基本' 'スレッド' 'threads' 'int' 8 'raw' 'threads'),
            (C 'fd' 'ファイル記述子' '使用中' 'fd_count' 'int' 8 'raw' 'fd_count'), (C 'fl' 'ファイル記述子' '上限' 'fd_limit' 'int' 10 'raw' 'fd_limit'),
            (C 'fr' 'ファイル記述子' '使用率' '使用中÷上限' 'pct' 8 'ratio' 'fd_count,fd_limit'),
            (C 'te' 'TCP（JBoss）' '確立' 'tcp_established' 'int' 7 'raw' 'tcp_established'), (C 'ti' 'TCP（JBoss）' '確立（受信側）' 'tcp_established_in' 'int' 9 'raw' 'tcp_established_in'),
            (C 'to' 'TCP（JBoss）' '確立（送信側）' 'tcp_established_out' 'int' 9 'raw' 'tcp_established_out'), (C 'cw' 'TCP（JBoss）' 'CLOSE_WAIT' 'tcp_close_wait' 'int' 10 'raw' 'tcp_close_wait'),
            (C 'li' 'TCP（JBoss）' 'LISTEN' 'tcp_listen' 'int' 7 'raw' 'tcp_listen'), (C 'ot' 'TCP（JBoss）' 'その他' 'tcp_other' 'int' 7 'raw' 'tcp_other'),
            (C 'tsk' 'TCP（JBoss）' 'ソケット合計' 'tcp_sockets' 'int' 9 'raw' 'tcp_sockets'),
            (C 'tw' 'TCP（タスク全体）' 'TIME_WAIT' 'tcp_time_wait_all' 'int' 10 'raw' 'tcp_time_wait_all'),
            (C 'op' '接続先（上位 5）' '送信側（相手のポート:数）' 'est_out_ports' 'text' 24 'raw' 'est_out_ports'),
            (C 'ip' '接続先（上位 5）' '受信側（自分のポート:数）' 'est_in_ports' 'text' 24 'raw' 'est_in_ports'),
            (C 'rss' 'メモリ（MB、参考）' 'RSS' 'vm_rss_kb' 'dec1' 8 'scale' 'vm_rss_kb' $KM), (C 'hwm' 'メモリ（MB、参考）' 'RSS 最大' 'vm_hwm_kb' 'dec1' 9 'scale' 'vm_hwm_kb' $KM),
            (C 'ra' 'メモリ（MB、参考）' '匿名' 'rss_anon_kb' 'dec1' 8 'scale' 'rss_anon_kb' $KM), (C 'rf' 'メモリ（MB、参考）' 'ファイル' 'rss_file_kb' 'dec1' 8 'scale' 'rss_file_kb' $KM)
        )
        Add-CF $sh 'fr' 'bar' '1' 0; Add-CF $sh 'fr' 'ge' '0.8' 0; Add-CF $sh 'cw' 'gt' '0' 1
        Put 'fd' $sh
    }

    # ==================== ④ CPU ====================
    if ($TB.ContainsKey('cpu_sched')) {
        Write-Info '集計: ④ CPU スケジューリング'
        $sh = Build-Sheet $TB['cpu_sched'] '④CPUスケジューリング' 'CPU の使い方と待ち（/proc・cgroup、時系列）' ('④ /proc/stat・/proc/loadavg・/proc/<pid>/task・cgroup の cpu.stat と PSI。JBoss の CPU（コア）= JBoss のプロセスが区間に使った CPU 時間 ÷ 経過時間 (アプリ = HTTP 処理・HTTP I/O・EE・その他のスレッド)。取り分 = タスク定義から求めたこのコンテナの CPU (vCPU)、JVM の CPU 数 = JVM が前提にしている CPU の数 (cpu_env.csv)。実行可能 = CPU を使っている・待っているスレッドの数 (VM 全体)。steal・PSI (CPU を待った時間の割合)・スロットリング (cgroup の CPU 上限で止められた時間) は、空欄 = この環境では取得できない項目です。') 1 $T4 @(
            (CT), (C 'cpus' '基本' 'CPU 数（OS）' 'cpus' 'int' 8 'raw' 'cpus'),
            (C 'jc' 'JBoss の CPU（コア）' '合計' 'jboss_cpu_cores' 'dec2' 8 'raw' 'jboss_cpu_cores'),
            (C 'ap' 'JBoss の CPU（コア）' 'アプリ' 'app_cpu_cores' 'dec2' 8 'raw' 'app_cpu_cores'),
            (C 'gc' 'JBoss の CPU（コア）' 'GC' 'gc_cpu_cores' 'dec2' 8 'raw' 'gc_cpu_cores'),
            (C 'jit' 'JBoss の CPU（コア）' 'JIT' 'jit_cpu_cores' 'dec2' 8 'raw' 'jit_cpu_cores'),
            $(if ($null -ne $share) { (C 'sh' 'JBoss の CPU（コア）' '取り分 (vCPU)' 'cpu_env: share_vcpu' 'dec2' 9 'const' '' 1 $share) }),
            $(if ($null -ne $jvmCpus) { (C 'jv' 'JBoss の CPU（コア）' 'JVM の CPU 数' 'cpu_env: jvm_cpus' 'int' 9 'const' '' 1 $jvmCpus) }),
            (C 'jr' '実行待ち' 'JBoss 実行中スレッド' 'jboss_threads_running' 'int' 10 'raw' 'jboss_threads_running'),
            (C 'pr' '実行待ち' '実行可能（全体）' 'procs_running' 'int' 9 'raw' 'procs_running'),
            (C 'pb' '実行待ち' 'I/O 待ち（全体）' 'procs_blocked' 'int' 9 'raw' 'procs_blocked'),
            (C 'l1' '実行待ち' 'ロード 1 分' 'load1' 'dec2' 8 'raw' 'load1'),
            (C 'cu' 'CPU（%、全 CPU）' 'user' 'cpu_user_pct' 'dec1' 7 'raw' 'cpu_user_pct'), (C 'cn' 'CPU（%、全 CPU）' 'nice' 'cpu_nice_pct' 'dec1' 6 'raw' 'cpu_nice_pct'),
            (C 'cs' 'CPU（%、全 CPU）' 'system' 'cpu_system_pct' 'dec1' 7 'raw' 'cpu_system_pct'), (C 'cw' 'CPU（%、全 CPU）' 'iowait' 'cpu_iowait_pct' 'dec1' 7 'raw' 'cpu_iowait_pct'),
            (C 'ci' 'CPU（%、全 CPU）' 'irq' 'cpu_irq_pct' 'dec1' 6 'raw' 'cpu_irq_pct'), (C 'csi' 'CPU（%、全 CPU）' 'softirq' 'cpu_softirq_pct' 'dec1' 7 'raw' 'cpu_softirq_pct'),
            (C 'cst' 'CPU（%、全 CPU）' 'steal' 'cpu_steal_pct' 'dec1' 7 'raw' 'cpu_steal_pct'), (C 'cid' 'CPU（%、全 CPU）' 'idle' 'cpu_idle_pct' 'dec1' 7 'raw' 'cpu_idle_pct'),
            (C 'ctx' 'OS' 'コンテキストスイッチ/秒' 'ctxt_per_sec' 'int' 11 'raw' 'ctxt_per_sec'),
            (C 'ps' 'CPU の待ち（PSI）' 'some avg10 (%)' 'psi_some_avg10' 'dec2' 9 'raw' 'psi_some_avg10'),
            (C 'pf' 'CPU の待ち（PSI）' 'full avg10 (%)' 'psi_full_avg10' 'dec2' 9 'raw' 'psi_full_avg10'),
            (C 'pm' 'CPU の待ち（PSI）' '待ち時間（区間 ms）' 'psi_some_ms' 'dec1' 10 'raw' 'psi_some_ms'),
            (C 'cp' 'スロットリング（区間）' '周期' 'cfs_periods' 'int' 8 'raw' 'cfs_periods'),
            (C 'ct' 'スロットリング（区間）' '制限された周期' 'cfs_throttled' 'int' 9 'raw' 'cfs_throttled'),
            (C 'ctm' 'スロットリング（区間）' '制限時間 ms' 'cfs_throttled_ms' 'dec1' 9 'raw' 'cfs_throttled_ms')
        )
        Add-CF $sh 'cst' 'ge' '10' 1; Add-CF $sh 'ct' 'gt' '0' 1; Add-CF $sh 'ps' 'ge' '20' 1
        Put 'cpu' $sh
    }

    # ==================== 収集ログ ====================
    $shLog = $null
    if ($logLines.Count -gt 0) {
        $lt = New-Table 'collector.log' @('time', 'component', 'level', 'message')
        $re = [regex]'^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}) \[perf-metrics\] \[([^\]]*)\] ?(.*)$'
        $lv = [regex]'^(INFO|WARN|ERROR|RESULT) (.*)$'
        foreach ($l in $logLines) {
            if ($l.Trim() -eq '') { continue }
            $m = $re.Match($l)
            if ($m.Success) {
                $msg = $m.Groups[3].Value; $level = ''
                $m2 = $lv.Match($msg); if ($m2.Success) { $level = $m2.Groups[1].Value; $msg = $m2.Groups[2].Value }
                $lt.Rows.Add([string[]]@($m.Groups[1].Value, $m.Groups[2].Value, $level, $msg))
            } else { $lt.Rows.Add([string[]]@('', '', '', $l)) }
        }
        $shLog = Build-Sheet $lt '収集ログ' '収集ログ（perf/collector.log）' 'perf-metrics.sh の動作ログです。WARN = 一時的な失敗や設定の注意 (収集は続けています)、RESULT = ④ の判定結果。時刻はコンテナの時刻のままです。' 0 $T0 @(
            (C 'tm' '基本' '時刻（コンテナ）' 'time' 'textc' 19 'raw' 'time'), (C 'cp' '基本' '収集' 'component' 'textc' 10 'raw' 'component'),
            (C 'lv' '基本' 'レベル' 'level' 'textc' 8 'raw' 'level'), (C 'ms' '内容' '内容' 'message' 'text' 160 'raw' 'message')
        )
        Add-CF $shLog 'lv' 'eqs' 'ERROR' 0; Add-CF $shLog 'lv' 'eqs' 'WARN' 1; Add-CF $shLog 'lv' 'eqs' 'RESULT' 2
    }

    # ==================== 所見・主要指標 ====================
    $Find = New-Object System.Collections.Generic.List[object]
    function AddF([int]$lv, [string]$cat, [string]$msg) { $Find.Add(@($lv, $cat, $msg, $Find.Count)) }
    function N0($v) { if ($null -eq $v) { return '－' }; return ([double]$v).ToString('#,0', $Inv) }
    function N1($v) { if ($null -eq $v) { return '－' }; return ([double]$v).ToString('#,0.0', $Inv) }
    function N2($v) { if ($null -eq $v) { return '－' }; return ([double]$v).ToString('#,0.00', $Inv) }
    function P0($v) { if ($null -eq $v) { return '－' }; return ([double]$v * 100).ToString('0', $Inv) + '%' }
    function P1($v) { if ($null -eq $v) { return '－' }; return ([double]$v * 100).ToString('0.0', $Inv) + '%' }
    function Z($v) { if ($null -eq $v) { return 0.0 }; return [double]$v }
    # 主要指標: 分類, 指標, 統計 (最大 / 95% 値 / 平均 / 最小) または値 1 つ, 単位, 備考, 種類 (1 = 統計、0 = 値), 書式
    $KP = New-Object System.Collections.Generic.List[object]
    function KRow([string]$cat, [string]$name, $st, [string]$unit, [string]$note, [string]$fmt) { if ($null -ne $st) { $KP.Add(@($cat, $name, $st, $unit, $note, 1, $fmt)) } }
    function KOne([string]$cat, [string]$name, $v, [string]$unit, [string]$note, [string]$fmt) { if ($null -ne $v) { $KP.Add(@($cat, $name, $v, $unit, $note, 0, $fmt)) } }
    function GName($g) { return ($g.Key -split "`t")[-1] }

    # ---- ① DB 接続プール ----
    $dsSum = New-Object System.Collections.Generic.List[object]
    $sh = $SM['ds']
    if ($null -ne $sh) {
        $cIn = [int]$sh.C['in'] - 1; $cMx = [int]$sh.C['mx'] - 1
        foreach ($g in $sh.Groups) {
            $name = GName $g; $atMax = 0
            for ($i = $g.Start; $i -le $g.End; $i++) { $a = $sh.Rows[$i][$cIn]; $b = $sh.Rows[$i][$cMx]; if ($null -ne $a -and $null -ne $b -and [double]$a -ge [double]$b -and [double]$b -gt 0) { $atMax++ } }
            $d = [pscustomobject]@{ Name = $name; G = $g; Max = (ColLast $sh 'mx' $g); In = (ColStat $sh 'in' $g); Us = (ColStat $sh 'us' $g)
                Wait = (Z (ColSum $sh 'wd' $g)); Fail = (Z (ColSum $sh 'fd' $g)); MaxWait = (ColMax $sh 'mwt' $g); AtMax = $atMax; N = ($g.End - $g.Start + 1)
                AvgGet = (ColLast $sh 'ag' $g); Bw = (ColStat $sh 'bw' $g); Uc = (ColStat $sh 'uc' $g); StatsOff = ([string](ColLast $sh 'se' $g) -eq 'false'); XaRb = (Z (ColSum $sh 'xr' $g))
                Used = ((Z (ColMax $sh 'ac' $g)) -gt 0 -or (Z (ColSum $sh 'wd' $g)) -gt 0) }
            $dsSum.Add($d)
            if ($d.Fail -gt 0) { AddF 3 'DB 接続プール' ('「' + $name + '」で接続の取得失敗 (取得タイムアウト) が ' + (N0 $d.Fail) + ' 件ありました。アプリでは IJ000453 などの例外になります。最大プール (' + (N0 $d.Max) + ') と、接続を長く保持している処理を確認してください。') }
            if ($d.AtMax -gt 0) { AddF 2 'DB 接続プール' ('「' + $name + '」の使用中が最大プール (' + (N0 $d.Max) + ') に達しました (' + $d.AtMax + ' / ' + $d.N + ' 回)。') }
            if ($d.Wait -gt 0) { AddF 2 'DB 接続プール' ('「' + $name + '」で空き接続の待ちが ' + (N0 $d.Wait) + ' 件発生しました (最大待ち時間 ' + (N0 $d.MaxWait) + ' ms、平均待ちスレッド数 最大 ' + $(if ($null -ne $d.Bw) { N1 $d.Bw.Max } else { '－' }) + ')。') }
            elseif ($null -ne $d.Us -and $d.Us.Max -ge 0.8) { AddF 1 'DB 接続プール' ('「' + $name + '」の使用率が最大 ' + (P0 $d.Us.Max) + ' まで上がりました (待ちは発生していません)。') }
            if ($d.StatsOff) { AddF 1 'DB 接続プール' ('「' + $name + '」のプール統計が無効です。値は 0 のままになります。') }
            if ($d.XaRb -gt 0) { AddF 1 'DB 接続プール' ('「' + $name + '」で XA のロールバックが ' + (N0 $d.XaRb) + ' 件ありました。') }
            if ($d.Used) {
                KRow 'DB 接続プール' ($name + ' 使用中') $d.In '接続' ('最大プール ' + (N0 $d.Max) + '・待ち ' + (N0 $d.Wait) + ' 件・取得失敗 ' + (N0 $d.Fail) + ' 件') 'int'
                KRow 'DB 接続プール' ($name + ' 平均待ちスレッド数') $d.Bw 'スレッド' '区間に空き接続を待っていたスレッドの平均' 'dec2'
            }
        }
    }
    # ---- ① HTTP・セッション ----
    $webSum = New-Object System.Collections.Generic.List[object]
    $sh = $SM['web']
    if ($null -ne $sh) {
        foreach ($g in $sh.Groups) {
            $nm = ($g.Key -split "`t") -join ' / '
            $rq = Z (ColSum $sh 'rq' $g); $er = Z (ColSum $sh 'er' $g)
            $w = [pscustomobject]@{ Name = $nm; G = $g; Req = $rq; Err = $er; Rps = (ColStat $sh 'rps' $g); Avg = (ColStat $sh 'avg' $g); Max = (ColMax $sh 'max' $g); Rec = ([string](ColLast $sh 'rr' $g) -eq 'true') }
            $webSum.Add($w)
            if ($er -gt 0) { AddF 2 'HTTP' ('リスナー「' + $nm + '」で 500 番台のエラーが ' + (N0 $er) + ' 件 (リクエストの ' + (P1 ($er / [Math]::Max(1.0, $rq))) + ') 返されました。server.log のスタックトレースと、JMeter のエラーの内容を確認してください。') }
            if ($rq -gt 0) {
                KRow 'HTTP' ($nm + ' リクエスト 毎秒') $w.Rps '件/秒' ('期間中 ' + (N0 $rq) + ' 件・エラー ' + (N0 $er) + ' 件') 'dec1'
                if ($w.Rec) { KRow 'HTTP' ($nm + ' 平均処理時間') $w.Avg 'ミリ秒' ('最大 ' + (N1 $w.Max) + ' ms (累計)') 'dec2' }
            }
        }
        $act = @($webSum | Where-Object { $_.Req -gt 0 })
        if ($act.Count -gt 0 -and @($act | Where-Object { -not $_.Rec }).Count -gt 0) {
            AddF 1 'HTTP' 'Undertow の処理時間は記録していません (record-request-start-time=false。既定値)。サーバー側の平均・最大処理時間も見る場合は、jboss-cli で /subsystem=undertow/server=default-server/http-listener=default:write-attribute(name=record-request-start-time,value=true) を実行して reload してください (わずかに負荷が増えます)。'
        }
    }
    $sh = $SM['ses']
    if ($null -ne $sh) {
        $reqTotal = 0.0; foreach ($w in $webSum) { $reqTotal += $w.Req }
        foreach ($g in $sh.Groups) {
            $nm = $g.Key; $rj = Z (ColSum $sh 'rj' $g); $cr = Z (ColSum $sh 'cr' $g); $mxA = ColMax $sh 'act' $g
            if ($rj -gt 0) { AddF 3 'セッション' ('「' + $nm + '」でセッションの作成が ' + (N0 $rj) + ' 件拒否されました (max-active-sessions の上限)。') }
            if ($cr -ge 100 -and $reqTotal -gt 0 -and $cr / $reqTotal -ge 0.5) { AddF 1 'セッション' ('「' + $nm + '」でリクエストの約 ' + (P0 ($cr / $reqTotal)) + ' が新しいセッションを作っています (期間中 ' + (N0 $cr) + ' 件、同時に最大 ' + (N0 $mxA) + ' 個)。JMeter に HTTP Cookie マネージャーがあるか、アプリが不要なセッションを作っていないかを確認してください (セッションはタイムアウトまでヒープに残ります)。') }
            KRow 'セッション' ($nm + ' アクティブ') (ColStat $sh 'act' $g) '個' ('期間中の作成 ' + (N0 $cr) + ' 件・拒否 ' + (N0 $rj) + ' 件') 'int'
        }
    }
    # ---- ① スレッドプール・IO ワーカー・トランザクション・JVM ----
    $sh = $SM['tp']
    if ($null -ne $sh) {
        foreach ($g in $sh.Groups) {
            $k = $g.Key -split "`t"; $pl = $POOLL[$k[0]]; if ($null -eq $pl) { $pl = $k[0] }; $nm = $pl + ' ' + $k[1]
            $rj = Z (ColSum $sh 'rj' $g); $qm = ColMax $sh 'q' $g; $hg = ColMax $sh 'hg' $g; $am = ColMax $sh 'ac' $g; $mx = ColLast $sh 'mx' $g
            if ($rj -gt 0) { AddF 3 'スレッドプール' ('「' + $nm + '」でタスクの実行が ' + (N0 $rj) + ' 件拒否されました。') }
            if ($null -ne $qm -and $qm -gt 0) { AddF 2 'スレッドプール' ('「' + $nm + '」でタスクの待ち (キュー) が最大 ' + (N0 $qm) + ' 件ありました。') }
            if ($null -ne $hg -and $hg -gt 0) { AddF 2 'スレッドプール' ('「' + $nm + '」でハングと判定されたスレッドが最大 ' + (N0 $hg) + ' 本ありました (hung-task-threshold 超過)。') }
            if ($null -ne $am -and $null -ne $mx -and $mx -gt 0 -and $am -ge $mx) { AddF 2 'スレッドプール' ('「' + $nm + '」の実行中のスレッドが上限 (' + (N0 $mx) + ') に達しました。') }
            if ($null -ne $am -and $am -gt 0) { KRow 'スレッドプール' ($nm + ' 実行中') (ColStat $sh 'ac' $g) 'スレッド' ('上限 ' + (N0 $mx)) 'int' }
        }
    }
    $sh = $SM['iow']
    if ($null -ne $sh) {
        $cB = [int]$sh.C['bt'] - 1; $cM = $(if ($sh.C.ContainsKey('mp')) { [int]$sh.C['mp'] - 1 } else { -1 })
        foreach ($g in $sh.Groups) {
            $nm = $g.Key; $hit = 0
            if ($cM -ge 0) { for ($i = $g.Start; $i -le $g.End; $i++) { $a = $sh.Rows[$i][$cB]; $b = $sh.Rows[$i][$cM]; if ($null -ne $a -and $null -ne $b -and [double]$b -gt 0 -and [double]$a -ge [double]$b) { $hit++ } } }
            $qm = ColMax $sh 'q' $g
            if ($hit -gt 0) { AddF 2 'IO ワーカー' ('IO ワーカー「' + $nm + '」のタスクスレッド (HTTP の処理スレッド) が上限 (' + (N0 (ColLast $sh 'mp' $g)) + ') に達しました (' + $hit + ' / ' + ($g.End - $g.Start + 1) + ' 回)。リクエストがキューで待たされます。遅い処理 (DB 待ちなど) と task-max-threads を確認してください。') }
            elseif ($null -ne $qm -and $qm -gt 0) { AddF 2 'IO ワーカー' ('IO ワーカー「' + $nm + '」でタスクの待ち (キュー) が最大 ' + (N0 $qm) + ' 件ありました。') }
            KRow 'IO ワーカー' ($nm + ' 使用中のタスクスレッド') (ColStat $sh 'bt' $g) 'スレッド' ('上限 ' + (N0 (ColLast $sh 'mp' $g)) + '・I/O スレッド ' + (N0 (ColLast $sh 'io' $g)) + '・接続数 最大 ' + (N0 (ColMax $sh 'cc' $g))) 'int'
        }
    }
    $sh = $SM['tx']
    if ($null -ne $sh) {
        $txTo = Z (ColSum $sh 'to'); $hs = Z (ColSum $sh 'hs'); $ab = Z (ColSum $sh 'a'); $cm = Z (ColSum $sh 'c')
        if ($txTo -gt 0) { AddF 3 'トランザクション' ('トランザクションのタイムアウトが ' + (N0 $txTo) + ' 件ありました。長い処理・ロック待ちを確認してください。') }
        if ($hs -gt 0) { AddF 3 'トランザクション' ('ヒューリスティックな結果 (コミットとロールバックが混在した可能性) が ' + (N0 $hs) + ' 件ありました。XA リソースの状態を確認してください。') }
        if ($ab -gt 0) { AddF 2 'トランザクション' ('中断 (ロールバック) が ' + (N0 $ab) + ' 件ありました (アプリ ' + (N0 (ColSum $sh 'ar')) + '・リソース ' + (N0 (ColSum $sh 'rr')) + '・システム ' + (N0 (ColSum $sh 'sr')) + ')。') }
        KRow 'トランザクション' 'コミット 毎秒' (ColStat $sh 'tps') '件/秒' ('期間中のコミット ' + (N0 $cm) + ' 件・中断 ' + (N0 $ab) + ' 件・タイムアウト ' + (N0 $txTo) + ' 件') 'dec1'
        KRow 'トランザクション' '実行中のトランザクション' (ColStat $sh 'inf') '件' '' 'int'
    }
    $sh = $SM['jvm']
    if ($null -ne $sh) {
        $fails = ColCount $sh 'ok' { param($v) $v -eq 0 }
        if ($fails -gt 0) { AddF 2 'jboss-cli' ('jboss-cli の取得に失敗した回が ' + $fails + ' 回ありました (管理インターフェースが応答しない = JBoss の高負荷・長い GC 停止・停止中)。「収集ログ」と GC の停止時間を確認してください。') }
        $cS = [int]$sh.C['ss'] - 1; $bad = @{}
        foreach ($row in $sh.Rows) { $v = $row[$cS]; if ($null -ne $v -and [string]$v -ne 'running') { $bad[[string]$v] = 1 } }
        if ($bad.Count -gt 0) { AddF 2 'JBoss' ('サーバーの状態が running 以外の回がありました (' + (($bad.Keys | Sort-Object) -join '、') + ')。reload-required のときは設定の変更が反映されていません。') }
        KRow 'JVM（jboss-cli）' 'ライブスレッド数' (ColStat $sh 'lt') 'スレッド' ('OS スレッド 最大 ' + (N0 (ColMax $sh 'os'))) 'int'
        KRow 'JVM（jboss-cli）' 'ヒープ使用量' (ColStat $sh 'hu') 'MB' ('上限 ' + (N0 (ColLast $sh 'hm')) + ' MB') 'dec1'
        KRow 'JVM（jboss-cli）' '処理中のリクエスト' (ColStat $sh 'ar') '件' '同時に処理しているリクエスト (request-controller)' 'int'
        KRow 'JVM（jboss-cli）' 'jboss-cli の応答時間' (ColStat $sh 'ms') 'ミリ秒' ('失敗 ' + $fails + ' 回') 'int'
    }
    # ---- ② jstat・jcmd・JFR ----
    $sh = $SM['js']
    if ($null -ne $sh) {
        $fgc = Z (ColSum $sh 'fn'); $fgt = Z (ColSum $sh 'ft'); $gt = Z (ColSum $sh 'gt'); $spt = Z (ColSum $sh 'spt')
        $t = $TB['jvm_jstat_gc']; $el = [double]($PerfRpt::GD($t, $t.Rows[$t.Rows.Count - 1], 'epoch')) - [double]($PerfRpt::GD($t, $t.Rows[0], 'epoch'))
        $op = ColStat $sh 'op'; $opm = ColStat $sh 'opm'; $ya = ColStat $sh 'ya'
        if ($fgc -gt 0) { AddF 3 'GC' ('Full GC が ' + (N0 $fgc) + ' 回発生しました (合計 ' + (N0 $fgt) + ' ms)。ヒープ不足・メタスペース不足・System.gc() の呼び出しを確認してください。') }
        if ($null -ne $opm) {
            if ($opm.Max -ge 0.85) { AddF 2 'ヒープ' ('Old 領域の使用量が最大ヒープの ' + (P0 $opm.Max) + ' に達しました (最大ヒープ ' + (N0 $maxHeapMB) + ' MB)。GC 後も下がらない場合はメモリリーク・ヒープ不足を疑います。') }
        } elseif ($null -ne $op -and $op.Max -ge 0.85 -and -not $isG1) { AddF 2 'ヒープ' ('Old 領域の使用率 (OU÷OC) が最大 ' + (P0 $op.Max) + ' に達しました。GC 後も下がらない場合はメモリリーク・ヒープ不足を疑います。') }
        if ($el -gt 0) {
            if ($gt / 1000 / $el -ge 0.05) { AddF 2 'GC' ('期間中の GC 時間率が ' + (P1 ($gt / 1000 / $el)) + ' です (目安 5% 未満)。') }
            if ($sh.C.ContainsKey('spt') -and $spt / 1000 / $el -ge 0.05) { AddF 2 'セーフポイント' ('セーフポイントでアプリが止まっていた時間の割合が ' + (P1 ($spt / 1000 / $el)) + ' です (GC 以外の停止を含む)。') }
        }
        KRow 'ヒープ・GC（jstat）' 'ヒープ使用量' (ColStat $sh 'hu') 'MB' ('容量 最大 ' + (N0 (ColMax $sh 'hc')) + ' MB') 'dec1'
        KRow 'ヒープ・GC（jstat）' 'Old 使用量' (ColStat $sh 'ou') 'MB' $(if ($null -ne $opm) { '最大ヒープに対して 最大 ' + (P0 $opm.Max) } elseif ($null -ne $op) { 'Old 使用率 (OU÷OC) 最大 ' + (P0 $op.Max) } else { '' }) 'dec1'
        KRow 'ヒープ・GC（jstat）' 'メタスペース使用量' (ColStat $sh 'mu') 'MB' '' 'dec1'
        KOne 'ヒープ・GC（jstat）' 'Young GC 回数' (ColSum $sh 'yn') '回' ('合計 ' + (N0 (ColSum $sh 'yt')) + ' ms・平均停止 ' + $(if ($null -ne $ya) { (N1 $ya.Avg) + ' ms (最大 ' + (N1 $ya.Max) + ' ms)' } else { '－' })) 'int'
        KOne 'ヒープ・GC（jstat）' 'Full GC 回数' $fgc '回' ('合計 ' + (N0 $fgt) + ' ms') 'int'
        if ($el -gt 0) {
            KOne 'ヒープ・GC（jstat）' 'GC 時間率（期間全体）' ([Math]::Round($gt / 1000 / $el * 100, 3)) '%' ('GC 時間 ' + (N2 ($gt / 1000)) + ' 秒 ÷ 経過 ' + (N0 $el) + ' 秒') 'dec2'
            if ($sh.C.ContainsKey('spt')) { KOne 'ヒープ・GC（jstat）' 'セーフポイント停止率' ([Math]::Round($spt / 1000 / $el * 100, 3)) '%' ('停止 ' + (N2 ($spt / 1000)) + ' 秒 (GC を含む)') 'dec2' }
        }
        if ($sh.C.ContainsKey('cmt')) { KOne 'ヒープ・GC（jstat）' 'JIT のコンパイル時間（期間）' (ColSum $sh 'cmt') 'ミリ秒' ('コンパイル ' + (N0 (ColSum $sh 'cmp')) + ' 件') 'int' }
    }
    $sh = $SM['jgc']
    if ($null -ne $sh) {
        $lp = ColStat $sh 'lp'
        $cc = [int]$sh.C['cs'] - 1; $causes = @{}
        foreach ($row in $sh.Rows) { $c = [string]$row[$cc]; if ($c -ne '') { if ($causes.ContainsKey($c)) { $causes[$c] = $causes[$c] + 1 } else { $causes[$c] = 1 } } }
        if ($null -ne $lp) {
            if ($lp.Max -ge 1000) { AddF 3 'GC（JFR）' ('GC の最長停止が ' + (N0 $lp.Max) + ' ms でした (1 秒以上アプリが止まりました)。') }
            elseif ($lp.Max -ge 200) { AddF 2 'GC（JFR）' ('GC の最長停止が ' + (N0 $lp.Max) + ' ms でした (G1 の停止目標 200 ms を超えています)。') }
        }
        if ($causes.ContainsKey('System.gc()')) { AddF 2 'GC（JFR）' ('System.gc() による GC が ' + $causes['System.gc()'] + ' 回ありました (アプリ・ライブラリ・RMI の分散 GC など)。呼び出し元を確認するか、-XX:+ExplicitGCInvokesConcurrent を検討してください。') }
        $hum = 0; foreach ($k in $causes.Keys) { if ($k -like '*Humongous*') { $hum += $causes[$k] } }
        if ($hum -gt 0) { AddF 1 'GC（JFR）' ('大きなオブジェクト (G1 のリージョンの半分以上の大きさ) の割り当てによる GC (Humongous) が ' + $hum + ' 回ありました。大きな配列・バッファを作る処理を確認してください。') }
        if ($causes.ContainsKey('Metadata GC Threshold')) { AddF 1 'GC（JFR）' ('メタスペースの拡張による GC (Metadata GC Threshold) が ' + $causes['Metadata GC Threshold'] + ' 回ありました。起動直後だけなら問題ありません。') }
        $ha = ColStat $sh 'ha'
        if ($null -ne $ha -and $null -ne $maxHeapMB -and $maxHeapMB -gt 0 -and $ha.P95 / $maxHeapMB -ge 0.85) { AddF 2 'ヒープ' ('GC の直後でもヒープの ' + (P0 ($ha.P95 / $maxHeapMB)) + ' (95% 値 ' + (N0 $ha.P95) + ' MB / 最大 ' + (N0 $maxHeapMB) + ' MB) が使われています。ヒープ不足・メモリリークの可能性があります。') }
        $top = (@($causes.GetEnumerator() | Sort-Object -Property Value -Descending | Select-Object -First 4) | ForEach-Object { $_.Key + ' ' + $_.Value + ' 回' }) -join '・'
        KRow 'GC（JFR）' 'GC の最長停止（1 回ごと）' $lp 'ミリ秒' ('GC ' + (N0 $sh.Rows.Count) + ' 回・停止の合計 ' + (N0 (ColSum $sh 'sp')) + ' ms・原因: ' + $top) 'dec1'
    }
    $sh = $SM['jst']
    if ($null -ne $sh) {
        $ex = ColStat $sh 'exs'
        KRow 'JVM 統計（JFR）' 'JVM の CPU（user + system）' (ColStat $sh 'jt') '%' 'この JVM が見ている CPU 全体を 100%' 'dec1'
        KRow 'JVM 統計（JFR）' '例外の発生' $ex '件/秒' '' 'dec1'
        KRow 'JVM 統計（JFR）' 'スレッドの開始（区間）' (ColStat $sh 'tst') 'スレッド' '多い場合はスレッドプールを使わずにスレッドを作っている可能性' 'int'
        if ($null -ne $ex -and $ex.Avg -ge 100) { AddF 1 '例外' ('例外が毎秒平均 ' + (N0 $ex.Avg) + ' 件作られています (最大 ' + (N0 $ex.Max) + ' 件/秒)。スタックトレースの作成は CPU を使います。JFR の記録 (jdk.JavaErrorThrow など) を JDK Mission Control で開くと発生源が分かります。') }
        $cf = ColMax $sh 'ccu'; if ($null -ne $cf -and $cf -gt 0) { AddF 3 'コードキャッシュ' ('JFR でコードキャッシュの満杯が記録されました (' + (N0 $cf) + ' 回)。JIT コンパイルが止まり、処理が遅くなります。-XX:ReservedCodeCacheSize を増やしてください。') }
        $thr = Z (ColSum $sh 'tms'); if ($thr -gt 0) { AddF 2 'CPU' ('JFR で CPU のスロットリング (cgroup の CPU 上限で止められた時間) が合計 ' + (N0 $thr) + ' ms 記録されました。') }
    }
    $sh = $SM['cc']
    if ($null -ne $sh) {
        $tg = $null; foreach ($g in $sh.Groups) { if ($g.Key -like 'CodeCache*') { $tg = $g } }
        if ($null -eq $tg -and $sh.Groups.Count -gt 0) { $tg = $sh.Groups[$sh.Groups.Count - 1] }
        if ($null -ne $tg) {
            $fc = ColMax $sh 'fc' $tg; $ur = ColMax $sh 'ur' $tg
            if ($null -ne $fc -and $fc -gt 0) { AddF 3 'コードキャッシュ' ('コードキャッシュが満杯になりました (' + (N0 $fc) + ' 回)。JIT コンパイルが止まり、処理が遅くなります。-XX:ReservedCodeCacheSize を増やしてください。') }
            elseif ($null -ne $ur -and $ur -ge 0.9) { AddF 2 'コードキャッシュ' ('コードキャッシュの使用率が最大 ' + (P0 $ur) + ' です。') }
            KRow 'コードキャッシュ' '使用量（合計）' (ColStat $sh 'us' $tg) 'MB' ('サイズ ' + (N0 (ColLast $sh 'sz' $tg)) + ' MB・使用率 最大 ' + (P0 $ur)) 'dec1'
        }
    }
    $sh = $SM['nmt']
    if ($null -ne $sh) {
        $tc = ColStat $sh 'tc'
        if ($null -ne $tc) {
            $first = $null; $c0 = [int]$sh.C['tc'] - 1; foreach ($row in $sh.Rows) { if ($null -ne $row[$c0]) { $first = [double]$row[$c0]; break } }
            $last = [double](ColLast $sh 'tc')
            KRow 'ネイティブメモリ（NMT）' 'コミット（合計）' $tc 'MB' ('最初 ' + (N0 $first) + ' MB → 最後 ' + (N0 $last) + ' MB。大きい順: ' + (($sh.Order | Select-Object -First 4) -join '・')) 'dec1'
            if ($null -ne $first -and $first -gt 0 -and $sh.Rows.Count -ge 6 -and ($last - $first) / $first -ge 0.2) { AddF 1 'ネイティブメモリ' ('JVM のネイティブメモリ (NMT のコミット量) が期間中に ' + (P0 (($last - $first) / $first)) + ' 増えました (' + (N0 $first) + ' → ' + (N0 $last) + ' MB)。増え続ける場合は「②NMT」シートで増えている分類を確認してください。') }
        }
    }
    $topLock = ''
    if ($AT.ContainsKey('jfr_contention')) {
        $t = $AT['jfr_contention']; $r0 = $t.Rows[0]
        $tm = $PerfRpt::GD($t, $r0, 'total_ms')
        $topLock = ($PerfRpt::G($t, $r0, 'site')) + ' (' + ($PerfRpt::G($t, $r0, 'kind')) + '、' + ($PerfRpt::G($t, $r0, 'class')) + ') で合計 ' + (N1 ([double]$tm / 1000)) + ' 秒・最大 ' + (N0 ($PerfRpt::GD($t, $r0, 'max_ms'))) + ' ms'
        if ($null -ne $tm -and $tm -ge 1000) { AddF 1 'ロック競合（JFR）' ('最も長く待ったロック: ' + $topLock + '。「②JFR上位」シートで上位の待ちを確認してください (待ち時間はスレッドごとの合計)。') }
    }
    if ($AT.ContainsKey('jfr_hot_methods')) {
        $t = $AT['jfr_hot_methods']; $r0 = $t.Rows[0]
        KOne 'JFR（CPU）' ('最も CPU を使ったメソッド: ' + ($PerfRpt::G($t, $r0, 'method'))) ($PerfRpt::GD($t, $r0, 'pct')) '%' ('JFR の実行サンプル ' + (N0 ($PerfRpt::GD($t, $r0, 'samples'))) + ' 件 (記録全体)') 'dec1'
    }
    $sh = $SM['ts']
    if ($null -ne $sh) {
        $dbw = ColMax $sh 'dbw'
        if ($null -ne $dbw -and $dbw -gt 0) { AddF 2 'DB 接続プール' ('DB 接続の空きを待って止まっているスレッドが最大 ' + (N0 $dbw) + ' 本ありました (jcmd Thread.print)。最大プールと、接続を長く保持している処理を確認してください。') }
        $bk = ColMax $sh 'http-task.k'
        if ($null -ne $bk -and $bk -gt 0) { AddF 1 'ロック競合' ('HTTP 処理のスレッドがロック (synchronized) の取得待ちで止まっている時がありました (最大 ' + (N0 $bk) + ' 本)。' + $(if ($topLock -ne '') { 'JFR で最も長く待ったロック: ' + $topLock + '。' } else { '' })) }
        KRow 'スレッド状態（jcmd）' '処理中のスレッド（全体）' (ColStat $sh 'abz') 'スレッド' '仕事を待っていない Java スレッド' 'int'
        KRow 'スレッド状態（jcmd）' 'ブロック中のスレッド' (ColStat $sh 'ab') 'スレッド' 'ロック (synchronized) の取得待ち' 'int'
        KRow 'スレッド状態（jcmd）' 'DB 接続待ちのスレッド' (ColStat $sh 'dbw') 'スレッド' 'IronJacamar のプールで空き接続を待っている' 'int'
    }
    # ---- ③ top・proc ----
    $sh = $SM['tops']
    if ($null -ne $sh) {
        $pc = ColStat $sh 'pc'
        if ($null -ne $pc) { AddF 1 '収集の負荷' ('収集処理 (jboss-cli・jstat・jcmd・perf-metrics) の CPU 使用率は平均 ' + (N1 $pc.Avg) + '%・最大 ' + (N1 $pc.Max) + '% でした (1 コア = 100%)。本番と比べる試験では、収集の有無で条件を揃えてください。') }
        KRow '③ top' 'ロードアベレージ（1 分）' (ColStat $sh 'l1') '' ('CPU 数 ' + (M 'container.cpus_online')) 'dec2'
        KRow '③ top' 'JBoss の CPU 使用率' (ColStat $sh 'pj') '%' '1 コア = 100%' 'dec1'
        KRow '③ top' '収集処理の CPU 使用率' $pc '%' 'jboss-cli・jstat・jcmd・perf-metrics の合計' 'dec1'
    }
    $sh = $SM['jt']
    if ($null -ne $sh) {
        foreach ($g in @('http-task', 'gc', 'jit')) { if ($sh.C.ContainsKey($g + '.c')) { KRow '③ JBoss スレッド' ((TG $g) + ' のスレッドの CPU') (ColStat $sh ($g + '.c')) 'コア' ('スレッド数 最大 ' + (N0 (ColMax $sh ($g + '.n')))) 'dec2' } }
        $dw = ColMax $sh 'ad'
        if ($null -ne $dw -and $dw -gt 0) { AddF 1 'ディスク I/O' ('JBoss のスレッドがディスク I/O 待ち (D 状態) になっていた時がありました (最大 ' + (N0 $dw) + ' 本)。ログの出力先 (EFS) への書き込み待ちなどが考えられます。') }
    }
    $sh = $SM['fd']
    if ($null -ne $sh) {
        $fr = ColMax $sh 'fr'; $cw = ColMax $sh 'cw'; $tw = ColMax $sh 'tw'
        if ($null -ne $fr -and $fr -ge 0.8) { AddF 3 'ファイル記述子' ('ファイル記述子の使用率が最大 ' + (P0 $fr) + ' に達しました (上限 ' + (N0 (ColLast $sh 'fl')) + ')。接続・ファイルのクローズ漏れを確認してください。') }
        if ($null -ne $cw -and $cw -gt 0) { AddF 2 'TCP' ('CLOSE_WAIT (相手が切断したのに JBoss 側で閉じていない接続) が最大 ' + (N0 $cw) + ' 本ありました。増え続ける場合は、HTTP クライアント・DB 接続などのクローズ漏れを確認してください。') }
        if ($null -ne $tw -and $tw -ge 1000) { AddF 1 'TCP' ('TIME_WAIT がタスク全体で最大 ' + (N0 $tw) + ' 本ありました。接続を使い回さずに張り直しています (JMeter の Keep-Alive・接続の再利用の設定を確認してください)。') }
        KRow '③ FD・TCP' 'ファイル記述子' (ColStat $sh 'fd') '個' ('上限 ' + (N0 (ColLast $sh 'fl'))) 'int'
        KRow '③ FD・TCP' 'TCP 確立（受信側）' (ColStat $sh 'ti') '本' 'JMeter などから JBoss への接続' 'int'
        KRow '③ FD・TCP' 'TCP 確立（送信側）' (ColStat $sh 'to') '本' 'JBoss から DB などへの接続' 'int'
        KRow '③ FD・TCP' 'TIME_WAIT（タスク全体）' (ColStat $sh 'tw') '本' '' 'int'
    }
    # ---- ④ CPU ----
    $res = CE 'judgement.result'; $rec = CE 'judgement.recommended_active_processor_count'; $jmsg = CE 'judgement.message'
    if ($res -ne '') {
        $lv = 0
        switch ($res) { '要' { $lv = 3 } '要検討' { $lv = 2 } '要確認' { $lv = 1 } '判定不可' { $lv = 1 } }
        AddF $lv '④ ActiveProcessorCount' ($res + ' — ' + $jmsg)
    }
    $sh = $SM['cpu']
    $cpuEv = @{}
    if ($null -ne $sh) {
        $jc = ColStat $sh 'jc'; $gcS = ColStat $sh 'gc'; $st = ColStat $sh 'cst'; $pr = ColStat $sh 'pr'; $ps = ColStat $sh 'ps'; $thr = ColSum $sh 'ct'
        $cpusOs = ColLast $sh 'cpus'
        $cpuEv = @{ jc = $jc; ap = (ColStat $sh 'ap'); gc = $gcS; jit = (ColStat $sh 'jit'); st = $st; pr = $pr; ps = $ps; thr = $thr; cpus = $cpusOs; jr = (ColStat $sh 'jr'); cw = (ColStat $sh 'cw') }
        if ($null -ne $st -and $st.P95 -ge 10) { AddF 2 'CPU' ('CPU の steal (ほかの VM に CPU を取られた時間) が 95% 値で ' + (N1 $st.P95) + '% ありました。') }
        if ($null -ne $pr -and $null -ne $cpusOs -and $pr.P95 -gt [double]$cpusOs) { AddF 2 'CPU' ('実行可能なスレッドの数 (95% 値 ' + (N0 $pr.P95) + ') が CPU 数 (' + (N0 $cpusOs) + ') を超えていました。CPU が足りずに待っているスレッドがあります。') }
        if ($null -ne $ps -and $ps.P95 -ge 20) { AddF 2 'CPU' ('CPU を待った時間の割合 (PSI some avg10) が 95% 値で ' + (N1 $ps.P95) + '% ありました。') }
        if ($null -ne $thr -and $thr -gt 0) { AddF 2 'CPU' ('cgroup の CPU 上限によるスロットリングが ' + (N0 $thr) + ' 周期ありました。') }
        if ($null -ne $jc -and $null -ne $share -and $share -gt 0 -and $jc.P95 -gt $share) { AddF 1 'CPU' ('JBoss の CPU 使用量 (95% 値 ' + (N2 $jc.P95) + ' コア) が、このコンテナの取り分 (' + (N2 $share) + ' vCPU) を超えていました。同じタスクのほかのコンテナが CPU を使うと、取り分まで減って遅くなります (Fargate は CPU シェアで配分)。') }
        if ($null -ne $jc -and $null -ne $gcS -and $jc.Avg -gt 0.05 -and $gcS.Avg / $jc.Avg -ge 0.2) { AddF 2 'GC' ('JBoss の CPU 時間の ' + (P0 ($gcS.Avg / $jc.Avg)) + ' を GC が使っていました。ヒープの大きさ・オブジェクトの作りすぎを確認してください。') }
        KRow '④ CPU' 'JBoss の CPU 使用量' $jc 'コア' $(if ($null -ne $share) { '取り分 ' + (N2 $share) + ' vCPU・JVM の CPU 数 ' + (N0 $jvmCpus) } else { '' }) 'dec2'
        KRow '④ CPU' 'うち GC' $gcS 'コア' '' 'dec2'
        KRow '④ CPU' 'うち JIT' (ColStat $sh 'jit') 'コア' '' 'dec2'
        KRow '④ CPU' '実行可能なスレッド（VM 全体）' $pr 'スレッド' ('CPU 数 ' + (N0 $cpusOs)) 'int'
        KRow '④ CPU' 'CPU の steal' $st '%' '' 'dec1'
        KRow '④ CPU' 'CPU の待ち（PSI some avg10）' $ps '%' '' 'dec2'
    }
    # ---- 収集・JFR ----
    if ($null -ne $shLog) {
        $cL = [int]$shLog.C['lv'] - 1; $cM = [int]$shLog.C['ms'] - 1; $warns = New-Object System.Collections.Generic.List[string]
        foreach ($row in $shLog.Rows) { if ($row[$cL] -eq 'WARN' -or $row[$cL] -eq 'ERROR') { $warns.Add([string]$row[$cM]) } }
        if ($warns.Count -gt 0) { AddF 1 '収集' ('収集ログに WARN / ERROR が ' + $warns.Count + ' 件あります (例: ' + $warns[0] + ')。「収集ログ」シートを確認してください。') }
    }
    if (-not $AT.ContainsKey('jfr_summary') -and $hasJfrFiles) { AddF 1 'JFR' 'JFR の記録 (perf/jfr/*.jfr) はありますが、CSV に変換されていません。コンテナで perf-metrics.sh jfr-csv (または pack) を実行するか、このスクリプトに -ConvertJfr を付けて PC の JDK 17 以降で変換してください。' }
    if ($filtered -and ($AT.ContainsKey('jfr_hot_methods') -or $AT.ContainsKey('jfr_contention'))) { AddF 0 'JFR' '「②JFR上位」のランキングは JFR の記録全体の集計です (-From / -To の期間指定は反映されません)。' }
    if (@($Find | Where-Object { $_[0] -ge 2 }).Count -eq 0) { AddF 0 '全般' '要対応・注意の項目はありません (接続プールの待ち・取得失敗、スレッドプールの上限到達、Full GC、長い GC 停止、CPU の待ち・steal は検出されませんでした)。' }

    # ==================== グラフ ====================
    $sh = $SM['ds']
    if ($null -ne $sh) {
        Add-ChartSection '① DB 接続プール'
        foreach ($d in $dsSum) {
            if (-not $d.Used) { continue }
            $g = $d.G; $dn = $d.Name
            Add-Chart ($dn + '：接続数') '接続数' '#,##0' @((Sr '使用中' $sh 'in' $g), (Sr 'アクティブ' $sh 'ac' $g), (Sr '最大プール' $sh 'mx' $g))
            Add-Chart ($dn + '：待ち・取得失敗（区間）') '件' '#,##0' @((Sr '待ち' $sh 'wd' $g), (Sr '取得失敗' $sh 'fd' $g))
            Add-Chart ($dn + '：平均待ちスレッド数・平均使用接続数') 'スレッド / 接続' '#,##0.0' @((Sr '平均待ちスレッド数' $sh 'bw' $g), (Sr '平均使用接続数' $sh 'uc' $g))
        }
    }
    $shW = $SM['web']; $shS = $SM['ses']
    if ($null -ne $shW -or $null -ne $shS) {
        Add-ChartSection '① HTTP・セッション'
        if ($null -ne $shW) {
            $s1 = @(); $s2 = @(); $s3 = @()
            foreach ($w in $webSum) { if ($w.Req -gt 0) { $s1 += Sr $w.Name $shW 'rps' $w.G; $s2 += Sr $w.Name $shW 'er' $w.G; if ($w.Rec) { $s3 += Sr $w.Name $shW 'avg' $w.G } } }
            Add-Chart 'リクエスト 毎秒（リスナー別）' '件/秒' '#,##0' $s1
            Add-Chart 'エラー（区間、リスナー別）' '件' '#,##0' $s2
            Add-Chart '平均処理時間（ミリ秒、リスナー別）' 'ミリ秒' '#,##0.0' $s3
        }
        if ($null -ne $shS) {
            $s1 = @(); $s2 = @(); foreach ($g in $shS.Groups) { $s1 += Sr $g.Key $shS 'act' $g; $s2 += Sr $g.Key $shS 'crs' $g }
            Add-Chart 'アクティブなセッション' '個' '#,##0' $s1
            Add-Chart 'セッションの作成 毎秒' '件/秒' '#,##0.0' $s2
        }
    }
    $shI = $SM['iow']; $shT = $SM['tp']
    if ($null -ne $shI -or $null -ne $shT) {
        Add-ChartSection '① IO ワーカー・スレッドプール'
        if ($null -ne $shI) {
            foreach ($g in $shI.Groups) {
                Add-Chart ('IO ワーカー「' + $g.Key + '」：タスクスレッド') 'スレッド' '#,##0' @((Sr '使用中' $shI 'bt' $g), (Sr '上限' $shI 'mp' $g), (Sr 'キュー' $shI 'q' $g))
                Add-Chart ('IO ワーカー「' + $g.Key + '」：接続数') '接続' '#,##0' @((Sr '接続数' $shI 'cc' $g))
            }
        }
        if ($null -ne $shT) {
            $s1 = @()
            foreach ($g in $shT.Groups) { if ((Z (ColMax $shT 'ac' $g)) -gt 0 -or (Z (ColMax $shT 'q' $g)) -gt 0) { $k = $g.Key -split "`t"; $pl = $POOLL[$k[0]]; if ($null -eq $pl) { $pl = $k[0] }; $s1 += Sr ($pl + ' ' + $k[1]) $shT 'ac' $g } }
            Add-Chart 'EE・EJB のスレッドプール：実行中' 'スレッド' '#,##0' $s1
        }
    }
    $sh = $SM['tx']
    if ($null -ne $sh) {
        Add-ChartSection '① トランザクション'
        Add-Chart 'コミット 毎秒' '件/秒' '#,##0' @((Sr 'コミット' $sh 'tps'))
        Add-Chart '中断・タイムアウト（区間）' '件' '#,##0' @((Sr '中断' $sh 'a'), (Sr 'タイムアウト' $sh 'to'), (Sr 'ヒューリスティック' $sh 'hs'))
        Add-Chart '実行中のトランザクション' '件' '#,##0' @((Sr '実行中' $sh 'inf'))
    }
    $sh = $SM['jvm']
    if ($null -ne $sh) {
        Add-ChartSection '① JVM（jboss-cli）'
        Add-Chart 'スレッド数' 'スレッド' '#,##0' @((Sr 'ライブ' $sh 'lt'), (Sr 'デーモン' $sh 'dt'), (Sr 'OS' $sh 'os'))
        Add-Chart 'ヒープ（MB）' 'MB' '#,##0' @((Sr '使用' $sh 'hu'), (Sr '確保' $sh 'hc'), (Sr '上限' $sh 'hm'))
        Add-Chart '処理中のリクエスト' '件' '#,##0' @((Sr '処理中' $sh 'ar'))
        Add-Chart 'jboss-cli の応答時間（ミリ秒）' 'ミリ秒' '#,##0' @((Sr '応答時間' $sh 'ms'))
    }
    $sh = $SM['js']
    if ($null -ne $sh) {
        Add-ChartSection '② ヒープ・GC（jstat）'
        Add-Chart 'ヒープ使用量（MB）' 'MB' '#,##0' @((Sr '使用（合計）' $sh 'hu'), (Sr 'Old 使用' $sh 'ou'), (Sr 'Eden 使用' $sh 'eu'), (Sr '容量（合計）' $sh 'hc'))
        Add-Chart 'GC 回数（区間）' '回' '#,##0' @((Sr 'Young' $sh 'yn'), (Sr 'Full' $sh 'fn'), (Sr 'Concurrent' $sh 'cn'))
        Add-Chart 'GC 時間（区間、ミリ秒）' 'ミリ秒' '#,##0' @((Sr 'GC 合計' $sh 'gt'), (Sr 'Young' $sh 'yt'), (Sr 'Full' $sh 'ft'))
        Add-Chart 'メタスペース（MB）' 'MB' '#,##0' @((Sr '使用' $sh 'mu'), (Sr '容量' $sh 'mc'), (Sr 'CCS 使用' $sh 'cu'))
        Add-Chart 'セーフポイント停止（区間、ミリ秒）' 'ミリ秒' '#,##0' @((Sr '停止' $sh 'spt'), (Sr '同期待ち' $sh 'sps'))
        Add-Chart 'JIT コンパイル（区間）' '件 / ミリ秒' '#,##0' @((Sr 'コンパイル数' $sh 'cmp'), (Sr 'コンパイル時間 ms' $sh 'cmt'))
    }
    $shG = $SM['jgc']; $shF = $SM['jst']
    if ($null -ne $shG -or $null -ne $shF) {
        Add-ChartSection '② JFR（GC の停止・JVM の統計）'
        if ($null -ne $shG) {
            Add-Chart 'GC ごとの停止時間（ミリ秒）' 'ミリ秒' '#,##0' @((Sr '最長停止' $shG 'lp'))
            Add-Chart 'GC 直後のヒープ（MB）' 'MB' '#,##0' @((Sr 'GC 後' $shG 'ha'), (Sr '確保' $shG 'hc'), (Sr '最大' $shG 'mh'))
        }
        if ($null -ne $shF) {
            Add-Chart 'JVM の CPU（%）' '%' '#,##0' @((Sr 'JVM user' $shF 'ju'), (Sr 'JVM system' $shF 'js'), (Sr 'マシン全体' $shF 'mt')) 100
            Add-Chart '例外の発生（毎秒）' '件/秒' '#,##0' @((Sr '例外' $shF 'exs'))
            Add-Chart 'スレッドの開始・クラスのロード（区間）' '件' '#,##0' @((Sr 'スレッドの開始' $shF 'tst'), (Sr 'クラスのロード' $shF 'cld'))
            Add-Chart 'コンテキストスイッチ（毎秒、OS 全体）' '回/秒' '#,##0' @((Sr 'コンテキストスイッチ' $shF 'cs'))
        }
    }
    $sh = $SM['ts']
    if ($null -ne $sh) {
        Add-ChartSection '② スレッドの状態（jcmd）'
        Add-Chart 'Java スレッドの状態（全体）' 'スレッド' '#,##0' @((Sr '実行可能' $sh 'ar'), (Sr 'ブロック' $sh 'ab'), (Sr '待機' $sh 'aw'), (Sr '時間待機' $sh 'atw'))
        $s1 = @((Sr '全体' $sh 'abz')); foreach ($g in @('http-task', 'http-io', 'ee-ejb', 'jboss', 'other')) { $s1 += Sr (TG $g) $sh ($g + '.b') }
        Add-Chart '処理中のスレッド（用途別）' 'スレッド' '#,##0' $s1
        Add-Chart 'DB 接続待ち・ロック待ちのスレッド' 'スレッド' '#,##0' @((Sr 'DB 接続待ち' $sh 'dbw'), (Sr 'HTTP 処理のブロック' $sh 'http-task.k'), (Sr 'ブロック（全体）' $sh 'ab'))
    }
    $shC = $SM['cc']; $shN = $SM['nmt']
    if ($null -ne $shC -or $null -ne $shN) {
        Add-ChartSection '② コードキャッシュ・ネイティブメモリ'
        if ($null -ne $shC) { $s1 = @(); foreach ($g in $shC.Groups) { $s1 += Sr $g.Key $shC 'us' $g }; Add-Chart 'コードキャッシュの使用量（MB）' 'MB' '#,##0' $s1 }
        if ($null -ne $shN) {
            $s1 = @((Sr '合計（コミット）' $shN 'tc')); $i = 0
            foreach ($cat in $shN.Order) { $i++; if ($i -gt 6) { break }; $s1 += Sr $cat $shN ('n' + $i) }
            Add-Chart 'ネイティブメモリ（コミット、MB）' 'MB' '#,##0' $s1
        }
    }
    $sh = $SM['tops']
    if ($null -ne $sh) {
        Add-ChartSection '③ top'
        Add-Chart 'ロードアベレージ・実行中のタスク' '' '#,##0.0' @((Sr '1 分' $sh 'l1'), (Sr '5 分' $sh 'l5'), (Sr '実行中のタスク' $sh 'tr'))
        Add-Chart 'CPU の内訳（%、全 CPU）' '%' '#,##0' @((Sr 'us' $sh 'us'), (Sr 'sy' $sh 'sy'), (Sr 'wa' $sh 'wa'), (Sr 'st' $sh 'st')) 100
        Add-Chart 'プロセス別の CPU（%、1 コア = 100）' '%' '#,##0' @((Sr 'JBoss' $sh 'pj'), (Sr '収集処理' $sh 'pc'), (Sr 'その他' $sh 'po'))
    }
    $sh = $SM['jt']
    if ($null -ne $sh) {
        Add-ChartSection '③ JBoss のスレッド（用途別）'
        $s1 = @((Sr '全体' $sh 'ac')); foreach ($g in @('http-task', 'http-io', 'ee-ejb', 'jboss', 'gc', 'jit')) { $s1 += Sr (TG $g) $sh ($g + '.c') }
        Add-Chart 'JBoss の CPU（コア、用途別）' 'コア' '#,##0.0' $s1
        $s1 = @(); foreach ($g in @('http-task', 'http-io', 'ee-ejb', 'jboss', 'gc', 'jit', 'other')) { $s1 += Sr (TG $g) $sh ($g + '.n') }
        Add-Chart 'JBoss のスレッド数（用途別）' 'スレッド' '#,##0' $s1
        Add-Chart '実行中・ディスク待ちのスレッド' 'スレッド' '#,##0' @((Sr '実行中 (R)' $sh 'ar'), (Sr 'ディスク待ち (D)' $sh 'ad'))
        Add-Chart '非自発的なコンテキストスイッチ（毎秒）' '回/秒' '#,##0' @((Sr '全体' $sh 'av'), (Sr 'HTTP 処理' $sh 'http-task.v'), (Sr 'GC' $sh 'gc.v'))
    }
    $sh = $SM['fd']
    if ($null -ne $sh) {
        Add-ChartSection '③ ファイル記述子・TCP'
        Add-Chart 'TCP 接続（JBoss）' '本' '#,##0' @((Sr '確立（受信側）' $sh 'ti'), (Sr '確立（送信側）' $sh 'to'), (Sr 'CLOSE_WAIT' $sh 'cw'))
        Add-Chart 'TIME_WAIT（タスク全体）・ファイル記述子' '個' '#,##0' @((Sr 'TIME_WAIT' $sh 'tw'), (Sr 'ファイル記述子' $sh 'fd'))
    }
    $sh = $SM['cpu']
    if ($null -ne $sh) {
        Add-ChartSection '④ CPU（ActiveProcessorCount の判定材料）'
        Add-Chart 'JBoss の CPU 使用量と取り分（コア）' 'コア' '#,##0.0' @((Sr 'JBoss 合計' $sh 'jc'), (Sr 'アプリ' $sh 'ap'), (Sr 'GC' $sh 'gc'), (Sr 'JIT' $sh 'jit'), (Sr '取り分 (vCPU)' $sh 'sh'), (Sr 'JVM の CPU 数' $sh 'jv'))
        Add-Chart '実行可能なスレッドと CPU 数' 'スレッド' '#,##0' @((Sr '実行可能（全体）' $sh 'pr'), (Sr 'JBoss 実行中' $sh 'jr'), (Sr 'CPU 数（OS）' $sh 'cpus'))
        Add-Chart 'CPU の steal・iowait（%）' '%' '#,##0.0' @((Sr 'steal' $sh 'cst'), (Sr 'iowait' $sh 'cw'))
        Add-Chart 'CPU の待ち（PSI）・スロットリング' '' '#,##0.0' @((Sr 'PSI some avg10 (%)' $sh 'ps'), (Sr 'スロットリング ms' $sh 'ctm'))
    }

    # ==================== 補助シート (セクション形式) ====================
    function V([object]$v, [string]$f) { return @{ V = $v; F = $f } }
    # ---- ② JFR 上位 ----
    $secJfrTop = New-Object System.Collections.Generic.List[object]
    if ($AT.ContainsKey('jfr_hot_methods')) {
        $t = $AT['jfr_hot_methods']
        $sec = New-Sec 'CPU を使ったメソッド（実行サンプルの上位）' 'JFR の jdk.ExecutionSample (実行中のスレッドを一定間隔で見て、そのとき動いていたメソッドを数えたもの)。割合 = 全サンプルに対する割合。JDK の内部のメソッドも含みます。' @('順位', '種類', 'サンプル数', '割合（%）', '', '', 'メソッド') @('int', 'textc', 'int', 'dec1', 'text', 'text', 'wrap+')
        foreach ($r in ($t.Rows | Select-Object -First 50)) { Sec-Add $sec @(($PerfRpt::GD($t, $r, 'rank')), 'CPU', ($PerfRpt::GD($t, $r, 'samples')), ($PerfRpt::GD($t, $r, 'pct')), $null, $null, ($PerfRpt::G($t, $r, 'method'))) }
        $secJfrTop.Add($sec)
    }
    if ($AT.ContainsKey('jfr_contention')) {
        $t = $AT['jfr_contention']
        $sec = New-Sec 'ロック・待ちの上位（待ち時間の合計が長い順）' 'monitor-enter = synchronized のロック待ち (jdk.JavaMonitorEnter)、thread-park = java.util.concurrent のロック・セマフォなどの待ち (jdk.ThreadPark。仕事を待っているだけのスレッドプールの待ちは除いています)。待った場所 = JDK 以外で最初のメソッド。合計はスレッドごとの待ち時間の合計です。' @('順位', '種類', '回数', '合計（ms）', '最大（ms）', '平均（ms）', 'ロックの種類（クラス）', '待った場所') @('int', 'textc', 'int', 'dec1', 'dec1', 'dec2', 'wrap', 'wrap')
        foreach ($r in ($t.Rows | Select-Object -First 50)) {
            $cnt = $PerfRpt::GD($t, $r, 'count'); $tot = $PerfRpt::GD($t, $r, 'total_ms')
            Sec-Add $sec @(($PerfRpt::GD($t, $r, 'rank')), ($PerfRpt::G($t, $r, 'kind')), $cnt, $tot, ($PerfRpt::GD($t, $r, 'max_ms')), ($PerfRpt::Div($tot, $cnt)), ($PerfRpt::G($t, $r, 'class')), ($PerfRpt::G($t, $r, 'site')))
        }
        $secJfrTop.Add($sec)
    }
    if ($AT.ContainsKey('jfr_io')) {
        $t = $AT['jfr_io']
        $sec = New-Sec 'ソケット・ファイルの I/O の上位（待ち時間の合計が長い順）' 'JFR の jdk.SocketRead / SocketWrite / FileRead / FileWrite (既定の設定では 20 ms 以上かかったものだけが記録されます)。socket-read の相手が DB なら、DB の応答待ちの時間です。' @('順位', '種類', '回数', '合計（ms）', '最大（ms）', 'KB', '対象') @('int', 'textc', 'int', 'dec1', 'dec1', 'dec1', 'wrap+')
        foreach ($r in ($t.Rows | Select-Object -First 50)) {
            $by = $PerfRpt::GD($t, $r, 'bytes'); $kb = $null; if ($null -ne $by) { $kb = [Math]::Round([double]$by / 1024, 1) }
            Sec-Add $sec @(($PerfRpt::GD($t, $r, 'rank')), ($PerfRpt::G($t, $r, 'kind')), ($PerfRpt::GD($t, $r, 'count')), ($PerfRpt::GD($t, $r, 'total_ms')), ($PerfRpt::GD($t, $r, 'max_ms')), $kb, ($PerfRpt::G($t, $r, 'target')))
        }
        $secJfrTop.Add($sec)
    }
    if ($AT.ContainsKey('jfr_vm_operations')) {
        $t = $AT['jfr_vm_operations']
        $sec = New-Sec 'VM の操作・セーフポイント（合計時間が長い順）' 'JVM がアプリのスレッドを止めて行う操作 (GC・最適化の取り消し・スレッドダンプなど)。(safepoint) が付いたものは、その間すべてのアプリのスレッドが止まります。' @('順位', '種類', '回数', '合計（ms）', '最大（ms）', '平均（ms）', '操作') @('int', 'textc', 'int', 'dec1', 'dec1', 'dec2', 'wrap+')
        foreach ($r in ($t.Rows | Select-Object -First 50)) {
            $cnt = $PerfRpt::GD($t, $r, 'count'); $tot = $PerfRpt::GD($t, $r, 'total_ms')
            Sec-Add $sec @(($PerfRpt::GD($t, $r, 'rank')), ($PerfRpt::G($t, $r, 'kind')), $cnt, $tot, ($PerfRpt::GD($t, $r, 'max_ms')), ($PerfRpt::Div($tot, $cnt)), ($PerfRpt::G($t, $r, 'operation')))
        }
        $secJfrTop.Add($sec)
    }
    # ---- ② JFR 記録 ----
    $secJfrRec = New-Object System.Collections.Generic.List[object]
    if ($AT.ContainsKey('jfr_summary')) {
        $t = $AT['jfr_summary']
        $sec = New-Sec '読み込んだ記録ファイル' ('perf/jfr/ の記録 (JBoss の終了時に書かれる perf_<pid>_<日時>.jfr、記録中のチャンク repo/、jfr-dump で作ったもの)。' + $jfrNote) @('種類', 'ファイル', 'イベント数', '', '', '状態・パス') @('textc', 'wrap', 'int', 'text', 'text', 'wrap')
        foreach ($r in $t.Rows) { if ($PerfRpt::G($t, $r, 'kind') -eq 'file') { $p = $PerfRpt::G($t, $r, 'name'); Sec-Add $sec @('ファイル', ([IO.Path]::GetFileName($p.Replace('/', '\'))), ($PerfRpt::GD($t, $r, 'count')), $null, $null, (($PerfRpt::G($t, $r, 'detail')) + '  ' + $p)) } }
        $secJfrRec.Add($sec)
    }
    if ($AT.ContainsKey('jfr_env')) {
        $t = $AT['jfr_env']
        $sec = New-Sec 'JVM・OS・GC の情報（JFR の記録から）' '' @('分類', '項目', '値') @('key', 'text', 'wrap+')
        foreach ($r in $t.Rows) { Sec-Add $sec @(($PerfRpt::G($t, $r, 'category')), ($PerfRpt::G($t, $r, 'key')), ($PerfRpt::G($t, $r, 'value'))) }
        $secJfrRec.Add($sec)
    }
    if ($AT.ContainsKey('jfr_summary')) {
        $t = $AT['jfr_summary']
        $sec = New-Sec 'イベントの件数（種類別）' 'JFR に記録されたイベントの種類と件数。JDK Mission Control (JMC) で .jfr を開くと、ここに無い詳細 (スタックトレース・割り当て・ロックの持ち主など) も見られます。' @('種類', 'イベント', '件数', '最初', '最後', '') @('textc', 'text', 'int', 'textc', 'textc', 'text')
        foreach ($r in $t.Rows) { if ($PerfRpt::G($t, $r, 'kind') -eq 'event') { Sec-Add $sec @('イベント', ($PerfRpt::G($t, $r, 'name')), ($PerfRpt::GD($t, $r, 'count')), ($PerfRpt::G($t, $r, 'first')), ($PerfRpt::G($t, $r, 'last')), $null) } }
        $secJfrRec.Add($sec)
    }
    # ---- ④ CPU 判定 ----
    $secCpu = New-Object System.Collections.Generic.List[object]
    if ($CE.Count -gt 0) {
        $sec = New-Sec '判定結果' '' @() @('key', 'big', 'wrap+')
        Sec-Add $sec @('-XX:ActiveProcessorCount の要否', $(if ($res -ne '') { $res } else { '－' }), $jmsg)
        $secCpu.Add($sec)
        $sec = New-Sec '' '' @() @('key', 'bold+')
        if ($rec -ne '' -and ($res -eq '要' -or $res -eq '要検討')) { Sec-Add $sec @('推奨する指定', ('-XX:ActiveProcessorCount=' + $rec)) }
        if ($rec -ne '' -and ($res -eq '要' -or $res -eq '要検討')) { Sec-Add $sec @('指定する場所', 'JBoss の JVM オプション (standalone.conf の JAVA_OPTS、またはタスク定義の環境変数 PREPEND_JAVA_OPTS。JAVA_OPTS を環境変数で丸ごと設定すると standalone.conf の既定値 -Xms・-Xmx などが使われなくなるため、PREPEND_JAVA_OPTS への追加を推奨)') }
        Sec-Add $sec @('このコンテナの CPU の取り分', $(if ($null -ne $share) { (N2 $share) + ' vCPU' + $(if ((CE 'ecs.container_cpu_units') -ne '') { '  (コンテナ定義の cpu ' + (CE 'ecs.container_cpu_units') + ' ユニット)' } elseif ((CE 'ecs.task_cpu_vcpu') -ne '') { '  (タスクの ' + (CE 'ecs.task_cpu_vcpu') + ' vCPU ÷ JVM のコンテナ ' + (CE 'ecs.jvm_containers') + ' 個)' } else { '' }) } else { '－' }))
        Sec-Add $sec @('JVM が認識した CPU 数', $(if ($null -ne $jvmCpus) { (N0 $jvmCpus) + ' 個' + $(if ((CE 'os.cpus_online') -ne '') { '  (OS のオンライン CPU ' + (CE 'os.cpus_online') + ' 個・cgroup の CPU 上限 ' + $(if ((CE 'cgroup.cpu_quota_cores') -ne '') { (CE 'cgroup.cpu_quota_cores') + ' コア' } else { 'なし' }) + ')' } else { '' }) } else { '－' }))
        $secCpu.Add($sec)
        $sec = New-Sec '判定の裏付け（性能試験中の実測）' '取り分より JBoss の CPU 使用量が大きい・実行可能なスレッドが CPU 数を超える・非自発的な切り替えが多いときは、CPU 数を前提にしたスレッド (GC・JIT・HTTP I/O) が CPU を奪い合っています。' @('項目', '最大', '95% 値', '平均', '最小', '単位', '説明') @('key', 'dec2', 'dec2', 'dec2', 'dec2', 'textc', 'wrap')
        $ev = @(
            @('JBoss の CPU 使用量', 'jc', 'コア', '④CPUスケジューリング: JBoss のプロセスの CPU 時間 ÷ 経過時間'),
            @('うちアプリ', 'ap', 'コア', 'HTTP 処理・HTTP I/O・EE・その他のスレッド'),
            @('うち GC', 'gc', 'コア', 'GC のスレッド (ParallelGCThreads・ConcGCThreads は CPU 数から決まる)'),
            @('うち JIT', 'jit', 'コア', 'JIT コンパイラのスレッド (CICompilerCount は CPU 数から決まる)'),
            @('実行可能なスレッド（VM 全体）', 'pr', 'スレッド', '/proc/stat の procs_running。CPU 数を超えると待ちが発生'),
            @('JBoss の実行中のスレッド', 'jr', 'スレッド', '取得した瞬間に実行中 (R) だった JBoss のスレッド'),
            @('CPU の steal', 'st', '%', 'ほかの VM に CPU を取られた時間の割合'),
            @('CPU の待ち（PSI some avg10）', 'ps', '%', 'CPU を待ったスレッドがあった時間の割合 (取得できる環境のみ)')
        )
        foreach ($e in $ev) { $s = $cpuEv[$e[1]]; if ($null -ne $s) { Sec-Add $sec @($e[0], ([Math]::Round($s.Max, 3)), ([Math]::Round($s.P95, 3)), ([Math]::Round($s.Avg, 3)), ([Math]::Round($s.Min, 3)), $e[2], $e[3]) } }
        $shJ = $SM['jt']
        if ($null -ne $shJ) { $s = ColStat $shJ 'av'; if ($null -ne $s) { Sec-Add $sec @('非自発的なコンテキストスイッチ', ([Math]::Round($s.Max, 1)), ([Math]::Round($s.P95, 1)), ([Math]::Round($s.Avg, 1)), ([Math]::Round($s.Min, 1)), '回/秒', '③JBossスレッド: 実行中に CPU を取り上げられた回数 (JBoss 全体)') } }
        if ($sec.Rows.Count -gt 0) { $secCpu.Add($sec) }
        $sec = New-Sec 'CPU 数から自動で決まる値（この JVM の実際の値）' 'JVM・JBoss は起動時に CPU 数を見て、次のスレッド数などを決めます。CPU 数を多く見積もると、取り分に対してスレッドが多すぎて CPU を奪い合います。' @('項目', '値', '決まり方') @('key', 'wrap+1', 'wrap+')
        foreach ($k in @(@('jvm.ActiveProcessorCount', '-1 = 指定なし (JVM が CPU 数を自分で決める)'), @('jvm.ParallelGCThreads', 'GC の並列スレッド。CPU 8 個までは CPU 数と同じ'), @('jvm.ConcGCThreads', 'G1 の並行マーキングのスレッド (ParallelGCThreads の約 1/4)'), @('jvm.CICompilerCount', 'JIT コンパイラのスレッド (CPU 数の対数に比例)'), @('jvm.gc', 'GC の種類。CPU 1 個・メモリ 1792MB 未満では Serial GC が選ばれる'), @('jvm.UseContainerSupport', 'コンテナの cgroup の上限を JVM が読むか (既定 true)'), @('jvm.MaxHeapSize', '最大ヒープ (バイト)'))) {
            if ($CE.Contains($k[0])) { Sec-Add $sec @(($k[0] -replace '^jvm\.', ''), ((CE $k[0]) + '  ' + [string]$CEN[$k[0]]), $k[1]) }
        }
        $shI = $SM['iow']
        if ($null -ne $shI -and $shI.Groups.Count -gt 0) {
            $g = $shI.Groups[0]
            Sec-Add $sec @('IO ワーカーの I/O スレッド', (N0 (ColLast $shI 'io' $g)), 'Undertow の I/O スレッド。既定 = CPU 数 × 2')
            Sec-Add $sec @('IO ワーカーのタスクスレッドの上限', (N0 (ColLast $shI 'mp' $g)), 'HTTP リクエストを処理するスレッドの上限。既定 = CPU 数 × 16')
        }
        $secCpu.Add($sec)
        $CAT = @{ ecs = 'ECS'; os = 'OS'; cgroup = 'cgroup'; jvm = 'JVM'; jvm_container = 'JVM コンテナ'; probe = '新しい JVM'; judgement = '判定' }
        $sec = New-Sec ('収集した値（cpu_env.csv、PID ' + $(if ($AT.ContainsKey('cpu_env')) { $PerfRpt::G($AT['cpu_env'], $AT['cpu_env'].Rows[$AT['cpu_env'].Rows.Count - 1], 'pid') } else { '' }) + '）') 'perf-metrics.sh が JVM の起動後に 1 回だけ集めた値です (ECS タスクメタデータ v4・/proc・cgroup・jcmd VM.flags / VM.info・オプション無しの新しい JVM)。' @('分類 / 項目', '値', '説明') @('key', 'wrap+4', 'wrap')
        foreach ($k in $CE.Keys) { $p = $k.Split('.', 2); $cl = $CAT[$p[0]]; if ($null -eq $cl) { $cl = $p[0] }; Sec-Add $sec @(($cl + ' / ' + $p[1]), ([string]$CE[$k]), ([string]$CEN[$k])) }
        $secCpu.Add($sec)
    }
    # ---- サマリー ----
    $secSum = New-Object System.Collections.Generic.List[object]
    $sec = New-Sec '所見' '' @('重要度', '分類', '内容') @('sevl', 'bold', 'wrap+')
    # 重要度の高い順。同じ重要度は追加した順 (Sort-Object は安定ソートではないため 2 番目のキーに追加順を使う)
    foreach ($f in ($Find | Sort-Object -Property @{ Expression = { $_[0] }; Descending = $true }, @{ Expression = { $_[3] }; Descending = $false })) {
        $lv = [int]$f[0]
        $lab = switch ($lv) { 3 { '■ 要対応' } 2 { '▲ 注意' } 1 { '● 参考' } default { '○ 良好' } }
        $st = switch ($lv) { 3 { 'sevh' } 2 { 'sevm' } default { 'sevl' } }
        Sec-Add $sec @((V $lab $st), $f[1], $f[2])
    }
    $secSum.Add($sec)
    if ($res -ne '') {
        $sec = New-Sec '④ -XX:ActiveProcessorCount の判定' '' @() @('key', 'big', 'wrap+')
        Sec-Add $sec @('判定', $res, ($jmsg + $(if ($rec -ne '' -and ($res -eq '要' -or $res -eq '要検討')) { '  →  推奨: -XX:ActiveProcessorCount=' + $rec } else { '' }) + '  (根拠は「④CPU判定」シート)'))
        $secSum.Add($sec)
    }
    $sec = New-Sec '主要指標' '最大・95% 値・平均・最小は、期間中の取得値 (区間の値) から求めています。値が 1 つの行は期間全体の値です。' @('分類', '指標', '最大', '95% 値', '平均', '最小', '単位', '備考') @('key', 'wrap', 'dec1', 'dec1', 'dec1', 'dec1', 'textc', 'wrap')
    $BF = @{ int = 'intb'; dec1 = 'dec1b'; dec2 = 'dec2b'; pct = 'pctb' }
    foreach ($k in $KP) {
        $fm = $k[6]; $fb = $BF[$fm]; if ($null -eq $fb) { $fb = 'dec1b' }
        if ($k[5] -eq 0) { Sec-Add $sec @($k[0], $k[1], (V ([Math]::Round([double]$k[2], 3)) $fb), (V '' 'muted'), (V '' 'muted'), (V '' 'muted'), $k[3], $k[4]) }
        else { $s = $k[2]; Sec-Add $sec @($k[0], $k[1], (V ([Math]::Round($s.Max, 3)) $fb), (V ([Math]::Round($s.P95, 3)) $fm), (V ([Math]::Round($s.Avg, 3)) $fm), (V ([Math]::Round($s.Min, 3)) $fm), $k[3], $k[4]) }
    }
    $secSum.Add($sec)
    if ($dsSum.Count -gt 0) {
        $sec = New-Sec 'DB 接続プール（データソース別）' '' @('データソース', '使用中 最大 / 最大プール', '使用率 最大', '使用率 平均', '待ち（件）', '取得失敗（件）', '平均待ちスレッド 最大', '平均取得（ms、最終）') @('key', 'textc', 'pctb', 'pct', 'int', 'int', 'dec2', 'int')
        foreach ($d in $dsSum) {
            Sec-Add $sec @($d.Name, ((N0 $(if ($null -ne $d.In) { $d.In.Max } else { $null })) + ' / ' + (N0 $d.Max)), $(if ($null -ne $d.Us) { [Math]::Round($d.Us.Max, 4) } else { $null }), $(if ($null -ne $d.Us) { [Math]::Round($d.Us.Avg, 4) } else { $null }),
                (V $d.Wait $(if ($d.Wait -gt 0) { 'intb' } else { 'int' })), (V $d.Fail $(if ($d.Fail -gt 0) { 'intb' } else { 'int' })), $(if ($null -ne $d.Bw) { [Math]::Round($d.Bw.Max, 3) } else { $null }), $d.AvgGet)
        }
        $secSum.Add($sec)
    }
    $act = @($webSum | Where-Object { $_.Req -gt 0 })
    if ($act.Count -gt 0) {
        $sec = New-Sec 'HTTP（リスナー別）' '' @('リスナー', 'リクエスト（件）', '毎秒 最大', '毎秒 平均', 'エラー（件）', 'エラー率', '平均処理時間（ms）') @('key+1', 'int', 'dec1', 'dec1', 'int', 'pct', 'dec2')
        foreach ($w in $act) { Sec-Add $sec @($w.Name, $w.Req, $(if ($null -ne $w.Rps) { [Math]::Round($w.Rps.Max, 2) } else { $null }), $(if ($null -ne $w.Rps) { [Math]::Round($w.Rps.Avg, 2) } else { $null }), (V $w.Err $(if ($w.Err -gt 0) { 'intb' } else { 'int' })), ([Math]::Round($w.Err / [Math]::Max(1.0, $w.Req), 4)), $(if ($null -ne $w.Avg) { [Math]::Round($w.Avg.Avg, 2) } else { '記録なし' })) }
        $secSum.Add($sec)
    }
    $sec = New-Sec '収集情報（抜粋。全項目は「収集情報」シート）' '' @() @('key', 'text+')
    $iv = 'jboss-cli ' + (M 'perf.cli_interval') + ' / jstat ' + (M 'perf.jstat_interval') + ' / jcmd ' + (M 'perf.jcmd_interval') + ' / top ' + (M 'perf.top_interval') + ' / ps ' + (M 'perf.ps_interval') + ' / proc ' + (M 'perf.proc_interval') + ' 秒'
    foreach ($it in @(@('対象', $who.Label), @('タスク (LOG_ID)', $who.LogId), @('ECS', ((M 'ecs.Family') + ':' + (M 'ecs.Revision') + '  ' + (M 'ecs.container.Name') + '  ' + (M 'ecs.LaunchType') + '  ' + (M 'ecs.AvailabilityZone')).Trim()),
            @('CPU・メモリ（タスク定義）', $(if ((M 'ecs.Limits.CPU') -ne '') { 'タスク ' + (M 'ecs.Limits.CPU') + ' vCPU / ' + (M 'ecs.Limits.Memory') + ' MiB、コンテナ ' + (M 'ecs.container.Limits.CPU') + ' ユニット / ' + (M 'ecs.container.Limits.Memory') + ' MiB' } else { '' })),
            @('JBoss / JVM', ((M 'jboss.product-name') + ' ' + (M 'jboss.product-version') + ' / ' + (M 'jvm.version')).Trim(' ', '/')), @('OS', (M 'container.os')),
            @('収集間隔', $iv), @('JFR', (M 'perf.jfr_note')), @('出力先', (M 'perf.output_dir')),
            @('収集開始', ((M 'perf.start_time') + ' (コンテナの時刻、UTC' + (M 'perf.utc_offset') + ')')))) {
        if ([string]::IsNullOrWhiteSpace($it[1])) { continue }
        Sec-Add $sec @($it[0], $it[1])
    }
    $secSum.Add($sec)

    # ==================== ブックの書き出し ====================
    $range = (SerialText $script:TMin) + ' ～ ' + (SerialText $script:TMax) + '（' + ([TimeSpan]::FromDays($script:TMax - $script:TMin)).ToString('hh\:mm\:ss') + '）'
    $tzNote = $(if ($UseRecordedTime) { 'コンテナで記録した時刻 (UTC' + $uo + ')' } else { 'この PC のタイムゾーン (' + [TimeZoneInfo]::Local.DisplayName + ')' })
    $Book = New-Object System.Collections.Generic.List[object]
    function BookAdd([string]$name, [string]$kind, $obj) { $Book.Add([pscustomobject]@{ Name = $name; Kind = $kind; Obj = $obj }) }
    BookAdd 'サマリー' 'summary' $null
    BookAdd 'グラフ' 'charts' $null
    foreach ($s in $Sheets) { if ($s.Name.StartsWith('①')) { BookAdd $s.Name 'table' $s } }
    foreach ($s in $Sheets) { if ($s.Name.StartsWith('②')) { BookAdd $s.Name 'table' $s } }
    if ($secJfrTop.Count -gt 0) { BookAdd '②JFR上位' 'jfrtop' $null }
    if ($secJfrRec.Count -gt 0) { BookAdd '②JFR記録' 'jfrrec' $null }
    foreach ($s in $Sheets) { if ($s.Name.StartsWith('③')) { BookAdd $s.Name 'table' $s } }
    if ($secCpu.Count -gt 0) { BookAdd '④CPU判定' 'cpujudge' $null }
    foreach ($s in $Sheets) { if ($s.Name.StartsWith('④')) { BookAdd $s.Name 'table' $s } }
    if ($null -ne $shLog) { BookAdd '収集ログ' 'table' $shLog }
    BookAdd '収集情報' 'meta' $null
    BookAdd '凡例' 'legend' $null

    $repTitle = $Title + $(if ($who.Label -ne '') { '　' + $who.Label } else { '' })
    $dir2 = Split-Path -Parent $outPath
    $tmp = Join-Path $dir2 ('.' + [IO.Path]::GetFileName($outPath) + '.' + [Guid]::NewGuid().ToString('N') + '.tmp')
    $fs = [IO.File]::Open($tmp, [IO.FileMode]::Create)
    $zip = New-Object IO.Compression.ZipArchive($fs, [IO.Compression.ZipArchiveMode]::Create)
    $nChart = 0
    try {
        for ($i = 0; $i -lt $Book.Count; $i++) {
            $b = $Book[$i]; $idx = $i + 1; $ent = 'xl/worksheets/sheet' + $idx + '.xml'
            switch ($b.Kind) {
                'table' { Write-Info ("シートを書いています: {0} ({1:N0} 行)" -f $b.Name, $b.Obj.Rows.Count); Write-TableSheet $zip $b.Obj $idx }
                'summary' {
                    $sub = $(if ($who.Label -ne '') { $who.Label + '　　' } else { '' }) + 'タスク ' + $who.LogId + '　　' + $range
                    $note = '時刻は ' + $tzNote + ' で表示しています。' + $(if ($filtered) { '期間を指定しています (-From ' + $From + ' -To ' + $To + ')。' } else { '' }) + '作成: ' + (Get-Date -Format 'yyyy/MM/dd HH:mm') + '　New-PerfMetricsReport.ps1 ' + $Version
                    Add-TextEntry $zip $ent (Write-SectionsSheet $idx $b.Name $Title $note @(16, 34, 12, 12, 12, 12, 9, 46) $secSum 'FF000000' 'portrait' $true $sub)
                }
                'charts' {
                    Write-Info 'グラフを作成しています...'
                    Add-TextEntry $zip $ent (Write-ChartsSheet $zip $idx $b.Name ('グラフ　' + $who.Label + '　' + $who.LogId) ('時間軸は全グラフ共通 (' + $range + '、' + $tzNote + ')。モノトーン表示のため線の種類で系列を区別しています (実線 → 破線 → 点線 → 長破線 → 一点鎖線 の順)。元データは各シートにあります。'))
                    $nChart = $script:NCH
                    if ($nChart -gt 0) { Add-TextEntry $zip ('xl/worksheets/_rels/sheet' + $idx + '.xml.rels') ('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' + "`n" + '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/drawing" Target="../drawings/drawing1.xml"/></Relationships>') }
                }
                'jfrtop' { Add-TextEntry $zip $ent (Write-SectionsSheet $idx $b.Name 'JFR の上位（CPU・ロック・I/O・VM の操作）' ('② JFR (Flight Recorder) の記録全体の集計 (perf-metrics.sh jfr-csv)。' + $jfrNote) @(6, 14, 10, 12, 10, 10, 60, 64) $secJfrTop $T2 'landscape' $false) }
                'jfrrec' { Add-TextEntry $zip $ent (Write-SectionsSheet $idx $b.Name 'JFR の記録' '② JFR の記録ファイル・JVM の情報・イベントの件数。.jfr は JDK Mission Control で開けます。' @(14, 40, 12, 19, 19, 80) $secJfrRec $T2 'landscape' $false) }
                'cpujudge' { Add-TextEntry $zip $ent (Write-SectionsSheet $idx $b.Name '④ -XX:ActiveProcessorCount の要否' '④ Fargate は CPU を上限 (クォータ) ではなく CPU シェア (取り分の比率) で配分するため、JVM は cgroup から CPU の上限を読めず、タスクの VM の CPU 数をそのまま使います (JDK 19 以降と、17.0.5・11.0.17 以降の更新版は CPU シェアを CPU 数の計算に使いません: JDK-8281181。元に戻すオプション UseContainerCpuShares も JDK 21 では削除済み)。JVM が CPU を多く見積もると、GC・JIT・Undertow のスレッドが取り分に対して多すぎて CPU を奪い合います。perf-metrics.sh はタスク定義 (ECS タスクメタデータ v4) から取り分を求め、JVM が認識した CPU 数と比べて判定しています。' @(42, 18, 12, 12, 12, 12, 70) $secCpu $T4 'landscape' $false) }
                'meta' { Add-TextEntry $zip $ent (Write-MetaSheet $idx $meta $dir) }
                'legend' { Add-TextEntry $zip $ent (Write-LegendSheet $idx) }
            }
        }
        Add-TextEntry $zip 'xl/styles.xml' ($StylesXml.Replace("`r`n", "`n").TrimEnd("`n") + "`n")
        $sorted = @($DefNames.ToArray())
        [Array]::Sort($sorted, [Comparison[object]] { param($p, $q) $c = [string]::CompareOrdinal([string]$p[1], [string]$q[1]); if ($c -ne 0) { return $c }; return ([int]$p[0]).CompareTo([int]$q[0]) })
        $wb = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' + "`n" + '<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">'
        $wb += '<workbookPr/><bookViews><workbookView xWindow="0" yWindow="0" windowWidth="28800" windowHeight="15600" tabRatio="900" activeTab="0"/></bookViews><sheets>'
        for ($i = 0; $i -lt $Book.Count; $i++) { $wb += '<sheet name="' + (X $Book[$i].Name) + '" sheetId="' + ($i + 1) + '" r:id="rId' + ($i + 1) + '"/>' }
        $wb += '</sheets>'
        if ($sorted.Count -gt 0) {
            $wb += '<definedNames>'
            foreach ($dn in $sorted) {
                if ($dn[1] -eq '_xlnm._FilterDatabase') { $wb += '<definedName name="' + $dn[1] + '" localSheetId="' + $dn[0] + '" hidden="1">' + (X $dn[2]) + '</definedName>' }
                else { $wb += '<definedName name="' + $dn[1] + '" localSheetId="' + $dn[0] + '">' + (X $dn[2]) + '</definedName>' }
            }
            $wb += '</definedNames>'
        }
        $wb += '<calcPr calcId="191029"/></workbook>'
        Add-TextEntry $zip 'xl/workbook.xml' $wb
        $rels = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' + "`n" + '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
        for ($i = 0; $i -lt $Book.Count; $i++) { $rels += '<Relationship Id="rId' + ($i + 1) + '" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet' + ($i + 1) + '.xml"/>' }
        $rels += '<Relationship Id="rId' + ($Book.Count + 1) + '" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/></Relationships>'
        Add-TextEntry $zip 'xl/_rels/workbook.xml.rels' $rels
        $cgct = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' + "`n" + '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
        $cgct += '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/>'
        $cgct += '<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>'
        for ($i = 1; $i -le $Book.Count; $i++) { $cgct += '<Override PartName="/xl/worksheets/sheet' + $i + '.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>' }
        $cgct += '<Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>'
        if ($nChart -gt 0) {
            $cgct += '<Override PartName="/xl/drawings/drawing1.xml" ContentType="application/vnd.openxmlformats-officedocument.drawing+xml"/>'
            for ($i = 1; $i -le $nChart; $i++) { $cgct += '<Override PartName="/xl/charts/chart' + $i + '.xml" ContentType="application/vnd.openxmlformats-officedocument.drawingml.chart+xml"/>' }
        }
        $cgct += '<Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/>'
        $cgct += '<Override PartName="/docProps/app.xml" ContentType="application/vnd.openxmlformats-officedocument.extended-properties+xml"/></Types>'
        Add-TextEntry $zip '[Content_Types].xml' $cgct
        Add-TextEntry $zip '_rels/.rels' ('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' + "`n" + '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/><Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/><Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/extended-properties" Target="docProps/app.xml"/></Relationships>')
        $w3c = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ', $Inv)
        Add-TextEntry $zip 'docProps/core.xml' ('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' + "`n" + '<cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:dcterms="http://purl.org/dc/terms/" xmlns:dcmitype="http://purl.org/dc/dcmitype/" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"><dc:title>' + (X $repTitle) + '</dc:title><dc:subject>' + (X $who.LogId) + '</dc:subject><dc:creator>New-PerfMetricsReport.ps1</dc:creator><cp:lastModifiedBy>New-PerfMetricsReport.ps1</cp:lastModifiedBy><dcterms:created xsi:type="dcterms:W3CDTF">' + $w3c + '</dcterms:created><dcterms:modified xsi:type="dcterms:W3CDTF">' + $w3c + '</dcterms:modified></cp:coreProperties>')
        Add-TextEntry $zip 'docProps/app.xml' ('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' + "`n" + '<Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/extended-properties" xmlns:vt="http://schemas.openxmlformats.org/officeDocument/2006/docPropsVTypes"><Application>New-PerfMetricsReport.ps1 ' + $Version + '</Application></Properties>')
    } catch {
        $zip.Dispose(); $fs.Dispose()
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        throw
    }
    $zip.Dispose(); $fs.Dispose()
    Move-Item -LiteralPath $tmp -Destination $outPath -Force
    Write-Info ("作成しました: {0} （シート {1}、グラフ {2}、{3:N1} 秒）" -f $outPath, $Book.Count, $nChart, $sw.Elapsed.TotalSeconds)
    $script:Created.Add($outPath)
}

#------------------------------------------------------------------------------
# 収集情報シート (perf_meta.csv と jvm_info.txt)
#------------------------------------------------------------------------------
$MetaLabel = @{
    'perf.version' = 'perf-metrics.sh の版'; 'perf.start_time' = '収集開始 (コンテナの時刻)'; 'perf.start_epoch' = '収集開始 (UNIX 秒)'
    'perf.utc_offset' = 'コンテナの UTC オフセット'; 'perf.output_dir' = '出力先'; 'perf.work_dir' = '作業ディレクトリ'; 'perf.collectors' = '動かした収集'
    'perf.cli_interval' = '① jboss-cli の間隔 (秒)'; 'perf.jstat_interval' = '② jstat の間隔 (秒)'; 'perf.jcmd_interval' = '② jcmd の間隔 (秒)'
    'perf.jfr_interval' = '② JFR の統計イベントの間隔 (秒)'; 'perf.top_interval' = '③ top の間隔 (秒)'; 'perf.ps_interval' = '③ ps の間隔 (秒)'; 'perf.proc_interval' = '③④ /proc の間隔 (秒)'
    'perf.jfr_mode' = 'JFR の記録方法'; 'perf.jfr_note' = 'JFR の記録'; 'perf.nmt' = 'Native Memory Tracking'; 'perf.threaddump' = 'スレッドダンプ'
    'perf.top_threads' = '③ top -H の件数'; 'perf.statistics_opts' = '統計の有効化 (起動引数)'; 'perf.prepend_java_opts' = 'JVM オプション (PREPEND_JAVA_OPTS)'
    'container.hostname' = 'ホスト名'; 'container.service_name' = 'サービス名'; 'container.component_name' = 'コンポーネント名'; 'container.component_role' = 'コンポーネントの役割'
    'container.log_id' = 'LOG_ID (タスク専用ディレクトリ)'; 'container.jboss_home' = 'JBOSS_HOME'; 'container.cpus_online' = 'CPU 数 (OS)'; 'container.mem_total_kb' = 'メモリ (KB、OS)'
    'container.os' = 'OS'; 'container.command' = '起動コマンド'
    'os.top_source' = '③ top の取得方法'; 'os.ps_source' = '③ ps の取得方法'; 'os.proc_sources' = '④ cgroup の CPU 統計・PSI'
    'jvm.jcmd_command' = 'jcmd'; 'jvm.jstat_command' = 'jstat の起動方法'; 'jvm.jstat_option' = 'jstat のオプション'; 'jvm.version' = 'JVM の版'; 'jvm.pid' = 'JBoss の PID'
    'jfr.state' = 'JFR の状態'; 'cli.controller' = 'jboss-cli の接続先'; 'cli.ds_stats_enabled_at_runtime' = 'プール統計を実行時に有効化した時刻'
}
$MetaCat = [ordered]@{ perf = '収集条件'; container = 'コンテナ'; ecs = 'ECS'; os = 'OS'; jvm = 'JVM'; jfr = 'JFR'; jboss = 'JBoss'; cli = 'jboss-cli' }
function Write-MetaSheet([int]$sheetIdx, $meta, [string]$dir) {
    $widths = @(14, 34, 100, 30)
    $secs = New-Object System.Collections.Generic.List[object]
    $sec = New-Sec 'perf_meta.csv' '収集開始時の環境・条件と、jboss-cli・jstat・jcmd の接続先・起動方法、ECS タスクメタデータ v4 の値です。パスワードは perf-metrics.sh が ******** に置き換えています。' @('分類', '項目', '値', 'キー') @('key', 'text', 'wrap', 'muted')
    $keys = @($meta.Keys)
    foreach ($cat in @($MetaCat.Keys) + @($keys | ForEach-Object { $_.Split('.')[0] } | Select-Object -Unique)) {
        foreach ($k in $keys) {
            if ($k.Split('.')[0] -ne $cat) { continue }
            $cl = $MetaCat[$cat]; if ($null -eq $cl) { $cl = $cat }
            $lb = $MetaLabel[$k]; if ($null -eq $lb) { $lb = $k.Substring($cat.Length + 1) }
            Sec-Add $sec @($cl, $lb, ([string]$meta[$k]), $k)
        }
        $keys = @($keys | Where-Object { $_.Split('.')[0] -ne $cat })
    }
    $secs.Add($sec)
    $jp = Join-Path $dir 'jvm_info.txt'
    if (Test-Path -LiteralPath $jp) {
        $sec = New-Sec 'jvm_info.txt' 'JVM の起動後に jcmd で取得した版・起動引数・フラグ (VM.version・VM.command_line・VM.flags など)。' @() @('muted', 'text', 'wrap+1')
        $n = 0
        foreach ($l in [IO.File]::ReadAllLines($jp, $Utf8)) {
            $n++; if ($n -gt 2000) { break }
            if ($l.StartsWith('# ')) { Sec-Add $sec @([string]$n, (V2 $l.Substring(2) 'bold'), $null) } else { Sec-Add $sec @([string]$n, $null, $l) }
        }
        $secs.Add($sec)
    }
    return Write-SectionsSheet $sheetIdx '収集情報' '収集情報' '' $widths $secs $T0 'landscape' $false
}
function V2([object]$v, [string]$f) { return @{ V = $v; F = $f } }

#------------------------------------------------------------------------------
# 凡例シート
#------------------------------------------------------------------------------
$LegendText = @'
H|このブックの見方
P|・時刻は既定で、レポートを作成した PC のタイムゾーンで表示しています (-UseRecordedTime を付けるとコンテナで記録した時刻)。JMeter の結果 (JTL) と突き合わせるときは同じタイムゾーンで比べてください。-From / -To で JMeter の実行時間帯に絞れます。
P|・シート名の ① ～ ④ は収集の区分です。① jboss-cli (JBoss の統計)、② jstat・jcmd・JFR (JVM)、③ top・ps・/proc (OS から見たプロセス・スレッド)、④ CPU 数の判定 (-XX:ActiveProcessorCount)。
P|・各データシートは 4 行目が分類、5 行目が見出し、6 行目が元の CSV の列名です。6 行目にオートフィルターがあります。グラフは「グラフ」シートにまとめ、時間軸を全グラフで揃えています。
P|・「区間」は前回の取得からの増分です。累計カウンタが減った場合 (サーバーの再起動・統計のクリア) は、その回の値をそのまま増分として扱います。「毎秒」は区間の増分 ÷ 経過秒です。
P|・95% 値は、期間中の取得値を小さい順に並べたときに 95% の位置にある値です (ときどき起きる最大値に引きずられない「ほぼ最大」)。
B|
H|シートの一覧
TH|シート|内容|元のファイル
T|サマリー|所見 (要対応・注意・参考)、④ の判定、主要指標 (最大・95% 値・平均・最小)、データソース別・リスナー別の表、収集情報の抜粋|すべて
T|グラフ|①～④ の時系列グラフ (時間軸は共通)|各シート
T|①DB接続プール|データソース別の接続数・使用率・待ち・取得失敗・取得時間・XA|cli_datasource.csv
T|①HTTP / ①セッション|リスナー別のリクエスト数・エラー・処理時間 / デプロイメント別のセッション数|cli_undertow.csv / cli_session.csv
T|①スレッドプール / ①IOワーカー|EE・EJB のスレッドプール / HTTP を処理する IO ワーカーのスレッド・キュー・接続数|cli_threadpool.csv / cli_io_worker.csv
T|①トランザクション / ①JVM（CLI）|コミット・中断・タイムアウト / スレッド・クラス・ヒープ・NIO バッファ・サーバーの状態・処理中のリクエスト|cli_transactions.csv / cli_jvm.csv
T|②ヒープ・GC（jstat）|ヒープ・メタスペース・GC の回数と時間・GC の原因・セーフポイント・JIT|jvm_jstat_gc.csv
T|②ヒープ（jcmd） / ②コードキャッシュ / ②NMT|G1 のリージョン・メタスペースの詳細 / JIT のコードの置き場 / JVM のネイティブメモリ (PERF_NMT=summary のとき)|jvm_jcmd_heap.csv / jvm_codecache.csv / jvm_nmt.csv
T|②スレッド状態|Java スレッドの状態 (実行可能・ブロック・待機) を用途別に数えたもの、DB 接続待ちのスレッド|jvm_thread_states.csv
T|②GC（JFR） / ②JVM統計（JFR）|GC ごとの停止時間・原因・ヒープ / JVM の CPU・例外・スレッド・クラス・コードキャッシュ・RSS|jfr_gc.csv / jfr_stats.csv
T|②JFR上位 / ②JFR記録|CPU を使ったメソッド・ロック待ち・I/O・VM の操作の上位 / 記録ファイル・JVM の情報・イベント件数|jfr_hot_methods.csv など / jfr_env.csv・jfr_summary.csv
T|③top概要 / ③topプロセス / ③topスレッド / ③ps|ロードアベレージ・CPU の内訳・プロセス別 CPU / プロセス一覧 / JBoss の CPU が高いスレッド / ps のプロセス一覧|os_top_*.csv / os_ps.csv
T|③JBossスレッド / ③FD・TCP|JBoss のスレッドの用途別 CPU・スレッド数・状態 / ファイル記述子・TCP の状態・RSS|os_jboss_threads.csv / os_jboss_proc.csv
T|④CPU判定 / ④CPUスケジューリング|-XX:ActiveProcessorCount の要否と根拠 / JBoss の CPU 使用量と取り分・実行待ち・steal・PSI・スロットリング|cpu_env.csv / cpu_sched.csv
T|収集ログ / 収集情報|perf-metrics.sh の動作ログ / 収集の条件・環境 (perf_meta.csv・jvm_info.txt)|collector.log / perf_meta.csv
B|
H|所見の判定
TH|重要度|内容|判定基準
T|■ 要対応|接続の取得失敗・Full GC・GC の 1 回の停止 1 秒以上・コードキャッシュの満杯・トランザクションのタイムアウト・ヒューリスティック・セッション / タスクの拒否・ファイル記述子 80% 以上・ActiveProcessorCount「要」|期間中に 1 回以上
T|▲ 注意|接続待ち・プールの上限到達・DB 接続待ちのスレッド・Old 領域が最大ヒープの 85% 以上 (G1 以外で最大ヒープが分からないときは OU÷OC)・GC 直後のヒープが最大ヒープの 85% 以上 (95% 値)・GC 時間率 5% 以上・GC の停止 200 ms 以上・System.gc()・スレッドプール / IO ワーカーの上限到達・キュー・500 エラー・トランザクションの中断・CLOSE_WAIT・jboss-cli の応答なし・CPU の steal 10% 以上 / 実行待ち・PSI 20% 以上・スロットリング・GC が CPU の 20% 以上・ActiveProcessorCount「要検討」|期間中に 1 回以上 (steal・実行待ち・PSI は 95% 値)
T|● 参考|接続プール使用率 80% 以上 (待ちなし)・統計が無効・Humongous / メタスペースによる GC・ロック競合・例外が毎秒 100 件以上・新しいセッションの作りすぎ・TIME_WAIT 1000 以上・ディスク I/O 待ち・ネイティブメモリの増加・取り分を超える CPU 使用・収集の負荷・収集ログの WARN|－
B|
H|Container Insights（拡張）との分担
P|・CloudWatch Container Insights (拡張された可観測性) で確認できる、タスク・コンテナの CPU 使用率 / 使用量・メモリ使用量・ネットワークの送受信量・ストレージの読み書き量・再起動回数などは、このブックでは扱いません (perf-metrics.sh も取得しません)。Undertow の送受信バイト数もネットワーク転送量と重なるため取得していません。
P|・このブックは、Container Insights では見えない「JBoss の中 (接続プール・スレッド・トランザクション)」「JVM の中 (ヒープ・GC・JIT・ロック)」「プロセス・スレッドの用途別の CPU と待ち」「JVM が前提にしている CPU 数」を扱います。③ の top の CPU の内訳・メモリは、プロセス別の値と比べるための参考です。
B|
H|注意事項
P|・収集用の jboss-cli・jstat・jcmd・/proc の読み取りも同じコンテナの CPU・メモリを使います (「③top概要」の収集処理の列・サマリーの「収集の負荷」)。本番と比べる試験では、収集の有無で条件を揃えてください。
P|・-Dwildfly.datasources / undertow / transactions.statistics-enabled=true (統計の有効化) と JFR (既定の設定で 1～2% 程度) のわずかな負荷があります。PERF_NMT=summary は 5～10% 程度の負荷とメモリの増加があります。
P|・jstat・jcmd は /tmp が書き込めないと JVM を見つけられません (readonlyRootFilesystem=true のときは /tmp にボリュームが必要。コンテナごとに別のボリュームにしてください)。
P|・「②JFR上位」「②JFR記録」は JFR の記録全体の集計で、-From / -To は反映されません。詳しい分析は .jfr を JDK Mission Control で開いてください。
P|・グラフはモノトーンのため、線の種類 (実線・破線・点線・長破線・一点鎖線) で系列を区別しています。
'@
function Write-LegendSheet([int]$sheetIdx) {
    $widths = @(34, 72, 48)
    $secs = New-Object System.Collections.Generic.List[object]
    $sec = $null
    foreach ($ln in ($LegendText -split "`r?`n")) {
        if ($ln -eq '') { continue }
        $a = $ln.Split('|')
        switch ($a[0]) {
            'H' { if ($null -ne $sec) { $secs.Add($sec) }; $sec = New-Sec $a[1] '' @() @('note+') }
            'TH' {
                if ($sec.Rows.Count -eq 0) { $sec.Head = @($a[1], $a[2], $a[3]); $sec.Fmt = @('bold', 'wrap', 'wrap') }
                else { $secs.Add($sec); $sec = New-Sec '' '' @($a[1], $a[2], $a[3]) @('bold', 'wrap', 'wrap') }
            }
            'T' { Sec-Add $sec @($a[1], $a[2], $a[3]) }
            'P' { if ($sec.Fmt.Count -ne 1) { $secs.Add($sec); $sec = New-Sec '' '' @() @('note+') }; Sec-Add $sec @($a[1]) }
            'B' { }
        }
    }
    if ($null -ne $sec) { $secs.Add($sec) }
    return Write-SectionsSheet $sheetIdx '凡例' '凡例・用語の説明' '' $widths $secs $T0 'landscape' $false
}

#------------------------------------------------------------------------------
# メイン
#------------------------------------------------------------------------------
$script:Created = New-Object System.Collections.Generic.List[string]
try {
    $dirs = Resolve-PerfDirs $InputPath
    # mid/ ごとコピーすると current (最後に起動したタスクへのリンク) 経由で同じ perf/ が
    # 2 回見つかるため、同じコンテナ・サービス・LOG_ID のものは 1 回だけ処理する (current を通らないパスを優先)
    $dirs = @($dirs | Sort-Object -Property @{ Expression = { $_ -match '[\\/]current[\\/]' } }, @{ Expression = { $_ } })
    $todo = New-Object System.Collections.Generic.List[object]; $seen = @{}
    foreach ($d in $dirs) {
        $who = Get-Who (Read-Meta $d) $d
        if ($seen.ContainsKey($who.Key)) { Write-Info "同じタスクの perf/ が重複しているため省略します: $d"; continue }
        $seen[$who.Key] = 1; $todo.Add(@($d, $who))
    }
    $multi = ($todo.Count -gt 1)
    if ($multi) { Write-Info ("perf/ ディレクトリが {0} 個見つかりました。1 つずつブックを作成します" -f $todo.Count) }
    foreach ($item in $todo) {
        $d = $item[0]; $who = $item[1]
        # -OutputPath が .xlsx で終わるとき (perf/ が 1 つ) だけファイル名、それ以外はディレクトリとして扱う
        if ($OutputPath -eq '') { $out = Join-Path (Get-Location).ProviderPath $who.FileName }
        elseif ($multi -or -not $OutputPath.EndsWith('.xlsx', [StringComparison]::OrdinalIgnoreCase)) { $out = Join-Path $OutputPath $who.FileName }
        else { $out = $OutputPath }
        if (-not [IO.Path]::IsPathRooted($out)) { $out = Join-Path (Get-Location).ProviderPath $out }
        $od = Split-Path -Parent $out
        if (-not (Test-Path -LiteralPath $od -PathType Container)) { New-Item -ItemType Directory -Path $od -Force | Out-Null }
        if ($who.Label -ne '') { Write-Info ("対象: {0}  (LOG_ID {1}、{2})" -f $who.Label, $who.LogId, $(if ($who.From -ne '') { $who.From } else { 'perf_meta.csv' })) }
        Build-Report $d $out $who
    }
} finally {
    foreach ($t in $TempDirs) { Remove-Item -LiteralPath $t -Recurse -Force -ErrorAction SilentlyContinue }
}
if ($Open) { foreach ($c in $script:Created) { Invoke-Item -LiteralPath $c } }
PERFRPT-MAIN#>
