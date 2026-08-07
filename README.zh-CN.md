# AIQuota

[English](README.md) | [简体中文](README.zh-CN.md)

macOS 菜单栏小工具：用彩色圆环显示 AI 编码额度**剩余百分比**。

**支持的服务**

| 服务 | 数据来源 | 圆环含义 |
| --- | --- | --- |
| **Codex**（默认） | `~/.codex/auth.json` → ChatGPT 用量接口 | 剩余额度 % |
| **Cursor** | 本机 Cursor 登录态（`state.vscdb`）→ Dashboard 用量接口 | 剩余 **Cursor Models** %（对齐 [Spending](https://cursor.com/dashboard/spending)） |
| **Kimi** | 网页 `kimi-auth` Cookie → 会员用量接口 | 剩余 **会员总使用量** % |

圆环颜色：绿 = 充裕，红 = 快用完；圆心数字为**剩余百分比**。

## 环境要求

- macOS 13+
- Xcode Command Line Tools / Swift 5.9+
- **Codex / Cursor**：本机已登录即可
- **Kimi**：需要网页会话 Cookie `kimi-auth`（不是 Code CLI 的 OAuth token）

一键导入 Kimi 登录时可选依赖：

```bash
pip3 install --user browser-cookie3
```

## 运行

```bash
./scripts/run.sh
```

会编译 release 并启动 `dist/AIQuota.app`（`LSUIElement`：仅菜单栏，无 Dock 图标）。

仅编译：

```bash
swift build -c release
```

## 使用

1. 点击菜单栏圆环打开面板  
2. 用分段控件切换 **Codex / Cursor / Kimi**  
3. **刷新** 手动拉取；默认约每 3 分钟自动刷新  
4. **打开控制台** 跳转对应用量页  
5. 右上角 **固定**：置顶浮动窗口，切换应用也不会关掉（方便跟着浏览器教程操作）  
6. 在 **Cursor** 页可切换状态栏圆环：**Cursor Models** / **Other Models**  
7. 在 **Kimi** 页可切换状态栏圆环：**总体**（会员总使用量）/ **Kimi Code**（Code 5h/7d 中更紧的那个）

若接口提供窗口信息，面板会显示 **重置日程**（如 5h / 7d / 30d）。显示偏好会本地持久化。

### Kimi 登录

Kimi Code CLI 的 token **不能**调会员总用量接口（会 401），必须用网页 `kimi-auth`：

1. 浏览器登录 [我的额度](https://www.kimi.com/membership/subscription?tab=quota)  
2. 在 AIQuota 切到 **Kimi** → 点 **导入网页登录**（通过 `browser-cookie3` 读取 Chrome / Edge / Brave / Chromium / Safari Cookie）  
3. 若失败：DevTools → Application → Cookies → 复制 `kimi-auth` → **粘贴 kimi-auth**  
4. 或设置环境变量 `KIMI_AUTH_TOKEN`

Token 会缓存在 `~/Library/Application Support/AIQuota/`。

Kimi 教程 / 粘贴 / 导入按钮**仅在 Kimi 页签**显示，切换到其他服务会自动隐藏。

## 隐私说明

凭证只留在本机。应用仅用已有登录态（或你粘贴的 Cookie）请求各家用量接口，不会上传到第三方服务器。

用量接口多为非官方内部 API，厂商改动后可能失效。

## 许可

个人使用与修改均可。
