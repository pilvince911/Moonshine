using System;
using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Security.Principal;
public static class MoonshineRestrictedProcess {
    [StructLayout(LayoutKind.Sequential)] struct SidAndAttributes { public IntPtr Sid; public uint Attributes; }
    [StructLayout(LayoutKind.Sequential,CharSet=CharSet.Unicode)] struct StartupInfo {
        public int cb; public string reserved,desktop,title; public uint x,y,xSize,ySize,xCount,yCount,fill,flags; public short show,reserved2; public IntPtr reservedPtr,input,output,error;
    }
    [StructLayout(LayoutKind.Sequential)] struct ProcessInfo { public IntPtr process,thread; public int processId,threadId; }
    [StructLayout(LayoutKind.Sequential)] struct SecurityAttributes { public int length; public IntPtr descriptor; public bool inherit; }
    [DllImport("advapi32.dll",SetLastError=true)] static extern bool OpenProcessToken(IntPtr process,uint access,out IntPtr token);
    [DllImport("advapi32.dll",SetLastError=true)] static extern bool CreateRestrictedToken(IntPtr token,uint flags,uint disableCount,[In] SidAndAttributes[] disabled,uint deleteCount,IntPtr deleted,uint restrictCount,IntPtr restricted,out IntPtr result);
    [DllImport("advapi32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool ConvertStringSidToSid(string sid,out IntPtr result);
    [DllImport("advapi32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool ConvertStringSecurityDescriptorToSecurityDescriptor(string text,uint revision,out IntPtr result,out uint size);
    [DllImport("advapi32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool CreateProcessAsUser(IntPtr token,string application,System.Text.StringBuilder command,IntPtr processSecurity,IntPtr threadSecurity,bool inherit,uint flags,IntPtr environment,string directory,ref StartupInfo startup,out ProcessInfo info);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
    [DllImport("kernel32.dll")] static extern IntPtr LocalFree(IntPtr handle);
    [DllImport("kernel32.dll",SetLastError=true)] static extern uint WaitForSingleObject(IntPtr handle,uint milliseconds);
    [DllImport("kernel32.dll",SetLastError=true)] static extern bool GetExitCodeProcess(IntPtr handle,out uint code);
    [DllImport("user32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern IntPtr CreateWindowStation(string name,uint flags,uint access,ref SecurityAttributes security);
    [DllImport("user32.dll",SetLastError=true)] static extern IntPtr GetProcessWindowStation();
    [DllImport("user32.dll",SetLastError=true)] static extern bool SetProcessWindowStation(IntPtr station);
    [DllImport("user32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern IntPtr CreateDesktop(string name,IntPtr device,IntPtr mode,uint flags,uint access,ref SecurityAttributes security);
    [DllImport("user32.dll",SetLastError=true)] static extern bool CloseDesktop(IntPtr desktop);
    [DllImport("user32.dll",SetLastError=true)] static extern bool CloseWindowStation(IntPtr station);
    public sealed class Child : IDisposable {
        IntPtr process,station,desktop;
        public int Id {get;private set;}
        internal Child(IntPtr process,int id,IntPtr station,IntPtr desktop) {this.process=process;Id=id;this.station=station;this.desktop=desktop;}
        public bool WaitForExit(int milliseconds) {
            var state=WaitForSingleObject(process,(uint)milliseconds);
            if(state==0xffffffff)throw new Win32Exception();return state==0;
        }
        public bool HasExited {get{return WaitForExit(0);}}
        public int ExitCode {get{uint code;if(!GetExitCodeProcess(process,out code))throw new Win32Exception();return unchecked((int)code);}}
        public void Dispose() {
            if(process!=IntPtr.Zero){CloseHandle(process);process=IntPtr.Zero;}
            if(desktop!=IntPtr.Zero){CloseDesktop(desktop);desktop=IntPtr.Zero;}
            if(station!=IntPtr.Zero){CloseWindowStation(station);station=IntPtr.Zero;}
        }
    }
    public static Child Start(string command,string directory) {
        IntPtr token=IntPtr.Zero,restricted=IntPtr.Zero,admin=IntPtr.Zero,security=IntPtr.Zero,station=IntPtr.Zero,desktop=IntPtr.Zero;
        try {
            if (!OpenProcessToken(Process.GetCurrentProcess().Handle,0xF01FF,out token)) throw new Win32Exception();
            if (!ConvertStringSidToSid("S-1-5-32-544",out admin)) throw new Win32Exception();
            var disabled=new SidAndAttributes[]{new SidAndAttributes{Sid=admin,Attributes=0}};
            if (!CreateRestrictedToken(token,1,1,disabled,0,IntPtr.Zero,0,IntPtr.Zero,out restricted)) throw new Win32Exception();
            // The CI agent's existing desktop may grant access only via the
            // Administrators group. Use a private desktop for this test user;
            // never change the security of an existing station or desktop.
            uint size;var sid=WindowsIdentity.GetCurrent().User.Value;
            if(!ConvertStringSecurityDescriptorToSecurityDescriptor("D:P(A;;GA;;;SY)(A;;GA;;;"+sid+")",1,out security,out size))throw new Win32Exception();
            var attributes=new SecurityAttributes();attributes.length=Marshal.SizeOf(typeof(SecurityAttributes));attributes.descriptor=security;
            var name="MoonshineCI"+Guid.NewGuid().ToString("N");
            station=CreateWindowStation(name,1,0xF037F,ref attributes);if(station==IntPtr.Zero)throw new Win32Exception();
            var previous=GetProcessWindowStation();if(previous==IntPtr.Zero)throw new Win32Exception();
            if(!SetProcessWindowStation(station))throw new Win32Exception();
            try {desktop=CreateDesktop("Default",IntPtr.Zero,IntPtr.Zero,0,0xF01FF,ref attributes);if(desktop==IntPtr.Zero)throw new Win32Exception();}
            finally {if(!SetProcessWindowStation(previous))throw new Win32Exception();}
            var startup=new StartupInfo();startup.cb=Marshal.SizeOf(typeof(StartupInfo));startup.desktop=name+"\\Default";ProcessInfo info;
            if (!CreateProcessAsUser(restricted,null,new System.Text.StringBuilder(command),IntPtr.Zero,IntPtr.Zero,false,0x08000000,IntPtr.Zero,directory,ref startup,out info)) throw new Win32Exception();
            CloseHandle(info.thread);
            var child=new Child(info.process,info.processId,station,desktop);station=IntPtr.Zero;desktop=IntPtr.Zero;return child;
        } finally {
            if(desktop!=IntPtr.Zero)CloseDesktop(desktop);if(station!=IntPtr.Zero)CloseWindowStation(station);
            if(security!=IntPtr.Zero)LocalFree(security);if(admin!=IntPtr.Zero)LocalFree(admin);
            if(restricted!=IntPtr.Zero)CloseHandle(restricted);if(token!=IntPtr.Zero)CloseHandle(token);
        }
    }
}
