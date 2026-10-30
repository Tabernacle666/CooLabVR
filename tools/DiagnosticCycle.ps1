[CmdletBinding()]
param(
    [ValidateRange(15,600)][int]$Seconds = 100,
    [ValidateRange(1,32)][int]$Parallel = 6,
    [switch]$GpuValidation
)
# Windows PowerShell 5.1, Git, CMake, OpenXR. The headset can remain on
# a table while Core renders three configurable virtual camera positions.
# Actual XR tracking still establishes the session; no pose injection into ABI.
# Images are captured by the host's existing OpenXR/WIC service.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$project = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$gitRoot = (& git -C $project rev-parse --show-toplevel)
if ($LASTEXITCODE -ne 0 -or -not $gitRoot) { throw 'A Git working tree is required.' }
$gitRoot = $gitRoot.Trim()
$branch = (& git -C $gitRoot branch --show-current).Trim()
if ($branch -ne 'dev') {
    throw "Current branch is '$branch', expected dev. Not switching branches automatically."
}
$dirty = @(& git -C $gitRoot status --porcelain --untracked-files=no)
if ($dirty.Count -gt 0 -and ($dirty -join '').Trim()) {
    throw 'Tracked files are modified. Commit/stash them before sync; this script will never reset or overwrite your changes.'
}
$staged = @(& git -C $gitRoot diff --cached --name-only)
if ($staged.Count -gt 0 -and ($staged -join '').Trim()) {
    throw 'The index already contains staged files. Refusing to include unrelated work in diagnostic commit.'
}
Write-Host 'Fetching development branch (fast-forward only)...'
& git -C $gitRoot fetch origin dev
if ($LASTEXITCODE -ne 0) { throw 'Git fetch failed. Check network/credentials.' }
& git -C $gitRoot pull --ff-only origin dev
if ($LASTEXITCODE -ne 0) { throw 'Fast-forward pull refused. No files were overwritten.' }
$sourceSha = (& git -C $gitRoot rev-parse HEAD).Trim()
$stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$short = $sourceSha.Substring(0,10)
$runId = $stamp + '_' + $short + '_' + $PID
$relative = 'diagnostics/runs/' + $runId
$runDir = Join-Path $gitRoot ($relative.Replace('/', '\'))
$images = Join-Path $runDir 'screenshots'
New-Item -ItemType Directory -Path $images -Force | Out-Null
$cycleLog = Join-Path $runDir 'cycle.txt'
$gameLog = Join-Path $runDir 'LaboVR_runtime.log'
$buildLogDirectory = Join-Path $project 'logs'
$exit = 1
$buildExit = -1
$gameExit = -1
$forcedTermination = $false
$phase = 'build'
$started = Get-Date
function Note([string]$text) {
    $line = (Get-Date -Format o) + ' ' + $text
    Add-Content -LiteralPath $cycleLog -Encoding UTF8 -Value $line
    Write-Host $line
}
Note "run=$runId base=$sourceSha duration_s=$Seconds mode=three_virtual_render_cameras"
Note 'Protocol: leave the active headset on the table; no physical head movement is required.'
# Not a separate rendering path. The WorldEditor adds a transient mast through
# visual_v1 and the host alone owns the screenshot/readback destination.
$env:CONSOLEVR_CAPTURE_DIR = $images
$env:CONSOLEVR_DIAGNOSTIC_SWEEP = '1'
$cameraFile = Join-Path $project 'tools\diagnostic_cameras.csv'
if (-not (Test-Path -LiteralPath $cameraFile)) {
    throw "Required camera preset file is absent: $cameraFile"
}
Copy-Item -LiteralPath $cameraFile -Destination (Join-Path $runDir 'diagnostic_cameras.csv')
Note ('Presets: ' + $cameraFile)
try {
    $phase = 'build'
    $buildScript = Join-Path $project 'tools\Build.ps1'
    Note 'Build: ConsoleVR all targets (Release)'
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $buildScript -Target all -Parallel $Parallel
    $buildExit = $LASTEXITCODE
    $candidate = Get-ChildItem -LiteralPath $buildLogDirectory -Filter 'build_console_*.log' -File -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -ge $started.AddSeconds(-5) } |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($candidate) {
        Copy-Item -LiteralPath $candidate.FullName -Destination (Join-Path $runDir 'LaboVR_build.log')
        Note ('Build log: ' + $candidate.Name)
    } else { Note 'WARN: no build log found.' }
    if ($buildExit -ne 0) {
        Note "Build failed code=$buildExit. Run is skipped, diagnostics will still be committed."
    } else {
        $phase = 'run'
        $exe = Join-Path $project 'build\bin\Release\LaboVR.exe'
        if (-not (Test-Path -LiteralPath $exe)) { throw "Missing executable $exe" }
        $args = @('--log', ('"' + $gameLog + '"'), '--diagnostic-sweep', [string]$Seconds,
            '--diagnostic-camera-file', ('"' + $cameraFile + '"'))
        if ($GpuValidation) { $args += '--gpu-validation' }
        Note ('Launching: LaboVR.exe --diagnostic-sweep ' + $Seconds)
        $proc = Start-Process -FilePath $exe -WorkingDirectory (Split-Path $exe) -ArgumentList $args -PassThru
        try {
            # The app exits its own XR loop. This timeout only catches a
            # deadlocked startup or the known pending-world-retirement bug.
            Wait-Process -Id $proc.Id -Timeout ($Seconds + 120) -ErrorAction Stop
            $proc.Refresh()
            $gameExit = $proc.ExitCode
            Note "Application finished code=$gameExit"
        } catch {
            $forcedTermination = $true
            Note ('WARN: game did not exit; timeout/exception: ' + $_.Exception.Message)
            try { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue } catch {}
            $gameExit = 124
        }
    }
    $exit = if ($buildExit -ne 0) { $buildExit } else { $gameExit }
} catch {
    Note ('ERROR at phase=' + $phase + ': ' + $_.Exception.Message)
    $exit = 10
} finally {
    $env:CONSOLEVR_CAPTURE_DIR = $null
    $env:CONSOLEVR_DIAGNOSTIC_SWEEP = $null
    $pngs = @(Get-ChildItem -LiteralPath $images -Filter '*.png' -File -ErrorAction SilentlyContinue)
    $captured = 0
    $failed = 0
    $requests = 0
    $observations = @()
    if (Test-Path -LiteralPath $gameLog) {
        $lines = Get-Content -LiteralPath $gameLog -ErrorAction SilentlyContinue
        $observations = @($lines | Where-Object { $_ -match 'sweep\.capture\.(saved|failed|request)' })
        $captured = @($observations | Where-Object { $_ -match 'sweep\.capture\.saved' }).Count
        $failed = @($observations | Where-Object { $_ -match 'sweep\.capture\.failed' }).Count
        $requests = @($observations | Where-Object { $_ -match 'sweep\.capture\.request' }).Count
        $observations | Set-Content -LiteralPath (Join-Path $runDir 'capture_index.txt') -Encoding UTF8
    }
    # Rename by the explicit host camera tag, preserving a one-to-one map
    # between Git PNG names and source camera coordinates.
    $renamed = @()
    if ($observations.Count -gt 0) {
        foreach ($entry in @($observations | Where-Object { $_ -match 'sweep\.capture\.saved' })) {
            if ($entry -match 'slot=(?<slot>[0-2])\s+request=.*?png=(?<png>.*?)\s+detail=') {
                $slot = [int]$Matches['slot']
                $file = $Matches['png']
                $label = ''
                if ($entry -match 'name=(?<name>[A-Za-z0-9_-]+)\s+slot=') { $label = $Matches['name'] }
                $original = Join-Path $images (Split-Path -Path $file -Leaf)
                $destination = ('{0:D2}_{1}.png' -f ($slot + 1),$label)
                if ($label -and (Test-Path -LiteralPath $original) -and
                    -not (Test-Path -LiteralPath (Join-Path $images $destination))) {
                    Rename-Item -LiteralPath $original -NewName $destination
                    $renamed += $destination
                }
            }
        }
    }
    $pngs = @(Get-ChildItem -LiteralPath $images -Filter '*.png' -File -ErrorAction SilentlyContinue)
    $meta = [ordered]@{
        schema_version = 1
        run_id = $runId
        utc_finished = (Get-Date).ToUniversalTime().ToString('o')
        source_commit = $sourceSha
        branch = 'dev'
        build_exit = $buildExit
        runtime_exit = $gameExit
        forced_termination = $forcedTermination
        requested_seconds = $Seconds
        camera_presets_file = 'diagnostic_cameras.csv'
        capture_requests = $requests
        capture_saved_events = $captured
        capture_failed_events = $failed
        png_files = @($pngs | Sort-Object Name | ForEach-Object { $_.Name })
        capture_mode = 'three host-only virtual render cameras; actual headset tracking untouched'
        marker = 'WorldEditor visual_v1 transient pole at X=0 Z=0, Y=0..4m'
        completeness = 'three programmed viewpoints; a missing PNG means that particular view was not captured'
    }
    $meta | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $runDir 'manifest.json') -Encoding UTF8
    Note "Summary: PNG=$($pngs.Count) captures_saved=$captured requests=$requests errors=$failed build=$buildExit run=$gameExit"
    Note ('Repository publication: ' + $relative)
    # Only stage the newly-created diagnostic directory. Do NOT add all logs
    # or user files, and never force push or reset a branch.
    & git -C $gitRoot add -f -- $relative
    if ($LASTEXITCODE -ne 0) { throw 'Git add failed; evidence stays on disk.' }
    & git -C $gitRoot diff --cached --quiet
    if ($LASTEXITCODE -eq 0) { Note 'Nothing to commit.' }
    elseif ($LASTEXITCODE -eq 1) {
        & git -C $gitRoot commit -m ("diagnostics: XR sweep " + $runId)
        if ($LASTEXITCODE -ne 0) { throw 'Git commit failed; evidence stays on disk.' }
        & git -C $gitRoot push origin dev
        if ($LASTEXITCODE -ne 0) {
            throw 'Git push rejected. Evidence committed locally; use git push origin dev after resolving remote changes.'
        }
        Write-Host ('Published commit: ' + (& git -C $gitRoot rev-parse HEAD))
    } else { throw 'Git staged status failed.' }
    Write-Host ('Run directory: ' + $runDir)
}
exit $exit
