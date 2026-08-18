import express from 'express';
import multer from 'multer';
import crypto from 'node:crypto';
import fs from 'node:fs/promises';
import {execFile} from 'node:child_process';
import {promisify} from 'node:util';
import path from 'node:path';
import {fileURLToPath} from 'node:url';

const execFileAsync = promisify(execFile);
const app = express();
const upload = multer({dest: process.env.UPLOAD_DIR || '/tmp/sidestore-web', limits: {fileSize: 1024 * 1024 * 1024}});
const jobs = new Map();
const root = path.dirname(fileURLToPath(import.meta.url));
const publicRoot = path.join(root, 'public');
const port = Number(process.env.PORT || 8787);
const origin = process.env.PUBLIC_ORIGIN || `http://localhost:${port}`;
const adapter = process.env.SIGNER_URL || '';

app.disable('x-powered-by');
app.use(express.json({limit: '1mb'}));
app.use((req, res, next) => {
  res.setHeader('Access-Control-Allow-Origin', process.env.WEB_ORIGIN || '*');
  res.setHeader('Access-Control-Allow-Headers', 'Content-Type, Authorization');
  res.setHeader('Access-Control-Allow-Methods', 'GET,POST,OPTIONS');
  if (req.method === 'OPTIONS') return res.sendStatus(204);
  next();
});
app.use('/v1', (req, res, next) => {
  if (process.env.API_TOKEN && req.get('authorization') !== `Bearer ${process.env.API_TOKEN}`) return res.status(401).json({error: 'Unauthorized'});
  next();
});

function id() { return crypto.randomUUID(); }
async function adapterCall(endpoint, payload) {
  if (!adapter) throw new Error('SIGNER_URL is not configured.');
  const r = await fetch(adapter.replace(/\/$/, '') + endpoint, {
    method: 'POST', headers: {'Content-Type': 'application/json'}, body: JSON.stringify(payload)
  });
  const d = await r.json().catch(() => ({}));
  if (!r.ok) throw new Error(d.error || `Signer returned ${r.status}`);
  return d;
}

/*
 * Real signing mode for an authorized macOS worker.
 *
 * Required environment variables on the signing host:
 *   SIGNING_IDENTITY   e.g. "Apple Development: Name (TEAMID)"
 *   PROVISION_PROFILE  path to a provisioning profile matching the app/device
 *   SIGNING_WORK_DIR   optional temporary directory
 *
 * The worker deliberately does not accept Apple ID passwords or 2FA codes.
 * Authentication/provisioning must be established through Apple's supported
 * developer tooling before this worker is used. The worker only signs an IPA
 * with credentials already installed on the authorized build machine.
 */
async function signIPA(input, output, bundleId) {
  if (process.platform !== 'darwin') throw new Error('Local signing requires a macOS worker with Xcode command-line tools.');
  const identity = process.env.SIGNING_IDENTITY;
  const profile = process.env.PROVISION_PROFILE;
  if (!identity || !profile) throw new Error('SIGNING_IDENTITY and PROVISION_PROFILE must be configured on the signing worker.');

  const work = await fs.mkdtemp(path.join(process.env.SIGNING_WORK_DIR || '/tmp', 'sidestore-sign-'));
  const src = path.join(work, 'input.ipa');
  const payload = path.join(work, 'Payload');
  const out = path.resolve(output);
  try {
    await fs.copyFile(input, src);
    await fs.mkdir(payload);
    await execFileAsync('/usr/bin/unzip', ['-q', src, '-d', work]);
    const entries = await fs.readdir(payload);
    const app = entries.find(x => x.endsWith('.app'));
    if (!app) throw new Error('IPA does not contain Payload/*.app');
    const appPath = path.join(payload, app);

    const profileData = await fs.readFile(profile);
    await fs.writeFile(path.join(appPath, 'embedded.mobileprovision'), profileData);

    const info = await execFileAsync('/usr/bin/codesign', ['-d', '--entitlements', ':-', appPath]).catch(() => ({stdout: ''}));
    const entitlementsPath = path.join(work, 'entitlements.plist');
    if (info.stdout) await fs.writeFile(entitlementsPath, info.stdout);

    await execFileAsync('/usr/bin/codesign', ['--force', '--sign', identity, '--timestamp=none', appPath]);
    await fs.rm(out, {force: true});
    await execFileAsync('/usr/bin/ditto', ['-c', '-k', '--sequesterRsrc', '--keepParent', payload, path.join(work, 'payload.zip')]);
    await execFileAsync('/usr/bin/ditto', ['-c', '-k', '--sequesterRsrc', '--keepParent', payload, out]);

    const zip = path.join(work, 'final.zip');
    await execFileAsync('/usr/bin/ditto', ['-c', '-k', '--sequesterRsrc', '--keepParent', payload, zip]);
    await fs.copyFile(zip, out);
    await execFileAsync('/usr/bin/codesign', ['--verify', '--deep', '--strict', appPath]);
    return {signedFile: out, bundleId, status: 'complete'};
  } finally {
    await fs.rm(work, {recursive: true, force: true}).catch(() => {});
  }
}

async function performSigning(job) {
  const signed = path.join(path.dirname(job.file), `${job.id}-signed.ipa`);
  if (adapter) return adapterCall('/v1/jobs', {id: job.id, name: job.name, bundleId: job.bundleId, version: job.version, filename: job.originalName, filePath: job.file});
  return signIPA(job.file, signed, job.bundleId);
}

function plist(job) {
  const ipa = `${origin}/v1/ipa/${job.id}`;
  const esc = x => String(x).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
  return `<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n<plist version="1.0"><dict><key>items</key><array><dict><key>assets</key><array><dict><key>kind</key><string>software-package</string><key>url</key><string>${ipa}</string></dict></array><key>metadata</key><dict><key>bundle-identifier</key><string>${esc(job.bundleId)}</string><key>bundle-version</key><string>${esc(job.version)}</string><key>kind</key><string>software</string><key>title</key><string>${esc(job.name)}</string></dict></dict></array></dict></plist>`;
}

app.post('/v1/jobs', upload.single('ipa'), async (req, res) => {
  if (!req.file) return res.status(400).json({error: 'IPA file is required'});
  const job = {id: id(), name: String(req.body.name || req.file.originalname), bundleId: String(req.body.bundleId || ''), version: String(req.body.version || '1.0'), file: req.file.path, originalName: req.file.originalname, status: 'queued', createdAt: Date.now()};
  if (!job.bundleId) return res.status(400).json({error: 'Bundle identifier is required'});
  jobs.set(job.id, job);
  try {
    job.status = 'signing';
    const result = await performSigning(job);
    Object.assign(job, result);
    if (result.status !== 'complete') job.status = result.status || 'queued';
    res.json({status: job.status, jobId: job.id});
  } catch (e) {
    job.status = 'failed'; job.error = e.message;
    res.status(502).json({error: e.message, jobId: job.id});
  }
});

app.post('/v1/auth/verify', (req, res) => res.status(410).json({error: 'Apple ID password/2FA collection is intentionally not implemented. Configure the authorized macOS signing worker with an existing Apple development signing identity and provisioning profile.'}));
app.get('/v1/jobs/:id', (req, res) => {
  const j = jobs.get(req.params.id); if (!j) return res.status(404).json({error: 'Job not found'});
  if (j.status === 'complete') return res.json({...j, installUrl: `itms-services://?action=download-manifest&url=${encodeURIComponent(`${origin}/v1/manifest/${j.id}`)}`, manifestUrl: `${origin}/v1/manifest/${j.id}`});
  res.json({id: j.id, status: j.status, error: j.error});
});
app.get('/v1/devices', (req, res) => res.json({devices: [], mode: 'provisioned-profile', message: 'Device registration is managed by the provisioning profile on the signing worker.'}));
app.get('/v1/manifest/:id', (req, res) => {const j = jobs.get(req.params.id); if (!j || j.status !== 'complete') return res.status(404).end(); res.type('application/xml').send(plist(j));});
app.get('/v1/ipa/:id', (req, res) => {const j = jobs.get(req.params.id); if (!j || j.status !== 'complete' || !j.signedFile) return res.status(404).end(); res.type('application/octet-stream'); res.download(j.signedFile, j.originalName);});
app.get('/healthz', (req, res) => res.json({ok: true, signer: adapter ? 'remote-adapter' : process.platform === 'darwin' ? 'local-macos' : 'unconfigured'}));
app.use(express.static(publicRoot));

app.listen(port, () => console.log(`SideStore Web signing gateway listening on ${origin}`));
process.on('SIGTERM', async () => {for (const j of jobs.values()) {if (j.file) await fs.rm(j.file, {force: true}).catch(() => {}); if (j.signedFile) await fs.rm(j.signedFile, {force: true}).catch(() => {});} process.exit(0);});
