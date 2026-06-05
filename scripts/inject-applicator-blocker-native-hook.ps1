param(
  [int]$ProcessId,
  [string]$DllPath = (Join-Path $PSScriptRoot '..\artifacts\local\bmf_applicator_func_blocker.dll')
)

$ErrorActionPreference = 'Stop'

if (!$ProcessId) {
  $process = Get-Process BrickadiaServer-Win64-Shipping -ErrorAction Stop |
    Sort-Object StartTime -Descending |
    Select-Object -First 1
  $ProcessId = $process.Id
}

$resolvedDll = (Resolve-Path -LiteralPath $DllPath).Path

$source = @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;

public static class Injector {
  [DllImport("kernel32.dll", SetLastError=true)]
  static extern IntPtr OpenProcess(uint access, bool inherit, int pid);

  [DllImport("kernel32.dll", SetLastError=true)]
  static extern IntPtr VirtualAllocEx(IntPtr process, IntPtr address, UIntPtr size, uint allocationType, uint protect);

  [DllImport("kernel32.dll", SetLastError=true)]
  static extern bool WriteProcessMemory(IntPtr process, IntPtr baseAddress, byte[] buffer, UIntPtr size, out UIntPtr written);

  [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Ansi)]
  static extern IntPtr GetProcAddress(IntPtr module, string procName);

  [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
  static extern IntPtr GetModuleHandle(string moduleName);

  [DllImport("kernel32.dll", SetLastError=true)]
  static extern IntPtr CreateRemoteThread(IntPtr process, IntPtr attributes, uint stackSize, IntPtr start, IntPtr parameter, uint creationFlags, out uint threadId);

  [DllImport("kernel32.dll", SetLastError=true)]
  static extern uint WaitForSingleObject(IntPtr handle, uint milliseconds);

  [DllImport("kernel32.dll", SetLastError=true)]
  static extern bool CloseHandle(IntPtr handle);

  const uint PROCESS_CREATE_THREAD = 0x0002;
  const uint PROCESS_QUERY_INFORMATION = 0x0400;
  const uint PROCESS_VM_OPERATION = 0x0008;
  const uint PROCESS_VM_WRITE = 0x0020;
  const uint PROCESS_VM_READ = 0x0010;
  const uint MEM_COMMIT = 0x1000;
  const uint MEM_RESERVE = 0x2000;
  const uint PAGE_READWRITE = 0x04;
  const uint WAIT_OBJECT_0 = 0x00000000;

  public static void Inject(int pid, string dllPath) {
    IntPtr process = OpenProcess(
      PROCESS_CREATE_THREAD | PROCESS_QUERY_INFORMATION | PROCESS_VM_OPERATION | PROCESS_VM_WRITE | PROCESS_VM_READ,
      false,
      pid);
    if (process == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error(), "OpenProcess failed");

    try {
      byte[] bytes = Encoding.Unicode.GetBytes(dllPath + "\0");
      IntPtr remote = VirtualAllocEx(process, IntPtr.Zero, (UIntPtr)bytes.Length, MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE);
      if (remote == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error(), "VirtualAllocEx failed");

      UIntPtr written;
      if (!WriteProcessMemory(process, remote, bytes, (UIntPtr)bytes.Length, out written) || written.ToUInt64() != (ulong)bytes.Length) {
        throw new Win32Exception(Marshal.GetLastWin32Error(), "WriteProcessMemory failed");
      }

      IntPtr kernel32 = GetModuleHandle("kernel32.dll");
      if (kernel32 == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error(), "GetModuleHandle failed");

      IntPtr loadLibrary = GetProcAddress(kernel32, "LoadLibraryW");
      if (loadLibrary == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error(), "GetProcAddress failed");

      uint threadId;
      IntPtr thread = CreateRemoteThread(process, IntPtr.Zero, 0, loadLibrary, remote, 0, out threadId);
      if (thread == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error(), "CreateRemoteThread failed");

      try {
        uint wait = WaitForSingleObject(thread, 10000);
        if (wait != WAIT_OBJECT_0) throw new Exception("Timed out waiting for remote LoadLibraryW thread");
      }
      finally {
        CloseHandle(thread);
      }
    }
    finally {
      CloseHandle(process);
    }
  }
}
'@

Add-Type -TypeDefinition $source
[Injector]::Inject($ProcessId, $resolvedDll)
"Injected $resolvedDll into PID $ProcessId"
