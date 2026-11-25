// Claude 세션 ↔ 사용자 디스코드 (의존성 X). 질문·결과물은 상주 봇(bot.mjs)이 올리고, 알림·채널 정리는 여기서 바로 디스코드에 보낸다.
//
//   node ask.mjs post --from "<세션 이름>" --title "질문 한 줄" [--text "설명"] [--options "추천안|다른 안"] [--recommend 0]
//                     [--no-free] [--files a.png,b.pdf] [--topic 업무이름] [--wait]
//        → #답변대기에 버튼 질문 (추천안 = 파란 버튼). 질문 id 출력. --wait 이면 답이 올 때까지 기다렸다가 답을 출력.
//   node ask.mjs show --from "<세션 이름>" --title "무엇" --text "봐 주실 곳: ...\n궁금한 점: ..." --files out.png[,b.mp4] [--topic X]
//        → #결과물-피드백에 실제 결과물. 사용자가 👍 / 👎 / ✏️ 피드백 쓰기 / 답장(글·그림)으로 여러 번 피드백.
//   node ask.mjs next --from "<세션 이름>"     그 세션의 다음 답/피드백이 올 때까지 기다림 (run_in_background로 하나만 켜 두고, 끝나면 다시).
//                                             출력: "ANSWER <id> | 질문 | 답 | 직접 쓴 글" / "FEEDBACK <id> | 결과물 | 👍·👎·글 | 내용 | files: ..."
//   node ask.mjs answers [--from "<세션 이름>"] 아직 안 받은 답·피드백 전부 (새 세션이 처음에 한 번)
//   node ask.mjs wait <id> [--timeout-min N] | list [--all] | cancel <id> | status
//   node ask.mjs notify "알림 내용" [--topic X | --channel 채널이름] [--files a.png]     → #알림 (봇이 꺼져 있어도 감)
//   node ask.mjs channel list
//   node ask.mjs channel create <이름> [--category 카테고리] [--topic "채널 설명"]
//   node ask.mjs channel rename <이름> <새 이름> [--category C]
//   node ask.mjs channel move <이름> --to <카테고리> [--category C]
//   node ask.mjs channel describe <이름> "채널 설명" [--category C]
//   node ask.mjs channel archive <이름> [--category C]        → 「보관함」 카테고리로 옮김 (지우지 않음 = 정리)
//   node ask.mjs channel delete <이름> --yes [--category C]   → 진짜 삭제 (사용자가 "삭제"라고 한 것만)
//   node ask.mjs category create <이름> | category rename <이름> <새 이름> | category delete <이름> --yes (빈 카테고리만)
//   (공통) --topic 업무이름 → 그 업무 카테고리의 #업무이름-답변대기 / -결과물-피드백 / -알림 (없으면 만듦). 없으면 「클로드」 카테고리.
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import {
  QDIR, DDIR, TMP, STATE, CORE, ARCHIVE, TOPIC_TEXT, placeOf, chanName, sameCat, readJSON, writeJSON, sleep, cut,
  creds, botAlive, api, ensureChannel,
} from './common.mjs';

for (const d of [QDIR, DDIR, TMP]) fs.mkdirSync(d, { recursive: true });
const qPath = (id) => path.join(QDIR, `${id}.json`);
const dPath = (id) => path.join(DDIR, `${id}.json`);
const LIMIT = 9.5 * 1024 * 1024;
const BOT_HINT = '  (경고: 디스코드 봇 신호가 없음 — node <키트>/gogo.mjs bot start)';

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
const mine = (q) => !str(args.from) || q.from === args.from;
const one = (s) => String(s || '').replace(/\r?\n/g, ' ');
const topic = str(args.topic).trim();
const newId = () => 'q' + new Date().toISOString().slice(2, 10).replace(/-/g, '') + '-' + crypto.randomBytes(2).toString('hex');
// Errors are thrown and printed at the end: process.exit() right after a fetch can crash Node on Windows (libuv assertion).
class Fail extends Error {}
const fail = (msg) => { throw new Fail(msg); };

function line(q) {
  const a = q.answer || {};
  return `ANSWER ${q.id} | ${q.title} | ${a.label ?? ''} | ${one(a.text)}${a.files?.length ? ` | files: ${a.files.join(';')}` : ''}`;
}
function fbLine(q, f) {
  const kind = f.kind === 'up' ? '👍 좋아요' : f.kind === 'down' ? '👎 별로예요' : '글';
  return `FEEDBACK ${q.id} | ${q.title} | ${kind} | ${one(f.text)}${f.files?.length ? ` | files: ${f.files.join(';')}` : ''}`;
}

/** Answers and feedback not yet handed over (and marks them handed over). */
function collect() {
  const out = [];
  for (const f of fs.readdirSync(QDIR).filter((x) => x.endsWith('.json'))) {
    const q = readJSON(path.join(QDIR, f));
    if (!q || !mine(q)) continue;
    if (q.type === 'show') {
      const fb = q.feedback || [];
      const d = readJSON(dPath(q.id), { fb: 0 });
      if (fb.length > d.fb) {
        for (const x of fb.slice(d.fb)) out.push(fbLine(q, x));
        writeJSON(dPath(q.id), { fb: fb.length });
      }
    } else if (q.status === 'answered' && !q.delivered) {
      q.delivered = true;
      writeJSON(path.join(QDIR, f), q);
      out.push(line(q));
    }
  }
  return out;
}
const pendingCount = () => fs.readdirSync(QDIR).map((f) => readJSON(path.join(QDIR, f)))
  .filter((q) => q && q.type !== 'show' && ['new', 'posted'].includes(q.status) && mine(q)).length;

async function wait(id, timeoutMin) {
  const end = timeoutMin ? Date.now() + timeoutMin * 60000 : Infinity;
  while (Date.now() < end) {
    const q = readJSON(qPath(id));
    if (!q) { console.log(`ERR no question ${id}`); process.exit(2); }
    if (q.status === 'answered') { q.delivered = true; writeJSON(qPath(id), q); console.log(line(q)); return; }
    if (q.status === 'cancelled') { console.log(`CANCELLED ${id}`); return; }
    await sleep(2000);
  }
  console.log(`TIMEOUT ${id}`);
  process.exit(3);
}

/** A copy of a video that fits Discord's upload limit (the original when it already fits; null when it cannot). Needs ffmpeg for videos. */
function fit(file, id) {
  if (!fs.existsSync(file)) return null;
  if (fs.statSync(file).size <= LIMIT) return file;
  if (!/\.(mp4|mov|webm|mkv)$/i.test(file)) return null;
  const pr = spawnSync('ffprobe', ['-v', 'error', '-show_entries', 'format=duration', '-of', 'csv=p=0', file], { encoding: 'utf8' });
  if (pr.error) return null;
  const dur = Math.max(1, parseFloat(pr.stdout) || 60);
  let kbps = Math.floor((LIMIT * 8 / 1000) / dur * 0.9) - 96;
  if (kbps < 120) return null;
  const out = path.join(TMP, `${id}_${path.basename(file).replace(/\.[^.]+$/, '')}.mp4`);
  for (const h of [720, 480]) {
    spawnSync('ffmpeg', ['-v', 'error', '-y', '-i', file, '-vf', `scale=-2:${h}`, '-c:v', 'libx264', '-b:v', `${kbps}k`, '-maxrate', `${kbps}k`,
      '-bufsize', `${kbps * 2}k`, '-c:a', 'aac', '-b:a', '96k', out]);
    if (fs.existsSync(out) && fs.statSync(out).size <= LIMIT) return out;
    kbps = Math.floor(kbps * 0.7);
  }
  return null;
}

function needCreds() {
  const c = creds();
  if (!c.token || !c.guild) fail('디스코드 토큰이 아직 없어요 → node <키트>/gogo.mjs discord-setup --token <봇 토큰>');
  return c;
}

/** Text channel by name (optionally inside a category). Exactly one match or an error that lists the choices. */
async function findChannel(token, guild, name, category) {
  const chs = await api(token, 'GET', `/guilds/${guild}/channels`);
  const cats = Object.fromEntries(chs.filter((c) => c.type === 4).map((c) => [c.id, c.name]));
  let hits = chs.filter((c) => c.type !== 4 && c.name === chanName(name));
  if (category) hits = hits.filter((c) => sameCat(cats[c.parent_id], category));
  if (!hits.length) fail(`채널 #${chanName(name)} 을(를) 못 찾았어요${category ? ` (카테고리 ${category})` : ''}. → node ask.mjs channel list`);
  if (hits.length > 1) fail(`#${chanName(name)} 이(가) 여러 카테고리에 있어요: ${hits.map((c) => cats[c.parent_id] || '(없음)').join(', ')} → --category 로 골라 주세요`);
  return { ch: hits[0], chs, cats };
}
async function findCategory(token, guild, name, chs) {
  return (chs || await api(token, 'GET', `/guilds/${guild}/channels`)).find((c) => c.type === 4 && sameCat(c.name, name));
}
async function ensureCategory(token, guild, name) {
  return (await findCategory(token, guild, name)) || api(token, 'POST', `/guilds/${guild}/channels`, { name, type: 4 });
}

async function main() {
if (cmd === 'post') {
  if (!args.title) fail('--title 필요');
  const id = newId();
  const options = str(args.options).split('|').map((s) => s.trim()).filter(Boolean);
  writeJSON(qPath(id), {
    id, from: args.from || 'Claude', title: String(args.title), text: str(args.text).replace(/\\n/g, '\n'),
    options, recommend: args.recommend !== undefined ? Number(args.recommend) : null, allow_free: !args['no-free'], topic,
    files: str(args.files).split(',').map((s) => s.trim()).filter(Boolean).map((f) => path.resolve(f)), status: 'new', created: new Date().toISOString(),
  });
  console.log(`QUESTION ${id} (#${placeOf('ask', topic).name})${botAlive() ? '' : BOT_HINT}`);
  if (args.wait) await wait(id, Number(args['timeout-min']) || 0);
} else if (cmd === 'show') {
  if (!args.title || !str(args.files)) fail('--title 과 --files 필요');
  const id = newId();
  const wanted = str(args.files).split(',').map((s) => s.trim()).filter(Boolean).map((f) => path.resolve(f));
  const missing = wanted.filter((f) => !fs.existsSync(f));
  if (missing.length) fail(`NOT POSTED: 파일이 없습니다 → ${missing.join(', ')}  (전체 경로로 주세요)`);
  const files = [];
  const notes = [];
  for (const f of wanted) {
    const g = fit(f, id);
    if (g) files.push(g); else notes.push(`(첨부 못 함: ${path.basename(f)} — 10MB가 넘음)`);
  }
  if (!files.length) fail('NOT POSTED: 올릴 수 있는 파일이 없습니다 (10MB가 넘음)');
  writeJSON(qPath(id), {
    id, type: 'show', topic, from: args.from || 'Claude', title: String(args.title),
    text: [str(args.text).replace(/\\n/g, '\n'), ...notes].filter(Boolean).join('\n'), files, feedback: [], status: 'new', created: new Date().toISOString(),
  });
  console.log(`SHOWN ${id} (${files.length} files, #${placeOf('show', topic).name})${botAlive() ? '' : BOT_HINT}`);
} else if (cmd === 'wait') {
  await wait(args._[0], Number(args['timeout-min']) || 0);
} else if (cmd === 'next') {
  const end = args['timeout-min'] ? Date.now() + Number(args['timeout-min']) * 60000 : Infinity;
  for (;;) {
    const got = collect();
    if (got.length) { console.log(got.join('\n')); console.log(`PENDING ${pendingCount()}`); break; }
    if (Date.now() > end) { console.log('TIMEOUT'); process.exit(3); }
    await sleep(2000);
  }
} else if (cmd === 'answers') {
  const got = collect();
  console.log(got.length ? got.join('\n') : 'NONE');
} else if (cmd === 'list') {
  for (const f of fs.readdirSync(QDIR).filter((x) => x.endsWith('.json')).sort()) {
    const q = readJSON(path.join(QDIR, f));
    if (!q || (!args.all && !['new', 'posted'].includes(q.status))) continue;
    const tail = q.type === 'show' ? `  (결과물, 피드백 ${(q.feedback || []).length}개)` : q.answer ? '  → ' + q.answer.label : '';
    console.log(`${q.id}  ${q.status.padEnd(8)}  [${q.from}] ${q.title}${tail}`);
  }
} else if (cmd === 'cancel') {
  const q = readJSON(qPath(args._[0]));
  if (!q) { console.log('없는 항목'); process.exit(2); }
  q.status = 'cancelled';
  writeJSON(qPath(q.id), q);
  console.log(`CANCELLED ${q.id}`);
} else if (cmd === 'status') {
  const s = readJSON(STATE, {});
  console.log(botAlive()
    ? `봇 살아 있음 (마지막 신호 ${s.heartbeat}, 대기 질문 ${s.pending ?? '?'}개)`
    : `봇 신호 없음 (마지막 ${s.heartbeat || '없음'}${s.lastError ? `, 오류: ${s.lastError}` : ''})`);
} else if (cmd === 'notify') {
  const { token, guild } = needCreds();
  const text = args._.join(' ').replace(/\\n/g, '\n').trim();
  if (!text) fail('알림 내용이 비었어요: node ask.mjs notify "내용"');
  const place = str(args.channel) ? { category: topic || CORE, name: str(args.channel), kind: 'alert' } : placeOf('alert', topic);
  const ch = await ensureChannel(token, guild, { ...place, topic: TOPIC_TEXT.alert });
  const files = str(args.files).split(',').map((s) => s.trim()).filter(Boolean).map((f) => path.resolve(f)).filter((f) => fs.existsSync(f) && fs.statSync(f).size <= LIMIT).slice(0, 10);
  const parts = [];
  let buf = '';
  for (const l of text.split('\n')) { if ((buf + l).length > 1900) { parts.push(buf); buf = ''; } buf += l + '\n'; }
  if (buf.trim()) parts.push(buf);
  for (let i = 0; i < parts.length; i++) {
    const last = i === parts.length - 1;
    await api(token, 'POST', `/channels/${ch.id}/messages`, { content: parts[i] }, last ? files : undefined);
  }
  console.log(`SENT #${ch.name}`);
} else if (cmd === 'channel' || cmd === 'category') {
  const { token, guild } = needCreds();
  const [op, a, b] = args._;
  const category = str(args.category);
  if (cmd === 'channel' && op === 'list') {
    const chs = (await api(token, 'GET', `/guilds/${guild}/channels`)).sort((x, y) => x.position - y.position);
    const cats = chs.filter((c) => c.type === 4);
    const icon = (c) => (c.type === 2 ? '🔊' : c.type === 15 ? '🗂' : '#');
    const loose = chs.filter((c) => c.type !== 4 && !c.parent_id);
    if (loose.length) console.log(`📁 (카테고리 없음)\n${loose.map((c) => `   ${icon(c)} ${c.name}`).join('\n')}`);
    for (const k of cats) {
      const kids = chs.filter((c) => c.parent_id === k.id);
      console.log(`📁 ${k.name}${kids.length ? '' : '  (비어 있음)'}${kids.length ? '\n' + kids.map((c) => `   ${icon(c)} ${c.name}${c.topic ? `  — ${cut(c.topic, 50)}` : ''}`).join('\n') : ''}`);
    }
  } else if (cmd === 'channel' && op === 'create') {
    if (!a) fail('채널 이름이 필요해요');
    const ch = await ensureChannel(token, guild, { category: category || CORE, name: a, topic: str(args.topic) });
    console.log(`OK #${ch.name} (카테고리 ${category || CORE})`);
  } else if (cmd === 'channel' && op === 'rename') {
    if (!a || !b) fail('사용법: channel rename <이름> <새 이름>');
    const { ch } = await findChannel(token, guild, a, category);
    const r = await api(token, 'PATCH', `/channels/${ch.id}`, { name: b });
    console.log(`OK #${ch.name} → #${r.name}`);
  } else if (cmd === 'channel' && op === 'move') {
    if (!a || !str(args.to)) fail('사용법: channel move <이름> --to <카테고리>');
    const { ch } = await findChannel(token, guild, a, category);
    const to = await ensureCategory(token, guild, str(args.to));
    await api(token, 'PATCH', `/channels/${ch.id}`, { parent_id: to.id });
    console.log(`OK #${ch.name} → 📁 ${to.name}`);
  } else if (cmd === 'channel' && op === 'describe') {
    if (!a || !b) fail('사용법: channel describe <이름> "설명"');
    const { ch } = await findChannel(token, guild, a, category);
    await api(token, 'PATCH', `/channels/${ch.id}`, { topic: b });
    console.log(`OK #${ch.name} 설명 바꿈`);
  } else if (cmd === 'channel' && op === 'archive') {
    if (!a) fail('채널 이름이 필요해요');
    const { ch } = await findChannel(token, guild, a, category);
    const to = await ensureCategory(token, guild, ARCHIVE);
    await api(token, 'PATCH', `/channels/${ch.id}`, { parent_id: to.id });
    console.log(`OK #${ch.name} → 📁 ${ARCHIVE} (지우지 않음, 다시 꺼내려면 channel move ${ch.name} --to <카테고리>)`);
  } else if (cmd === 'channel' && op === 'delete') {
    if (!a) fail('채널 이름이 필요해요');
    if (!args.yes) fail('진짜 지우려면 --yes 를 붙여 주세요 (지운 채널과 글은 되살릴 수 없어요. 정리만 하려면 channel archive)');
    const { ch } = await findChannel(token, guild, a, category);
    await api(token, 'DELETE', `/channels/${ch.id}`);
    console.log(`DELETED #${ch.name}`);
  } else if (cmd === 'category' && op === 'create') {
    if (!a) fail('카테고리 이름이 필요해요');
    const k = await ensureCategory(token, guild, a);
    console.log(`OK 📁 ${k.name}`);
  } else if (cmd === 'category' && op === 'rename') {
    if (!a || !b) fail('사용법: category rename <이름> <새 이름>');
    const k = await findCategory(token, guild, a);
    if (!k) fail(`카테고리 ${a} 없음`);
    await api(token, 'PATCH', `/channels/${k.id}`, { name: b });
    console.log(`OK 📁 ${k.name} → ${b}`);
  } else if (cmd === 'category' && op === 'delete') {
    if (!a) fail('카테고리 이름이 필요해요');
    if (!args.yes) fail('지우려면 --yes (빈 카테고리만 지워요)');
    const chs = await api(token, 'GET', `/guilds/${guild}/channels`);
    const k = await findCategory(token, guild, a, chs);
    if (!k) fail(`카테고리 ${a} 없음`);
    const kids = chs.filter((c) => c.parent_id === k.id);
    if (kids.length) fail(`카테고리 ${k.name} 안에 채널 ${kids.length}개가 있어요 (${kids.map((c) => c.name).join(', ')}) → 먼저 옮기거나 보관하세요`);
    await api(token, 'DELETE', `/channels/${k.id}`);
    console.log(`DELETED 📁 ${k.name}`);
  } else fail('channel list|create|rename|move|describe|archive|delete · category create|rename|delete');
} else {
  console.log(fs.readFileSync(fileURLToPath(import.meta.url), 'utf8').split('\n').filter((l) => l.startsWith('//')).join('\n'));
}
}
main().catch((e) => { console.error(e instanceof Fail ? e.message : `❌ ${e.message}`); process.exitCode = 1; });
