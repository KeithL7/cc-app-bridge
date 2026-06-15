// appbridge daemon — local HTTP bridge that owns a persistent PowerShell UIA worker.
// Mirrors the kimi-webbridge topology: HTTP server (this) + always-on engine (worker.ps1).
//   GET  /status   -> health
//   POST /command  -> {action, args, session} forwarded to the worker as NDJSON
import http from 'node:http';
import { spawn } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

const VERSION = '0.1.0';
const PORT = 10087;
const HOST = '127.0.0.1';

const HOME = os.homedir();
const BASE = path.join(HOME, '.appbridge');
const DAEMON_DIR = path.join(BASE, 'daemon');
const WORKER = path.join(DAEMON_DIR, 'worker.ps1');
const LOG_DIR = path.join(BASE, 'logs');
const LOG_FILE = path.join(LOG_DIR, 'daemon.log');
const PID_FILE = path.join(BASE, 'appbridge.pid');

for (const d of [BASE, LOG_DIR]) fs.mkdirSync(d, { recursive: true });

const logStream = fs.createWriteStream(LOG_FILE, { flags: 'a' });
function log(...a) {
  const line = `[${new Date().toISOString()}] ${a.join(' ')}`;
  logStream.write(line + '\n');
}

// ---- locate pwsh -----------------------------------------------------------
function resolvePwsh() {
  const candidates = [
    'C:\\Program Files\\PowerShell\\7\\pwsh.exe',
    path.join(process.env.LOCALAPPDATA || '', 'Microsoft\\WindowsApps\\pwsh.exe'),
    'C:\\Program Files\\PowerShell\\7-preview\\pwsh.exe',
  ];
  for (const c of candidates) { try { if (fs.existsSync(c)) return c; } catch {} }
  return 'pwsh'; // last resort: rely on PATH
}
const PWSH = resolvePwsh();

// ---- worker lifecycle ------------------------------------------------------
let worker = null;
let workerReady = false;
let workerPid = null;
let stdoutBuf = '';
let nextId = 1;
const pending = new Map(); // id -> {resolve, reject, timer}
let shuttingDown = false;
let fastFailCount = 0;
let lastSpawnAt = 0;
const startedAt = Date.now();

function spawnWorker() {
  if (shuttingDown) return;
  lastSpawnAt = Date.now();
  log(`spawning worker via ${PWSH}`);
  worker = spawn(PWSH, ['-NoProfile', '-NonInteractive', '-File', WORKER], {
    cwd: DAEMON_DIR,
    windowsHide: true,
    stdio: ['pipe', 'pipe', 'pipe'],
  });
  workerPid = worker.pid;
  stdoutBuf = '';

  worker.stdout.setEncoding('utf8');
  worker.stdout.on('data', (chunk) => {
    stdoutBuf += chunk;
    let nl;
    while ((nl = stdoutBuf.indexOf('\n')) >= 0) {
      const line = stdoutBuf.slice(0, nl).trim();
      stdoutBuf = stdoutBuf.slice(nl + 1);
      if (!line) continue;
      handleWorkerLine(line);
    }
  });

  worker.stderr.setEncoding('utf8');
  worker.stderr.on('data', (chunk) => {
    for (const l of chunk.split(/\r?\n/)) {
      if (l.trim()) {
        log(`worker> ${l}`);
        if (l.includes('ready (pid')) { workerReady = true; fastFailCount = 0; }
      }
    }
  });

  worker.on('exit', (code, sig) => {
    workerReady = false;
    log(`worker exited code=${code} sig=${sig}`);
    // fail all in-flight requests
    for (const [id, p] of pending) {
      clearTimeout(p.timer);
      p.reject(new Error('worker exited before responding'));
      pending.delete(id);
    }
    if (shuttingDown) return;
    if (Date.now() - lastSpawnAt < 2500) fastFailCount++; else fastFailCount = 0;
    if (fastFailCount >= 5) {
      log('worker crash-looping (5x fast fail) — not respawning. Check antivirus / logs.');
      return;
    }
    setTimeout(spawnWorker, 800);
  });

  worker.on('error', (err) => log(`worker spawn error: ${err.message}`));
}

function handleWorkerLine(line) {
  let msg;
  try { msg = JSON.parse(line); }
  catch { log(`unparseable worker line: ${line.slice(0, 200)}`); return; }
  const p = pending.get(msg.id);
  if (!p) return;
  clearTimeout(p.timer);
  pending.delete(msg.id);
  p.resolve(msg);
}

function sendCommand(action, args, session, timeoutMs = 30000) {
  return new Promise((resolve, reject) => {
    if (!worker || !worker.stdin.writable) return reject(new Error('worker not running'));
    const id = nextId++;
    const timer = setTimeout(() => {
      pending.delete(id);
      reject(new Error(`worker timed out after ${timeoutMs}ms on action '${action}'`));
    }, timeoutMs);
    pending.set(id, { resolve, reject, timer });
    const payload = JSON.stringify({ id, action, args: args || {}, session: session || 'default' });
    try { worker.stdin.write(payload + '\n'); }
    catch (e) { clearTimeout(timer); pending.delete(id); reject(e); }
  });
}

// ---- HTTP server -----------------------------------------------------------
function sendJson(res, code, obj) {
  const body = JSON.stringify(obj);
  res.writeHead(code, { 'Content-Type': 'application/json; charset=utf-8' });
  res.end(body);
}

const server = http.createServer((req, res) => {
  if (req.method === 'GET' && req.url === '/status') {
    return sendJson(res, 200, {
      running: true,
      port: PORT,
      version: VERSION,
      worker_connected: workerReady,
      worker_pid: workerPid,
      pid: process.pid,
      uptime_seconds: Math.round((Date.now() - startedAt) / 1000),
    });
  }
  if (req.method === 'POST' && req.url === '/command') {
    let body = '';
    req.on('data', (c) => { body += c; if (body.length > 50 * 1024 * 1024) req.destroy(); });
    req.on('end', async () => {
      let parsed;
      try { parsed = JSON.parse(body || '{}'); }
      catch { return sendJson(res, 400, { success: false, error: 'invalid JSON body' }); }
      const { action, args, session } = parsed;
      if (!action) return sendJson(res, 400, { success: false, error: "missing 'action'" });
      try {
        const reply = await sendCommand(action, args, session);
        if (reply.ok) sendJson(res, 200, { success: true, data: reply.data });
        else sendJson(res, 200, { success: false, error: reply.error });
      } catch (e) {
        sendJson(res, 200, { success: false, error: e.message });
      }
    });
    return;
  }
  sendJson(res, 404, { success: false, error: 'not found' });
});

server.on('error', (err) => {
  if (err.code === 'EADDRINUSE') log(`port ${PORT} already in use — another daemon running?`);
  else log(`server error: ${err.message}`);
  process.exit(1);
});

server.listen(PORT, HOST, () => {
  fs.writeFileSync(PID_FILE, String(process.pid));
  fs.writeFileSync(path.join(BASE, 'version'), VERSION);
  log(`appbridge daemon v${VERSION} listening on http://${HOST}:${PORT} (pid ${process.pid})`);
  spawnWorker();
});

function shutdown() {
  shuttingDown = true;
  log('shutting down');
  try { worker && worker.kill(); } catch {}
  try { fs.unlinkSync(PID_FILE); } catch {}
  try { server.close(); } catch {}
  setTimeout(() => process.exit(0), 200);
}
process.on('SIGTERM', shutdown);
process.on('SIGINT', shutdown);
process.on('SIGHUP', shutdown);
