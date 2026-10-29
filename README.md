# X4 Shipyard Analyzer

A lightweight PowerShell script that streams X4 Foundations save files (.xml / .xml.gz) and reports which wares are missing to complete queued NPC ship orders - broken down per shipyard and per ship. No in-game diagnostics needed.

## Requirements

- Windows PowerShell 5.1+ (pre-installed on Windows 10/11)
- No additional modules needed

## Usage

    .\x4-shipyard-analyzer.ps1

Or specify a save path directly:

    .\x4-shipyard-analyzer.ps1 -SavePath "C:\MySaves"

## ⚠️ Save First!

The script reads the **save file on disk**, not your live game state.
If you haven't saved, it will show you data from hours ago.
Save your game. Then run the script.

## Output

Shows missing wares per shipyard, grouped by ship.
