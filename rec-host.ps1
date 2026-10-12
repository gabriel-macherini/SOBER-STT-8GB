# Persistent mic recorder host (latency fix).
#
# The original rec.ps1 compiles the C# (Add-Type) and spawns a pwsh per
# recording: ~1.2s until the mic is live, clipping the start of speech.
# This host compiles the type ONCE, then just toggles recording via stdin.
#
# Commands (one line each, replies "ok"):
#   start <wavPath> <levelPath>   start recording to file and publish level
#   stop                          finalize and close the file
#   quit                          exit
#
# levelPath receives an integer 0..100 (last buffer peak) for the overlay.
#
# Same winmm recorder as the user's rec.ps1, with Start() on a thread and StopAndWait().

$src = @"
using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading;

public class WaveRecHost {
    const uint CALLBACK_NULL = 0x00000000;
    const uint WIM_DATA = 0x3F0;
    const uint WAVE_MAPPER = 0xFFFFFFFF;
    const uint WHDR_DONE = 0x00000001;
    const int BUF = 3200;   // ~100ms a 16kHz mono: nivel do medidor responsivo

    public delegate void WaveInProc(IntPtr hwi, uint uMsg, IntPtr dwInstance, IntPtr dwParam1, IntPtr dwParam2);

    [StructLayout(LayoutKind.Sequential)] struct WAVEFORMATEX {
        public ushort wFormatTag; public ushort nChannels; public uint nSamplesPerSec;
        public uint nAvgBytesPerSec; public ushort nBlockAlign; public ushort wBitsPerSample; public ushort cbSize;
    }
    [StructLayout(LayoutKind.Sequential)] struct WAVEHDR {
        public IntPtr lpData; public uint dwBufferLength; public uint dwBytesRecorded;
        public IntPtr dwUser; public uint dwFlags; public uint dwLoops; public IntPtr lpNext; public uint reserved;
    }

    [DllImport("winmm.dll")] static extern uint waveInOpen(out IntPtr hwi, uint uDeviceID, ref WAVEFORMATEX pwfx, WaveInProc dwCallback, IntPtr dwInstance, uint fdwOpen);
    [DllImport("winmm.dll")] static extern uint waveInPrepareHeader(IntPtr hwi, ref WAVEHDR pwh, uint cbwh);
    [DllImport("winmm.dll")] static extern uint waveInAddBuffer(IntPtr hwi, ref WAVEHDR pwh, uint cbwh);
    [DllImport("winmm.dll")] static extern uint waveInStart(IntPtr hwi);
    [DllImport("winmm.dll")] static extern uint waveInStop(IntPtr hwi);
    [DllImport("winmm.dll")] static extern uint waveInUnprepareHeader(IntPtr hwi, ref WAVEHDR pwh, uint cbwh);
    [DllImport("winmm.dll")] static extern uint waveInClose(IntPtr hwi);
    [DllImport("winmm.dll")] static extern uint waveInReset(IntPtr hwi);

    IntPtr hwi = IntPtr.Zero;
    FileStream fs;
    WAVEHDR[] hdrs = new WAVEHDR[4];
    IntPtr[] bufs = new IntPtr[4];
    uint dataLen = 0;
    public bool Stopped = false;
    Thread thread;
    string levelPath;

    void WriteHeader() {
        byte[] h = new byte[44];
        h[0]=0x52;h[1]=0x49;h[2]=0x46;h[3]=0x46;
        BitConverter.GetBytes(36+dataLen).CopyTo(h,4);
        h[8]=0x57;h[9]=0x41;h[10]=0x56;h[11]=0x45;
        h[12]=0x66;h[13]=0x6D;h[14]=0x74;h[15]=0x20;
        BitConverter.GetBytes(16u).CopyTo(h,16);
        BitConverter.GetBytes((ushort)1).CopyTo(h,20);
        BitConverter.GetBytes((ushort)1).CopyTo(h,22);
        BitConverter.GetBytes(16000u).CopyTo(h,24);
        BitConverter.GetBytes(32000u).CopyTo(h,28);
        BitConverter.GetBytes((ushort)2).CopyTo(h,32);
        BitConverter.GetBytes((ushort)16).CopyTo(h,34);
        h[36]=0x64;h[37]=0x61;h[38]=0x74;h[39]=0x61;
        BitConverter.GetBytes(dataLen).CopyTo(h,40);
        fs.Position = 0; fs.Write(h,0,44); fs.Flush();
    }

    // Publish the last buffer peak (0..100) for the overlay to read.
    void PublishLevel(byte[] data) {
        if (levelPath == null) return;
        int peak = 0;
        for (int k = 0; k + 1 < data.Length; k += 2) {
            short s = (short)(data[k] | (data[k+1] << 8));
            int a = s < 0 ? -s : s;
            if (a > peak) peak = a;
        }
        int pct = (int)Math.Min(100, Math.Round(Math.Sqrt(peak / 32768.0) * 110));
        try { File.WriteAllText(levelPath, pct.ToString()); } catch {}
    }

    public void Start(string path, uint devId, string level) {
        levelPath = level;
        try { File.WriteAllText(levelPath, "0"); } catch {}
        thread = new Thread(() => {
            try { Run(path, devId); }
            catch (Exception e) { Console.Error.WriteLine("rec: " + e.Message); }
        });
        thread.IsBackground = true;
        thread.Start();
    }

    public void StopAndWait(int ms) {
        Stopped = true;
        if (thread != null) thread.Join(ms);
    }

    int Run(string path, uint devId) {
        GCHandle pin = GCHandle.Alloc(hdrs, GCHandleType.Pinned);
        fs = new FileStream(path, FileMode.Create, FileAccess.ReadWrite);
        WriteHeader();
        WAVEFORMATEX fmt = new WAVEFORMATEX { wFormatTag = 1, nChannels = 1, nSamplesPerSec = 16000, wBitsPerSample = 16, nBlockAlign = 2, nAvgBytesPerSec = 32000, cbSize = 0 };
        uint r = waveInOpen(out hwi, devId, ref fmt, null, IntPtr.Zero, CALLBACK_NULL);
        if (r != 0) { Console.Error.WriteLine("rec: waveInOpen failed " + r); pin.Free(); fs.Dispose(); return (int)r; }
        for (int i = 0; i < hdrs.Length; i++) {
            bufs[i] = Marshal.AllocHGlobal(BUF);
            hdrs[i] = new WAVEHDR { lpData = bufs[i], dwBufferLength = BUF };
            waveInPrepareHeader(hwi, ref hdrs[i], (uint)Marshal.SizeOf(typeof(WAVEHDR)));
            waveInAddBuffer(hwi, ref hdrs[i], (uint)Marshal.SizeOf(typeof(WAVEHDR)));
        }
        waveInStart(hwi);
        while (!Stopped) {
            for (int i = 0; i < hdrs.Length; i++) {
                if ((hdrs[i].dwFlags & WHDR_DONE) != 0) {
                    byte[] data = new byte[hdrs[i].dwBytesRecorded];
                    Marshal.Copy(hdrs[i].lpData, data, 0, data.Length);
                    fs.Position = 44 + dataLen;
                    fs.Write(data, 0, data.Length);
                    fs.Flush();
                    dataLen += (uint)data.Length;
                    WriteHeader();
                    PublishLevel(data);
                    hdrs[i].dwBytesRecorded = 0;
                    hdrs[i].dwFlags &= ~WHDR_DONE;
                    waveInAddBuffer(hwi, ref hdrs[i], (uint)Marshal.SizeOf(typeof(WAVEHDR)));
                }
            }
            Thread.Sleep(20);
        }
        waveInStop(hwi); waveInReset(hwi);
        for (int i = 0; i < hdrs.Length; i++) {
            waveInUnprepareHeader(hwi, ref hdrs[i], (uint)Marshal.SizeOf(typeof(WAVEHDR)));
            Marshal.FreeHGlobal(bufs[i]);
        }
        waveInClose(hwi);
        WriteHeader();
        fs.Dispose();
        if (levelPath != null) { try { File.WriteAllText(levelPath, "0"); } catch {} }
        pin.Free();
        return 0;
    }
}
"@

Add-Type -TypeDefinition $src -Language CSharp
[Console]::Out.WriteLine("ready")
[Console]::Out.Flush()

$rec = $null
while ($true) {
    $line = [Console]::In.ReadLine()
    if ($null -eq $line) { break }
    $line = $line.Trim()
    if ($line -eq "") { continue }
    $parts = $line -split '\s+'
    switch ($parts[0]) {
        "start" {
            if ($rec) { $rec.StopAndWait(1000); $rec = $null }
            $rec = [WaveRecHost]::new()
            $rec.Start($parts[1], [uint32]4294967295, $parts[2])
            [Console]::Out.WriteLine("ok"); [Console]::Out.Flush()
        }
        "stop" {
            if ($rec) { $rec.StopAndWait(3000); $rec = $null }
            [Console]::Out.WriteLine("ok"); [Console]::Out.Flush()
        }
        "quit" {
            if ($rec) { $rec.StopAndWait(1000) }
            break
        }
        default { [Console]::Out.WriteLine("err"); [Console]::Out.Flush() }
    }
}
