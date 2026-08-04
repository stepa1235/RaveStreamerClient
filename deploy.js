const https = require('https');
const fs = require('fs');
const path = require('path');

const token = process.env.GITHUB_TOKEN || process.env.TOKEN || '';
const repo = 'stepa1235/RaveStreamerClient';
const releaseTag = 'v1.0.0';

const headers = {
  'Authorization': `Bearer ${token}`,
  'User-Agent': 'LunaDeployer',
  'Accept': 'application/vnd.github.v3+json'
};

function request(url, options = {}, body = null) {
  return new Promise((resolve, reject) => {
    const req = https.request(url, { headers, ...options }, (res) => {
      let data = '';
      res.on('data', chunk => data += chunk);
      res.on('end', () => {
        if (res.statusCode >= 200 && res.statusCode < 300) {
          resolve(data ? JSON.parse(data) : null);
        } else {
          reject(new Error(`Request failed with status ${res.statusCode}: ${data}`));
        }
      });
    });
    req.on('error', reject);
    if (body) {
      req.write(body);
    }
    req.end();
  });
}

async function deleteAllOldReleases() {
  console.log("1. Fetching all existing releases...");
  try {
    const releases = await request(`https://api.github.com/repos/${repo}/releases`);
    if (Array.isArray(releases)) {
      for (const rel of releases) {
        console.log(`Deleting release ${rel.name || rel.tag_name} (id: ${rel.id})...`);
        await request(`https://api.github.com/repos/${repo}/releases/${rel.id}`, { method: 'DELETE' });
      }
    }
  } catch (e) {
    console.log("Error or no releases found:", e.message);
  }
}

async function deleteAllOldTags() {
  console.log("2. Fetching all existing tags...");
  try {
    const refs = await request(`https://api.github.com/repos/${repo}/git/matching-refs/tags`);
    if (Array.isArray(refs)) {
      for (const ref of refs) {
        const tagName = ref.ref.replace('refs/tags/', '');
        console.log(`Deleting tag ref ${tagName}...`);
        await request(`https://api.github.com/repos/${repo}/git/refs/tags/${tagName}`, { method: 'DELETE' });
      }
    }
  } catch (e) {
    console.log("Error or no tags found:", e.message);
  }
}

async function uploadAsset(uploadUrl, filePath, name, contentType) {
  if (!fs.existsSync(filePath)) {
    console.log(`Warning: File ${filePath} not found, skipping upload.`);
    return;
  }
  const url = uploadUrl.replace('{?name,label}', `?name=${encodeURIComponent(name)}`);
  const fileStats = fs.statSync(filePath);
  const options = {
    method: 'POST',
    headers: {
      ...headers,
      'Content-Type': contentType,
      'Content-Length': fileStats.size
    }
  };

  return new Promise((resolve, reject) => {
    const req = https.request(url, options, (res) => {
      let data = '';
      res.on('data', chunk => data += chunk);
      res.on('end', () => {
        if (res.statusCode >= 200 && res.statusCode < 300) {
          console.log(`Asset ${name} uploaded successfully.`);
          resolve();
        } else {
          reject(new Error(`Asset upload failed with status ${res.statusCode}: ${data}`));
        }
      });
    });
    req.on('error', reject);
    fs.createReadStream(filePath).pipe(req);
  });
}

async function deploy() {
  await deleteAllOldReleases();
  await deleteAllOldTags();

  console.log("3. Creating new v1.0.0 release...");
  const release = await request(`https://api.github.com/repos/${repo}/releases`, {
    method: 'POST'
  }, JSON.stringify({
    tag_name: releaseTag,
    name: `Luna ${releaseTag}`,
    body: 'Luna v1.0.0 - Official First Release! Synchronized video watching app.'
  }));

  const uploadUrl = release.upload_url;

  console.log("4. Uploading Windows zip...");
  await uploadAsset(uploadUrl, path.join(__dirname, 'Luna-Windows.zip'), 'Luna-Windows.zip', 'application/zip');
  await uploadAsset(uploadUrl, path.join(__dirname, 'RaveStreamer-Windows.zip'), 'RaveStreamer-Windows.zip', 'application/zip');

  console.log("5. Uploading Android APK...");
  await uploadAsset(uploadUrl, path.join(__dirname, 'Luna.apk'), 'Luna.apk', 'application/vnd.android.package-archive');
  await uploadAsset(uploadUrl, path.join(__dirname, 'RaveStreamer.apk'), 'RaveStreamer.apk', 'application/vnd.android.package-archive');

  console.log("Deployment of Luna v1.0.0 complete!");
}

deploy().catch(console.error);
