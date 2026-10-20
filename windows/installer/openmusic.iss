; Windows installer (Inno Setup 6). Built by the release workflow:
;   iscc /DAppVersion=1.2.3 /DSourceDir=<Release folder> /DOutputDir=dist windows\installer\openmusic.iss
; Installs for the current user only, so no administrator prompt.

#ifndef AppVersion
  #define AppVersion "1.0.0"
#endif
#ifndef SourceDir
  #define SourceDir "..\..\build\windows\x64\runner\Release"
#endif
#ifndef OutputDir
  #define OutputDir "..\..\dist"
#endif

[Setup]
AppId={{6F1D2C7E-4B9A-4E8B-9E7A-0C3F5B2A9D41}
AppName=OpenMusic
AppVersion={#AppVersion}
AppPublisher=OpenMusic
AppPublisherURL=https://github.com/Araryarch67/OpenMusic
DefaultDirName={localappdata}\Programs\OpenMusic
DefaultGroupName=OpenMusic
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir={#OutputDir}
OutputBaseFilename=OpenMusic-windows-x64-setup
SetupIconFile=..\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\openmusic.exe
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
CloseApplications=yes

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\OpenMusic"; Filename: "{app}\openmusic.exe"
Name: "{autodesktop}\OpenMusic"; Filename: "{app}\openmusic.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\openmusic.exe"; Description: "{cm:LaunchProgram,OpenMusic}"; Flags: nowait postinstall skipifsilent
