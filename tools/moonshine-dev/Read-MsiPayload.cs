// SPDX-License-Identifier: GPL-3.0-only
// Read-only Windows Installer database access. Never installs or executes an MSI.
using System;
using System.IO;
using System.Text;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public sealed class MoonshineMsiReader : IDisposable {
    uint database;
    [DllImport("msi.dll",CharSet=CharSet.Unicode,ExactSpelling=true)] static extern uint MsiOpenDatabaseW(string path,IntPtr mode,out uint handle);
    [DllImport("msi.dll",CharSet=CharSet.Unicode,ExactSpelling=true)] static extern uint MsiDatabaseOpenViewW(uint db,string query,out uint view);
    [DllImport("msi.dll")] static extern uint MsiViewExecute(uint view,uint record);
    [DllImport("msi.dll")] static extern uint MsiViewFetch(uint view,out uint record);
    [DllImport("msi.dll")] static extern uint MsiCloseHandle(uint handle);
    [DllImport("msi.dll",CharSet=CharSet.Unicode,ExactSpelling=true)] static extern uint MsiRecordGetStringW(uint record,uint field,StringBuilder text,ref uint count);
    [DllImport("msi.dll")] static extern uint MsiRecordReadStream(uint record,uint field,byte[] bytes,ref uint count);
    static void Check(uint result) { if(result!=0)throw new IOException("Read-only MSI API error "+result); }
    public MoonshineMsiReader(string path) { Check(MsiOpenDatabaseW(Path.GetFullPath(path),IntPtr.Zero,out database)); }
    static string Value(uint record,uint field) {
        uint count=0;uint code=MsiRecordGetStringW(record,field,null,ref count);
        if(code!=0&&code!=234)Check(code);
        count++;var value=new StringBuilder((int)count);Check(MsiRecordGetStringW(record,field,value,ref count));return value.ToString();
    }
    public string[][] Query(string query,int columns) {
        uint view;Check(MsiDatabaseOpenViewW(database,query,out view));
        try {
            Check(MsiViewExecute(view,0));var rows=new List<string[]>();uint record;
            while(true) {
                uint code=MsiViewFetch(view,out record);if(code==259)break;Check(code);
                try {var row=new string[columns];for(int i=0;i<columns;i++)row[i]=Value(record,(uint)i+1);rows.Add(row);}finally{MsiCloseHandle(record);}
            }
            return rows.ToArray();
        } finally {MsiCloseHandle(view);}
    }
    public void ExtractStream(string name,string destination) {
        uint view;Check(MsiDatabaseOpenViewW(database,"SELECT `Data` FROM `_Streams` WHERE `Name`='"+name.Replace("'","''")+"'",out view));
        try {
            Check(MsiViewExecute(view,0));uint record;Check(MsiViewFetch(view,out record));
            try {
                using(var output=new FileStream(destination,FileMode.CreateNew,FileAccess.Write,FileShare.None)) {
                    byte[] bytes=new byte[65536];long total=0;
                    while(true){uint count=(uint)bytes.Length;Check(MsiRecordReadStream(record,1,bytes,ref count));if(count==0)break;total+=count;if(total>268435456)throw new IOException("Oversized MSI stream");output.Write(bytes,0,(int)count);}
                }
            }finally{MsiCloseHandle(record);}
        } finally {MsiCloseHandle(view);}
    }
    public void Dispose(){if(database!=0){MsiCloseHandle(database);database=0;}}
}
