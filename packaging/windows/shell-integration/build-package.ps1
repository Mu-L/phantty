param(
    [Parameter(Mandatory = $true)][string]$TargetDir,
    [Parameter(Mandatory = $true)][string]$ExtensionPath,
    [string]$SigningCertificateThumbprint = $env:WISPTERM_WINDOWS_SIGN_THUMBPRINT,
    [string]$TimestampUrl = 'http://timestamp.digicert.com'
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Find-SdkTool([string]$Name) {
    $command = Get-Command $Name -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }
    $sdk = Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10\bin'
    $tool = Get-ChildItem -Path (Join-Path $sdk "*\x64\$Name") -ErrorAction SilentlyContinue |
        Sort-Object FullName -Descending | Select-Object -First 1
    if (!$tool) { throw "Windows SDK tool $Name was not found. Install the Windows SDK packaging tools." }
    return $tool.FullName
}

$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..'))
$target = [IO.Path]::GetFullPath($TargetDir)
$exe = Join-Path $target 'wispterm.exe'
if (!(Test-Path -LiteralPath $exe)) { throw "Missing desktop executable: $exe" }
if (!(Test-Path -LiteralPath $ExtensionPath)) { throw "Missing Explorer extension: $ExtensionPath" }
$pe = [IO.File]::ReadAllBytes($ExtensionPath)
if ($pe.Length -lt 64) { throw 'Invalid Explorer DLL.' }
$peOffset = [BitConverter]::ToInt32($pe, 60)
if ($peOffset -lt 0 -or $peOffset + 6 -gt $pe.Length -or [BitConverter]::ToUInt32($pe, $peOffset) -ne 0x4550 -or [BitConverter]::ToUInt16($pe, $peOffset + 4) -ne 0x8664) {
    throw 'Explorer identity packaging requires an x64 DLL.'
}
$versionText = Get-Content -Raw (Join-Path $repoRoot 'build.zig.zon')
if ($versionText -notmatch '\.version\s*=\s*"(\d+)\.(\d+)\.(\d+)"') { throw 'Cannot read desktop version from build.zig.zon.' }
$version = "$($Matches[1]).$($Matches[2]).$($Matches[3]).0"
foreach ($part in $version.Split('.')) { if ([int]$part -gt 65535) { throw 'Desktop version exceeds MSIX version range.' } }
$publisher = 'CN=WispTerm'
$certificate = $null
if ($SigningCertificateThumbprint) {
    $certificate = Get-Item -LiteralPath "Cert:\CurrentUser\My\$SigningCertificateThumbprint"
    if (!$certificate.HasPrivateKey) { throw 'Signing certificate has no private key.' }
    $publisher = $certificate.Subject
}
$integration = Join-Path $target 'shell-integration'
New-Item -ItemType Directory -Force $integration | Out-Null
$dllHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $ExtensionPath).Hash.Substring(0,16).ToLowerInvariant()
$templateHash = (Get-FileHash -Algorithm SHA256 (Join-Path $PSScriptRoot 'AppxManifest.xml')).Hash
$sha = [Security.Cryptography.SHA256]::Create()
try { $hash = ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes("$dllHash|$templateHash|$publisher")))).Replace('-','').Substring(0,16).ToLowerInvariant() } finally { $sha.Dispose() }
$payloadRelative = "shell-integration\$version-$hash"
$extensionRelative = "$payloadRelative\wispterm-shell-extension.dll"
$extensionDest = Join-Path $target $extensionRelative
New-Item -ItemType Directory -Force (Split-Path -Parent $extensionDest) | Out-Null
Copy-Item -LiteralPath $ExtensionPath -Destination $extensionDest -Force

# Resize the existing application artwork into the MSIX resource sizes.
Add-Type -AssemblyName System.Drawing
$assets = Join-Path $integration 'Assets'
New-Item -ItemType Directory -Force $assets | Out-Null
$image = [Drawing.Image]::FromFile((Join-Path $repoRoot 'assets\wispterm.png'))
try {
    foreach ($entry in @(@('StoreLogo',50), @('Square44x44Logo',44), @('Square150x150Logo',150))) {
        $bitmap = New-Object Drawing.Bitmap ([int]$entry[1]), ([int]$entry[1])
        $graphics = [Drawing.Graphics]::FromImage($bitmap)
        try {
            $graphics.InterpolationMode = [Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
            $graphics.DrawImage($image, 0, 0, [int]$entry[1], [int]$entry[1])
            $bitmap.Save((Join-Path $assets "$($entry[0]).png"), [Drawing.Imaging.ImageFormat]::Png)
        } finally { $graphics.Dispose(); $bitmap.Dispose() }
    }
} finally { $image.Dispose() }

$escapedPublisher = [Security.SecurityElement]::Escape($publisher)
$manifest = (Get-Content -Raw (Join-Path $PSScriptRoot 'AppxManifest.xml')).
    Replace('@PUBLISHER@', $escapedPublisher).Replace('@VERSION@', $version).Replace('@EXTENSION_PATH@', $extensionRelative)
$utf8 = New-Object Text.UTF8Encoding $false
# Keep a loose manifest for explicit developer registration; never silently
# enable Developer Mode or trust a certificate on the user's machine.
$payloadDir = Split-Path -Parent $extensionDest
$manifestPath = Join-Path $payloadDir 'AppxManifest.xml'
[IO.File]::WriteAllText($manifestPath, $manifest, $utf8)
$staging = Join-Path $integration 'package-staging'
New-Item -ItemType Directory -Force $staging | Out-Null
try {
    [IO.File]::WriteAllText((Join-Path $staging 'AppxManifest.xml'), $manifest, $utf8)
    $makeAppx = Find-SdkTool 'makeappx.exe'
    $msix = Join-Path $payloadDir 'WispTerm.ContextMenu.msix'
    & $makeAppx pack /o /nv /d $staging /p $msix
    if ($LASTEXITCODE -ne 0) { throw 'MakeAppx failed.' }
} finally { Remove-Item -LiteralPath $staging -Recurse -Force }

# Embed the matching identity in the COPIED desktop exe. Dev builds and the
# source binary are untouched; existing icon resources are preserved by mt.
$appManifest = Join-Path $integration 'wispterm.manifest'
[IO.File]::WriteAllText($appManifest, @"
<?xml version="1.0" encoding="utf-8"?>
<assembly manifestVersion="1.0" xmlns="urn:schemas-microsoft-com:asm.v1">
 <assemblyIdentity version="1.0.0.0" name="WispTerm" />
 <msix xmlns="urn:schemas-microsoft-com:msix.v1" publisher="$escapedPublisher" packageName="WispTerm.ContextMenu" applicationId="WispTerm" />
</assembly>
"@, $utf8)
$mt = Find-SdkTool 'mt.exe'
# mt.exe mishandles UNC manifest paths (including WSL checkouts). Give it
# short native paths and copy back only after successful resource editing.
$resourceStage = Join-Path ([IO.Path]::GetTempPath()) ('WispTermResources-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force $resourceStage | Out-Null
try {
    $localExe = Join-Path $resourceStage 'wispterm.exe'
    $localManifest = Join-Path $resourceStage 'wispterm.manifest'
    Copy-Item -LiteralPath $exe -Destination $localExe
    Copy-Item -LiteralPath $appManifest -Destination $localManifest
    & $mt -nologo -manifest $localManifest "-outputresource:$localExe;#1"
    if ($LASTEXITCODE -ne 0) { throw 'Embedding package identity in wispterm.exe failed.' }
    Copy-Item -LiteralPath $localExe -Destination $exe -Force
} finally { Remove-Item -LiteralPath $resourceStage -Recurse -Force }
if ($certificate) {
    $signTool = Find-SdkTool 'signtool.exe'
    $signArgs = @('sign','/fd','SHA256','/sha1',$certificate.Thumbprint)
    if ($TimestampUrl) { $signArgs += @('/tr',$TimestampUrl,'/td','SHA256') }
    & $signTool @signArgs $msix
    if ($LASTEXITCODE -ne 0) { throw 'Signing the context menu identity package failed.' }
} else {
    Write-Warning 'Context menu package is unsigned. Add-Context-Menu.cmd requires a trusted signed package. See docs/windows-context-menu.md for developer testing and release signing.'
}
foreach ($name in @('context-menu.ps1', 'Add-Context-Menu.cmd', 'Remove-Context-Menu.cmd')) {
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination (Join-Path $target $name) -Force
}

[IO.File]::WriteAllText((Join-Path $integration 'identity.json'), (@{
    Manifest = "$payloadRelative\AppxManifest.xml"
    Package = "$payloadRelative\WispTerm.ContextMenu.msix"
} | ConvertTo-Json), $utf8)
