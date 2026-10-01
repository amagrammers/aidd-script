# aidd-script

aidd のツール（ai-harness-main / aidd-create-docs / aidd-template / aidd-docs）をインストール・更新するための
セットアップスクリプトと、`aidd` CLI 本体（.NET）を持つリポジトリ。

## 構成

| パス | 役割 |
| -- | -- |
| `setup.sh`（Linux / WSL）/ `setup_macos.sh`（macOS）/ `setup.ps1`（Windows） | 初回ブートストラップ用スクリプト。curl/`Invoke-WebRequest` でダウンロードしてから実行する delivery を想定する |
| `src/main/` | `aidd` CLI 本体（`aidd.csproj`）のソース |

## setup.sh / setup_macos.sh / setup.ps1 が行うこと

1. git / .NET SDK 10 の確認・導入（Linux は各ディストリのパッケージマネージャ、macOS は Homebrew〔無ければ Homebrew 自体も導入〕、Windows は winget）
2. `aidd-script` 自身を `~/.aidd/aidd-script` へ clone し、そこから `aidd` CLI を `~/.aidd/aidd-script/publish` へ発行
3. `aidd-template` を `~/.aidd/aidd-template` へ clone（既にあれば差分があるときだけ更新。`aidd --init` が中身をコピーする）
4. `aidd --update-aidd` で `~/.aidd` のツール一式（ai-harness-main / aidd-create-docs / aidd-template / aidd-docs / aidd-script）を clone・発行
5. 各ツールの `publish/` を PATH へ追加し、`aidd --version` / `ai-harness-main --doctor` / `aidd-create-docs --version` で動作確認

プロジェクトには触れない（プロジェクトの配線・初期化は行わない）。

再実行しても安全（各手順は導入済みなら読み飛ばす。ただし `aidd --update-aidd` が管理するツール一式は
仕様上、毎回最新へ差し替わる）。

### 使い方

```bash
# ダウンロードしてから実行する（curl | bash は使わない。詳細は setup.sh 冒頭のコメントを参照）
curl -fsSL -o /tmp/aidd-setup.sh https://raw.githubusercontent.com/amagrammers/aidd-script/main/setup.sh
bash /tmp/aidd-setup.sh
```

```bash
# macOS
curl -fsSL -o /tmp/aidd-setup-macos.sh https://raw.githubusercontent.com/amagrammers/aidd-script/main/setup_macos.sh
bash /tmp/aidd-setup-macos.sh
```

macOS 版は PATH を `~/.zshrc`（`$SHELL` が bash のときは `~/.bash_profile`）へ書く。Apple Silicon（`osx-arm64`）と
Intel（`osx-x64`）の両方に対応し、macOS 以外で実行するとエラーで止まる。

```powershell
irm https://raw.githubusercontent.com/amagrammers/aidd-script/main/setup.ps1 -OutFile aidd-setup.ps1
.\aidd-setup.ps1
```

実行するディレクトリは問わない。

共通オプション（`setup.sh` / `setup_macos.sh` / `setup.ps1` とも。書式は `--org <値>` で統一）:

| オプション | 既定値 | 内容 |
| -- | -- | -- |
| `--protocol` | `https` | リポジトリ取得プロトコル（`https` / `ssh`） |
| `--ssh-name` | `github.com` | ssh の URL `git@<ssh-name>:<org>/<repo>.git` のホスト部分。`~/.ssh/config` の `Host` エイリアス名を指定する（アカウントごとに鍵を使い分ける用途）。`--protocol ssh` のときだけ指定できる（https で指定するとエラー） |
| `--org` | `amagrammers` | 取得元の GitHub org |
| `--branch` | `main` | 取得元ブランチ |

例: `.\aidd-setup.ps1 --org rgp-lab`

## aidd CLI（`src/main/`）

```
aidd --version
aidd --update-aidd [--protocol https|ssh] [--ssh-name <name>] [--org <org>] [--branch <branch>]
aidd --init
aidd --update-project
```

- **`aidd --version`** — `aidd <バージョン>+<コミット>` を標準出力へ出す（バージョンは `aidd.csproj` の `<Version>`）。引数は取らない。setup の動作確認が使う

`--update-aidd` は `~/.aidd`（マシン側）、`--init` と `--update-project` はカレントディレクトリ（プロジェクト側）が対象。

- **`aidd --init`** — 引数なし。取得はせず、`~/.aidd/aidd-template` の中身と `~/.aidd/aidd-docs/core`
  （`.docs/` として配置）をカレントディレクトリへコピーする。`aidd-template` 側の `.git/` と `.docs/` は
  コピーしない。`~/.aidd` に無ければ `aidd --update-aidd` を先に実行するよう促して中断する。書き込み前に
  衝突を全件検査し、既存ファイルと衝突するものが 1 つでもあれば何も変更せず中断する
- **`aidd --update-aidd`** — `~/.aidd/<repo>` に ai-harness-main・aidd-create-docs・aidd-script・aidd-template・
  aidd-docs の clone を置き、指定した org/branch と比べて**差分があるときだけ**更新する（`git fetch` →
  HEAD と比較 → 差分があれば `reset --hard` で揃える。ローカル変更は破棄される）。差分が無ければ何もしない。
  ai-harness-main・aidd-create-docs・aidd-script（aidd 自身）は更新があったとき、または発行物が無いときに
  clone 内からビルドし、self-contained 単一ファイルとして `<repo>/publish/` へ再発行する。
  aidd 自身の再発行は最後に行い、実行中のプロセスは旧版のまま終了する（次回から新版）。実行中の exe は
  上書きできないため、既存の exe を `.old` へ改名してから発行する。aidd-template・aidd-docs はビルドしない。
  clone を持たない旧配置があれば削除して clone し直す
- **`aidd --update-project`** — 引数なし。取得はせず、`~/.aidd/aidd-docs/core` でカレントディレクトリの
  `.docs/` を丸ごと置換する（`.docs/` にしか無いファイルは消える）。`~/.aidd` に無ければ
  `aidd --update-aidd` を先に実行するよう促して中断する。途中で失敗しても既存の `.docs/` は残る

### `~/.aidd` の構成

```
~/.aidd/
  aidd-script/        clone（setup が初回に配置。以降は `--update-aidd` が更新・再発行する）
    publish/          aidd 実行体（PATH）
  ai-harness-main/    clone
    publish/          ai-harness-main 実行体と lib/（PATH）
  aidd-create-docs/   clone
    publish/          aidd-create-docs 実行体と lib/（PATH）
  aidd-template/      clone（`--init` が中身をコピーする）
  aidd-docs/          clone（`--init` / `--update-project` が core/ を読む）
```

## 関係

`ai-harness` ワークスペースの隣接プロダクト（`ai-harness-main` / `aidd-create-docs` / `aidd-docs` /
`aidd-template`）とは別リポジトリ・別ライフサイクル。本リポジトリはそれらを導入・更新する側であり、
コード上の参照関係は持たない（`aidd` CLI が実行時に git 経由で取得するのみ）。
