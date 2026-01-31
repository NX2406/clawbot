# clawbot

> 一键把 OpenClaw 在 Ubuntu 上跑稳：**root 常驻 + npm 全局 + Codex(OAuth) 登录**，并带一个“傻瓜式”菜单。

这个仓库解决的核心问题：  
很多人用 **Codex 账户登录**（不是 API Key），但 **gateway/daemon 是以 root 常驻**跑的，结果 OAuth 凭据没落在 `/root/.openclaw`，就会出现类似报错：

- `No API key found for provider "openai-codex"`  
（文案误导，根因通常是 **root 的 auth-profiles.json 缺失/不匹配**）

本项目的 `install.sh` 会把这些坑“一次性捋平”。

---

## 功能概览

脚本是交互式菜单，包含：

1. **安装**：安装 Node 22+、npm 全局 openclaw、基础依赖、修复 root PATH  
2. **启动**：统一按 root 常驻策略启动/重启（优先 daemon），避免 tmux/gateway 冲突  
3. **停止**：停止 daemon/gateway，并清理残留 gateway 进程  
4. **日志查看**：跟随 openclaw 日志输出  
5. **换模型**：快速切换 `openai-codex(OAuth)` / `openai(API Key)`  
6. **TG 输入连接码**：用于 headless 场景的“配对/复制凭据”提示  
7. **更新**：npm 更新 openclaw 并重启  
8. **卸载**：卸载 openclaw，可选删除 `/root/.openclaw`

---

## 适用环境

- Ubuntu / Debian 系（使用 `apt-get`）
- **建议**：全程 root 执行（本仓库就是为 root 常驻场景设计的）

---

## 快速开始

### 方式 A：直接拉取仓库运行
```bash
git clone <你的仓库地址> clawbot
cd clawbot
chmod +x install.sh
./install.sh
