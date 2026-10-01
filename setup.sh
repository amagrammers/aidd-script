#!/usr/bin/env bash
# aidd-template ベースのプロジェクトをセットアップするスクリプト。
# git / .NET SDK 10 を確認し、無ければ導入したうえで、aidd-script 本体（aidd CLI）を
# $HOME/.aidd/aidd へ発行する。以降のツール一式（ai-harness-main / aidd-create-docs /
# aidd-docs）の導入は、発行した aidd CLI（`aidd --update-aidd`）に委譲する。
# あわせて ai-harness-main はこのプロジェクトへ配線する
# （.claude/settings.json の hook 追記 ＋ ai-harness-aidd の有効化）。
# あわせて git の pre-commit フック（.githooks/）を配線する。
#
# curl 等でダウンロードしてから実行する delivery を想定し、対象プロジェクトの
# ルートディレクトリで実行する（スクリプト自身の設置場所は問わない。PROJECT_ROOT は
# 実行時のカレントディレクトリ）。
#
# 再実行しても安全（各手順は導入済みなら読み飛ばす。ただし aidd --update-aidd が管理する
# ai-harness-main / aidd-create-docs / aidd-docs は、aidd --update-aidd の仕様どおり毎回最新へ
# 差し替わる）。

set -euo pipefail

# 最小構成の Linux イメージには ICU が入っておらず、素の dotnet CLI がそれだけで起動に失敗する。
# 各リポジトリの csproj で InvariantGlobalization を指定済みだが、ビルドに使う dotnet CLI
# 自身にも同じモードを強制しておく（ICU の有無に依存しない）。
export DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=1

# 5 リポジトリはすべて同一 org 配下。URL は「PROTOCOL + ORG/<リポジトリ>.git」で組む。
PROTOCOL="https"   # https | ssh
ORG="amagrammers"
BRANCH="main"
INSTALL_DIR="${HOME}/.aidd"
# ~/.aidd/<リポジトリ名> が各リポジトリの clone、ビルド成果物はその直下の publish/ に置く。
# 各ツールが同じ lib/ を共有すると、互いに無関係なプラグイン DLL が同じフォルダに混在して
# しまう（プラグインローダは lib/ 配下の *.dll を全走査するため）。ツールごとに別の
# publish/ を持たせ、発行先・PATH 登録とも独立させる。
AIDD_REPO_DIR="${INSTALL_DIR}/aidd-script"
AIDD_INSTALL_DIR="${AIDD_REPO_DIR}/publish"
HARNESS_INSTALL_DIR="${INSTALL_DIR}/ai-harness-main/publish"
CREATE_DOCS_INSTALL_DIR="${INSTALL_DIR}/aidd-create-docs/publish"
PROJECT_ROOT="$(pwd)"
PROFILE_FILE="${HOME}/.bashrc"

while [ $# -gt 0 ]; do
  case "$1" in
    --protocol) PROTOCOL="$2"; shift 2 ;;
    --org) ORG="$2"; shift 2 ;;
    --branch) BRANCH="$2"; shift 2 ;;
    *) echo "[setup] 不明な引数です: $1" >&2; exit 1 ;;
  esac
done

case "$PROTOCOL" in
  https) AIDD_SCRIPT_REPO_URL="https://github.com/${ORG}/aidd-script.git" ;;
  ssh)   AIDD_SCRIPT_REPO_URL="git@github.com:${ORG}/aidd-script.git" ;;
  *) echo "[setup] --protocol は https か ssh のいずれかです: $PROTOCOL" >&2; exit 1 ;;
esac

case "$(uname -m)" in
  x86_64|amd64) RID="linux-x64" ;;
  aarch64|arm64) RID="linux-arm64" ;;
  *) echo "[setup] 未対応のアーキテクチャです: $(uname -m)" >&2; exit 1 ;;
esac

log() { echo "[setup] $*"; }

detect_pkg_manager() {
  if command -v apt-get >/dev/null 2>&1; then echo apt-get
  elif command -v dnf >/dev/null 2>&1; then echo dnf
  elif command -v yum >/dev/null 2>&1; then echo yum
  elif command -v pacman >/dev/null 2>&1; then echo pacman
  else echo none
  fi
}

as_root() {
  if [ "$(id -u)" -eq 0 ]; then
    "$@"
  elif command -v sudo >/dev/null 2>&1; then
    sudo "$@"
  else
    echo "[setup] root 権限が無く sudo も使えません。手動で実行してください: $*" >&2
    exit 1
  fi
}

install_package() {
  local pkg="$1"
  case "$(detect_pkg_manager)" in
    apt-get) as_root apt-get update -y && as_root apt-get install -y "$pkg" ;;
    dnf)     as_root dnf install -y "$pkg" ;;
    yum)     as_root yum install -y "$pkg" ;;
    pacman)  as_root pacman -Sy --noconfirm "$pkg" ;;
    *) echo "[setup] 対応するパッケージマネージャが見つかりません。${pkg} を手動でインストールしてください。" >&2; exit 1 ;;
  esac
}

install_git() {
  if command -v git >/dev/null 2>&1; then
    log "git: OK ($(git --version))"
    return
  fi
  log "git をインストールします…"
  install_package git
  command -v git >/dev/null 2>&1 || { echo "[setup] git のインストールに失敗しました。" >&2; exit 1; }
}

install_dotnet_sdk() {
  if command -v dotnet >/dev/null 2>&1 && dotnet --list-sdks 2>/dev/null | grep -q '^10\.'; then
    log ".NET SDK 10: OK"
    return
  fi
  log ".NET SDK 10 をインストールします…"
  command -v curl >/dev/null 2>&1 || install_package curl

  local installer
  installer="$(mktemp)"
  curl -fsSL https://dot.net/v1/dotnet-install.sh -o "$installer"
  bash "$installer" --channel 10.0 --install-dir "${HOME}/.dotnet"
  rm -f "$installer"

  local path_line='export PATH="$HOME/.dotnet:$PATH"'
  if ! grep -qF "$path_line" "$PROFILE_FILE" 2>/dev/null; then
    echo "$path_line" >> "$PROFILE_FILE"
  fi
  export PATH="${HOME}/.dotnet:${PATH}"

  command -v dotnet >/dev/null 2>&1 || { echo "[setup] .NET SDK のインストールに失敗しました。" >&2; exit 1; }
}

# aidd CLI 自身は aidd --update-aidd の対象外（自己更新はしない）。再実行時は既に発行済みなら
# 読み飛ばす。最新へ差し替えたい場合は $AIDD_REPO_DIR を消してから再実行する。
build_aidd() {
  local exe_path="${AIDD_INSTALL_DIR}/aidd"
  if [ -x "$exe_path" ]; then
    log "aidd: OK ($exe_path)"
    return
  fi

  if [ ! -d "${AIDD_REPO_DIR}/.git" ]; then
    log "aidd-script を ${AIDD_REPO_DIR} へ clone します（branch: ${BRANCH}）…"
    rm -rf "$AIDD_REPO_DIR"
    git clone --quiet --depth 1 --branch "$BRANCH" "$AIDD_SCRIPT_REPO_URL" "$AIDD_REPO_DIR"
  fi

  log "aidd を ${AIDD_INSTALL_DIR} へ発行します（self-contained 単一ファイル）…"
  # -tl:off は dotnet の要約表示（ターミナルロガー）を切る。端末へ直に出すと、日本語環境で
  # 「3.1 秒後に 成功しました をビルド」のように語順の崩れた要約になるため。
  dotnet publish "${AIDD_REPO_DIR}/src/main/aidd.csproj" \
    -c Release -r "$RID" --self-contained true \
    -p:PublishSingleFile=true \
    -tl:off -o "$AIDD_INSTALL_DIR"

  [ -x "$exe_path" ] || { echo "[setup] aidd の発行に失敗しました（${exe_path} が見つかりません）。" >&2; exit 1; }
  log "aidd を発行しました: ${exe_path}"
}

add_dir_to_path() {
  local dir="$1"
  local path_line="export PATH=\"${dir}:\$PATH\""
  if ! grep -qF "$path_line" "$PROFILE_FILE" 2>/dev/null; then
    log "PATH に ${dir} を追加します（${PROFILE_FILE}）…"
    echo "$path_line" >> "$PROFILE_FILE"
  else
    log "PATH: OK（${dir} は登録済み）"
  fi
  case ":${PATH}:" in
    *":${dir}:"*) ;;
    *) export PATH="${dir}:${PATH}" ;;
  esac
}

# ai-harness-main / aidd-create-docs / aidd-docs の発行・取得は aidd --update-aidd に委譲する
# （aidd-script/src/main/Program.cs 側と二重にロジックを持たないため）。
update_tool_suite() {
  add_dir_to_path "$AIDD_INSTALL_DIR"
  log ".aidd のツール一式を aidd --update-aidd で発行します…"
  "${AIDD_INSTALL_DIR}/aidd" --update-aidd --protocol "$PROTOCOL" --org "$ORG" --branch "$BRANCH"
  add_dir_to_path "$HARNESS_INSTALL_DIR"
  add_dir_to_path "$CREATE_DOCS_INSTALL_DIR"
}

initialize_git_repo() {
  if git -C "$PROJECT_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
    log "git リポジトリ: OK"
    return
  fi

  log "このプロジェクトはまだ git リポジトリではありません。初期化して初回コミットを作成します…"
  git -C "$PROJECT_ROOT" init -q
  git -C "$PROJECT_ROOT" add -A
  git -C "$PROJECT_ROOT" commit -q -m "chore: aidd-template から初期化"
}

configure_git_hooks() {
  chmod +x "${PROJECT_ROOT}/.githooks/pre-commit" 2>/dev/null || true

  local current
  current="$(git -C "$PROJECT_ROOT" config --local --get core.hooksPath || true)"
  if [ "$current" = ".githooks" ]; then
    log "git hooks: OK（core.hooksPath は設定済み）"
    return
  fi

  log "git hooks を配線します（core.hooksPath=.githooks）…"
  git -C "$PROJECT_ROOT" config --local core.hooksPath .githooks
}

main() {
  install_git
  install_dotnet_sdk
  build_aidd
  update_tool_suite
  initialize_git_repo
  configure_git_hooks

  local exe="${HARNESS_INSTALL_DIR}/ai-harness-main"
  local create_docs_exe="${CREATE_DOCS_INSTALL_DIR}/aidd-create-docs"

  log "プロジェクトを配線します（settings.json の hook ＋ ai-harness-aidd の有効化）…"
  "$exe" --init "$PROJECT_ROOT" --enable ai-harness-aidd

  log "動作確認…"
  "$exe" --doctor
  if ! "$exe" --validate "$PROJECT_ROOT"; then
    echo "[setup] --validate が失敗しました。上記のログを確認してください。" >&2
    exit 1
  fi
  "$create_docs_exe" --version

  log "セットアップ完了。Claude Code を再起動してください。"
}

main "$@"
