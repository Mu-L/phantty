param([switch]$RegisterPackage)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$test = Join-Path $repo 'zig-out\bin\wispterm-shell-extension-test.exe'
$dll = Join-Path $repo 'zig-out\bin\wispterm-shell-extension.dll'
if (!(Test-Path $test) -or !(Test-Path $dll)) { throw 'Run zig build shell-extension-test first.' }
# C: working directories avoid WSL UNC semantics in the Windows test runner.
$scratch = Join-Path ([IO.Path]::GetTempPath()) ('WispTermShellTest-' + [guid]::NewGuid().ToString('N'))
$install = Join-Path $scratch 'install space'
$second = Join-Path $scratch 'relocated install'
New-Item -ItemType Directory -Force $install | Out-Null
try {
    Copy-Item -LiteralPath $test -Destination (Join-Path $install 'wispterm.exe')
    & (Join-Path $repo 'packaging\windows\shell-integration\build-package.ps1') -TargetDir $install -ExtensionPath $dll -TimestampUrl ""
    $metadata = Get-Content -Raw (Join-Path $install 'shell-integration\identity.json') | ConvertFrom-Json
    [xml]$manifest = Get-Content -Raw (Join-Path $install $metadata.Manifest)
    $ns = New-Object Xml.XmlNamespaceManager $manifest.NameTable
    $ns.AddNamespace('com','http://schemas.microsoft.com/appx/manifest/com/windows10')
    $class = $manifest.SelectSingleNode('//com:Class',$ns)
    $packagedDll = Join-Path $install $class.Path
    Push-Location $scratch
    try {
        & (Join-Path $install 'wispterm.exe') $packagedDll
        if ($LASTEXITCODE -ne 0) { throw 'Direct COM/launch tests failed.' }
    } finally { Pop-Location }
    $menu = Join-Path $install 'context-menu.ps1'
    $before = & $menu -Action Status
    & $menu -Action Refresh # Must not opt a fresh installation into registration.
    $after = & $menu -Action Status
    if ($before.Enabled -ne $after.Enabled) { throw 'Refresh enabled an unregistered installation.' }
    if (!$RegisterPackage -and !(Get-AuthenticodeSignature (Join-Path $install $metadata.Package)).Status.Equals('Valid')) {
        $rejected = $false
        try { & $menu -Action Install } catch { $rejected = $true }
        if (!$rejected -or (& $menu -Action Status).Enabled) { throw 'Untrusted package was not rejected before registration.' }
        Write-Host 'PASS: unsigned package refused without changing registration'
    }
    if ($RegisterPackage) {
        if (@(Get-AppxPackage -Name WispTerm.ContextMenu).Count -or (Test-Path 'HKCU:\Software\WispTerm\ContextMenu')) {
            throw 'Registration tests require a clean/disposable Windows user profile.'
        }
        # Uses an already trusted signing certificate; this script neither
        # creates certificates nor enables Developer Mode.
        & $menu -Action Install
        & $menu -Action Install # idempotence
        if (!(& $menu -Action Status).Enabled) { throw 'Registration status was not enabled.' }
        Push-Location $scratch
        try {
            & (Join-Path $install 'wispterm.exe') --registered
            if ($LASTEXITCODE -ne 0) { throw 'Packaged COM activation/launch tests failed.' }
        } finally { Pop-Location }
        Copy-Item -LiteralPath $install -Destination $second -Recurse
        $secondMenu = Join-Path $second 'context-menu.ps1'
        & $secondMenu -Action Install
        & $menu -Action Remove # An old copy must not unregister the active copy.
        if (!(& $secondMenu -Action Status).Enabled) { throw 'Removing an old copy removed the active registration.' }
        Push-Location $scratch
        try {
            & (Join-Path $second 'wispterm.exe') --registered
            if ($LASTEXITCODE -ne 0) { throw 'Relocated packaged COM activation failed.' }
        } finally { Pop-Location }
        & $secondMenu -Action Remove
        & $secondMenu -Action Remove # removal is idempotent
        if (@(Get-AppxPackage -Name WispTerm.ContextMenu).Count) { throw 'Package remained registered after removal.' }
        Write-Host 'PASS: signed identity registration, packaged activation, relocation, ownership and removal'
    }
} finally {
    if ($RegisterPackage) {
        foreach ($root in @($second,$install)) {
            $menu = Join-Path $root 'context-menu.ps1'
            if (Test-Path $menu) { & $menu -Action Remove }
        }
    }
    try { Remove-Item -LiteralPath $scratch -Recurse -Force }
    catch { Write-Warning "A COM surrogate still holds test files; cleanup directory: $scratch" }
}
