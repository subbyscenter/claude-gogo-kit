// Local servers for the shortcuts popup: which ones run (and how much memory, when last used), start one when its
// shortcut is clicked while it is off, stop the ones not used for a while. Nothing here opens a window.
//   node servers.mjs list                       → <data>/servers.tsv (the popup reads it) and learns how each one starts
//   node servers.mjs sample                     → notes which servers a browser has open right now (cheap; every 5 min)
//   node servers.mjs start <port> [--out FILE]  → starts it hidden and waits until it answers; FILE gets "ok" or the error
//   node servers.mjs stop <port>...             → stops them (pm2 stop, else the process tree); "keep" ones are skipped
//   node servers.mjs keep <port> on|off         → never offered for stopping
//   node servers.mjs add --port N --name 이름 --cwd 폴더 --cmd "명령"   (a server Claude made: how to start it)
//   node servers.mjs remove <port> · show
// --data DIR = where servers.json / servers.tsv / used.log live (default: $GOGO_HOME/desktop, else this folder).
import fs from 'node:fs';
import os from 'node:os';
import net from 'node:net';
import path from 'node:path';
import { spawn, spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const [cmd, ...rest] = process.argv.slice(2);
const args = { _: [] };
for (let i = 0; i < rest.length; i++) {
  if (rest[i].startsWith('--')) { const v = rest[i + 1]; if (v === undefined || v.startsWith('--')) args[rest[i].slice(2)] = true; else { args[rest[i].slice(2)] = v; i++; } } else args._.push(rest[i]);
}
const DATA = path.resolve(args.data || (process.env.GOGO_HOME ? path.join(process.env.GOGO_HOME, 'desktop') : HERE));
const REG = path.join(DATA, 'servers.json');
const TSV = path.join(DATA, 'servers.tsv');
const USED = path.join(DATA, 'used.log');
const LOGS = path.join(DATA, 'server-logs');
const SHORTCUTS = args.shortcuts || path.join(DATA, 'shortcuts.txt');
const now = () => Math.floor(Date.now() / 1000);

// Programs that run local web servers people make; anything else listening (system, vendor apps) is not listed.
const RUNTIMES = /^(node|python|pythonw|python3(\.\d+)?|py|pyw|bun|deno|uvicorn|java|javaw|php|php-cgi|ruby|dotnet)\.exe$/i;
// Programs whose connections mean "someone is looking at it": browsers, and Tailscale (the laptop, remotely).
const CLIENTS = /^(chrome|msedge|firefox|whale|opera|brave|vivaldi|tailscaled)\.exe$/i;

const readJSON = (f, d) => { try { return JSON.parse(fs.readFileSync(f, 'utf8').replace(/^﻿/, '')); } catch { return d; } };
function writeAtomic(f, text) {
  fs.mkdirSync(path.dirname(f), { recursive: true });
  fs.writeFileSync(`${f}.tmp`, text);
  fs.renameSync(`${f}.tmp`, f);
}
const loadReg = () => { const r = readJSON(REG, {}); r.servers ??= {}; return r; };
const saveReg = (r) => writeAtomic(REG, JSON.stringify(r, null, 1) + '\n');
const entryFor = (reg, port) => reg.servers[port] || Object.values(reg.servers).find((e) => (e.ports || []).includes(Number(port))) || null;

// ---- what the system says ----------------------------------------------------------------------------------------
/** netstat -ano: listening sockets on this machine's own addresses (not the Tailscale one) and open connections. */
function sockets() {
  const out = spawnSync('netstat', ['-ano', '-p', 'tcp'], { encoding: 'utf8', windowsHide: true }).stdout || '';
  const out6 = spawnSync('netstat', ['-ano', '-p', 'tcpv6'], { encoding: 'utf8', windowsHide: true }).stdout || '';
  const listen = [];
  const conns = [];
  for (const line of `${out}\n${out6}`.split(/\r?\n/)) {
    const f = line.trim().split(/\s+/);
    if (f[0] !== 'TCP' || f.length < 5) continue;
    const [, local, foreign, state, pid] = f;
    const lp = Number(local.slice(local.lastIndexOf(':') + 1));
    const la = local.slice(0, local.lastIndexOf(':'));
    if (state === 'LISTENING') {
      if (/^(127\.0\.0\.1|0\.0\.0\.0|\[::1\]|\[::\])$/.test(la)) listen.push({ port: lp, pid: Number(pid) });
    } else if (state === 'ESTABLISHED') {
      conns.push({ pid: Number(pid), toPort: Number(foreign.slice(foreign.lastIndexOf(':') + 1)), to: foreign.slice(0, foreign.lastIndexOf(':')) });
    }
  }
  return { listen, conns };
}
/** tasklist: pid → image name (cheap; for sampling). */
function taskNames() {
  const out = spawnSync('tasklist', ['/fo', 'csv', '/nh'], { encoding: 'utf8', windowsHide: true }).stdout || '';
  const m = new Map();
  for (const line of out.split(/\r?\n/)) {
    const f = line.match(/^"([^"]*)","(\d+)"/);
    if (f) m.set(Number(f[2]), f[1]);
  }
  return m;
}
// Every process (id, parent, name, path, command line, memory) and, for `cwdOf`, its current folder (read from the
// process itself — Windows keeps it there; WMI does not report it).
const PS = (pids) => `
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$procs = @(Get-CimInstance Win32_Process | Select-Object ProcessId, ParentProcessId, Name, ExecutablePath, CommandLine, WorkingSetSize)
$cwd = @{}
$want = @(${pids.join(',')})
if ($want.Count) {
  Add-Type -TypeDefinition @'
using System; using System.Runtime.InteropServices; using System.Text;
public static class ProcCwd {
  [DllImport("ntdll.dll")] static extern int NtQueryInformationProcess(IntPtr h, int c, byte[] info, int len, out int ret);
  [DllImport("kernel32.dll")] static extern IntPtr OpenProcess(int access, bool inherit, int pid);
  [DllImport("kernel32.dll")] static extern bool ReadProcessMemory(IntPtr h, IntPtr addr, byte[] buf, int size, out IntPtr read);
  [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
  static byte[] Read(IntPtr h, long addr, int n) { byte[] b = new byte[n]; IntPtr r; return ReadProcessMemory(h, new IntPtr(addr), b, n, out r) ? b : null; }
  public static string Of(int pid) {
    IntPtr h = OpenProcess(0x0410, false, pid);
    if (h == IntPtr.Zero) return null;
    try {
      byte[] pbi = new byte[48]; int ret;
      if (NtQueryInformationProcess(h, 0, pbi, pbi.Length, out ret) != 0) return null;
      byte[] pp = Read(h, BitConverter.ToInt64(pbi, 8) + 0x20, 8);              // PEB.ProcessParameters
      if (pp == null) return null;
      byte[] us = Read(h, BitConverter.ToInt64(pp, 0) + 0x38, 16);             // CurrentDirectory.DosPath
      if (us == null) return null;
      byte[] s = Read(h, BitConverter.ToInt64(us, 8), BitConverter.ToUInt16(us, 0));
      return s == null ? null : Encoding.Unicode.GetString(s);
    } finally { CloseHandle(h); }
  }
}
'@
  foreach ($id in $want) { $cwd["$id"] = [ProcCwd]::Of([int]$id) }
}
@{ procs = $procs; cwd = $cwd } | ConvertTo-Json -Depth 3 -Compress
`;
function processes(cwdOf = []) {
  const r = spawnSync('powershell', ['-NoProfile', '-NonInteractive', '-EncodedCommand', Buffer.from(PS(cwdOf), 'utf16le').toString('base64')],
    { encoding: 'utf8', windowsHide: true, timeout: 60000, maxBuffer: 64 * 1024 * 1024 });
  const j = JSON.parse((r.stdout || '').trim() || '{"procs":[],"cwd":{}}');
  const byId = new Map();
  for (const p of [].concat(j.procs || [])) byId.set(p.ProcessId, { id: p.ProcessId, parent: p.ParentProcessId, name: p.Name || '', exe: p.ExecutablePath || '', cmd: p.CommandLine || '', mem: Number(p.WorkingSetSize) || 0 });
  return { byId, cwd: j.cwd || {} };
}
/** Running pm2 apps by process id → name (only where pm2 is used; its pid files are not reliable: stale, names cut). */
function pm2Pids() {
  const m = new Map();
  if (!fs.existsSync(process.env.PM2_HOME || path.join(os.homedir(), '.pm2'))) return m;
  const out = shell('pm2 jlist').out;
  try {
    for (const a of JSON.parse(out.slice(out.indexOf('[')))) if (a.pid && a.pm2_env?.status === 'online') m.set(a.pid, a.name);
  } catch {}
  return m;
}

// ---- servers -----------------------------------------------------------------------------------------------------
const argsOf = (cmdline) => cmdline.replace(/^\s*("[^"]*"|\S+)\s*/, '').trim();
/** The process to start and stop: the listening one, or the venv launcher above it (same arguments, same runtime). */
function rootOf(p, byId) {
  let cur = p;
  for (let i = 0; i < 4; i++) {
    const up = byId.get(cur.parent);
    if (!up || !RUNTIMES.test(up.name) || argsOf(up.cmd) !== argsOf(cur.cmd)) break;
    cur = up;
  }
  return cur;
}
function descendants(id, byId) {
  const out = [id];
  for (let i = 0; i < out.length; i++) for (const p of byId.values()) if (p.parent === out[i] && !out.includes(p.id)) out.push(p.id);
  return out;
}
/** A vendor program bundling a runtime (e.g. Adobe's node.exe running files under Program Files) is not a server of ours. */
function vendor(p) {
  const pf = [process.env.ProgramFiles, process.env['ProgramFiles(x86)']].filter(Boolean).map((d) => d.toLowerCase());
  const first = (argsOf(p.cmd).match(/^"([^"]+)"|^(\S+)/) || [])[0]?.replace(/"/g, '').toLowerCase() || '';
  return /^[a-z]:\\/.test(first) && pf.some((d) => first.startsWith(d));
}
/** port → the name of its shortcut (the one with the shortest address wins: the site's front page). */
function shortcutNames() {
  const m = new Map();
  const len = new Map();
  try {
    for (const line of fs.readFileSync(SHORTCUTS, 'utf8').split(/\r?\n/)) {
      const f = line.split('|').map((s) => s.trim());
      const u = f.length > 1 && f[1].match(/^https?:\/\/(?:localhost|127\.0\.0\.1|\[::1\]):(\d+)(\S*)/i);
      if (!u || !f[0] || f[0].startsWith('#')) continue;
      const port = Number(u[1]);
      if (!m.has(port) || u[2].length < len.get(port)) { m.set(port, f[0]); len.set(port, u[2].length); }
    }
  } catch {}
  return m;
}
function mergeUsed(reg) {
  let text = '';
  try { text = fs.readFileSync(USED, 'utf8'); fs.rmSync(USED, { force: true }); } catch { return; }
  for (const line of text.split(/\r?\n/)) {
    const [port, t] = line.split('\t').map(Number);
    if (!port || !t) continue;
    const e = entryFor(reg, port) || (reg.servers[port] = { firstSeen: t });
    e.lastUsed = Math.max(e.lastUsed || 0, t);
  }
}
/** The running servers, grouped by process: [{key, ports, root, pm2, mem, name, ...}]. Learns how each one starts. */
function scan(reg, { learn = true } = {}) {
  const { listen, conns } = sockets();
  const { byId } = processes();
  const pm2 = pm2Pids();
  const shortcut = shortcutNames();
  const groups = new Map();
  for (const l of listen) {
    const p = byId.get(l.pid);
    if (!p || !RUNTIMES.test(p.name)) continue;
    let pm2Name = '';
    for (let c = p, i = 0; c && i < 8; c = byId.get(c.parent), i++) if (pm2.has(c.id)) { pm2Name = pm2.get(c.id); break; }
    if (!pm2Name && vendor(p)) continue;
    const root = rootOf(p, byId);
    const g = groups.get(root.id) || { root, leaf: p, pm2: pm2Name, ports: [] };
    if (!g.ports.includes(l.port)) g.ports.push(l.port);
    groups.set(root.id, g);
  }
  const t = now();
  for (const g of groups.values()) {
    g.ports.sort((a, b) => a - b);
    const known = g.ports.map((port) => entryFor(reg, port)).find(Boolean);
    g.key = String(known ? Object.keys(reg.servers).find((k) => reg.servers[k] === known) : (g.ports.find((port) => shortcut.has(port)) || g.ports[0]));
    g.e = known || (reg.servers[g.key] = {});
  }
  // How a server that is not pm2's starts = its command line in its folder. The folder is read only when new.
  const learnable = learn ? [...groups.values()].filter((g) => !g.pm2 && !g.e.manual) : [];
  const need = learnable.filter((g) => !g.e.cwd || g.e.cmd !== g.root.cmd);
  const cwd = need.length ? processes(need.map((g) => g.leaf.id)).cwd : {};
  const list = [];
  for (const g of groups.values()) {
    const { e } = g;
    const key = g.key;
    e.ports = g.ports;
    e.firstSeen ||= t;
    e.pid = g.root.id;
    if (learn && !e.manual) {
      if (g.pm2) { e.pm2 = g.pm2; delete e.cmd; delete e.cwd; } else if (cwd[String(g.leaf.id)] || e.cmd !== g.root.cmd) {
        e.cmd = g.root.cmd;
        delete e.pm2;
        if (cwd[String(g.leaf.id)]) e.cwd = cwd[String(g.leaf.id)].replace(/\\$/, '');
      }
    }
    const group = new Set(descendants(g.root.id, byId));
    const mem = [...group].reduce((s, id) => s + (byId.get(id)?.mem || 0), 0);
    const inUse = conns.some((c) => g.ports.includes(c.toPort) && /^(127\.0\.0\.1|\[::1\]|\[::ffff:127\.0\.0\.1\])$/.test(c.to)
      && !group.has(c.pid) && CLIENTS.test(byId.get(c.pid)?.name || ''));
    if (inUse) e.lastUsed = t;
    const name = e.name || g.ports.map((port) => shortcut.get(port)).find(Boolean) || e.pm2 || `${g.leaf.name.replace(/\.exe$/i, '')} ${path.basename((argsOf(g.leaf.cmd).match(/[^\s"]+\.(m?js|py|ts)\b/i) || [''])[0])}`.trim();
    list.push({ key, ports: g.ports, name, mem, inUse, entry: e, how: e.pm2 ? 'pm2' : e.cmd ? 'cmd' : 'none' });
  }
  return list.sort((a, b) => b.mem - a.mem);
}
const idleMinutes = (e, t = now()) => Math.max(0, Math.round((t - Math.max(e.lastUsed || 0, e.firstSeen || t)) / 60));
function writeTsv(list) {
  const t = now();
  const rows = [`at\t${t}`];
  for (const s of list) {
    rows.push(['s', s.key, s.ports.join(','), s.name.replace(/[\t\r\n]/g, ' '), Math.round(s.mem / 1048576), s.inUse ? 0 : idleMinutes(s.entry, t),
      s.how, s.entry.keep ? 1 : 0, s.inUse ? 1 : 0].join('\t'));
  }
  writeAtomic(TSV, rows.join('\n') + '\n');
}
function listNow() {
  const reg = loadReg();
  mergeUsed(reg);
  const list = scan(reg);
  saveReg(reg);
  writeTsv(list);
  return list;
}

// ---- start / stop ------------------------------------------------------------------------------------------------
const answers = (port) => Promise.any(['127.0.0.1', '::1'].map((host) => new Promise((res, rej) => {
  const s = net.connect({ host, port, timeout: 800 }, () => { s.destroy(); res(true); });
  s.on('error', rej).on('timeout', () => { s.destroy(); rej(new Error('timeout')); });
}))).then(() => true, () => false);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
function shell(line) {
  const r = spawnSync(process.env.ComSpec || 'cmd.exe', ['/d', '/s', '/c', `"${line}"`], { encoding: 'utf8', windowsHide: true, windowsVerbatimArguments: true, timeout: 120000 });
  return { ok: r.status === 0, out: `${r.stdout || ''}${r.stderr || ''}`.trim() };
}
async function startPort(port) {
  if (await answers(port)) return 'ok';
  const reg = loadReg();
  const e = entryFor(reg, port);
  if (!e || (!e.pm2 && !e.cmd)) throw new Error('이 서버를 켜는 법을 아직 몰라요 (한 번 직접 켜 두면 다음부터 기억해요)');
  e.lastUsed = now();
  saveReg(reg);
  if (e.pm2) {
    const r = shell(`pm2 start "${e.pm2}"`);
    if (!r.ok) throw new Error(`pm2 start ${e.pm2} 실패: ${r.out.slice(-200)}`);
  } else {
    fs.mkdirSync(LOGS, { recursive: true });
    const log = fs.openSync(path.join(LOGS, `${port}.log`), 'a');
    const cwd = e.cwd && fs.existsSync(e.cwd) ? e.cwd : undefined;
    // Not "detached": that would give the server a console window of its own. Started like this the shell gets a
    // console with no window, the server shares it, and (Node's job object lets grandchildren break away) the server
    // keeps running after this script and the shell have gone.
    const child = spawn(e.cmd, { shell: true, cwd, windowsHide: true, stdio: ['ignore', log, log] });
    child.unref();
  }
  for (let i = 0; i < 180; i++) { if (await answers(port)) return 'ok'; await sleep(500); }
  throw new Error(`90초 안에 안 켜졌어요 — 기록: ${path.join(LOGS, `${port}.log`)}`);
}
function stopPorts(ports, { force = false } = {}) {
  const reg = loadReg();
  const list = scan(reg, { learn: false });
  const done = [];
  for (const port of ports) {
    const s = list.find((x) => x.ports.includes(Number(port)) || x.key === String(port));
    if (!s) continue;
    if (s.entry.keep && !force) { done.push(`${s.name}: 항상 켜 두기라 그대로`); continue; }
    if (s.how === 'none' && !force) { done.push(`${s.name}: 다시 켜는 법을 몰라 그대로`); continue; }
    const r = s.entry.pm2 ? shell(`pm2 stop "${s.entry.pm2}"`) : shell(`taskkill /PID ${s.entry.pid} /T /F`);
    done.push(`${s.name}: ${r.ok ? '끔' : `못 끔 (${r.out.slice(-120)})`}`);
  }
  saveReg(reg);
  return done;
}

// ---- commands ----------------------------------------------------------------------------------------------------
async function main() {
  if (cmd === 'list') {
    const list = listNow();
    console.log(`${list.length} servers → ${TSV}`);
  } else if (cmd === 'sample') {
    // Cheap: netstat + tasklist only. A browser (or Tailscale) connected to a known server's port = used now.
    const reg = loadReg();
    mergeUsed(reg);
    const names = taskNames();
    const { listen, conns } = sockets();
    const ports = new Set(listen.map((l) => l.port));
    const t = now();
    for (const c of conns) {
      if (!ports.has(c.toPort) || !CLIENTS.test(names.get(c.pid) || '') || !/^(127\.0\.0\.1|\[::1\]|\[::ffff:127\.0\.0\.1\])$/.test(c.to)) continue;
      const e = entryFor(reg, c.toPort);
      if (e) e.lastUsed = t;
    }
    saveReg(reg);
  } else if (cmd === 'start') {
    const port = Number(args._[0]);
    let result;
    try { result = await startPort(port); } catch (e) { result = e.message; }
    if (args.out) writeAtomic(path.resolve(args.out), result);
    console.log(result);
    process.exitCode = result === 'ok' ? 0 : 1;
    try { listNow(); } catch {}
  } else if (cmd === 'stop') {
    for (const line of stopPorts(args._, { force: Boolean(args.force) })) console.log(line);
    await sleep(800);
    listNow();
  } else if (cmd === 'keep') {
    const reg = loadReg();
    const e = entryFor(reg, args._[0]) || (reg.servers[args._[0]] = { firstSeen: now() });
    e.keep = args._[1] !== 'off';
    saveReg(reg);
    console.log(`${args._[0]}: ${e.keep ? '항상 켜 두기' : '끌 수 있음'}`);
    try { listNow(); } catch {}
  } else if (cmd === 'add') {
    const port = Number(args.port);
    if (!port || !args.cmd) { console.error('사용법: servers.mjs add --port 8123 --name "이름" --cwd "폴더" --cmd "node server.mjs"'); process.exitCode = 1; return; }
    const reg = loadReg();
    const e = entryFor(reg, port) || (reg.servers[port] = { firstSeen: now() });
    Object.assign(e, { manual: true, cmd: String(args.cmd), ...(args.cwd ? { cwd: path.resolve(String(args.cwd)) } : {}), ...(args.name ? { name: String(args.name) } : {}) });
    delete e.pm2;
    e.ports = [...new Set([port, ...(e.ports || [])])];
    saveReg(reg);
    console.log(`등록: ${port} ${e.name || ''} — ${e.cmd}${e.cwd ? ` (폴더 ${e.cwd})` : ''}`);
  } else if (cmd === 'remove') {
    const reg = loadReg();
    for (const k of Object.keys(reg.servers)) if (k === String(args._[0])) delete reg.servers[k];
    saveReg(reg);
  } else if (cmd === 'show') {
    const list = listNow();
    const reg = loadReg();
    console.log(`켜진 서버 ${list.length}개 · 메모리 ${Math.round(list.reduce((s, x) => s + x.mem, 0) / 1048576)}MB`);
    for (const s of list) console.log(`  ${s.ports.join(',').padEnd(10)} ${s.name.padEnd(28)} ${String(Math.round(s.mem / 1048576)).padStart(5)}MB  ${s.inUse ? '지금 사용 중' : `${idleMinutes(s.entry)}분 안 씀`}  ${s.how}${s.entry.keep ? ' · 항상 켜 두기' : ''}`);
    const off = Object.entries(reg.servers).filter(([k, e]) => !list.some((s) => s.key === k) && (e.pm2 || e.cmd));
    if (off.length) console.log(`꺼져 있지만 켜는 법을 아는 서버 ${off.length}개: ${off.map(([k, e]) => `${k} ${e.name || e.pm2 || ''}`.trim()).join(' · ')}`);
  } else {
    console.log(fs.readFileSync(fileURLToPath(import.meta.url), 'utf8').split('\n').filter((l) => l.startsWith('//')).join('\n'));
  }
}
await main();
