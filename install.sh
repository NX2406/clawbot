#!/bin/bash
# ==============================================================================
# OpenClaw (Ubuntu) Root 常驻 + Codex(OAuth) 最优稳定脚本（带菜单）
#
# 菜单功能：
#  1. 安装        - 安装 Node 22+、npm 全局 openclaw、基础依赖，规范 root PATH
#  2. 启动        - 统一以 daemon 方式启动/重启，避免 tmux/gateway 冲突
#  3. 停止        - 停止 daemon/gateway，并清理残留 gateway 进程
#  4. 日志查看    - openclaw logs --follow（若不可用则提示）
#  5. 换模型      - 交互式选择 provider：openai-codex(OAuth) / openai(API Key) 等
#  6. TG 输入连接码 - headless 场景：提示你如何在有浏览器的机器登录并复制 OAuth（或你自己粘贴连接码/链接）
#  7. 更新        - npm 更新 openclaw 到 latest，并重启
#  8. 卸载        - npm uninstall -g openclaw（可选删除 /root/.openclaw）
#
# 重点：默认走 openai-codex OAuth（你不用 API key）
# ==============================================================================
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;36m'
PLAIN='\033[0m'

say()   { echo -e "${BLUE}➜${PLAIN} $*"; }
ok()    { echo -e "${GREEN}✓${PLAIN} $*"; }
warn()  { echo -e "${YELLOW}⚠${PLAIN} $*"; }
fail()  { echo -e "${RED}✗${PLAIN} $*"; exit 1; }

OPENCLAW_AGENT_ID="${OPENCLAW_AGENT_ID:-main}"
OPENCLAW_PORT="${OPENCLAW_PORT:-}"

require_root() {
  [[ "$(id -u)" -eq 0 ]] || fail "请使用 root 运行：sudo -i 或 sudo bash $0"
  export HOME="/root"
  mkdir -p /root
}

have_cmd() { command -v "$1" >/dev/null 2>&1; }

apt_ready() {
  have_cmd apt-get || fail "仅适配 Ubuntu/Debian（缺少 apt-get）"
  export DEBIAN_FRONTEND=noninteractive
}

apt_update_once() {
  say "更新 apt 索引..."
  local i
  for i in {1..20}; do
    if apt-get update -o Acquire::Retries=3 >/dev/null 2>&1; then
      ok "apt 索引更新完成"
      return 0
    fi
    sleep 2
  done
  warn "apt-get update 多次失败，继续尝试安装依赖（可能会失败）"
}

apt_install() {
  local pkgs=("$@")
  say "安装依赖：${pkgs[*]}"
  apt-get install -y --no-install-recommends "${pkgs[@]}" >/dev/null
  ok "依赖安装完成：${pkgs[*]}"
}

ensure_base_tools() {
  apt_update_once
  apt_install ca-certificates curl gnupg lsb-release jq tmux
}

ensure_node_22() {
  if have_cmd node; then
    local v major
    v="$(node -v 2>/dev/null || true)"
    major="$(echo "$v" | sed 's/^v//' | cut -d. -f1 || true)"
    if [[ "$major" =~ ^[0-9]+$ ]] && [[ "$major" -ge 22 ]]; then
      ok "Node 已满足：$v"
      return 0
    fi
    warn "Node 版本偏旧：$v（需要 22+），将升级"
  else
    warn "未检测到 Node，将安装 Node 22+"
  fi

  say "通过 NodeSource 安装/升级 Node.js 22..."
  curl -fsSL https://deb.nodesource.com/setup_22.x | bash - >/dev/null
  apt_install nodejs
  ok "Node 安装完成：$(node -v)"
}

ensure_npm() {
  have_cmd npm || fail "npm 不存在（nodejs 安装异常）"
  ok "npm 可用：$(npm -v)"
}

fix_path_for_root() {
  local npm_prefix npm_bin
  npm_prefix="$(npm config get prefix 2>/dev/null || true)"
  npm_bin="${npm_prefix%/}/bin"

  if [[ -n "$npm_bin" && -d "$npm_bin" ]]; then
    if ! echo ":$PATH:" | grep -q ":$npm_bin:"; then
      export PATH="$npm_bin:$PATH"
      ok "已临时加入 PATH：$npm_bin"
    fi
    local line="export PATH=\"$npm_bin:\$PATH\""
    for f in /root/.bashrc /root/.profile; do
      [[ -f "$f" ]] || touch "$f"
      grep -qF "$line" "$f" 2>/dev/null || echo "$line" >> "$f"
    done
    ok "PATH 持久化完成（/root/.bashrc, /root/.profile）"
  else
    warn "未能解析 npm global bin 目录（prefix=$npm_prefix），如遇 openclaw 找不到请手工处理"
  fi
}

ensure_openclaw_npm_global() {
  say "npm 全局安装/升级 openclaw..."
  npm config set fund false >/dev/null 2>&1 || true
  npm config set audit false >/dev/null 2>&1 || true

  npm install -g openclaw@latest --no-fund --no-audit || {
    warn "npm install 失败，尝试清理残留后重试..."
    local npm_root
    npm_root="$(npm root -g 2>/dev/null || true)"
    rm -rf "${npm_root}/openclaw" 2>/dev/null || true
    npm cache clean --force >/dev/null 2>&1 || true
    npm install -g openclaw@latest --no-fund --no-audit
  }

  if have_cmd openclaw; then
    ok "openclaw 已安装：$(openclaw --version 2>/dev/null || echo 'version unknown')"
  else
    warn "openclaw 安装后仍不可用（PATH 问题），尝试修复 PATH 后重新打开终端或 source /root/.bashrc"
  fi
}

# --------------------------
# Root 统一：避免 tmux/gateway/daemon 冲突
# --------------------------
kill_conflicting_instances() {
  say "清理可能冲突的 openclaw 常驻实例（gateway/daemon）..."

  # 先尝试优雅停止
  openclaw gateway stop >/dev/null 2>&1 || true
  openclaw daemon stop  >/dev/null 2>&1 || true

  # tmux 会话名包含 gateway 的，杀掉
  if tmux ls 2>/dev/null | grep -qi "gateway"; then
    warn "检测到 tmux 会话名包含 gateway，尝试停止..."
    tmux kill-session -t gateway >/dev/null 2>&1 || true
    ok "tmux gateway 会话已处理（若存在）"
  fi

  # 兜底：杀 gateway 进程
  pkill -f "openclaw gateway" >/dev/null 2>&1 || true
  ok "冲突清理完成（若先前存在）"
}

show_running_state() {
  say "当前 openclaw 进程概览："
  ps -ef | grep -E "openclaw (gateway|daemon)" | grep -v grep || echo "(none)"
  if [[ -n "$OPENCLAW_PORT" ]]; then
    say "端口监听检查：$OPENCLAW_PORT"
    ss -lntp | grep -E ":${OPENCLAW_PORT}\b" || echo "(no listener on ${OPENCLAW_PORT})"
  fi
}

# --------------------------
# Codex OAuth 认证检测
# --------------------------
auth_paths() {
  local base="/root/.openclaw"
  local agent_dir="${base}/agents/${OPENCLAW_AGENT_ID}/agent"
  local auth_store="${agent_dir}/auth-profiles.json"
  local cred_legacy="${base}/credentials/oauth.json"
  echo "$base|$agent_dir|$auth_store|$cred_legacy"
}

ensure_auth_dirs_permissions() {
  local base agent_dir auth_store cred_legacy
  IFS='|' read -r base agent_dir auth_store cred_legacy < <(auth_paths)

  mkdir -p "$agent_dir" "$(dirname "$cred_legacy")"
  chmod 700 "$base" "$base/agents" "$base/credentials" 2>/dev/null || true
  chmod -R 700 "$base/agents" "$base/credentials" 2>/dev/null || true
  [[ -f "$auth_store" ]] && chmod 600 "$auth_store" 2>/dev/null || true
  [[ -f "$cred_legacy" ]] && chmod 600 "$cred_legacy" 2>/dev/null || true
  ok "root 认证目录/权限已规范化：$base"
}

auth_store_has_openai_codex() {
  local base agent_dir auth_store cred_legacy
  IFS='|' read -r base agent_dir auth_store cred_legacy < <(auth_paths)
  [[ -f "$auth_store" ]] || return 1
  grep -q '"openai-codex"' "$auth_store" 2>/dev/null
}

codex_oauth_login() {
  ensure_auth_dirs_permissions

  if auth_store_has_openai_codex; then
    ok "已检测到 openai-codex(OAuth) 认证信息（/root/.openclaw 下）"
    return 0
  fi

  warn "未检测到 openai-codex 认证信息（这正是你截图报错的根因）"
  say "尝试触发 OAuth 登录：openclaw models auth login --provider openai-codex"
  set +e
  openclaw models auth login --provider openai-codex
  local rc=$?
  set -e
  [[ $rc -ne 0 ]] && warn "登录命令返回非 0（可能是 headless 无法完成），继续给出解决方案"

  ensure_auth_dirs_permissions

  if auth_store_has_openai_codex; then
    ok "OAuth 已落地到 /root/.openclaw（修复完成）"
    return 0
  fi

  warn "仍未看到 openai-codex 认证落地（典型：纯 SSH/headless）"
  echo -e "${BLUE}最稳复制法（在有浏览器的电脑上做一次登录，然后拷文件到服务器 root）：${PLAIN}"
  echo "  1) 在有浏览器的电脑执行：openclaw models auth login --provider openai-codex"
  echo "  2) 复制到本服务器："
  echo "     ~/.openclaw/credentials/oauth.json                -> /root/.openclaw/credentials/oauth.json"
  echo "     ~/.openclaw/agents/main/agent/auth-profiles.json  -> /root/.openclaw/agents/main/agent/auth-profiles.json"
  echo "  3) 服务器执行：chmod 600 /root/.openclaw/credentials/oauth.json /root/.openclaw/agents/main/agent/auth-profiles.json"
  echo "  4) 重启：openclaw daemon restart || true"
  return 0
}

# --------------------------
# 启停/日志
# --------------------------
start_services() {
  say "启动/重启（统一由 daemon 接管，避免 tmux 与手动 gateway 冲突）"
  kill_conflicting_instances
  openclaw daemon restart >/dev/null 2>&1 || true
  openclaw gateway restart >/dev/null 2>&1 || true
  # 防止残留手动 gateway，再次确保单实例
  pkill -f "openclaw gateway" >/dev/null 2>&1 || true
  openclaw daemon restart >/dev/null 2>&1 || true
  ok "启动流程已执行"
  show_running_state
}

stop_services() {
  say "停止 openclaw 服务..."
  openclaw gateway stop >/dev/null 2>&1 || true
  openclaw daemon stop  >/dev/null 2>&1 || true
  pkill -f "openclaw gateway" >/dev/null 2>&1 || true
  ok "停止完成"
  show_running_state
}

view_logs() {
  say "日志查看（Ctrl+C 退出）"
  if openclaw logs --help >/dev/null 2>&1; then
    openclaw logs --follow || true
  else
    warn "当前 openclaw 版本不支持 logs 子命令。你可以用："
    echo "  - journalctl -u openclaw* -f   （如果你用的是 systemd 单元）"
    echo "  - 或 ps 找到进程后看它输出/重定向日志"
    show_running_state
  fi
}

# --------------------------
# 换模型（provider）
# --------------------------
switch_model_menu() {
  echo ""
  echo -e "${BLUE}选择模型/认证方式：${PLAIN}"
  echo "1) openai-codex（OAuth / ChatGPT 订阅登录，推荐）"
  echo "2) openai（API Key 方式，需要设置 OPENAI_API_KEY）"
  echo "3) 返回"
  echo -n "请输入编号: "
  read -r c
  case "$c" in
    1)
      say "切换到 openai-codex（OAuth）"
      codex_oauth_login
      start_services
      ;;
    2)
      say "切换到 openai（API Key）"
      echo -n "请输入 OPENAI_API_KEY: "
      read -r key
      [[ -z "$key" ]] && fail "API Key 不能为空"

      # 将 key 写入 root 环境变量（谨慎：会落盘）
      local envfile="/root/.openclaw_api_env"
      umask 077
      cat > "$envfile" <<EOF
export OPENAI_API_KEY="${key}"
EOF
      ok "已写入 $envfile（权限 600），你可以 source 它后再启动"
      echo "建议："
      echo "  source $envfile"
      echo "  openclaw daemon restart || true"
      ;;
    *)
      ok "返回"
      ;;
  esac
}

# --------------------------
# TG 输入连接码（给 headless 用）
# --------------------------
tg_pair_code_help() {
  echo ""
  echo -e "${BLUE}TG 输入连接码（headless 提示）${PLAIN}"
  echo "你截图的错误本质是：root 的 /root/.openclaw 下缺少 openai-codex 的 OAuth 凭据。"
  echo ""
  echo "如果服务器无法打开浏览器，请按这个流程："
  echo "  1) 在有浏览器的电脑执行：openclaw models auth login --provider openai-codex"
  echo "  2) 把文件复制到服务器 root："
  echo "     ~/.openclaw/credentials/oauth.json                -> /root/.openclaw/credentials/oauth.json"
  echo "     ~/.openclaw/agents/main/agent/auth-profiles.json  -> /root/.openclaw/agents/main/agent/auth-profiles.json"
  echo "  3) 服务器执行：chmod 600 /root/.openclaw/credentials/oauth.json /root/.openclaw/agents/main/agent/auth-profiles.json"
  echo "  4) 重启：openclaw daemon restart || true"
  echo ""
  echo "如果你的 OpenClaw 版本支持“配对码/enroll/pair_token”类命令，你也可以尝试："
  echo "  openclaw models auth login --provider openai-codex"
  echo "然后按终端给出的链接/码在你的设备上完成。"
  echo ""
  ok "提示输出完毕"
}

# --------------------------
# 安装/更新/卸载
# --------------------------
do_install() {
  require_root
  apt_ready
  ensure_base_tools
  ensure_node_22
  ensure_npm
  fix_path_for_root
  ensure_openclaw_npm_global
  ensure_auth_dirs_permissions
  ok "安装阶段完成"
}

do_update() {
  require_root
  apt_ready
  ensure_node_22
  ensure_npm
  fix_path_for_root
  say "更新 openclaw 到 latest..."
  npm install -g openclaw@latest --no-fund --no-audit
  ok "更新完成"
  start_services
}

do_uninstall() {
  require_root
  apt_ready
  stop_services
  if have_cmd npm; then
    say "卸载 openclaw..."
    npm uninstall -g openclaw >/dev/null 2>&1 || true
    ok "npm 卸载完成"
  else
    warn "npm 不存在，跳过 npm 卸载"
  fi

  echo -n "是否删除 /root/.openclaw 配置目录？(y/N): "
  read -r ans
  if [[ "${ans,,}" == "y" ]]; then
    rm -rf /root/.openclaw
    ok "已删除 /root/.openclaw"
  else
    ok "保留 /root/.openclaw"
  fi
}

# --------------------------
# 主菜单
# --------------------------
print_menu() {
  clear || true
  echo -e "${BLUE}OpenClaw 管理菜单（Root 常驻 / npm 全局 / Codex OAuth）${PLAIN}"
  echo ""
  echo "1. 安装"
  echo "2. 启动"
  echo "3. 停止"
  echo "---------------------------"
  echo "4. 日志查看"
  echo "5. 换模型"
  echo "6. TG输入连接码"
  echo "---------------------------"
  echo "7. 更新"
  echo "8. 卸载"
  echo ""
}

main() {
  require_root

  while true; do
    print_menu
    echo -n "请选择 [1-8]："
    read -r choice
    case "$choice" in
      1) do_install; read -r -p "按回车返回菜单..." _ ;;
      2) codex_oauth_login; start_services; read -r -p "按回车返回菜单..." _ ;;
      3) stop_services; read -r -p "按回车返回菜单..." _ ;;
      4) view_logs; read -r -p "按回车返回菜单..." _ ;;
      5) switch_model_menu; read -r -p "按回车返回菜单..." _ ;;
      6) tg_pair_code_help; read -r -p "按回车返回菜单..." _ ;;
      7) do_update; read -r -p "按回车返回菜单..." _ ;;
      8) do_uninstall; read -r -p "按回车返回菜单..." _ ;;
      *) warn "无效选项：$choice"; sleep 1 ;;
    esac
  done
}

main "$@"
