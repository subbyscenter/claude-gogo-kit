// gogo 키트 — Claude Code PC 기본 세팅을 한 번에 깔고(install), 세션 시작 때 점검·자동 수리(check --fix)한다.
//   caveman(토큰 절약) · 카파시 원문 지침(65줄) + "카파시라면?" · 옵시디언 누적 기억(Karpathy LLM Wiki) · 디스코드 질문/결과물/알림 봇
//
//   node gogo.mjs install [--pc-name 이름] [--vault 폴더] [--skip obsidian-app,caveman,autostart,npm]
//   node gogo.mjs check [--fix] [--json]            /gogo 가 --fix 로 부른다
//   node gogo.mjs discord-setup --token <봇 토큰> [--guild <서버 id>]
//   node gogo.mjs bot start|stop|status
//   (시험용) --home <폴더> : 그 폴더를 사용자 홈처럼 씀 — 이 PC의 진짜 설정은 건드리지 않음
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import crypto from 'node:crypto';
import { spawn, spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const VERSION = '1.0.0';
const KIT = path.dirname(fileURLToPath(import.meta.url));
const [cmd, ...rest] = process.argv.slice(2);
const args = { _: [] };
for (let i = 0; i < rest.length; i++) {
  const a = rest[i];
  if (a.startsWith('--')) {
    const k = a.slice(2);
    const v = rest[i + 1];
    if (v === undefined || v.startsWith('--')) args[k] = true; else { args[k] = v; i++; }
  } else args._.push(a);
}
const str = (v) => (v && v !== true ? String(v) : '');

const TEST = Boolean(str(args.home));
const HOME = TEST ? path.resolve(str(args.home)) : os.homedir();
if (TEST) process.env.GOGO_HOME = process.env.GOGO_HOME || path.join(HOME, '.gogo');
const C = await import('./discord/common.mjs');   // after GOGO_HOME is set
const { GOGO_HOME, STATE, LOG, STOP_FILE, ENV_FILE, readJSON, sleep, creds, botAlive, api, saveEnv, BOT_PERMISSIONS, MESSAGE_CONTENT_FLAGS } = C;

const CLAUDE_DIR = TEST ? path.join(HOME, '.claude') : (process.env.CLAUDE_CONFIG_DIR || path.join(HOME, '.claude'));
const APPDATA = TEST ? path.join(HOME, 'AppData', 'Roaming') : (process.env.APPDATA || path.join(HOME, 'AppData', 'Roaming'));
const LOCALAPPDATA = TEST ? path.join(HOME, 'AppData', 'Local') : (process.env.LOCALAPPDATA || path.join(HOME, 'AppData', 'Local'));
const RECORD = path.join(GOGO_HOME, 'install.json');
const rec = readJSON(RECORD, {});
const PC = str(args['pc-name']) || process.env.GOGO_PC_NAME || rec.pcName || os.hostname();
const VAULT = path.resolve(str(args.vault) || process.env.GOGO_VAULT || rec.vault || path.join(HOME, 'obsidian_vault'));
const SKIP = new Set(str(args.skip).split(',').map((s) => s.trim()).filter(Boolean));
const BOT = path.join(KIT, 'discord', 'bot.mjs');
const STARTUP_VBS = path.join(APPDATA, 'Microsoft', 'Windows', 'Start Menu', 'Programs', 'Startup', 'gogo-discord-bot.vbs');
const WIN = process.platform === 'win32';

// The originals, fetched at install time and checked byte for byte (pinned commit / known hash).
const KARPATHY = {
  name: 'karpathy-CLAUDE.md', strict: true,
  url: 'https://raw.githubusercontent.com/multica-ai/andrej-karpathy-skills/8462496b34419f20b32778610571ac723e91f94c/CLAUDE.md',
  page: 'https://github.com/multica-ai/andrej-karpathy-skills/blob/main/CLAUDE.md',
  sha256: '694a2d721e41c385f3db492838c23299826df5ba9809e3b0721aac70021e196a',
};
const LLM_WIKI = {
  name: 'LLM-WIKI.md', strict: false,
  url: 'https://gist.githubusercontent.com/karpathy/442a6bf555914893e9891c11519de94f/raw',
  page: 'https://gist.github.com/karpathy/442a6bf555914893e9891c11519de94f',
  sha256: 'dc3efe98ae62f23dd08acad13aba2e95287beb20b6bec2f4af0423557fe37401',
};
const CAVEMAN = { id: 'caveman@caveman', repo: 'JuliusBrussee/caveman', zip: 'https://codeload.github.com/JuliusBrussee/caveman/zip/refs/heads/main' };
const VAULT_DIRS = ['AI-Sessions/raw/assets', 'AI-Sessions/conversations',
  ...['sources', 'entities', 'concepts', 'decisions', 'errors', 'projects', 'guides'].map((d) => `AI-Sessions/wiki/${d}`)];
const BLOCK_START = '<!-- gogo-kit:start';
const BLOCK_END = '<!-- gogo-kit:end -->';

// ---- small helpers -----------------------------------------------------------------------------------------------
const read = (f) => { try { return fs.readFileSync(f, 'utf8').replace(/^\uFEFF/, ''); } catch { return null; } };
const write = (f, text) => { fs.mkdirSync(path.dirname(f), { recursive: true }); fs.writeFileSync(f, text); };
const writeJSON2 = (f, o) => write(f, JSON.stringify(o, null, 2) + '\n');
const fwd = (p) => String(p).replace(/\\/g, '/');
const normPath = (p) => fwd(path.resolve(String(p))).replace(/\/+$/, '').toLowerCase();
const samePath = (a, b) => normPath(a) === normPath(b);
const lf = (s) => s.replace(/\r\n/g, '\n');
const sha = (b) => crypto.createHash('sha256').update(b).digest('hex');
const today = () => new Date(Date.now() - new Date().getTimezoneOffset() * 60000).toISOString().slice(0, 10);
const stamp = () => new Date().toISOString().replace(/[-:]/g, '').slice(0, 15);
const backedUp = new Set();
function backup(f) {
  if (backedUp.has(f) || !fs.existsSync(f)) return;
  fs.copyFileSync(f, `${f}.bak-gogo-${stamp()}`);
  backedUp.add(f);
}
const VARS = () => ({
  PC_NAME: PC, VAULT: fwd(VAULT), KIT: fwd(KIT), DATE: today(), VERSION,
  ASK: `node "${fwd(path.join(KIT, 'discord', 'ask.mjs'))}"`, GOGO: `node "${fwd(path.join(KIT, 'gogo.mjs'))}"`,
});
const render = (t) => lf(t).replace(/\{\{(\w+)\}\}/g, (m, k) => VARS()[k] ?? m);
/** "//c/Users/x/vault/**" — Claude Code's permission-rule form of an absolute Windows path. */
const ruleOf = (p) => { const f = fwd(path.resolve(p)); return /^[A-Za-z]:/.test(f) ? `//${f[0].toLowerCase()}${f.slice(2)}/**` : `/${f}/**`; };
const vaultRule = () => `Edit(${ruleOf(VAULT)})`;

async function download(url) {
  try {
    const r = await fetch(url, { signal: AbortSignal.timeout(60000), headers: { 'User-Agent': 'gogo-kit' } });
    if (!r.ok) throw new Error(`HTTP ${r.status}`);
    return Buffer.from(await r.arrayBuffer());
  } catch (e) {
    if (!WIN) throw e;
    // A company proxy that Node does not see is usually fine for PowerShell (system proxy).
    const tmp = path.join(os.tmpdir(), `gogo-dl-${crypto.randomBytes(4).toString('hex')}`);
    const ps = spawnSync('powershell', ['-NoProfile', '-Command',
      `[Net.ServicePointManager]::SecurityProtocol='Tls12'; $ProgressPreference='SilentlyContinue'; Invoke-WebRequest -UseBasicParsing -Uri '${url}' -OutFile '${tmp}'`],
    { encoding: 'utf8', timeout: 300000, windowsHide: true });
    if (ps.status !== 0 || !fs.existsSync(tmp)) throw new Error(`${e.message}; PowerShell: ${(ps.stderr || '').trim().slice(0, 200)}`);
    const b = fs.readFileSync(tmp);
    fs.rmSync(tmp, { force: true });
    return b;
  }
}
/** Verbatim original text (cached in ~/.gogo/cache once its hash checks out). */
async function upstream(src) {
  const cache = path.join(GOGO_HOME, 'cache', src.name);
  if (fs.existsSync(cache)) {
    const b = fs.readFileSync(cache);
    if (sha(b) === src.sha256 || !src.strict) return { text: lf(b.toString('utf8')), verified: sha(b) === src.sha256 };
  }
  const b = await download(src.url);
  const verified = sha(b) === src.sha256;
  if (!verified && src.strict) throw new Error(`${src.name}: 받은 내용이 원문과 다름 (sha256 불일치) — ${src.url}`);
  write(cache, b);
  return { text: lf(b.toString('utf8')), verified };
}

function run(bin, argv, opts = {}) {
  const base = { encoding: 'utf8', timeout: 300000, windowsHide: true, ...opts };
  const r = /\.cmd$/i.test(bin)   // npm shims (.cmd) need cmd.exe; every argument quoted
    ? spawnSync(process.env.ComSpec || 'cmd.exe', ['/d', '/s', '/c', `"${[bin, ...argv].map((a) => `"${a}"`).join(' ')}"`], { ...base, windowsVerbatimArguments: true })
    : spawnSync(bin, argv, base);
  return { ok: r.status === 0, out: `${r.stdout || ''}${r.stderr || ''}${r.error ? r.error.message : ''}`.trim() };
}
function claudeBin() {
  const c = [];
  if (process.env.CLAUDE_BIN) c.push(process.env.CLAUDE_BIN);
  const w = spawnSync(WIN ? 'where' : 'which', ['claude'], { encoding: 'utf8', windowsHide: true });
  if (w.status === 0) c.push(...w.stdout.split(/\r?\n/).map((s) => s.trim()).filter(Boolean));
  const realHome = os.homedir();
  c.push(path.join(realHome, '.local', 'bin', WIN ? 'claude.exe' : 'claude'));
  const ext = path.join(realHome, '.vscode', 'extensions');
  try {
    for (const d of fs.readdirSync(ext).filter((x) => x.startsWith('anthropic.claude-code-')).sort().reverse()) {
      c.push(path.join(ext, d, 'resources', 'native-binary', WIN ? 'claude.exe' : 'claude'));
    }
  } catch {}
  const found = c.filter((p) => fs.existsSync(p) && (!WIN || /\.(exe|cmd)$/i.test(p)));
  return found.find((p) => !/\.cmd$/i.test(p)) || found[0] || null;
}
const nodeOnPath = () => spawnSync(WIN ? 'where' : 'which', ['node'], { encoding: 'utf8', windowsHide: true }).status === 0;

// ---- install steps (each idempotent; returns what it changed, '' = nothing) ----------------------------------------
async function renderedBlock() {
  const k = await upstream(KARPATHY);
  const pcPart = render(read(path.join(KIT, 'claude', 'CLAUDE.kit.md')));
  return {
    karpathy: k.text.trimEnd(),
    pcPart: pcPart.trimEnd(),
    block: `${BLOCK_START} — 이 표시 사이는 gogo 키트가 관리해요 (/gogo 가 원래대로 되돌림). 내 메모는 표시 밖에 쓰세요. -->\n`
      + `${k.text.trimEnd()}\n\n---\n\n${pcPart.trimEnd()}\n${BLOCK_END}`,
  };
}
async function stepClaudeMd() {
  const f = path.join(CLAUDE_DIR, 'CLAUDE.md');
  const cur = lf(read(f) ?? '');
  const { block } = await renderedBlock();
  const s = cur.indexOf(BLOCK_START);
  const e = cur.indexOf(BLOCK_END);
  let next;
  if (s >= 0 && e > s) next = cur.slice(0, s) + block + cur.slice(e + BLOCK_END.length);
  else next = block + (cur.trim() ? `\n\n${cur}` : '\n');   // keep what was there, below the block
  if (next === cur) return '';
  backup(f);
  write(f, next);
  return '~/.claude/CLAUDE.md (카파시 원문 + 이 PC 규칙)';
}
function skillFiles() {
  const root = path.join(KIT, 'claude', 'skills');
  return fs.readdirSync(root).map((name) => ({ name, src: path.join(root, name, 'SKILL.md'), dst: path.join(CLAUDE_DIR, 'skills', name, 'SKILL.md') }));
}
function stepSkills() {
  const changed = [];
  for (const { name, src, dst } of skillFiles()) {
    const text = render(read(src));
    if (read(dst) === text) continue;
    if (fs.existsSync(dst) && !read(dst).includes('gogo-kit')) backup(dst);
    write(dst, text);
    changed.push(`/${name}`);
  }
  return changed.length ? `스킬 ${changed.join(' ')}` : '';
}
function readSettings() {
  const f = path.join(CLAUDE_DIR, 'settings.json');
  const raw = read(f);
  if (!raw || !raw.trim()) return {};
  try { return JSON.parse(raw); } catch (e) { throw new Error(`~/.claude/settings.json 이 JSON 오류라 건드리지 않았어요: ${e.message}`); }
}
function saveSettings(s) {
  const f = path.join(CLAUDE_DIR, 'settings.json');
  backup(f);
  writeJSON2(f, s);
}
function stepSettings() {
  const s = readSettings();
  const before = JSON.stringify(s);
  s.permissions ??= {};
  const dirs = (s.permissions.additionalDirectories ??= []);
  if (!dirs.some((d) => samePath(d, VAULT))) dirs.push(fwd(VAULT));
  const allow = (s.permissions.allow ??= []);
  if (!allow.includes(vaultRule())) allow.push(vaultRule());
  if (JSON.stringify(s) === before) return '';
  saveSettings(s);
  return 'settings.json (보관함을 모든 프로젝트에서 읽기·쓰기)';
}
function cavemanState() {
  const inst = readJSON(path.join(CLAUDE_DIR, 'plugins', 'installed_plugins.json'), {});
  const entry = inst?.plugins?.[CAVEMAN.id]?.[0];
  let s = {};
  try { s = readSettings(); } catch {}
  return {
    installed: Boolean(entry && fs.existsSync(entry.installPath)),
    enabled: s.enabledPlugins?.[CAVEMAN.id] === true,
    declared: Boolean(s.extraKnownMarketplaces?.caveman),
    flag: (read(path.join(CLAUDE_DIR, '.caveman-active')) || '').trim(),
  };
}
async function cavemanLocalCopy() {
  const dir = path.join(GOGO_HOME, 'vendor');
  const zip = path.join(dir, 'caveman.zip');
  write(zip, await download(CAVEMAN.zip));
  const r = run('powershell', ['-NoProfile', '-Command', `Expand-Archive -LiteralPath '${zip}' -DestinationPath '${dir}' -Force`]);
  const out = path.join(dir, 'caveman-main');
  if (!fs.existsSync(path.join(out, '.claude-plugin', 'marketplace.json'))) throw new Error(`caveman 압축 풀기 실패: ${r.out.slice(0, 200)}`);
  return out;
}
async function stepCaveman() {
  const st = cavemanState();
  if (st.installed && st.enabled) return '';
  const bin = claudeBin();
  const env = TEST ? { ...process.env, CLAUDE_CONFIG_DIR: CLAUDE_DIR } : process.env;
  const notes = [];
  if (bin) {
    const known = readJSON(path.join(CLAUDE_DIR, 'plugins', 'known_marketplaces.json'), {});
    if (!known.caveman) {
      let r = run(bin, ['plugin', 'marketplace', 'add', CAVEMAN.repo], { env });
      if (!r.ok) {
        notes.push(`GitHub 마켓 추가 실패(${r.out.slice(0, 120)}) → 압축본으로`);
        r = run(bin, ['plugin', 'marketplace', 'add', await cavemanLocalCopy()], { env });
        if (!r.ok) notes.push(`압축본 마켓 추가 실패: ${r.out.slice(0, 160)}`);
      }
    }
    const r = run(bin, ['plugin', 'install', CAVEMAN.id, '--scope', 'user'], { env });
    if (!r.ok) notes.push(`plugin install: ${r.out.slice(0, 160)}`);
    const after = cavemanState();
    if (after.installed && after.enabled) return 'caveman 플러그인 설치 (새 세션부터 켜짐)';
  } else notes.push('claude 실행 파일을 못 찾음');
  // Fallback: declare it in user settings — Claude Code fetches enabled plugins of user settings at its next start.
  const s = readSettings();
  s.extraKnownMarketplaces ??= {};
  s.extraKnownMarketplaces.caveman ??= { source: { source: 'github', repo: CAVEMAN.repo } };
  s.enabledPlugins ??= {};
  s.enabledPlugins[CAVEMAN.id] = true;
  saveSettings(s);
  return `caveman: 설정에 적어 둠 → 다음 Claude Code 시작 때 자동 설치 (${notes.join(' / ')})`;
}
function walk(dir, base = dir) {
  return fs.readdirSync(dir, { withFileTypes: true }).flatMap((d) => (d.isDirectory()
    ? walk(path.join(dir, d.name), base) : [path.relative(base, path.join(dir, d.name))]));
}
const ORIGINAL_HEADER = (src, what) => `<!--\n원문 그대로(verbatim). 수정하지 않음.\n출처: ${src.page}\n${what}\n-->\n\n`;
async function stepVault() {
  const made = [];
  for (const d of VAULT_DIRS) fs.mkdirSync(path.join(VAULT, d), { recursive: true });
  const tpl = path.join(KIT, 'vault');
  for (const rel of walk(tpl)) {
    const dst = path.join(VAULT, rel);
    if (fs.existsSync(dst)) continue;              // the vault belongs to its owner: never overwrite
    write(dst, render(read(path.join(tpl, rel))));
    made.push(fwd(rel));
  }
  const kf = path.join(VAULT, 'KARPATHY-CLAUDE.md');
  if (!fs.existsSync(kf)) {
    const k = await upstream(KARPATHY);
    write(kf, ORIGINAL_HEADER(KARPATHY, '코딩·작업 행동 원칙 (Karpathy 가이드라인). 이 vault 운영 규칙은 CLAUDE.md에 있다.') + k.text);
    made.push('KARPATHY-CLAUDE.md');
  }
  const wf = path.join(VAULT, 'LLM-WIKI.md');
  if (!fs.existsSync(wf)) {
    const w = await upstream(LLM_WIKI);
    write(wf, ORIGINAL_HEADER(LLM_WIKI, `Andrej Karpathy — "LLM Wiki". 이 vault 설계의 근거.${w.verified ? '' : ' (받은 날 원문이 키트가 알던 판과 달랐음)'}`) + w.text);
    made.push('LLM-WIKI.md');
  }
  return made.length ? `보관함 ${made.length}개 파일 만듦` : '';
}
function obsidianExe() {
  return [path.join(LOCALAPPDATA, 'Programs', 'Obsidian', 'Obsidian.exe'), path.join(LOCALAPPDATA, 'Obsidian', 'Obsidian.exe'),
    ...(TEST ? [] : ['C:/Program Files/Obsidian/Obsidian.exe'])].find((p) => fs.existsSync(p)) || null;
}
const OBSIDIAN_JSON = path.join(APPDATA, 'obsidian', 'obsidian.json');
const vaultRegistered = () => Object.values(readJSON(OBSIDIAN_JSON, {})?.vaults || {}).some((v) => v?.path && samePath(v.path, VAULT));
const obsidianRunning = () => WIN && !TEST && /obsidian\.exe/i.test(spawnSync('tasklist', ['/FI', 'IMAGENAME eq Obsidian.exe', '/NH'], { encoding: 'utf8', windowsHide: true }).stdout || '');
function stepObsidianRegister() {
  if (vaultRegistered()) return '';
  if (obsidianRunning()) throw new Error('옵시디언이 켜져 있어 보관함 등록을 못 했어요 → 옵시디언을 끄고 /gogo 다시 (또는 옵시디언에서 「폴더를 보관함으로 열기」)');
  const o = readJSON(OBSIDIAN_JSON, {}) || {};
  o.vaults ??= {};
  o.vaults[crypto.randomBytes(8).toString('hex')] = { path: path.resolve(VAULT), ts: Date.now(), open: true };
  writeJSON2(OBSIDIAN_JSON, o);
  return '옵시디언에 보관함 등록';
}
async function stepObsidianApp() {
  if (obsidianExe()) return '';
  if (!WIN) throw new Error('윈도우가 아니에요 → https://obsidian.md/download 에서 직접 설치');
  run('winget', ['install', '-e', '--id', 'Obsidian.Obsidian', '--scope', 'user', '--silent', '--disable-interactivity',
    '--accept-package-agreements', '--accept-source-agreements'], { timeout: 600000 });
  if (obsidianExe()) return '옵시디언 앱 설치 (winget)';
  const rel = JSON.parse((await download('https://api.github.com/repos/obsidianmd/obsidian-releases/releases/latest')).toString('utf8'));
  const asset = (rel.assets || []).find((a) => /^Obsidian-[\d.]+\.exe$/.test(a.name));
  if (!asset) throw new Error('옵시디언 설치 파일을 못 찾음 → https://obsidian.md/download');
  const exe = path.join(os.tmpdir(), asset.name);
  write(exe, await download(asset.browser_download_url));
  run(exe, ['/S'], { timeout: 600000 });              // per-user installer: no admin
  if (obsidianExe()) return '옵시디언 앱 설치 (GitHub)';
  throw new Error('옵시디언 앱 설치 실패 (회사 PC가 설치를 막는 듯) → https://obsidian.md/download 에서 직접');
}
function npmCli() {
  return [path.join(path.dirname(process.execPath), 'node_modules', 'npm', 'bin', 'npm-cli.js'),
    path.join(process.env.LOCALAPPDATA || '', 'Programs', 'nodejs', 'node_modules', 'npm', 'bin', 'npm-cli.js')].find((p) => fs.existsSync(p));
}
const discordDepsOk = () => fs.existsSync(path.join(KIT, 'discord', 'node_modules', 'discord.js', 'package.json'));
function stepDiscordDeps() {
  if (discordDepsOk()) return '';
  const cwd = path.join(KIT, 'discord');
  const cli = npmCli();
  const npmArgs = ['install', '--omit=dev', '--no-audit', '--no-fund'];
  const r = cli ? run(process.execPath, [cli, ...npmArgs], { cwd, timeout: 900000 }) : run(WIN ? 'npm.cmd' : 'npm', npmArgs, { cwd, timeout: 900000 });
  if (!discordDepsOk()) throw new Error(`디스코드 부품(discord.js) 설치 실패: ${r.out.slice(-300)}`);
  return 'discord.js 설치';
}
function vbsText() {
  const q = (s) => s.replace(/"/g, '""');
  return [
    "' gogo 키트: 디스코드 봇을 숨겨서 켜 두고, 꺼지면 다시 켠다. 이 파일을 지우면 자동 시작이 멈춘다.",
    'Set sh = CreateObject("WScript.Shell")',
    `sh.Environment("PROCESS")("GOGO_HOME") = "${q(GOGO_HOME)}"`,
    'Do',
    `  rc = sh.Run("""${q(process.execPath)}"" ""${q(BOT)}""", 0, True)`,
    '  If rc = 3 Then WScript.Quit',
    '  If rc = 4 Or rc = 5 Then',
    '    WScript.Sleep 300000',
    '  Else',
    '    WScript.Sleep 15000',
    '  End If',
    'Loop',
    '',
  ].join('\r\n');
}
const readUtf16 = (f) => { try { return fs.readFileSync(f).toString('utf16le').replace(/^\uFEFF/, ''); } catch { return null; } };
function stepAutostart() {
  if (!WIN) return '';
  const t = vbsText();
  if (readUtf16(STARTUP_VBS) === t) return '';
  fs.mkdirSync(path.dirname(STARTUP_VBS), { recursive: true });
  fs.writeFileSync(STARTUP_VBS, Buffer.from('\uFEFF' + t, 'utf16le'));   // UTF-16 so a Korean user name in the path survives
  return '디스코드 봇 자동 시작 (Windows 시작프로그램)';
}

// ---- Discord bot control ----------------------------------------------------------------------------------------
async function waitAlive(sec) {
  for (let i = 0; i < sec * 2; i++) { if (botAlive()) return true; await sleep(500); }
  return false;
}
async function botStart() {
  fs.rmSync(STOP_FILE, { force: true });
  if (botAlive()) return '이미 켜져 있음';
  if (!creds().token) throw new Error('토큰이 없어요 → gogo.mjs discord-setup --token <봇 토큰>');
  if (!discordDepsOk()) stepDiscordDeps();
  const env = { ...process.env, GOGO_HOME };
  if (WIN && fs.existsSync(STARTUP_VBS)) {
    spawn('wscript.exe', [STARTUP_VBS], { detached: true, stdio: 'ignore', windowsHide: true, env }).unref();
    if (await waitAlive(25)) return '봇 켬 (자동 재시작 루프)';
  }
  spawn(process.execPath, [BOT], { detached: true, stdio: 'ignore', windowsHide: true, env }).unref();
  if (await waitAlive(25)) return '봇 켬';
  throw new Error(`봇이 안 켜져요: ${readJSON(STATE, {}).lastError || `로그 ${fwd(LOG)}`}`);
}
async function botStop() {
  fs.mkdirSync(GOGO_HOME, { recursive: true });
  fs.writeFileSync(STOP_FILE, new Date().toISOString());
  const s = readJSON(STATE, {});
  try { if (s.pid) process.kill(s.pid); } catch {}
  C.writeJSON(STATE, { ...s, heartbeat: null, pid: null });
  return '봇 끔 (자동 시작은 다음 bot start 때 다시)';
}

// ---- checks -----------------------------------------------------------------------------------------------------
// status: ok | warn | fail | skip. `fix` runs only under --fix for warn/fail.
async function checks() {
  const out = [];
  const add = (label, status, detail, extra = {}) => out.push({ label, status, detail, ...extra });
  const claudeMd = lf(read(path.join(CLAUDE_DIR, 'CLAUDE.md')) || '');
  let blk = null;
  try { blk = await renderedBlock(); } catch (e) { add('카파시 원문 받기', 'fail', e.message, { hint: '인터넷(raw.githubusercontent.com) 연결 확인' }); }

  add('Node.js', nodeOnPath() ? 'ok' : 'fail', `${process.version}${nodeOnPath() ? '' : ' — 새 터미널에서 node 가 안 보임'}`,
    { hint: nodeOnPath() ? '' : 'setup.ps1 을 다시 실행하거나 Claude Code를 새로 시작' });

  const cv = cavemanState();
  if (cv.installed && cv.enabled) {
    add('caveman (토큰 절약)', 'ok', cv.flag ? `켜짐 (${cv.flag})` : '설치됨 — 새 세션부터 켜짐', { hint: cv.flag ? '' : 'Claude Code 새 세션을 열면 적용' });
  } else if (cv.enabled && cv.declared) {
    add('caveman (토큰 절약)', 'warn', '설정에 적힘 — 다음 Claude Code 시작 때 자동 설치', { fix: stepCaveman, hint: 'Claude Code 새 세션' });
  } else add('caveman (토큰 절약)', 'fail', cv.installed ? '설치됐지만 꺼져 있음' : '설치 안 됨', { fix: stepCaveman });

  if (blk) {
    add('카파시 원문 지침 (65줄)', claudeMd.includes(blk.karpathy) ? 'ok' : 'fail',
      claudeMd.includes(blk.karpathy) ? '~/.claude/CLAUDE.md 에 원문 그대로' : '없거나 원문과 다름', { fix: stepClaudeMd });
    add('이 PC 규칙 (한국어·옵시디언·디코)', claudeMd.includes(blk.pcPart) ? 'ok' : 'fail',
      claudeMd.includes(blk.pcPart) ? `${PC} 기준` : '없거나 키트 버전과 다름', { fix: stepClaudeMd });
  }
  const sk = skillFiles().map((x) => ({ ...x, ok: read(x.dst) === render(read(x.src)) }));
  add('스킬 /gogo · /karpathy', sk.every((x) => x.ok) ? 'ok' : 'fail',
    sk.map((x) => `/${x.name} ${x.ok ? 'O' : 'X'}`).join(' · '), { fix: stepSkills });

  const missing = ['CLAUDE.md', 'index.md', 'log.md', 'KARPATHY-CLAUDE.md', 'LLM-WIKI.md', ...VAULT_DIRS].filter((r) => !fs.existsSync(path.join(VAULT, r)));
  let wikiCount = 0;
  try { wikiCount = walk(path.join(VAULT, 'AI-Sessions', 'wiki')).filter((f) => f.endsWith('.md')).length; } catch {}
  add('옵시디언 보관함', missing.length ? 'fail' : 'ok', missing.length ? `없음: ${missing.slice(0, 4).join(', ')}` : `${fwd(VAULT)} · wiki 문서 ${wikiCount}개`, { fix: stepVault });

  let s = {};
  let sErr = '';
  try { s = readSettings(); } catch (e) { sErr = e.message; }
  const access = (s.permissions?.additionalDirectories || []).some((d) => samePath(d, VAULT)) && (s.permissions?.allow || []).includes(vaultRule());
  add('보관함 접근 (모든 프로젝트)', access ? 'ok' : 'fail', sErr || (access ? '읽기·쓰기 허용됨' : 'settings.json 에 등록 안 됨'), { fix: sErr ? null : stepSettings });

  const exe = obsidianExe();
  const reg = vaultRegistered();
  add('옵시디언 앱', exe && reg ? 'ok' : 'warn', `${exe ? '설치됨' : '설치 안 됨'} · ${reg ? '보관함 등록됨' : '보관함 미등록'}`, {
    fix: async () => [!reg ? stepObsidianRegister() : '', !exe && !SKIP.has('obsidian-app') ? await stepObsidianApp() : ''].filter(Boolean).join(', '),
    hint: '앱은 사람이 보는 용도 (Claude는 앱 없이도 보관함을 씀)',
  });

  const { token, guild } = creds();
  if (!token || !guild) {
    add('디스코드', 'warn', '봇 토큰 없음', { hint: '봇을 만든 뒤: node gogo.mjs discord-setup --token <토큰>' });
  } else {
    let net = '';
    try {
      const me = await api(token, 'GET', '/users/@me');
      const g = await api(token, 'GET', `/guilds/${guild}`);
      net = `봇 ${me.username} · 서버 「${g.name}」`;
      add('디스코드 연결', 'ok', net);
      const app = await api(token, 'GET', '/applications/@me').catch(() => null);
      const mc = Boolean(((app && app.flags) || 0) & MESSAGE_CONTENT_FLAGS);
      if (!mc) add('디스코드 Message Content', 'warn', '꺼짐 — 답장 글은 @멘션이 있어야 읽힘', { hint: '개발자 포털 Bot 탭 → MESSAGE CONTENT INTENT 켜기' });
    } catch (e) {
      add('디스코드 연결', 'fail', e.status === 401 ? '토큰이 틀림' : e.status === 403 || e.status === 404 ? '봇이 그 서버에 없음' : `연결 실패: ${e.message}`,
        { hint: e.status ? 'discord-setup 다시' : '회사 네트워크가 디스코드를 막는지 확인' });
    }
    if (net) {
      if (!discordDepsOk()) add('디스코드 부품', 'fail', 'discord.js 없음', { fix: stepDiscordDeps });
      const st = readJSON(STATE, {});
      add('디스코드 봇 실행', botAlive() ? 'ok' : 'fail', botAlive() ? `켜짐 (pid ${st.pid})` : `꺼짐${st.lastError ? ` — ${st.lastError}` : ''}`, { fix: botStart });
      if (WIN) add('봇 자동 시작', readUtf16(STARTUP_VBS) === vbsText() ? 'ok' : 'fail', readUtf16(STARTUP_VBS) === vbsText() ? 'Windows 시작프로그램' : '없음', { fix: stepAutostart });
    }
  }
  return out;
}

const ICON = { ok: '✅', warn: '⚠️', fail: '❌', skip: '➖' };
function printTable(rows, fixed) {
  if (args.json) { console.log(JSON.stringify({ pc: PC, vault: fwd(VAULT), version: VERSION, rows: rows.map(({ fix, ...r }) => r), fixed }, null, 1)); return; }
  console.log(`## gogo 점검 — ${today()} (${PC}, 키트 ${VERSION})\n`);
  console.log('| 항목 | 상태 | 내용 |\n|---|---|---|');
  for (const r of rows) console.log(`| ${r.label} | ${ICON[r.status]} | ${String(r.detail).replace(/\|/g, '/')} |`);
  if (fixed.length) console.log(`\n고친 것: ${fixed.join(' · ')}`);
  const todo = rows.filter((r) => r.status !== 'ok' && r.hint).map((r) => `- ${r.label}: ${r.hint}`);
  if (todo.length) console.log(`\n할 일:\n${todo.join('\n')}`);
  const bad = rows.filter((r) => r.status === 'fail').length;
  console.log(`\nRESULT ${bad ? 'FAIL' : rows.some((r) => r.status === 'warn') ? 'WARN' : 'OK'} (${rows.filter((r) => r.status === 'ok').length}/${rows.length} ok)`);
}
function saveRecord() {
  C.writeJSON(RECORD, { ...rec, pcName: PC, vault: path.resolve(VAULT), kit: KIT, version: VERSION, installedAt: rec.installedAt || new Date().toISOString(), updatedAt: new Date().toISOString() });
}

// ---- commands ---------------------------------------------------------------------------------------------------
if (cmd === 'install' || cmd === 'check') {
  fs.mkdirSync(GOGO_HOME, { recursive: true });
  const fixed = [];
  const errors = [];
  const tryStep = async (name, fn) => {
    try { const r = await fn(); if (r) fixed.push(r); } catch (e) { errors.push(`${name}: ${e.message}`); }
  };
  if (cmd === 'install') {
    saveRecord();
    await tryStep('CLAUDE.md', stepClaudeMd);
    await tryStep('스킬', stepSkills);
    await tryStep('보관함', stepVault);
    await tryStep('설정', stepSettings);
    if (!SKIP.has('caveman')) await tryStep('caveman', stepCaveman);
    await tryStep('옵시디언 등록', stepObsidianRegister);
    if (!SKIP.has('obsidian-app')) await tryStep('옵시디언 앱', stepObsidianApp);
    if (!SKIP.has('npm')) await tryStep('디스코드 부품', stepDiscordDeps);
    if (!SKIP.has('autostart')) await tryStep('자동 시작', stepAutostart);
    if (creds().token && !SKIP.has('autostart')) await tryStep('봇', botStart);
  }
  let rows = await checks();
  if (args.fix) {
    for (const r of rows.filter((x) => x.status !== 'ok' && x.fix)) await tryStep(r.label, r.fix);
    if (fixed.length || errors.length) rows = await checks();
  }
  if (cmd === 'check' && fixed.length) saveRecord();
  printTable(rows, fixed);
  if (errors.length) console.log(`\n고치다 막힌 것:\n${errors.map((e) => `- ${e}`).join('\n')}`);
  process.exitCode = rows.some((r) => r.status === 'fail') ? 1 : 0;
} else if (cmd === 'discord-setup') {
  // returns the exit code (no process.exit() after network use — it can crash Node on Windows)
  process.exitCode = await (async () => {
    const token = str(args.token).trim();
    if (!token) { console.error('사용법: node gogo.mjs discord-setup --token <봇 토큰> [--guild <서버 id>]'); return 1; }
    let me;
    try { me = await api(token, 'GET', '/users/@me'); } catch (e) {
      console.error(e.status === 401 ? '❌ 토큰이 틀려요 (개발자 포털 Bot 탭 → Reset Token 으로 새로 복사)' : `❌ 디스코드 연결 실패 (회사 네트워크가 막는지 확인): ${e.message}`);
      return 1;
    }
    const app = await api(token, 'GET', '/applications/@me').catch(() => null);
    const invite = `https://discord.com/oauth2/authorize?client_id=${app?.id || me.id}&scope=bot&permissions=${BOT_PERMISSIONS}`;
    let guild = str(args.guild);
    if (!guild) {
      const gs = await api(token, 'GET', '/users/@me/guilds');
      if (gs.length === 1) guild = gs[0].id;
      else if (!gs.length) {
        saveEnv({ DISCORD_TOKEN: token });
        console.log(`⚠️ 봇 ${me.username} 이(가) 아직 어느 서버에도 없어요. 이 링크로 서버에 초대한 뒤 이 명령을 다시:\n${invite}`);
        return 2;
      } else {
        console.log(`봇이 서버 ${gs.length}개에 있어요 — --guild 로 하나 골라 주세요:\n${gs.map((x) => `  ${x.id}  ${x.name}`).join('\n')}`);
        return 2;
      }
    }
    let g;
    try { g = await api(token, 'GET', `/guilds/${guild}`); } catch (e) { console.error(`❌ 서버 ${guild} 에 봇이 없어요 (${e.message})\n초대 링크: ${invite}`); return 1; }
    saveEnv({ DISCORD_TOKEN: token, DISCORD_GUILD_ID: guild });
    const mc = Boolean(((app && app.flags) || 0) & MESSAGE_CONTENT_FLAGS);
    console.log(`✅ 저장함 (${fwd(ENV_FILE)}, 토큰은 화면에 안 보임) — 봇 ${me.username} · 서버 「${g.name}」`);
    console.log(mc ? '✅ Message Content Intent 켜짐' : '⚠️ Message Content Intent 꺼짐 → 개발자 포털 Bot 탭에서 켜기 (답장 글 읽기)');
    if (!discordDepsOk()) console.log(stepDiscordDeps());
    if (WIN) stepAutostart();
    try { console.log(`✅ ${await botStart()} — 디스코드에 「클로드」 카테고리(#답변대기 #결과물-피드백 #알림)가 생겨요`); } catch (e) { console.log(`❌ ${e.message}`); return 1; }
    return 0;
  })();
} else if (cmd === 'bot') {
  const op = args._[0];
  try {
    if (op === 'start') console.log(await botStart());
    else if (op === 'stop') console.log(await botStop());
    else {
      const st = readJSON(STATE, {});
      console.log(botAlive() ? `켜짐 · ${st.bot || ''} · pid ${st.pid} · 마지막 신호 ${st.heartbeat}` : `꺼짐${st.lastError ? ` · 오류: ${st.lastError}` : ''} · 로그 ${fwd(LOG)}`);
    }
  } catch (e) { console.log(`❌ ${e.message}`); process.exitCode = 1; }
} else {
  console.log(fs.readFileSync(fileURLToPath(import.meta.url), 'utf8').split('\n').filter((l) => l.startsWith('//')).join('\n'));
}
