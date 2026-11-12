# PelagiVex 3D 工作台

将同一物体的原始多角度照片放进一个目录。PelagiVex 在 Mac 上用 RealityKit `PhotogrammetrySession` 对齐视角、生成网格并贴图，导出 USDZ 和对应的 `.usdz.capture.json`。应用会检查本机支持情况。macOS 26 可能在首次使用时下载并缓存改进的低纹理重建模型，离线时系统可使用已有模型。 [Apple 重建 API 指南](https://developer.apple.com/documentation/realitykit/creating-3d-objects-from-photographs) · [macOS 26 发布说明](https://developer.apple.com/documentation/macos-release-notes/macos-26-release-notes#Object-Capture)

## 拍摄自己的物体

- 选表面有纹理、形状固定的物体，先用均匀的漫射光拍摄。透明、镜面反光或缺少纹理的区域容易出现缺失。
- 固定物体，绕它缓慢移动。拍到所有侧面，再补拍较高和较低的视角。需要底面时可以翻转刚性物体，并保留与前一组照片重叠的特征。
- 让物体占画面大部分。保持焦距、对焦和曝光一致，相邻两张尽量至少重叠 70%。低于 50% 时，Apple 提醒对齐可能失败或质量下降。保留清晰的原始照片和元数据。
- 先准备几十张不同视角的照片。应用要求至少 20 张不同且可读的输入。Apple 在 WWDC 建议按对象复杂度拍摄约 20–200 张近照。照片数量和角度覆盖都影响结果。没有可用的深度或已知比例尺时，尺寸需要另行校准。 [Apple 拍摄指南](https://developer.apple.com/documentation/realitykit/capturing-photographs-for-realitykit-object-capture) · [WWDC21 Object Capture](https://developer.apple.com/videos/play/wwdc2021/10076/)

## 在最新版应用中操作

轻点待命画面开启摄像头。系统自动锁定持续可见的跟踪目标，显示类别和置信度，并生成蓝色 **预测 3D** 卡片。短暂掉检时锁定保留最多 1.6 秒，轮廓随有效的当前检测恢复。锁定期间 SAM 优先细化该物体，其余目标显示识别模型的轮廓。

卡片固定为 260 × 208 点，目标跨过中线缓冲区后才换到对侧。卡片会在对侧寻找留白，找不到安全位置就暂时隐藏。蓝色线框自动慢转，也可拖动旋转。滚动或捏合可调整卡片内模型的缩放，切换目标或恢复显示时保留该比例。实时卡片只在内存中用单帧轮廓推测闭合体积。点右上方透明区域或右键画面可打开选项。

从选项打开 **高级工作台**。把物体完整放在画面中央，点 **一键建模**，应用会锁定目标并自动选择建模路径。

- **保持同一个视角**。从锁定帧的实例轮廓和 Depth Anything V2 相对深度生成闭合、有厚度的蓝色线框。采样器连续五次判断画面重复后自动开始生成，通常需先稳定约 5–7 秒。背面和厚度采用几何推断，模型尺寸为归一化单位。深度模型不可用时，采样器仍可用有效轮廓生成闭合体积。USDZ 记录保留所用方法和耗时。 [Apple Core ML 模型](https://developer.apple.com/machine-learning/models/)
- **缓慢绕拍**。按提示拍摄一圈并补拍高角度。应用过滤重复、偏暗、细节不足和变化过大的画面。五段都达到采样条件后提交给 RealityKit，生成带纹理和特征标注的模型。可暂停，也可在至少 20 张合格照片后提交。引导阶段依据画面变化和保存计数推进，相机角度与覆盖率没有标定。

从实时识别开始时，打开 **分析 → 启动并扫描**。目标锁定后点 **引导绕拍建模**，按正面、第一侧面、背面、另一侧面和高角度五段拍摄。每段由你确认方向并启动采集，每秒保存一张完整画面，每段至少四张。保持同一物体静止，缓慢移动镜头，给相邻照片留重叠。五段齐备后点 **生成带标注的模型**。

模型视图用红色引线显示锁定时记录的整物特征。像素尺寸和深度来自锁定帧，模型没有经过实物尺度标定。导出时勾选 **同时导出重建记录和特征标注**，让 `.usdz.capture.json` 和 USDZ 一起保存。用 PelagiVex 重新打开匹配的模型会恢复标注。

也可以独立进行照片采集或导入：

1. 打开 `dist/PelagiVex.app`，在视频选项的 **摄像头来源**中选择 Camo Camera，然后轻点画面开启摄像头。再从视频选项打开 **高级工作台**，进入 **3D**。
2. 在画面里 **框选区域**，包住完整物体并留出移动余量。列表按检测框中心筛选区域目标，扫描保存照片按该区域裁剪；底层识别仍处理全画面。镜像只影响显示，保存照片保持原始方向。
3. 点 **开始新扫描**，围绕静止物体缓慢移动，补充高低角度。每秒最多保存一张，最多 180 张。至少 20 张才能提交，这是应用门槛，不是完整覆盖保证。停止后可在 Finder 查看照片；再次点“开始新扫描”会建立另一个目录。
4. 点 **停止并重建 / 重建已拍照片**。应用先写完已接收照片，再停止实时识别和相机，运行本机重建。也可直接 **导入照片文件夹…** 使用手机拍摄的高分辨率原图。
5. 完成后自动进入模型视图：拖动旋转、滚动或按钮缩放、切换线框、重置相机。**导出 USDZ…**保存含纹理的模型，可勾选同时导出记录。重启后通过 **打开已有 USDZ…**恢复查看。

照片与模型保存在 `~/Library/Application Support/PelagiVex/Scans/`。不会自动删除输入。拍摄中相机画幅改变会停止该次扫描；请固定手机方向、镜头和焦距。这里不估计实时相机轨迹，也不以照片数量伪装成表面覆盖率。Camo 当前输入实际是 1280×720；高分辨率原图导入可以保留更多拍摄细节。尺寸没有标定，缺失表面仍需要补拍。

## 可复跑样本

单视角回放位于仓库根目录的 `.cache/single-view-study/automatic-replay/`。运行其中的 `run.sh`，同一张 Rock36 真实照片以递增采集时钟重复送入正式筛帧和重建逻辑。测试使用 Vision 的前景掩膜注入目标锁定，验证重复采样自动触发、Core ML 深度使用、文件记录、重新打开和 USDZ 校验。逐阶段耗时、几何拓扑、蓝色线框的正面与侧面预览以及仅轮廓对照，在 `.cache/object-capture-validation/single-view-rock36/` 中可复跑。回放没有经过 Camo 或实时识别锁定。

打包默认从 `.cache/coreml-depth-v2/DepthAnythingV2SmallF16.mlmodelc` 或同名 `.mlpackage` 载入相对深度资源，也可用 `PELAGIVEX_RELATIVE_DEPTH_MODEL_DIR` 指定目录。以下命令从仓库根目录准备官方模型。使用已编译资源时应用无需在首次运行自行编译包。

```bash
mkdir -p .cache/coreml-depth-v2
cd .cache/coreml-depth-v2
curl -fL https://ml-assets.apple.com/coreml/models/Image/DepthEstimation/DepthAnything/DepthAnythingV2SmallF16.mlpackage.zip -o apple-depth-v2-small.zip
echo '8e875979ec82fa46f292468a7567a520b2aa07c41008c32141f3396da05a4067  apple-depth-v2-small.zip' | shasum -a 256 -c
ditto -x -k apple-depth-v2-small.zip .
swift -e 'import CoreML; import Foundation; let input = URL(fileURLWithPath: "DepthAnythingV2SmallF16.mlpackage"); let compiled = try MLModel.compileModel(at: input); try FileManager.default.copyItem(at: compiled, to: URL(fileURLWithPath: "DepthAnythingV2SmallF16.mlmodelc"))'
```

一键建模的验证产物在仓库根目录的 `.cache/object-capture-validation/auto-orbit-smoke-20261107T184305Z/`。用 Apple Rock36 回放代替摄像头输入，注入目标锁定后，实际采集代码跳过重复帧、每段保存 6 张，并自动提交 30 张照片给本机重建。`Rock36-auto-annotated.usdz` 和随附记录通过校验并能恢复标注。真实手机绕拍仍需单独验证。

使用 Apple 官方命令行示例附带的 Rock36。已下载 36 张原始 HEIC 照片，共 71,922,240 字节。解压时保留了原文件名和图像字节。样本文件和参考模型带有随包的 `LICENSE.txt`，版权为 © 2025 Apple Inc.，许可要求保留版权和许可声明。 [Apple 官方示例](https://developer.apple.com/documentation/realitykit/creating-a-photogrammetry-command-line-app) · [样本原始压缩包](https://docs-assets.developer.apple.com/published/8ca2a2cfae7e/CreatingAPhotogrammetryCommandLineApp.zip)

带标注的实机验证产物位于仓库根目录的 `.cache/object-capture-validation/guided-link-smoke-20261107T182458Z/`。36 张样例照片用约 64 秒生成 `Rock36-annotated.usdz`。应用重新打开后恢复验证样例的三条标注，拖动旋转时引线跟随模型。记录哈希不匹配时，模型仍可打开，标注会隐藏。Camo 实测覆盖锁定到引导入口，`bash scripts/test_object_capture.sh` 覆盖分段写入和暂停，用户物体的完整绕拍留待实际体验。

| 文件 | 大小（字节） | SHA-256 |
| --- | ---: | --- |
| `Rock36Images.zip` | 71,671,621 | `1fb15cca86402f021b8172fc633603aa6e06ece2e77071ef5bf573255eea4ac8` |
| `Rock36_reduced.usdz`，Apple 提供的参考模型 | 4,575,949 | `355d50a0fb847537048b82edaa3058cde4eba3890b09cdd3c107dbd86adafd42` |
| `LICENSE.txt` | 1,225 | `556c0c44df6826fa5f63651ea926b717b78e02a894cd4a4da064751c57743481` |

本地目录为 `.cache/object-capture-fixture/apple-rock36/`，其中 `provenance.json` 记录来源、归档标识、校验和与每张照片的 SHA-256。目录已准备好时可直接使用 `images/`。重新准备时运行 `python3 .cache/object-capture-fixture/download-apple-rock36.py`。该脚本通过 HTTP 字节范围读取所需成员并验证 ZIP CRC。也可以从上面的 Apple 链接下载官方归档，取出 `Data/Rock36Images.zip` 和 `LICENSE.txt`，再解压照片。

当前机器上的 SceneKit 读档探针从 Apple 参考文件读出 1 个几何节点、1 个材质和 25,000 个三角面，三轴边界有效。记录位于 `apple-rock36/reference-viewer-probe.json`。这项检查验证参考文件能被加载，PelagiVex 的重建文件在下面的独立输出目录生成。macOS 的 Preview 和 Quick Look 也可打开 USDZ。 [SCNView 文档](https://developer.apple.com/documentation/scenekit/scnview) · [Apple USD 查看器文档](https://developer.apple.com/documentation/usd/creating-usd-files-for-apple-devices)

另有一套可复用的公开实拍备选数据。`.cache/object-capture-fixture/images/` 保存 MicroPasts 的 54 张 Arreton Down 文物照片，共 203,552,277 字节，来源固定于 `ff6a818b226c73018ce331e38fd2ceea1aa1a0e9`。按 CC BY 4.0 署名 Andy Bevan、Chiara Bonacchi、Adi Keinan-Schoonbaert、Dan Pett 和 Neil Wilkin。其许可证和逐张哈希在同级目录。 [MicroPasts 原始数据仓库](https://github.com/MicroPasts/socketed-axe-version2/tree/ff6a818b226c73018ce331e38fd2ceea1aa1a0e9)

## 本机实测

2026 年 11 月 7 日，在 Apple M5 Pro、macOS 26.5.1 上，用同一重建后端编译的独立命令行入口处理 36 张 Rock36 原始照片。细节选 `reduced`，匹配顺序选 `unordered`。命令成功退出，耗时 75.64 秒，后端记录处理耗时 75.11 秒。

本机生成的 `model.usdz` 为 10,074,408 字节，SHA-256 为 `6a8bbfbcb7c29a19525a51a30b44eeece43b96c8b72baaf236994bf8d2b5ae67`。ZIP CRC 校验通过，内有一个 USDC 网格和三张 PNG 贴图，输出哈希与重建记录一致。SceneKit 读出了 1 个网格节点、1 个材质、25,000 个三角面和有限的三轴边界。

重建记录的输入提示为空。Apple 的资产打包组件在 stderr 中报告了中间贴图引用路径诊断，最终归档包含环境遮蔽、法线和颜色贴图。进度、stderr、逐图输入哈希、输出校验和读档探针保存在 `.cache/object-capture-validation/rock36-reduced-20261107T061557Z/`，对应 `stdout.log`、`stderr.log`、`model.usdz.capture.json`、`validation.json` 和 `model-viewer-probe.json`。

另用合成彩色画面测试了采集路径。镜像取景中的框选保存了对应的未镜像 160 × 160 原始区域，确认一秒采样间隔、结束前写完最后一帧、拒绝尺寸变化和写入失败回滚。可在本目录运行 `bash scripts/test_object_capture.sh`，已保存结果见 `.cache/object-capture-validation/capture-regression.json`。

这次公开样本实测验证了从真实照片到可读取的贴图网格的流程。几何精度和完整覆盖仍需独立参照。用手机围绕用户自己的物体完成一次采集和重建，是后续的实测项。

## 运行和核对本机输出

在仓库根目录运行以下命令。`reduced` 是默认细节级别，也可指定 `preview` 或 `medium`。命令行导入使用无序照片匹配、常规特征灵敏度及物体遮罩。每次复跑请选一个新输出名。

```sh
pelagi_studio_run=$(mktemp -d "$PWD/.cache/object-capture-fixture/reproduction-run.XXXXXX")

pelagivex-native/apps/macos/PelagiVexNative/dist/PelagiVex.app/Contents/MacOS/PelagiVexNative \
  --object-reconstruct "$PWD/.cache/object-capture-fixture/apple-rock36/images" \
  "$pelagi_studio_run/Rock36_pelagivex.usdz" reduced \
  > "$pelagi_studio_run/reconstruct.log" 2>&1

swift .cache/object-capture-fixture/inspect-usdz.swift "$pelagi_studio_run/Rock36_pelagivex.usdz"
```

完成后可在应用里旋转、缩放查看模型，并打开 `Rock36_pelagivex.usdz.capture.json` 核对使用的照片、设置、耗时、输出大小与哈希。查看记录中是否出现照片跳过、分辨率下采样或视角拼接不完整等提示。Apple 的参考模型可作视觉对照。尺寸和形状精度应使用独立测量验证。


## 最终安装包交互验收

`bash scripts/build.sh` 已通过 62 项 Swift 测试（8 个套件）并完成签名校验。通过正式应用的“导入照片文件夹”再次提交同一 36 张 Rock36 原始照片，实际生成带纹理模型并自动进入完整 3D 视野。本次应用内处理用时 75.76 秒，完整后端用时 75.95 秒，输入提示 0 条。模型保存于 `/Users/zhongjiehuang/Library/Application Support/PelagiVex/Scans/import-F484AB5E-940B-4CE5-80FE-71BC8F0EDE1B/model.usdz`，其旁边有原始记录。独立 CLI 的 75.64 秒记录仍保留，两次运行不合并成性能统计。

已在原生界面验证 Camo 实时出帧、区域框选与列表筛选、清除区域、真实模型纹理显示、拖动旋转、放大缩小、线框、重置和 USDZ 导出。导出模型及记录与原文件逐字节一致。界面只显示“最新版”，dist 只保留一个应用。详细检查与最终文件哈希见仓库根目录 `.cache/object-capture-validation/app-verification.json`；清理清单为 `.cache/cleanup/latest-only.json`。

按用户选择，本轮没有保存新的个人摄像头照片，没有开展手机绕拍完整物体验证。合成源帧测试验证采集写盘与 ROI 坐标；真实公开照片验证重建和交互。两者不能替代未来对用户实际物体的完整绕拍与形状精度评估。
