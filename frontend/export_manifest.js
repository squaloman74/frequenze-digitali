'use strict';

const crypto = require('crypto');

function createIntegrityManifest(csv, hwid, exportedAt = new Date().toISOString()) {
  if (typeof csv !== 'string') throw new TypeError('CSV content must be a string.');
  if (typeof hwid !== 'string' || !hwid) throw new TypeError('A device HWID is required.');

  return {
    schema_version: 1,
    algorithm: 'SHA-256',
    exported_at: exportedAt,
    hwid,
    sha256: crypto.createHash('sha256').update(csv, 'utf8').digest('hex'),
    note: 'Integrity checksum only; this manifest is not a digital signature.',
  };
}

module.exports = { createIntegrityManifest };
