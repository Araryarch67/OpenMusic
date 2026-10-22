# Prints "<pid>`t<display name>" for every audio session on the default
# output (what Windows' volume mixer lists). Used by zz_desktop_features_test.
$ErrorActionPreference = 'Stop'
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

[ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")] class MMDeviceEnumerator {}

[Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IMMDeviceEnumerator {
  int EnumAudioEndpoints(int dataFlow, int stateMask, out IntPtr devices);
  int GetDefaultAudioEndpoint(int dataFlow, int role, out IMMDevice device);
}

[Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IMMDevice {
  int Activate(ref Guid iid, int clsCtx, IntPtr activationParams, [MarshalAs(UnmanagedType.IUnknown)] out object iface);
}

[Guid("77AA99A0-1BD6-484F-8BC7-2C654C9A9B6F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IAudioSessionManager2 {
  int GetAudioSessionControl(IntPtr guid, int flags, out IntPtr control);
  int GetSimpleAudioVolume(IntPtr guid, int flags, out IntPtr volume);
  int GetSessionEnumerator(out IAudioSessionEnumerator sessions);
}

[Guid("E2F5BB11-0570-40CA-ACDD-3AA01277DEE8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IAudioSessionEnumerator {
  int GetCount(out int count);
  int GetSession(int index, out IAudioSessionControl2 session);
}

[Guid("bfb7ff88-7239-4fc9-8fa2-07c950be9c6d"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IAudioSessionControl2 {
  int GetState(out int state);
  int GetDisplayName([MarshalAs(UnmanagedType.LPWStr)] out string name);
  int SetDisplayName(string name, IntPtr context);
  int GetIconPath(out IntPtr path);
  int SetIconPath(string path, IntPtr context);
  int GetGroupingParam(out Guid param);
  int SetGroupingParam(ref Guid param, IntPtr context);
  int RegisterAudioSessionNotification(IntPtr client);
  int UnregisterAudioSessionNotification(IntPtr client);
  int GetSessionIdentifier(out IntPtr id);
  int GetSessionInstanceIdentifier(out IntPtr id);
  int GetProcessId(out uint pid);
}

public static class AudioSessions {
  public static string List() {
    var devices = (IMMDeviceEnumerator)new MMDeviceEnumerator();
    var sb = new System.Text.StringBuilder();
    foreach (var role in new[] { 0, 1 }) {
      IMMDevice device;
      if (devices.GetDefaultAudioEndpoint(0, role, out device) != 0) continue;
      var iid = typeof(IAudioSessionManager2).GUID;
      object o;
      Marshal.ThrowExceptionForHR(device.Activate(ref iid, 23, IntPtr.Zero, out o));
      IAudioSessionEnumerator sessions;
      Marshal.ThrowExceptionForHR(((IAudioSessionManager2)o).GetSessionEnumerator(out sessions));
      int n;
      sessions.GetCount(out n);
      for (int i = 0; i < n; i++) {
        IAudioSessionControl2 s;
        sessions.GetSession(i, out s);
        uint pid; string name;
        s.GetProcessId(out pid);
        s.GetDisplayName(out name);
        sb.AppendLine(pid + "\t" + name);
      }
    }
    return sb.ToString();
  }
}
"@
[AudioSessions]::List()
