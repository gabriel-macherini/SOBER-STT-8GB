#Requires AutoHotkey v2.0
#SingleInstance Force
Persistent

APPVER := "1.0.4"

; ============================================================================
; SOBER-STT - tray app
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
; config.local.json (dev override, gitignored) wins when present.
GetCfgVal(text, key) {
    if (RegExMatch(text, '"' . key . '"\s*:\s*(-?\d+)', &m))
        return Integer(m[1])
    if (RegExMatch(text, '"' . key . '"\s*:\s*"([^"]*)"', &m))
        return m[1]
    return ""
}
try {
    cfgText := FileRead(A_ScriptDir "\config.json")
    v := GetCfgVal(cfgText, "runnerPort")
    if (v != "")
        PORT := v
} catch {
}
try {
    localText := FileRead(A_ScriptDir "\config.local.json")
    v := GetCfgVal(localText, "runnerPort")
    if (v != "")
        PORT := v
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

LOGF := A_Temp "\sober-tray.log"
; P2: level/phase live where the runner writes them (tmpDir, %TEMP% by
; default). Refreshed from /health at boot; A_Temp is only the fallback.
LEVELF := A_Temp "\sober-stt.level"
PHASEF := A_Temp "\sober-stt.phase"
RefreshTmpPaths() {
    global LEVELF, PHASEF
    try {
        h := HttpGet("/health")
        if (RegExMatch(h, '"tmpDir"\s*:\s*"((?:[^"\\]|\\.)*)"', &m)) {
            dir := StrReplace(m[1], "\\", "\")
            if (dir != "") {
                LEVELF := dir "\sober-stt.level"
                PHASEF := dir "\sober-stt.phase"
            }
        }
    } catch {
    }
}
; Persisted toggles live outside the install folder (which may be read-only).
STATE_DIR := EnvGet("APPDATA") . "\SOBER-STT-8GB"
WARMF := STATE_DIR "\warm.state"   ; "1" = keep models loaded
REG_RUN := "HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Run"
REG_NAME := "SOBER-STT"

#Include locale.ahk
LOCALEF := STATE_DIR "\locale"
CHUNKF := STATE_DIR "\chunk.state"   ; "0" = single-call mode (default: chunks on)
global SOBER_TOKEN := ""
TOKENF := STATE_DIR "\sober-stt.token" ; per-boot API token written by runner.mjs
; The runner writes the per-boot token to the state dir AND tmpDir, and deletes
; both on shutdown, so a missing, stale or wrong file is normal (a runner that
; lost the bind race used to leave its own token behind). Both paths are
; candidates; keep the first one the API actually accepts. Probes with TryHttp
; on purpose: HttpSend would call back into LoadToken on 403.
LoadToken() {
    global SOBER_TOKEN, TOKENF
    for f in [TOKENF, A_Temp "\sober-stt.token"] {
        try {
            t := Trim(FileRead(f))
            if (t = "")
                continue
            SOBER_TOKEN := t
            if (InStr(TryHttp("GET", "/health", 1500, ""), '"ok":true')) {
                ; Candidate from tmpDir: repair the state-dir copy, which is
                ; where the next boot reads it from. A stale file there used to
                ; lock the tray out of a live runner for good.
                if (f != TOKENF) {
                    try FileDelete(TOKENF)
                    try FileAppend(t, TOKENF, "UTF-8")
                }
                return
            }
        } catch {
        }
    }
}
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
; Gesture debug log in %TEMP%\sober-tray.log. Off by default.
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
            A_IconTip := T("tip.ready") . " v" . APPVER
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
    ; U1: center on the monitor with the mouse, not the primary one.
    CoordMode "Mouse", "Screen"
    MouseGetPos &mx, &my
    mon := 1
    Loop MonitorGetCount() {
        MonitorGet(A_Index, &ml, &mt, &mr, &mb)
        if (mx >= ml && mx < mr && my >= mt && my < mb) {
            mon := A_Index
            break
        }
    }
    MonitorGet(mon, &ml, &mt, &mr, &mb)
    x := ml + ((mr - ml) - 172) // 2
    y := mb - 150
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
; Every call carries the per-boot token. A 403 means "wrong token", never
; success: the runner deletes the token file on shutdown and writes a new one on
; start, so a stale or missing file is normal and must not be read as "the
; runner is up". On 403 we reload the token and retry once; if the API still
; refuses we return "" so callers can react instead of painting an overlay for a
; recording that never started.
HttpPost(path, timeoutMs := 5000, body := "") {
    return HttpSend("POST", path, timeoutMs, body)
}
HttpGet(path, timeoutMs := 1500) {
    return HttpSend("GET", path, timeoutMs, "")
}
HttpSend(method, path, timeoutMs, body) {
    global LastHttpStatus
    r := TryHttp(method, path, timeoutMs, body)
    if (r = "" && LastHttpStatus = 403) {
        LoadToken()
        r := TryHttp(method, path, timeoutMs, body)
        if (r = "" && LastHttpStatus = 403)
            try TrayTip(T("msg.engine"), "SOBER-STT", "Icon!")
    }
    return r
}
TryHttp(method, path, timeoutMs, body) {
    global SOBER_TOKEN, LastHttpStatus
    LastHttpStatus := 0
    try {
        req := ComObject("WinHttp.WinHttpRequest.5.1")
        req.SetTimeouts(2000, 2000, 60000, timeoutMs)
        req.Open(method, "http://127.0.0.1:" . PORT . path, false)
        if (SOBER_TOKEN != "")
            req.SetRequestHeader("X-SOBER-Token", SOBER_TOKEN)
        if (body != "")
            req.SetRequestHeader("Content-Type", "application/json")
        if (body = "")
            req.Send()
        else
            req.Send(body)
        LastHttpStatus := req.Status
        if (req.Status != 200)
            return ""
        return req.ResponseText
    } catch {
        return ""
    }
}

DoStart() {
    Dbg("DoStart")
    r := HttpPost("/start")
    if (!InStr(r, '"ok":true')) {
        if (r = "") {
            ; No answer at all: the API is down or our token is stale (the token
            ; rotates every boot). Relink once and retry.
            EnsureRunner()
            r := HttpPost("/start")
        }
        if (!InStr(r, '"ok":true')) {
            ; The runner answered with a reason (no microphone, bad token, busy).
            ; Say it instead of flashing an overlay for a start that never was.
            SetState("idle")
            try TrayTip(InStr(r, "no-mic") ? T("msg.nomic") : T("msg.fail"), "SOBER-STT", "Icon!")
            return
        }
    }
    SetState("rec")
}
DoCancel() {
    Dbg("DoCancel")
    HttpPost("/cancel")
    SetState("idle")
}
DoPipeline() {
    ; /stop returns at once ({started, seq}); the overlay keeps
    ; repainting while phases change, and PollResult closes at the end.
    ; The focused window's PID goes along so the runner can put it back
    ; on top before pasting (U2).
    global POLL_SEQ, POLL_N, POLL_PID, POLL_EMPTY
    Dbg("DoPipeline")
    try {
        POLL_PID := WinGetPID("A")
    } catch {
        POLL_PID := 0
    }
    resp := HttpPost("/stop", 10000, '{"pid":' . POLL_PID . '}')
    m := ""
    if (RegExMatch(resp, '"seq"\s*:\s*(\d+)', &m)) {
        POLL_SEQ := Integer(m[1])
        POLL_N := 0
        POLL_EMPTY := 0
        SetTimer(PollResult, 150)
    } else {
        ; No seq: the runner never got the clip (token refused / not listening).
        SetState("idle")
    }
}

PollResult(*) {
    global POLL_SEQ, POLL_N, POLL_EMPTY
    POLL_N += 1
    r := HttpGet("/result?seq=" . POLL_SEQ, 3000)
    if (r = "") {
        ; No answer at all (runner died mid-pipeline): don't poll for 3 min.
        POLL_EMPTY += 1
        if (POLL_EMPTY >= 8) {
            SetTimer(PollResult, 0)
            SetState("idle")
            try TrayTip(T("msg.fail"), "SOBER-STT", "Icon!")
            return
        }
    } else {
        POLL_EMPTY := 0
    }
    if (InStr(r, '"done":true')) {
        SetTimer(PollResult, 0)
        SetState("idle")
        if (InStr(r, '"ok":false')) {
            ; U4: failures were silent since toasts were removed. One
            ; balloon on error only; success stays quiet.
            try TrayTip(T("msg.fail"), "SOBER-STT", "Icon!")
        }
        return
    }
    if (POLL_N > 1200) {
        ; B10: a long chunked dictation can outlast 3 min of polling. Don't
        ; go idle while the runner is still processing; extend the wait.
        h := HttpGet("/health", 3000)
        if (InStr(h, '"processing":true')) {
            POLL_N := 1000
            return
        }
        SetTimer(PollResult, 0)
        SetState("idle")
    }
}

; ---- Lifecycle -------------------------------------------------------------
StartRunner() {
    global runnerPID
    LoadToken()
    if (InStr(HttpGet("/health"), '"ok":true')) {
        runnerPID := 0
        return
    }
    Run('"' . NODE . '" "' . RUNNER . '"', A_ScriptDir, "Hide", &runnerPID)
    Loop 40 {
        Sleep 200
        LoadToken()
        if (InStr(HttpGet("/health"), '"ok":true'))
            return
    }
}

; Guarantees a runner we can authenticate against. The token rotates every boot
; and is deleted on shutdown, so when the tray starts with a missing or stale
; file it must not adopt a runner it cannot talk to: re-read the token, and if
; that still fails, drop whatever holds the port and start a runner we own.
EnsureRunner() {
    if (InStr(HttpGet("/health"), '"ok":true'))
        return true
    LoadToken()
    if (InStr(HttpGet("/health"), '"ok":true'))
        return true
    KillRunnerOnPort()
    StartRunner()
    return InStr(HttpGet("/health"), '"ok":true') != ""
}

; Last resort: close the process listening on the API port (an orphan runner
; whose token we cannot read), so a fresh one binds with a token we know.
; netstat goes through a temp file: RunWait's captured output is unreliable here.
KillRunnerOnPort() {
    tmp := A_Temp . "\sober-stt.netstat"
    try {
        FileDelete(tmp)
        RunWait(A_ComSpec . ' /c netstat -ano | findstr LISTENING > "' . tmp . '"', , "Hide")
        for line in StrSplit(FileRead(tmp, "UTF-8"), "`n", "`r") {
            ; <proto> <local:port> <foreign> <state> <pid>, space padded
            if (RegExMatch(line, "^\s*TCP\s+\S*:" . PORT . "\s+\S+\s+LISTENING\s+(\d+)\s*$", &m))
                try ProcessClose(Integer(m[1]))
        }
    } catch {
    }
    try FileDelete(tmp)
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
    } else {
        A_TrayMenu.Uncheck(T("menu.warm"))
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
    } else {
        A_TrayMenu.Uncheck(T("menu.autostart"))
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
    } else {
        A_TrayMenu.Uncheck(T("menu.chunk"))
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
    HelpGui := Gui("+AlwaysOnTop +ToolWindow", T("help.title") . " v" . APPVER)
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
        if (RegExMatch(h, '"modelsDir"\s*:\s*"((?:[^"\\]|\\.)*)"', &md))
            MODELS_DIR := StrReplace(md[1], "\\", "\")
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
    } else if (InStr(r, "too-big-confirm")) {
        if (MsgBox(T("msg.bigmodel"), "SOBER-STT", "YesNo Icon!") = "Yes") {
            r2 := HttpPost("/models", 8000, '{"slot":"' . slot . '","file":"' . file . '","confirmed":true}')
            if (InStr(r2, '"ok":true')) {
                RefreshModelsMenu()
            }
        }
    }
}

; ---- Support -------------------------------------------------------------
; U5: no more treasure hunt in %TEMP%. Temp folder + last transcript live
; in the tray menu; the runner log goes to <tmpDir>\sober-stt.log.
OpenTempDir(*) {
    dir := ""
    try {
        h := HttpGet("/health")
        if (RegExMatch(h, '"tmpDir"\s*:\s*"((?:[^"\\]|\\.)*)"', &m))
            dir := StrReplace(m[1], "\\", "\")
    } catch {
    }
    if (dir = "")
        dir := A_Temp
    try Run(dir)
}

CopyLastTranscript(*) {
    r := HttpGet("/last")
    if (r = "" || InStr(r, '"ok":false')) {
        try TrayTip(T("msg.nolast"), "SOBER-STT", "Icon!")
        return
    }
    if (RegExMatch(r, '"text"\s*:\s*"((?:[^"\\]|\\.)*)"', &m)) {
        t := m[1]
        t := StrReplace(t, "\\", "\x00")
        t := StrReplace(t, '\"', '"')
        t := StrReplace(t, "\n", "`n")
        t := StrReplace(t, "\r", "`r")
        t := StrReplace(t, "\t", "`t")
        t := StrReplace(t, "\x00", "\")
        try {
            A_Clipboard := t
            TrayTip(T("msg.copied"), "SOBER-STT")
        }
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
    A_TrayMenu.Add(T("menu.temp"), OpenTempDir)
    A_TrayMenu.Add(T("menu.copylast"), CopyLastTranscript)
    A_TrayMenu.Add(T("menu.help"), ShowHelp)
    A_TrayMenu.Add(T("menu.exit"), ExitVoice)
    if (warm)
        A_TrayMenu.Check(T("menu.warm"))
    if (IsAutostart())
        A_TrayMenu.Check(T("menu.autostart"))
    if (chunking)
        A_TrayMenu.Check(T("menu.chunk"))
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

; ---- Emergency cancel ------------------------------------------------------
; U6: Esc aborts a recording while the overlay shows it (same as a short
; double-tap). Guarded to the recording phase so Esc keeps working in the
; focused app at any other time.
EscCancels() {
    global OVL, PHASEF
    try {
        if (!IsObject(OVL) || !OVL.Visible)
            return false
        if (!FileExist(PHASEF))
            return false
        return Trim(FileRead(PHASEF)) = "recording"
    } catch {
        return false
    }
}
#HotIf EscCancels()
Esc:: {
    Dbg("esc-cancel")
    SetTimer(DoCancel, -10)
    SetState("idle")
}
#HotIf

; ---- Boot ------------------------------------------------------------------
OnExit((*) => (StopRunner(), 0))
try FileDelete(LOGF)
Dbg("boot")
EnsureRunner()
RefreshTmpPaths()
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
; Chunks default on (no file = on).
try {
    if (FileExist(CHUNKF) && Trim(FileRead(CHUNKF)) = "0") {
        chunking := false
        HttpPost("/chunk", 5000, '{"enabled":false}')
        A_TrayMenu.Uncheck(T("menu.chunk"))
    }
} catch {
}
RefreshModelsMenu()
SetState("idle")
