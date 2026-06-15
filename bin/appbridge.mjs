#!/usr/bin/env node
// appbridge CLI — lifecycle control for the local desktop-automation daemon.
// Usage: node appbridge.mjs <status|start|stop|restart|logs [-n N]>
import http from 'node:http';
import { spawn, spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

const PORT = 10087;
const HOST = '127.0.0.1';
const HOME = os.homedir();
const BASE = path.join(HOME, '.appbridge');
const DAEMON = path.join(BASE, 'daemon', 'daemon.mjs');
const LOG_FILE = path.join(BASE, 'logs', 'daemon.log');
const PID_FILE = path.join(BASE, 'appbridge.pid');

function getStatus(timeoutMs = 1500) {
  return new Promise((resolve) => {
    const req = http.get({ host: HOST, port: PORT, path: '/status', timeout: timeoutMs }, (res) => {
      let body = '';
      res.on('data', (c) => (body += c));
      res.on('end', () => { try { resolve(JSON.parse(body)); } catch { resolve(null); } });
    });
    req.on('error', () => resolve(null));
    req.on('timeout', () => { req.destroy(); resolve(null); });
  });
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function cmdStatus() {
  const s = await getStatus();
  if (!s) { console.log(JSON.stringify({ running: false })); return; }
  console.log(JSON.stringify(s));
}

async function cmdStart() {
  const existing = await getStatus();
  if (existing && existing.running) {
    console.log(JSON.stringify({ ...existing, note: 'already running' }));
    return;
  }
  const child = spawn(process.execPath, [DAEMON], {
    detached: true,
    stdio: 'ignore',
    windowsHide: true,
  });
  child.unref();
  // Poll until the worker is connected (pwsh + UIA assemblies take ~1-3s).
  const deadline = Date.now() + 12000;
  let s = null;
  while (Date.now() < deadline) {
    await sleep(350);
    s = await getStatus();
    if (s && s.worker_connected) break;
  }
  if (s) console.log(JSON.stringify(s));
  else console.log(JSON.stringify({ running: false, error: 'daemon did not come up — check logs' }));
}

function killTree(pid) {
  try { spawnSync('taskkill', ['/PID', String(pid), '/T', '/F'], { windowsHide: true }); } catch {}
}

async function cmdStop() {
  let killed = false;
  if (fs.existsSync(PID_FILE)) {
    const pid = parseInt(fs.readFileSync(PID_FILE, 'utf8').trim(), 10);
    if (pid) { killTree(pid); killed = true; }
    try { fs.unlinkSync(PID_FILE); } catch {}
  }
  // Sweep any orphaned worker (pwsh running worker.ps1) as a safety net.
  try {
    spawnSync('powershell', ['-NoProfile', '-NonInteractive', '-Command',
      "Get-CimInstance Win32_Process -Filter \"Name='pwsh.exe'\" | Where-Object { $_.CommandLine -like '*appbridge*worker.ps1*' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }"],
      { windowsHide: true });
  } catch {}
  console.log(JSON.stringify({ stopped: true, killedDaemon: killed }));
}

async function cmdRestart() {
  await cmdStop();
  await sleep(600);
  await cmdStart();
}

function cmdLogs(args) {
  let n = 80;
  const i = args.indexOf('-n');
  if (i >= 0 && args[i + 1]) n = parseInt(args[i + 1], 10) || 80;
  if (!fs.existsSync(LOG_FILE)) { console.log('(no log file yet)'); return; }
  const lines = fs.readFileSync(LOG_FILE, 'utf8').split(/\r?\n/).filter(Boolean);
  console.log(lines.slice(-n).join('\n'));
}

const [cmd, ...rest] = process.argv.slice(2);
(async () => {
  switch (cmd) {
    case 'status': await cmdStatus(); break;
    case 'start': await cmdStart(); break;
    case 'stop': await cmdStop(); break;
    case 'restart': await cmdRestart(); break;
    case 'logs': cmdLogs(rest); break;
    default:
      console.log('usage: node appbridge.mjs <status|start|stop|restart|logs [-n N]>');
      process.exit(cmd ? 1 : 0);
  }
})();
