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
function escXml(value) { return String(value).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;').replace(/'/g, '&apos;'); }

async function adapterCall(endpoint, payload) {
  if (!adapter) throw new Error('SIGNER_URL is not configured.');
  const r = await fetch(adapter.replace(/\/$/, '') + endpoint, {
    method: 'POST',
    headers: {'Content-Type': 'application/json'},
    body: JSON.stringify(payload)
  });
  const d = await r.json().catch(() => ({}));
  if (!r.ok) throw new Error(d.error || `Signer returned ${r.status}`);
  return d;
}

/*
 * Authorized macOS worker mode.
 * The worker uses an already-installed Apple development signing identity and
 * matching provisioning profile. It deliberately does not collect Apple ID
 * passwords, verification codes, cookies, or other authentication secrets.
 */
async function signIPA(input, output) {
  if (process.platform !== 'darwin') throw new Error('Local signing requires a macOS worker with Xcode command-line tools.');
  const identity = process.env.SIGNING_IDENTITY;
  const profile = process.env.PROVISION_PROFILE;
  if (!identity || !profile) throw new Error('SIGNING_IDENTITY and PROVISION_PROFILE must be configured on the signing worker.');

  const work = await fs.mkdtemp(path.join(process.env.SIGNING_WORK_DIR || '/tmp', 'sidestore-sign-'));
  const src = path.join(work, 'input.ipa');
  const extract = path.join(work, 'extract');
  const out = path.resolve(output);
  try {
    await fs.copyFile(input, src);
    await fs.mkdir(extract);
    await execFileAsync('/usr/bin/unzip', ['-q', src, '-d', extract]);
    const payload = path.join(extract, 'Payload');
    const entries = await fs.readdir(payload);
    const appName = entries.find(name => name.endsWith('.app'));
    if (!appName) throw new Error('IPA does not contain Payload/*.app.');
    const appPath = path.join(payload, appName);

    await fs.copyFile(profile, path.join(appPath, 'embedded.mobileprovision'));

    // Sign nested code before its containing .app. This covers frameworks,
    // dylibs, app extensions, and plug-ins that commonly invalidate an IPA
    // when only the top-level application is re-signed.
    const nested = [];
    async function collect(dir) {
      for (const name of await fs.readdir(dir, {withFileTypes: true})) {
        const full = path.join(dir, name.name);
        if (name.isDirectory()) {
          if (name.name.endsWith('.framework') || name.name.endsWith('.appex') || name.name.endsWith('.app') || name.name.endsWith('.xpc')) nested.push(full);
          await collect(full);
        }
      }
    }
    await collect(appPath);
    nested.sort((a, b) => b.split(path.sep).length - a.split(path.sep).length);

    for (const bundle of nested) {
      await execFileAsync('/usr/bin/codesign', ['--force', '--sign', identity, '--timestamp=none', bundle]);
    }
    await execFileAsync('/usr/bin/codesign', ['--force', '--sign', identity, '--timestamp=none', '--deep', appPath]);
    await execFileAsync('/usr/bin/codesign', ['--verify', '--deep', '--strict', '--verbose=2', appPath]);

    // Produce a real IPA archive with Payload/ at its root.
    await fs.rm(out, {force: true});
    await execFileAsync('/usr/bin/ditto', ['-c', '-k', '--sequesterRsrc', '--keepParent', payload, out]);
    const stat = await fs.stat(out);
    if (!stat.size) throw new Error('Signing produced an empty IPA.');

    return {signedFile: out, status: 'complete'};
  } finally {
    await fs.rm(work, {recursive: true, force: true}).catch(() => {});
  }
}

async function performSigning(job) {
  const signed = path.join(path.dirname(job.file), `${job.id}-signed.ipa`);
  if (adapter) return adapterCall('/v1/jobs', {
    id: job.id,
    name: job.name,
    bundleId: job.bundleId,
    version: job.version,
    filename: job.originalName,
    filePath: job.file
  });
  return signIPA(job.file, signed);
}

function plist(job) {
  const ipa = `${origin}/v1/ipa/${job.id}`;
  return `<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n<plist version="1.0"><dict><key>items</key><array><dict><key>assets</key><array><dict><key>kind</key><string>software-package</string><key>url</key><string>${escXml(ipa)}</string></dict></array><key>metadata</key><dict><key>bundle-identifier</key><string>${escXml(job.bundleId)}</string><key>bundle-version</key><string>${escXml(job.version)}</string><key>kind</key><string>software</string><key>title</key><string>${escXml(job.name)}</string></dict></dict></array></dict></plist>`;
}

app.post('/v1/jobs', upload.single('ipa'), async (req, res) => {
  if (!req.file) return res.status(400).json({error: 'IPA file is required'});
  const job = {
    id: id(),
    name: String(req.body.name || req.file.originalname),
    bundleId: String(req.body.bundleId || ''),
    version: String(req.body.version || '1.0'),
    file: req.file.path,
    originalName: req.file.originalname,
    status: 'queued',
    createdAt: Date.now()
  };
  if (!job.bundleId) {
    await fs.rm(job.file, {force: true}).catch(() => {});
    return res.status(400).json({error: 'Bundle identifier is required'});
  }
  jobs.set(job.id, job);
  try {
    job.status = 'signing';
    const result = await performSigning(job);
    Object.assign(job, result);
    job.status = result.status || 'queued';
    res.json({status: job.status, jobId: job.id});
  } catch (error) {
    job.status = 'failed';
    job.error = error instanceof Error ? error.message : String(error);
    res.status(502).json({error: job.error, jobId: job.id});
  }
});

app.post('/v1/auth/verify', (req, res) => res.status(410).json({
  error: 'Direct Apple ID password/2FA collection is not implemented. Configure the authorized macOS signing worker with an existing Apple development signing identity and provisioning profile.'
}));

app.get('/v1/jobs/:id', (req, res) => {
  const job = jobs.get(req.params.id);
  if (!job) return res.status(404).json({error: 'Job not found'});
  if (job.status === 'complete') {
    const manifestUrl = `${origin}/v1/manifest/${job.id}`;
    return res.json({...job, installUrl: `itms-services://?action=download-manifest&url=${encodeURIComponent(manifestUrl)}`, manifestUrl});
  }
  res.json({id: job.id, status: job.status, error: job.error});
});

app.get('/v1/devices', (req, res) => res.json({
  devices: [],
  mode: 'provisioned-profile',
  message: 'Device registration is represented by the provisioning profile installed on the authorized signing worker.'
}));

app.get('/v1/manifest/:id', (req, res) => {
  const job = jobs.get(req.params.id);
  if (!job || job.status !== 'complete') return res.status(404).end();
  res.type('application/xml').send(plist(job));
});

app.get('/v1/ipa/:id', (req, res) => {
  const job = jobs.get(req.params.id);
  if (!job || job.status !== 'complete' || !job.signedFile) return res.status(404).end();
  res.type('application/octet-stream').download(job.signedFile, job.originalName);
});

app.get('/healthz', (req, res) => res.json({
  ok: true,
  signer: adapter ? 'remote-adapter' : process.platform === 'darwin' ? 'local-macos' : 'unconfigured'
}));

app.use(express.static(publicRoot));
app.listen(port, () => console.log(`SideStore Web signing gateway listening on ${origin}`));

process.on('SIGTERM', async () => {
  for (const job of jobs.values()) {
    if (job.file) await fs.rm(job.file, {force: true}).catch(() => {});
    if (job.signedFile) await fs.rm(job.signedFile, {force: true}).catch(() => {});
  }
  process.exit(0);
});
