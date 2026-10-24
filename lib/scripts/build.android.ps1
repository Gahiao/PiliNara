#Requires -Version 5.1
<#
.SYNOPSIS
    Local Android build for PiliPlus: version stamping, patches, APK/AAB, rename.

.DESCRIPTION
    Local counterpart of .github/workflows/build.yml (the "android" job). It does:

      1. version stamping - version from pubspec.yaml, build number from
                            "git rev-list --count HEAD", apk name gets the short
                            commit hash as a suffix (same as build.ps1 android)
      2. patches          - lib/scripts/patch.windows.ps1 -Platform android
      3. pub get          - unless -SkipPubGet
      4. flutter build    - apk --release --split-per-abi with the release defines,
                            or aab with -Target aab
      5. rename           - copies the outputs to dist\ as
                            PiliPlus_android_<version>_<abi>.apk

    Signing is picked up from android\key.properties when present; without it the
    Gradle script falls back to the debug key, so the APK still builds.

    ASCII only on purpose: Windows PowerShell 5.1 reads BOM-less scripts as ANSI.

.PARAMETER FlutterRoot
    Flutter SDK root. Defaults to $env:FLUTTER_ROOT, then the flutter on PATH.

.PARAMETER RepoRoot
    PiliPlus repository root. Defaults to the parent of lib\scripts.

.PARAMETER OutDir
    Where the renamed artifacts go. Default <repo>\dist.

.PARAMETER Target
    apk (default), aab, or both.

.PARAMETER Dev
    Build the dev variant (applicationIdSuffix .dev, no release defines),
    matching the pull_request build in CI.

.PARAMETER NoSplitAbi
    Build one universal APK instead of per-ABI APKs.

.PARAMETER BuildNumber
    Override the auto-computed build number.

.PARAMETER SkipPatch
    Do not apply the Flutter/pub-cache patches.

.PARAMETER SkipPubGet
    Do not run "flutter pub get".

.PARAMETER Clean
    Run "flutter clean" before building.

.PARAMETER NoVersionSuffix
    Do not append the commit hash to the version name.

.EXAMPLE
    .\build.android.ps1

.EXAMPLE
    .\build.android.ps1 -SkipPatch -Target both

.EXAMPLE
    .\build.android.ps1 -Dev -BuildNumber 1200
#>
[CmdletBinding()]
param(
    [string]$FlutterRoot,
    [string]$RepoRoot,
    [string]$OutDir,
    [ValidateSet('apk', 'aab', 'both')]
    [string]$Target = 'apk',
    [switch]$Dev,
    [switch]$DebugBuild,
    [switch]$NoSplitAbi,
    [string]$TargetPlatform,
    [switch]$Deploy,
    [string]$DeviceIp,
    [string]$AppId = 'com.example.piliplus',
    [int]$BuildNumber = 0,
    [switch]$SkipPatch,
    [switch]$SkipPubGet,
    [switch]$Clean,
    [switch]$NoVersionSuffix
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

    # -Echo streams the output live instead of buffering it in a temp file, so a
    # long "flutter build" does not look frozen. The last lines are still kept for
    # error reporting.
    if ($Echo) {
        $buffer = New-Object System.Collections.ArrayList
        $previousEap = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        Push-Location $WorkingDirectory
        try {
            & $Exe @Arguments 2>&1 | ForEach-Object {
                $lineText = "$_"
                [void]$buffer.Add($lineText)
                Write-Host $lineText
            }
            $code = $LASTEXITCODE
        }
        finally {
            Pop-Location
            $ErrorActionPreference = $previousEap
        }
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
        $streamed = ($buffer | Select-Object -Last 80) -join "`n"
        return [pscustomobject]@{ Code = $code; Output = $streamed }
    }

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

# ---------------------------------------------------------------------- main

$script:RepoRoot = ''
$started = Get-Date

try {
    Write-Step 'resolving paths'
    $script:RepoRoot = Resolve-RepoRoot -Given $RepoRoot
    $flutterDir = Resolve-FlutterRoot -Given $FlutterRoot
    $pubspecPath = Join-Path $script:RepoRoot 'pubspec.yaml'
    if (-not (Test-Path $pubspecPath)) { throw ("{0} does not look like the PiliPlus repository" -f $script:RepoRoot) }
    Write-Ok ("repo    : {0}" -f $script:RepoRoot)
    Write-Ok ("flutter : {0}" -f $flutterDir)

    if (-not $OutDir) { $OutDir = Join-Path $script:RepoRoot 'dist' }
    if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }
    Write-Ok ("output  : {0}" -f $OutDir)

    Write-Step 'collecting version info'
    $pubVersion = Read-PubspecVersion -PubspecPath $pubspecPath

    $commit = Invoke-External -Exe 'git' -Arguments @('rev-parse', 'HEAD') -WorkingDirectory $script:RepoRoot
    $commitHash = ''
    if ($commit.Code -eq 0) { $commitHash = $commit.Output.Trim() }
    if (-not $commitHash) { $commitHash = 'unknown' }
    $shortHash = $commitHash
    if ($commitHash.Length -gt 9) { $shortHash = $commitHash.Substring(0, 9) }

    $versionName = $pubVersion.Name
    if (-not $NoVersionSuffix) { $versionName = "{0}-{1}" -f $versionName, $shortHash }

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

    $buildTime = [int]([DateTimeOffset]::Now.ToUnixTimeSeconds())
    $fullVersion = "{0}+{1}" -f $versionName, $buildNumber

    Write-Ok ("version : {0}" -f $fullVersion)
    Write-Ok ("commit  : {0}" -f $commitHash)

    if ($Dev) {
        Write-Note 'dev variant: applicationIdSuffix .dev, release defines skipped'
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

    $keyProperties = Join-Path $script:RepoRoot 'android\key.properties'
    if (Test-Path $keyProperties) {
        Write-Ok 'android\key.properties found, APK will be release-signed'
    }
    else {
        Write-Note 'android\key.properties missing, Gradle falls back to the debug key'
    }

    if (-not $SkipPatch) {
        Write-Step 'applying patches (android)'
        $patcher = Join-Path $PSScriptRoot 'patch.windows.ps1'
        if (-not (Test-Path $patcher)) { throw ("patch script not found: {0}" -f $patcher) }
        $patchResult = Invoke-External -Exe 'powershell.exe' `
            -Arguments @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $patcher,
                         '-FlutterRoot', $flutterDir, '-Platform', 'android') `
            -WorkingDirectory $script:RepoRoot -Echo
        if ($patchResult.Code -ne 0) {
            $tail = ($patchResult.Output -split "`n" | Select-Object -Last 30) -join "`n"
            throw ("patch step failed:`n{0}" -f $tail)
        }
    }
    else {
        Write-Note 'patch step skipped (-SkipPatch)'
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

    $buildNumberArg = '--build-number=' + $buildNumber
    $nameArg = '--build-name=' + $pubVersion.Name
    $artifacts = @()

    $variantTag = ''
    if ($Dev) { $variantTag += '_dev' }
    if ($DebugBuild) { $variantTag += '_debug' }

    if ($DebugBuild -and $Target -ne 'apk') {
        Write-Note 'appbundle only exists for release, building apk instead'
        $Target = 'apk'
    }

    if ($Target -eq 'apk' -or $Target -eq 'both') {
        $buildType = 'release'
        if ($DebugBuild) { $buildType = 'debug' }

        Write-Step ("flutter build apk --{0}" -f $buildType)
        $buildArgs = @('build', 'apk', ('--' + $buildType), $nameArg, $buildNumberArg)

        # Debug builds are universal; splitting per ABI only saves release size.
        if (-not $DebugBuild -and -not $NoSplitAbi) { $buildArgs += '--split-per-abi' }
        if ($TargetPlatform) {
            $buildArgs += '--target-platform'
            $buildArgs += $TargetPlatform
        }

        if ($Dev) {
            $buildArgs += '--android-project-arg'
            $buildArgs += 'dev=1'
        }
        else {
            $buildArgs += '--dart-define-from-file=pili_release.json'
        }
        if (-not $SkipPubGet) { $buildArgs += '--no-pub' }

        $build = Invoke-External -Exe (Join-Path $flutterDir 'bin\flutter.bat') -Arguments $buildArgs -WorkingDirectory $script:RepoRoot -Echo
        if ($build.Code -ne 0) { throw ("flutter build apk failed:`n{0}" -f $build.Output) }

        $apkDir = Join-Path $script:RepoRoot 'build\app\outputs\flutter-apk'
        $apks = @(Get-ChildItem -Path $apkDir -Filter '*.apk' -File -ErrorAction SilentlyContinue)
        if ($apks.Count -eq 0) { throw ("no apk produced in {0}" -f $apkDir) }

        foreach ($apk in $apks) {
            $abi = 'universal'
            if ($apk.Name -match '^app-(.+)-release\.apk$') { $abi = $Matches[1] }
            elseif ($apk.Name -match '^app-(.+)-profile\.apk$') { $abi = $Matches[1] }
            elseif ($apk.Name -match '^app-(.+)-debug\.apk$') { $abi = $Matches[1] }

            # Only pick up the APKs that belong to this variant.
            $wanted = 'release'
            if ($DebugBuild) { $wanted = 'debug' }
            if ($apk.Name -notlike ("*-{0}.apk" -f $wanted)) { continue }

            $destName = "PiliPlus_android_{0}{1}_{2}.apk" -f $fullVersion, $variantTag, $abi
            $dest = Join-Path $OutDir $destName
            Copy-Item $apk.FullName $dest -Force
            $artifacts += $dest
            Write-Ok ("{0} ({1:N1} MB)" -f $dest, ((Get-Item $dest).Length / 1MB))
        }
    }

    if ($Target -eq 'aab' -or $Target -eq 'both') {
        Write-Step 'flutter build appbundle --release'
        $aabArgs = @('build', 'appbundle', '--release', $nameArg, $buildNumberArg)
        if (-not $Dev) { $aabArgs += '--dart-define-from-file=pili_release.json' }
        else { $aabArgs += '--android-project-arg'; $aabArgs += 'dev=1' }
        if (-not $SkipPubGet) { $aabArgs += '--no-pub' }

        $build = Invoke-External -Exe (Join-Path $flutterDir 'bin\flutter.bat') -Arguments $aabArgs -WorkingDirectory $script:RepoRoot -Echo
        if ($build.Code -ne 0) { throw ("flutter build appbundle failed:`n{0}" -f $build.Output) }

        $aab = Get-ChildItem -Path (Join-Path $script:RepoRoot 'build\app\outputs\bundle\release') -Filter '*.aab' -File -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if (-not $aab) { throw 'no aab produced' }
        $dest = Join-Path $OutDir ("PiliPlus_android_{0}.aab" -f $fullVersion)
        Copy-Item $aab.FullName $dest -Force
        $artifacts += $dest
        Write-Ok ("{0} ({1:N1} MB)" -f $dest, ((Get-Item $dest).Length / 1MB))
    }

    if ($Deploy) {
        Write-Step 'deploying over adb'

        $adbCandidates = @(
            (Join-Path $env:ANDROID_SDK_ROOT 'platform-tools\adb.exe'),
            (Join-Path $env:ANDROID_HOME 'platform-tools\adb.exe'),
            'E:\androidSDK\platform-tools\adb.exe',
            (Join-Path $env:LOCALAPPDATA 'Android\Sdk\platform-tools\adb.exe'))
        $adb = ''
        foreach ($candidate in $adbCandidates) {
            if ($candidate -and (Test-Path $candidate)) { $adb = $candidate; break }
        }
        if (-not $adb) {
            $adbCmd = Get-Command adb -ErrorAction SilentlyContinue
            if ($adbCmd) { $adb = $adbCmd.Source }
        }
        if (-not $adb) { throw 'adb not found; install Android platform-tools or set ANDROID_HOME' }
        Write-Ok ("adb: {0}" -f $adb)

        if ($DeviceIp) {
            Write-Note ("adb connect {0}" -f $DeviceIp)
            $connect = Invoke-External -Exe $adb -Arguments @('connect', $DeviceIp) -WorkingDirectory $script:RepoRoot -Echo
            if ($connect.Output -match 'cannot|failed|refused') {
                Write-Note ("connect failed: {0}" -f $connect.Output)
            }
        }

        $devicesOutput = (Invoke-External -Exe $adb -Arguments @('devices') -WorkingDirectory $script:RepoRoot).Output
        $readyDevice = ($devicesOutput -split "`n" | Where-Object { $_ -match '\sdevice$' } | Select-Object -First 1)

        if (-not $readyDevice) {
            Write-Host $devicesOutput -ForegroundColor DarkGray
            throw 'no device in "device" state; run adb pair / adb connect first, or pass -DeviceIp'
        }
        Write-Ok ("device: {0}" -f $readyDevice.Trim())

        $apkToInstall = $artifacts | Where-Object { $_ -match 'arm64' } | Select-Object -First 1
        if (-not $apkToInstall) { $apkToInstall = $artifacts | Select-Object -First 1 }
        if (-not $apkToInstall) { throw 'no apk to install' }

        $install = Invoke-External -Exe $adb -Arguments @('install', '-r', $apkToInstall) -WorkingDirectory $script:RepoRoot -Echo
        if ($install.Code -ne 0) { throw ("adb install failed:`n{0}" -f $install.Output) }

        $appIdReal = $AppId
        if ($Dev) { $appIdReal += '.dev' }
        Invoke-External -Exe $adb `
            -Arguments @('shell', 'monkey', '-p', $appIdReal, '-c', 'android.intent.category.LAUNCHER', '1') `
            -WorkingDirectory $script:RepoRoot | Out-Null
        Write-Ok ("launched {0}" -f $appIdReal)
    }

    Write-Step 'summary'
    Write-Ok ("version  : {0}" -f $fullVersion)
    foreach ($artifact in $artifacts) { Write-Ok ("artifact : {0}" -f $artifact) }
    Write-Ok ("elapsed  : {0:N1} min" -f ((Get-Date) - $started).TotalMinutes)

    Write-Host ''
    Write-Host 'Build finished.' -ForegroundColor Green
}
catch {
    $lineNo = $_.InvocationInfo.ScriptLineNumber
    Write-Bad ("`nFAILED: {0}" -f $_.Exception.Message)
    if ($lineNo) { Write-Bad ("at line {0}" -f $lineNo) }
    Write-Bad 'hints:'
    Write-Host '  - a JDK 17 is required: flutter doctor -v must show the Android toolchain'
    Write-Host '  - run with -SkipPatch when the SDK/pub cache is already patched'
    Write-Host '  - run with -Clean when the Gradle build directory looks stale'
    exit 1
}
