; SOBER-STT-8GB installer (Inno Setup 6).
;
; One click: picks a folder, asks about Desktop/Start icons + Windows
; autostart, downloads the models and GPU binaries listed in
; downloads.json (shown on the Ready page with name + version + size),
; extracts them into place, and leaves the app ready to dictate.
;
; Build with:  pwsh tools/build-installer.ps1
; (regenerates generated-downloads.iss, then runs ISCC on this file)

#define AppVersion "1.0.2"
#define DistDir "..\dist\SOBER-STT"

#include "generated-downloads-defs.iss"

[Setup]
AppId={{3B075193-1973-403F-AEE4-5DF4B41E28C7}
AppName=SOBER-STT
AppVersion={#AppVersion}
AppPublisher=Sober
DefaultDirName={localappdata}\SOBER-STT-8GB
DefaultGroupName=SOBER-STT
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
OutputDir=..\dist
OutputBaseFilename=SOBER-STT-Setup-{#AppVersion}
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
SetupIconFile=..\voice-idle.ico
UninstallDisplayIcon={app}\SOBER-STT.exe
; Real disk need: staged app + everything in downloads.json (installed size)
ExtraDiskSpaceRequired={#DownloadTotalBytes}
; ~5 GB to download, ~6 GB on disk; allow resuming a slow first install
AllowCancelDuringInstall=yes

[Languages]
Name: "en"; MessagesFile: "compiler:Default.isl"
; pt-BR vendored (official Inno pt is pt-PT): upstream at
; https://github.com/jrsoftware/issrc/blob/main/Files/Languages/BrazilianPortuguese.isl
Name: "pt"; MessagesFile: "Languages\BrazilianPortuguese.isl"
Name: "fr"; MessagesFile: "compiler:Languages\French.isl"
Name: "es"; MessagesFile: "compiler:Languages\Spanish.isl"

[CustomMessages]
en.TDesktop=Create a Desktop icon
pt.TDesktop=Criar ícone na Área de Trabalho
fr.TDesktop=Créer une icône sur le Bureau
es.TDesktop=Crear un icono en el Escritorio
en.TStartMenu=Create a Start Menu entry
pt.TStartMenu=Criar entrada no Menu Iniciar
fr.TStartMenu=Créer une entrée dans le menu Démarrer
es.TStartMenu=Crear una entrada en el menú Inicio
en.TAutostart=Start with Windows
pt.TAutostart=Iniciar com o Windows
fr.TAutostart=Démarrer avec Windows
es.TAutostart=Iniciar con Windows
en.GroupIcons=Icons:
pt.GroupIcons=Ícones:
fr.GroupIcons=Icônes :
es.GroupIcons=Iconos:
en.GroupStartup=Startup:
pt.GroupStartup=Inicialização:
fr.GroupStartup=Démarrage :
es.GroupStartup=Inicio:
en.RunNow=Launch SOBER-STT now
pt.RunNow=Iniciar o SOBER-STT agora
fr.RunNow=Lancer SOBER-STT maintenant
es.RunNow=Iniciar SOBER-STT ahora
en.MemoDownloads=What will be downloaded (items already in the folder are skipped):
pt.MemoDownloads=O que será baixado (pulando o que já existe na pasta):
fr.MemoDownloads=Ce qui sera téléchargé (l'existant est ignoré) :
es.MemoDownloads=Lo que se descargará (se omite lo existente):
en.GpuNone=No NVIDIA GPU was detected. SOBER-STT works best with CUDA; without it, transcription falls back to CPU (much slower). Continue anyway?
pt.GpuNone=Nenhuma GPU NVIDIA foi detectada. O SOBER-STT funciona melhor com CUDA; sem ela a transcrição cai para CPU (bem mais lenta). Continuar mesmo assim?
fr.GpuNone=Aucun GPU NVIDIA détecté. SOBER-STT fonctionne mieux avec CUDA ; sans lui, la transcription passe en CPU (bien plus lent). Continuer quand même ?
es.GpuNone=No se detectó GPU NVIDIA. SOBER-STT funciona mejor con CUDA; sin ella, la transcripción usa CPU (mucho más lento). ¿Continuar igualmente?
en.GpuOld=%s looks too old for the bundled CUDA 12 builds (GTX 10xx / Quadro P-series or newer required). It will likely fall back to CPU. Continue anyway?
pt.GpuOld=%s parece antiga demais para os builds CUDA 12 incluídos (GTX 10xx / Quadro série P ou mais nova). Deve cair para CPU. Continuar mesmo assim?
fr.GpuOld=%s semble trop ancien pour les builds CUDA 12 inclus (GTX 10xx / Quadro série P ou plus récent requis). Probable repli en CPU. Continuer quand même ?
es.GpuOld=%s parece demasiado antigua para los builds CUDA 12 incluidos (se requiere GTX 10xx / Quadro serie P o posterior). Probablemente usará CPU. ¿Continuar igualmente?
en.GpuSmall=%s reports only %d MB VRAM (6+ GB recommended for the bundled models). Large models may spill to RAM or fail to load. Continue anyway?
pt.GpuSmall=%s tem apenas %d MB de VRAM (recomendado 6+ GB para os modelos incluídos). Modelos grandes podem estourar para RAM ou falhar. Continuar mesmo assim?
fr.GpuSmall=%s ne rapporte que %d Mo de VRAM (6+ Go recommandés). Les gros modèles risquent de déborder en RAM ou d'échouer. Continuer quand même ?
es.GpuSmall=%s solo reporta %d MB de VRAM (recomendados 6+ GB). Los modelos grandes pueden desbordar a RAM o fallar. ¿Continuar igualmente?
en.DlAborted=Download interrupted. Run the installer again: finished items are kept.
pt.DlAborted=Download interrompido. Rode o instalador de novo: o que já baixou é aproveitado.
fr.DlAborted=Téléchargement interrompu. Relancez l'installateur : les éléments terminés sont conservés.
es.DlAborted=Descarga interrumpida. Ejecute el instalador de nuevo: lo terminado se conserva.
en.DlFailed=Download of
pt.DlFailed=Falha no download de
fr.DlFailed=Échec du téléchargement de
es.DlFailed=Falló la descarga de
en.DlRetry=Run the installer again: finished items are kept.
pt.DlRetry=Rode o instalador de novo: o que já baixou é aproveitado.
fr.DlRetry=Relancez l'installateur : les éléments terminés sont conservés.
es.DlRetry=Ejecute el instalador de nuevo: lo terminado se conserva.
en.SaveFailed=Could not save
pt.SaveFailed=Não consegui salvar
fr.SaveFailed=Impossible d'enregistrer
es.SaveFailed=No se pudo guardar
en.Incomplete=Incomplete install, failed to verify:
pt.Incomplete=Instalação incompleta, faltou verificar:
fr.Incomplete=Installation incomplète, vérification échouée :
es.Incomplete=Instalación incompleta, no se pudo verificar:
en.UninstQ=Also delete the downloaded models (~3.6 GB)?
pt.UninstQ=Apagar também os modelos baixados (~3.6 GB)?
fr.UninstQ=Supprimer aussi les modèles téléchargés (~3,6 Go) ?
es.UninstQ=¿Eliminar también los modelos descargados (~3,6 GB)?
en.UninstQ2=Say No to keep them and speed up a future reinstall.
pt.UninstQ2=Diga Não para manter e acelerar uma futura reinstalação.
fr.UninstQ2=Répondez Non pour les garder et accélérer une réinstallation.
es.UninstQ2=Diga No para conservarlos y acelerar una reinstalación.
en.UninstState=Also remove settings (language, toggles, model choices)?
pt.UninstState=Remover também as preferências (idioma, toggles, modelos)?
fr.UninstState=Supprimer aussi les préférences (langue, options, modèles) ?
es.UninstState=¿Eliminar también las preferencias (idioma, opciones, modelos)?

[Tasks]
Name: "desktopicon"; Description: "{cm:TDesktop}"; GroupDescription: "{cm:GroupIcons}"; Flags: checkedonce
Name: "startmenu"; Description: "{cm:TStartMenu}"; GroupDescription: "{cm:GroupIcons}"; Flags: checkedonce
Name: "autostart"; Description: "{cm:TAutostart}"; GroupDescription: "{cm:GroupStartup}"; Flags: unchecked

[Dirs]
Name: "{app}\models"
Name: "{app}\bin\whisper"
Name: "{app}\bin\llama"

[Files]
Source: "{#DistDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autodesktop}\SOBER-STT"; Filename: "{app}\SOBER-STT.exe"; Tasks: desktopicon
Name: "{group}\SOBER-STT"; Filename: "{app}\SOBER-STT.exe"; Tasks: startmenu
Name: "{group}\Desinstalar SOBER-STT"; Filename: "{uninstallexe}"; Tasks: startmenu

[Registry]
Root: HKCU; Subkey: "SOFTWARE\Microsoft\Windows\CurrentVersion\Run"; ValueType: string; ValueName: "SOBER-STT"; ValueData: """{app}\SOBER-STT.exe"""; Flags: uninsdeletevalue; Tasks: autostart

[UninstallDelete]
; Binaries fetched at install time (not part of [Files])
Type: filesandordirs; Name: "{app}\bin"
Type: files; Name: "{app}\models\*.zip"

[Run]
Filename: "{app}\SOBER-STT.exe"; Description: "{cm:RunNow}"; Flags: postinstall nowait skipifsilent unchecked

[Code]
#include "generated-downloads.iss"

var
  DownloadPage: TDownloadWizardPage;

procedure InitializeWizard;
begin
  DownloadPage := CreateDownloadPage(SetupMessage(msgWizardPreparing), SetupMessage(msgPreparingDesc), nil);
end;

const
  MIN_VRAM_MB = 6144; { 6 GB: bundled Qwen + Parakeet peak need headroom on top }

{ Fills GpuName/VramMB (MiB, -1 when unknown). Prefers nvidia-smi (exact),
  falls back to WMI (name only; AdapterRAM caps at 4 GB there, so it is
  ignored for the size check). Returns True when an NVIDIA GPU exists. }
function GetNvidiaInfo(var GpuName: String; var VramMB: Integer): Boolean;
var
  WMI, Col, Item: Variant;
  I, Code: Integer;
  VcName, TmpFile, SmiOut: String;
  Lines: AnsiString;
begin
  Result := False;
  GpuName := '';
  VramMB := -1;
  TmpFile := ExpandConstant('{tmp}\sober-gpu.txt');
  if Exec('cmd.exe', '/c nvidia-smi --query-gpu=name,memory.total --format=csv,noheader,nounits > "' + TmpFile + '"',
      '', SW_HIDE, ewWaitUntilTerminated, Code) and (Code = 0)
     and LoadStringFromFile(TmpFile, Lines) then
  begin
    DeleteFile(TmpFile);
    SmiOut := Trim(String(Lines));
    if (SmiOut <> '') and (Pos('NVIDIA', Uppercase(SmiOut)) = 0) then
      SmiOut := 'NVIDIA ' + SmiOut;
    I := Pos(',', SmiOut);
    if I = 0 then
      I := Pos(';', SmiOut);
    if I > 0 then
    begin
      GpuName := Trim(Copy(SmiOut, 1, I - 1));
      VramMB := StrToIntDef(Trim(Copy(SmiOut, I + 1, Length(SmiOut))), -1);
      Result := GpuName <> '';
      Exit;
    end;
  end;
  try
    WMI := CreateOleObject('WbemScripting.SWbemLocator');
    Col := WMI.ConnectServer('.', 'root\CIMV2').ExecQuery('SELECT Name FROM Win32_VideoController');
    for I := 0 to Col.Count - 1 do
    begin
      Item := Col.ItemIndex(I);
      VcName := Item.Name;
      if Pos('NVIDIA', Uppercase(VcName)) > 0 then
      begin
        GpuName := VcName;
        Result := True;
        Break;
      end;
    end;
  except
  end;
end;

{ Pre-Pascal families: no CUDA 12 support in the bundled builds. Unknown
  future names default to compatible (no false alarm on new cards). }
function IsOldGpu(const GpuName: String): Boolean;
var
  U: String;
begin
  U := Uppercase(GpuName);
  Result :=
    (Pos('GTX 4', U) > 0) or (Pos('GTX 5', U) > 0) or
    (Pos('GTX 6', U) > 0) or (Pos('GTX 7', U) > 0) or
    (Pos('GTX 9', U) > 0) or (Pos('GT 4', U) > 0) or
    (Pos('GT 6', U) > 0) or (Pos('GT 7', U) > 0) or
    (Pos('GT 9', U) > 0) or (Pos('QUADRO K', U) > 0) or
    (Pos('QUADRO M', U) > 0) or (Pos('QUADRO FX', U) > 0) or
    (Pos('TESLA K', U) > 0) or (Pos('TESLA M', U) > 0) or
    (Pos('GRID K', U) > 0) or (Pos('FERMI', U) > 0) or
    (Pos('KEPLER', U) > 0) or (Pos('MAXWELL', U) > 0);
end;

function InitializeSetup(): Boolean;
var
  GpuName: String;
  VramMB: Integer;
begin
  Result := True;
  if not GetNvidiaInfo(GpuName, VramMB) then
  begin
    if MsgBox(CustomMessage('GpuNone'), mbConfirmation, MB_YESNO) = IDNO then
      Result := False;
  end
  else if IsOldGpu(GpuName) then
  begin
    if MsgBox(Format(CustomMessage('GpuOld'), [GpuName]), mbConfirmation, MB_YESNO) = IDNO then
      Result := False;
  end
  else if (VramMB >= 0) and (VramMB < MIN_VRAM_MB) then
  begin
    if MsgBox(Format(CustomMessage('GpuSmall'), [GpuName, VramMB]), mbConfirmation, MB_YESNO) = IDNO then
      Result := False;
  end;
end;

function UpdateReadyMemo(Space, NewLine, MemoUserInfoInfo, MemoDirInfo, MemoTypeInfo,
  MemoComponentsInfo, MemoGroupInfo, MemoTasksInfo: String): String;
begin
  Result := MemoDirInfo + NewLine + NewLine +
    CustomMessage('MemoDownloads') + NewLine +
    DownloadListText();
  if MemoTasksInfo <> '' then
    Result := Result + NewLine + NewLine + MemoTasksInfo;
end;

function MissingCount(): Integer;
var
  I: Integer;
begin
  Result := 0;
  for I := 0 to DownloadCount - 1 do
    if not FileExists(ExpandConstant('{app}\') + DownloadCheckFile(I)) then
      Result := Result + 1;
end;

function NextButtonClick(CurPageID: Integer): Boolean;
var
  I: Integer;
  TmpFile, DestDir, DestFile: String;
begin
  Result := True;
  if CurPageID = wpReady then
  begin
    if MissingCount() = 0 then
      Exit;
    { Downloads land directly in the target folder, item by item: }
    { interrupting and re-running resumes (finished items are skipped). }
    { An interrupted file itself restarts from zero (installer limitation). }
    ForceDirectories(ExpandConstant('{app}'));
    DownloadPage.Show;
    try
      for I := 0 to DownloadCount - 1 do
      begin
        if FileExists(ExpandConstant('{app}\') + DownloadCheckFile(I)) then
          Continue;
        DownloadPage.Clear;
        DownloadPage.Add(DownloadUrl(I), DownloadFile(I), DownloadSha256(I));
        try
          DownloadPage.Download;
        except
          if DownloadPage.AbortedByUser then
            MsgBox(CustomMessage('DlAborted'), mbInformation, MB_OK)
          else
            MsgBox(CustomMessage('DlFailed') + ' ' + DownloadLabel(I) + ': ' + GetExceptionMessage + #13#10 +
              CustomMessage('DlRetry'), mbError, MB_OK);
          Result := False;
          Exit;
        end;
        TmpFile := ExpandConstant('{tmp}\') + DownloadFile(I);
        DestDir := ExpandConstant('{app}\') + DownloadDestSub(I);
        ForceDirectories(DestDir);
        DestFile := DestDir + '\' + DownloadFile(I);
        if not CopyFile(TmpFile, DestFile, False) then
        begin
          MsgBox(CustomMessage('SaveFailed') + ' ' + DestFile + '. ' + CustomMessage('DlRetry'), mbError, MB_OK);
          Result := False;
          Exit;
        end;
        DeleteFile(TmpFile);
      end;
    finally
      DownloadPage.Hide;
    end;
  end;
end;

procedure CurStepChanged(CurStep: TSetupStep);
var
  I, Code: Integer;
  ZipFile, DestDir, Check, Failures: String;
begin
  if CurStep <> ssPostInstall then
    Exit;
  Failures := '';
  for I := 0 to DownloadCount - 1 do
  begin
    Check := ExpandConstant('{app}\') + DownloadCheckFile(I);
    if FileExists(Check) then
      Continue;
    DestDir := ExpandConstant('{app}\') + DownloadDestSub(I);
    ZipFile := DestDir + '\' + DownloadFile(I);
    if DownloadExtract(I) then
    begin
      { Some upstream zips nest files one level deep (whisper.cpp uses
        Release\); flatten so bins land directly in the dest folder. }
      if FileExists(ZipFile) then
      begin
        Exec('powershell.exe',
          '-NoProfile -NonInteractive -Command "Expand-Archive -LiteralPath ''' + ZipFile +
        ''' -DestinationPath ''' + DestDir + ''' -Force; ' +
        '$r=''' + DestDir + '\Release''; ' +
        'if (Test-Path $r) { Move-Item $r\* ''' + DestDir + ''' -Force; Remove-Item $r }"',
        '', SW_HIDE, ewWaitUntilTerminated, Code);
        DeleteFile(ZipFile);
      end;
    end;
    if not FileExists(Check) then
      Failures := Failures + '  - ' + DownloadLabel(I) + ' (' + DownloadVersion(I) + ')' + #13#10;
  end;
  { Seed the tray UI language from the wizard choice (in-app switching
    overwrites this file afterwards). }
  ForceDirectories(ExpandConstant('{userappdata}\SOBER-STT-8GB'));
  SaveStringToFile(ExpandConstant('{userappdata}\SOBER-STT-8GB\locale'), ActiveLanguage(), False);
  if Failures <> '' then
    RaiseException(CustomMessage('Incomplete') + #13#10 + Failures +
      CustomMessage('DlRetry'));
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  if CurUninstallStep = usUninstall then
  begin
    if MsgBox(CustomMessage('UninstQ') + #13#10 +
      CustomMessage('UninstQ2'),
      mbConfirmation, MB_YESNO) = IDYES then
      DelTree(ExpandConstant('{app}\models'), True, True, True);
    if MsgBox(CustomMessage('UninstState'), mbConfirmation, MB_YESNO) = IDYES then
    begin
      DelTree(ExpandConstant('{userappdata}\SOBER-STT-8GB'), True, True, True);
      { NOTE: Use GetEnv, not the tmp constant (that one is the setup temp dir). }
      DeleteFile(GetEnv('TEMP') + '\sober-stt.token');
      DeleteFile(GetEnv('TEMP') + '\sober-stt.last.json');
      DeleteFile(GetEnv('TEMP') + '\sober-stt.log');
      DeleteFile(GetEnv('TEMP') + '\sober-stt.wav');
      DeleteFile(GetEnv('TEMP') + '\sober-stt.level');
      DeleteFile(GetEnv('TEMP') + '\sober-stt.phase');
    end;
  end;
end;
