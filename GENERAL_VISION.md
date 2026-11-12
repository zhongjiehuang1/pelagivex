# PelagiVex：通用本机视觉识别

PelagiVex 的当前产品目标是通用视觉识别：观察日常场景中的多个目标，显示类别和置信度，保留短时跟踪，并允许用户指定固定类别表以外的搜索对象。水下场景是一个可选应用领域，原始门框模型保留为历史研究工件。

“通用”描述产品覆盖的任务与可扩展输入，并不表示模型可以自动、正确地命名画面里的一切物体。

## 两种识别方式

| 界面模式 | 模型与输入 | 能力 | 适用边界 |
| --- | --- | --- | --- |
| **Fast objects** | YOLOE-26s-seg-pf，640×640 RGB，原生 Core ML FP32；后台 SAM2.1 Tiny 细化轮廓 | 无需输入物体名，按内置 **4,585 名称词表**自动识别并分割；置信度、短时跟踪、A/B 近远比较 | 词表还含场景与描述词，不代表 4,585 种物理对象；误识别和漏检仍存在；SAM 更新频率与检测、显示频率分别统计 |
| **Text-guided objects** | OWLv2 Base，RGB 加自定义英文名称，再用 SAM2.1 Tiny 细化轮廓 | 搜索指定类别表以外的目标，返回名称、文字相关分数和物体轮廓 | 按输入词表搜索；不等于自动生成场景内所有名称；没有 A/B 深度比较 |

自动模式已不只限于原有的 80 类。内置词表的名称数量也不等于可靠识别类别数：它包含场景及形容性概念，实际预测可能出现不符合物理对象的标签。类别置信度只是该模型的原始分数，不能把词表扩大理解为准确率提高。

独立的文字搜索模式最多接受 32 个名称，适合按场景设置词表，例如：

```text
tissue box, headphones, charger, keys, pen, monitor, cabinet
```

输入对象的常用英文名通常比一整段抽象描述更易核对。近义词、细粒度名称和背景会影响结果；不同模式和不同搜索词的分数不能直接解释为同一标尺上的正确概率。当前入口没有验证任意中文描述的识别能力。

两种模式均可自动生成物体细轮廓，细化本身不要求手工描边或选 A/B。自动模式无需填写物体名称，用 YOLO 检测框提示 SAM；文字模式按已应用的词表识别，再用 OWLv2 的当前帧检测框提示 SAM。文字模式仍不提供 A/B 深度比较。切换识别模式或搜索词后，旧轨迹和 A/B 选择需要重置，以免把不同类别语义的结果连成同一目标。

## 自动细轮廓与速度

v0.8 新增 **Performance → Efficient preview**：停止摄像头后可切换到选择性混合精度识别模型，保持类别索引运算为 FP32，其余适合的运算采用 FP16；默认仍是 **Reference**。两次本机离线调度复跑约为 **30 FPS**，参考配置为 **26.32–26.56 FPS**，均开启后台 SAM，但不含渲染与深度，也不代表每秒 30 次 SAM。个别原始分数和小目标掩膜存在变化，因此保留为可选预览。[完整研究与复跑记录](pelagivex-native/apps/macos/PelagiVexNative/MAX_PERFORMANCE_RESEARCH.md)

v0.7 的 **Draw fine outlines** 默认开启，线宽默认为 **1.5 像素**，可在 **1–4 像素**之间调节。**Fast objects** 内的 **Live fine contours (SAM)** 也默认开启。YOLO 检测与显示持续处理新画面；本机 SAM2.1 Hiera Tiny 在独立队列中细化采样帧，不再让每次检测等待 SAM。队列同时最多处理一项任务，不积累旧帧。关闭该选项会停用额外 SAM 工作，保留 YOLO 自带的实例轮廓。

SAM 完成后，Metal 按目标逐一核对：旧、新观测必须具有相同的已确认跟踪 ID 和类别，来源年龄不超过 **0.65 秒**，框 IoU 至少 **0.45**，宽、高变化比各在 **0.7–1.4** 内，且画面宽高比保持一致。通过检查的轮廓用检测框之间的仿射映射移到当前框内；未通过的目标立即使用当前 YOLO 掩膜。掉检目标不会留下旧轮廓。切换模式、停用 SAM 或停止摄像头会清除缓存。细化纹理按 SAM 结果序号上传一次，再用于后续新帧。

这是一种保守的框几何近似，不能保证跟随非刚性形变、旋转、遮挡边界或错误关联；它没有估计光流。界面独立显示 **Inference / Display FPS** 与 **SAM refresh FPS、Worker 时间、Result age、Fine n/m targets**。例如 30 FPS 的检测或显示并不意味着每秒调用 SAM 30 次；`Fine n/m` 只表示当前通过传播门限的目标数。

细化实现位于原生模块的 `scripts/segmentation_refiner.py`。它按原始 RGB 画面坐标处理当前检测框，输出长边不超过 **1024 像素**的实例 ID 图。当前 YOLOE 原型掩膜为 **160×160**；历史 YOLO11 路径为 192×192。这些尺寸来自不同模型与输入设置，不能只按大小判断分割质量。细化可保留更多显示细节，但细线、透明部分、遮挡及错误检测仍可能造成不完整或错误边界。

当前额外 SAM 细化用于可视化，不替换自动检测模型自身用于深度汇总的掩膜。模型升级后识别及分割输入已改变，不能沿用旧模型的准确性结论；本次没有据此宣称 A/B 深度或测距更准确。SAM 的掩膜质量估计分数也不是类别正确概率。

## 本机运行与摄像头

从仓库根目录打开当前构建：

```bash
native=pelagivex-native/apps/macos/PelagiVexNative
open "$native/dist/PelagiVex.app"
```

选择 **Camo Camera** 可使用已连接手机的画面；也可选 Mac 摄像头。模型和 Python 环境已安装后，两种识别方式均在 Mac 上运行，不需要云 GPU。第一次模型加载与热启动推理必须分开看待。

快速模式中的置信度滑块控制新目标的接受阈值。当前 YOLOE 路径要求连续两次符合阈值与时序要求的观测才发布新目标，首次显示因此略晚；类别变化也需确认。对已有确认轨迹，仅在近期、强几何匹配且候选相互唯一时允许跨类别关联恢复 ID，确认前不将旧类别分数贴到当前观测。较弱观测可以延续已有轨迹；短时未检测的目标只保留明确标注的元数据，不能当作当前可见目标使用旧深度。文字模式仍按其分析帧生成轮廓，帧率与结果年龄另行观察。

## 模型依据与贡献边界

默认自动后端现为官方 **YOLOE-26s-seg-pf** 的本机导出，采用 schema 2 的端到端分割输出合同，输入为 640×640。它直接输出掩膜，因此 SAM 是额外轮廓细化选项，不是识别链路的必需第二阶段。此处没有重新训练基础模型，也没有将其称为在所有任务与硬件上最优。[YOLOE 官方文档](https://docs.ultralytics.com/models/yoloe) · [本机导出与复跑记录](pelagivex-native/apps/macos/PelagiVexNative/Model-YOLOE26s-PF-640/README.md) · [模型选择和后续微调路线](MODEL_ROADMAP.md)

OWLv2 来自 Google DeepMind 的 *Scaling Open-Vocabulary Object Detection*。该工作用文字条件和自训练扩大检测类别覆盖，是本产品使用的既有基础模型；接入它不构成新的视觉模型发明。[原论文，NeurIPS 2023](https://papers.neurips.cc/paper_files/paper/2023/hash/e6d58fc68c0f3c36ae6e0e64478a69c0-Abstract-Conference.html) · [Google 发布的 Base 模型卡](https://huggingface.co/google/owlv2-base-patch16-ensemble) · [Transformers 官方使用文档](https://huggingface.co/docs/transformers/model_doc/owlv2)

细轮廓使用 Meta 发布的 SAM2.1 Hiera Tiny 和原始 SAM 2 实现。官方代码和模型为 Apache-2.0；仓库另带 BSD-3-Clause 的可选连通分量代码，本路径不使用该扩展。[Meta 官方仓库及许可证](https://github.com/facebookresearch/sam2) · [官方 Tiny 模型卡](https://huggingface.co/facebook/sam2.1-hiera-tiny)

广类别自动词表与开放词汇搜索提供不同的输入方式，都不保证任意对象、材质、遮挡或视角的识别可靠。产品的研究增量仍要通过受控实验建立，例如 [主动获取顺序证据的研究候选](PAIR_NEXT_RESEARCH.md)。

## 当前验证怎样解读

已有 YOLO11 快速模式的 Camo 检测、置信度显示和短时跟踪验证见 [TRACKING_UPDATE.md](pelagivex-native/apps/macos/PelagiVexNative/TRACKING_UPDATE.md)。这些历史结果不等同于当前 YOLOE 后端的验证。

### 当前 YOLOE 导出与保存帧检查

最终采用 **FP32** 导出。先前 FP16 尝试在真实输入上把部分类别索引舍入成了相邻值，例如 4353→4352、3963→3964；FP16 不能精确表示 2048 以上的每个整数。被拒绝的尝试保存在 `.cache/yoloe26/export-fp16.log`。不能只看框大致相同，就将有类别索引错误的模型发布给用户。

最终 FP32 的相同保存 RGB 输入，对照导出分支的 PyTorch、Core ML CPU_ONLY 以及 Core ML ALL：真实帧上置信度高于 0.10 的 **11／11 个参考检测标签**保持一致，包括大于 2048 的奇数类别索引。模型即使在两后端给出相同的错误语义标签，也仍然会通过这项转换检查；所以这不是识别准确率证明。原始记录分别在模型目录的 `export-report.json` 和 `compute-unit-audit.json`。

在这台 M5 Pro 上，Core ML ALL 对该真实 640×640 保存输入的一次预热后五次模型调用，中位数约 **38 毫秒**，不含采集、缩放补边、解码、跟踪、显示及额外 SAM。PyTorch MPS 对两张保存真实帧的热调用约 **46–77 毫秒**，记录在 `.cache/yoloe26/mps-benchmark.json`；两个调用范围和模型分支不同，不能直接写成同一端到端 FPS 对比。

### v0.7 异步轮廓与跟踪检查

当前构建通过 **59 项 Swift 测试，分属 7 个测试组**，覆盖端到端解码、大类别索引、两帧确认、类别变化、掉检，以及轮廓传播的时间、身份、几何和数组重排门限。测试通过不代表真实识别或边界准确率。

异步与串行 SAM 的同模型本机调度对照、v0.7 Camo 短时观察及逐次结果的复跑入口见 [REALTIME_CONTOURS.md](pelagivex-native/apps/macos/PelagiVexNative/REALTIME_CONTOURS.md)。离线测试将保存的公共 Bonn 图像以人工设定的 30 Hz 输入节奏循环，排除渲染与深度；它衡量调度吞吐与处理延迟，不能当作原视频时间轴、摄像头持续帧率或识别精度对比。

SAM 的本机 FP32 优化在两个固定保存输入上与原 FP32 选择流程保持实例 ID 像素一致；局部热调用中位数约为 **两个目标 105 ms、五个目标 116 ms**。这证明这些输入的实现一致性，不证明相对于人工真值的精度；FP16 autocast 试验改变了像素，未作为默认配置。这些调用不包含完整摄像头链路，也不能据此声称 30 SAM FPS。冷启动、任务提交间隔和其他本机模型的竞争另行计入实际刷新率。[逐次计时与像素对照记录](.cache/general-vision/sam-profile/results.json)

跟踪审核复用 Bonn Crowd3 的 **112 个采样帧、545 条相同检测观测**。两帧确认与保守类别恢复将全场发布观测从 **545 降至 469**；已有人工身份别名目标的发布观测从 **71 降至 70**，其 ID 变化仍为 **1 次对 1 次**。这段真实输入体现了覆盖率代价，没有证明身份连续性提高，也缺少全场稠密真值以判断误报率。构造序列验证了短暂误标签被抑制，但不能替代真实准确率实验。[审核输入、结果与复跑方法](.cache/yoloe26/tracker-confirmation/README.md)

### v0.6 原生 Camo 短时实测（历史串行管线）

2026-11-07，v0.6 的 YOLOE-26s PF FP32 后端已接入 Camo Camera。以下保留当时原生界面的短时读数，输入为 **1920×1080**，模型内部仍使用 640×640 输入；其 SAM 串行等待方式已被 v0.7 替换：

| 配置 | 采集 | 推理 | 显示 | 界面 Model 时间 |
| --- | ---: | ---: | ---: | ---: |
| Extra boundary detail **关闭**，保留 YOLOE 自带实例轮廓 | 约 30 FPS | 约 30 FPS | 约 28 FPS | 约 20–21 ms |
| Extra boundary detail **开启**，YOLOE 加 SAM 细化，两个观察时点 | 约 30 FPS | 约 3.5–6.0 FPS | 约 3.5–5.9 FPS | 约 248–301.8 ms，含细化 worker 时间 |

当时的 **Extra boundary detail 默认为开启**。开启时两个观察时点有 **19–21 个当前目标**，分析帧年龄约 **0.39–0.44 秒**，界面的 Callback to GPU P95 两次约为 **375.9／466 ms**。物体细轮廓沿行李箱、灯具和椅子等目标显示；没有独立边界真值，不能据此给出轮廓准确率。

v0.6 SAM 开启时，`Model` 读数包含原检测模型时间加细化 worker 时间；v0.7 则分别列出检测和 SAM。FPS、单帧计时、帧年龄与 P95 的统计范围不同，也不能简单互取倒数。上述历史短时界面读数不能替代固定时长的持续性能基准，也不证明类别或跟踪准确率；当时没有保存摄像头录像。

三个界面观察时点、验证范围和构建记录保存在 [native-validation.json](model/yoloe26/native-validation.json)，其中包括 45 项 Swift 检查、签名验证以及 12 份历史配对回放报告逐字节一致的记录。

### 旧管线的记录

升级前，自动 YOLO11+SAM 的一次 Camo 观察约为 **4 FPS**，文字 OWLv2+SAM 约为 **2 FPS**。这是旧管线在当时场景中的界面观察，不能用作当前 YOLOE 的实时速度。

SAM 细化的保存帧探针使用 Bonn 椅子录像的一帧与两个已检测的椅子框。第一次 SAM 调用约 **2.198 秒**，其中记录的 SAM 加载约 **1.342 秒**；第二次热调用约 **0.421 秒**。这是同一帧、两个框的局部测时，不是分割准确率或持续摄像头帧率基准。原始记录位于 `.cache/general-vision/sam2-tiny-worker-probe.json`。该记录还包含一次 OWLv2 加 SAM 的文字搜索响应，不能把只细化两个已有框的时间当作整个文字模式耗时。

先前仅返回检测框、尚未加入 SAM 的 OWLv2 保存帧探针，两次 worker 处理约为 **0.401／0.208 秒**，记录在 `.cache/general-vision/open-vocab-worker-probe.json`。它是细化接入前的测时，不代表当前端到端速度。首次加载、Swift 图像准备、进程通信、显示和其他同时运行的模型都需计入完整链路。最终持续 Camo 实测须单独报告。

历史 v0.6 原生构建的 **45 项 Swift 测试**通过，包含端到端解码及大类别索引的三项检查，见 `.cache/yoloe26/build-native.log`。此前还有 **24 项 Python 测试**记录。单元检查不证明真实识别准确率、持续速度或轮廓精度；v0.7 的检查数量及适用范围见前文。

类别覆盖验证应包含固定 80 类之外的目标，并以人工核验的对象和框为参考，记录漏检和误识别。测试输入搜索词须在看结果前固定，不能只留下命中的词。不同词表长度、CPU/MPS、冷启动、热启动以及与实时相机并发的结果应分开报告。当前单帧测时不提供这些准确性结论。

历史配对实验所需 YOLO11 模型仍随包保留在 `Contents/Resources/LegacyStudyModel`，避免把新的默认检测器悄悄换进旧研究输入。自动广类别模型和这些历史受控回放分别记录。

## SAM2.1 Tiny 可复现安装

从仓库根目录运行。以下命令复用已有的 `.venv-model`，固定官方源码提交、权重和独立依赖目录，不升级该环境中的 PyTorch 或 Transformers：

```bash
mkdir -p .cache/sam2.1-tiny .cache/sam2-deps
if [ ! -d .cache/sam2-source/.git ]; then
  git clone https://github.com/facebookresearch/sam2.git .cache/sam2-source
fi
git -C .cache/sam2-source checkout --detach 2b90b9f5ceec907a1c18123530e92e794ad901a4
curl -fL --retry 2 \
  https://huggingface.co/facebook/sam2.1-hiera-tiny/resolve/de431c4/sam2.1_hiera_tiny.pt \
  -o .cache/sam2.1-tiny/sam2.1_hiera_tiny.pt
printf '%s  %s\n' \
  7402e0d864fa82708a20fbd15bc84245c2f26dff0eb43a4b5b93452deb34be69 \
  .cache/sam2.1-tiny/sam2.1_hiera_tiny.pt | shasum -a 256 -c -
.venv-model/bin/python -m pip install --target .cache/sam2-deps --no-deps \
  hydra-core==1.3.2 omegaconf==2.3.0 antlr4-python3-runtime==4.9.3 \
  iopath==0.1.10 portalocker==3.2.0
```

本次实际安装元数据在 `.cache/sam2.1-tiny/setup.json`，配置文件为 `configs/sam2.1/sam2.1_hiera_t.yaml`。现有运行环境为 PyTorch 2.8.0 和 Transformers 4.54.1；本路径直接加载 Meta 原始实现。依赖、权重或处理配置变化后，应重跑探针和相机验证，不沿用旧的时间或结果。

## 历史入口

仓库中的 Java/Tomcat API、原始 `web/` 页面、RF-DETR Gate 权重和移动端隧道演示仍对应原来的水下竞赛门任务。其数据、许可、模型校验和和复现方式保留在 [README 的历史原型部分](README.md#legacy-underwater-gate-prototype)。本次定位调整没有把这些历史模型变成通用模型，也不表示已经将新的识别能力部署到旧的公网服务。
