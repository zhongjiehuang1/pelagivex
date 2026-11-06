"use strict";
(() => {
  const $ = id => document.getElementById(id);
  const video = $("source"), canvas = $("result"), ctx = canvas.getContext("2d"), base = new URL("./",document.baseURI);
  // Three in-flight frames by default; an explicit setting of 2 favors low-bandwidth links.
  const requestedSlots = new URL(document.baseURI).searchParams.getAll("slots");
  const maxPending = requestedSlots.length === 1 && requestedSlots[0] === "2" ? 2 : 3;
  const requestedCapture = new URL(document.baseURI).searchParams.getAll("capture");
  const requestHighCapture = requestedCapture.length === 1 && requestedCapture[0] === "120";
  let source = null, client = null, running = false, starting = false, generation = 0;
  let lastFinished = null, recentIntervals = [], cameraSetting = null, cameraReportedMax = null, lastRate = null;
  let language = "en", currentMessage = "正在打开摄像头…", currentConnection = "准备中";
  let placeholderTitle = "正在打开摄像头", placeholderDetail = "请允许浏览器使用摄像头";
  try { const saved = localStorage.getItem("pelagivex.language"); if (saved === "zh" || saved === "en") language = saved; } catch (_) {}
  const english = {
    "正在打开摄像头…":"Opening camera…", "正在打开摄像头":"Opening camera",
    "请允许浏览器使用摄像头":"Please allow camera access", "准备中":"Preparing",
    "识别已停止":"Detection stopped", "点击下方按钮重新打开摄像头":"Tap below to reopen the camera",
    "已停止":"Stopped", "识别结果与画面不匹配":"Detection result does not match the frame",
    "门框":"Gate", "正在识别":"Detecting", "加密连接":"Encrypted connection",
    "正在连接":"Connecting", "正在连接识别服务…":"Connecting to detection service…",
    "识别组件未加载":"Detection component unavailable", "识别结果异常，请重试":"Invalid detection result; try again",
    "识别服务繁忙，正在重试…":"Detection service busy; retrying…", "连接中断，请检查网络后重试":"Connection lost; check your network and retry",
    "已连接，正在接收画面…":"Connected; receiving frames…", "连接失败，请检查网络后重试":"Connection failed; check your network and retry",
    "请稍候，正在开始识别":"Please wait while detection starts", "摄像头已关闭":"Camera closed",
    "请打开摄像头":"Open the camera", "点击下方按钮，并允许浏览器使用摄像头":"Tap below and allow camera access",
    "等待摄像头授权":"Waiting for camera permission", "未连接":"Not connected"
  };
  const translate = text => language === "en" ? (english[text] || text) : text;
  const message = text => { currentMessage = text; $("status").textContent = translate(text); };
  function setConnection(label, error = false) { currentConnection = label; $("connection").textContent = translate(label); $("status-dot").dataset.error = String(error); }
  function placeholder(title, detail) {
    placeholderTitle = title; placeholderDetail = detail;
    $("placeholder-text").textContent = translate(title);
    $("placeholder-detail").textContent = translate(detail);
    $("placeholder").hidden = false; canvas.hidden = true; $("stats").hidden = true;
  }
  function renderStats() {
    if (lastRate === null) return;
    const isEnglish = language === "en", unit = isEnglish ? "fps" : "帧/秒";
    const camera = cameraSetting === null ? (isEnglish ? "Camera setting unknown" : "相机设置未知") : `${isEnglish ? "Camera setting" : "相机设置"} ${cameraSetting.toFixed(1)} ${unit}`;
    const ceiling = requestHighCapture ? (cameraReportedMax === null ? (isEnglish ? "Browser maximum unknown · " : "浏览器报告上限未知 · ") : `${isEnglish ? "Browser-reported maximum" : "浏览器报告上限"} ${cameraReportedMax.toFixed(1)} ${unit} · `) : "";
    $("stats").textContent = `${ceiling}${camera} · ${isEnglish ? "Detection" : "识别"} ${lastRate.toFixed(1)} ${unit}`;
  }
  function updateLanguage() {
    document.documentElement.lang = language === "zh" ? "zh-CN" : "en";
    document.querySelectorAll("[data-en][data-zh]").forEach(el => { el.textContent = el.dataset[language]; });
    $("language").textContent = language === "en" ? "中" : "EN";
    $("language").setAttribute("aria-label", language === "en" ? "Switch to Chinese" : "Switch to English");
    document.querySelector(".viewer").setAttribute("aria-label", language === "en" ? "Analyzed frame" : "已分析画面");
    canvas.setAttribute("aria-label", language === "en" ? "Detection frame and boxes" : "识别画面及检测框");
    $("status").textContent = translate(currentMessage); $("connection").textContent = translate(currentConnection);
    $("placeholder-text").textContent = translate(placeholderTitle); $("placeholder-detail").textContent = translate(placeholderDetail);
    renderStats();
  }
  function release() {
    const old = source; source = null;
    if (old) old.getTracks().forEach(track => track.stop());
    video.pause(); video.srcObject = null; video.removeAttribute("src"); video.load();
    // Clear the final frame when capture stops.
    canvas.width = 1; canvas.height = 1;
  }
  function refreshCameraSetting() {
    const track=source && source.getVideoTracks()[0];
    let settings={};
    try { if (track && typeof track.getSettings === "function") settings=track.getSettings(); } catch (_) {}
    cameraSetting=Number.isFinite(settings.frameRate) && settings.frameRate > 0 ? settings.frameRate : null;
    cameraReportedMax=null;
    if (requestHighCapture) {
      try {
        const capabilities=track && typeof track.getCapabilities === "function" ? track.getCapabilities() : null;
        const max=capabilities && capabilities.frameRate && capabilities.frameRate.max;
        cameraReportedMax=Number.isFinite(max) && max>0 ? max : null;
      } catch (_) {}
    }
  }
  function stop(reason = "识别已停止") {
    generation++; running = false; starting = false;
    if (client) { client.stop(); client = null; }
    release(); lastFinished = null; recentIntervals = []; cameraSetting = null; cameraReportedMax = null; lastRate = null;
    $("camera").disabled = false; $("camera").hidden = false; $("stop").hidden = true;
    placeholder(reason,"点击下方按钮重新打开摄像头"); message(reason); setConnection("已停止");
  }
  function draw(data, frame) {
    if (!data || Number(data.width) !== frame.width || Number(data.height) !== frame.height || !Array.isArray(data.detections)) throw new Error("识别结果与画面不匹配");
    canvas.width = frame.width; canvas.height = frame.height; ctx.drawImage(frame,0,0);
    const line = Math.max(2,frame.width*.004), size = Math.max(14,Math.min(30,frame.width*.026));
    ctx.lineWidth=line; ctx.font=`600 ${size}px Arial`; ctx.textBaseline="top"; ctx.lineJoin="round";
    for (const detection of data.detections) {
      if (!Array.isArray(detection.box) || detection.box.length !== 4) continue;
      const b=detection.box.map(Number); if (!b.every(Number.isFinite)) continue;
      const x1=Math.max(0,Math.min(frame.width,b[0])), y1=Math.max(0,Math.min(frame.height,b[1]));
      const x2=Math.max(0,Math.min(frame.width,b[2])), y2=Math.max(0,Math.min(frame.height,b[3]));
      if (x2<=x1 || y2<=y1) continue;
      ctx.strokeStyle="#b6ffd1"; ctx.strokeRect(x1,y1,x2-x1,y2-y1);
      const confidence=Number(detection.confidence), label=`${translate("门框")} ${Number.isFinite(confidence)?(Math.max(0,Math.min(1,confidence))*100).toFixed(1)+"%":""}`;
      const x=Math.max(2,Math.min(x1+4,frame.width-ctx.measureText(label).width-4));
      const y=Math.max(2,Math.min(y1+4,frame.height-size-4));
      ctx.lineWidth=Math.max(3,size*.18); ctx.strokeStyle="#0a201c"; ctx.strokeText(label,x,y); ctx.fillStyle="#edfff4"; ctx.fillText(label,x,y); ctx.lineWidth=line;
    }
    $("placeholder").hidden = true; canvas.hidden = false;
    const now = performance.now();
    if (lastFinished !== null) {
      const delta=now-lastFinished;
      if(delta>0){recentIntervals.push(delta);if(recentIntervals.length>10)recentIntervals.shift();}
    }
    lastFinished=now;
    if (recentIntervals.length) {
      const avg=recentIntervals.reduce((a,b)=>a+b,0)/recentIntervals.length;
      lastRate = 1000 / avg; renderStats();
      $("stats").hidden=false;
    }
    message("正在识别"); setConnection("加密连接");
  }
  function beginStream(token) {
    try {
      setConnection("正在连接"); message("正在连接识别服务…");
      // Keep an already-loaded old client usable during a rolling asset update.
      const StreamClient = window.PelagivexFrameDrivenClient || window.PelagivexStreamClient;
      if (typeof StreamClient !== "function") throw new Error("识别组件未加载");
      client = new StreamClient({
        video, base, maxPending,
        onResult:(data,frame)=>{if(running && token===generation) try{draw(data,frame)}catch(_){stop("识别结果异常，请重试")}},
        onMetrics:()=>{if(running && token===generation)refreshCameraSetting()},
        onBusy:()=>{if(running && token===generation)message("识别服务繁忙，正在重试…")},
        onFallback:()=>{if(running && token===generation)stop("连接中断，请检查网络后重试")}
      });
      client.start();
      if (client && client.socket) client.socket.addEventListener("open",()=>{
        if(running && token===generation){message("已连接，正在接收画面…");setConnection("加密连接");}
      });
    } catch (_) { if (running && token===generation) stop("连接失败，请检查网络后重试"); }
  }
  async function startCamera() {
    if (running || starting) return;
    const token=++generation; starting=true;
    $("camera").disabled=true; $("camera").hidden=true; $("stop").hidden=false;
    placeholder("正在打开摄像头","请允许浏览器使用摄像头"); message("正在打开摄像头…"); setConnection("准备中");
    try {
      if (!navigator.mediaDevices || !navigator.mediaDevices.getUserMedia) throw new Error("unsupported");
      const constraints={width:{ideal:1280},height:{ideal:720},facingMode:{ideal:"environment"}};
      let supportsFrameRate=true;
      try {
        if (typeof navigator.mediaDevices.getSupportedConstraints === "function")
          supportsFrameRate=navigator.mediaDevices.getSupportedConstraints().frameRate === true;
      } catch (_) { supportsFrameRate=false; }
      let incoming;
      if (requestHighCapture && supportsFrameRate) {
        try { incoming=await navigator.mediaDevices.getUserMedia({video:{...constraints,frameRate:{ideal:120}},audio:false}); }
        catch (error) {
          if (token!==generation) return;
          if (!["OverconstrainedError","TypeError"].includes(error.name)) throw error;
          incoming=await navigator.mediaDevices.getUserMedia({video:constraints,audio:false});
        }
      } else incoming=await navigator.mediaDevices.getUserMedia({video:constraints,audio:false});
      if (token!==generation) { incoming.getTracks().forEach(track=>track.stop()); return; }
      source=incoming;
      refreshCameraSetting();
      video.srcObject=incoming; video.muted=true; await video.play();
      if (token!==generation) { incoming.getTracks().forEach(track=>track.stop()); return; }
      incoming.getVideoTracks().forEach(track=>track.addEventListener("ended",()=>{if(source===incoming)stop("摄像头已关闭")},{once:true}));
      starting=false; running=true; lastFinished=null; recentIntervals=[];
      placeholder("正在连接","请稍候，正在开始识别"); beginStream(token);
    } catch (_) {
      if (token===generation) {
        starting=false; running=false; release();
        $("camera").hidden=false; $("camera").disabled=false; $("stop").hidden=true;
        placeholder("请打开摄像头","点击下方按钮，并允许浏览器使用摄像头");
        message("等待摄像头授权"); setConnection("未连接",true);
      }
    }
  }
  $("language").addEventListener("click", () => {
    language = language === "en" ? "zh" : "en";
    try { localStorage.setItem("pelagivex.language", language); } catch (_) {}
    updateLanguage();
  });
  updateLanguage();
  $("camera").addEventListener("click",startCamera);
  $("stop").addEventListener("click",()=>stop());
  window.addEventListener("pagehide",()=>stop());
  startCamera();
})();
