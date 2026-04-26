; ============================================================================
;  homepage-v2-installer / Inno Setup script
;  ビルド: ISCC.exe homepage-v2-installer.iss
; ============================================================================

#define MyAppName       "homepage-v2-installer"
#define MyAppVersion    "1.0.0"
#define MyAppPublisher  "homepage-v2"
#define MyAppExeName    "HomepageV2Tray.exe"
#define MyDistroName    "homepage-v2-latest"
; 配布物 (GitHub Releases) のタグ・リポジトリ・ファイル名
; MyReleaseTag に 'latest' を指定すると、本体リポ (homepage) の最新リリースを参照します
#define MyReleaseTag    "latest"
#define MyReleaseRepo   "okamoto53515606/homepage"
#define MyTarFileName   "homepage-v2-latest.tar.gz"

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
; インストール直後: ダウンロード済み tar を検証 → wsl --import
; （DL は [Code] セクションでウィザードの進捗バーを使って実施済み）
Filename: "powershell.exe"; \
    Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\scripts\install-wsl.ps1"" -DistroName ""{#MyDistroName}"" -TarFile ""{code:GetTarPath}"" -ExpectedSha256 ""{code:GetExpectedSha256}"""; \
    StatusMsg: "WSL イメージを検証して取り込んでいます (数分かかります)..."; \
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
var
  DownloadPage: TDownloadWizardPage;
  CachedTarPath: String;
  CachedSha256: String;
  WslWasAutoInstalled: Boolean;

function GetTarPath(Param: String): String;
begin
  Result := CachedTarPath;
end;

function GetExpectedSha256(Param: String): String;
begin
  Result := CachedSha256;
end;

function OnDownloadProgress(const Url, FileName: String; const Progress, ProgressMax: Int64): Boolean;
begin
  if ProgressMax <> 0 then
    Log(Format('  %d / %d (%d%%)', [Progress, ProgressMax, (Progress * 100) div ProgressMax]));
  Result := True;
end;

procedure InitializeWizard;
begin
  DownloadPage := CreateDownloadPage(
    'WSL イメージのダウンロード',
    'homepage-v2 用の WSL2 イメージ (gzip圧縮済み, 約1.1GB) をダウンロードしています。回線速度により数分かかります。',
    @OnDownloadProgress);
end;

function LoadSha256FromFile(const FilePath: String): String;
var
  Lines: TArrayOfString;
  S: String;
  SpacePos: Integer;
begin
  Result := '';
  if not LoadStringsFromFile(FilePath, Lines) then Exit;
  if GetArrayLength(Lines) = 0 then Exit;
  S := Trim(Lines[0]);
  SpacePos := Pos(' ', S);
  if SpacePos > 0 then
    Result := Lowercase(Copy(S, 1, SpacePos - 1))
  else
    Result := Lowercase(S);
end;

function NextButtonClick(CurPageID: Integer): Boolean;
var
  CacheDir, TarPath, ShaPath, TarUrl, ShaUrl, CachedHash: String;
  UseCache: Boolean;
begin
  Result := True;
  if CurPageID = wpReady then
  begin
    CacheDir := ExpandConstant('{localappdata}\HomepageV2\cache');
    if not ForceDirectories(CacheDir) then
    begin
      MsgBox('キャッシュフォルダを作成できません: ' + CacheDir, mbError, MB_OK);
      Result := False; Exit;
    end;
    TarPath := CacheDir + '\{#MyTarFileName}';
    ShaPath := CacheDir + '\{#MyTarFileName}.sha256';
#if MyReleaseTag == "latest"
    TarUrl  := 'https://github.com/{#MyReleaseRepo}/releases/latest/download/{#MyTarFileName}';
    ShaUrl  := 'https://github.com/{#MyReleaseRepo}/releases/latest/download/{#MyTarFileName}.sha256';
#else
    TarUrl  := 'https://github.com/{#MyReleaseRepo}/releases/download/{#MyReleaseTag}/{#MyTarFileName}';
    ShaUrl  := 'https://github.com/{#MyReleaseRepo}/releases/download/{#MyReleaseTag}/{#MyTarFileName}.sha256';
#endif

    // --- キャッシュ再利用判定 -------------------------------------------------
    // tar と sha256 の両方が存在し、sha256 ファイル形式が正常であればダウンロードをスキップする
    // (実 SHA 検証は install-wsl.ps1 が行うため、ここでは形式検証のみ)
    UseCache := False;
    if FileExists(TarPath) and FileExists(ShaPath) then
    begin
      CachedHash := LoadSha256FromFile(ShaPath);
      if Length(CachedHash) = 64 then
      begin
        Log('Cache hit: reuse ' + TarPath);
        CachedTarPath := TarPath;
        CachedSha256  := CachedHash;
        UseCache := True;
      end
      else
        Log('Cache sha256 file invalid; will re-download');
    end;

    if UseCache then Exit;

    DownloadPage.Clear;
    DownloadPage.Add(ShaUrl, '{#MyTarFileName}.sha256', '');
    DownloadPage.Add(TarUrl, '{#MyTarFileName}', '');
    DownloadPage.Show;
    try
      try
        DownloadPage.Download;
        // CreateDownloadPage は {tmp} に保存するため、キャッシュへコピー
        FileCopy(ExpandConstant('{tmp}\{#MyTarFileName}.sha256'), ShaPath, False);
        FileCopy(ExpandConstant('{tmp}\{#MyTarFileName}'), TarPath, False);
        CachedTarPath := TarPath;
        CachedSha256  := LoadSha256FromFile(ShaPath);
        if Length(CachedSha256) <> 64 then
        begin
          MsgBox('SHA256 ハッシュファイルの形式が不正です。', mbError, MB_OK);
          Result := False;
        end;
      except
        if MsgBox('ダウンロードに失敗しました: ' + GetExceptionMessage + #13#10 + 'リトライしますか？',
                  mbError, MB_YESNO) = IDYES then
          Result := False  // ウィザード上に留まる→再度 Next で再試行
        else
          Result := False;
      end;
    finally
      DownloadPage.Hide;
    end;
  end;
end;

function IsWslAvailable(): Boolean;
var
  ResultCode: Integer;
begin
  // wsl.exe --status が成功 (ExitCode=0) なら WSL2 利用可能と判定
  Result := False;
  if Exec('wsl.exe', '--status', '', SW_HIDE, ewWaitUntilTerminated, ResultCode) then
    Result := (ResultCode = 0);
end;

function TryInstallWsl(): Boolean;
var
  ResultCode: Integer;
begin
  Result := False;
  if MsgBox(
      'WSL2 がインストールされていません。' + #13#10 +
      '今すぐ自動でインストールしますか?' + #13#10 + #13#10 +
      '・UAC (管理者の確認) ダイアログが表示されます' + #13#10 +
      '・所要時間は 1〜3 分程度です' + #13#10 +
      '・通常は再起動不要ですが、環境によっては再起動が必要になる場合があります',
      mbConfirmation, MB_YESNO) = IDNO then
    Exit;

  // ShellExec の 'runas' 動詞で UAC 昇格して wsl --install を実行
  // --no-distribution: 既定の Ubuntu を入れず、WSL ランタイムのみ導入
  if not ShellExec('runas', 'wsl.exe',
      '--install --no-distribution', '', SW_SHOW, ewWaitUntilTerminated, ResultCode) then
  begin
    MsgBox(
      'WSL のインストールを起動できませんでした (UAC キャンセル等)。' + #13#10 +
      '管理者 PowerShell で `wsl --install` を手動実行してから再試行してください。',
      mbError, MB_OK);
    Exit;
  end;

  if ResultCode <> 0 then
  begin
    MsgBox(
      'WSL のインストールが失敗しました (ExitCode=' + IntToStr(ResultCode) + ')。' + #13#10 +
      '管理者 PowerShell で `wsl --install` を手動実行してから再試行してください。',
      mbError, MB_OK);
    Exit;
  end;

  // インストール直後の状態確認
  if IsWslAvailable() then
  begin
    WslWasAutoInstalled := True;
    Result := True;
    Exit;
  end;

  // 再起動が必要なケース (Virtual Machine Platform 等の機能初有効化時)
  MsgBox(
    'WSL のインストールは完了しましたが、有効化のために PC の再起動が必要です。' + #13#10 +
    '再起動後、改めて本インストーラを実行してください。',
    mbInformation, MB_OK);
end;

function NeedRestart(): Boolean;
begin
  // 自動インストール経由で WSL を入れた場合は、万全を期して再起動を推奨する
  // (完了画面に「今すぐ再起動 / 後で手動で再起動」のラジオが表示される)
  Result := WslWasAutoInstalled;
end;

function InitializeSetup(): Boolean;
begin
  Result := True;
  WslWasAutoInstalled := False;
  if IsWslAvailable() then Exit;

  // WSL2 未導入 → 自動インストールを試行
  if not TryInstallWsl() then
  begin
    Result := False;
    Exit;
  end;
end;
