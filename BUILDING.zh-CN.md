# 从源码构建 MacSteamTool

本指南说明完整的 macOS 发布构建流程，包括通用应用、原生 Steam 接入、
Wine/CrossOver 桥接层、联机组件、DMG 安装镜像、ZIP 压缩包和源码压缩包。

## 环境要求

- macOS 14 或更新版本的 Mac。应用最低要求 macOS 14；应用内自动初始化要求
  macOS 15 或更新版本。
- Xcode Command Line Tools（或完整 Xcode），其中应包含 Swift、Clang、
  `codesign` 和 macOS SDK。
- [Homebrew](https://brew.sh)。仓库不会替你安装 Homebrew。
- 首次构建需要可用的网络连接。构建会下载若干固定版本、并经过 SHA-256
  校验的上游源码和二进制 SDK 压缩包。
- 几 GB 可用空间。SwiftPM 缓存和 Wine 构建目录位于被忽略的目录中，后续构建
  可以复用。

## 全新克隆后的步骤

在仓库根目录执行：

```sh
./script/bootstrap_build_env.sh --check
./script/build_and_run.sh --build
python3 script/package_release.py
```

第一条命令只读检查环境。如果已经安装 Homebrew，可以用下面的命令安装原生
构建所需的 formula，然后再次检查：

```sh
./script/bootstrap_build_env.sh --install
```

`--install` 不会安装 Xcode 或 Homebrew 本身。如果缺少其中任何一个，请先用
`xcode-select --install` 安装 Xcode Command Line Tools，并从 Homebrew 官网安装
Homebrew，再重新执行检查。

构建脚本会自动识别 Apple 芯片的 Homebrew（`/opt/homebrew`）和 Intel 的
Homebrew（`/usr/local`），不需要手动设置架构相关的 PATH。

## 每条命令的作用

- `script/bootstrap_build_env.sh` 检查 macOS 版本和所有命令行工具。只有显式
  使用 `--install` 时才会修改机器。
- `script/build_and_run.sh --build` 分别构建 arm64 与 x86_64 Swift 产物并合并
  成通用二进制，然后构建并打包 ConnectTool、PatchProbe、CloudRedirect、
  ManifestPins、NotProton、原生 Steam 接入以及 CrossOver/Wine 桥接层。
- `script/package_release.py` 校验通用应用，制作 arm64、x86_64 和 universal
  三种架构的 DMG 与 ZIP，同时生成源码 ZIP 和 `SHA256SUMS.txt`，最终统一放入
  `outputs/MacSteamTool-<版本>/`。

单独执行 `swift build` 并不能完成发布构建：它不会生成打包应用所需的原生
辅助组件和 CrossOver 桥接层。

## 下载内容和生成目录

源码仓库不会提交生成的二进制文件或大型上游源码树。全新克隆时，构建可能会
下载以下内容：

- SwiftPM 依赖（例如 ZIPFoundation），放在 `.build/` 或配置的 Swift scratch
  目录中。
- 固定版本的 Dobby，放在 `work/dobby/`。
- 固定版本的 Wine 源码与 Valve/Proton 头文件，放在
  `work/crossover-bridge-release/` 及其 scratch 目录中。
- ConnectTool 固定版本发布包和 SDK 切片，放在 `work/`。
- 原生接入所需的其他固定版本 Steam 头文件和运行时输入。

下载地址、版本和哈希记录在使用它们的脚本和清单旁边。下载中断或失败后可以
直接重试；脚本会先写入临时文件，校验通过后才替换缓存。日常迭代建议保留
`.build/` 和 `work/`。这些目录已写入 `.gitignore`，也会从源码发布包中排除。

## 打包和签名

打包使用 macOS 自带的 `hdiutil`、`ditto`、`lipo` 和 `codesign`。生成的应用和
安装包采用 ad-hoc 签名，适合本地使用，但不会自动公证。Developer ID 签名与
公证属于独立的发布步骤，不是本地构建或测试的前置条件。

## 常见问题

- **缺少命令：**运行 `./script/bootstrap_build_env.sh --check`；Homebrew
  formula 可用 `--install` 安装，Apple 工具可用 `xcode-select --install`。
- **Git、curl 或 SwiftPM 下载失败：**在同一个工作区重试即可。全新机器的构建
  依赖网络；`work/` 与 SwiftPM 中已经通过校验的文件会被复用。
- **Wine 源码版本不正确：**只删除未完成的
  `work/crossover-bridge-release/scratch/wine`，然后重新构建。除非要主动升级
  桥接层，否则不要修改固定版本。
- **出现磁盘 I/O 或旧构建错误：**先停止并行构建，只删除受影响的被忽略目录
  （例如 `work/swift-build-arm64`）后重试。不要删除受维护的源码目录。
- **在 Apple 芯片上构建 Intel 版本：**不需要 Intel Mac；构建使用 MinGW 和
  Swift 交叉编译生成 x86_64 切片。但完整游戏启动仍建议在实体 Intel Mac 上
  验证。

## 源码发布包

`script/package_release.py` 生成的源码 ZIP 会包含本指南、中文指南、脚本、源码、
清单、许可证和维护中的资源；`.git`、构建缓存、`work/`、`outputs/` 及其他生成
产物会被排除。其他开发者克隆仓库或解压源码包后，可以按上面的 bootstrap 步骤
重新构建。
