#!/usr/bin/env node
// wechat-send.mjs — send a WeChat message to a named contact, via cc-app-bridge.
//
// Usage:
//   node wechat-send.mjs "<contact>" "<message>"           # DRY RUN: type it, screenshot, do NOT send
//   node wechat-send.mjs "<contact>" "<message>" --send    # actually send (press Enter)
//
// WeChat 4.0 exposes almost no UIA tree, so this drives it by coordinates + screenshots.
// It is intentionally SAFE-BY-DEFAULT: outward-facing (a real message to a real person),
// so it dry-runs unless you pass --send. Always eyeball the screenshots it prints — they
// confirm (a) the chat header is the right person and (b) the text landed before sending.
//
// Layout assumption: standard WeChat window (left contact sidebar + right chat pane).
// If you resize WeChat oddly and clicks miss, adjust the offsets in coords() below.

import http from 'node:http';

const PORT = 10087;
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

function cmd(action, args = {}, session = 'wx') {
  return new Promise((resolve, reject) => {
    const b = JSON.stringify({ action, args, session });
    const r = http.request(
      { host: '127.0.0.1', port: PORT, path: '/command', method: 'POST',
        headers: { 'Content-Type': 'application/json; charset=utf-8', 'Content-Length': Buffer.byteLength(b) } },
      (x) => { let d = ''; x.on('data', (c) => (d += c)); x.on('end', () => resolve(JSON.parse(d))); });
    r.on('error', reject); r.write(b); r.end();
  });
}
const refOf = (tree, re) => { const l = (tree || '').split('\n').find((x) => re.test(x)); return l ? l.match(/(@e\d+)/)[1] : null; };

async function getWx(retries = 6) {
  for (let i = 0; i < retries; i++) {
    const w = await cmd('list_windows');
    const wx = w.data.windows.find((x) => x.title === '微信' && x.bounds.w < 2000)
            || w.data.windows.find((x) => /微信/.test(x.title) && x.bounds.w < 2000);
    if (wx) return wx;
    await sleep(500);
  }
  return null;
}

// Pixel targets derived from the standard layout. Sidebar is fixed-width (so search/contact
// use fixed left offsets); the input box is anchored to the chat pane + bottom edge.
function coords(b) {
  return {
    search:  { x: b.x + 240, y: b.y + 86 },
    contact: { x: b.x + 200, y: b.y + 200 },                 // first result row under 联系人
    input:   { x: b.x + Math.round(b.w * 0.5), y: b.y + b.h - 41 },
  };
}

async function restoreFromTray() {
  const w = await cmd('list_windows', {}, 'tray');
  const tray = w.data.windows.find((x) => x.class === 'Shell_TrayWnd');
  if (!tray) throw new Error('taskbar (Shell_TrayWnd) not found');
  // 1) WeChat icon directly visible in the tray?
  let s = await cmd('snapshot', { handle: tray.handle, maxNodes: 400 }, 'tray');
  let wxRef = refOf(s.data.tree, /Button "微信(?:"| |（)/);
  if (wxRef) { await cmd('click', { selector: wxRef }, 'tray'); await sleep(1600); return; }
  // 2) otherwise open the hidden-icons overflow and look there
  const chev = refOf(s.data.tree, /Button "显示隐藏的图标"/);
  if (!chev) throw new Error('no WeChat tray icon and no overflow chevron found');
  await cmd('click', { selector: chev }, 'tray');
  await sleep(800);
  const w2 = await cmd('list_windows', {}, 'tray');
  const fly = w2.data.windows.find((x) => /Overflow|XamlIsland/i.test(x.class));
  if (!fly) throw new Error('tray overflow flyout did not open');
  s = await cmd('snapshot', { handle: fly.handle, includeOffscreen: true, maxNodes: 200 }, 'tray');
  wxRef = refOf(s.data.tree, /Button "微信(?:"| |（)/);
  if (!wxRef) throw new Error('WeChat icon not found in tray overflow');
  await cmd('click', { selector: wxRef }, 'tray');
  await sleep(1600);
}

async function shot(wx, tag) {
  const v = (await getWx()) || wx;
  const r = await cmd('screenshot', { handle: v.handle, raise: false });
  console.log(`  [screenshot:${tag}] ${r.data.path}`);
  return r.data.path;
}

async function main() {
  const [contact, message, ...flags] = process.argv.slice(2);
  const SEND = flags.includes('--send');
  if (!contact || !message) {
    console.log('usage: node wechat-send.mjs "<contact>" "<message>" [--send]');
    process.exit(1);
  }
  console.log(`contact="${contact}" message="${message}" mode=${SEND ? 'SEND' : 'DRY-RUN'}`);

  // make sure daemon is up
  const st = await cmd('ping').catch(() => null);
  if (!st || !st.success) { console.log('ERROR: appbridge daemon not responding on :' + PORT + ' — start it first.'); process.exit(2); }

  // 1) get/restore WeChat
  let wx = await getWx(2);
  if (!wx) { console.log('WeChat window not visible — restoring from tray...'); await restoreFromTray(); wx = await getWx(); }
  if (!wx) { console.log('ERROR: could not bring up the WeChat window.'); process.exit(3); }
  console.log(`WeChat window @ ${JSON.stringify(wx.bounds)}`);
  let c = coords(wx.bounds);

  // 2) search the contact
  await cmd('click', c.search);                 // focuses search box + activates window
  await sleep(450);
  let cur = await getWx();
  if (!cur || !cur.foreground) { console.log('ABORT: WeChat did not come to foreground after clicking search (click may have missed).'); process.exit(4); }
  await cmd('key', { keys: '^a' });             // clear any residue in the search box
  await cmd('paste', { text: contact });
  await sleep(1600);                            // let results populate

  // 3) open the first contact result, then verify
  await cmd('click', c.contact);
  await sleep(900);
  wx = (await getWx()) || wx; c = coords(wx.bounds);
  console.log('Opened a chat. VERIFY the header in this screenshot is the intended person:');
  await shot(wx, 'chat-opened');

  // 4) type the message into the input box (clear first so reruns don't duplicate)
  await cmd('click', c.input);
  await sleep(350);
  cur = await getWx();
  if (!cur || !cur.foreground) { console.log('ABORT: WeChat not foreground after clicking input (likely hit a toolbar icon). Nothing typed/sent.'); process.exit(5); }
  await cmd('key', { keys: '^a' });
  await cmd('paste', { text: message });
  await sleep(400);
  console.log('Message typed into the input box (NOT yet sent). Verify it here:');
  await shot(wx, 'typed');

  // 5) send or stop
  if (!SEND) {
    console.log('\nDRY RUN complete — message is typed but NOT sent.');
    console.log('Review the two screenshots above. If the person and text are correct, rerun with --send:');
    console.log(`  node wechat-send.mjs "${contact}" "${message}" --send`);
    return;
  }
  await cmd('key', { keys: '{ENTER}' });
  await sleep(800);
  console.log('SENT. Confirmation screenshot:');
  await shot(wx, 'sent');
}

main().catch((e) => { console.log('ERROR:', e.message); process.exit(10); });
