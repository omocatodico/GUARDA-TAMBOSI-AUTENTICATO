using System;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Linq;

internal static class Program
{
    private static int Main(string[] args)
    {
        var exitCode = 0;

        try
        {
            var exePath = Process.GetCurrentProcess().MainModule.FileName;
            var baseDir = Path.GetDirectoryName(exePath) ?? Environment.CurrentDirectory;
            var runScript = Path.Combine(baseDir, "stop-all.ps1");

            if (!File.Exists(runScript))
            {
                Console.Error.WriteLine("stop-all.ps1 non trovato nella stessa cartella dell'exe.");
                Console.Error.WriteLine("Percorso atteso: " + runScript);
                exitCode = 2;
                return exitCode;
            }

            var extraArgs = string.Join(" ", args.Select(Quote));
            var psArgs = "-NoProfile -ExecutionPolicy Bypass -File " + Quote(runScript);
            if (!string.IsNullOrWhiteSpace(extraArgs))
            {
                psArgs += " " + extraArgs;
            }

            var psi = new ProcessStartInfo
            {
                FileName = "powershell.exe",
                Arguments = psArgs,
                UseShellExecute = true,
                Verb = "runas",
                WorkingDirectory = baseDir
            };

            Process.Start(psi);
            Console.WriteLine("Comando di stop avviato in una nuova finestra PowerShell elevata.");
            Console.WriteLine("Script: " + runScript);
            exitCode = 0;
            return exitCode;
        }
        catch (Win32Exception ex)
        {
            if (ex.NativeErrorCode == 1223)
            {
                Console.Error.WriteLine("Elevazione annullata dall'utente.");
                exitCode = 3;
                return exitCode;
            }

            Console.Error.WriteLine("Errore avvio: " + ex.Message);
            exitCode = 1;
            return exitCode;
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine("Errore avvio: " + ex.Message);
            exitCode = 1;
            return exitCode;
        }
    }

    private static string Quote(string value)
    {
        if (string.IsNullOrEmpty(value))
        {
            return "\"\"";
        }

        return "\"" + value.Replace("\"", "\\\"") + "\"";
    }
}
