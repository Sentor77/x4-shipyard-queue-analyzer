<#
.SYNOPSIS
    Analysiert X4 Foundations Savegames auf fehlende Werft-Ressourcen pro Spieler-Werft.
.DESCRIPTION
    Liest zeilenweise (Streaming) .xml oder .xml.gz Savegames aus und listet
    blockierte Bauteile in den Bauschlangen aller eigenen Werften auf.
#>

[CmdletBinding()]
param (
    [string]$SavePath = ""
)

# 1. Pfad ermitteln (Default: Standard-Dokumenten-Ordner von Egosoft)
if ([string]::IsNullOrWhiteSpace($SavePath)) {
    $defaultPath = Join-Path -Path ([System.Environment]::GetFolderPath('MyDocuments')) -ChildPath "Egosoft\X4"
    
    Write-Host "=== X4 Savegame Analyzer ===" -ForegroundColor Cyan
    Write-Host "Standardpfad: $defaultPath" -ForegroundColor Gray
    $userInput = Read-Host "Pfad anpassen (Enter fuer Standardpfad)"
    
    if ([string]::IsNullOrWhiteSpace($userInput)) {
        $SavePath = $defaultPath
    } else {
        $SavePath = $userInput.Trim('"') # Entfernt evtl. Anfuehrungszeichen bei Drag&Drop
    }
}

# 2. Prüfen, ob der Pfad existiert und Savegames enthält
if (-not (Test-Path $SavePath)) {
    Write-Host "`n[FEHLER] Der angegebene Pfad wurde nicht gefunden:" -ForegroundColor Red
    Write-Host "'$SavePath'" -ForegroundColor Yellow
    Write-Host "Bitte ueberpruefe den Pfad und starte das Skript erneut." -ForegroundColor Red
    return
}

# Suche nach .xml und .xml.gz Dateien
$saveFiles = Get-ChildItem -Path $SavePath -Recurse -Include *.xml, *.xml.gz -ErrorAction SilentlyContinue | 
             Sort-Object LastWriteTime -Descending

if ($saveFiles.Count -eq 0) {
    Write-Host "`n[HINWEIS] Keine Savegame-Dateien (.xml oder .xml.gz) gefunden in:" -ForegroundColor Red
    Write-Host "'$SavePath'" -ForegroundColor Yellow
    Write-Host "Stelle sicher, dass im Ordner (oder dessen Unterordnern) Savegames liegen." -ForegroundColor Gray
    return
}

# 3. Auswahlliste anzeigen
Write-Host ""
Write-Host "=== Verfuegbare Savegames ===" -ForegroundColor Cyan
for ($i = 0; $i -lt $saveFiles.Count; $i++) {
    $file = $saveFiles[$i]
    $sizeMB = [math]::Round($file.Length / 1MB, 2)
    Write-Host "[$($i + 1)] $($file.Name) ($sizeMB MB) - Letzte Aenderung: $($file.LastWriteTime)"
}

$selection = Read-Host "`nBitte waehle ein Savegame aus (1-$($saveFiles.Count))"
$selectedIndex = [int]$selection - 1

if ($selectedIndex -lt 0 -or $selectedIndex -ge $saveFiles.Count) {
    Write-Host "Ungueltige Auswahl!" -ForegroundColor Red
    return
}

$targetFile = $saveFiles[$selectedIndex]
Write-Host ""
Write-Host "Analysiere Werft-Bauschlangen in '$($targetFile.Name)'..." -ForegroundColor Green

# 4. Stream-Reader einrichten (unterstuetzt .xml und .xml.gz)
$fileStream = [System.IO.File]::OpenRead($targetFile.FullName)
if ($targetFile.Extension -eq '.gz') {
    $gzipStream = New-Object System.IO.Compression.GZipStream($fileStream, [System.IO.Compression.CompressionMode]::Decompress)
    $reader = New-Object System.IO.StreamReader($gzipStream)
} else {
    $reader = New-Object System.IO.StreamReader($fileStream)
}

# Speicherstruktur: Dictionary mit [StationName] = HashSet[Waren]
$shipyardResults = [System.Collections.Generic.Dictionary[string, System.Collections.Generic.HashSet[string]]]::new()

$inShipyard = $false
$inBuildtasks = $false
$currentStationName = ""
$currentWares = $null

# Such-Tags
$tagStation = "class=" + [char]34 + "station" + [char]34
$tagPlayer = "owner=" + [char]34 + "player" + [char]34
$tagShipyard1 = "Shipyard"
$tagShipyard2 = "shipyard"
$tagNameKey = "name=" + [char]34
$tagBuildOpen = [char]60 + "buildtasks" + [char]62
$tagBuildClose = [char]60 + "/buildtasks" + [char]62
$tagStationClose = [char]60 + "/component" + [char]62
$tagWareKey = "ware=" + [char]34

# 5. Datei zeilenweise parsen
try {
    while (($line = $reader.ReadLine()) -ne $null) {
        # Prüft auf Station + Player-Besitz + Werft-Klasse
        if ($line.Contains($tagStation) -and $line.Contains($tagPlayer) -and ($line.Contains($tagShipyard1) -or $line.Contains($tagShipyard2))) {
            $inShipyard = $true
            
            # Stationsnamen extrahieren
            if ($line.Contains($tagNameKey)) {
                $idxName = $line.IndexOf($tagNameKey)
                $startName = $idxName + $tagNameKey.Length
                $endName = $line.IndexOf([char]34, $startName)
                if ($endName -gt $startName) {
                    $currentStationName = $line.Substring($startName, $endName - $startName)
                }
            } else {
                $currentStationName = "Unbenannte Spieler-Werft"
            }

            # Eigenes Ware-Set für diese spezifische Werft anlegen
            if (-not $shipyardResults.ContainsKey($currentStationName)) {
                $shipyardResults[$currentStationName] = New-Object System.Collections.Generic.HashSet[string]
            }
            $currentWares = $shipyardResults[$currentStationName]
        }

        if ($inShipyard) {
            if ($line.Contains($tagBuildOpen)) {
                $inBuildtasks = $true
            }

            if ($inBuildtasks) {
                if ($line.Contains($tagWareKey)) {
                    $idx = $line.IndexOf($tagWareKey)
                    if ($idx -ge 0) {
                        $start = $idx + $tagWareKey.Length
                        $end = $line.IndexOf([char]34, $start)
                        if ($end -gt $start) {
                            $ware = $line.Substring($start, $end - $start)
                            $null = $currentWares.Add($ware)
                        }
                    }
                }

                if ($line.Contains($tagBuildClose)) {
                    $inBuildtasks = $false
                }
            }

            # Beendet das Auslesen dieser spezifischen Werft, wenn das Tag schließt
            if ($line.Contains($tagStationClose) -and -not $inBuildtasks) {
                $inShipyard = $false
                $currentStationName = ""
                $currentWares = $null
            }
        }
    }
}
finally {
    $reader.Close()
    if ($gzipStream) { $gzipStream.Close() }
    $fileStream.Close()
}

# 6. Ergebnis strukturiert nach Werften ausgeben
Write-Host ""
Write-Host "=== ANALYSE-ERGEBNIS PRO WERFT ===" -ForegroundColor Cyan

if ($shipyardResults.Count -eq 0) {
    Write-Host "Keine Spieler-Werften im Savegame gefunden!" -ForegroundColor Yellow
} else {
    foreach ($station in $shipyardResults.Keys) {
        Write-Host ""
        Write-Host "------------------------------------------" -ForegroundColor DarkGray
        Write-Host " WERFT: $station" -ForegroundColor Yellow
        Write-Host "------------------------------------------" -ForegroundColor DarkGray
        
        $wares = $shipyardResults[$station]
        if ($wares.Count -gt 0) {
            Write-Host " Fehlende Waren in der Bauschlange:" -ForegroundColor Red
            foreach ($ware in $wares) {
                Write-Host "  - $ware" -ForegroundColor Red
            }
        } else {
            Write-Host " Keine blockierten Bauauftraege." -ForegroundColor Green
        }
    }
}