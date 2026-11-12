# PelagiVex — local general-purpose vision

PelagiVex is a local visual-recognition product for everyday objects and user-specified categories. Its current product is the native macOS application: it accepts the Mac camera or a phone through Camo, displays object labels and model confidence, and tracks short-term object identities. The product scope is general visual recognition; underwater imagery is one possible application, rather than the defining use case.

Two recognition modes serve different tasks:

- **Fast objects:** automatic **YOLOE-26s-seg-pf** recognition and instance segmentation through Core ML at 640×640, with a built-in **4,585-name vocabulary**, confidence, short-dropout tracking and A/B approximate depth comparison. The vocabulary includes scene names and descriptive concepts, not 4,585 distinct physical-object classes. **Live fine contours (SAM)** refines detected contours in the background with local SAM2.1 Tiny.
- **Text-guided objects:** independent local OWLv2 detection for user-specified names, followed by SAM2.1 Tiny object contours. This searches the entered vocabulary and returns prompt-dependent scores. It does not automatically name everything in a scene, and this mode does not provide A/B depth measurements.

Both modes process images on the Mac after their environment and model files are installed. See [General Vision: scope, models and verification](GENERAL_VISION.md) for the current capabilities and evaluation limits.

## Run the current macOS product

The current development build is in the checkout. On this Mac, the Desktop PelagiVex shortcut opens the same bundle.

```bash
native=pelagivex-native/apps/macos/PelagiVexNative
open "$native/dist/PelagiVex.app"
```

Choose **Camo Camera** to use a connected phone, or choose the Mac camera. In **Fast objects**, the confidence threshold controls new detections; established targets can continue from weaker observations and briefly missing tracks are marked separately. In **Text-guided objects**, enter the object names to find and apply the vocabulary. English prompts are the supported starting point; scores are model confidences, not calibrated probabilities.

Both modes can draw thin estimated object outlines. The outline-width control ranges from 1 to 4 pixels and defaults to 1.5. **Live fine contours (SAM)** is enabled by default in **Fast objects**, with independent detection and detail-refresh rates. Disable it for the YOLO-only view. SAM refinement changes the displayed contour, while the existing depth-measurement masks remain unchanged. A finer outline is not evidence of more accurate depth.

Stop the camera and use **Performance → Efficient preview** to try selective mixed-precision recognition on CPU/GPU. **Reference** remains the startup default. The efficient export preserves large class IDs, but individual scores and small-object masks can differ. The [performance research record](pelagivex-native/apps/macos/PelagiVexNative/MAX_PERFORMANCE_RESEARCH.md) keeps the earlier offline stress tests. The current live baseline is below.

The automatic model is a locally exported official checkpoint, not a newly trained model or a claim of universal SOTA. Its verified schema-2 bundle uses FP32 because an FP16 attempt changed high class indices through rounding. A saved real-frame conversion check retained all 11 reference labels; it does not establish recognition accuracy. Saved-input model-call timing and current camera throughput are separate measurements. The older YOLO11 study bundle is retained under the app's `Contents/Resources/LegacyStudyModel` for historical replay. See the [export and parity record](pelagivex-native/apps/macos/PelagiVexNative/Model-YOLOE26s-PF-640/README.md) and [model selection, fine-tuning and architecture roadmap](MODEL_ROADMAP.md).

Build and verify locally:

```bash
bash pelagivex-native/apps/macos/PelagiVexNative/scripts/build.sh
```

The build runs the Swift tests and creates the application in the native module's `dist/` directory. Model setup, local Python dependencies and model licence information are in the [native README](pelagivex-native/apps/macos/PelagiVexNative/README.md). General-purpose recognition does not imply reliable recognition of every category or scene, and the monocular depth estimates are not physical distance measurements.

## 下一步

当前优先级是**稳定实时链路，再提高遮挡后的身份恢复**。本机 v0.11.4 的 223 秒 Camo 实测开启 SAM 和自动旋转，采集维持约 30 FPS，分析画面显示中位数 29.94 FPS、P05 为 19.55 FPS，SAM 平均每秒完成 3.91 次。日志有 6 次恢复原跟踪编号和 10 次超时后切换编号，缺少物理身份标注。本机原始数据和复跑入口见 [Camo 实测](.cache/camo-interactive-study/run-2030/summary.md)。

1. **找出长时掉帧的来源。** 在同一段输入上交叉测试 SAM 开关与 3D 卡片显隐，固定识别模型、分辨率和回放节奏，分别记录识别、SAM、渲染、排队和丢帧。再用至少 5 分钟 Camo 实测复核。建议验收目标为至少 95% 的一秒窗口达到 29.5 FPS 的独立分析画面，同时核对识别更新率与结果延迟。根据剖析结果决定要继续迁到 C++ 或改到 Metal 的代码。
2. **用真实身份验收持续锁定。** 先做一套独立标注的短遮挡、同类交叉、移出与重入片段。对照现有 1.6 秒锁定和加入外观、运动证据的恢复策略，报告同物体接回率、接回延迟与误锁时长。对有标注的帧同时量轮廓边界精度，确认 SAM 优先级改动后的取舍。另用 Camo 完成卡片跨边、主动遮挡和换物体测试，核对 260 × 208 点尺寸及手动缩放。
3. **用独立几何证据验证研究假设。** 先用 Camo 与同帧标定板测量小幅相机横移，以 RGB-D 或实物测量提供独立前后真值。比较相同时间、移动距离和推理预算下的被动复测、固定往返与主动选取观测时机。按确认率、错误确认率和确认延迟判断是否值得发展为论文。目标自身运动、弱视差与掉检都作为实验条件，检验系统何时应保留判断。 [主动观测方案](PAIR_NEXT_RESEARCH.md)

## Product and research records

- [General vision scope and local evaluation](GENERAL_VISION.md).
- [Current model selection and future training](MODEL_ROADMAP.md).
- [Performance experiments, boundary failures and research hypothesis](pelagivex-native/apps/macos/PelagiVexNative/MAX_PERFORMANCE_RESEARCH.md).
- [Native product instructions](pelagivex-native/apps/macos/PelagiVexNative/README.md).
- [Tracking continuity and confidence verification](pelagivex-native/apps/macos/PelagiVexNative/TRACKING_UPDATE.md).
- [Budgeted pair-depth replay study](pelagivex-native/apps/macos/PelagiVexNative/PAIR_STUDY.md).
- [Research questions and literature](PAIR_RESEARCH.md), with the [active-observation research candidate](PAIR_NEXT_RESEARCH.md).

The repository also contains `local_vision/`, an earlier loopback-only browser workbench for COCO and text-guided detection plus depth experiments. The Java application, gate weights, original web interfaces and tunnel scripts below are retained as the historical underwater-gate prototype. Their detector remains specialised; they do not acquire the native application's general-recognition capabilities through a change of title.

## Legacy underwater-gate prototype

Pelagivex is a research prototype for detecting underwater competition gates in photographs and sampled video or camera frames. A Java web application uses an RF-DETR Nano model fine-tuned on underwater images. The application is independent of Project Trident and does not control a vehicle.

### Use

Choose a JPEG or PNG image, then select **Detect gate**. An optional example is a simulated image, clearly labelled in the interface. The browser accepts JPEG or PNG files up to 20 MiB and 40 million pixels, then locally scales larger images to at most 4 million pixels and 4,000 pixels per side before upload. The server accepts at most 8 MiB and processes one inference request at a time.

For continuous analysis, choose **Video** or **Camera**, select a video or grant camera permission, and start analysis. Keep the page open while analysing. The browser sends individual resized JPEG frames to the server; it does not upload the full video or audio. Only one request is in flight at a time: the next available frame is captured as soon as the previous request finishes, without building a queue. The analysed frame is shown separately from the live input. Actual throughput depends on the server and network; it is not guaranteed to match the source frame rate. Stopping, changing mode, or closing the page ends analysis and releases the camera.

### Components

- `web/`: bilingual static interface and the credited synthetic example.
- `src/main/java/`: Java 21, Servlet 4, and ONNX Runtime inference API for Tomcat 9.
- `scripts/`: dataset preparation, model training, evaluation, and export tools.
- `pelagivex-native/apps/macos/PelagiVexNative/`: independent SwiftUI macOS camera and instance-segmentation development preview. See its [README](pelagivex-native/apps/macos/PelagiVexNative/README.md) for setup and limitations.
- `model/gate-v2.onnx`: selected trained model artifact (not tracked in Git).
- `data/`, `runs/`, `.venv-model/` and `.cache/`: local research data, checkpoints, environment and caches; excluded from Git.

The legacy Java gate application is unavailable until `model/gate-v2.onnx` is supplied. The selected model is not currently distributed in this repository or through GitHub Releases. If you have a copy, its SHA-256 is `48b7e5f293a0fd1be254cf6565dad1c0e3453bfb45384b0ff8e619a7c5146381`; see the [model card](model/MODEL_CARD.md) for artifact and reproduction details. The server defaults to `/opt/pelagivex/model/gate.onnx`; for local runs configure `-Dpelagivex.model.path=/absolute/path/to/gate-v2.onnx`.

### Data and attribution

- Model architecture and initial weights: [RF-DETR](https://github.com/roboflow/rf-detr), Apache 2.0, Nano version.
- Training data: [SAUVC Dataset by mo_bilal14](https://www.kaggle.com/datasets/mobilal14/sauvc-dataset), whose listing states MIT. The original image ownership and licence chain have not been independently verified. The training images are not redistributed here.
- Example image: [jack-www/sauvc-v1](https://huggingface.co/datasets/jack-www/sauvc-v1), listed as MIT. The image is a simulated scene, converted from PNG to JPEG. It is not a real underwater photograph.

The training source's original video/scene grouping is unknown, and near-duplicate frames were found across its supplied splits. Performance on that test split cannot establish performance in new pools, waters, cameras, or RoboSub tasks. This prototype is for research and demonstration, not autonomous vehicle control.

### Build

Use Maven and a JDK capable of compiling Java 21. `mvn test` runs backend checks and `mvn package` produces `target/Pelagivex.war`. Tomcat 9 provides Servlet 4. Use the model artifact above; a missing or incompatible model makes `/api/health` and detection unavailable rather than generating simulated detections.

The current native product runs independently of this Java gate service. Use the current build and model instructions at the top of this README; its general-purpose backends are separate from RF-DETR Gate.

### Server deployment

The public Nginx site serves the interface from `/opt/pelagivex/site-v2` and proxies `/api/` to the existing Tomcat application. The model remains at `/opt/pelagivex/model/gate.onnx`. When publishing interface changes, update the Nginx-served static files as well as the source; updating only the WAR does not update the public interface. Validate Nginx configuration before reloading it.

### Private Mac mobile demo

`scripts/start_wss_demo.sh` runs the existing FP32 gate model on the Mac (CoreML with CPU execution for unsupported operations), a token-protected local WebSocket site, and an SSH reverse tunnel when a compatible HTTPS `/mac-ws/` route has been configured. The model and inference remain on the Mac; image frames travel through the HTTPS server and encrypted SSH tunnel. The single-window camera page requests permission and starts automatically where the browser allows it; otherwise the user can tap the camera button. It displays the actual analysed frame and its matching detections. The browser keeps at most three frames in flight, the local backend allows up to four simultaneous inferences, and the stream service retains at most one newer waiting frame. The `?slots=2` parameter selects the lower-bandwidth option. `?capture=120` requests a 120 fps camera setting where the browser supports it and shows the browser-reported limit, actual selected setting and measured detection rate separately; it does not guarantee 120 fps.

Run `bash scripts/start_wss_demo.sh` in a Mac Terminal. Enter the server password only in the SSH prompt; the script does not save it. A fresh secret URL is printed after HTTPS and WSS handshake checks; anyone with that URL can access the demo. Keep the Terminal running and the Mac awake; Ctrl-C stops only that run's backend, WSS server and tunnel and deletes its temporary token. Existing local or remote port use causes a safe failure instead of replacing another service. The previous public tunnel and its server route are currently removed; this script cannot publish an endpoint until an appropriate route is deliberately configured again. The setup also depends on a known SSH host key.

The project virtual environment must contain `websockets==15.0.1` and `certifi` (see `scripts/requirements-wss.txt`); the existing Java runtime, compiled project and model are also required. CoreML and CPU outputs can differ slightly; test results on a limited image set do not establish identical predictions in every scene.
