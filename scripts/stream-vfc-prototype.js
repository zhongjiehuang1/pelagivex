"use strict";
/* Experimental standalone client. Not loaded by the production page.
 * Server protocol: token-prefixed api/stream, binary [u64 BE id][JPEG],
 * JSON result/dropped/error messages. Does not retain frames after completion.
 */
(() => {
  class PelagivexFrameDrivenClient {
    constructor({video, base, wsUrl = "api/stream", onResult, onFallback, onBusy = () => {}, onMetrics = () => {}, maxPending = 2}) {
      if (!video || typeof onResult !== "function" || typeof onFallback !== "function") throw new TypeError("Missing stream callbacks");
      this.video = video;
      const page = new URL(base, document.baseURI);
      this.base = new URL(wsUrl, page);
      if (this.base.host !== page.host || !["http:","https:"].includes(page.protocol)) throw new TypeError("Stream must use the page origin");
      if (page.protocol === "https:" && ["https:","wss:"].includes(this.base.protocol)) this.base.protocol = "wss:";
      else if (page.protocol === "http:" && ["http:","ws:"].includes(this.base.protocol)) this.base.protocol = "ws:";
      else throw new TypeError("Stream must use the page origin");
      this.onResult = onResult; this.onFallback = onFallback; this.onBusy = onBusy; this.onMetrics = onMetrics;
      this.maxPending = Number.isFinite(maxPending) ? Math.max(1, Math.min(3, Math.floor(maxPending))) : 2;
      this.pending = new Map(); this.lastDisplayed = 0; this.nextId = 1;
      this.active = false; this.encoding = false; this.pumpTimer = null; this.openTimer = null;
      this.socket = null; this.epoch = 0; this.resumeAt = 0;
      this.frameHandle = null; this.metricsTimer = null; this.watchdog = null; this.driverEpoch = 0; this.lastCallbackAt = null; this.lastSourceIndex = null; this.lastMediaTime = null;
      this.driver = typeof video.requestVideoFrameCallback === "function" ? "video-compositor" : "animation-time-approximate";
      this.metrics = {videoFramesObserved:0,callbackMisses:0,captured:0,backpressureSkipped:0,duplicates:0,sent:0,results:0,dropped:0,displayed:0};
      this.onPageHide = () => {
        const media = this.video.srcObject;
        this.stop();
        if (media && typeof media.getTracks === "function") media.getTracks().forEach(track => track.stop());
      };
    }
    start() {
      if (this.active) return;
      this.active = true; const epoch = ++this.epoch;
      window.addEventListener("pagehide", this.onPageHide);
      try { this.socket = new WebSocket(this.base.href); }
      catch (err) { this.fallback(err); return; }
      const socket = this.socket;
      this.openTimer = setTimeout(() => { if (this.active && socket.readyState !== WebSocket.OPEN) this.fallback(new Error("Stream connection timeout")); }, 5000);
      socket.addEventListener("open", () => {
        if (!this.active || epoch !== this.epoch) return;
        clearTimeout(this.openTimer); this.openTimer = null;
        this.metricsTimer = setInterval(() => { try { this.onMetrics({...this.metrics,driver:this.driver}); } catch (_) {} }, 1000);
        this.lastCallbackAt = performance.now();
        this.watchdog = setInterval(() => {
          if (!this.active || this.driver !== "video-compositor" || this.video.paused || this.video.ended) return;
          if (performance.now() - this.lastCallbackAt < 1500) return;
          if (this.frameHandle !== null && typeof this.video.cancelVideoFrameCallback === "function") this.video.cancelVideoFrameCallback(this.frameHandle);
          this.frameHandle = null; this.driverEpoch++; this.driver = "animation-time-approximate"; this.lastMediaTime = null;
          this.requestNextFrame();
        }, 500);
        this.requestNextFrame();
      });
      socket.addEventListener("message", event => { if (this.active && epoch === this.epoch) this.receive(event); });
      socket.addEventListener("error", () => { if (this.active && epoch === this.epoch) this.fallback(new Error("Stream connection error")); });
      socket.addEventListener("close", () => { if (this.active && epoch === this.epoch) this.fallback(new Error("Stream disconnected")); });
    }
    requestNextFrame() {
      if (!this.active || this.frameHandle !== null) return;
      const epoch=this.epoch, driverEpoch=this.driverEpoch;
      if (this.driver === "video-compositor") {
        this.frameHandle = this.video.requestVideoFrameCallback((now,meta) => {
          if(!this.active || epoch!==this.epoch || driverEpoch!==this.driverEpoch)return;
          this.frameHandle = null; this.videoFrame(now,meta);
        });
      } else {
        this.frameHandle = requestAnimationFrame(now => {
          if(!this.active || epoch!==this.epoch || driverEpoch!==this.driverEpoch)return;
          this.frameHandle = null; this.videoFrame(now,{mediaTime:this.video.currentTime});
        });
      }
    }
    videoFrame(now, metadata) {
      if (!this.active) return;
      this.lastCallbackAt = performance.now();
      // Register again first; no captured-frame queue is created.
      this.requestNextFrame();
      const video=this.video;
      if(video.paused||video.ended||video.readyState<2||!video.videoWidth||!video.videoHeight)return;
      let sourceIndex=null;
      if(this.driver === "video-compositor" && Number.isSafeInteger(metadata.presentedFrames)) {
        sourceIndex=metadata.presentedFrames;
        if(this.lastSourceIndex!==null && sourceIndex<=this.lastSourceIndex){this.metrics.duplicates++;return;}
        const delta=this.lastSourceIndex===null?1:sourceIndex-this.lastSourceIndex;
        this.metrics.videoFramesObserved+=delta;
        this.metrics.callbackMisses+=Math.max(0,delta-1);
        this.lastSourceIndex=sourceIndex;
      } else {
        const mediaTime=Number(metadata.mediaTime);
        if(!Number.isFinite(mediaTime) || mediaTime===this.lastMediaTime){this.metrics.duplicates++;return;}
        this.lastMediaTime=mediaTime; this.metrics.videoFramesObserved++;
      }
      if(!this.socket || this.socket.readyState!==WebSocket.OPEN || this.encoding || this.pending.size>=this.maxPending ||
         this.socket.bufferedAmount>1500000 || performance.now()<this.resumeAt){this.metrics.backpressureSkipped++;return;}
      this.captureFrame(sourceIndex,Number(metadata.mediaTime));
    }
    captureFrame(sourceIndex, frameTime) {
      const video=this.video;
      const fac=Math.min(1,1280/video.videoWidth,1280/video.videoHeight,Math.sqrt(1000000/(video.videoWidth*video.videoHeight)));
      const canvas=document.createElement("canvas");
      canvas.width=Math.max(1,Math.floor(video.videoWidth*fac)); canvas.height=Math.max(1,Math.floor(video.videoHeight*fac));
      const context=canvas.getContext("2d");
      if(!context){this.fallback(new Error("Canvas unavailable"));return;}
      const epoch=this.epoch,capturedAt=performance.now();
      this.encoding=true;
      try {
        context.drawImage(video,0,0,canvas.width,canvas.height);this.metrics.captured++;
        canvas.toBlob(jpeg=>{
          this.encoding=false;
          if(!this.active||epoch!==this.epoch)return;
          if(!jpeg){this.fallback(new Error("JPEG encoding failed"));return;}
          if(this.nextId>Number.MAX_SAFE_INTEGER){this.fallback(new Error("Stream frame ID exhausted"));return;}
          const id=this.nextId++,header=new ArrayBuffer(8),view=new DataView(header);
          view.setUint32(0,Math.floor(id/0x100000000),false);view.setUint32(4,id>>>0,false);
          try {
            const timeout=setTimeout(()=>{if(this.active&&this.pending.has(id))this.fallback(new Error("Stream result timeout"));},15000);
            this.pending.set(id,{canvas,frameTime,capturedAt,sourceIndex,timeout});
            this.socket.send(new Blob([header,jpeg],{type:"application/octet-stream"})); this.metrics.sent++;
          }catch(err){const frame=this.pending.get(id);if(frame)clearTimeout(frame.timeout);this.pending.delete(id);this.fallback(err);}
        },"image/jpeg",0.87);
      }catch(err){this.encoding=false;this.fallback(err);}
    }
    receive(event) {
      if (typeof event.data !== "string" || event.data.length > 2000000) { this.fallback(new Error("Invalid stream response")); return; }
      let message;
      try { message = JSON.parse(event.data); } catch (_) { this.fallback(new Error("Invalid stream response")); return; }
      if (!message || !Number.isSafeInteger(message.id) || message.id < 1 || !["result","dropped","error"].includes(message.type)) {
        this.fallback(new Error("Invalid stream message")); return;
      }
      const frame = this.pending.get(message.id);
      if (!frame) return;
      clearTimeout(frame.timeout);
      this.pending.delete(message.id);
      if (message.type === "error") {
        if (message.status === 429) { this.resumeAt = performance.now() + 1000; this.onBusy(); return; }
        this.fallback(new Error(`Stream detection failed (${message.status || "unknown"})`)); return;
      }
      if (message.type === "dropped") this.metrics.dropped++;
      if (message.type === "result") {
        const data = message.data;
        if (!data || Number(data.width) !== frame.canvas.width || Number(data.height) !== frame.canvas.height || !Array.isArray(data.detections)) {
          this.fallback(new Error("Invalid detection result")); return;
        }
        this.metrics.results++;
        if (message.id > this.lastDisplayed) {
          this.lastDisplayed = message.id; this.metrics.displayed++;
          try { this.onResult(data,frame.canvas,{id:message.id,frameTime:frame.frameTime,capturedAt:frame.capturedAt,sourceIndex:frame.sourceIndex}); }
          catch (err) { this.fallback(err); return; }
        }
      }
    }
    fallback(error) {
      if (!this.active) return;
      this.stop(); this.onFallback(error);
    }
    stop() {
      this.active = false; this.epoch++;
      if (this.frameHandle !== null) {
        if(this.driver === "video-compositor" && typeof this.video.cancelVideoFrameCallback === "function")this.video.cancelVideoFrameCallback(this.frameHandle);
        else if(this.driver !== "video-compositor")cancelAnimationFrame(this.frameHandle);
      }
      this.frameHandle=null;
      if(this.metricsTimer!==null)clearInterval(this.metricsTimer);
      if(this.watchdog!==null)clearInterval(this.watchdog);
      this.metricsTimer=null; this.watchdog=null;
      if (this.pumpTimer !== null) clearTimeout(this.pumpTimer);
      if (this.openTimer !== null) clearTimeout(this.openTimer);
      this.pumpTimer = null; this.openTimer = null; this.encoding = false;
      for (const frame of this.pending.values()) clearTimeout(frame.timeout);
      this.pending.clear(); this.resumeAt = 0;
      if (this.socket) { try { this.socket.close(); } catch (_) {} }
      this.socket = null;
      window.removeEventListener("pagehide",this.onPageHide);
    }
  }
  window.PelagivexFrameDrivenClient = PelagivexFrameDrivenClient;
})();
