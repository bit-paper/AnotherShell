# AnotherShell (Beta 0.0.1)

<p align="center">
  <img src="./AnotherShell/Assets.xcassets/AnotherShellLogo512.imageset/logo_512.png" alt="AnotherShell Logo" width="120" />
</p>

<p align="center">
  <a href="#-简体中文">中文</a> |
  <a href="#-english">English</a>
</p>

---

## 🇨🇳 简体中文

AnotherShell 是一款原生 macOS SSH/SFTP 工具，定位为“简洁、稳定、好看、好用”的远程工作台，融合终端会话与文件传输体验。

### 功能亮点

- 原生 macOS 标签式 SSH 会话
- 会话内嵌双栏 SFTP 文件传输
- 客户端语法高亮（不依赖远端 ANSI 颜色）
- 中英文界面与多主题（含 Liquid Glass）
- 会话状态与系统指标动态展示

### 软件截图

#### 1) 主界面与会话工作台
![主界面与会话工作台](./docs/screenshots/use1.png)

#### 2) 新建连接（简化连接表单）
![新建连接](./docs/screenshots/create-link.png)

#### 3) 设置中心（语言 / 主题 / 外观）
![设置中心](./docs/screenshots/config.png)

#### 4) SFTP 文件传输面板
![SFTP 文件传输](./docs/screenshots/sftp.png)

#### 5) 关于页面（版本与项目信息）
![关于页面](./docs/screenshots/about.png)

### 版本信息

- 当前版本：`0.0.1`
- 通道：`Beta`

### 本地运行

```bash
open AnotherShell.xcodeproj
```

### 一键打包

```bash
bash scripts/package.sh --clean
```

默认产物：

- `build/dist/AnotherShell.app`
- `build/dist/AnotherShell-Beta-0.0.1.dmg`
- `build/dist/AnotherShell-Beta-0.0.1.pkg`

### 协议

本项目采用 [MIT License](./LICENSE) 开源。

---

## 🇺🇸 English

AnotherShell is a native macOS SSH/SFTP client focused on a clean, stable, and productive remote workflow with integrated terminal and file transfer experience.

### Highlights

- Native macOS tabbed SSH sessions
- In-session dual-pane SFTP transfer panel
- Client-side syntax highlighting (independent from remote ANSI colors)
- Bilingual UI (Chinese / English) and multiple themes (including Liquid Glass)
- Live session status and system metrics

### Screenshots

#### 1) Main workspace and active sessions
![Main workspace and sessions](./docs/screenshots/use1.png)

#### 2) Create host connection (simplified form)
![Create host connection](./docs/screenshots/create-link.png)

#### 3) Settings center (language / theme / appearance)
![Settings center](./docs/screenshots/config.png)

#### 4) SFTP transfer panel
![SFTP transfer panel](./docs/screenshots/sftp.png)

#### 5) About window (version and project details)
![About window](./docs/screenshots/about.png)

### Version

- Current version: `0.0.1`
- Channel: `Beta`

### Run locally

```bash
open AnotherShell.xcodeproj
```

### One-command packaging

```bash
bash scripts/package.sh --clean
```

Default artifacts:

- `build/dist/AnotherShell.app`
- `build/dist/AnotherShell-Beta-0.0.1.dmg`
- `build/dist/AnotherShell-Beta-0.0.1.pkg`

### License

This project is released under the [MIT License](./LICENSE).

