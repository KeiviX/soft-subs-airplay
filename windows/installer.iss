; Inno Setup script for Soft Subs. Built by build.ps1 (SOFTSUBS_VERSION is set there).
#define Version GetEnv("SOFTSUBS_VERSION")

[Setup]
AppId={{8C1B9E4F-5D2A-4F7B-9A3E-2B6C1D0E7F11}
AppName=Soft Subs
AppVersion={#Version}
AppPublisher=KeiviX
AppPublisherURL=https://github.com/KeiviX/soft-subs-airplay
DefaultDirName={autopf}\Soft Subs
DisableProgramGroupPage=yes
OutputDir=..\dist
OutputBaseFilename=SoftSubs-Setup-{#Version}
SetupIconFile=softsubs\icon.ico
UninstallDisplayIcon={app}\SoftSubs.exe
Compression=lzma2/max
SolidCompression=yes
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
; Admin so the installer can open the firewall for the TV, which streams from this PC.
PrivilegesRequired=admin
WizardStyle=modern
CloseApplications=force

[Tasks]
Name: "startup"; Description: "Start Soft Subs automatically when I sign in"

[Files]
Source: "build\dist\SoftSubs\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "..\dist\chrome\soft-subs-chrome\*"; DestDir: "{app}\chrome-extension"; Flags: ignoreversion recursesubdirs

[Icons]
Name: "{autoprograms}\Soft Subs"; Filename: "{app}\SoftSubs.exe"
Name: "{autoprograms}\Soft Subs Chrome extension folder"; Filename: "{app}\chrome-extension"
Name: "{autostartup}\Soft Subs"; Filename: "{app}\SoftSubs.exe"; Tasks: startup

[Registry]
; softsubs:// lets the Chrome extension start the app when it isn't running.
Root: HKCR; Subkey: "softsubs"; ValueType: string; ValueData: "URL:Soft Subs"; Flags: uninsdeletekey
Root: HKCR; Subkey: "softsubs"; ValueType: string; ValueName: "URL Protocol"; ValueData: ""
Root: HKCR; Subkey: "softsubs\shell\open\command"; ValueType: string; ValueData: """{app}\SoftSubs.exe"" ""%1"""

[Run]
Filename: "{sys}\netsh.exe"; Parameters: "advfirewall firewall delete rule name=""Soft Subs"""; Flags: runhidden
Filename: "{sys}\netsh.exe"; Parameters: "advfirewall firewall add rule name=""Soft Subs"" dir=in action=allow program=""{app}\SoftSubs.exe"" enable=yes profile=private,domain"; Flags: runhidden
Filename: "{app}\SoftSubs.exe"; Description: "Open Soft Subs"; Flags: nowait postinstall skipifsilent
Filename: "{app}\chrome-extension"; Description: "Show the Chrome extension folder (for Load unpacked)"; Flags: postinstall shellexec skipifsilent unchecked

[UninstallRun]
Filename: "{sys}\netsh.exe"; Parameters: "advfirewall firewall delete rule name=""Soft Subs"""; Flags: runhidden; RunOnceId: "RemoveFirewallRule"
Filename: "{sys}\taskkill.exe"; Parameters: "/F /IM SoftSubs.exe"; Flags: runhidden; RunOnceId: "StopApp"
