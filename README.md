# DriveLens

**Find out what's filling your Windows drive, and which parts are safe to delete.**

[![CI](https://github.com/Umair-Habibx123/DriveLens/actions/workflows/ci.yml/badge.svg)](https://github.com/Umair-Habibx123/DriveLens/actions/workflows/ci.yml)
[![Latest release](https://img.shields.io/github/v/release/Umair-Habibx123/DriveLens?label=release)](https://github.com/Umair-Habibx123/DriveLens/releases/latest)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue)](LICENSE)

**Status:** v1.0.0, released November 2026, actively maintained. Tested on Windows 11, and on Windows Server in CI. It should also work on Windows 10, but that hasn't been tested yet.

DriveLens scans a drive and opens a dashboard in your browser. It shows which folders use the most space, labels each one as safe to delete or worth checking first, and gives you cleanup steps. Right-click anything to open it in File Explorer. It only reads your drive and never deletes anything itself.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/screenshots/overview-dark.png">
  <img alt="DriveLens overview: free and used space, drive health, a treemap of the biggest folders and a details panel" src="docs/screenshots/overview-light.png">
</picture>

<sub>Screenshots use demo data.</sub>

## Quick start

1. Download `DriveLens-vX.Y.Z.zip` from the **[latest release](https://github.com/Umair-Habibx123/DriveLens/releases/latest)** and extract it.
2. Double-click **`DriveLens.cmd`**.
3. The dashboard opens in your browser when the scan finishes. A full 240 GB drive with 1.7 million files took 20 to 50 seconds on the author's PC.

Keep the small console window open while you use the dashboard, because it powers the File Explorer and Rescan buttons. It closes by itself about a minute after you close the page.

To run it from PowerShell instead, open the extracted folder and run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\DriveLens.ps1
```

## Why DriveLens

Tools like WinDirStat, WizTree and TreeSize show you **where** the space went. DriveLens also tells you **what you can safely do about it**:

- **Verdicts with reasons:** every flagged folder is marked green (safe to delete) or yellow (check first), with a plain-language explanation.
- **Developer caches:** it recognizes space that general tools don't label, such as the npm, pip, uv, Gradle and NuGet caches, `node_modules`, Python environments, `.next` build folders, Docker data and AI model caches.
- **A cleanup guide:** it gives steps and copy-ready commands with the current size of each, plus which Disk Cleanup options are safe to tick.
- **Nothing to install:** it's a PowerShell script and an HTML page you can read in full, with no executable to trust.

**When to use something else:**
- **Every file, or the fastest scan:** WizTree reads the drive's file table directly, so it's much faster on huge drives and lists individual files. DriveLens works at folder level.
- **Deleting from inside the tool:** DriveLens never deletes anything itself. You use File Explorer or the provided commands.
- **Duplicate files:** DriveLens doesn't look for them.

## What it finds

| Color | Meaning | Examples |
|---|---|---|
| 🟩 Green | **Safe to delete.** It rebuilds itself. | Temp files, browser caches, npm, pip, uv and Yarn caches, `.next` and other build output |
| 🟨 Yellow | **Needs review.** It could be safe, but check first. | `node_modules`, Python environments, Gradle and NuGet caches, Docker data, Hugging Face and Ollama models, Downloads, Recycle Bin, hibernation file |
| ⬜ Gray | **Everything else.** Leave it unless you know what it is. | Windows, installed apps, your documents |

To flag something else, add a rule in `DriveLens.ps1`. [CONTRIBUTING.md](CONTRIBUTING.md) shows how.

## The dashboard

- **Treemap:** shows the biggest folders at each level. Double-click to look inside, and use the breadcrumb or Backspace to go back.
- **Details panel:** click any box to see its size, location, verdict and largest subfolders.
- **Right-click menu:** open a folder in File Explorer, show it in its parent folder, or copy its path.
- **Drive health:** shows free space status, disk and file system health, and SSD wear and temperature when Windows reports them.
- **Clean up tab:** lists every step with its size, plus every flagged item with all of its locations.
- **Rescan:** see how much you recovered without restarting.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/screenshots/right-click-dark.png">
  <img alt="Right-click menu on a project folder with Open in File Explorer, Show in parent folder, Copy path and Look inside" src="docs/screenshots/right-click-light.png">
</picture>

<details>
<summary>See the cleanup guide</summary>

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/screenshots/cleanup-dark.png">
  <img alt="Clean up tab with numbered steps, sizes for each step, Disk Cleanup advice and copy-ready commands" src="docs/screenshots/cleanup-light.png">
</picture>

</details>

## Safety and privacy

- **Read-only:** DriveLens never deletes, moves or changes your files.
- **Offline:** nothing leaves your PC. There's no telemetry, account or internet connection.
- **Locked-down local server:** the page talks to a small server on `127.0.0.1`. It accepts connections from your own PC only, needs a one-time key, and only opens locations from the current scan. [SECURITY.md](SECURITY.md) has the details.
- **One file written:** the only file it writes is `DriveLens-Report.html` in its own folder. It lists your folder names, so don't share it publicly.

## Options

DriveLens scans the drive it's on, so to scan another drive, copy the folder there, such as `D:\DriveLens`. Or pass options:

| Option | What it does |
|---|---|
| `-Drive E` | Scan drive E instead |
| `-NoServer` | Only write the report file, without the File Explorer and Rescan buttons |
| `-NoOpen` | Don't open the browser |

Right-click `DriveLens.cmd` and choose **Run as administrator** to measure protected folders, such as the Windows Update cache, and to show SSD wear and temperature.

## Requirements and limits

- **Windows PowerShell 5.1** (included with Windows) and any modern browser. No admin rights required.
- **Folder-level scan:** small folders are grouped together.
- **Protected folders:** without admin rights, some system folders are skipped.
- **Drive health:** it shows what Windows reports, not a full disk test.
- **Uninstall:** delete the DriveLens folder. Nothing is installed or written anywhere else.

## Contributing

Bug reports, detection ideas and pull requests are welcome:
- [CONTRIBUTING.md](CONTRIBUTING.md) explains how to add a rule.
- [CHANGELOG.md](CHANGELOG.md) lists what changed in each release.
- [SECURITY.md](SECURITY.md) explains how to report a security problem privately.

## License

[MIT](LICENSE) © 2026 [Umair Habib](https://github.com/Umair-Habibx123). If DriveLens saved you some space, a ⭐ helps others find it.
