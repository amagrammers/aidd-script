#Requires -Version 5.1
<#
aidd-template ベースのプロジェクトをセットアップするスクリプト。
git / .NET SDK 10 を確認し、無ければ導入したうえで、aidd-script 本体（aidd CLI）を
$env:USERPROFILE\.aidd\aidd へ発行する。以降のツール一式（ai-harness-main / aidd-create-docs /
aidd-docs）の導入は、発行した aidd CLI（`aidd --update-aidd`）に委譲する。
あわせて ai-harness-main はこのプロジェクトへ配線する
（.claude/settings.json の hook 追記 ＋ ai-harness-aidd の有効化）。
あわせて git の pre-commit フック（.githooks/）を配線する。

Invoke-WebRequest 等でダウンロードしてから実行する delivery を想定し、対象プロジェクトの
ルートディレクトリで実行する（スクリプト自身の設置場所は問わない。$ProjectRoot は
実行時のカレントディレクトリ）。

再実行しても安全（各手順は導入済みなら読み飛ばす。ただし aidd --update-aidd が管理する
ai-harness-main / aidd-create-docs / aidd-docs は、aidd --update-aidd の仕様どおり毎回最新へ
差し替わる）。
#>

$ErrorActionPreference = 'Stop'

# setup.sh と引数の書式を揃えるため、param() ではなく $args を自前で解釈する
# （param() だと -Org 形式になり、--org が位置引数として別の引数へ束縛されてしまう）。
$Protocol = 'https'   # https | ssh
$SshName = $null      # ssh のときの <ssh-name>@github.com の部分。未指定なら git
$Org = 'amagrammers'
$Branch = 'main'

for ($i = 0; $i -lt $args.Count; $i += 2) {
    if ($i + 1 -ge $args.Count) { throw "[setup] $($args[$i]) には値が必要です。" }
    switch ($args[$i]) {
        '--protocol' { $Protocol = $args[$i + 1] }
        '--ssh-name' { $SshName = $args[$i + 1] }
        '--org'      { $Org = $args[$i + 1] }
        '--branch'   { $Branch = $args[$i + 1] }
        default      { throw "[setup] 不明な引数です: $($args[$i])" }
    }
}

if ($Protocol -notin @('https', 'ssh')) {
    throw "[setup] --protocol は https か ssh のいずれかです: $Protocol"
}

if ($SshName -and $Protocol -ne 'ssh') {
    throw '[setup] --ssh-name は --protocol ssh のときだけ指定できます。'
}

switch ($Protocol) {
    'https' { $AiddScriptRepoUrl = "https://github.com/$Org/aidd-script.git" }
    'ssh'   { $AiddScriptRepoUrl = "$(if ($SshName) { $SshName } else { 'git' })@github.com`:$Org/aidd-script.git" }
}

$InstallDir = Join-Path $env:USERPROFILE '.aidd'
# ~/.aidd/<リポジトリ名> が各リポジトリの clone、ビルド成果物はその直下の publish/ に置く。
# 各ツールが同じ lib/ を共有すると、互いに無関係なプラグイン DLL が同じフォルダに混在して
# しまう（プラグインローダは lib/ 配下の *.dll を全走査するため）。ツールごとに別の
# publish/ を持たせ、発行先・PATH 登録とも独立させる。
$AiddRepoDir = Join-Path $InstallDir 'aidd-script'
$AiddInstallDir = Join-Path $AiddRepoDir 'publish'
$HarnessInstallDir = Join-Path $InstallDir 'ai-harness-main\publish'
$CreateDocsInstallDir = Join-Path $InstallDir 'aidd-create-docs\publish'
$ProjectRoot = (Get-Location).Path
$Rid = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'win-arm64' } else { 'win-x64' }

function Write-Step($message) {
    Write-Host "[setup] $message"
}

function Test-Command($name) {
    return [bool](Get-Command $name -ErrorAction SilentlyContinue)
}

function Sync-PathFromEnvironment {
    $machine = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $user = [Environment]::GetEnvironmentVariable('Path', 'User')
    $env:Path = @($machine, $user) -join ';'
}

function Install-Git {
    if (Test-Command git) {
        Write-Step "git: OK ($(git --version))"
        return
    }
    if (-not (Test-Command winget)) {
        throw 'git が見つからず winget も使えません。git を手動でインストールしてから再実行してください。'
    }
    Write-Step 'git をインストールします…'
    winget install --id Git.Git -e --source winget --accept-package-agreements --accept-source-agreements
    Sync-PathFromEnvironment
    if (-not (Test-Command git)) {
        throw 'git のインストールに失敗しました。シェルを再起動してから再実行してください。'
    }
}

function Install-DotNetSdk {
    $hasSdk10 = $false
    if (Test-Command dotnet) {
        $sdks = & dotnet --list-sdks 2>$null
        $hasSdk10 = [bool]($sdks | Where-Object { $_ -match '^10\.' })
    }
    if ($hasSdk10) {
        Write-Step '.NET SDK 10: OK'
        return
    }
    if (-not (Test-Command winget)) {
        throw '.NET SDK 10 が見つからず winget も使えません。手動でインストールしてから再実行してください。'
    }
    Write-Step '.NET SDK 10 をインストールします…'
    winget install --id Microsoft.DotNet.SDK.10 -e --source winget --accept-package-agreements --accept-source-agreements
    Sync-PathFromEnvironment
    if (-not (Test-Command dotnet)) {
        throw '.NET SDK のインストールに失敗しました。シェルを再起動してから再実行してください。'
    }
}

# aidd CLI 自身は aidd --update-aidd の対象外（自己更新はしない）ため、setup が更新する。
# clone と remote の差分があるとき、または発行物が無いときだけ発行する（差分が無ければ読み飛ばす）。
function Build-Aidd {
    $exePath = Join-Path $AiddInstallDir 'aidd.exe'
    $changed = $false

    if (-not (Test-Path (Join-Path $AiddRepoDir '.git'))) {
        Write-Step "aidd-script を $AiddRepoDir へ clone します（branch: $Branch）…"
        Remove-Item -Recurse -Force $AiddRepoDir -ErrorAction SilentlyContinue
        & git clone --quiet --depth 1 --branch $Branch $AiddScriptRepoUrl $AiddRepoDir
        if ($LASTEXITCODE -ne 0) { throw 'aidd-script のクローンに失敗しました。' }
        $changed = $true
    }
    else {
        # org / protocol / ssh-name の変更に追随するため、毎回 remote を指定どおりに揃える
        & git -C $AiddRepoDir remote set-url origin $AiddScriptRepoUrl
        if ($LASTEXITCODE -ne 0) { throw 'git remote set-url に失敗しました。' }
        & git -C $AiddRepoDir fetch --quiet --depth 1 origin $Branch
        if ($LASTEXITCODE -ne 0) { throw 'aidd-script の fetch に失敗しました。' }
        $head = (& git -C $AiddRepoDir rev-parse HEAD)
        $remote = (& git -C $AiddRepoDir rev-parse FETCH_HEAD)
        if ($head -ne $remote) {
            Write-Step 'aidd-script に差分があります。更新します…'
            & git -C $AiddRepoDir reset --quiet --hard FETCH_HEAD
            if ($LASTEXITCODE -ne 0) { throw 'git reset に失敗しました。' }
            $changed = $true
        }
    }

    if ((-not $changed) -and (Test-Path $exePath)) {
        Write-Step "aidd: OK ($exePath)"
        return
    }

    Write-Step "aidd を $AiddInstallDir へ発行します（self-contained 単一ファイル）…"
    # -tl:off は dotnet の要約表示（ターミナルロガー）を切る。端末へ直に出すと、日本語環境で
    # 「3.1 秒後に 成功しました をビルド」のように語順の崩れた要約になるため。
    & dotnet publish (Join-Path $AiddRepoDir 'src\main\aidd.csproj') `
        -c Release -r $Rid --self-contained true `
        -p:PublishSingleFile=true `
        -tl:off -o $AiddInstallDir
    if ($LASTEXITCODE -ne 0) { throw 'dotnet publish に失敗しました。' }

    if (-not (Test-Path $exePath)) {
        throw "aidd の発行に失敗しました（$exePath が見つかりません）。"
    }
    Write-Step "aidd を発行しました: $exePath"
}

function Add-InstallDirToUserPath([string]$Dir) {
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    $parts = @($userPath -split ';' | Where-Object { $_ -ne '' })
    if ($parts -notcontains $Dir) {
        Write-Step "ユーザー PATH に $Dir を追加します…"
        $joined = if ($userPath) { $userPath.TrimEnd(';') + ';' + $Dir } else { $Dir }
        [Environment]::SetEnvironmentVariable('Path', $joined, 'User')
    } else {
        Write-Step "PATH: OK（$Dir は登録済み）"
    }
    Sync-PathFromEnvironment
}

# ai-harness-main / aidd-create-docs / aidd-docs の発行・取得は aidd --update-aidd に委譲する
# （aidd-script/src/main/Program.cs 側と二重にロジックを持たないため）。
function Update-ToolSuite {
    Add-InstallDirToUserPath $AiddInstallDir
    Write-Step '.aidd のツール一式を aidd --update-aidd で発行します…'
    $aiddExe = Join-Path $AiddInstallDir 'aidd.exe'
    $sshArgs = if ($SshName) { @('--ssh-name', $SshName) } else { @() }
    & $aiddExe --update-aidd --protocol $Protocol @sshArgs --org $Org --branch $Branch
    if ($LASTEXITCODE -ne 0) { throw 'aidd --update-aidd に失敗しました。' }
    Add-InstallDirToUserPath $HarnessInstallDir
    Add-InstallDirToUserPath $CreateDocsInstallDir
}

function Initialize-GitRepo {
    & git -C $ProjectRoot rev-parse --git-dir *> $null
    if ($LASTEXITCODE -eq 0) {
        Write-Step 'git リポジトリ: OK'
        return
    }

    Write-Step 'このプロジェクトはまだ git リポジトリではありません。初期化して初回コミットを作成します…'
    & git -C $ProjectRoot init -q
    if ($LASTEXITCODE -ne 0) { throw 'git init に失敗しました。' }

    & git -C $ProjectRoot add -A
    & git -C $ProjectRoot commit -q -m 'chore: aidd-template から初期化'
    if ($LASTEXITCODE -ne 0) { throw '初回コミットの作成に失敗しました。' }
}

function Set-GitHooksPath {
    $current = & git -C $ProjectRoot config --local --get core.hooksPath 2>$null
    if ($current -eq '.githooks') {
        Write-Step 'git hooks: OK（core.hooksPath は設定済み）'
        return
    }

    Write-Step 'git hooks を配線します（core.hooksPath=.githooks）…'
    & git -C $ProjectRoot config --local core.hooksPath .githooks
    if ($LASTEXITCODE -ne 0) { throw 'core.hooksPath の設定に失敗しました。' }
}

# --- main ---
Install-Git
Install-DotNetSdk
Build-Aidd
Update-ToolSuite
Initialize-GitRepo
Set-GitHooksPath

$exe = Join-Path $HarnessInstallDir 'ai-harness-main.exe'
$createDocsExe = Join-Path $CreateDocsInstallDir 'aidd-create-docs.exe'

Write-Step 'プロジェクトを配線します（settings.json の hook ＋ ai-harness-aidd の有効化）…'
& $exe --init $ProjectRoot --enable ai-harness-aidd
if ($LASTEXITCODE -ne 0) { throw '--init に失敗しました。' }

Write-Step '動作確認…'
& $exe --doctor
& $exe --validate $ProjectRoot
if ($LASTEXITCODE -ne 0) {
    throw '--validate が失敗しました。上記のログを確認してください。'
}
& $createDocsExe --version
if ($LASTEXITCODE -ne 0) { throw 'aidd-create-docs --version に失敗しました。' }

Write-Step 'セットアップが完了しました。'
