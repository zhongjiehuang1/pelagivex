# PelagiVex Native — macOS V0.1 development preview

原生 SwiftUI + AVFoundation + Core ML + Metal 实例分割原型。
保留原仓库的 Java/Web/水下 Gate 版本，不修改其部署。

**当前不是已在 M5 真机验收的正式版。** 源码已实现完整的摄像头→推理→掩码→显示路径，
但必须区分源码实现、编译通过、模型转换通过和实际摄像头性能这四个层次。
没有权重时只显示真实摄像头预览，绝不生成模拟检测。

## 首次使用（在你的 Mac 上）

需要 Apple Silicon、macOS 14+、Xcode Command Line Tools，以及导出模型时使用的 Python 3.11/3.12。
先在终端进入本目录；不需要启动 Java、Tomcat 或 Web 服务。

```bash
# 首先构建摄像头预览版；不会下载模型或训练数据。
bash scripts/build.sh
open dist/PelagiVex.app
```

读取上游模型许可后，使用隔离的 Python 环境下载官方 YOLO11n-seg 权重并导出：

```bash
# 这一步会从 PyPI / 官方模型发布源下载依赖和模型；不是后台自动任务。
# 使用 Python 3.12 时可写 PYTHON=python3.12 bash scripts/setup_model.sh ...
bash scripts/setup_model.sh --acknowledge-model-license
bash scripts/build.sh
open dist/PelagiVex.app
```

第二次打包会把导出的模型编译并放进 App；之后本地推理不需要 Python 或联网。
也可以在预览 App 中选择 `Model` 文件夹加载模型。启动摄像头必须由用户点击并授权。
构建使用本地 ad-hoc 签名，不是 Developer ID 签名或公证版本；不要求关闭 Gatekeeper。

## 已实现

- 优先内置摄像头，BGRA `CVPixelBuffer` 输入，最高请求 30 fps，记录实际采集速率。
- 串行推理、最多一帧待处理，后来的帧替换过期帧；不积压 JPEG 或网络请求。
- Core ML 四种允许算力配置：全部、CPU+GPU、CPU+ANE、CPU 对照。实际算子分配由 Core ML 决定。
- Core Image / Metal 图像缩放和居中 letterbox，原始图像宽高比保留。
- 严格检查模型接口，解码类别、框、mask coefficients 和 prototypes；按类别执行 NMS。
- Metal 重建每个实例的可见 Mask；着色和形状边线叠加在**同一张已分析帧**上。
- 镜像仅作用于最终显示；原型掩码的孔洞和非矩形形状不被矩形框替代。
- 简单的类别感知 IoU 追踪 ID，非人物身份识别，不声称遮挡恢复或跨摄像头重识别。
- 真实采集、推理、新显示帧 FPS；预处理、Core ML、CPU 后处理和 Metal 耗时。
- 回调到 GPU 完成的滚动 P95；它**不是**光子到屏幕的完整物理延迟。
- 模型导出时检查实际张量形状、记录 SHA-256/版本，并进行两个合成输入的 Core ML/PyTorch 输出对照。

## 为什么第一版使用 YOLO11n-seg，而不是立即绑定 YOLO26

这是明确冻结的 80 类分割基线，不宣称是最新或最佳模型。
YOLO11 的原始 `[1,4+classes+maskChannels,anchors]` 输出与当前解码器对应；
YOLO26/YOLOE 的端到端输出需要单独适配，不能把两个格式混着解码。
后续可以增加新模型适配器，但须先通过输出对照与独立场景精度测试。
上游模型及训练代码的许可证不因转换为 Core ML 而改变；下载前阅读
https://www.ultralytics.com/license 。仓库不附带下载后的权重或训练图片。

## 测试

```bash
swift test
python3 -m unittest discover -s scripts -p 'test_*.py' -v
```

16 项 Swift 核心测试覆盖几何还原、NMS、坏张量、帧队列、ID 关联与 FPS/P95；
6 项 Python 测试覆盖输出接口与误用模型的拒绝逻辑。
Linux 测试只证明可移植核心，不验证 Apple SDK、摄像头或 Metal 着色器。
GitHub `Native macOS validation` 工作流编译打包不带权重的预览 App；查看实际运行结果，
不能把工作流配置的存在视为 CI 已通过。

## 已知限制 / 下一步验收

1. **未提供 M5 实测 FPS、准确率或温度数据**，30 FPS 是目标，不是保证。
2. Mask 目前在 prototype 分辨率重建；细椅腿、头发、线缆等边缘可能粗糙。
   下一阶段增加高分辨率掩码恢复和边界质量评估，不能用平滑绘图掩盖模型误差。
3. 重叠区域优先显示分数最高的实例；最多 25 个实例，NMS 候选上限 1,000。
4. 本阶段没有自动拍摄、视频录制、训练数据收集或百万图片下载。
5. 摄像头转换、裁切、颜色及镜像需用真实测试卡对照；两个合成导出样本不能代替这些测试。
6. 长时运行、系统休眠/唤醒、设备拔插、热降频和错误恢复还需真机验证。
7. 没有精细化像素跟踪、开放词汇上千类识别、量化优化或发布公证。
8. 模型导出依赖按直接版本固定，并保留 `pip freeze`；尚不是经过 Mac 验收的完整依赖锁文件。

## 真机验收顺序

先验证无模型时只显示预览；再用真实模型对人、椅子、包和杯子测试。
检查轮廓对应当前已分析画面，切换镜像后不左右错位；移动物体检验掉帧而非延迟累积。
分别测试全部/CPU+GPU/CPU+ANE/CPU 四种配置，固定输入尺寸、光线与物体数量。
最后连续运行 30 分钟，记录 FPS、P95、内存和温度状态，再决定是否换模型或扩大训练集。

## 来源

- Core ML 转换及 CPU/GPU/ANE 调度：https://apple.github.io/coremltools/docs-guides/source/model-prediction.html
- Ultralytics Core ML 导出：https://docs.ultralytics.com/integrations/coreml/
- YOLO11 模型：https://docs.ultralytics.com/models/yolo11/
- AVFoundation 丢弃过期帧：https://developer.apple.com/documentation/avfoundation/avcapturevideodataoutput/alwaysdiscardslatevideoframes
