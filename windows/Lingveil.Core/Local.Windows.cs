using System.Diagnostics;
using System.Runtime.InteropServices;

namespace Lingveil.Core;

/// A Job object that ends every process in it when this app exits, crashes or is killed.
public static class Job
{
    static readonly IntPtr handle = Create();

    public static void Add(Process p) => AssignProcessToJobObject(handle, p.Handle);

    static IntPtr Create()
    {
        var h = CreateJobObject(IntPtr.Zero, null);
        var info = new JOBOBJECT_EXTENDED_LIMIT_INFORMATION { BasicLimitInformation = { LimitFlags = 0x2000 } };   // KILL_ON_JOB_CLOSE
        int size = Marshal.SizeOf(info);
        var ptr = Marshal.AllocHGlobal(size);
        Marshal.StructureToPtr(info, ptr, false);
        SetInformationJobObject(h, 9, ptr, (uint)size);   // JobObjectExtendedLimitInformation
        Marshal.FreeHGlobal(ptr);
        return h;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct JOBOBJECT_BASIC_LIMIT_INFORMATION
    {
        public long PerProcessUserTimeLimit, PerJobUserTimeLimit;
        public uint LimitFlags;
        public UIntPtr MinimumWorkingSetSize, MaximumWorkingSetSize;
        public uint ActiveProcessLimit;
        public UIntPtr Affinity;
        public uint PriorityClass, SchedulingClass;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct IO_COUNTERS { public ulong A, B, C, D, E, F; }

    [StructLayout(LayoutKind.Sequential)]
    struct JOBOBJECT_EXTENDED_LIMIT_INFORMATION
    {
        public JOBOBJECT_BASIC_LIMIT_INFORMATION BasicLimitInformation;
        public IO_COUNTERS IoInfo;
        public UIntPtr ProcessMemoryLimit, JobMemoryLimit, PeakProcessMemoryUsed, PeakJobMemoryUsed;
    }

    [DllImport("kernel32", SetLastError = true, CharSet = CharSet.Unicode)] static extern IntPtr CreateJobObject(IntPtr a, string? name);
    [DllImport("kernel32", SetLastError = true)] static extern bool SetInformationJobObject(IntPtr job, int cls, IntPtr info, uint len);
    [DllImport("kernel32", SetLastError = true)] static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);
}

public static class Memory
{
    [StructLayout(LayoutKind.Sequential)]
    struct MEMORYSTATUSEX { public uint Length, Load; public ulong TotalPhys, AvailPhys, TotalPage, AvailPage, TotalVirtual, AvailVirtual, AvailExtended; }
    [DllImport("kernel32")] static extern bool GlobalMemoryStatusEx(ref MEMORYSTATUSEX m);

    public static long AvailableMB { get { var m = new MEMORYSTATUSEX { Length = 64 }; GlobalMemoryStatusEx(ref m); return (long)(m.AvailPhys >> 20); } }
    public static int TotalGB { get { var m = new MEMORYSTATUSEX { Length = 64 }; GlobalMemoryStatusEx(ref m); return (int)Math.Round(m.TotalPhys / 1073741824.0); } }

    /// Captures pass through megabytes of buffers; once a translation closes, compact the
    /// heap and trim the working set so the idle app stays small.
    public static void Relieve() => Task.Delay(500).ContinueWith(_ =>
    {
        System.Runtime.GCSettings.LargeObjectHeapCompactionMode = System.Runtime.GCLargeObjectHeapCompactionMode.CompactOnce;
        GC.Collect(2, GCCollectionMode.Forced, true, true);
        SetProcessWorkingSetSize(Process.GetCurrentProcess().Handle, -1, -1);
    });

    [DllImport("kernel32")] static extern bool SetProcessWorkingSetSize(IntPtr p, nint min, nint max);
}
