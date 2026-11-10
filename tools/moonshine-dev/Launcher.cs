// SPDX-License-Identifier: GPL-3.0-only
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Text;
using System.Windows.Forms;

[assembly: AssemblyTitle("Moonshine")]
[assembly: AssemblyDescription("Moonshine graphical launcher")]
[assembly: AssemblyVersion("1.0.1.0")]
[assembly: AssemblyFileVersion("1.0.1.0")]
[assembly: AssemblyInformationalVersion("1.0.1-rc.1")]

internal static class MoonshineLauncher
{
    // ProcessStartInfo on .NET Framework takes one Windows command line.
    private static string QuoteArgument(string value)
    {
        var quoted = new StringBuilder("\"");
        int backslashes = 0;
        foreach (char character in value)
        {
            if (character == '\\')
            {
                backslashes++;
                continue;
            }
            quoted.Append('\\', character == '"' ? backslashes * 2 + 1 : backslashes);
            quoted.Append(character);
            backslashes = 0;
        }
        quoted.Append('\\', backslashes * 2);
        return quoted.Append('"').ToString();
    }

    [STAThread]
    private static int Main(string[] arguments)
    {
        try
        {
            bool trayOnly = false;
            string trace = null;
            for (int index = 0; index < arguments.Length; index++)
            {
                if (arguments[index] == "-TrayOnly" && !trayOnly)
                {
                    trayOnly = true;
                }
                else if (arguments[index] == "-CITrace" && trace == null && index + 1 < arguments.Length &&
                         Environment.GetEnvironmentVariable("GITHUB_ACTIONS") == "true" &&
                         Environment.GetEnvironmentVariable("CI") == "true")
                {
                    trace = arguments[++index];
                }
                else
                {
                    throw new ArgumentException("Option de lancement Moonshine invalide.");
                }
            }

            string script = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "Gestion-Moonshine.ps1");
            if (!File.Exists(script))
            {
                throw new FileNotFoundException("Extraire le ZIP Moonshine au complet avant de l'ouvrir.");
            }
            string system = Environment.GetFolderPath(Environment.SpecialFolder.System);
            var command = new List<string> {
                "-NoLogo", "-NoProfile", "-STA", "-WindowStyle", "Hidden",
                "-ExecutionPolicy", "Bypass", "-File", script
            };
            if (trayOnly)
            {
                command.Add("-TrayOnly");
            }
            if (trace != null)
            {
                command.Add("-CITrace");
                command.Add(trace);
            }
            var start = new ProcessStartInfo {
                FileName = Path.Combine(system, @"WindowsPowerShell\v1.0\powershell.exe"),
                Arguments = string.Join(" ", command.ConvertAll(QuoteArgument).ToArray()),
                WorkingDirectory = Environment.GetFolderPath(Environment.SpecialFolder.Windows),
                UseShellExecute = false,
                CreateNoWindow = true,
                WindowStyle = ProcessWindowStyle.Hidden
            };
            // Release the executable immediately so setup can archive its directory.
            using (Process child = Process.Start(start))
            {
                if (child == null)
                {
                    throw new InvalidOperationException("Le gestionnaire Moonshine n'a pas demarre.");
                }
            }
            return 0;
        }
        catch (Exception error)
        {
            MessageBox.Show(error.Message, "Moonshine", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 1;
        }
    }
}
