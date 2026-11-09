# Contributing to DriveLens

Thanks for helping make DriveLens better. Bug reports, ideas and pull requests are all welcome.

## Report a bug or suggest an idea

[Open an issue](https://github.com/Umair-Habibx123/drivelens/issues/new/choose) and pick a template. For bugs, include:
- your Windows version
- whether you ran DriveLens as administrator
- any message shown in the console window

Don't paste your scan report, because it lists your folder names.

## Add a detection rule

Most improvements are new rules: a cache or folder that DriveLens should flag. Rules live in the `$rules` list near the top of `DriveLens.ps1`:

```powershell
@{ id='yarn'; label='Yarn cache'; verdict='Safe'; why='Packages Yarn can download again.'; paths=@("$la\Yarn\Cache") }
```

| Field | Meaning |
|---|---|
| `id` | Short unique name |
| `label` | What people see in the dashboard |
| `verdict` | `Safe` (rebuilds itself), `Review` (check first) or `Keep` (never delete by hand) |
| `why` | One plain sentence explaining the verdict |
| `paths` | Exact folders to match |
| `names` | Folder names to match anywhere outside system and app folders, such as `node_modules` |

Only mark something `Safe` if deleting it can never lose someone's work.

## Make a change

1. Fork the repository and create a branch.
2. Make your change, then run DriveLens on your own PC to check it:
   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File .\DriveLens.ps1
   ```
3. Open a pull request that describes what changed and why.

Automatic checks run on every pull request. They lint the PowerShell, scan a drive on Windows and check that the dashboard's JavaScript parses.

## Guidelines

- **Never delete:** DriveLens itself must never delete, move or change files.
- **No dependencies:** keep it working on stock Windows PowerShell 5.1, with nothing to install.
- **Plain language:** write UI text that anyone can understand.
