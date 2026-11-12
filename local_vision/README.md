# 本机摄像头：多物体与距离估计

在项目根目录运行 `bash local_vision/start.sh`，等待日志中出现 `Ready` 后打开 <http://127.0.0.1:8768/>，允许摄像头并开始分析。停止分析会释放摄像头；停止服务使用 `bash local_vision/stop.sh`。服务只监听 127.0.0.1；摄像头画面不经过外部服务器。可用 `PELAGIVEX_LOCAL_PORT=8769` 为启动和停止脚本指定相同的其他端口。

页面中点击已检测的目标，或先使用单帧比较冻结画面、再点击物体选点；输入该点的已知实际前向距离，即可为后续估计应用比例校准。点击“重置”恢复原始估计；刷新页面也会清除校准。选点使用当前分析帧附近区域的深度中位数，小物体边缘可能混入背景。校准只是简单比例修正，不能替代相机标定或修复所有角度、场景和不同距离上的误差。数值是单目模型对摄像头前向深度的估计，并非测距仪读数，也不保证等于斜向目标的直线距离。检测框中间区域的背景、遮挡、反光、玻璃和运动模糊都可能造成误差。该室内模型不适合未经验证的水下测距、避障或安全用途。

## 模型和运行

- 多类别：RF-DETR Medium COCO 预训练权重，检测 COCO 类别；并不覆盖所有物体。没有合并原有水下门框专用模型。默认 MPS，缺少支持的算子可回退 CPU。项目使用的 RF-DETR 版本和模型许可参见 [RF-DETR](https://github.com/roboflow/rf-detr)。
- 可选文字搜索：Google OWLv2 Base，输入英文名称（如 `tissue box` 或 `person, bottle`），仅搜索输入的类别；首次运行会加载模型，可能较慢，误检仍可能发生。权重保存在 `.cache/owlv2/`，为 [Apache-2.0](https://huggingface.co/google/owlv2-base-patch16-ensemble)。
- 深度：Depth Anything V2 Metric Indoor Base，室内数据训练的单目模型，模型权重为 **CC BY-NC 4.0（非商业使用）**。来源 [模型页](https://huggingface.co/depth-anything/Depth-Anything-V2-Metric-Indoor-Base-hf)，本地版本 revision `c6d9784685727bfc6d0a7b5452ce94afaee1e7f5`。不同场景或摄像头的精度尚未验证。
- 权重保存在 `model/rf-detr-medium.pth` 和 `model/local-depth/`，属于本地文件，不纳入 Git。Python 依赖使用项目 `.venv-model`；MPS 不可用时使用 CPU。启动脚本将缓存和临时文件限制在本项目内。
- 界面只有一个画面：实时视频上叠加最近完成的检测，移动时标记和距离可能滞后。页面请求 120 fps，并分别显示设备报告上限、当前设置、浏览器采样到帧率和识别速率；它们并不相同，设备上限低于 120 时无法达到 120。一次最多处理一帧，避免积压。显示的置信度是检测置信度，不是距离精度。
- 单帧比较在同一个窗口冻结一帧，用同一张图和同一个点比较 Base 与 Large 的原始未校准读数。Large 模型存于 `model/local-depth-large/`，来源 [Depth Anything V2 Metric Indoor Large](https://huggingface.co/depth-anything/Depth-Anything-V2-Metric-Indoor-Large-hf)，许可为 CC BY-NC 4.0。比较结果本身不证明其他物体或距离的精度。

本机依赖版本包括 `rfdetr==1.4.0`、`torch==2.8.0`、`transformers==4.54.1`、OpenCV、NumPy 和 Pillow。检测权重来自 [RF-DETR Medium COCO 官方权重](https://storage.googleapis.com/rfdetr/medium_coco/checkpoint_best_regular.pth)，SHA-256 为 `749ff6071828aaffac63e204c4f4135ed3d6cdae4d702e086c360edc3b5768c8`；深度 `model.safetensors` 的 SHA-256 为 `8b902f5d9a8c8a9520f3a8c6a00afe442b464eff5aaf0cb405d1da721cd9f79f`。部署时应同时保存深度模型目录中的配置文件。

## 实时性能与深度比较

OWLv2 在 Apple MPS 上使用 FP16；遇到不支持的操作或非有限模型输出时自动回退 FP32，CPU 使用 FP32。实时模式省略仅用于冻结比较的深度网格，减少数据传输；画面超过两秒未获得新检测时会隐藏过期的实时框。识别结果依旧可能滞后于视频，且帧率与摄像头的采集帧率分别显示。

单帧比较可选择 Depth Anything Large 或 Apple Depth Pro。Depth Pro 保存在 `model/local-depth-pro/`，基于图像估计焦距，模型条款为 [Apple AMLR](https://huggingface.co/apple/DepthPro-hf)；它运算耗时较长，目前只用于比较，不作为实时模型。比较读数均为未校准预测。通过实测点应用的比例校准只校准 Base 的显示结果，不保证其他距离、位置或环境准确；刷新页面将重置。

可选“混合精度（实验加速）”对 Base 深度使用 MPS autocast；遇到运行错误或非有限输出会回退 FP32。有限输出也可能有数值误差，所以需要在实际场景比较标准 FP32；切换深度精度会重置距离校准。对比帧的 Base 始终为未校准 FP32。

“实测距离记录”支持在同一冻结帧选点、输入实测前向距离并记录未校准结果、候选模型结果与适用的已校准结果及误差。仅记录数值在当前页面内，不保存摄像头画面；刷新清空。可以在同一相机、同一深度精度下使用“恢复校准系数”恢复先前记录的系数，但应在多个未参与校准的距离上验证。

OWLv2 对较大画面使用快速图像预处理；最长边小于 960 像素的画面使用原预处理方式。此优化不降低模型输入分辨率，但实时帧率和检测结果仍需以实际摄像头为准。

两点仿射校准仅应在同一摄像头、相同深度精度与明确的距离范围内使用。可根据记录预览拟合，并使用独立留出样本验证后，手动输入斜率与偏移；不自动应用。输入超出拟合范围时属于外推，不能保证准确，非正估计不显示。切换深度模式或重新加载页面会清除校准。

可选更大型模型：识别模式提供 OWLv2 Large，实时深度提供 Depth Anything V2 Metric Indoor Large；它们可与原模型切换，通常会增加延迟。更大模型不保证对每个物体或距离更准确；切换深度模型会重置校准，需要重新实测。Large 深度权重采用 CC BY-NC 4.0。OWLv2 Large 的权重采用 Apache-2.0，存放于 `.cache/owlv2-large/`。
