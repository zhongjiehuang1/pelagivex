# Pelagivex

Pelagivex is a research prototype for detecting underwater competition gates in photographs and sampled video or camera frames. A Java web application uses an RF-DETR Nano model fine-tuned on underwater images. The application is independent of Project Trident and does not control a vehicle.

## Use

Choose a JPEG or PNG image, then select **Detect gate**. An optional example is a simulated image, clearly labelled in the interface. The browser accepts JPEG or PNG files up to 20 MiB and 40 million pixels, then locally scales larger images to at most 4 million pixels and 4,000 pixels per side before upload. The server accepts at most 8 MiB and processes one inference request at a time.

For continuous analysis, choose **Video** or **Camera**, select a video or grant camera permission, and start analysis. Keep the page open while analysing. The browser sends individual resized JPEG frames to the server; it does not upload the full video or audio. Only one request is in flight at a time: the next available frame is captured as soon as the previous request finishes, without building a queue. The analysed frame is shown separately from the live input. Actual throughput depends on the server and network; it is not guaranteed to match the source frame rate. Stopping, changing mode, or closing the page ends analysis and releases the camera.

## Components

- `web/`: bilingual static interface and the credited synthetic example.
- `src/main/java/`: Java 21, Servlet 4, and ONNX Runtime inference API for Tomcat 9.
- `scripts/`: dataset preparation, model training, evaluation, and export tools.
- `model/gate-v2.onnx`: selected trained model artifact (distributed separately as a release asset).
- `data/`, `runs/`, `.venv-model/` and `.cache/`: local research data, checkpoints, environment and caches; excluded from Git.

The application is unavailable until `model/gate-v2.onnx` is supplied. The selected model is distributed in the [prototype model release](https://github.com/zhjpersonal83-cell/pelagivex/releases/tag/v0.1.0); its SHA-256 is `48b7e5f293a0fd1be254cf6565dad1c0e3453bfb45384b0ff8e619a7c5146381`. The server defaults to `/opt/pelagivex/model/gate.onnx`; for local runs configure `-Dpelagivex.model.path=/absolute/path/to/gate-v2.onnx`.

## Data and attribution

- Model architecture and initial weights: [RF-DETR](https://github.com/roboflow/rf-detr), Apache 2.0, Nano version.
- Training data: [SAUVC Dataset by mo_bilal14](https://www.kaggle.com/datasets/mobilal14/sauvc-dataset), whose listing states MIT. The original image ownership and licence chain have not been independently verified. The training images are not redistributed here.
- Example image: [jack-www/sauvc-v1](https://huggingface.co/datasets/jack-www/sauvc-v1), listed as MIT. The image is a simulated scene, converted from PNG to JPEG. It is not a real underwater photograph.

The training source's original video/scene grouping is unknown, and near-duplicate frames were found across its supplied splits. Performance on that test split cannot establish performance in new pools, waters, cameras, or RoboSub tasks. This prototype is for research and demonstration, not autonomous vehicle control.

## Build

Use Maven and a JDK capable of compiling Java 21. `mvn test` runs backend checks and `mvn package` produces `target/Pelagivex.war`. Tomcat 9 provides Servlet 4. Use the model artifact above; a missing or incompatible model makes `/api/health` and detection unavailable rather than generating simulated detections.

## Server deployment

The public Nginx site serves the interface from `/opt/pelagivex/site-v2` and proxies `/api/` to the existing Tomcat application. The model remains at `/opt/pelagivex/model/gate.onnx`. When publishing interface changes, update the Nginx-served static files as well as the source; updating only the WAR does not update the public interface. Validate Nginx configuration before reloading it.

## Private Mac mobile demo

`scripts/start_wss_demo.sh` runs the existing FP32 gate model on the Mac (CoreML with CPU execution for unsupported operations), a token-protected local WebSocket site, and an SSH reverse tunnel when a compatible HTTPS `/mac-ws/` route has been configured. The model and inference remain on the Mac; image frames travel through the HTTPS server and encrypted SSH tunnel. The single-window camera page requests permission and starts automatically where the browser allows it; otherwise the user can tap the camera button. It displays the actual analysed frame and its matching detections. The browser keeps at most three frames in flight, the local backend allows up to four simultaneous inferences, and the stream service retains at most one newer waiting frame. The `?slots=2` parameter selects the lower-bandwidth option. `?capture=120` requests a 120 fps camera setting where the browser supports it and shows the browser-reported limit, actual selected setting and measured detection rate separately; it does not guarantee 120 fps.

Run `bash scripts/start_wss_demo.sh` in a Mac Terminal. Enter the server password only in the SSH prompt; the script does not save it. A fresh secret URL is printed after HTTPS and WSS handshake checks; anyone with that URL can access the demo. Keep the Terminal running and the Mac awake; Ctrl-C stops only that run's backend, WSS server and tunnel and deletes its temporary token. Existing local or remote port use causes a safe failure instead of replacing another service. The previous public tunnel and its server route are currently removed; this script cannot publish an endpoint until an appropriate route is deliberately configured again. The setup also depends on a known SSH host key.

The project virtual environment must contain `websockets==15.0.1` and `certifi` (see `scripts/requirements-wss.txt`); the existing Java runtime, compiled project and model are also required. CoreML and CPU outputs can differ slightly; test results on a limited image set do not establish identical predictions in every scene.
