<#
  一键开锁 —— APK 构建脚本（不依赖 Android Studio / Gradle）

  管线：aapt2 compile -> aapt2 link -> javac -> d8 -> 注入 classes.dex
        -> zipalign -> apksigner

  用法：
    powershell -ExecutionPolicy Bypass -File build.ps1     # 全自动（缺 SDK 会自动下载）
    pwsh -File build.ps1                                   # PowerShell 7 同样可用
    ... -WorkRoot D:\build                                 # 指定构建目录（必须纯 ASCII）
    ... -VersionName 1.2 -VersionCode 3                    # 更换版本号
    ... -SkipDownload                                      # 已有 dl\*.zip 时跳过下载

  三个已踩过的坑（脚本内已处理）：
    1) aapt2 无法打开含中文的路径 —— 所以源工程会被复制到纯 ASCII 的
       $WorkRoot 下再编译。$WorkRoot 本身也必须全 ASCII。
    2) Google 仓库在本机 HTTPS 握手被拦，改用 http:// 下载可正常获取。
    3) javac 会把「过时 API」提示写到 stderr，在 $ErrorActionPreference='Stop'
       下会被 PowerShell 当成终止错误中断构建 —— 故所有外部命令统一走
       Run-Native 包装（失败时才回显输出）。

  注意：本文件必须保存为「UTF-8 with BOM」，否则 PowerShell 5.1 会按 GBK
        解析脚本中的中文，导致语法错误。
#>
[CmdletBinding()]
param(
    [string]$SourceRoot  = '',
    [string]$WorkRoot    = '',
    [string]$OutApk      = '',
    [int]   $VersionCode = 3,
    [string]$VersionName = '1.1',
    [switch]$SkipDownload
)

$ErrorActionPreference = 'Stop'

# PowerShell 5.1 下 -File 场景中 $PSScriptRoot 在 param 默认值里可能为空，故在此兜底
if (-not $SourceRoot) {
    $SourceRoot = if ($PSScriptRoot) { $PSScriptRoot }
                  elseif ($MyInvocation.MyCommand.Path) { Split-Path -Parent $MyInvocation.MyCommand.Path }
                  else { (Get-Location).Path }
}
if (-not $WorkRoot) { $WorkRoot = Join-Path $env:TEMP 'dormbuild' }
if (-not $OutApk)   { $OutApk   = Join-Path $SourceRoot "DormUnlock-v$VersionName-debug.apk" }
$SourceRoot = (Resolve-Path $SourceRoot).Path

$BuildToolsZip = 'build-tools_r35_windows.zip'
$PlatformZip   = 'platform-35_r02.zip'
$BtVerDir      = 'android-15'                     # build-tools 解压后的版本子目录名
$BaseUrl       = 'http://dl.google.com/android/repository'
$MinSdk        = 24
$TargetSdk     = 35

function Info($m) { Write-Host "==> $m" -ForegroundColor Cyan }
function Fail($m) { Write-Host "!!! $m" -ForegroundColor Red; exit 1 }

<#
  运行外部命令。返回其输出（字符串数组），失败则回显输出并终止脚本。
  关键点：临时把 ErrorActionPreference 放宽为 Continue，否则原生命令写入
  stderr 的内容（如 javac 的提示）在 Stop 模式下会变成终止错误。
#>
function Run-Native {
    param(
        [Parameter(Mandatory = $true)][scriptblock]$Command,
        [Parameter(Mandatory = $true)][string]$What
    )
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = & $Command 2>&1
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $prev
    }
    if ($code -ne 0) {
        $output | ForEach-Object { Write-Host $_ }
        Fail "$What 失败（exit code $code）"
    }
    return $output
}

# ---------------------------------------------------------------- 前置检查
if ($WorkRoot -notmatch '^[\x20-\x7E]+$') {
    Fail "构建目录必须全为 ASCII 字符（aapt2 不支持中文路径）：$WorkRoot`n    请用 -WorkRoot 指定，例如 D:\dormbuild"
}

$jdkCandidates = @($env:JAVA_HOME) + @(
    'C:\Program Files\Java',
    'C:\Program Files\Android\Android Studio\jbr'
) + (Get-ChildItem 'C:\Program Files\Eclipse Adoptium','C:\Program Files\Microsoft','C:\Program Files\Amazon Corretto' `
        -Directory -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName)

$jdk = $null
foreach ($c in $jdkCandidates) {
    if ($c -and (Test-Path (Join-Path $c 'bin\javac.exe')) -and (Test-Path (Join-Path $c 'bin\keytool.exe'))) { $jdk = $c; break }
}
if (-not $jdk) { Fail '找不到同时含 javac 和 keytool 的 JDK（需要 JDK 8+，建议 17）。请设置 JAVA_HOME。' }

$javac   = Join-Path $jdk 'bin\javac.exe'
$keytool = Join-Path $jdk 'bin\keytool.exe'
$env:JAVA_HOME = $jdk
Info "JDK = $jdk"

New-Item -ItemType Directory -Force -Path $WorkRoot, (Join-Path $WorkRoot 'sdk'), (Join-Path $WorkRoot 'out') | Out-Null
Add-Type -AssemblyName System.IO.Compression.FileSystem

# ---------------------------------------------------------------- 1. SDK 组件
$dlDir = Join-Path $SourceRoot 'dl'
New-Item -ItemType Directory -Force -Path $dlDir | Out-Null

foreach ($z in @($BuildToolsZip, $PlatformZip)) {
    $zipPath = Join-Path $dlDir $z
    if ((Test-Path $zipPath) -and (Get-Item $zipPath).Length -gt 1MB) { Info "$z 已存在，跳过下载"; continue }
    if ($SkipDownload) { Fail "缺少 $zipPath 且指定了 -SkipDownload" }
    Info "下载 $z ..."
    Run-Native { & curl.exe -sSL --max-time 2400 -o $zipPath "$BaseUrl/$z" } "下载 $z" | Out-Null
    if ((Get-Item $zipPath).Length -lt 1MB) { Fail "下载结果异常：$zipPath" }
}

foreach ($z in @($BuildToolsZip, $PlatformZip)) {
    $name = [System.IO.Path]::GetFileNameWithoutExtension($z)
    $dest = Join-Path $WorkRoot "sdk\$name"
    if (Test-Path $dest) { Info "$name 已解压，跳过"; continue }
    Info "解压 $z ..."
    [System.IO.Compression.ZipFile]::ExtractToDirectory((Join-Path $dlDir $z), $dest)
}

$bt = Join-Path $WorkRoot "sdk\$([System.IO.Path]::GetFileNameWithoutExtension($BuildToolsZip))\$BtVerDir"
$aj = Join-Path $WorkRoot "sdk\$([System.IO.Path]::GetFileNameWithoutExtension($PlatformZip))\android-$TargetSdk\android.jar"
if (-not (Test-Path (Join-Path $bt 'aapt2.exe'))) { Fail "找不到 aapt2：$bt" }
if (-not (Test-Path $aj))                        { Fail "找不到 android.jar：$aj" }

$aapt2     = Join-Path $bt 'aapt2.exe'
$d8        = Join-Path $bt 'd8.bat'
$zipalign  = Join-Path $bt 'zipalign.exe'
$apksigner = Join-Path $bt 'apksigner.bat'

# ---------------------------------------------------------------- 2. 复制源工程到 ASCII 目录
$proj = Join-Path $WorkRoot 'project'
if (Test-Path $proj) { Remove-Item -Recurse -Force $proj }
Copy-Item -Recurse -Force (Join-Path $SourceRoot 'project') $proj
Info "源工程已复制到 $proj"

$out = Join-Path $WorkRoot 'out'
foreach ($d in @('classes','dex')) {
    if (Test-Path (Join-Path $out $d)) { Remove-Item -Recurse -Force (Join-Path $out $d) }
    New-Item -ItemType Directory -Force -Path (Join-Path $out $d) | Out-Null
}
foreach ($f in @('res.zip','base.apk','unsigned.apk','aligned.apk','DormUnlock.apk')) {
    if (Test-Path (Join-Path $out $f)) { Remove-Item (Join-Path $out $f) -Force }
}

# ---------------------------------------------------------------- 3. 资源
Info 'aapt2 compile 资源'
Run-Native { & $aapt2 compile --dir (Join-Path $proj 'res') -o (Join-Path $out 'res.zip') } 'aapt2 compile' | Out-Null

Info 'aapt2 link 生成基础 APK'
Run-Native {
    & $aapt2 link -o (Join-Path $out 'base.apk') -I $aj `
        --manifest (Join-Path $proj 'AndroidManifest.xml') `
        -A (Join-Path $proj 'assets') `
        --min-sdk-version $MinSdk --target-sdk-version $TargetSdk `
        --version-code $VersionCode --version-name $VersionName `
        (Join-Path $out 'res.zip')
} 'aapt2 link' | Out-Null

# ---------------------------------------------------------------- 4. Java -> dex
Info 'javac 编译 Java 源码'
Run-Native {
    & $javac -source 8 -target 8 -encoding UTF-8 -nowarn `
        -bootclasspath $aj -cp $aj -d (Join-Path $out 'classes') `
        (Join-Path $proj 'src\com\example\dormunlock\MainActivity.java')
} 'javac' | Out-Null

Info 'd8 生成 classes.dex'
$classes = Get-ChildItem (Join-Path $out 'classes') -Recurse -Filter *.class | ForEach-Object { $_.FullName }
Run-Native { & $d8 --min-api $MinSdk --lib $aj --output (Join-Path $out 'dex') $classes } 'd8' | Out-Null

# ---------------------------------------------------------------- 5. 打包 / 对齐 / 签名
Info '注入 classes.dex'
Copy-Item (Join-Path $out 'base.apk') (Join-Path $out 'unsigned.apk') -Force
$zip = [System.IO.Compression.ZipFile]::Open((Join-Path $out 'unsigned.apk'), 'Update')
[System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
    $zip, (Join-Path $out 'dex\classes.dex'), 'classes.dex',
    [System.IO.Compression.CompressionLevel]::Optimal) | Out-Null
$zip.Dispose()

Info 'zipalign 对齐'
Run-Native { & $zipalign -p -f 4 (Join-Path $out 'unsigned.apk') (Join-Path $out 'aligned.apk') } 'zipalign' | Out-Null

$ks = Join-Path $SourceRoot 'debug.keystore'
if (-not (Test-Path $ks)) {
    Info '生成 debug.keystore'
    Run-Native {
        & $keytool -genkeypair -keystore $ks -storepass android -keypass android `
            -alias androiddebugkey -keyalg RSA -keysize 2048 -validity 10950 `
            -dname "CN=Android Debug,O=Android,C=US"
    } 'keytool' | Out-Null
} else {
    Info "复用已有签名 $ks"
}

Info 'apksigner 签名'
Run-Native {
    & $apksigner sign --ks $ks --ks-pass pass:android --key-pass pass:android `
        --out (Join-Path $out 'DormUnlock.apk') (Join-Path $out 'aligned.apk')
} 'apksigner sign' | Out-Null

# ---------------------------------------------------------------- 6. 校验 + 输出
Info '校验签名与对齐'
$verify = Run-Native { & $apksigner verify --verbose (Join-Path $out 'DormUnlock.apk') } 'APK 签名校验'
$verify | ForEach-Object { Write-Host "    $_" }
Run-Native { & $zipalign -c 4 (Join-Path $out 'DormUnlock.apk') } 'APK 对齐校验' | Out-Null

Copy-Item (Join-Path $out 'DormUnlock.apk') $OutApk -Force
$apk = Get-Item $OutApk
$sha = (Get-FileHash $OutApk -Algorithm SHA256).Hash
Write-Host ''
Info "构建完成：$($apk.FullName)"
Write-Host "    大小   : $($apk.Length) bytes"
Write-Host "    SHA256 : $sha"
Write-Host ''
Write-Host '安装到手机（需开启 USB 调试）：' -ForegroundColor Yellow
Write-Host "    adb install -r `"$($apk.FullName)`"" -ForegroundColor Yellow
