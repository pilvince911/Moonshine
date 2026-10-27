# Moonshine development

Moonshine is the Windows streaming host fork. Moonlight is the client; keep the names distinct. Preserve VibeShine/Sunshine attribution and third-party notices.

- Read `README.md` and `docs/moonshine/DEVELOPMENT.md` before changing integration behavior.
- Base reference: VibeShine 2.0.1, `f078104b2b9224f080e503271dcea2a96fb573c1`. Keep upstream updates traceable.
- Keep the game library integration isolated from capture, encoding and driver changes.
- Preserve stable OPi5 UUIDs, owner/key identity, personal app settings, explicit confirmation, backups and recovery journals.
- Only known native actions may reach the worker. Credentials go through local ACL-protected named pipes after verifying the child process ID, never arguments, snapshots or logs. Revoke temporary job tokens and retain per-user execution. Do not use inherited handles across Windows sessions.
- Do not add Steam or Playnite importers alongside the Moonshine reconciler. Retain necessary launcher/runtime compatibility independently of import.
- Never run installers, change services/drivers, replace the user's current host or publish a release as part of source/CI work.
- Run `python3 tools/moonshine-dev/validate_source.py`, the native policy test, the frontend build, `tests/moonshine/Invoke-EngineTests.ps1` under Windows PowerShell 5.1 and the Windows process-bridge test as applicable. Record unavailable checks.
- Synthetic tests, an asynchronous process bridge, a source build and real Xbox/Steam/EA launches are different evidence. Do not claim a qualified installer, stream or release from a source-only result.
- No personal inventories, raw machine logs, secrets or production signing material in Git. Use the owner's Drive for private evidence and build archives.
