import { readFileSync, writeFileSync, unlinkSync, existsSync } from 'fs';
import { execSync } from 'child_process';
import workerModule from '../tools/relay/worker.js';

console.log('=== Running Browser Beam Interoperability & Worker Tests ===\n');

let passed = 0;
let failed = 0;

function assert(condition, message) {
  if (condition) {
    console.log(`  PASS: ${message}`);
    passed++;
  } else {
    console.error(`  FAIL: ${message}`);
    failed++;
  }
}

// --------------------------------------------------------------------------
// Test 1: Worker Health Check (JSON)
// --------------------------------------------------------------------------
console.log('Test 1: Worker Health Check Endpoint');
try {
  const reqHealth = new Request('https://backup.ultimatejimmy.workers.dev/health');
  const env = { BEAM_KV: {}, GDRIVE_CLIENT_SECRET: 'test' };
  const resp = await workerModule.fetch(reqHealth, env, {});
  assert(resp.status === 200, 'GET /health returns HTTP 200');
  assert(resp.headers.get('Content-Type').includes('application/json'), 'GET /health Content-Type is application/json');
  const data = await resp.json();
  assert(data.status === 'ok' && data.version === '2.5', 'Health check data status ok and version 2.5');
} catch (e) {
  assert(false, 'Worker health check failed: ' + e.message);
}

// --------------------------------------------------------------------------
// Test 2: Worker Web Portal (HTML)
// --------------------------------------------------------------------------
console.log('\nTest 2: Worker Web Portal Route');
try {
  const reqRoot = new Request('https://backup.ultimatejimmy.workers.dev/', {
    headers: { 'Accept': 'text/html,application/xhtml+xml' }
  });
  const env = { BEAM_KV: {} };
  const resp = await workerModule.fetch(reqRoot, env, {});
  assert(resp.status === 200, 'GET / returns HTTP 200');
  assert(resp.headers.get('Content-Type').includes('text/html'), 'GET / Content-Type is text/html');
  const html = await resp.text();
  assert(html.includes('KOReader Beam'), 'HTML contains KOReader Beam branding');
  assert(html.includes('decryptBeamPayload'), 'HTML embeds client-side decryption engine');
  assert(html.includes('id="pin-input"'), 'HTML contains pin input field');
} catch (e) {
  assert(false, 'Worker portal route failed: ' + e.message);
}

// --------------------------------------------------------------------------
// Test 3: Worker Web Portal with Query Param ?code=482910
// --------------------------------------------------------------------------
console.log('\nTest 3: Query Parameter Pre-population');
try {
  const reqParam = new Request('https://backup.ultimatejimmy.workers.dev/beam?code=482910', {
    headers: { 'Accept': 'text/html' }
  });
  const resp = await workerModule.fetch(reqParam, {}, {});
  const html = await resp.text();
  assert(html.includes('"482910"'), 'HTML pre-populates initial code from ?code parameter');
} catch (e) {
  assert(false, 'Worker query parameter test failed: ' + e.message);
}

// --------------------------------------------------------------------------
// Test 4: End-to-End Cryptographic Compatibility (Lua Encryption -> JS Decryption)
// --------------------------------------------------------------------------
console.log('\nTest 4: Cross-Platform Encryption/Decryption Compatibility');
try {
  // Use WSL luajit to encrypt a known zip payload with backup_beam.lua
  const tmpEncPath = '/tmp/test_interop_beam.kobeam';
  const testPin = '739281';
  const testFilename = 'koreader_backup_20261006.zip';
  const testContent = 'PK_ZIP_HEADER_SIMULATED_CONTENT_FOR_INTEROP_TESTING_1234567890';

  const luaScript = `
    package.path = package.path .. ";./backup.koplugin/?.lua;./backup.koplugin/backup.koplugin/?.lua"
    local koreader_bases = { "/home/jimmy/squashfs-root/usr/lib/koreader" }
    for _, b in ipairs(koreader_bases) do
      package.path = package.path .. ";" .. b .. "/?.lua;" .. b .. "/ffi/?.lua;" .. b .. "/frontend/?.lua;" .. b .. "/libs/?.lua"
      package.cpath = package.cpath .. ";" .. b .. "/libs/?.so;" .. b .. "/libs/libkoreader-?.so"
    end
    package.loaded["gettext"] = function(s) return s end
    package.loaded["logger"] = { info = function() end, warn = function() end, err = function() end }
    local Beam = require("backup_beam")
    local enc = Beam.encryptPayload("${testContent}", "${testPin}", "${testFilename}")
    local f = io.open("${tmpEncPath}", "wb")
    f:write(enc)
    f:close()
  `;

  const scriptPath = 'C:/Users/Jimmy/.gemini/antigravity/brain/207446ba-0f9b-482e-a9db-2ac2aa2678df/scratch/test_gen.lua';
  writeFileSync(scriptPath, luaScript, 'utf8');

  execSync(`wsl bash -c "cd /mnt/c/Users/Jimmy/Documents/backup && /home/jimmy/squashfs-root/usr/lib/koreader/luajit /mnt/c/Users/Jimmy/.gemini/antigravity/brain/207446ba-0f9b-482e-a9db-2ac2aa2678df/scratch/test_gen.lua"`);

  // Read back the encrypted binary in Node.js
  const localTmp = 'C:/Users/Jimmy/.gemini/antigravity/brain/207446ba-0f9b-482e-a9db-2ac2aa2678df/scratch/test_interop.kobeam';
  execSync(`wsl cp ${tmpEncPath} /mnt/c/Users/Jimmy/.gemini/antigravity/brain/207446ba-0f9b-482e-a9db-2ac2aa2678df/scratch/test_interop.kobeam`);

  const encryptedBuf = readFileSync(localTmp);
  assert(encryptedBuf.length > testContent.length + 108, 'Encrypted payload size includes header and ciphertext');

  // Import decrypt function from scratch/beam_crypto.mjs
  const { decryptBeamPayload } = await import('file:///C:/Users/Jimmy/.gemini/antigravity/brain/207446ba-0f9b-482e-a9db-2ac2aa2678df/scratch/beam_crypto.mjs');
  const result = decryptBeamPayload(encryptedBuf, testPin);

  assert(result.filename === testFilename, 'Decrypted filename matches original: ' + result.filename);
  const decryptedText = new TextDecoder().decode(result.bytes);
  assert(decryptedText === testContent, 'Decrypted content bit-for-bit matches original plaintext');

  // Test Tampered Payload Detection
  const tamperedBuf = new Uint8Array(encryptedBuf);
  tamperedBuf[tamperedBuf.length - 1] ^= 0xff; // flip last bit
  let tamperCaught = false;
  try {
    decryptBeamPayload(tamperedBuf, testPin);
  } catch (err) {
    tamperCaught = true;
  }
  assert(tamperCaught, 'Tampered ciphertext rejected by HMAC verification');

  // Test Wrong PIN Detection
  let wrongPinCaught = false;
  try {
    decryptBeamPayload(encryptedBuf, '999999');
  } catch (err) {
    wrongPinCaught = true;
  }
  assert(wrongPinCaught, 'Incorrect PIN rejected by HMAC verification');

  // Clean up
  try { execSync(`wsl rm -f ${tmpEncPath}`); } catch (_) {}
} catch (e) {
  assert(false, 'Cryptographic compatibility test failed: ' + e.message);
}

// --------------------------------------------------------------------------
// Summary
// --------------------------------------------------------------------------
console.log(`\n=== Results: ${passed} Passed, ${failed} Failed ===`);
if (failed > 0) process.exit(1);
