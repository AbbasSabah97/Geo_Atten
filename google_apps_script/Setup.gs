function setupSystem() {
  const props = PropertiesService.getScriptProperties();
  if (!props.getProperty('PIN_PEPPER')) props.setProperty('PIN_PEPPER', Utilities.getUuid() + Utilities.getUuid() + Utilities.getUuid());
  if (!props.getProperty('SESSION_PEPPER')) props.setProperty('SESSION_PEPPER', Utilities.getUuid() + Utilities.getUuid() + Utilities.getUuid());
  if (!props.getProperty('TIME_ZONE')) props.setProperty('TIME_ZONE', 'Asia/Baghdad');

  let rootFolder;
  const rootFolderId = props.getProperty('ROOT_FOLDER_ID');
  if (rootFolderId) rootFolder = DriveApp.getFolderById(rootFolderId);
  else {
    rootFolder = DriveApp.createFolder('Geo Attendance');
    props.setProperty('ROOT_FOLDER_ID', rootFolder.getId());
  }

  let backupFolder;
  const backupFolderId = props.getProperty('BACKUP_FOLDER_ID');
  if (backupFolderId) backupFolder = DriveApp.getFolderById(backupFolderId);
  else {
    backupFolder = rootFolder.createFolder('Backups');
    props.setProperty('BACKUP_FOLDER_ID', backupFolder.getId());
  }

  let ss;
  const sheetId = props.getProperty('SHEET_ID');
  if (sheetId) ss = SpreadsheetApp.openById(sheetId);
  else {
    ss = SpreadsheetApp.create('Geo Attendance Database');
    props.setProperty('SHEET_ID', ss.getId());
    DriveApp.getFileById(ss.getId()).moveTo(rootFolder);
  }

  initializeSheets_(ss);
  ensureBackupTrigger_();
  return { spreadsheet_id: ss.getId(), spreadsheet_url: ss.getUrl(), root_folder_id: rootFolder.getId(), backup_folder_id: backupFolder.getId() };
}

function initializeSheets_(ss) {
  const definitions = [
    [SHEETS.EMPLOYEES, ['employee_code','name','pin_hash','pin_salt','device_id','active','worksite_id','last_event_type','last_event_at','locked_until','failed_attempts','created_at','updated_at']],
    [SHEETS.WORKSITES, ['worksite_id','name','latitude','longitude','radius_meters','max_accuracy_meters','active']],
    [SHEETS.ATTENDANCE, ['event_id','employee_code','event_type','server_time_utc','local_date','latitude','longitude','accuracy_meters','distance_meters','accepted','reason','device_id','app_version','challenge_id','client_time_utc']],
    [SHEETS.SESSIONS, ['token_hash','employee_code','device_id','expires_at','created_at','last_seen_at','revoked']],
    [SHEETS.AUDIT, ['server_time_utc','employee_code','action','result','device_id','details']],
  ];
  definitions.forEach(function (def) {
    let sheet = ss.getSheetByName(def[0]);
    if (!sheet) sheet = ss.insertSheet(def[0]);
    sheet.getRange(1, 1, 1, def[1].length).setValues([def[1]]);
    sheet.setFrozenRows(1);
    sheet.getRange(1, 1, 1, def[1].length).setFontWeight('bold');
  });
  const defaultSheet = ss.getSheetByName('Sheet1');
  if (defaultSheet && ss.getSheets().length > definitions.length) ss.deleteSheet(defaultSheet);
}

function addWorksite(worksiteId, name, latitude, longitude, radiusMeters, maxAccuracyMeters) {
  ensureConfigured_();
  worksiteId = String(worksiteId || '').trim().toUpperCase();
  name = String(name || '').trim();
  latitude = Number(latitude); longitude = Number(longitude); radiusMeters = Number(radiusMeters); maxAccuracyMeters = Number(maxAccuracyMeters || 35);
  if (!worksiteId || !name || !Number.isFinite(latitude) || !Number.isFinite(longitude) || latitude < -90 || latitude > 90 || longitude < -180 || longitude > 180 || !Number.isFinite(radiusMeters) || radiusMeters < 10 || radiusMeters > 1000 || !Number.isFinite(maxAccuracyMeters) || maxAccuracyMeters < 5 || maxAccuracyMeters > 200) throw new Error('Invalid worksite values');
  const sheet = sheet_(SHEETS.WORKSITES), row = findExactRow_(sheet, COL.SITE.ID, worksiteId), values = [[worksiteId, name, latitude, longitude, radiusMeters, maxAccuracyMeters, true]];
  if (row) sheet.getRange(row, 1, 1, 7).setValues(values); else sheet.appendRow(values[0]);
  return { ok: true, worksite_id: worksiteId };
}

function addOrUpdateEmployee(employeeCode, name, pin, worksiteId) {
  ensureConfigured_();
  employeeCode = normalizeEmployeeCode_(employeeCode); name = String(name || '').trim(); pin = String(pin || ''); worksiteId = String(worksiteId || '').trim().toUpperCase();
  if (!employeeCode || !name || pin.length < 4 || pin.length > 32) throw new Error('Invalid employee values');
  if (!worksiteById_(worksiteId)) throw new Error('Unknown worksite');
  const employees = sheet_(SHEETS.EMPLOYEES), row = findExactRow_(employees, COL.EMP.CODE, employeeCode), now = new Date(), salt = Utilities.getUuid(), hash = pinHash_(pin, salt);
  if (row) {
    employees.getRange(row, COL.EMP.NAME).setValue(name);
    employees.getRange(row, COL.EMP.PIN_HASH).setValue(hash);
    employees.getRange(row, COL.EMP.PIN_SALT).setValue(salt);
    employees.getRange(row, COL.EMP.ACTIVE).setValue(true);
    employees.getRange(row, COL.EMP.WORKSITE_ID).setValue(worksiteId);
    employees.getRange(row, COL.EMP.FAILED_ATTEMPTS).setValue(0);
    employees.getRange(row, COL.EMP.LOCKED_UNTIL).clearContent();
    employees.getRange(row, COL.EMP.UPDATED_AT).setValue(now);
  } else employees.appendRow([employeeCode, name, hash, salt, '', true, worksiteId, '', '', '', 0, now, now]);
  return { ok: true, employee_code: employeeCode };
}

function resetEmployeeDevice(employeeCode) {
  ensureConfigured_(); employeeCode = normalizeEmployeeCode_(employeeCode);
  const employees = sheet_(SHEETS.EMPLOYEES), row = findExactRow_(employees, COL.EMP.CODE, employeeCode);
  if (!row) throw new Error('Employee not found');
  employees.getRange(row, COL.EMP.DEVICE_ID).clearContent();
  employees.getRange(row, COL.EMP.UPDATED_AT).setValue(new Date());
  revokeEmployeeSessions_(employeeCode);
  return { ok: true, employee_code: employeeCode };
}

function setEmployeeActive(employeeCode, active) {
  ensureConfigured_(); employeeCode = normalizeEmployeeCode_(employeeCode);
  const employees = sheet_(SHEETS.EMPLOYEES), row = findExactRow_(employees, COL.EMP.CODE, employeeCode);
  if (!row) throw new Error('Employee not found');
  employees.getRange(row, COL.EMP.ACTIVE).setValue(active === true);
  employees.getRange(row, COL.EMP.UPDATED_AT).setValue(new Date());
  if (active !== true) revokeEmployeeSessions_(employeeCode);
  return { ok: true, employee_code: employeeCode, active: active === true };
}

function dailyBackup() {
  ensureConfigured_();
  const props = PropertiesService.getScriptProperties(), ssId = props.getProperty('SHEET_ID'), backupFolder = DriveApp.getFolderById(props.getProperty('BACKUP_FOLDER_ID'));
  const name = 'Geo Attendance Backup ' + Utilities.formatDate(new Date(), timezone_(), 'yyyy-MM-dd HHmmss');
  DriveApp.getFileById(ssId).makeCopy(name, backupFolder);
  cleanupSessions_();
}

function cleanupSessions_() {
  const sheet = sheet_(SHEETS.SESSIONS), lastRow = sheet.getLastRow();
  if (lastRow < 2) return;
  const values = sheet.getRange(2, 1, lastRow - 1, 7).getValues(), cutoff = Date.now() - 7 * 24 * 3600 * 1000;
  for (let i = values.length - 1; i >= 0; i--) {
    const expires = parseDate_(values[i][3]), revoked = truthy_(values[i][6]);
    if ((expires && expires.getTime() < cutoff) || revoked) sheet.deleteRow(i + 2);
  }
}

function ensureBackupTrigger_() {
  const exists = ScriptApp.getProjectTriggers().some(function (trigger) { return trigger.getHandlerFunction() === 'dailyBackup'; });
  if (!exists) ScriptApp.newTrigger('dailyBackup').timeBased().everyDays(1).atHour(2).create();
}
