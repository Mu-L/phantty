param(
    [ValidateSet('Install','Remove','Status','Refresh')][string]$Action = 'Status',
    [string]$InstallDir = $PSScriptRoot,
    [switch]$Development
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$packageName = 'WispTerm.ContextMenu'
$stateKey = 'HKCU:\Software\WispTerm\ContextMenu'
$root = [IO.Path]::GetFullPath($InstallDir).TrimEnd('\')
$zh = (Get-UICulture).Name.StartsWith('zh')
function T([string]$English, [string]$Chinese) { if ($zh) { return $Chinese }; return $English }
function Read-State {
    if (Test-Path -LiteralPath $stateKey) { return Get-ItemProperty -LiteralPath $stateKey }
    return $null
}
function Resolve-Payload([string]$Relative) {
    $path = [IO.Path]::GetFullPath((Join-Path $root $Relative))
    if (!$path.StartsWith($root + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Invalid context-menu payload path.' }
    if (!(Test-Path -LiteralPath $path -PathType Leaf)) { throw "Missing context-menu payload: $path" }
    return $path
}
function Assert-NotRunning([string]$Directory) {
    $exe = Join-Path $Directory 'wispterm.exe'
    $running = @(Get-Process -Name wispterm -ErrorAction SilentlyContinue | Where-Object {
        try { $_.Path -eq $exe } catch { $false }
    })
    if ($running.Count) { throw (T 'Close the registered WispTerm installation before changing its context menu. Sessions have not been terminated.' '请先关闭已注册的 WispTerm，再更改右键菜单。当前会话未被终止。') }
}
function Write-State($Values) {
    New-Item -Path $stateKey -Force | Out-Null
    foreach ($name in @('InstallDir','PackagePath','ManifestPath','PackageFullName','Development')) {
        $type = if ($name -eq 'Development') { 'DWord' } else { 'String' }
        New-ItemProperty -LiteralPath $stateKey -Name $name -Value $Values.$name -PropertyType $type -Force | Out-Null
    }
}
function Register-Payload([string]$PackagePath, [string]$ManifestPath, [string]$ExternalLocation, [bool]$Dev) {
    if ($Dev) {
        Add-AppxPackage -Register $ManifestPath -ExternalLocation $ExternalLocation -ErrorAction Stop
    } else {
        Add-AppxPackage -Path $PackagePath -ExternalLocation $ExternalLocation -ErrorAction Stop
    }
}
function Notify-Shell {
    if (!('WispTermShellNotify' -as [type])) {
        Add-Type 'using System; using System.Runtime.InteropServices; public static class WispTermShellNotify { [DllImport("shell32.dll")] public static extern void SHChangeNotify(uint e, uint f, IntPtr a, IntPtr b); }'
    }
    [WispTermShellNotify]::SHChangeNotify(0x08000000, 0, [IntPtr]::Zero, [IntPtr]::Zero)
}

$state = Read-State
$owned = $state -and $state.InstallDir -eq $root
$packages = @(Get-AppxPackage -Name $packageName -ErrorAction Stop)
if ($Action -eq 'Status') {
    [pscustomobject]@{
        Enabled = [bool]($owned -and (@($packages | ForEach-Object { $_.PackageFullName }) -contains $state.PackageFullName))
        RegisteredInstallDir = if ($state) { $state.InstallDir } else { '' }
        Package = if ($packages.Count) { $packages[0].PackageFullName } else { '' }
    }
    return
}
if ($Action -eq 'Remove') {
    # Removing an older portable copy must not unregister a newer installation.
    if ($owned) {
        Assert-NotRunning $root
        foreach ($package in $packages) {
            if ($package.PackageFullName -eq $state.PackageFullName) { Remove-AppxPackage -Package $package.PackageFullName -ErrorAction Stop }
        }
        Remove-Item -LiteralPath $stateKey -Force
        Notify-Shell
    }
    Write-Host (T 'WispTerm context menu removed for this installation.' '已移除此安装目录的 WispTerm 右键菜单。')
    return
}
if ($Action -eq 'Refresh' -and (!$owned -or !(@($packages | ForEach-Object { $_.PackageFullName }) -contains $state.PackageFullName))) { return }
if ([Environment]::OSVersion.Version.Build -lt 19041) { throw (T 'The context menu requires Windows 10 2004 or later.' '右键菜单需要 Windows 10 2004 或更新版本。') }
if ($env:PROCESSOR_ARCHITECTURE -ne 'AMD64') { throw 'Use x64 PowerShell on an x64 Windows installation for this extension.' }
$metadata = Get-Content -Raw (Resolve-Payload 'shell-integration\identity.json') | ConvertFrom-Json
$manifestPath = Resolve-Payload $metadata.Manifest
$packagePath = Resolve-Payload $metadata.Package
[xml]$manifest = Get-Content -Raw $manifestPath
$identity = $manifest.Package.Identity
if ($identity.Name -ne $packageName) { throw 'Unexpected context-menu package name.' }
$null = Resolve-Payload 'wispterm.exe'
$dev = [bool]$Development
if ($Action -eq 'Refresh' -and $state) { $dev = [bool]$state.Development }
if ($dev) {
    $unlocked = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock' -ErrorAction SilentlyContinue
    if (!$unlocked -or !($unlocked.PSObject.Properties.Name -contains 'AllowDevelopmentWithoutDevLicense') -or $unlocked.AllowDevelopmentWithoutDevLicense -ne 1) {
        throw 'Developer Mode is not enabled. Enable it explicitly in Windows Settings for loose-manifest testing, or use a trusted signed package.'
    }
} else {
    $signature = Get-AuthenticodeSignature -LiteralPath $packagePath
    if ($signature.Status -ne 'Valid') {
        throw (T "Context menu package signature is not trusted ($($signature.Status)). Install a release with a trusted signed identity package. No certificates were imported." "右键菜单身份包的签名不受信任（$($signature.Status)）。请使用附带受信任签名身份包的版本；本脚本未导入任何证书。")
    }
}
# Refuse to replace a registration we cannot roll back or attribute to WispTerm.
foreach ($package in $packages) {
    if (!$state -or $package.PackageFullName -ne $state.PackageFullName) { throw 'An unmanaged WispTerm context-menu package is registered. Remove it explicitly before registering this installation.' }
    if ($package.Publisher -ne $identity.Publisher) { throw 'Publisher changed. Remove the previous context menu before installing the new publisher.' }
}
if ($packages.Count -gt 1) { throw 'Multiple WispTerm context-menu packages are registered.' }
$previous = if ($packages.Count) { $packages[0] } else { $null }
# Preserve an existing equal-version registration only if it points at these
# immutable payloads. New builds at the same app version still get re-registered.
if ($previous -and $owned -and $state.PackagePath -eq $packagePath -and [bool]$state.Development -eq $dev) {
    Write-Host (T 'WispTerm context menu is already enabled.' 'WispTerm 右键菜单已启用。')
    return
}
if ($previous) { Assert-NotRunning $state.InstallDir; Remove-AppxPackage -Package $previous.PackageFullName -ErrorAction Stop }
try {
    Register-Payload $packagePath $manifestPath $root $dev
    $installed = @(Get-AppxPackage -Name $packageName | Where-Object { $_.Publisher -eq $identity.Publisher })
    if ($installed.Count -ne 1) { throw 'Package registration did not produce exactly one matching package.' }
    Write-State @{
        InstallDir = $root; PackagePath = $packagePath; ManifestPath = $manifestPath
        PackageFullName = $installed[0].PackageFullName; Development = [int]$dev
    }
} catch {
    $failure = $_
    # Undo any partially successful new registration before restoring the old.
    Get-AppxPackage -Name $packageName | Where-Object { $_.Publisher -eq $identity.Publisher } |
        ForEach-Object { Remove-AppxPackage -Package $_.PackageFullName -ErrorAction Continue }
    if ($previous) {
        try { Register-Payload $state.PackagePath $state.ManifestPath $state.InstallDir ([bool]$state.Development) }
        catch { Write-Warning "Previous context menu could not be restored: $_" }
    }
    if ($state) { Write-State $state }
    elseif (Test-Path -LiteralPath $stateKey) { Remove-Item -LiteralPath $stateKey -Force }
    throw $failure
}
Notify-Shell
Write-Host (T 'WispTerm context menu enabled. Reopen File Explorer; if its menu is cached, sign out and back in.' '已启用 WispTerm 右键菜单。请重新打开资源管理器；若菜单仍有缓存，请注销后重新登录。')
