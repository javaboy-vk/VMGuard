/*
================================================================================
 VMGuard – Preshutdown Sentinel Service – v1.0.1
================================================================================
 File Name   : Program.cs
 Author      : javaboy-vk
 Date        : 2026-01-16
 Version     : 1.0.1

 PURPOSE
   Provide a preshutdown-tier “tripwire” that triggers VMGuard’s STOP release
   path early during host shutdown, before normal service teardown.

 RESPONSIBILITIES
   1) Register as a Windows service that ACCEPTS_PRESHUTDOWN.
   2) On PRESHUTDOWN, invoke VMGuard Guard STOP event signaler (best-effort).
   3) Also handle SHUTDOWN/STOP as fallback.
   4) NEVER block shutdown; always be bounded and best-effort.

 NON-RESPONSIBILITIES
   - Does NOT shut down VMware directly.
   - Does NOT run vmrun.
   - Does NOT manage VM running flag files.
   - Does NOT manage VMGuard Guard lifecycle.

 LIFECYCLE CONTEXT
   - Runs as LocalSystem service.
   - Designed to live under P:\Scripts\VMGuard.
   - Uses only relative paths rooted at its own executable directory.

 v1.0.1 CHANGE
   - Eliminates Error 109 on STOP by removing Environment.Exit and allowing
     ServiceMain to return naturally.
   - Removes polling sleep loop; ServiceMain blocks on a kernel wait handle
     and is released by the control handler.

================================================================================
*/

using System;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

namespace VMGuard.PreshutdownSentinel
{
    internal static class SentinelService
    {
        private const string ServiceName = "VMGuard-Preshutdown-Sentinel";

        private const int StopSignalerMaxWaitMs = 3000;

        private static SERVICE_STATUS_HANDLE _serviceStatusHandle = IntPtr.Zero;
        private static SERVICE_STATUS _serviceStatus;
        private static readonly object _invokeLock = new();
        private static int _invoked = 0;

        // v1.0.1: event-driven ServiceMain lifetime (no polling / no sleeps)
        private static readonly ManualResetEvent _stopEvent = new(false);

        static int Main(string[] args)
        {
            if (Environment.UserInteractive)
            {
                Log("===========================================");
                Log("VMGuard Preshutdown Sentinel v1.0.1 (CONSOLE MODE)");
                Log("===========================================");
                InvokeStopSignalerBestEffort("CONSOLE");
                return 0;
            }

            SERVICE_TABLE_ENTRY[] serviceTable = new SERVICE_TABLE_ENTRY[]
            {
                new SERVICE_TABLE_ENTRY { lpServiceName = ServiceName, lpServiceProc = ServiceMain },
                new SERVICE_TABLE_ENTRY { lpServiceName = null, lpServiceProc = null }
            };

            if (!StartServiceCtrlDispatcher(serviceTable))
            {
                Log("[ERROR] StartServiceCtrlDispatcher failed.");
                return 1;
            }

            return 0;
        }

        private static void ServiceMain(int argc, IntPtr argv)
        {
            // v1.0.2: ensure service can be restarted cleanly
            _stopEvent.Reset();

            _serviceStatusHandle = RegisterServiceCtrlHandlerEx(ServiceName, ServiceCtrlHandlerEx, IntPtr.Zero);
            if (_serviceStatusHandle == IntPtr.Zero)
            {
                Log("[ERROR] RegisterServiceCtrlHandlerEx failed.");
                return;
            }

            _serviceStatus = new SERVICE_STATUS
            {
                dwServiceType = SERVICE_WIN32_OWN_PROCESS,
                dwCurrentState = SERVICE_START_PENDING,
                dwControlsAccepted = SERVICE_ACCEPT_STOP | SERVICE_ACCEPT_SHUTDOWN | SERVICE_ACCEPT_PRESHUTDOWN,
                dwWin32ExitCode = 0,
                dwServiceSpecificExitCode = 0,
                dwCheckPoint = 1,
                dwWaitHint = 5000
            };

            SetServiceStatus(_serviceStatusHandle, ref _serviceStatus);

            Log("===========================================");
            Log("VMGuard Preshutdown Sentinel Service v1.0.1 (START)");
            Log("===========================================");
            Log($"BaseDir : {AppContext.BaseDirectory}");

            _serviceStatus.dwCurrentState = SERVICE_RUNNING;
            _serviceStatus.dwCheckPoint = 0;
            _serviceStatus.dwWaitHint = 0;
            SetServiceStatus(_serviceStatusHandle, ref _serviceStatus);

            Log($"[PROBE] PRESHUTDOWN accepted by SCM = {((_serviceStatus.dwControlsAccepted & SERVICE_ACCEPT_PRESHUTDOWN) != 0)}");

            // v1.0.1: block without polling; released by BeginStopSequence()
            _stopEvent.WaitOne();
        }

        private static uint ServiceCtrlHandlerEx(uint control, uint evt, IntPtr data, IntPtr ctx)
        {
            try
            {
                if (control == SERVICE_CONTROL_PRESHUTDOWN)
                    BeginStopSequence("PRESHUTDOWN");
                else if (control == SERVICE_CONTROL_SHUTDOWN)
                    BeginStopSequence("SHUTDOWN");
                else if (control == SERVICE_CONTROL_STOP)
                    BeginStopSequence("STOP");
                else if (control == SERVICE_CONTROL_INTERROGATE)
                    SetServiceStatus(_serviceStatusHandle, ref _serviceStatus);
            }
            catch { }
            return 0;
        }

        private static void BeginStopSequence(string reason)
        {
            if (Interlocked.Exchange(ref _invoked, 1) == 1)
                return;

            lock (_invokeLock)
            {
                _serviceStatus.dwCurrentState = SERVICE_STOP_PENDING;
                _serviceStatus.dwCheckPoint = 1;
                _serviceStatus.dwWaitHint = 8000;
                SetServiceStatus(_serviceStatusHandle, ref _serviceStatus);

                Log("===========================================");
                Log($"CONTROL: {reason} received");
                Log("===========================================");

                InvokeStopSignalerBestEffort(reason);

                _serviceStatus.dwCurrentState = SERVICE_STOPPED;
                _serviceStatus.dwCheckPoint = 0;
                _serviceStatus.dwWaitHint = 0;
                SetServiceStatus(_serviceStatusHandle, ref _serviceStatus);

                // v1.0.1: release ServiceMain to return naturally (prevents Error 109)
                try { _stopEvent.Set(); } catch { }
            }
        }

        private static void InvokeStopSignalerBestEffort(string reason)
        {
            try
            {
                string baseDir = AppContext.BaseDirectory.TrimEnd('\\');
                string script = System.IO.Path.GetFullPath(System.IO.Path.Combine(baseDir, "..\\..\\guard\\vmguard-guard-stop-event-signal.ps1"));

                Log($"Invoking STOP signaler. Reason={reason}");
                Log($"Script: {script}");

                if (!System.IO.File.Exists(script))
                {
                    Log("[WARN] Stop signaler script not found.");
                    return;
                }

                var psi = new ProcessStartInfo
                {
                    FileName = "powershell.exe",
                    Arguments = $"-NoProfile -ExecutionPolicy Bypass -File \"{script}\"",
                    UseShellExecute = false,
                    CreateNoWindow = true
                };

                using var p = Process.Start(psi);
                if (p == null) return;

                if (!p.WaitForExit(StopSignalerMaxWaitMs))
                {
                    try { p.Kill(true); } catch { }
                    Log("[WARN] Stop signaler timed out.");
                }
                else
                {
                    Log($"Stop signaler exited. ExitCode={p.ExitCode}");
                }
            }
            catch (Exception ex)
            {
                Log("[ERROR] " + ex.Message);
            }
        }

        private static void Log(string msg)
{
    try
    {
        string baseDir = AppContext.BaseDirectory.TrimEnd('\\');

        // BaseDirectory = ...\VMGuard\Preshutdown_Sentinel\bin\
        // VMGuard root   = ...\VMGuard\
        // Logs root      = ...\VMGuard\logs\

        string vmguardRoot = System.IO.Path.GetFullPath(
            System.IO.Path.Combine(baseDir, "..\\..")
        );

        string logDir = System.IO.Path.Combine(vmguardRoot, "logs");
        System.IO.Directory.CreateDirectory(logDir);

        string logFile = System.IO.Path.Combine(logDir, "vmguard-preshutdown-sentinel.log");

        string ts = DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss.fff");
        System.IO.File.AppendAllText(
            logFile,
            $"{ts} {msg}{Environment.NewLine}",
            Encoding.UTF8
        );
    }
    catch { }
}



        private const uint SERVICE_WIN32_OWN_PROCESS = 0x00000010;
        private const uint SERVICE_START_PENDING = 0x00000002;
        private const uint SERVICE_RUNNING = 0x00000004;
        private const uint SERVICE_STOP_PENDING = 0x00000003;
        private const uint SERVICE_STOPPED = 0x00000001;

        private const uint SERVICE_CONTROL_STOP = 0x00000001;
        private const uint SERVICE_CONTROL_SHUTDOWN = 0x00000005;
        private const uint SERVICE_CONTROL_PRESHUTDOWN = 0x0000000F;
        private const uint SERVICE_CONTROL_INTERROGATE = 0x00000004;

        private const uint SERVICE_ACCEPT_STOP = 0x00000001;
        private const uint SERVICE_ACCEPT_SHUTDOWN = 0x00000004;
        private const uint SERVICE_ACCEPT_PRESHUTDOWN = 0x00000100;

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct SERVICE_TABLE_ENTRY
        {
            public string? lpServiceName;
            public ServiceMainFunction? lpServiceProc;
        }

        private delegate void ServiceMainFunction(int argc, IntPtr argv);
        private delegate uint HandlerExFunction(uint control, uint evt, IntPtr data, IntPtr ctx);

        [StructLayout(LayoutKind.Sequential)]
        private struct SERVICE_STATUS
        {
            public uint dwServiceType;
            public uint dwCurrentState;
            public uint dwControlsAccepted;
            public uint dwWin32ExitCode;
            public uint dwServiceSpecificExitCode;
            public uint dwCheckPoint;
            public uint dwWaitHint;
        }

        private struct SERVICE_STATUS_HANDLE
        {
            public IntPtr Handle;
            public static implicit operator IntPtr(SERVICE_STATUS_HANDLE h) => h.Handle;
            public static implicit operator SERVICE_STATUS_HANDLE(IntPtr p) => new SERVICE_STATUS_HANDLE { Handle = p };
        }

        [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        private static extern bool StartServiceCtrlDispatcher([In] SERVICE_TABLE_ENTRY[] table);

        [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        private static extern SERVICE_STATUS_HANDLE RegisterServiceCtrlHandlerEx(
            string serviceName, HandlerExFunction handler, IntPtr ctx);

        [DllImport("advapi32.dll", SetLastError = true)]
        private static extern bool SetServiceStatus(SERVICE_STATUS_HANDLE handle, ref SERVICE_STATUS status);

        // Delegate root to prevent GC of native callback
        private static readonly HandlerExFunction _serviceCtrlHandlerEx = ServiceCtrlHandlerEx;
    }
}
