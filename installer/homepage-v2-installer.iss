; ============================================================================
;  homepage-v2-installer / Inno Setup script
;  ビルド: ISCC.exe homepage-v2-installer.iss
; ============================================================================

#define MyAppName       "homepage-v2-installer"
#define MyAppVersion    "1.0.0"
#define MyAppPublisher  "homepage-v2"
#define MyAppExeName    "HomepageV2Tray.exe"
#define MyDistroName    "homepage-v2-latest"

[Setup]
AppId={{B5D7F7C2-7F1F-4F2D-9B6F-HOMEPAGEV2INST}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
DefaultDirName={localappdata}\HomepageV2\app
DefaultGroupName={#MyAppName}
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
OutputDir=..\dist
OutputBaseFilename=homepage-v2-installer-setup
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
SetupIconFile=..\assets\icon.ico
UninstallDisplayIcon={app}\{#MyAppExeName}
ArchitecturesInstallIn64BitMode=x64
ArchitecturesAllowed=x64

[Languages]
Name: "japanese"; MessagesFile: "compiler:Languages\Japanese.isl"

[Tasks]
Name: "desktopicon"; Description: "デスクトップにショートカットを作成する"; GroupDescription: "追加のショートカット:"; Flags: unchecked

[Files]
; トレイ常駐 .exe（事前に build-exe.ps1 で生成しておく）
Source: "..\tray-app\HomepageV2Tray.exe"; DestDir: "{app}"; Flags: ignoreversion

; インストール/アンインストール用 PowerShell スクリプト
Source: "scripts\install-wsl.ps1";   DestDir: "{app}\scripts"; Flags: ignoreversion
Source: "scripts\uninstall-wsl.ps1"; DestDir: "{app}\scripts"; Flags: ignoreversion

; アイコン
Source: "..\assets\icon.ico"; DestDir: "{app}"; Flags: ignoreversion skipifsourcedoesntexist

[Icons]
Name: "{group}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; IconFilename: "{app}\icon.ico"
Name: "{group}\ログフォルダを開く"; Filename: "{localappdata}\HomepageV2\logs"
Name: "{group}\{cm:UninstallProgram,{#MyAppName}}"; Filename: "{uninstallexe}"
Name: "{userdesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; IconFilename: "{app}\icon.ico"; Tasks: desktopicon

[Run]
; インストール直後: WSL イメージ DL & import （3GB のため時間がかかる旨を表示）
Filename: "powershell.exe"; \
    Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\scripts\install-wsl.ps1"" -DistroName ""{#MyDistroName}"""; \
    StatusMsg: "WSL イメージをダウンロードして取り込んでいます (約3GB、数分かかります)..."; \
    Flags: runhidden waituntilterminated

; トレイアプリ起動（任意）
Filename: "{app}\{#MyAppExeName}"; Description: "{#MyAppName} を起動する"; Flags: nowait postinstall skipifsilent

[UninstallRun]
; アンインストール時: WSL ディストリ登録解除
Filename: "powershell.exe"; \
    Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\scripts\uninstall-wsl.ps1"" -DistroName ""{#MyDistroName}"""; \
    Flags: runhidden waituntilterminated; \
    RunOnceId: "UninstallWslDistro"

[UninstallDelete]
Type: filesandordirs; Name: "{localappdata}\HomepageV2\cache"
; logs と wsl は意図的に残す（ユーザーが手動で消せる）

[Code]
function InitializeSetup(): Boolean;
var
  ResultCode: Integer;
begin
  Result := True;
  // wsl.exe の存在を簡易チェック
  if not Exec('wsl.exe', '--status', '', SW_HIDE, ewWaitUntilTerminated, ResultCode) then
  begin
    if MsgBox('WSL が見つかりません。' + #13#10 +
              '管理者 PowerShell で `wsl --install` を実行し、PC を再起動してから本インストーラを再実行してください。' + #13#10 + #13#10 +
              'このまま続行しますか？',
              mbConfirmation, MB_YESNO) = IDNO then
      Result := False;
  end;
end;
