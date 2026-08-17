# DeepSeek 助手 macOS 应用

把 [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) 的 Web GUI 包装成原生 macOS 应用（Swift + AppKit + WKWebView），双击即可像 Codex 桌面端一样在独立窗口中使用。

## 功能

- 原生窗口（透明标题栏、流量灯按钮），窗口大小/位置自动记忆
- 全局快捷键 **⌥Space** 唤起/隐藏窗口（与 Codex 一致）；关闭窗口 = 收进菜单栏，服务和会话保持在线
- 菜单栏常驻图标（小鲸鱼）：显示/隐藏窗口、重新载入、在浏览器中打开、**开机自启**开关、退出
- **用量与余额**（菜单栏 / 应用菜单）：查询 DeepSeek API 余额（官方接口）+ 本机全部会话的 token 用量统计，并按官方定价（v4-pro/v4-flash、高峰/空闲时段）估算费用
- **编辑菜单**：⌘C/⌘V/⌘X/⌘A/⌘Z 剪切、拷贝、粘贴、全选、撤销、重做（WKWebView 必需）
- 系统通知：应用自己拉起的服务就绪时提示；服务意外退出时提示
- **单实例（PID 文件锁）**：重复打开只会聚焦已有窗口，不依赖 LaunchServices 注册状态
- 自动管理后台服务生命周期：
  - 启动时探测 `http://127.0.0.1:3080`（长探测窗口约 27 秒），已有服务则直接复用（不重复拉起）
  - 端口空闲时自动执行 `dsh web --port 3080`，就绪后加载界面
  - **绝不强制终止其他进程**：端口被占用但无响应时只提示，避免破坏正在写入的会话日志
  - 退出时只回收「自己拉起」的服务，不影响其他进程的服务
- 服务工作目录默认 `~/Desktop/deepseek`，可在菜单「设置 → 更改工作目录…」修改（下次启动生效）
- `window.open` / 外链自动跳转系统浏览器；菜单支持重新载入、前进后退、在浏览器中打开
- 日志：`~/Library/Logs/DeepSeek助手/`（`app.log` 应用日志、`server.log` 服务日志）
- 收到 SIGTERM/SIGINT 时优雅退出（登出、Activity Monitor 结束进程也不会遗留服务）

## 端口配置

默认 3080，可覆盖（优先级从高到低）：

1. 命令行：`DeepSeekAssistant --port 3090`
2. Bundle 内配置：`DeepSeek助手.app/Contents/Resources/port.conf`（写入端口号后需重新 `codesign --force --deep -s -` 签名）
3. 环境变量 `DSH_PORT`
4. UserDefaults：`defaults write com.deepseek.assistant port -int 3090`

## 构建

```bash
cd mac-app && ./build.sh
```

产物为 `mac-app/DeepSeek助手.app`。注意：本机 Xcode CLT 的 26.5 SDK 与 Swift 编译器版本不匹配，
`build.sh` 已固定使用 `MacOSX15.4.sdk` 并把模块缓存放在 `.cache/` 内。

## 自定义图标

把任意方形图片（建议 ≥1024×1024，png/jpg）放到 `mac-app/` 下并命名为 `icon-source.png` 或 `icon-source.jpg`，重新 `./build.sh` 即可替换应用图标；删除该文件则回退到程序生成的鲸鱼图标。

## 安装

```bash
ditto "mac-app/DeepSeek助手.app" "/Applications/DeepSeek助手.app"
```

本地构建、ad-hoc 签名的应用可直接双击运行（未公证，仅当从网络下载时才可能被 Gatekeeper 拦截）。

## 依赖

- 已安装 `dsh`（`npm install -g @deepseek-ai/dsh`），位于 `/opt/homebrew/bin`、`/usr/local/bin` 或 `~/.npm-global/bin`
- 本机装有 node（应用会自动在常见路径及 `~/.nvm` 下查找）
