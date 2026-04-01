using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.ServiceProcess;

/// <summary>
/// Windows Service wrapper for GUARDA TAMBOSI pipeline.
/// Build with: service.ps1 -Action compile
/// Install with: service.ps1 -Action install
/// </summary>
public sealed class MovieServerService : ServiceBase
{
    private Process _mainProcess;

    public MovieServerService()
    {
        this.ServiceName        = "GuardaTambosi";
        this.CanStop            = true;
        this.CanPauseAndContinue = false;
        this.AutoLog            = true;
    }

    protected override void OnStart(string[] args)
    {
        string baseDir   = GetBaseDir();
        string ps        = GetPowerShellPath();
        string runScript = Path.Combine(baseDir, "run-all.ps1");

        var psi = new ProcessStartInfo(
            ps,
            "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File \"" + runScript + "\"")
        {
            UseShellExecute  = false,
            CreateNoWindow   = true,
            WorkingDirectory = baseDir,
        };

        _mainProcess = Process.Start(psi);
    }

    protected override void OnStop()
    {
        string baseDir    = GetBaseDir();
        string ps         = GetPowerShellPath();
        string stopScript = Path.Combine(baseDir, "stop-all.ps1");

        // Run stop-all.ps1 to gracefully shut down all sub-processes.
        using (Process stopProc = Process.Start(new ProcessStartInfo(
            ps,
            "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File \"" + stopScript + "\"")
        {
            UseShellExecute  = false,
            CreateNoWindow   = true,
            WorkingDirectory = baseDir,
        }))
        {
            if (stopProc != null) stopProc.WaitForExit(30000);
        }

        // Also wait for (and kill) the main run-all process.
        if (_mainProcess != null && !_mainProcess.HasExited)
        {
            try
            {
                _mainProcess.WaitForExit(10000);
                if (!_mainProcess.HasExited) _mainProcess.Kill();
            }
            catch { /* best-effort */ }
        }
    }

    // Entry point — SCM starts this; block direct execution to avoid confusion.
    public static void Main(string[] programArgs)
    {
        if (Environment.UserInteractive)
        {
            Console.Error.WriteLine("GuardaTambosi Windows Service");
            Console.Error.WriteLine("Non avviare questo file direttamente.");
            Console.Error.WriteLine("Usa: powershell -ExecutionPolicy Bypass -File service.ps1 install");
            Environment.Exit(1);
            return;
        }
        ServiceBase.Run(new MovieServerService());
    }

    private static string GetBaseDir()
    {
        return Path.GetDirectoryName(Assembly.GetExecutingAssembly().Location)
               ?? AppDomain.CurrentDomain.BaseDirectory;
    }

    private static string GetPowerShellPath()
    {
        // Prefer the inbox Windows PowerShell 5.1 for maximum compatibility.
        string sys32 = Environment.GetFolderPath(Environment.SpecialFolder.System);
        string inbox = Path.Combine(sys32, @"WindowsPowerShell\v1.0\powershell.exe");
        if (File.Exists(inbox)) return inbox;

        // Fallback: just "powershell.exe" on PATH.
        return "powershell.exe";
    }
}
