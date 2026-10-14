; SOBER-STT-8GB installer (Inno Setup 6).
;
; One click: picks a folder, asks about Desktop/Start icons + Windows
; autostart, downloads the models and GPU binaries listed in
; downloads.json (shown on the Ready page with name + version + size),
; extracts them into place, and leaves the app ready to dictate.
;
; Build with:  pwsh tools/build-installer.ps1
; (regenerates generated-downloads.iss, then runs ISCC on this file)

#define AppVersion "1.0.0"
#define DistDir "..\dist\SOBER-STT"

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
UninstallDisplayIcon={app}\SOBER-STT.exe
; ~4.5 GB of downloads; allow resuming a slow first install
AllowCancelDuringInstall=yes

[Languages]
Name: "portuguese"; MessagesFile: "compiler:Languages\Portuguese.isl"

[Tasks]
Name: "desktopicon"; Description: "Criar ícone na Área de Trabalho"; GroupDescription: "Ícones:"; Flags: checkedonce
Name: "startmenu"; Description: "Criar entrada no Menu Iniciar"; GroupDescription: "Ícones:"; Flags: checkedonce
Name: "autostart"; Description: "Iniciar com o Windows"; GroupDescription: "Inicialização:"; Flags: unchecked

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
Filename: "{app}\SOBER-STT.exe"; Description: "Iniciar o SOBER-STT agora"; Flags: postinstall nowait skipifsilent unchecked

[Code]
#include "generated-downloads.iss"

var
  DownloadPage: TDownloadWizardPage;

procedure InitializeWizard;
begin
  DownloadPage := CreateDownloadPage(SetupMessage(msgWizardPreparing), SetupMessage(msgPreparingDesc), nil);
end;

function IsNvidiaPresent(): Boolean;
var
  WMI, Col, Item: Variant;
  I: Integer;
  VcName: String;
begin
  Result := False;
  try
    WMI := CreateOleObject('WbemScripting.SWbemLocator');
    Col := WMI.ConnectServer('.', 'root\CIMV2').ExecQuery('SELECT Name FROM Win32_VideoController');
    for I := 0 to Col.Count - 1 do
    begin
      Item := Col.ItemIndex(I);
      VcName := Item.Name;
      if Pos('NVIDIA', Uppercase(VcName)) > 0 then
      begin
        Result := True;
        Break;
      end;
    end;
  except
  end;
end;

function InitializeSetup(): Boolean;
begin
  Result := True;
  if not IsNvidiaPresent() then
    if MsgBox('Nenhuma GPU NVIDIA foi detectada.' + #13#10 +
      'O SOBER-STT funciona melhor com CUDA; sem ela a transcrição cai para CPU (bem mais lenta).' + #13#10#13#10 +
      'Continuar mesmo assim?', mbConfirmation, MB_YESNO) = IDNO then
      Result := False;
end;

function UpdateReadyMemo(Space, NewLine, MemoUserInfoInfo, MemoDirInfo, MemoTypeInfo,
  MemoComponentsInfo, MemoGroupInfo, MemoTasksInfo: String): String;
begin
  Result := MemoDirInfo + NewLine + NewLine +
    'O que será baixado (pulando o que já existe na pasta):' + NewLine +
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
  Target: String;
begin
  Result := True;
  if CurPageID = wpReady then
  begin
    if MissingCount() = 0 then
      Exit;
    DownloadPage.Clear;
    for I := 0 to DownloadCount - 1 do
    begin
      Target := ExpandConstant('{app}\') + DownloadCheckFile(I);
      if not FileExists(Target) then
        DownloadPage.Add(DownloadUrl(I), DownloadFile(I), '');
    end;
    DownloadPage.Show;
    try
      try
        DownloadPage.Download;
      except
        if DownloadPage.AbortedByUser then
          MsgBox('Download cancelado. A instalação não pode continuar sem os modelos.', mbError, MB_OK)
        else
          MsgBox('Falha no download: ' + GetExceptionMessage + #13#10 +
            'Verifique a conexão e rode o instalador de novo (itens prontos são pulados).', mbError, MB_OK);
        Result := False;
      end;
    finally
      DownloadPage.Hide;
    end;
  end;
end;

procedure CurStepChanged(CurStep: TSetupStep);
var
  I, Code: Integer;
  TmpFile, DestDir, DestFile, Check: String;
  Failures: String;
begin
  if CurStep <> ssPostInstall then
    Exit;
  Failures := '';
  for I := 0 to DownloadCount - 1 do
  begin
    Check := ExpandConstant('{app}\') + DownloadCheckFile(I);
    if FileExists(Check) then
      Continue;
    TmpFile := ExpandConstant('{tmp}\') + DownloadFile(I);
    DestDir := ExpandConstant('{app}\') + DownloadDestSub(I);
    ForceDirectories(DestDir);
    if DownloadExtract(I) then
    begin
      { Some upstream zips nest files one level deep (whisper.cpp uses
        Release\); flatten so bins land directly in the dest folder. }
      Exec('powershell.exe',
        '-NoProfile -NonInteractive -Command "Expand-Archive -LiteralPath ''' + TmpFile +
        ''' -DestinationPath ''' + DestDir + ''' -Force; ' +
        '$r=''' + DestDir + '\Release''; ' +
        'if (Test-Path $r) { Move-Item $r\* ''' + DestDir + ''' -Force; Remove-Item $r }"',
        '', SW_HIDE, ewWaitUntilTerminated, Code);
      DeleteFile(TmpFile);
    end
    else
    begin
      DestFile := DestDir + '\' + DownloadFile(I);
      if CopyFile(TmpFile, DestFile, False) then
        DeleteFile(TmpFile);
    end;
    if not FileExists(Check) then
      Failures := Failures + '  - ' + DownloadLabel(I) + ' (' + DownloadVersion(I) + ')' + #13#10;
  end;
  if Failures <> '' then
    RaiseException('Instalação incompleta, faltou verificar:' + #13#10 + Failures +
      'Rode o instalador de novo (itens prontos são pulados).');
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  if CurUninstallStep = usUninstall then
    if MsgBox('Apagar também os modelos baixados (~3.6 GB)?' + #13#10 +
      'Diga Não para manter e acelerar uma futura reinstalação.',
      mbConfirmation, MB_YESNO) = IDYES then
      DelTree(ExpandConstant('{app}\models'), True, True, True);
end;
