const express = require('express');
const http = require('http');
const { Server } = require('socket.io');
const cors = require('cors');
const fs = require('fs');
const path = require('path');
const os = require('os');
const crypto = require('crypto');

const app = express();
// Trust only explicitly configured proxy networks; direct clients cannot forge their IP.
app.set('trust proxy', process.env.TRUST_PROXY ? process.env.TRUST_PROXY.split(',').map(s => s.trim()) : 'loopback');
app.use(cors());
app.use(express.json({ limit: '25mb' }));
app.use(express.urlencoded({ limit: '25mb', extended: true }));

const uploadsDir = path.join(__dirname, 'uploads');
if (!fs.existsSync(uploadsDir)) {
  fs.mkdirSync(uploadsDir, { recursive: true });
}
// Admin routes fail closed until a secret is configured. Never ship a shared default.
const ADMIN_SECRET = process.env.ADMIN_SECRET || null;
function validAdminToken(token) {
  if (!ADMIN_SECRET || typeof token !== 'string') return false;
  const a = Buffer.from(token);
  const b = Buffer.from(ADMIN_SECRET);
  return a.length === b.length && crypto.timingSafeEqual(a, b);
}

// Admin authentication middleware
function requireAdminAuth(req, res, next) {
  const authHeader = req.headers['authorization'];
  const tokenHeader = req.headers['x-admin-token'];
  const queryToken = req.query.token;

  let token = null;
  if (authHeader && authHeader.startsWith('Bearer ')) {
    token = authHeader.slice(7).trim();
  } else if (tokenHeader) {
    token = String(tokenHeader).trim();
  } else if (queryToken) {
    token = String(queryToken).trim();
  }

  if (!validAdminToken(token)) {
    console.warn(`[Security] Unauthorized admin access attempt to ${req.path} from IP: ${req.ip}`);
    return res.status(401).json({ ok: false, error: 'Unauthorized: Invalid or missing admin token' });
  }
  next();
}

app.use('/uploads', express.static(uploadsDir));

// In-memory sliding window rate-limiter for chat image uploads
const uploadRateLimits = new Map();
const MAX_UPLOADS_PER_MINUTE = 25;

// Endpoint to upload chat images and GIFs (secured with rate limiting and signature validation)
app.post('/api/upload-chat-image', async (req, res) => {
  try {
    const clientIp = req.ip || req.connection.remoteAddress || 'unknown';
    const now = Date.now();
    const clientHistory = uploadRateLimits.get(clientIp) || [];
    const recentUploads = clientHistory.filter(t => now - t < 60000);
    if (recentUploads.length >= MAX_UPLOADS_PER_MINUTE) {
      return res.status(429).json({ error: 'Too many uploads. Please wait a minute.' });
    }
    recentUploads.push(now);
    uploadRateLimits.set(clientIp, recentUploads);

    const { imageBase64, filename } = req.body || {};
    if (!imageBase64 || typeof imageBase64 !== 'string') {
      return res.status(400).json({ error: 'No image data provided' });
    }

    let buffer;
    let ext = 'jpg';
    if (imageBase64.includes(';base64,')) {
      const parts = imageBase64.split(';base64,');
      const mime = parts[0];
      if (mime.includes('png')) ext = 'png';
      else if (mime.includes('gif')) ext = 'gif';
      else if (mime.includes('webp')) ext = 'webp';
      buffer = Buffer.from(parts[1], 'base64');
    } else {
      buffer = Buffer.from(imageBase64, 'base64');
    }

    // Limit image size to 10MB
    if (buffer.length > 10 * 1024 * 1024) {
      return res.status(413).json({ error: 'Image too large (max 10MB)' });
    }
    if (buffer.length < 12) {
      return res.status(400).json({ error: 'Invalid image file data' });
    }

    // Magic bytes signature validation
    const isJpeg = buffer[0] === 0xFF && buffer[1] === 0xD8 && buffer[2] === 0xFF;
    const isPng = buffer[0] === 0x89 && buffer[1] === 0x50 && buffer[2] === 0x4E && buffer[3] === 0x47;
    const isGif = buffer[0] === 0x47 && buffer[1] === 0x49 && buffer[2] === 0x46;
    const isWebp = buffer.slice(0, 4).toString() === 'RIFF' && buffer.slice(8, 12).toString() === 'WEBP';

    if (!isJpeg && !isPng && !isGif && !isWebp) {
      return res.status(400).json({ error: 'Invalid image file signature (only JPEG, PNG, GIF, WebP allowed)' });
    }

    if (isPng) ext = 'png';
    else if (isGif) ext = 'gif';
    else if (isWebp) ext = 'webp';
    else if (isJpeg) ext = 'jpg';

    const safeFilename = `${Date.now()}_${crypto.randomBytes(6).toString('hex')}.${ext}`;
    const filePath = path.join(uploadsDir, safeFilename);
    await fs.promises.writeFile(filePath, buffer);

    const protocol = req.protocol || 'http';
    const host = req.get('host') || '195.133.26.226:3000';
    const url = `${protocol}://${host}/uploads/${safeFilename}`;
    console.log(`[Upload] Image saved: ${safeFilename} (${(buffer.length / 1024).toFixed(1)} KB) -> ${url}`);
    res.json({ ok: true, url, filename: safeFilename });
  } catch (err) {
    console.error('[Upload Error]', err);
    res.status(500).json({ error: err.message });
  }
});

app.use(express.static(path.join(__dirname, 'public')));
app.get('/admin', (req, res) => res.sendFile(path.join(__dirname, 'public', 'index.html')));
app.get('/', (req, res) => res.sendFile(path.join(__dirname, 'public', 'index.html')));

// Health check endpoint (public)
app.get('/health', (req, res) => {
  res.json({ status: 'ok', time: new Date() });
});

// Admin endpoints (protected by requireAdminAuth)
app.get('/api/stats', requireAdminAuth, (req, res) => {
  const statsRooms = {};
  for (const [rId, room] of rooms.entries()) {
    statsRooms[rId] = {
      roomId: room.roomId,
      videoUrl: room.videoUrl,
      videoName: room.videoName,
      isPlaying: room.isPlaying,
      currentTime: room.currentTime,
      userCount: (room.users || []).length,
      users: (room.users || []).map(u => ({ id: u.id, username: u.username, isHost: u.isHost })),
      isLiveStreaming: room.isLiveStreaming || false
    };
  }
  res.json({
    ok: true,
    uptime: process.uptime(),
    memory: process.memoryUsage(),
    roomCount: rooms.size,
    rooms: statsRooms
  });
});

// Admin: Send server message to room
app.post('/api/admin/send-message', requireAdminAuth, (req, res) => {
  try {
    const { roomId, message, sender } = req.body || {};
    if (!roomId || !message) return res.status(400).json({ ok: false, error: 'roomId and message required' });
    const room = rooms.get(roomId);
    if (!room) return res.status(404).json({ ok: false, error: 'Room not found' });
    const senderName = (sender && typeof sender === 'string' && sender.trim()) ? sender.trim() : 'Сервер';
    const chatMsg = {
      id: Math.random().toString(36).substring(2, 9),
      username: senderName,
      text: message,
      timestamp: new Date().toLocaleTimeString('ru-RU', { hour12: false }),
      clientId: 'server-admin'
    };
    if (!room.messages) room.messages = [];
    room.messages.push(chatMsg);
    if (room.messages.length > 100) room.messages.shift();
    io.to(roomId).emit('chat-msg', chatMsg);
    console.log('[Admin] Server msg to room ' + roomId + ' (' + senderName + '): ' + message);
    res.json({ ok: true });
  } catch (err) {
    console.error('[Admin Send Message Error]', err);
    res.status(500).json({ ok: false, error: err.message });
  }
});

// Admin: Close a room (kick all users and cleanup)
app.post('/api/admin/close-room', requireAdminAuth, (req, res) => {
  try {
    const { roomId, reason } = req.body || {};
    if (!roomId) return res.status(400).json({ ok: false, error: 'roomId required' });
    const room = rooms.get(roomId);
    if (!room) return res.status(404).json({ ok: false, error: 'Room not found' });
    const closedReason = (reason && typeof reason === 'string' && reason.trim()) ? reason.trim() : 'Комната закрыта администратором';

    const warnMsg = {
      id: Math.random().toString(36).substring(2, 9),
      username: 'Сервер',
      text: '🚫 Комната закрыта администратором' + (reason ? ': ' + reason : ''),
      timestamp: new Date().toLocaleTimeString('ru-RU', { hour12: false }),
      clientId: 'server-admin'
    };

    // 1. Send warning chat message
    io.to(roomId).emit('chat-msg', warnMsg);

    // 2. Emit kicked to all users in room
    io.to(roomId).emit('kicked');

    // 3. Force sockets to leave room
    if (room.users && Array.isArray(room.users)) {
      for (const u of room.users) {
        if (u && u.id) {
          const s = io.sockets.sockets.get(u.id);
          if (s) {
            s.emit('kicked');
            try { s.leave(roomId); } catch (_) {}
          }
        }
      }
    }

    // 4. Delete room from Map
    rooms.delete(roomId);

    // 5. Broadcast updated admin-stats immediately
    const statsRooms = {};
    for (const [rId, rm] of rooms.entries()) {
      statsRooms[rId] = {
        roomId: rm.roomId,
        videoUrl: rm.videoUrl,
        videoName: rm.videoName,
        isPlaying: rm.isPlaying,
        currentTime: rm.currentTime,
        users: rm.users || [],
        queue: rm.queue || [],
        isLiveStreaming: rm.isLiveStreaming || false
      };
    }
    io.to('luna:admin').emit('admin-stats', { rooms: statsRooms });

    console.log('[Admin] Room ' + roomId + ' closed. Reason: ' + closedReason);
    res.json({ ok: true });
  } catch (err) {
    console.error('[Admin Close Room Error]', err);
    res.status(500).json({ ok: false, error: err.message });
  }
});

// Admin: Restart service
app.post('/api/restart', requireAdminAuth, (req, res) => {
  console.log(`[Admin] Restart command received from IP: ${req.ip}`);
  res.json({ ok: true, message: 'Restarting process...' });
  setTimeout(() => process.exit(0), 500);
});

// Admin: View logs
app.get('/api/logs', requireAdminAuth, (req, res) => {
  try {
    const logFile = path.join(os.homedir(), '.pm2', 'logs', 'luna-server-out.log');
    if (fs.existsSync(logFile)) {
      const content = fs.readFileSync(logFile, 'utf8');
      const lines = content.trim().split('\n').slice(-100);
      return res.json({ ok: true, logs: lines });
    }
  } catch (_) {}
  res.json({ ok: true, logs: [] });
});

const isWindows = os.platform() === 'win32';
const ytDlpFilename = isWindows ? 'yt-dlp.exe' : 'yt-dlp';
const ytDlpPath = path.join(__dirname, ytDlpFilename);

async function downloadYtDlp() {
  if (fs.existsSync(ytDlpPath)) return;
  console.log(`Downloading ${ytDlpFilename} for universal video link extraction...`);
  try {
    const fetch = require('node-fetch');
    const url = isWindows
      ? 'https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp.exe'
      : 'https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp';

    const resp = await fetch(url);
    if (!resp.ok) throw new Error(`HTTP status ${resp.status}`);
    const fileStream = fs.createWriteStream(ytDlpPath);
    await new Promise((resolve, reject) => {
      resp.body.pipe(fileStream);
      resp.body.on('error', reject);
      fileStream.on('finish', resolve);
    });

    if (!isWindows) {
      fs.chmodSync(ytDlpPath, 0o755);
    }

    console.log(`${ytDlpFilename} downloaded successfully.`);
  } catch (err) {
    console.error(`Failed to download ${ytDlpFilename}:`, err.message);
  }
}

// Start download in background
downloadYtDlp();

async function fetchWithAntiBot(url, headers = {}) {
  const fetch = require('node-fetch');
  const userAgent = headers['User-Agent'] || 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';

  const reqHeaders = {
    ...headers,
    'User-Agent': userAgent,
    'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8,application/signed-exchange;v=b3;q=0.7',
    'Accept-Language': 'ru-RU,ru;q=0.9,en-US;q=0.8,en;q=0.7',
    'Cache-Control': 'no-cache',
    'Connection': 'keep-alive'
  };

  let response = await fetch(url, { headers: reqHeaders });
  const setCookie = response.headers.raw()['set-cookie'] || [];
  const jsCookie = setCookie.find(c => c.startsWith('__js_p_='));

  if (jsCookie) {
    console.log('[Anti-Bot] DDoS-Guard challenge detected. Solving...');
    const cookieValue = jsCookie.split(';')[0].split('=')[1];
    const code = parseInt(cookieValue.split(',')[0]);

    const get_jhash = (b) => {
      let x = 123456789;
      let k = 0;
      for (let i = 0; i < 1677696; i++) {
        x = ((x + b) ^ (x + (x % 3) + (x % 17) + b) ^ i) % 16776960;
        if (x % 117 === 0) k = (k + 1) % 1111;
      }
      return k;
    };

    const fixedEncodeURIComponent = (str) => {
      return encodeURIComponent(str).replace(/[!'()*]/g, (c) => "%" + c.charCodeAt(0).toString(16));
    };

    const jhash = get_jhash(code);
    const cookieHeader = `__js_p_=${cookieValue}; __jhash_=${jhash}; __jua_=${fixedEncodeURIComponent(userAgent)}`;

    // Mimic browser setTimeout delay
    await new Promise(resolve => setTimeout(resolve, 1500));

    reqHeaders['Cookie'] = cookieHeader;
    reqHeaders['Referer'] = url;

    response = await fetch(url, { headers: reqHeaders });
    console.log('[Anti-Bot] Challenge solved, second request status:', response.status);
  }

  return response;
}

function runYtDlp(videoUrl, referer = null) {
  return new Promise((resolve, reject) => {
    if (!fs.existsSync(ytDlpPath)) {
      return reject(new Error(`${ytDlpFilename} is not downloaded yet. Please try again in a few seconds.`));
    }
    const { execFile } = require('child_process');
    const userAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36';
    const args = [
      '--dump-json',
      '-f', 'bestvideo+bestaudio/b/best',
      '--no-warnings',
      '--no-playlist',
      '--socket-timeout', '15',
      '--user-agent', userAgent,
      '--add-header', `User-Agent:${userAgent}`,
      '--extractor-args', 'youtube:player_client=ios',
    ];
    if (videoUrl.includes('rutube.ru') || videoUrl.includes('rutube')) {
      const ref = 'https://rutube.ru/';
      args.push('--referer', ref);
      args.push('--add-header', `Referer:${ref}`);
      args.push('--add-header', `Origin:${ref.slice(0, -1)}`);
    } else if (videoUrl.includes('vk.com') || videoUrl.includes('vkvideo.ru') || videoUrl.includes('okcdn.ru') || videoUrl.includes('mycdn.me')) {
      const ref = videoUrl.includes('vkvideo.ru') ? 'https://vkvideo.ru/' : (videoUrl.includes('okcdn.ru') || videoUrl.includes('mycdn.me') ? 'https://ok.ru/' : 'https://vk.com/');
      args.push('--referer', ref);
      args.push('--add-header', `Referer:${ref}`);
      args.push('--add-header', `Origin:${ref.slice(0, -1)}`);
    } else if (referer) {
      args.push('--referer', referer);
      args.push('--add-header', `Referer:${referer}`);
    }
    args.push('--', videoUrl);

    execFile(ytDlpPath, args, { timeout: 45000, maxBuffer: 8 * 1024 * 1024 }, (error, stdout, stderr) => {
      if (error) {
        return reject(error);
      }
      try {
        const metadata = JSON.parse(stdout);
        let bestUrl = null;
        let selectedFormat = null;

        if (metadata.formats && metadata.formats.length > 0) {
          // Filter out formats without audio or without video
          const combinedFormats = metadata.formats.filter(f => f.url && f.acodec !== 'none' && f.vcodec !== 'none');
          if (combinedFormats.length > 0) {
            const urlMp4Formats = combinedFormats.filter(f => (f.format_id && String(f.format_id).startsWith('url')) || (f.url && f.url.includes('.mp4')));
            const hlsFormats = combinedFormats.filter(f => (f.format_id && String(f.format_id).startsWith('hls-')) || (f.url && f.url.includes('.m3u8')) || (f.protocol && f.protocol.includes('m3u8')));
            if (urlMp4Formats.length > 0) {
              selectedFormat = urlMp4Formats[urlMp4Formats.length - 1];
            } else if (hlsFormats.length > 0) {
              selectedFormat = hlsFormats[hlsFormats.length - 1];
            } else {
              selectedFormat = combinedFormats[combinedFormats.length - 1];
            }
          } else {
            const directFormats = metadata.formats.filter(f => f.url && (f.protocol === 'https' || f.protocol === 'http' || (f.protocol && f.protocol.includes('m3u8')) || f.url.includes('.mp4') || f.url.includes('.m3u8')));
            selectedFormat = directFormats.length > 0 ? directFormats[directFormats.length - 1] : metadata.formats[metadata.formats.length - 1];
          }
        }

        bestUrl = selectedFormat ? selectedFormat.url : (metadata.url || null);
        const isHls = (selectedFormat && selectedFormat.protocol && selectedFormat.protocol.includes('m3u8')) ||
                      (selectedFormat && selectedFormat.url && selectedFormat.url.includes('.m3u8')) ||
                      (!selectedFormat && metadata.protocol && metadata.protocol.includes('m3u8')) ||
                      (!selectedFormat && metadata.ext === 'm3u8');

        resolve({
          url: bestUrl,
          title: metadata.title || metadata.description,
          isHls: isHls
        });
      } catch (err) {
        reject(new Error('Failed to parse metadata from yt-dlp output'));
      }
    });
  });
}

async function scrapeTranslators(page) {
  try {
    return await page.evaluate(() => {
      const items = Array.from(document.querySelectorAll(
        '.b-translator__item, .translator-item, [data-translator_id], .tabs-sel span[data-voice], .voice-btn, .voice-item, .voice_item, select.voice-select option, select[name="voice"] option'
      ));
      return items.map((el, i) => {
        const name = (el.innerText || el.textContent || el.value || '').trim();
        const id = el.getAttribute('data-translator_id') || el.getAttribute('data-id') || el.value || String(i);
        const isActive = el.classList.contains('active') || el.classList.contains('current') || el.classList.contains('b-translator__item--active') || el.selected;
        return { index: i, name, translatorId: id, isActive };
      }).filter(t => t.name && t.name.length > 0 && t.name.length < 60);
    });
  } catch (e) {
    console.log('[Puppeteer] Could not scrape translators:', e.message);
    return [];
  }
}


// Extract player iframe URL from HTML using fetchWithAntiBot (bypasses DDoS-Guard without headless browser)
async function extractPlayerFromHtml(targetUrl, referer = 'https://www.google.com/') {
  console.log(`[HtmlExtract] Fetching page HTML with DDoS-Guard bypass: ${targetUrl}`);

  try {
    const response = await fetchWithAntiBot(targetUrl, {
      'Referer': referer,
    });

    if (!response.ok) {
      throw new Error(`HTTP ${response.status}`);
    }

    const html = await response.text();
    console.log(`[HtmlExtract] Got HTML, length: ${html.length}`);

    if (html.length < 500) {
      console.log('[HtmlExtract] Page too short, probably blocked by DDoS-Guard');
      return null;
    }

    // 2. Look for direct video URLs (m3u8, mp4) in the HTML
    const videoPatterns = [
      /["'](?:src|url|source|file)["']\s*[=:]\s*["']((?:https?:)?\/\/[^"']+\.m3u8[^"']*)["']/gi,
      /["']((?:https?:)?\/\/[^"']+\.m3u8[^"']*)["']/gi,
      /["']((?:https?:)?\/\/(?:vk-cdn|vkuser|okcdn\.ru|mycdn\.me|userapi\.com|vk\.me|vkuservideo)[^"']+)["']/gi,
    ];

    for (const pattern of videoPatterns) {
      const matches = [...html.matchAll(pattern)];
      if (matches.length > 0) {
        let videoUrl = matches[0][1];
        if (videoUrl.startsWith('//')) videoUrl = 'https:' + videoUrl;
        console.log(`[HtmlExtract] Found direct video URL in HTML: ${videoUrl}`);
        return { type: 'video', url: videoUrl };
      }
    }

    // 1. Look for iframe player URLs in HTML attributes
    const iframePatterns = [
      /iframe[^>]+(?:src|data-src)=["']((?:https?:)?\/\/[^"']*(?:videocdn|collaps|kodik|hdvb|alloha|vk\.com\/video_ext|rutube|bazon|ustore|player|embed|kinobox|stream|ortified)[^"']*)["']/gi,
      /["'](?:src|iframe_url|player_url|playerUrl|data_url)["']\s*[=:]\s*["']((?:https?:)?\/\/[^"']+(?:videocdn|collaps|kodik|hdvb|alloha|rutube|player|embed|ortified)[^"']*)["']/gi,
      /player[_\-]?(?:src|url|iframe)\s*[=:]\s*["']((?:https?:)?\/\/[^"']+)["']/gi,
    ];

    for (const pattern of iframePatterns) {
      const matches = [...html.matchAll(pattern)];
      if (matches.length > 0) {
        let iframeUrl = matches[0][1];
        if (iframeUrl.startsWith('//')) iframeUrl = 'https:' + iframeUrl;
        console.log(`[HtmlExtract] Found embedded player URL: ${iframeUrl}`);
        return { type: 'iframe', url: iframeUrl };
      }
    }

    // 3. Look for kinobox or hdvb-style player configs in JavaScript
    const jsConfigPatterns = [
      /(?:iframe|embed|player).*?["']((?:https?:)?\/\/[^"']{10,200})["']/gi,
    ];

    for (const pattern of jsConfigPatterns) {
      const matches = [...html.matchAll(pattern)];
      for (const m of matches) {
        let u = m[1];
        if (u.startsWith('//')) u = 'https:' + u;
        if (u.includes('player') || u.includes('embed') || u.includes('video') || u.includes('ortified')) {
          console.log(`[HtmlExtract] Found JS player config URL: ${u}`);
          return { type: 'iframe', url: u };
        }
      }
    }

    console.log('[HtmlExtract] No player URL found in HTML');
    return null;
  } catch (e) {
    console.log(`[HtmlExtract] Error: ${e.message}`);
    return null;
  }
}
async function extractFromMovieSite(targetUrl) {
  const puppeteer = require('puppeteer-extra');
  const StealthPlugin = require('puppeteer-extra-plugin-stealth');
  puppeteer.use(StealthPlugin());

  console.log(`[Puppeteer] Launching headless browser for ${targetUrl}`);
  const browser = await puppeteer.launch({
    headless: true,
    args: [
      '--no-sandbox', '--disable-setuid-sandbox', '--disable-dev-shm-usage',
      '--disable-blink-features=AutomationControlled',
      '--autoplay-policy=no-user-gesture-required',
      '--disable-features=IsolateOrigins,site-per-process',
      '--disable-popup-blocking',
    ]
  });

  let videoUrl = null;
  let cookies = [];
  let translators = [];

  const isVideoUrl = (u) => {
    if (!u) return false;
    const lower = u.toLowerCase();
    const isMedia = lower.includes('.m3u8') || lower.includes('.mp4') ||
                    lower.includes('okcdn.ru') || lower.includes('vkvd') ||
                    lower.includes('vk-cdn') || lower.includes('vkuser') ||
                    lower.includes('mycdn.me') || lower.includes('userapi.com') ||
                    lower.includes('vk.me') || lower.includes('vkuservideo');
    return isMedia &&
      !lower.includes('prebid') && !lower.includes('vast') &&
      !lower.includes('blank') && !lower.includes('/ad/') &&
      !lower.includes('botsford') && !lower.includes('distribrey') &&
      !lower.includes('yadro') && !lower.includes('preroll') &&
      !lower.includes('franecki') &&
      lower.length > 20;
  };

  const page = await browser.newPage();

  // Block new tabs/popups (LordFilm opens ads in new tabs on click)
  browser.on('targetcreated', async (target) => {
    try {
      if (target.type() === 'page') {
        const newPage = await target.page();
        if (newPage) await newPage.close();
      }
    } catch(e) {}
  });

  await page.setUserAgent('Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36');
  await page.setViewport({ width: 1280, height: 720 });

  // Force HLS/MP4 over WebM
  await page.evaluateOnNewDocument(() => {
    const origCanPlay = HTMLMediaElement.prototype.canPlayType;
    HTMLMediaElement.prototype.canPlayType = function(type) {
      if (type && type.toLowerCase().includes('webm')) return '';
      return origCanPlay.call(this, type);
    };
    if (window.MediaSource && MediaSource.isTypeSupported) {
      const origIsSupported = MediaSource.isTypeSupported;
      MediaSource.isTypeSupported = function(type) {
        if (type && type.toLowerCase().includes('webm')) return false;
        return origIsSupported.call(this, type);
      };
    }
  });

  // Use CDP to intercept ALL network requests including from iframes
  const client = await page.target().createCDPSession();
  await client.send('Network.enable');
  client.on('Network.requestWillBeSent', (params) => {
    const u = params.request.url;
    if (isVideoUrl(u) && !videoUrl) {
      console.log(`[CDP] Intercepted video request: ${u.substring(0, 120)}`);
      videoUrl = u;
    }
  });
  client.on('Network.responseReceived', (params) => {
    const u = params.response.url;
    const ct = (params.response.mimeType || '').toLowerCase();
    if ((ct.includes('mpegurl') || ct.includes('mp4') || ct.includes('video')) && isVideoUrl(u) && !videoUrl) {
      console.log(`[CDP] Intercepted video response (mime: ${ct}): ${u.substring(0, 120)}`);
      videoUrl = u;
    }
  });

  // Block ads/images to speed up
  await page.setRequestInterception(true);
  page.on('request', req => {
    const type = req.resourceType();
    const u = req.url().toLowerCase();
    if (['image', 'stylesheet', 'font'].includes(type)) {
      req.abort();
    } else if (u.includes('googlesyndication') || u.includes('doubleclick') || u.includes('adservice')) {
      req.abort();
    } else {
      req.continue();
    }
  });

  try {
    console.log('[Puppeteer] Navigating to page...');
    try {
      await page.goto(targetUrl, { waitUntil: 'domcontentloaded', timeout: 30000 });
    } catch(navErr) {
      console.log(`[Puppeteer] Goto timeout: ${navErr.message}. Continuing...`);
    }

    // Wait for auto-play
    await new Promise(r => setTimeout(r, 3000));
    if (videoUrl) {
      const cookieArr = await page.cookies().catch(() => []);
      const cookieStr = cookieArr.map(c => `${c.name}=${c.value}`).join('; ');
      await browser.close();
      return { url: videoUrl, title: 'Web Stream', cookies: cookieStr, translators };
    }

    translators = await scrapeTranslators(page);
    if (translators.length > 0) console.log('[Puppeteer] Found translators:', translators.map(t => t.name));

    // Get all iframes from the page
    const getAllIframes = async () => {
      return await page.evaluate(() => {
        const results = [];
        const scan = (doc) => {
          doc.querySelectorAll('iframe').forEach(f => {
            const src = f.src || f.getAttribute('data-src') || '';
            if (src && src.startsWith('http')) results.push(src);
            try { if (f.contentDocument) scan(f.contentDocument); } catch(e) {}
          });
        };
        scan(document);
        return results;
      });
    };

    const getPlayerIframe = async () => {
      const allFrames = await getAllIframes();
      console.log('[Puppeteer] All iframes:', allFrames.slice(0, 5));
      const known = allFrames.find(src => {
        const s = src.toLowerCase();
        return s.includes('collaps') || s.includes('kodik') || s.includes('alloha') ||
               s.includes('videocdn') || s.includes('bazon') || s.includes('hdvb') ||
               s.includes('video') || s.includes('player') || s.includes('embed') ||
               s.includes('vk.com') || s.includes('kinobox') || s.includes('stream');
      });
      return known || (allFrames.length > 0 ? allFrames[0] : null);
    };

    console.log('[Puppeteer] Checking for player iframes...');
    let iframeUrl = await getPlayerIframe();

    if (iframeUrl) {
      console.log(`[Puppeteer] Found player iframe: ${iframeUrl}`);
      try {
        const frameResult = await runYtDlp(iframeUrl);
        if (frameResult && frameResult.url) {
          console.log('[Puppeteer] yt-dlp on iframe succeeded!');
          await browser.close();
          return frameResult;
        }
      } catch (e) {
        console.log(`[Puppeteer] yt-dlp failed on iframe: ${e.message}`);
      }
      console.log(`[Puppeteer] Navigating to iframe: ${iframeUrl}`);
      // Removed page.goto(iframeUrl) to preserve referer context
      translators = await scrapeTranslators(page);
    }

    // Try specific play button selectors
    if (!videoUrl) {
      const playSelectors = [
        '.jw-icon-display', '.plyr__control--overlaid', '.vjs-big-play-button',
        '.play-btn', '.play-button', '[class*="play"]', '.b-player__play',
        '.b-player', 'button[class*="play"]', '.pp-play', '.flowplayer .fp-play'
      ];
      for (const sel of playSelectors) {
        try {
          const el = await page.$(sel);
          if (el) {
            console.log(`[Puppeteer] Clicking: ${sel}`);
            await el.click();
            await new Promise(r => setTimeout(r, 3000));
            if (videoUrl) break;
          }
        } catch(e) {}
      }
    }

    // Fall back to clicking the player container / center
        if (!videoUrl) {
      console.log('[Puppeteer] Taking screenshot for debug...');
      await page.screenshot({ path: 'C:\\RaveStreamer\\server\\debug_player.png' });

      const playerPos = await page.evaluate(() => {
        const p = document.querySelector(
          '.player, #player, .player-box, .kinobox_player, .b-player, ' +
          '.video-player, #videoplayer, iframe, video'
        );
        if (p) {
          p.scrollIntoView({ behavior: 'instant', block: 'center' });
          const rect = p.getBoundingClientRect();
          return { x: rect.x + rect.width / 2, y: rect.y + rect.height / 2 };
        }
        return null;
      });

      const clickX = playerPos ? playerPos.x : 640;
      const clickY = playerPos ? playerPos.y : 360;
      console.log(`[Puppeteer] Clicking at (${clickX}, ${clickY})...`);

      for (let i = 0; i < 15; i++) {
        await page.mouse.click(clickX, clickY);
        await new Promise(r => setTimeout(r, 2000));
        if (videoUrl) break;

        const dynIframe = await getPlayerIframe();
        if (dynIframe && dynIframe !== iframeUrl) {
          console.log(`[Puppeteer] New iframe appeared: ${dynIframe}`);
          iframeUrl = dynIframe;
          // Removed page.goto(dynIframe) to preserve referer context
          translators = await scrapeTranslators(page);
          for (let j = 0; j < 15; j++) {
            const vp = page.viewport();
            await page.mouse.click(vp ? vp.width / 2 : 640, vp ? vp.height / 2 : 360);
            await new Promise(r => setTimeout(r, 2000));
            if (videoUrl) break;
          }
          break;
        }
      }
    }

    if (videoUrl) {
      try { cookies = await page.cookies(); } catch(e) {}
    }
  } catch (err) {
    console.error(`[Puppeteer] Error: ${err.message}`);
  } finally {
    await browser.close();
  }

  if (videoUrl) {
    const cookieStr = cookies.map(c => `${c.name}=${c.value}`).join('; ');
    return { url: videoUrl, title: 'Web Stream', cookies: cookieStr, translators };
  } else {
    throw new Error('Puppeteer could not find any .m3u8 or .mp4 stream on the page.');
  }
}

function isVkOrCdnUrl(urlStr) {
  if (!urlStr) return false;
  const lower = String(urlStr).toLowerCase();
  return lower.includes('vk.com') ||
         lower.includes('vkvideo') ||
         lower.includes('vk.ru') ||
         lower.includes('vkuser') ||
         lower.includes('vk-cdn') ||
         lower.includes('okcdn.ru') ||
         lower.includes('mycdn.me') ||
         lower.includes('userapi.com') ||
         lower.includes('vk.me') ||
         lower.includes('vkuservideo') ||
         lower.includes('ok.ru') ||
         lower.includes('rutube.ru') ||
         lower.includes('rutube');
}

// HLS Proxy to bypass IP-locked cookies
app.get('/proxy/hls', async (req, res) => {
  const { url, cookies, referer } = req.query;
  if (!url) return res.status(400).send('Missing url');

  const fetch = require('node-fetch');
  const headers = {
    'User-Agent': (url.includes('srcAg=CHROME') || isVkOrCdnUrl(url))
      ? 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36'
      : (req.headers['user-agent'] || 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_4 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Mobile/15E148 Safari/604.1'),
    'Accept': '*/*',
    'Accept-Language': 'ru-RU,ru;q=0.9',
  };
  if (cookies) headers['Cookie'] = cookies;
  if (url.includes('rutube.ru') || url.includes('rutube') || (referer && (referer.includes('rutube.ru') || referer.includes('rutube')))) {
    headers['Referer'] = 'https://rutube.ru/';
    headers['Origin'] = 'https://rutube.ru';
  } else if (url.includes('okcdn.ru') || url.includes('mycdn.me') || url.includes('ok.ru')) {
    headers['Referer'] = 'https://ok.ru/';
    headers['Origin'] = 'https://ok.ru';
  } else if (url.includes('vkvideo.ru') || (referer && referer.includes('vkvideo.ru'))) {
    headers['Referer'] = 'https://vkvideo.ru/';
    headers['Origin'] = 'https://vkvideo.ru';
  } else if (isVkOrCdnUrl(url) || (referer && isVkOrCdnUrl(referer))) {
    headers['Referer'] = 'https://vk.com/';
    headers['Origin'] = 'https://vk.com';
  } else if (referer) {
    try {
      const u = new URL(referer);
      headers['Referer'] = u.origin + '/';
      headers['Origin'] = u.origin;
    } catch (_) {}
  }

  try {
    const upstream = await fetch(url, { headers });
    if (!upstream.ok) {
      return res.status(upstream.status).send(`Upstream error: ${upstream.status}`);
    }

    const contentType = upstream.headers.get('content-type') || '';
    const text = await upstream.text();

    if (contentType.includes('mpegurl') || contentType.includes('x-mpegurl') || url.includes('.m3u8')) {
      const serverBase = `${req.protocol}://${req.get('host')}`;

      const rewritten = text.split('\n').map(line => {
        const trimmed = line.trim();
        if (!trimmed) return line;

        if (trimmed.startsWith('#')) {
          // Rewrite URI="url" attributes inside tags (e.g. #EXT-X-MEDIA, #EXT-X-KEY)
          return line.replace(/URI="([^"]+)"/g, (match, p1) => {
            let absUrl;
            try {
              absUrl = new URL(p1, upstream.url).href;
            } catch(e) {
              absUrl = p1;
            }

            let proxyUrl;
            if (absUrl.includes('.m3u8') || absUrl.includes('m3u8')) {
              proxyUrl = `${serverBase}/proxy/hls?url=${encodeURIComponent(absUrl)}&cookies=${encodeURIComponent(cookies || '')}&referer=${encodeURIComponent(referer || '')}`;
            } else {
              proxyUrl = `${serverBase}/proxy/segment?url=${encodeURIComponent(absUrl)}&cookies=${encodeURIComponent(cookies || '')}&referer=${encodeURIComponent(referer || '')}`;
            }
            return `URI="${proxyUrl}"`;
          });
        }

        let absUrl;
        try {
          absUrl = new URL(trimmed, upstream.url).href;
        } catch(e) {
          absUrl = trimmed;
        }

        if (trimmed.includes('.m3u8') || trimmed.includes('m3u8')) {
          return `${serverBase}/proxy/hls?url=${encodeURIComponent(absUrl)}&cookies=${encodeURIComponent(cookies || '')}&referer=${encodeURIComponent(referer || '')}`;
        } else {
          return `${serverBase}/proxy/segment?url=${encodeURIComponent(absUrl)}&cookies=${encodeURIComponent(cookies || '')}&referer=${encodeURIComponent(referer || '')}`;
        }
      }).join('\n');

      res.set('Content-Type', 'application/vnd.apple.mpegurl');
      res.set('Access-Control-Allow-Origin', '*');
      res.send(rewritten);
    } else {
      res.set('Content-Type', contentType);
      res.set('Access-Control-Allow-Origin', '*');
      res.send(text);
    }
  } catch (err) {
    console.error('[HLS Proxy] Error:', err.message);
    res.status(500).send(err.message);
  }
});

app.get('/proxy/segment', async (req, res) => {
  const { url, cookies, referer } = req.query;
  if (!url) return res.status(400).send('Missing url');

  const fetch = require('node-fetch');
  const headers = {
    'User-Agent': (url.includes('srcAg=CHROME') || isVkOrCdnUrl(url))
      ? 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36'
      : (req.headers['user-agent'] || 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_4 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Mobile/15E148 Safari/604.1'),
    'Accept': '*/*',
  };
  if (cookies) headers['Cookie'] = cookies;
  if (url.includes('rutube.ru') || url.includes('rutube') || (referer && (referer.includes('rutube.ru') || referer.includes('rutube')))) {
    headers['Referer'] = 'https://rutube.ru/';
    headers['Origin'] = 'https://rutube.ru';
  } else if (url.includes('okcdn.ru') || url.includes('mycdn.me') || url.includes('ok.ru')) {
    headers['Referer'] = 'https://ok.ru/';
    headers['Origin'] = 'https://ok.ru';
  } else if (url.includes('vkvideo.ru') || (referer && referer.includes('vkvideo.ru'))) {
    headers['Referer'] = 'https://vkvideo.ru/';
    headers['Origin'] = 'https://vkvideo.ru';
  } else if (isVkOrCdnUrl(url) || (referer && isVkOrCdnUrl(referer))) {
    headers['Referer'] = 'https://vk.com/';
    headers['Origin'] = 'https://vk.com';
  } else if (referer) {
    try {
      const u = new URL(referer);
      headers['Referer'] = u.origin + '/';
      headers['Origin'] = u.origin;
    } catch (_) {}
  }
  if (req.headers.range) {
    headers['Range'] = req.headers.range;
  }

  const controller = new AbortController();
  req.on('close', () => {
    controller.abort();
  });

  let upstream;
  let attempts = 0;
  while (attempts < 3) {
    try {
      upstream = await fetch(url, { headers, signal: controller.signal });
      if (upstream.ok || upstream.status === 206 || (upstream.status < 500 && upstream.status !== 429)) {
        break;
      }
    } catch (e) {
      if (e.name === 'AbortError') return;
    }
    attempts++;
    await new Promise(r => setTimeout(r, 400 * attempts));
  }

  try {
    if (!upstream || (!upstream.ok && upstream.status !== 206)) {
      const status = upstream ? upstream.status : 502;
      return res.status(status).send(`Segment upstream error: ${status}`);
    }

    res.status(upstream.status);
    ['content-type', 'content-length', 'content-range', 'accept-ranges'].forEach(h => {
      if (upstream.headers.has(h)) res.set(h, upstream.headers.get(h));
    });
    res.set('Access-Control-Allow-Origin', '*');
    upstream.body.on('error', (err) => {
      if (err.name === 'AbortError') return; // Ignore aborts
      console.error('[Segment Proxy] Stream error:', err.message);
      res.end();
    }).pipe(res);
  } catch (err) {
    if (err.name === 'AbortError') return; // Ignore aborts
    console.error('[Segment Proxy] Error:', err.message);
    if (!res.headersSent) res.status(500).send(err.message);
  }
});

// Endpoint to extract video from third-party sites
app.get('/extract', async (req, res) => {
  const targetUrl = req.query.url;
  if (!targetUrl) {
    return res.status(400).json({ success: false, error: 'Query parameter "url" is required' });
  }
  try {
    console.log(`Extracting video from URL: ${targetUrl}`);
    let result;
    const lowerTarget = targetUrl.toLowerCase();
    if (lowerTarget.includes('.m3u8') || lowerTarget.includes('.mp4') || lowerTarget.includes('.mkv') ||
        lowerTarget.includes('okcdn.ru') || lowerTarget.includes('vkvd') || lowerTarget.includes('mycdn.me') ||
        lowerTarget.includes('vkuservideo') || lowerTarget.includes('vk-cdn') || lowerTarget.includes('userapi.com')) {
      console.log(`[Extract] URL is already a direct media stream: ${targetUrl}`);
      result = {
        url: targetUrl,
        title: 'Direct Video Stream',
        isHls: lowerTarget.includes('.m3u8') || lowerTarget.includes('m3u8')
      };
    } else {
      try {
        // 1. Try direct yt-dlp extraction (fastest)
        result = await runYtDlp(targetUrl);
        console.log('Direct yt-dlp run completed successfully.');
      } catch (directErr) {
        console.log(`Direct yt-dlp run failed: ${directErr.message}.`);
      }
      if (targetUrl.includes('youtube.com') || targetUrl.includes('youtu.be')) {
        console.log('Trying dynamic Invidious API fallback for YouTube...');
        let videoId = targetUrl.includes('youtu.be/') ? targetUrl.split('youtu.be/')[1]?.split('?')[0] : targetUrl.split('v=')[1]?.split('&')[0];
        if (videoId) {
          const fetch = require('node-fetch');
          try {
            const instancesRes = await fetch('https://api.invidious.io/instances.json?sort_by=health');
            if (instancesRes.ok) {
              const instancesData = await instancesRes.json();
              const activeInstances = instancesData.filter(i => i[1] && i[1].type === 'https' && i[1].api === true).map(i => i[1].uri);

              for (const inst of activeInstances.slice(0, 10)) {
                try {
                  console.log(`Trying Invidious instance: ${inst}`);
                  const controller = new AbortController();
                  const timeout = setTimeout(() => controller.abort(), 4000);
                  const res = await fetch(`${inst}/api/v1/videos/${videoId}`, { signal: controller.signal });
                  clearTimeout(timeout);

                  if (res.ok) {
                    const data = await res.json();
                    const stream = data.formatStreams && (data.formatStreams.find(s => s.resolution && s.resolution.includes('1080')) || data.formatStreams[0]);
                    if (stream && stream.url) {
                      result = { url: stream.url, title: data.title };
                      console.log(`Invidious API fallback successful on ${inst}.`);
                      break;
                    }
                  }
                } catch(e) { /* ignore and try next */ }
              }
            }
          } catch(e) { console.log('Failed to fetch Invidious instances', e.message); }
        }
      }

      if (!result) {
        // 2. Try HTML extraction: fetch page with DDoS-Guard bypass, parse player iframe URL
        console.log('Trying HTML extraction (DDoS-Guard bypass + iframe parsing)...');
        try {
          const htmlResult = await extractPlayerFromHtml(targetUrl);
          if (htmlResult) {
            if (htmlResult.type === 'video') {
              result = { url: htmlResult.url, title: 'Web Stream', cookies: '' };
              console.log(`[HtmlExtract] Using direct video URL from HTML: ${htmlResult.url}`);
            } else if (htmlResult.type === 'iframe') {
              console.log(`[HtmlExtract] Trying yt-dlp on player iframe: ${htmlResult.url}`);
              try {
                result = await runYtDlp(htmlResult.url);
                console.log('[HtmlExtract] yt-dlp on player iframe succeeded!');
              } catch(e) {
                console.log(`[HtmlExtract] yt-dlp on iframe failed: ${e.message}. Trying HTML extraction on iframe...`);
                try {
                  const recursiveResult = await extractPlayerFromHtml(htmlResult.url, targetUrl);
                  if (recursiveResult && recursiveResult.type === 'video') {
                    console.log(`[HtmlExtract] Success! Found direct video inside iframe: ${recursiveResult.url}`);
                    result = { url: recursiveResult.url, title: 'Web Stream', cookies: '' };
                  } else {
                    console.log(`[HtmlExtract] Recursive HTML extraction did not yield a direct video. Using Puppeteer on iframe only...`);
                    result = await extractFromMovieSite(htmlResult.url);
                  }
                } catch (e2) {
                  console.log(`[HtmlExtract] Recursive HTML extraction error: ${e2.message}. Using Puppeteer on iframe only...`);
                  result = await extractFromMovieSite(htmlResult.url);
                }
              }
            }
          }
        } catch(e) {
          console.log(`[HtmlExtract] HTML extraction failed: ${e.message}`);
        }
      }

      if (!result) {
        console.log('Trying full Puppeteer scraper on original URL...');
        result = await extractFromMovieSite(targetUrl);
      }
    }

    let finalUrl = result.url;
    const isM3U8 = finalUrl.includes('.m3u8') || finalUrl.includes('m3u8') || !!result.isHls;
    if (isM3U8) {
      finalUrl = `/proxy/hls?url=${encodeURIComponent(result.url)}&cookies=${encodeURIComponent(result.cookies || '')}&referer=${encodeURIComponent(targetUrl)}`;
    } else if (isVkOrCdnUrl(finalUrl) || isVkOrCdnUrl(targetUrl) || finalUrl.includes('.mp4')) {
      finalUrl = `/proxy/segment?url=${encodeURIComponent(result.url)}&cookies=${encodeURIComponent(result.cookies || '')}&referer=${encodeURIComponent(targetUrl)}`;
    }

    res.json({
      success: true,
      url: finalUrl,
      title: result.title,
      cookies: result.cookies,
      translators: result.translators || []
    });
  } catch (error) {
    console.error('Extraction error:', error.message);
    res.status(500).json({ success: false, error: error.message });
  }
});

// Active live stream relay buffers per room
const activeLiveStreams = new Map(); // roomId -> { viewers: Set<res>, header0: Buffer, header1: Buffer, recentChunks: Buffer[] }
const activeLiveFrames = new Map(); // roomId -> { frame: Buffer, viewers: Set<res> }

app.get('/live-stream-mjpeg/:roomId', (req, res) => {
  const roomId = req.params.roomId;
  let stream = activeLiveFrames.get(roomId);
  if (!stream) {
    stream = { frame: null, viewers: new Set() };
    activeLiveFrames.set(roomId, stream);
  }

  res.writeHead(200, {
    'Content-Type': 'multipart/x-mixed-replace; boundary=ffserverbound',
    'Cache-Control': 'no-cache, no-store, must-revalidate',
    'Pragma': 'no-cache',
    'Expires': '0',
    'Connection': 'close',
    'Access-Control-Allow-Origin': '*'
  });

  stream.viewers.add(res);

  if (stream.frame) {
    try {
      res.write(`--ffserverbound\r\nContent-Type: image/jpeg\r\nContent-Length: ${stream.frame.length}\r\n\r\n`);
      res.write(stream.frame);
      res.write('\r\n');
    } catch (_) {}
  }

  req.on('close', () => {
    stream.viewers.delete(res);
  });
});

app.get('/live-stream/:roomId', (req, res) => {
  const roomId = req.params.roomId;
  let stream = activeLiveStreams.get(roomId);

  if (!stream) {
    stream = { viewers: new Set(), header0: null, header1: null, recentChunks: [] };
    activeLiveStreams.set(roomId, stream);
  }

  res.setHeader('Content-Type', 'video/webm');
  res.setHeader('Cache-Control', 'no-cache, no-store, must-revalidate');
  res.setHeader('Pragma', 'no-cache');
  res.setHeader('Expires', '0');
  res.setHeader('Connection', 'keep-alive');
  res.setHeader('Transfer-Encoding', 'chunked');
  res.setHeader('bypass-tunnel-reminder', 'true');
  res.setHeader('Access-Control-Allow-Origin', '*');

  stream.viewers.add(res);

  if (stream.header0) {
    try { res.write(stream.header0); } catch (_) {}
  }
  if (stream.header1) {
    try { res.write(stream.header1); } catch (_) {}
  }
  if (stream.recentChunks && stream.recentChunks.length > 0) {
    for (const chunk of stream.recentChunks) {
      try { res.write(chunk); } catch (_) {}
    }
  }

  req.on('close', () => {
    if (stream) {
      stream.viewers.delete(res);
    }
  });
});

app.get('/version', async (req, res) => {
  try {
    const fetch = require('node-fetch');
    const response = await fetch('https://api.github.com/repos/stepa1235/RaveStreamerClient/releases/latest', { headers: { 'User-Agent': 'LunaServer/1.0' } });
    const data = await response.json();
    if (data.tag_name) {
      let version = data.tag_name;
      if (version.startsWith('v')) version = version.substring(1);

      let androidUrl = '';
      let windowsUrl = '';

      if (data.assets) {
        for (const asset of data.assets) {
          if (asset.name.endsWith('.apk')) androidUrl = asset.browser_download_url;
          if (asset.name.endsWith('.zip')) windowsUrl = asset.browser_download_url;
        }
      }

      return res.json({
        latest_version: version,
        android_url: androidUrl,
        windows_url: windowsUrl
      });
    }
  } catch (err) {
    console.error('Failed to fetch latest release from GitHub', err);
  }

  // Fallback
  res.json({
    "latest_version": "1.0.13",
    "android_url": "https://github.com/stepa1235/RaveStreamerClient/releases/download/v1.0.13/app-release.apk",
    "windows_url": "https://github.com/stepa1235/RaveStreamerClient/releases/download/v1.0.13/RaveStreamer-Windows.zip"
  });
});

// Switch dubbing: reload page, click translator button by index, capture new stream
app.get('/extract-translator', async (req, res) => {
  const { url, index } = req.query;
  if (!url || index === undefined) {
    return res.status(400).json({ success: false, error: 'url and index are required' });
  }
  const targetIndex = parseInt(index, 10);
  console.log(`[Translator] Switching to translator index ${targetIndex} on ${url}`);

  const puppeteer = require('puppeteer-core');
  const browser = await puppeteer.launch({
    executablePath: process.env.PUPPETEER_EXECUTABLE_PATH || '/usr/bin/chromium-browser',
    args: ['--no-sandbox','--disable-setuid-sandbox','--disable-dev-shm-usage','--autoplay-policy=no-user-gesture-required','--disable-web-security','--disable-features=IsolateOrigins,site-per-process'],
    headless: true,
    timeout: 60000,
  });

  try {
    const page = await browser.newPage();
    await page.setViewport({ width: 1280, height: 720 });
    await page.setUserAgent('Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36');

    let videoUrl = null;
    await page.setRequestInterception(true);
    page.on('request', req => {
      const u = req.url();
      if ((u.includes('.m3u8') || u.includes('.mp4')) && !u.includes('prebid') && !u.includes('blank')) videoUrl = u;
      const t = req.resourceType();
      if (['image','stylesheet','font'].includes(t)) req.abort(); else req.continue();
    });
    page.on('response', resp => {
      const u = resp.url();
      const ct = resp.headers()['content-type'] || '';
      if ((ct.includes('mpegurl') || ct.includes('video/mp4')) && !u.includes('prebid') && !u.includes('blank')) {
        videoUrl = u;
        console.log('[Translator] Found video via response:', u.substring(0, 80));
      }
    });

    await page.goto(url, { waitUntil: 'domcontentloaded', timeout: 30000 }).catch(() => {});
    await new Promise(r => setTimeout(r, 3000));

    // Click the translator button at the given index inside player iframe if present
    const getPlayerIframe = async () => {
      return await page.evaluate(() => {
        const frames = Array.from(document.querySelectorAll('iframe'));
        const playerFrame = frames.find(f => {
           const src = f.src ? f.src.toLowerCase() : '';
           return src.includes('collaps') || src.includes('kodik') || src.includes('alloha') || src.includes('videocdn') || src.includes('bazon') || src.includes('ustore') || src.includes('video') || src.includes('player');
        });
        return playerFrame ? playerFrame.src : null;
      });
    };

    let iframeUrl = await getPlayerIframe();
    if (iframeUrl) {
      console.log(`[Translator] Found potential player iframe: ${iframeUrl}. Navigating directly...`);
      await page.goto(iframeUrl, { waitUntil: 'domcontentloaded', timeout: 30000 }).catch(() => {});
      await new Promise(r => setTimeout(r, 2000));
    }

    const clicked = await page.evaluate((idx) => {
      const items = Array.from(document.querySelectorAll(
        '.b-translator__item, .translator-item, [data-translator_id], .tabs-sel span[data-voice], .voice-btn, .voice-item, .voice_item, select.voice-select option, select[name="voice"] option'
      ));
      if (idx >= 0 && idx < items.length) {
        const item = items[idx];
        if (item.tagName.toLowerCase() === 'option') {
          const select = item.parentNode;
          select.value = item.value;
          select.dispatchEvent(new Event('change', { bubbles: true }));
          return true;
        } else {
          item.click();
          return true;
        }
      }
      return false;
    }, targetIndex);

    console.log('[Translator] Click result:', clicked);

    // Wait for new video URL to appear
    for (let i = 0; i < 30; i++) {
      await new Promise(r => setTimeout(r, 1000));
      if (videoUrl) break;
    }

    if (!videoUrl) {
      // Try clicking player area to trigger autoplay
      const playerPos = await page.evaluate(() => {
        const p = document.querySelector('.player, #player, .player-box, iframe');
        if (p) {
          p.scrollIntoView({ behavior: 'instant', block: 'center' });
          const rect = p.getBoundingClientRect();
          return { x: rect.x + rect.width / 2, y: rect.y + rect.height / 2 };
        }
        return null;
      });
      if (playerPos) {
        for (let i = 0; i < 10; i++) {
          await page.mouse.click(playerPos.x, playerPos.y);
          await new Promise(r => setTimeout(r, 1500));
          if (videoUrl) break;
        }
      }
    }

    await browser.close();

    if (!videoUrl) {
      return res.status(500).json({ success: false, error: 'Could not find stream for this dubbing' });
    }

    let finalUrl = videoUrl;
    const isM3U8 = finalUrl.includes('.m3u8') || finalUrl.includes('m3u8');
    const isDirectFile = finalUrl.includes('.mp4') || finalUrl.includes('.webm') || finalUrl.includes('.ogg') || finalUrl.includes('googlevideo.com') || isVkOrCdnUrl(finalUrl) || isVkOrCdnUrl(url);

    if (isM3U8) {
      finalUrl = `/proxy/hls?url=${encodeURIComponent(videoUrl)}&cookies=&referer=${encodeURIComponent(url)}`;
    } else if (isDirectFile || isVkOrCdnUrl(finalUrl) || isVkOrCdnUrl(url)) {
      finalUrl = `/proxy/segment?url=${encodeURIComponent(videoUrl)}&cookies=&referer=${encodeURIComponent(url)}`;
    } else {
      finalUrl = `/proxy/hls?url=${encodeURIComponent(videoUrl)}&cookies=&referer=${encodeURIComponent(url)}`;
    }

    res.json({ success: true, url: finalUrl });
  } catch (err) {
    await browser.close().catch(() => {});
    console.error('[Translator] Error:', err.message);
    res.status(500).json({ success: false, error: err.message });
  }
});

// Stream proxy: uses ffmpeg to convert HLS (.m3u8) to a streamable MP4
// video_player_win cannot play .m3u8 natively, so we transcode on the fly
app.get('/proxy/stream', async (req, res) => {
  const { url, cookies, referer } = req.query;
  if (!url) return res.status(400).send('Missing url');

  const { spawn } = require('child_process');

  const ffmpegHeaders = [
    `User-Agent: Mozilla/5.0 (iPhone; CPU iPhone OS 17_4 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Mobile/15E148 Safari/604.1`
  ];
  if (cookies) ffmpegHeaders.push(`Cookie: ${cookies}`);
  if (referer) {
    try {
      const u = new URL(referer);
      ffmpegHeaders.push(`Referer: ${u.origin}/`);
      ffmpegHeaders.push(`Origin: ${u.origin}`);
    } catch (_) {}
  }

  const headerStr = ffmpegHeaders.join('\r\n');

  console.log(`[Proxy] Streaming via ffmpeg: ${url.substring(0, 80)}`);

  res.setHeader('Content-Type', 'video/mp4');
  res.setHeader('Transfer-Encoding', 'chunked');
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Cache-Control', 'no-cache');

  const ffmpegArgs = [
    '-headers', headerStr,
    '-i', url,
    '-c', 'copy',          // Copy codecs — no re-encoding, very fast
    '-movflags', 'frag_keyframe+empty_moov+faststart',
    '-f', 'mp4',
    'pipe:1'               // Output to stdout
  ];

  const ffmpeg = spawn('ffmpeg', ffmpegArgs, { stdio: ['ignore', 'pipe', 'pipe'] });

  ffmpeg.stdout.pipe(res);

  ffmpeg.stderr.on('data', (d) => {
    // Log only occasionally to avoid spamming
    const line = d.toString();
    if (line.includes('Error') || line.includes('error') || line.includes('time=')) {
      console.log('[ffmpeg]', line.trim().substring(0, 120));
    }
  });

  ffmpeg.on('close', (code) => {
    console.log(`[ffmpeg] Process exited with code ${code}`);
    if (!res.headersSent) res.end();
  });

  ffmpeg.on('error', (err) => {
    console.error('[ffmpeg] Failed to start:', err.message);
    if (!res.headersSent) {
      res.status(500).send('ffmpeg not available: ' + err.message);
    }
  });

  req.on('close', () => {
    console.log('[Proxy] Client disconnected, killing ffmpeg');
    ffmpeg.kill('SIGKILL');
  });
});

// Video streaming endpoint with support for Range requests (critical for video seeking)
app.get('/video', (req, res) => {
  const videoPath = req.query.path;
  if (!videoPath || typeof videoPath !== 'string') {
    return res.status(400).send('Query parameter "path" is required');
  }

  // Prevent null bytes injection
  if (videoPath.includes('\0')) {
    return res.status(400).send('Invalid path');
  }

  const videosDir = path.resolve(__dirname, 'videos');
  const allowedDirs = [videosDir, uploadsDir];
  if (!fs.existsSync(videosDir)) {
    try { fs.mkdirSync(videosDir, { recursive: true }); } catch (_) {}
  }

  // Normalize path and ensure it stays strictly within authorized media directories
  let cleanPath = path.normalize(videoPath).replace(/^"|"$/g, '');
  let resolvedPath;
  if (path.isAbsolute(cleanPath)) {
    resolvedPath = path.resolve(cleanPath);
  } else {
    resolvedPath = path.resolve(videosDir, cleanPath);
  }

  const isAllowed = allowedDirs.some(dir => resolvedPath.startsWith(dir + path.sep) || resolvedPath === dir);
  if (!isAllowed) {
    console.warn(`[Security] Blocked unauthorized /video path attempt: "${videoPath}" from IP: ${req.ip}`);
    return res.status(403).send('Forbidden: Access outside authorized media directory is denied');
  }

  const ext = path.extname(resolvedPath).toLowerCase();
  const allowedExts = ['.mp4', '.mkv', '.webm', '.avi', '.mov', '.ts', '.m3u8', '.mp3', '.m4a', '.flv'];
  if (!allowedExts.includes(ext)) {
    return res.status(403).send('Forbidden: Invalid media file type');
  }

  if (!fs.existsSync(resolvedPath)) {
    return res.status(404).send('Video file not found');
  }

  try {
    const stat = fs.statSync(resolvedPath);
    const fileSize = stat.size;
    const range = req.headers.range;

    // Detect content type based on extension
    let contentType = 'video/mp4';
    if (ext === '.mkv') contentType = 'video/x-matroska';
    else if (ext === '.webm') contentType = 'video/webm';
    else if (ext === '.avi') contentType = 'video/x-msvideo';
    else if (ext === '.mov') contentType = 'video/quicktime';
    else if (ext === '.mp3') contentType = 'audio/mpeg';
    else if (ext === '.m4a') contentType = 'audio/mp4';

    if (range) {
      const parts = range.replace(/bytes=/, "").split("-");
      const start = parseInt(parts[0], 10);
      const end = parts[1] ? parseInt(parts[1], 10) : fileSize - 1;

      if (start >= fileSize) {
        res.status(416).send('Requested range not satisfiable\n' + start + ' >= ' + fileSize);
        return;
      }

      const chunksize = (end - start) + 1;
      const file = fs.createReadStream(cleanPath, { start, end });
      const head = {
        'Content-Range': `bytes ${start}-${end}/${fileSize}`,
        'Accept-Ranges': 'bytes',
        'Content-Length': chunksize,
        'Content-Type': contentType,
      };

      res.writeHead(206, head);
      file.pipe(res);
    } else {
      const head = {
        'Content-Length': fileSize,
        'Content-Type': contentType,
      };
      res.writeHead(200, head);
      fs.createReadStream(cleanPath).pipe(res);
    }
  } catch (error) {
    console.error('Error streaming video:', error);
    res.status(500).send('Internal server error streaming video');
  }
});

// Create HTTP and WebSocket server
const server = http.createServer(app);
const io = new Server(server, {
  cors: {
    origin: '*',
    methods: ['GET', 'POST']
  },
  pingInterval: 10000,
  pingTimeout: 5000
});

// Room states storage
// Key: roomId, Value: { roomId, videoUrl, videoName, isPlaying, currentTime, lastUpdated, users: [{ id, username }] }
const rooms = new Map();

// Persistent Room Hosts Storage (roomId -> { hostToken, hostClientId, hostUsername, createdAt })
const ROOM_HOSTS_FILE = path.join(__dirname, 'room_hosts.json');
let persistentRoomHosts = Object.create(null);
try {
  if (fs.existsSync(ROOM_HOSTS_FILE)) {
    const raw = JSON.parse(fs.readFileSync(ROOM_HOSTS_FILE, 'utf-8'));
    for (const [rId, val] of Object.entries(raw)) {
      if (typeof val === 'string') {
        persistentRoomHosts[rId] = {
          hostToken: null,
          hostClientId: null,
          hostUsername: val,
          createdAt: Date.now()
        };
      } else if (val && typeof val === 'object') {
        persistentRoomHosts[rId] = val;
      }
    }
    console.log(`Loaded ${Object.keys(persistentRoomHosts).length} persistent room hosts.`);
  }
} catch (e) {
  console.error('Error loading room_hosts.json:', e);
}

function saveRoomHosts() {
  try {
    fs.writeFileSync(ROOM_HOSTS_FILE, JSON.stringify(persistentRoomHosts, null, 2), 'utf-8');
  } catch (e) {
    console.error('Error saving room_hosts.json:', e);
  }
}

// Admin Stats Broadcast
setInterval(() => {
  const statsRooms = {};
  for (const [rId, room] of rooms.entries()) {
    statsRooms[rId] = {
      roomId: room.roomId,
      videoUrl: room.videoUrl,
      videoName: room.videoName,
      isPlaying: room.isPlaying,
      currentTime: room.currentTime,
      users: room.users || [],
      queue: room.queue || [],
      isLiveStreaming: room.isLiveStreaming || false
    };
  }
  io.to('luna:admin').emit('admin-stats', { rooms: statsRooms });
}, 5000);

// coturn must use the same TURN_SHARED_SECRET and use-auth-secret configuration.
// Relay credentials are short-lived and issued only after joining a room.
function getIceServers(socketId = null) {
  const servers = [
    { urls: 'stun:stun.l.google.com:19302' },
    { urls: 'stun:stun1.l.google.com:19302' }
  ];
  if (socketId && process.env.TURN_SHARED_SECRET && process.env.TURN_URLS) {
    const username = `${Math.floor(Date.now() / 1000) + 3600}:${socketId}`;
    servers.push({
      urls: process.env.TURN_URLS.split(',').map(s => s.trim()).filter(Boolean),
      username,
      credential: crypto.createHmac('sha1', process.env.TURN_SHARED_SECRET).update(username).digest('base64')
    });
  }
  return servers;
}

io.on('connection', (socket) => {
  if (validAdminToken(socket.handshake.auth?.adminToken)) socket.join('luna:admin');
  // Validate before destructuring event arguments; reject malformed and cross-room traffic.
  let eventWindow = Date.now();
  let eventCount = 0;
  socket.use(([event, data], next) => {
    if (Date.now() - eventWindow >= 10000) { eventWindow = Date.now(); eventCount = 0; }
    if (++eventCount > 1200) return;
    if (event === 'get-ice-servers') return next();
    if (!data || typeof data !== 'object' || Array.isArray(data) || Buffer.isBuffer(data)) return;
    if (typeof data.roomId !== 'string' || !/^[a-zA-Z0-9_-]{1,128}$/.test(data.roomId)) return;
    if (event !== 'join-room' && (!socket.rooms.has(data.roomId) ||
        !rooms.get(data.roomId)?.users.some(u => u.id === socket.id))) return;
    if (event.startsWith('webrtc-') && !rooms.get(data.roomId)?.users.some(u => u.id === data.targetId)) return;
    if (['play', 'pause', 'seek'].includes(event) &&
        (typeof data.time !== 'number' || !Number.isFinite(data.time) || data.time < 0)) return;
    if (event === 'sync-state' && (typeof data.isPlaying !== 'boolean' ||
        typeof data.currentTime !== 'number' || !Number.isFinite(data.currentTime) || data.currentTime < 0)) return;
    if (['video-change', 'change-video', 'add-to-queue'].includes(event)) {
      if (typeof data.videoUrl !== 'string' || data.videoUrl.length > 8192 ||
          (data.videoName != null && (typeof data.videoName !== 'string' || data.videoName.length > 512))) return;
    }
    if (event === 'chat-msg' && data.replyTo != null) {
      if (typeof data.replyTo !== 'object' || Array.isArray(data.replyTo)) return;
      for (const key of ['id', 'sender', 'username', 'text']) {
        if (data.replyTo[key] != null && (typeof data.replyTo[key] !== 'string' || data.replyTo[key].length > 4000)) return;
      }
    }
    if (event === 'join-room') {
      for (const key of ['username', 'password', 'clientId', 'hostToken', 'adminToken']) {
        if (data[key] != null && (typeof data[key] !== 'string' || data[key].length > 256)) return;
      }
      if (socket.rooms.has(data.roomId)) return;
    }
    next();
  });
  console.log(`User connected: ${socket.id}`);

  // Send ICE servers immediately upon connection so all WebRTC peers are ready
  socket.emit('ice-servers', getIceServers());

  // Dynamic ICE / TURN configuration for authorized clients
  socket.on('get-ice-servers', () => {
    const joined = [...rooms.values()].some(room => room.users.some(u => u.id === socket.id));
    socket.emit('ice-servers', getIceServers(joined ? socket.id : null));
  });

  // Join or create a room
  socket.on('join-room', ({ roomId, username, password, isHost, isBroadcaster, clientId, hostToken, adminToken }) => {
    if (!roomId) return;

    let room = rooms.get(roomId);
    const isNewRoom = !room && !persistentRoomHosts[roomId];
    const rawUsername = username || `Guest_${socket.id.slice(0, 4)}`;
    // Strip invisible/zero-width and spoofing characters
    const cleanUsername = rawUsername.replace(/[\u200B-\u200D\uFEFF]/g, '').trim() || `Guest_${socket.id.slice(0, 4)}`;
    const isAdminSocket = validAdminToken(adminToken);

    // Check persistent hosts
    const savedHostEntry = persistentRoomHosts[roomId];
    // Device IDs are public metadata, not proof of ownership.
    const isBroadcasterUser = Boolean(isBroadcaster && (isAdminSocket ||
      (hostToken && hostToken === (room?.hostToken || savedHostEntry?.hostToken))));

    if (!room) {
      let initialHostToken = null;
      let initialHostClientId = null;
      let initialHostUsername = null;

      if (savedHostEntry) {
        initialHostToken = savedHostEntry.hostToken;
        initialHostClientId = savedHostEntry.hostClientId;
        initialHostUsername = savedHostEntry.hostUsername;
      }

      // If room is completely new, generate a secure hostToken
      if (!initialHostToken) {
        initialHostToken = (hostToken && typeof hostToken === 'string' && hostToken.length >= 16)
          ? hostToken
          : crypto.randomBytes(24).toString('hex');
        initialHostClientId = clientId || null;
        initialHostUsername = cleanUsername;
        persistentRoomHosts[roomId] = {
          hostToken: initialHostToken,
          hostClientId: initialHostClientId,
          hostUsername: initialHostUsername,
          createdAt: Date.now()
        };
        saveRoomHosts();
      }

      // Create new room if it doesn't exist
      room = {
        roomId,
        password: password || null,
        hostToken: initialHostToken,
        hostClientId: initialHostClientId,
        hostUsername: initialHostUsername || cleanUsername,
        videoUrl: '',
        videoName: '',
        isPlaying: false,
        currentTime: 0,
        lastUpdated: Date.now(),
        users: [],
        bannedUsernames: new Set(),
        bannedIPs: new Set(),
        messages: [],
        uploadedFiles: [],
        isLiveStreaming: false
      };
      rooms.set(roomId, room);
    } else {
      // Room exists in memory: verify password and bans
      if (room.password && room.password !== password) {
        socket.emit('room-error', { type: 'WRONG_PASSWORD', message: 'Неверный пароль или комната приватная.' });
        return;
      }

      // Check if user is banned
      const clientIP = socket.handshake.address;
      const isLoopback = clientIP === '::1' || clientIP === '127.0.0.1' || clientIP.includes('localhost');
      if (room.bannedUsernames.has(username) || (!isLoopback && room.bannedIPs.has(clientIP))) {
        console.log(`Rejecting banned user ${username} (IP: ${clientIP}) from room ${roomId}`);
        socket.emit('join-error', 'You are banned from this room.');
        return;
      }

      // If user reconnects with same socket/clientId, remove stale socket to avoid duplicate
      if (clientId) {
        room.users = room.users.filter(u => u.id !== socket.id);
      }

      // Check if username is already taken by another active user in this room (skip for broadcaster)
      if (!isBroadcasterUser) {
        const isDuplicateName = room.users.some(u =>
          u.id !== socket.id &&
          !u.isBroadcaster &&
          u.username.toLowerCase() === cleanUsername.toLowerCase()
        );
        if (isDuplicateName) {
          console.log(`Rejecting duplicate username "${cleanUsername}" in room ${roomId}`);
          socket.emit('room-error', {
            type: 'DUPLICATE_USERNAME',
            message: 'Пользователь с таким именем уже есть в комнате! Выберите другое имя.'
          });
          return;
        }
      }
    }

    socket.join(roomId);

    if (room.emptyTimer) {
      clearTimeout(room.emptyTimer);
      room.emptyTimer = null;
      console.log(`Room ${roomId} grace period cancelled: user re-joined.`);
    }

    // Determine host:
    // 1. hostToken matches room.hostToken (cryptographic match)
    // 3. The creator of a new, unreserved room is host
    // 4. Admin socket with valid adminToken
    // 5. Broadcaster is authorized ONLY if they possess a matching hostToken or adminToken
    const tokenMatches = Boolean(hostToken && room.hostToken && hostToken === room.hostToken);
    const isFirstUserInNewRoom = isNewRoom;

    // Broadcaster must prove ownership with hostToken or adminToken:

    let isUserHost = Boolean(isBroadcasterUser || tokenMatches || isFirstUserInNewRoom || isAdminSocket);

    // If verified as host, ensure room host metadata is up to date
    if (isUserHost && !isBroadcasterUser) {
      room.hostUsername = cleanUsername;
      if (clientId) room.hostClientId = clientId;
      if (!room.hostToken) {
        room.hostToken = (hostToken && hostToken.length >= 16) ? hostToken : crypto.randomBytes(24).toString('hex');
      }
      persistentRoomHosts[roomId] = {
        hostToken: room.hostToken,
        hostClientId: room.hostClientId,
        hostUsername: room.hostUsername,
        createdAt: persistentRoomHosts[roomId]?.createdAt || Date.now()
      };
      saveRoomHosts();

      // Ensure no other active viewer retains host flag
      for (const u of room.users) {
        if (!u.isBroadcaster) u.isHost = false;
      }
    }

    const user = {
      id: socket.id,
      clientId: clientId || null,
      username: isBroadcasterUser ? `${cleanUsername} (Broadcaster)` : cleanUsername,
      isHost: isUserHost,
      isBroadcaster: isBroadcasterUser
    };
    room.users.push(user);
    // Keep host at index 0 if present
    room.users.sort((a, b) => (b.isHost ? 1 : 0) - (a.isHost ? 1 : 0));

    console.log(`User ${user.username} (${socket.id}, clientId=${clientId}, isHost=${isUserHost}) joined room: ${roomId}`);

    // Notify all users in the room of updated user list
    io.to(roomId).emit('room-users', room.users);

    if (!isBroadcasterUser && !isAdminSocket && !user.username.includes('(Broadcaster)')) {
      const joinMessage = {
        id: Date.now().toString() + Math.random().toString(),
        username: 'System',
        text: `${user.username} joined the room`,
        timestamp: Date.now(),
        clientId: 'system'
      };
      room.messages.push(joinMessage);
      if (room.messages.length > 100) room.messages.shift();
      io.to(roomId).emit('chat-msg', joinMessage);
    }

    // Send current room playback state to the newly joined user
    socket.emit('room-state', {
      hostUsername: room.hostUsername,
      isHost: isUserHost,
      hostToken: isUserHost ? room.hostToken : null,
      videoUrl: room.videoUrl,
      videoName: room.videoName,
      isPlaying: room.isPlaying,
      currentTime: room.currentTime,
      // If video is playing, send calculated current time based on last update time
      calculatedTime: room.isPlaying
        ? room.currentTime + (Date.now() - room.lastUpdated) / 1000
        : room.currentTime,
      queue: room.queue || [],
      headers: room.headers,
      isLiveStreaming: room.isLiveStreaming
    });

    // Send ICE servers immediately to the joining client
    socket.emit('ice-servers', getIceServers(socket.id));

    // Send the last 50 chat messages from room history
    socket.emit('chat-history', room.messages || []);
  });

  function isRoomHost(room, socketId) {
    if (!room || !room.users) return false;
    const user = room.users.find(u => u.id === socketId);
    if (!user) return false;
    return Boolean(user.isHost || user.isBroadcaster);
  }

  // Clear player event
  socket.on('clear-player', ({ roomId }) => {
    const room = rooms.get(roomId);
    if (!room) return;
    if (!isRoomHost(room, socket.id)) {
      socket.emit('action-error', 'Только хост может очистить плеер.');
      return;
    }

    room.videoUrl = '';
    room.videoName = 'No Video Loaded';
    room.headers = null;
    room.isPlaying = false;
    room.currentTime = 0;
    room.isLiveStreaming = false;

    console.log(`Room ${roomId} player cleared by host ${socket.id}`);
    io.to(roomId).emit('video-changed', {
      videoUrl: '',
      videoName: 'No Video Loaded',
      headers: null
    });
    io.to(roomId).emit('stream-stopped', {});
  });

  // Change video source
  const handleVideoChange = ({ roomId, videoUrl, videoName, headers }) => {
    const room = rooms.get(roomId);
    if (!room) return;
    if (!isRoomHost(room, socket.id)) {
      console.log(`Blocked non-host ${socket.id} from changing video in room ${roomId}`);
      socket.emit('action-error', 'Только хост может изменять видео.');
      return;
    }

    room.videoUrl = videoUrl;
    room.videoName = videoName || (videoUrl ? 'External Video' : 'No Video Loaded');
    room.headers = headers;
    room.isPlaying = false;
    room.currentTime = 0;
    room.lastUpdated = Date.now();

    console.log(`Room ${roomId} video changed by host to: ${videoName || videoUrl}`);
    io.to(roomId).emit('video-changed', {
      videoUrl: room.videoUrl,
      videoName: room.videoName,
      headers: room.headers
    });
  };

  socket.on('video-change', handleVideoChange);
  socket.on('change-video', handleVideoChange);

  // Play event
  socket.on('play', ({ roomId, time }) => {
    const room = rooms.get(roomId);
    if (!room || !isRoomHost(room, socket.id)) return;

    room.isPlaying = true;
    room.currentTime = time;
    room.lastUpdated = Date.now();

    console.log(`Room ${roomId} playback started at: ${time}s`);
    socket.to(roomId).emit('played', { time });
  });

  // Pause event
  socket.on('pause', ({ roomId, time }) => {
    const room = rooms.get(roomId);
    if (!room || !isRoomHost(room, socket.id)) return;

    room.isPlaying = false;
    room.currentTime = time;
    room.lastUpdated = Date.now();

    console.log(`Room ${roomId} playback paused at: ${time}s`);
    socket.to(roomId).emit('paused', { time });
  });

  // Seek event
  socket.on('seek', ({ roomId, time }) => {
    const room = rooms.get(roomId);
    if (!room || !isRoomHost(room, socket.id)) return;

    room.currentTime = time;
    room.lastUpdated = Date.now();

    console.log(`Room ${roomId} seeked to: ${time}s`);
    socket.to(roomId).emit('seeked', { time });
  });

  // Periodic state sync from the host
  socket.on('sync-state', ({ roomId, isPlaying, currentTime }) => {
    const room = rooms.get(roomId);
    if (!room || !room.users || room.users.length === 0) return;

    // Only accept sync from the host
    if (!isRoomHost(room, socket.id)) return;

    room.isPlaying = isPlaying;
    room.currentTime = currentTime;
    room.lastUpdated = Date.now();

    // Broadcast state to other users silently
    socket.to(roomId).emit('state-synced', {
      isPlaying: room.isPlaying,
      currentTime: room.currentTime
    });
  });

  // Chat message event
  socket.on('chat-msg', ({ roomId, username, text, clientId, replyTo, imageUrl }) => {
    if (!roomId || (!text && !imageUrl)) return;

    const room = rooms.get(roomId);
    if (!room) return;
    const member = room.users.find(u => u.id === socket.id);
    if (!member || (text != null && (typeof text !== 'string' || text.length > 4000)) ||
        (imageUrl != null && (typeof imageUrl !== 'string' || imageUrl.length > 2048 || !/^https?:\/\//.test(imageUrl)))) return;

    const message = {
      id: Math.random().toString(36).substring(2, 9) + Date.now().toString(36),
      username: member.username,
      text: text || '',
      imageUrl: imageUrl || null,
      replyTo: (replyTo && typeof replyTo === 'object') ? {
        id: replyTo.id || '',
        sender: replyTo.sender || replyTo.username || '',
        text: replyTo.text || ''
      } : null,
      reactions: {},
      timestamp: new Date().toLocaleTimeString(),
      clientId: member.clientId || ''
    };

    if (!room.messages) room.messages = [];
    room.messages.push(message);
    if (room.messages.length > 100) room.messages.shift(); // keep last 100 messages

    io.to(roomId).emit('chat-msg', message);
  });

  // Chat reaction event
  socket.on('chat-reaction', ({ roomId, messageId, emoji, username, clientId }) => {
    if (!roomId || !messageId || !emoji || !username) return;

    const room = rooms.get(roomId);
    if (!room || !room.messages) return;

    const member = room.users.find(u => u.id === socket.id);
    if (!member || !['❤️','👍','👎','🔥','😂','😮','😢','👏','🎉'].includes(emoji)) return;
    username = member.username;
    const msg = room.messages.find(m => m.id === messageId);
    if (!msg) return;

    if (!msg.reactions) msg.reactions = {};
    if (!Array.isArray(msg.reactions[emoji])) msg.reactions[emoji] = [];

    const userIdx = msg.reactions[emoji].indexOf(username);
    if (userIdx > -1) {
      msg.reactions[emoji].splice(userIdx, 1);
      if (msg.reactions[emoji].length === 0) {
        delete msg.reactions[emoji];
      }
    } else {
      msg.reactions[emoji].push(username);
    }

    io.to(roomId).emit('chat-reaction-updated', {
      messageId,
      reactions: msg.reactions
    });
  });

  // Add video to queue
  socket.on('add-to-queue', ({ roomId, videoUrl, videoName, headers }) => {
    const room = rooms.get(roomId);
    if (!room) return;
    if (!isRoomHost(room, socket.id)) {
      socket.emit('action-error', 'Только хост может добавлять видео в очередь.');
      return;
    }

    if (!room.queue) room.queue = [];
    if (room.queue.length >= 100) return;
    room.queue.push({ videoUrl, videoName, headers });

    console.log(`Added to room ${roomId} queue: ${videoName || videoUrl}`);
    io.to(roomId).emit('queue-updated', { queue: room.queue });
  });

  // Remove video from queue
  socket.on('remove-from-queue', ({ roomId, index }) => {
    const room = rooms.get(roomId);
    if (!room || !room.queue || !isRoomHost(room, socket.id)) return;

    if (index >= 0 && index < room.queue.length) {
      const removed = room.queue.splice(index, 1);
      console.log(`Removed from room ${roomId} queue: ${removed[0].videoName}`);
      io.to(roomId).emit('queue-updated', { queue: room.queue });
    }
  });

  // Skip to next video in queue
  socket.on('skip-video', ({ roomId }) => {
    const room = rooms.get(roomId);
    if (!room || !room.queue || !isRoomHost(room, socket.id)) return;

    if (room.queue.length > 0) {
      const nextVideo = room.queue.shift();
      room.videoUrl = nextVideo.videoUrl;
      room.videoName = nextVideo.videoName;
      room.headers = nextVideo.headers;
      room.isPlaying = true;
      room.currentTime = 0;
      room.lastUpdated = Date.now();

      console.log(`Skipped to next video in room ${roomId}: ${room.videoName}`);
      io.to(roomId).emit('video-changed', {
        videoUrl: room.videoUrl,
        videoName: room.videoName,
        headers: room.headers
      });
    } else {
      room.videoUrl = '';
      room.videoName = 'No Video Loaded';
      room.headers = null;
      room.isPlaying = false;
      room.currentTime = 0;
      room.lastUpdated = Date.now();

      console.log(`Queue is empty, clearing player in room ${roomId}.`);
      io.to(roomId).emit('video-changed', {
        videoUrl: '',
        videoName: 'No Video Loaded',
        headers: null
      });
    }
    io.to(roomId).emit('queue-updated', { queue: room.queue });
  });

  // Live Stream Relay Events
  socket.on('live-stream-chunk', (data) => {
    if (!data) return;
    const roomId = data.roomId;
    const rawChunk = data.chunk || data;
    if (!roomId || !rawChunk || !isRoomHost(rooms.get(roomId), socket.id)) return;
    if (!Buffer.isBuffer(rawChunk) && !(rawChunk instanceof Uint8Array)) return;

    let stream = activeLiveStreams.get(roomId);
    if (!stream) {
      stream = { viewers: new Set(), header0: null, header1: null, recentChunks: [] };
      activeLiveStreams.set(roomId, stream);
    }
    const chunkBuffer = Buffer.isBuffer(rawChunk) ? rawChunk : Buffer.from(rawChunk);

    if (!stream.header0) {
      stream.header0 = chunkBuffer;
    } else if (!stream.header1) {
      stream.header1 = chunkBuffer;
    } else {
      if (!stream.recentChunks) stream.recentChunks = [];
      stream.recentChunks.push(chunkBuffer);
      stream.bufferedBytes = (stream.bufferedBytes || 0) + chunkBuffer.length;
      while (stream.recentChunks.length > 100 || stream.bufferedBytes > 8 * 1024 * 1024) {
        stream.bufferedBytes -= stream.recentChunks.shift().length;
      }
    }

    // Do not emit live-stream-chunk over socket to prevent saturating client mobile connections
    // socket.to(roomId).emit('live-stream-chunk', chunkBuffer);

    for (const res of stream.viewers) {
      try {
        if (!res.write(chunkBuffer)) { res.destroy(); stream.viewers.delete(res); }
      } catch (e) {
        stream.viewers.delete(res);
      }
    }
  });

  socket.on('live-audio-chunk', (data) => {
    if (!data || !data.roomId || !data.chunk) return;
    const roomId = data.roomId;
    const rawChunk = data.chunk;
    if (!isRoomHost(rooms.get(roomId), socket.id) || (!Buffer.isBuffer(rawChunk) && !(rawChunk instanceof Uint8Array))) return;
    const chunkBuffer = Buffer.isBuffer(rawChunk) ? rawChunk : Buffer.from(rawChunk);
    socket.to(roomId).emit('live-audio-chunk', chunkBuffer);
  });

  socket.on('start-stream', ({ roomId }) => {
    const room = rooms.get(roomId);
    if (!room) return;
    if (!isRoomHost(room, socket.id)) {
      socket.emit('action-error', { message: 'Только хост комнаты может запускать стрим' });
      return;
    }
    room.isLiveStreaming = true;

    let stream = activeLiveStreams.get(roomId);
    if (!stream) {
      stream = { viewers: new Set(), chunks: [] };
      activeLiveStreams.set(roomId, stream);
    } else {
      stream.chunks = [];
    }

    console.log(`Room ${roomId} started live streaming`);
    io.to(roomId).emit('stream-started', { hostId: socket.id });
  });

  socket.on('stop-stream', ({ roomId }) => {
    const room = rooms.get(roomId);
    if (!room) return;
    if (!isRoomHost(room, socket.id)) {
      socket.emit('action-error', { message: 'Только хост комнаты может останавливать стрим' });
      return;
    }
    room.isLiveStreaming = false;

    const stream = activeLiveStreams.get(roomId);
    if (stream) {
      for (const res of stream.viewers) {
        try { res.end(); } catch (_) {}
      }
      activeLiveStreams.delete(roomId);
    }

    console.log(`Room ${roomId} stopped live streaming`);
    io.to(roomId).emit('stream-stopped');
  });

  socket.on('new-viewer', ({ roomId, viewerId }) => {
    if (roomId) {
      socket.to(roomId).emit('new-viewer', { viewerId: socket.id, roomId });
    }
  });

  socket.on('webrtc-offer', ({ targetId, offer, roomId }) => {
    socket.to(targetId).emit('webrtc-offer', {
      senderId: socket.id,
      targetId,
      offer,
      roomId
    });
  });

  socket.on('webrtc-answer', ({ targetId, answer, roomId }) => {
    socket.to(targetId).emit('webrtc-answer', {
      senderId: socket.id,
      targetId,
      answer,
      roomId
    });
  });

  socket.on('webrtc-ice-candidate', ({ targetId, candidate, roomId }) => {
    socket.to(targetId).emit('webrtc-ice-candidate', {
      senderId: socket.id,
      targetId,
      candidate,
      roomId
    });
  });

  // Kick user event (only allowed by room host)
  socket.on('kick-user', ({ roomId, targetSocketId }) => {
    const room = rooms.get(roomId);
    if (!room) return;
    if (!isRoomHost(room, socket.id)) {
      console.warn(`Non-host user ${socket.id} attempted to kick user ${targetSocketId}`);
      socket.emit('action-error', { message: 'Только хост комнаты может исключать пользователей' });
      return;
    }

    const targetSocket = io.sockets.sockets.get(targetSocketId);
    if (targetSocket) {
      const targetUser = room.users.find(u => u.id === targetSocketId);
      const kickedName = targetUser ? targetUser.username : 'User';
      console.log(`Kicking user ${targetSocketId} from room ${roomId}`);
      targetSocket.emit('kicked');
      targetSocket.leave(roomId);

      // Clean up target user from room users array
      room.users = room.users.filter(u => u.id !== targetSocketId);
      io.to(roomId).emit('room-users', room.users);

      const kickMessage = {
        id: Date.now().toString() + Math.random().toString(),
        username: 'System',
        text: `${kickedName} was kicked from the room`,
        timestamp: Date.now(),
        clientId: 'system'
      };
      room.messages.push(kickMessage);
      if (room.messages.length > 100) room.messages.shift();
      io.to(roomId).emit('chat-msg', kickMessage);
    }
  });

  // Ban user event (only allowed by room host)
  socket.on('ban-user', ({ roomId, targetSocketId }) => {
    const room = rooms.get(roomId);
    if (!room) return;
    if (!isRoomHost(room, socket.id)) {
      socket.emit('action-error', { message: 'Только хост комнаты может банить пользователей' });
      return;
    }

    const targetSocket = io.sockets.sockets.get(targetSocketId);
    if (targetSocket) {
      const targetUser = room.users.find(u => u.id === targetSocketId);
      const bannedName = targetUser ? targetUser.username : 'User';
      if (targetUser) {
        room.bannedUsernames.add(targetUser.username);

        const clientIP = targetSocket.handshake.address;
        const isLoopback = clientIP === '::1' || clientIP === '127.0.0.1' || clientIP.includes('localhost');
        if (!isLoopback) {
          room.bannedIPs.add(clientIP);
        }
        console.log(`Banning user ${targetUser.username} (IP: ${clientIP}) from room ${roomId}`);
      }

      targetSocket.emit('kicked-and-banned');
      targetSocket.leave(roomId);

      // Clean up target user from room users array
      room.users = room.users.filter(u => u.id !== targetSocketId);
      io.to(roomId).emit('room-users', room.users);

      const banMessage = {
        id: Date.now().toString() + Math.random().toString(),
        username: 'System',
        text: `${bannedName} was banned from the room`,
        timestamp: Date.now(),
        clientId: 'system'
      };
      room.messages.push(banMessage);
      if (room.messages.length > 100) room.messages.shift();
      io.to(roomId).emit('chat-msg', banMessage);
    }
  });

  // Disconnect handler
  socket.on('disconnect', () => {
    console.log(`User disconnected: ${socket.id}`);

    // Find rooms this user was in and clean up
    for (const [roomId, room] of rooms.entries()) {
      const userIndex = room.users.findIndex(u => u.id === socket.id);
      if (userIndex !== -1) {
        const leavingUser = room.users[userIndex];
        const wasHost = leavingUser.isHost || Boolean(room.hostUsername && leavingUser.username.toLowerCase() === room.hostUsername.toLowerCase());
        const username = leavingUser.username;
        const isBroadcaster = Boolean(leavingUser.isBroadcaster || username.includes('(Broadcaster)'));
        room.users.splice(userIndex, 1);
        console.log(`User ${username} left room: ${roomId}`);

        if (!isBroadcaster) {
          const leaveMessage = {
            id: Date.now().toString() + Math.random().toString(),
            username: 'System',
            text: `${username} left the room`,
            timestamp: Date.now(),
            clientId: 'system'
          };
          room.messages.push(leaveMessage);
          if (room.messages.length > 100) room.messages.shift();
          io.to(roomId).emit('chat-msg', leaveMessage);
        }

        if (room.users.length === 0) {
          console.log(`Room ${roomId} is now empty. Starting 120s grace period before cleanup...`);
          if (room.emptyTimer) clearTimeout(room.emptyTimer);
          room.emptyTimer = setTimeout(() => {
            if (room.users && room.users.length === 0) {
              if (room.uploadedFiles && room.uploadedFiles.length > 0) {
                for (const fileRelPath of room.uploadedFiles) {
                  try {
                    const absPath = path.join(__dirname, fileRelPath);
                    if (fs.existsSync(absPath)) {
                      fs.unlinkSync(absPath);
                      console.log(`Deleted uploaded file ${fileRelPath} because room ${roomId} expired.`);
                    }
                  } catch (err) {
                    console.error(`Error deleting file ${fileRelPath}: ${err.message}`);
                  }
                }
              }
              delete persistentRoomHosts[roomId];
              saveRoomHosts();
              rooms.delete(roomId);
              console.log(`Room ${roomId} deleted after 120s grace period.`);
            }
          }, 120000);
        } else {
          // DO NOT transfer host to a guest on disconnect!
          // Host identity is reserved by hostToken & clientId for the entire room lifetime.
          // When the host reconnects, they immediately resume their host role.
          if (wasHost) {
            console.log(`Host ${username} disconnected from room ${roomId}. Host rights preserved for room lifetime.`);
          }

          // If the leaving user was host and was streaming a browser tab, stop it
          if (wasHost && room.isLiveStreaming) {
            room.isLiveStreaming = false;
            const stream = activeLiveStreams.get(roomId);
            if (stream) {
              for (const res of stream.viewers) {
                try { res.end(); } catch (_) {}
              }
              activeLiveStreams.delete(roomId);
            }
            io.to(roomId).emit('stream-stopped');
          }

          // Notify remaining users of updated user list
          io.to(roomId).emit('room-users', room.users);
        }
      }
    }
  });
});

// Retrieve local IP addresses for clients to connect
function getLocalIPs() {
  const interfaces = os.networkInterfaces();
  const addresses = [];
  for (const name of Object.keys(interfaces)) {
    for (const iface of interfaces[name]) {
      if (iface.family === 'IPv4' && !iface.internal) {
        addresses.push(iface.address);
      }
    }
  }
  return addresses;
}

const PORT = process.env.PORT || 3000;
server.listen(PORT, '0.0.0.0', async () => {
  console.log(`=================================================`);
  console.log(` RaveStreamer Server is running!`);
  console.log(` Port: ${PORT}`);
  console.log(` Localhost: http://localhost:${PORT}`);
  console.log(` Network IPs (use these on Android/other devices):`);
  const ips = getLocalIPs();
  ips.forEach(ip => {
    console.log(`   http://${ip}:${PORT}`);
  });
  console.log(`=================================================`);

  // Auto-start localtunnel and update GitHub Gist
  const GITHUB_TOKEN = process.env.GITHUB_TOKEN;
  if (!GITHUB_TOKEN) return; // Tunnels / Gist updates are opt-in.
  const GIST_ID = '0811a2ec6e74b06965de32f61643da5b';

  try {
    const fetch = require('node-fetch');
    const publicUrl = process.env.PUBLIC_URL || (process.env.RENDER === 'true' ? 'https://ravestreamerserver.onrender.com' : null);

    if (publicUrl) {
      console.log(` Running with public URL: ${publicUrl}. Skipping localtunnel, updating Gist...`);

      let latestVersion = '1.0.0';
      let androidUrl = 'https://github.com/stepa1235/RaveStreamerClient/releases/download/v1.0.0/Luna.apk';
      let windowsUrl = 'https://github.com/stepa1235/RaveStreamerClient/releases/download/v1.0.0/Luna-Windows.zip';

      try {
        const curResp = await fetch(`https://api.github.com/gists/${GIST_ID}`);
        if (curResp.ok) {
          const curData = await curResp.json();
          const fileContent = JSON.parse(curData.files['ravestreamer.json'].content);
          if (fileContent.latest_version) latestVersion = fileContent.latest_version;
          if (fileContent.android_url) androidUrl = fileContent.android_url;
          if (fileContent.windows_url) windowsUrl = fileContent.windows_url;
        }
      } catch (_) {}

      const gistResp = await fetch(`https://api.github.com/gists/${GIST_ID}`, {
        method: 'PATCH',
        headers: {
          'Authorization': `token ${GITHUB_TOKEN}`,
          'Content-Type': 'application/json',
        },
        body: JSON.stringify({
          files: {
            'ravestreamer.json': {
              content: JSON.stringify({
                url: publicUrl,
                latest_version: latestVersion,
                android_url: androidUrl,
                windows_url: windowsUrl
              }, null, 2)
            }
          }
        })
      });

      if (gistResp.ok) {
        console.log(` Gist updated with Render URL and preserved version info!`);
      } else {
        console.error(` Failed to update Gist on Render: ${gistResp.status}`);
      }
      return;
    }

    const localtunnel = require('localtunnel');
    let currentTunnel = null;

    async function setupTunnel() {
      try {
        console.log(' Starting localtunnel...');
        if (currentTunnel) {
          try { currentTunnel.close(); } catch (_) {}
        }
        currentTunnel = await localtunnel({ port: PORT, subdomain: 'ravestreamer-stepa-server' });
        console.log(` Tunnel URL: ${currentTunnel.url}`);

        let ltLatestVersion = '1.0.0';
        let ltAndroidUrl = 'https://github.com/stepa1235/RaveStreamerClient/releases/download/v1.0.0/Luna.apk';
        let ltWindowsUrl = 'https://github.com/stepa1235/RaveStreamerClient/releases/download/v1.0.0/Luna-Windows.zip';
        try {
          const ghResp = await fetch('https://api.github.com/repos/stepa1235/RaveStreamerClient/releases/latest', { headers: { 'User-Agent': 'LunaServer/1.0' } });
          if (ghResp.ok) {
             const ghData = await ghResp.json();
             if (ghData.tag_name) {
               ltLatestVersion = ghData.tag_name.replace('v', '');
               ltAndroidUrl = `https://github.com/stepa1235/RaveStreamerClient/releases/download/${ghData.tag_name}/RaveStreamer.apk`;
               ltWindowsUrl = `https://github.com/stepa1235/RaveStreamerClient/releases/download/${ghData.tag_name}/RaveStreamer-Windows.zip`;
             }
          }
        } catch (e) {}

        const gistResp = await fetch(`https://api.github.com/gists/${GIST_ID}`, {
          method: 'PATCH',
          headers: {
            'Authorization': `token ${GITHUB_TOKEN}`,
            'Content-Type': 'application/json',
          },
          body: JSON.stringify({
            files: {
              'ravestreamer.json': {
                content: JSON.stringify({
                  url: currentTunnel.url,
                  latest_version: ltLatestVersion,
                  android_url: ltAndroidUrl,
                  windows_url: ltWindowsUrl
                }, null, 2)
              }
            }
          })
        });

        if (gistResp.ok) {
          console.log(` Gist updated: https://gist.github.com/stepa1235/${GIST_ID}`);
        } else {
          console.error(` Failed to update Gist: ${gistResp.status}`);
        }

        currentTunnel.on('close', () => {
          console.log(' Tunnel closed. Reconnecting in 5 seconds...');
          setTimeout(setupTunnel, 5000);
        });

        currentTunnel.on('error', (err) => {
          console.error(` Tunnel error: ${err.message}. Reconnecting in 5 seconds...`);
          setTimeout(setupTunnel, 5000);
        });

      } catch (e) {
        console.error(` Failed to start tunnel: ${e.message}. Retrying in 10 seconds...`);
        setTimeout(setupTunnel, 10000);
      }
    }

    setupTunnel();

    setInterval(() => {
      if (currentTunnel && currentTunnel.url) {
        fetch(`${currentTunnel.url}/health`, { headers: { 'bypass-tunnel-reminder': 'true' } }).catch(() => {});
      }
    }, 30000);
  } catch (e) {
    console.error(` Setup error: ${e.message}`);
  }
});
