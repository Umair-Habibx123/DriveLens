# DriveLens: scans the drive this folder is on and opens a dashboard.
# It only reads your drive. It writes DriveLens-Report.html in this folder and, while the
# dashboard is open, serves it on a private local address (127.0.0.1) so the page
# can open folders in File Explorer and rescan. It never deletes anything.
#   .\DriveLens.ps1             scan the drive this folder is on
#   .\DriveLens.ps1 -Drive E    scan another drive
#   .\DriveLens.ps1 -NoServer   only write DriveLens-Report.html, without File Explorer or Rescan buttons
param([string]$Drive, [switch]$NoOpen, [switch]$NoServer)
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path

if ($Drive) { $Drive = $Drive.Substring(0, 1).ToUpper() + ':' }
else { $Drive = (Split-Path -Qualifier $here).ToUpper() }
if ($Drive -notmatch '^[A-Z]:$') { throw 'Copy this folder onto a local drive, such as D:\DriveLens, and run it from there.' }

Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Diagnostics;
using System.Collections.Generic;
using System.Collections.Concurrent;
using System.Runtime.InteropServices;
using System.Threading;
public class SMResult {
  public Dictionary<string,long> Tree = new Dictionary<string,long>(StringComparer.OrdinalIgnoreCase);
  public Dictionary<string,long> RuleSizes = new Dictionary<string,long>();
  public Dictionary<string,long> PathSizes = new Dictionary<string,long>(StringComparer.OrdinalIgnoreCase);
  public Dictionary<string,string> PathRule = new Dictionary<string,string>(StringComparer.OrdinalIgnoreCase);
  public Dictionary<string,long> RootFiles = new Dictionary<string,long>(StringComparer.OrdinalIgnoreCase);
  public long Total, Files, Links;
  public long Unreadable;
}
public static class SMScan {
  const int MaxDepth = 6;
  [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
  struct FindData {
    public uint Attributes;
    public uint C1, C2, A1, A2, W1, W2;
    public uint SizeHigh, SizeLow, Res0, Res1;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)] public string Name;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 14)] public string AltName;
  }
  [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
  static extern IntPtr FindFirstFileExW(string name, int level, out FindData data, int op, IntPtr filter, int flags);
  [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
  static extern bool FindNextFileW(IntPtr h, out FindData data);
  [DllImport("kernel32.dll")] static extern bool FindClose(IntPtr h);
  [DllImport("kernel32.dll")] static extern IntPtr GetStdHandle(int n);
  [DllImport("kernel32.dll")] static extern bool GetConsoleMode(IntPtr h, out uint m);
  [DllImport("kernel32.dll")] static extern bool SetConsoleMode(IntPtr h, uint m);

  public static long FilesSoFar, BytesSoFar;
  public static volatile bool Done;
  public static SMResult Result;
  public static string Failure;
  static string[] skipNames;

  // Stops a click in the console window from pausing the scan.
  public static void DisableClickPause() {
    try {
      IntPtr h = GetStdHandle(-10);
      uint m;
      if (GetConsoleMode(h, out m)) SetConsoleMode(h, (m & ~(uint)0x40) | 0x80);
    } catch { }
  }

  public static void Begin(string root, Dictionary<string,string> exact, Dictionary<string,string> names, string[] skip) {
    skipNames = skip;
    Interlocked.Exchange(ref FilesSoFar, 0);
    Interlocked.Exchange(ref BytesSoFar, 0);
    Result = null; Failure = null; Done = false;
    var t = new Thread(() => {
      try { Result = Run(root, exact, names); }
      catch (Exception e) { Failure = e.Message; }
      Done = true;
    });
    t.IsBackground = true;
    t.Start();
  }

  static SMResult Run(string root, Dictionary<string,string> exact, Dictionary<string,string> names) {
    var r = new SMResult();
    var ex = new Dictionary<string,string>(exact, StringComparer.OrdinalIgnoreCase);
    var nm = new Dictionary<string,string>(names, StringComparer.OrdinalIgnoreCase);
    var stack = new ConcurrentStack<string[]>();
    int pending = 1;
    stack.Push(new string[] { root, null, null });
    int count = Math.Max(2, Math.Min(8, Environment.ProcessorCount));
    var workers = new Thread[count];
    string failure = null;
    for (int w = 0; w < count; w++) {
      workers[w] = new Thread(() => {
        try {
          while (Volatile.Read(ref pending) > 0) {
            string[] item;
            if (!stack.TryPop(out item)) { Thread.Sleep(1); continue; }
            try { Visit(item, r, ex, nm, stack, ref pending); }
            finally { Interlocked.Decrement(ref pending); }
          }
        } catch (Exception e) { failure = e.Message; Volatile.Write(ref pending, 0); }
      });
      workers[w].IsBackground = true;
      workers[w].Start();
    }
    foreach (var t in workers) t.Join();
    if (failure != null) throw new Exception(failure);
    return r;
  }

  static bool NameRuleAllowed(string full) {
    foreach (var s in skipNames) if (full.IndexOf(s, StringComparison.OrdinalIgnoreCase) >= 0) return false;
    return true;
  }

  static void Visit(string[] item, SMResult r, Dictionary<string,string> ex, Dictionary<string,string> nm, ConcurrentStack<string[]> stack, ref int pending) {
    string path = item[0], rule = item[1], rulePath = item[2];
    bool isRoot = path.Length == 2;
    FindData d;
    IntPtr h = FindFirstFileExW(@"\\?\" + path + @"\*", 1, out d, 0, IntPtr.Zero, 2);
    if (h == new IntPtr(-1)) { Interlocked.Increment(ref r.Unreadable); return; }
    long sum = 0, total = 0, files = 0, links = 0;
    Dictionary<string,long> rootFiles = null;
    List<KeyValuePair<string,string>> marks = null;
    try {
      do {
        string name = d.Name;
        if (name == "." || name == "..") continue;
        if ((d.Attributes & 0x10) != 0) {
          if ((d.Attributes & 0x400) != 0) { links++; continue; }
          string full = path + "\\" + name;
          string nr = rule, np = rulePath, found;
          if (nr == null) {
            bool hit = ex.TryGetValue(full, out found);
            if (!hit && nm.TryGetValue(name, out found) && NameRuleAllowed(full)) hit = true;
            if (hit) {
              nr = found; np = full;
              if (marks == null) marks = new List<KeyValuePair<string,string>>();
              marks.Add(new KeyValuePair<string,string>(np, nr));
            }
          }
          Interlocked.Increment(ref pending);
          stack.Push(new string[] { full, nr, np });
        } else {
          if ((d.Attributes & 0x400000) != 0 || (d.Attributes & 0x1000) != 0) continue;
          long len = ((long)d.SizeHigh << 32) | d.SizeLow;
          files++;
          total += len;
          if (isRoot) {
            if (rootFiles == null) rootFiles = new Dictionary<string,long>(StringComparer.OrdinalIgnoreCase);
            rootFiles[name] = len;
          } else { sum += len; }
        }
      } while (FindNextFileW(h, out d));
    } finally { FindClose(h); }
    Interlocked.Add(ref FilesSoFar, files);
    Interlocked.Add(ref BytesSoFar, total);
    lock (r) {
      r.Files += files; r.Total += total; r.Links += links;
      if (rootFiles != null) foreach (var f in rootFiles) r.RootFiles[f.Key] = f.Value;
      if (marks != null) foreach (var m in marks) r.PathRule[m.Key] = m.Value;
      long v;
      if (rule != null) {
        r.RuleSizes.TryGetValue(rule, out v); r.RuleSizes[rule] = v + sum;
        r.PathSizes.TryGetValue(rulePath, out v); r.PathSizes[rulePath] = v + sum;
      } else if (!isRoot) {
        var parts = path.Split('\\');
        string key = parts[0];
        int last = Math.Min(MaxDepth, parts.Length - 1);
        for (int i = 1; i <= last; i++) {
          key += "\\" + parts[i];
          r.Tree.TryGetValue(key, out v); r.Tree[key] = v + sum;
        }
      }
    }
  }

  // Adds flagged folders back into the folder tree and returns folders worth showing.
  public static List<string> KeepFolders(SMResult r, long threshold) {
    foreach (var kv in r.PathSizes) {
      var parts = kv.Key.Split('\\');
      string key = parts[0];
      int last = Math.Min(MaxDepth, parts.Length - 2);
      long v;
      for (int i = 1; i <= last; i++) {
        key += "\\" + parts[i];
        r.Tree.TryGetValue(key, out v); r.Tree[key] = v + kv.Value;
      }
      r.Tree[kv.Key] = kv.Value;
    }
    var keep = new List<string>();
    foreach (var kv in r.Tree) if (kv.Value >= threshold) keep.Add(kv.Key);
    keep.Sort((a, b) => a.Length.CompareTo(b.Length));
    return keep;
  }
}

// A tiny web server on 127.0.0.1 so the dashboard can open folders in File Explorer.
// Every request must carry the one-time key that is only written into the served page,
// and it only opens paths that appear in the scan.
public static class SMServer {
  static TcpListener listener;
  public static int Port;
  public static string Token;
  public static volatile string Html = "";
  public static volatile int Version = 1;
  public static volatile bool RescanRequested, Scanning;
  public static volatile string ScanError;
  public static long LastPing;
  static HashSet<string> allowed = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
  static readonly object gate = new object();

  public static void SetAllowed(IEnumerable<string> paths) {
    var s = new HashSet<string>(paths, StringComparer.OrdinalIgnoreCase);
    lock (gate) { allowed = s; }
  }

  public static void Start() {
    listener = new TcpListener(IPAddress.Loopback, 0);
    listener.Start();
    Port = ((IPEndPoint)listener.LocalEndpoint).Port;
    Interlocked.Exchange(ref LastPing, DateTime.UtcNow.Ticks);
    var t = new Thread(() => {
      while (true) {
        TcpClient c;
        try { c = listener.AcceptTcpClient(); } catch { return; }
        ThreadPool.QueueUserWorkItem(_ => Handle(c));
      }
    });
    t.IsBackground = true;
    t.Start();
  }

  public static double IdleSeconds() {
    return TimeSpan.FromTicks(DateTime.UtcNow.Ticks - Interlocked.Read(ref LastPing)).TotalSeconds;
  }

  static string Esc(string s) {
    if (s == null) return "";
    var b = new StringBuilder();
    foreach (char ch in s) {
      if (ch == '"' || ch == '\\') { b.Append('\\').Append(ch); }
      else if (ch < 32) { b.Append(' '); }
      else b.Append(ch);
    }
    return b.ToString();
  }

  static void Send(NetworkStream s, int code, string type, string body) {
    byte[] data = Encoding.UTF8.GetBytes(body);
    string status = code == 200 ? "OK" : code == 403 ? "Forbidden" : code == 404 ? "Not Found" : "Bad Request";
    string head = "HTTP/1.1 " + code + " " + status + "\r\nContent-Type: " + type +
      "\r\nContent-Length: " + data.Length + "\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nConnection: close\r\n\r\n";
    byte[] h = Encoding.ASCII.GetBytes(head);
    s.Write(h, 0, h.Length);
    s.Write(data, 0, data.Length);
  }

  static void Handle(TcpClient c) {
    try {
      using (c) {
        c.ReceiveTimeout = 5000;
        var s = c.GetStream();
        var reader = new StreamReader(s, Encoding.ASCII, false, 4096, true);
        string first = reader.ReadLine();
        if (first == null) return;
        string host = null, origin = null, line;
        while (!string.IsNullOrEmpty(line = reader.ReadLine())) {
          int i = line.IndexOf(':');
          if (i <= 0) continue;
          string k = line.Substring(0, i).Trim().ToLowerInvariant(), v = line.Substring(i + 1).Trim();
          if (k == "host") host = v; else if (k == "origin") origin = v;
        }
        var parts = first.Split(' ');
        if (parts.Length < 2 || parts[0] != "GET") { Send(s, 400, "text/plain", "Bad request"); return; }
        string self1 = "127.0.0.1:" + Port, self2 = "localhost:" + Port;
        if (host != self1 && host != self2) { Send(s, 403, "text/plain", "Forbidden"); return; }
        if (origin != null && origin != "http://" + self1 && origin != "http://" + self2) { Send(s, 403, "text/plain", "Forbidden"); return; }

        string target = parts[1], route = target, query = "";
        int q = target.IndexOf('?');
        if (q >= 0) { route = target.Substring(0, q); query = target.Substring(q + 1); }
        var args = new Dictionary<string,string>();
        foreach (var pair in query.Split('&')) {
          if (pair.Length == 0) continue;
          // Browsers send spaces in query strings as "+", and a real "+" as "%2B".
          int e = pair.IndexOf('=');
          string k = Uri.UnescapeDataString((e < 0 ? pair : pair.Substring(0, e)).Replace('+', ' '));
          string v = e < 0 ? "" : Uri.UnescapeDataString(pair.Substring(e + 1).Replace('+', ' '));
          args[k] = v;
        }

        if (route == "/") { Send(s, 200, "text/html; charset=utf-8", Html); return; }
        if (route == "/favicon.ico") { Send(s, 404, "text/plain", ""); return; }
        string tok;
        if (!args.TryGetValue("t", out tok) || tok != Token) { Send(s, 403, "application/json", "{\"ok\":false,\"error\":\"This page is out of date. Run DriveLens again.\"}"); return; }

        if (route == "/api/ping") {
          Interlocked.Exchange(ref LastPing, DateTime.UtcNow.Ticks);
          Send(s, 200, "application/json", "{\"ok\":true,\"version\":" + Version + "}");
          return;
        }
        if (route == "/api/status") {
          Interlocked.Exchange(ref LastPing, DateTime.UtcNow.Ticks);
          Send(s, 200, "application/json", "{\"ok\":true,\"scanning\":" + (Scanning || RescanRequested ? "true" : "false") +
            ",\"files\":" + Interlocked.Read(ref SMScan.FilesSoFar) +
            ",\"bytes\":" + Interlocked.Read(ref SMScan.BytesSoFar) +
            ",\"version\":" + Version + ",\"error\":\"" + Esc(ScanError) + "\"}");
          return;
        }
        if (route == "/api/rescan") {
          if (!Scanning) { ScanError = null; RescanRequested = true; }
          Send(s, 200, "application/json", "{\"ok\":true}");
          return;
        }
        if (route == "/api/open") {
          string p, mode;
          args.TryGetValue("p", out p);
          args.TryGetValue("mode", out mode);
          bool ok;
          lock (gate) { ok = p != null && allowed.Contains(p); }
          if (!ok) { Send(s, 403, "application/json", "{\"ok\":false,\"error\":\"That location isn't part of this scan.\"}"); return; }
          if (p.Length == 2) p += "\\";
          bool isDir = Directory.Exists(p), isFile = !isDir && File.Exists(p);
          if (!isDir && !isFile) { Send(s, 404, "application/json", "{\"ok\":false,\"error\":\"That location no longer exists. It may have been deleted since the scan.\"}"); return; }
          string argsText = (isFile || mode == "select") ? "/select,\"" + p.TrimEnd('\\') + "\"" : "\"" + p + "\"";
          if (p.Length == 3 && mode == "select") argsText = "\"" + p + "\"";
          Process.Start(new ProcessStartInfo("explorer.exe", argsText) { UseShellExecute = true });
          Send(s, 200, "application/json", "{\"ok\":true}");
          return;
        }
        Send(s, 404, "text/plain", "Not found");
      }
    } catch { }
  }
}
'@

$u = $env:USERPROFILE
$la = $env:LOCALAPPDATA
$ra = $env:APPDATA
$win = $env:SystemRoot

$cachePaths = New-Object System.Collections.ArrayList
$sitePaths = New-Object System.Collections.ArrayList
foreach ($base in "$la\Google\Chrome\User Data", "$la\Microsoft\Edge\User Data", "$la\BraveSoftware\Brave-Browser\User Data") {
  if (Test-Path -LiteralPath $base) {
    Get-ChildItem -LiteralPath $base -Directory -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq 'Default' -or $_.Name -like 'Profile *' } | ForEach-Object {
      [void]$cachePaths.Add("$($_.FullName)\Cache"); [void]$cachePaths.Add("$($_.FullName)\Code Cache")
      [void]$sitePaths.Add("$($_.FullName)\Service Worker\CacheStorage")
    }
  }
}
if (Test-Path -LiteralPath "$la\Mozilla\Firefox\Profiles") {
  Get-ChildItem -LiteralPath "$la\Mozilla\Firefox\Profiles" -Directory -Force -ErrorAction SilentlyContinue | ForEach-Object { [void]$cachePaths.Add("$($_.FullName)\cache2") }
}

$rules = @(
  @{ id='recycle'; label='Recycle Bin'; verdict='Review'; why='Files you deleted earlier. Check nothing important is in there before emptying it.'; paths=@("$Drive\`$Recycle.Bin") }

  @{ id='temp'; label='Your temp files'; verdict='Safe'; why='Temporary files. Disk Cleanup removes older ones and skips files apps may still need.'; paths=@("$la\Temp") }
  @{ id='wintemp'; label='Windows temp files'; verdict='Safe'; why='System temporary files. Only fully measured when run as administrator.'; paths=@("$win\Temp") }
  @{ id='delivery'; label='Delivery Optimization cache'; verdict='Safe'; why='Cached Windows update files. Only measured when run as administrator.'; paths=@("$win\ServiceProfiles\NetworkService\AppData\Local\Microsoft\Windows\DeliveryOptimization\Cache") }
  @{ id='thumbs'; label='Thumbnail and icon caches'; verdict='Safe'; why='Windows rebuilds them when needed. Clear them with Disk Cleanup.'; paths=@("$la\Microsoft\Windows\Explorer") }
  @{ id='browser'; label='Browser caches'; verdict='Safe'; why='Cached images and code. Sites may load slower at first.'; paths=@($cachePaths) }
  @{ id='npm'; label='npm cache'; verdict='Safe'; why='Packages npm can download again. Next installs may be slower.'; paths=@("$la\npm-cache\_cacache") }
  @{ id='pip'; label='pip cache'; verdict='Safe'; why='Python packages pip can download again.'; paths=@("$la\pip\cache") }
  @{ id='uv'; label='uv cache'; verdict='Safe'; why='Python packages uv can download again.'; paths=@("$la\uv\cache") }
  @{ id='yarn'; label='Yarn cache'; verdict='Safe'; why='Packages Yarn can download again.'; paths=@("$la\Yarn\Cache") }
  @{ id='vsix'; label='VS Code saved extension installers'; verdict='Safe'; why='Copies of extension downloads, not your installed extensions.'; paths=@("$ra\Code\CachedExtensionVSIXs") }
  @{ id='steamweb'; label='Steam web cache'; verdict='Safe'; why='Steam rebuilds it when needed.'; paths=@("$la\Steam\htmlcache") }
  @{ id='build'; label='Framework build caches'; verdict='Safe'; why='Build output such as .next. The next build recreates it. Stop dev servers first.'; names=@('.next','.nuxt','.svelte-kit','.angular','.turbo','.parcel-cache') }

  @{ id='wudownload'; label='Windows Update downloads'; verdict='Review'; why='Windows downloads these again if needed. Stop the update service first, and never clear them during an update.'; paths=@("$win\SoftwareDistribution\Download") }
  @{ id='downloads'; label='Downloads folder'; verdict='Review'; why='Your downloads. Look for old installers and files you no longer need.'; paths=@("$u\Downloads") }
  @{ id='windowsold'; label='Previous Windows installation'; verdict='Review'; why='Lets you go back to your earlier Windows version. Remove it with Disk Cleanup, not by hand.'; paths=@("$Drive\Windows.old") }
  @{ id='winre'; label='Windows recovery update files'; verdict='Review'; why="Could be tied to a pending update, so don't delete them by hand."; paths=@("$Drive\`$WinREAgent") }
  @{ id='sitestore'; label='Browser site storage'; verdict='Review'; why='Offline data saved by websites. Clearing it can sign you out or remove site data.'; paths=@($sitePaths) }
  @{ id='vsstorage'; label='VS Code WebStorage'; verdict='Review'; why='Extensions may store data here, so check before clearing it.'; paths=@("$ra\Code\WebStorage") }
  @{ id='modules'; label='node_modules folders'; verdict='Review'; why='Project dependencies. Safe to remove from projects you no longer work on, then reinstall if needed.'; names=@('node_modules') }
  @{ id='venv'; label='Python environments'; verdict='Review'; why='Project environments. You can recreate them, but check how each project was set up first.'; names=@('.venv','venv') }
  @{ id='terraform'; label='Terraform folders'; verdict='Review'; why='terraform init restores providers, but only clear these for projects you are not using.'; names=@('.terraform') }
  @{ id='gradle'; label='Gradle caches'; verdict='Review'; why='Gradle downloads these again, so builds will be slower next time.'; paths=@("$u\.gradle\caches") }
  @{ id='pnpm'; label='pnpm store'; verdict='Review'; why='Projects may link to it. Use pnpm store prune instead of deleting it.'; paths=@("$la\pnpm\store") }
  @{ id='nuget'; label='NuGet packages'; verdict='Review'; why='.NET packages that can be restored, but builds will be slower next time.'; paths=@("$u\.nuget\packages") }
  @{ id='cargo'; label='Cargo registry'; verdict='Review'; why='Rust packages that can be downloaded again.'; paths=@("$u\.cargo\registry") }
  @{ id='pub'; label='Dart Pub cache'; verdict='Review'; why='Flutter and Dart packages that can be downloaded again.'; paths=@("$la\Pub\Cache") }
  @{ id='bun'; label='Bun cache'; verdict='Review'; why='Packages Bun can download again.'; paths=@("$u\.bun\install\cache") }
  @{ id='hf'; label='Hugging Face models'; verdict='Review'; why='AI models you can download again, but projects may rely on them.'; paths=@("$u\.cache\huggingface") }
  @{ id='ollama'; label='Ollama models'; verdict='Review'; why='AI models. Remove the ones you do not use with ollama rm.'; paths=@("$u\.ollama\models") }
  @{ id='docker'; label='Docker data'; verdict='Review'; why="Images and containers. Clean up from Docker itself, not by deleting files."; paths=@("$la\Docker") }
  @{ id='avd'; label='Android emulators'; verdict='Review'; why='Emulator images. Remove unused ones from Android Studio.'; paths=@("$u\.android\avd") }
  @{ id='gupdate'; label='GoogleUpdater cache'; verdict='Review'; why="Update cache that may come back, so there's little to gain."; paths=@("$Drive\Program Files (x86)\Google\GoogleUpdater\crx_cache") }

  @{ id='prefetch'; label='Prefetch'; verdict='Keep'; why='Helps apps start faster. Deleting it gains almost nothing. Only measured when run as administrator.'; paths=@("$win\Prefetch") }
  @{ id='winsxs'; label='WinSxS'; verdict='Keep'; why='Windows components. Never delete by hand. Its real size is usually smaller than shown.'; paths=@("$win\WinSxS") }
  @{ id='pkgcache'; label='Package Cache'; verdict='Keep'; why='Windows and Visual Studio use it to repair, update or uninstall software.'; paths=@("$Drive\ProgramData\Package Cache") }
)

$exact = New-Object 'System.Collections.Generic.Dictionary[string,string]'
$names = New-Object 'System.Collections.Generic.Dictionary[string,string]'
$ruleById = @{}
foreach ($r in $rules) {
  $ruleById[$r.id] = $r
  foreach ($p in @($r.paths)) { if ($p -and $p.StartsWith("$Drive\", [StringComparison]::OrdinalIgnoreCase)) { $exact[$p] = $r.id } }
  foreach ($n in @($r.names)) { if ($n) { $names[$n] = $r.id } }
}
# Dependency folders inside installed apps and tool folders aren't yours to clear.
$skipNames = [string[]]@('\AppData\','\Windows\','\Program Files\','\Program Files (x86)\','\ProgramData\','\.vscode\','\.cursor\','\.local\','\.cache\','\.npm\','\.nvm\','\.bun\','\.codex\','\.claude\','\$Recycle.Bin\')
$BytesPerGiB = 1073741824.0
$MinNode = 0.03
$isSystem = $Drive -ieq $env:SystemDrive
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$template = [IO.File]::ReadAllText((Join-Path $here 'template.html'), [Text.Encoding]::UTF8)

function Get-Health {
  $h = [ordered]@{ diskName=''; mediaType=''; diskHealth=''; volumeHealth=''; fileSystem=''; wearPct=$null; tempC=$null }
  $letter = $Drive.Substring(0, 1)
  try { $vol = Get-Volume -DriveLetter $letter -ErrorAction Stop; $h.volumeHealth = [string]$vol.HealthStatus; $h.fileSystem = [string]$vol.FileSystem } catch {}
  try {
    $part = Get-Partition -DriveLetter $letter -ErrorAction Stop
    $pd = Get-PhysicalDisk -ErrorAction Stop | Where-Object { "$($_.DeviceId)" -eq "$($part.DiskNumber)" } | Select-Object -First 1
    if ($pd) {
      $h.diskName = [string]$pd.FriendlyName
      $h.mediaType = [string]$pd.MediaType
      $h.diskHealth = [string]$pd.HealthStatus
      try {
        $rc = $pd | Get-StorageReliabilityCounter -ErrorAction Stop
        if ($null -ne $rc.Wear) { $h.wearPct = [int]$rc.Wear }
        if ($rc.Temperature) { $h.tempC = [int]$rc.Temperature }
      } catch {}
    }
  } catch {}
  return $h
}
$health = Get-Health

function Invoke-Build {
  $disk = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$Drive'"
  if (-not $disk -or -not $disk.Size) { throw "Drive $Drive wasn't found, or it isn't ready." }

  Write-Host ''
  Write-Host "  DriveLens - scanning $Drive" -ForegroundColor Cyan
  Write-Host '  Nothing on your drive is changed or deleted.'
  Write-Host ''
  [SMScan]::DisableClickPause()
  $sw = [Diagnostics.Stopwatch]::StartNew()
  [SMScan]::Begin($Drive, $exact, $names, $skipNames)
  $live = -not [Console]::IsOutputRedirected
  while (-not [SMScan]::Done) {
    Start-Sleep -Milliseconds 250
    if ($live) {
      $line = "  {0:N0} files  |  {1:N1} GB read  |  {2:N0} seconds" -f [SMScan]::FilesSoFar, ([SMScan]::BytesSoFar / $BytesPerGiB), $sw.Elapsed.TotalSeconds
      Write-Host ("`r" + $line.PadRight(70)) -NoNewline
    }
  }
  $sw.Stop()
  if ($live) { Write-Host '' }
  if ([SMScan]::Failure) { throw "The scan stopped: $([SMScan]::Failure)" }
  $result = [SMScan]::Result
  $disk = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$Drive'"

  $folderNotes = @{}
  if ($isSystem) {
    $folderNotes[$win] = "Windows system files. Don't delete anything here by hand, apart from the cleanup guide's steps."
    $folderNotes["$Drive\Program Files"] = 'Installed apps. Remove them through Settings > Apps.'
    $folderNotes["$Drive\Program Files (x86)"] = 'Installed apps. Remove them through Settings > Apps.'
    $folderNotes["$Drive\ProgramData"] = 'Shared app data. Leave it unless you know what a folder is.'
  }
  $allowed = New-Object System.Collections.Generic.List[string]
  $allowed.Add($Drive)

  function New-Node([string]$name, [string]$path, [double]$gib) {
    [pscustomobject]@{ n=$name; p=$path; s=$gib; v=$null; w=$null; f=0; c=(New-Object System.Collections.ArrayList) }
  }
  $rootNode = New-Node $Drive $Drive ([math]::Round($result.Total / $BytesPerGiB, 2))
  $nodes = @{}
  $nodes[$Drive.ToLower()] = $rootNode
  foreach ($path in [SMScan]::KeepFolders($result, [long]($MinNode * $BytesPerGiB))) {
    $node = New-Node (Split-Path $path -Leaf) $path ([math]::Round($result.Tree[$path] / $BytesPerGiB, 2))
    $allowed.Add($path)
    if ($result.PathRule.ContainsKey($path)) {
      $r = $ruleById[$result.PathRule[$path]]
      $node.v = $r.verdict; $node.w = $r.why
      if (@($r.paths).Count -eq 1) { $node.n = $r.label }
    } elseif ($folderNotes.ContainsKey($path)) { $node.w = $folderNotes[$path] }
    $nodes[$path.ToLower()] = $node
    $parent = $path
    do {
      $parent = $parent.Substring(0, $parent.LastIndexOf('\'))
      $pn = $nodes[$parent.ToLower()]
    } while (-not $pn -and $parent.Contains('\'))
    if (-not $pn) { $pn = $rootNode }
    [void]$pn.c.Add($node)
  }
  foreach ($f in $result.RootFiles.GetEnumerator()) {
    $size = [math]::Round($f.Value / $BytesPerGiB, 2)
    if ($size -lt $MinNode) { continue }
    $node = New-Node $f.Key "$Drive\$($f.Key)" $size
    $node.f = 1
    $allowed.Add($node.p)
    if ($f.Key -ieq 'hiberfil.sys') { $node.v = 'Review'; $node.w = 'Hibernation file. Run powercfg /h off as administrator to remove it, which also turns off Hibernate and Fast Startup.' }
    elseif ($f.Key -ieq 'pagefile.sys') { $node.v = 'Keep'; $node.w = 'Windows virtual memory. Leave it alone.' }
    elseif ($f.Key -ieq 'swapfile.sys') { $node.v = 'Keep'; $node.w = 'Windows memory file. Leave it alone.' }
    [void]$rootNode.c.Add($node)
  }
  foreach ($node in @($nodes.Values)) {
    if ($node.c.Count -gt 0) {
      $rest = [math]::Round($node.s - ($node.c | Measure-Object s -Sum).Sum, 2)
      if ($rest -ge $MinNode) { [void]$node.c.Add((New-Node 'Other files' $node.p $rest)) }
    }
  }

  $items = New-Object System.Collections.ArrayList
  $sizes = @{}
  foreach ($r in $rules) {
    $bytes = [long]0
    if ($result.RuleSizes.ContainsKey($r.id)) { $bytes = $result.RuleSizes[$r.id] }
    $size = [math]::Round($bytes / $BytesPerGiB, 2)
    $sizes[$r.id] = $size
    if ($size -lt 0.01 -or $r.verdict -eq 'Keep') { continue }
    $locs = @($result.PathRule.GetEnumerator() | Where-Object { $_.Value -eq $r.id -and $result.PathSizes.ContainsKey($_.Key) -and $result.PathSizes[$_.Key] -gt 0 } |
      Sort-Object { $result.PathSizes[$_.Key] } -Descending | Select-Object -First 12 |
      ForEach-Object { $allowed.Add($_.Key); [pscustomobject]@{ p=$_.Key; gb=[math]::Round($result.PathSizes[$_.Key] / $BytesPerGiB, 2); f=0 } })
    [void]$items.Add([pscustomobject]@{ label=$r.label; gb=$size; verdict=$r.verdict; why=$r.why; count=@($result.PathRule.Values | Where-Object { $_ -eq $r.id }).Count; paths=@($locs) })
  }
  $hib = $result.RootFiles.Keys | Where-Object { $_ -ieq 'hiberfil.sys' } | Select-Object -First 1
  if ($hib) {
    $hgb = [math]::Round($result.RootFiles[$hib] / $BytesPerGiB, 2)
    [void]$items.Add([pscustomobject]@{ label='Hibernation file'; gb=$hgb; verdict='Review'; why='Run powercfg /h off as administrator to remove it. This also turns off Hibernate and Fast Startup.'; count=1; paths=@([pscustomobject]@{ p="$Drive\$hib"; gb=$hgb; f=1 }) })
  }

  $removeCommand = {
    param([string[]]$ids, [int]$limit)
    $found = @($result.PathRule.GetEnumerator() | Where-Object { $ids -contains $_.Value -and $result.PathSizes.ContainsKey($_.Key) } | Sort-Object { $result.PathSizes[$_.Key] } -Descending | Select-Object -First $limit | ForEach-Object { $_.Key })
    if (-not $found.Count) { return '' }
    $quoted = ($found | ForEach-Object { "'" + ($_ -replace "'", "''") + "'" }) -join ",`r`n  "
    return "Remove-Item -LiteralPath $quoted -Recurse -Force"
  }

  $data = [ordered]@{
    drive = $Drive
    isSystem = $isSystem
    isAdmin = $isAdmin
    health = $health
    scannedAt = (Get-Date).ToString('d MMM yyyy, h:mm tt')
    seconds = [int]$sw.Elapsed.TotalSeconds
    totalGb = [math]::Round($disk.Size / $BytesPerGiB, 1)
    freeGb = [math]::Round($disk.FreeSpace / $BytesPerGiB, 1)
    usedGb = [math]::Round(($disk.Size - $disk.FreeSpace) / $BytesPerGiB, 1)
    countedGb = [math]::Round($result.Total / $BytesPerGiB, 1)
    files = $result.Files
    unreadable = $result.Unreadable
    sizes = $sizes
    items = @($items)
    tree = $rootNode
    buildCommand = (& $removeCommand @('build') 40)
    appCommand = (& $removeCommand @('vsix','steamweb') 10)
  }
  $json = $data | ConvertTo-Json -Depth 40 -Compress
  $static = $template.Replace('/*__DATA__*/null', $json).Replace('/*__SERVER__*/null', 'null')
  $out = Join-Path $here 'DriveLens-Report.html'
  try { [IO.File]::WriteAllText($out, $static, (New-Object Text.UTF8Encoding($false))) }
  catch { $out = Join-Path $env:TEMP 'DriveLens-Report.html'; [IO.File]::WriteAllText($out, $static, (New-Object Text.UTF8Encoding($false))) }
  Write-Host ("  Done in {0} seconds. {1} GB free of {2} GB." -f $data.seconds, $data.freeGb, $data.totalGb) -ForegroundColor Green
  return [pscustomobject]@{ Json = $json; File = $out; Allowed = $allowed }
}

function Set-Served($build) {
  $server = '{"token":"' + [SMServer]::Token + '","version":' + [SMServer]::Version + '}'
  [SMServer]::SetAllowed([string[]]$build.Allowed)
  [SMServer]::Html = $template.Replace('/*__DATA__*/null', $build.Json).Replace('/*__SERVER__*/null', $server)
}

$build = Invoke-Build

if ($NoServer) {
  if (-not $NoOpen) { Start-Process $build.File }
  return
}

[SMServer]::Token = [Guid]::NewGuid().ToString('N')
Set-Served $build
[SMServer]::Start()
$url = "http://127.0.0.1:$([SMServer]::Port)/"
Write-Host ''
Write-Host "  Dashboard: $url" -ForegroundColor Cyan
Write-Host '  Keep this window open while you use the dashboard.'
Write-Host '  It closes by itself about a minute after you close the page.'
if (-not $NoOpen) { Start-Process $url }

while ($true) {
  Start-Sleep -Milliseconds 300
  if ([SMServer]::RescanRequested) {
    [SMServer]::Scanning = $true
    [SMServer]::RescanRequested = $false
    try {
      $build = Invoke-Build
      [SMServer]::Version = [SMServer]::Version + 1
      Set-Served $build
    } catch {
      [SMServer]::ScanError = $_.Exception.Message
      Write-Host "  Rescan failed: $($_.Exception.Message)" -ForegroundColor Red
    } finally {
      [SMServer]::Scanning = $false
    }
  }
  if (-not [SMServer]::Scanning -and [SMServer]::IdleSeconds() -gt 75) { break }
}
Write-Host '  The dashboard was closed. Goodbye.'
