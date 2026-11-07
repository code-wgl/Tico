<div align="center">
  <img src="Assets/AppIcon/Tic-256.png" width="120" alt="Tico app icon">
  <h1>Tico</h1>
  <p><strong>把想法和待办留在桌面上。</strong></p>
  <p>Native floating notes and task lists for macOS.</p>

  [![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
</div>

Tico 是一款 macOS 桌面便签应用。每张便签都是独立的窗口，适合随手记录、整理任务，并在工作时保持内容可见。它基于开源项目 [Tic](https://github.com/kasvith/tic) 构建，并在此基础上持续改进。

Tico is a native macOS sticky-note app for keeping notes and tasks close at hand. It builds on the open-source [Tic](https://github.com/kasvith/tic) project.

## 功能 Features

- **桌面便签**：创建、移动、缩放和收起便签；可按需置顶或显示在所有空间。
- **任务与 Markdown**：使用清单、子任务和 Markdown 组织内容，支持拖动调整任务顺序。
- **外观与管理**：为便签选择颜色和背景，搜索便签，并在下次启动时恢复窗口状态。
- **本地存储**：通过 SQLite 保存便签和任务；正式版与开发版使用各自的数据目录。
- **更多工具**：提供图片、提醒、导入导出，以及可在设置中开启的 MCP 集成。

## 系统要求 Requirements

- macOS 14 或更高版本。
- 从源码构建需要 Swift 6.0 或更高版本，以及与项目依赖兼容的 Xcode 和 macOS SDK。项目开发规范使用 Swift 6.2 / Xcode 26。

## 安装 Installation

如果仓库已有可下载的构建，请在 [GitHub Releases](https://github.com/code-wgl/Tico/releases) 查看对应版本及安装说明。也可以按下方步骤从源码构建。

本项目的本地打包脚本使用 ad-hoc 签名；这种签名不等同于 Apple Developer ID 签名或公证，其他 Mac 的首次打开体验可能受到 macOS 安全设置影响。

## 从源码构建 Build from source

```sh
git clone git@github.com:code-wgl/Tico.git
cd Tico
swift build
swift test
./scripts/package.sh           # 开发版，使用独立数据目录
./scripts/package.sh --stable  # 正式版
```

项目使用 Swift Package Manager 管理依赖，首次构建需要联网下载依赖。打包产物位于 `dist/development/` 或 `dist/stable/`；使用 `--open` 可在打包后打开应用。也可使用 `open Package.swift` 在 Xcode 中打开项目。

> 兼容已有用户数据：正式版保留原 Tic 的应用标识和 `~/Library/Application Support/Tic/` 数据目录；开发版使用独立目录。备份和迁移时请注意保护自己的便签数据。

## 使用 Usage

1. 从菜单栏创建或查找便签，或使用 **⌘N** 新建。
2. 在便签内输入内容、管理任务，拖动调整位置和尺寸。
3. 双击标题栏可收起或展开便签；在设置中调整快捷键和其他偏好。
4. 需要 AI 客户端访问时，在应用的 MCP 设置中开启并按界面说明配置。

## 项目结构 Project structure

| 路径 | 用途 |
| --- | --- |
| `Sources/Tic/` | SwiftUI / AppKit 应用、窗口管理、数据库和 MCP 实现 |
| `Tests/TicTests/` | Swift 测试 |
| `Assets/`、`Packaging/` | 图标和应用打包资源 |
| `scripts/package.sh` | 本地开发版和正式版打包脚本 |
| `site/` | 项目网站 |

## 参与贡献 Contributing

欢迎提交 issue 和 pull request。提交前请描述问题或使用场景，保持修改范围清晰，并在本地运行 `swift build` 和 `swift test`。涉及界面、窗口、数据或打包的修改，也请说明实际验证方式和已知限制。

## 致谢与许可 Credits and license

Tico 基于 [Kasun Vithanage 的 Tic](https://github.com/kasvith/tic)。感谢原作者和所有贡献者。本项目按 [MIT License](LICENSE) 发布；原项目版权声明保留在许可证文件中。
