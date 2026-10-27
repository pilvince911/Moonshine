using System;
using System.Diagnostics;
using System.Security;
public static class MoonshineTestUserProcess {
    // CI-only: launch with a genuine standard test account. Credentials use
    // Windows logon APIs through ProcessStartInfo, never command-line arguments.
    public static Process Start(string command,string directory,string user,SecureString password) {
        if(command.Length<3 || command[0]!='"')throw new ArgumentException("Quoted executable required.");
        var end=command.IndexOf('"',1);if(end<0)throw new ArgumentException("Invalid executable.");
        var info=new ProcessStartInfo();info.FileName=command.Substring(1,end-1);info.Arguments=command.Substring(end+1).TrimStart();
        info.WorkingDirectory=directory;info.UseShellExecute=false;info.CreateNoWindow=true;
        info.UserName=user;info.Domain=Environment.MachineName;info.Password=password;info.LoadUserProfile=true;
        return Process.Start(info);
    }
}
