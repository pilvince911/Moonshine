using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Security;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Text;
public static class MoonshineTestUserProcess {
    [StructLayout(LayoutKind.Sequential,CharSet=CharSet.Unicode)] struct StartupInfo {
        public int cb; public string reserved,desktop,title; public uint x,y,xSize,ySize,xCount,yCount,fill,flags;
        public short show,reserved2; public IntPtr reservedPtr,input,output,error;
    }
    [StructLayout(LayoutKind.Sequential)] struct ProcessInfo { public IntPtr process,thread; public int processId,threadId; }
    [DllImport("advapi32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool CreateProcessWithLogonW(string user,string domain,IntPtr password,uint logonFlags,string application,StringBuilder command,uint creationFlags,IntPtr environment,string directory,ref StartupInfo startup,out ProcessInfo process);
    [DllImport("user32.dll")] static extern IntPtr GetProcessWindowStation();
    [DllImport("user32.dll")] static extern IntPtr GetThreadDesktop(uint id);
    [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();
    [DllImport("user32.dll",SetLastError=true)] static extern bool GetUserObjectSecurity(IntPtr handle,ref uint requested,byte[] buffer,uint length,out uint needed);
    [DllImport("user32.dll",SetLastError=true)] static extern bool SetUserObjectSecurity(IntPtr handle,ref uint requested,byte[] buffer);
    [DllImport("kernel32.dll",SetLastError=true)] static extern uint WaitForSingleObject(IntPtr process,uint milliseconds);
    [DllImport("kernel32.dll",SetLastError=true)] static extern bool GetExitCodeProcess(IntPtr process,out uint code);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
    internal sealed class DesktopAccess : IDisposable {
        IntPtr station,desktop;byte[] stationBefore,desktopBefore;
        static byte[] Grant(IntPtr handle,SecurityIdentifier sid,int mask) {
            if(handle==IntPtr.Zero)throw new Win32Exception();
            uint requested=4,needed;
            GetUserObjectSecurity(handle,ref requested,null,0,out needed);
            if(needed==0)throw new Win32Exception();
            var before=new byte[needed];
            if(!GetUserObjectSecurity(handle,ref requested,before,needed,out needed))throw new Win32Exception();
            var descriptor=new RawSecurityDescriptor(before,0);
            if(descriptor.DiscretionaryAcl==null)throw new InvalidOperationException("CI desktop has no explicit DACL.");
            descriptor.DiscretionaryAcl.InsertAce(descriptor.DiscretionaryAcl.Count,new CommonAce(AceFlags.None,AceQualifier.AccessAllowed,mask,sid,false,null));
            var after=new byte[descriptor.BinaryLength];descriptor.GetBinaryForm(after,0);
            if(!SetUserObjectSecurity(handle,ref requested,after))throw new Win32Exception();
            return before;
        }
        public DesktopAccess(SecurityIdentifier sid) {
            station=GetProcessWindowStation();desktop=GetThreadDesktop(GetCurrentThreadId());
            try { stationBefore=Grant(station,sid,0x000f037f);desktopBefore=Grant(desktop,sid,0x000f01ff); }
            catch { Dispose();throw; }
        }
        public void Dispose() {uint requested=4;if(desktopBefore!=null){SetUserObjectSecurity(desktop,ref requested,desktopBefore);desktopBefore=null;}if(stationBefore!=null){SetUserObjectSecurity(station,ref requested,stationBefore);stationBefore=null;}}
    }
    public sealed class Child : IDisposable {
        IntPtr process;DesktopAccess access;public int Id {get;private set;}
        internal Child(IntPtr process,int id,DesktopAccess access){this.process=process;Id=id;this.access=access;}
        public bool WaitForExit(int milliseconds){var state=WaitForSingleObject(process,(uint)milliseconds);if(state==0xffffffff)throw new Win32Exception();return state==0;}
        public bool HasExited {get{return WaitForExit(0);}}
        public int ExitCode {get{uint code;if(!GetExitCodeProcess(process,out code))throw new Win32Exception();return unchecked((int)code);}}
        public void Dispose(){if(process!=IntPtr.Zero){if(HasExited && access!=null){access.Dispose();access=null;}CloseHandle(process);process=IntPtr.Zero;}}
    }
    // CI only: temporarily grant the generated standard account access to this
    // process's desktop, then restore the exact descriptors when its child exits.
    // No inherited handles, command-line credentials, or production accounts.
    public static Child Start(string command,string directory,string user,SecureString password) {
        if(Environment.GetEnvironmentVariable("GITHUB_ACTIONS")!="true")throw new InvalidOperationException("Disposable CI machines only.");
        if(command.Length>=1024)throw new ArgumentException("The CI logon command must be shorter than 1024 characters; use a script file.");
        if(command.Length<3 || command[0]!='"')throw new ArgumentException("Quoted executable required.");
        var end=command.IndexOf('"',1);if(end<0)throw new ArgumentException("Invalid executable.");
        var sid=(SecurityIdentifier)new NTAccount(Environment.MachineName,user).Translate(typeof(SecurityIdentifier));
        var access=new DesktopAccess(sid);var secret=Marshal.SecureStringToGlobalAllocUnicode(password);
        try {
            var startup=new StartupInfo();startup.cb=Marshal.SizeOf(typeof(StartupInfo));startup.flags=1;startup.show=0;ProcessInfo info;
            if(!CreateProcessWithLogonW(user,Environment.MachineName,secret,1,command.Substring(1,end-1),new StringBuilder(command),0x400,IntPtr.Zero,directory,ref startup,out info)){var code=Marshal.GetLastWin32Error();throw new Win32Exception(code,"CI CreateProcessWithLogonW failed: "+code);}
            CloseHandle(info.thread);var result=new Child(info.process,info.processId,access);access=null;return result;
        } finally {if(access!=null)access.Dispose();Marshal.ZeroFreeGlobalAllocUnicode(secret);}
    }
}
