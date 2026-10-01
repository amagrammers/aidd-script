#!/usr/bin/env bash
# aidd のツールをインストール・セットアップするスクリプト（macOS / Homebrew 版。PATH の追加を含む）。
# Homebrew / git / .NET SDK 10 を確認し、無ければ導入したうえで、aidd-script 本体（aidd CLI）を
# $HOME/.aidd/aidd-script/publish へ発行する。以降のツール一式（ai-harness-main /
# aidd-create-docs / aidd-docs）の導入は、発行した aidd CLI（`aidd --update-aidd`）に委譲する。
# プロジェクトには触れない（プロジェクトの配線・初期化は行わない）。
#
# setup.sh（Linux / WSL）との違いは、依存の導入手段（Homebrew）・RID（osx-*）・PATH を書くシェルの
# プロファイル（zsh は ~/.zshrc、bash は ~/.bash_profile）のみ。引数と動作は setup.sh と同じ。
#
# curl 等でダウンロードしてから実行する delivery を想定する（実行時のカレントディレクトリや
# スクリプト自身の設置場所は問わない）。
#
# 再実行しても安全（各手順は導入済みなら読み飛ばす。ただし aidd --update-aidd が管理する
# ai-harness-main / aidd-create-docs / aidd-docs は、aidd --update-aidd の仕様どおり毎回最新へ
# 差し替わる）。

set -euo pipefail

# ビルドに使う dotnet CLI 自身にも InvariantGlobalization を強制しておく（ICU の有無に依存しない）。
export DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=1

# 5 リポジトリはすべて同一 org 配下。URL は「PROTOCOL + ORG/<リポジトリ>.git」で組む。
PROTOCOL="https"   # https | ssh
SSH_NAME=""        # ssh のときの git@<ssh-name>:... のホスト部分（~/.ssh/config の Host エイリアス）。未指定なら github.com
ORG="amagrammers"
BRANCH="main"
INSTALL_DIR="${HOME}/.aidd"
# ~/.aidd/<リポジトリ名> が各リポジトリの clone、ビルド成果物はその直下の publish/ に置く。
# 各ツールが同じ lib/ を共有すると、互いに無関係なプラグイン DLL が同じフォルダに混在して
# しまう（プラグインローダは lib/ 配下の *.dll を全走査するため）。ツールごとに別の
# publish/ を持たせ、発行先・PATH 登録とも独立させる。
AIDD_REPO_DIR="${INSTALL_DIR}/aidd-script"
TEMPLATE_REPO_DIR="${INSTALL_DIR}/aidd-template"
AIDD_INSTALL_DIR="${AIDD_REPO_DIR}/publish"
HARNESS_INSTALL_DIR="${INSTALL_DIR}/ai-harness-main/publish"
CREATE_DOCS_INSTALL_DIR="${INSTALL_DIR}/aidd-create-docs/publish"

# macOS の既定シェルは zsh。bash を使っているときだけ ~/.bash_profile へ書く
# （ターミナルはログインシェルとして起動するため、~/.bashrc は読まれない）。
case "${SHELL:-}" in
  */bash) PROFILE_FILE="${HOME}/.bash_profile" ;;
  *)      PROFILE_FILE="${HOME}/.zshrc" ;;
esac

while [ $# -gt 0 ]; do
  case "$1" in
    --protocol) PROTOCOL="$2"; shift 2 ;;
    --ssh-name) SSH_NAME="$2"; shift 2 ;;
    --org) ORG="$2"; shift 2 ;;
    --branch) BRANCH="$2"; shift 2 ;;
    *) echo "[setup] 不明な引数です: $1" >&2; exit 1 ;;
  esac
done

if [ -n "$SSH_NAME" ] && [ "$PROTOCOL" != "ssh" ]; then
  echo "[setup] --ssh-name は --protocol ssh のときだけ指定できます。" >&2
  exit 1
fi

case "$PROTOCOL" in
  https|ssh) ;;
  *) echo "[setup] --protocol は https か ssh のいずれかです: $PROTOCOL" >&2; exit 1 ;;
esac

# aidd-script は public のため、--org / --protocol / --ssh-name に依らず固定の https URL から取得する。
AIDD_SCRIPT_REPO_URL="https://github.com/amagrammers/aidd-script.git"

if [ "$(uname -s)" != "Darwin" ]; then
  echo "[setup] このスクリプトは macOS 専用です。Linux / WSL は setup.sh を使ってください。" >&2
  exit 1
fi

case "$(uname -m)" in
  arm64)  RID="osx-arm64" ;;
  x86_64) RID="osx-x64" ;;
  *) echo "[setup] 未対応のアーキテクチャです: $(uname -m)" >&2; exit 1 ;;
esac

log() { echo "[setup] $*"; }

# brew コマンドを PATH へ載せる。Apple Silicon は /opt/homebrew、Intel は /usr/local に入る。
load_brew_env() {
  local brew_bin
  for brew_bin in /opt/homebrew/bin/brew /usr/local/bin/brew; do
    if [ -x "$brew_bin" ]; then
      eval "$("$brew_bin" shellenv)"
      return 0
    fi
  done
  return 1
}

install_homebrew() {
  if command -v brew >/dev/null 2>&1 || load_brew_env; then
    log "Homebrew: OK ($(brew --version | head -n 1))"
    return
  fi

  log "Homebrew をインストールします…"
  command -v curl >/dev/null 2>&1 || { echo "[setup] curl が見つかりません。" >&2; exit 1; }
  # 公式のインストーラ。sudo のパスワード入力と Xcode Command Line Tools の導入を伴う
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

  load_brew_env || { echo "[setup] Homebrew のインストールに失敗しました。" >&2; exit 1; }

  # 新しいシェルでも brew が使えるようにする
  local shellenv_line
  shellenv_line="eval \"\$($(command -v brew) shellenv)\""
  if ! grep -qF "$shellenv_line" "$PROFILE_FILE" 2>/dev/null; then
    echo "$shellenv_line" >> "$PROFILE_FILE"
  fi
}

install_git() {
  # macOS の /usr/bin/git は Xcode Command Line Tools への入口で、未導入だと案内ダイアログを出して
  # 失敗する。--version が通ることで実体の有無を判定する。
  if git --version >/dev/null 2>&1; then
    log "git: OK ($(git --version))"
    return
  fi
  log "git をインストールします…"
  brew install git
  git --version >/dev/null 2>&1 || { echo "[setup] git のインストールに失敗しました。" >&2; exit 1; }
}

install_dotnet_sdk() {
  if command -v dotnet >/dev/null 2>&1 && dotnet --list-sdks 2>/dev/null | grep -q '^10\.'; then
    log ".NET SDK 10: OK"
    return
  fi
  log ".NET SDK をインストールします（brew install --cask dotnet-sdk）…"
  brew install --cask dotnet-sdk

  # cask が入れる pkg は /usr/local/share/dotnet に展開される。PATH に無ければ補う
  if ! command -v dotnet >/dev/null 2>&1 && [ -x /usr/local/share/dotnet/dotnet ]; then
    export PATH="/usr/local/share/dotnet:${PATH}"
  fi

  command -v dotnet >/dev/null 2>&1 || { echo "[setup] .NET SDK のインストールに失敗しました。" >&2; exit 1; }
  dotnet --list-sdks 2>/dev/null | grep -q '^10\.' || {
    echo "[setup] .NET SDK 10 が見つかりません（導入されたのは $(dotnet --version)）。.NET SDK 10 を手動で導入してください。" >&2
    exit 1
  }
}

# aidd CLI の初回導入（以降の更新は aidd --update-aidd が行う）。再実行時は旧版の aidd で
# 引数が通らない問題を避けるため、ここでも clone と remote の差分確認をする。
# 差分があるとき、または発行物が無いときだけ発行する（差分が無ければ読み飛ばす）。
build_aidd() {
  local exe_path="${AIDD_INSTALL_DIR}/aidd"
  local changed=0

  if [ ! -d "${AIDD_REPO_DIR}/.git" ]; then
    log "aidd-script を ${AIDD_REPO_DIR} へ clone します（branch: ${BRANCH}）…"
    rm -rf "$AIDD_REPO_DIR"
    git clone --quiet --depth 1 --branch "$BRANCH" "$AIDD_SCRIPT_REPO_URL" "$AIDD_REPO_DIR"
    changed=1
  else
    # org / protocol / ssh-name の変更に追随するため、毎回 remote を指定どおりに揃える
    git -C "$AIDD_REPO_DIR" remote set-url origin "$AIDD_SCRIPT_REPO_URL"
    git -C "$AIDD_REPO_DIR" fetch --quiet --depth 1 origin "$BRANCH"
    if [ "$(git -C "$AIDD_REPO_DIR" rev-parse HEAD)" != "$(git -C "$AIDD_REPO_DIR" rev-parse FETCH_HEAD)" ]; then
      log "aidd-script に差分があります。更新します…"
      git -C "$AIDD_REPO_DIR" reset --quiet --hard FETCH_HEAD
      changed=1
    fi
  fi

  if [ "$changed" -eq 0 ] && [ -x "$exe_path" ]; then
    log "aidd: OK ($exe_path)"
    return
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

# aidd-template を ~/.aidd/aidd-template へ clone する（aidd --init が中身をコピーする）。
# 既にあれば remote を指定どおりに揃えて fetch し、差分があるときだけ更新する。
sync_template() {
  local url
  case "$PROTOCOL" in
    https) url="https://github.com/${ORG}/aidd-template.git" ;;
    ssh)   url="git@${SSH_NAME:-github.com}:${ORG}/aidd-template.git" ;;
  esac

  if [ ! -d "${TEMPLATE_REPO_DIR}/.git" ]; then
    log "aidd-template を ${TEMPLATE_REPO_DIR} へ clone します（branch: ${BRANCH}）…"
    rm -rf "$TEMPLATE_REPO_DIR"
    git clone --quiet --depth 1 --branch "$BRANCH" "$url" "$TEMPLATE_REPO_DIR"
    return
  fi

  git -C "$TEMPLATE_REPO_DIR" remote set-url origin "$url"
  git -C "$TEMPLATE_REPO_DIR" fetch --quiet --depth 1 origin "$BRANCH"
  if [ "$(git -C "$TEMPLATE_REPO_DIR" rev-parse HEAD)" != "$(git -C "$TEMPLATE_REPO_DIR" rev-parse FETCH_HEAD)" ]; then
    log "aidd-template に差分があります。更新します…"
    git -C "$TEMPLATE_REPO_DIR" reset --quiet --hard FETCH_HEAD
  else
    log "aidd-template: OK（差分なし）"
  fi
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
  local ssh_args=()
  [ -n "$SSH_NAME" ] && ssh_args=(--ssh-name "$SSH_NAME")
  "${AIDD_INSTALL_DIR}/aidd" --update-aidd --protocol "$PROTOCOL" ${ssh_args[@]+"${ssh_args[@]}"} --org "$ORG" --branch "$BRANCH"
  add_dir_to_path "$HARNESS_INSTALL_DIR"
  add_dir_to_path "$CREATE_DOCS_INSTALL_DIR"
}

main() {
  install_homebrew
  install_git
  install_dotnet_sdk
  build_aidd
  sync_template
  update_tool_suite

  local exe="${HARNESS_INSTALL_DIR}/ai-harness-main"
  local create_docs_exe="${CREATE_DOCS_INSTALL_DIR}/aidd-create-docs"

  log "動作確認…"
  "${AIDD_INSTALL_DIR}/aidd" --version
  "$exe" --doctor
  "$create_docs_exe" --version

  log "セットアップ完了。新しいターミナルを開くか、source ${PROFILE_FILE} を実行してください。"
}

main "$@"
