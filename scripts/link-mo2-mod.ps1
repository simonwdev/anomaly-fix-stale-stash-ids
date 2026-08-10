# Creates (or removes) a junction that exposes this repo as an MO2 mod, so the
# working copy is playable in-game without copying files. A junction (not a
# symlink) because it needs no admin rights / Developer Mode and MO2's VFS
# follows it transparently.
#
#   .\scripts\link-mo2-mod.ps1 -ModsDir "<MO2 profile>\mods"
#   .\scripts\link-mo2-mod.ps1 -ModsDir "<MO2 profile>\mods" -Remove
[CmdletBinding()]
param(
    # MO2 mods folder to link into
    [Parameter(Mandatory)]
    [string]$ModsDir,

    # Remove the junction instead of creating it
    [switch]$Remove,

    # Mod folder name as it appears in MO2. Defaults to the repo folder name so
    # the link is obviously a dev checkout rather than an installed copy.
    [string]$Name = "[DEBUG] $(Split-Path (Split-Path $PSScriptRoot -Parent) -Leaf)"
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path -LiteralPath $ModsDir -PathType Container)) {
    throw "Mods folder not found: $ModsDir"
}

# The script lives in scripts\; the mod root is the repo root one level up.
$target = Split-Path $PSScriptRoot -Parent
$link   = Join-Path $ModsDir $Name

if ($Remove) {
    if (-not (Test-Path -LiteralPath $link)) {
        Write-Host "Nothing to remove: $link does not exist."
        return
    }
    $item = Get-Item -LiteralPath $link -Force
    # Only ever delete a reparse point: a real directory here is an installed
    # copy of the mod, and deleting it would destroy files.
    if (-not ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw "$link is a real directory, not a junction - refusing to delete it."
    }
    # Deletes the junction itself; the target's contents are untouched.
    $item.Delete()
    Write-Host "Removed junction: $link"
    return
}

# Junction targets come back in whatever form the filesystem stored them, so
# normalise both sides before comparing. A trailing separator alone would
# otherwise make the script refuse a link it created itself.
function Get-ComparablePath([string]$p) {
    if (-not $p) { return "" }
    return $p.TrimEnd('\', '/')
}

if (Test-Path -LiteralPath $link) {
    $item = Get-Item -LiteralPath $link -Force
    # .Target is a string in PS 7 and a string[] in Windows PowerShell 5.1.
    $linkTarget = Get-ComparablePath (@($item.Target) | Select-Object -First 1)
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -and
        $linkTarget -eq (Get-ComparablePath $target)) {
        Write-Host "Already linked: $link -> $target"
        return
    }
    throw "$link already exists and is not a junction to this repo - remove it in MO2 first."
}

New-Item -ItemType Junction -Path $link -Target $target | Out-Null
Write-Host "Created junction: $link -> $target"
Write-Host "Refresh MO2 (F5) and enable '$Name' in the left pane."
