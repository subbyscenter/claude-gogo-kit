; Minimal GDI+ painting for the shortcuts popup: a layered window (per-pixel alpha: round corners, soft shadow,
; anti-aliased circles) painted from a 32-bit DIB and handed to UpdateLayeredWindow.
#Requires AutoHotkey v2.0

GdipStart() {
  static token := 0
  if token
    return
  DllCall("LoadLibrary", "str", "gdiplus", "ptr")
  input := Buffer(24, 0), NumPut("uint", 1, input, 0)
  DllCall("gdiplus\GdiplusStartup", "ptr*", &token, "ptr", input, "ptr", 0)
}

class Canvas {
  __New(w, h) {
    GdipStart()
    this.w := w, this.h := h
    info := Buffer(40, 0)
    NumPut("uint", 40, info, 0), NumPut("int", w, info, 4), NumPut("int", -h, info, 8), NumPut("ushort", 1, info, 12), NumPut("ushort", 32, info, 14)
    this.dc := DllCall("CreateCompatibleDC", "ptr", 0, "ptr")
    this.bitmap := DllCall("CreateDIBSection", "ptr", this.dc, "ptr", info, "uint", 0, "ptr*", 0, "ptr", 0, "uint", 0, "ptr")
    this.old := DllCall("SelectObject", "ptr", this.dc, "ptr", this.bitmap, "ptr")
    DllCall("gdiplus\GdipCreateFromHDC", "ptr", this.dc, "ptr*", &g := 0)
    this.g := g
    DllCall("gdiplus\GdipSetSmoothingMode", "ptr", g, "int", 4)        ; anti-alias
    DllCall("gdiplus\GdipSetInterpolationMode", "ptr", g, "int", 7)    ; high-quality bicubic
    DllCall("gdiplus\GdipSetPixelOffsetMode", "ptr", g, "int", 2)      ; high quality
    DllCall("gdiplus\GdipSetTextRenderingHint", "ptr", g, "int", 4)    ; anti-alias (ClearType breaks the alpha)
  }
  __Delete() {
    DllCall("gdiplus\GdipDeleteGraphics", "ptr", this.g)
    DllCall("SelectObject", "ptr", this.dc, "ptr", this.old)
    DllCall("DeleteObject", "ptr", this.bitmap)
    DllCall("DeleteDC", "ptr", this.dc)
  }
  static Brush(argb) {
    DllCall("gdiplus\GdipCreateSolidFill", "uint", argb, "ptr*", &brush := 0)
    return brush
  }
  RoundPath(x, y, w, h, r) {
    DllCall("gdiplus\GdipCreatePath", "int", 0, "ptr*", &path := 0)
    d := r * 2
    DllCall("gdiplus\GdipAddPathArc", "ptr", path, "float", x, "float", y, "float", d, "float", d, "float", 180, "float", 90)
    DllCall("gdiplus\GdipAddPathArc", "ptr", path, "float", x + w - d, "float", y, "float", d, "float", d, "float", 270, "float", 90)
    DllCall("gdiplus\GdipAddPathArc", "ptr", path, "float", x + w - d, "float", y + h - d, "float", d, "float", d, "float", 0, "float", 90)
    DllCall("gdiplus\GdipAddPathArc", "ptr", path, "float", x, "float", y + h - d, "float", d, "float", d, "float", 90, "float", 90)
    DllCall("gdiplus\GdipClosePathFigure", "ptr", path)
    return path
  }
  RoundRect(x, y, w, h, r, argb) {
    path := this.RoundPath(x, y, w, h, r), brush := Canvas.Brush(argb)
    DllCall("gdiplus\GdipFillPath", "ptr", this.g, "ptr", brush, "ptr", path)
    DllCall("gdiplus\GdipDeleteBrush", "ptr", brush), DllCall("gdiplus\GdipDeletePath", "ptr", path)
  }
  RoundBorder(x, y, w, h, r, argb, width := 1) {
    path := this.RoundPath(x, y, w, h, r)
    DllCall("gdiplus\GdipCreatePen1", "uint", argb, "float", width, "int", 2, "ptr*", &pen := 0)
    DllCall("gdiplus\GdipDrawPath", "ptr", this.g, "ptr", pen, "ptr", path)
    DllCall("gdiplus\GdipDeletePen", "ptr", pen), DllCall("gdiplus\GdipDeletePath", "ptr", path)
  }
  Circle(x, y, d, argb) {
    brush := Canvas.Brush(argb)
    DllCall("gdiplus\GdipFillEllipse", "ptr", this.g, "ptr", brush, "float", x, "float", y, "float", d, "float", d)
    DllCall("gdiplus\GdipDeleteBrush", "ptr", brush)
  }
  Ring(x, y, d, argb, width) {
    DllCall("gdiplus\GdipCreatePen1", "uint", argb, "float", width, "int", 2, "ptr*", &pen := 0)
    DllCall("gdiplus\GdipDrawEllipse", "ptr", this.g, "ptr", pen, "float", x, "float", y, "float", d, "float", d)
    DllCall("gdiplus\GdipDeletePen", "ptr", pen)
  }
  ; A picture inside a circle: a big one fills it, a small one (a 16/32 px favicon) sits in the middle at its size.
  Picture(image, x, y, d) {
    DllCall("gdiplus\GdipGetImageWidth", "ptr", image, "uint*", &iw := 0), DllCall("gdiplus\GdipGetImageHeight", "ptr", image, "uint*", &ih := 0)
    if !iw || !ih
      return false
    if Max(iw, ih) >= d * 0.9 {
      DllCall("gdiplus\GdipCreatePath", "int", 0, "ptr*", &path := 0)
      DllCall("gdiplus\GdipAddPathEllipse", "ptr", path, "float", x, "float", y, "float", d, "float", d)
      DllCall("gdiplus\GdipSetClipPath", "ptr", this.g, "ptr", path, "int", 0)
      scale := d / Min(iw, ih)
      DllCall("gdiplus\GdipDrawImageRect", "ptr", this.g, "ptr", image, "float", x + (d - iw * scale) / 2, "float", y + (d - ih * scale) / 2, "float", iw * scale, "float", ih * scale)
      DllCall("gdiplus\GdipResetClip", "ptr", this.g), DllCall("gdiplus\GdipDeletePath", "ptr", path)
    } else {
      this.Circle(x, y, d, 0xFFF1F2F5)
      side := Min(d * 0.56, Max(iw, ih) * 2), scale := side / Max(iw, ih)
      DllCall("gdiplus\GdipDrawImageRect", "ptr", this.g, "ptr", image, "float", x + (d - iw * scale) / 2, "float", y + (d - ih * scale) / 2, "float", iw * scale, "float", ih * scale)
    }
    return true
  }
  ; align: 0 left, 1 centre, 2 right (always centred vertically).
  Text(text, x, y, w, h, size, argb, bold := false, font := "Malgun Gothic", align := 1) {
    DllCall("gdiplus\GdipCreateFontFamilyFromName", "wstr", font, "ptr", 0, "ptr*", &family := 0)
    DllCall("gdiplus\GdipCreateFont", "ptr", family, "float", size, "int", bold ? 1 : 0, "int", 2, "ptr*", &font := 0)
    DllCall("gdiplus\GdipCreateStringFormat", "int", 0x1000, "int", 0, "ptr*", &format := 0) ; no wrap
    DllCall("gdiplus\GdipSetStringFormatAlign", "ptr", format, "int", align), DllCall("gdiplus\GdipSetStringFormatLineAlign", "ptr", format, "int", 1)
    DllCall("gdiplus\GdipSetStringFormatTrimming", "ptr", format, "int", 3) ; ellipsis
    rect := Buffer(16), NumPut("float", x, rect, 0), NumPut("float", y, rect, 4), NumPut("float", w, rect, 8), NumPut("float", h, rect, 12)
    brush := Canvas.Brush(argb)
    DllCall("gdiplus\GdipDrawString", "ptr", this.g, "wstr", text, "int", -1, "ptr", font, "ptr", rect, "ptr", format, "ptr", brush)
    DllCall("gdiplus\GdipDeleteBrush", "ptr", brush), DllCall("gdiplus\GdipDeleteStringFormat", "ptr", format)
    DllCall("gdiplus\GdipDeleteFont", "ptr", font), DllCall("gdiplus\GdipDeleteFontFamily", "ptr", family)
  }
  ; Hand the painted pixels to the layered window at screen position x, y.
  Present(hwnd, x, y) {
    point := Buffer(8), NumPut("int", x, point, 0), NumPut("int", y, point, 4)
    size := Buffer(8), NumPut("int", this.w, size, 0), NumPut("int", this.h, size, 4)
    source := Buffer(8, 0)
    blend := Buffer(4, 0), NumPut("uchar", 255, blend, 2), NumPut("uchar", 1, blend, 3) ; constant alpha 255, AC_SRC_ALPHA
    return DllCall("UpdateLayeredWindow", "ptr", hwnd, "ptr", 0, "ptr", point, "ptr", size, "ptr", this.dc, "ptr", source, "uint", 0, "ptr", blend, "uint", 2)
  }
}

; Pictures by file, loaded once (a reload of the list keeps them; a changed file is read again).
LoadPicture(path) {
  static cache := Map()
  if !FileExist(path)
    return 0
  key := path "|" FileGetTime(path) "|" FileGetSize(path)
  if cache.Has(key)
    return cache[key]
  GdipStart()
  image := 0
  if DllCall("gdiplus\GdipLoadImageFromFile", "wstr", path, "ptr*", &image) != 0
    image := 0
  cache[key] := image
  return image
}

; A picture made into a square PNG icon at dest (centre cut, at most `side` px): a big photo would slow every repaint.
SaveIconPicture(source, dest, side := 192) {
  GdipStart()
  if DllCall("gdiplus\GdipLoadImageFromFile", "wstr", source, "ptr*", &image := 0) != 0 || !image
    return false
  DllCall("gdiplus\GdipGetImageWidth", "ptr", image, "uint*", &iw := 0), DllCall("gdiplus\GdipGetImageHeight", "ptr", image, "uint*", &ih := 0)
  cut := Min(iw, ih), side := Min(side, cut)
  DllCall("gdiplus\GdipCreateBitmapFromScan0", "int", side, "int", side, "int", 0, "int", 0x26200A, "ptr", 0, "ptr*", &bitmap := 0) ; 32bpp ARGB
  DllCall("gdiplus\GdipGetImageGraphicsContext", "ptr", bitmap, "ptr*", &g := 0)
  DllCall("gdiplus\GdipSetInterpolationMode", "ptr", g, "int", 7), DllCall("gdiplus\GdipSetPixelOffsetMode", "ptr", g, "int", 2)
  DllCall("gdiplus\GdipDrawImageRectRect", "ptr", g, "ptr", image, "float", 0, "float", 0, "float", side, "float", side
    , "float", (iw - cut) / 2, "float", (ih - cut) / 2, "float", cut, "float", cut, "int", 2, "ptr", 0, "ptr", 0, "ptr", 0)
  DllCall("gdiplus\GdipDeleteGraphics", "ptr", g)
  ok := SavePng(bitmap, dest)
  DllCall("gdiplus\GdipDisposeImage", "ptr", bitmap), DllCall("gdiplus\GdipDisposeImage", "ptr", image)
  return ok
}

SavePng(bitmap, path) {
  clsid := Buffer(16)
  DllCall("ole32\CLSIDFromString", "wstr", "{557CF406-1A04-11D3-9A73-0000F81EF32E}", "ptr", clsid) ; PNG encoder
  return DllCall("gdiplus\GdipSaveImageToFile", "ptr", bitmap, "wstr", path, "ptr", clsid, "ptr", 0) = 0
}
