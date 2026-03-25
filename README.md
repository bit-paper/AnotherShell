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

AnotherShell 是一个原生 macOS SSH/SFTP 工具，目标是提供接近 FinalShell / MobaXterm / Tabby 的高效终端体验。

### 核心能力

- 原生 macOS SSH 会话管理（标签会话）
- 内置 SFTP 文件浏览与传输面板（会话内联）
- 客户端侧高亮（不依赖远端 ANSI 颜色）
- 中英文语言切换
- 多主题（含 Liquid Glass 风格）
- 连接状态与系统信息实时展示

### 版本信息

- 当前版本：`0.0.1`
- 版本通道：`Beta`
- 提交基线：`feat: ship beta 0.0.1 UX and packaging baseline`

### 开发环境

- macOS
- Xcode（建议完整安装，不使用 CommandLineTools 单独构建）
- Swift / SwiftUI

### 本地运行

```bash
open AnotherShell.xcodeproj
```

在 Xcode 中选择 `AnotherShell` scheme 后运行。

### 一键打包

项目已内置打包脚本：

```bash
bash scripts/package.sh --clean
```

输出目录：

- `build/dist/AnotherShell.app`
- `build/dist/AnotherShell-Beta-0.0.1.dmg`
- `build/dist/AnotherShell-Beta-0.0.1.pkg`

常用参数：

```bash
bash scripts/package.sh --help
bash scripts/package.sh --no-dmg
bash scripts/package.sh --no-pkg
bash scripts/package.sh --version 0.0.2
```

### 常见问题

#### 1) `dist` 目录为空

通常是 `xcodebuild` 失败（依赖拉取失败、网络问题、Xcode 路径不正确）。

先执行：

```bash
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
git ls-remote https://github.com/migueldeicaza/SwiftTerm
git ls-remote https://github.com/gaetanzanella/swift-ssh-client
```

再重新执行打包脚本。

#### 2) 图标不刷新

先 `Product -> Clean Build Folder`，再重启 App。

### 协议

本项目使用 [MIT License](./LICENSE) 开源。

---

## 🇺🇸 English

AnotherShell is a native macOS SSH/SFTP client focused on a fast and clean workflow, inspired by tools like FinalShell, MobaXterm, and Tabby.

### Key Features

- Native macOS SSH session management (tabbed sessions)
- Embedded SFTP file browser and transfer panel (in-session)
- Client-side syntax highlighting (not dependent on remote ANSI colors)
- Bilingual UI (Chinese / English)
- Multiple themes (including Liquid Glass style)
- Real-time session and system status metrics

### Version

- Current version: `0.0.1`
- Channel: `Beta`
- Baseline commit: `feat: ship beta 0.0.1 UX and packaging baseline`

### Development Environment

- macOS
- Xcode (full Xcode installation recommended)
- Swift / SwiftUI

### Run Locally

```bash
open AnotherShell.xcodeproj
```

Select the `AnotherShell` scheme in Xcode and run.

### One-Command Packaging

Built-in packaging script:

```bash
bash scripts/package.sh --clean
```

Artifacts:

- `build/dist/AnotherShell.app`
- `build/dist/AnotherShell-Beta-0.0.1.dmg`
- `build/dist/AnotherShell-Beta-0.0.1.pkg`

Common options:

```bash
bash scripts/package.sh --help
bash scripts/package.sh --no-dmg
bash scripts/package.sh --no-pkg
bash scripts/package.sh --version 0.0.2
```

### Troubleshooting

#### 1) Empty `dist` directory

Usually `xcodebuild` failed early (package fetch/network/developer path issues).

Check with:

```bash
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
git ls-remote https://github.com/migueldeicaza/SwiftTerm
git ls-remote https://github.com/gaetanzanella/swift-ssh-client
```

Then rerun the packaging script.

#### 2) Icon not refreshed

Run `Product -> Clean Build Folder` in Xcode, then restart the app.

### License

This project is released under the [MIT License](./LICENSE).

