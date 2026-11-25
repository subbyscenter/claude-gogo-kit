; Self-test of the parts that need no window: the shortcut list, the quest note and the calendar note. Works in a
; folder of its own under %TEMP% (GOGO_HOME is set to it) — the real ~\.gogo and vault are not touched.
;   AutoHotkey64.exe /ErrorStdOut test.ahk          → PASS / FAIL lines, exit code = number of failures
#Requires AutoHotkey v2.0
OnError((e, *) => (FileAppend("ERROR " e.Message " — " e.What " line " e.Line " " e.Extra "`n", "*", "UTF-8"), ExitApp(99)))
SANDBOX :=A_Temp "\gogo-desktop-test-" A_TickCount
DirCreate(SANDBOX "\vault\내 일정")
FileOpen(SANDBOX "\install.json", "w", "UTF-8-RAW").Write('{"pcName":"시험","vault":"' StrReplace(SANDBOX "\vault", "\", "\\") '"}')
EnvSet("GOGO_HOME", SANDBOX)
#Include lib.ahk
#Include draw.ahk
#Include popup.ahk
#Include chrome.ahk
failures := 0
Check(name, ok, detail := "") {
  global failures
  FileAppend((ok ? "PASS " : "FAIL ") name (detail != "" ? "  " detail : "") "`n", "*", "UTF-8")
  if !ok
    failures++
}

; ---- where things are ----
Check("data folder from GOGO_HOME", DATA_DIR = SANDBOX "\desktop" && SHORTCUTS = SANDBOX "\desktop\shortcuts.txt")
Check("vault from install.json", VAULT = SANDBOX "\vault", VAULT)
Check("notes in the vault", QUEST_MD = SANDBOX "\vault\내 일정\오늘의 퀘스트.md" && CAL_MD = SANDBOX "\vault\내 일정\일정.md")
Check("a browser found (Chrome or Edge)", BROWSER.exe = "" || FileExist(BROWSER.exe), BROWSER.exe)
Check("obsidian link encoding", UriEncode("C:\내 일정\a b.md") = "C%3A%5C%EB%82%B4%20%EC%9D%BC%EC%A0%95%5Ca%20b.md")

; ---- shortcuts list ----
Check("no list yet: one empty section", (secs := LoadSections(SHORTCUTS)).Length = 1 && !secs[1].items.Length)
DirCreate(DATA_DIR)
FileOpen(SHORTCUTS, "w", "UTF-8").Write("# 설명`n[회사]`n메일 | https://mail.example.com`n폴더 | C:\Windows`n[집]`n그림 | https://a.com | icons\a.png`n")
secs := LoadSections(SHORTCUTS)
Check("categories and shortcuts", secs.Length = 2 && secs[1].name = "회사" && secs[1].items.Length = 2 && secs[2].items[1].name = "그림")
Check("a picture in the data folder", secs[2].items[1].picture = DATA_DIR "\icons\a.png" && ShortcutLine(secs[2].items[1]) = "그림 | https://a.com | icons\a.png")
secs[1].items.Push({name: "새것", target: "https://b.com", picture: "", color: "", up: "", profile: ""})
SaveSections(SHORTCUTS, secs)
text := FileRead(SHORTCUTS, "UTF-8")
Check("saved: comment kept, new one in its category", InStr(text, "# 설명") = 1 && InStr(text, "폴더 | C:\Windows`r`n새것 | https://b.com`r`n`r`n[집]"))

; ---- quest note ----
q := ParseQuestLine("- [ ] 거래처 전화 (1/3) → 메일 → 검색=https://x.com/?q=1")
Check("quest with a count and buttons", q && q.label = "거래처 전화" && q.done = 1 && q.target = 3 && q.links.Length = 2
  && q.links[1].open = "메일" && q.links[2].label = "검색" && q.links[2].open = "https://x.com/?q=1")
Check("ticked quest = done", (q := ParseQuestLine("  - [x] 메일 확인")) && q.done = 1 && q.target = 1)
Check("plain bullet is a quest too", (q := ParseQuestLine("- 운동")) && q.label = "운동" && q.done = 0)
Check("not quests", !ParseQuestLine("> - [ ] 예시") && !ParseQuestLine("## 회사") && !ParseQuestLine("- [ ] ") && !ParseQuestLine("텍스트"))
Check("a bare address as a button", (q := ParseQuestLine("- [ ] 보고서 -> https://docs.example.com/a")) && q.links[1].open = "https://docs.example.com/a" && q.links[1].label = "docs.example.com/a")
Check("tick one", SetQuestLine("- [ ] 메일 확인", 1) = "- [x] 메일 확인")
Check("count up keeps buttons", SetQuestLine("  - [ ] 전화 (1/3) → 메일", 2) = "  - [ ] 전화 (2/3) → 메일")
Check("count complete ticks it", SetQuestLine("- [ ] 전화 (2/3)", 3) = "- [x] 전화 (3/3)")
Check("untick, a count in the name stays", SetQuestLine("- [x] 1/2분기 (2/2) 보고 (3/3)", 0) = "- [ ] 1/2분기 (2/2) 보고 (0/3)")
note := "# 오늘의 퀘스트`r`n`r`n> - [ ] 예시`r`n`r`n## 회사`r`n- [x] 메일 확인`r`n- [ ] 전화 (2/3) → 메일`r`n## 집`r`n- 운동`r`n`r`n<!-- gogo-quest-date: 2000-01-01 -->`r`n"
info := ParseQuestNote(note)
Check("note read", info.date = "2000-01-01" && info.total = 3 && info.complete = 1 && info.rows.Length = 5 && info.rows[1].cat && info.rows[2].line = 6)
reset := ResetQuestText(note, "2026-11-25")
Check("new day: unticked, counts 0, stamped, the rest as it was", reset = StrReplace(StrReplace(StrReplace(StrReplace(note
  , "- [x] 메일", "- [ ] 메일"), "(2/3)", "(0/3)"), "- 운동", "- [ ] 운동"), "2000-01-01", "2026-11-25"))
Check("no stamp yet: added at the end", InStr(ResetQuestText("- [x] a`n", "2026-11-25"), "- [ ] a`n`n<!-- gogo-quest-date: 2026-11-25 -->`n"))
FileOpen(QUEST_MD, "w", "UTF-8").Write(note)
Check("first look of the day resets the note once", LoadQuests() && questInfo.date = FormatTime(, "yyyy-MM-dd") && questInfo.complete = 0
  && InStr(FileRead(QUEST_MD, "UTF-8"), "전화 (0/3)") && !LoadQuests())
BumpQuest(questInfo.rows[3], 1)
Check("click = one more, saved", InStr(FileRead(QUEST_MD, "UTF-8"), "- [ ] 전화 (1/3) → 메일") && questInfo.rows[3].done = 1)
BumpQuest(questInfo.rows[3], -1), BumpQuest(questInfo.rows[2], 1)
Check("right click = one less; a single one ticks", InStr(FileRead(QUEST_MD, "UTF-8"), "- [x] 메일 확인`r`n- [ ] 전화 (0/3)") && questInfo.complete = 1)
BumpQuest(questInfo.rows[2], 1)
Check("a done one clicked again = back to 0", InStr(FileRead(QUEST_MD, "UTF-8"), "- [ ] 메일 확인") && questInfo.complete = 0)
Check("vault templates hold no quest or event", !ParseQuestNote(FileRead(A_ScriptDir "\..\vault\내 일정\오늘의 퀘스트.md", "UTF-8")).total
  && !ParseCalendarNote(FileRead(A_ScriptDir "\..\vault\내 일정\일정.md", "UTF-8"), "2026-11-25").Length)

; ---- calendar note ----
cal := "# 일정`n> - [ ] 2026-01-01 | 예시`n- [ ] 2026-12-03 | 회사 | 분기 보고서 | 초안`n- [x] 2026-12-10~12 | 출장`n- 2026.1.5 15:00 | 약속 | 치과`n- [ ] 2026-12-30~2027-01-02 | 휴가 | 연말`n- [ ] 2026-02-30 | 틀린 날`n- [ ] 2026-11-20~11-18 | 거꾸로`n"
ev := ParseCalendarNote(cal, "2026-11-25")
Check("calendar lines", ev.Length = 5, ev.Length " events")
Check("category, title with |", ev[1].start = "2026-12-03" && ev[1].end = "2026-12-03" && ev[1].cat = "회사" && ev[1].title = "분기 보고서 | 초안" && ev[1].status = "")
Check("short range, done, no category", ev[2].start = "2026-12-10" && ev[2].end = "2026-12-12" && ev[2].cat = "" && ev[2].title = "출장" && ev[2].status = "완료")
Check("dots, a time, past", ev[3].start = "2026-01-05" && ev[3].cat = "약속" && ev[3].title = "15:00 치과" && ev[3].status = "지남")
Check("range over the new year", ev[4].end = "2027-01-02")
Check("an end before the start = one day", ev[5].start = "2026-11-20" && ev[5].end = "2026-11-20")
FileOpen(CAL_MD, "w", "UTF-8").Write(cal)
Check("calendar map by day", LoadCalendar() && calEvents.Has("2026-12-11") && calEvents["2026-12-31"][1].title = "연말" && !LoadCalendar())

try DirDelete(SANDBOX, true)
FileAppend(failures ? "FAILED " failures "`n" : "ALL PASS`n", "*", "UTF-8")
ExitApp(failures)
