<#
.SYNOPSIS
    Analyzes X4 Foundations savegames for missing shipyard resources per player shipyard.
.DESCRIPTION
    Reads line-by-line (streaming) .xml or .xml.gz savegames with UTF-8 encoding.
    Extracts missing components in active build queues, ignores deleted tasks,
    maps them to respective ships (extracted from macro/component), and cross-checks against the station's buy list.
#>

[CmdletBinding()]
param (
    [string]$SavePath = ""
)

# Helper function to read attributes reliably (space prefix avoids matching "basename" when searching "name")
function Get-Attr([string]$Line, [string]$Name) {
    $key = " $Name=" + [char]34
    $i = $Line.IndexOf($key)
    if ($i -lt 0) { return $null }
    $i += $key.Length
    $end = $Line.IndexOf([char]34, $i)
    if ($end -lt $i) { return $null }
    return $Line.Substring($i, $end - $i)
}

# 1. Determine Path (Default: Standard Egosoft Documents Path)
if ([string]::IsNullOrWhiteSpace($SavePath)) {
    $defaultPath = Join-Path -Path ([System.Environment]::GetFolderPath('MyDocuments')) -ChildPath "Egosoft\X4"

    Write-Host "=== X4 Savegame Shipyard Analyzer ===" -ForegroundColor Cyan
    Write-Host "Default path: $defaultPath" -ForegroundColor Gray
    $userInput = Read-Host "Custom path (Press Enter for default)"

    if ([string]::IsNullOrWhiteSpace($userInput)) {
        $SavePath = $defaultPath
    } else {
        $SavePath = $userInput.Trim('"') # Remove drag & drop quotes
    }
}

# 2. Check if path exists and filter for genuine X4 savegame files
if (-not (Test-Path $SavePath)) {
    Write-Host "`n[ERROR] The specified path was not found:" -ForegroundColor Red
    Write-Host "'$SavePath'" -ForegroundColor Yellow
    Write-Host "Please check the path and run the script again." -ForegroundColor Red
    return
}

$resolvedRoot = (Resolve-Path $SavePath).Path.TrimEnd('\', '/')
$saveFiles = @(Get-ChildItem -Path $SavePath -Recurse -File -Include save_*.xml, save_*.xml.gz, autosave_*.xml, autosave_*.xml.gz, quicksave.xml, quicksave.xml.gz -ErrorAction SilentlyContinue |
             Where-Object { $_.Directory.Name -ieq 'save' -or $_.DirectoryName.TrimEnd('\', '/') -eq $resolvedRoot } |
             Sort-Object LastWriteTime -Descending)

if ($saveFiles.Count -eq 0) {
    Write-Host "`n[NOTICE] No savegame files (save_*, autosave_*, quicksave .xml/.xml.gz) found in:" -ForegroundColor Red
    Write-Host "'$SavePath'" -ForegroundColor Yellow
    Write-Host "Make sure savegames are located in this directory or subdirectories." -ForegroundColor Gray
    return
}

# 3. Display selection list
Write-Host ""
Write-Host "=== Available Savegames ===" -ForegroundColor Cyan
for ($i = 0; $i -lt $saveFiles.Count; $i++) {
    $file = $saveFiles[$i]
    $sizeMB = [math]::Round($file.Length / 1MB, 2)
    Write-Host "[$($i + 1)] $($file.Name) ($sizeMB MB) - Last Modified: $($file.LastWriteTime)"
}

$selection = Read-Host "`nPlease select a savegame (1-$($saveFiles.Count))"
$selectedIndex = 0
if (-not [int]::TryParse($selection, [ref]$selectedIndex) -or $selectedIndex -lt 1 -or $selectedIndex -gt $saveFiles.Count) {
    Write-Host "Invalid selection!" -ForegroundColor Red
    return
}

$targetFile = $saveFiles[$selectedIndex - 1]
Write-Host ""
Write-Host "Analyzing shipyard build queues in '$($targetFile.Name)'..." -ForegroundColor Green

# 4. Setup Stream-Reader with explicit UTF-8 Encoding
$gzipStream = $null
$fileStream = [System.IO.File]::OpenRead($targetFile.FullName)
$utf8 = [System.Text.Encoding]::UTF8

if ($targetFile.Extension -eq '.gz') {
    $gzipStream = New-Object System.IO.Compression.GZipStream($fileStream, [System.IO.Compression.CompressionMode]::Decompress)
    $reader = New-Object System.IO.StreamReader($gzipStream, $utf8)
} else {
    $reader = New-Object System.IO.StreamReader($fileStream, $utf8)
}

$results = New-Object System.Collections.Generic.List[object]

# <build> entries carry no ship macro, only a component ID that points to a ship
# object elsewhere in the savegame (before OR after the station). So we collect
# id -> macro for all ships in the same pass and resolve names afterwards.
$shipMacros = New-Object 'System.Collections.Generic.Dictionary[string,string]'

$station      = $null   # Current player station
$depth        = 0       # Component nesting depth inside the station
$inBuildtasks = $false
$inQueue      = $false  # Only <queue> counts, <removed> (deleted tasks) is ignored
$inInsuff     = $false
$order        = $null

# 5. Parse file line by line
try {
    while ($null -ne ($line = $reader.ReadLine())) {
        $t = $line.TrimStart()

        if ($t.StartsWith('<component class="ship_')) {
            $sid = Get-Attr $t 'id'
            $smac = Get-Attr $t 'macro'
            if ($sid -and $smac) { $shipMacros[$sid] = $smac }
        }

        if ($null -eq $station) {
            if ($t.StartsWith('<component class="station"') -and $t.Contains(' owner="player"')) {
                $name = Get-Attr $t 'name'
                $code = Get-Attr $t 'code'
                if ([string]::IsNullOrEmpty($name)) { $name = "Player Station (Unnamed)" }
                $station = [pscustomobject]@{ Name = $name; Code = $code; Buy = @(); Orders = (New-Object System.Collections.Generic.List[object]) }
                $depth = 1
            }
            continue
        }

        # Track nested components (modules, docked ships)
        if ($t.StartsWith('<component ')) {
            if (-not $t.EndsWith('/>')) { $depth++ }
            continue
        }
        if ($t.StartsWith('</component>')) {
            $depth--
            if ($depth -eq 0) {
                if ($station.Orders.Count -gt 0) { $results.Add($station) }
                $station = $null
            }
            continue
        }
        if ($depth -ne 1) { continue }   # Only evaluate station-level tags

        if ($t.StartsWith('<setting name="buy"')) {
            $w = Get-Attr $t 'wares'
            if ($w) { $station.Buy = $w -split ' ' }
        }
        elseif ($t.StartsWith('<buildtasks>'))  { $inBuildtasks = $true }
        elseif ($t.StartsWith('</buildtasks>')) { $inBuildtasks = $false; $inQueue = $false }
        elseif ($inBuildtasks) {
            if     ($t.StartsWith('<queue>'))  { $inQueue = $true }
            elseif ($t.StartsWith('</queue>')) { $inQueue = $false }
            elseif ($inQueue) {
                if ($t.StartsWith('<build ')) {
                    $order = [pscustomobject]@{
                        Faction   = Get-Attr $t 'faction'
                        Type      = Get-Attr $t 'type'
                        Component = Get-Attr $t 'component'
                        ShipName  = ""   # resolved after parsing
                        Missing   = (New-Object System.Collections.Generic.List[string])
                    }
                    $station.Orders.Add($order)
                }
                elseif ($t.StartsWith('</build>'))        { $order = $null; $inInsuff = $false }
                elseif ($t.StartsWith('<insufficient>'))  { $inInsuff = $true }
                elseif ($t.StartsWith('</insufficient>')) { $inInsuff = $false }
                elseif ($inInsuff -and $order -and $t.StartsWith('<ware ')) {
                    $order.Missing.Add((Get-Attr $t 'ware'))
                }
            }
        }
    }
}
finally {
    $reader.Close()
    if ($gzipStream) { $gzipStream.Close() }
    $fileStream.Close()
}

# Resolve readable ship names, e.g. "ship_arg_s_fighter_01_a_macro" -> "ARG s fighter 01 a"
foreach ($s in $results) {
    foreach ($o in $s.Orders) {
        $macro = $null
        if ($o.Component) { $null = $shipMacros.TryGetValue($o.Component, [ref]$macro) }

        if ($macro -and $macro -match '^ship_([a-z]+)_(.+)_macro$') {
            $name = "$($Matches[1].ToUpper()) $($Matches[2] -replace '_', ' ')"
        } else {
            $name = "Unknown ship ($($o.Component))"
        }
        if ($o.Faction) { $name += " for $($o.Faction)" }
        if ($o.Type -and $o.Type -ne 'buildship') { $name += " [$($o.Type)]" }
        $o.ShipName = $name
    }
}

# 6. Format and display results per shipyard and missing ware
Write-Host ""
Write-Host "=== ANALYSIS RESULTS PER SHIPYARD ===" -ForegroundColor Cyan

if ($results.Count -eq 0) {
    Write-Host "No player shipyards with active build orders found." -ForegroundColor Yellow
    return
}

foreach ($s in $results) {
    $label = $s.Name
    if ($s.Code) { $label += " ($($s.Code))" }

    Write-Host ""
    Write-Host "--------------------------------------------------" -ForegroundColor DarkGray
    Write-Host " SHIPYARD: $label" -ForegroundColor Yellow
    Write-Host "--------------------------------------------------" -ForegroundColor DarkGray

    $blocked = @($s.Orders | Where-Object { $_.Missing.Count -gt 0 })
    Write-Host " Total orders in queue: $($s.Orders.Count) | Blocked: $($blocked.Count)"

    if ($blocked.Count -eq 0) {
        Write-Host " No blocked build tasks." -ForegroundColor Green
        continue
    }

    $byWare = $blocked | ForEach-Object { $o = $_; $o.Missing | ForEach-Object { [pscustomobject]@{ Ware = $_; ShipName = $o.ShipName } } } |
              Group-Object Ware | Sort-Object Count -Descending

    Write-Host " Missing Wares:" -ForegroundColor Red
    foreach ($g in $byWare) {
        $ships = ($g.Group | Group-Object ShipName | ForEach-Object { "$($_.Name) x$($_.Count)" }) -join ', '
        $hint = ""
        if ($s.Buy.Count -gt 0 -and $s.Buy -notcontains $g.Name) {
            $hint = "  <-- NOT on station buy list (Missing Blueprint?)"
        }
        Write-Host ("  - {0}: blocks {1} order(s) ({2}){3}" -f $g.Name, $g.Count, $ships, $hint) -ForegroundColor Red
    }
}