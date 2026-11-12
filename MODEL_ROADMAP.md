# PelagiVex 模型路线：先部署成熟实时模型，再微调与研究结构

2026-11-07 核对官方文档和本机代码。本阶段已采用 **YOLOE-26s-seg-pf** 作为自动广类别识别与分割的部署基线，并接入原生应用；同时保留同尺寸的 **YOLOE-26s-seg** 原始可训练权重供后续微调。当前工作是将成熟模型适配到 Mac 产品；接入新模型本身不构成研究创新。

## 为什么选这条路线

| 路线 | 直接可用的能力 | 后续研究与产品取舍 |
| --- | --- | --- |
| **YOLOE-26s-seg-pf** | 无需输入物体名称，使用内置 **4,585 个名称**识别并产生实例掩膜；小尺寸模型便于先验证本机延迟 | 适合先解决“不想手工列词、也不只识别 80 类”；词表广不等于识别一切，长尾名称和误识别仍需评估 |
| **YOLOE-26s-seg** | 同系列的文字／视觉提示分割检查点 | 用于自有标注微调与架构实验；不能把部署版 PF 文件直接当成可训练源 |
| **RF-DETR-Seg** | 成熟的 COCO 预训练实例分割与微调路线，分割系列权重及代码为 Apache-2.0 | 是后续自有数据精度与许可条件的重要对照；预训练版本没有自动 4,585 名称的同等能力 |
| **SAM 3.1** | 官方最新发布包含多目标共享记忆处理，面向概念分割和跟踪 | 官方安装以 CUDA GPU 为前提；本项目尚无经验证的 Mac 原生运行路径，先作为研究对照，不直接许诺本机实时 |

YOLOE 的 PF 与普通检查点功能不同：PF 版支持预测、跟踪和导出，但不接受 `set_classes()`，也不是官方直接微调入口。Core ML 等静态导出的类别会固定，修改类别或结构需要回到原始权重重新导出。[YOLOE 官方模型说明](https://docs.ultralytics.com/models/yoloe)

RF-DETR 分割预训练模型使用 COCO；官方公布的分割延迟测在 **NVIDIA T4、TensorRT、FP16、batch 1**。SAM 3.1 的多目标加速展示也使用 NVIDIA 硬件。这些结果不能直接换算成 MacBook Pro 的 FPS，也不能将其中一个基准上的领先写成“所有场景 SOTA”。[RF-DETR 分割说明](https://github.com/roboflow/rf-detr/blob/develop/docs/learn/run/segmentation.md) · [RF-DETR 许可](https://github.com/roboflow/rf-detr#license) · [SAM 3 官方安装要求](https://github.com/facebookresearch/sam3#installation) · [SAM 3.1 发布说明](https://github.com/facebookresearch/sam3/blob/main/RELEASE_SAM3p1.md)

选择 YOLOE-26s 是对**自动广类别、直接输出掩膜、本机可部署性和后续可训练性**的工程判断，不是已经完成的全模型排名。Core ML 转换、原生解码和持续相机链路仍须以本机实测验收。

## 已有工件与验收标准

本机 PF 权重来自官方发布：

- URL：`https://github.com/ultralytics/assets/releases/download/v8.4.0/yoloe-26s-seg-pf.pt`
- SHA-256：`01605da3f2e0e5325df45d5f5eef8e40b5b5c7d085399be3c33ac638258b150a`
- 本机加载的词表数量：4,585；输出头：`YOLOESegment26`。
- 记录位置：`.cache/yoloe26/mps-benchmark.json`、`.cache/yoloe26/model-names.json`。前者是在少量保存帧上重复运行的 MPS 探针，包含冷／热调用，不能当作准确率或持续相机基准。

新后端验收应在同一输入分辨率与候选数量下分开记录：模型前向、后处理、掩膜重建、图像准备、进程通信、跟踪与显示；然后测持续 Camo 运行、P50/P95 延迟、丢帧与内存。PyTorch 和 Core ML 输出要按同帧匹配检查框、类别和掩膜，不能只检查模型文件能加载。

历史 **v0.6 串行 SAM** 部署完成了 Camo 短时验证：YOLOE-26s PF **FP32**、1920×1080 摄像头输入，关闭 **Extra boundary detail**、使用模型自带实例轮廓时，界面观察到采集约 **30 FPS**、推理约 **30 FPS**、显示约 **28 FPS**，原生 Core ML 模型时间约 **20–21 ms**。开启 SAM 细化的两个观察时点为推理约 **3.5–6.0 FPS**、显示约 **3.5–5.9 FPS**，有 19–21 个当前目标；其中一次分析帧年龄约 0.44 秒。当时 `Model` 约 248–301.8 ms 的开启状态读数包含细化 worker 时间。这里都是历史短时界面读数，不是当前 v0.7 速度、持续运行基准或识别、跟踪、轮廓准确率结果；没有保存摄像头录像。[三个历史观察时点与构建记录](model/yoloe26/native-validation.json) · [FP32 导出与保存帧一致性记录](pelagivex-native/apps/macos/PelagiVexNative/Model-YOLOE26s-PF-640/README.md)

当前 **v0.7** 使用 **Live fine contours (SAM)**，后台细化与新帧检测、显示分别运行；按已确认 ID、类别、0.65 秒有效期及几何门限传播近期轮廓，失效目标退回当前原生分割。SAM 刷新率与检测／显示 FPS 分开统计。其同模型离线调度实验、Camo 观察、复跑命令和局限见 [REALTIME_CONTOURS.md](pelagivex-native/apps/macos/PelagiVexNative/REALTIME_CONTOURS.md)。离线人工输入节奏下的吞吐提升不等于分割网络变成 30 Hz，也不等于识别精度提高。

当前原生构建通过 **59 项 Swift 测试、7 个测试组**；历史 v0.6 为 45 项，之前的细轮廓管线另有 **24 项 Python 测试**记录。单元检查不能直接证明真实速度或识别精度。原来的 YOLO11、OWLv2 与 SAM 路径可以作为对照和回退基线。

## 后续微调：使用可训练源，不用 PF 导出版

官方自有分割标注微调入口是 `YOLOEPESegTrainer`。其导入和构建逻辑已同时核对官方 API 与本次隔离安装的 **ultralytics 8.4.193** 源码；不能省略 trainer 参数后假设默认训练器具有同一语义。[官方分割训练器](https://docs.ultralytics.com/reference/models/yolo/yoloe/train_seg)

标注采用 YOLO 实例分割格式：每张图对应一个同名文本文件，每个对象一行类别索引和归一化多边形点，至少三个点。框标注不能直接冒充精细轮廓标注。训练／验证／测试按场景或录像分组，避免相邻帧跨集合。[官方数据格式](https://docs.ultralytics.com/datasets/segment/)

准备人工核验的数据集 YAML 后，可使用以下**未来运行模板**。路径是需要准备的工件，不表示仓库已经有这些标注；本次没有启动训练。

```bash
export PYTHONPATH="$PWD/.cache/yoloe26/ultralytics-deps"
.venv-model/bin/python - <<'PY'
from pathlib import Path

checkpoint = Path(".cache/yoloe26/yoloe-26s-seg.pt")
dataset = Path("data/general-vision/data.yaml")
if not checkpoint.is_file() or not dataset.is_file():
    raise SystemExit("Prepare the local trainable checkpoint and reviewed dataset YAML first.")

from ultralytics import YOLOE
from ultralytics.models.yolo.yoloe import YOLOEPESegTrainer

model = YOLOE(str(checkpoint.resolve()))
model.train(
    data=str(dataset.resolve()),
    trainer=YOLOEPESegTrainer,
    device="mps",
    batch=1,
    imgsz=512,
    epochs=30,
    workers=0,
    amp=False,
    cache=False,
    seed=42,
    project="runs/general-vision",
    name="yoloe26s-reviewed-finetune",
)
PY
```

`batch=1`、512 输入和关闭 AMP 是本机首次排查的保守起点，不是已经验证的最优超参数或训练时长保证。先用一轮小规模运行检查标签、显存、损失和输出，再执行正式实验；MPS 不支持的算子或内存问题应保留原始报错，不能静默改到云端。[官方 MPS 训练方式](https://docs.ultralytics.com/modes/train/#apple-silicon-mps-training)

首次将类别名称编码进普通检查点时，还需预先准备匹配的 CLIP 分词依赖和 `mobileclip2_b.ts` 文本编码器，才能离线完成该路径。它们不是 PF 推理的运行依赖。

此微调会把自有类别融合进输出头，得到针对该数据集的专用模型；它不会自动保留可任意换词或完整 4,585 名称的原有能力。因此保留原始 PF 广类别模型，将微调模型作为单独配置，按留出场景比较二者，而不是用专用头替换通用模型后仍宣称能力完全相同。

RF-DETR-Seg 是并行对照：可从 `RFDETRSegSmall` 等尺寸特定预训练类开始，在同一批人工标注上微调并比较。它支持 COCO JSON 或 YOLO 数据入口；具体训练参数须固定到使用的版本。[官方训练源码文档](https://github.com/roboflow/rf-detr/blob/develop/docs/learn/train/index.md)

## 后续结构实验：由失败案例决定变量

先固定成熟模型基线、场景划分、标签、随机种子集合和部署预算，再选一个经证据支持的瓶颈。例如，小物体漏检可研究更高分辨率特征；细长目标边界不完整可研究分割头或训练损失；跨帧闪烁则需要时序证据或关联机制。每次只改变一个因素。

项目已保存可编辑的 **s 尺寸**结构副本 [model/yoloe26/yoloe-26s-seg.yaml](model/yoloe26/yoloe-26s-seg.yaml)，固定 `scale: s`；不能用未指定尺寸的泛型文件名代替后假设它会加载同一结构。标准结构与可训练检查点的初步匹配已加载 **958／958 项参数**，这只是结构复现与加载检查，没有进行训练。后续从该副本建立有版本号的实验配置，再加载形状兼容的预训练参数。保存配置差异、实际加载与随机初始化的项数、训练计算量以及模型输出合同。[本项目模型配方](model/yoloe26/README.md) · [官方结构配置](https://github.com/ultralytics/ultralytics/blob/main/ultralytics/cfg/models/26/yoloe-26-seg.yaml)

每个候选至少比较：原模型、只微调、结构改动加相同训练预算。报告框／掩膜指标、边界指标、按尺寸与遮挡分组的漏检、跨帧 ID 连续性，以及本机端到端延迟与内存。若仅因更多训练、更大输入或更大模型获益，需要将这些控制项分开。改变输出结构后重新验证原生解码与 Core ML 一致性；一次未完成的导出不能记为可部署结果。

## 许可路径

Ultralytics 源码采用 AGPL-3.0，另有 Enterprise 许可路径。研究工件应保留源码、版本、配置、权重来源和适用许可；后续分发或闭源商业交付再根据实际使用方式核对相应条款。RF-DETR-Seg 的 Apache-2.0 许可可作为产品选型的另一项因素。[Ultralytics 源码许可](https://github.com/ultralytics/ultralytics/blob/main/LICENSE) · [官方许可选项](https://www.ultralytics.com/license)
