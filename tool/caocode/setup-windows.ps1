param([string]$FlutterSdk = (Join-Path $env:USERPROFILE 'develop\flutter-3.47.5'))
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
$OutputEncoding = [Console]::OutputEncoding
if (-not $IsWindows -or $PSVersionTable.PSVersion.Major -lt 7) {
    throw '需要 Windows PowerShell 7'
}
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$toolchain = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'toolchain.json') -Raw -Encoding UTF8 | ConvertFrom-Json
Set-Location -LiteralPath $root
if (-not (Test-Path -LiteralPath $FlutterSdk)) {
    New-Item -ItemType Directory -Path (Split-Path -Parent $FlutterSdk) -Force | Out-Null
    & git clone --depth 1 --branch $toolchain.flutterVersion https://github.com/flutter/flutter.git $FlutterSdk
    if ($LASTEXITCODE -ne 0) { throw 'Flutter SDK 下载失败' }
}
$revision = & git -C $FlutterSdk rev-parse HEAD
if ($LASTEXITCODE -ne 0 -or $revision -ne $toolchain.flutterRevision) {
    throw "Flutter SDK 版本不匹配：$revision"
}
& git -C $FlutterSdk symbolic-ref -q HEAD | Out-Null
if ($LASTEXITCODE -ne 0) {
    & git -C $FlutterSdk switch -c stable
    if ($LASTEXITCODE -ne 0) { throw 'Flutter SDK 分支初始化失败' }
}
$env:PATH = (Join-Path $FlutterSdk 'bin') + ';' + $env:PATH
$flutter = Join-Path $FlutterSdk 'bin\flutter.bat'
& $flutter config --enable-windows-desktop --no-analytics
if ($LASTEXITCODE -ne 0) { throw 'Flutter 配置失败' }
. (Join-Path $PSScriptRoot 'flutter-tools.ps1')
Invoke-CaocodePubGet $flutter $root
& (Join-Path $PSScriptRoot 'cache-windows-sdk.ps1') -FlutterSdk $FlutterSdk
& $flutter doctor -v
if ($LASTEXITCODE -ne 0) { throw 'Flutter 环境检查失败' }
