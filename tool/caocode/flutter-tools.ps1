$ErrorActionPreference = 'Stop'

function Initialize-CaocodePluginJunctions([string]$Root) {
    $metadataPath = Join-Path $Root '.flutter-plugins-dependencies'
    if (-not (Test-Path -LiteralPath $metadataPath)) { return 0 }
    $metadata = Get-Content -LiteralPath $metadataPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $created = 0
    # Flutter prepares links for every desktop project present, even when
    # building Windows. Linux support adds a second set to prepare here.
    foreach ($platform in @('windows', 'linux')) {
        if (-not (Test-Path -LiteralPath (Join-Path $Root $platform))) { continue }
        $links = Join-Path $Root "$platform\flutter\ephemeral\.plugin_symlinks"
        New-Item -ItemType Directory -Path $links -Force | Out-Null
        foreach ($plugin in $metadata.plugins.$platform) {
            # Flutter links every plugin, including Dart-only plugins.
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
