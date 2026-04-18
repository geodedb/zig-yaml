#Requires -Version 5.1
# SPDX-License-Identifier: Apache-2.0
# Installs a pinned Zig toolchain under .\zig-<version>\ on Windows.
param(
    [Parameter(Mandatory = $true)]
    [string]$Version
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$arch = switch ($env:PROCESSOR_ARCHITECTURE) {
    "AMD64" { "x86_64" }
    "ARM64" { "aarch64" }
    default { throw "unsupported architecture: $($env:PROCESSOR_ARCHITECTURE)" }
}

$targetKey  = "$arch-windows"
$archive    = "zig-$arch-windows-$Version"
$zipFile    = "$archive.zip"
$installDir = "zig-$Version"

if (Test-Path "$installDir\zig.exe") {
    Write-Host "Zig $Version already present at $installDir"
    exit 0
}

$indexPath = Join-Path $env:TEMP "zig-index.json"
Write-Host "Fetching Zig download index..."
Invoke-WebRequest -Uri "https://ziglang.org/download/index.json" -OutFile $indexPath -UseBasicParsing

$index = Get-Content $indexPath -Raw | ConvertFrom-Json
$versionNode = $index.$Version
if ($null -eq $versionNode) { throw "Zig version $Version not found in index" }
$pkg = $versionNode.$targetKey
if ($null -eq $pkg) { throw "Target $targetKey not published for Zig $Version" }

$tarballUrl = $pkg.tarball
$expected   = $pkg.shasum.ToLower()
$download   = Join-Path $env:TEMP $zipFile

Write-Host "Downloading $tarballUrl"
Invoke-WebRequest -Uri $tarballUrl -OutFile $download -UseBasicParsing

$actual = (Get-FileHash -Algorithm SHA256 -Path $download).Hash.ToLower()
if ($actual -ne $expected) {
    throw "SHA256 mismatch: expected $expected, got $actual"
}

Write-Host "Extracting..."
if (Test-Path $archive) { Remove-Item -Recurse -Force $archive }
Expand-Archive -Path $download -DestinationPath . -Force
Move-Item -Path $archive -Destination $installDir -Force

Write-Host "Zig $Version installed to $installDir"
