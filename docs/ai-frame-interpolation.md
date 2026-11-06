# AI 补帧扩展（实验实现，未完成 GPU 验收）

右键菜单“AI 补帧”独立于画质预设。默认关闭，新进程也关闭；按同一行开关。普通使用不下载、不启动Python，也不插入视频滤镜。

## 当前能做什么

- 安装器提供下载前确认、固定版本/大小/SHA256校验、独立Python/VS、解包路径检查、安装锁、失败保留旧环境。
- 下载清单固定Python 3.13.9、VapourSynth R82、vs-mlrt v15.16（TensorRT 10.16.0 / CUDA 13.2）；下载合计约3.33 GiB，需至少12 GiB可用空间。尚未在RTX5070验证此组合；驱动不兼容会导致探测或准备失败。
- 控制脚本支持独立开关、取消准备、旧任务结果作废、模型引擎在独立进程准备、只管理自己的 `@mpv_rife` 滤镜、不清除其他滤镜。已有其他vf时拒绝启用；shader不受此限制。
- 标准VS接入候选使用RIFE 4.25、2倍帧率、原尺寸、10位YUV输出、基础场景切换检测。支持范围目标为偶数尺寸最高3840×2160、1–30fps逐行输入。
- 识别到不同帧时长会拒绝继续补帧，但仅靠平均帧率不能证明CFR；真实VFR和片尾处理仍需验证。

**未验收：完整大型包安装布局、TensorRT引擎生成、5070实时性能、关闭后显存完全释放、真实片源跳转/切集/片尾、HDR静态元数据和实显。不能把菜单开关成功当成这些测试通过。**

## 在这台电脑上查看菜单

文件：`D:\Victor Zhang的项目文件\mpv-042-test\player\mpv.exe`。

位置：右键 → AI 补帧。普通查看选“查看运行信息”；不需要为查看界面安装环境。本机Intel Iris Xe不具备此TensorRT路线的目标NVIDIA GPU，先不下载大型依赖。

## 在家里安装和启动

配置源：`D:\Victor Zhang的项目文件\mpv`（本机开发位置，不是家里固定路径）。完整配置应复制到你家原来的 `C:\Users\Gosickless\AppData\Roaming\mpv`；如实际用户名不同，使用实际配置目录。

1. 在使用这套配置的mpv中，右键 → AI 补帧 → 安装／更新运行环境。确认框会列出下载体积、实际目录和实验限制。点击“是”才下载；取消不改变系统环境。
2. 默认目录为 `%LOCALAPPDATA%\mpv-rife`。在家里账号为Gosickless时是 `C:\Users\Gosickless\AppData\Local\mpv-rife`。可在 `C:\Users\Gosickless\AppData\Roaming\mpv\script-opts\rife.conf` 的 `runtime_root=` 填绝对目录；留空使用默认。
3. 安装成功后，右键 → AI 补帧 → 使用补帧环境启动新窗口。旧窗口保留；新窗口通过局部进程环境加载VS。安装不会修改系统PATH、Python或注册表。
4. 在新窗口打开SDR视频，点击“AI补帧：关闭”。先探测NVIDIA环境，再独立准备模型，成功后才把滤镜挂入播放链。输入/驱动/环境失败时显示不可用及原因。首次引擎生成可能需要数分钟，可以取消；已产生的磁盘缓存保留。

手动启动示例（两处路径按你的实际安装修改）：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:\Users\Gosickless\AppData\Roaming\mpv\rife\launch.ps1" -Mpv "D:\Software\mpv\mpv.exe"
```

`ExecutionPolicy Bypass` 只用于这个启动进程，不改系统执行策略。使用微软签名/系统策略禁止脚本的环境仍可能需要管理员按组织规则处理；不要为了扩展禁用系统安全设置。

## HDR10

实验候选链保持浮点PQ编码RGB，不先转SDR，再回到10位YUV。默认 `experimental_hdr=no`，HDR10会明确提示待验收；杜比视界与HLG拒绝处理。

只有明确接受未验证的HDR画质/元数据风险时，才在实际配置目录的 `script-opts\rife.conf` 改为 `experimental_hdr=yes` 并重启。此选项不是“正式HDR支持”开关。尚未证明静态母版信息、MaxCLL/MaxFALL在标准mpv桥接中完整往返，也未证明PQ域对这个SDR训练模型的预测准确性。第一版HDR10目标尚未完成验收，不静默降级为SDR。

## 运行环境和关闭行为

- `runtime/`：版本化Python、VS、推理库及上游许可文件。
- `cache/`：本机TensorRT引擎；不要把另一台电脑的缓存直接复制过来。
- `downloads/`：通过校验的下载包；再次安装可复用，半成品会重下。
- `staging/`：临时解包，失败不激活。当前不自动清理旧阶段/版本，避免误删使用中的环境。
- `progress.json` 和 `prepare-*.jsonl.stderr`：安装进度、模型准备错误。排查前检查日志是否包含本机路径，不要上传私有信息。

关闭只移除本扩展滤镜并取消准备，不改画质预设、音量或字幕。切集在同进程保留开启意愿，但重新检查片源；新进程默认关闭。异步滤镜错误会尝试关闭，不自动无限重载视频。运行库可能仍驻留进程，关闭后资源释放尚待GPU实测；彻底退出mpv是清理加载库的可靠边界。

当前未提供自动卸载菜单；如需清理，先关闭所有加载该环境的mpv/准备进程，备份需要的日志，再处理明确的环境根目录。不要删除mpv配置目录。后续补充经过测试的卸载/旧版本回收流程。

## 本机已完成的验证

- Python/VS小型样本可导入、创建CPU帧，标准mpv0.42.0可加载该VSScript。另用不含推理的CPU颜色往返样本验证了PQ、BT.2020、矩阵与10位输出标记可保留；不代表静态HDR元数据、RIFE画质或HDR实显通过。
- Lua控制：默认关闭、不添加vf，关闭不删除既有滤镜，缺少环境/不支持输入时拒绝开启，菜单状态正确。
- Python输入策略：1080p/1440p/4K、越界/奇数尺寸、高帧率、未知色彩、HDR实验门禁。
- PowerShell解析与安装计划只读检查；大型TensorRT/模型包未下载。

依赖来自Python、VapourSynth、AmusementClub/vs-mlrt官方发布资产。上游模型和推理库许可在下载包内，不把本控制脚本的分发许可视为它们的许可。
