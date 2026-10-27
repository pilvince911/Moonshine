using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Security;
using System.Text;
public static class MoonshineTestUserProcess {
    [StructLayout(LayoutKind.Sequential,CharSet=CharSet.Unicode)] struct StartupInfo {
        public int cb; public string reserved,desktop,title; public uint x,y,xSize,ySize,xCount,yCount,fill,flags;
        public short show,reserved2; public IntPtr reservedPtr,input,output,error;
    }
    [StructLayout(LayoutKind.Sequential)] struct ProcessInfo { public IntPtr process,thread; public int processId,threadId; }
    [DllImport("advapi32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool CreateProcessWithLogonW(string user,string domain,IntPtr password,uint logonFlags,string application,StringBuilder command,uint creationFlags,IntPtr environment,string directory,ref StartupInfo startup,out ProcessInfo process);
    [DllImport("kernel32.dll",SetLastError=true)] static extern uint WaitForSingleObject(IntPtr process,uint milliseconds);
    [DllImport("kernel32.dll",SetLastError=true)] static extern bool GetExitCodeProcess(IntPtr process,out uint code);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
    public sealed class Child : IDisposable {
        IntPtr process;public int Id {get;private set;}
        internal Child(IntPtr process,int id){this.process=process;Id=id;}
        public bool WaitForExit(int milliseconds){var state=WaitForSingleObject(process,(uint)milliseconds);if(state==0xffffffff)throw new Win32Exception();return state==0;}
        public bool HasExited {get{return WaitForExit(0);}}
        public int ExitCode {get{uint code;if(!GetExitCodeProcess(process,out code))throw new Win32Exception();return unchecked((int)code);}}
        public void Dispose(){if(process!=IntPtr.Zero){CloseHandle(process);process=IntPtr.Zero;}}
    }
    // CI-only. No inherited CI-agent handles or CREATE_NO_WINDOW flag are
    // forwarded to the separate logon. Windows supplies the user's environment.
    public static Child Start(string command,string directory,string user,SecureString password) {
        if(command.Length<3 || command[0]!='"')throw new ArgumentException("Quoted executable required.");
        var end=command.IndexOf('"',1);if(end<0)throw new ArgumentException("Invalid executable.");
        var startup=new StartupInfo();startup.cb=Marshal.SizeOf(typeof(StartupInfo));startup.flags=1;startup.show=0;
        var secret=Marshal.SecureStringToGlobalAllocUnicode(password);
        try {
            ProcessInfo info;
            if(!CreateProcessWithLogonW(user,Environment.MachineName,secret,1,command.Substring(1,end-1),new StringBuilder(command),0x400,IntPtr.Zero,directory,ref startup,out info))throw new Win32Exception();
            CloseHandle(info.thread);return new Child(info.process,info.processId);
        } finally {Marshal.ZeroFreeGlobalAllocUnicode(secret);}
    }
}
