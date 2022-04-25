# 3cx-minimize.ps1
# Written by Steve Allison - https://nooblet.org/
 
# path to the default location of the startup entry
$startupPath = "C:\ProgramData\Microsoft\Windows\Start Menu\Programs\StartUp\3CXPhone for Windows.lnk"
 
# path to the default location of the 3CXPhone executable
$3cxPath = "C:\Users\Alex\AppData\Local\Programs\3CXDesktopApp\3CXDesktopApp.exe"
 
# processName to search for
$3cxProcess = "3CXDesktopApp.exe"
 
# how long to wait (in seconds) for 3cx to load before we give up
$wait = 30
 
#################################################
# idea from https://community.idera.com/database-tools/powershell/ask_the_experts/f/powershell_for_windows-12/11584/how-to-script-clicking-on-x-to-close-window
function Close-Window {
    param(
        [Parameter()]
        $handle = (Get-Process -Id $pid).MainWindowHandle
    )
 
    # expose "SendMessage" function
    $winAPI = Add-Type -MemberDefinition @'
[DllImport("user32.dll")]
public static extern int SendMessage(int hWnd, uint Msg, int wParam, int lParam);
'@ -Name "Win32CloseWindow" -Namespace Win32Functions -PassThru
   
    # close window
    $winAPI::SendMessage($handle, 0x0112, 0xF060, 0)
}
#################################################
 
# If 3CX is installed, lets see if we need to start it
if ((Test-Path($3cxPath))) {
    # if 3CX isn't set to startup automatically, then we need to start it
    if (!(Test-Path($startupPath))) {
        # Start 3CX
        Start-Process $3cxPath
    }
}
 
# Set start time, used to determine when to stop
$startTime = Get-Date
 
# Check if loop has been running longer than $wait
Start-Sleep -s 5
while ((New-TimeSpan -Start $startTime -End (Get-Date)).TotalSeconds -le $wait) {
    # Get 3cx process details
    $process = (Get-Process -Name $3cxProcess)
    if ($process.length -gt 0) {
        # minimize process
        # Handles that equal 0 are already minimized/hidden
        $process.MainWindowHandle | Where-Object { [int]$_ -gt 0 } | ForEach-Object { Close-Window $_ }
        break
    }
}