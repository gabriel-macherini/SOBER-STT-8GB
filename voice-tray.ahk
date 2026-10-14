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

global runnerPID := 0
global warm := false
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
            A_IconTip := "OpenCode Voice - gravando (solte para processar)"
            ShowOverlay()
        case "proc":
            TraySetIcon(ICON_PROC)
            A_IconTip := "OpenCode Voice - processando..."
            ShowOverlay()
        default:
            TraySetIcon(ICON_IDLE)
            A_IconTip := "OpenCode Voice - pronto (duplo-toque e segure o CapsLock)"
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

    col := COL_REC, label := "Gravando"
    if (phase = "transcribing") {
        col := COL_TRA, label := "Transcrevendo..."
    } else if (phase = "normalizing") {
        col := COL_NOR, label := "Normalizando..."
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
        TrayTip("OpenCode Voice", "Runner nao respondeu.", 2)
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
        msg := InStr(resp, "no-speech") ? "Nenhuma fala detectada." : "Falha: " . resp
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
            msg := InStr(r, "no-speech") ? "Nenhuma fala detectada." : "Falha no processamento."
            TrayTip("OpenCode Voice", msg, 2)
        }
        return
    }
    if (POLL_N > 1200) {
        SetTimer(PollResult, 0)
        SetState("idle")
        TrayTip("OpenCode Voice", "Tempo esgotado no processamento.", 2)
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
    TrayTip("OpenCode Voice", "Runner nao subiu. Veja se o Node esta no PATH.", 3)
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
        A_TrayMenu.Check("Manter modelos carregados")
        TrayTip("OpenCode Voice", "Modelos mantidos carregados.", 1)
    } else {
        A_TrayMenu.Uncheck("Manter modelos carregados")
        TrayTip("OpenCode Voice", "Idle kill em 1 min reativado.", 1)
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
        A_TrayMenu.Check("Iniciar com o Windows")
        TrayTip("OpenCode Voice", "Vai iniciar junto com o Windows.", 1)
    } else {
        A_TrayMenu.Uncheck("Iniciar com o Windows")
        TrayTip("OpenCode Voice", "Nao vai mais iniciar com o Windows.", 1)
    }
}

; ---- Tray menu -------------------------------------------------------------
A_TrayMenu.Delete()
A_TrayMenu.Add("Manter modelos carregados", ToggleWarm)
A_TrayMenu.Add("Iniciar com o Windows", ToggleAutostart)
A_TrayMenu.Add()
A_TrayMenu.Add("Abrir pasta", (*) => Run(A_ScriptDir))
A_TrayMenu.Add("Sair", ExitVoice)

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
; Restore the persisted toggle: whatever was checked on exit is back on launch.
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
    if (FileExist(WARMF) && Trim(FileRead(WARMF)) = "1") {
        warm := true
        HttpPost("/warm", 5000, '{"enabled":true}')
        A_TrayMenu.Check("Manter modelos carregados")
    }
} catch {
}
if (IsAutostart())
    A_TrayMenu.Check("Iniciar com o Windows")
SetState("idle")
TrayTip("OpenCode Voice", "Ativo. Duplo-toque e segure o CapsLock para falar.", 1)
