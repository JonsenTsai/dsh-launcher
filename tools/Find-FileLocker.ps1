<#
.SYNOPSIS
  Find which process is holding a file whose name contains the given string.
.DESCRIPTION
  Enumerates all system handle tables via NtQuerySystemInformation + NtQueryObject
  and matches the file name. No Sysinternals handle.exe needed (pure .NET P/Invoke).
  Usage:
    powershell -NoProfile -ExecutionPolicy Bypass -File Find-FileLocker.ps1
    powershell -NoProfile -ExecutionPolicy Bypass -File Find-FileLocker.ps1 -FileName cordis.yml
#>
param(
    [string]$FileName = 'cordis.yml'
)

$code = @'
using System;
using System.Runtime.InteropServices;
using System.Collections.Generic;

public class HandleSearcher {
    [DllImport("ntdll.dll")] static extern int NtQuerySystemInformation(int infoClass, IntPtr info, int size, out int ret);
    [DllImport("ntdll.dll")] static extern int NtQueryObject(IntPtr handle, int infoClass, IntPtr objInfo, int size, out int ret);
    [DllImport("kernel32.dll")] static extern IntPtr OpenProcess(int access, bool inherit, int pid);
    [DllImport("kernel32.dll")] static extern int DuplicateHandle(IntPtr srcProc, IntPtr srcHandle, IntPtr targetProc, out IntPtr targetHandle, int access, bool inherit, int options);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
    [DllImport("kernel32.dll")] static extern int GetCurrentProcessId();

    [StructLayout(LayoutKind.Sequential)]
    struct SYSTEM_HANDLE_ENTRY {
        public int ProcessId;
        public byte ObjectTypeIndex;
        public byte HandleAttributes;
        public ushort HandleValue;
        public IntPtr Object;
        public int GrantedAccess;
    }

    public static List<string> Find(string needle) {
        var result = new List<string>();
        int size = 0x20000;
        IntPtr buf = Marshal.AllocHGlobal(size);
        int ret;
        int status = NtQuerySystemInformation(16, buf, size, out ret);
        while (status == unchecked((int)0xC0000004)) {
            Marshal.FreeHGlobal(buf);
            size *= 2;
            buf = Marshal.AllocHGlobal(size);
            status = NtQuerySystemInformation(16, buf, size, out ret);
        }
        if (status != 0) { Marshal.FreeHGlobal(buf); return result; }
        int count = Marshal.ReadInt32(buf, 0);
        IntPtr entries = IntPtr.Add(buf, 4);
        int entrySize = Marshal.SizeOf(typeof(SYSTEM_HANDLE_ENTRY));
        for (int i = 0; i < count; i++) {
            IntPtr e = IntPtr.Add(entries, i * entrySize);
            int pid = Marshal.ReadInt32(e, 0);
            if (pid == 0) continue;
            IntPtr hProcess = OpenProcess(0x40, false, pid);
            if (hProcess == IntPtr.Zero) continue;
            IntPtr srcHandle = new IntPtr(Marshal.ReadInt16(e, 6));
            IntPtr dup;
            int dupRes = DuplicateHandle(hProcess, srcHandle, (IntPtr)(-1), out dup, 0, false, 2);
            CloseHandle(hProcess);
            if (dupRes != 0) continue;
            int oSize = 0x1000;
            IntPtr oBuf = Marshal.AllocHGlobal(oSize);
            int oRet;
            int s2 = NtQueryObject(dup, 1, oBuf, oSize, out oRet);
            if (s2 == 0) {
                int nameLen = Marshal.ReadInt16(oBuf, 0);
                if (nameLen > 0 && nameLen < oSize) {
                    IntPtr bufPtr = Marshal.ReadIntPtr(oBuf, 8);
                    string name = Marshal.PtrToStringUni(bufPtr, nameLen / 2);
                    if (name != null && name.IndexOf(needle, StringComparison.OrdinalIgnoreCase) >= 0) {
                        result.Add(pid + "\t" + name);
                    }
                }
            }
            Marshal.FreeHGlobal(oBuf);
            CloseHandle(dup);
        }
        Marshal.FreeHGlobal(buf);
        return result;
    }
}
'@
Add-Type -TypeDefinition $code -ErrorAction Stop

Write-Output "Enumerating all system handles to find files containing '$FileName' (takes ~10-40s)..."
$res = [HandleSearcher]::Find($FileName)

if ($res.Count -eq 0) {
    Write-Output ">>> No process is currently holding a file that contains '$FileName'."
    Write-Output "    (If you ran this right when dsh failed to start, the locker already released it."
    Write-Output "     Strong suspect: real-time antivirus (Huorong/Defender) scanning the .dsh folder."
    Write-Output "     Fix: add $env:USERPROFILE\.dsh to antivirus exclusions, then retry.)"
} else {
    Write-Output ">>> Found handle(s) holding '$FileName':"
    foreach ($r in $res) { Write-Output ("  " + $r) }
    Write-Output ""
    Write-Output ">>> Process details:"
    $pids = @()
    foreach ($r in $res) {
        $p = $r.Split("`t")[0]
        if ($pids -notcontains $p) { $pids += $p }
    }
    foreach ($p in $pids) {
        try {
            $pr = Get-Process -Id $p -ErrorAction SilentlyContinue
            $cmd = (Get-CimInstance Win32_Process -Filter "ProcessId=$p" -ErrorAction SilentlyContinue).CommandLine
            Write-Output ("  PID=$p  Name=$($pr.ProcessName)  Path=$($pr.Path)")
            if ($cmd) { Write-Output ("    CMD=$cmd") }
        } catch {
            Write-Output ("  PID=$p (cannot get details: $($_.Exception.Message))")
        }
    }
}
