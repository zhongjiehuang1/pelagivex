# PelagiVex 额外实拍回放数据

开发素材为 TUM RGB-D `freiburg3_walking_static`。额外验证使用波恩大学两套实拍数据，片段边界、目标身份和 RGB 标注在查看策略结果前确定。同一椅子录像中的两段使用同一场景与同一对椅子，其中第二段提供无翻转对照。拥挤场景提供不同摄像头和人物遮挡条件。样本量只适合做有明确失败条件的可行性验证。

| 片段 | 选取的原录像时间（s） | RGB-D 对 / 最大时间差 | A / B | 独立传感器参考 |
| --- | ---: | ---: | --- | --- |
| Chairs 前段 | 0.0–16.5 | 166 / 0.000 ms | 左椅 #2 / 右椅 #1 | 166 帧有效。7.712 s 首次连续两帧为 A 更近，15.685 s 首次连续两帧翻回 B 更近。 |
| Chairs 后段 | 20.2–34.3 | 142 / 0.000 ms | 左椅 #1 / 右椅 #2 | 142 帧有效。B 始终更近，验证策略会不会在无翻转时产生错误答案。 |
| Crowd3 | 0.0–11.5 | 112 / 16.550 ms | 棕衣蓝领 #27 / 浅灰衣 #1 | 33 帧有两人有效参考，其中 25 帧同时保留指定 ID。5.496–5.898 s 为 A 更近，5.999–6.099 s 落入近距阈值，6.199–6.904 s 为 B 更近。 |

Chairs 是 640×480、30 Hz 的 Asus Xtion Pro Live 实拍，作者发布的 RGB 与深度索引对这里选到的帧完全同步。Crowd3 下载包使用 TUM RGB-D 格式，作者说明深度图已配准至 RGB。两套数据均按该格式以 5,000 像素值为一米，零代表无数据。所有时间以对应原录像第一张 RGB 为零点。提取程序在 10 Hz 网格取最近的 RGB 图，再配对最近的传感器图，拒绝时间差超过 20 ms 的帧。模型以原始 PNG 为输入。[Chairs 数据与采集说明](https://www.ais.uni-bonn.de/download/rigidmultibody/) · [Stückler 与 Behnke，BMVC 2013，§5](https://ais.uni-bonn.de/papers/BMVC2013_Stueckler.pdf#page=7) · [Crowd3 数据与配准说明](https://www.ipb.uni-bonn.de/data/rgbd-dynamic-dataset/) · [Palazzolo 等，IROS 2019，§V-B](https://arxiv.org/pdf/1905.02082#page=6) · [TUM 格式](https://cvg.cit.tum.de/data/datasets/rgbd-dataset/file_formats)

独立参考标注使用 RGB 画面上的椅面和躯干内部点。椅子标注锚点约每 0.5 秒一帧，人物约每 0.3 秒一帧，在不超过 19 个原始帧的锚点之间插值。每个点取其在配准深度图中 11×11 像素邻域的有效值中位数。有效像素少于 80% 或四分位距超过 0.12 m 时弃用该点。锚点和同步深度来自原始帧，模型分割掩膜只用于模型自己的测距和共享掩膜对照。叠加图可核对标注落点，侧车 JSON 记录原始文件、深度、有效像素比例和四分位距。椅子原始档案另含运动捕捉数据，本次参考以传感器测得的可见座面深度为准。

两人标注仍可在目标重现后识别同一人。Crowd3 中棕衣人约在 7.004 s 被灰衣人遮挡，#27 消失，7.306 s 起重现为 #45。原选择会按 #27 的跟踪终止处理，重现后的 #45 不续接、也不计作纠正。Chairs 的两对指定 ID 在各自片段的全部帧中可见。Crowd3 的 5.093 s 有一帧孤立的 B 更近，未达到连续两帧的翻转条件。

参考定义会改变绝对评分。在 Chairs 前段 166 帧中，独立座面与共享掩膜给出相同三分类的有 112 帧，其余 54 帧均在一方给出方向、另一方判为太近的边界上。第一处确认翻转 7.712 s，座面差 7.5 cm，掩膜差 4.1 cm。同一录像的 Chairs 后段有 135/142 帧同判 B 更近，另 7 帧掩膜判为太近。Crowd3 可同时核验原 ID 和躯干深度的 25 帧中，两种参考 19 帧一致，6 帧在近距阈值两侧。整对象掩膜和局部物理表面的深度可能不同，因此分别保存两种参考，比较结果时以独立参考为主。

## 重跑

在仓库根目录执行。原始档案和生成文件都保存在 Git 忽略的 `.cache/pair-study/`，手工标注与提取代码保存在仓库。用仓库的 `.venv-model/bin/python`，或已安装 NumPy 和 Pillow 的 Python 3.11+。

```bash
study=.cache/pair-study
mkdir -p "$study"
curl -fL --retry 2 'https://www.ais.uni-bonn.de/download/rigidmultibody/rgbd_moseg_bonn_chairs.zip' \
  -o "$study/bonn-chairs.zip"
curl -fL --retry 2 'https://www.ipb.uni-bonn.de/html/projects/rgbd_dynamic2019/rgbd_bonn_crowd3.zip' \
  -o "$study/bonn-crowd3.zip"
shasum -a 256 "$study/bonn-chairs.zip" "$study/bonn-crowd3.zip"

python=.venv-model/bin/python
app=pelagivex-native/apps/macos/PelagiVexNative/dist/PelagiVex.app/Contents/MacOS/PelagiVexNative
for dataset in chairs-near chairs-far crowd3; do
  archive=bonn-chairs
  if [ "$dataset" = crowd3 ]; then archive=bonn-crowd3; fi
  clip="$study/bonn-$dataset"
  "$python" scripts/pair_validation_data.py prepare "$dataset" "$study/$archive.zip" "$clip"
  "$app" --pair-trace "$clip/manifest.json" "$clip/trace.json"
  "$python" scripts/pair_validation_data.py reference \
    "$clip/manifest.json" "scripts/pair-validation/$dataset.json" "$clip/independent.json"
  "$python" scripts/pair_validation_data.py contact "$clip/manifest.json" --trace "$clip/trace.json"
done
```

下载档案 SHA-256：

- `bonn-chairs.zip` `146411a2e933bf2c37e6bc4a79c5a29b99aa1cae4307f5b75d2b3e1801ffa861`
- `bonn-crowd3.zip` `1e630f12389c0552ad3edb3cfdb64b9872ad1a24641016ef70ab7e0008d79c23`

回放使用每个片段的同一份 `trace.json` 与同一对 ID。该 trace 保留每帧实际在 Mac 上测到的推理耗时。使用 `independent.json` 可按独立标注评分，省略它可重跑共享掩膜参考。

原有 TUM 开发片段也可从同一份转换档重建。用版本固定的下载链接和以下命令保留原来的文件编号、RGB 帧、深度图和 5 Hz 人工躯干核验。 [TUM RGB-D 数据](https://cvg.cit.tum.de/data/datasets/rgbd-dataset) · [Voxel51 MCAP 转换](https://huggingface.co/datasets/Voxel51/TUM-RGBD)

```bash
study=.cache/pair-study
python=.venv-model/bin/python
mkdir -p "$study"
curl -fL --retry 2 \
  'https://huggingface.co/datasets/Voxel51/TUM-RGBD/resolve/f21e73c5bf0d91fc66f3c5759c9d438e52ab24a6/data/freiburg3/fr3_walking_static.fo.mcap' \
  -o "$study/fr3_walking_static.fo.mcap"
shasum -a 256 "$study/fr3_walking_static.fo.mcap"
"$python" -m pip install --target "$study/deps" 'mcap==1.6.0' 'imageio-ffmpeg==0.7.0'
for fps in 5 10; do
  PYTHONPATH="$study/deps" "$python" scripts/pair_extract_tum.py \
    "$study/fr3_walking_static.fo.mcap" "$study/walking-static-${fps}fps" --fps "$fps"
done
"$python" scripts/pair_verify_tum_torso.py "$study/walking-static-5fps"
```

MCAP SHA-256 为 `976341118d533d0c6ee25a71c2b75a5976f9f49898659b3e5db5f6e604d90e65`。5 Hz 与 10 Hz 分别应生成 122 与 243 对配准帧。重新录制模型 trace 后，参考原生应用目录的 `PAIR_STUDY.md` 执行指定 ID 的回放。
