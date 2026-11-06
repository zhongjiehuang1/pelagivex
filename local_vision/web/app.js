"use strict";
(() => {
  const $ = id => document.getElementById(id);
  const video = $("camera"), canvas = $("result"), stage = canvas.closest(".result-stage");
  // COCO names stay unchanged in backend data; translation is display-only.
  const cocoLabels = new Map(Object.entries({
    "person":"人", "bicycle":"自行车", "car":"汽车", "motorcycle":"摩托车", "airplane":"飞机", "bus":"公共汽车", "train":"火车", "truck":"卡车", "boat":"船", "traffic light":"交通信号灯", "fire hydrant":"消防栓", "stop sign":"停车标志", "parking meter":"停车计费器", "bench":"长椅", "bird":"鸟", "cat":"猫", "dog":"狗", "horse":"马", "sheep":"羊", "cow":"牛", "elephant":"大象", "bear":"熊", "zebra":"斑马", "giraffe":"长颈鹿", "backpack":"背包", "umbrella":"雨伞", "handbag":"手提包", "tie":"领带", "suitcase":"行李箱", "frisbee":"飞盘", "skis":"滑雪板", "snowboard":"单板滑雪板", "sports ball":"球", "kite":"风筝", "baseball bat":"棒球棒", "baseball glove":"棒球手套", "skateboard":"滑板", "surfboard":"冲浪板", "tennis racket":"网球拍", "bottle":"瓶子", "wine glass":"酒杯", "cup":"杯子", "fork":"叉子", "knife":"刀", "spoon":"勺子", "bowl":"碗", "banana":"香蕉", "apple":"苹果", "sandwich":"三明治", "orange":"橙子", "broccoli":"西兰花", "carrot":"胡萝卜", "hot dog":"热狗", "pizza":"披萨", "donut":"甜甜圈", "cake":"蛋糕", "chair":"椅子", "couch":"沙发", "potted plant":"盆栽", "bed":"床", "dining table":"餐桌", "toilet":"马桶", "tv":"电视", "laptop":"笔记本电脑", "mouse":"鼠标", "remote":"遥控器", "keyboard":"键盘", "cell phone":"手机", "microwave":"微波炉", "oven":"烤箱", "toaster":"烤面包机", "sink":"水槽", "refrigerator":"冰箱", "book":"书", "clock":"时钟", "vase":"花瓶", "scissors":"剪刀", "teddy bear":"泰迪熊", "hair drier":"吹风机", "toothbrush":"牙刷",
    "motorbike":"摩托车", "aeroplane":"飞机", "sofa":"沙发", "pottedplant":"盆栽", "diningtable":"餐桌", "tvmonitor":"电视", "mobile phone":"手机", "hair dryer":"吹风机"
  }));
  const isOwl = mode => mode === "owl" || mode === "owl_large";
  const depthModeName = mode => mode === "large" ? "Depth Anything Large" : mode === "mixed" ? "混合精度" : "标准 FP32";
  function displayLabel(value) {
    const original = typeof value === "string" && value.trim() ? value : "物体";
    return isOwl(detectorMode) ? original : (cocoLabels.get(original.trim().toLowerCase()) || original);
  }
  let stream = null, running = false, starting = false, generation = 0;
  let videoFrameHandle = null, videoFrameTimes = [], videoFrameLastReport = 0;
  let captureCanvas = null, captureContext = null, resultExpiryTimer = null, resultRevision = 0;
  // A live overlay older than this can be dangerously misleading on moving scenes.
  const MAX_OVERLAY_AGE_MS = 2000;
  let controller = null, timer = null, frameCount = 0, previousAt = null, intervals = [];
  let scale = 1, offset = 0, selected = null, lastDetections = [], lastScale = 1;
  // The grid is replaced atomically with the canvas so clicks use the exact displayed frame.
  let displayedDepth = null;
  let compareRequested = false, compareFrozen = false;
  // Numeric measurements exist only in this page; camera images are never saved.
  let measurementPoint = null, measurements = [], fitSelection = null;
  // A configuration version ensures a completed request from the previous
  // mode/search does not replace the newly selected configuration's output.
  let detectorMode = "owl_large", detectorPrompts = "tissue box", detectorVersion = 0;

  function showDetectorStatus(message, error = false) {
    $("detector-status").textContent = message;
    $("detector-status").classList.toggle("error", error);
  }
  function clearDetectorResult() {
    clearResultExpiry();
    detectorVersion++; previousAt = null; intervals = []; displayedDepth = null;
    selected = null; $("selected").textContent = "尚未选择目标";
    $("fps").textContent = "—"; $("latency").textContent = "—"; $("count").textContent = "—"; $("frame-count").textContent = "—";
    $("detections").replaceChildren();
    const message = document.createElement("p"); message.className = "empty";
    message.textContent = "等待新模式的识别结果"; $("detections").append(message);
    canvas.hidden = true; $("result-placeholder").hidden = false;
    $("frame-label").textContent = "等待新画面";
    if (running) setStatus("正在切换识别模式，请等待当前帧完成…");
  }
  function validPrompts() {
    const input = $("owl-prompts").value.trim();
    const parts = input.split(",").map(part => part.trim()).filter(Boolean);
    const normalized = parts.join(", ");
    if (!input || input.length > 300 || normalized.length > 300 || parts.length < 1 || parts.length > 8 || parts.some(part => part.length > 128)) {
      showDetectorStatus("请输入 1 至 8 个英文名称，每项不超过 128 字符，总长度不超过 300 字符。", true);
      return null;
    }
    return normalized;
  }
  $("detector-mode").addEventListener("change", () => {
    const next = $("detector-mode").value;
    $("owl-options").hidden = !isOwl(next);
    detectorMode = next;
    if (isOwl(next)) {
      const prompts = validPrompts();
      if (prompts) detectorPrompts = prompts;
      else { $("owl-prompts").value = detectorPrompts; }
      showDetectorStatus(`${next === "owl_large" ? "OWLv2 Large（较慢）" : "OWLv2 Base"}：${detectorPrompts}；模型首次加载可能需要较长时间。`);
    } else showDetectorStatus("常见物体模式");
    clearDetectorResult();
  });
  $("apply-prompts").addEventListener("click", () => {
    const prompts = validPrompts();
    if (!prompts) return;
    detectorPrompts = prompts; $("owl-prompts").value = prompts;
    showDetectorStatus(`文字搜索：${prompts}`);
    if (isOwl(detectorMode)) clearDetectorResult();
  });
  $("owl-prompts").addEventListener("keydown", event => {
    if (event.key === "Enter") { event.preventDefault(); $("apply-prompts").click(); }
  });

  function setStatus(message, error = false) {
    $("status-text").textContent = message;
    $("status").classList.toggle("error", error);
  }
  const candidateLabels = {large:"Large", pro:"Depth Pro", mixed:"Base 混合精度"};
  const comparisonLabel = () => candidateLabels[$("compare-model").value] || "Large";
  function updateButtons() {
    $("start").disabled = running || starting;
    $("stop").disabled = !running && !starting;
    $("compare-depth").disabled = !running || (compareRequested && !compareFrozen);
    $("compare-depth").textContent = compareFrozen ? "继续实时识别" : (compareRequested ? "正在等待比较结果…" : `比较 Base 与 ${comparisonLabel()} 深度（单帧）`);
    $("compare-model").disabled = compareRequested || compareFrozen;
    $("depth-mode").disabled = compareRequested || compareFrozen;
    $("detector-mode").disabled = compareRequested || compareFrozen;
    $("owl-prompts").disabled = compareRequested || compareFrozen;
    $("apply-prompts").disabled = compareRequested || compareFrozen;
    $("calibrate").disabled = compareRequested || compareFrozen;
    $("reset-scale").disabled = compareRequested || compareFrozen;
    $("restore-scale").disabled = compareRequested || compareFrozen;
    $("apply-affine").disabled = compareRequested || compareFrozen;
    $("measurement-save").disabled = !compareFrozen || !measurementPoint;
    $("measurement-clear").disabled = measurements.length === 0;
  }
  function clearResultExpiry() {
    resultRevision++;
    if (resultExpiryTimer !== null) { clearTimeout(resultExpiryTimer); resultExpiryTimer = null; }
  }
  function scheduleResultExpiry(capturedAt, token) {
    clearResultExpiry();
    const revision = resultRevision;
    const remaining = Math.max(0, MAX_OVERLAY_AGE_MS - (performance.now() - capturedAt));
    resultExpiryTimer = setTimeout(() => {
      resultExpiryTimer = null;
      if (!running || compareFrozen || token !== generation || revision !== resultRevision) return;
      canvas.hidden = true;
      displayedDepth = null;
      $("count").textContent = "—";
      $("frame-label").textContent = "上一识别结果已过期";
      const message = document.createElement("p"); message.className = "empty";
      message.textContent = "结果超过 2 秒，已隐藏过期标记；正在等待新画面";
      $("detections").replaceChildren(message);
    }, remaining);
  }
  function abortRequest() {
    if (timer !== null) { clearTimeout(timer); timer = null; }
    if (controller) { controller.abort(); controller = null; }
  }
  function stop(message = "摄像头已关闭。") {
    generation++;
    running = false;
    starting = false;
    compareRequested = false; compareFrozen = false; measurementPoint = null; stage.classList.remove("is-frozen");
    clearResultExpiry();
    canvas.hidden = true; displayedDepth = null; $("result-placeholder").hidden = true;
    $("compare-result").textContent = "";
    abortRequest();
    if (stream) { stream.getTracks().forEach(track => track.stop()); stream = null; }
    video.pause(); video.srcObject = null; video.classList.remove("active");
    $("camera-placeholder").hidden = false;
    $("camera-settings").textContent = "摄像头已关闭";
    $("camera-delivery").textContent = "页面接收帧率待测";
    if (videoFrameHandle !== null && typeof video.cancelVideoFrameCallback === "function") video.cancelVideoFrameCallback(videoFrameHandle);
    videoFrameHandle = null; videoFrameTimes = []; videoFrameLastReport = 0;
    captureCanvas = null; captureContext = null;
    setStatus(message);
    updateButtons();
  }
  function apiError(data, fallback) {
    const detail = data && (data.error || data.message || data.detail);
    return typeof detail === "string" && detail.length < 300 ? detail : fallback;
  }
  async function checkHealth() {
    try {
      const response = await fetch("/api/health", {cache:"no-store"});
      if (!response.ok) throw Error();
      if (!running && !starting) setStatus("本机服务已连接，可以打开摄像头。");
    } catch (_) {
      if (!running && !starting) setStatus("无法连接本机服务，请检查终端中的启动信息。", true);
    }
  }
  async function start() {
    if (running || starting) return;
    if (!navigator.mediaDevices || !navigator.mediaDevices.getUserMedia) {
      setStatus("当前浏览器无法访问摄像头。请使用本机 localhost 页面并检查浏览器权限。", true); return;
    }
    const token = ++generation;
    starting = true; updateButtons(); setStatus("正在请求摄像头权限…");
    try {
      const incoming = await navigator.mediaDevices.getUserMedia({video:{width:{ideal:1280},height:{ideal:720},frameRate:{ideal:120}},audio:false});
      if (token !== generation) { incoming.getTracks().forEach(track => track.stop()); return; }
      stream = incoming; video.srcObject = stream;
      await video.play();
      if (token !== generation) { incoming.getTracks().forEach(track => track.stop()); return; }
      const track = stream.getVideoTracks()[0];
      track.addEventListener("ended", () => { if (stream === incoming) stop("摄像头已断开。"); }, {once:true});
      const settings = track.getSettings();
      let capabilities = {};
      try { if (typeof track.getCapabilities === "function") capabilities = track.getCapabilities(); } catch (_) { /* capability reporting is optional */ }
      const maximum = Number(capabilities.frameRate && capabilities.frameRate.max);
      const selectedRate = Number(settings.frameRate);
      const sizeText = settings.width && settings.height ? `${settings.width} × ${settings.height}` : "尺寸未知";
      const maxText = Number.isFinite(maximum) && maximum > 0 ? `${maximum.toFixed(0)} 帧/秒` : "未知";
      const settingText = Number.isFinite(selectedRate) && selectedRate > 0 ? `${selectedRate.toFixed(1)} 帧/秒` : "未知";
      $("camera-settings").textContent = `${sizeText} · 设备报告上限 ${maxText} · 当前设置 ${settingText}`;
      video.classList.add("active"); $("camera-placeholder").hidden = true;
      captureCanvas = document.createElement("canvas");
      captureContext = captureCanvas.getContext("2d", {alpha:false});
      if (!captureContext) throw Error("无法采集摄像头画面。");
      frameCount = 0; previousAt = null; intervals = []; running = true; starting = false; updateButtons();
      videoFrameTimes = []; videoFrameLastReport = 0;
      if (typeof video.requestVideoFrameCallback === "function") {
        const onVideoFrame = now => {
          if (!running || token !== generation || stream !== incoming) return;
          videoFrameTimes.push(now);
          if (videoFrameTimes.length > 90) videoFrameTimes.shift();
          const elapsed = now - videoFrameTimes[0];
          if (videoFrameTimes.length > 1 && elapsed > 0 && now - videoFrameLastReport >= 1000) {
            $("camera-delivery").textContent = `页面收到约 ${((videoFrameTimes.length - 1) * 1000 / elapsed).toFixed(1)} 帧/秒（浏览器采样）`;
            videoFrameLastReport = now;
          }
          videoFrameHandle = video.requestVideoFrameCallback(onVideoFrame);
        };
        videoFrameHandle = video.requestVideoFrameCallback(onVideoFrame);
      } else $("camera-delivery").textContent = "浏览器不支持到帧率统计";
      setStatus("正在识别；第一次推理可能需要较长时间…");
      schedule(token, 0);
    } catch (failure) {
      if (token !== generation) return;
      stop("摄像头已关闭。");
      setStatus(`无法打开摄像头，请检查浏览器和系统权限。${failure.name === "NotFoundError" ? "未找到可用摄像头。" : ""}`, true);
    }
  }
  function schedule(token, delay) {
    if (!running || compareFrozen || token !== generation) return;
    timer = setTimeout(() => { timer = null; processFrame(token); }, delay);
  }
  function finite(value) { return typeof value === "number" && Number.isFinite(value); }
  function renderDetections(items, scaleUsed, offsetUsed, comparisonFrame) {
    const list = $("detections"); list.replaceChildren();
    lastDetections = items; lastScale = scaleUsed;
    if (!items.length) { const p = document.createElement("p"); p.className="empty"; p.textContent="本帧未检测到物体"; list.append(p); return; }
    items.forEach((item, index) => {
      const button = document.createElement("button"); button.type="button"; button.className="detection";
      const left = document.createElement("span"), title = document.createElement("strong"), confidence = document.createElement("small"), right = document.createElement("span");
      title.textContent = `${index + 1}. ${displayLabel(item.label)}`;
      confidence.textContent = finite(item.confidence) ? `置信度 ${(item.confidence * 100).toFixed(0)}%` : "置信度不可用";
      right.className="distance"; right.textContent = finite(item.distance_m) && item.distance_m > 0 ? `约 ${item.distance_m.toFixed(2)} 米` : "距离不可用";
      left.append(title, confidence); button.append(left, right);
      button.addEventListener("click", () => {
        if (comparisonFrame && $("depth-mode").value !== "standard") {
          $("calibration-status").textContent="比较帧使用 Base 标准 FP32，不能用于其他深度模型或精度的校准；请先切换标准模式并重新比较。";
          $("selected").closest("details").open=true; return;
        }
        if (!finite(item.distance_m) || item.distance_m <= 0) { $("calibration-status").textContent="该目标没有可用的距离估计，请选择其他目标。"; return; }
        selected = {label:displayLabel(item.label), distance:item.distance_m, scale:scaleUsed, offset:offsetUsed};
        $("selected").textContent = `已选择：${selected.label}，该帧估计 ${selected.distance.toFixed(2)} 米`;
        $("calibration-status").textContent = "已保存这一帧的估计值，请输入同一目标的实测前向距离。";
        $("selected").closest("details").open = true;
        $("known-distance").focus();
      });
      list.append(button);
    });
  }
  function drawFrame(capture, detections, frozenFrame) {
    if (canvas.width !== capture.width) canvas.width = capture.width;
    if (canvas.height !== capture.height) canvas.height = capture.height;
    const context = canvas.getContext("2d");
    if (!context) throw Error("无法绘制分析画面。");
    context.clearRect(0, 0, canvas.width, canvas.height);
    if (frozenFrame) context.drawImage(capture, 0, 0);
    const size = Math.max(14, Math.min(25, Math.round(capture.width * .018)));
    context.font = `600 ${size}px Arial, sans-serif`; context.textBaseline = "top";
    for (const item of detections) {
      if (!Array.isArray(item.box) || item.box.length !== 4 || !item.box.every(finite)) continue;
      const [x1,y1,x2,y2] = item.box;
      const x = Math.max(0, Math.min(capture.width, x1)), y = Math.max(0, Math.min(capture.height, y1));
      const right = Math.max(0, Math.min(capture.width, x2)), bottom = Math.max(0, Math.min(capture.height, y2));
      if (right <= x || bottom <= y) continue;
      context.strokeStyle="#b7f4c8"; context.lineWidth=Math.max(2,capture.width*.0025); context.strokeRect(x,y,right-x,bottom-y);
      const label = `${displayLabel(item.label)}${finite(item.confidence) ? ` ${(item.confidence*100).toFixed(0)}%` : ""}${finite(item.distance_m) && item.distance_m > 0 ? ` ~${item.distance_m.toFixed(2)}m` : ""}`;
      const width = context.measureText(label).width + 12;
      const tx = Math.max(0, Math.min(x, capture.width - width));
      const ty = Math.max(0, y - size - 8);
      context.fillStyle="rgba(5,22,17,.86)"; context.fillRect(tx,ty,width,size+8);
      context.fillStyle="#d8ffe1"; context.fillText(label,tx+6,ty+4);
    }
    canvas.hidden=false; $("result-placeholder").hidden=true;
  }
  async function processFrame(token) {
    if (!running || compareFrozen || token !== generation) return;
    if (video.readyState < 2 || !video.videoWidth || !video.videoHeight) { schedule(token,150); return; }
    try {
      // Reuse one canvas per camera session; the single-flight loop retains it
      // until its response completes, so the saved image stays frame-aligned.
      const captureStart=performance.now(), capturedDate = new Date(), capturedAt = capturedDate.toLocaleTimeString("zh-CN"), capture=captureCanvas, ctx=captureContext;
      if (!capture || !ctx) throw Error("无法采集摄像头画面。");
      const factor=Math.min(1, 1280 / video.videoWidth, 1280 / video.videoHeight);
      const width=Math.max(1,Math.round(video.videoWidth*factor)), height=Math.max(1,Math.round(video.videoHeight*factor));
      if (capture.width !== width) capture.width=width;
      if (capture.height !== height) capture.height=height;
      ctx.drawImage(video,0,0,capture.width,capture.height);
      const blob=await new Promise((resolve,reject) => capture.toBlob(x => x ? resolve(x) : reject(Error("无法编码摄像头画面。")),"image/jpeg",.88));
      if (!running || token !== generation) return;
      const captureDuration = performance.now() - captureStart;
      const comparing=compareRequested, scaleUsed=comparing ? 1 : scale, offsetUsed=comparing ? 0 : offset, detectorUsed=detectorMode,
        promptsUsed=detectorPrompts, versionUsed=detectorVersion, compareModel=$("compare-model").value,
        depthUsed=comparing ? "standard" : $("depth-mode").value, form=new FormData();
      form.append("image",blob,"frame.jpg"); form.append("scale",String(scaleUsed)); form.append("offset",String(offsetUsed));
      form.append("detector",detectorUsed); form.append("depth_mode", depthUsed);
      if (isOwl(detectorUsed)) form.append("prompts",promptsUsed);
      if (comparing) { form.append("compare_depth","1"); form.append("compare_model", compareModel); }
      const request = new AbortController(); controller=request;
      const response=await fetch("/api/analyze",{method:"POST",body:form,signal:request.signal,cache:"no-store"});
      if (response.status === 429) {
        if (!running || token !== generation) return;
        controller = null; setStatus("本机正在处理上一帧，稍后自动重试…"); schedule(token, 500); return;
      }
      let data; try { data=await response.json(); } catch (_) { throw Error("本机服务返回的数据无法读取。"); }
      if (!running || token !== generation) return;
      if (versionUsed !== detectorVersion) { controller = null; schedule(token, 0); return; }
      if (!response.ok) throw Error(apiError(data,"本机分析失败，请检查终端日志。"));
      if (!comparing) {
        const actual=data.depth_mode_actual;
        $("depth-mode-status").textContent = depthUsed === "mixed"
          ? actual === "mixed" ? "混合精度正在运行。" : actual === "standard" ? "设备未启用混合精度，实际回退至标准 FP32。" : "混合精度的实际执行方式未知，请检查服务。"
          : depthUsed === "large" ? actual === "large" ? "Depth Anything Large 正在运行。" : "Large 模型的实际执行方式未知，请检查服务。"
          : actual === "standard" ? "标准 FP32 正在运行。" : "标准模式执行方式未知，请检查服务。";
      }
      if (Number(data.width)!==capture.width || Number(data.height)!==capture.height || !Array.isArray(data.detections)) throw Error("识别结果格式无效，请检查本机服务。");
      // A calibration change while this request was running makes its values stale.
      // Wait for it to finish, then submit a new frame using the latest scale.
      if (!comparing && (scaleUsed !== scale || offsetUsed !== offset)) { controller = null; schedule(token, 0); return; }
      const detections=data.detections.filter(x => x && typeof x === "object");
      stage.classList.toggle("is-frozen", comparing);
      drawFrame(capture,detections,comparing); renderDetections(detections,scaleUsed,offsetUsed,comparing);
      const grid=data.depth_grid, largeGrid=data.depth_grid_large;
      const validGrid = g => g && Number.isInteger(g.width) && Number.isInteger(g.height) && g.width > 0 && g.height > 0 && Array.isArray(g.values) && g.values.length === g.width * g.height;
      const candidateName = candidateLabels[compareModel] || "Large";
      if (comparing && (!validGrid(largeGrid) || !validGrid(grid) || largeGrid.width !== grid.width || largeGrid.height !== grid.height || data.depth_candidate_name !== candidateName)) throw Error("深度比较结果不完整，请检查本机服务。");
      let candidateDisplayName = candidateName, comparisonWarning = "";
      if (comparing && compareModel === "mixed" && data.depth_candidate_actual !== "mixed") {
        if (data.depth_candidate_actual === "standard") {
          candidateDisplayName = "Base 混合精度（已回退 FP32）";
          comparisonWarning = "混合精度已回退 FP32，本次不是混合精度比较。";
        } else {
          candidateDisplayName = "Base 混合精度（实际精度未知）";
          comparisonWarning = "混合精度的实际执行方式未知，请检查服务。";
        }
      }
      displayedDepth = validGrid(grid) ? {grid, largeGrid:comparing ? largeGrid : null, candidateName:candidateDisplayName,
        candidateActual:data.depth_candidate_actual, compareModel, scale:scaleUsed, offset:offsetUsed, liveScale:scale, liveOffset:offset,
        liveDepthMode:$("depth-mode").value, capturedAt:capturedDate.toISOString(), frame:frameCount+1} : null;
      const now=performance.now(); frameCount++;
      if (previousAt !== null && now > previousAt) { intervals.push(now-previousAt); if (intervals.length>10) intervals.shift(); }
      previousAt=now;
      $("fps").textContent=intervals.length ? (1000/(intervals.reduce((a,b)=>a+b,0)/intervals.length)).toFixed(1) : "—";
      const timings=data.timing_ms || {};
      const elapsed=Number(timings.total ?? timings.total_ms ?? timings.totalMs);
      $("latency").textContent=Number.isFinite(elapsed) && elapsed>=0 ? Math.round(elapsed) : "—";
      $("count").textContent=String(detections.length);
      $("frame-count").textContent=`第 ${frameCount} 帧`;
      $("frame-label").textContent=`${capture.width} × ${capture.height} · 采集 ${capturedAt} · 延迟 ${Math.round(now-captureStart)} 毫秒`;
      controller=null;
      if (comparing) {
        clearResultExpiry();
        measurementPoint=null; $("measurement-status").textContent="请点击冻结画面中目标的内部，再输入实测距离。";
        compareRequested=false; compareFrozen=true; updateButtons();
        $("compare-result").textContent=`${comparisonWarning}第 ${frameCount} 帧已冻结。点击纸盒内部，比较同一点的原始未校准距离。`;
        setStatus("比较帧已冻结；摄像头仍在运行。");
      } else {
        scheduleResultExpiry(captureStart, token);
        setStatus(compareRequested ? `正在准备比较，首次加载 ${comparisonLabel()} 可能较慢…` : `正在本机识别 · 画面采集及编码 ${Math.round(captureDuration)} 毫秒`);
        schedule(token,0);
      }
    } catch (failure) {
      if (!running || token !== generation || failure.name === "AbortError") return;
      controller=null; stop("识别已停止。"); setStatus(failure.message || "本机分析失败，请检查终端日志。",true);
    }
  }
  function choosePoint(event) {
    const shown=displayedDepth;
    if (!compareFrozen || !shown || canvas.hidden) {
      $("calibration-status").textContent="请先使用单帧深度比较冻结分析画面，再选择测距点。";
      $("selected").closest("details").open=true; return;
    }
    const rect=canvas.getBoundingClientRect();
    // Account for object-fit: contain and any unused space inside the element.
    const ratio=Math.min(rect.width/canvas.width,rect.height/canvas.height);
    const imageWidth=canvas.width*ratio, imageHeight=canvas.height*ratio;
    const px=event.clientX-rect.left-(rect.width-imageWidth)/2;
    const py=event.clientY-rect.top-(rect.height-imageHeight)/2;
    if (!Number.isFinite(ratio) || ratio <= 0 || px < 0 || py < 0 || px >= imageWidth || py >= imageHeight) return;
    const x=Math.min(shown.grid.width-1,Math.floor(px/imageWidth*shown.grid.width));
    const y=Math.min(shown.grid.height-1,Math.floor(py/imageHeight*shown.grid.height));
    function neighborhood(grid) {
      const values=[];
      for (let dy=-1;dy<=1;dy++) for (let dx=-1;dx<=1;dx++) {
        const xx=x+dx, yy=y+dy;
        if (xx<0 || yy<0 || xx>=grid.width || yy>=grid.height) continue;
        const v=grid.values[yy*grid.width+xx];
        if (finite(v) && v>0) values.push(v);
      }
      values.sort((a,b)=>a-b);
      if (!values.length) return null;
      const mid=Math.floor(values.length/2);
      return values.length%2 ? values[mid] : (values[mid-1]+values[mid])/2;
    }
    const raw=neighborhood(shown.grid);
    if (raw === null) {
      $("calibration-status").textContent="该点没有有效深度，请选择物体内部的其他位置。";
      $("selected").closest("details").open=true; return;
    }
    if (shown.largeGrid) {
      const large=neighborhood(shown.largeGrid);
      $("compare-result").textContent=large === null
        ? `第 ${shown.frame} 帧：Base 未校准 ${raw.toFixed(2)} 米；${shown.candidateName} 在此点无有效值。`
        : `第 ${shown.frame} 帧同一点，未校准：Base ${raw.toFixed(2)} 米；${shown.candidateName} ${large.toFixed(2)} 米。请与该处实测前向距离比较。`;
      // Compare frames always run uncalibrated standard Base. For the optional
      // calibrated column, only apply a scale to the precision mode that earned it.
      let calibrated=null, calibratedLabel="";
      if (shown.liveDepthMode === "standard") {
        calibrated=raw*shown.liveScale+shown.liveOffset; calibratedLabel="Base FP32";
      } else if (shown.liveDepthMode === "mixed" && shown.compareModel === "mixed" && shown.candidateActual === "mixed" && large !== null) {
        calibrated=large*shown.liveScale+shown.liveOffset; calibratedLabel="Base 混合精度";
      } else if (shown.liveDepthMode === "large" && shown.compareModel === "large" && large !== null) {
        calibrated=large*shown.liveScale+shown.liveOffset; calibratedLabel="Depth Anything Large";
      }
      measurementPoint={frame:shown.frame, capturedAt:shown.capturedAt, base:raw, candidate:large,
        candidateName:shown.candidateName, compareModel:shown.compareModel, candidateActual:shown.candidateActual,
        liveDepthMode:shown.liveDepthMode, calibrated, calibratedLabel, calibratedScale:shown.liveScale, calibratedOffset:shown.liveOffset};
      $("measurement-status").textContent=`已选第 ${shown.frame} 帧的同一点；输入实测距离后记录。`;
      updateButtons();
    }
    if ($("depth-mode").value === "standard") {
      selected={label:"画面选点", distance:raw*shown.scale+shown.offset, scale:shown.scale, offset:shown.offset};
      $("selected").textContent=`已选择：画面选点（第 ${shown.frame} 帧），该点估计 ${selected.distance.toFixed(2)} 米`;
      $("calibration-status").textContent="已保存这一帧的估计值；输入该处实测前向距离即可校准。";
    } else {
      selected=null; $("selected").textContent="尚未选择目标";
      $("calibration-status").textContent="比较帧使用 Base 标准 FP32，不能用于其他深度模型或精度的校准；请先切换标准模式并重新比较。";
    }
    $("selected").closest("details").open=true;
    // Mark only this displayed frame; later frames do not inherit stale coordinates.
    const ctx=canvas.getContext("2d"), sx=px/ratio, sy=py/ratio;
    if (ctx) {
      ctx.save(); ctx.strokeStyle="#ffffff"; ctx.lineWidth=Math.max(2,canvas.width*.002);
      ctx.beginPath(); ctx.arc(sx,sy,Math.max(7,canvas.width*.008),0,2*Math.PI); ctx.stroke();
      ctx.beginPath(); ctx.moveTo(sx-12,sy);ctx.lineTo(sx+12,sy);ctx.moveTo(sx,sy-12);ctx.lineTo(sx,sy+12);ctx.stroke(); ctx.restore();
    }
  }
  canvas.addEventListener("click",choosePoint);
  function applyScale() {
    const known=Number($("known-distance").value);
    if (!selected) { $("calibration-status").textContent="请先点击检测目标或已分析画面上的位置。"; return; }
    if (!Number.isFinite(known) || known < .05 || known > 1000) { $("calibration-status").textContent="请输入 0.05 至 1000 米之间的实测距离。"; return; }
    const raw=(selected.distance-selected.offset)/selected.scale;
    const next = known/raw;
    if (!Number.isFinite(raw) || raw <= 0 || !Number.isFinite(next) || next < .01 || next > 100) { $("calibration-status").textContent="校准比例超出范围，请重新选择目标并检查实测距离。"; return; }
    scale=next; offset=0; $("scale-note").textContent=`当前：${scale.toFixed(3)} × 原始距离 + 0.000 米（单点校准）`;
    $("calibration-status").textContent="已应用比例校准，下一帧生效。不同距离和场景仍可能存在较大误差。";
    selected=null; $("selected").textContent="尚未选择目标";
    restartAnalysisAfterScale();
  }
  function restartAnalysisAfterScale() {
    // Do not abort an executing inference: the server may continue processing it.
    // The pending response is discarded above if its scale is now stale.
    previousAt = null; intervals = []; displayedDepth = null;
  }
  $("depth-mode").addEventListener("change", () => {
    $("depth-mode-status").textContent = `已请求${depthModeName($("depth-mode").value)}，正在等待实际执行结果…`;
    scale=1; offset=0; selected=null; $("known-distance").value="";
    $("scale-note").textContent="当前：1.000 × 原始距离 + 0.000 米（未校准）";
    $("calibration-status").textContent="实时深度精度已切换；旧距离校准已重置，请按当前模式重新校准。";
    clearDetectorResult();
  });
  $("compare-model").addEventListener("change", updateButtons);
  $("compare-depth").addEventListener("click", () => {
    if (!running) return;
    if (compareFrozen) {
      clearResultExpiry();
      compareFrozen=false; measurementPoint=null; $("measurement-status").textContent="已恢复实时画面；请重新冻结并选点后再记录。"; stage.classList.remove("is-frozen"); canvas.hidden=true; videoFrameTimes=[]; videoFrameLastReport=0; $("camera-delivery").textContent="页面接收帧率重新采样中"; $("compare-result").textContent="已恢复实时识别。";
      displayedDepth=null; previousAt=null; intervals=[]; updateButtons(); schedule(generation,0);
      return;
    }
    if (compareRequested) return;
    selected=null; measurementPoint=null; $("selected").textContent="尚未选择目标";
    compareRequested=true; $("compare-result").textContent=`正在准备比较，首次加载 ${comparisonLabel()} 模型可能较慢。`;
    setStatus("正在准备同帧比较…"); updateButtons();
  });
  function measurementCell(text) {
    const td=document.createElement("td"); td.textContent=text; return td;
  }
  function measurementValue(value, known, label="") {
    if (!finite(value)) return "不可用";
    const delta=value-known;
    return `${label ? label + " " : ""}${value.toFixed(2)} m / ${delta >= 0 ? "+" : ""}${delta.toFixed(2)} m`;
  }
  function renderMeasurements() {
    const rows=$("measurement-rows"); rows.replaceChildren();
    for (const m of measurements) {
      const tr=document.createElement("tr");
      const timestamp=new Date(m.capturedAt).toLocaleTimeString("zh-CN");
      tr.append(measurementCell(`第 ${m.frame} 帧 · ${timestamp}`), measurementCell(`${m.known.toFixed(2)} m`),
        measurementCell(measurementValue(m.base,m.known)), measurementCell(measurementValue(m.candidate,m.known,m.candidateName)),
        measurementCell(m.calibratedScale !== 1 || m.calibratedOffset !== 0 ? measurementValue(m.calibrated > 0 ? m.calibrated : null,m.known,`${m.calibratedLabel} a=${m.calibratedScale.toFixed(4)} b=${m.calibratedOffset.toFixed(4)}m`) : "未校准"));
      rows.append(tr);
    }
    updateFitOptions();
    if (fitSelection) renderFitPreview(fitSelection);
    updateButtons();
  }
  $("measurement-save").addEventListener("click", () => {
    const known=Number($("measurement-distance").value);
    if (!compareFrozen || !measurementPoint || !displayedDepth || measurementPoint.frame !== displayedDepth.frame) {
      $("measurement-status").textContent="请先冻结同一画面并点击目标内部。"; return;
    }
    if (!Number.isFinite(known) || known < .05 || known > 1000) {
      $("measurement-status").textContent="请输入 0.05 至 1000 米之间的实测距离。"; return;
    }
    measurements.push({...measurementPoint, known});
    $("measurement-status").textContent=`已记录第 ${measurementPoint.frame} 帧；记录只保存在本页。`;
    renderMeasurements();
  });
  $("measurement-clear").addEventListener("click", () => {
    measurements=[]; fitSelection=null; renderMeasurements(); clearFitPreview("至少记录两个不同实测距离，再选择拟合点。"); $("measurement-status").textContent="本页测量记录已清空。";
  });
  // This preview never changes the active scale or submits calibration data.
  // Candidate identity includes actual precision, so an FP32 fallback cannot
  // silently be mixed with a genuine MPS mixed-precision sample.
  function fitObservation(m, source) {
    if (source === "base") return finite(m.base) ? {value:m.base, signature:"base-fp32", label:"Base 标准 FP32"} : null;
    if (!finite(m.candidate) || !["large","pro","mixed"].includes(m.compareModel)) return null;
    if (m.compareModel === "mixed" && !["mixed","standard"].includes(m.candidateActual)) return null;
    return {value:m.candidate, signature:`${m.compareModel}:${m.candidateActual || "native"}`, label:m.candidateName};
  }
  function updateFitOptions() {
    for (const id of ["fit-first","fit-second"]) {
      const select=$(id), previous=select.value;
      select.replaceChildren();
      const blank=document.createElement("option"); blank.value=""; blank.textContent="请选择记录"; select.append(blank);
      measurements.forEach((m,index) => {
        const option=document.createElement("option"); option.value=String(index);
        option.textContent=`记录 ${index+1} · ${m.known.toFixed(2)} m · 第 ${m.frame} 帧 · ${new Date(m.capturedAt).toLocaleTimeString("zh-CN")}`;
        select.append(option);
      });
      if (previous !== "" && Number(previous) < measurements.length) select.value=previous;
    }
    $("fit-calculate").disabled=measurements.length<2;
  }
  function clearFitPreview(message) {
    $("fit-rows").replaceChildren(); $("fit-status").textContent=message;
  }
  function renderFitPreview(selection) {
    const first=measurements[selection.first], second=measurements[selection.second];
    const aObs=first && fitObservation(first,selection.source), bObs=second && fitObservation(second,selection.source);
    if (!first || !second || !aObs || !bObs || aObs.signature !== bObs.signature ||
        (first.frame === second.frame && first.capturedAt === second.capturedAt)) {
      fitSelection=null; clearFitPreview("拟合需要不同帧、同一模型及实际精度的两条有效记录。"); return;
    }
    const deltaRaw=bObs.value-aObs.value, deltaKnown=second.known-first.known;
    if (Math.abs(deltaRaw)<0.001 || Math.abs(deltaKnown)<0.001) {
      fitSelection=null; clearFitPreview("两点的实测距离和原始读数都须不同，且原始读数至少相差 0.001 米。"); return;
    }
    const a=deltaKnown/deltaRaw, b=first.known-a*aObs.value;
    if (!Number.isFinite(a) || !Number.isFinite(b) || a <= 0) {
      fitSelection=null; clearFitPreview("两点不满足距离随原始读数递增，不能建立正向拟合。"); return;
    }
    const rawMin=Math.min(aObs.value,bObs.value), rawMax=Math.max(aObs.value,bObs.value);
    const knownMin=Math.min(first.known,second.known), knownMax=Math.max(first.known,second.known);
    const rows=$("fit-rows"); rows.replaceChildren(); let holdouts=0;
    measurements.forEach((m,index) => {
      const obs=fitObservation(m,selection.source), tr=document.createElement("tr");
      const isFit=index === selection.first || index === selection.second;
      const purpose=isFit ? "拟合" : "留出测试";
      let prediction="不适用", absoluteError="—", range="模型或实际精度不同";
      if (obs && obs.signature === aObs.signature) {
        const value=a*obs.value+b;
        if (!isFit) holdouts++;
        if (Number.isFinite(value) && value > 0) {
          prediction=`${value.toFixed(2)} m`; absoluteError=`${Math.abs(value-m.known).toFixed(2)} m`;
        } else { prediction="非正值，不可用"; }
        const outsideRaw=obs.value<rawMin || obs.value>rawMax;
        const outsideKnown=m.known<knownMin || m.known>knownMax;
        range=(outsideRaw || outsideKnown) ? "外推（超出拟合范围）" : "拟合范围内";
      }
      tr.append(measurementCell(`记录 ${index+1} · ${purpose}`), measurementCell(`${m.known.toFixed(2)} m`),
        measurementCell(prediction), measurementCell(absoluteError), measurementCell(range));
      rows.append(tr);
    });
    $("fit-status").textContent=`${aObs.label} · 预览：距离 = ${a.toFixed(4)} × 原始读数 ${b >= 0 ? "+" : "−"} ${Math.abs(b).toFixed(4)} 米；${holdouts} 条同模型留出测试。未应用到实时测距。`;
  }
  $("fit-calculate").addEventListener("click", () => {
    const firstText=$("fit-first").value, secondText=$("fit-second").value;
    if (firstText === "" || secondText === "" || firstText === secondText) {
      fitSelection=null; clearFitPreview("请选择两条不同记录作为拟合点。"); return;
    }
    fitSelection={first:Number(firstText), second:Number(secondText), source:$("fit-source").value};
    renderFitPreview(fitSelection);
  });
  for (const id of ["fit-source","fit-first","fit-second"]) $(id).addEventListener("change", () => {
    fitSelection=null; clearFitPreview("选择改变后，请重新点击预览；不会自动应用。");
  });
  $("start").addEventListener("click",start); $("stop").addEventListener("click",() => stop());
  $("calibrate").addEventListener("click",applyScale);
  $("apply-affine").addEventListener("click", () => {
    const slopeText=$("affine-slope").value.trim(), offsetText=$("affine-offset").value.trim();
    const slope=Number(slopeText), intercept=Number(offsetText);
    if (!slopeText || !offsetText || !Number.isFinite(slope) || slope < .01 || slope > 100 ||
        !Number.isFinite(intercept) || intercept < -100 || intercept > 100) {
      $("calibration-status").textContent="请输入 0.01–100 的正斜率和 −100–100 米的偏移。"; return;
    }
    scale=slope; offset=intercept; selected=null; $("selected").textContent="尚未选择目标";
    const mode=depthModeName($("depth-mode").value);
    $("scale-note").textContent=`当前：${scale.toFixed(4)} × 原始距离 ${offset >= 0 ? "+" : "−"} ${Math.abs(offset).toFixed(4)} 米（仿射，${mode}）`;
    $("calibration-status").textContent="已手动应用仿射系数。仅适用于本模式和当前相机，拟合区间外为外推；非正估计不会显示。";
    restartAnalysisAfterScale();
  });
  $("restore-scale").addEventListener("click", () => {
    const input=$("restore-scale-value").value.trim();
    const restored=Number(input);
    if (!input || !Number.isFinite(restored) || restored < .01 || restored > 100) {
      $("calibration-status").textContent="请输入 0.01 至 100 的有效校准系数。"; return;
    }
    scale=restored; offset=0; selected=null; $("selected").textContent="尚未选择目标";
    const mode=depthModeName($("depth-mode").value);
    $("scale-note").textContent=`当前：${scale.toFixed(3)} × 原始距离 + 0.000 米（已恢复，${mode}）`;
    $("calibration-status").textContent=`已为${mode}恢复系数；请仅在原校准相机和场景下使用，并验证其他距离。`;
    restartAnalysisAfterScale();
  });
  $("reset-scale").addEventListener("click",() => {
    scale=1; offset=0; selected=null; $("selected").textContent="尚未选择目标"; $("known-distance").value="";
    $("scale-note").textContent="当前：1.000 × 原始距离 + 0.000 米（未校准）"; $("calibration-status").textContent="已重置比例。"; restartAnalysisAfterScale();
  });
  window.addEventListener("pagehide",() => stop());
  updateButtons(); checkHealth();
})();
