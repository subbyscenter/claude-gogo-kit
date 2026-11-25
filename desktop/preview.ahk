; Shows the shortcuts popup (with the quest window and the calendar) for a look without touching the keyboard or the
; focus: at x, y (screen pixels), for a few seconds, then exits. Set GOGO_HOME first to look at another data folder.
;   AutoHotkey64.exe preview.ahk [x] [y] [ms] [hover] [mode: order / edit]
#Requires AutoHotkey v2.0
#Include lib.ahk
#Include draw.ahk
#Include popup.ahk
#Include chrome.ahk
DllCall("SetThreadDpiAwarenessContext", "ptr", -4, "ptr")
CoordMode("Mouse", "Screen")
x := A_Args.Length >= 1 ? Integer(A_Args[1]) : 200, y := A_Args.Length >= 2 ? Integer(A_Args[2]) : 200
ms := A_Args.Length >= 3 ? Integer(A_Args[3]) : 3000
ShowShortcuts(false)
popup.GetPos(, , &w, &h)
posX := x, posY := y
if A_Args.Length >= 4
  hover := Integer(A_Args[4])
if A_Args.Length >= 5
  mode := A_Args[5]
Relayout()
try FileAppend("shown " w "x" h " at " x "," y " · quests " questInfo.complete "/" questInfo.total " · calendar days " calEvents.Count
  " · browser " (BROWSER.exe != "" ? BROWSER.name : "default") "`n", "*", "UTF-8")  ; no console: skip
Sleep(ms)
ExitApp()
