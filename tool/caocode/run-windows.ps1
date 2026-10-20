param(
    [string]$FlutterSdk = (Join-Path $env:USERPROFILE 'develop\flutter-3.47.5')
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
$version = (& $flutter --version --machine) | ConvertFrom-Json
if ($LASTEXITCODE -ne 0) { throw '无法读取 Flutter 版本' }
if ($version.frameworkRevision -ne $toolchain.flutterRevision) { throw 'Flutter SDK 版本不匹配' }
. (Join-Path $PSScriptRoot 'flutter-tools.ps1')
Invoke-CaocodePubGet $flutter $root
Initialize-CaocodeWslServer $root $FlutterSdk
& (Join-Path $PSScriptRoot 'cache-windows-sdk.ps1') -FlutterSdk $FlutterSdk
& $flutter run --device-id windows --debug --no-pub --machine
if ($LASTEXITCODE -ne 0) { throw 'Windows 开发启动失败' }
