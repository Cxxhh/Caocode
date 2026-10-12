$ErrorActionPreference = 'Stop'

function Initialize-CaocodePluginJunctions([string]$Root) {
    $metadataPath = Join-Path $Root '.flutter-plugins-dependencies'
    if (-not (Test-Path -LiteralPath $metadataPath)) { return 0 }
    $metadata = Get-Content -LiteralPath $metadataPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $links = Join-Path $Root 'windows\flutter\ephemeral\.plugin_symlinks'
    New-Item -ItemType Directory -Path $links -Force | Out-Null
    $created = 0
    foreach ($plugin in $metadata.plugins.windows) {
        # Flutter links every plugin, including ones without a native build.
        if (-not (Test-Path -LiteralPath $plugin.path)) { continue }
        $link = Join-Path $links $plugin.name
        if (Test-Path -LiteralPath $link) {
            $item = Get-Item -LiteralPath $link -Force
            if ($item.LinkType -eq 'Junction' -and
                [IO.Path]::GetFullPath($item.Target).TrimEnd('\') -ne [IO.Path]::GetFullPath($plugin.path).TrimEnd('\')) {
                [IO.Directory]::Delete($link)
            }
        }
        if (-not (Test-Path -LiteralPath $link)) {
            New-Item -ItemType Junction -Path $link -Target $plugin.path | Out-Null
            $created++
        }
    }
    return $created
}

function Invoke-CaocodePubGet([string]$Flutter, [string]$Root) {
    Initialize-CaocodePluginJunctions $Root | Out-Null
    & $Flutter pub get
    if ($LASTEXITCODE -eq 0) {
        # pub get refreshes the metadata. New plugins need junctions before
        # the following build attempts to create privileged symlinks.
        Initialize-CaocodePluginJunctions $Root | Out-Null
        return
    }
    if ((Initialize-CaocodePluginJunctions $Root) -gt 0) {
        Write-Output '已创建 Windows 插件目录联接，重新获取依赖。'
        & $Flutter pub get
        if ($LASTEXITCODE -eq 0) {
            Initialize-CaocodePluginJunctions $Root | Out-Null
            return
        }
    }
    throw 'Windows 依赖安装失败'
}
