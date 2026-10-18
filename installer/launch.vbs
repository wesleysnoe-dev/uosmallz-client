' UO Smallz launcher: runs update-check.ps1 with no console window.
' update-check.ps1 checks for a client update and then starts TazUO.exe.
Dim fso, sh, dir, ps
Set fso = CreateObject("Scripting.FileSystemObject")
Set sh = CreateObject("WScript.Shell")
dir = fso.GetParentFolderName(WScript.ScriptFullName)
ps = sh.ExpandEnvironmentStrings("%SystemRoot%") & "\System32\WindowsPowerShell\v1.0\powershell.exe"
sh.Run """" & ps & """ -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & dir & "\update-check.ps1""", 0, False
