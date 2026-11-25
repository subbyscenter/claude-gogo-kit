// gogo 키트 디스코드 봇 (이 PC에 하나, 자동 시작 루프가 켜 둠).
// 1) 질문: Claude 세션이 ask.mjs post 로 ~/.gogo/data/q/<id>.json 을 만들면 #답변대기에 버튼 질문으로 올리고,
//    버튼·반응(1️⃣~🔟, ✅/👍=추천안)·✏️ 직접 쓰기·답장으로 온 답을 그 파일에 적는다. 채널 맨 아래엔 늘 「답변 대기 N개」 목록.
// 2) 결과물: ask.mjs show 로 만든 항목은 #결과물-피드백에 파일과 함께 올리고 👍 / 👎 / ✏️ / 답장을 피드백으로 쌓는다.
// 3) 채널: --topic 업무이름 이면 「업무이름」 카테고리와 채널을 처음 쓸 때 만든다.
// 종료 코드(자동 시작 루프용): 3 = 이미 다른 봇이 돎 / 멈춤 요청 → 루프 끝, 4 = 토큰 없음, 5 = 로그인 실패.
import fs from 'node:fs';
import path from 'node:path';
import {
  Client, GatewayIntentBits, Partials, Events, ChannelType, ActionRowBuilder, ButtonBuilder, ButtonStyle,
  ModalBuilder, TextInputBuilder, TextInputStyle, AttachmentBuilder,
} from 'discord.js';
import {
  QDIR, FBFILES, STATE, LOG, STOP_FILE, CH, TOPIC_TEXT, MESSAGE_CONTENT_FLAGS, placeOf, chanName, sameCat,
  readJSON, writeJSON, cut, creds, api,
} from './common.mjs';

fs.mkdirSync(QDIR, { recursive: true });
fs.mkdirSync(FBFILES, { recursive: true });
const log = (...a) => { try { fs.appendFileSync(LOG, `${new Date().toISOString()} ${a.join(' ')}\n`); } catch {} };
const state = () => readJSON(STATE, {});
const setState = (o) => writeJSON(STATE, { ...state(), ...o });
const qPath = (id) => path.join(QDIR, `${id}.json`);
const allQ = () => fs.readdirSync(QDIR).filter((f) => f.endsWith('.json')).map((f) => readJSON(path.join(QDIR, f))).filter(Boolean)
  .sort((a, b) => (a.created || '').localeCompare(b.created || ''));
const isShow = (q) => q.type === 'show';
const fbLabel = (f) => (f.kind === 'up' ? '👍 좋아요' : f.kind === 'down' ? '👎 별로예요' : `“${cut(f.text || '(그림)', 120)}”`);
const NUM = ['1️⃣', '2️⃣', '3️⃣', '4️⃣', '5️⃣', '6️⃣', '7️⃣', '8️⃣', '9️⃣', '🔟'];

// ---- start-up guards -------------------------------------------------------------------------------------------
if (fs.existsSync(STOP_FILE)) { log('stop file present — not starting'); process.exit(3); }
const { token, guild } = creds();
if (!token || !guild) { log('no token/guild in ~/.gogo/.env'); setState({ lastError: '토큰 없음 (gogo.mjs discord-setup)' }); process.exit(4); }
{
  const s = state();
  let other = false;
  try { if (s.pid && s.pid !== process.pid) { process.kill(s.pid, 0); other = true; } } catch (e) { other = e.code === 'EPERM'; }
  if (other && s.heartbeat && Date.now() - Date.parse(s.heartbeat) < 30000) { log('another bot is running', s.pid); process.exit(3); }
}

// Read replies' text even without an @mention only when the Message Content intent is on in the developer portal
// (asking for it while it is off makes the login fail).
let messageContent = false;
try { messageContent = Boolean(((await api(token, 'GET', '/applications/@me')).flags || 0) & MESSAGE_CONTENT_FLAGS); } catch (e) { log('app flags', e.message); }

const client = new Client({
  intents: [GatewayIntentBits.Guilds, GatewayIntentBits.GuildMessages, GatewayIntentBits.GuildMessageReactions,
    ...(messageContent ? [GatewayIntentBits.MessageContent] : [])],
  partials: [Partials.Message, Partials.Channel, Partials.Reaction],
});
let busy = Promise.resolve();
const serial = (fn) => (busy = busy.then(fn).catch((e) => log('ERR', e.stack || e.message)));

// ---- channels --------------------------------------------------------------------------------------------------
const chans = {}; // "category/name" → channel (re-checked: deleted or moved away → found or made again)
async function channel(kind, topic) {
  const { category, name } = placeOf(kind, topic);
  const key = `${category}/${name}`;
  const c0 = chans[key];
  if (c0 && client.channels.cache.has(c0.id) && sameCat(c0.parent?.name, category)) return c0;
  const g = await client.guilds.fetch(guild);
  const chs = [...(await g.channels.fetch()).values()].filter(Boolean);
  let parent = chs.find((x) => x.type === ChannelType.GuildCategory && sameCat(x.name, category));
  if (!parent) parent = await g.channels.create({ name: category, type: ChannelType.GuildCategory });
  let c = chs.find((x) => x.type === ChannelType.GuildText && x.parentId === parent.id && x.name === chanName(name));
  if (!c) { c = await g.channels.create({ name, type: ChannelType.GuildText, topic: TOPIC_TEXT[kind], parent: parent.id }); log('made channel', name); }
  return (chans[key] = c);
}
const askPlace = (q) => placeOf('ask', q.topic);
const keyOf = (p) => `${p.category}/${p.name}`;
const messageOf = async (q) => (await client.channels.fetch(q.posted.channel)).messages.fetch(q.posted.message);

function body(q) {
  if (isShow(q)) {
    const fb = q.feedback || [];
    const tail = fb.length ? `\n💬 **피드백 ${fb.length}개 전달됨** — 마지막: ${fbLabel(fb[fb.length - 1])}` : '';
    return cut(`🎬 **${q.title}**\n-# ${q.from || 'Claude'} · ${q.id}\n${q.text || ''}${tail}`, 1990);
  }
  const opts = (q.options || []).map((o, i) => `${NUM[i] || `${i + 1}.`} ${o}${q.recommend === i ? '  ← 추천' : ''}`).join('\n');
  const head = q.status === 'answered' ? `✅ **답변함: ${q.answer.label}${q.answer.text ? ` — ${cut(q.answer.text, 300)}` : ''}**\n` : '';
  return cut(`${head}❓ **${q.title}**\n-# ${q.from || 'Claude'} · ${q.id}\n${q.text ? q.text + '\n' : ''}${opts ? '\n' + opts : ''}`, 1990);
}

// Button ids start with "g" (gask:/gfb:) so they never clash with another bot that uses ask:/fb:.
function buttons(q) {
  if (isShow(q)) {
    return [new ActionRowBuilder().addComponents(
      new ButtonBuilder().setCustomId(`gfb:${q.id}:up`).setLabel('👍 좋아요').setStyle(ButtonStyle.Success),
      new ButtonBuilder().setCustomId(`gfb:${q.id}:down`).setLabel('👎 별로예요').setStyle(ButtonStyle.Danger),
      new ButtonBuilder().setCustomId(`gfb:${q.id}:write`).setLabel('✏️ 피드백 쓰기').setStyle(ButtonStyle.Primary))];
  }
  if (q.status === 'answered') return [];
  const rows = [];
  let row = new ActionRowBuilder();
  (q.options || []).slice(0, 20).forEach((o, i) => {
    if (row.components.length === 5) { rows.push(row); row = new ActionRowBuilder(); }
    row.addComponents(new ButtonBuilder().setCustomId(`gask:${q.id}:${i}`).setLabel(cut(`${i + 1}. ${o}`, 80))
      .setStyle(q.recommend === i ? ButtonStyle.Primary : ButtonStyle.Secondary));
  });
  if (q.allow_free !== false) {
    if (row.components.length === 5) { rows.push(row); row = new ActionRowBuilder(); }
    row.addComponents(new ButtonBuilder().setCustomId(`gask:${q.id}:free`).setLabel('✏️ 직접 쓰기').setStyle(ButtonStyle.Success));
  }
  if (row.components.length) rows.push(row);
  return rows.slice(0, 5);
}

async function postNew() {
  const changed = new Map();
  for (const q of allQ().filter((x) => x.status === 'new')) {
    const c = await channel(isShow(q) ? 'show' : 'ask', q.topic);
    const files = (q.files || []).filter((f) => fs.existsSync(f)).slice(0, 10).map((f) => new AttachmentBuilder(f));
    let m;
    try { m = await c.send({ content: body(q), components: buttons(q), files }); } catch (e) {
      log('send failed', q.id, e.message);                       // usually a file over the upload limit: post without files, say so
      m = await c.send({ content: cut(body(q) + '\n(첨부 실패: 파일이 너무 큼)', 1990), components: buttons(q) });
    }
    Object.assign(q, { status: 'posted', posted: { channel: c.id, message: m.id, url: m.url, at: new Date().toISOString() } });
    writeJSON(qPath(q.id), q);
    log('posted', q.id, q.title);
    if (!isShow(q)) changed.set(keyOf(askPlace(q)), q.topic);
  }
  for (const q of allQ().filter((x) => x.status === 'cancelled' && x.posted && !x.cancel_done)) {   // ask.mjs cancel
    try { const m = await messageOf(q); await m.edit({ content: cut(`🚫 **거둔 ${isShow(q) ? '결과물' : '질문'}** ~~${q.title}~~`, 1990), components: [] }); } catch {}
    q.cancel_done = true;
    writeJSON(qPath(q.id), q);
    if (!isShow(q)) changed.set(keyOf(askPlace(q)), q.topic);
  }
  for (const t of changed.values()) await refreshIndex(t);
}

// The 「답변 대기 N개」 list at the bottom of each ask channel (that channel's questions only).
async function refreshIndex(topic) {
  const place = placeOf('ask', topic);
  const key = keyOf(place);
  const c = await channel('ask', topic);
  const pend = allQ().filter((q) => q.status === 'posted' && !isShow(q) && keyOf(askPlace(q)) === key);
  const indexes = state().indexes || {};
  if (indexes[key]) { try { await (await c.messages.fetch(indexes[key])).delete(); } catch {} }
  let content;
  const components = [];
  if (!pend.length) content = '📮 **답변 대기 없음** ✅ 모두 답하셨어요.';
  else {
    const lines = pend.map((q, i) => `${i + 1}. ${cut(q.title, 70)} → ${q.posted.url}`);
    content = cut(`📮 **답변 대기 ${pend.length}개** — 위에서부터 하나씩 (누르면 그 질문으로 이동)\n${lines.join('\n')}`, 1990);
    components.push(new ActionRowBuilder().addComponents(
      new ButtonBuilder().setStyle(ButtonStyle.Link).setURL(pend[0].posted.url).setLabel(cut(`▶ 다음 질문: ${pend[0].title}`, 80))));
  }
  const m = await c.send({ content, components });
  setState({ indexes: { ...indexes, [key]: m.id }, ...(topic ? {} : { pending: pend.length }) });
}

function nextLink(exceptId) {
  const me = readJSON(qPath(exceptId)) || {};
  const n = allQ().find((q) => q.status === 'posted' && !isShow(q) && q.id !== exceptId && keyOf(askPlace(q)) === keyOf(askPlace(me)));
  return n ? `다음 질문 → ${n.posted.url}` : '남은 질문 없음 🎉';
}

async function answer(id, a) {
  const q = readJSON(qPath(id));
  if (!q || isShow(q) || q.status !== 'posted') return null;
  q.status = 'answered';
  q.answer = { ...a, at: new Date().toISOString() };
  q.delivered = false;
  writeJSON(qPath(id), q);
  log('answered', id, a.label, a.via);
  try { const m = await messageOf(q); await m.edit({ content: body(q), components: [] }); } catch (e) { log('edit failed', id, e.message); }
  await refreshIndex(q.topic);
  return q;
}

async function addFeedback(id, f) {
  const q = readJSON(qPath(id));
  if (!q || !isShow(q) || q.status !== 'posted') return null;
  (q.feedback = q.feedback || []).push({ ...f, at: new Date().toISOString() });
  writeJSON(qPath(id), q);
  log('feedback', id, f.kind, f.via);
  try { const m = await messageOf(q); await m.edit({ content: body(q), components: buttons(q) }); } catch (e) { log('edit failed', id, e.message); }
  return q;
}

client.on(Events.InteractionCreate, (i) => serial(async () => {
  if (i.isButton() && i.customId.startsWith('gask:')) {
    const [, id, k] = i.customId.split(':');
    const q = readJSON(qPath(id));
    if (!q || q.status !== 'posted') { await i.reply({ content: '이미 답한 질문이에요.', ephemeral: true }).catch(() => {}); return; }
    if (k === 'free') {
      const modal = new ModalBuilder().setCustomId(`gaskm:${id}`).setTitle(cut(q.title, 45));
      modal.addComponents(new ActionRowBuilder().addComponents(new TextInputBuilder().setCustomId('text').setLabel('답변 (그대로 Claude에게 전달돼요)')
        .setStyle(TextInputStyle.Paragraph).setRequired(true).setMaxLength(1500)));
      await i.showModal(modal);
      return;
    }
    const idx = Number(k);
    await i.deferReply({ ephemeral: true });
    await answer(id, { choice: idx, label: q.options[idx], text: '', via: 'button', by: i.user.username });
    await i.editReply(`전달했어요 ✅ (${cut(q.options[idx], 60)})\n${nextLink(id)}`).catch(() => {});
  } else if (i.isModalSubmit() && i.customId.startsWith('gaskm:')) {
    const id = i.customId.split(':')[1];
    const text = i.fields.getTextInputValue('text');
    await i.deferReply({ ephemeral: true });
    const q = await answer(id, { choice: null, label: '직접 쓴 답', text, via: 'modal', by: i.user.username });
    await i.editReply(q ? `전달했어요 ✅\n${nextLink(id)}` : '이미 답한 질문이에요.').catch(() => {});
  } else if (i.isButton() && i.customId.startsWith('gfb:')) {
    const [, id, k] = i.customId.split(':');
    const q = readJSON(qPath(id));
    if (!q || q.status !== 'posted') { await i.reply({ content: '이 결과물은 더 이상 피드백을 받지 않아요.', ephemeral: true }).catch(() => {}); return; }
    if (k === 'write') {
      const modal = new ModalBuilder().setCustomId(`gfbm:${id}`).setTitle(cut(q.title, 45));
      modal.addComponents(new ActionRowBuilder().addComponents(new TextInputBuilder().setCustomId('text').setLabel('피드백 (그대로 담당 Claude에게 전달돼요)')
        .setStyle(TextInputStyle.Paragraph).setRequired(true).setMaxLength(1800)));
      await i.showModal(modal);
      return;
    }
    await i.deferReply({ ephemeral: true });
    await addFeedback(id, { kind: k === 'up' ? 'up' : 'down', text: '', via: 'button', by: i.user.username });
    await i.editReply(`전달했어요 ${k === 'up' ? '👍' : '👎'} — 더 하실 말이 있으면 ✏️ 피드백 쓰기 (여러 번 써도 돼요)`).catch(() => {});
  } else if (i.isModalSubmit() && i.customId.startsWith('gfbm:')) {
    const id = i.customId.split(':')[1];
    const text = i.fields.getTextInputValue('text');
    await i.deferReply({ ephemeral: true });
    const q = await addFeedback(id, { kind: 'text', text, via: 'modal', by: i.user.username });
    await i.editReply(q ? '전달했어요 ✅ 담당 Claude가 바로 받아요.' : '이 결과물은 더 이상 피드백을 받지 않아요.').catch(() => {});
  }
}));

client.on(Events.MessageReactionAdd, (r, user) => serial(async () => {
  if (user.bot) return;
  if (r.partial) await r.fetch().catch(() => {});
  const q = allQ().find((x) => x.status === 'posted' && x.posted?.message === r.message.id);
  if (!q) return;
  const e = r.emoji.name;
  if (isShow(q)) {
    if (e === '👍' || e === '👎') await addFeedback(q.id, { kind: e === '👍' ? 'up' : 'down', text: '', via: 'reaction', by: user.username });
    return;
  }
  let idx = NUM.indexOf(e);
  if (['✅', '👍', '👌'].includes(e)) idx = q.recommend ?? (q.options?.length === 1 ? 0 : -1);
  if (idx < 0 || idx >= (q.options || []).length) return;
  await answer(q.id, { choice: idx, label: q.options[idx], text: '', via: 'reaction', by: user.username });
}));

// A reply to a question or a result: its text and pictures become the answer / feedback.
client.on(Events.MessageCreate, (msg) => serial(async () => {
  if (msg.author.bot || !msg.reference?.messageId) return;
  const q = allQ().find((x) => x.status === 'posted' && x.posted?.message === msg.reference.messageId);
  if (!q) return;
  const text = (msg.content || '').replace(/<@!?\d+>/g, '').trim();
  const files = [];
  let n = 0;
  for (const a of msg.attachments.values()) {
    try {
      const buf = Buffer.from(await (await fetch(a.url)).arrayBuffer());
      const f = path.join(FBFILES, `${q.id}_${Date.now()}_${n++}_${(a.name || 'file').replace(/[^\w.\-가-힣]/g, '_')}`);
      fs.writeFileSync(f, buf);
      files.push(f);
    } catch (e) { log('attachment failed', q.id, e.message); }
  }
  if (!text && !files.length) {
    await msg.reply('글이 안 보였어요. ✏️ 버튼으로 써 주세요.').catch(() => {});
    return;
  }
  const ok = isShow(q)
    ? await addFeedback(q.id, { kind: 'text', text, files, via: 'reply', by: msg.author.username })
    : await answer(q.id, { choice: null, label: '직접 쓴 답', text, files, via: 'reply', by: msg.author.username });
  if (ok) await msg.react('✅').catch(() => {});
}));

// Ending without process.exit() right after network use: on Windows that can crash Node (libuv assertion) and lose the exit code.
const timers = [];
function quit(code) {
  timers.forEach(clearInterval);
  client.destroy();
  process.exitCode = code;
  setTimeout(() => process.exit(code), 5000).unref();
}

client.once(Events.ClientReady, async (c) => {
  log('ready', c.user.tag, messageContent ? '(message content on)' : '(message content off)');
  setState({ heartbeat: new Date().toISOString(), pid: process.pid, bot: c.user.tag, lastError: null, messageContent });
  await serial(async () => {
    for (const kind of Object.keys(CH)) await channel(kind, '');   // the 「클로드」 category with #답변대기 #결과물-피드백 #알림
    await postNew();
    if (!(state().indexes || {})[keyOf(placeOf('ask', ''))]) await refreshIndex('');
  });
  timers.push(setInterval(() => serial(postNew), 2000));
  timers.push(setInterval(() => {
    if (fs.existsSync(STOP_FILE)) { log('stop requested'); setState({ heartbeat: null }); quit(3); return; }
    setState({ heartbeat: new Date().toISOString(), pid: process.pid });
  }, 10000));
});
client.on('error', (e) => log('client error', e.message));
client.login(token).catch((e) => {
  const msg = /intent/i.test(e.message) ? 'Message Content Intent 문제 (개발자 포털 Bot 탭 확인)'
    : /token/i.test(e.message) ? '토큰이 틀림 (개발자 포털에서 Reset Token 후 gogo.mjs discord-setup)' : e.message;
  log('login failed', e.message);
  setState({ lastError: msg });
  quit(5);
});
