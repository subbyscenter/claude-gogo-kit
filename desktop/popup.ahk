; gogo 바로가기 창 — the shortcuts popup with today's quests and the calendar (desktop.ahk binds it to Ctrl+Shift+F;
; preview.ahk shows it for a check).
#Requires AutoHotkey v2.0

; ~\.gogo (or GOGO_HOME): the list and its icons live in desktop\ there (never in the kit folder); the vault comes from
; install.json, which gogo.mjs writes.
GOGO_HOME := EnvGet("GOGO_HOME") != "" ? EnvGet("GOGO_HOME") : EnvGet("USERPROFILE") "\.gogo"
DATA_DIR := GOGO_HOME "\desktop"
SHORTCUTS := DATA_DIR "\shortcuts.txt"
ICON_CACHE := DATA_DIR "\icons-cache"   ; favicons fetched from the pages
BROWSER := FindBrowser()                ; Chrome or Edge: {exe, name, data}
VAULT := GogoVault(GOGO_HOME "\install.json") || EnvGet("USERPROFILE") "\obsidian_vault"
; 오늘의 퀘스트 (화면 오른쪽 위) · 달력 (위쪽 가운데) = 보관함의 노트 두 개. 빈 곳이나 「편집」을 누르면 옵시디언에서 열림.
QUEST_MD := VAULT "\내 일정\오늘의 퀘스트.md"
CAL_MD := VAULT "\내 일정\일정.md"
; 서버 (servers.ahk): 꺼진 로컬 페이지는 눌렀을 때 숨겨서 켜고, 켜진 서버 수·끄기. node = gogo.mjs가 알려 준 것(GOGO_NODE).
SERVERS_DIR := DATA_DIR
SERVERS_JS := A_ScriptDir "\servers.mjs"
NODE := EnvGet("GOGO_NODE") != "" ? EnvGet("GOGO_NODE") : "node.exe"

EditShortcuts() {
  HideShortcuts()
  Run('notepad.exe "' SHORTCUTS '"')
}

OpenFolder() {
  HideShortcuts()
  DirCreate(DATA_DIR)
  Run('explorer.exe "' DATA_DIR '"')
}

; ---------- the popup ----------
global popup := 0, items := [], hover := 0, selected := 0, panel := 0, posX := 0, posY := 0
global checks := Map(), checkStart := 0, lastUp := Map(), misses := 0, focused := true
; mode = "" / "order" (drag icons) / "edit" (click one to edit); drag = the icon being dragged; dialog = the open
; add/edit/group dialog; prevWindow = the window in front before the popup; holdUntil = keep the popup open until.
global mode := "", hoverButton := "", drag := 0, dialog := 0, prevWindow := 0, holdUntil := 0, tabWindow := false
; sections = the categories in order, [{name, items}]; items = all their shortcuts in that order (item.si = its section).
; hoverHead = the section whose heading the mouse is on. A drag is {item, si, pos, ...} or, for a heading, {cat: true, si, ...}.
global sections := [], hoverHead := 0
; The quest window: shown with the popup at the top right of the main screen (never takes the focus, so the
; popup stays open while its link buttons are clicked). questLinks = the link buttons painted last time.
; questRows = the quest rows painted last time (a click ticks one).
global questInfo := ParseQuestNote(""), questStamp := "", questWin := 0, questLinks := [], questRows := [], questHover := 0, questPos := 0
; calMonth = the shown month "yyyyMM" (this month each time the popup opens); calEvents = date -> [{cat, title, status}].
global calEvents := Map(), calStamp := "", calWin := 0, calMonth := "", calButtons := []

PopupVisible() => popup && DllCall("IsWindowVisible", "ptr", popup.Hwnd)

; Reads the quest note again when it changed (or the day did). True if it did. The first look on a new day unticks
; every quest in the note (once: the note is stamped with the day).
LoadQuests() {
  global questInfo, questStamp
  today := FormatTime(, "yyyy-MM-dd")
  stamp := FileExist(QUEST_MD) ? FileGetTime(QUEST_MD) "|" FileGetSize(QUEST_MD) : "none"
  if stamp = questStamp && (stamp = "none" || questInfo.date = today)
    return false
  questStamp := stamp, text := ReadNote(QUEST_MD), info := ParseQuestNote(text)
  if text != "" && info.date != today {
    text := ResetQuestText(text, today)
    if WriteNote(QUEST_MD, text)
      questStamp := FileGetTime(QUEST_MD) "|" FileGetSize(QUEST_MD), info := ParseQuestNote(text)
    else
      info.date := today   ; could not write: try again the next time the note changes
  }
  info.day := DayLabel(), questInfo := info
  return true
}

; A click on a quest: one more done (a complete one goes back to 0); delta -1 (right click): one less. Saved in the note.
BumpQuest(r, delta) {
  global questStamp
  text := ReadNote(QUEST_MD), nl := InStr(text, "`r`n") ? "`r`n" : "`n", lines := StrSplit(text, "`n", "`r")
  q := r.line <= lines.Length ? ParseQuestLine(lines[r.line]) : ""
  if !q || q.label != r.label {
    questStamp := "", LoadQuests(), questWin && ShowQuests()
    return Flash("목록이 바뀌어서 다시 읽었어요 — 한 번 더 눌러 주세요")
  }
  lines[r.line] := SetQuestLine(lines[r.line], delta > 0 ? (q.done >= q.target ? 0 : q.done + 1) : q.done - 1)
  if !WriteNote(QUEST_MD, JoinLines(lines, nl))
    return Flash("저장하지 못했어요: " QUEST_MD)
  questStamp := "", LoadQuests(), questWin && ShowQuests()   ; same second, same size: read it anyway
}

OpenQuestEditor() => OpenNote(QUEST_MD)

; A note of the vault in Obsidian (when it is installed), else in Notepad.
OpenNote(file) {
  HideShortcuts()
  if !FileExist(file)
    return Flash("노트가 없어요: " file "  (/gogo 로 다시 만들 수 있어요)")
  installed := false
  for key in ["HKCU\Software\Classes\obsidian\shell\open\command", "HKCR\obsidian\shell\open\command"]
    try installed := installed || RegRead(key) != ""
  if installed
    try return Run("obsidian://open?path=" UriEncode(file))
  try Run('notepad.exe "' file '"')
}

ToggleShortcuts() => PopupVisible() ? HideShortcuts() : ShowShortcuts()

; activate := false shows it without taking the focus (preview.ahk); it then stays open until hidden.
ShowShortcuts(activate := true) {
  global popup, items, hover, selected, panel, posX, posY, misses, focused := activate
  global mode := "", hoverButton := "", drag := 0, holdUntil := 0, tabWindow := false, prevWindow := WinExist("A")
  if !popup {
    ; A layered window: the painting carries its own alpha (round corners, shadow).
    popup := Gui("-Caption +E0x80000 +AlwaysOnTop +ToolWindow -DPIScale", "gogo 바로가기")
    OnMessage(0x0200, PopupMouseMove)    ; WM_MOUSEMOVE
    OnMessage(0x02A3, PopupMouseLeave)   ; WM_MOUSELEAVE
    OnMessage(0x0201, PopupMouseDown)    ; WM_LBUTTONDOWN
    OnMessage(0x0202, PopupClick)        ; WM_LBUTTONUP
    OnMessage(0x0215, PopupCaptureLost)  ; WM_CAPTURECHANGED
    OnMessage(0x0205, PopupMenu)         ; WM_RBUTTONUP
  }
  global sections := LoadSections(SHORTCUTS), hoverHead := 0
  Flatten()
  for item in items
    if lastUp.Has(item.target)
      item.up := lastUp[item.target]
  hover := 0, selected := 0, misses := 0
  LoadQuests()
  ShowQuests()
  global calMonth := FormatTime(, "yyyyMM")
  LoadCalendar()
  ShowCalendar()
  panel := Layout()
  ; Centred on the mouse, kept inside that screen.
  MouseGetPos(&mx, &my)
  m := MonitorRect(MonitorOfPoint(mx, my) || MonitorGetPrimary())
  posX := Max(m.l, Min(m.r - panel.w, mx - panel.w // 2)), posY := Max(m.t, Min(m.b - panel.h, my - panel.h // 2))
  popup.Show(Format("x{} y{} w{} h{}", posX, posY, panel.w, panel.h) (activate ? "" : " NA"))
  Paint()
  if activate
    WinActivate(popup.Hwnd)
  StartChecks()
  LoadServers()
  RefreshServers()
  SetTimer(Watch, 80)
}

HideShortcuts() {
  global hover
  SetTimer(Watch, 0)
  EndDrag()
  hover := 0
  if popup
    popup.Hide()
  if questWin
    questWin.Hide()
  if calWin
    calWin.Hide()
  if dialog
    dialog.cancel()
}

; items again from sections, after anything moved.
Flatten() {
  global items := []
  for si, sec in sections
    for item in sec.items
      item.si := si, items.Push(item)
}

FlatIndex(item) {
  for i, it in items
    if it = item
      return i
  return 0
}

; Sizes in physical pixels: the buttons on top, then each category — its heading (none for the one nameless section)
; and its icons in rows of up to six (an empty one keeps one row to drop into) — and the hovered one's name in the
; footer. tiles[i] = where items[i] sits; bands[si] = section si's heading and rows. minRows (while dragging) =
; ObjPtr(section) -> rows it keeps, so the sections do not jump under the mouse.
Layout(minRows := 0) {
  s := A_ScreenDPI / 96
  n := Max(items.Length, 1), cols := Min(6, n)
  d := Round(48 * s), gap := Round(16 * s), pad := Round(20 * s), foot := Round(28 * s), margin := Round(16 * s), head := Round(32 * s)
  hh := Round(28 * s), sgap := Round(12 * s)
  grid := cols * d + (cols - 1) * gap, pw := Max(pad * 2 + grid, Round(300 * s)), gx := margin + (pw - grid) // 2
  top := margin + pad + head, y := top, tiles := [], bands := []
  for si, sec in sections {
    h := sec.name != "" ? hh : 0, rows := Max(1, Ceil(sec.items.Length / cols))
    if minRows && minRows.Has(ObjPtr(sec))
      rows := Max(rows, minRows[ObjPtr(sec)])
    gy := y + h
    for k, item in sec.items
      tiles.Push({x: gx + Mod(k - 1, cols) * (d + gap), y: gy + ((k - 1) // cols) * (d + gap)})
    bottom := gy + rows * d + (rows - 1) * gap
    bands.Push({top: y, hh: h, gy: gy, rows: rows, bottom: bottom})
    y := bottom + sgap
  }
  ph := pad + head + (y - sgap - top) + Round(10 * s) + foot + Round(8 * s)
  return {s: s, cols: cols, d: d, gap: gap, pad: pad, foot: foot, margin: margin, radius: Round(22 * s), sgap: sgap,
    pw: pw, ph: ph, gx: gx, w: pw + margin * 2, h: ph + margin * 2, tiles: tiles, bands: bands}
}

; After the list grew or shrank: new size, same top-left corner (kept inside the screen).
Relayout() {
  global panel, posX, posY
  Flatten()
  panel := Layout()
  m := MonitorRect(MonitorOfPoint(posX + panel.margin, posY + panel.margin) || MonitorGetPrimary())
  posX := Max(m.l, Min(m.r - panel.w, posX)), posY := Max(m.t, Min(m.b - panel.h, posY))
  Paint()
}

TileRect(i) => panel.tiles[i]

; The section whose heading is at x, y (0 if none).
HeadAt(x, y) {
  if x < panel.margin || x > panel.margin + panel.pw
    return 0
  for si, b in panel.bands
    if b.hh && y >= b.top && y < b.top + b.hh
      return si
  return 0
}

; The section a point is in: the first whose rows end below it (half the gap between sections counts as above).
BandAt(y) {
  for si, b in panel.bands
    if y < b.bottom + panel.sgap / 2
      return si
  return panel.bands.Length
}

TileAt(x, y) {
  r := panel.d / 2 + 4 * panel.s
  for i, item in items {
    t := TileRect(i), cx := t.x + panel.d / 2, cy := t.y + panel.d / 2
    if (x - cx) ** 2 + (y - cy) ** 2 <= r ** 2
      return i
  }
  return 0
}

; Where the dragged icon goes: {si, pos} = the section under the point and the slot nearest it there.
DropAt(x, y) {
  si := BandAt(y), b := panel.bands[si], step := panel.d + panel.gap
  col := Max(0, Min(panel.cols - 1, Round((x - panel.gx - panel.d / 2) / step)))
  row := Max(0, Min(b.rows - 1, Round((y - b.gy - panel.d / 2) / step)))
  count := sections[si].items.Length + (si = drag.si ? 0 : 1)
  return {si: si, pos: Max(1, Min(count, row * panel.cols + col + 1))}
}

; Where a dragged heading goes: after every other section whose middle is above the point.
HeadDropAt(y) {
  at := 1
  for si, b in panel.bands
    if si != drag.si && (b.top + b.bottom) / 2 < y
      at++
  return at
}

; The round buttons at the top right (Segoe MDL2 glyphs): add, new category, order, edit, group.
ToolButtons() {
  static specs := [["add", 0xE710, "새 바로가기"], ["category", 0xE8F4, "새 카테고리"]
    , ["order", 0xE8CB, "순서 바꾸기  ·  아이콘·카테고리 이름 끌기"], ["edit", 0xE70F, "편집  ·  아이콘이나 카테고리 이름을 누르기"]
    , ["group", 0xE8B9, "그룹 만들기  ·  크롬 창의 탭을 한 번에 여는 바로가기"]]
  s := panel.s, d := Round(28 * s), step := d + Round(6 * s)
  x := panel.margin + panel.pw - Round(14 * s) - specs.Length * step + Round(6 * s), y := panel.margin + Round(14 * s)
  list := []
  for spec in specs
    list.Push({id: spec[1], glyph: Chr(spec[2]), tip: spec[3], x: x + (A_Index - 1) * step, y: y, d: d})
  return list
}

ButtonAt(x, y) {
  if ServerPillAt(x, y)
    return "servers"
  for b in ToolButtons()
    if (x - b.x - b.d / 2) ** 2 + (y - b.y - b.d / 2) ** 2 <= (b.d / 2 + 2 * panel.s) ** 2
      return b.id
  return ""
}

PressButton(id) {
  if id = "servers"
    return ShowServers()
  if id = "add"
    return EditShortcut(0, hoverHead || (selected ? items[selected].si : 0))
  if id = "category"
    return EditCategory(0)
  if id = "group"
    return MakeGroup()
  SetMode(mode = id ? "" : id)
}

SetMode(value) {
  global mode
  mode := value
  Paint()
}

; ---------- the quest window ----------
QuestRowHeight(r, s) => r.cat ? Round(28 * s) : Round(40 * s) + (r.links.Length ? Round(30 * s) : 0)

QuestLayout() {
  s := A_ScreenDPI / 96, margin := Round(16 * s), pad := Round(18 * s), head := Round(32 * s), foot := Round(26 * s)
  body := questInfo.rows.Length ? 0 : Round(60 * s)
  for r in questInfo.rows
    body += QuestRowHeight(r, s)
  pw := Round(340 * s), ph := pad + head + body + foot + Round(6 * s)
  return {s: s, margin: margin, pad: pad, head: head, foot: foot, pw: pw, ph: ph, w: pw + margin * 2, h: ph + margin * 2}
}

; Top right of the main screen's work area (half the shadow margin may hang off the edge).
ShowQuests() {
  global questWin, questPos, questHover := 0
  if !questWin
    questWin := Gui("-Caption +E0x80000 +E0x08000000 +AlwaysOnTop +ToolWindow -DPIScale", "gogo 오늘의 퀘스트")  ; layered, no-activate
  L := QuestLayout(), m := MonitorRect(MonitorGetPrimary())
  questPos := {x: m.r - L.w + Round(L.margin / 2), y: m.t + Round(L.margin / 2), L: L}
  questWin.Show(Format("x{} y{} w{} h{} NA", questPos.x, questPos.y, L.w, L.h))
  PaintQuests()
}

; ---------- 달력 (top centre of the main screen) ----------
; 일정.md (lib.ahk ParseCalendarNote): 기간 일정은 시작일~끝날 모든 날짜에 같은 일정을 넣는다(기간 하이라이트).
LoadCalendar() {
  global calEvents, calStamp
  today := FormatTime(, "yyyy-MM-dd")
  stamp := (FileExist(CAL_MD) ? FileGetTime(CAL_MD) "|" FileGetSize(CAL_MD) : "none") "|" today   ; 지남 changes with the day
  if stamp = calStamp
    return false
  calStamp := stamp, calEvents := Map()
  for e in ParseCalendarNote(ReadNote(CAL_MD), today) {
    d := StrReplace(e.start, "-"), e.long := DateDiff(StrReplace(e.end, "-"), d, "Days") > 14
    loop 400 {  ; 시작일부터 끝날까지 하루씩 (2주 넘는 긴 기간은 첫날·마지막날만)
      key := FormatTime(d, "yyyy-MM-dd")
      if !calEvents.Has(key)
        calEvents[key] := []
      if !e.long || key = e.start || key = e.end
        calEvents[key].Push(e)
      if key = e.end
        break
      d := DateAdd(d, 1, "Days")
    }
  }
  return true
}

; 목록용 날짜 글자: 하루짜리 "11/19 (목)", 기간 "11/17~19 (화~목)", 달 넘김 "11/30~12/2".
CalRangeLabel(e) {
  s := StrReplace(e.start, "-"), t := StrReplace(e.end, "-"), wd := "일월화수목금토"
  sw := SubStr(wd, Integer(FormatTime(s, "WDay")), 1), tw := SubStr(wd, Integer(FormatTime(t, "WDay")), 1)
  a := Integer(SubStr(s, 5, 2)) "/" Integer(SubStr(s, 7, 2))
  if s = t
    return a " (" sw ")"
  b := SubStr(s, 1, 6) = SubStr(t, 1, 6) ? Integer(SubStr(t, 7, 2)) "" : Integer(SubStr(t, 5, 2)) "/" Integer(SubStr(t, 7, 2))
  return a "~" b " (" sw "~" tw ")"
}

; n = -1 / +1 months, 0 = back to this month.
CalMove(n) {
  global calMonth
  if !calWin || !DllCall("IsWindowVisible", "ptr", calWin.Hwnd)
    return
  if n = 0
    calMonth := FormatTime(, "yyyyMM")
  else {
    y := Integer(SubStr(calMonth, 1, 4)), m := Integer(SubStr(calMonth, 5, 2)) + n
    y += m > 12 ? 1 : m < 1 ? -1 : 0, m := m > 12 ? 1 : m < 1 ? 12 : m
    calMonth := y Format("{:02}", m)
  }
  ShowCalendar()
}

OpenCalendarBig() => OpenNote(CAL_MD)

; Category colours (background, text): one of six, picked by the category's name; done / past ones grey.
CalColor(e) {
  static pairs := [[0xFFE0F2FE, 0xFF0369A1], [0xFFFCE7F3, 0xFFBE185D], [0xFFDCFCE7, 0xFF15803D], [0xFFFEF3C7, 0xFFB45309]
    , [0xFFEDE9FE, 0xFF6D28D9], [0xFFFEE2E2, 0xFFB91C1C]]
  if e.status = "완료" || e.status = "지남"
    return [0xFFF1F2F5, 0xFF9AA0AC]
  if e.cat = ""
    return [0xFFF1F5F9, 0xFF475569]
  hash := 0
  loop parse e.cat
    hash := Mod(hash * 31 + Ord(A_LoopField), 1000003)
  return pairs[Mod(hash, pairs.Length) + 1]
}

ShowCalendar() {
  global calWin, calButtons := []
  if !calMonth
    return
  if !calWin
    calWin := Gui("-Caption +E0x80000 +E0x08000000 +AlwaysOnTop +ToolWindow -DPIScale", "gogo 달력")  ; layered, no-activate
  s := A_ScreenDPI / 96, margin := Round(16 * s), pad := Round(18 * s), r0 := Round(22 * s)
  first := calMonth "01", lead := Integer(FormatTime(first, "WDay")) - 1
  days := Integer(FormatTime(DateAdd(SubStr(DateAdd(first, 31, "Days"), 1, 6) "01", -1, "Days"), "d"))
  rows := Ceil((lead + days) / 7), y4 := SubStr(calMonth, 1, 4), mm := SubStr(calMonth, 5, 2), today := FormatTime(, "yyyy-MM-dd")
  list := [], seen := Map()
  loop days {
    day := A_Index, key := y4 "-" mm "-" Format("{:02}", day)
    if calEvents.Has(key)
      for e in calEvents[key]
        if !seen.Has(ObjPtr(e))  ; 기간 일정은 목록에 한 번만
          seen[ObjPtr(e)] := 1, list.Push({day: day, key: key, e: e})
  }
  shown := Min(list.Length, 6)
  pw := Round(560 * s), cw := (pw - pad * 2) / 7, chh := Round(58 * s), head := Round(36 * s), dow := Round(22 * s), lh := Round(20 * s)
  ph := pad + head + dow + rows * chh + Round(12 * s) + Round(22 * s) + Max(1, shown) * lh + (list.Length > shown ? lh : 0) + Round(26 * s)
  w := pw + margin * 2, h := ph + margin * 2, m := MonitorRect(MonitorGetPrimary())
  x0 := m.l + (m.r - m.l - w) // 2, y0 := m.t + Round(margin / 2)
  calWin.Show(Format("x{} y{} w{} h{} NA", x0, y0, w, h))
  c := Canvas(w, h)
  loop 10 {
    k := 11 - A_Index
    c.RoundRect(margin - k, margin - k + Round(4 * s), pw + k * 2, ph + k * 2, r0 + k, (A_Index * 2) << 24)
  }
  c.RoundRect(margin, margin, pw, ph, r0, 0xFFFFFFFF)
  c.RoundBorder(margin + 0.5, margin + 0.5, pw - 1, ph - 1, r0, 0xFFE4E6EB)
  x := margin + pad, y := margin + pad, iw := pw - pad * 2
  c.Text(y4 "년 " Integer(mm) "월", x, y, iw * 0.4, Round(26 * s), 15 * s, 0xFF1F2430, true, , 0)
  ; buttons, right to left: 편집 ▶ 오늘 ◀
  bx := x + iw, bh := Round(26 * s)
  for b in [["big", "편집"], ["next", "▶"], ["today", "오늘"], ["prev", "◀"]] {
    bw := Round(TextWidth(b[2], 11 * s) + 22 * s), bx -= bw
    c.RoundRect(bx, y, bw, bh, bh / 2, b[1] = "big" ? 0xFFEC4899 : 0xFFFCE7F3)
    c.Text(b[2], bx, y, bw, bh, 11 * s, b[1] = "big" ? 0xFFFFFFFF : 0xFFBE185D, true)
    calButtons.Push({x: bx, y: y, w: bw, h: bh, act: b[1]}), bx -= Round(6 * s)
  }
  y += head
  for i, d in ["일", "월", "화", "수", "목", "금", "토"]
    c.Text(d, x + (i - 1) * cw, y, cw, dow, 10.5 * s, i = 1 ? 0xFFDC2626 : i = 7 ? 0xFF2563EB : 0xFF8A90A0, true)
  y += dow
  loop days {
    cell := lead + A_Index - 1, cx := x + Mod(cell, 7) * cw, cy := y + (cell // 7) * chh, key := y4 "-" mm "-" Format("{:02}", A_Index)
    c.RoundRect(cx + 1 * s, cy + 1 * s, cw - 2 * s, chh - 2 * s, 6 * s, Mod(cell, 2) ? 0xFFFAFAFB : 0xFFF6F7F9)
    nd := Round(20 * s), col := Mod(cell, 7)
    if key = today
      c.Circle(cx + 3 * s, cy + 3 * s, nd, 0xFFEC4899)
    c.Text(A_Index "", cx + 3 * s, cy + 3 * s, nd, nd, 10 * s, key = today ? 0xFFFFFFFF : col = 0 ? 0xFFDC2626 : col = 6 ? 0xFF2563EB : 0xFF1F2430, true)
    if !calEvents.Has(key)
      continue
    ev := calEvents[key], ey := cy + Round(25 * s), eh := Round(13 * s)
    for e in ev  ; 기간(시작일~마감일) 안의 날짜 = 칸 테두리를 그 일정 색으로 강조
      if e.start != e.end && !e.long && e.status != "완료" && e.status != "지남" {
        c.RoundBorder(cx + 1.5 * s, cy + 1.5 * s, cw - 3 * s, chh - 3 * s, 6 * s, CalColor(e)[2])
        break
      }
    for i, e in ev {
      if i > 2 {
        c.Text("+" (ev.Length - 2), cx + cw - Round(22 * s), cy + 3 * s, Round(20 * s), nd, 9 * s, 0xFF8A90A0, true, , 2)
        break
      }
      k := CalColor(e)
      c.RoundRect(cx + 2 * s, ey, cw - 4 * s, eh, 3 * s, k[1])
      c.Text(e.title, cx + 3 * s, ey - 1 * s, cw - 6 * s, eh + 2 * s, 8 * s, k[2], true, , 0)
      ey += eh + Round(2 * s)
    }
  }
  y += rows * chh + Round(12 * s)
  c.Text("이번 달 일정 " list.Length "개", x, y, iw, Round(22 * s), 11.5 * s, 0xFF8A90A0, true, , 0)
  y += Round(22 * s)
  if !list.Length
    c.Text("일정 없음", x, y, iw, lh, 11.5 * s, 0xFFB0B5C0, false, , 0)
  loop shown {
    it := list[A_Index], k := CalColor(it.e), dl := Round(122 * s)
    c.Circle(x, y + lh / 2 - 4 * s, 8 * s, k[2])
    c.Text(CalRangeLabel(it.e), x + 14 * s, y, dl, lh, 11 * s, 0xFF1F2430, true, , 0)
    c.Text(it.e.title, x + 14 * s + dl + 2 * s, y, iw - 14 * s - dl - 2 * s, lh, 11 * s, StrCompare(it.e.end, today) < 0 ? 0xFF9AA0AC : 0xFF1F2430, false, , 0)
    y += lh
  }
  if list.Length > shown
    c.Text("… 외 " (list.Length - shown) "개 — 편집", x + 14 * s, y, iw, lh, 10.5 * s, 0xFF8A90A0, false, , 0)
  c.Text("◀ ▶ 또는 Shift+←/→ 로 달 넘기기  ·  편집 = 옵시디언 「내 일정/일정」", x, margin + ph - Round(26 * s), iw, Round(22 * s), 10 * s, 0xFFB0B5C0, false, , 0)
  c.Present(calWin.Hwnd, x0, y0)
}

; A rough text width (Hangul about one em, Latin a little over half) for the link pills.
TextWidth(text, size) {
  w := 0
  loop parse text
    w += Ord(A_LoopField) >= 0x1100 ? size : size * 0.6
  return w
}

; Today and done/all, then each category and its quests (check, name, count, bar, link buttons).
PaintQuests() {
  global questLinks := [], questRows := []
  if !questWin || !questPos
    return
  L := questPos.L, s := L.s, c := Canvas(L.w, L.h), r0 := Round(22 * s)
  loop 10 {
    k := 11 - A_Index
    c.RoundRect(L.margin - k, L.margin - k + Round(4 * s), L.pw + k * 2, L.ph + k * 2, r0 + k, (A_Index * 2) << 24)
  }
  c.RoundRect(L.margin, L.margin, L.pw, L.ph, r0, 0xFFFFFFFF)
  c.RoundBorder(L.margin + 0.5, L.margin + 0.5, L.pw - 1, L.ph - 1, r0, 0xFFE4E6EB)
  x := L.margin + L.pad, w := L.pw - L.pad * 2, y := L.margin + L.pad
  c.Text("오늘의 퀘스트  " questInfo.day, x, y, w * 0.7, Round(24 * s), 12.5 * s, 0xFFBE185D, true, , 0)
  c.Text("완료 " questInfo.complete " / " questInfo.total, x + w * 0.5, y, w * 0.5, Round(24 * s), 12.5 * s, 0xFFBE185D, true, , 2)
  y += L.head
  if !questInfo.rows.Length
    c.Text("아직 없어요  ·  빈 곳을 누르면 노트가 열려요", x, y, w, Round(60 * s), 12 * s, 0xFF8A90A0, false, , 0)
  for r in questInfo.rows {
    if r.cat {
      c.Text(r.label, x, y + 4 * s, w, Round(22 * s), 11.5 * s, 0xFF8A90A0, true, , 0)
      y += Round(28 * s)
      continue
    }
    ok := r.done >= r.target, cd := Round(18 * s), tx := x + cd + Round(8 * s), nw := Round(64 * s)
    if ok {
      c.Circle(x, y + 2 * s, cd, 0xFFEC4899)
      c.Text(Chr(0xE73E), x, y + 2 * s, cd, cd, 9 * s, 0xFFFFFFFF, false, "Segoe MDL2 Assets")
    } else
      c.Ring(x + 1 * s, y + 3 * s, cd - 2 * s, 0xFFC3C7CF, 1.5 * s)
    label := r.label
    c.Text(label, tx, y, w - (tx - x) - nw, Round(22 * s), 12.5 * s, ok ? 0xFF8A90A0 : 0xFF1F2430, false, , 0)
    c.Text(r.done " / " r.target, x + w - nw, y, nw, Round(22 * s), 12.5 * s, ok ? 0xFFEC4899 : 0xFF1F2430, true, , 2)
    bw := w - (tx - x), by := y + Round(27 * s), bh := Round(5 * s)
    c.RoundRect(tx, by, bw, bh, bh / 2, 0xFFEDF0F5)
    if r.done > 0
      c.RoundRect(tx, by, Max(bh, bw * Min(1, r.done / r.target)), bh, bh / 2, 0xFFEC4899)
    lx := tx, ly := y + Round(40 * s), lh := Round(22 * s)
    for link in r.links {
      lw := Round(TextWidth(link.label, 11 * s) + 20 * s)
      if lx + lw > x + w
        break
      on := questLinks.Length + 1 = questHover
      c.RoundRect(lx, ly, lw, lh, lh / 2, on ? 0xFFEC4899 : 0xFFFCE7F3)
      c.Text(link.label, lx, ly, lw, lh, 11 * s, on ? 0xFFFFFFFF : 0xFFBE185D, true)
      questLinks.Push({x: lx, y: ly, w: lw, h: lh, link: link})
      lx += lw + Round(6 * s)
    }
    questRows.Push({y: y, h: QuestRowHeight(r, s), r: r})
    y += QuestRowHeight(r, s)
  }
  tip := questHover ? questLinks[questHover].link.open : "누르면 체크  ·  오른쪽 클릭 −1  ·  빈 곳 = 편집"
  c.Text(tip, x, L.margin + L.ph - L.foot - 4 * s, w, L.foot, 11.5 * s, 0xFF8A90A0, false, , 0)
  c.Present(questWin.Hwnd, questPos.x, questPos.y)
}

QuestLinkAt(x, y) {
  for i, b in questLinks
    if x >= b.x && x <= b.x + b.w && y >= b.y && y <= b.y + b.h
      return i
  return 0
}

; The quest whose row is at x, y (0 if none).
QuestRowAt(x, y) {
  L := questPos.L
  if x < L.margin || x > L.margin + L.pw
    return 0
  for row in questRows
    if y >= row.y && y < row.y + row.h
      return row.r
  return 0
}

; A link opens like a shortcut: a shortcut of the list by its name (with its Chrome profile), else the address or path.
OpenQuestLink(link) {
  for item in items
    if item.name = link.open
      return OpenShortcut(item)
  if !ValidTarget(link.open)
    return Flash("바로가기를 찾지 못했어요: " link.open)
  OpenShortcut({name: link.label, target: link.open, profile: ""})
}

Paint() {
  if !popup || !panel
    return
  L := panel, s := L.s, c := Canvas(L.w, L.h)
  ; Soft shadow: stacked faint rounded rectangles, a little lower than the panel.
  loop 10 {
    k := 11 - A_Index
    c.RoundRect(L.margin - k, L.margin - k + Round(4 * s), L.pw + k * 2, L.ph + k * 2, L.radius + k, (A_Index * 2) << 24)
  }
  c.RoundRect(L.margin, L.margin, L.pw, L.ph, L.radius, 0xFFFFFFFF)
  c.RoundBorder(L.margin + 0.5, L.margin + 0.5, L.pw - 1, L.ph - 1, L.radius, 0xFFE4E6EB)
  tip := ""
  for b in ToolButtons() {
    on := b.id = mode
    if b.id = hoverButton
      tip := b.tip
    if on || b.id = hoverButton
      c.Circle(b.x, b.y, b.d, on ? 0xFF3B82F6 : 0xFFEDF0F5)
    c.Text(b.glyph, b.x, b.y, b.d, b.d, 13 * s, on ? 0xFFFFFFFF : 0xFF4B5263, false, "Segoe MDL2 Assets")
  }
  PaintServerPill(c, hoverButton = "servers")   ; servers.ahk: how many local servers run
  if hoverButton = "servers"
    tip := ServerTip()
  ; Category headings (a dragged one blue, a pointed one grey), and a dragged icon's target section tinted.
  for si, b in L.bands {
    sec := sections[si], x := L.margin + L.pad - 6 * s, w := L.pw - L.pad * 2 + 12 * s
    if drag && !drag.HasOwnProp("cat") && si = drag.si
      c.RoundRect(x, b.top - 4 * s, w, b.bottom - b.top + 10 * s, 12 * s, 0xFFEFF6FF)
    if !sec.items.Length && !items.Length   ; nothing at all yet
      c.Text(mode = "order" ? "여기로 끌어 놓기" : "오른쪽 위 ＋ 로 첫 바로가기를 넣어 보세요", L.margin + L.pad, b.gy, L.pw - L.pad * 2, L.d, 11.5 * s, 0xFFB0B5C0, false)
    else if !sec.items.Length
      c.Text(mode = "order" ? "여기로 끌어 놓기" : "비어 있음", L.gx, b.gy, L.cols * L.d + (L.cols - 1) * L.gap, L.d, 11.5 * s, 0xFFB0B5C0, false)
    if !b.hh
      continue
    dragged := drag && drag.HasOwnProp("cat") && si = drag.si
    if dragged || si = hoverHead
      c.RoundRect(x, b.top, w, b.hh - 4 * s, 8 * s, dragged ? 0xFF3B82F6 : 0xFFEDF0F5)
    grip := mode = "order" ? Round(18 * s) : 0
    if grip
      c.Text(Chr(0xE76F), x + 6 * s, b.top, grip, b.hh - 4 * s, 10 * s, dragged ? 0xFFFFFFFF : 0xFF8A90A0, false, "Segoe MDL2 Assets")
    c.Text(sec.name, x + 8 * s + grip, b.top, w * 0.7, b.hh - 4 * s, 11.5 * s, dragged ? 0xFFFFFFFF : 0xFF4B5263, true, , 0)
    c.Text(sec.items.Length "개", x, b.top, w - 8 * s, b.hh - 4 * s, 10.5 * s, dragged ? 0xFFFFFFFF : 0xFFB0B5C0, false, , 2)
  }
  for i, item in items {
    t := TileRect(i)
    if drag && drag.HasOwnProp("item") && item = drag.item {
      c.Ring(t.x + 2 * s, t.y + 2 * s, L.d - 4 * s, 0xFFC3C7CF, 1.5 * s)   ; where it will land
      continue
    }
    if i = hover || i = selected
      c.Circle(t.x - 6 * s, t.y - 6 * s, L.d + 12 * s, 0xFFEDF0F5)
    DrawIcon(c, item, t.x, t.y, L.d)
    if i = selected
      c.Ring(t.x - 5 * s, t.y - 5 * s, L.d + 10 * s, 0xFF3B82F6, 2 * s)
    if item.up != "" {
      dot := Round(12 * s), x := t.x + L.d - dot + 2 * s, y := t.y + L.d - dot + 2 * s
      c.Circle(x - 2 * s, y - 2 * s, dot + 4 * s, 0xFFFFFFFF)
      c.Circle(x, y, dot, item.up ? 0xFF22C55E : 0xFFC3C7CF)
    }
  }
  if drag && drag.HasOwnProp("item") {
    ; The dragged icon follows the mouse (inside the panel), lifted on a soft shadow.
    x := Max(L.margin, Min(L.margin + L.pw - L.d, drag.x - L.d / 2)), y := Max(L.margin, Min(L.margin + L.ph - L.d, drag.y - L.d / 2))
    c.Circle(x - 3 * s, y + 1 * s, L.d + 6 * s, 0x30000000)
    DrawIcon(c, drag.item, x, y, L.d)
  }
  focus := hover || selected
  strong := tip != "" || (focus && !drag) || (hoverHead && !drag)
  footer := tip != "" ? tip
    : drag ? (drag.HasOwnProp("cat") ? "놓은 자리로 카테고리가 옮겨져요" : "놓은 자리로 옮겨져요  ·  다른 카테고리에 놓아도 돼요")
    : focus ? items[focus].name "   " ShortTarget(items[focus].target) (items[focus].up = 0 ? "  · 꺼져 있음" : "")
    : hoverHead ? sections[hoverHead].name "  ·  " (mode = "order" ? "끌어서 카테고리 순서 바꾸기" : mode = "edit" ? "눌러서 이름 바꾸기·삭제" : "오른쪽 클릭 = 카테고리 메뉴")
    : mode = "order" ? "아이콘·카테고리 이름을 끌어서 옮기기  ·  Esc 끝"
    : mode = "edit" ? "고칠 바로가기나 카테고리 이름을 누르세요  ·  Esc 끝"
    : "클릭 열기  ·  Ctrl+클릭 탭  ·  Shift+클릭 새 창  ·  Esc 닫기"
  c.Text(footer, L.margin + 14 * s, L.margin + L.ph - L.foot - 6 * s, L.pw - 28 * s, L.foot, 12.5 * s, strong ? 0xFF1F2430 : 0xFF8A90A0, strong)
  c.Present(popup.Hwnd, posX, posY)
}

DrawIcon(c, item, x, y, d) {
  picture := item.picture != "" ? item.picture : IsGroup(item.target) ? "" : CachedIcon(item.target)
  image := picture != "" ? LoadPicture(picture) : 0
  if image && c.Picture(image, x, y, d)
    return
  c.Circle(x, y, d, 0xFF000000 | Integer("0x" ShortcutColor(item)))
  c.Text(ShortcutLabel(item.name), x, y, d, d, d * 0.38, 0xFFFFFFFF, true)
}

; how = "" opens it and closes the popup. Ctrl+click ("tab") and Shift+click ("window") keep the popup open for more:
; "tab" opens the page as a new tab of the Chrome window that was in front (if that was not Chrome: a new window
; first, then tabs in it), "window" a new window each time. A group opens as the tabs of a new window ("tab": as tabs).
OpenItem(i, how := "") {
  global tabWindow, holdUntil
  if i < 1 || i > items.Length
    return
  if mode = "edit"
    return EditShortcut(i)
  if mode = "order"
    return
  OpenShortcut(items[i], how)
}

OpenShortcut(item, how := "", started := false) {
  global tabWindow, holdUntil
  target := item.target, group := IsGroup(target)
  if !started && item.up = 0 && LocalPort(target) != "" {   ; servers.ahk: start it hidden, open when it answers
    if how = ""
      HideShortcuts()
    return StartThenOpen(item, how)
  }
  NoteUsed(target)
  if how = ""
    HideShortcuts()
  else
    holdUntil := A_TickCount + 1500   ; the browser takes the focus: the popup takes it back (Watch)
  if BROWSER.exe = "" && RegExMatch(target, "i)^https?://") {   ; neither Chrome nor Edge: Windows' default browser
    for page in StrSplit(target, " ")
      try Run(page)
    return
  }
  if !RegExMatch(target, "i)^https?://") || (how = "" && item.profile = "" && !group) {
    try Run(target)
    catch
      Flash("열지 못했어요: " target)
    return
  }
  ; In Chrome: a shortcut tied to a profile (4th field) opens in that profile's window.
  args := ""
  if item.profile != "" {
    dir := ChromeProfileDir(item.profile)
    if dir = ""
      return Flash("크롬 프로필을 찾지 못했어요: " item.profile)
    args := '--profile-directory="' dir '" '
  }
  if how = "window" || (how = "" && group) || (how = "tab" && !tabWindow && !ChromeWindow(prevWindow))
    args .= "--new-window "
  if how = "tab"
    tabWindow := true
  for page in StrSplit(target, " ")
    args .= ' "' page '"'
  try Run('"' BROWSER.exe '" ' args)
  catch
    Flash("열지 못했어요: " item.name)
}

Move(dx, dy) {
  global selected
  if !items.Length
    return
  i := selected || hover || 1
  if (selected || hover) && dx
    i := Max(1, Min(items.Length, i + dx))
  else if selected || hover {
    ; Up / down: the icon of the nearest row above / below (across category headings), nearest in its column.
    cur := TileRect(i), best := 0, bestScore := 0
    for j, t in panel.tiles
      if dy < 0 ? t.y < cur.y - 1 : t.y > cur.y + 1 {
        score := Abs(t.y - cur.y) * 10000 + Abs(t.x - cur.x)
        if !best || score < bestScore
          best := j, bestScore := score
      }
    i := best || i
  }
  selected := i
  Paint()
}

; ---------- mouse ----------
; Signed client coordinates (negative outside the popup while dragging).
MouseX(lParam) => lParam << 48 >> 48
MouseY(lParam) => lParam << 32 >> 48

PopupMouseMove(wParam, lParam, msg, hwnd) {
  global hover, hoverButton, questHover, hoverHead
  if questWin && hwnd = questWin.Hwnd {
    track := Buffer(24, 0), NumPut("uint", 24, track, 0), NumPut("uint", 2, track, 4), NumPut("ptr", hwnd, track, 8)
    DllCall("TrackMouseEvent", "ptr", track)
    if (i := QuestLinkAt(MouseX(lParam), MouseY(lParam))) != questHover
      questHover := i, PaintQuests()
    return
  }
  if !popup || hwnd != popup.Hwnd
    return
  x := MouseX(lParam), y := MouseY(lParam)
  if drag
    return DragTo(x, y)
  track := Buffer(24, 0), NumPut("uint", 24, track, 0), NumPut("uint", 2, track, 4), NumPut("ptr", hwnd, track, 8) ; TME_LEAVE
  DllCall("TrackMouseEvent", "ptr", track)
  i := TileAt(x, y), b := ButtonAt(x, y), h := i || b != "" ? 0 : HeadAt(x, y)
  if i != hover || b != hoverButton || h != hoverHead
    hover := i, hoverButton := b, hoverHead := h, Paint()
}
PopupMouseLeave(wParam, lParam, msg, hwnd) {
  global hover, hoverButton, questHover, hoverHead
  if questWin && hwnd = questWin.Hwnd && questHover {
    questHover := 0
    return PaintQuests()
  }
  if popup && hwnd = popup.Hwnd && !drag && (hover || hoverButton != "" || hoverHead)
    hover := 0, hoverButton := "", hoverHead := 0, Paint()
}
; In the order mode a pressed icon or category heading is picked up; it follows the mouse until let go.
PopupMouseDown(wParam, lParam, msg, hwnd) {
  global drag, hover, hoverHead
  if !popup || hwnd != popup.Hwnd || mode != "order"
    return
  x := MouseX(lParam), y := MouseY(lParam)
  if i := TileAt(x, y) {
    item := items[i], si := item.si, minRows := Map()
    for k, b in panel.bands
      minRows[ObjPtr(sections[k])] := b.rows
    drag := {item: item, si: si, pos: i - FlatIndex(sections[si].items[1]) + 1, from: si "/" i, x: x, y: y, minRows: minRows}
  } else if si := HeadAt(x, y)
    drag := {cat: true, si: si, from: si, x: x, y: y}
  else
    return
  hover := 0, hoverHead := 0
  DllCall("SetCapture", "ptr", hwnd)
  Paint()
}

; Moves what is dragged to the place under x, y: an icon to a slot of any section, a heading among the headings.
DragTo(x, y) {
  global panel
  drag.x := x, drag.y := y
  if drag.HasOwnProp("cat") {
    at := HeadDropAt(y)
    if at != drag.si
      sections.InsertAt(at, sections.RemoveAt(drag.si)), drag.si := at, Flatten(), panel := Layout()
    return Paint()
  }
  t := DropAt(x, y)
  if t.si != drag.si || t.pos != drag.pos {
    sections[drag.si].items.RemoveAt(drag.pos)
    sections[t.si].items.InsertAt(t.pos, drag.item)
    drag.si := t.si, drag.pos := t.pos
    Flatten(), panel := Layout(drag.minRows)
    for k, b in panel.bands
      drag.minRows[ObjPtr(sections[k])] := b.rows
  }
  Paint()
}
PopupClick(wParam, lParam, msg, hwnd) {
  if calWin && hwnd = calWin.Hwnd {
    x := MouseX(lParam), y := MouseY(lParam)
    for b in calButtons
      if x >= b.x && x <= b.x + b.w && y >= b.y && y <= b.y + b.h
        return b.act = "big" ? OpenCalendarBig() : b.act = "today" ? CalMove(0) : CalMove(b.act = "prev" ? -1 : 1)
    return
  }
  if questWin && hwnd = questWin.Hwnd {
    x := MouseX(lParam), y := MouseY(lParam)
    if i := QuestLinkAt(x, y)
      return OpenQuestLink(questLinks[i].link)
    return (r := QuestRowAt(x, y)) ? BumpQuest(r, 1) : OpenQuestEditor()
  }
  if !popup || hwnd != popup.Hwnd
    return
  if drag
    return EndDrag()
  x := MouseX(lParam), y := MouseY(lParam)
  if b := ButtonAt(x, y)
    return PressButton(b)
  if mode = "edit" && (si := HeadAt(x, y))
    return EditCategory(si)
  OpenItem(TileAt(x, y), wParam & 0x8 ? "tab" : wParam & 0x4 ? "window" : "")   ; MK_CONTROL / MK_SHIFT
}
PopupCaptureLost(wParam, lParam, msg, hwnd) {
  if popup && hwnd = popup.Hwnd
    EndDrag()
}
; Right click: on an icon its edit and "move to" menu, on a heading the category's menu, then the list's own items.
PopupMenu(wParam, lParam, msg, hwnd) {
  if questWin && hwnd = questWin.Hwnd {   ; right click on a quest: one less
    if r := QuestRowAt(MouseX(lParam), MouseY(lParam))
      BumpQuest(r, -1)
    return
  }
  if !popup || hwnd != popup.Hwnd || drag
    return
  x := MouseX(lParam), y := MouseY(lParam), menu := Menu()
  if i := TileAt(x, y) {
    item := items[i]
    menu.Add("✎ 「" item.name "」 편집…", (*) => EditShortcut(FlatIndex(item)))
    if sections.Length > 1 {
      sub := Menu()
      for si, sec in sections
        if si != item.si
          sub.Add(sec.name, MoveToSection.Bind(item, si))
      menu.Add("📁 다른 카테고리로 옮기기", sub)
    }
    menu.Add()
  } else if si := HeadAt(x, y) {
    menu.Add("+ 「" sections[si].name "」에 새 바로가기…", (*) => EditShortcut(0, si))
    menu.Add("✎ 카테고리 이름 바꾸기·삭제…", (*) => EditCategory(si))
    menu.Add()
  }
  menu.Add("📁 새 카테고리…", (*) => EditCategory(0))
  menu.Add("✎ 바로가기 목록 편집", (*) => EditShortcuts())
  menu.Add("📂 폴더 열기", (*) => OpenFolder())
  menu.Show()
}

; Puts item at the end of section si (right-click menu) and saves.
MoveToSection(item, si, *) {
  global selected
  for k, it in sections[item.si].items
    if it = item {
      sections[item.si].items.RemoveAt(k)
      break
    }
  sections[si].items.Push(item)
  Relayout(), selected := FlatIndex(item)
  SaveList(), Paint()
  Flash("「" item.name "」 → 「" sections[si].name "」")
}

; Lets go of what is dragged where it is; a new order is saved.
EndDrag() {
  global drag
  if !drag
    return
  moved := drag.from != (drag.HasOwnProp("cat") ? drag.si : drag.si "/" FlatIndex(drag.item)), drag := 0
  DllCall("ReleaseCapture")
  if moved
    SaveList()
  Relayout()
}

SaveList() {
  try SaveSections(SHORTCUTS, sections)
  catch as e
    Flash("저장하지 못했어요: " e.Message)
}

; ---------- categories ----------
; si = 0: a new category (added at the end). Otherwise rename or delete section si; its shortcuts go to the category
; above it (the one below, for the first) when it is deleted, after a question.
EditCategory(si) {
  global dialog
  if dialog
    return WinActivate(dialog.gui.Hwnd)
  sec := si ? sections[si] : 0
  g := Gui("+AlwaysOnTop -MinimizeBox +Owner" popup.Hwnd, si ? "카테고리 편집" : "새 카테고리")
  g.SetFont("s10", "Malgun Gothic")
  g.AddText(, "카테고리 이름")
  nameBox := g.AddEdit("w300", si ? sec.name : "")
  if !si
    g.AddText("w300 c6B7280", "맨 아래에 생겨요. ⇅ 순서 바꾸기에서 이름을 끌어 옮기고, 아이콘을 끌어 넣으세요.")
  g.AddButton("xm y+16 w90 Default", si ? "저장" : "만들기").OnEvent("Click", Save)
  g.AddButton("x+8 w90", "취소").OnEvent("Click", Close)
  if si
    g.AddButton("x+24 w90", "삭제").OnEvent("Click", Delete)
  g.OnEvent("Close", Close), g.OnEvent("Escape", Close)
  dialog := {gui: g, cancel: Close}
  ShowBeside(g)

  Save(*) {
    name := Trim(nameBox.Value)
    g.Opt("+OwnDialogs")
    if (problem := CategoryNameProblem(sections, name, sec)) != ""
      return MsgBox(problem, "카테고리", "Icon!")
    if sec
      sec.name := name
    else {
      ; The first category: the shortcuts so far (no heading) become "기타" (or nothing, if there are none).
      if sections.Length = 1 && sections[1].name = "" {
        if sections[1].items.Length
          sections[1].name := "기타"
        else
          sections.RemoveAt(1)
      }
      if !SectionByName(sections, name)   ; "기타" just made above
        sections.Push({name: name, items: []})
    }
    Done()
  }
  Delete(*) {
    g.Opt("+OwnDialogs")
    n := sec.items.Length
    if n {
      if sections.Length = 1
        return MsgBox("하나뿐인 카테고리라 바로가기를 옮길 곳이 없어요.", "카테고리", "Icon!")
      to := sections[si > 1 ? si - 1 : 2]
      if MsgBox("「" sec.name "」을 지울까요?`n안의 바로가기 " n "개는 「" to.name "」 카테고리 맨 끝으로 옮겨져요.", "카테고리 삭제", "OKCancel Icon? Default2") != "OK"
        return
      to.items.Push(sec.items*)
    }
    sections.RemoveAt(si)
    if !sections.Length
      sections.Push({name: "", items: []})
    Done()
  }
  Done() {
    Close()
    SaveList()
    Relayout()
  }
  Close(*) {
    global dialog := 0
    g.Destroy()
    if PopupVisible()
      WinActivate(popup.Hwnd)
  }
}

; ---------- add / edit ----------
; i = 0: a new shortcut (name and address). Otherwise shortcut i: name, address, picture or colour — the popup shows
; the changes while editing, and 취소 / Esc puts them back. A group's addresses are edited one a line.
; si (a new one) = the category it goes in at first (0 = the last one).
EditShortcut(i, si := 0) {
  global dialog, selected
  if dialog
    return WinActivate(dialog.gui.Hwnd)
  item := i ? items[i] : {name: "", target: "", picture: "", color: "", up: "", profile: ""}
  before := item.Clone(), group := IsGroup(item.target)
  if i
    selected := i, Paint()
  g := Gui("+AlwaysOnTop -MinimizeBox +Owner" popup.Hwnd, i ? "바로가기 편집" : "새 바로가기")
  g.SetFont("s10", "Malgun Gothic")
  catBox := 0
  if sections.Length > 1 || sections[1].name != "" {
    names := []
    for sec in sections
      names.Push(sec.name)
    g.AddText(, "카테고리")
    catBox := g.AddDropDownList("w380 Choose" (i ? item.si : si || sections.Length), names)
    g.AddText("y+12", "이름")
  } else
    g.AddText(, "이름")
  nameBox := g.AddEdit("w380", item.name)
  g.AddText("y+12", group ? "주소 (한 줄에 하나, 함께 열려요)" : "주소 (웹 주소 또는 폴더·파일 경로)")
  targetBox := g.AddEdit("w380" (group ? " r6" : ""), group ? StrReplace(item.target, " ", "`r`n") : item.target)
  if i {
    g.AddText("y+12", "아이콘")
    g.AddButton("xm", "사진 고르기…").OnEvent("Click", PickPicture)
    g.AddButton("x+6", "색 고르기…").OnEvent("Click", PickColor)
    g.AddButton("x+6", "기본으로").OnEvent("Click", (*) => SetIcon("", ""))
    iconNote := g.AddText("xm y+8 w380 c6B7280")
    nameBox.OnEvent("Change", (*) => (item.name := Trim(nameBox.Value), Paint()))
    SetIcon(item.picture, item.color)
  }
  g.AddButton("xm y+16 w90 Default", "저장").OnEvent("Click", Save)
  g.AddButton("x+8 w90", "취소").OnEvent("Click", Cancel)
  g.OnEvent("Close", Cancel), g.OnEvent("Escape", Cancel)
  dialog := {gui: g, cancel: Cancel}
  ShowBeside(g)

  SetIcon(picture, color) {
    item.picture := picture, item.color := color
    iconNote.Value := picture != "" ? "사진: " picture : color != "" ? "색: #" color : "기본: 사이트 아이콘, 없으면 이름 글자"
    Paint()
  }
  PickPicture(*) {
    g.Opt("+OwnDialogs")
    path := FileSelect(1, DATA_DIR "\icons\", "아이콘 사진", "그림 (*.png; *.jpg; *.jpeg; *.gif; *.bmp; *.ico)")
    if path = ""
      return
    if !LoadPicture(path)
      return MsgBox("이 그림은 열 수 없어요.", "아이콘", "Icon!")
    SetIcon(path, "")
  }
  PickColor(*) {
    color := ChooseColor(g.Hwnd, ShortcutColor(item))
    if color != ""
      SetIcon("", color)
  }
  Save(*) {
    global selected
    name := Trim(LTrim(StrReplace(nameBox.Value, "|", "/"), "# ")), target := TargetFromText(targetBox.Value)
    g.Opt("+OwnDialogs")
    if name = ""
      return MsgBox("이름을 적어 주세요.", "바로가기", "Icon!")
    if !ValidTarget(target)
      return MsgBox("주소는 https://… 같은 웹 주소나 D:\… 폴더·파일 경로로 적어 주세요.`n여러 줄은 웹 주소만 돼요.", "바로가기", "Icon!")
    ; A picture from elsewhere is copied into icons\ (made small: a big photo slows every repaint).
    if item.picture != "" && InStr(item.picture, DATA_DIR "\") != 1 {
      copy := NewIconPath(item.picture)
      if !SaveIconPicture(item.picture, copy)
        return MsgBox("사진을 저장하지 못했어요.", "아이콘", "Icon!")
      item.picture := copy
    }
    if item.target != target
      item.up := ""
    item.name := name, item.target := target
    to := catBox ? catBox.Value : 1, add := !i
    if i && to != item.si {   ; another category: to its end
      for k, it in sections[item.si].items
        if it = item {
          sections[item.si].items.RemoveAt(k)
          break
        }
      add := true
    }
    if add
      sections[to].items.Push(item)
    Close()
    SaveList()
    Relayout()
    selected := FlatIndex(item)
    Paint()
    StartChecks()
  }
  Cancel(*) {
    for key in ["name", "target", "picture", "color"]
      item.%key% := before.%key%
    Close()
    Paint()
  }
  Close() {
    global dialog := 0
    g.Destroy()
    if PopupVisible()
      WinActivate(popup.Hwnd)
  }
}

; Beside the popup (right of it, else left), on its screen.
ShowBeside(g) {
  g.Show("Hide")
  g.GetPos(, , &w, &h)
  m := MonitorRect(MonitorOfPoint(posX + panel.w // 2, posY + panel.h // 2) || MonitorGetPrimary())
  x := posX + panel.w - panel.margin
  if x + w > m.r
    x := posX + panel.margin - w
  g.Show(Format("x{} y{}", Max(m.l, Min(m.r - w, x)), Max(m.t, Min(m.b - h, posY + panel.margin))) (focused ? "" : " NA"))   ; preview: no focus
}

; A free name in icons\ for a picked picture (saved there as PNG).
NewIconPath(source) {
  SplitPath(source, , , , &stem)
  DirCreate(DATA_DIR "\icons")
  path := DATA_DIR "\icons\" stem ".png", n := 1
  while FileExist(path)
    path := DATA_DIR "\icons\" stem "-" (++n) ".png"
  return path
}

; Windows' colour dialog at `rrggbb`, the icon palette as its custom colours. "RRGGBB", or "" if cancelled.
ChooseColor(owner, rrggbb) {
  static custom := Buffer(64, 0)
  swap := v => (v & 0xFF) << 16 | v & 0xFF00 | (v >> 16) & 0xFF   ; RGB <-> Windows' BGR
  for hex in ShortcutPalette()
    NumPut("uint", swap(Integer("0x" hex)), custom, (A_Index - 1) * 4)
  cc := Buffer(9 * A_PtrSize, 0)   ; CHOOSECOLOR
  NumPut("uint", cc.Size, cc, 0), NumPut("ptr", owner, cc, A_PtrSize), NumPut("uint", swap(Integer("0x" rrggbb)), cc, 3 * A_PtrSize)
  NumPut("ptr", custom.Ptr, cc, 4 * A_PtrSize), NumPut("uint", 0x3, cc, 5 * A_PtrSize)   ; CC_RGBINIT | CC_FULLOPEN
  if !DllCall("comdlg32\ChooseColorW", "ptr", cc)
    return ""
  return Format("{:06X}", swap(NumGet(cc, 3 * A_PtrSize, "uint")))
}

; ---------- 그룹 만들기 ----------
; The tabs of the Chrome window last in front become one shortcut that opens them all. A dialog lists them first to
; check (all ticked — or, when the open tab is in a tab group, that group's tabs) and to name the shortcut.
MakeGroup() {
  global dialog
  if dialog
    return WinActivate(dialog.gui.Hwnd)
  hwnd := LastChromeWindow(prevWindow)
  if !hwnd
    return Flash("열린 크롬 창이 없어요")
  info := ChromeTabs(hwnd)
  if !info || !info.tabs.Length
    return Flash("크롬 탭을 읽지 못했어요")
  current := ""
  for tab in info.tabs
    if tab.selected
      current := tab.group
  g := Gui("+AlwaysOnTop -MinimizeBox +Owner" popup.Hwnd, "그룹 만들기")
  g.SetFont("s10", "Malgun Gothic")
  g.AddText(, "이 탭으로 그룹을 만들까요?")
  list := g.AddListView("w440 r10 Checked -Hdr", ["탭"])
  for tab in info.tabs
    list.Add(current = "" || tab.group = current ? "Check" : "", (tab.group != "" ? "[" tab.group "]  " : "") tab.name)
  list.ModifyCol(1, 410)
  g.AddText("y+12", "이름")
  nameBox := g.AddEdit("w440", current != "" ? current : "탭 그룹")
  g.AddButton("xm y+16 w110 Default", "그룹 만들기").OnEvent("Click", Make)
  g.AddButton("x+8 w90", "취소").OnEvent("Click", Close)
  g.OnEvent("Close", Close), g.OnEvent("Escape", Close)
  dialog := {gui: g, cancel: Close}
  ShowBeside(g)

  Make(*) {
    global selected
    picked := [], row := 0
    while row := list.GetNext(row, "Checked")
      picked.Push(info.tabs[row])
    name := Trim(LTrim(StrReplace(nameBox.Value, "|", "/"), "# "))
    g.Opt("+OwnDialogs")
    if !picked.Length
      return MsgBox("탭을 하나 이상 골라 주세요.", "그룹 만들기", "Icon!")
    if name = ""
      return MsgBox("이름을 적어 주세요.", "그룹 만들기", "Icon!")
    Close()
    ToolTip("탭 주소 읽는 중…")
    pages := ""
    for url in ChromeTabUrls(info, picked)
      if url != ""
        pages .= (pages = "" ? "" : " ") StrReplace(url, " ", "%20")
    if pages = ""
      return Flash("웹 주소가 있는 탭이 없어요")
    sections[-1].items.Push(item := {name: name, target: pages, picture: "", color: "", up: "", profile: info.profile})
    SaveList()
    Relayout()
    selected := FlatIndex(item), Paint()
    count := StrSplit(pages, " ").Length
    Flash("「" name "」 탭 " count "개" (count < picked.Length ? "  (웹 주소가 아닌 탭 " picked.Length - count "개 뺌)" : ""))
  }
  Close(*) {
    global dialog := 0
    g.Destroy()
    if PopupVisible()
      WinActivate(popup.Hwnd)
  }
}

; ---------- while open: focus and running status ----------
; Each local page is asked at once (asynchronously, so the popup never waits); ● running / ○ not. "localhost" is
; asked as 127.0.0.1 and [::1] side by side: a server listens on one of them, and asking the other first costs
; Windows two seconds before it falls back.
StartChecks() {
  global checks := Map(), checkStart := A_TickCount
  changed := false
  for item in items {
    if !LocalWeb(item.target)
      continue
    requests := []
    for address in LoopbackAddresses(item.target) {
      try {
        request := ComObject("WinHttp.WinHttpRequest.5.1")
        request.SetTimeouts(300, 500, 500, 1500)
        request.Open("GET", address, true)
        request.Send()
        requests.Push({request: request, address: address, failed: false})
      }
    }
    if requests.Length
      checks[item] := requests
    else
      changed := SetUp(item, 0) || changed
  }
  if changed
    Paint()
}

SetUp(item, up) {
  lastUp[item.target] := up
  if item.up = up
    return false
  item.up := up
  return true
}

Watch() {
  global misses
  if !PopupVisible()
    return SetTimer(Watch, 0)
  ; Closes when another window takes the focus — not while a dialog of its own is open. Right after a Ctrl/Shift+click
  ; the browser takes the focus: the popup takes it back, to stay for the next click.
  if A_TickCount < holdUntil {
    misses := 0
    if !WinActive("ahk_id " popup.Hwnd)
      try WinActivate(popup.Hwnd)
  } else if !focused || dialog || WinActive("ahk_id " popup.Hwnd)
    misses := 0
  else if ++misses >= 2
    return HideShortcuts()
  if LoadQuests()
    ShowQuests()
  if LoadCalendar()
    ShowCalendar()
  if LoadServers() {   ; servers.ahk: the count landed (or servers were stopped): dots, pill and list again
    StartChecks()
    Paint()
    FillServerList()
  }
  changed := false
  for item, requests in checks.Clone() {
    answered := 0
    for entry in requests {
      if entry.failed
        continue
      try {
        if entry.request.WaitForResponse(0)
          answered := entry
      } catch
        entry.failed := true
      if answered
        break
    }
    late := A_TickCount - checkStart > 2500
    pending := false
    for entry in requests
      pending := pending || !entry.failed
    if !answered && pending && !late
      continue
    checks.Delete(item)
    changed := SetUp(item, answered ? 1 : 0) || changed
    if answered && FetchIcon(item, answered.request, answered.address)
      changed := true
  }
  if changed
    Paint()
}

; ---------- favicons (fetched once per site into icons-cache) ----------
CachedIcon(target) {
  key := IconKey(target)
  if key != ""
    for ext in ["png", "ico", "jpg", "gif"]
      if FileExist(ICON_CACHE "\" key "." ext)
        return ICON_CACHE "\" key "." ext
  return ""
}

; The page's own icon (<link rel="icon">, else /favicon.ico); SVG and HTML answers are skipped. True if one was saved.
FetchIcon(item, page, base) {
  static tried := Map()
  key := IconKey(item.target)
  if key = "" || item.picture != "" || tried.Has(key) || CachedIcon(item.target) != ""
    return false
  tried[key] := true
  html := ""
  try html := page.ResponseText
  urls := []
  if RegExMatch(html, "i)<link\b[^>]*\brel=[`"']?[^`"'>]*icon[^>]*>", &tag) && RegExMatch(tag[0], "i)\bhref=[`"']?([^`"' >]+)", &href)
    if !RegExMatch(href[1], "i)\.svg(\?|$)|^data:")
      urls.Push(ResolveUrl(base, href[1]))
  urls.Push(ResolveUrl(base, "/favicon.ico"))
  for url in urls {
    try {
      request := ComObject("WinHttp.WinHttpRequest.5.1")
      request.SetTimeouts(300, 500, 500, 1500)
      request.Open("GET", url, false)
      request.Send()
      type := request.Status = 200 ? request.GetResponseHeader("Content-Type") : ""
      ext := RegExMatch(type, "i)png") ? "png" : RegExMatch(type, "i)icon") ? "ico" : RegExMatch(type, "i)jpe?g") ? "jpg" : RegExMatch(type, "i)gif") ? "gif" : ""
      if ext = ""
        continue
      DirCreate(ICON_CACHE)
      path := ICON_CACHE "\" key "." ext
      stream := ComObject("ADODB.Stream")
      stream.Type := 1, stream.Open(), stream.Write(request.ResponseBody), stream.SaveToFile(path, 2), stream.Close()
      if LoadPicture(path)
        return true
      FileDelete(path)
    }
  }
  return false
}
