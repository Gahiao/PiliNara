#Requires -Version 5.1
<#
.SYNOPSIS
    Apply the PiliPlus patches to a local Flutter SDK and pub cache on Windows.

.DESCRIPTION
    Windows-local version of lib/scripts/patch.ps1. The original script assumes
    GitHub Actions, where GITHUB_WORKSPACE and FLUTTER_ROOT are already set by
    actions/checkout and subosito/flutter-action. When run by hand on a desktop
    those variables are missing, so this variant:

      * derives the repository root from its own location ($PSScriptRoot\..\..)
      * resolves FLUTTER_ROOT from -FlutterRoot, $env:FLUTTER_ROOT or PATH
      * resolves the pub cache from $env:PUB_CACHE or %LOCALAPPDATA%\Pub\Cache
      * normalizes patch files to LF in a temp copy instead of editing the repo
      * verifies every patch exists before touching anything
      * prints the real git error when a patch fails to apply

    Everything runs in ASCII only: Windows PowerShell 5.1 reads BOM-less scripts
    as ANSI, and non-ASCII text there can break parsing.

.PARAMETER Platform
    Target platform: windows (default), android, ios, linux or macos.

.PARAMETER RepoRoot
    PiliPlus repository root. Defaults to the parent of lib\scripts.

.PARAMETER FlutterRoot
    Flutter SDK root. Defaults to $env:FLUTTER_ROOT, then the flutter on PATH.

.PARAMETER SkipPubGet
    Do not run "flutter pub get" before patching the pub cache packages.

.PARAMETER KeepLineEndings
    Use patch files exactly as stored; skip the CRLF -> LF normalization.

.PARAMETER ResetFlutter
    Run "git reset --hard" in the Flutter SDK before patching. Use this when a
    previous run already applied the patches and you want a clean start.

.PARAMETER DryRun
    Only resolve paths, check that the patches exist and print the plan.

.EXAMPLE
    .\patch.windows.ps1

.EXAMPLE
    .\patch.windows.ps1 -Platform android -FlutterRoot C:\Users\fk\flutter

.EXAMPLE
    .\patch.windows.ps1 -ResetFlutter -Platform windows
#>
[CmdletBinding()]
param(
    [string]$Platform = 'windows',
    [string]$RepoRoot,
    [string]$FlutterRoot,
    [switch]$SkipPubGet,
    [switch]$SkipFlutterPatches,
    [switch]$KeepLineEndings,
    [switch]$ResetFlutter,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

function Write-Step { param([string]$Message) Write-Host "`n==> $Message" -ForegroundColor Cyan }
function Write-Ok { param([string]$Message) Write-Host "    $Message" -ForegroundColor Green }
function Write-Note { param([string]$Message) Write-Host "    $Message" -ForegroundColor Yellow }
function Write-Bad { param([string]$Message) Write-Host "    $Message" -ForegroundColor Red }

# Runs an external command and captures stdout+stderr plus the exit code.
# cmd.exe redirection is used on purpose: PowerShell 5.1 swallows or promotes
# native stderr in ways that depend on $ErrorActionPreference.
function Invoke-External {
    param(
        [Parameter(Mandatory = $true)][string]$Exe,
        [string[]]$Arguments = @(),
        [Parameter(Mandatory = $true)][string]$WorkingDirectory
    )

    $tmp = [System.IO.Path]::GetTempFileName()
    $line = 'cd /d "' + $WorkingDirectory + '" && "' + $Exe + '"'
    foreach ($arg in $Arguments) {
        $line += ' "' + ($arg -replace '"', '""') + '"'
    }
    $line += ' > "' + $tmp + '" 2>&1'

    cmd /c $line | Out-Null
    $code = $LASTEXITCODE

    $text = ''
    if (Test-Path $tmp) {
        $text = Get-Content -Path $tmp -Raw -ErrorAction SilentlyContinue
        if ($null -eq $text) { $text = '' }
    }
    Remove-Item $tmp -Force -ErrorAction SilentlyContinue

    # "$null" is guaranteed to produce an empty string, unlike a cast on a null
    # value in some PowerShell 5.1 edge cases.
    $outText = "$text"
    return [pscustomobject]@{ Code = $code; Output = $outText.TrimEnd() }
}

function Resolve-RepoRoot {
    param([string]$Given)

    if ($Given) { return [System.IO.Path]::GetFullPath($Given) }
    if ($PSScriptRoot) {
        return [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
    }
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

function Get-PubCacheRoots {
    $roots = @()
    if ($env:PUB_CACHE) { $roots += $env:PUB_CACHE }
    if ($env:LOCALAPPDATA) { $roots += (Join-Path $env:LOCALAPPDATA 'Pub\Cache') }
    if ($HOME) { $roots += (Join-Path $HOME '.pub-cache') }
    return @($roots | Where-Object { $_ } | Select-Object -Unique)
}

function Find-PubPackage {
    param([Parameter(Mandatory = $true)][string]$Prefix)

    # Packages live under <root>\hosted\<registry>\<name>-<version>. The registry
    # folder is named after the host: pub.dev for the default, but e.g.
    # pub.flutter-io.cn when PUB_HOSTED_URL points at a mirror.
    foreach ($root in $script:PubCacheRoots) {
        $hosted = Join-Path $root 'hosted'
        if (-not (Test-Path $hosted)) { continue }
        foreach ($registry in Get-ChildItem -Path $hosted -Directory -ErrorAction SilentlyContinue) {
            $found = Get-ChildItem -Path $registry.FullName -Directory -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -like ("{0}-*" -f $Prefix) } |
                Select-Object -Last 1
            if ($found) { return $found }
        }
    }
    return $null
}

# Returns a path to a patch file with LF line endings. The repository copy is
# never modified: a normalized copy is written to %TEMP% when needed.
function Get-LfPatch {
    param([string]$Path)

    if ($KeepLineEndings) { return $Path }

    $bytes = [System.IO.File]::ReadAllBytes($Path)
    if (-not ($bytes -contains [byte]13)) { return $Path }

    $text = [System.Text.Encoding]::UTF8.GetString($bytes)
    $text = $text -replace "`r`n", "`n"

    $tmp = Join-Path $env:TEMP ('pilipatch-' + [guid]::NewGuid().ToString('N') + '.patch')
    [System.IO.File]::WriteAllText($tmp, $text, (New-Object System.Text.UTF8Encoding($false)))
    if ($null -eq $script:TempPatches) {
        $script:TempPatches = New-Object System.Collections.ArrayList
    }
    [void]$script:TempPatches.Add($tmp)
    return $tmp
}

function Apply-Patch {
    param(
        [Parameter(Mandatory = $true)][string]$RelativePath,
        [Parameter(Mandatory = $true)][string]$TargetDirectory
    )

    $full = Join-Path $script:RepoRoot (($RelativePath -replace '/', '\'))
    if (-not (Test-Path $full)) { throw ("patch not found: {0}" -f $full) }

    Write-Note ("apply {0}" -f $RelativePath)
    if ($DryRun) { return }

    $source = Get-LfPatch -Path $full

    $result = Invoke-External -Exe 'git' -Arguments @('apply', '--whitespace=nowarn', $source) -WorkingDirectory $TargetDirectory
    if ($result.Code -ne 0) {
        # A failed forward apply usually means the patch is already in place
        # (this script was run twice). Probe with a reverse check first.
        $reverse = Invoke-External -Exe 'git' -Arguments @('apply', '--reverse', '--check', $source) -WorkingDirectory $TargetDirectory
        if ($reverse.Code -eq 0) {
            Write-Note ("{0} already applied, skipping" -f $RelativePath)
            return
        }

        Write-Bad ("git apply failed (exit {0})" -f $result.Code)
        if ($result.Output) { Write-Host $result.Output -ForegroundColor DarkGray }
        throw ("failed to apply {0} in {1}" -f $RelativePath, $TargetDirectory)
    }

    Write-Ok ("{0} applied" -f $RelativePath)
}

function Invoke-Preflight {
    param([string[]]$RelativePaths)

    $missing = @()
    foreach ($relative in $RelativePaths) {
        $full = Join-Path $script:RepoRoot (($relative -replace '/', '\'))
        if (-not (Test-Path $full)) { $missing += $relative }
    }
    if ($missing.Count -gt 0) {
        Write-Bad 'missing patch files:'
        foreach ($item in $missing) { Write-Host ("  - {0}" -f $item) }
        throw 'preflight failed, nothing was applied'
    }
    Write-Ok ("{0} patch file(s) present" -f $RelativePaths.Count)
}

# --------------------------------------------------------------- patch lists

$BottomSheetAndroidPatch = 'lib/scripts/bottom_sheet_android.patch'
$BottomSheetIOSFlutterPatch = 'lib/scripts/bottom_sheet_ios_flutter.patch'
$BottomSheetIOSPiliPlusPatch = 'lib/scripts/bottom_sheet_ios_piliplus.patch'
$ScrollViewPatch = 'lib/scripts/scroll_view.patch'
$TextSelectionPatch = 'lib/scripts/text_selection.patch'
$NavigatorPatch = 'lib/scripts/navigator.patch'
$ImageAnimPatch = 'lib/scripts/image_anim.patch'
$LayoutBuilderPatch = 'lib/scripts/layout_builder.patch'
$NavigationDrawerPatch = 'lib/scripts/navigation_drawer.patch'
$PopupMenuPatch = 'lib/scripts/popup_menu.patch'
$FABPatch = 'lib/scripts/fab.patch'
$SelectableRegionPatch = 'lib/scripts/selectable_region.patch'
$EditableTextPatch = 'lib/scripts/editable_text.patch'
$TextFieldPatch = 'lib/scripts/text_field.patch'
$ScrollPositionPatch = 'lib/scripts/scroll_position.patch'
$ScrollablePatch = 'lib/scripts/scrollable.patch'
$ScaffoldPatch = 'lib/scripts/scaffold.patch'
$ScrollableGesturePatch = 'lib/scripts/scrollable_gesture.patch'
$DraggableScrollableSheetPatch = 'lib/scripts/draggable_scrollable_sheet.patch'
$TextPatch = 'lib/scripts/text.patch'
$TextPainterPatch = 'lib/scripts/text_painter.patch'
$SliverPatch = 'lib/scripts/sliver.patch'
$RefreshIndicatorPatch = 'lib/scripts/refresh_indicator.patch'
$NullSafetySelectableRegionPatch = 'lib/scripts/null_safety_for_selectable_region.patch'
$ModalBarrierPatch = 'lib/scripts/modal_barrier.patch'
$MouseCursorPatch = 'lib/scripts/mouse_cursor.patch'
$GeetestIOSPatch = 'lib/scripts/geetest_ios.patch'
$DoubleTapGesturePatch = 'lib/scripts/double_tap_gesture.patch'

$patches = @(
    $ModalBarrierPatch, $TextSelectionPatch, $MouseCursorPatch,
    $ImageAnimPatch, $LayoutBuilderPatch, $NavigationDrawerPatch,
    $PopupMenuPatch, $FABPatch, $NullSafetySelectableRegionPatch,
    $SelectableRegionPatch, $EditableTextPatch, $TextFieldPatch,
    $ScrollPositionPatch, $ScrollablePatch, $ScrollableGesturePatch,
    $DraggableScrollableSheetPatch, $ScaffoldPatch, $TextPatch,
    $TextPainterPatch, $SliverPatch, $RefreshIndicatorPatch,
    $DoubleTapGesturePatch
)

$iosPrePatches = @()

$BottomSheetAndroidPatchMaterial = 'lib/scripts/material/bottom_sheet_android.patch'
$BottomSheetIOSFlutterMaterialPatchMaterial = 'lib/scripts/material/bottom_sheet_ios_flutter_material.patch'
$ModalBarrierPatchMaterial = 'lib/scripts/material/modal_barrier_material.patch'
$NavigationDrawerPatchMaterial = 'lib/scripts/material/navigation_drawer.patch'
$PopupMenuPatchMaterial = 'lib/scripts/material/popup_menu.patch'
$FABPatchMaterial = 'lib/scripts/material/fab.patch'
$TextFieldPatchMaterial = 'lib/scripts/material/text_field.patch'
$ScaffoldPatchMaterial = 'lib/scripts/material/scaffold.patch'
$RefreshIndicatorPatchMaterial = 'lib/scripts/material/refresh_indicator.patch'
$TabsPatchMaterial = 'lib/scripts/material/tabs.patch'

$patchesMaterial = @(
    $ModalBarrierPatchMaterial, $NavigationDrawerPatchMaterial, $PopupMenuPatchMaterial,
    $FABPatchMaterial, $TextFieldPatchMaterial, $ScaffoldPatchMaterial,
    $RefreshIndicatorPatchMaterial, $TabsPatchMaterial
)

$BottomSheetIOSFlutterPatchCupertino = 'lib/scripts/cupertino/bottom_sheet_ios_flutter.patch'
$patchesCupertino = @()

# ------------------------------------------------------------------ platform

$platformName = $Platform.ToLower()
switch ($platformName) {
    'ios' {
        $iosPrePatches += $BottomSheetIOSPiliPlusPatch
        $iosPrePatches += $GeetestIOSPatch
        $patches += $ScrollViewPatch
        $patches += $BottomSheetIOSFlutterPatch
        $patches += $NavigatorPatch
        $patchesMaterial += $BottomSheetIOSFlutterMaterialPatchMaterial
        $patchesCupertino += $BottomSheetIOSFlutterPatchCupertino
    }
    'android' {
        $patches += $BottomSheetAndroidPatch
        $patches += $ScrollViewPatch
        $patches += $NavigatorPatch
        $patchesMaterial += $BottomSheetAndroidPatchMaterial
    }
    'linux' { }
    'macos' { }
    'windows' { }
    default { Write-Note ("unknown platform '{0}', applying common patches only" -f $Platform) }
}

# ---------------------------------------------------------------------- main

$script:RepoRoot = ''
$script:TempPatches = New-Object System.Collections.ArrayList

try {
    Write-Step 'resolving paths'
    $script:RepoRoot = Resolve-RepoRoot -Given $RepoRoot
    $flutterDir = Resolve-FlutterRoot -Given $FlutterRoot
    $script:PubCacheRoots = Get-PubCacheRoots
    Write-Ok ("repo          : {0}" -f $script:RepoRoot)
    Write-Ok ("flutter       : {0}" -f $flutterDir)
    Write-Ok ("pub cache     : {0}" -f ($script:PubCacheRoots -join ' | '))
    Write-Ok ("platform      : {0}" -f $platformName)

    if (-not (Test-Path (Join-Path $script:RepoRoot 'pubspec.yaml'))) {
        throw ("{0} does not look like the PiliPlus repository" -f $script:RepoRoot)
    }
    if (-not (Test-Path (Join-Path $flutterDir 'packages\flutter\lib\src'))) {
        throw ("{0} does not look like a Flutter SDK checkout" -f $flutterDir)
    }

    Write-Step 'preflight'
    $allPatches = @($iosPrePatches) + @($patches) + @($patchesMaterial) + @($patchesCupertino)
    Invoke-Preflight -RelativePaths $allPatches

    if ($DryRun) {
        Write-Step 'dry run plan'
        foreach ($item in $iosPrePatches) { Write-Host ("  repo      : {0}" -f $item) }
        foreach ($item in $patches) { Write-Host ("  flutter   : {0}" -f $item) }
        foreach ($item in $patchesMaterial) { Write-Host ("  material  : {0}" -f $item) }
        foreach ($item in $patchesCupertino) { Write-Host ("  cupertino : {0}" -f $item) }
        Write-Ok 'nothing was applied (-DryRun)'
        return
    }

    Write-Step 'git identity'
    $userName = (Invoke-External -Exe 'git' -Arguments @('config', '--global', 'user.name') -WorkingDirectory $script:RepoRoot)
    if ($userName.Code -ne 0 -or -not $userName.Output) {
        Invoke-External -Exe 'git' -Arguments @('config', '--global', 'user.name', 'ci') -WorkingDirectory $script:RepoRoot | Out-Null
        Invoke-External -Exe 'git' -Arguments @('config', '--global', 'user.email', 'example@example.com') -WorkingDirectory $script:RepoRoot | Out-Null
        Write-Ok 'user.name / user.email set for this machine'
    }
    else {
        Write-Ok ("user.name = {0}" -f $userName.Output.Trim())
    }

    if ($ResetFlutter) {
        Write-Step 'resetting the Flutter SDK'
        Write-Note ("git reset --hard in {0}" -f $flutterDir)
        $reset = Invoke-External -Exe 'git' -Arguments @('reset', '--hard') -WorkingDirectory $flutterDir
        if ($reset.Code -ne 0) { throw ("git reset --hard failed:`n{0}" -f $reset.Output) }
        Write-Ok 'Flutter SDK restored'
    }
    else {
        $status = Invoke-External -Exe 'git' -Arguments @('status', '--porcelain') -WorkingDirectory $flutterDir
        if ($status.Code -eq 0 -and $status.Output) {
            Write-Note 'Flutter SDK already has local changes; patches may fail to apply'
            Write-Note 'use -ResetFlutter for a clean start'
        }
    }

    if ($SkipFlutterPatches) {
        Write-Step 'skipping Flutter SDK patches'
        Write-Note 'the SDK is expected to be patched already (-SkipFlutterPatches)'
    }
    else {
        Write-Step 'patching the repository'
        foreach ($patch in $iosPrePatches) {
            Apply-Patch -RelativePath $patch -TargetDirectory $script:RepoRoot
        }

        Write-Step 'patching the Flutter SDK'
        foreach ($patch in $patches) {
            Apply-Patch -RelativePath $patch -TargetDirectory $flutterDir
        }
    }

    Write-Step 'material_ui'
    # The real pub cache root can differ from what PUB_CACHE claims: flutter may
    # have extracted packages into %LOCALAPPDATA%\Pub\Cache instead. Remove stale
    # copies from every candidate root before pub get re-extracts them.
    if (-not $SkipPubGet) {
        foreach ($root in $script:PubCacheRoots) {
            $hosted = Join-Path $root 'hosted'
            if (-not (Test-Path $hosted)) { continue }
            foreach ($registry in Get-ChildItem -Path $hosted -Directory -ErrorAction SilentlyContinue) {
                Get-ChildItem -Path $registry.FullName -Directory -ErrorAction SilentlyContinue |
                    Where-Object { $_.Name -like 'material_ui-*' } |
                    ForEach-Object {
                        Write-Note ("removing {0}" -f $_.FullName)
                        Remove-Item -Path $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
                    }
            }
        }
    }

    if ($SkipPubGet) {
        Write-Note 'flutter pub get skipped (-SkipPubGet)'
    }
    else {
        Write-Step 'flutter pub get'
        $flutterExe = Join-Path $flutterDir 'bin\flutter.bat'
        $pubGet = Invoke-External -Exe $flutterExe -Arguments @('pub', 'get') -WorkingDirectory $script:RepoRoot
        if ($pubGet.Code -ne 0) { throw ("flutter pub get failed:`n{0}" -f $pubGet.Output) }
        Write-Ok 'dependencies resolved'
    }

    $materialPackage = Find-PubPackage -Prefix 'material_ui'
    if (-not $materialPackage) { throw 'material_ui package not found in the pub cache' }
    Write-Ok ("material_ui    : {0}" -f $materialPackage.FullName)

    foreach ($patch in $patchesMaterial) {
        Apply-Patch -RelativePath $patch -TargetDirectory $materialPackage.FullName
    }

    Write-Step 'cupertino_ui'
    $cupertinoPackage = Find-PubPackage -Prefix 'cupertino_ui'
    if (-not $cupertinoPackage) { throw 'cupertino_ui package not found in the pub cache' }
    Write-Ok ("cupertino_ui   : {0}" -f $cupertinoPackage.FullName)

    foreach ($patch in $patchesCupertino) {
        Apply-Patch -RelativePath $patch -TargetDirectory $cupertinoPackage.FullName
    }

    Write-Host ''
    Write-Host 'All patches applied.' -ForegroundColor Green
    Write-Host ("  flutter  : {0}" -f $flutterDir) -ForegroundColor Green
    Write-Host ("  platform : {0}" -f $platformName) -ForegroundColor Green
}
catch {
    $lineNo = $_.InvocationInfo.ScriptLineNumber
    $lineText = "$($_.InvocationInfo.Line)"
    Write-Bad ("`nFAILED: {0}" -f $_.Exception.Message)
    if ($lineNo) { Write-Bad ("at line {0}: {1}" -f $lineNo, $lineText.Trim()) }
    Write-Bad 'hints:'
    Write-Host '  - pass -FlutterRoot if the SDK is not on PATH'
    Write-Host '  - pass -ResetFlutter when the SDK already carries an older patch set'
    Write-Host '  - patches are matched against the Flutter version, a mismatch shows as "patch does not apply"'
    exit 1
}
finally {
    foreach ($temp in $script:TempPatches) {
        Remove-Item $temp -Force -ErrorAction SilentlyContinue
    }
}
