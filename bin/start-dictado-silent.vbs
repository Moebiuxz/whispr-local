' start-dictado-silent.vbs
' Launches start-dictado.ps1 silently (no flash, no window).
' Used by the Startup folder shortcut for autostart.
Set fso = CreateObject("Scripting.FileSystemObject")
binDir  = fso.GetParentFolderName(WScript.ScriptFullName)
ps1     = binDir & "\start-dictado.ps1"
Set sh = CreateObject("WScript.Shell")
sh.Run "powershell.exe -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & ps1 & """", 0, False
