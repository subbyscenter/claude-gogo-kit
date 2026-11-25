// Shared by ask.mjs (Claude sessions), bot.mjs (the resident Discord bot) and ../gogo.mjs (setup + health check).
// No dependencies: Discord REST calls use the global fetch of Node 18+.
// Everything this PC keeps (token, questions, answers, logs) lives in GOGO_HOME (default ~/.gogo), never in the kit folder.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

export const GOGO_HOME = process.env.GOGO_HOME || path.join(os.homedir(), '.gogo');
export const ENV_FILE = path.join(GOGO_HOME, '.env');
export const DATA = path.join(GOGO_HOME, 'data');
export const QDIR = path.join(DATA, 'q');          // one JSON file per question / shown result
export const DDIR = path.join(DATA, 'd');          // what ask.mjs already handed to its session
export const TMP = path.join(DATA, 'tmp');
export const FBFILES = path.join(DATA, 'fbfiles');  // pictures the user attached to answers / feedback
export const STATE = path.join(DATA, 'state.json'); // bot heartbeat, pid, last error, index message ids
export const LOG = path.join(DATA, 'bot.log');
export const STOP_FILE = path.join(GOGO_HOME, 'bot.stop');

// Channel layout: core channels live in the 「클로드」 category; `--topic 회계` gets its own 「회계」 category
// with #회계-답변대기 / #회계-결과물-피드백 / #회계-알림 (made on first use). Archived channels go to 「보관함」.
export const CORE = process.env.GOGO_CATEGORY || '클로드';
export const ARCHIVE = process.env.GOGO_ARCHIVE || '보관함';
export const CH = { ask: '답변대기', show: '결과물-피드백', alert: '알림' };
export const TOPIC_TEXT = {
  ask: 'Claude가 답을 기다리는 질문만 올라와요. 버튼·반응·✏️ 직접 쓰기·답장으로 답하면 바로 Claude에게 전달돼요. 맨 아래 목록에서 다음 질문으로 이동.',
  show: 'Claude가 만든 결과물(그림·영상·파일). 👍 / 👎 / ✏️ 피드백 쓰기, 또는 그 메시지에 답장하면 담당 Claude에게 바로 전달돼요.',
  alert: 'Claude 작업 알림: 오래 걸린 일이 끝남·실패·확인이 필요함.',
};
export const placeOf = (kind, topic) => (topic
  ? { category: topic, name: `${topic}-${CH[kind]}`, kind }
  : { category: CORE, name: CH[kind], kind });
/** How Discord stores a text-channel name (lowercase, spaces → hyphens). */
export const chanName = (s) => String(s).trim().toLowerCase().replace(/\s+/g, '-');
export const sameCat = (a, b) => String(a || '').trim().toLowerCase() === String(b || '').trim().toLowerCase();

// Bot permissions the invite link asks for (no Administrator): View Channels, Manage Channels, Send Messages,
// Embed Links, Attach Files, Read Message History, Add Reactions.
export const BOT_PERMISSIONS = 1024 + 16 + 2048 + 16384 + 32768 + 65536 + 64; // 117840
export const MESSAGE_CONTENT_FLAGS = (1 << 18) | (1 << 19); // app flags: Message Content intent on (verified or limited)

export const readJSON = (f, d = null) => { try { return JSON.parse(fs.readFileSync(f, 'utf8').replace(/^﻿/, '')); } catch { return d; } };
export const writeJSON = (f, o) => {
  fs.mkdirSync(path.dirname(f), { recursive: true });
  const t = `${f}.tmp${process.pid}`;
  fs.writeFileSync(t, JSON.stringify(o, null, 1));
  fs.renameSync(t, f);
};
export const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
export const cut = (s, n) => (String(s).length > n ? String(s).slice(0, n - 1) + '…' : String(s));

/** KEY=VALUE lines of ~/.gogo/.env (quotes stripped). */
export function loadEnv(file = ENV_FILE) {
  const out = {};
  let text = '';
  try { text = fs.readFileSync(file, 'utf8').replace(/^﻿/, ''); } catch { return out; }
  for (const line of text.split(/\r?\n/)) {
    const m = line.match(/^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)\s*$/);
    if (m) out[m[1]] = m[2].replace(/^(['"])(.*)\1$/, '$2').trim();
  }
  return out;
}
export function saveEnv(values, file = ENV_FILE) {
  const cur = loadEnv(file);
  const next = { ...cur, ...values };
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, Object.entries(next).map(([k, v]) => `${k}=${v}`).join('\n') + '\n');
}
/** Bot token + server id. The file wins; GOGO_DISCORD_TOKEN / GOGO_DISCORD_GUILD_ID are for tests only. */
export function creds() {
  const e = loadEnv();
  return {
    token: (e.DISCORD_TOKEN || process.env.GOGO_DISCORD_TOKEN || '').trim(),
    guild: (e.DISCORD_GUILD_ID || process.env.GOGO_DISCORD_GUILD_ID || '').trim(),
  };
}

export function botAlive() {
  const s = readJSON(STATE, {});
  return Boolean(s.heartbeat && Date.now() - Date.parse(s.heartbeat) < 60000);
}

/** Discord REST v10 call. `files` = local paths sent as attachments (multipart). Retries on 429. */
export async function api(token, method, route, body, files) {
  for (let attempt = 0; attempt < 6; attempt++) {
    const init = { method, headers: { Authorization: `Bot ${token}`, 'User-Agent': 'DiscordBot (https://github.com/subbyscenter/claude-gogo-kit, 1.0)' }, signal: AbortSignal.timeout(20000) };
    if (files?.length) {
      const fd = new FormData();
      fd.append('payload_json', JSON.stringify(body || {}));
      files.forEach((f, i) => fd.append(`files[${i}]`, new Blob([fs.readFileSync(f)]), path.basename(f)));
      init.body = fd;
    } else if (body !== undefined) {
      init.headers['Content-Type'] = 'application/json';
      init.body = JSON.stringify(body);
    }
    const r = await fetch(`https://discord.com/api/v10${route}`, init);
    const text = await r.text();
    let data = null;
    try { data = text ? JSON.parse(text) : null; } catch { data = { message: text }; }
    if (r.status === 429) { await sleep(((data && data.retry_after) || 1) * 1000 + 200); continue; }
    if (!r.ok) {
      const e = new Error(cut(`${r.status} ${data?.message || text}`, 300));
      e.status = r.status;
      e.code = data?.code;
      throw e;
    }
    return data;
  }
  throw new Error('Discord rate limit: 잠시 뒤 다시');
}

/** Text channel `name` inside category `category` (both made if missing), over REST. */
export async function ensureChannel(token, guild, { category, name, topic }) {
  const chs = await api(token, 'GET', `/guilds/${guild}/channels`);
  let cat = chs.find((c) => c.type === 4 && sameCat(c.name, category));
  if (!cat) cat = await api(token, 'POST', `/guilds/${guild}/channels`, { name: category, type: 4 });
  const ch = chs.find((c) => c.type === 0 && c.parent_id === cat.id && c.name === chanName(name));
  return ch || api(token, 'POST', `/guilds/${guild}/channels`, { name, type: 0, parent_id: cat.id, ...(topic ? { topic } : {}) });
}
