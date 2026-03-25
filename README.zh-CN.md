# AnotherShell (Beta 0.0.1)

<p align="center">
  <img src="./AnotherShell/Assets.xcassets/AnotherShellLogo512.imageset/logo_512.png" alt="AnotherShell Logo" width="120" />
</p>

<p align="center">
  <a href="./README.zh-CN.md">简体中文</a> |
  <a href="./README.md">English</a>
</p>

AnotherShell 是一款原生 macOS SSH/SFTP 工具，定位为“简洁、稳定、好看、好用”的远程工作台，融合终端会话与文件传输体验。

## 项目初衷（温和版）

在长期使用同类工具的过程中，我们获得了很多启发，也看到了不同产品的侧重点：

- **FinalShell**：功能丰富、生态成熟；但在 macOS 场景下，部分用户会感受到 Java 技术栈带来的启动和交互延迟。
- **Termius**：产品体验非常完整、商业化能力强；但对部分个人开发者来说，付费门槛较高，同时界面风格更偏移动端。
- **Tabby**：跨平台能力突出、扩展性不错；但在某些设备或重负载场景中，可能出现资源占用偏高或交互不够丝滑的情况。

AnotherShell 的目标不是否定这些优秀产品，而是基于上述体验，提供一个更贴合 **macOS 原生交互**、更轻量、并对中文用户更友好的 SSH/SFTP 方案。

## 功能亮点

- 原生 macOS 标签式 SSH 会话
- 会话内嵌双栏 SFTP 文件传输
- 客户端语法高亮（不依赖远端 ANSI 颜色）
- 中英文界面与多主题（含 Liquid Glass）
- 会话状态与系统指标动态展示

## 软件截图

### 1) 主界面与会话工作台
![主界面与会话工作台](./docs/screenshots/use1.png)

### 2) 新建连接（简化连接表单）
![新建连接](./docs/screenshots/create-link.png)

### 3) 设置中心（语言 / 主题 / 外观）
![设置中心](./docs/screenshots/config.png)

### 4) SFTP 文件传输面板
![SFTP 文件传输面板](./docs/screenshots/sftp.png)

### 5) 关于页面（版本与项目信息）
![关于页面](./docs/screenshots/about.png)

## 社群与支持

### 粉丝群
![AnotherShell 粉丝群](./docs/screenshots/wechat_group.JPG)

### 作者微信二维码
![作者微信二维码](./docs/screenshots/wechat_me.JPG)

### 微信赞赏码（打赏支持）
![微信赞赏码](./docs/screenshots/wechat_reward.JPG)

## 版本信息

- 当前版本：`0.0.1`
- 通道：`Beta`

## 本地运行

```bash
open AnotherShell.xcodeproj
```

## 一键打包

```bash
bash scripts/package.sh --clean
```

默认产物：

- `build/dist/AnotherShell.app`
- `build/dist/AnotherShell-Beta-0.0.1.dmg`
- `build/dist/AnotherShell-Beta-0.0.1.pkg`

## 开源协议

本项目采用 [MIT License](./LICENSE) 开源。
