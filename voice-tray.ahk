#Requires AutoHotkey v2.0
#SingleInstance Force
Persistent

; ============================================================================
; OpenCode Voice - tray app
;
; While this script runs, CapsLock gains a "double-tap and hold" gesture to
; record. CapsLock keeps working normally (~ prefix = key passes through).
;
; Quitting the app = voice off + VRAM/RAM freed (kills s1/qwen).
; The runner (runner.mjs) owns the pipeline; this script starts it on launch.
;
; Overlay: wave bars at the bottom, color per phase
;   recording (green) -> transcribing (orange) -> normalizing (blue) -> hides
; ============================================================================

PORT := 8791
; Honor config.json so installs can move off the default port on conflict.
try {
    cfgText := FileRead(A_ScriptDir "\config.json")
    if (RegExMatch(cfgText, '"runnerPort"\s*:\s*(\d+)', &m))
        PORT := Integer(m[1])
} catch {
}
; Prefer the bundled portable Node (installer layout); fall back to PATH.
NODE := "node"
if FileExist(A_ScriptDir "\node\node.exe")
    NODE := A_ScriptDir "\node\node.exe"
RUNNER := A_ScriptDir "\runner.mjs"
ICON_IDLE := A_ScriptDir "\voice-idle.ico"
ICON_REC := A_ScriptDir "\voice-rec.ico"
ICON_PROC := A_ScriptDir "\voice-proc.ico"

; Gesture (ms)
TAP_MAX := 400
GAP := 800
HOLD_MIN := 200

; Overlay (wave bars)
BARS := 17
BARW := 4
BARGAP := 5
BARH := 30
COL_REC := "0x3FB950"   ; green
COL_TRA := "0xF5A623"   ; orange
COL_NOR := "0x4C9AFF"   ; blue

LOGF := A_Temp "\voice-tray.log"
LEVELF := A_Temp "\opencode-stt.level"
PHASEF := A_Temp "\opencode-stt.phase"
; Persisted toggles live outside the install folder (which may be read-only).
STATE_DIR := EnvGet("APPDATA") . "\SOBER-STT-8GB"
WARMF := STATE_DIR "\warm.state"   ; "1" = keep models loaded
REG_RUN := "HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Run"
REG_NAME := "SOBER-STT"

#Include locale.ahk
LOCALEF := STATE_DIR "\locale"
CHUNKF := STATE_DIR "\chunk.state"   ; "0" = single-call mode (default: chunks on)
LISTCF := STATE_DIR "\listcont.state"   ; "1" = carry list numbers across chunks
global ActiveLang := "en"

; UI language lookup with English fallback.
T(key) {
    global LANG, ActiveLang
    try {
        if (LANG[ActiveLang].Has(key))
            return LANG[ActiveLang][key]
        return LANG["en"][key]
    } catch {
        return key
    }
}

; Language switch from the tray menu; persists like the other toggles.
SetLanguage(code, *) {
    global ActiveLang, STATE_DIR, LOCALEF
    ActiveLang := code
    try {
        if (!DirExist(STATE_DIR))
            DirCreate(STATE_DIR)
        try FileDelete(LOCALEF)
        FileAppend(code, LOCALEF)
    } catch {
    }
    BuildTrayMenu()
    RefreshModelsMenu()
}

global runnerPID := 0
global warm := false
global chunking := true
global listcont := false
global lastTapUp := 0
global armed := false
global downTime := 0
global keyDown := false
global OVL := ""
global OVL_TEXT := ""
global OVL_BARSS := []
global OVL_COLOR := ""
global OVL_TICK := 0
global POLL_SEQ := 0
global POLL_N := 0
; Gesture debug log in %TEMP%\voice-tray.log. Off by default.
global VOICE_DEBUG := false

Dbg(m) {
    global VOICE_DEBUG
    if (!VOICE_DEBUG)
        return
    try FileAppend(Format("{1}`t{2}`n", A_TickCount, m), LOGF)
}

; ---- Tray state ----------------------------------------------------------
SetState(state) {
    switch state {
        case "rec":
            TraySetIcon(ICON_REC)
            A_IconTip := T("tip.rec")
            ShowOverlay()
        case "proc":
            TraySetIcon(ICON_PROC)
            A_IconTip := T("tip.proc")
            ShowOverlay()
        default:
            TraySetIcon(ICON_IDLE)
            A_IconTip := T("tip.ready")
            HideOverlay()
    }
}

; ---- Overlay (wave bars) ---------------------------------------------------
; Parent click-through/no-activate; each bar is a colored child window.
BuildOverlay() {
    global OVL, OVL_TEXT, OVL_BARSS, BARS, BARW, BARGAP, COL_REC
    OVL := Gui("+AlwaysOnTop -Caption +ToolWindow +E0x08000000 +E0x20")
    OVL.BackColor := "0x0A0A0A"
    OVL.SetFont("s9 cWhite", "Segoe UI")
    contentW := BARS * (BARW + BARGAP) - BARGAP
    OVL_TEXT := OVL.Add("Text", "x12 y8 w" contentW " h16 Center", "Gravando")
    OVL_BARSS := []
    Loop BARS {
        b := Gui("-Caption +ToolWindow +E0x08000000 +E0x20 +Parent" OVL.Hwnd)
        b.BackColor := COL_REC
        b.Show("x0 y0 w" BARW " h" BARW " NoActivate")
        ApplyPill(b, BARW, BARW)
        OVL_BARSS.Push(b)
    }
}

; Rounded corners (pill) for a bar.
ApplyPill(g, w, h) {
    r := DllCall("gdi32\CreateRoundRectRgn", "int", 0, "int", 0, "int", w + 1, "int", h + 1, "int", w, "int", w, "ptr")
    DllCall("user32\SetWindowRgn", "ptr", g.Hwnd, "ptr", r, "int", true)
}

; Rounded corners for the overlay container.
ApplyRound(g, w, h, radius) {
    r := DllCall("gdi32\CreateRoundRectRgn", "int", 0, "int", 0, "int", w + 1, "int", h + 1, "int", radius, "int", radius, "ptr")
    DllCall("user32\SetWindowRgn", "ptr", g.Hwnd, "ptr", r, "int", true)
}

ShowOverlay() {
    global OVL, OVL_BARSS, OVL_COLOR
    if (!OVL)
        BuildOverlay()
    x := (A_ScreenWidth - 172) // 2
    y := A_ScreenHeight - 150
    OVL.Show("x" x " y" y " w172 h68 NoActivate")
    ApplyRound(OVL, 172, 68, 20)
    for b in OVL_BARSS
        b.Show("NoActivate")
    OVL_COLOR := ""
    SetTimer(UpdateOverlay, 60)
}

HideOverlay() {
    global OVL, OVL_BARSS
    SetTimer(UpdateOverlay, 0)
    if (OVL)
        OVL.Hide()
    for b in OVL_BARSS
        b.Hide()
}

UpdateOverlay(*) {
    global OVL, OVL_TEXT, OVL_BARSS, OVL_COLOR, OVL_TICK
    global BARS, BARW, BARGAP, BARH, COL_REC, COL_TRA, COL_NOR, PHASEF, LEVELF
    phase := "recording"
    try {
        if FileExist(PHASEF)
            phase := Trim(FileRead(PHASEF))
    } catch {
    }
    if (phase = "idle") {
        HideOverlay()
        return
    }

    col := COL_REC, label := T("ov.rec")
    if (phase = "transcribing") {
        col := COL_TRA, label := T("ov.tra")
    } else if (phase = "normalizing") {
        col := COL_NOR, label := T("ov.nor")
    }
    OVL_TEXT.Text := label
    if (col != OVL_COLOR) {
        for b in OVL_BARSS
            b.BackColor := col
        OVL_COLOR := col
    }

    if (phase = "recording") {
        lvl := 0
        try {
            if FileExist(LEVELF)
                lvl := Integer(Trim(FileRead(LEVELF)))
        } catch {
        }
    } else {
        ; no audio: pulse around a mid level, no scrolling
        OVL_TICK += 1
        lvl := 45 + 35 * Abs(Sin(OVL_TICK * 0.18))
    }

    bottom := 8 + 16 + 6 + BARH
    Loop BARS {
        i := A_Index
        env := Sin(3.141592653589793 * i / (BARS + 1))     ; tall in the center, short at the edges
        h := Round(BARW + env * (BARH - BARW) * (0.22 + 0.78 * lvl / 100))
        if (h < BARW)
            h := BARW
        px := 12 + (i - 1) * (BARW + BARGAP)
        b := OVL_BARSS[i]
        b.Move(px, bottom - h, BARW, h)
        ApplyPill(b, BARW, h)
    }
}

; ---- HTTP ------------------------------------------------------------------
HttpPost(path, timeoutMs := 5000, body := "") {
    try {
        req := ComObject("WinHttp.WinHttpRequest.5.1")
        req.SetTimeouts(2000, 2000, 60000, timeoutMs)
        req.Open("POST", "http://127.0.0.1:" . PORT . path, false)
        if (body != "")
            req.SetRequestHeader("Content-Type", "application/json")
        req.Send(body)
        return req.ResponseText
    } catch {
        return ""
    }
}

HttpGet(path, timeoutMs := 1500) {
    try {
        req := ComObject("WinHttp.WinHttpRequest.5.1")
        req.SetTimeouts(1000, 1000, 3000, timeoutMs)
        req.Open("GET", "http://127.0.0.1:" . PORT . path, false)
        req.Send()
        return req.ResponseText
    } catch {
        return ""
    }
}

DoStart() {
    Dbg("DoStart")
    if (HttpPost("/start") = "") {
        SetState("idle")
        TrayTip("OpenCode Voice", T("tip.norunner"), 2)
    } else {
        SetState("rec")
    }
}
DoCancel() {
    Dbg("DoCancel")
    HttpPost("/cancel")
    SetState("idle")
}
DoPipeline() {
    ; /stop returns at once ({started, seq}); the overlay keeps
    ; repainting while phases change, and PollResult closes at the end.
    global POLL_SEQ, POLL_N
    Dbg("DoPipeline")
    resp := HttpPost("/stop", 10000)
    m := ""
    if (RegExMatch(resp, '"seq"\s*:\s*(\d+)', &m)) {
        POLL_SEQ := Integer(m[1])
        POLL_N := 0
        SetTimer(PollResult, 150)
    } else {
        SetState("idle")
        msg := InStr(resp, "no-speech") ? T("tip.nospeech") : "Falha: " . resp
        TrayTip("OpenCode Voice", msg, 2)
    }
}

PollResult(*) {
    global POLL_SEQ, POLL_N
    POLL_N += 1
    r := HttpGet("/result?seq=" . POLL_SEQ, 3000)
    if (InStr(r, '"done":true')) {
        SetTimer(PollResult, 0)
        SetState("idle")
        if (InStr(r, '"ok":false')) {
            msg := InStr(r, "no-speech") ? T("tip.nospeech") : T("tip.failed")
            TrayTip("OpenCode Voice", msg, 2)
        }
        return
    }
    if (POLL_N > 1200) {
        SetTimer(PollResult, 0)
        SetState("idle")
        TrayTip("OpenCode Voice", T("tip.timeout"), 2)
    }
}

; ---- Lifecycle -------------------------------------------------------------
StartRunner() {
    global runnerPID
    if (HttpGet("/health") != "") {
        runnerPID := 0
        return
    }
    Run('"' . NODE . '" "' . RUNNER . '"', A_ScriptDir, "Hide", &runnerPID)
    Loop 40 {
        Sleep 200
        if (HttpGet("/health") != "")
            return
    }
    TrayTip("OpenCode Voice", T("tip.noserver"), 3)
}

StopRunner() {
    global runnerPID
    try HttpPost("/kill")
    if (runnerPID) {
        try ProcessClose(runnerPID)
        runnerPID := 0
    }
}

ExitVoice(*) {
    HideOverlay()
    StopRunner()
    ExitApp()
}

ToggleWarm(*) {
    global warm, STATE_DIR, WARMF
    warm := !warm
    try {
        if (!DirExist(STATE_DIR))
            DirCreate(STATE_DIR)
        try FileDelete(WARMF)
        FileAppend(warm ? "1" : "0", WARMF)
    } catch {
    }
    HttpPost("/warm", 5000, warm ? '{"enabled":true}' : '{"enabled":false}')
    if (warm) {
        A_TrayMenu.Check(T("menu.warm"))
        TrayTip("OpenCode Voice", T("tip.warm.on"), 1)
    } else {
        A_TrayMenu.Uncheck(T("menu.warm"))
        TrayTip("OpenCode Voice", T("tip.warm.off"), 1)
    }
}

; ---- Autostart (Iniciar com o Windows) ------------------------------------
; Persisted in HKCU\...\Run; A_ScriptFullPath covers both dev (.ahk) and the
; compiled SOBER-STT.exe from the installer.
IsAutostart() {
    global REG_RUN, REG_NAME
    try {
        RegRead(REG_RUN, REG_NAME)
        return true
    } catch {
        return false
    }
}

SetAutostart(enable) {
    global REG_RUN, REG_NAME
    if (enable) {
        try RegWrite('"' . A_ScriptFullPath . '"', "REG_SZ", REG_RUN, REG_NAME)
    } else {
        try RegDelete(REG_RUN, REG_NAME)
    }
}

ToggleAutostart(*) {
    enable := !IsAutostart()
    SetAutostart(enable)
    if (enable) {
        A_TrayMenu.Check(T("menu.autostart"))
        TrayTip("OpenCode Voice", T("tip.auto.on"), 1)
    } else {
        A_TrayMenu.Uncheck(T("menu.autostart"))
        TrayTip("OpenCode Voice", T("tip.auto.off"), 1)
    }
}

ToggleChunk(*) {
    global chunking, STATE_DIR, CHUNKF
    chunking := !chunking
    try {
        if (!DirExist(STATE_DIR))
            DirCreate(STATE_DIR)
        try FileDelete(CHUNKF)
        FileAppend(chunking ? "1" : "0", CHUNKF)
    } catch {
    }
    HttpPost("/chunk", 5000, chunking ? '{"enabled":true}' : '{"enabled":false}')
    if (chunking) {
        A_TrayMenu.Check(T("menu.chunk"))
        TrayTip("OpenCode Voice", T("tip.chunk.on"), 1)
    } else {
        A_TrayMenu.Uncheck(T("menu.chunk"))
        TrayTip("OpenCode Voice", T("tip.chunk.off"), 1)
    }
}

ToggleListCont(*) {
    global listcont, STATE_DIR, LISTCF
    listcont := !listcont
    try {
        if (!DirExist(STATE_DIR))
            DirCreate(STATE_DIR)
        try FileDelete(LISTCF)
        FileAppend(listcont ? "1" : "0", LISTCF)
    } catch {
    }
    HttpPost("/listcont", 5000, listcont ? '{"enabled":true}' : '{"enabled":false}')
    if (listcont) {
        A_TrayMenu.Check(T("menu.listcont"))
        TrayTip("OpenCode Voice", T("tip.list.on"), 1)
    } else {
        A_TrayMenu.Uncheck(T("menu.listcont"))
        TrayTip("OpenCode Voice", T("tip.list.off"), 1)
    }
}

; ---- Help ---------------------------------------------------------------
; Small window (not MsgBox) so the GitHub URL is a real clickable link.
; Private -> public keeps the same URL as long as owner/name don't change.
global HelpGui := ""
ShowHelp(*) {
    global HelpGui
    try HelpGui.Destroy()
    catch {
    }
    HelpGui := Gui("+AlwaysOnTop +ToolWindow", T("help.title"))
    HelpGui.SetFont("s9", "Segoe UI")
    HelpGui.Add("Text", "w420", T("help.body"))
    HelpGui.Add("Link", "w420", '<a href="https://github.com/gabriel-macherini/SOBER-STT-8GB">GitHub: gabriel-macherini/SOBER-STT-8GB</a>')
    HelpGui.Add("Button", "Default w80", "OK").OnEvent("Click", (*) => HelpGui.Destroy())
    HelpGui.Show()
}

; ---- Model switching (Trocar modelo) --------------------------------------
; Lists the model files dropped in models/ per slot; the runner validates
; (extension, GGUF magic) and persists the choice per machine. "Padrão do
; instalador" clears the override back to config.json.
MODELS_DIR := A_ScriptDir "\models"
global ModelsMenu := Menu()
global SubParakeet := Menu(), SubS1 := Menu(), SubQwen := Menu()
global ActiveModels := Map("parakeet", "", "s1", "", "qwen", "")

RefreshModelsMenu() {
    global SubParakeet, SubS1, SubQwen, ActiveModels, MODELS_DIR
    try {
        h := HttpGet("/health")
        if (RegExMatch(h, '"parakeet"\s*:\s*"([^"]*)"', &m))
            ActiveModels["parakeet"] := m[1]
        if (RegExMatch(h, '"s1"\s*:\s*"([^"]*)"', &m))
            ActiveModels["s1"] := m[1]
        if (RegExMatch(h, '"qwen"\s*:\s*"([^"]*)"', &m))
            ActiveModels["qwen"] := m[1]
    } catch {
    }
    for sub in [SubParakeet, SubS1, SubQwen] {
        try sub.Delete()
    }
    AddModelItems(SubParakeet, "parakeet", MODELS_DIR "\*.bin")
    AddModelItems(SubS1, "s1", MODELS_DIR "\*.gguf")
    AddModelItems(SubQwen, "qwen", MODELS_DIR "\*.gguf")
}

AddModelItems(sub, slot, pattern) {
    global ActiveModels
    active := ActiveModels[slot]
    sub.Add(T("menu.def"), SwitchModel.Bind(slot, ""))
    if (active = "")
        sub.Check(T("menu.def"))
    sub.Add()
    Loop Files pattern {
        name := A_LoopFileName
        sub.Add(name, SwitchModel.Bind(slot, name))
        if (name = active)
            sub.Check(name)
    }
}

SwitchModel(slot, file, *) {
    r := HttpPost("/models", 8000, '{"slot":"' . slot . '","file":"' . file . '"}')
    if (InStr(r, '"ok":true')) {
        RefreshModelsMenu()
        TrayTip("OpenCode Voice", file = "" ? T("tip.model.def") : T("tip.model.on") . file, 1)
    } else if (InStr(r, "too-big-confirm")) {
        if (MsgBox(T("msg.bigmodel"), "SOBER-STT", "YesNo Icon!") = "Yes") {
            r2 := HttpPost("/models", 8000, '{"slot":"' . slot . '","file":"' . file . '","confirmed":true}')
            if (InStr(r2, '"ok":true')) {
                RefreshModelsMenu()
                TrayTip("OpenCode Voice", T("tip.model.on") . file, 1)
            } else {
                TrayTip("OpenCode Voice", T("tip.model.no"), 2)
            }
        }
    } else {
        TrayTip("OpenCode Voice", T("tip.model.no"), 2)
    }
}

; ---- Tray menu -------------------------------------------------------------
; Rebuilt on boot and on every language switch, so all labels follow T().
; The warm/autostart checks are reapplied here too (persisted elsewhere).
global LangMenu := Menu()

BuildTrayMenu() {
    global ModelsMenu, SubParakeet, SubS1, SubQwen, LangMenu, MODELS_DIR
    global ActiveLang, warm
    A_TrayMenu.Delete()
    A_TrayMenu.Add(T("menu.warm"), ToggleWarm)
    A_TrayMenu.Add(T("menu.autostart"), ToggleAutostart)
    A_TrayMenu.Add(T("menu.chunk"), ToggleChunk)
    A_TrayMenu.Add(T("menu.listcont"), ToggleListCont)
    ModelsMenu.Delete()
    ModelsMenu.Add(T("slot.stt"), SubParakeet)
    ModelsMenu.Add(T("slot.s1"), SubS1)
    ModelsMenu.Add(T("slot.qwen"), SubQwen)
    ModelsMenu.Add()
    ModelsMenu.Add(T("menu.modelsdir"), (*) => Run(MODELS_DIR))
    A_TrayMenu.Add(T("menu.models"), ModelsMenu)
    LangMenu.Delete()
    for code in ["en", "pt", "fr", "es"] {
        LangMenu.Add(LANG[code]["lang.name"], SetLanguage.Bind(code))
        if (code = ActiveLang)
            LangMenu.Check(LANG[code]["lang.name"])
    }
    A_TrayMenu.Add(T("menu.lang"), LangMenu)
    A_TrayMenu.Add()
    A_TrayMenu.Add(T("menu.folder"), (*) => Run(A_ScriptDir))
    A_TrayMenu.Add(T("menu.help"), ShowHelp)
    A_TrayMenu.Add(T("menu.exit"), ExitVoice)
    if (warm)
        A_TrayMenu.Check(T("menu.warm"))
    if (IsAutostart())
        A_TrayMenu.Check(T("menu.autostart"))
    if (chunking)
        A_TrayMenu.Check(T("menu.chunk"))
    if (listcont)
        A_TrayMenu.Check(T("menu.listcont"))
}

; ---- Gesture: double-tap and hold CapsLock ---------------------------------
; "~" lets CapsLock pass through natively; we only observe down/up.
~CapsLock:: {
    global lastTapUp, armed, downTime, keyDown
    if (keyDown)                          ; CapsLock auto-repeat: ignore
        return
    keyDown := true
    downTime := A_TickCount
    Dbg("down armed=" . armed . " gap=" . (lastTapUp ? (downTime - lastTapUp) : -1))
    if (lastTapUp && (downTime - lastTapUp) <= GAP) {
        armed := true
        lastTapUp := 0
        SetTimer(DoStart, -10)            ; start recording on press
    }
}

~CapsLock Up:: {
    global lastTapUp, armed, downTime, keyDown
    keyDown := false
    held := A_TickCount - downTime
    Dbg("up held=" . held . " armed=" . armed)
    if (armed) {
        armed := false
        if (held >= HOLD_MIN) {
            SetState("proc")
            SetTimer(DoPipeline, -10)     ; process + paste
        } else {
            SetTimer(DoCancel, -10)       ; plain double-tap: cancel
        }
    } else {
        lastTapUp := (held <= TAP_MAX) ? A_TickCount : 0
    }
}

; ---- Boot ------------------------------------------------------------------
OnExit((*) => (StopRunner(), 0))
try FileDelete(LOGF)
Dbg("boot")
StartRunner()
; Restore persisted choices: warm toggle, UI language, autostart check.
; (Autostart itself lives in HKCU\...\Run; here we only re-check the menu.)
; Migrates the pre-installer warm.state that lived next to the script.
try {
    if (!FileExist(WARMF) && FileExist(A_ScriptDir "\warm.state")) {
        if (!DirExist(STATE_DIR))
            DirCreate(STATE_DIR)
        FileMove(A_ScriptDir "\warm.state", WARMF)
    }
} catch {
}
try {
    if (FileExist(LOCALEF) && Trim(FileRead(LOCALEF)) != "") {
        code := Trim(FileRead(LOCALEF))
        if (code = "en" || code = "pt" || code = "fr" || code = "es")
            ActiveLang := code
    }
} catch {
}
BuildTrayMenu()
try {
    if (FileExist(WARMF) && Trim(FileRead(WARMF)) = "1") {
        warm := true
        HttpPost("/warm", 5000, '{"enabled":true}')
        A_TrayMenu.Check(T("menu.warm"))
    }
} catch {
}
; Chunks default on (no file = on); list continuation defaults off.
try {
    if (FileExist(CHUNKF) && Trim(FileRead(CHUNKF)) = "0") {
        chunking := false
        HttpPost("/chunk", 5000, '{"enabled":false}')
        A_TrayMenu.Uncheck(T("menu.chunk"))
    }
} catch {
}
try {
    if (FileExist(LISTCF) && Trim(FileRead(LISTCF)) = "1") {
        listcont := true
        HttpPost("/listcont", 5000, '{"enabled":true}')
        A_TrayMenu.Check(T("menu.listcont"))
    }
} catch {
}
RefreshModelsMenu()
SetState("idle")
TrayTip("OpenCode Voice", T("tip.boot"), 1)
