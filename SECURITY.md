# Security policy

## How DriveLens handles your system

- **Read-only:** DriveLens only reads file and folder sizes. It never deletes, moves or changes files.
- **Offline:** it sends nothing over the internet and has no telemetry.
- **Local server:** while the dashboard is open, a small web server runs on `127.0.0.1`, so the page can open File Explorer and rescan. It:
  - only accepts connections from the same PC
  - requires a random one-time key that's only in your page
  - rejects requests from other websites
  - only opens locations that appear in the current scan
- **Automatic shutdown:** the server stops about a minute after you close the dashboard.

## Reporting a vulnerability

Please don't open a public issue for security problems. Report them privately through [GitHub's private vulnerability reporting](https://github.com/Umair-Habibx123/drivelens/security/advisories/new), or email umairhabibabc@gmail.com.

Include the steps to reproduce the problem and what an attacker could do. You'll get a reply within a week.

## Supported versions

Security fixes go into the latest release.
