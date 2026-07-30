using System;
using System.ComponentModel;
using System.IO;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.Win32.SafeHandles;

namespace Casein
{
    public static class ConPtyBridge
    {
        private const uint EXTENDED_STARTUPINFO_PRESENT = 0x00080000;
        private const uint CREATE_SUSPENDED = 0x00000004;
        private const int STARTF_USESTDHANDLES = 0x00000100;
        private const int PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE = 0x00020016;
        private const int PROC_THREAD_ATTRIBUTE_JOB_LIST = 0x0002000D;
        private const int JobObjectExtendedLimitInformation = 9;
        private const int JobObjectBasicAccountingInformation = 1;
        private const uint JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE = 0x00002000;

        [StructLayout(LayoutKind.Sequential)]
        private struct COORD
        {
            public short X;
            public short Y;

            public COORD(short x, short y)
            {
                X = x;
                Y = y;
            }
        }

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct STARTUPINFO
        {
            public int cb;
            public string lpReserved;
            public string lpDesktop;
            public string lpTitle;
            public int dwX;
            public int dwY;
            public int dwXSize;
            public int dwYSize;
            public int dwXCountChars;
            public int dwYCountChars;
            public int dwFillAttribute;
            public int dwFlags;
            public short wShowWindow;
            public short cbReserved2;
            public IntPtr lpReserved2;
            public IntPtr hStdInput;
            public IntPtr hStdOutput;
            public IntPtr hStdError;
        }

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct STARTUPINFOEX
        {
            public STARTUPINFO StartupInfo;
            public IntPtr lpAttributeList;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct PROCESS_INFORMATION
        {
            public IntPtr hProcess;
            public IntPtr hThread;
            public uint dwProcessId;
            public uint dwThreadId;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct SECURITY_ATTRIBUTES
        {
            public int nLength;
            public IntPtr lpSecurityDescriptor;
            public int bInheritHandle;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct JOBOBJECT_BASIC_LIMIT_INFORMATION
        {
            public long PerProcessUserTimeLimit;
            public long PerJobUserTimeLimit;
            public uint LimitFlags;
            public UIntPtr MinimumWorkingSetSize;
            public UIntPtr MaximumWorkingSetSize;
            public uint ActiveProcessLimit;
            public UIntPtr Affinity;
            public uint PriorityClass;
            public uint SchedulingClass;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct JOBOBJECT_BASIC_ACCOUNTING_INFORMATION
        {
            public long TotalUserTime;
            public long TotalKernelTime;
            public long ThisPeriodTotalUserTime;
            public long ThisPeriodTotalKernelTime;
            public uint TotalPageFaultCount;
            public uint TotalProcesses;
            public uint ActiveProcesses;
            public uint TotalTerminatedProcesses;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct IO_COUNTERS
        {
            public ulong ReadOperationCount;
            public ulong WriteOperationCount;
            public ulong OtherOperationCount;
            public ulong ReadTransferCount;
            public ulong WriteTransferCount;
            public ulong OtherTransferCount;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct JOBOBJECT_EXTENDED_LIMIT_INFORMATION
        {
            public JOBOBJECT_BASIC_LIMIT_INFORMATION BasicLimitInformation;
            public IO_COUNTERS IoInfo;
            public UIntPtr ProcessMemoryLimit;
            public UIntPtr JobMemoryLimit;
            public UIntPtr PeakProcessMemoryUsed;
            public UIntPtr PeakJobMemoryUsed;
        }

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool CreatePipe(
            out SafeFileHandle hReadPipe,
            out SafeFileHandle hWritePipe,
            IntPtr lpPipeAttributes,
            uint nSize);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern int CreatePseudoConsole(
            COORD size,
            SafeFileHandle hInput,
            SafeFileHandle hOutput,
            uint dwFlags,
            out IntPtr phPC);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern int ResizePseudoConsole(IntPtr hPC, COORD size);

        [DllImport("kernel32.dll")]
        private static extern void ClosePseudoConsole(IntPtr hPC);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool InitializeProcThreadAttributeList(
            IntPtr lpAttributeList,
            int dwAttributeCount,
            int dwFlags,
            ref IntPtr lpSize);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool UpdateProcThreadAttribute(
            IntPtr lpAttributeList,
            uint dwFlags,
            IntPtr attribute,
            IntPtr lpValue,
            IntPtr cbSize,
            IntPtr lpPreviousValue,
            IntPtr lpReturnSize);

        [DllImport("kernel32.dll")]
        private static extern void DeleteProcThreadAttributeList(IntPtr lpAttributeList);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool CreateProcess(
            string lpApplicationName,
            string lpCommandLine,
            ref SECURITY_ATTRIBUTES lpProcessAttributes,
            ref SECURITY_ATTRIBUTES lpThreadAttributes,
            bool bInheritHandles,
            uint dwCreationFlags,
            IntPtr lpEnvironment,
            string lpCurrentDirectory,
            [In] ref STARTUPINFOEX lpStartupInfo,
            out PROCESS_INFORMATION lpProcessInformation);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern IntPtr CreateJobObject(IntPtr lpJobAttributes, string lpName);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool SetInformationJobObject(
            IntPtr hJob,
            int JobObjectInformationClass,
            IntPtr lpJobObjectInformation,
            uint cbJobObjectInformationLength);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool TerminateJobObject(IntPtr hJob, uint uExitCode);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool QueryInformationJobObject(
            IntPtr hJob,
            int JobObjectInformationClass,
            IntPtr lpJobObjectInformation,
            uint cbJobObjectInformationLength,
            IntPtr lpReturnLength);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern uint ResumeThread(IntPtr hThread);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern uint WaitForSingleObject(IntPtr hHandle, uint dwMilliseconds);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool GetExitCodeProcess(IntPtr hProcess, out uint lpExitCode);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool CloseHandle(IntPtr hObject);

        public static int Run(int dataPort, int controlPort, string bridgeToken, string commandLine, string workingDirectory, short cols, short rows)
        {
            SafeFileHandle inputRead = null;
            SafeFileHandle inputWrite = null;
            SafeFileHandle outputRead = null;
            SafeFileHandle outputWrite = null;
            IntPtr pseudoConsole = IntPtr.Zero;
            IntPtr attributeList = IntPtr.Zero;
            IntPtr job = IntPtr.Zero;
            IntPtr jobList = IntPtr.Zero;
            PROCESS_INFORMATION processInfo = new PROCESS_INFORMATION();

            try
            {
                Check(CreatePipe(out inputRead, out inputWrite, IntPtr.Zero, 0), "CreatePipe(input)");
                Check(CreatePipe(out outputRead, out outputWrite, IntPtr.Zero, 0), "CreatePipe(output)");

                CheckHResult(CreatePseudoConsole(new COORD(cols, rows), inputRead, outputWrite, 0, out pseudoConsole), "CreatePseudoConsole");
                inputRead.Dispose();
                inputRead = null;
                outputWrite.Dispose();
                outputWrite = null;

                job = CreateKillOnCloseJob();

                IntPtr attributeListSize = IntPtr.Zero;
                InitializeProcThreadAttributeList(IntPtr.Zero, 2, 0, ref attributeListSize);
                attributeList = Marshal.AllocHGlobal(attributeListSize);
                Check(InitializeProcThreadAttributeList(attributeList, 2, 0, ref attributeListSize), "InitializeProcThreadAttributeList");

                Check(
                    UpdateProcThreadAttribute(
                        attributeList,
                        0,
                        new IntPtr(PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE),
                        pseudoConsole,
                        new IntPtr(IntPtr.Size),
                        IntPtr.Zero,
                        IntPtr.Zero),
                    "UpdateProcThreadAttribute");

                jobList = Marshal.AllocHGlobal(IntPtr.Size);
                Marshal.WriteIntPtr(jobList, job);
                Check(
                    UpdateProcThreadAttribute(
                        attributeList,
                        0,
                        new IntPtr(PROC_THREAD_ATTRIBUTE_JOB_LIST),
                        jobList,
                        new IntPtr(IntPtr.Size),
                        IntPtr.Zero,
                        IntPtr.Zero),
                    "UpdateProcThreadAttribute(JobList)");

                STARTUPINFOEX startup = new STARTUPINFOEX();
                startup.StartupInfo.cb = Marshal.SizeOf(typeof(STARTUPINFOEX));
                startup.StartupInfo.dwFlags = STARTF_USESTDHANDLES;
                startup.lpAttributeList = attributeList;
                SECURITY_ATTRIBUTES processSecurity = new SECURITY_ATTRIBUTES();
                processSecurity.nLength = Marshal.SizeOf(typeof(SECURITY_ATTRIBUTES));
                SECURITY_ATTRIBUTES threadSecurity = new SECURITY_ATTRIBUTES();
                threadSecurity.nLength = Marshal.SizeOf(typeof(SECURITY_ATTRIBUTES));

                Check(
                    CreateProcess(
                        null,
                        commandLine,
                        ref processSecurity,
                        ref threadSecurity,
                        false,
                        EXTENDED_STARTUPINFO_PRESENT | CREATE_SUSPENDED,
                        IntPtr.Zero,
                        String.IsNullOrWhiteSpace(workingDirectory) ? null : workingDirectory,
                        ref startup,
                        out processInfo),
                    "CreateProcess");

                if (ResumeThread(processInfo.hThread) == UInt32.MaxValue)
                {
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "ResumeThread");
                }

                CloseHandle(processInfo.hThread);
                processInfo.hThread = IntPtr.Zero;

                using (TcpClient dataClient = new TcpClient())
                using (TcpClient controlClient = new TcpClient())
                {
                    dataClient.NoDelay = true;
                    controlClient.NoDelay = true;
                    dataClient.Connect("127.0.0.1", dataPort);
                    controlClient.Connect("127.0.0.1", controlPort);

                    using (NetworkStream network = dataClient.GetStream())
                    using (NetworkStream control = controlClient.GetStream())
                    using (FileStream input = new FileStream(inputWrite, FileAccess.Write))
                    using (FileStream output = new FileStream(outputRead, FileAccess.Read))
                    {
                        Authenticate(network, bridgeToken);
                        Authenticate(control, bridgeToken);
                        CancellationTokenSource cancellation = new CancellationTokenSource();
                        Task inputPump = Pump(network, input, cancellation.Token);
                        Task outputPump = Pump(output, network, cancellation.Token);
                        Task controlPump =
                            RunControlLoop(control, pseudoConsole, job, cancellation.Token);

                        while (WaitForSingleObject(processInfo.hProcess, 50) == 0x00000102)
                        {
                            if (controlPump.IsCompleted || inputPump.IsFaulted || outputPump.IsFaulted)
                            {
                                break;
                            }
                        }

                        cancellation.Cancel();
                        // A control disconnect means the owning BEAM session is
                        // gone. Terminate synchronously instead of relying only
                        // on handle teardown so close/1 does not return while a
                        // descendant remains alive.
                        if (WaitForSingleObject(processInfo.hProcess, 0) == 0x00000102)
                        {
                            Check(TerminateJobObject(job, 1), "TerminateJobObject");
                        }
                        if (pseudoConsole != IntPtr.Zero)
                        {
                            ClosePseudoConsole(pseudoConsole);
                            pseudoConsole = IntPtr.Zero;
                        }
                        try { Task.WaitAll(new Task[] { inputPump, outputPump, controlPump }, 1000); }
                        catch (AggregateException) { }
                    }
                }

                uint exitCode;
                return GetExitCodeProcess(processInfo.hProcess, out exitCode) ? unchecked((int)exitCode) : 1;
            }
            finally
            {
                if (processInfo.hThread != IntPtr.Zero) CloseHandle(processInfo.hThread);
                if (processInfo.hProcess != IntPtr.Zero) CloseHandle(processInfo.hProcess);
                if (job != IntPtr.Zero) CloseHandle(job);
                if (jobList != IntPtr.Zero) Marshal.FreeHGlobal(jobList);
                if (attributeList != IntPtr.Zero)
                {
                    DeleteProcThreadAttributeList(attributeList);
                    Marshal.FreeHGlobal(attributeList);
                }
                if (pseudoConsole != IntPtr.Zero) ClosePseudoConsole(pseudoConsole);
                if (inputRead != null) inputRead.Dispose();
                if (inputWrite != null) inputWrite.Dispose();
                if (outputRead != null) outputRead.Dispose();
                if (outputWrite != null) outputWrite.Dispose();
            }
        }

        private static IntPtr CreateKillOnCloseJob()
        {
            IntPtr job = CreateJobObject(IntPtr.Zero, null);
            if (job == IntPtr.Zero)
            {
                throw new Win32Exception(Marshal.GetLastWin32Error(), "CreateJobObject");
            }

            int size = Marshal.SizeOf(typeof(JOBOBJECT_EXTENDED_LIMIT_INFORMATION));
            IntPtr limitsPointer = Marshal.AllocHGlobal(size);

            try
            {
                JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits =
                    new JOBOBJECT_EXTENDED_LIMIT_INFORMATION();
                limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
                Marshal.StructureToPtr(limits, limitsPointer, false);

                if (!SetInformationJobObject(
                        job,
                        JobObjectExtendedLimitInformation,
                        limitsPointer,
                        (uint)size))
                {
                    throw new Win32Exception(
                        Marshal.GetLastWin32Error(),
                        "SetInformationJobObject");
                }

                return job;
            }
            catch
            {
                CloseHandle(job);
                throw;
            }
            finally
            {
                Marshal.FreeHGlobal(limitsPointer);
            }
        }

        private static void Authenticate(NetworkStream stream, string token)
        {
            byte[] bytes = Encoding.ASCII.GetBytes(token ?? String.Empty);
            if (bytes.Length == 0) throw new InvalidOperationException("Missing bridge authentication token");
            stream.Write(bytes, 0, bytes.Length);
            stream.Flush();
        }

        private static async Task RunControlLoop(
            NetworkStream stream,
            IntPtr pseudoConsole,
            IntPtr job,
            CancellationToken cancellation)
        {
            using (StreamReader reader = new StreamReader(stream, Encoding.UTF8, false, 1024, true))
            {
                while (!cancellation.IsCancellationRequested)
                {
                    string line = await reader.ReadLineAsync().ConfigureAwait(false);
                    if (line == null) return;

                    if (line == "close")
                    {
                        Check(TerminateJobObject(job, 1), "TerminateJobObject");
                        WaitForEmptyJob(job, 10000);
                        byte[] acknowledgement = Encoding.ASCII.GetBytes("closed\n");
                        await stream.WriteAsync(
                            acknowledgement,
                            0,
                            acknowledgement.Length,
                            cancellation).ConfigureAwait(false);
                        await stream.FlushAsync(cancellation).ConfigureAwait(false);
                        return;
                    }

                    string[] parts = line.Split(' ');
                    short cols;
                    short rows;
                    if (parts.Length == 3 && parts[0] == "resize" &&
                        Int16.TryParse(parts[1], out cols) && Int16.TryParse(parts[2], out rows) &&
                        cols > 0 && rows > 0)
                    {
                        CheckHResult(ResizePseudoConsole(pseudoConsole, new COORD(cols, rows)), "ResizePseudoConsole");
                    }
                }
            }
        }

        private static void WaitForEmptyJob(IntPtr job, int timeoutMilliseconds)
        {
            int size = Marshal.SizeOf(typeof(JOBOBJECT_BASIC_ACCOUNTING_INFORMATION));
            IntPtr accountingPointer = Marshal.AllocHGlobal(size);
            DateTime deadline = DateTime.UtcNow.AddMilliseconds(timeoutMilliseconds);

            try
            {
                while (true)
                {
                    Check(
                        QueryInformationJobObject(
                            job,
                            JobObjectBasicAccountingInformation,
                            accountingPointer,
                            (uint)size,
                            IntPtr.Zero),
                        "QueryInformationJobObject");

                    JOBOBJECT_BASIC_ACCOUNTING_INFORMATION accounting =
                        (JOBOBJECT_BASIC_ACCOUNTING_INFORMATION)Marshal.PtrToStructure(
                            accountingPointer,
                            typeof(JOBOBJECT_BASIC_ACCOUNTING_INFORMATION));

                    if (accounting.ActiveProcesses == 0) return;
                    if (DateTime.UtcNow >= deadline)
                    {
                        throw new TimeoutException("Timed out waiting for the terminal Job Object to empty");
                    }

                    Thread.Sleep(10);
                }
            }
            finally
            {
                Marshal.FreeHGlobal(accountingPointer);
            }
        }

        private static Task Pump(Stream source, Stream destination, CancellationToken cancellation)
        {
            return Task.Factory.StartNew(
                delegate
                {
                    byte[] buffer = new byte[8192];
                    while (!cancellation.IsCancellationRequested)
                    {
                        int count = source.Read(buffer, 0, buffer.Length);
                        if (count <= 0) break;
                        destination.Write(buffer, 0, count);
                        destination.Flush();
                    }
                },
                cancellation,
                TaskCreationOptions.LongRunning,
                TaskScheduler.Default);
        }

        private static void Check(bool result, string operation)
        {
            if (!result) throw new Win32Exception(Marshal.GetLastWin32Error(), operation);
        }

        private static void CheckHResult(int result, string operation)
        {
            if (result != 0) throw new Win32Exception(result, operation);
        }
    }
}
