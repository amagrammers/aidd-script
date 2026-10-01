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
2. `aidd-script` 自身を clone し、`aidd` CLI を `~/.aidd/aidd` へ発行
3. `aidd --update-aidd` で `~/.aidd` のツール一式（ai-harness-main / aidd-create-docs / aidd-docs）を発行・取得
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
| `--org` | `amagrammers` | 取得元の GitHub org |
| `--branch` | `main` | 取得元ブランチ |

例: `.\aidd-setup.ps1 --org rgp-lab`

## aidd CLI（`src/main/`）

```
aidd --update-aidd [--protocol https|ssh] [--org <org>] [--branch <branch>]
aidd --update-project
```

2 つは対象が異なる。`--update-aidd` は `~/.aidd`（マシン側）、`--update-project` はカレントディレクトリ（プロジェクト側）。

- **`aidd --update-aidd`** — `~/.aidd` 配下の ai-harness-main・aidd-create-docs・aidd-docs を、
  指定した org/branch から取得し直して最新へ差し替える（ai-harness-main・aidd-create-docs は clone
  してから self-contained 単一ファイルとして再発行、aidd-docs は clone のみ）。
  既存があっても常に差し替える（差分 pull はしない）
- **`aidd --update-project`** — 引数なし。取得はせず、`~/.aidd/aidd-docs/core` でカレントディレクトリの
  `.docs/` を丸ごと置換する（`.docs/` にしか無いファイルは消える）。`~/.aidd` に無ければ
  `aidd --update-aidd` を先に実行するよう促して中断する。途中で失敗しても既存の `.docs/` は残る

## 関係

`ai-harness` ワークスペースの隣接プロダクト（`ai-harness-main` / `aidd-create-docs` / `aidd-docs` /
`aidd-template`）とは別リポジトリ・別ライフサイクル。本リポジトリはそれらを導入・更新する側であり、
コード上の参照関係は持たない（`aidd` CLI が実行時に git 経由で取得するのみ）。
