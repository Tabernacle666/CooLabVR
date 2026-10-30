param([string]$Destination = (Split-Path -Parent $PSScriptRoot))
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
# Release identity is sourced exclusively from VERSION.txt (1.1.49.10.2+).
$version = (Get-Content -LiteralPath (Join-Path $root 'VERSION.txt') -Raw).Trim()
$stage = Join-Path ([IO.Path]::GetTempPath()) ('ConsoleVR-package-' + [Guid]::NewGuid())
try {
    $source = New-Item -ItemType Directory -Path (Join-Path $stage 'ConsoleVR')
    foreach ($directory in @('src','labs','shaders','profiles','cmake','tools')) {
        Copy-Item -LiteralPath (Join-Path $root $directory) -Destination $source.FullName -Recurse
    }
    foreach ($file in (Get-ChildItem -LiteralPath $root -File)) {
        if ($file.Name -in @('CMakeLists.txt','VERSION.txt') -or $file.Extension -eq '.bat') {
            Copy-Item -LiteralPath $file.FullName -Destination $source.FullName
        }
    }
    Get-ChildItem -LiteralPath $source.FullName -Recurse -File |
        Where-Object { $_.Extension -in @('.md','.log','.obj','.pdb','.exe','.dll','.zip') } |
        Remove-Item -Force
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    $archive = Join-Path $Destination "ConsoleVR_$version.zip"
    Compress-Archive -LiteralPath $source.FullName -DestinationPath $archive -Force
    # Distribute the independent public SDK separately from the full source archive.
    $sdkSource = Join-Path $stage 'ConsoleVRCartridgeSDK'
    & cmake "-DLABOVR_SDK_OUTPUT=$sdkSource" -P (Join-Path $root 'cmake/ExportCartridgeSDK.cmake')
    if ($LASTEXITCODE -ne 0) { throw 'ConsoleVR cartridge SDK export failed' }
    $sdkArchive = Join-Path $Destination "ConsoleVR_CartridgeSDK_$version.zip"
    Compress-Archive -LiteralPath $sdkSource -DestinationPath $sdkArchive -Force
    Write-Output $archive
    Write-Output $sdkArchive
} finally {
    if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
}
