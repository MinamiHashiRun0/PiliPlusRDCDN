# 打包前的预处理：让 patch.ps1 在任意环境（含 CI runner）都能**重复**跑通。
#
# 为什么需要它：
#
# 1) pub cache 里的 material_ui / cupertino_ui 是 pub 解压出来的目录，**没有 .git**，
#    而 patch.ps1 用 `git apply` 往它们里面打补丁，于是报 "not a git repository" 并
#    throw。（本机实测两者都没有 .git；补一个空仓库后 11 个包 patch 全部可应用。）
#
# 2) patch.ps1 的 iOS 分支**不做** git reset（只有 android/linux 分支做），而
#    GitHub 的 flutter-action 会按 flutter-version 缓存 SDK —— 第一次跑改过 SDK 后，
#    缓存里存的是**已打补丁**的 SDK，第二次跑再打一遍必然 "patch does not apply"。
#    实测：run 35483535954 成功（首次），run 35484576201 在
#    packages/flutter/lib/src/material/popup_menu.dart 上冲突失败。
#    同理，被打过补丁的 pub 包也会随缓存留下。
#
# 所以本脚本把"起点"重新摆正：仓库 → Flutter SDK → pub 包，三处都恢复原状再打补丁。
# 这样无论跑多少次、缓存里是什么状态，结果都一致。
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

# pub cache 的可能位置（Linux/macOS 用 ~/.pub-cache，Windows 用 LOCALAPPDATA）
$cacheRoots = @()
if ($env:PUB_CACHE) { $cacheRoots += $env:PUB_CACHE }
$cacheRoots += (Join-Path $HOME '.pub-cache')
if ($env:LOCALAPPDATA) { $cacheRoots += (Join-Path $env:LOCALAPPDATA 'Pub\Cache') }

function Get-PkgDir([string]$name) {
    foreach ($cache in $cacheRoots) {
        $hosted = Join-Path $cache 'hosted/pub.dev'
        if (-not (Test-Path $hosted)) { continue }
        $dir = Get-ChildItem $hosted -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like "$name-*" } |
            Sort-Object Name |
            Select-Object -Last 1
        if ($dir) { return $dir }
    }
    return $null
}

# ---- 1) 放宽 flutter 版本约束 -------------------------------------------------
# 上游写死 `flutter: 3.47.4`，而 pub 从 Dart 3.9 起会对 root package 校验 flutter
# 约束的上限，3.47.5 会被直接拒掉。放宽成 >=3.47.4 幂等且可重复。
$content = Get-Content $pubspec -Raw
if ($content -match '(?m)^(\s*flutter:\s*)["'']?3\.47\.4["'']?\s*$') {
    $content = $content -replace '(?m)^(\s*flutter:\s*)["'']?3\.47\.4["'']?\s*$', '$1">=3.47.4"'
    [System.IO.File]::WriteAllText($pubspec, $content, (New-Object System.Text.UTF8Encoding($false)))
    Write-Host 'pubspec.yaml: flutter 约束已放宽为 >=3.47.4'
} else {
    Write-Host 'pubspec.yaml: flutter 约束已是放宽状态，跳过'
}

# ---- 2) 把仓库与 Flutter SDK 恢复到干净状态 -----------------------------------
# 用 checkout 而不是 reset --hard：只覆盖 tracked 文件，不动未跟踪的产物
# （pili_release.json、build/ 之类）。
Write-Host '[clean] 恢复仓库 tracked 文件'
git -C $root checkout -- .
if ($LASTEXITCODE -ne 0) { throw "恢复仓库失败（$LASTEXITCODE）" }

$flutterRoot = $env:FLUTTER_ROOT
if (-not $flutterRoot) {
    # flutter-action 一般会设置它；拿不到就从 flutter 可执行文件位置推
    $flutterBin = (Get-Command flutter -ErrorAction SilentlyContinue).Source
    if ($flutterBin) { $flutterRoot = Split-Path (Split-Path $flutterBin -Parent) -Parent }
}
if ($flutterRoot -and (Test-Path (Join-Path $flutterRoot '.git'))) {
    Write-Host "[clean] 恢复 Flutter SDK：$flutterRoot"
    git -C $flutterRoot checkout -- .
    if ($LASTEXITCODE -ne 0) { throw "恢复 Flutter SDK 失败（$LASTEXITCODE）" }
} else {
    Write-Host "[clean] 跳过 SDK 恢复（FLUTTER_ROOT='$flutterRoot'，或它不是 git 仓库）"
}

# ---- 3) 删掉可能已被打过补丁的 pub 包，强制重新解压出干净副本 -----------------
# 实测：删掉目录后 `pub get` 会重新解出该包（不需要联网重下，pub 有本地副本）。
$patchedPkgs = @('material_ui', 'cupertino_ui')
foreach ($name in $patchedPkgs) {
    $dir = Get-PkgDir $name
    if ($dir) {
        Write-Host "[clean] 删除 $($dir.Name)（稍后由 pub get 重新解出干净副本）"
        Remove-Item $dir.FullName -Recurse -Force
    }
}

# ---- 4) 依赖 -----------------------------------------------------------------
flutter pub get
if ($LASTEXITCODE -ne 0) { throw "flutter pub get 失败（$LASTEXITCODE）" }

# ---- 5) 给重新解出的包补 .git，供 patch.ps1 使用 ------------------------------
foreach ($name in $patchedPkgs) {
    $dir = Get-PkgDir $name
    if (-not $dir) { throw "pub get 之后仍找不到 $name（找过：$($cacheRoots -join ', ')）" }
    if (Test-Path (Join-Path $dir.FullName '.git')) {
        Write-Host "$($dir.Name): 已有 .git，跳过"
        continue
    }
    # 空仓库就够：git apply 只要求在一个 work tree 里（默认不允许在仓库外打补丁）
    git -C $dir.FullName init -q
    if ($LASTEXITCODE -ne 0) { throw "git init 失败：$($dir.FullName)" }
    Write-Host "$($dir.Name): 已补临时 .git"
}

# ---- 6) 版本号与 dart-define（生成被 gitignore 的 pili_release.json）----------
# build.ps1 最后会往 $env:GITHUB_ENV 追加 version=...；该变量只在 Actions 里存在，
# 本地跑时若未定义，Add-Content 会直接报错。这里用一个临时文件兜住。
# 注意：build.ps1 会改写 pubspec.yaml 的 version 行——这一步要放在"恢复仓库"之后。
$env:GITHUB_ENV ??= Join-Path ([System.IO.Path]::GetTempPath()) 'pili_ci_env'
if (-not (Test-Path $env:GITHUB_ENV)) { New-Item -ItemType File -Path $env:GITHUB_ENV -Force | Out-Null }

& (Join-Path $root 'lib/scripts/build.ps1')
if ($LASTEXITCODE -ne 0) { throw "build.ps1 失败（$LASTEXITCODE）" }

# ---- 7) 打补丁 ---------------------------------------------------------------
# 平台参数透给 patch.ps1：它按 iOS / android / macos / linux / windows 选不同补丁集
# （iOS 会额外打 geetest_ios 与 bottom_sheet_ios_piliplus）。
& (Join-Path $root 'lib/scripts/patch.ps1') $Platform
if ($LASTEXITCODE -ne 0) { throw "patch.ps1 $Platform 失败（$LASTEXITCODE）" }

Write-Host "$Platform 预处理完成。"
