'use strict';

const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const test = require('node:test');

const { createIntegrityManifest } = require('../export_manifest');

test('manifest hashes the exact CSV bytes and carries export metadata', () => {
  const csv = 'ora,frequenza\r\n12:00:00,432.1';
  const hwid = '2017a338715d123ad2e897b9a71419d8';
  const exportedAt = '2026-10-24T12:00:00.000Z';
  const manifest = createIntegrityManifest(csv, hwid, exportedAt);

  assert.equal(
    manifest.sha256,
    crypto.createHash('sha256').update(csv, 'utf8').digest('hex'),
  );
  assert.equal(manifest.hwid, hwid);
  assert.equal(manifest.exported_at, exportedAt);
  assert.equal(manifest.algorithm, 'SHA-256');
  assert.match(manifest.note, /not a digital signature/i);
  assert.notEqual(
    manifest.sha256,
    crypto.createHash('sha256').update(`${csv}\r\n`, 'utf8').digest('hex'),
  );
});

test('manifest requires CSV and device identity', () => {
  assert.throws(() => createIntegrityManifest(null, 'device'), TypeError);
  assert.throws(() => createIntegrityManifest('csv', ''), TypeError);
});
