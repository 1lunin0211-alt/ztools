Unicode true
ManifestDPIAware true
RequestExecutionLevel admin
SetCompressor /SOLID lzma

!include "MUI2.nsh"
!include "LogicLib.nsh"
!include "x64.nsh"

!ifndef SOURCE_DIR
  !error "SOURCE_DIR is required. Pass /DSOURCE_DIR=..."
!endif

!ifndef OUTPUT_DIR
  !define OUTPUT_DIR "."
!endif

!ifdef INSTALLER_CONFIG
  !include "${INSTALLER_CONFIG}"
!endif

!ifndef APP_VERSION
  !define APP_VERSION "1.1"
!endif

!ifndef APP_VERSION_QUAD
  !define APP_VERSION_QUAD "1.1.0.0"
!endif

!ifndef APP_PUBLISHER
  !define APP_PUBLISHER "Лунин В.И."
!endif

!define APP_NAME "ZTool"
!define APP_UNINSTALL_KEY "Software\Microsoft\Windows\CurrentVersion\Uninstall\ZTool"
!define START_MENU_DIR "ZTool"
!define ADDIN_GUID "{59959DFA-3229-4B86-852E-52ABF2BDB8C0}"

Name "${APP_NAME}"
OutFile "${OUTPUT_DIR}\ZTool-Setup-${APP_VERSION}.exe"
InstallDir "C:\ZTool"
BrandingText "${APP_NAME} ${APP_VERSION}"
ShowInstDetails show
ShowUninstDetails show

VIProductVersion "${APP_VERSION_QUAD}"
VIAddVersionKey "ProductName" "${APP_NAME}"
VIAddVersionKey "ProductVersion" "${APP_VERSION}"
VIAddVersionKey "CompanyName" "${APP_PUBLISHER}"
VIAddVersionKey "FileDescription" "${APP_NAME} installer"
VIAddVersionKey "FileVersion" "${APP_VERSION}"
VIAddVersionKey "LegalCopyright" "Copyright (c) ${APP_PUBLISHER}"

!define MUI_ABORTWARNING
!ifdef INSTALLER_ICON
  !define MUI_ICON "${INSTALLER_ICON}"
  !define MUI_UNICON "${INSTALLER_ICON}"
!endif
!define MUI_WELCOMEPAGE_TITLE "Установка ${APP_NAME} ${APP_VERSION}"
!define MUI_WELCOMEPAGE_TEXT "Этот мастер установит ${APP_NAME}, зарегистрирует надстройку SolidWorks и создаст ярлыки."
!define MUI_FINISHPAGE_TITLE "${APP_NAME} установлен"
!define MUI_FINISHPAGE_TEXT "${APP_NAME} ${APP_VERSION} установлен. Надстройка SolidWorks зарегистрирована и будет загружаться при запуске SolidWorks."

!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_PAGE_FINISH

!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES

!insertmacro MUI_LANGUAGE "Russian"

LangString Msg64BitRequired ${LANG_RUSSIAN} "${APP_NAME} предназначен для 64-битной Windows и SolidWorks x64."
LangString MsgCloseApps ${LANG_RUSSIAN} "Перед установкой или удалением закройте SolidWorks и ZTool.$\r$\n$\r$\nЗапущены процессы:$\r$\n$0"
LangString MsgRegisterFailed ${LANG_RUSSIAN} "Файлы установлены, но регистрация надстройки SolidWorks не прошла. Код ошибки: $0.$\r$\nЗапустите установщик от имени администратора или выполните Register ZTool SolidWorks AddIn.cmd из папки установки."
LangString MsgUnregisterFailed ${LANG_RUSSIAN} "Удаление регистрации надстройки SolidWorks завершилось с ошибкой. Код ошибки: $0.$\r$\nФайлы всё равно будут удалены."
LangString MsgLegacyUninstallFailed ${LANG_RUSSIAN} "Не удалось удалить предыдущую установку ZTool из:$\r$\n$1$\r$\n$\r$\nКод ошибки: $0"

Var PowerShellExe
Var ExitCode
Var ExecOutput

Function .onInit
  SetShellVarContext all
  ${IfNot} ${RunningX64}
    MessageBox MB_ICONSTOP "$(Msg64BitRequired)"
    Abort
  ${EndIf}
FunctionEnd

Function GetPowerShell64
  StrCpy $PowerShellExe "$WINDIR\Sysnative\WindowsPowerShell\v1.0\powershell.exe"
  IfFileExists "$PowerShellExe" done
  StrCpy $PowerShellExe "$WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe"
  IfFileExists "$PowerShellExe" done
  StrCpy $PowerShellExe "$SYSDIR\WindowsPowerShell\v1.0\powershell.exe"
done:
FunctionEnd

Function CheckRunningApps
  Call GetPowerShell64
  nsExec::ExecToStack '"$PowerShellExe" -NoProfile -ExecutionPolicy Bypass -Command "$$p=Get-Process -Name SLDWORKS,ZTool -ErrorAction SilentlyContinue; if ($$p) { $$p | ForEach-Object { $$_.ProcessName } | Sort-Object -Unique | Write-Output; exit 20 }; exit 0"'
  Pop $ExitCode
  Pop $ExecOutput
  ${If} $ExitCode != 0
    StrCpy $0 "$ExecOutput"
    MessageBox MB_ICONSTOP "$(MsgCloseApps)"
    Abort
  ${EndIf}
FunctionEnd

Function RemovePreviousInstall
  ReadRegStr $1 HKLM "${APP_UNINSTALL_KEY}" "InstallLocation"
  ${If} $1 == ""
    StrCpy $1 "$PROGRAMFILES64\ZTool"
  ${EndIf}

  ${If} $1 == ""
    Return
  ${EndIf}

  ${If} $1 == $INSTDIR
    Return
  ${EndIf}

  ${If} $1 == "$PROGRAMFILES64\ZTool"
    Call GetPowerShell64
    IfFileExists "$1\Unregister ZTool SolidWorks AddIn.ps1" 0 remove_files
    ExecWait '"$PowerShellExe" -NoProfile -ExecutionPolicy Bypass -File "$1\Unregister ZTool SolidWorks AddIn.ps1" -RemoveLegacy' $ExitCode
    ${If} $ExitCode != 0
      StrCpy $0 "$ExitCode"
      MessageBox MB_ICONSTOP "$(MsgLegacyUninstallFailed)"
      Abort
    ${EndIf}
remove_files:
    RMDir /r "$1"
    DeleteRegKey HKLM "${APP_UNINSTALL_KEY}"
  ${EndIf}
FunctionEnd

Section "ZTool" SecMain
  SetShellVarContext all
  SetRegView 64
  Call CheckRunningApps
  Call RemovePreviousInstall

  SetOutPath "$INSTDIR"
!ifdef INSTALLER_ICON
  File /oname=ZTool.ico "${INSTALLER_ICON}"
!endif
  File /r "${SOURCE_DIR}\*.*"

  WriteUninstaller "$INSTDIR\Uninstall.exe"

  CreateDirectory "$SMPROGRAMS\${START_MENU_DIR}"
  CreateShortCut "$SMPROGRAMS\${START_MENU_DIR}\ZTool.lnk" "$INSTDIR\ZTool.exe" "" "$INSTDIR\ZTool.ico" 0
  CreateShortCut "$SMPROGRAMS\${START_MENU_DIR}\Деактивация лицензии.lnk" "$INSTDIR\ZTool License Deactivate.exe" "" "$INSTDIR\ZTool.ico" 0
  CreateShortCut "$SMPROGRAMS\${START_MENU_DIR}\Регистрация надстройки SolidWorks.lnk" "$INSTDIR\Register ZTool SolidWorks AddIn.cmd" "" "$INSTDIR\ZTool.ico" 0
  CreateShortCut "$SMPROGRAMS\${START_MENU_DIR}\Удалить ZTool.lnk" "$INSTDIR\Uninstall.exe" "" "$INSTDIR\Uninstall.exe" 0
  CreateShortCut "$DESKTOP\ZTool.lnk" "$INSTDIR\ZTool.exe" "" "$INSTDIR\ZTool.ico" 0

  WriteRegStr HKLM "${APP_UNINSTALL_KEY}" "DisplayName" "${APP_NAME}"
  WriteRegStr HKLM "${APP_UNINSTALL_KEY}" "DisplayVersion" "${APP_VERSION}"
  WriteRegStr HKLM "${APP_UNINSTALL_KEY}" "Publisher" "${APP_PUBLISHER}"
  WriteRegStr HKLM "${APP_UNINSTALL_KEY}" "InstallLocation" "$INSTDIR"
  WriteRegStr HKLM "${APP_UNINSTALL_KEY}" "DisplayIcon" "$INSTDIR\ZTool.ico,0"
  WriteRegStr HKLM "${APP_UNINSTALL_KEY}" "UninstallString" '"$INSTDIR\Uninstall.exe"'
  WriteRegStr HKLM "${APP_UNINSTALL_KEY}" "QuietUninstallString" '"$INSTDIR\Uninstall.exe" /S'
  WriteRegDWORD HKLM "${APP_UNINSTALL_KEY}" "NoModify" 1
  WriteRegDWORD HKLM "${APP_UNINSTALL_KEY}" "NoRepair" 1

  Call GetPowerShell64
  ExecWait '"$PowerShellExe" -NoProfile -ExecutionPolicy Bypass -File "$INSTDIR\Register ZTool SolidWorks AddIn.ps1" -PackageRoot "$INSTDIR" -RemoveLegacy' $ExitCode
  ${If} $ExitCode != 0
    StrCpy $0 "$ExitCode"
    MessageBox MB_ICONSTOP "$(MsgRegisterFailed)"
    Abort
  ${EndIf}
SectionEnd

Function un.GetPowerShell64
  StrCpy $PowerShellExe "$WINDIR\Sysnative\WindowsPowerShell\v1.0\powershell.exe"
  IfFileExists "$PowerShellExe" done
  StrCpy $PowerShellExe "$WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe"
  IfFileExists "$PowerShellExe" done
  StrCpy $PowerShellExe "$SYSDIR\WindowsPowerShell\v1.0\powershell.exe"
done:
FunctionEnd

Function un.CheckRunningApps
  Call un.GetPowerShell64
  nsExec::ExecToStack '"$PowerShellExe" -NoProfile -ExecutionPolicy Bypass -Command "$$p=Get-Process -Name SLDWORKS,ZTool -ErrorAction SilentlyContinue; if ($$p) { $$p | ForEach-Object { $$_.ProcessName } | Sort-Object -Unique | Write-Output; exit 20 }; exit 0"'
  Pop $ExitCode
  Pop $ExecOutput
  ${If} $ExitCode != 0
    StrCpy $0 "$ExecOutput"
    MessageBox MB_ICONSTOP "$(MsgCloseApps)"
    Abort
  ${EndIf}
FunctionEnd

Section "Uninstall"
  SetShellVarContext all
  SetRegView 64
  Call un.CheckRunningApps

  Call un.GetPowerShell64
  IfFileExists "$INSTDIR\Unregister ZTool SolidWorks AddIn.ps1" 0 skip_unreg
  ExecWait '"$PowerShellExe" -NoProfile -ExecutionPolicy Bypass -File "$INSTDIR\Unregister ZTool SolidWorks AddIn.ps1" -RemoveLegacy' $ExitCode
  ${If} $ExitCode != 0
    StrCpy $0 "$ExitCode"
    MessageBox MB_ICONEXCLAMATION "$(MsgUnregisterFailed)"
  ${EndIf}
skip_unreg:

  Delete "$DESKTOP\ZTool.lnk"
  Delete "$SMPROGRAMS\${START_MENU_DIR}\ZTool.lnk"
  Delete "$SMPROGRAMS\${START_MENU_DIR}\Деактивация лицензии.lnk"
  Delete "$SMPROGRAMS\${START_MENU_DIR}\Регистрация надстройки SolidWorks.lnk"
  Delete "$SMPROGRAMS\${START_MENU_DIR}\Удалить ZTool.lnk"
  RMDir "$SMPROGRAMS\${START_MENU_DIR}"

  DeleteRegKey HKLM "${APP_UNINSTALL_KEY}"
  RMDir /r "$INSTDIR"
SectionEnd
