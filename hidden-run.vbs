' hidden-run.vbs - run the given command line fully hidden (no console flash).
' Used by git-gui-master to launch the dock helper without a PowerShell window.
Dim a, c, i, s
Set a = WScript.Arguments
c = ""
For i = 0 To a.Count - 1
  s = a(i)
  If InStr(s, " ") > 0 Then s = """" & s & """"
  If i > 0 Then c = c & " "
  c = c & s
Next
CreateObject("WScript.Shell").Run c, 0, False
