# AnotherShell (Beta 0.0.1)

AnotherShell 是一个原生 macOS SSH/SFTP 工具，目标是提供接近 FinalShell / MobaXterm / Tabby 的高效终端体验。

## 核心能力

- 原生 macOS SSH 会话管理（标签会话）
- 内置 SFTP 文件浏览与传输面板（会话内联）
- 客户端侧高亮（不依赖远端 ANSI 颜色）
- 中英文语言切换
- 多主题（含 Liquid Glass 风格）
- 连接信息、状态展示与实时刷新

## 版本信息

- 当前版本：`0.0.1`
- 版本通道：`Beta`
- 提交基线：`feat: ship beta 0.0.1 UX and packaging baseline`

## 开发环境

- macOS
- Xcode（建议完整安装，非 CommandLineTools）
- Swift / SwiftUI

## 本地运行

```bash
open AnotherShell.xcodeproj
```

然后在 Xcode 选择 `AnotherShell` scheme 直接运行。

## 一键打包

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

## 常见问题

### 1) dist 目录为空

通常是 `xcodebuild` 失败（依赖未拉取、网络问题、Xcode 路径不正确）。

先确认：

```bash
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
git ls-remote https://github.com/migueldeicaza/SwiftTerm
git ls-remote https://github.com/gaetanzanella/swift-ssh-client
```

再重新执行打包脚本。

### 2) 图标不刷新

清理构建缓存后重启 App：

```bash
# Xcode: Product -> Clean Build Folder
```

## 说明

- About 页面内已标注：本软件由 AI 协作方式构建。
- 项目当前仍在 Beta 阶段，欢迎继续迭代。

