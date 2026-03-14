[Setup]
AppName=FastSync
AppVersion=1.0
DefaultDirName={localappdata}\FastSync
DefaultGroupName=FastSync
OutputBaseFilename=FastSync
OutputDir=installer_output
PrivilegesRequired=admin

[Files]
Source: "dist\FastSync.exe"; DestDir: "{app}"
Source: "assets\*"; DestDir: "{app}\assets"

[Icons]
Name: "{group}\FastSync"; Filename: "{app}\FastSync.exe"
Name: "{userdesktop}\FastSync"; Filename: "{app}\FastSync.exe"

[Registry]
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueName: "FastSync"; ValueType: string; ValueData: """{app}\FastSync.exe"" --tray"; Flags: uninsdeletevalue

[Run]
Filename: "netsh"; Parameters: "advfirewall firewall delete rule name=FastSync"; Flags: runhidden
Filename: "netsh"; Parameters: "advfirewall firewall delete rule name=FastSyncUDP"; Flags: runhidden
Filename: "netsh"; Parameters: "advfirewall firewall add rule name=FastSync dir=in action=allow protocol=TCP localport=8000"; Flags: runhidden
Filename: "netsh"; Parameters: "advfirewall firewall add rule name=FastSyncUDP dir=in action=allow protocol=UDP localport=9876,9877"; Flags: runhidden

Filename: "{app}\FastSync.exe"; Description: "Launch FastSync"; Flags: postinstall nowait skipifsilent