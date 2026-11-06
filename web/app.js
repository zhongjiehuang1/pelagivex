"use strict";

(() => {
  const $ = id => document.getElementById(id);
  const base = new URL("./", document.baseURI);
  const strings = {
    zh: {
      workspace:"水下视觉 · UNDERWATER VISION", eyebrow:"水下视觉实验室", headlineA:"让水下目标，", headlineB:"清晰可见。", intro:"使用图片、视频或摄像头，识别水下比赛门框。", introNote:"为探索而设计\n从一张图片开始", workTitle:"识别工作台", checking:"正在连接模型", ready:"模型已就绪", unavailable:"模型暂不可用", dropTitle:"将图片拖到这里", dropCopy:"或点击选择水下图片", stageFooter:"JPG、PNG · 20 MB 以内，大图在本地缩小", panelTitle:"开始识别", panelDescription:"实验模型，仅识别水下门框；低光或遮挡可能造成漏检。", choose:"选择图片", replace:"更换图片", detect:"开始识别", detecting:"识别中…", sample:"试用仿真示例图", sampleSource:"仿真图来源：", results:"识别结果", resultsEmpty:"结果会显示在这里", resultNote:"置信度反映模型的判断，不代表结果一定正确。", panelFoot:"一次识别，一次探索", focusTitle:"专注水下门框", focusCopy:"针对水下机器人视觉任务的原型。", outputTitle:"结果一目了然", outputCopy:"查看检测位置、置信度与处理时间。", purposeTitle:"为探索而构建", purposeCopy:"研究演示，不用于控制真实机器人。", footerText:"水下视觉原型", processing:"正在识别图片", preparing:"正在本地处理图片", resizedNote:"已在浏览器处理，识别时上传处理后的图片。", noDetections:"未检测到目标", found:"检测到 {n} 个目标", time:"处理时间 {time}", seconds:"秒", ms:"毫秒", invalidType:"请选择 JPG 或 PNG 图片。", tooLarge:"图片过大，请选择不超过 20 MB 的图片。", dimensions:"图片尺寸过大，最多支持 4000 万像素、单边不超过 20000 像素。", processingError:"图片处理失败，请尝试其他图片。", invalidImage:"无法读取这张图片，请尝试其他文件。", serverError:"识别失败，请稍后重试。", connectionError:"无法连接模型服务，请稍后重试。", unavailableError:"模型当前不可用，请稍后重试。", sampleError:"示例图片暂时不可用。", gate:"门框", boxLabel:"门框", chooseAria:"选择图片", langAria:"Switch to English", previewAlt:"待识别的水下图片", overlayAria:"模型识别结果"
    },
    en: {
      workspace:"UNDERWATER VISION", eyebrow:"UNDERWATER VISION LAB", headlineA:"See more", headlineB:"beneath the surface.", intro:"Detect underwater gates in images, video or camera footage.", introNote:"MADE FOR EXPLORATION\nSTART WITH AN IMAGE", workTitle:"Detection workspace", checking:"Connecting to model", ready:"Model ready", unavailable:"Model unavailable", dropTitle:"Drop an image here", dropCopy:"or click to choose an underwater image", stageFooter:"JPG / PNG · 20 MB max · larger images resized locally", panelTitle:"Start detecting", panelDescription:"Experimental model for underwater gates only; low light or occlusion may cause missed detections.", choose:"Choose image", replace:"Change image", detect:"Detect gate", detecting:"Detecting…", sample:"Try simulated sample", sampleSource:"Simulated image: ", results:"Detection results", resultsEmpty:"Results will appear here", resultNote:"Confidence reflects the model's estimate, not a guarantee.", panelFoot:"One image, one discovery", focusTitle:"Focused on gates", focusCopy:"A prototype for underwater robotics vision.", outputTitle:"See the details", outputCopy:"View detected locations, confidence and processing time.", purposeTitle:"Built to explore", purposeCopy:"Research demonstration; not for controlling a real robot.", footerText:"UNDERWATER VISION PROTOTYPE", processing:"Analyzing image", preparing:"Preparing image locally", resizedNote:"Prepared in your browser; the processed image is uploaded for detection.", noDetections:"No gate detected", found:"{n} detection(s)", time:"Processed in {time}", seconds:"s", ms:"ms", invalidType:"Please choose a JPG or PNG image.", tooLarge:"Image is too large. Choose a file up to 20 MB.", dimensions:"Image dimensions exceed 40 megapixels or 20000 pixels per side.", processingError:"Image processing failed. Please try a different image.", invalidImage:"This image could not be read. Try another file.", serverError:"Detection failed. Please try again.", connectionError:"Cannot connect to the model service. Please try again.", unavailableError:"The model is currently unavailable. Please try again later.", sampleError:"The example image is unavailable.", gate:"Gate", boxLabel:"Gate", chooseAria:"Choose image", langAria:"切换为中文", previewAlt:"Underwater image to analyze", overlayAria:"Model detections"
    }
  };
  const maxInputBytes = 20 * 1024 * 1024;
  const maxUploadBytes = 8 * 1024 * 1024;
  const validTypes = ["image/jpeg", "image/png"];
  const ns = "http://www.w3.org/2000/svg";
  let language = "en", selectedFile = null, objectUrl = null, currentImage = null;
  let ready = false, working = false, processingPhase = "processing", requestSerial = 0, selectionSerial = 0, activeRequest = null, lastResult = null, currentError = null;
  try { const saved = localStorage.getItem("pelagivex.language"); if (saved === "zh" || saved === "en") language = saved; } catch (_) {}
  const t = key => strings[language][key] || key;
  const format = (str, values) => str.replace(/\{(\w+)\}/g, (_, key) => String(values[key] ?? ""));
  const apiUrl = path => new URL(path, base);

  function updateLanguage() {
    document.documentElement.lang = language === "zh" ? "zh-CN" : "en";
    document.querySelectorAll("[data-i18n]").forEach(element => { element.textContent = t(element.dataset.i18n); });
    $("language").innerHTML = language === "zh" ? 'EN <span aria-hidden="true">↗</span>' : '中 <span aria-hidden="true">↗</span>';
    $("language").setAttribute("aria-label", t("langAria"));
    $("preview").alt = t("previewAlt");
    $("overlay").setAttribute("aria-label", t("overlayAria"));
    $("choose-label").querySelector("span").textContent = t(selectedFile ? "replace" : "choose");
    $("detect").querySelector("span").textContent = t(working ? (processingPhase === "preparing" ? "preparing" : "detecting") : "detect");
    $("busy").querySelector("span[data-i18n]").textContent = t(processingPhase);
    updateStatus();
    if (currentError) showError(currentError.key, currentError.detail);
    if (lastResult) renderResult(lastResult);
  }

  function updateStatus(state) {
    if (state) $("status").dataset.state = state;
    const current = $("status").dataset.state || "checking";
    $("status-text").textContent = t(current === "ready" ? "ready" : current === "error" ? "unavailable" : "checking");
  }

  function setWorking(value, phase = "processing") {
    working = value;
    processingPhase = phase;
    $("busy").querySelector("span[data-i18n]").textContent = t(phase);
    $("busy").hidden = !value;
    $("detect").disabled = value || !selectedFile || !ready;
    $("detect").querySelector("span").textContent = t(value ? (phase === "preparing" ? "preparing" : "detecting") : "detect");
    $("stage").setAttribute("aria-busy", String(value));
  }

  function showError(key, detail = "") {
    currentError = {key, detail};
    const text = detail || t(key);
    $("error").textContent = text;
    $("error").hidden = false;
  }
  function clearError() { currentError = null; $("error").hidden = true; $("error").textContent = ""; }
  function resetResults() {
    lastResult = null;
    $("overlay").replaceChildren();
    $("empty-results").hidden = false;
    $("result-content").hidden = true;
    $("result-count").textContent = "—";
    $("detection-list").replaceChildren();
    clearError();
  }

  // Read dimensions before asking the browser to decode the image, so a
  // malformed or extremely large image cannot allocate an unbounded canvas.
  async function inspectImage(file) {
    const buffer = await file.arrayBuffer();
    const bytes = new Uint8Array(buffer), view = new DataView(buffer);
    const png = [137,80,78,71,13,10,26,10];
    if (file.type === "image/png") {
      if (bytes.length < 24 || !png.every((b, i) => bytes[i] === b) || String.fromCharCode(...bytes.slice(12, 16)) !== "IHDR") throw Error("invalidImage");
      return {width:view.getUint32(16), height:view.getUint32(20), orientation:1, buffer};
    }
    if (bytes.length < 4 || bytes[0] !== 0xff || bytes[1] !== 0xd8) throw Error("invalidImage");
    let pos = 2, width = 0, height = 0, orientation = 1, exifStart = -1, exifEnd = -1;
    const sof = new Set([0xc0,0xc1,0xc2,0xc3,0xc5,0xc6,0xc7,0xc9,0xca,0xcb,0xcd,0xce,0xcf]);
    while (pos + 3 < bytes.length) {
      const start = pos;
      if (bytes[pos++] !== 0xff) throw Error("invalidImage");
      while (pos < bytes.length && bytes[pos] === 0xff) pos++;
      const marker = bytes[pos++];
      if (marker === 0xda || marker === 0xd9) break;
      if (marker === 0xd8 || marker === 0x01 || (marker >= 0xd0 && marker <= 0xd7)) continue;
      if (pos + 2 > bytes.length) throw Error("invalidImage");
      const length = view.getUint16(pos), end = pos + length;
      if (length < 2 || end > bytes.length) throw Error("invalidImage");
      if (sof.has(marker)) {
        if (length < 8) throw Error("invalidImage");
        height = view.getUint16(pos + 3); width = view.getUint16(pos + 5);
      }
      // Store the EXIF segment so it can be removed before decoding and the
      // orientation applied exactly once, consistently across browsers.
      if (marker === 0xe1 && length >= 16 && String.fromCharCode(...bytes.slice(pos + 2, pos + 8)) === "Exif\0\0") {
        const tiff = pos + 8, little = bytes[tiff] === 0x49 && bytes[tiff + 1] === 0x49;
        const big = bytes[tiff] === 0x4d && bytes[tiff + 1] === 0x4d;
        if ((little || big) && tiff + 8 <= end && view.getUint16(tiff + 2, little) === 42) {
          const ifd = tiff + view.getUint32(tiff + 4, little);
          if (ifd + 2 <= end) {
            const count = view.getUint16(ifd, little);
            for (let i = 0; i < count && ifd + 2 + i * 12 + 12 <= end; i++) {
              const entry = ifd + 2 + i * 12;
              if (view.getUint16(entry, little) === 0x0112 && view.getUint16(entry + 2, little) === 3 && view.getUint32(entry + 4, little) === 1) {
                const value = view.getUint16(entry + 8, little);
                if (value >= 2 && value <= 8) { orientation = value; exifStart = start; exifEnd = end; }
                break;
              }
            }
          }
        }
      }
      pos = end;
    }
    if (!width || !height) throw Error("invalidImage");
    return {width, height, orientation, exifStart, exifEnd, buffer};
  }

  function encodeCanvas(canvas, type) {
    return new Promise((resolve, reject) => {
      try { canvas.toBlob(blob => blob && blob.type === type ? resolve(blob) : reject(Error("processingError")), type, 0.92); }
      catch (_) { reject(Error("processingError")); }
    });
  }

  async function prepareImage(file, info, selection) {
    const rotated = info.orientation >= 5;
    const orientedWidth = rotated ? info.height : info.width;
    const orientedHeight = rotated ? info.width : info.height;
    let scale = Math.min(1, 4000 / orientedWidth, 4000 / orientedHeight, Math.sqrt(4000000 / (orientedWidth * orientedHeight)));
    const mustProcess = scale < 1 || file.size > maxUploadBytes || info.orientation !== 1;
    if (!mustProcess) return {file, width:orientedWidth, height:orientedHeight, processed:false};
    let source = file;
    if (info.orientation !== 1 && info.exifStart >= 0) {
      source = new Blob([info.buffer.slice(0, info.exifStart), info.buffer.slice(info.exifEnd)], {type:file.type});
    }
    const sourceUrl = URL.createObjectURL(source);
    const image = new Image();
    try {
      await new Promise((resolve, reject) => { image.onload = resolve; image.onerror = reject; image.src = sourceUrl; });
      if (image.naturalWidth !== info.width || image.naturalHeight !== info.height) throw Error("processingError");
      for (let attempt = 0; attempt < 8; attempt++) {
        if (selection !== selectionSerial) throw Error("superseded");
        const drawWidth = Math.max(1, Math.floor(info.width * scale));
        const drawHeight = Math.max(1, Math.floor(info.height * scale));
        const canvas = document.createElement("canvas");
        canvas.width = rotated ? drawHeight : drawWidth;
        canvas.height = rotated ? drawWidth : drawHeight;
        const context = canvas.getContext("2d");
        if (!context) throw Error("processingError");
        const w = drawWidth, h = drawHeight;
        switch (info.orientation) {
          case 2: context.transform(-1, 0, 0, 1, w, 0); break;
          case 3: context.transform(-1, 0, 0, -1, w, h); break;
          case 4: context.transform(1, 0, 0, -1, 0, h); break;
          case 5: context.transform(0, 1, 1, 0, 0, 0); break;
          case 6: context.transform(0, 1, -1, 0, h, 0); break;
          case 7: context.transform(0, -1, -1, 0, h, w); break;
          case 8: context.transform(0, -1, 1, 0, 0, w); break;
        }
        context.drawImage(image, 0, 0, drawWidth, drawHeight);
        const blob = await encodeCanvas(canvas, file.type);
        const width = canvas.width, height = canvas.height;
        canvas.width = 0; canvas.height = 0;
        if (blob.size <= maxUploadBytes) return {file:new File([blob], file.name, {type:file.type}), width, height, processed:true};
        scale *= 0.8;
      }
      throw Error("processingError");
    } finally { URL.revokeObjectURL(sourceUrl); }
  }

  async function selectFile(file) {
    if (!file) return;
    const selection = ++selectionSerial;
    requestSerial++;
    if (activeRequest) { activeRequest.abort(); activeRequest = null; }
    setWorking(false); clearError();
    if (!validTypes.includes(file.type)) { showError("invalidType"); return; }
    if (file.size > maxInputBytes) { showError("tooLarge"); return; }
    setWorking(true, "preparing");
    try {
      const info = await inspectImage(file);
      if (selection !== selectionSerial) return;
      if (!info.width || !info.height || info.width > 20000 || info.height > 20000 || info.width * info.height > 40000000) throw Error("dimensions");
      const prepared = await prepareImage(file, info, selection);
      if (selection !== selectionSerial) return;
      const newUrl = URL.createObjectURL(prepared.file);
      const preview = new Image();
      try { await new Promise((resolve, reject) => { preview.onload = resolve; preview.onerror = reject; preview.src = newUrl; }); }
      catch (_) { URL.revokeObjectURL(newUrl); throw Error("invalidImage"); }
      if (selection !== selectionSerial) { URL.revokeObjectURL(newUrl); return; }
      if (preview.naturalWidth !== prepared.width || preview.naturalHeight !== prepared.height) { URL.revokeObjectURL(newUrl); throw Error("processingError"); }
      if (objectUrl) URL.revokeObjectURL(objectUrl);
      objectUrl = newUrl; selectedFile = prepared.file;
      currentImage = {width:prepared.width, height:prepared.height};
      $("preview").src = objectUrl;
      $("file-name").textContent = file.name;
      $("image-size").textContent = `${currentImage.width} × ${currentImage.height}`;
      $("resize-note").hidden = !prepared.processed;
      $("dropzone").hidden = true;
      $("image-view").hidden = false;
      $("choose-label").querySelector("span").textContent = t("replace");
      resetResults();
    } catch (error) {
      if (selection === selectionSerial) {
        const key = ["invalidImage", "dimensions", "processingError"].includes(error.message) ? error.message : "invalidImage";
        showError(key);
      }
    } finally { if (selection === selectionSerial) setWorking(false); }
  }

  function svgElement(tag, attrs) {
    const node = document.createElementNS(ns, tag);
    Object.entries(attrs).forEach(([key,value]) => node.setAttribute(key, String(value)));
    return node;
  }
  function displayLabel(raw) {
    const value = String(raw || "gate");
    return /^(gate|door|gate_frame|门框)$/i.test(value) ? t("gate") : value;
  }
  function renderResult(result) {
    const width = Number(result.width), height = Number(result.height);
    const detections = Array.isArray(result.detections) ? result.detections : [];
    const overlay = $("overlay");
    overlay.setAttribute("viewBox", `0 0 ${width} ${height}`);
    overlay.replaceChildren();
    const list = $("detection-list"); list.replaceChildren();
    const duration = Number(result.duration_ms);
    const formattedDuration = Number.isFinite(duration) && duration >= 0 ? (duration >= 1000 ? `${(duration/1000).toFixed(2)} ${t("seconds")}` : `${Math.round(duration)} ${t("ms")}`) : null;
    $("result-summary").textContent = (detections.length ? format(t("found"), {n:detections.length}) : t("noDetections")) + (formattedDuration ? ` · ${format(t("time"), {time:formattedDuration})}` : "");
    $("result-count").textContent = String(detections.length).padStart(2,"0");
    for (const detection of detections) {
      if (!Array.isArray(detection.box) || detection.box.length !== 4) continue;
      const values = detection.box.map(Number);
      if (!values.every(Number.isFinite)) continue;
      const [x1,y1,x2,y2] = values;
      const x = Math.max(0, Math.min(width,x1)), y = Math.max(0, Math.min(height,y1));
      const w = Math.max(0, Math.min(width,x2)-x), h = Math.max(0, Math.min(height,y2)-y);
      if (!w || !h) continue;
      const confidence = Number(detection.confidence);
      const score = Number.isFinite(confidence) ? `${(Math.max(0,Math.min(1,confidence))*100).toFixed(1)}%` : "—";
      const label = displayLabel(detection.label);
      overlay.append(svgElement("rect", {x,y,width:w,height:h}));
      // SVG coordinates are source-image pixels, not screen pixels. Keep labels
      // readable after a large image is scaled down, without overwhelming a
      // small input image. The rectangle keeps its original detection bounds.
      const fontSize = Math.min(width * 0.08, height * 0.12, Math.max(12, width * 0.026));
      const padding = fontSize * 0.18;
      const text = svgElement("text", {
        x: Math.min(width - padding, x + padding),
        y: Math.max(0, Math.min(height - fontSize, y + padding))
      });
      text.style.fontSize = `${fontSize}px`;
      text.style.strokeWidth = `${fontSize * 0.14}px`;
      text.textContent = `${label} ${score}`;
      overlay.append(text);
      const row = document.createElement("div"); row.className = "detection-row";
      const name = document.createElement("span"); name.textContent = label;
      const value = document.createElement("b"); value.textContent = score;
      row.append(name,value); list.append(row);
    }
    $("empty-results").hidden = true;
    $("result-content").hidden = false;
  }

  async function detect() {
    if (!selectedFile || !ready || working) return;
    resetResults(); setWorking(true);
    const serial = ++requestSerial;
    const form = new FormData(); form.append("image", selectedFile, selectedFile.name);
    const controller = new AbortController(); activeRequest = controller;
    try {
      const response = await fetch(apiUrl("api/detect"), {method:"POST", body:form, signal:controller.signal});
      let payload;
      try { payload = await response.json(); } catch (_) { throw new Error(t("serverError")); }
      if (!response.ok) throw new Error(typeof payload.error === "string" ? payload.error : t("serverError"));
      if (!(Number(payload.width)>0) || !(Number(payload.height)>0) || !Array.isArray(payload.detections)) throw new Error(t("serverError"));
      if (serial !== requestSerial) return;
      lastResult = payload; renderResult(payload);
    } catch (error) {
      if (serial === requestSerial) showError("serverError", error instanceof TypeError ? t("connectionError") : String(error.message || t("serverError")));
    } finally { if (serial === requestSerial) { activeRequest = null; setWorking(false); } }
  }

  async function checkHealth() {
    try {
      const response = await fetch(apiUrl("api/health"), {cache:"no-store"});
      const data = await response.json();
      ready = response.ok && data.status === "ok" && data.model && data.model.available === true;
    } catch (_) { ready = false; }
    updateStatus(ready ? "ready" : "error");
    if (!working) setWorking(false);
  }

  window.addEventListener("pelagivex:mode-change", () => { selectionSerial++; requestSerial++; if (activeRequest) { activeRequest.abort(); activeRequest = null; } setWorking(false); });

  $("language").addEventListener("click", () => { language = language === "zh" ? "en" : "zh"; try { localStorage.setItem("pelagivex.language", language); } catch (_) {} updateLanguage(); });
  $("file-input").addEventListener("change", event => { selectFile(event.target.files[0]); event.target.value = ""; });
  $("detect").addEventListener("click", detect);
  for (const id of ["dropzone", "choose-label"]) {
    const element = $(id); element.tabIndex = 0;
    element.addEventListener("keydown", event => { if (event.key === "Enter" || event.key === " ") { event.preventDefault(); $("file-input").click(); } });
  }
  for (const name of ["dragenter","dragover"]) $("stage").addEventListener(name, event => { event.preventDefault(); $("stage").classList.add("dragging"); });
  for (const name of ["dragleave","drop"]) $("stage").addEventListener(name, event => { event.preventDefault(); $("stage").classList.remove("dragging"); });
  $("stage").addEventListener("drop", event => selectFile(event.dataTransfer.files[0]));
  $("sample").addEventListener("click", async () => {
    try {
      const response = await fetch(apiUrl("assets/sample.jpg"));
      if (!response.ok || !(response.headers.get("content-type") || "").startsWith("image/")) throw new Error();
      const blob = await response.blob();
      await selectFile(new File([blob], "pelagivex-sample.jpg", {type:blob.type}));
    } catch (_) { showError("sampleError"); }
  });
  fetch(apiUrl("assets/sample.jpg"), {method:"HEAD"}).then(response => { if (response.ok && (response.headers.get("content-type") || "").startsWith("image/")) { $("sample").hidden = false; $("sample-credit").hidden = false; } }).catch(() => {});
  updateLanguage();
  checkHealth();
})();
