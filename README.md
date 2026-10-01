# aidd-script

`aidd-template` ベースのプロジェクトを立ち上げる・保守するためのセットアップスクリプトと、
`aidd` CLI 本体（.NET）を持つリポジトリ。

## 構成

| パス | 役割 |
| -- | -- |
| `setup.sh` / `setup.ps1` | 初回ブートストラップ用スクリプト。curl/`Invoke-WebRequest` でダウンロードしてから実行する delivery を想定し、対象プロジェクトのルートディレクトリで実行する |
| `src/main/` | `aidd` CLI 本体（`aidd.csproj`）のソース |

## setup.sh / setup.ps1 が行うこと

1. git / .NET SDK 10 の確認・導入
2. `aidd-script` 自身を `~/.aidd/aidd-script` へ clone し、そこから `aidd` CLI を `~/.aidd/aidd-script/publish` へ発行
3. `aidd --update-aidd` で `~/.aidd` のツール一式（ai-harness-main / aidd-create-docs / aidd-docs）を clone・発行
4. git リポジトリの初期化・pre-commit フック（`.githooks/`）の配線
5. `ai-harness-main --init --enable ai-harness-aidd` でこのプロジェクトへ hook を配線し、`--doctor` / `--validate` で動作確認

再実行しても安全（各手順は導入済みなら読み飛ばす。ただし `aidd --update-aidd` が管理するツール一式は
仕様上、毎回最新へ差し替わる）。

### 使い方

```bash
# ダウンロードしてから実行する（curl | bash は使わない。詳細は setup.sh 冒頭のコメントを参照）
curl -fsSL -o /tmp/aidd-setup.sh https://raw.githubusercontent.com/amagrammers/aidd-script/main/setup.sh
bash /tmp/aidd-setup.sh
```

```powershell
irm https://raw.githubusercontent.com/amagrammers/aidd-script/main/setup.ps1 -OutFile aidd-setup.ps1
.\aidd-setup.ps1
```

いずれも対象プロジェクトのルートディレクトリで実行する。

共通オプション（`setup.sh` / `setup.ps1` とも。書式は `--org <値>` で統一）:

| オプション | 既定値 | 内容 |
| -- | -- | -- |
| `--protocol` | `https` | リポジトリ取得プロトコル（`https` / `ssh`） |
| `--ssh-name` | `git` | ssh の URL `<ssh-name>@github.com:<org>/<repo>.git` のユーザー名部分。`--protocol ssh` のときだけ指定できる（https で指定するとエラー） |
| `--org` | `amagrammers` | 取得元の GitHub org |
| `--branch` | `main` | 取得元ブランチ |

例: `.\aidd-setup.ps1 --org rgp-lab`

## aidd CLI（`src/main/`）

```
aidd --update-aidd [--protocol https|ssh] [--ssh-name <name>] [--org <org>] [--branch <branch>]
aidd --update-project
```

2 つは対象が異なる。`--update-aidd` は `~/.aidd`（マシン側）、`--update-project` はカレントディレクトリ（プロジェクト側）。

- **`aidd --update-aidd`** — `~/.aidd/<repo>` に ai-harness-main・aidd-create-docs・aidd-docs の clone を
  置き、指定した org/branch と比べて**差分があるときだけ**更新する（`git fetch` → HEAD と比較 →
  差分があれば `reset --hard` で揃える。ローカル変更は破棄される）。差分が無ければ何もしない。
  ai-harness-main・aidd-create-docs は更新があったとき、または発行物が無いときに clone 内からビルドし、
  self-contained 単一ファイルとして `<repo>/publish/` へ再発行する。aidd-docs はビルドしない。
  clone を持たない旧配置があれば削除して clone し直す
- **`aidd --update-project`** — 引数なし。取得はせず、`~/.aidd/aidd-docs/core` でカレントディレクトリの
  `.docs/` を丸ごと置換する（`.docs/` にしか無いファイルは消える）。`~/.aidd` に無ければ
  `aidd --update-aidd` を先に実行するよう促して中断する。途中で失敗しても既存の `.docs/` は残る

### `~/.aidd` の構成

```
~/.aidd/
  aidd-script/        clone（setup が配置。自己更新はしない）
    publish/          aidd 実行体（PATH）
  ai-harness-main/    clone
    publish/          ai-harness-main 実行体と lib/（PATH）
  aidd-create-docs/   clone
    publish/          aidd-create-docs 実行体と lib/（PATH）
  aidd-docs/          clone（`--update-project` が core/ を読む）
```

## 関係

`ai-harness` ワークスペースの隣接プロダクト（`ai-harness-main` / `aidd-create-docs` / `aidd-docs` /
`aidd-template`）とは別リポジトリ・別ライフサイクル。本リポジトリはそれらを導入・更新する側であり、
コード上の参照関係は持たない（`aidd` CLI が実行時に git 経由で取得するのみ）。
