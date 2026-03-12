const http = require("http");
const fs = require("fs");
const path = require("path");
const { execSync, exec } = require("child_process");
const { WebSocketServer } = require("ws");
const OBSWebSocket = require("obs-websocket-js").default;

// --- Config ---

const HTTP_PORT = parseInt(process.env.PORT || "8080", 10);
const OBS_WS_URL = process.env.OBS_WS_URL || "ws://127.0.0.1:4455";
const OBS_WS_PASSWORD = process.env.OBS_WS_PASSWORD || undefined;

// --- State ---

const obs = new OBSWebSocket();
let obsConnected = false;
let obsRunning = false;
let replayBufferActive = false;
const clients = new Set();

// --- OBS Connection ---

async function connectOBS() {
  if (obsConnected) return true;
  try {
    await obs.connect(OBS_WS_URL, OBS_WS_PASSWORD);
    obsConnected = true;
    console.log("Connected to OBS WebSocket");
    return true;
  } catch (err) {
    console.log("OBS WebSocket connect failed:", err.message);
    obsConnected = false;
    return false;
  }
}

obs.on("ConnectionClosed", () => {
  console.log("OBS WebSocket disconnected");
  obsConnected = false;
  replayBufferActive = false;
  broadcast();
});

obs.on("ReplayBufferStateChanged", (data) => {
  replayBufferActive = data.outputActive;
  broadcast();
});

obs.on("ReplayBufferSaved", () => {
  broadcastEvent("replaySaved");
});

// --- OBS Helpers ---

function isOBSRunning() {
  try {
    execSync("pgrep -x obs", { stdio: "ignore" });
    return true;
  } catch {
    return false;
  }
}

function launchOBS() {
  return new Promise((resolve) => {
    exec('open -a "OBS"', (err) => {
      if (err) {
        console.log("Failed to launch OBS:", err.message);
        resolve(false);
      } else {
        resolve(true);
      }
    });
  });
}

async function refreshStatus() {
  obsRunning = isOBSRunning();
  if (obsRunning && !obsConnected) {
    await connectOBS();
  }
  if (obsConnected) {
    try {
      const resp = await obs.call("GetReplayBufferStatus");
      replayBufferActive = resp.outputActive;
    } catch {
      replayBufferActive = false;
    }
  } else {
    replayBufferActive = false;
  }
}

// --- WebSocket broadcast to browser clients ---

function getStatus() {
  return JSON.stringify({
    type: "status",
    obsRunning,
    obsConnected,
    replayBufferActive,
  });
}

function broadcast() {
  const msg = getStatus();
  for (const ws of clients) {
    if (ws.readyState === 1) ws.send(msg);
  }
}

function broadcastEvent(event, data) {
  const msg = JSON.stringify({ type: "event", event, ...data });
  for (const ws of clients) {
    if (ws.readyState === 1) ws.send(msg);
  }
}

function sendResult(ws, id, success, message) {
  ws.send(JSON.stringify({ type: "result", id, success, message }));
}

// --- Command handler ---

async function handleCommand(ws, msg) {
  let parsed;
  try {
    parsed = JSON.parse(msg);
  } catch {
    return;
  }
  const { command, id } = parsed;

  switch (command) {
    case "launchOBS": {
      if (isOBSRunning()) {
        obsRunning = true;
        await connectOBS();
        sendResult(ws, id, true, "OBS already running");
      } else {
        const ok = await launchOBS();
        if (ok) {
          obsRunning = true;
          // Wait for OBS to initialize its WebSocket server
          await new Promise((r) => setTimeout(r, 3000));
          await connectOBS();
          sendResult(ws, id, true, "OBS launched");
        } else {
          sendResult(ws, id, false, "Failed to launch OBS");
        }
      }
      await refreshStatus();
      broadcast();
      break;
    }

    case "startReplayBuffer": {
      if (!obsConnected && !(await connectOBS())) {
        sendResult(ws, id, false, "Not connected to OBS");
        break;
      }
      try {
        await obs.call("StartReplayBuffer");
        replayBufferActive = true;
        sendResult(ws, id, true, "Replay buffer started");
      } catch (err) {
        sendResult(ws, id, false, err.message);
      }
      broadcast();
      break;
    }

    case "stopReplayBuffer": {
      if (!obsConnected) {
        sendResult(ws, id, false, "Not connected to OBS");
        break;
      }
      try {
        await obs.call("StopReplayBuffer");
        replayBufferActive = false;
        sendResult(ws, id, true, "Replay buffer stopped");
      } catch (err) {
        sendResult(ws, id, false, err.message);
      }
      broadcast();
      break;
    }

    case "saveReplay": {
      if (!obsConnected) {
        sendResult(ws, id, false, "Not connected to OBS");
        break;
      }
      try {
        await obs.call("SaveReplayBuffer");
        sendResult(ws, id, true, "Replay saved!");
      } catch (err) {
        sendResult(ws, id, false, err.message);
      }
      break;
    }

    case "getStatus": {
      await refreshStatus();
      ws.send(getStatus());
      break;
    }
  }
}

// --- HTTP server ---

const MIME = {
  ".html": "text/html",
  ".css": "text/css",
  ".js": "application/javascript",
  ".json": "application/json",
  ".png": "image/png",
  ".svg": "image/svg+xml",
};

const httpServer = http.createServer((req, res) => {
  let filePath =
    req.url === "/" ? "/index.html" : req.url.split("?")[0];
  filePath = path.join(__dirname, "public", filePath);

  const ext = path.extname(filePath);
  const contentType = MIME[ext] || "application/octet-stream";

  fs.readFile(filePath, (err, data) => {
    if (err) {
      res.writeHead(404);
      res.end("Not found");
    } else {
      res.writeHead(200, { "Content-Type": contentType });
      res.end(data);
    }
  });
});

// --- WebSocket server (browser clients) ---

const wss = new WebSocketServer({ server: httpServer });

wss.on("connection", (ws) => {
  clients.add(ws);
  console.log("Client connected (" + clients.size + " total)");
  ws.send(getStatus());

  ws.on("message", (data) => handleCommand(ws, data.toString()));
  ws.on("close", () => {
    clients.delete(ws);
    console.log("Client disconnected (" + clients.size + " total)");
  });
});

// --- Start ---

httpServer.listen(HTTP_PORT, "0.0.0.0", async () => {
  const nets = require("os").networkInterfaces();
  const addresses = Object.values(nets)
    .flat()
    .filter((i) => i.family === "IPv4" && !i.internal)
    .map((i) => i.address);

  console.log("=================================");
  console.log("  OBS Remote Server");
  console.log("=================================");
  console.log("");
  console.log("  Open on your phone:");
  for (const addr of addresses) {
    console.log(`    http://${addr}:${HTTP_PORT}`);
  }
  console.log("");
  console.log(`  OBS WebSocket: ${OBS_WS_URL}`);
  console.log("=================================");

  await refreshStatus();
  if (obsRunning) console.log("OBS is running, connected:", obsConnected);
});

// Poll status every 10s to catch external changes
setInterval(async () => {
  const wasBefore = obsRunning;
  const wasBufBefore = replayBufferActive;
  await refreshStatus();
  if (obsRunning !== wasBefore || replayBufferActive !== wasBufBefore) {
    broadcast();
  }
}, 10000);
