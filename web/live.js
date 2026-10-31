"use strict";

// Live sources stay in this tab. Only downscaled, silent JPEG frames are sent
// to the same-origin detection API. Results are drawn on the exact saved frame.
(() => {
  const $ = id => document.getElementById(id);
  const base = new URL("./", document.baseURI);
  const messages = {
    zh: {
      image:"图片", video:"视频", camera:"摄像头", source:"输入画面", analyzed:"已分析画面", chooseVideo:"选择视频", changeVideo:"更换视频", openCamera:"打开摄像头", closeCamera:"关闭摄像头", start:"开始连续识别", stop:"停止识别", title:"连续识别", resultTitle:"识别状态", videoHint:"选择一个本地视频", cameraHint:"需在浏览器中允许摄像头", videoEmpty:"选择视频开始", cameraEmpty:"打开摄像头开始", resultEmpty:"结果会显示在这里", caption:"这里显示实际发送并完成识别的画面；结果会比输入画面有延迟。", videoDescription:"选择本地视频，网页会定期将画面发送到服务器识别。原始视频不会整段上传，也不发送音频。", cameraDescription:"允许摄像头后，网页会定期将画面发送到服务器识别；不会采集或发送音频。", note:"实验模型仅识别水下门框；低光、遮挡或不同水域可能漏检。结果不用于控制真实机器人。", foot:"识别由连接的设备完成", chooseFirst:"选择视频后开始识别。", cameraFirst:"打开摄像头后开始识别。", checking:"正在连接识别服务…", modelDown:"模型暂不可用，请稍后重试。", loading:"正在加载视频…", videoReady:"视频已就绪，可以开始识别。", openingCamera:"正在请求摄像头权限…", cameraReady:"摄像头已打开，可以开始识别。", permission:"无法打开摄像头，请检查浏览器权限和设备。", unsupported:"当前浏览器不支持摄像头。", videoError:"无法读取该视频，请尝试浏览器支持的 MP4 或 WebM。", videoTooLarge:"视频超过 2 GB，请选择更小的文件。", analyzing:"正在持续识别…", paused:"视频已暂停，播放后继续识别。", buffering:"正在等待画面…", ended:"视频已结束。", stopped:"识别已停止。", cameraClosed:"摄像头已关闭。", busy:"服务器正忙，稍后自动重试。", connectionError:"无法连接服务器，识别已停止。", frameError:"无法处理当前画面，识别已停止。", badResult:"服务器返回的数据无法读取，识别已停止。", result:"已分析 {n} 帧 · 本帧 {count} 个目标", timing:"实际间隔 {interval} 秒/帧 · 服务器 {duration} 秒", firstTiming:"服务器处理 {duration} 秒", intervalOnly:"实际间隔 {interval} 秒/帧", frameVideo:"已分析画面 · 视频 {time}", frameCamera:"已分析画面 · {time}", gate:"门框", noGate:"未检测到门框", modeAria:"选择输入方式", liveAria:"连续识别工作台"
    },
    en: {
      image:"Image", video:"Video", camera:"Camera", source:"Live input", analyzed:"Analyzed frame", chooseVideo:"Choose video", changeVideo:"Change video", openCamera:"Open camera", closeCamera:"Close camera", start:"Start continuous detection", stop:"Stop detection", title:"Continuous detection", resultTitle:"Detection status", videoHint:"Choose a local video", cameraHint:"Allow camera access in your browser", videoEmpty:"Choose a video to begin", cameraEmpty:"Open the camera to begin", resultEmpty:"Results will appear here", caption:"The analyzed frame is the exact image sent to the server; results lag behind the input.", videoDescription:"Choose a local video. The page periodically sends frames to the server; the whole video and audio are not uploaded.", cameraDescription:"After you allow the camera, the page periodically sends frames to the server. Audio is never captured or sent.", note:"Experimental underwater gate model. Low light, occlusion or new environments may cause misses. Not for controlling a real vehicle.", foot:"Detection runs on the connected device", chooseFirst:"Choose a video to start.", cameraFirst:"Open the camera to start.", checking:"Connecting to the detection service…", modelDown:"The model is unavailable. Please try again later.", loading:"Loading video…", videoReady:"Video ready. Start detection when ready.", openingCamera:"Requesting camera access…", cameraReady:"Camera ready. Start detection when ready.", permission:"Cannot open the camera. Check browser permission and the device.", unsupported:"This browser does not support camera access.", videoError:"Cannot read this video. Try a browser-supported MP4 or WebM.", videoTooLarge:"Video exceeds 2 GB. Choose a smaller file.", analyzing:"Analyzing frames…", paused:"Video paused. Play it to continue detection.", buffering:"Waiting for a frame…", ended:"Video ended.", stopped:"Detection stopped.", cameraClosed:"Camera closed.", busy:"Server busy. Retrying shortly.", connectionError:"Cannot reach the server. Detection stopped.", frameError:"Cannot process this frame. Detection stopped.", badResult:"The server returned invalid data. Detection stopped.", result:"{n} frames analyzed · {count} detection(s) in this frame", timing:"Actual interval {interval} s/frame · server {duration} s", firstTiming:"Server processing {duration} s", intervalOnly:"Actual interval {interval} s/frame", frameVideo:"Analyzed frame · video {time}", frameCamera:"Analyzed frame · {time}", gate:"Gate", noGate:"No gate detected", modeAria:"Choose input mode", liveAria:"Continuous detection workspace"
    }
  };
  const lang = () => document.documentElement.lang === "en" ? "en" : "zh";
  const t = key => messages[lang()][key] || key;
  const fmt = (key, values) => t(key).replace(/\{(\w+)\}/g, (_, key) => String(values[key] ?? ""));
  const video = $("source-video"), resultCanvas = $("snapshot");
  let mode = "image", stream = null, videoUrl = null, modelReady = false;
  let running = false, startPending = false, generation = 0, sourceGeneration = 0, activeRequest = null, timer = null;
  let frameCount = 0, lastSuccessAt = null, latestResult = null, stateKey = "chooseFirst", errorKey = null;
  let recentIntervals = [];
  let captionKind = null, captionValue = null;

  function state(key) { stateKey = key; $("live-state-text").textContent = t(key); }
  function error(key) { errorKey = key; $("live-error").hidden = !key; $("live-error").textContent = key ? t(key) : ""; }
  function updateControls() {
    const sourceReady = mode === "camera" ? !!stream && video.readyState >= 2 : !!videoUrl && video.readyState >= 2;
    $("live-start").disabled = !sourceReady || !modelReady || running || startPending;
    $("live-start").hidden = running;
    $("live-stop").hidden = !running;
    $("video-choose").hidden = mode !== "video";
    $("camera-open").hidden = mode !== "camera";
  }
  function updateTexts() {
    $("mode-image").textContent = t("image"); $("mode-video").textContent = t("video"); $("mode-camera").textContent = t("camera");
    document.querySelector(".mode-switch").setAttribute("aria-label", t("modeAria"));
    $("live-workspace").setAttribute("aria-label", t("liveAria"));
    $("source-label").textContent = t("source"); $("snapshot-label").textContent = t("analyzed");
    $("source-hint").textContent = t(mode === "camera" ? "cameraHint" : "videoHint");
    $("source-placeholder").textContent = t(mode === "camera" ? "cameraEmpty" : "videoEmpty");
    $("snapshot-placeholder").textContent = t("resultEmpty");
    $("live-title").textContent = t("title");
    $("live-description").textContent = t(mode === "camera" ? "cameraDescription" : "videoDescription");
    $("video-choose-text").textContent = t(videoUrl ? "changeVideo" : "chooseVideo");
    $("camera-open").textContent = t(stream ? "closeCamera" : "openCamera");
    $("live-start-text").textContent = t("start"); $("live-stop").textContent = t("stop");
    $("live-result-title").textContent = t("resultTitle"); $("live-note").textContent = t("note"); $("live-foot").textContent = t("foot");
    state(stateKey); if (errorKey) error(errorKey);
    renderSummary(); updateCaption(); updateControls();
  }
  function updateCaption() {
    $("snapshot-caption").textContent = captionKind ? fmt(captionKind, {time:captionValue}) + " · " + t("caption") : t("caption");
  }
  function renderSummary() {
    if (!latestResult) { $("live-count").textContent = "—"; $("live-detail").textContent = ""; return; }
    $("live-count").textContent = String(latestResult.count).padStart(2,"0");
    if (stateKey === "analyzing") $("live-state-text").textContent = fmt("result", {n:frameCount, count:latestResult.count});
    const {fps, capture, request, duration} = latestResult;
    const ms = value => Math.round(value);
    if (lang() === "zh") {
      const rate = fps === null ? "" : `${fps.toFixed(1)} 帧/秒 · `;
      const server = duration === null ? "" : `（含服务端 ${ms(duration)} 毫秒）`;
      $("live-detail").textContent = `${rate}采集编码 ${ms(capture)} 毫秒 · 请求 ${ms(request)} 毫秒${server}`;
    } else {
      const rate = fps === null ? "" : `${fps.toFixed(1)} fps · `;
      const server = duration === null ? "" : ` (includes ${ms(duration)} ms server processing)`;
      $("live-detail").textContent = `${rate}capture and encode ${ms(capture)} ms · request ${ms(request)} ms${server}`;
    }
  }
  function stopAnalysis(reason = "stopped") {
    generation++; running = false;
    if (timer !== null) { clearTimeout(timer); timer = null; }
    if (activeRequest) { activeRequest.abort(); activeRequest = null; }
    state(reason); updateControls();
  }
  function releaseSource() {
    sourceGeneration++;
    if (stream) { stream.getTracks().forEach(track => track.stop()); stream = null; }
    video.pause(); video.srcObject = null; video.removeAttribute("src"); video.load();
    if (videoUrl) { URL.revokeObjectURL(videoUrl); videoUrl = null; }
    video.classList.remove("camera-active");
    $("source-placeholder").hidden = false;
  }
  function resetResult() {
    frameCount = 0; lastSuccessAt = null; latestResult = null; recentIntervals = []; captionKind = null; captionValue = null;
    resultCanvas.hidden = true; $("snapshot-placeholder").hidden = false;
    resultCanvas.width = 1; resultCanvas.height = 1;
    $("live-count").textContent = "—"; $("live-detail").textContent = ""; error(null); updateCaption();
  }
  async function checkModel() {
    try {
      const r = await fetch(new URL("api/health",base), {cache:"no-store"});
      const data = await r.json(); modelReady = r.ok && data.status === "ok" && data.model && data.model.available === true;
    } catch (_) { modelReady = false; }
    if (!modelReady && mode !== "image") state("modelDown");
    updateControls();
  }
  function selectMode(next) {
    if (next === mode) return;
    // Cancel any image inference or preprocessing as the user switches modes.
    window.dispatchEvent(new Event("pelagivex:mode-change"));
    stopAnalysis(); releaseSource(); resetResult(); mode = next;
    for (const m of ["image","video","camera"]) {
      $("mode-"+m).classList.toggle("active", m === mode);
      $("mode-"+m).setAttribute("aria-pressed", String(m === mode));
    }
    $("image-workspace").hidden = mode !== "image";
    $("live-workspace").hidden = mode === "image";
    video.controls = mode === "video";
    state(mode === "camera" ? "cameraFirst" : "chooseFirst");
    updateTexts();
    if (mode !== "image") checkModel();
  }
  async function chooseVideo(file) {
    if (!file || mode !== "video") return;
    stopAnalysis(); releaseSource(); resetResult();
    if (!file.type.startsWith("video/") && !/\.(mp4|webm|mov|m4v)$/i.test(file.name)) { error("videoError"); updateControls(); return; }
    if (file.size > 2 * 1024 * 1024 * 1024) { error("videoTooLarge"); updateControls(); return; }
    const current = ++sourceGeneration;
    videoUrl = URL.createObjectURL(file); video.src = videoUrl; video.controls = true; video.load(); state("loading"); updateTexts();
    try {
      await new Promise((resolve, reject) => {
        const ok = () => { cleanup(); resolve(); }, fail = () => { cleanup(); reject(Error("video")); };
        const cleanup = () => { video.removeEventListener("loadeddata",ok); video.removeEventListener("error",fail); };
        video.addEventListener("loadeddata",ok,{once:true}); video.addEventListener("error",fail,{once:true});
        if (video.readyState >= 2) ok();
      });
      if (current !== sourceGeneration || mode !== "video") return;
      $("source-placeholder").hidden = true; state("videoReady"); error(null); updateControls();
    } catch (_) {
      if (current !== sourceGeneration) return;
      releaseSource(); state("chooseFirst"); error("videoError"); updateTexts();
    }
  }
  async function openCamera() {
    if (mode !== "camera") return;
    if (stream) { stopAnalysis("cameraClosed"); releaseSource(); state("cameraClosed"); updateTexts(); return; }
    stopAnalysis(); releaseSource(); resetResult();
    if (!navigator.mediaDevices || !navigator.mediaDevices.getUserMedia) { error("unsupported"); return; }
    const current = ++sourceGeneration; state("openingCamera"); updateControls();
    $("camera-open").disabled = true;
    try {
      const incoming = await navigator.mediaDevices.getUserMedia({video:{width:{ideal:1280},height:{ideal:720},facingMode:{ideal:"environment"}},audio:false});
      if (current !== sourceGeneration || mode !== "camera") { incoming.getTracks().forEach(track => track.stop()); return; }
      stream = incoming; video.srcObject = incoming; video.classList.add("camera-active"); video.controls = false; video.muted = true;
      await video.play();
      if (current !== sourceGeneration || mode !== "camera") { incoming.getTracks().forEach(track => track.stop()); return; }
      incoming.getVideoTracks().forEach(track => track.addEventListener("ended", () => { if (stream === incoming) { stopAnalysis("cameraClosed"); releaseSource(); updateTexts(); } }, {once:true}));
      $("source-placeholder").hidden = true; state("cameraReady"); error(null); updateTexts();
    } catch (_) {
      if (current !== sourceGeneration) return;
      releaseSource(); state("cameraFirst"); error("permission"); updateTexts();
    } finally { $("camera-open").disabled = false; updateControls(); }
  }
  function clock(seconds) {
    if (!Number.isFinite(seconds)) return "--:--";
    const whole = Math.floor(seconds), h = Math.floor(whole/3600), m = Math.floor((whole%3600)/60), s = whole%60;
    return (h ? `${h}:` : "") + String(m).padStart(2,"0") + ":" + String(s).padStart(2,"0");
  }
  function snapshot(result, capture) {
    resultCanvas.width = capture.width; resultCanvas.height = capture.height;
    const ctx = resultCanvas.getContext("2d");
    if (!ctx) throw Error("frameError");
    ctx.drawImage(capture,0,0); ctx.lineWidth = Math.max(2, capture.width * 0.004);
    ctx.strokeStyle = "#b6ffd1"; ctx.fillStyle = "#edfff4";
    const size = Math.max(14, Math.min(30, capture.width * 0.026));
    ctx.font = `600 ${size}px Arial, sans-serif`; ctx.textBaseline = "top"; ctx.lineJoin = "round";
    let count = 0;
    for (const detection of result.detections) {
      if (!Array.isArray(detection.box) || detection.box.length !== 4) continue;
      const b = detection.box.map(Number); if (!b.every(Number.isFinite)) continue;
      const x1=Math.max(0,Math.min(capture.width,b[0])), y1=Math.max(0,Math.min(capture.height,b[1]));
      const x2=Math.max(0,Math.min(capture.width,b[2])), y2=Math.max(0,Math.min(capture.height,b[3]));
      if (x2<=x1 || y2<=y1) continue;
      ctx.strokeStyle="#b6ffd1"; ctx.strokeRect(x1,y1,x2-x1,y2-y1);
      const confidence = Number(detection.confidence);
      const label = `${t("gate")} ${Number.isFinite(confidence) ? (Math.max(0,Math.min(1,confidence))*100).toFixed(1)+"%" : ""}`;
      const x = Math.max(2,Math.min(x1+4,capture.width-ctx.measureText(label).width-4));
      const y = Math.max(2,Math.min(y1+4,capture.height-size-4));
      ctx.lineWidth = Math.max(3,size*0.18); ctx.strokeStyle="#0a201c"; ctx.strokeText(label,x,y); ctx.fillText(label,x,y);
      count++;
    }
    resultCanvas.hidden = false; $("snapshot-placeholder").hidden = true;
    return count;
  }
  function schedule(token, delay) {
    if (!running || token !== generation) return;
    timer = setTimeout(() => { timer = null; processFrame(token); }, delay);
  }
  async function processFrame(token) {
    if (!running || token !== generation) return;
    if (mode === "video" && video.ended) { stopAnalysis("ended"); return; }
    if (video.paused || video.readyState < 2 || !video.videoWidth || !video.videoHeight) {
      state(video.paused && mode === "video" ? "paused" : "buffering"); schedule(token,500); return;
    }
    const captureStarted = performance.now();
    const frameTime = mode === "video" ? clock(video.currentTime) : new Date().toLocaleTimeString(lang() === "zh" ? "zh-CN" : "en-GB");
    const factor = Math.min(1, 1280/video.videoWidth, 1280/video.videoHeight, Math.sqrt(1000000/(video.videoWidth*video.videoHeight)));
    const capture = document.createElement("canvas");
    capture.width = Math.max(1,Math.floor(video.videoWidth*factor)); capture.height = Math.max(1,Math.floor(video.videoHeight*factor));
    const context = capture.getContext("2d");
    if (!context) { stopAnalysis("stopped"); error("frameError"); return; }
    try {
      context.drawImage(video,0,0,capture.width,capture.height);
      const blob = await new Promise((resolve,reject) => capture.toBlob(b => b ? resolve(b) : reject(Error("frameError")),"image/jpeg",0.87));
      if (!running || token !== generation) return;
      const captureDuration = performance.now() - captureStarted;
      const form = new FormData(); form.append("image",blob,"frame.jpg");
      const controller = new AbortController(); activeRequest = controller;
      const requestStarted = performance.now();
      const response = await fetch(new URL("api/detect",base), {method:"POST",body:form,signal:controller.signal,cache:"no-store"});
      if (!running || token !== generation) return;
      if (response.status === 429) { activeRequest = null; state("busy"); schedule(token,5000); return; }
      if (!response.ok) throw Error(response.status === 503 ? "modelDown" : "connectionError");
      const data = await response.json();
      const requestDuration = performance.now() - requestStarted;
      if (!running || token !== generation) return;
      if (Number(data.width) !== capture.width || Number(data.height) !== capture.height || !Array.isArray(data.detections)) throw Error("badResult");
      const count = snapshot(data,capture), now = performance.now();
      frameCount++;
      const reportedDuration = Number(data.duration_ms);
      if (lastSuccessAt !== null) {
        const interval = now - lastSuccessAt;
        if (interval > 0) { recentIntervals.push(interval); if (recentIntervals.length > 10) recentIntervals.shift(); }
      }
      const averageInterval = recentIntervals.length ? recentIntervals.reduce((sum, value) => sum + value, 0) / recentIntervals.length : null;
      latestResult = {count, duration:Number.isFinite(reportedDuration) && reportedDuration >= 0 ? reportedDuration : null,
        capture:captureDuration, request:requestDuration, fps:averageInterval === null ? null : 1000 / averageInterval};
      lastSuccessAt = now; stateKey = "analyzing"; renderSummary();
      captionKind = mode === "video" ? "frameVideo" : "frameCamera"; captionValue = frameTime; updateCaption(); error(null);
      activeRequest = null;
      // Submit the latest frame as soon as the previous request completes.
      // One in-flight request provides backpressure and prevents frame queues;
      // a busy server still triggers the retry delay above.
      schedule(token,0);
    } catch (failure) {
      if (!running || token !== generation || failure.name === "AbortError") return;
      stopAnalysis("stopped"); error(["frameError","badResult","modelDown"].includes(failure.message) ? failure.message : "connectionError");
    }
  }
  async function startAnalysis() {
    if (mode === "image" || running || startPending || !modelReady) return;
    if (mode === "camera" && !stream) return;
    if (mode === "video" && !videoUrl) return;
    error(null); startPending = true; updateControls();
    const sourceToken = sourceGeneration;
    try {
      if (video.paused) { if (video.ended) video.currentTime = 0; await video.play(); }
      if (sourceToken !== sourceGeneration || mode === "image" || (mode === "camera" && !stream) || (mode === "video" && !videoUrl)) return;
      resetResult(); running = true; const token = ++generation; state("analyzing"); processFrame(token);
    } catch (_) { if (sourceToken === sourceGeneration) state("paused"); }
    finally { startPending = false; updateControls(); }
  }
  for (const m of ["image","video","camera"]) $("mode-"+m).addEventListener("click", () => selectMode(m));
  $("video-input").addEventListener("change", event => { const file = event.target.files[0]; event.target.value = ""; chooseVideo(file); });
  $("video-choose").tabIndex = 0;
  $("video-choose").addEventListener("keydown", event => { if (event.key === "Enter" || event.key === " ") { event.preventDefault(); $("video-input").click(); } });
  $("camera-open").addEventListener("click",openCamera);
  $("live-start").addEventListener("click",startAnalysis);
  $("live-stop").addEventListener("click",() => { stopAnalysis(); if (mode === "camera") { releaseSource(); state("cameraClosed"); } updateTexts(); });
  video.addEventListener("ended", () => { if (running && mode === "video") stopAnalysis("ended"); });
  video.addEventListener("loadeddata",updateControls);
  window.addEventListener("pagehide",() => { stopAnalysis(); releaseSource(); });
  new MutationObserver(updateTexts).observe(document.documentElement,{attributes:true,attributeFilter:["lang"]});
  updateTexts();
})();
