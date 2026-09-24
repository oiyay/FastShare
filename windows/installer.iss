[Setup]
AppName=FastShare
AppVersion=5.0.3
DefaultDirName={pf}\FastShare
DefaultGroupName=FastShare
OutputDir=..\build\windows\x64\installer
OutputBaseFilename=FastShare-Setup
Compression=lzma2
SolidCompression=yes
ArchitecturesInstallIn64BitMode=x64
DisableProgramGroupPage=yes
UninstallDisplayIcon={app}\fast_share.exe

[Files]
Source: "..\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\FastShare"; Filename: "{app}\fast_share.exe"
Name: "{commondesktop}\FastShare"; Filename: "{app}\fast_share.exe"
