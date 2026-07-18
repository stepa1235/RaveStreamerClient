

async function testProxy() {
  const serverUrl = 'https://ravestreamerserver.onrender.com';
  // I need a valid lordfilm m3u8 url to test.
  // The user's screenshot showed: https://ab.interkh.com/x-en-x/khw1kBAcYa8cFy8xFy8aRp8cFn8xFn8aRC9zMXw1y0Znmn9bBEQ3bwStnC5IghAUMmXGKIyayY0GKBO/SrkVPvL9Siz2zGSZRHXvSvz1FhSZOXZZjBSvRGb4kvRckvE2zGqakCSfzG1vSmzakhb4SrAczBOWRvxH1w9zGE2FBeekrOrSmswkhq50zZ0jBQAFhE4SrE4kGkpk2L0kpSfKB05zvKpRhb3RiXZFmR3R2LrHtYJjmsvz2bGRGD3FhSpFBb3SpS0jBE3FhA4RhQ1RGbrk1XwzGRGFhz=
  // Let's just run extraction ourselves via our local server to get a fresh URL and fresh cookies, then test the proxy!
  
  console.log("Starting extraction on Render to get fresh cookies/URL...");
  try {
    const res = await fetch(`https://ravestreamerserver.onrender.com/extract?url=${encodeURIComponent('https://me.lordfilm5.pro/filmy/11007-mstiteli-2012.html')}`);
    const data = await res.json();
    console.log("Extraction result:", JSON.stringify(data, null, 2));
    
    if (data.success && data.url.includes('/proxy/hls')) {
       const proxyUrl = data.url.startsWith('/') ? `https://ravestreamerserver.onrender.com${data.url}` : data.url;
       console.log("Fetching proxy URL:", proxyUrl);
       const proxyRes = await fetch(proxyUrl);
       console.log("Proxy status:", proxyRes.status);
       const text = await proxyRes.text();
       console.log("Proxy response snippet:", text.substring(0, 500));
       
       // If it's a playlist, find the first variant or segment
       const lines = text.split('\n');
       const nextUrl = lines.find(l => l.trim() && !l.startsWith('#'));
       if (nextUrl) {
         console.log("Fetching next link from playlist:", nextUrl);
         const nextRes = await fetch(nextUrl);
         console.log("Next link status:", nextRes.status);
         const nextText = await nextRes.text();
         console.log("Next link response snippet:", nextText.substring(0, 500));
       }
    }
  } catch(e) {
    console.error("Test failed:", e.message);
  }
}

testProxy();
