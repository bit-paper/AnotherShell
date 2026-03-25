# AnotherShell (Beta 0.0.1)

<p align="center">
  <img src="./AnotherShell/Assets.xcassets/AnotherShellLogo512.imageset/logo_512.png" alt="AnotherShell Logo" width="120" />
</p>

<p align="center">
  <a href="./README.zh-CN.md">简体中文</a> |
  <a href="./README.md">English</a>
</p>

AnotherShell is a native macOS SSH/SFTP client focused on a clean, stable, and productive remote workflow with integrated terminal and file transfer experience.

## Why AnotherShell

This project was inspired by real-world use of several excellent tools in the ecosystem, each with clear strengths and different priorities:

- **FinalShell**: feature-rich and mature; however, some macOS users may notice heavier startup/interaction latency in Java-based workflows.
- **Termius**: polished and highly complete product; for some individual developers, pricing can be a higher barrier, and the UI language may feel more mobile-oriented.
- **Tabby**: strong cross-platform flexibility and extensibility; in certain environments, users may still experience higher resource usage or less smooth interactions.

AnotherShell is not meant to replace or dismiss these tools.  
Its goal is to offer a lighter, more **macOS-native** SSH/SFTP experience with practical defaults and a friendly bilingual workflow.

## Highlights

- Native macOS tabbed SSH sessions
- In-session dual-pane SFTP transfer panel
- Client-side syntax highlighting (independent from remote ANSI colors)
- Bilingual UI (Chinese / English) and multiple themes (including Liquid Glass)
- Live session status and system metrics

## Screenshots

### 1) Main workspace and active sessions
![Main workspace and sessions](./docs/screenshots/use1.png)

### 2) Create host connection (simplified form)
![Create host connection](./docs/screenshots/create-link.png)

### 3) Settings center (language / theme / appearance)
![Settings center](./docs/screenshots/config.png)

### 4) SFTP transfer panel
![SFTP transfer panel](./docs/screenshots/sftp.png)

### 5) About window (version and project details)
![About window](./docs/screenshots/about.png)

## Community & Support

### Fans Group
![AnotherShell Fans Group](./docs/screenshots/wechat_group.JPG)

### Author WeChat QR
![Author WeChat](./docs/screenshots/wechat_me.JPG)

### WeChat Reward (Donation)
![WeChat Reward](./docs/screenshots/wechat_reward.JPG)

## Version

- Current version: `0.0.1`
- Channel: `Beta`

## Run locally

```bash
open AnotherShell.xcodeproj
```

## One-command packaging

```bash
bash scripts/package.sh --clean
```

Default artifacts:

- `build/dist/AnotherShell.app`
- `build/dist/AnotherShell-Beta-0.0.1.dmg`
- `build/dist/AnotherShell-Beta-0.0.1.pkg`

## License

This project is released under the [MIT License](./LICENSE).
