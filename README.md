# DeepSeek 助手 macOS 应用

把 [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) 的 Web GUI 包装成原生 macOS 应用（Swift + AppKit + WKWebView）。双击即用，像 Codex 桌面端一样在独立窗口中与 DeepSeek 助手对话。

## 功能

- 原生窗口（透明标题栏、流量灯按钮），窗口大小/位置自动记忆
- 全局快捷键 **⌥Space** 唤起/隐藏窗口；关闭窗口 = 收进菜单栏，会话保持在线
- 菜单栏常驻图标：显示/隐藏、重新载入、在浏览器中打开、**开机自启**开关、退出（服务可继续后台运行）
- **用量与余额**（菜单栏 / 应用菜单）：查询 DeepSeek API 余额（官方接口）+ 本机全部会话的 token 用量与费用估算（官方定价、高峰/空闲时段、v4-pro/v4-flash 切换），并可**内嵌打开官方平台用量页**（登录一次直连账号数据）
- **编辑菜单**：⌘C/⌘V/⌘X/⌘A/⌘Z 剪切、拷贝、粘贴、全选、撤销、重做
- 界面语言：应用声明简体中文，GUI 默认中文界面；附带 dsh 命令菜单英文描述汉化补丁
- 系统通知：应用拉起的服务就绪时提示；服务意外退出时提示
- 单实例运行（PID 文件锁）：重复打开只会聚焦已有窗口
- 自动管理 `dsh web` 服务生命周期：
  - 长探测窗口（约 27 秒），已有服务直接复用，不重复拉起
  - 端口空闲时自动启动服务，就绪后加载界面
  - **绝不强制终止其他进程**，避免破坏正在写入的会话日志
  - **退出应用服务继续后台运行**（任务与子代理不中断）；「退出并停止服务」才完整终止
- 工作目录默认 `~/Desktop/deepseek`，可在菜单「设置 → 更改工作目录…」修改

## 快速安装

1. 从 [Releases](https://github.com/zhangyuyao-zx/deepseek-harness-mac/releases) 下载 `DeepSeek-Assistant-1.1.0.zip`
2. 解压后把 `DeepSeek助手.app` 拖入「应用程序」文件夹
3. 双击运行（首次启动允许通知权限，体验更好）

依赖：本机已安装 [dsh](https://www.npmjs.com/package/@deepseek-ai/dsh)（`npm install -g @deepseek-ai/dsh`）与 node。

## 从源码构建

```bash
cd mac-app && ./build.sh
# 产物: mac-app/DeepSeek助手.app
```

详见 [mac-app/README.md](mac-app/README.md)（端口配置、自定义图标等）。

## 目录结构

```
mac-app/           Mac 应用源码与构建脚本(Swift)
session-repair/    会话日志诊断与修复工具
releases/          发布安装包
```

## session-repair：会话日志自愈补丁

dsh 的会话日志（`~/.dsh/sessions/`）在服务进程被中断重写时可能残留重复行，导致 GUI 报「历史加载失败 / corrupt session log: seq gap」。

- `session-log-resync.patch` — 针对 `dsh-session-persistence-jsonl` 的补丁：把「中断重写留下的重复行」从致命错误改为自动跳过并对齐；真正缺数据的场景仍然报错（防线保留）
- `scan.mjs` — 与 dsh 相同逻辑的日志扫描诊断脚本
- `test-patch.mjs` — 补丁端到端验证脚本（合成损坏样本）

应用补丁：

```bash
cd "$(npm root -g)/@deepseek-ai/dsh/node_modules/@deepseek-ai/dsh-session-persistence-jsonl"
git apply /path/to/session-log-resync.patch   # 或手动按 patch 修改 lib/index.js
```

注意：`npm install -g @deepseek-ai/dsh` 重装会覆盖补丁，需重新应用。该补丁也可提交到 deepseek-harness 上游。

## License

[MIT](LICENSE)
