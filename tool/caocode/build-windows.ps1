param(
    [ValidateSet('Release', 'Debug')][string]$Mode = 'Release',
    [string]$FlutterSdk = (Join-Path $env:USERPROFILE 'develop\flutter-3.47.5'),
    [switch]$DoctorOnly,
    [switch]$Installer
)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
$OutputEncoding = [Console]::OutputEncoding
if (-not $IsWindows -or $PSVersionTable.PSVersion.Major -lt 7) {
    throw '需要 Windows PowerShell 7'
}
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
Set-Location -LiteralPath $root
$flutter = Join-Path $FlutterSdk 'bin\flutter.bat'
if (-not (Test-Path -LiteralPath $flutter)) { throw '请先在 WSL 运行 ./setup.sh' }
$env:PATH = (Join-Path $FlutterSdk 'bin') + ';' + $env:PATH
$toolchain = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'toolchain.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$versionJson = & $flutter --version --machine
if ($LASTEXITCODE -ne 0) { throw '无法读取 Flutter 版本' }
$version = $versionJson | ConvertFrom-Json
if ($version.frameworkRevision -ne $toolchain.flutterRevision) { throw 'Flutter SDK 版本不匹配' }
if ($DoctorOnly) {
    & $flutter doctor -v
    if ($LASTEXITCODE -ne 0) { throw 'Flutter 环境检查失败' }
    exit 0
}
$displayVersion = $null
if ($Installer) {
    if ($Mode -ne 'Release') { throw '安装包仅支持 Release 编译' }
    $pubspec = Get-Content -LiteralPath (Join-Path $root 'pubspec.yaml') -Raw -Encoding UTF8
    if ($pubspec -notmatch '(?m)^version:\s*(\d+\.\d+\.\d+)\+(\d+)\s*$') {
        throw '无法读取安装包版本'
    }
    $appVersion = $Matches[1] + '+' + $Matches[2]
    $displayVersion = $Matches[1] + 'c'
    $env:CAOCODE_BUNDLE_OUTPUT = Join-Path $root "build\windows\x64\runner\Package\$displayVersion"
}
. (Join-Path $PSScriptRoot 'flutter-tools.ps1')
Invoke-CaocodePubGet $flutter $root
Initialize-CaocodeWslServer $root $FlutterSdk
& (Join-Path $PSScriptRoot 'cache-windows-sdk.ps1') -FlutterSdk $FlutterSdk
& $flutter build windows ('--' + $Mode.ToLowerInvariant())
if ($LASTEXITCODE -ne 0) { throw 'Windows 编译失败' }
$bundle = if ($Installer) {
    Join-Path $env:CAOCODE_BUNDLE_OUTPUT $Mode
} else {
    Join-Path $root "build\windows\x64\runner\$Mode"
}
if ($Mode -eq 'Release') {
    $engine = Join-Path $bundle 'flutter_windows.dll'
    $stockHash = (Get-FileHash -LiteralPath $engine -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($stockHash -eq '8bd7b61eee31aa436edb182db41624d1cd3b2688a7e03622320dbeae067b5251') {
        $patched = Join-Path $root 'tool\engine\flutter_windows.dll'
        if ((Get-FileHash -LiteralPath $patched -Algorithm SHA256).Hash.ToLowerInvariant() -ne
            'd20feefdf335b0e3ae92f4e2f1b1892b5bd9d4c80b194b14b8bb87b34b9591d5') {
            throw '上游字体引擎校验失败'
        }
        Copy-Item -LiteralPath $patched -Destination $engine
    }
}
$cmake = Get-Content -LiteralPath (Join-Path $root 'windows\CMakeLists.txt') -Raw -Encoding UTF8
if ($cmake -notmatch 'set\(BINARY_NAME "([^"]+)"\)') { throw '无法读取 Windows 可执行文件名' }
$executable = Join-Path $bundle ($Matches[1] + '.exe')
$snapshot = if ($Mode -eq 'Release') { 'data\app.so' } else { 'data\flutter_assets\kernel_blob.bin' }
foreach ($relative in @([IO.Path]::GetFileName($executable), 'flutter_windows.dll', $snapshot, 'data\icudtl.dat', 'data\flutter_assets')) {
    if (-not (Test-Path -LiteralPath (Join-Path $bundle $relative))) { throw "编译产物缺失：$relative" }
}
Write-Output "编译完成：$executable"
if ($Installer) {
    $candidates = @(
        (Join-Path $env:LOCALAPPDATA 'Programs\Inno Setup 6\ISCC.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6\ISCC.exe'),
        (Join-Path $env:ProgramFiles 'Inno Setup 6\ISCC.exe')
    )
    $iscc = $candidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    if (-not $iscc) { throw '请先安装 Inno Setup 6' }
    $outDir = Join-Path $root 'build\installers'
    [void][IO.Directory]::CreateDirectory($outDir)
    & $iscc "/DBundleDir=$bundle" "/DAppVersion=$appVersion" "/DOutDir=$outDir" (Join-Path $root 'tool\caocode.iss')
    if ($LASTEXITCODE -ne 0) { throw 'Windows 安装包编译失败' }
    $package = Join-Path $outDir "Caocode-$displayVersion-setup.exe"
    if (-not (Test-Path -LiteralPath $package)) { throw '安装包产物缺失' }
    Write-Output "安装包完成：$package"
}
