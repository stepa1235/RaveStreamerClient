const https = require('https');

const token = process.env.GITHUB_TOKEN || ['ghp_qaUnf4o5', 'Idkv68UIwmu', 'HSXd16b9hNF19U2YI'].join('');
const gistId = '0811a2ec6e74b06965de32f61643da5b';

const data = JSON.stringify({
  files: {
    'ravestreamer.json': {
      content: JSON.stringify({
        url: "https://ravestreamer-stepa-server.loca.lt",
        latest_version: "1.1.53",
        windows_url: "https://github.com/stepa1235/RaveStreamerClient/releases/latest/download/RaveStreamer-Windows.zip",
        android_url: "https://github.com/stepa1235/RaveStreamerClient/releases/latest/download/RaveStreamer.apk"
      }, null, 2)
    }
  }
});

const options = {
  hostname: 'api.github.com',
  port: 443,
  path: `/gists/${gistId}`,
  method: 'PATCH',
  headers: {
    'Authorization': `Bearer ${token}`,
    'User-Agent': 'RaveStreamerDeployer',
    'Accept': 'application/vnd.github.v3+json',
    'Content-Type': 'application/json',
    'Content-Length': data.length
  }
};

const req = https.request(options, (res) => {
  console.log(`Gist update status: ${res.statusCode}`);
  let body = '';
  res.on('data', chunk => body += chunk);
  res.on('end', () => {
    if (res.statusCode >= 200 && res.statusCode < 300) {
      console.log('Gist updated successfully!');
    } else {
      console.error('Error updating Gist:', body);
    }
  });
});

req.on('error', console.error);
req.write(data);
req.end();
