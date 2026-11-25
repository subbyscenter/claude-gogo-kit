; Local servers in the shortcuts popup — servers.mjs does the work, always hidden (no console window):
;   · a local page whose server is off: clicking its shortcut starts the server, then opens the page when it answers
;   · the pill at the popup's top left = how many servers run; it opens the list, where long-unused ones can be stopped
;     (they start again on their shortcut's next click)
;   · every 5 minutes (SampleServers): which servers a browser has open, for "last used"
; The host script sets SERVERS_DIR (data: servers.json, servers.tsv, used.log), SERVERS_JS and NODE.
#Requires AutoHotkey v2.0

global serverInfo := {at: 0, list: []}, serverStamp := "", starting := Map(), serverGui := 0, serverList := 0, serverListPid := 0

; servers.tsv: "at <tab> epoch", then "s <tab> key <tab> ports <tab> name <tab> MB <tab> idle minutes <tab> how <tab> keep <tab> in use"
ParseServers(text) {
  info := {at: 0, list: []}
  for line in StrSplit(text, "`n", "`r") {
    if line = ""
      continue
    f := StrSplit(line, "`t")
    if f[1] = "at" && f.Length >= 2 && IsInteger(f[2])
      info.at := Integer(f[2])
    else if f[1] = "s" && f.Length >= 9 && IsInteger(f[5]) && IsInteger(f[6])
      info.list.Push({key: f[2], ports: f[3], name: f[4], mb: Integer(f[5]), idle: Integer(f[6]), how: f[7], keep: f[8] = "1", inUse: f[9] = "1"})
  }
  return info
}

; Runs servers.mjs hidden. wait: until it ends (its exit code); else its process id (0 if it could not start).
ServersRun(argsText, wait := false) {
  DirCreate(SERVERS_DIR)
  line := '"' NODE '" "' SERVERS_JS '" ' argsText ' --data "' SERVERS_DIR '"'
  try {
    if wait
      return RunWait(line, SERVERS_DIR, "Hide")
    Run(line, SERVERS_DIR, "Hide", &pid)
    return pid
  }
  return 0
}

; Counts again in the background (Watch repaints when servers.tsv lands); once at a time.
RefreshServers() {
  global serverListPid
  if serverListPid && ProcessExist(serverListPid)
    return
  serverListPid := ServersRun("list")
}

SampleServers() => ServersRun("sample")

; Reads servers.tsv again when it changed. True if it did.
LoadServers() {
  global serverInfo, serverStamp
  file := SERVERS_DIR "\servers.tsv"
  stamp := FileExist(file) ? FileGetTime(file) "|" FileGetSize(file) : ""
  if stamp = serverStamp
    return false
  serverStamp := stamp, text := ""
  try text := FileRead(file, "UTF-8")
  serverInfo := ParseServers(text)
  return true
}

ServerMemory() {
  mb := 0
  for s in serverInfo.list
    mb += s.mb
  return mb >= 1024 ? Round(mb / 1024, 1) "GB" : mb "MB"
}

; "12분 전" / "3시간 전" / "2일 전"
IdleLabel(minutes) => minutes < 60 ? minutes "분" : minutes < 1440 ? Round(minutes / 60) "시간" : Round(minutes / 1440) "일"

; ---------- the pill (top left of the popup) ----------
ServerPill() {
  s := panel.s, text := serverInfo.at ? "서버 " serverInfo.list.Length "개" : "서버 …"
  return {x: panel.margin + Round(14 * s), y: panel.margin + Round(14 * s), w: Round(TextWidth(text, 11.5 * s) + 34 * s), h: Round(28 * s), text: text}
}

ServerPillAt(x, y) {
  p := ServerPill()
  return x >= p.x && x <= p.x + p.w && y >= p.y && y <= p.y + p.h
}

PaintServerPill(c, hovered) {
  p := ServerPill(), s := panel.s
  c.RoundRect(p.x, p.y, p.w, p.h, p.h / 2, hovered ? 0xFFE5E7EB : 0xFFF3F4F6)
  c.Circle(p.x + 11 * s, p.y + p.h / 2 - 4 * s, 8 * s, serverInfo.list.Length ? 0xFF22C55E : 0xFFC3C7CF)
  c.Text(p.text, p.x + 22 * s, p.y, p.w - 26 * s, p.h, 11.5 * s, 0xFF374151, true, , 0)
}

ServerTip() => serverInfo.at ? "켜진 서버 " serverInfo.list.Length "개 · 메모리 " ServerMemory() "  ·  눌러서 보기·끄기" : "서버를 세는 중…"

; ---------- the list window ----------
ShowServers() {
  global dialog, serverGui, serverList
  if dialog
    return WinActivate(dialog.gui.Hwnd)
  g := Gui("+AlwaysOnTop -MinimizeBox +Owner" popup.Hwnd, "켜진 서버")
  g.SetFont("s10", "Malgun Gothic")
  head := g.AddText("w620")
  serverList := g.AddListView("w620 r14 Checked Grid NoSort", ["이름", "포트", "메모리", "안 쓴 지", "상태"])
  g.AddText("w620 c6B7280", "끈 서버는 그 바로가기를 누르면 다시 켜져요. 「켜는 법 모름」·「항상 켜 두기」는 끄지 않아요.")
  g.AddButton("xm y+10", "하루 넘게 안 쓴 것 고르기").OnEvent("Click", PickIdle)
  g.AddButton("x+6 Default", "고른 것 끄기").OnEvent("Click", StopPicked)
  g.AddButton("x+6", "항상 켜 두기 ↔").OnEvent("Click", ToggleKeep)
  g.AddButton("x+6", "새로고침").OnEvent("Click", (*) => (head.Value := "다시 세는 중…", RefreshServers()))
  g.AddButton("x+6", "닫기").OnEvent("Click", Close)
  g.OnEvent("Close", Close), g.OnEvent("Escape", Close)
  serverGui := {gui: g, head: head}
  dialog := {gui: g, cancel: Close}
  FillServerList()
  ShowBeside(g)
  RefreshServers()

  PickIdle(*) {
    loop serverList.GetCount() {
      s := serverInfo.list[A_Index]
      serverList.Modify(A_Index, s.idle >= 1440 && !s.inUse && !s.keep && s.how != "none" ? "Check" : "-Check")
    }
  }
  StopPicked(*) {
    keys := "", names := "", n := 0, row := 0
    while row := serverList.GetNext(row, "Checked") {
      s := serverInfo.list[row]
      if s.keep || s.how = "none"
        continue
      keys .= " " s.key, names .= "`n  · " s.name " (" s.mb "MB)", n++
    }
    g.Opt("+OwnDialogs")
    if !n
      return MsgBox("끌 서버를 체크해 주세요. (「켜는 법 모름」·「항상 켜 두기」는 끄지 않아요)", "켜진 서버", "Icon!")
    if MsgBox(n "개를 끌까요?" names "`n`n바로가기를 누르면 다시 켜져요.", "켜진 서버", "OKCancel Icon? Default1") != "OK"
      return
    head.Value := n "개 끄는 중…"
    ServersRun("stop" keys)
  }
  ToggleKeep(*) {
    row := serverList.GetNext(0, "Focused") || serverList.GetNext(0)
    if !row
      return
    s := serverInfo.list[row]
    head.Value := "「" s.name "」 " (s.keep ? "끌 수 있게" : "항상 켜 두기로") " 바꾸는 중…"
    ServersRun("keep " s.key (s.keep ? " off" : " on"))
  }
  Close(*) {
    global dialog := 0, serverGui := 0
    g.Destroy()
    if PopupVisible()
      WinActivate(popup.Hwnd)
  }
}

FillServerList() {
  if !serverGui
    return
  serverList.Opt("-Redraw")
  checked := Map(), row := 0
  while row := serverList.GetNext(row, "Checked")
    checked[serverList.GetText(row, 2)] := true
  serverList.Delete()
  for s in serverInfo.list
    serverList.Add(checked.Has(s.ports) ? "Check" : "", s.name, s.ports, s.mb "MB", s.inUse ? "지금 사용 중" : IdleLabel(s.idle)
      , s.keep ? "항상 켜 두기" : s.how = "none" ? "켜는 법 모름" : "")
  loop 5
    serverList.ModifyCol(A_Index, A_Index = 1 ? 230 : "AutoHdr")
  serverList.Opt("+Redraw")
  serverGui.head.Value := serverInfo.at ? "켜진 서버 " serverInfo.list.Length "개 · 메모리 " ServerMemory() "  (" FormatTime(DateAdd(DateAdd("19700101", serverInfo.at, "Seconds"), DateDiff(A_Now, A_NowUTC, "Seconds"), "Seconds"), "HH:mm") " 기준)" : "세는 중…"
}

; ---------- start on click ----------
; The port of a single local page ("" if none).
LocalPort(target) => LocalWeb(target) && RegExMatch(target, "i)^https?://(?:localhost|127\.0\.0\.1|\[::1\]):(\d+)", &m) ? m[1] : ""

; Opened from the popup = used now (servers.mjs reads used.log).
NoteUsed(target) {
  if (port := LocalPort(target)) != ""
    try FileAppend(port "`t" DateDiff(A_NowUTC, "19700101", "Seconds") "`n", SERVERS_DIR "\used.log", "UTF-8-RAW")
}

Say(text, ms := 5000) {
  ToolTip(text)
  SetTimer(() => ToolTip(), -ms)
}

; A local page whose server is off: start it hidden, open the page once it answers (or say why not).
StartThenOpen(item, how) {
  port := LocalPort(item.target)
  if starting.Has(port)
    return Say("「" item.name "」 켜는 중이에요…", 2000)
  out := SERVERS_DIR "\start-" port ".txt"
  try FileDelete(out)
  pid := ServersRun("start " port ' --out "' out '"')
  if !pid
    return Say("node를 찾지 못해서 「" item.name "」 서버를 못 켰어요")
  starting[port] := {pid: pid, item: item, how: how, out: out, since: A_TickCount}
  ToolTip("「" item.name "」 서버 켜는 중…")
  SetTimer(WatchStarts, 300)
}

WatchStarts() {
  for port, s in starting.Clone() {
    if ProcessExist(s.pid) && A_TickCount - s.since < 120000
      continue
    starting.Delete(port)
    result := ""
    try result := Trim(FileRead(s.out, "UTF-8"), " `r`n")
    try FileDelete(s.out)
    if result = "ok" {
      ToolTip()
      SetUp(s.item, 1)
      OpenShortcut(s.item, s.how, true)
    } else
      Say("「" s.item.name "」 서버를 켜지 못했어요: " (result != "" ? result : "시간이 너무 걸려요"), 7000)
  }
  if !starting.Count
    SetTimer(WatchStarts, 0)
}
