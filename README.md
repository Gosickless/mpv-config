# 我的 mpv 配置

Windows 下使用的个人 mpv 配置，主要用于动漫播放。包含 ModernZ 界面、中文右键菜单、字幕搜索、播放进度保存，以及 Anime4K / ArtCNN 着色器。

本仓库保存配置、脚本、字体和着色器，播放器本体需要单独安装。

## mpv 本体版本

**使用的是开发构建，不是正式发布的 mpv 0.41.0。**

2026-10-24 在本机 `D:\Software\mpv\mpv.exe` 执行 `--version`，得到：

```text
mpv v0.41.0-923-g7b8915bc1
built on Aug 14 2026 00:28:16
libplacebo version: v7.371.0 (v7.360.0-111-g22ee762-dirty)
FFmpeg version: N-126125-g1d7b14f61
```

其中 `-923-g7b8915bc1` 是 Git 开发版本标识，不能省略后就当作正式版版本号。上面的 libplacebo 版本也保留了构建输出中的 `dirty` 标记。

这份配置以该开发构建为使用基准，尚未验证正式发行版或其他开发构建的兼容性。配置使用了 `load-context-menu`、`save-watch-history`、`window-corners` 等选项，以及菜单和脚本接口；更换版本后如出现未知选项或菜单异常，请先核对播放器版本。

本仓库没有附带该构建的安装包，也没有确认其下载来源。升级本体后，可在 PowerShell 中运行以下命令，并更新本节记录：

```powershell
& "D:\Software\mpv\mpv.exe" --version
```

如果播放器装在其他位置，请替换命令中的路径。

## 安装与使用

1. 单独准备 mpv 播放器，版本基准见上文。
2. 备份已有配置，将本仓库内容放入 `%APPDATA%\mpv`，即通常的 `C:\Users\你的用户名\AppData\Roaming\mpv`。
3. 检查 `mpv.conf` 中的截图目录。目前为 `D:/Picture/mpv截图`，请按自己的目录修改。
4. 重新启动 mpv 并打开视频。

如播放器目录下另有 `portable_config`，请检查实际加载的是哪套配置。也可以显式指定本仓库目录启动：

```powershell
& "D:\Software\mpv\mpv.exe" --config-dir="$env:APPDATA\mpv" "D:\Video\example.mkv"
```

该命令中的播放器和视频路径都需要按实际情况替换。

## 文件说明

| 路径 | 用途 |
| --- | --- |
| `mpv.conf` | 渲染、解码、音轨与字幕偏好、截图和界面设置 |
| `input.conf` | 自定义快捷键 |
| `menu.conf` | 中文右键菜单 |
| `menu.conf.example` | 菜单参考文件 |
| `script-opts/` | 各脚本的选项 |
| `scripts/` | ModernZ、thumbfast、文件浏览器、字幕搜索等脚本 |
| `script-modules/` | JavaScript 脚本使用的模块 |
| `fonts/` | 界面图标字体 |
| `shaders/` | Anime4K 和 ArtCNN 着色器 |

自动保存脚本按 `script-opts/auto_save_state.conf` 中的设置每 30 秒保存播放进度。音量脚本把全局音量保存至 `script-opts/volume_state.txt`。

## 常用快捷键

| 按键 | 功能 |
| --- | --- |
| `←` / `→` | 精确后退 / 前进 3 秒 |
| `↓` / `↑` | 降低 / 提高音量 5 |
| `Shift+↓` / `Shift+↑` | 降低 / 提高音量 1 |
| `Ctrl+1` 至 `Ctrl+6` | 切换 Anime4K 模式 A、B、C、A+A、B+B、C+A |
| `Ctrl+7` | 启用 ArtCNN C4F32 |
| `Ctrl+0` | 清除所有 GLSL 着色器 |
| `Ctrl+A` | 打开 assrt 字幕搜索 |
| 鼠标右键 | 打开上下文菜单 |
| `>` / `<` | 先保存进度，再切换下一集 / 上一集 |
| 鼠标前进 / 后退侧键 | 先保存进度，再切换下一集 / 上一集 |
| `Enter` | 先保存进度，再切换下一集 |
| `Ctrl+I` | 调用输入配置编辑入口 |
| `Ctrl+,` | 调用配置文件编辑入口 |

着色器通过快捷键手动选择；具体绑定以 `input.conf` 为准。

## Git 与 GitHub

本地仓库已初始化，分支名为 `main`。Git 的提交保存本地快照，`git push` 才会把提交上传到 GitHub。

首次上传：

1. 登录 GitHub，打开 [新建仓库页面](https://github.com/new)。
2. 填写仓库名，例如 `mpv-config`，选择 `Private`（私有）或 `Public`（公开）。
3. 创建一个空仓库：不要初始化 README、`.gitignore` 或 License，本地已有提交和相应文件。
4. 点击 **Create repository**，复制新仓库的 HTTPS 地址。
5. 在 PowerShell 中执行下面的命令，将示例地址替换为自己的仓库地址：

```powershell
Set-Location "$env:APPDATA\mpv"
git remote add origin https://github.com/YOUR_USERNAME/mpv-config.git
git push -u origin main
```

首次推送如出现登录或授权提示，按提示完成 GitHub 身份验证。上传后刷新仓库页面，应能看到配置文件和本 README。

以后修改配置后，在本仓库目录执行：

```powershell
git status
git diff
git add .
git commit -m "更新 mpv 配置"
git push
```

先通过 `git status` 和 `git diff` 检查即将提交的内容。`.gitignore` 排除了常见的播放状态、缓存、历史、日志，以及本地音量和收藏文件；这些文件仍保留在本机。播放器也可能把状态保存在 `%LOCALAPPDATA%\mpv`，该目录不属于本仓库。

`scripts/assrt.lua` 自带一个 API token 默认值，`script-opts/assrt.conf` 也提供自定义 token 配置入口。公开仓库前请确认没有填入个人凭据；`.gitignore` 不会自动隐藏配置文件里的敏感字段。

上传流程参考 [GitHub 官方文档：将本地代码添加到 GitHub](https://docs.github.com/en/migrations/importing-source-code/using-the-command-line-to-import-source-code/adding-locally-hosted-code-to-github)。

## 第三方内容

仓库包含第三方脚本、字体和着色器。请保留文件中的作者、来源及许可声明；具体使用和再分发条件以各组件原有许可为准。
