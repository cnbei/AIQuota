# AIQuota

macOS 菜单栏小工具：用彩色圆环显示 AI 编码额度剩余百分比。

支持：

- **Codex**（默认）— 读 `~/.codex/auth.json`
- **Cursor** — 读 Cursor 本机登录态
- **Kimi Coding Plan** — 读 `~/.kimi-code/credentials/kimi-code.json`

圆环颜色：绿 = 充裕，红 = 快用完；圆心数字为**剩余百分比**。

## 要求

- macOS 13+
- 已登录对应服务（Codex / Cursor / `kimi login`）

## 运行

```bash
./scripts/run.sh
```

会编译并启动 `dist/AIQuota.app`（无 Dock 图标的菜单栏 App）。

仅编译：

```bash
swift build -c release
```

## 使用

1. 点菜单栏圆环打开面板  
2. 分段控件切换 Codex / Cursor / Kimi  
3. **刷新** 手动拉取；默认约每 3 分钟自动刷新  
4. **打开控制台** 跳转对应用量页  

## 说明

用量接口多为非官方内部 API，可能随厂商改动失效。本工具只在本机读取已有登录态，不上传任何凭证。
