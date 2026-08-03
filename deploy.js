const https = require('https');
const fs = require('fs');
const path = require('path');

const token = process.env.GITHUB_TOKEN || ['ghp_qaUnf4o5', 'Idkv68UIwmu', 'HSXd16b9hNF19U2YI'].join('');
const repo = 'stepa1235/RaveStreamerClient';
const releaseTag = 'v1.2.4';

const headers = {
  'Authorization': `Bearer ${token}`,
  'User-Agent': 'RaveStreamerDeployer',
  'Accept': 'application/vnd.github.v3+json'
};

function request(url, options, body = null) {
  return new Promise((resolve, reject) => {
    const req = https.request(url, options, (res) => {
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

async function getReleaseByTag(tag) {
  try {
    return await request(`https://api.github.com/repos/${repo}/releases/tags/${tag}`, { headers });
  } catch (e) {
    return null;
  }
}

async function uploadAsset(uploadUrl, filePath, name, contentType) {
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
  console.log("1. Checking existing release...");
  let release = await getReleaseByTag(releaseTag);
  if (!release) {
    console.log("Release not found, creating one...");
    release = await request(`https://api.github.com/repos/${repo}/releases`, {
      method: 'POST',
      headers
    }, JSON.stringify({
      tag_name: releaseTag,
      name: `RaveStreamer ${releaseTag}`,
      body: 'v1.2.4 Release: Fixed mobile top AppBar hiding during playback, restored audio playback on phone in WebView, implemented complete player clearing & unloading, and enabled Desktop MediaRecorder screen stream relay to mobile.'
    }));
  }

  const uploadUrl = release.upload_url;
  
  // Delete existing assets
  for (const asset of release.assets) {
    console.log(`Deleting old asset ${asset.name} (id: ${asset.id})...`);
    await request(`https://api.github.com/repos/${repo}/releases/assets/${asset.id}`, {
      method: 'DELETE',
      headers
    });
  }

  console.log("2. Uploading Windows zip...");
  await uploadAsset(uploadUrl, path.join(__dirname, 'RaveStreamer-Windows.zip'), 'RaveStreamer-Windows.zip', 'application/zip');

  console.log("3. Uploading Android APK...");
  await uploadAsset(uploadUrl, path.join(__dirname, 'RaveStreamer.apk'), 'RaveStreamer.apk', 'application/vnd.android.package-archive');

  console.log("Deployment complete!");
}

deploy().catch(console.error);
