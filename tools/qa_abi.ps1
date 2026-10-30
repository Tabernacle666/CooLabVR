[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Ticket,
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[0-9a-fA-F]{40}$')]
    [string]$Commit,
    [ValidateRange(1, 32)]
    [int]$Parallel = 6,
    [string]$StartupReference
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# The ticket mapping is fixed to the ABI registry/plan. An unknown ticket fails,
# rather than silently running a different test.
$caseByTicket = @{
    '1.1.55.66' = 'harness'
    '1.1.55.67' = 'packet_include'
    '1.1.55.68' = 'scene_merge'
    '1.1.55.69' = 'diagnostic_records'
    '1.1.55.70' = 'c_tags'
    '1.1.55.71' = 'sdk_road'
    '1.1.55.72' = 'client_text'
    '1.1.55.73' = 'client_clock'
    '1.1.55.74' = 'diagnostic_host'
    '1.1.55.75' = 'layout'
    '1.1.55.76' = 'client_audio_values'
    '1.1.55.77' = 'authored_raycast'
    '1.1.55.78' = 'diagnostic_client'
    '1.1.55.79' = 'diagnostic_capture'
    '1.1.55.80' = 'host_prefix'
    '1.1.55.81' = 'output_prefix'
    '1.1.55.82' = 'public_limits'
    '1.1.55.83' = 'authored_raycast_use'
    '1.1.55.84' = 'composition_contract'
    '1.1.55.85' = 'wire_records'
    '1.1.55.86' = 'baseline'
    '1.1.55.89' = 'sdk_limits'
    '1.1.55.90' = 'package_root'
    '1.1.55.91' = 'canonical_reader'
    '1.1.55.92' = 'composition_policy'
    '1.1.55.93' = 'layer_contract'
    '1.1.55.94' = 'wire_geometry'
}
if (-not $caseByTicket.ContainsKey($Ticket)) {
    throw "Unknown or unauthorized ABI ticket: $Ticket"
}
if ($env:OS -ne 'Windows_NT') { throw 'Windows MSVC x64 is required.' }

$root = Split-Path $PSScriptRoot -Parent
$version = (Get-Content -Raw -LiteralPath (Join-Path $root 'VERSION.txt')).Trim()
$runId = (Get-Date -Format 'yyyyMMdd_HHmmss_fff') + '_' + $PID
$run = Join-Path $root (Join-Path 'logs\qa_abi' (Join-Path $Ticket $runId))
# New per-invocation build trees prevent reuse of products from an earlier run.
$build = Join-Path $run 'engine_build'
$abiBuild = Join-Path $run 'abi_build'
New-Item -ItemType Directory -Path $run -ErrorAction Stop | Out-Null
$phases = [ordered]@{}
$products = [ordered]@{}
$startup = [ordered]@{ status = 'not_provided'; recorded_by = 'creator_only'; path = $null; sha256 = $null }
$outcome = 'failed'
$failure = $null

function Invoke-Recorded {
    param([string]$Name, [string]$Executable, [string[]]$Arguments)
    $path = Join-Path $run ($Name + '.log')
    $writer = New-Object System.IO.StreamWriter($path, $false, (New-Object System.Text.UTF8Encoding($false)))
    $writer.AutoFlush = $true
    $exitCode = -1
    try {
        $writer.WriteLine($Executable + ' ' + ($Arguments -join ' '))
        $previous = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'
            & $Executable @Arguments 2>&1 | ForEach-Object {
                $line = $_.ToString()
                $writer.WriteLine($line)
                Write-Host $line
            }
            $exitCode = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $previous
        }
        $writer.WriteLine('exit_code=' + $exitCode)
    } finally {
        $writer.Dispose()
    }
    $phases[$Name] = [ordered]@{
        executable = $Executable
        arguments = @($Arguments)
        exit_code = $exitCode
        log = $path
    }
    if ($exitCode -ne 0) {
        throw "$Name failed (exit $exitCode). See $path"
    }
}

function Get-BuiltProduct {
    param([string]$Directory, [string]$FileName)
    if (-not (Test-Path -LiteralPath $Directory -PathType Container)) {
        throw "Missing build output directory: $Directory"
    }
    $matches = @(Get-ChildItem -LiteralPath $Directory -Recurse -File -Filter $FileName)
    if ($matches.Count -ne 1) {
        throw "Expected exactly one binary $FileName in $Directory; found $($matches.Count)"
    }
    $item = $matches[0]
    return [ordered]@{
        path = $item.FullName
        bytes = $item.Length
        sha256 = (Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash
    }
}

try {
    foreach ($tool in @('cmake', 'ctest', 'git')) {
        if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
            throw "Missing command in PATH: $tool"
        }
    }
    $headOutput = @(& git -C $root rev-parse HEAD 2>&1)
    if ($LASTEXITCODE -ne 0 -or $headOutput.Count -ne 1) {
        throw 'Cannot read the source Git commit.'
    }
    $head = [string]$headOutput[0]
    if ($head.Trim() -ne $Commit) {
        throw "Checkout SHA $head differs from -Commit $Commit"
    }
    # Exclude only this tool's historical outputs; reject all other dirty inputs.
    $gitStatus = @(& git -C $root status --porcelain=v1 --untracked-files=all -- ':(exclude)logs/qa_abi' 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw 'Cannot inspect Git worktree and index status.'
    }
    if ($gitStatus.Count -ne 0) {
        throw ('Checkout has staged, unstaged or untracked changes: ' + ($gitStatus -join '; '))
    }
    if ($Ticket -eq '1.1.55.86' -and $version -ne '1.1.55.86') {
        throw "VERSION.txt must be 1.1.55.86, found $version"
    }
    $case = [string]$caseByTicket[$Ticket]
    $testPattern = if ($Ticket -eq '1.1.55.89') {
        '^abi\.sdk_limits\.landscape_budget_sdk_only$'
    } elseif ($Ticket -eq '1.1.55.90') {
        '^abi\.package_root\.package_root_survives_create_call$'
    } elseif ($Ticket -eq '1.1.55.91') {
        '^abi\.canonical_reader\.canonical_lease_stale_release_retry$'
    } elseif ($Ticket -eq '1.1.55.92') {
        '^abi\.composition_policy\.exclusive_vs_inclusive_policy$'
    } elseif ($Ticket -eq '1.1.55.93') {
        '^abi\.layer_contract\.layer_contract_no_native_scene$'
    } elseif ($Ticket -eq '1.1.55.94') {
        '^abi\.wire_geometry\.wire_geometry_old_fixture_roundtrip$'
    } else {
        '^abi\.' + $case + '$'
    }
    $caseFile = Join-Path $root ("tests\abi\cases\" + $case + '.cpp')
    if (-not (Test-Path -LiteralPath $caseFile -PathType Leaf)) {
        throw "ABI case file is missing: $caseFile"
    }

    # Full native Windows configuration and both shipping outputs.
    Invoke-Recorded 'engine_configure' 'cmake' @(
        '-S', $root, '-B', $build, '-G', 'Visual Studio 17 2022', '-A', 'x64',
        '-DLABOVR_ABI_PACKAGE_ROOT_PROBE=ON')
    Invoke-Recorded 'engine_build' 'cmake' @(
        '--build', $build, '--config', 'Release', '--target',
        'LaboVRPackage', 'CandidateMemoryBudgetTest', '--parallel', [string]$Parallel)
    $products['LaboVR.exe'] = Get-BuiltProduct (Join-Path $build 'bin') 'LaboVR.exe'
    $products['LaboVRLaboratory.dll'] = Get-BuiltProduct (Join-Path $build 'module') 'LaboVRLaboratory.dll'
    $products['CandidateMemoryBudgetTest.exe'] = Get-BuiltProduct $build 'CandidateMemoryBudgetTest.exe'

    # The ABI harness configures without the engine, but remains MSVC x64.
    Invoke-Recorded 'abi_configure' 'cmake' @(
        '-S', (Join-Path $root 'tests\abi'), '-B', $abiBuild,
        '-G', 'Visual Studio 17 2022', '-A', 'x64')
    Invoke-Recorded 'abi_build' 'cmake' @(
        '--build', $abiBuild, '--config', 'Release',
        '--target', 'abi_contract_tests', '--parallel', [string]$Parallel)
    Invoke-Recorded 'native_memory' 'ctest' @(
        '--test-dir', $build, '-C', 'Release', '--output-on-failure',
        '--no-tests=error', '-R', '^candidate_memory_budget$')
    # The package-root proof must load this invocation's built laboratory,
    # not a DLL installed elsewhere on the creator's machine.
    $priorLabLibrary = [Environment]::GetEnvironmentVariable(
        'LABOVR_LABORATORY_LIBRARY', 'Process')
    try {
        if ($Ticket -eq '1.1.55.90') {
            $env:LABOVR_LABORATORY_LIBRARY = [string]$products['LaboVRLaboratory.dll'].path
        }
        Invoke-Recorded 'abi_ticket' 'ctest' @(
            '--test-dir', $abiBuild, '-C', 'Release', '--output-on-failure',
            '--no-tests=error', '-R', $testPattern)
    } finally {
        [Environment]::SetEnvironmentVariable(
            'LABOVR_LABORATORY_LIBRARY', $priorLabLibrary, 'Process')
    }

    # Startup/VR is not run by this command. An external creator-produced
    # capture may be attached, but absence is explicitly NOT evidence of a pass.
    if ($StartupReference) {
        if (-not (Test-Path -LiteralPath $StartupReference -PathType Leaf)) {
            throw "Missing creator startup capture: $StartupReference"
        }
        $capture = Join-Path $run ('startup_reference' + [IO.Path]::GetExtension($StartupReference))
        Copy-Item -LiteralPath $StartupReference -Destination $capture -ErrorAction Stop
        $startup = [ordered]@{
            status = 'creator_capture_attached'
            recorded_by = 'creator_only'
            path = $capture
            sha256 = (Get-FileHash -LiteralPath $capture -Algorithm SHA256).Hash
        }
    }
    $outcome = 'native_checks_passed'
} catch {
    $failure = $_.ToString()
    Write-Host ('ERROR: ' + $failure)
} finally {
    foreach ($config in @(
        @{ From = (Join-Path $build 'CMakeCache.txt'); To = 'engine_CMakeCache.txt' },
        @{ From = (Join-Path $abiBuild 'CMakeCache.txt'); To = 'abi_CMakeCache.txt' })) {
        if (Test-Path -LiteralPath $config.From -PathType Leaf) {
            Copy-Item -LiteralPath $config.From -Destination (Join-Path $run $config.To) -Force
        }
    }
    $manifest = [ordered]@{
        ticket = $Ticket
        requested_commit = $Commit
        version = $version
        platform = 'Windows MSVC x64 Release'
        abi_case = $caseByTicket[$Ticket]
        outcome = $outcome
        failure = $failure
        phases = $phases
        products = $products
        startup_reference = $startup
        run_directory = $run
    }
    $manifest | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $run 'result.json') -Encoding UTF8
}
if ($outcome -eq 'failed') { exit 1 }
exit 0
