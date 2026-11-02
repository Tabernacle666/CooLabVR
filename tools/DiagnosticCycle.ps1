[CmdletBinding()]
param(
    [ValidateRange(15,600)][int]$Seconds = 120,
    [ValidateRange(1,32)][int]$Parallel = 6,
    [switch]$GpuValidation
)
# Windows PowerShell 5.1. Headset stays powered on, on the table.
# The launcher does not fetch, pull, commit or push anything.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$project = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$exe = Join-Path $project 'build\bin\Release\LaboVR.exe'
$cameraFile = Join-Path $PSScriptRoot 'diagnostic_cameras.csv'
$stamp = Get-Date -Format 'yyyyMMdd_HHmmss_fff'
$runId = $stamp + '_' + $PID
$runDir = Join-Path $project ('diagnostics\runs\' + $runId)
$images = Join-Path $runDir 'screenshots'
$raw = Join-Path $runDir '_raw'
New-Item -ItemType Directory -Path $images,$raw -Force | Out-Null
$cycleLog = Join-Path $runDir 'cycle.txt'
$gameLog = Join-Path $runDir 'LaboVR_runtime.log'
$sourceSha = $null
$buildStatus = 'skipped_current_binary'
$buildExit = $null
$gameExit = $null
$forcedTermination = $false
$start = Get-Date
$exitCode = 1
$errors = New-Object 'System.Collections.Generic.List[string]'
$previousCaptureDir = $env:CONSOLEVR_CAPTURE_DIR
$relayDelivery = $null
$relayQa = $null
$relayQaCommit = $null
$relaySource = $null
$relayEligible = $false
$relayError = ''
try {
    $deliveryPath = Join-Path $project 'collaboration\programmeur\livraison.json'
    $qaPath = Join-Path $project 'collaboration\verificateur\verification.json'
    if((Test-Path $deliveryPath) -and (Test-Path $qaPath)) {
        $relayDelivery = Get-Content $deliveryPath -Raw | ConvertFrom-Json
        $relayQa = Get-Content $qaPath -Raw | ConvertFrom-Json
        $relaySource = [string]$relayDelivery.source_sha
        $relayQaCommit = (& git -C $project log -1 --format=%H -- collaboration/verificateur/verification.json 2>$null)
        $same = $relayDelivery.cycle_id -eq $relayQa.cycle_id -and $relayDelivery.billet -eq $relayQa.billet -and $relayDelivery.source_sha -eq $relayQa.source_sha -and [int]$relayDelivery.tentative -eq [int]$relayQa.tentative
        $relayEligible = $same -and $relayDelivery.etat -eq 'termine' -and $relayQa.etat -eq 'termine' -and $relayQa.examen -eq 'complet' -and $relayQa.resultat -eq 'conforme' -and [int]$relayQa.nombre_constats -eq 0 -and $relayQaCommit -match '^[a-f0-9]{40}
function Note([string]$line) {
    $value = (Get-Date -Format o) + ' ' + $line
    Add-Content -LiteralPath $cycleLog -Encoding UTF8 -Value $value
    Write-Host $value
}
try {
    if(-not (Test-Path -LiteralPath $cameraFile -PathType Leaf)) { throw "Missing camera CSV: $cameraFile" }
    Copy-Item -LiteralPath $cameraFile -Destination (Join-Path $runDir 'diagnostic_cameras.csv')
    if(Get-Command git -ErrorAction SilentlyContinue) {
        $sourceSha = (& git -C $project rev-parse HEAD 2>$null)
        if($LASTEXITCODE -ne 0) { $sourceSha = $null }
    }
    Note "Diagnostic start; source=$sourceSha; code=$relaySource; no Git sync; settle=3s/view; views=$((@(Import-Csv $cameraFile)).Count)"
    # Reuse a built executable. Only rebuild when it is missing or code/CMake is newer.
    $needsBuild = -not (Test-Path -LiteralPath $exe -PathType Leaf)
    if(-not $needsBuild) {
        $builtAt = (Get-Item -LiteralPath $exe).LastWriteTimeUtc
        $sources = @(Get-ChildItem -LiteralPath (Join-Path $project 'src'),(Join-Path $project 'labs'),(Join-Path $project 'shaders'),(Join-Path $project 'cmake') -Recurse -File |
            Where-Object { $_.Extension -in @('.cpp','.c','.h','.hpp','.cu','.inl','.hlsl','.cmake') })
        $sources += @(Get-Item -LiteralPath (Join-Path $project 'CMakeLists.txt'),(Join-Path $project 'VERSION.txt'))
        $needsBuild = @($sources | Where-Object { $_.LastWriteTimeUtc -gt $builtAt }).Count -gt 0
    }
    if($needsBuild) {
        $buildStatus = 'built_missing_or_stale'
        Note 'Build required: executable missing or sources newer than executable'
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'Build.ps1') -Target all -Parallel $Parallel
        $buildExit = $LASTEXITCODE
        $buildLog = Get-ChildItem -LiteralPath (Join-Path $project 'logs') -Filter 'build_console_*.log' -File -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if($buildLog) { Copy-Item -LiteralPath $buildLog.FullName -Destination (Join-Path $runDir 'LaboVR_build.log') }
        if($buildExit -ne 0) { throw "Build failed (exit $buildExit)" }
    } else { Note 'Build SKIPPED: existing executable is current' }
    if(-not (Test-Path -LiteralPath $exe -PathType Leaf)) { throw "Executable missing: $exe" }
    $env:CONSOLEVR_CAPTURE_DIR = $raw
    $args = @('--log',('"' + $gameLog + '"'),'--diagnostic-sweep',[string]$Seconds,
              '--diagnostic-camera-file',('"' + $cameraFile + '"'))
    if($GpuValidation) { $args += '--gpu-validation' }
    Note "Starting LaboVR; max_runtime_seconds=$Seconds"
    $proc = Start-Process -FilePath $exe -WorkingDirectory (Split-Path $exe) -ArgumentList $args -PassThru
    try {
        Wait-Process -Id $proc.Id -Timeout ($Seconds + 60) -ErrorAction Stop
        $proc.Refresh()
        $gameExit = $proc.ExitCode
        Note "Game exited itself with code $gameExit"
    } catch {
        $forcedTermination = $true
        $gameExit = 124
        Note "Timeout waiting for game exit: $($_.Exception.Message)"
        Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
    }
} catch {
    $errors.Add($_.Exception.Message)
    Note ('ERROR: ' + $_.Exception.Message)
} finally {
    $env:CONSOLEVR_CAPTURE_DIR = $previousCaptureDir
    $captureEvents = @()
    $summary = $null
    $cpuMetrics = $null
    $gpuMetrics = $null
    $physicsProfile = @()
    $xrProfile = $null
    $gpuTiming = @()
    $gpuExperiment = $null
    $continuity = $null
    $gpuPasses = @()
    $gpuQueues = @()
    if(Test-Path -LiteralPath $gameLog -PathType Leaf) {
        $lines = @(Get-Content -LiteralPath $gameLog -ErrorAction SilentlyContinue)
        $captureEvents = @($lines | Where-Object { $_ -match 'sweep\.capture\.saved' })
        $summary = @($lines | Where-Object { $_ -match 'sweep\.summary' } | Select-Object -Last 1)
        $summary = if($summary.Count) { [string]$summary[0] } else { $null }
        $cpuLines = @($lines | Where-Object { $_ -match '\tsweep\.cpu\t' } | Select-Object -Last 1)
        $gpuLines = @($lines | Where-Object { $_ -match '\tsweep\.gpu\t' } | Select-Object -Last 1)
        if($cpuLines.Count) { $cpuMetrics = [string]$cpuLines[0] }
        if($gpuLines.Count) { $gpuMetrics = [string]$gpuLines[0] }
        # Get-Content attaches PSPath/PSDrive notes to each string. Force bare strings,
        # otherwise ConvertTo-Json recursively serializes the entire provider graph.
        $physicsProfile = @($lines | Where-Object { $_ -match '\tphysics\.profile\.' } |
            ForEach-Object { [string]::Copy($_.ToString()) })
        $xrRows = @($lines | Where-Object { $_ -match '\tsweep\.xr\t' } | Select-Object -Last 1)
        $continuityRows = @($lines | Where-Object { $_ -match '\tsweep\.population_continuity\t' } | Select-Object -Last 1)
        if($continuityRows.Count) { $continuity = [string]$continuityRows[0] }
        $gpuTimingRows = @($lines | Where-Object { $_ -match '\tsweep\.gpu_timing\t' })
        $gpuExperimentRows = @($lines | Where-Object { $_ -match '\tsweep\.gpu_experiment\t' } | Select-Object -Last 1)
        if($xrRows.Count) { $xrProfile = [string]$xrRows[0] }
        $gpuTiming = @($gpuTimingRows | ForEach-Object { [string]::Copy($_.ToString()) })
        if($gpuExperimentRows.Count) { $gpuExperiment = [string]$gpuExperimentRows[0] }
        $gpuPasses = @($lines | Where-Object { $_ -match '\tsweep\.gpu_pass\t' } |
            ForEach-Object { [string]::Copy($_.ToString()) })
        $gpuQueues = @($lines | Where-Object { $_ -match '\tsweep\.gpu_queue\t' } |
            ForEach-Object { [string]::Copy($_.ToString()) })
        $lines | Where-Object { $_ -match 'sweep\.(start|view|capture|summary|timeout)' } |
            Set-Content -LiteralPath (Join-Path $runDir 'capture_index.txt') -Encoding UTF8
    }
    if($captureEvents.Count) {
        try {
            Add-Type -AssemblyName System.Drawing
            $jpegEncoder = [System.Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() |
                Where-Object { $_.MimeType -eq 'image/jpeg' } | Select-Object -First 1
            if(-not $jpegEncoder) { throw 'JPEG encoder unavailable' }
            foreach($captureEvent in $captureEvents) {
                if($captureEvent -notmatch 'slot=(\d+)\s+name=([a-zA-Z0-9_]+)\s+file=(.*)$') {
                    throw "Unrecognized capture record: $captureEvent"
                }
                $slot = [int]$Matches[1]
                $name = $Matches[2]
                $png = $Matches[3].Trim()
                if(-not (Test-Path -LiteralPath $png -PathType Leaf)) { throw "Missing captured PNG: $png" }
                $jpg = Join-Path $images ('{0:D2}_{1}.jpg' -f ($slot+1),$name)
                $bitmap = [System.Drawing.Image]::FromFile($png)
                $quality = New-Object System.Drawing.Imaging.EncoderParameters(1)
                try {
                    $quality.Param[0] = [System.Drawing.Imaging.EncoderParameter]::new(
                        [System.Drawing.Imaging.Encoder]::Quality,[long]74)
                    $limit = 1280
                    $ratio = [Math]::Min(1.0, $limit / [double]([Math]::Max($bitmap.Width,$bitmap.Height)))
                    $w = [Math]::Max(1,[int][Math]::Round($bitmap.Width*$ratio))
                    $h = [Math]::Max(1,[int][Math]::Round($bitmap.Height*$ratio))
                    $resized = New-Object System.Drawing.Bitmap($w,$h)
                    try {
                        $g = [System.Drawing.Graphics]::FromImage($resized)
                        try { $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic; $g.DrawImage($bitmap,0,0,$w,$h) }
                        finally { $g.Dispose() }
                        $resized.Save($jpg,$jpegEncoder,$quality)
                    } finally { $resized.Dispose() }
                } finally { $quality.Dispose();$bitmap.Dispose() }
                Remove-Item -LiteralPath $png -Force
                Note "JPEG saved: $jpg"
            }
        } catch {
            $errors.Add('JPEG conversion: ' + $_.Exception.Message)
            Note ('ERROR JPEG: ' + $_.Exception.Message)
        }
    }
    if($gameExit -eq 0 -and (-not $xrProfile -or $gpuTiming.Count -ne 2 -or -not $gpuExperiment -or $gpuPasses.Count -eq 0)) {
        $errors.Add('GPU/OpenXR performance profile incomplete')
        Note 'ERROR: missing GPU/OpenXR performance profile'
    }
    if(($null -ne $gameExit) -and (-not $continuity -or $continuity -notmatch 'result=pass\b')) {
        $errors.Add('Hidden population continuity was not verified')
        Note 'ERROR: hidden population continuity was not verified'
    }
    if($gameExit -eq 0 -and $physicsProfile.Count -ne 7) {
        $errors.Add("Physics telemetry incomplete: received $($physicsProfile.Count)/7 profile records")
        Note "ERROR: expected seven physics.profile records; received $($physicsProfile.Count)"
    }
    $jpgs = @(Get-ChildItem -LiteralPath $images -Filter '*.jpg' -File -ErrorAction SilentlyContinue | Sort-Object Name)
    $expectedViews = @(Import-Csv -LiteralPath $cameraFile).Count
    $complete = ($gameExit -eq 0 -and -not $forcedTermination -and $jpgs.Count -eq $expectedViews -and $errors.Count -eq 0)
    $exitCode = if($complete) { 0 } else { 20 }
    if($complete) { Remove-Item -LiteralPath $raw -Recurse -Force -ErrorAction SilentlyContinue }
    $manifest = [ordered]@{
        schema_version = 2
        source_commit = $relaySource
        tested_head = $sourceSha
        cycle_id = $relayDelivery.cycle_id
        billet = $relayDelivery.billet
        tentative = [int]$relayDelivery.tentative
        verification_commit_sha = $relayQaCommit
        run_id = $runId
        finished_utc = (Get-Date).ToUniversalTime().ToString('o')
        build = $buildStatus
        build_exit = $buildExit
        runtime_exit = $gameExit
        forced_termination = $forcedTermination
        runtime_seconds_limit = $Seconds
        camera_settle_seconds = 3
        preset = [ordered]@{ night = 'dark_room'; panel = 'amber'; fog = 'enabled'; flies = 500 }
        cameras = 'diagnostic_cameras.csv'
        saved_events = $captureEvents.Count
        jpeg_files = @($jpgs | ForEach-Object { $_.Name })
        performance_summary = $summary
        performance_cpu = $cpuMetrics
        performance_gpu = $gpuMetrics
        population_continuity = $continuity
        performance_physics = @($physicsProfile)
        performance_xr = $xrProfile
        performance_gpu_timing = @($gpuTiming)
        performance_gpu_experiment = $gpuExperiment
        performance_gpu_passes = @($gpuPasses)
        performance_gpu_queues = @($gpuQueues)
        errors = @($errors.ToArray())
        complete = $complete
    }
    $manifest | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $runDir 'manifest.json') -Encoding UTF8
    $receipt = [ordered]@{
        schema_version = 1; cycle_id = [string]$relayDelivery.cycle_id; billet = [string]$relayDelivery.billet
        tentative = [int]$relayDelivery.tentative; source_sha = [string]$relaySource
        verification_commit_sha = [string]$relayQaCommit; tested_head = [string]$sourceSha
        run_id = $runId; manifest_path = "diagnostics/runs/$runId/manifest.json"
        etat = $(if($complete){'complet'}elseif($buildExit -ne $null -and $buildExit -ne 0){'echec_compilation'}else{'echec_execution'})
    }
    $receiptPath = Join-Path $project 'collaboration\diagnostic\retour.json'
    New-Item -ItemType Directory -Path (Split-Path $receiptPath) -Force | Out-Null
    $receipt | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $receiptPath -Encoding UTF8
    Note "Diagnostic receipt: $receiptPath ; user must commit and push the run and receipt together."
    Note "Result: complete=$complete jpeg=$($jpgs.Count) runtime=$gameExit; files=$runDir"
    Note 'No Git action performed. Use GitHub Desktop to commit/push diagnostics/runs.'
}
exit $exitCode
 -and $relaySource -match '^[a-f0-9]{40}
function Note([string]$line) {
    $value = (Get-Date -Format o) + ' ' + $line
    Add-Content -LiteralPath $cycleLog -Encoding UTF8 -Value $value
    Write-Host $value
}
try {
    if(-not (Test-Path -LiteralPath $cameraFile -PathType Leaf)) { throw "Missing camera CSV: $cameraFile" }
    Copy-Item -LiteralPath $cameraFile -Destination (Join-Path $runDir 'diagnostic_cameras.csv')
    if(Get-Command git -ErrorAction SilentlyContinue) {
        $sourceSha = (& git -C $project rev-parse HEAD 2>$null)
        if($LASTEXITCODE -ne 0) { $sourceSha = $null }
    }
    Note "Diagnostic start; source=$sourceSha; no Git sync; settle=3s/view; views=2"
    # Reuse a built executable. Only rebuild when it is missing or code/CMake is newer.
    $needsBuild = -not (Test-Path -LiteralPath $exe -PathType Leaf)
    if(-not $needsBuild) {
        $builtAt = (Get-Item -LiteralPath $exe).LastWriteTimeUtc
        $sources = @(Get-ChildItem -LiteralPath (Join-Path $project 'src'),(Join-Path $project 'labs'),(Join-Path $project 'shaders'),(Join-Path $project 'cmake') -Recurse -File |
            Where-Object { $_.Extension -in @('.cpp','.c','.h','.hpp','.cu','.inl','.hlsl','.cmake') })
        $sources += @(Get-Item -LiteralPath (Join-Path $project 'CMakeLists.txt'),(Join-Path $project 'VERSION.txt'))
        $needsBuild = @($sources | Where-Object { $_.LastWriteTimeUtc -gt $builtAt }).Count -gt 0
    }
    if($needsBuild) {
        $buildStatus = 'built_missing_or_stale'
        Note 'Build required: executable missing or sources newer than executable'
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'Build.ps1') -Target all -Parallel $Parallel
        $buildExit = $LASTEXITCODE
        $buildLog = Get-ChildItem -LiteralPath (Join-Path $project 'logs') -Filter 'build_console_*.log' -File -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if($buildLog) { Copy-Item -LiteralPath $buildLog.FullName -Destination (Join-Path $runDir 'LaboVR_build.log') }
        if($buildExit -ne 0) { throw "Build failed (exit $buildExit)" }
    } else { Note 'Build SKIPPED: existing executable is current' }
    if(-not (Test-Path -LiteralPath $exe -PathType Leaf)) { throw "Executable missing: $exe" }
    $env:CONSOLEVR_CAPTURE_DIR = $raw
    $args = @('--log',('"' + $gameLog + '"'),'--diagnostic-sweep',[string]$Seconds,
              '--diagnostic-camera-file',('"' + $cameraFile + '"'))
    if($GpuValidation) { $args += '--gpu-validation' }
    Note "Starting LaboVR; max_runtime_seconds=$Seconds"
    $proc = Start-Process -FilePath $exe -WorkingDirectory (Split-Path $exe) -ArgumentList $args -PassThru
    try {
        Wait-Process -Id $proc.Id -Timeout ($Seconds + 60) -ErrorAction Stop
        $proc.Refresh()
        $gameExit = $proc.ExitCode
        Note "Game exited itself with code $gameExit"
    } catch {
        $forcedTermination = $true
        $gameExit = 124
        Note "Timeout waiting for game exit: $($_.Exception.Message)"
        Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
    }
} catch {
    $errors.Add($_.Exception.Message)
    Note ('ERROR: ' + $_.Exception.Message)
} finally {
    $env:CONSOLEVR_CAPTURE_DIR = $previousCaptureDir
    $captureEvents = @()
    $summary = $null
    $cpuMetrics = $null
    $gpuMetrics = $null
    $physicsProfile = @()
    $xrProfile = $null
    $gpuTiming = @()
    $gpuExperiment = $null
    $continuity = $null
    $gpuPasses = @()
    $gpuQueues = @()
    if(Test-Path -LiteralPath $gameLog -PathType Leaf) {
        $lines = @(Get-Content -LiteralPath $gameLog -ErrorAction SilentlyContinue)
        $captureEvents = @($lines | Where-Object { $_ -match 'sweep\.capture\.saved' })
        $summary = @($lines | Where-Object { $_ -match 'sweep\.summary' } | Select-Object -Last 1)
        $summary = if($summary.Count) { [string]$summary[0] } else { $null }
        $cpuLines = @($lines | Where-Object { $_ -match '\tsweep\.cpu\t' } | Select-Object -Last 1)
        $gpuLines = @($lines | Where-Object { $_ -match '\tsweep\.gpu\t' } | Select-Object -Last 1)
        if($cpuLines.Count) { $cpuMetrics = [string]$cpuLines[0] }
        if($gpuLines.Count) { $gpuMetrics = [string]$gpuLines[0] }
        # Get-Content attaches PSPath/PSDrive notes to each string. Force bare strings,
        # otherwise ConvertTo-Json recursively serializes the entire provider graph.
        $physicsProfile = @($lines | Where-Object { $_ -match '\tphysics\.profile\.' } |
            ForEach-Object { [string]::Copy($_.ToString()) })
        $xrRows = @($lines | Where-Object { $_ -match '\tsweep\.xr\t' } | Select-Object -Last 1)
        $continuityRows = @($lines | Where-Object { $_ -match '\tsweep\.population_continuity\t' } | Select-Object -Last 1)
        if($continuityRows.Count) { $continuity = [string]$continuityRows[0] }
        $gpuTimingRows = @($lines | Where-Object { $_ -match '\tsweep\.gpu_timing\t' })
        $gpuExperimentRows = @($lines | Where-Object { $_ -match '\tsweep\.gpu_experiment\t' } | Select-Object -Last 1)
        if($xrRows.Count) { $xrProfile = [string]$xrRows[0] }
        $gpuTiming = @($gpuTimingRows | ForEach-Object { [string]::Copy($_.ToString()) })
        if($gpuExperimentRows.Count) { $gpuExperiment = [string]$gpuExperimentRows[0] }
        $gpuPasses = @($lines | Where-Object { $_ -match '\tsweep\.gpu_pass\t' } |
            ForEach-Object { [string]::Copy($_.ToString()) })
        $gpuQueues = @($lines | Where-Object { $_ -match '\tsweep\.gpu_queue\t' } |
            ForEach-Object { [string]::Copy($_.ToString()) })
        $lines | Where-Object { $_ -match 'sweep\.(start|view|capture|summary|timeout)' } |
            Set-Content -LiteralPath (Join-Path $runDir 'capture_index.txt') -Encoding UTF8
    }
    if($captureEvents.Count) {
        try {
            Add-Type -AssemblyName System.Drawing
            $jpegEncoder = [System.Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() |
                Where-Object { $_.MimeType -eq 'image/jpeg' } | Select-Object -First 1
            if(-not $jpegEncoder) { throw 'JPEG encoder unavailable' }
            foreach($captureEvent in $captureEvents) {
                if($captureEvent -notmatch 'slot=(\d+)\s+name=([a-zA-Z0-9_]+)\s+file=(.*)$') {
                    throw "Unrecognized capture record: $captureEvent"
                }
                $slot = [int]$Matches[1]
                $name = $Matches[2]
                $png = $Matches[3].Trim()
                if(-not (Test-Path -LiteralPath $png -PathType Leaf)) { throw "Missing captured PNG: $png" }
                $jpg = Join-Path $images ('{0:D2}_{1}.jpg' -f ($slot+1),$name)
                $bitmap = [System.Drawing.Image]::FromFile($png)
                $quality = New-Object System.Drawing.Imaging.EncoderParameters(1)
                try {
                    $quality.Param[0] = [System.Drawing.Imaging.EncoderParameter]::new(
                        [System.Drawing.Imaging.Encoder]::Quality,[long]92)
                    $bitmap.Save($jpg,$jpegEncoder,$quality)
                } finally { $quality.Dispose();$bitmap.Dispose() }
                Remove-Item -LiteralPath $png -Force
                Note "JPEG saved: $jpg"
            }
        } catch {
            $errors.Add('JPEG conversion: ' + $_.Exception.Message)
            Note ('ERROR JPEG: ' + $_.Exception.Message)
        }
    }
    if($gameExit -eq 0 -and (-not $xrProfile -or $gpuTiming.Count -ne 2 -or -not $gpuExperiment -or $gpuPasses.Count -eq 0)) {
        $errors.Add('GPU/OpenXR performance profile incomplete')
        Note 'ERROR: missing GPU/OpenXR performance profile'
    }
    if(($null -ne $gameExit) -and (-not $continuity -or $continuity -notmatch 'result=pass\b')) {
        $errors.Add('Hidden population continuity was not verified')
        Note 'ERROR: hidden population continuity was not verified'
    }
    if($gameExit -eq 0 -and $physicsProfile.Count -ne 7) {
        $errors.Add("Physics telemetry incomplete: received $($physicsProfile.Count)/7 profile records")
        Note "ERROR: expected seven physics.profile records; received $($physicsProfile.Count)"
    }
    $jpgs = @(Get-ChildItem -LiteralPath $images -Filter '*.jpg' -File -ErrorAction SilentlyContinue | Sort-Object Name)
    $complete = ($gameExit -eq 0 -and -not $forcedTermination -and $jpgs.Count -eq 2 -and $errors.Count -eq 0)
    $exitCode = if($complete) { 0 } else { 20 }
    if($complete) { Remove-Item -LiteralPath $raw -Recurse -Force -ErrorAction SilentlyContinue }
    $manifest = [ordered]@{
        schema_version = 2
        source_commit = $sourceSha
        run_id = $runId
        finished_utc = (Get-Date).ToUniversalTime().ToString('o')
        build = $buildStatus
        build_exit = $buildExit
        runtime_exit = $gameExit
        forced_termination = $forcedTermination
        runtime_seconds_limit = $Seconds
        camera_settle_seconds = 3
        preset = [ordered]@{ night = 'dark_room'; panel = 'amber'; fog = 'enabled'; flies = 500 }
        cameras = 'diagnostic_cameras.csv'
        saved_events = $captureEvents.Count
        jpeg_files = @($jpgs | ForEach-Object { $_.Name })
        performance_summary = $summary
        performance_cpu = $cpuMetrics
        performance_gpu = $gpuMetrics
        population_continuity = $continuity
        performance_physics = @($physicsProfile)
        performance_xr = $xrProfile
        performance_gpu_timing = @($gpuTiming)
        performance_gpu_experiment = $gpuExperiment
        performance_gpu_passes = @($gpuPasses)
        performance_gpu_queues = @($gpuQueues)
        errors = @($errors.ToArray())
        complete = $complete
    }
    $manifest | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $runDir 'manifest.json') -Encoding UTF8
    Note "Result: complete=$complete jpeg=$($jpgs.Count) runtime=$gameExit; files=$runDir"
    Note 'No Git action performed. Use GitHub Desktop to commit/push diagnostics/runs.'
}
exit $exitCode

        if($relayEligible) {
            & git -C $project merge-base --is-ancestor $relaySource HEAD
            if($LASTEXITCODE -ne 0) { $relayEligible = $false; $relayError = 'Source de livraison hors de la branche locale.' }
            else {
                $changed = @(& git -C $project diff --name-only $relaySource HEAD -- src labs shaders cmake CMakeLists.txt)
                if($changed.Count) { $relayEligible = $false; $relayError = 'Code modifié après la livraison QA : ' + ($changed -join ', ') }
            }
        }
    }
} catch { $relayError = $_.Exception.Message }
if(-not $relayEligible) { throw "Diagnostic réservé à une livraison QA conforme, non modifiée. $relayError" }
function Note([string]$line) {
    $value = (Get-Date -Format o) + ' ' + $line
    Add-Content -LiteralPath $cycleLog -Encoding UTF8 -Value $value
    Write-Host $value
}
try {
    if(-not (Test-Path -LiteralPath $cameraFile -PathType Leaf)) { throw "Missing camera CSV: $cameraFile" }
    Copy-Item -LiteralPath $cameraFile -Destination (Join-Path $runDir 'diagnostic_cameras.csv')
    if(Get-Command git -ErrorAction SilentlyContinue) {
        $sourceSha = (& git -C $project rev-parse HEAD 2>$null)
        if($LASTEXITCODE -ne 0) { $sourceSha = $null }
    }
    Note "Diagnostic start; source=$sourceSha; no Git sync; settle=3s/view; views=2"
    # Reuse a built executable. Only rebuild when it is missing or code/CMake is newer.
    $needsBuild = -not (Test-Path -LiteralPath $exe -PathType Leaf)
    if(-not $needsBuild) {
        $builtAt = (Get-Item -LiteralPath $exe).LastWriteTimeUtc
        $sources = @(Get-ChildItem -LiteralPath (Join-Path $project 'src'),(Join-Path $project 'labs'),(Join-Path $project 'shaders'),(Join-Path $project 'cmake') -Recurse -File |
            Where-Object { $_.Extension -in @('.cpp','.c','.h','.hpp','.cu','.inl','.hlsl','.cmake') })
        $sources += @(Get-Item -LiteralPath (Join-Path $project 'CMakeLists.txt'),(Join-Path $project 'VERSION.txt'))
        $needsBuild = @($sources | Where-Object { $_.LastWriteTimeUtc -gt $builtAt }).Count -gt 0
    }
    if($needsBuild) {
        $buildStatus = 'built_missing_or_stale'
        Note 'Build required: executable missing or sources newer than executable'
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'Build.ps1') -Target all -Parallel $Parallel
        $buildExit = $LASTEXITCODE
        $buildLog = Get-ChildItem -LiteralPath (Join-Path $project 'logs') -Filter 'build_console_*.log' -File -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if($buildLog) { Copy-Item -LiteralPath $buildLog.FullName -Destination (Join-Path $runDir 'LaboVR_build.log') }
        if($buildExit -ne 0) { throw "Build failed (exit $buildExit)" }
    } else { Note 'Build SKIPPED: existing executable is current' }
    if(-not (Test-Path -LiteralPath $exe -PathType Leaf)) { throw "Executable missing: $exe" }
    $env:CONSOLEVR_CAPTURE_DIR = $raw
    $args = @('--log',('"' + $gameLog + '"'),'--diagnostic-sweep',[string]$Seconds,
              '--diagnostic-camera-file',('"' + $cameraFile + '"'))
    if($GpuValidation) { $args += '--gpu-validation' }
    Note "Starting LaboVR; max_runtime_seconds=$Seconds"
    $proc = Start-Process -FilePath $exe -WorkingDirectory (Split-Path $exe) -ArgumentList $args -PassThru
    try {
        Wait-Process -Id $proc.Id -Timeout ($Seconds + 60) -ErrorAction Stop
        $proc.Refresh()
        $gameExit = $proc.ExitCode
        Note "Game exited itself with code $gameExit"
    } catch {
        $forcedTermination = $true
        $gameExit = 124
        Note "Timeout waiting for game exit: $($_.Exception.Message)"
        Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
    }
} catch {
    $errors.Add($_.Exception.Message)
    Note ('ERROR: ' + $_.Exception.Message)
} finally {
    $env:CONSOLEVR_CAPTURE_DIR = $previousCaptureDir
    $captureEvents = @()
    $summary = $null
    $cpuMetrics = $null
    $gpuMetrics = $null
    $physicsProfile = @()
    $xrProfile = $null
    $gpuTiming = @()
    $gpuExperiment = $null
    $continuity = $null
    $gpuPasses = @()
    $gpuQueues = @()
    if(Test-Path -LiteralPath $gameLog -PathType Leaf) {
        $lines = @(Get-Content -LiteralPath $gameLog -ErrorAction SilentlyContinue)
        $captureEvents = @($lines | Where-Object { $_ -match 'sweep\.capture\.saved' })
        $summary = @($lines | Where-Object { $_ -match 'sweep\.summary' } | Select-Object -Last 1)
        $summary = if($summary.Count) { [string]$summary[0] } else { $null }
        $cpuLines = @($lines | Where-Object { $_ -match '\tsweep\.cpu\t' } | Select-Object -Last 1)
        $gpuLines = @($lines | Where-Object { $_ -match '\tsweep\.gpu\t' } | Select-Object -Last 1)
        if($cpuLines.Count) { $cpuMetrics = [string]$cpuLines[0] }
        if($gpuLines.Count) { $gpuMetrics = [string]$gpuLines[0] }
        # Get-Content attaches PSPath/PSDrive notes to each string. Force bare strings,
        # otherwise ConvertTo-Json recursively serializes the entire provider graph.
        $physicsProfile = @($lines | Where-Object { $_ -match '\tphysics\.profile\.' } |
            ForEach-Object { [string]::Copy($_.ToString()) })
        $xrRows = @($lines | Where-Object { $_ -match '\tsweep\.xr\t' } | Select-Object -Last 1)
        $continuityRows = @($lines | Where-Object { $_ -match '\tsweep\.population_continuity\t' } | Select-Object -Last 1)
        if($continuityRows.Count) { $continuity = [string]$continuityRows[0] }
        $gpuTimingRows = @($lines | Where-Object { $_ -match '\tsweep\.gpu_timing\t' })
        $gpuExperimentRows = @($lines | Where-Object { $_ -match '\tsweep\.gpu_experiment\t' } | Select-Object -Last 1)
        if($xrRows.Count) { $xrProfile = [string]$xrRows[0] }
        $gpuTiming = @($gpuTimingRows | ForEach-Object { [string]::Copy($_.ToString()) })
        if($gpuExperimentRows.Count) { $gpuExperiment = [string]$gpuExperimentRows[0] }
        $gpuPasses = @($lines | Where-Object { $_ -match '\tsweep\.gpu_pass\t' } |
            ForEach-Object { [string]::Copy($_.ToString()) })
        $gpuQueues = @($lines | Where-Object { $_ -match '\tsweep\.gpu_queue\t' } |
            ForEach-Object { [string]::Copy($_.ToString()) })
        $lines | Where-Object { $_ -match 'sweep\.(start|view|capture|summary|timeout)' } |
            Set-Content -LiteralPath (Join-Path $runDir 'capture_index.txt') -Encoding UTF8
    }
    if($captureEvents.Count) {
        try {
            Add-Type -AssemblyName System.Drawing
            $jpegEncoder = [System.Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() |
                Where-Object { $_.MimeType -eq 'image/jpeg' } | Select-Object -First 1
            if(-not $jpegEncoder) { throw 'JPEG encoder unavailable' }
            foreach($captureEvent in $captureEvents) {
                if($captureEvent -notmatch 'slot=(\d+)\s+name=([a-zA-Z0-9_]+)\s+file=(.*)$') {
                    throw "Unrecognized capture record: $captureEvent"
                }
                $slot = [int]$Matches[1]
                $name = $Matches[2]
                $png = $Matches[3].Trim()
                if(-not (Test-Path -LiteralPath $png -PathType Leaf)) { throw "Missing captured PNG: $png" }
                $jpg = Join-Path $images ('{0:D2}_{1}.jpg' -f ($slot+1),$name)
                $bitmap = [System.Drawing.Image]::FromFile($png)
                $quality = New-Object System.Drawing.Imaging.EncoderParameters(1)
                try {
                    $quality.Param[0] = [System.Drawing.Imaging.EncoderParameter]::new(
                        [System.Drawing.Imaging.Encoder]::Quality,[long]92)
                    $bitmap.Save($jpg,$jpegEncoder,$quality)
                } finally { $quality.Dispose();$bitmap.Dispose() }
                Remove-Item -LiteralPath $png -Force
                Note "JPEG saved: $jpg"
            }
        } catch {
            $errors.Add('JPEG conversion: ' + $_.Exception.Message)
            Note ('ERROR JPEG: ' + $_.Exception.Message)
        }
    }
    if($gameExit -eq 0 -and (-not $xrProfile -or $gpuTiming.Count -ne 2 -or -not $gpuExperiment -or $gpuPasses.Count -eq 0)) {
        $errors.Add('GPU/OpenXR performance profile incomplete')
        Note 'ERROR: missing GPU/OpenXR performance profile'
    }
    if(($null -ne $gameExit) -and (-not $continuity -or $continuity -notmatch 'result=pass\b')) {
        $errors.Add('Hidden population continuity was not verified')
        Note 'ERROR: hidden population continuity was not verified'
    }
    if($gameExit -eq 0 -and $physicsProfile.Count -ne 7) {
        $errors.Add("Physics telemetry incomplete: received $($physicsProfile.Count)/7 profile records")
        Note "ERROR: expected seven physics.profile records; received $($physicsProfile.Count)"
    }
    $jpgs = @(Get-ChildItem -LiteralPath $images -Filter '*.jpg' -File -ErrorAction SilentlyContinue | Sort-Object Name)
    $complete = ($gameExit -eq 0 -and -not $forcedTermination -and $jpgs.Count -eq 2 -and $errors.Count -eq 0)
    $exitCode = if($complete) { 0 } else { 20 }
    if($complete) { Remove-Item -LiteralPath $raw -Recurse -Force -ErrorAction SilentlyContinue }
    $manifest = [ordered]@{
        schema_version = 2
        source_commit = $sourceSha
        run_id = $runId
        finished_utc = (Get-Date).ToUniversalTime().ToString('o')
        build = $buildStatus
        build_exit = $buildExit
        runtime_exit = $gameExit
        forced_termination = $forcedTermination
        runtime_seconds_limit = $Seconds
        camera_settle_seconds = 3
        preset = [ordered]@{ night = 'dark_room'; panel = 'amber'; fog = 'enabled'; flies = 500 }
        cameras = 'diagnostic_cameras.csv'
        saved_events = $captureEvents.Count
        jpeg_files = @($jpgs | ForEach-Object { $_.Name })
        performance_summary = $summary
        performance_cpu = $cpuMetrics
        performance_gpu = $gpuMetrics
        population_continuity = $continuity
        performance_physics = @($physicsProfile)
        performance_xr = $xrProfile
        performance_gpu_timing = @($gpuTiming)
        performance_gpu_experiment = $gpuExperiment
        performance_gpu_passes = @($gpuPasses)
        performance_gpu_queues = @($gpuQueues)
        errors = @($errors.ToArray())
        complete = $complete
    }
    $manifest | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $runDir 'manifest.json') -Encoding UTF8
    Note "Result: complete=$complete jpeg=$($jpgs.Count) runtime=$gameExit; files=$runDir"
    Note 'No Git action performed. Use GitHub Desktop to commit/push diagnostics/runs.'
}
exit $exitCode
