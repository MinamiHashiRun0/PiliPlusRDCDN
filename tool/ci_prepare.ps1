# 打包前的预处理：让 patch.ps1 在任意环境（含 CI runner）都能跑通。
#
# 为什么需要它：
#   patch.ps1 用 `git apply` 往两处打补丁——Flutter SDK 源码，以及 pub cache 里的
#   material_ui / cupertino_ui。前者本来就是 git 仓库；后者是 pub 解压出来的目录，
#   **没有 .git**，于是 `git apply` 会以 "not a git repository" 失败，而 patch.ps1
#   在失败时直接 throw。
#   本机实测：material_ui-1.3.0 / cupertino_ui-1.1.0 都没有 .git，但给它们补一个
#   临时 .git 之后，全部 11 个包 patch 都能干净应用（Flutter 3.47.5）。
#
# 顺带把版本约束放宽：上游写死 `flutter: 3.47.4`，而 pub 从 Dart 3.9 起会对 root package
# 校验 flutter 约束的上限，本机/CI 用的 3.47.5 会被直接拒掉。这里统一放宽成 >=3.47.4。
#
# 用法（在仓库根目录）：
#   pwsh -File tool/ci_prepare.ps1 [iOS|android|macos|linux|windows]
#   不给平台参数时按 iOS 处理。

param(
    [string]$Platform = 'iOS'
)

$ErrorActionPreference = 'Stop'

$root = (Get-Location).Path
$pubspec = Join-Path $root 'pubspec.yaml'

if (-not (Test-Path $pubspec)) {
    throw "pubspec.yaml 不在当前目录，请先 cd 到仓库根目录（当前：$root）"
}

# ---- 1) 放宽 flutter 版本约束 -------------------------------------------------
$content = Get-Content $pubspec -Raw
if ($content -match '(?m)^(\s*flutter:\s*)["'']?3\.47\.4["'']?\s*$') {
    $content = $content -replace '(?m)^(\s*flutter:\s*)["'']?3\.47\.4["'']?\s*$', '$1">=3.47.4"'
    # Set-Content -NoNewline 会丢末尾换行，用 .NET 写回保持原样
    [System.IO.File]::WriteAllText($pubspec, $content, (New-Object System.Text.UTF8Encoding($false)))
    Write-Host 'pubspec.yaml: flutter 约束已放宽为 >=3.47.4'
} else {
    Write-Host 'pubspec.yaml: flutter 约束已是放宽状态，跳过'
}

# ---- 2) 依赖 -----------------------------------------------------------------
flutter pub get
if ($LASTEXITCODE -ne 0) { throw "flutter pub get 失败（$LASTEXITCODE）" }

# ---- 3) 给 pub cache 里的包补 .git，供 patch.ps1 使用 -------------------------
$cacheRoots = @()
if ($env:PUB_CACHE) { $cacheRoots += $env:PUB_CACHE }
$cacheRoots += (Join-Path $HOME '.pub-cache')
if ($env:LOCALAPPDATA) { $cacheRoots += (Join-Path $env:LOCALAPPDATA 'Pub\Cache') }

foreach ($pkg in @('material_ui', 'cupertino_ui')) {
    $dir = $null
    foreach ($cache in $cacheRoots) {
        $hosted = Join-Path $cache 'hosted/pub.dev'
        if (-not (Test-Path $hosted)) { continue }
        $dir = Get-ChildItem $hosted -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like "$pkg-*" } |
            Sort-Object Name |
            Select-Object -Last 1
        if ($dir) { break }
    }
    if (-not $dir) { throw "在 pub cache 里找不到 $pkg（找过：$($cacheRoots -join ', ')）" }

    if (Test-Path (Join-Path $dir.FullName '.git')) {
        Write-Host "$($dir.Name): 已有 .git，跳过"
        continue
    }
    # 空仓库就够：git apply 只要求在一个 work tree 里（默认不允许在仓库外打补丁）
    git -C $dir.FullName init -q
    if ($LASTEXITCODE -ne 0) { throw "git init 失败：$($dir.FullName)" }
    Write-Host "$($dir.Name): 已补临时 .git"
}

# ---- 4) 版本号与 dart-define（会生成被 gitignore 的 pili_release.json）--------
# build.ps1 最后会往 $env:GITHUB_ENV 追加 version=...；GITHUB_ENV 只在 Actions 里存在，
# 本地跑时若未定义，Set-Content/Add-Content 会直接报错。这里补一个临时文件兜住。
$env:GITHUB_ENV ??= Join-Path ([System.IO.Path]::GetTempPath()) 'pili_ci_env'
if (-not (Test-Path $env:GITHUB_ENV)) { New-Item -ItemType File -Path $env:GITHUB_ENV -Force | Out-Null }

& (Join-Path $root 'lib/scripts/build.ps1')
if ($LASTEXITCODE -ne 0) { throw "build.ps1 失败（$LASTEXITCODE）" }

# ---- 5) 打补丁 ---------------------------------------------------------------
# 平台参数直接透给 patch.ps1：它按 iOS / android / macos / linux / windows 选不同的
# 补丁集（iOS 会额外打 geetest_ios 与 bottom_sheet_ios_piliplus）。
& (Join-Path $root 'lib/scripts/patch.ps1') $Platform
if ($LASTEXITCODE -ne 0) { throw "patch.ps1 $Platform 失败（$LASTEXITCODE）" }

Write-Host "$Platform 预处理完成。"
