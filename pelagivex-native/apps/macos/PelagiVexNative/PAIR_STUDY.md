# PelagiVex：两物体前后顺序，开发与额外实拍验证

**结论：** 把撤下旧答案与下一次推理解耦后，等调用数下有正例，也有反例。TUM 开发录像里的一次 10 Hz 翻转在 0.49 秒后显示了新顺序，五秒基线和首轮自适应均未纠正。另两套 Bonn 实拍验证中，椅子有一次确认更快，人群片段却丢失了原有目标 ID，自适应在跟踪结束前没有纠正。数据支持进一步研究，但不支持“自适应通常更快或同时提高覆盖率”的结论。

## 产品与策略

- `dist/PelagiVex.app` 中，选择相机并启动，从检测结果中指定 A、B。比较面板显示 A/B 更近、太接近、复测中、等待新帧或哪个目标丢失。换模式或改选会丢弃旧配对证据。新 ID 需要重新选择。
- 两种模式均使用 YOLO11x-seg 768、同一 IoU 跟踪器和 Depth Anything V2 Metric Indoor Base。模型只看 RGB。深度顺序用掩膜内估计值的中位数，差异阈值为 5 cm 或较近深度的 5%，取较大者。
- **五秒基线**在 worker 可用且两 ID 都在时约每 2 秒提交一次，证据从源帧算起最多显示 5 秒。**自适应**用相对框尺度、单目标的大尺度变化、两框重叠变化标记旧证据可能失效；不会仅因同尺度的横向平移而撤下答案。这些量只决定何时复测，不能直接生成新方向。撤下后通常至少等 0.55 秒并要求几何再变化一次；如果未出现新的变化，1.25 秒后允许复测。这个上限是**允许发起**的时间；无预算、目标丢失或 worker 忙仍会延后。
- 自适应每 2 秒回补一次调用的额度，最多保存两次。平稳画面满 2.75 秒后可以提前刷新，但要有至少 1.4 次额度；证据到 3 秒仍会过期。首轮规则和取消复测等待的消融只在回放 CLI 中比较。Bonn 片段及独立标注和策略均在查看该批比较结果前冻结；策略 SHA-256 为 `802630b9040d50937c6ae3ae843ac9628975a9f1b4f84ac60b59e45bc7abc0ee`。

## 如何读结果

同一片段的四种策略读取同一份帧序列、检测、跟踪和缓存的单目预测。仿真只在一次调用提交后，按该帧在本机实测的 worker 时长延迟交付预测。一次只有一个 worker，忙时不排队；参考深度从不进入调度。报告中的调用数是**回放中实际提交的次数**，并非为每种策略再运行一次模型。准备 trace 时已经在 MacBook Pro（M5 Pro、24 GB，macOS 26.5.1）逐帧实跑，保存热启动后的 Python worker 时间：含解码、推理和掩膜测距，不含模型加载、Swift JPEG 编码、进程间传输、相机和显示延迟。时间累加包含提交后未及完成的尾帧调用。

方向覆盖率的分母是原选定两 ID 共可见、且两者参考有效的时间。错误方向时长包含方向相反以及参考判为太近时仍给出方向；逐片报告把两项分开。参考方向连续两帧翻转才算事件，取第一帧为起点。首次显示正确方向的延迟按采样帧计算；“太接近”“复测中”均不算纠正。若该方向仍成立的评分窗口结束、参考中断或原 ID 跟踪结束前没显示正确方向，记未纠正。新 ID 不拼接。延迟 0 表示画面在事件时已经与新参考一致，可能是旧答案碰巧转为正确；它不证明系统重新确认了翻转。

## TUM 开发回放

方向指标使用共享掩膜的配准传感器参考；标出的两次交叉另用独立 RGB 躯干落点核对，见文末首轮记录和数据重建命令。两个采样率来自同一录像，不能当作两次独立验证。

| 开发片段（目标事件） | 调用 基线／自适应 | Worker 秒 | 错误方向秒 | 方向覆盖率 | 目标事件纠正延迟 |
| --- | ---: | ---: | ---: | ---: | --- |
| [10 Hz，6.21 s](pair-study-results/tum-10hz-crossing1.md) | 4／4 | 0.65／0.65 | 0.30／0.00 | 28.0%／7.1% | 未纠正／0.49 s |
| [10 Hz，13.91 s](pair-study-results/tum-10hz-crossing2.md) | 1／1 | 0.16／0.16 | 1.20／0.00 | 87.9%／0.0% | 未纠正／未纠正 |
| [5 Hz，6.21 s](pair-study-results/tum-5hz-crossing1.md) | 4／4 | 0.62／0.62 | 0.40／0.20 | 27.9%／11.2% | 未纠正／未纠正 |
| [5 Hz，14.01 s](pair-study-results/tum-5hz-crossing2.md) | 2／2 | 0.31／0.31 | 1.20／0.00 | 92.6%／0.0% | 未纠正／未纠正 |

10 Hz 第一次交叉，首轮的最后一次调用在 6.00 s，冻结版改到 6.50 s，回放在 6.70 s 显示新方向；不等待的消融没有纠正。该对还有一次自动参考翻转，自适应反而从 1.58 s 变成 2.58 s。5 Hz 的第一次交叉虽在 6.80 s 得到新方向，但交付时几何已再次变化，没显示出来。开发中观察到短等待变体曾纠正 5 Hz 第二次交叉；最终冻结策略没有重现。10 Hz 第二处只有一次等额调用，且两 ID 不足两秒共存；一次调用通常无法既确认初始顺序又确认翻转。

## Bonn 额外实拍：独立标注为主

独立 RGB 落点和注册深度数据的标注方法、同步误差、下载命令和原始档案校验和见仓库根目录 [PAIR_VALIDATION_DATA.md](../../../../PAIR_VALIDATION_DATA.md)。椅子前、后段来自同一段录影，后段是无翻转对照；Crowd3 来自另一套数据。下表先保留完整周期基线，以其调用数为共同上限。所有数字按**基线／自适应**排列。

| 片段 | 调用 | Worker 秒 | 错误方向秒 | 方向覆盖率 | 各次纠正延迟 | 未纠正 |
| --- | ---: | ---: | ---: | ---: | --- | ---: |
| [Chairs 前段](pair-study-results/bonn-chairs-near-independent.md) | 9／8 | 1.34／1.18 | 3.78／2.92 | 37.3%／34.6% | 7.71 s：均未纠正；15.68 s：0.80／0.60 s | 1／1 |
| [Chairs 后段](pair-study-results/bonn-chairs-far-independent.md) | 7／6 | 1.01／0.86 | 0.00／0.00 | 84.4%／90.0% | 无翻转 | 0／0 |
| [Crowd3](pair-study-results/bonn-crowd3-independent.md) | 2／2 | 0.29／0.29 | 1.61／1.01 | 76.0%／60.0% | 6.20 s：0.00 s（旧答案）／未纠正 | 0／1 |

事后以自适应已用次数为共同硬上限的敏感性分析：Chairs 前段 [8／8 次](pair-study-results/bonn-chairs-near-matched.md)、1.19／1.18 worker 秒、两处事件未纠正数 **2／1**，其余主指标不变。Chairs 后段 [6／6 次](pair-study-results/bonn-chairs-far-matched.md)、0.86／0.86 worker 秒，方向覆盖率仍为 84.4%／90.0%。这不是预注册的预算选择。完整上限下，取消等待的消融也在 0.60 s 纠正椅子的第二处翻转；这 0.20 s 领先无法单独归因于等待。Crowd3 基线在翻转发生时仍展示 4.19 s 的旧 B 答案，6.20 s 采到的独立新调用则判为太接近；两者都没有用翻转后的帧给出正确的新确认。自适应先丢弃一个跟踪变化中的结果，又在 4.89 s 花掉最后一次调用。7.004 s 棕衣人消失，7.306 s 以 #45 重现，不能替 #27 记为纠正。

两种参考下的趋势并不完全相同。[Chairs 前段共享掩膜](pair-study-results/bonn-chairs-near-shared.md)把第一处确认翻转从 7.71 s 提前到 5.00 s，并将基线／自适应的错误方向时长从 3.78／2.92 s 变为 2.68／1.82 s。[Chairs 后段](pair-study-results/bonn-chairs-far-shared.md)的独立标注没有错误，共享掩膜把部分 B 帧判为太近，得到 0.30／0.70 s 错误。[Crowd3](pair-study-results/bonn-crowd3-shared.md)两种参考仍得到相同的纠正判定。共享掩膜会让模型和真值共同受到可见部位、背景污染和遮挡的影响，不能当作独立验证。

## 摄像头实测（2026-11-07）

已运行最终打包的 0.2 预览版。MacBook Pro 内置摄像头 1920×1080、采集约 30 FPS，现场观察检测与显示约 25–26 FPS，并取得一个目标的本机深度。随后按用户指示使用手机经 Camo Camera：1920×1080、采集约 30 FPS，在双目标比较中观察到约 19–21 FPS 的检测与显示。用户选定行李箱 A、椅子 B；自适应模式显示 **A is closer** 且多次复测，切到五秒基线后仍保留 A/B 并从新请求得到 **A is closer**，最后切回自适应。该实测验证采集、识别、选择、深度输出和模式切换；未在现场采集物理真值或计时翻转，也未将摄像头画面保存作数据集。

## 复跑本版

从本文件所在目录运行：

```bash
bash scripts/build.sh
bash scripts/replay_pair_study.sh
diff -ru pair-study-results "$(git rev-parse --show-toplevel)/.cache/pair-study/confirmation-results"
```

程序使用 `.cache/pair-study/` 里的原始 trace；精确的回放输入也打包保存在同处的 `confirmation-replay-inputs.tar.gz`。无需重新运行模型即可重现表格。重采 trace 时按数据说明先重建 RGB-D 输入，再运行 `--pair-trace`；重复计时和同一采样率下的跟踪可能因硬件及软件版本不同而改变。原始结果中的每次提交时间、实际计数、worker 秒、方向覆盖率、错误时长、延迟和未纠正数都留在 `pair-study-results/`。论文选题、反证条件和目标期刊见 [PAIR_RESEARCH.md](../../../../PAIR_RESEARCH.md)。

---

## First pilot (preserved)

This pilot uses one 25-second real recording, `freiburg3_walking_static`. Two people cross twice. The local app runs YOLO11x-seg 768 and Depth Anything V2 Metric Indoor Base on the RGB frames. The benchmark reads registered depth from the recording's separate sensor only for scoring. It summarizes that depth inside the same segmentation masks, so the scores depend on which parts the detector sees and on track continuity. Manual checks on the RGB frames identified each person by clothing and checked the swap windows against sensor depth at visible torso points.

The first trace contains 122 RGB-D pairs at approximately 5 Hz, with up to 1.462 ms synchronization skew. The sensitivity trace contains 243 pairs at approximately 10 Hz, with up to 5.422 ms skew. Both traces come from the same recording. [TUM RGB-D Benchmark and license](https://cvg.cit.tum.de/data/datasets/rgbd-dataset) · [Depth format](https://cvg.cit.tum.de/data/datasets/rgbd-dataset/file_formats) · [MCAP conversion](https://huggingface.co/datasets/Voxel51/TUM-RGBD)

## Protocol

- Each run selects the two track IDs present at one of the manually checked crossings. The second crossing is a separate selection because the original tracks ended. The late co-visible pair is also included in the local replay reports.
- Both policies start from the same frames and model outputs. The baseline attempts one request every two seconds and can display evidence for five seconds. The adaptive policy has one token per two seconds on average, with capacity for two saved calls. Each adaptive replay is capped at the baseline's observed request count for that pair. Each mode uses a single worker and can use only results from frames it requested.
- The recorder measures warm depth-worker time for each frame on this Mac. The simulator makes each requested result available at the first sampled frame at or after its modeled finish time. The totals below exclude Swift JPEG preparation, interprocess transfer, display latency and any concurrent live workload. The same segmentation cost is shared.
- Direction coverage is the share of scored time with a displayed A-or-B answer. Wrong-direction time includes answers when the sensor depths are too close to distinguish by the preset tolerance. The tables mark an exchange as unresolved when the display never matches the new reference direction before that scoring interval ends.

## Results for the two verified crossings

| Sample rate and crossing | Calls in each mode | Baseline / adaptive worker time | Baseline / adaptive direction coverage | Baseline / adaptive wrong-direction time | Exchange resolved |
| --- | ---: | ---: | ---: | ---: | --- |
| 5 Hz, A #1 / B #2, 6.21 s | 4 | 0.62 / 0.62 s | 27.9% / 5.7% | 0.40 / 0.00 s | Neither |
| 5 Hz, A #81 / B #106, 14.01 s | 2 | 0.31 / 0.30 s | 92.6% / 0.0% | 1.20 / 0.00 s | Neither |
| 10 Hz, A #1 / B #2, 6.21 s | 4 | 0.65 / 0.65 s | 28.0% / 2.8% | 0.30 / 0.00 s | Neither |
| 10 Hz, A #67 / B #92, 13.91 s | 1 | 0.16 / 0.16 s | 87.9% / 0.0% | 1.20 / 0.00 s | Neither |

The duration metrics cover each selected pair's scored visible interval. Crossing time is the first sampled frame of the sustained new sensor order at that sample rate. The full replay reports also list automatic reference reversals elsewhere in each interval. The only shared resolved reversal for the first track pair took 1.58 s for both policies, at both sample rates. In the pilot, adaptive mode spent less time showing a wrong direction and gave a direction much less often. The tested rule did not speed up either manually verified exchange.

At the first crossing, both adaptive replays spent their last call at 6.00 s, before the new reference order at 6.21 s. At the second crossing, the 5 Hz adaptive replay called at 13.81 s, when the monocular estimates were too close to give a direction. At 10 Hz one track ended before the baseline could make a second call, so the equal-call comparison allowed one call in each mode. These timings separate early stale-result suppression from obtaining usable evidence after the order changes.

## Repeat locally

Run from the directory containing this file. The study inputs, raw traces, per-pair Markdown reports, and the manual verification points are under the checkout's ignored `.cache/pair-study` directory on this Mac. The two extract scripts there record how the paired frames were sampled from the MCAP. The input manifest contains a source description, a depth-units-per-metre scale, and frames with monotonically increasing seconds and RGB/depth paths relative to the manifest.

```bash
study="$(git rev-parse --show-toplevel)/.cache/pair-study"
app=dist/PelagiVex.app/Contents/MacOS/PelagiVexNative
"$app" --pair-trace "$study/walking-static-5fps/manifest.json" "$study/trace.json"
"$app" --pair-replay "$study/trace.json" 1 2
"$app" --pair-replay "$study/trace.json" 81 106
"$app" --pair-trace "$study/walking-static-10fps/manifest.json" "$study/trace-10fps.json"
"$app" --pair-replay "$study/trace-10fps.json" 1 2
"$app" --pair-replay "$study/trace-10fps.json" 67 92
```
