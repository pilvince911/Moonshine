using System;
using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;
public static class MoonshineRestrictedProcess {
    [StructLayout(LayoutKind.Sequential)] struct SidAndAttributes { public IntPtr Sid; public uint Attributes; }
    [StructLayout(LayoutKind.Sequential,CharSet=CharSet.Unicode)] struct StartupInfo {
        public int cb; public string reserved,desktop,title; public uint x,y,xSize,ySize,xCount,yCount,fill,flags; public short show,reserved2; public IntPtr reservedPtr,input,output,error;
    }
    [StructLayout(LayoutKind.Sequential)] struct ProcessInfo { public IntPtr process,thread; public int processId,threadId; }
    [DllImport("advapi32.dll",SetLastError=true)] static extern bool OpenProcessToken(IntPtr process,uint access,out IntPtr token);
    [DllImport("advapi32.dll",SetLastError=true)] static extern bool CreateRestrictedToken(IntPtr token,uint flags,uint disableCount,[In] SidAndAttributes[] disabled,uint deleteCount,IntPtr deleted,uint restrictCount,IntPtr restricted,out IntPtr result);
    [DllImport("advapi32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool ConvertStringSidToSid(string sid,out IntPtr result);
    [DllImport("advapi32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool CreateProcessAsUser(IntPtr token,string application,System.Text.StringBuilder command,IntPtr processSecurity,IntPtr threadSecurity,bool inherit,uint flags,IntPtr environment,string directory,ref StartupInfo startup,out ProcessInfo info);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
    [DllImport("kernel32.dll")] static extern IntPtr LocalFree(IntPtr handle);
    public static Process Start(string command,string directory) {
        IntPtr token=IntPtr.Zero,restricted=IntPtr.Zero,admin=IntPtr.Zero;
        try {
            if (!OpenProcessToken(Process.GetCurrentProcess().Handle,0xF01FF,out token)) throw new Win32Exception();
            if (!ConvertStringSidToSid("S-1-5-32-544",out admin)) throw new Win32Exception();
            var disabled=new SidAndAttributes[]{new SidAndAttributes{Sid=admin,Attributes=0}};
            if (!CreateRestrictedToken(token,1,1,disabled,0,IntPtr.Zero,0,IntPtr.Zero,out restricted)) throw new Win32Exception();
            var startup=new StartupInfo();startup.cb=Marshal.SizeOf(typeof(StartupInfo));ProcessInfo info;
            if (!CreateProcessAsUser(restricted,null,new System.Text.StringBuilder(command),IntPtr.Zero,IntPtr.Zero,false,0x08000000,IntPtr.Zero,directory,ref startup,out info)) throw new Win32Exception();
            try {return Process.GetProcessById(info.processId);} finally {CloseHandle(info.thread);CloseHandle(info.process);}
        } finally {if(admin!=IntPtr.Zero)LocalFree(admin);if(restricted!=IntPtr.Zero)CloseHandle(restricted);if(token!=IntPtr.Zero)CloseHandle(token);}
    }
}
