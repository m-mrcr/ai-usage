# Security Policy

## Reporting a vulnerability

Please do not write about a vulnerability, or about credentials/personal information being unintentionally exposed, on a public page or social media.
For this public repository, report it privately through GitHub's
[Private Vulnerability Reporting](https://github.com/moritouch/ai-usage/security/advisories/new).
Do not post unfixed vulnerabilities or secret information in a regular issue.

Where possible, please include:

- The AI Usage version and build number
- The macOS version
- A summary of the impact and reproduction steps
- The minimal error details needed, with secrets removed

Please do not send:

- OAuth tokens, Authorization headers, or Keychain contents
- Complete JSONL logs from Claude Code, Codex, or Grok
- `statusline-raw.log`, snapshots, `settings.json`, or statusLine backups
- Raw screenshots or logs containing usernames or home directory paths
- Developer ID private keys, notarization credentials, or CI secrets

## Supported versions

Security fixes are provided for the latest distributed release in principle. From AI Usage 0.1.10 onward,
you can check the signed update feed from Settings > "Check for Updates…". Only the migration to 0.1.10,
the first public release with Sparkle, requires a manual replacement — verify the SHA-256 for the same
version path against the notarized DMG on the official product page.

Apple's notarization is an automated malware and signature check; it does not represent an endorsement
or recommendation by Apple of the app's features, privacy, or overall security design.
