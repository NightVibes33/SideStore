import express from 'express';
import multer from 'multer';
import crypto from 'node:crypto';
import fs from 'node:fs/promises';
import path from 'node:path';
import {fileURLToPath} from 'node:url';

const app=express();
const upload=multer({dest:process.env.UPLOAD_DIR||'/tmp/sidestore-web',limits:{fileSize:1024*1024*1024}});
const jobs=new Map();
const sessions=new Map();
const root=path.dirname(fileURLToPath(import.meta.url));
const publicRoot=path.join(root,'public');
const port=Number(process.env.PORT||8787);
const origin=process.env.PUBLIC_ORIGIN||`http://localhost:${port}`;
const adapter=process.env.SIGNER_URL||'';

app.disable('x-powered-by');app.use(express.json({limit:'1mb'}));app.use((req,res,next)=>{res.setHeader('Access-Control-Allow-Origin',process.env.WEB_ORIGIN||'*');res.setHeader('Access-Control-Allow-Credentials','true');res.setHeader('Access-Control-Allow-Headers','Content-Type');res.setHeader('Access-Control-Allow-Methods','GET,POST,OPTIONS');if(req.method==='OPTIONS')return res.sendStatus(204);next()});
app.use('/v1',async(req,res,next)=>{if(process.env.API_TOKEN&&req.get('authorization')!==`Bearer ${process.env.API_TOKEN}`)return res.status(401).json({error:'Unauthorized'});next()});

function id(){return crypto.randomUUID()}
async function callAdapter(endpoint,payload){if(!adapter)throw new Error('SIGNER_URL is not configured.');const r=await fetch(adapter.replace(/\/$/,'')+endpoint,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(payload)});const d=await r.json().catch(()=>({}));if(!r.ok)throw new Error(d.error||`Signer returned ${r.status}`);return d}
function plist(job){const install=`${origin}/v1/install/${job.id}`;return `<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n<plist version="1.0"><dict><key>items</key><array><dict><key>assets</key><array><dict><key>kind</key><string>software-package</string><key>url</key><string>${origin}/v1/ipa/${job.id}</string></dict></array><key>metadata</key><dict><key>bundle-identifier</key><string>${job.bundleId}</string><key>bundle-version</key><string>${job.version}</string><key>kind</key><string>software</string><key>title</key><string>${job.name}</string></dict></dict></array></dict></plist>`}

app.post('/v1/jobs',upload.single('ipa'),async(req,res)=>{if(!req.file)return res.status(400).json({error:'IPA file is required'});const job={id:id(),name:String(req.body.name||req.file.originalname),bundleId:String(req.body.bundleId||''),version:String(req.body.version||'1.0'),file:req.file.path,originalName:req.file.originalname,status:'queued',createdAt:Date.now()};if(!job.bundleId)return res.status(400).json({error:'Bundle identifier is required'});jobs.set(job.id,job);try{const result=await callAdapter('/v1/jobs',{id:job.id,name:job.name,bundleId:job.bundleId,version:job.version,filename:job.originalName,filePath:job.file});Object.assign(job,result);if(result.status==='verification_required'){const sessionId=result.sessionId||id();job.status='verification_required';job.sessionId=sessionId;sessions.set(sessionId,{jobId:job.id});return res.json({status:'verification_required',sessionId,jobId:job.id})}res.json({status:job.status,jobId:job.id,message:'Signing job created'})}catch(e){job.status='failed';job.error=e.message;res.status(502).json({error:e.message})}});
app.post('/v1/auth/verify',async(req,res)=>{const {sessionId,code}=req.body||{};if(!sessionId||!code)return res.status(400).json({error:'sessionId and code are required'});const s=sessions.get(sessionId);if(!s)return res.status(404).json({error:'Verification session expired'});try{const result=await callAdapter('/v1/auth/verify',{sessionId,code});const job=jobs.get(s.jobId);if(job)Object.assign(job,result,{status:result.status||'queued'});sessions.delete(sessionId);res.json({ok:true,status:job?.status||result.status||'queued'})}catch(e){res.status(502).json({error:e.message})}});
app.get('/v1/jobs/:id',(req,res)=>{const j=jobs.get(req.params.id);if(!j)return res.status(404).json({error:'Job not found'});if(j.status==='complete')return res.json({...j,installUrl:`itms-services://?action=download-manifest&url=${encodeURIComponent(`${origin}/v1/manifest/${j.id}`)}`,manifestUrl:`${origin}/v1/manifest/${j.id}`});res.json({id:j.id,status:j.status,error:j.error})});
app.get('/v1/devices',async(req,res)=>{try{const d=await callAdapter('/v1/devices',{});res.json(d)}catch(e){res.status(502).json({error:e.message})}});
app.get('/v1/manifest/:id',(req,res)=>{const j=jobs.get(req.params.id);if(!j||j.status!=='complete')return res.status(404).end();res.type('application/xml').send(plist(j))});
app.get('/v1/ipa/:id',async(req,res)=>{const j=jobs.get(req.params.id);if(!j||j.status!=='complete'||!j.signedFile)return res.status(404).end();res.type('application/octet-stream');res.download(j.signedFile,j.originalName)});
app.use(express.static(publicRoot));

app.listen(port,()=>console.log(`SideStore Web signing gateway listening on ${origin}`));
process.on('SIGTERM',async()=>{for(const j of jobs.values()){if(j.file)await fs.rm(j.file,{force:true}).catch(()=>{})}process.exit(0)});
