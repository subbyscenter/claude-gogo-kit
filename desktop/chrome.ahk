; gogo 바로가기 창 — a Chrome (or Edge) window's tabs, read through its accessibility tree (MSAA), for 「그룹 만들기」.
; Tab names are matched in Korean Chrome's wording ("… - 이름 그룹에 속함"). BROWSER (lib.ahk FindBrowser) = which one.
#Requires AutoHotkey v2.0

; The Chrome window the user was last in: `prev` if it is one, else the topmost Chrome window; 0 if none.
LastChromeWindow(prev := 0) {
  if prev && ChromeWindow(prev)
    return prev
  for hwnd in WinGetList("ahk_exe " BROWSER.name " ahk_class Chrome_WidgetWin_1")
    if ChromeWindow(hwnd)
      return hwnd
  return 0
}

; A visible browser window ("page - Chrome"; not the profile picker "Google Chrome" or an app window).
ChromeWindow(hwnd) {
  try return BROWSER.name != "" && WinGetProcessName(hwnd) = BROWSER.name && WinGetClass(hwnd) = "Chrome_WidgetWin_1"
      && RegExMatch(WinGetTitle(hwnd), " - ((Google )?Chrome|Microsoft.{0,2}Edge)$") && (WinGetStyle(hwnd) & 0x10000000)
  return false
}

; The tabs of a Chrome window, left to right: {name, group, selected, acc} — name without Chrome's "- 메모리 사용량 …"
; and group notes, group = the tab group it is in ("" if none). profile = the window's profile folder when its title
; names the profile ("… - Chrome - 이름 (프로필)"), else "". 0 if the tab strip is not found.
ChromeTabs(hwnd) {
  root := AccFromWindow(hwnd)
  strip := root ? AccFind(root, el => AccGet(el, "accRole") = 0x3C, [0x0F, 0x14, 0x16]) : 0   ; page tab list
  if !strip
    return 0
  tabs := []
  for el in AccChildren(strip) {
    if AccGet(el, "accRole") != 0x25   ; page tab (a group's header is a nested tab list)
      continue
    name := AccGet(el, "accName"), group := ""
    if RegExMatch(name, "^(.*) - (.+?) 그룹에 속함$", &m)   ; the last " - " before the note
      name := m[1], group := m[2]
    name := RegExReplace(name, " - 메모리 사용량.*$")
    tabs.Push({name: name, group: group, selected: (AccGet(el, "accState") & 2) != 0, acc: el})
  }
  profile := ""
  if RegExMatch(AccGet(root, "accName"), " - (?:Google )?Chrome - (.+)$", &m)
    profile := ChromeProfileDir(m[1]) || (RegExMatch(m[1], "\(([^()]+)\)$", &p) ? ChromeProfileDir(p[1]) : "")
  return {tabs: tabs, profile: profile, root: root, hwnd: hwnd}
}

; The address of each of `picked` (tabs from ChromeTabs): Chrome shows only the open tab's page, so each one is opened
; in turn and its page read, then the tab that was open comes back. "" for a tab whose page is not http(s).
; A minimized window has no page to read: it is shown (without the focus) meanwhile.
ChromeTabUrls(info, picked) {
  urls := [], back := 0
  for tab in info.tabs
    if tab.selected
      back := tab
  minimized := WinGetMinMax(info.hwnd) = -1
  if minimized
    DllCall("ShowWindow", "ptr", info.hwnd, "int", 4)   ; SW_SHOWNOACTIVATE
  for tab in picked {
    try tab.acc.accDoDefaultAction(0)
    urls.Push(OpenPageUrl(info.root, tab))
  }
  if back
    try back.acc.accDoDefaultAction(0)
  if minimized
    DllCall("ShowWindow", "ptr", info.hwnd, "int", 7)   ; SW_SHOWMINNOACTIVE
  return urls
}

; Waits (up to 3 s: a sleeping tab loads again) until the tab is open and its page is the one shown.
OpenPageUrl(root, tab) {
  deadline := A_TickCount + 3000, url := ""
  loop {
    if AccGet(tab.acc, "accState") & 2 {
      page := AccFind(root, el => AccGet(el, "accRole") = 0x0F, [0x14, 0x16, 0x3C])   ; the page (document)
      url := page ? AccGet(page, "accValue") : "", title := page ? AccGet(page, "accName") : ""
      if RegExMatch(url, "i)^https?://") && title != "" && InStr(tab.name, title) = 1
        return url
    }
    if A_TickCount > deadline
      return RegExMatch(url, "i)^https?://") ? url : ""
    Sleep(60)
  }
}

; ---------- MSAA ----------
AccFromWindow(hwnd) {
  static lib := DllCall("LoadLibrary", "str", "oleacc", "ptr")   ; kept loaded: the objects it hands out live in it
  iid := Buffer(16)
  DllCall("ole32\IIDFromString", "wstr", "{618736E0-3C3D-11CF-810C-00AA00389B71}", "ptr", iid)   ; IAccessible
  if DllCall("oleacc\AccessibleObjectFromWindow", "ptr", hwnd, "uint", 0xFFFFFFFC, "ptr", iid, "ptr*", &p := 0) = 0 && p
    return ComValue(9, p)
  return 0
}

AccChildren(acc) {
  list := []
  try n := acc.accChildCount
  catch
    return list
  if !n
    return list
  size := 8 + 2 * A_PtrSize   ; VARIANT
  buf := Buffer(n * size, 0)
  if DllCall("oleacc\AccessibleChildren", "ptr", ComObjValue(acc), "int", 0, "int", n, "ptr", buf, "int*", &got := 0) != 0
    return list
  loop got {
    at := (A_Index - 1) * size
    if NumGet(buf, at, "ushort") = 9   ; VT_DISPATCH
      list.Push(ComValue(9, NumGet(buf, at + 8, "ptr")))
  }
  return list
}

AccGet(acc, prop) {
  try return acc.%prop%(0)
  return ""
}

; Depth-first search for the first element `match` accepts. Hidden parts and elements of the roles in `skip` are not
; searched below: every step is a call into Chrome, and the page and toolbars hold hundreds of elements.
AccFind(acc, match, skip, depth := 0) {
  if depth > 15 || (AccGet(acc, "accState") & 0x8000)   ; invisible
    return 0
  if match(acc)
    return acc
  role := AccGet(acc, "accRole")
  for r in skip
    if role = r
      return 0
  for child in AccChildren(acc)
    if found := AccFind(child, match, skip, depth + 1)
      return found
  return 0
}
