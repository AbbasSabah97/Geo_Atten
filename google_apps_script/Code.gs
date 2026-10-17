const SHEETS = Object.freeze({
  EMPLOYEES: 'Employees',
  WORKSITES: 'Worksites',
  ATTENDANCE: 'Attendance',
  SESSIONS: 'Sessions',
  AUDIT: 'Audit',
});

const COL = Object.freeze({
  EMP: { CODE: 1, NAME: 2, PIN_HASH: 3, PIN_SALT: 4, DEVICE_ID: 5, ACTIVE: 6, WORKSITE_ID: 7, LAST_EVENT: 8, LAST_EVENT_AT: 9, LOCKED_UNTIL: 10, FAILED_ATTEMPTS: 11, CREATED_AT: 12, UPDATED_AT: 13 },
  SITE: { ID: 1, NAME: 2, LAT: 3, LNG: 4, RADIUS: 5, MAX_ACCURACY: 6, ACTIVE: 7 },
  SESSION: { TOKEN_HASH: 1, EMPLOYEE_CODE: 2, DEVICE_ID: 3, EXPIRES_AT: 4, CREATED_AT: 5, LAST_SEEN_AT: 6, REVOKED: 7 },
});

const SECURITY = Object.freeze({
  LOGIN_WINDOW_SECONDS: 60,
  LOGIN_MAX_ATTEMPTS_PER_WINDOW: 6,
  LOCKOUT_AFTER_FAILURES: 8,
  LOCKOUT_MINUTES: 15,
  SESSION_TTL_HOURS: 12,
  CHALLENGE_TTL_SECONDS: 120,
  MAX_HISTORY_SCAN_ROWS: 3000,
  HISTORY_LIMIT: 20,
});

function doGet() {
  return json_({ ok: true, service: 'Geo Attendance Google Workspace API', version: '0.2.0', time_utc: new Date().toISOString() });
}

function doPost(e) {
  try {
    ensureConfigured_();
    const body = parseJsonBody_(e);
    const action = String(body.action || '').trim().toLowerCase();
    switch (action) {
      case 'login': return json_(login_(body));
      case 'me': return json_(me_(body));
      case 'history': return json_(history_(body));
      case 'challenge': return json_(challenge_(body));
      case 'punch': return json_(punch_(body));
      case 'logout': return json_(logout_(body));
      default: return json_(fail_('INVALID_ACTION', 'طلب غير صالح.'));
    }
  } catch (error) {
    console.error(error && error.stack ? error.stack : error);
    return json_(fail_('SERVER_ERROR', 'حدث خطأ داخلي في خدمة الحضور.'));
  }
}

function login_(body) {
  const employeeCode = normalizeEmployeeCode_(body.employee_code);
  const pin = String(body.pin || '');
  const deviceId = normalizeDeviceId_(body.device_id);
  if (!employeeCode || pin.length < 4 || !deviceId) return fail_('INVALID_CREDENTIALS', 'رمز الموظف أو الرمز السري غير صحيح.');
  if (!consumeLoginRateLimit_(employeeCode, deviceId)) {
    audit_(employeeCode, 'login', 'rate_limited', deviceId, 'Too many attempts');
    return fail_('RATE_LIMITED', 'محاولات كثيرة. انتظر دقيقة ثم حاول مرة أخرى.');
  }
  const employees = sheet_(SHEETS.EMPLOYEES);
  const row = findExactRow_(employees, COL.EMP.CODE, employeeCode);
  if (!row) {
    audit_(employeeCode, 'login', 'failed', deviceId, 'Unknown employee code');
    return fail_('INVALID_CREDENTIALS', 'رمز الموظف أو الرمز السري غير صحيح.');
  }
  const values = employees.getRange(row, 1, 1, 13).getValues()[0];
  if (!truthy_(values[COL.EMP.ACTIVE - 1])) return fail_('ACCOUNT_DISABLED', 'الحساب غير مفعل. راجع الإدارة.');
  const lockedUntil = parseDate_(values[COL.EMP.LOCKED_UNTIL - 1]);
  if (lockedUntil && lockedUntil.getTime() > Date.now()) return fail_('ACCOUNT_LOCKED', 'تم إيقاف تسجيل الدخول مؤقتاً بسبب المحاولات الفاشلة.');
  const salt = String(values[COL.EMP.PIN_SALT - 1] || '');
  const storedHash = String(values[COL.EMP.PIN_HASH - 1] || '');
  if (!constantTimeEquals_(storedHash, pinHash_(pin, salt))) {
    const failures = Number(values[COL.EMP.FAILED_ATTEMPTS - 1] || 0) + 1;
    employees.getRange(row, COL.EMP.FAILED_ATTEMPTS).setValue(failures);
    if (failures >= SECURITY.LOCKOUT_AFTER_FAILURES) {
      employees.getRange(row, COL.EMP.LOCKED_UNTIL).setValue(new Date(Date.now() + SECURITY.LOCKOUT_MINUTES * 60 * 1000));
      employees.getRange(row, COL.EMP.FAILED_ATTEMPTS).setValue(0);
    }
    employees.getRange(row, COL.EMP.UPDATED_AT).setValue(new Date());
    audit_(employeeCode, 'login', 'failed', deviceId, 'Invalid PIN');
    return fail_('INVALID_CREDENTIALS', 'رمز الموظف أو الرمز السري غير صحيح.');
  }
  const lock = LockService.getScriptLock();
  lock.waitLock(10000);
  try {
    const existingDevice = String(employees.getRange(row, COL.EMP.DEVICE_ID).getValue() || '');
    if (existingDevice && existingDevice !== deviceId) {
      audit_(employeeCode, 'login', 'blocked', deviceId, 'Device mismatch');
      return fail_('DEVICE_MISMATCH', 'هذا الحساب مرتبط بجهاز آخر. راجع الإدارة لإعادة ربط الجهاز.');
    }
    if (!existingDevice) employees.getRange(row, COL.EMP.DEVICE_ID).setValue(deviceId);
    employees.getRange(row, COL.EMP.FAILED_ATTEMPTS).setValue(0);
    employees.getRange(row, COL.EMP.LOCKED_UNTIL).clearContent();
    employees.getRange(row, COL.EMP.UPDATED_AT).setValue(new Date());
    revokeEmployeeSessions_(employeeCode);
    const token = createSession_(employeeCode, deviceId);
    audit_(employeeCode, 'login', 'success', deviceId, '');
    return ok_({ access_token: token, token_type: 'bearer', expires_in_seconds: SECURITY.SESSION_TTL_HOURS * 3600, employee: employeeSummaryFromRow_(row) });
  } finally { lock.releaseLock(); }
}

function me_(body) {
  const session = authenticate_(body);
  if (!session.ok) return session;
  const employee = employeeByCode_(session.employee_code);
  if (!employee) return fail_('SESSION_INVALID', 'الحساب غير متاح.');
  const site = worksiteById_(employee.worksite_id);
  if (!site) return fail_('WORKSITE_NOT_FOUND', 'لم يتم تعيين موقع عمل صالح لهذا الموظف.');
  return ok_({ name: employee.name, employee_code: employee.employee_code, worksite_id: site.worksite_id, worksite_name: site.name, worksite_radius_meters: site.radius_meters, max_accuracy_meters: site.max_accuracy_meters });
}

function history_(body) {
  const session = authenticate_(body);
  if (!session.ok) return session;
  const sheet = sheet_(SHEETS.ATTENDANCE);
  const lastRow = sheet.getLastRow();
  if (lastRow < 2) return ok_({ items: [] });
  const count = Math.min(lastRow - 1, SECURITY.MAX_HISTORY_SCAN_ROWS);
  const values = sheet.getRange(lastRow - count + 1, 1, count, 15).getValues();
  const items = [];
  for (let i = values.length - 1; i >= 0 && items.length < SECURITY.HISTORY_LIMIT; i--) {
    const r = values[i];
    if (String(r[1]) !== session.employee_code) continue;
    items.push({ event_id: String(r[0]), event_type: String(r[2]), created_at: iso_(r[3]), latitude: Number(r[5]), longitude: Number(r[6]), accuracy_meters: Number(r[7]), distance_meters: Number(r[8]), accepted: truthy_(r[9]), reason: String(r[10] || '') });
  }
  return ok_({ items: items });
}

function challenge_(body) {
  const session = authenticate_(body);
  if (!session.ok) return session;
  const challengeId = Utilities.getUuid();
  CacheService.getScriptCache().put('challenge:' + challengeId, JSON.stringify({ employee_code: session.employee_code, device_id: session.device_id, issued_at: Date.now() }), SECURITY.CHALLENGE_TTL_SECONDS);
  return ok_({ challenge_id: challengeId, expires_in_seconds: SECURITY.CHALLENGE_TTL_SECONDS, server_time_utc: new Date().toISOString() });
}

function punch_(body) {
  const session = authenticate_(body);
  if (!session.ok) return session;
  const eventType = String(body.event_type || '').trim();
  if (eventType !== 'check_in' && eventType !== 'check_out') return fail_('INVALID_EVENT', 'نوع العملية غير صالح.');
  const challengeId = String(body.challenge_id || '').trim();
  const challengeCheck = consumeChallenge_(challengeId, session.employee_code, session.device_id);
  if (!challengeCheck.ok) return challengeCheck;
  const latitude = Number(body.latitude), longitude = Number(body.longitude), accuracy = Number(body.accuracy_meters), isMocked = body.is_mocked === true;
  if (!Number.isFinite(latitude) || latitude < -90 || latitude > 90 || !Number.isFinite(longitude) || longitude < -180 || longitude > 180 || !Number.isFinite(accuracy) || accuracy <= 0) return fail_('INVALID_LOCATION', 'بيانات الموقع غير صالحة.');
  const employee = employeeByCode_(session.employee_code);
  if (!employee || !employee.active) return fail_('ACCOUNT_DISABLED', 'الحساب غير مفعل.');
  if (employee.device_id !== session.device_id) return fail_('DEVICE_MISMATCH', 'الجهاز غير معتمد لهذا الحساب.');
  const site = worksiteById_(employee.worksite_id);
  if (!site || !site.active) return fail_('WORKSITE_DISABLED', 'موقع العمل غير مفعل.');
  let accepted = true, reason = '';
  const distance = haversineMeters_(latitude, longitude, site.latitude, site.longitude);
  if (isMocked) { accepted = false; reason = 'تم اكتشاف موقع وهمي Mock Location.'; }
  else if (accuracy > site.max_accuracy_meters) { accepted = false; reason = 'دقة الموقع غير كافية. انتظر GPS ثم أعد المحاولة.'; }
  else if (distance > site.radius_meters) { accepted = false; reason = 'أنت خارج النطاق الجغرافي المسموح لموقع العمل.'; }
  const lock = LockService.getScriptLock();
  lock.waitLock(15000);
  try {
    const freshEmployee = employeeByCode_(session.employee_code);
    if (!freshEmployee) return fail_('ACCOUNT_DISABLED', 'الحساب غير متاح.');
    if (accepted && eventType === 'check_in' && freshEmployee.last_event_type === 'check_in') { accepted = false; reason = 'تم تسجيل الحضور مسبقاً. يجب تسجيل الانصراف أولاً.'; }
    if (accepted && eventType === 'check_out' && freshEmployee.last_event_type !== 'check_in') { accepted = false; reason = 'لا يوجد حضور مفتوح لتسجيل الانصراف.'; }
    const now = new Date(), eventId = Utilities.getUuid(), localDate = Utilities.formatDate(now, timezone_(), 'yyyy-MM-dd');
    sheet_(SHEETS.ATTENDANCE).appendRow([eventId, session.employee_code, eventType, now, localDate, latitude, longitude, accuracy, distance, accepted, reason, session.device_id, String(body.app_version || ''), challengeId, String(body.client_time_utc || '')]);
    if (accepted) {
      const employees = sheet_(SHEETS.EMPLOYEES);
      employees.getRange(freshEmployee.row, COL.EMP.LAST_EVENT).setValue(eventType);
      employees.getRange(freshEmployee.row, COL.EMP.LAST_EVENT_AT).setValue(now);
      employees.getRange(freshEmployee.row, COL.EMP.UPDATED_AT).setValue(now);
    }
    audit_(session.employee_code, eventType, accepted ? 'accepted' : 'rejected', session.device_id, JSON.stringify({ distance_meters: distance, accuracy_meters: accuracy, reason: reason }));
    return ok_({ accepted: accepted, reason: reason, event_id: eventId, event_type: eventType, created_at: now.toISOString(), distance_meters: distance, accuracy_meters: accuracy, worksite_radius_meters: site.radius_meters });
  } finally { lock.releaseLock(); }
}

function logout_(body) { const token = String(body.session_token || '').trim(); if (token) revokeSessionToken_(token); return ok_({ logged_out: true }); }

function authenticate_(body) {
  const token = String(body.session_token || '').trim(), deviceId = normalizeDeviceId_(body.device_id);
  if (!token || !deviceId) return fail_('UNAUTHORIZED', 'انتهت جلسة الدخول.');
  const sessions = sheet_(SHEETS.SESSIONS), tokenHash = sessionTokenHash_(token), row = findExactRow_(sessions, COL.SESSION.TOKEN_HASH, tokenHash);
  if (!row) return fail_('UNAUTHORIZED', 'انتهت جلسة الدخول.');
  const values = sessions.getRange(row, 1, 1, 7).getValues()[0];
  if (truthy_(values[COL.SESSION.REVOKED - 1])) return fail_('UNAUTHORIZED', 'انتهت جلسة الدخول.');
  if (String(values[COL.SESSION.DEVICE_ID - 1]) !== deviceId) return fail_('DEVICE_MISMATCH', 'الجلسة لا تخص هذا الجهاز.');
  const expiresAt = parseDate_(values[COL.SESSION.EXPIRES_AT - 1]);
  if (!expiresAt || expiresAt.getTime() <= Date.now()) { sessions.getRange(row, COL.SESSION.REVOKED).setValue(true); return fail_('UNAUTHORIZED', 'انتهت صلاحية جلسة الدخول.'); }
  sessions.getRange(row, COL.SESSION.LAST_SEEN_AT).setValue(new Date());
  return { ok: true, employee_code: String(values[COL.SESSION.EMPLOYEE_CODE - 1]), device_id: deviceId, session_row: row };
}

function consumeChallenge_(challengeId, employeeCode, deviceId) {
  if (!challengeId) return fail_('CHALLENGE_REQUIRED', 'تعذر التحقق من الطلب. حاول مرة أخرى.');
  const cache = CacheService.getScriptCache(), key = 'challenge:' + challengeId, lock = LockService.getScriptLock();
  lock.waitLock(5000);
  try {
    const raw = cache.get(key);
    if (!raw) return fail_('CHALLENGE_EXPIRED', 'انتهت صلاحية التحقق الأمني. حاول مرة أخرى.');
    cache.remove(key);
    const data = JSON.parse(raw);
    if (data.employee_code !== employeeCode || data.device_id !== deviceId) return fail_('CHALLENGE_INVALID', 'فشل التحقق الأمني من الطلب.');
    return { ok: true };
  } finally { lock.releaseLock(); }
}

function createSession_(employeeCode, deviceId) {
  const token = Utilities.getUuid() + '.' + Utilities.getUuid() + '.' + Utilities.getUuid(), now = new Date(), expiresAt = new Date(now.getTime() + SECURITY.SESSION_TTL_HOURS * 3600 * 1000);
  sheet_(SHEETS.SESSIONS).appendRow([sessionTokenHash_(token), employeeCode, deviceId, expiresAt, now, now, false]);
  return token;
}

function revokeEmployeeSessions_(employeeCode) { const sheet = sheet_(SHEETS.SESSIONS), lastRow = sheet.getLastRow(); if (lastRow < 2) return; const values = sheet.getRange(2, 1, lastRow - 1, 7).getValues(); for (let i = values.length - 1; i >= 0; i--) if (String(values[i][1]) === employeeCode && !truthy_(values[i][6])) sheet.getRange(i + 2, COL.SESSION.REVOKED).setValue(true); }
function revokeSessionToken_(token) { const sessions = sheet_(SHEETS.SESSIONS), row = findExactRow_(sessions, COL.SESSION.TOKEN_HASH, sessionTokenHash_(token)); if (row) sessions.getRange(row, COL.SESSION.REVOKED).setValue(true); }
function employeeByCode_(employeeCode) { const sheet = sheet_(SHEETS.EMPLOYEES), row = findExactRow_(sheet, COL.EMP.CODE, employeeCode); if (!row) return null; const r = sheet.getRange(row, 1, 1, 13).getValues()[0]; return { row: row, employee_code: String(r[0]), name: String(r[1]), device_id: String(r[4] || ''), active: truthy_(r[5]), worksite_id: String(r[6] || ''), last_event_type: String(r[7] || ''), last_event_at: iso_(r[8]) }; }
function employeeSummaryFromRow_(row) { const current = sheet_(SHEETS.EMPLOYEES).getRange(row, 1, 1, 13).getValues()[0]; return { employee_code: String(current[0]), name: String(current[1]), worksite_id: String(current[6] || '') }; }
function worksiteById_(worksiteId) { if (!worksiteId) return null; const sheet = sheet_(SHEETS.WORKSITES), row = findExactRow_(sheet, COL.SITE.ID, worksiteId); if (!row) return null; const r = sheet.getRange(row, 1, 1, 7).getValues()[0], lat = Number(r[2]), lng = Number(r[3]), radius = Number(r[4]), maxAccuracy = Number(r[5]); if (!Number.isFinite(lat) || !Number.isFinite(lng) || !Number.isFinite(radius) || !Number.isFinite(maxAccuracy)) return null; return { worksite_id: String(r[0]), name: String(r[1]), latitude: lat, longitude: lng, radius_meters: radius, max_accuracy_meters: maxAccuracy, active: truthy_(r[6]) }; }
function consumeLoginRateLimit_(employeeCode, deviceId) { const cache = CacheService.getScriptCache(), digest = sha256Hex_(employeeCode + '|' + deviceId).slice(0, 24), key = 'login-rate:' + digest, count = Number(cache.get(key) || 0) + 1; cache.put(key, String(count), SECURITY.LOGIN_WINDOW_SECONDS); return count <= SECURITY.LOGIN_MAX_ATTEMPTS_PER_WINDOW; }
function findExactRow_(sheet, column, value) { const lastRow = sheet.getLastRow(); if (lastRow < 2) return 0; const finder = sheet.getRange(2, column, lastRow - 1, 1).createTextFinder(String(value)).matchEntireCell(true).matchCase(true).findNext(); return finder ? finder.getRow() : 0; }
function audit_(employeeCode, action, result, deviceId, details) { try { sheet_(SHEETS.AUDIT).appendRow([new Date(), employeeCode || '', action || '', result || '', deviceId || '', details || '']); } catch (error) { console.error('Audit write failed: ' + error); } }
function pinHash_(pin, salt) { return hmacHex_(salt + '|' + String(pin), property_('PIN_PEPPER')); }
function sessionTokenHash_(token) { return hmacHex_(String(token), property_('SESSION_PEPPER')); }
function hmacHex_(value, key) { const bytes = Utilities.computeHmacSha256Signature(String(value), String(key)); return bytes.map(function (b) { const v = b < 0 ? b + 256 : b; return ('0' + v.toString(16)).slice(-2); }).join(''); }
function sha256Hex_(value) { const bytes = Utilities.computeDigest(Utilities.DigestAlgorithm.SHA_256, String(value)); return bytes.map(function (b) { const v = b < 0 ? b + 256 : b; return ('0' + v.toString(16)).slice(-2); }).join(''); }
function constantTimeEquals_(a, b) { a = String(a || ''); b = String(b || ''); if (a.length !== b.length || a.length === 0) return false; let result = 0; for (let i = 0; i < a.length; i++) result |= a.charCodeAt(i) ^ b.charCodeAt(i); return result === 0; }
function haversineMeters_(lat1, lon1, lat2, lon2) { const r = 6371000, toRad = function (d) { return d * Math.PI / 180; }, p1 = toRad(lat1), p2 = toRad(lat2), dp = toRad(lat2 - lat1), dl = toRad(lon2 - lon1), a = Math.sin(dp / 2) * Math.sin(dp / 2) + Math.cos(p1) * Math.cos(p2) * Math.sin(dl / 2) * Math.sin(dl / 2); return 2 * r * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a)); }
function parseJsonBody_(e) { if (!e || !e.postData || !e.postData.contents) throw new Error('Missing body'); const body = JSON.parse(e.postData.contents); if (!body || typeof body !== 'object') throw new Error('Invalid body'); return body; }
function normalizeEmployeeCode_(value) { return String(value || '').trim().toUpperCase().replace(/[^A-Z0-9_-]/g, '').slice(0, 40); }
function normalizeDeviceId_(value) { return String(value || '').trim().replace(/[^A-Za-z0-9._:-]/g, '').slice(0, 120); }
function truthy_(value) { return value === true || String(value).toLowerCase() === 'true' || Number(value) === 1; }
function parseDate_(value) { if (!value) return null; if (Object.prototype.toString.call(value) === '[object Date]' && !isNaN(value.getTime())) return value; const d = new Date(value); return isNaN(d.getTime()) ? null : d; }
function iso_(value) { const d = parseDate_(value); return d ? d.toISOString() : ''; }
function timezone_() { return PropertiesService.getScriptProperties().getProperty('TIME_ZONE') || 'Asia/Baghdad'; }
function ensureConfigured_() { const props = PropertiesService.getScriptProperties(); if (!props.getProperty('SHEET_ID') || !props.getProperty('PIN_PEPPER') || !props.getProperty('SESSION_PEPPER')) throw new Error('System not configured. Run setupSystem() first.'); }
function property_(name) { const value = PropertiesService.getScriptProperties().getProperty(name); if (!value) throw new Error('Missing script property: ' + name); return value; }
function sheet_(name) { const sheet = SpreadsheetApp.openById(property_('SHEET_ID')).getSheetByName(name); if (!sheet) throw new Error('Missing sheet: ' + name); return sheet; }
function ok_(data) { return Object.assign({ ok: true }, data || {}); }
function fail_(code, message) { return { ok: false, code: code, message: message }; }
function json_(data) { return ContentService.createTextOutput(JSON.stringify(data)).setMimeType(ContentService.MimeType.JSON); }
