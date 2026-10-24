#Requires -Version 5.1
<#
.SYNOPSIS
    Full local Windows build for PiliPlus: version stamping, patches, build, package.

.DESCRIPTION
    Local counterpart of .github/workflows/win_x64.yml. It performs:

      1. version stamping   - reads version from pubspec.yaml, build number from
                              "git rev-list --count HEAD", writes pili_release.json
      2. patches            - calls lib/scripts/patch.windows.ps1 -Platform windows
      3. pub get            - unless -SkipPubGet
      4. flutter build      - windows release with --build-name/--build-number and
                              --dart-define-from-file=pili_release.json
      5. packaging          - copies the runner output to dist\ and zips a portable
                              package, optionally builds the Inno Setup installer
                              through fastforge (-Installer)

    ASCII only on purpose: Windows PowerShell 5.1 reads BOM-less scripts as ANSI,
    and non-ASCII text there can break parsing.

.PARAMETER FlutterRoot
    Flutter SDK root. Defaults to $env:FLUTTER_ROOT, then the flutter on PATH.

.PARAMETER RepoRoot
    PiliPlus repository root. Defaults to the parent of lib\scripts.

.PARAMETER OutDir
    Output directory for the packaged artifacts. Default <repo>\dist.

.PARAMETER BuildNumber
    Override the auto-computed build number (git commit count).

.PARAMETER SkipPatch
    Do not apply the Flutter/pub-cache patches (they are expected to be applied).

.PARAMETER SkipPubGet
    Do not run "flutter pub get".

.PARAMETER Clean
    Run "flutter clean" before building.

.PARAMETER Installer
    Also build the Inno Setup installer with fastforge (must be on PATH).

.PARAMETER NoZip
    Skip the portable zip.

.EXAMPLE
    .\build.windows.ps1

.EXAMPLE
    .\build.windows.ps1 -SkipPatch -Installer

.EXAMPLE
    .\build.windows.ps1 -Clean -BuildNumber 1200
#>
[CmdletBinding()]
param(
    [string]$FlutterRoot,
    [string]$RepoRoot,
    [string]$OutDir,
    [int]$BuildNumber = 0,
    [switch]$SkipPatch,
    [switch]$SkipPubGet,
    [switch]$Clean,
    [switch]$Installer,
    [switch]$NewLibmpv,
    [switch]$RestoreRepo,
    [switch]$NoZip
)

$ErrorActionPreference = 'Stop'

function Write-Step { param([string]$Message) Write-Host "`n==> $Message" -ForegroundColor Cyan }
function Write-Ok { param([string]$Message) Write-Host "    $Message" -ForegroundColor Green }
function Write-Note { param([string]$Message) Write-Host "    $Message" -ForegroundColor Yellow }
function Write-Bad { param([string]$Message) Write-Host "    $Message" -ForegroundColor Red }

function Invoke-External {
    param(
        [Parameter(Mandatory = $true)][string]$Exe,
        [string[]]$Arguments = @(),
        [Parameter(Mandatory = $true)][string]$WorkingDirectory,
        [switch]$Echo
    )

    $tmp = [System.IO.Path]::GetTempFileName()
    $line = 'cd /d "' + $WorkingDirectory + '" && "' + $Exe + '"'
    foreach ($arg in $Arguments) {
        $line += ' "' + ($arg -replace '"', '""') + '"'
    }
    $line += ' > "' + $tmp + '" 2>&1'

    Write-Host ("    > {0} {1}" -f (Split-Path -Leaf $Exe), ($Arguments -join ' ')) -ForegroundColor DarkGray
    cmd /c $line | Out-Null
    $code = $LASTEXITCODE

    $text = ''
    if (Test-Path $tmp) {
        $text = Get-Content -Path $tmp -Raw -ErrorAction SilentlyContinue
        if ($null -eq $text) { $text = '' }
    }
    Remove-Item $tmp -Force -ErrorAction SilentlyContinue

    $output = "$text"
    if ($Echo -and $output) { Write-Host $output -ForegroundColor DarkGray }
    return [pscustomobject]@{ Code = $code; Output = $output.TrimEnd() }
}

function Resolve-RepoRoot {
    param([string]$Given)
    if ($Given) { return [System.IO.Path]::GetFullPath($Given) }
    if ($PSScriptRoot) { return [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..')) }
    if ($env:GITHUB_WORKSPACE) { return [System.IO.Path]::GetFullPath($env:GITHUB_WORKSPACE) }
    throw 'cannot locate the repository root, pass -RepoRoot'
}

function Resolve-FlutterRoot {
    param([string]$Given)

    $candidates = @()
    if ($Given) { $candidates += $Given }
    if ($env:FLUTTER_ROOT) { $candidates += $env:FLUTTER_ROOT }

    $cmd = Get-Command flutter -ErrorAction SilentlyContinue
    if ($cmd -and $cmd.Source) {
        $candidates += (Split-Path -Parent (Split-Path -Parent $cmd.Source))
    }

    foreach ($candidate in $candidates) {
        if (-not $candidate) { continue }
        try { $full = [System.IO.Path]::GetFullPath($candidate) } catch { continue }
        if (Test-Path (Join-Path $full 'bin\flutter.bat')) { return $full }
    }
    throw 'cannot locate the Flutter SDK, pass -FlutterRoot (e.g. C:\Users\fk\flutter)'
}

function Read-PubspecVersion {
    param([string]$PubspecPath)

    $text = Get-Content -Path $PubspecPath -Raw
    if ($text -notmatch '(?m)^version:\s*(\S+)\s*$') {
        throw "no version field in $PubspecPath"
    }
    $raw = $Matches[1]

    $name = $raw
    $suffix = 1
    if ($raw -match '^(.+?)\+(\d+)$') {
        $name = $Matches[1]
        $suffix = [int]$Matches[2]
    }
    return [pscustomobject]@{ Raw = $raw; Name = $name; Suffix = $suffix }
}

function Read-RequiredFlutter {
    param([string]$PubspecPath)

    # Line-based scan on purpose: the previous single regex used nested lazy
    # quantifiers over multi-line text and could backtrack for minutes on a
    # normal pubspec.yaml, which looked like the build hanging.
    $inEnvironment = $false
    foreach ($line in (Get-Content -Path $PubspecPath)) {
        if ($line -match '^environment:\s*$') {
            $inEnvironment = $true
            continue
        }
        if (-not $inEnvironment) { continue }
        if ($line -match '^\S') { break }
        if ($line -match '^\s+flutter:\s*"?([0-9][^"\s]*)"?\s*$') {
            return $Matches[1]
        }
    }
    return ''
}

# ---------------------------------------------------------------------- main

$script:RepoRoot = ''
$started = Get-Date

try {
    Write-Step 'resolving paths'
    $script:RepoRoot = Resolve-RepoRoot -Given $RepoRoot
    $flutterDir = Resolve-FlutterRoot -Given $FlutterRoot
    $pubspecPath = Join-Path $script:RepoRoot 'pubspec.yaml'
    if (-not (Test-Path $pubspecPath)) { throw ("{0} does not look like the PiliPlus repository" -f $script:RepoRoot) }
    $repoRelative = $script:RepoRoot
    Write-Ok ("repo    : {0}" -f $script:RepoRoot)
    Write-Ok ("flutter : {0}" -f $flutterDir)

    if (-not $OutDir) { $OutDir = Join-Path $script:RepoRoot 'dist' }
    if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }
    Write-Ok ("output  : {0}" -f $OutDir)

    Write-Step 'collecting version info'
    $pubVersion = Read-PubspecVersion -PubspecPath $pubspecPath
    $versionName = $pubVersion.Name

    if ($BuildNumber -gt 0) {
        $buildNumber = $BuildNumber
        Write-Note ("build number from -BuildNumber: {0}" -f $buildNumber)
    }
    else {
        $rev = Invoke-External -Exe 'git' -Arguments @('rev-list', '--count', 'HEAD') -WorkingDirectory $script:RepoRoot
        if ($rev.Code -eq 0 -and $rev.Output.Trim() -match '^\d+$') {
            $buildNumber = [int]$rev.Output.Trim()
            Write-Note ("build number from git commit count: {0}" -f $buildNumber)
        }
        else {
            $buildNumber = $pubVersion.Suffix
            Write-Note ("build number from pubspec: {0}" -f $buildNumber)
        }
    }

    $commit = Invoke-External -Exe 'git' -Arguments @('rev-parse', 'HEAD') -WorkingDirectory $script:RepoRoot
    $commitHash = ''
    if ($commit.Code -eq 0) { $commitHash = $commit.Output.Trim() }
    if (-not $commitHash) { $commitHash = 'unknown' }

    $buildTime = [int]([DateTimeOffset]::Now.ToUnixTimeSeconds())
    $fullVersion = "{0}+{1}" -f $versionName, $buildNumber

    Write-Ok ("version : {0}" -f $fullVersion)
    Write-Ok ("commit  : {0}" -f $commitHash)

    $requiredFlutter = Read-RequiredFlutter -PubspecPath $pubspecPath
    if ($requiredFlutter) {
        # Read bin\cache\flutter.version.json instead of spawning "flutter --version":
        # that command can block for minutes (startup lock, tool rebuild) and its
        # output is captured, so the console would look frozen.
        $actualFlutter = ''
        $versionFile = Join-Path $flutterDir 'bin\cache\flutter.version.json'
        if (Test-Path $versionFile) {
            try {
                $versionJson = Get-Content -Path $versionFile -Raw | ConvertFrom-Json
                if ($versionJson.frameworkVersion) { $actualFlutter = [string]$versionJson.frameworkVersion }
            }
            catch {
                Write-Note 'cannot parse bin\cache\flutter.version.json, skipping the version check'
            }
        }

        if (-not $actualFlutter) {
            Write-Note ("pubspec expects Flutter {0}; run flutter --version once to refresh the cache" -f $requiredFlutter)
        }
        elseif ($actualFlutter -ne $requiredFlutter) {
            Write-Note ("pubspec expects Flutter {0}, SDK is {1}; patches may not apply" -f $requiredFlutter, $actualFlutter)
        }
        else {
            Write-Ok ("flutter version matches pubspec ({0})" -f $requiredFlutter)
        }
    }

    Write-Step 'writing pili_release.json'
    $release = @{
        'pili.name' = $versionName
        'pili.code' = $buildNumber
        'pili.hash' = $commitHash
        'pili.time' = $buildTime
    }
    $releasePath = Join-Path $script:RepoRoot 'pili_release.json'
    $json = ($release | ConvertTo-Json -Compress)
    [System.IO.File]::WriteAllText($releasePath, $json, (New-Object System.Text.UTF8Encoding($false)))
    Write-Ok ("{0} -> {1}" -f $releasePath, $json)

    if (-not $SkipPatch) {
        Write-Step 'applying patches'
        $patcher = Join-Path $PSScriptRoot 'patch.windows.ps1'
        if (-not (Test-Path $patcher)) { throw ("patch script not found: {0}" -f $patcher) }
        $patchResult = Invoke-External -Exe 'powershell.exe' `
            -Arguments @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $patcher,
                         '-FlutterRoot', $flutterDir, '-Platform', 'windows') `
            -WorkingDirectory $script:RepoRoot -Echo
        if ($patchResult.Code -ne 0) {
            $tail = ($patchResult.Output -split "`n" | Select-Object -Last 30) -join "`n"
            throw ("patch step failed:`n{0}" -f $tail)
        }
    }
    else {
        Write-Note 'patch step skipped (-SkipPatch)'
    }

    if ($NewLibmpv) {
        Write-Step 'applying newlibmpv patch'
        $libmpvPatch = Join-Path $script:RepoRoot 'lib\scripts\newlibmpv.patch'
        if (-not (Test-Path $libmpvPatch)) { throw ("newlibmpv patch not found: {0}" -f $libmpvPatch) }

        $alreadyApplied = Invoke-External -Exe 'git' -Arguments @('apply', '--reverse', '--check', $libmpvPatch) -WorkingDirectory $script:RepoRoot
        if ($alreadyApplied.Code -eq 0) {
            Write-Note 'newlibmpv patch already applied, skipping'
        }
        else {
            $apply = Invoke-External -Exe 'git' -Arguments @('apply', '--whitespace=nowarn', $libmpvPatch) -WorkingDirectory $script:RepoRoot
            if ($apply.Code -ne 0) { throw ("git apply lib/scripts/newlibmpv.patch failed:`n{0}" -f $apply.Output) }
            Write-Ok 'covered: player code + pubspec (media_kit ref native -> upstream)'
        }
    }

    if ($Clean) {
        Write-Step 'flutter clean'
        $cleanResult = Invoke-External -Exe (Join-Path $flutterDir 'bin\flutter.bat') -Arguments @('clean') -WorkingDirectory $script:RepoRoot -Echo
        if ($cleanResult.Code -ne 0) { throw ("flutter clean failed:`n{0}" -f $cleanResult.Output) }
    }

    if (-not $SkipPubGet) {
        Write-Step 'flutter pub get'
        $pubGet = Invoke-External -Exe (Join-Path $flutterDir 'bin\flutter.bat') -Arguments @('pub', 'get') -WorkingDirectory $script:RepoRoot -Echo
        if ($pubGet.Code -ne 0) { throw ("flutter pub get failed:`n{0}" -f $pubGet.Output) }
    }
    else {
        Write-Note 'pub get skipped (-SkipPubGet)'
    }

    Write-Step 'flutter build windows --release'
    $buildArgs = @('build', 'windows', '--release',
        ('--build-name=' + $versionName),
        ('--build-number=' + $buildNumber),
        '--dart-define-from-file=pili_release.json')
    if (-not $SkipPubGet) { $buildArgs += '--no-pub' }

    $build = Invoke-External -Exe (Join-Path $flutterDir 'bin\flutter.bat') -Arguments $buildArgs -WorkingDirectory $script:RepoRoot -Echo
    if ($build.Code -ne 0) { throw ("flutter build failed:`n{0}" -f $build.Output) }

    $runnerDir = Join-Path $script:RepoRoot 'build\windows\x64\runner\Release'
    if (-not (Test-Path $runnerDir)) { throw ("build output not found: {0}" -f $runnerDir) }

    $exe = Get-ChildItem -Path $runnerDir -Filter '*.exe' -File | Select-Object -First 1
    if (-not $exe) { throw ("no .exe in {0}" -f $runnerDir) }
    Write-Ok ("executable: {0}" -f $exe.FullName)

    $variant = ''
    if ($NewLibmpv) { $variant = '_NewLibmpv' }

    $portableDir = Join-Path $OutDir ("PiliPlus-Win" + $variant)
    if (Test-Path $portableDir) { Remove-Item $portableDir -Recurse -Force }
    New-Item -ItemType Directory -Path $portableDir -Force | Out-Null
    Copy-Item -Path (Join-Path $runnerDir '*') -Destination $portableDir -Recurse -Force
    Write-Ok ("portable files: {0}" -f $portableDir)

    $zipPath = ''
    if (-not $NoZip) {
        Write-Step 'packaging portable zip'
        $zipName = "PiliPlus_windows_{0}_x64{1}_portable.zip" -f $fullVersion, $variant
        $zipPath = Join-Path $OutDir $zipName
        if (Test-Path $zipPath) { Remove-Item $zipPath -Force }
        Compress-Archive -Path $portableDir -DestinationPath $zipPath -CompressionLevel Optimal -Force
        Write-Ok ("zip: {0} ({1:N1} MB)" -f $zipPath, ((Get-Item $zipPath).Length / 1MB))
    }

    $installerPath = ''
    if ($Installer) {
        Write-Step 'building Inno Setup installer (fastforge)'
        $fastforgeExe = ''
        $fastforgeCmd = Get-Command fastforge -ErrorAction SilentlyContinue
        if ($fastforgeCmd) {
            $fastforgeExe = $fastforgeCmd.Source
        }
        else {
            foreach ($candidate in @(
                    (Join-Path $env:LOCALAPPDATA 'Pub\Cache\bin\fastforge.bat'),
                    (Join-Path $HOME '.pub-cache\bin\fastforge.bat'),
                    (Join-Path $env:LOCALAPPDATA 'Pub\Cache\bin\fastforge.exe'))) {
                if (Test-Path $candidate) { $fastforgeExe = $candidate; break }
            }
        }

        if (-not $fastforgeExe) {
            Write-Note 'fastforge not found on PATH or in the pub global bin directory'
            Write-Note 'install it with: dart pub global activate fastforge'
        }
        else {
            $innoDir = ''
            foreach ($root in @('C:\Program Files (x86)', 'C:\Program Files', (Join-Path $env:LOCALAPPDATA 'Programs'))) {
                if (-not (Test-Path $root)) { continue }
                $foundDir = Get-ChildItem -Path $root -Directory -Filter 'Inno Setup*' -ErrorAction SilentlyContinue |
                    Where-Object { Test-Path (Join-Path $_.FullName 'ISCC.exe') } |
                    Select-Object -First 1
                if ($foundDir) { $innoDir = $foundDir.FullName; break }
            }

            if (-not $innoDir) {
                Write-Note 'Inno Setup not found; fastforge will probably fail to build the installer'
            }
            else {
                Write-Ok ("Inno Setup : {0}" -f $innoDir)
                $env:Path = "$env:Path;$innoDir"

                $innoLang = Join-Path $innoDir 'Languages\ChineseSimplified.isl'
                $repoIsl = Join-Path $script:RepoRoot 'windows\packaging\exe\ChineseSimplified.isl'
                if ((Test-Path $repoIsl) -and -not (Test-Path $innoLang)) {
                    try {
                        New-Item -ItemType Directory -Path (Split-Path $innoLang -Parent) -Force | Out-Null
                        Copy-Item -Path $repoIsl -Destination $innoLang -Force -ErrorAction Stop
                        Write-Ok 'installed ChineseSimplified.isl for Inno Setup'
                    }
                    catch {
                        Write-Note 'could not copy ChineseSimplified.isl (needs admin); installer may fall back to English'
                    }
                }
            }

            $pkg = Invoke-External -Exe $fastforgeExe `
                -Arguments @('package', '--platform', 'windows', '--targets', 'exe', '--skip-clean',
                             ('--flutter-build-args=dart-define-from-file=pili_release.json,no-pub')) `
                -WorkingDirectory $script:RepoRoot -Echo
            if ($pkg.Code -ne 0) {
                Write-Note 'fastforge failed; the portable package above is still valid'
            }
            else {
                $setup = Get-ChildItem -Path (Join-Path $script:RepoRoot 'dist') -Filter '*.exe' -File -Recurse -ErrorAction SilentlyContinue |
                    Sort-Object LastWriteTime -Descending | Select-Object -First 1
                if ($setup) {
                    $setupName = [System.IO.Path]::GetFileNameWithoutExtension($setup.Name) + $variant + '.exe'
                    $installerPath = Join-Path $OutDir $setupName
                    if ($setup.FullName -ne $installerPath) { Copy-Item $setup.FullName $installerPath -Force }
                    Write-Ok ("installer: {0}" -f $installerPath)
                }
                else {
                    Write-Note 'fastforge reported success but no .exe was found in dist'
                }
            }
        }
    }

    if ($RestoreRepo -and $NewLibmpv) {
        Write-Step 'restoring repository files'
        foreach ($file in @('pubspec.yaml', 'pubspec.lock', 'lib/plugin/pl_player/widgets/mpv_convert_webp.dart')) {
            Invoke-External -Exe 'git' -Arguments @('checkout', '--', $file) -WorkingDirectory $script:RepoRoot | Out-Null
        }
        Write-Ok 'newlibmpv changes reverted'
    }

    Write-Step 'summary'
    Write-Ok ("version  : {0}" -f $fullVersion)
    Write-Ok ("repo     : {0}" -f $repoRelative)
    Write-Ok ("runner   : {0}" -f $runnerDir)
    Write-Ok ("portable : {0}" -f $portableDir)
    if ($zipPath) { Write-Ok ("zip      : {0}" -f $zipPath) }
    if ($installerPath) { Write-Ok ("setup    : {0}" -f $installerPath) }
    Write-Ok ("elapsed  : {0:N1} min" -f ((Get-Date) - $started).TotalMinutes)

    Write-Host ''
    Write-Host 'Build finished.' -ForegroundColor Green
}
catch {
    $lineNo = $_.InvocationInfo.ScriptLineNumber
    Write-Bad ("`nFAILED: {0}" -f $_.Exception.Message)
    if ($lineNo) { Write-Bad ("at line {0}" -f $lineNo) }
    Write-Bad 'hints:'
    Write-Host '  - Visual Studio "Desktop development with C++" is required for flutter build windows'
    Write-Host '  - run with -SkipPatch when the SDK/pub cache is already patched'
    Write-Host '  - run with -Clean when the build directory looks stale'
    exit 1
}
