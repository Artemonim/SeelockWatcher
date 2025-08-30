#requires -Version 5.1

<#
* Builds a clean ZIP archive suitable for GitHub Releases.
* Excludes local config, outputs, temp files, IDE metadata.
#>

[CmdletBinding()]
param(
    # * Output folder for artifacts
    [string]$ArtifactsDir = "$PSScriptRoot/../dist",

    # * Archive file name without extension
    [string]$ArchiveName = "SeelockWatcher",

    # * Optional version tag, e.g., v1.0.0. If empty, date-based suffix is used
    [string]$Version = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-ProjectRoot { (Resolve-Path -LiteralPath (Join-Path -Path $PSScriptRoot -ChildPath '..')).ProviderPath }

try {
    $root = Get-ProjectRoot
    if (-not (Test-Path -LiteralPath $ArtifactsDir)) { New-Item -ItemType Directory -Path $ArtifactsDir | Out-Null }

    $stamp = if ([string]::IsNullOrWhiteSpace($Version)) { (Get-Date -Format 'yyyyMMdd-HHmmss') } else { $Version }
    $tempDir = Join-Path -Path $ArtifactsDir -ChildPath ("build-" + $stamp)
    if (Test-Path -LiteralPath $tempDir) { Remove-Item -Recurse -Force -LiteralPath $tempDir }
    New-Item -ItemType Directory -Path $tempDir | Out-Null

    # * Copy allowlist
    $include = @(
        'Readme.md',
        'Config.ini.example',
        'Create-Shortcut.bat',
        'sync.ps1',
        'scripts/Connect-Seelock.ps1',
        'scripts/Convert-SeelockVideos.ps1',
        'scripts/Strings.ps1',
        'Language.ini',
        'LICENSE'
    )

    foreach ($rel in $include) {
        $src = Join-Path -Path $root -ChildPath $rel
        if (Test-Path -LiteralPath $src) {
            $dst = Join-Path -Path $tempDir -ChildPath $rel
            $dstDir = Split-Path -Path $dst -Parent
            if (-not (Test-Path -LiteralPath $dstDir)) { New-Item -ItemType Directory -Path $dstDir | Out-Null }
            Copy-Item -LiteralPath $src -Destination $dst -Recurse -Force
        }
    }

    # * Create zip
    $zipPath = Join-Path -Path $ArtifactsDir -ChildPath ("$ArchiveName-$stamp.zip")
    if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath -Force }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [System.IO.Compression.ZipFile]::CreateFromDirectory($tempDir, $zipPath)

    Write-Host ("Artifact created: {0}" -f $zipPath)
    exit 0
} catch {
    Write-Error ("Build failed: {0}" -f $_)
    exit 1
} finally {
    # * Clean temp build dir
    try { if ($tempDir -and (Test-Path -LiteralPath $tempDir)) { Remove-Item -Recurse -Force -LiteralPath $tempDir } } catch { }
}




