const https = require('https');
const fs = require('fs');
const path = require('path');
const { execSync } = require('child_process');

let token = (process.env.GITHUB_TOKEN || process.env.TOKEN || '').trim();
if (!token) {
  try {
    const creds = execSync('git credential fill', {
      input: 'protocol=https\nhost=github.com\n\n',
      encoding: 'utf-8',
      stdio: ['pipe', 'pipe', 'ignore']
    });
    const match = creds.match(/password=(.+)/);
    if (match) {
      token = match[1].trim();
    }
  } catch (e) {
    // ignore
  }
}

if (!token) {
  console.error('ERROR: GITHUB_TOKEN or TOKEN environment variable is required to deploy.');
  process.exit(1);
}
const repo = 'stepa1235/RaveStreamerClient';
const releaseTag = 'v1.1.1';

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

async function deleteExistingRelease() {
  console.log(`1. Checking if release ${releaseTag} exists...`);
  try {
    const releases = await request(`https://api.github.com/repos/${repo}/releases`);
    if (Array.isArray(releases)) {
      for (const rel of releases) {
        if (rel.tag_name === releaseTag) {
          console.log(`Deleting existing release ${rel.name || rel.tag_name} (id: ${rel.id})...`);
          await request(`https://api.github.com/repos/${repo}/releases/${rel.id}`, { method: 'DELETE' });
        }
      }
    }
  } catch (e) {
    console.log("Error checking releases:", e.message);
  }
}

async function deleteExistingTag() {
  console.log(`2. Checking if tag ${releaseTag} exists...`);
  try {
    await request(`https://api.github.com/repos/${repo}/git/refs/tags/${releaseTag}`, { method: 'DELETE' });
    console.log(`Deleted existing tag ${releaseTag}`);
  } catch (e) {
    // fine if doesn't exist
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

async function updateGist() {
  const gistId = '0811a2ec6e74b06965de32f61643da5b';
  console.log('6. Updating Gist with v1.1.0 update info...');
  try {
    let currentUrl = 'https://stepan1235-ravestreamer.hf.space';
    try {
      const cur = await request(`https://api.github.com/gists/${gistId}`);
      if (cur && cur.files && cur.files['ravestreamer.json']) {
        const parsed = JSON.parse(cur.files['ravestreamer.json'].content);
        if (parsed.url) currentUrl = parsed.url;
      }
    } catch (_) {}

    await request(`https://api.github.com/gists/${gistId}`, {
      method: 'PATCH'
    }, JSON.stringify({
      files: {
        'ravestreamer.json': {
          content: JSON.stringify({
            url: currentUrl,
            latest_version: '1.1.1',
            android_url: `https://github.com/${repo}/releases/download/${releaseTag}/Luna.apk`,
            windows_url: `https://github.com/${repo}/releases/download/${releaseTag}/Luna-Windows.zip`
          }, null, 2)
        }
      }
    }));
    console.log('Gist updated successfully!');
  } catch (e) {
    console.log('Failed to update Gist:', e.message);
  }
}

async function deploy() {
  await deleteExistingRelease();
  await deleteExistingTag();

  console.log(`3. Creating new ${releaseTag} release...`);
  const release = await request(`https://api.github.com/repos/${repo}/releases`, {
    method: 'POST'
  }, JSON.stringify({
    tag_name: releaseTag,
    name: `Luna ${releaseTag}`,
    body: 'Luna v1.1.1\n\n- Новое всплывающее меню реакций и действий в стиле Telegram (плавающая капсула эмодзи с мягким блюром и компактное контекстное меню ответов)\n- Расширенный набор реакций (❤️, 👍, 👎, 🔥, 😂, 😮, 😢, 👏, 🎉)\n- Быстрый доступ к меню действий по клику на сообщение, долгому нажатию и правой кнопке мыши\n- Стилизованные Telegram-плашки реакций под сообщениями и обновленная панель цитирования'
  }));

  const uploadUrl = release.upload_url;

  console.log("4. Uploading Windows zip (Luna-Windows.zip)...");
  await uploadAsset(uploadUrl, path.join(__dirname, 'Luna-Windows.zip'), 'Luna-Windows.zip', 'application/zip');

  console.log("5. Uploading Android APK (Luna.apk)...");
  await uploadAsset(uploadUrl, path.join(__dirname, 'Luna.apk'), 'Luna.apk', 'application/vnd.android.package-archive');

  await updateGist();

  console.log(`Deployment of Luna ${releaseTag} complete!`);
}

deploy().catch(console.error);
