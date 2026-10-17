# Google Workspace backend

This backend uses Google Apps Script as the HTTPS API, Google Sheets as the live datastore, and Google Drive for the database file and automated backups.

## Security model

- PINs are never stored in plaintext. The sheet stores an HMAC-SHA256 digest with a per-user salt; the server-only pepper lives in Script Properties.
- Session tokens are random and only their HMAC hashes are stored in the Sessions sheet.
- Accounts bind to the first device ID that successfully logs in.
- Repeated failed logins trigger rate limiting and temporary account lockout.
- Punch requests use a short-lived, single-use challenge to reduce replay attacks.
- Geofence distance is calculated on the server, not trusted from the phone.
- Mock-location reports and poor GPS accuracy are rejected.
- LockService serializes critical punch writes to reduce double punches under concurrency.
- Audit events and rejected attendance attempts are stored.
- A daily Drive backup of the entire spreadsheet is created automatically.

## Setup

1. Go to https://script.google.com and create a standalone Apps Script project named `Geo Attendance API`.
2. Add `Code.gs` and `Setup.gs` from this folder. In Project Settings, enable the manifest file and replace it with `appsscript.json`.
3. Run `setupSystem()` once from the Apps Script editor and grant the requested Google Drive/Sheets permissions. It returns the created spreadsheet and Drive folder IDs/URL.
4. Add the real worksite from the editor, for example:
   `addWorksite('SITE01', 'Main Office', 32.000000, 44.000000, 50, 35)`
5. Add employees from the editor, for example:
   `addOrUpdateEmployee('EMP001', 'Employee Name', '482731', 'SITE01')`
6. Deploy > New deployment > Web app.
   - Execute as: **Me**
   - Who has access: choose the least-permissive setting that still allows your employees to call the app. If employees do not have managed Google accounts, the web app must be reachable without interactive Google sign-in; application login/session security is then enforced by this code.
7. Copy the deployed URL. It must look like `https://script.google.com/macros/s/.../exec`.
8. In GitHub Actions, run `Build Android APK` and paste that URL in `google_script_url`, or set a repository variable named `GOOGLE_SCRIPT_URL`.

## Administration helpers

- `addWorksite(...)` creates or updates a worksite.
- `addOrUpdateEmployee(...)` creates/updates an employee and safely hashes the PIN.
- `resetEmployeeDevice('EMP001')` allows the employee to bind a new device on the next login.
- `setEmployeeActive('EMP001', false)` disables the account and revokes sessions.
- `dailyBackup()` can be run manually; setup also creates a daily trigger.

Do not manually enter PIN hashes or session tokens into Sheets. Use the helper functions so security fields are generated server-side.
