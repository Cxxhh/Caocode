; The Windows installer for Caocode, compiled by tool/build_windows.dart.
;
; It is compiled with three /D defines, all required:
;   BundleDir  the Release bundle to pack (the folder holding caocode.exe)
;   AppVersion the version pubspec.yaml carries, as it writes it (1.0.0+1)
;   OutDir     where to write the installer (build/installers)
;
; Output: Caocode-<version>-setup.exe

#ifndef BundleDir
  #error BundleDir is not defined: pass /DBundleDir=<release bundle folder>
#endif

#ifndef AppVersion
  #error AppVersion is not defined: pass /DAppVersion=<version from pubspec.yaml>
#endif
#ifndef OutDir
  #error OutDir is not defined: pass /DOutDir=<folder for the installer>
#endif

; The part of the version Windows records, without the build number pubspec
; adds after "+".
#define VersionNumber Copy(AppVersion, 1, Pos("+", AppVersion) - 1)
#if Pos("+", AppVersion) == 0
  #undef VersionNumber
  #define VersionNumber AppVersion
#endif
#define DisplayVersion VersionNumber + "c"

[Setup]
; Base of the identity Windows uses for the installed app. It must not change
; between versions, or an upgrade installs beside the old one instead of over
; it.
AppId={{da15d7fd-aed2-4f72-b2af-34c18d5db30c}
AppName=Caocode
AppVersion={#DisplayVersion}
AppPublisher=Caocode
AppVerName=Caocode {#DisplayVersion}
DefaultDirName={autopf}\Caocode
DefaultGroupName=Caocode
UninstallDisplayName=Caocode
UninstallDisplayIcon={app}\caocode.exe
OutputBaseFilename=Caocode-{#DisplayVersion}-setup
OutputDir={#OutDir}
; What Explorer shows for the installer itself. Windows wants four numbers,
; where pubspec's version has three.
VersionInfoVersion={#VersionNumber}.0
VersionInfoProductTextVersion={#DisplayVersion}
AppPublisherURL=https://github.com/Cxxhh/Caocode
AppSupportURL=https://github.com/Cxxhh/Caocode/issues
AppUpdatesURL=https://github.com/Cxxhh/Caocode/releases/latest
LicenseFile=..\LICENSE
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
; The app is 64-bit only (flutter build windows is x64 here).
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
; Per user by default ({autopf} is then %LOCALAPPDATA%\Programs): neither
; the install nor the app's updates ask for elevation, which a machine may
; not grant (no admin; UAC set to elevate signed programs only, and Setup is
; not signed) or show behind other windows. For all users (Program Files,
; elevated) is the dialog's other choice; an update keeps the install mode
; there is (UsePreviousPrivileges, and lib/update/installer_io.dart passes
; it).
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
DisableProgramGroupPage=yes
; A running Caocode is asked to close (it quits on WM_ENDSESSION, see
; windows/runner/flutter_window.cpp), and ended if it does not: a version
; from before that, or one stuck, would otherwise hold Setup at "Closing
; applications..." for good.
CloseApplications=force
; Always a log (%TEMP%\Setup Log <date> #<n>.txt, or where /LOG= says, as
; an update the app runs does): a silent install that fails says why only
; there.
SetupLogging=yes

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; \
  GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked
Name: "addtopath"; Description: "Add Caocode to the PATH"; \
  GroupDescription: "Other:"; Flags: unchecked
Name: "contextmenu"; \
  Description: "Add ""Open with Caocode"" and ""Open with Fast Ide"" to Explorer's context menu"; \
  GroupDescription: "Other:"

[Files]
Source: "..\LICENSE"; DestDir: "{app}"; Flags: ignoreversion
; The whole bundle: caocode.exe, the engine and plugin DLLs, data\ (the
; AOT app.so and flutter_assets) which sit beside the executable, and
; remote\ (VERSION and servers.json: which caocode-server remote projects
; run on their host, and where the app downloads it; tool/build_windows.dart
; puts them there).
Source: "{#BundleDir}\*"; DestDir: "{app}"; \
  Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\Caocode"; Filename: "{app}\caocode.exe"
Name: "{group}\{cm:UninstallProgram,Caocode}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\Caocode"; Filename: "{app}\caocode.exe"; Tasks: desktopicon

[Registry]
; Only when asked for. Which hive follows the install mode: a per-machine
; install writes the machine's PATH (HKLM), a per-user one the user's (HKCU).
; Writing HKCU while installing as admin would put the entry in whichever
; account elevated, which is not necessarily the one that runs the app.
Root: HKLM; Subkey: "SYSTEM\CurrentControlSet\Control\Session Manager\Environment"; \
  ValueType: expandsz; ValueName: "Path"; ValueData: "{olddata};{app}"; \
  Tasks: addtopath; Check: IsAdminInstallMode and NeedsAddPath(ExpandConstant('{app}'), True)
Root: HKCU; Subkey: "Environment"; ValueType: expandsz; ValueName: "Path"; \
  ValueData: "{olddata};{app}"; Tasks: addtopath; \
  Check: (not IsAdminInstallMode) and NeedsAddPath(ExpandConstant('{app}'), False)

; Explorer's context menu, on a file, a folder and a folder's background,
; each in a new window: Open with Caocode, a new agent in a narrow window of
; its own (a file in its composer; see AppWindows.openAgent), and Open with
; Fast Ide, as `code -n` opens it (the path its own working folder: it is
; absolute). HKA is the install mode's hive (HKLM per machine, HKCU per
; user). Windows 11 lists them under "Show more options". Unticked on a
; reinstall, they go. Settings → General writes the same keys under HKCU
; (lib/platform/context_menu_io.dart), for the user alone.
Root: HKA; Subkey: "Software\Classes\*\shell\Caocode"; ValueType: string; \
  ValueName: ""; ValueData: "{code:MenuLabel|Caocode}"; Tasks: contextmenu; \
  Flags: uninsdeletekey
Root: HKA; Subkey: "Software\Classes\*\shell\Caocode"; ValueType: string; \
  ValueName: "Icon"; ValueData: """{app}\caocode.exe"""; Tasks: contextmenu
Root: HKA; Subkey: "Software\Classes\*\shell\Caocode\command"; \
  ValueType: string; ValueName: ""; \
  ValueData: """{app}\caocode.exe"" --caocode-agent ""%1"""; Tasks: contextmenu
Root: HKA; Subkey: "Software\Classes\Directory\shell\Caocode"; \
  ValueType: string; ValueName: ""; ValueData: "{code:MenuLabel|Caocode}"; \
  Tasks: contextmenu; Flags: uninsdeletekey
Root: HKA; Subkey: "Software\Classes\Directory\shell\Caocode"; \
  ValueType: string; ValueName: "Icon"; ValueData: """{app}\caocode.exe"""; \
  Tasks: contextmenu
Root: HKA; Subkey: "Software\Classes\Directory\shell\Caocode\command"; \
  ValueType: string; ValueName: ""; \
  ValueData: """{app}\caocode.exe"" --caocode-agent ""%V"""; Tasks: contextmenu
Root: HKA; Subkey: "Software\Classes\Directory\Background\shell\Caocode"; \
  ValueType: string; ValueName: ""; ValueData: "{code:MenuLabel|Caocode}"; \
  Tasks: contextmenu; Flags: uninsdeletekey
Root: HKA; Subkey: "Software\Classes\Directory\Background\shell\Caocode"; \
  ValueType: string; ValueName: "Icon"; ValueData: """{app}\caocode.exe"""; \
  Tasks: contextmenu
Root: HKA; Subkey: "Software\Classes\Directory\Background\shell\Caocode\command"; \
  ValueType: string; ValueName: ""; \
  ValueData: """{app}\caocode.exe"" --caocode-agent ""%V"""; Tasks: contextmenu
Root: HKA; Subkey: "Software\Classes\*\shell\CaocodeFastIde"; \
  ValueType: string; ValueName: ""; ValueData: "{code:MenuLabel|Fast Ide}"; \
  Tasks: contextmenu; Flags: uninsdeletekey
Root: HKA; Subkey: "Software\Classes\*\shell\CaocodeFastIde"; \
  ValueType: string; ValueName: "Icon"; ValueData: """{app}\caocode.exe"""; \
  Tasks: contextmenu
Root: HKA; Subkey: "Software\Classes\*\shell\CaocodeFastIde\command"; \
  ValueType: string; ValueName: ""; \
  ValueData: """{app}\caocode.exe"" --caocode-cli ""%1"" -n ""%1"""; \
  Tasks: contextmenu
Root: HKA; Subkey: "Software\Classes\Directory\shell\CaocodeFastIde"; \
  ValueType: string; ValueName: ""; ValueData: "{code:MenuLabel|Fast Ide}"; \
  Tasks: contextmenu; Flags: uninsdeletekey
Root: HKA; Subkey: "Software\Classes\Directory\shell\CaocodeFastIde"; \
  ValueType: string; ValueName: "Icon"; ValueData: """{app}\caocode.exe"""; \
  Tasks: contextmenu
Root: HKA; Subkey: "Software\Classes\Directory\shell\CaocodeFastIde\command"; \
  ValueType: string; ValueName: ""; \
  ValueData: """{app}\caocode.exe"" --caocode-cli ""%V"" -n ""%V"""; \
  Tasks: contextmenu
Root: HKA; Subkey: "Software\Classes\Directory\Background\shell\CaocodeFastIde"; \
  ValueType: string; ValueName: ""; ValueData: "{code:MenuLabel|Fast Ide}"; \
  Tasks: contextmenu; Flags: uninsdeletekey
Root: HKA; Subkey: "Software\Classes\Directory\Background\shell\CaocodeFastIde"; \
  ValueType: string; ValueName: "Icon"; ValueData: """{app}\caocode.exe"""; \
  Tasks: contextmenu
Root: HKA; Subkey: "Software\Classes\Directory\Background\shell\CaocodeFastIde\command"; \
  ValueType: string; ValueName: ""; \
  ValueData: """{app}\caocode.exe"" --caocode-cli ""%V"" -n ""%V"""; \
  Tasks: contextmenu
; The caocode: URL scheme, always: a site's one-click import of an upstream
; (caocode.dev/import opens caocode://provider/import?…; see
; docs/upstream-import.md). The link comes after --caocode-link, which the
; runner hands Flutter as a request (windows/runner/open_requests.cpp).
Root: HKA; Subkey: "Software\Classes\caocode"; ValueType: string; \
  ValueName: ""; ValueData: "URL:Caocode"; Flags: uninsdeletekey
Root: HKA; Subkey: "Software\Classes\caocode"; ValueType: string; \
  ValueName: "URL Protocol"; ValueData: ""
Root: HKA; Subkey: "Software\Classes\caocode\DefaultIcon"; ValueType: string; \
  ValueName: ""; ValueData: """{app}\caocode.exe"",0"
Root: HKA; Subkey: "Software\Classes\caocode\shell\open\command"; \
  ValueType: string; ValueName: ""; \
  ValueData: """{app}\caocode.exe"" --caocode-link ""%1"""
; Unticked: what an earlier install added goes.
Root: HKA; Subkey: "Software\Classes\*\shell\Caocode"; ValueType: none; \
  Tasks: not contextmenu; Flags: deletekey
Root: HKA; Subkey: "Software\Classes\Directory\shell\Caocode"; ValueType: none; \
  Tasks: not contextmenu; Flags: deletekey
Root: HKA; Subkey: "Software\Classes\Directory\Background\shell\Caocode"; \
  ValueType: none; Tasks: not contextmenu; Flags: deletekey
Root: HKA; Subkey: "Software\Classes\*\shell\CaocodeFastIde"; ValueType: none; \
  Tasks: not contextmenu; Flags: deletekey
Root: HKA; Subkey: "Software\Classes\Directory\shell\CaocodeFastIde"; \
  ValueType: none; Tasks: not contextmenu; Flags: deletekey
Root: HKA; Subkey: "Software\Classes\Directory\Background\shell\CaocodeFastIde"; \
  ValueType: none; Tasks: not contextmenu; Flags: deletekey

[Run]
Filename: "{app}\caocode.exe"; Description: "{cm:LaunchProgram,Caocode}"; \
  Flags: nowait postinstall skipifsilent
; An update the app ran (lib/update/installer_io.dart) is silent, which
; skips the entry above: /RELAUNCH opens the app again once it is in place,
; as the user who ran it rather than the administrator Setup elevated to.
Filename: "{app}\caocode.exe"; Flags: nowait runasoriginaluser; \
  Check: RelaunchRequested

[Code]
const
  SYNCHRONIZE = $00100000;
  WaitPidTimeout = 120000;

function OpenProcess(dwDesiredAccess: DWORD; bInheritHandle: BOOL;
  dwProcessId: DWORD): THandle;
  external 'OpenProcess@kernel32.dll stdcall';
function WaitForSingleObject(hHandle: THandle; dwMilliseconds: DWORD): DWORD;
  external 'WaitForSingleObject@kernel32.dll stdcall';
function CloseHandle(hObject: THandle): BOOL;
  external 'CloseHandle@kernel32.dll stdcall';

// An update the app runs (lib/update/installer_io.dart) starts Setup as the
// app quits, with /WAITPID=<the app's process>, so the elevation it asks
// for comes up in front of the app: it waits here (two minutes at most) for
// the app to be gone before installing over it. One that does not go is
// closed by CloseApplications=force.
function InitializeSetup: Boolean;
var
  Pid: Integer;
  App: THandle;
begin
  Result := True;
  Pid := StrToIntDef(ExpandConstant('{param:WAITPID|0}'), 0);
  if Pid <= 0 then
    Exit;
  App := OpenProcess(SYNCHRONIZE, False, Pid);
  if App = 0 then
  begin
    Log(Format('Process %d is gone already', [Pid]));
    Exit;
  end;
  Log(Format('Waiting for process %d to quit', [Pid]));
  if WaitForSingleObject(App, WaitPidTimeout) <> 0 then
    Log(Format('Process %d is still running', [Pid]));
  CloseHandle(App);
end;

// Whether the command line asks for the app to be opened after a silent
// install (/RELAUNCH, an update's; see [Run]). Not silent, the finish
// page's checkbox opens it.
function RelaunchRequested: Boolean;
var
  I: Integer;
begin
  Result := False;
  if not WizardSilent then
    Exit;
  for I := 1 to ParamCount do
    if CompareText(ParamStr(I), '/RELAUNCH') = 0 then
    begin
      Result := True;
      Exit;
    end;
end;

// The context menu's labels (see [Registry]): "Open with Caocode", in
// Chinese where Windows is. Written as code points, so the script's encoding
// does not matter.
function MenuLabel(Param: String): String;
begin
  if (GetUILanguage and $3FF) = $04 then
    Result := #$7528 + ' ' + Param + ' ' + #$6253#$5F00
  else
    Result := 'Open with ' + Param;
end;

// Whether {app} is already on the PATH the install will write, so a reinstall
// does not append it a second time. Machine reads the machine's PATH, user the
// user's, matching [Registry] above.
function NeedsAddPath(Param: string; Machine: Boolean): Boolean;
var
  Path: String;
  Subkey: String;
  RootKey: Integer;
begin
  if Machine then
  begin
    RootKey := HKEY_LOCAL_MACHINE;
    Subkey := 'SYSTEM\CurrentControlSet\Control\Session Manager\Environment';
  end
  else
  begin
    RootKey := HKEY_CURRENT_USER;
    Subkey := 'Environment';
  end;

  if not RegQueryStringValue(RootKey, Subkey, 'Path', Path) then
  begin
    Result := True;
    Exit;
  end;
  Result := Pos(';' + Uppercase(Param) + ';', ';' + Uppercase(Path) + ';') = 0;
end;
