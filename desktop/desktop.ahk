; gogo 바로가기 창 — always-on key for the whole PC (runs at sign-in from the Startup folder, gogo-desktop.vbs).
;   Ctrl+Shift+F   the shortcuts popup: round icons of the pages and folders in ~\.gogo\desktop\shortcuts.txt
;                  (again = close), with today's quests (top right) and the calendar (top centre) from the vault.
;                  Its buttons add, reorder and edit shortcuts and make one of a browser window's tabs.
#Requires AutoHotkey v2.0
#SingleInstance Force
Persistent
#Include lib.ahk
#Include draw.ahk
#Include popup.ahk
#Include chrome.ahk
#Include servers.ahk

; Physical pixels for windows and screens on every monitor (otherwise a scaled screen reports scaled coordinates).
DllCall("SetThreadDpiAwarenessContext", "ptr", -4, "ptr")
CoordMode("Mouse", "Screen")
A_IconTip := "gogo 바로가기`nCtrl+Shift+F 바로가기 · 오늘의 퀘스트 · 달력"

tray := A_TrayMenu
tray.Delete()
tray.Add("바로가기 열기`tCtrl+Shift+F", (*) => ShowShortcuts())
tray.Add("바로가기 목록 편집", (*) => EditShortcuts())
tray.Add("폴더 열기", (*) => OpenFolder())
tray.Add()
tray.Add("다시 불러오기", (*) => Reload())
tray.Add("끄기", (*) => ExitApp())
tray.Default := "바로가기 열기`tCtrl+Shift+F"

SetTimer(SampleServers, 300000)   ; every 5 min: which local servers a browser has open ("last used")

^+f::ToggleShortcuts()

; ---------- keys while the popup has the focus ----------
#HotIf PopupVisible() && WinActive("ahk_id " popup.Hwnd)
Left::Move(-1, 0)
Right::Move(1, 0)
+Left::CalMove(-1)    ; 달력 이전 달
+Right::CalMove(1)    ; 달력 다음 달
Up::Move(0, -1)
Down::Move(0, 1)
Enter::OpenItem(selected || hover || 1)
NumpadEnter::OpenItem(selected || hover || 1)
Space::OpenItem(selected || hover || 1)
Esc::mode ? SetMode("") : HideShortcuts()
1::OpenItem(1)
2::OpenItem(2)
3::OpenItem(3)
4::OpenItem(4)
5::OpenItem(5)
6::OpenItem(6)
7::OpenItem(7)
8::OpenItem(8)
9::OpenItem(9)
#HotIf
