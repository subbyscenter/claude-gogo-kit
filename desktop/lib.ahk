; gogo 바로가기 창 — the functions (desktop.ahk binds them to keys, test.ahk checks them).
; User data (shortcuts.txt, icons) lives in DATA_DIR (~\.gogo\desktop), not in the kit folder.
#Requires AutoHotkey v2.0

; ---------- shortcuts popup ----------
; shortcuts.txt: "[카테고리]" lines (see LoadSections) and one "name | address | icon | chrome profile" per line — address = http(s) address or a folder/file
; path, or several http(s) addresses separated by spaces (a group: they open together as tabs); icon (optional) = a
; picture file (png/ico/jpg) or a circle colour (#RRGGBB); chrome profile (optional) = the profile's e-mail, name or
; folder ("Profile 30") to open the address in. # starts a comment.
LoadShortcuts(file) {
  list := []
  if !FileExist(file)
    return list
  for line in StrSplit(FileRead(file, "UTF-8"), "`n", "`r")
    if item := ParseShortcut(line)
      list.Push(item)
  return list
}

; One line of the list as a shortcut, or "" if it is not one.
ParseShortcut(line) {
  line := Trim(line)
  if line = "" || SubStr(line, 1, 1) = "#"
    return ""
  parts := StrSplit(line, "|", " `t", 4)
  if parts.Length < 2
    return ""
  name := Trim(parts[1]), target := Trim(parts[2]), icon := parts.Length > 2 ? Trim(parts[3]) : ""
  if RegExMatch(target, "i)^https?://")
    target := RegExReplace(target, "\s+", " ")   ; a group's addresses, one space apart
  if name = "" || !ValidTarget(target)
    return ""
  item := {name: name, target: target, picture: "", color: "", up: "", profile: parts.Length > 3 ? Trim(parts[4]) : ""}
  if RegExMatch(icon, "^#([0-9a-fA-F]{6})$", &hex)
    item.color := hex[1]
  else if icon != ""
    item.picture := RegExMatch(icon, "i)^[a-z]:\\|^\\\\") ? icon : DATA_DIR "\" icon
  return item
}

ValidTarget(target) => RegExMatch(target, "i)^(https?://\S+( https?://\S+)*|[a-z]:\\.*|\\\\.+)$") > 0

; A group: several web addresses that open together.
IsGroup(target) => RegExMatch(target, "i)^https?://\S+ ") > 0

; ---------- categories ----------
; A line "[이름]" starts a category: the shortcuts below it belong to it, until the next one. Shortcuts above the first
; category line are in the nameless section — shown without a heading when it is the only one, else named "기타".
ParseCategory(line) => RegExMatch(Trim(line), "^\[([^\[\]|]*[^\[\]|\s][^\[\]|]*)\]$", &m) ? Trim(m[1]) : ""

; The list as sections [{name, items}] in the file's order; a category named twice is one section.
LoadSections(file) {
  sections := [{name: "", items: []}], current := sections[1]
  if FileExist(file)
    for line in StrSplit(FileRead(file, "UTF-8"), "`n", "`r") {
      if (name := ParseCategory(line)) != "" {
        current := 0
        for sec in sections
          if sec.name = name
            current := sec
        if !current
          sections.Push(current := {name: name, items: []})
      } else if item := ParseShortcut(line)
        current.items.Push(item)
    }
  if sections.Length > 1 {
    loose := sections.RemoveAt(1)
    if loose.items.Length {
      other := SectionByName(sections, "기타")
      if other
        other.items.InsertAt(1, loose.items*)
      else
        loose.name := "기타", sections.InsertAt(1, loose)
    }
  }
  return sections
}

SectionByName(sections, name) {
  for sec in sections
    if sec.name = name
      return sec
  return 0
}

; A name a new or renamed category may take: "" if fine, else what is wrong.
CategoryNameProblem(sections, name, except := 0) {
  if name = ""
    return "이름을 적어 주세요."
  if RegExMatch(name, "[\[\]|]")
    return "이름에 [ ] | 는 쓸 수 없어요."
  for sec in sections
    if sec != except && sec.name = name
      return "「" name "」 카테고리가 이미 있어요."
  return ""
}

; Writes the list back in the list's order. The comment lines at the top stay; other lines that are not a shortcut
; or a category (later comments) follow the shortcuts. The file is replaced in one step.
SaveShortcuts(file, items) => SaveSections(file, [{name: "", items: items}])

SaveSections(file, sections) {
  head := "", rest := "", top := true
  if FileExist(file)
    for line in StrSplit(FileRead(file, "UTF-8"), "`n", "`r") {
      if top && (Trim(line) = "" || SubStr(Trim(line), 1, 1) = "#") {
        head .= line "`r`n"
        continue
      }
      top := false
      if Trim(line) != "" && !ParseShortcut(line) && ParseCategory(line) = ""
        rest .= line "`r`n"
    }
  text := Trim(head, "`r`n") != "" ? RTrim(head, "`r`n") "`r`n`r`n" : "", body := ""
  for sec in sections {
    if sec.name != ""
      body .= (body = "" ? "" : "`r`n") "[" sec.name "]`r`n"
    for item in sec.items
      body .= ShortcutLine(item) "`r`n"
  }
  text .= body
  if rest != ""
    text .= "`r`n" rest
  FileOpen(file ".tmp", "w", "UTF-8-RAW").Write(text)
  FileMove(file ".tmp", file, 1)
}

; The list line of a shortcut (empty fields at the end left out); a picture in this folder is written relative to it.
ShortcutLine(item) {
  icon := item.picture != "" ? (InStr(item.picture, DATA_DIR "\") = 1 ? SubStr(item.picture, StrLen(DATA_DIR) + 2) : item.picture)
    : item.color != "" ? "#" item.color : ""
  line := item.name " | " item.target
  if icon != "" || item.profile != ""
    line .= " | " icon
  if item.profile != ""
    line .= " | " item.profile
  return line
}

; An address as typed: quotes ("copy as path") and D:/ slashes fixed, a bare site given its http(s)://.
NormalizeTarget(text) {
  text := Trim(Trim(text), "`"")
  if RegExMatch(text, "i)^[a-z]:/")
    text := StrReplace(text, "/", "\")
  if text = "" || ValidTarget(text)
    return text
  if RegExMatch(text, "i)^(localhost|127\.0\.0\.1|\[::1\])([:/]|$)")
    return "http://" text
  if RegExMatch(text, "^[\w-]+(\.[\w-]+)+([:/?#]\S*)?$")
    return "https://" text
  return text
}

; The address box of the edit dialog: one address a line (several = a group), each as NormalizeTarget makes it.
TargetFromText(text) {
  target := ""
  for line in StrSplit(text, "`n", "`r `t")
    if line != ""
      target .= (target = "" ? "" : " ") NormalizeTarget(line)
  return target
}

; A Chrome profile folder ("Profile 30", "Default") from what the list says: the folder itself, the e-mail of the
; account signed in to it, or the profile's name (looked up in Chrome's Local State). "" if not found.
ChromeProfileDir(value, localState := "") {
  if RegExMatch(value, "^(Default|Profile \d+)$")
    return value
  if localState = ""
    localState := BROWSER.data "\Local State"
  if value = "" || !FileExist(localState)
    return ""
  text := FileRead(localState, "UTF-8")
  at := InStr(text, '"user_name":"' value '"') || InStr(text, '"name":"' value '"')
  if !at
    return ""
  ; The nearest profile key before it is the profile that account belongs to.
  found := "", pos := 1
  while (pos := RegExMatch(text, '"(Default|Profile \d+)":\{', &m, pos)) && pos < at
    found := m[1], pos += m.Len
  return found
}

; A page this computer serves (localhost): its popup icon shows whether it is running.
LocalWeb(target) => RegExMatch(target, "i)^https?://(localhost|127\.0\.0\.1)(:\d+)?(/\S*)?$") > 0

; The addresses to ask for a local page: "localhost" as both 127.0.0.1 and [::1], anything else as it is.
LoopbackAddresses(target) {
  if !RegExMatch(target, "i)^(https?://)localhost(.*)$", &m)
    return [target]
  return [m[1] "127.0.0.1" m[2], m[1] "[::1]" m[2]]
}

; File name for a page's cached favicon: one per site (host and port).
IconKey(target) {
  if !RegExMatch(target, "i)^https?://([^/:?#]+)(?::(\d+))?", &m)
    return ""
  return RegExReplace(m[1], "[^\w.-]", "_") (m[2] ? "_" m[2] : "")
}

; The letters on a generated icon: the first syllable of a Korean name, else the initials of up to two words.
ShortcutLabel(name) {
  name := Trim(RegExReplace(name, "\s*\(.*\)\s*", " "))
  first := SubStr(name, 1, 1)
  if !RegExMatch(first, "[A-Za-z0-9]")
    return first
  words := StrSplit(name, " ", " `t-_")
  return StrUpper(words.Length > 1 ? SubStr(words[1], 1, 1) SubStr(words[2], 1, 1) : SubStr(name, 1, 2))
}

; The colour of a generated icon: the one given in the list, else one from a palette picked by the name.
ShortcutColor(item) {
  if item.color != ""
    return item.color
  palette := ShortcutPalette(), hash := 0
  loop parse item.name
    hash := Mod(hash * 31 + Ord(A_LoopField), 1000003)
  return palette[Mod(hash, palette.Length) + 1]
}

ShortcutPalette() => ["FF9F43", "7463D9", "19778D", "E0B028", "3B82F6", "EF4444", "10B981", "EC4899", "6366F1", "0EA5E9", "F97316", "8B5CF6"]

; The address without http(s):// and the last slash (a group: how many tabs), for the popup footer.
ShortTarget(target) => IsGroup(target) ? "탭 " StrSplit(target, " ").Length "개" : RegExReplace(RegExReplace(target, "i)^https?://"), "/$")

; An address the page links (an icon) resolved against the page address.
ResolveUrl(base, href) {
  if RegExMatch(href, "i)^https?://")
    return href
  if SubStr(href, 1, 2) = "//"
    return RegExReplace(base, "i)^(https?:).*", "$1") href
  if SubStr(href, 1, 1) = "/"
    return RegExReplace(base, "i)^(https?://[^/]+).*", "$1") href
  return RegExReplace(base, "[^/]*$") href
}

Flash(text) {
  ToolTip(text)
  SetTimer(() => ToolTip(), -1600)
}

; ---------- monitors ----------
MonitorRect(n, work := true) {
  if work
    MonitorGetWorkArea(n, &l, &t, &r, &b)
  else
    MonitorGet(n, &l, &t, &r, &b)
  return {l: l, t: t, r: r, b: b, w: r - l, h: b - t}
}

MonitorOfPoint(x, y) {
  loop MonitorGetCount() {
    m := MonitorRect(A_Index, false)
    if x >= m.l && x < m.r && y >= m.t && y < m.b
      return A_Index
  }
  return 0
}

; ---------- where things are ----------
; The vault folder from ~\.gogo\install.json (gogo.mjs writes it); "" if not found.
GogoVault(installJson) {
  text := ""
  try text := FileRead(installJson, "UTF-8")
  if !RegExMatch(text, '"vault"\s*:\s*"((?:[^"\\]|\\.)*)"', &m)
    return ""
  return StrReplace(StrReplace(m[1], '\"', '"'), "\\", "\")
}

; The browser shortcuts open in: the default one if it is Chrome or Edge, else Chrome, else Edge.
; {exe, name (process), data (its User Data folder)}; exe = "" when neither is installed (pages open with Windows' default).
FindBrowser() {
  app := EnvGet("LOCALAPPDATA"), x86 := EnvGet("ProgramFiles(x86)")
  chrome := {paths: [A_ProgramFiles "\Google\Chrome\Application\chrome.exe", x86 "\Google\Chrome\Application\chrome.exe", app "\Google\Chrome\Application\chrome.exe"]
    , name: "chrome.exe", data: app "\Google\Chrome\User Data"}
  edge := {paths: [x86 "\Microsoft\Edge\Application\msedge.exe", A_ProgramFiles "\Microsoft\Edge\Application\msedge.exe"]
    , name: "msedge.exe", data: app "\Microsoft\Edge\User Data"}
  progId := ""
  try progId := RegRead("HKCU\Software\Microsoft\Windows\Shell\Associations\UrlAssociations\https\UserChoice", "ProgId")
  for b in InStr(progId, "MSEdge") ? [edge, chrome] : [chrome, edge]
    for p in b.paths
      if FileExist(p)
        return {exe: p, name: b.name, data: b.data}
  return {exe: "", name: "", data: ""}
}

; "11월 25일 (수)"
DayLabel() => FormatTime(, "M월 d일") " (" SubStr("일월화수목금토", A_WDay, 1) ")"

; Percent-encoding (UTF-8) for an obsidian:// link.
UriEncode(text) {
  buf := Buffer(StrPut(text, "UTF-8")), StrPut(text, buf, "UTF-8"), out := ""
  loop buf.Size - 1 {
    b := NumGet(buf, A_Index - 1, "uchar")
    out .= (b >= 0x30 && b <= 0x39) || (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A) || b = 0x2D || b = 0x2E || b = 0x5F || b = 0x7E
      ? Chr(b) : Format("%{:02X}", b)
  }
  return out
}

; Replaces a note in one step (no BOM). False if it could not be written.
WriteNote(file, text) {
  try {
    FileOpen(file ".tmp", "w", "UTF-8-RAW").Write(text)
    FileMove(file ".tmp", file, 1)
    return true
  }
  return false
}

ReadNote(file) {
  text := ""
  try text := FileRead(file, "UTF-8")
  return LTrim(text, Chr(0xFEFF))
}

JoinLines(lines, nl) {
  out := ""
  for i, line in lines
    out .= (i > 1 ? nl : "") line
  return out
}

; ---------- 오늘의 퀘스트 (보관함 「내 일정/오늘의 퀘스트.md」) ----------
; "## 분류" 줄 아래 "- [ ] 할 일" (체크 = [x]). 하루 여러 번 = 이름 끝 "(0/3)". 버튼 = 끝에 " → 이름=주소" (여러 개 가능,
; " → 이름" 만 = 바로가기 목록의 그 이름). 숨은 줄 "<!-- gogo-quest-date: 2026-11-25 -->" = 체크를 마지막으로 푼 날.

; One line of the note as a quest {label, done, target, counted, links}, or "" if it is not one.
ParseQuestLine(line) {
  if !RegExMatch(line, "^\s*[-*+]\s+(?:\[([^\]])\](?:\s+|$))?(.*?)\s*$", &m) || m[2] = ""
    return ""
  parts := StrSplit(RegExReplace(m[2], "\s+(?:→|->)\s*", Chr(1)), Chr(1)), name := Trim(parts[1]), links := []
  target := 1, done := 0, counted := false
  if RegExMatch(name, "\s*\(\s*(\d+)\s*/\s*(\d+)\s*\)$", &c)
    name := Trim(SubStr(name, 1, c.Pos - 1)), done := Integer(c[1]), target := Max(1, Integer(c[2])), counted := true
  if name = ""
    return ""
  if m[1] = "x" || m[1] = "X"
    done := target
  loop parts.Length - 1 {
    p := Trim(parts[A_Index + 1])
    if p = ""
      continue
    if RegExMatch(p, "i)^(https?://|[a-z]:\\|\\\\)")
      links.Push({label: ShortTarget(p), open: p})
    else if at := InStr(p, "=")
      links.Push({label: Trim(SubStr(p, 1, at - 1)), open: NormalizeTarget(SubStr(p, at + 1))})
    else
      links.Push({label: p, open: p})   ; a shortcut of the list, by its name
  }
  return {cat: false, label: name, done: Min(done, target), target: target, counted: counted, links: links}
}

; The note as {date, complete, total, rows}: rows = categories {cat: true, label} and quests (with .line = their line number).
ParseQuestNote(text) {
  info := {date: "", day: "", complete: 0, total: 0, rows: []}
  for i, line in StrSplit(text, "`n", "`r") {
    if RegExMatch(line, "<!--\s*gogo-quest-date:\s*(\d{4}-\d{2}-\d{2})\s*-->", &d)
      info.date := d[1]
    else if RegExMatch(line, "^\s*#{2,6}\s+(.*\S)", &h)
      info.rows.Push({cat: true, label: h[1]})
    else if q := ParseQuestLine(line) {
      q.line := i, info.rows.Push(q), info.total++
      if q.done >= q.target
        info.complete++
    }
  }
  return info
}

; The quest line with `done` (of its target): [x] when complete, its "(n/m)" updated. Indent, name and buttons stay.
SetQuestLine(line, done) {
  q := ParseQuestLine(line)
  if !q || !RegExMatch(line, "^(\s*[-*+]\s+)(?:\[[^\]]\]\s+)?(.*)$", &m)
    return line
  done := Max(0, Min(q.target, done)), rest := m[2]
  if q.counted
    rest := RegExReplace(rest, "\(\s*\d+\s*/\s*(\d+)\s*\)(?=\s*(?:$|→|->))", "(" done "/$1)", , 1)
  return m[1] "[" (done >= q.target ? "x" : " ") "] " rest
}

; A new day: every quest unticked and its count back to 0, the note stamped with `date`.
ResetQuestText(text, date) {
  nl := InStr(text, "`r`n") ? "`r`n" : "`n", lines := StrSplit(text, "`n", "`r"), stamped := false
  for i, line in lines {
    if RegExMatch(line, "<!--\s*gogo-quest-date:")
      lines[i] := "<!-- gogo-quest-date: " date " -->", stamped := true
    else if ParseQuestLine(line)
      lines[i] := SetQuestLine(line, 0)
  }
  out := JoinLines(lines, nl)
  return stamped ? out : RTrim(out, "`r`n") nl nl "<!-- gogo-quest-date: " date " -->" nl
}

; ---------- 일정 (보관함 「내 일정/일정.md」) ----------
; 한 줄에 하나: "- [ ] 2026-12-03 | 분류 | 내용" · 시간 "2026-12-03 15:00 | …" · 기간 "2026-12-10~2026-12-12" (~12-12, ~12 도 됨)
; · 끝난 일 [x] · 분류는 빼도 됨 ("- [ ] 2026-12-03 | 내용"). → [{start, end, cat, title, status}], status = 완료 / 지남 / "".
ParseCalendarNote(text, today) {
  list := []
  for line in StrSplit(text, "`n", "`r") {
    if !RegExMatch(line, "^\s*[-*+]\s+(?:\[([^\]])\]\s+)?(\d{4})[-./](\d{1,2})[-./](\d{1,2})(?:\s*~\s*(?:(?:(\d{4})[-./])?(\d{1,2})[-./])?(\d{1,2}))?(?:\s+(\d{1,2}:\d{2}(?:\s*~\s*\d{1,2}:\d{2})?))?\s*(.*)$", &m)
      continue
    start := Ymd(m[2], m[3], m[4]), end := start
    if start = ""
      continue
    if m[7] != "" {
      end := Ymd(m[5] != "" ? m[5] : m[2], m[6] != "" ? m[6] : m[3], m[7])
      if end = "" || StrCompare(end, start) < 0
        end := start
    }
    parts := StrSplit(LTrim(Trim(m[9]), "| "), "|", " `t"), cat := "", title := ""
    if parts.Length >= 2 {
      cat := parts[1]
      loop parts.Length - 1
        title .= (A_Index > 1 ? " | " : "") parts[A_Index + 1]
    } else if parts.Length
      title := parts[1]
    title := Trim((m[8] != "" ? m[8] " " : "") title)
    if title = ""
      title := cat != "" ? cat : "일정"
    status := m[1] = "x" || m[1] = "X" ? "완료" : StrCompare(end, today) < 0 ? "지남" : ""
    list.Push({start: start, end: end, cat: cat, title: title, status: status})
  }
  return list
}

; "2026-12-03" from its parts, or "" if that is not a date.
Ymd(y, m, d) {
  t := y Format("{:02d}{:02d}", Integer(m), Integer(d))
  return IsTime(t) && StrLen(t) = 8 ? SubStr(t, 1, 4) "-" SubStr(t, 5, 2) "-" SubStr(t, 7, 2) : ""
}
