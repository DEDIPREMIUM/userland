#!/bin/bash

# ==========================================
#  USERLAND UBUNTU SERVER SETUP (HOST ZERO)
# ==========================================

echo "Updating system..."
if [ "$(id -u)" -ne 0 ]; then
    SUDO="sudo"
else
    SUDO=""
fi

$SUDO apt-get update
$SUDO apt-get install -y python3 curl wget git procps nano

# --- Cloudflared Installation ---
echo "Checking Cloudflared..."
if ! command -v cloudflared &> /dev/null; then
    echo "Installing Cloudflared..."
    ARCH=$(dpkg --print-architecture)
    if [[ "$ARCH" == "arm64" ]]; then
        CF_ARCH="arm64"
    elif [[ "$ARCH" == "amd64" ]]; then
        CF_ARCH="amd64"
    elif [[ "$ARCH" == "armhf" ]]; then
        CF_ARCH="arm"
    else
        CF_ARCH="amd64" # Fallback
    fi

    wget -O cloudflared https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-$CF_ARCH
    chmod +x cloudflared
    $SUDO mv cloudflared /usr/local/bin/cloudflared
fi

# --- Create server.py ---
echo "Creating server.py..."
cat > server.py << 'EOF_PYTHON'
import http.server
import socketserver
import os
import time
import json
import subprocess
import threading

PORT = 8080

def get_cpu_usage():
    try:
        with open("/proc/stat", "r") as f:
            line = f.readline()
            parts = line.split()
            # user+nice+system+idle+iowait+irq+softirq
            total = sum(map(int, parts[1:8]))
            idle = int(parts[4])
            return total, idle
    except:
        return 0, 0

# Initial CPU read
prev_total, prev_idle = get_cpu_usage()
stats_lock = threading.Lock()

class ThreadingTCPServer(socketserver.ThreadingMixIn, socketserver.TCPServer):
    pass

class SpeedTestHandler(http.server.SimpleHTTPRequestHandler):
    def do_GET(self):
        global prev_total, prev_idle

        # API: System Stats
        if self.path == '/api/stats':
            try:
                with stats_lock:
                    # 1. CPU Calculation
                    curr_total, curr_idle = get_cpu_usage()
                    diff_total = curr_total - prev_total
                    diff_idle = curr_idle - prev_idle
                    cpu_percent = 0
                    if diff_total > 0:
                        cpu_percent = round(((diff_total - diff_idle) / diff_total) * 100, 1)
                    prev_total, prev_idle = curr_total, curr_idle

                # 2. RAM Usage
                mem_info = {}
                with open("/proc/meminfo", "r") as f:
                    for line in f:
                        parts = line.split()
                        mem_info[parts[0].strip(':')] = int(parts[1]) # in kB

                total_mem = mem_info.get('MemTotal', 1)
                avail_mem = mem_info.get('MemAvailable', mem_info.get('MemFree', 0))
                used_mem = total_mem - avail_mem
                ram_percent = round((used_mem / total_mem) * 100, 1)

                # 3. Battery (Linux generic fallback)
                battery = 0
                try:
                    # Try common paths
                    paths = [
                        "/sys/class/power_supply/battery/capacity",
                        "/sys/class/power_supply/BAT0/capacity"
                    ]
                    for p in paths:
                        if os.path.exists(p):
                            with open(p, "r") as f:
                                battery = int(f.read().strip())
                            break
                except:
                    battery = 0

                stats = {
                    "cpu": cpu_percent,
                    "ram": ram_percent,
                    "battery": battery
                }

                self.send_response(200)
                self.send_header('Content-type', 'application/json')
                self.end_headers()
                self.wfile.write(json.dumps(stats).encode())
                return
            except Exception as e:
                self.send_error(500, str(e))
                return

        # Handle dummy file generation for download test
        if self.path == '/garbage.dat':
            self.send_response(200)
            self.send_header('Content-type', 'application/octet-stream')
            self.send_header('Content-Length', '10485760') # 10MB
            self.end_headers()
            # Send 10MB of chunks
            chunk = b'0' * 65536 # 64KB
            try:
                for _ in range(160): # 160 * 64KB ~= 10MB
                    self.wfile.write(chunk)
            except BrokenPipeError:
                pass # Client disconnected
            return

        # Default behavior for other files
        return http.server.SimpleHTTPRequestHandler.do_GET(self)

    def do_POST(self):
        if self.path == '/upload':
            # Read the data to simulate upload processing
            try:
                content_length = int(self.headers['Content-Length'])
                _ = self.rfile.read(content_length)

                self.send_response(200)
                self.send_header('Content-type', 'text/plain')
                self.end_headers()
                self.wfile.write(b'Upload Received')
            except:
                self.send_error(400, "Bad Request")
            return

        return http.server.SimpleHTTPRequestHandler.do_POST(self)

Handler = SpeedTestHandler

print(f"Serving HTTP on 0.0.0.0 port {PORT} ...")
print("Features: System Monitor (/api/stats), Speed Test (garbage.dat, /upload)")

# Use ThreadingTCPServer for concurrent requests
with ThreadingTCPServer(("", PORT), Handler) as httpd:
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("\nServer stopped.")
EOF_PYTHON

# --- Create menu.sh ---
echo "Creating menu.sh..."
cat > menu.sh << 'EOF_BASH'
#!/bin/bash

# ==========================================
#  USERLAND SERVER MANAGER - MODERN EDITION
# ==========================================

# --- WARNA & VISUAL ---
R='\033[1;31m' # Red
G='\033[1;32m' # Green
Y='\033[1;33m' # Gold
C='\033[1;36m' # Cyan
W='\033[1;37m' # White
B='\033[1m'    # Bold
RESET='\033[0m'

TOKEN_FILE="token.txt"
LOG_FILE="cloudflare.log"

# --- HELPER UI ---
draw_border() {
    echo -e "${Y}==========================================${RESET}"
}

header() {
    clear
    echo -e "${C}"
    echo "  _   _  ___  ____ _____   _____ _____ ____   ___  "
    echo " | | | |/ _ \/ ___|_   _| |__  /| ____|  _ \ / _ \ "
    echo " | |_| | | | \___ \ | |     / / |  _| | |_) | | | |"
    echo " |  _  | |_| |___) || |    / /_ | |___|  _ <| |_| |"
    echo " |_| |_|\___/|____/ |_|   /____||_____|_| \_\\___/ "
    echo -e "${RESET}"
    echo -e "${C}╔════════════════════════════════════════╗${RESET}"
    echo -e "${C}║         ${Y}${B}  HOST ZERO SERVER  ${C}         ║${RESET}"
    echo -e "${C}║        ${W}UserLAnd Edition${C}                ║${RESET}"
    echo -e "${C}╚════════════════════════════════════════╝${RESET}"
    echo "" # Spacing
}

cek_status() {
    if pgrep -f "python3 server.py" > /dev/null; then
        STAT_SERVER="${G}[ AKTIF ]${RESET}"
    elif pgrep -f "python3 -m http.server" > /dev/null; then
        STAT_SERVER="${G}[ AKTIF (Default) ]${RESET}"
    else
        STAT_SERVER="${R}[ MATI ]${RESET}"
    fi

    if pgrep -f "cloudflared tunnel" > /dev/null; then
        STAT_HOST="${G}[ AKTIF ]${RESET}"
    else
        STAT_HOST="${R}[ NONAKTIF ]${RESET}"
    fi
}

create_template() {
    if [[ -f "index.html" ]]; then
        echo -e "${Y}[!] File index.html sudah ada.${RESET}"
        read -p " Timpa file? (y/n): " CONFIRM
        if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
            echo -e "${R}Batal membuat template.${RESET}"; sleep 2
            return
        fi
    fi
    echo -e "${Y}[*] Membuat Template Modern...${RESET}"

    # HTML
    cat > index.html << 'EOF_HTML'
<!DOCTYPE html>
<html lang="id">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Modern Termux Server</title>
    <link rel="stylesheet" href="style.css">
</head>
<body>
    <div class="container">
        <div class="glass-card">
            <h1>Welcome to <span class="gradient-text">Termux Server</span></h1>
            <p>Website ini berjalan langsung dari HP Android Anda.</p>
            <div class="code-box">
                <code>Status: Online 🟢</code>
            </div>
            <button onclick="showAlert()">Klik Saya</button>
        </div>
    </div>
    <script src="script.js"></script>
</body>
</html>
EOF_HTML

    # CSS
    cat > style.css << 'EOF_CSS'
:root {
    --bg-color: #0f0c29;
    --card-bg: rgba(255, 255, 255, 0.1);
    --primary: #00d2ff;
    --secondary: #3a7bd5;
}

body {
    margin: 0;
    font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif;
    background: linear-gradient(to right, #24243e, #302b63, #0f0c29);
    color: white;
    height: 100vh;
    display: flex;
    justify-content: center;
    align-items: center;
}

.glass-card {
    background: var(--card-bg);
    backdrop-filter: blur(10px);
    border-radius: 16px;
    padding: 2rem;
    border: 1px solid rgba(255,255,255,0.2);
    text-align: center;
    box-shadow: 0 4px 30px rgba(0, 0, 0, 0.5);
    max-width: 400px;
    width: 90%;
}

.gradient-text {
    background: linear-gradient(to right, var(--primary), var(--secondary));
    -webkit-background-clip: text;
    -webkit-text-fill-color: transparent;
    font-weight: bold;
}

button {
    background: linear-gradient(45deg, var(--primary), var(--secondary));
    border: none;
    padding: 10px 20px;
    border-radius: 50px;
    color: white;
    font-weight: bold;
    cursor: pointer;
    margin-top: 20px;
    transition: transform 0.2s;
}

button:hover {
    transform: scale(1.05);
}

.code-box {
    background: rgba(0,0,0,0.5);
    padding: 10px;
    border-radius: 8px;
    margin: 15px 0;
    font-family: monospace;
}
EOF_CSS

    # JS
    cat > script.js << 'EOF_JS'
function showAlert() {
    alert("Halo! Script JS berhasil berjalan dengan lancar!");
    console.log("Termux Server is Running...");
}
EOF_JS

    echo -e "${G}[✓] Template berhasil dibuat!${RESET}"
    sleep 2
}

create_speedtest() {
    echo -e "${Y}[*] Memeriksa paket yang diperlukan...${RESET}"
    if ! command -v python3 &> /dev/null; then
        echo -e "${Y}[*] Menginstall python3...${RESET}"
        sudo apt-get install python3 -y
    fi
    echo -e "${G}[✓] Paket selesai.${RESET}"

    if [[ -f "index.html" ]]; then
        echo -e "${Y}[!] File index.html sudah ada.${RESET}"
        read -p " Timpa file? (y/n): " CONFIRM
        if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
            echo -e "${R}Batal membuat template.${RESET}"; sleep 2
            return
        fi
    fi

    echo -e "${Y}[*] Membuat Template Speed Test Mewah...${RESET}"

    # HTML SPEEDTEST
    cat > index.html << 'EOF_HTML'
<!DOCTYPE html>
<html lang="id">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>SpeedTest Ultimate</title>
    <link rel="stylesheet" href="style.css">
    <link href="https://fonts.googleapis.com/css2?family=Orbitron:wght@400;700&display=swap" rel="stylesheet">
</head>
<body>
    <div class="container">
        <div class="glass-panel">
            <h1 class="glitch" data-text="HOST ZERO">HOST ZERO</h1>
            <p class="subtitle">ULTIMATE SPEED TEST</p>

            <div class="gauge-wrapper">
                <div class="gauge-bg"></div>
                <div class="gauge-fill" id="gaugeFill"></div>
                <div class="gauge-cover">
                    <span id="speedValue">0.0</span>
                    <span class="unit">Mbps</span>
                </div>
            </div>

            <div class="stats-grid">
                <div class="stat-box">
                    <span class="label">PING</span>
                    <span class="value" id="pingValue">--</span>
                    <span class="unit-small">ms</span>
                </div>
                <div class="stat-box">
                    <span class="label">JITTER</span>
                    <span class="value" id="jitterValue">--</span>
                    <span class="unit-small">ms</span>
                </div>
                <div class="stat-box">
                    <span class="label">UPLOAD</span>
                    <span class="value" id="uploadValue">--</span>
                    <span class="unit-small">Mbps</span>
                </div>
            </div>

            <button id="startBtn" onclick="startTest()">START TEST</button>
            <div id="statusText">READY</div>
        </div>
    </div>
    <script src="script.js"></script>
</body>
</html>
EOF_HTML

    # CSS SPEEDTEST
    cat > style.css << 'EOF_CSS'
:root {
    --bg-dark: #050510;
    --neon-cyan: #00f3ff;
    --neon-purple: #bc13fe;
    --glass: rgba(255, 255, 255, 0.05);
}

body {
    background: radial-gradient(circle at center, #1a1a2e, var(--bg-dark));
    color: white;
    font-family: 'Orbitron', sans-serif;
    margin: 0;
    height: 100vh;
    display: flex;
    justify-content: center;
    align-items: center;
    overflow: hidden;
}

.container {
    position: relative;
    z-index: 10;
}

.glass-panel {
    background: var(--glass);
    backdrop-filter: blur(20px);
    border: 1px solid rgba(255,255,255,0.1);
    border-radius: 20px;
    padding: 40px;
    text-align: center;
    box-shadow: 0 0 50px rgba(0,243,255,0.1);
    width: 350px;
}

h1.glitch {
    font-size: 2.5rem;
    margin: 0;
    color: var(--neon-cyan);
    text-shadow: 0 0 10px var(--neon-cyan);
    letter-spacing: 2px;
}

.subtitle {
    color: #888;
    margin-bottom: 30px;
    font-size: 0.8rem;
    letter-spacing: 5px;
}

.gauge-wrapper {
    width: 200px;
    height: 200px;
    margin: 0 auto 30px;
    position: relative;
    border-radius: 50%;
    background: rgba(255,255,255,0.02);
    box-shadow: inset 0 0 20px rgba(0,0,0,0.5);
}

.gauge-cover {
    position: absolute;
    top: 50%;
    left: 50%;
    transform: translate(-50%, -50%);
    text-align: center;
}

#speedValue {
    font-size: 3rem;
    font-weight: bold;
    display: block;
}

.unit {
    color: #888;
    font-size: 1rem;
}

.stats-grid {
    display: grid;
    grid-template-columns: 1fr 1fr 1fr;
    gap: 10px;
    margin-bottom: 30px;
}

.stat-box {
    background: rgba(0,0,0,0.3);
    padding: 10px;
    border-radius: 8px;
    border-bottom: 2px solid var(--neon-purple);
}

.stat-box .label {
    display: block;
    font-size: 0.7rem;
    color: #aaa;
    margin-bottom: 5px;
}

.stat-box .value {
    font-size: 1.2rem;
    color: white;
}

button {
    background: linear-gradient(45deg, var(--neon-cyan), var(--neon-purple));
    border: none;
    padding: 15px 40px;
    color: white;
    font-family: 'Orbitron', sans-serif;
    font-weight: bold;
    font-size: 1.1rem;
    border-radius: 30px;
    cursor: pointer;
    transition: 0.3s;
    text-shadow: 0 2px 4px rgba(0,0,0,0.3);
}

button:hover {
    transform: scale(1.05);
    box-shadow: 0 0 30px rgba(188, 19, 254, 0.5);
}

#statusText {
    margin-top: 20px;
    color: var(--neon-cyan);
    font-size: 0.9rem;
    animation: blink 2s infinite;
}

@keyframes blink { 50% { opacity: 0.5; } }
EOF_CSS

    # JS SPEEDTEST
    cat > script.js << 'EOF_JS'
async function startTest() {
    const btn = document.getElementById('startBtn');
    const status = document.getElementById('statusText');
    const speedVal = document.getElementById('speedValue');

    btn.disabled = true;
    btn.style.opacity = "0.5";

    // 1. PING TEST
    status.innerText = "MEASURING PING...";
    const pings = [];
    for(let i=0; i<5; i++) {
        const start = performance.now();
        await fetch(window.location.href + '?ping=' + i);
        const end = performance.now();
        pings.push(end - start);
    }
    const minPing = Math.min(...pings);
    const maxPing = Math.max(...pings);
    const avgPing = pings.reduce((a,b)=>a+b)/pings.length;

    document.getElementById('pingValue').innerText = minPing.toFixed(0);
    document.getElementById('jitterValue').innerText = (avgPing - minPing).toFixed(0);

    // 2. DOWNLOAD TEST
    status.innerText = "TESTING DOWNLOAD...";
    const dlStart = performance.now();
    try {
        // Download 10MB dummy file
        const response = await fetch('/garbage.dat');
        const reader = response.body.getReader();
        let receivedLength = 0;

        while(true) {
            const {done, value} = await reader.read();
            if (done) break;
            receivedLength += value.length;

            // Calculate instantaneous speed
            const now = performance.now();
            const duration = (now - dlStart) / 1000;
            const mbps = (receivedLength * 8 / 1000000) / duration;
            speedVal.innerText = mbps.toFixed(1);
        }

        const dlEnd = performance.now();
        const totalDuration = (dlEnd - dlStart) / 1000;
        const finalSpeed = (10 * 8) / totalDuration; // 10MB * 8 bits

    } catch(e) {
        console.log("Using fallback download test (small file loop)");
        // Fallback logic if server doesn't support garbage.dat
    }

    // 3. UPLOAD TEST
    status.innerText = "TESTING UPLOAD...";
    const ulStart = performance.now();
    const data = new Uint8Array(2 * 1024 * 1024); // 2MB Upload
    try {
        await fetch('/upload', {
            method: 'POST',
            body: data
        });
        const ulEnd = performance.now();
        const ulDuration = (ulEnd - ulStart) / 1000;
        const ulMbps = (2 * 8) / ulDuration;
        document.getElementById('uploadValue').innerText = ulMbps.toFixed(1);
    } catch(e) {
        document.getElementById('uploadValue').innerText = "Err";
    }

    status.innerText = "TEST COMPLETED";
    btn.disabled = false;
    btn.style.opacity = "1";
    btn.innerText = "RESTART";
}
EOF_JS

    echo -e "${G}[✓] Template Speed Test Berhasil!${RESET}"
    sleep 2
}

create_monitor() {
    echo -e "${Y}[*] Menggunakan System Monitor (Linux Mode)...${RESET}"
    # Removed termux-api dependency

    if [[ -f "index.html" ]]; then
        echo -e "${Y}[!] File index.html sudah ada.${RESET}"
        read -p " Timpa file? (y/n): " CONFIRM
        if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
            echo -e "${R}Batal membuat template.${RESET}"; sleep 2
            return
        fi
    fi

    echo -e "${Y}[*] Membuat Dashboard Monitor Cyberpunk...${RESET}"

    # HTML MONITOR
    cat > index.html << 'EOF_HTML'
<!DOCTYPE html>
<html lang="id">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>HOST ZERO MONITOR</title>
    <link rel="stylesheet" href="style.css">
    <script src="https://cdn.jsdelivr.net/npm/chart.js"></script>
    <link href="https://fonts.googleapis.com/css2?family=Rajdhani:wght@500;700&display=swap" rel="stylesheet">
</head>
<body>
    <div class="container">
        <header>
            <h1 class="glitch">HOST ZERO // SYSTEM</h1>
            <div class="status-line">STATUS: <span class="online">ONLINE</span></div>
        </header>

        <div class="grid">
            <!-- CPU CARD -->
            <div class="card">
                <h2>CPU LOAD</h2>
                <div class="chart-container">
                    <canvas id="cpuChart"></canvas>
                </div>
                <div class="big-value"><span id="cpuVal">0</span>%</div>
            </div>

            <!-- RAM CARD -->
            <div class="card">
                <h2>MEMORY USAGE</h2>
                <div class="progress-bar">
                    <div class="fill" id="ramFill"></div>
                </div>
                <div class="big-value"><span id="ramVal">0</span>%</div>
            </div>

            <!-- BATTERY CARD -->
            <div class="card">
                <h2>POWER CELL</h2>
                <div class="battery-icon">
                    <div class="battery-level" id="battFill"></div>
                </div>
                <div class="big-value"><span id="battVal">0</span>%</div>
            </div>
        </div>

        <footer>UserLAnd Server Manager v3</footer>
    </div>
    <script src="script.js"></script>
</body>
</html>
EOF_HTML

    # CSS MONITOR
    cat > style.css << 'EOF_CSS'
:root {
    --bg: #0a0a12;
    --card: #141420;
    --accent: #ff0055;
    --cyan: #00f3ff;
    --text: #e0e0e0;
}

body {
    background-color: var(--bg);
    color: var(--text);
    font-family: 'Rajdhani', sans-serif;
    margin: 0;
    padding: 20px;
    height: 100vh;
    box-sizing: border-box;
}

.container {
    max-width: 800px;
    margin: 0 auto;
}

header {
    text-align: center;
    margin-bottom: 30px;
    border-bottom: 2px solid var(--accent);
    padding-bottom: 10px;
}

h1.glitch {
    color: var(--cyan);
    font-size: 2.5rem;
    margin: 0;
    letter-spacing: 5px;
    text-shadow: 2px 2px var(--accent);
}

.status-line {
    font-size: 1.2rem;
    margin-top: 5px;
}

.online {
    color: #00ff00;
    font-weight: bold;
    animation: blink 1s infinite;
}

.grid {
    display: grid;
    grid-template-columns: repeat(auto-fit, minmax(200px, 1fr));
    gap: 20px;
}

.card {
    background: var(--card);
    border: 1px solid rgba(255,255,255,0.1);
    border-radius: 10px;
    padding: 20px;
    text-align: center;
    box-shadow: 0 4px 15px rgba(0,0,0,0.5);
}

.card h2 {
    color: var(--accent);
    margin-top: 0;
    font-size: 1.5rem;
}

.big-value {
    font-size: 3rem;
    font-weight: bold;
    margin-top: 10px;
}

/* RAM BAR */
.progress-bar {
    background: #333;
    height: 20px;
    border-radius: 10px;
    overflow: hidden;
    margin: 20px 0;
}
.fill {
    height: 100%;
    background: var(--cyan);
    width: 0%;
    transition: width 0.5s;
}

/* BATTERY */
.battery-icon {
    width: 60px;
    height: 100px;
    border: 4px solid white;
    border-radius: 10px;
    margin: 10px auto;
    position: relative;
    padding: 3px;
}
.battery-icon::before {
    content: '';
    position: absolute;
    top: -10px;
    left: 15px;
    width: 30px;
    height: 6px;
    background: white;
}
.battery-level {
    background: #00ff00;
    width: 100%;
    height: 0%;
    position: absolute;
    bottom: 3px;
    transition: height 0.5s;
}

@keyframes blink { 50% { opacity: 0.5; } }
EOF_CSS

    # JS MONITOR
    cat > script.js << 'EOF_JS'
const ctx = document.getElementById('cpuChart').getContext('2d');
const cpuChart = new Chart(ctx, {
    type: 'line',
    data: {
        labels: Array(20).fill(''),
        datasets: [{
            label: 'CPU Usage',
            data: Array(20).fill(0),
            borderColor: '#ff0055',
            borderWidth: 2,
            tension: 0.4,
            pointRadius: 0
        }]
    },
    options: {
        responsive: true,
        scales: {
            y: { min: 0, max: 100, grid: { color: '#333' } },
            x: { display: false }
        },
        plugins: { legend: { display: false } }
    }
});

async function updateStats() {
    try {
        const response = await fetch('/api/stats');
        const data = await response.json();

        // Update CPU Chart
        cpuChart.data.datasets[0].data.shift();
        cpuChart.data.datasets[0].data.push(data.cpu);
        cpuChart.update();
        document.getElementById('cpuVal').innerText = data.cpu;

        // Update RAM
        document.getElementById('ramFill').style.width = data.ram + '%';
        document.getElementById('ramVal').innerText = data.ram;

        // Update Battery
        document.getElementById('battFill').style.height = data.battery + '%';
        document.getElementById('battVal').innerText = data.battery;

        // Color logic for battery
        const battEl = document.getElementById('battFill');
        if(data.battery < 20) battEl.style.background = '#ff0000';
        else if(data.battery < 50) battEl.style.background = '#ffaa00';
        else battEl.style.background = '#00ff00';

    } catch (e) {
        console.error("Connection lost");
    }
}

setInterval(updateStats, 1000);
EOF_JS

    echo -e "${G}[✓] Template Monitor Berhasil!${RESET}"
    sleep 2
}

create_anime_template() {
    if [[ -f "index.html" ]]; then
        echo -e "${Y}[!] File index.html sudah ada.${RESET}"
        read -p " Timpa file? (y/n): " CONFIRM
        if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
            echo -e "${R}Batal membuat template.${RESET}"; sleep 2
            return
        fi
    fi

    echo -e "${Y}[*] Membuat Template Animasi Indonesia (Modern)...${RESET}"

    # HTML ANIME
    cat > index.html << 'EOF_HTML'
<!DOCTYPE html>
<html lang="id">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>ANIMASI INDONESIA - Nonton Kartun</title>
    <link rel="stylesheet" href="style.css">
    <link href="https://fonts.googleapis.com/css2?family=Poppins:wght@400;600;800&display=swap" rel="stylesheet">
    <link rel="stylesheet" href="https://cdnjs.cloudflare.com/ajax/libs/font-awesome/6.0.0/css/all.min.css">
</head>
<body>
    <nav class="glass-nav">
        <div class="logo">ANI<span class="highlight">INDONESIA</span></div>
        <div class="menu-icon"><i class="fas fa-bars"></i></div>
    </nav>

    <!-- HERO SECTION -->
    <header class="hero" id="hero-section">
        <div class="hero-content">
            <span class="tag">TOP RATED</span>
            <h1 id="hero-title">NARUTO SHIPPUDEN</h1>
            <p>Petualangan ninja muda Naruto Uzumaki yang bercita-cita menjadi Hokage.</p>
            <button class="watch-btn" onclick="openPlayer('naruto')"><i class="fas fa-play"></i> NONTON SEKARANG</button>
        </div>
        <div class="hero-overlay"></div>
    </header>

    <!-- GRID SECTION -->
    <main class="container">
        <h2 class="section-title">Populer Saat Ini 🔥</h2>
        <div class="anime-grid" id="animeGrid">
            <!-- Items injected by JS -->
        </div>
    </main>

    <!-- VIDEO MODAL -->
    <div id="videoModal" class="modal">
        <div class="modal-content">
            <span class="close-btn" onclick="closePlayer()">&times;</span>
            <div class="video-wrapper">
                <iframe id="videoFrame" src="" frameborder="0" allowfullscreen></iframe>
            </div>
            <h3 id="nowPlaying">Judul Animasi</h3>
        </div>
    </div>

    <script src="script.js"></script>
</body>
</html>
EOF_HTML

    # CSS ANIME
    cat > style.css << 'EOF_CSS'
:root {
    --bg-dark: #090912;
    --card-bg: #151520;
    --accent: #ff4d00; /* Orange Naruto Style */
    --text-main: #ffffff;
    --text-sec: #aaaaaa;
}

* { box-sizing: border-box; margin: 0; padding: 0; }

body {
    background-color: var(--bg-dark);
    color: var(--text-main);
    font-family: 'Poppins', sans-serif;
    overflow-x: hidden;
}

/* NAV */
.glass-nav {
    position: fixed;
    top: 0;
    width: 100%;
    padding: 20px 5%;
    display: flex;
    justify-content: space-between;
    align-items: center;
    background: linear-gradient(to bottom, rgba(0,0,0,0.8), transparent);
    z-index: 100;
}

.logo { font-weight: 800; font-size: 1.5rem; letter-spacing: 1px; }
.highlight { color: var(--accent); }

/* HERO */
.hero {
    height: 70vh;
    background: url('https://images4.alphacoders.com/606/606275.jpg') center/cover no-repeat;
    position: relative;
    display: flex;
    align-items: center;
    padding: 0 5%;
}

.hero-overlay {
    position: absolute;
    top: 0; left: 0; width: 100%; height: 100%;
    background: linear-gradient(to right, #090912 10%, transparent 70%),
                linear-gradient(to top, #090912 0%, transparent 50%);
}

.hero-content {
    position: relative;
    z-index: 2;
    max-width: 500px;
}

.tag {
    background: var(--accent);
    padding: 5px 10px;
    font-size: 0.8rem;
    border-radius: 4px;
    font-weight: bold;
}

.hero h1 {
    font-size: 3rem;
    margin: 15px 0;
    line-height: 1.1;
    text-transform: uppercase;
}

.hero p { color: var(--text-sec); margin-bottom: 25px; }

.watch-btn {
    background: var(--accent);
    color: white;
    border: none;
    padding: 12px 30px;
    font-size: 1rem;
    font-weight: bold;
    border-radius: 50px;
    cursor: pointer;
    transition: 0.3s;
    display: flex;
    align-items: center;
    gap: 10px;
}

.watch-btn:hover {
    transform: scale(1.05);
    box-shadow: 0 0 20px rgba(255, 77, 0, 0.5);
}

/* GRID */
.container { padding: 40px 5%; }
.section-title { margin-bottom: 20px; font-size: 1.5rem; border-left: 5px solid var(--accent); padding-left: 15px; }

.anime-grid {
    display: grid;
    grid-template-columns: repeat(auto-fill, minmax(140px, 1fr));
    gap: 20px;
}

.anime-card {
    background: var(--card-bg);
    border-radius: 10px;
    overflow: hidden;
    transition: 0.3s;
    cursor: pointer;
    position: relative;
}

.anime-card:hover { transform: translateY(-5px); }

.card-img {
    width: 100%;
    height: 200px;
    object-fit: cover;
}

.card-info { padding: 10px; }
.card-title { font-size: 0.9rem; font-weight: 600; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
.card-ep { font-size: 0.7rem; color: var(--text-sec); }

/* MODAL */
.modal {
    display: none;
    position: fixed;
    top: 0; left: 0; width: 100%; height: 100%;
    background: rgba(0,0,0,0.9);
    z-index: 200;
    justify-content: center;
    align-items: center;
    backdrop-filter: blur(5px);
}

.modal-content {
    width: 90%;
    max-width: 800px;
    background: #1a1a1a;
    border-radius: 15px;
    overflow: hidden;
    position: relative;
}

.close-btn {
    position: absolute;
    top: 10px; right: 15px;
    color: white;
    font-size: 30px;
    cursor: pointer;
    z-index: 10;
}

.video-wrapper {
    position: relative;
    padding-bottom: 56.25%; /* 16:9 */
    height: 0;
}

.video-wrapper iframe {
    position: absolute;
    top: 0; left: 0;
    width: 100%; height: 100%;
}

h3#nowPlaying { padding: 15px; font-size: 1.1rem; }
EOF_CSS

    # JS ANIME
    cat > script.js << 'EOF_JS'
const animeList = [
    {
        id: 'naruto',
        title: 'Naruto Shippuden',
        ep: 'Episode 500',
        img: 'https://m.media-amazon.com/images/M/MV5BZGFiMWFhNDAtMzUyZS00NmQ2LTljNDYtNTA0ZTI3ZjI1NmY1XkEyXkFqcGdeQXVyNzYzMzkyNTM@._V1_.jpg',
        video: 'https://www.youtube.com/embed/QczGoCmX-pI?autoplay=1' // Trailer Dummy
    },
    {
        id: 'onepiece',
        title: 'One Piece',
        ep: 'Episode 1000+',
        img: 'https://m.media-amazon.com/images/M/MV5BODcwNWE3OTMtMDc3MS00NDFjLWE1OTAtNDU3NjgxODMxY2UyXkEyXkFqcGdeQXVyNTAyODkwOQ@@._V1_FMjpg_UX1000_.jpg',
        video: 'https://www.youtube.com/embed/S8_YwFLCh4U?autoplay=1'
    },
    {
        id: 'kimetsu',
        title: 'Demon Slayer',
        ep: 'Season 3',
        img: 'https://m.media-amazon.com/images/M/MV5BZjZjNzI5MDctY2Y4YS00NmM4LTljMmItYzMwM2Q5MWExOGI4XkEyXkFqcGdeQXVyNzYzMzkyNTM@._V1_FMjpg_UX1000_.jpg',
        video: 'https://www.youtube.com/embed/t6MXHxe8yVA?autoplay=1'
    },
    {
        id: 'jujutsu',
        title: 'Jujutsu Kaisen',
        ep: 'Season 2',
        img: 'https://m.media-amazon.com/images/M/MV5BNGY4MTg3NzgtMmFkZi00NTg5LWExMmEtMWI3YzI1ODdmMWQ1XkEyXkFqcGdeQXVyMjQwMDg0Ng@@._V1_.jpg',
        video: 'https://www.youtube.com/embed/O6qVieflwqs?autoplay=1'
    },
    {
        id: 'upin',
        title: 'Upin & Ipin',
        ep: 'Terbaru 2024',
        img: 'https://upload.wikimedia.org/wikipedia/id/8/89/Upin_%26_Ipin_logo.png', // Fallback generic
        video: 'https://www.youtube.com/embed/mK9WJ6Y7968?autoplay=1'
    },
    {
        id: 'boboiboy',
        title: 'BoBoiBoy Galaxy',
        ep: 'Musim 2',
        img: 'https://m.media-amazon.com/images/M/MV5BMjA4ODU3NTI0NF5BMl5BanBnXkFtZTgwMTY2MzU5MzE@._V1_.jpg',
        video: 'https://www.youtube.com/embed/HuF_R3t9XjE?autoplay=1'
    }
];

const grid = document.getElementById('animeGrid');
const modal = document.getElementById('videoModal');
const iframe = document.getElementById('videoFrame');
const titleDisplay = document.getElementById('nowPlaying');

// Render Grid
animeList.forEach(anime => {
    const card = document.createElement('div');
    card.className = 'anime-card';
    card.innerHTML = `
        <img src="${anime.img}" alt="${anime.title}" class="card-img" onerror="this.src='https://via.placeholder.com/150x200?text=No+Image'">
        <div class="card-info">
            <div class="card-title">${anime.title}</div>
            <div class="card-ep">${anime.ep}</div>
        </div>
    `;
    card.onclick = () => openPlayer(anime.id);
    grid.appendChild(card);
});

function openPlayer(id) {
    const anime = animeList.find(a => a.id === id);
    if(anime) {
        iframe.src = anime.video;
        titleDisplay.innerText = "Sedang Memutar: " + anime.title;
        modal.style.display = 'flex';
    }
}

function closePlayer() {
    modal.style.display = 'none';
    iframe.src = '';
}

// Close modal on outside click
window.onclick = function(event) {
    if (event.target == modal) {
        closePlayer();
    }
}
EOF_JS

    echo -e "${G}[✓] Template Animasi Berhasil Dibuat!${RESET}"
    sleep 2
}

input_custom_code() {
    clear
    echo -e "${C}╔════════════════════════════════════════╗${RESET}"
    echo -e "${C}║      ${Y}UPLOAD KODE CUSTOM (PASTE)${C}        ║${RESET}"
    echo -e "${C}╚════════════════════════════════════════╝${RESET}"
    echo ""
    echo -e "${W}Pilih jenis file yang ingin di-isi:${RESET}"
    echo -e "${W} 1. ${Y}HTML${RESET} (index.html)"
    echo -e "${W} 2. ${C}CSS${RESET}  (style.css)"
    echo -e "${W} 3. ${G}JS${RESET}   (script.js)"
    echo ""
    read -p " Pilihan [1-3]: " TIPE_FILE

    case $TIPE_FILE in
        1) TARGET="index.html"; NAME="HTML" ;;
        2) TARGET="style.css"; NAME="CSS" ;;
        3) TARGET="script.js"; NAME="JavaScript" ;;
        *) echo -e "${R}Batal.${RESET}"; sleep 1; return ;;
    esac

    echo -e "\n${Y}[*] Instruksi:${RESET}"
    echo -e "1. Copy kode ${NAME} Anda."
    echo -e "2. Paste di bawah garis ini."
    echo -e "3. Tekan ${G}ENTER${RESET} setelah baris terakhir."
    echo -e "4. Tekan ${R}CTRL + D${RESET} untuk MENYIMPAN."
    echo -e "${C}------------------------------------------${RESET}"

    # Capture input
    cat > "$TARGET"

    if [ -s "$TARGET" ]; then
        echo -e "\n${G}[✓] File $TARGET berhasil disimpan!${RESET}"
    else
        echo -e "\n${R}[!] File kosong atau gagal disimpan.${RESET}"
    fi
    sleep 2
}

update_script() {
    echo -e "${Y}[*] Mengecek pembaruan...${RESET}"
    echo -e "${W}Fitur Update Git dinonaktifkan di versi UserLAnd.${RESET}"
    read -p "Tekan Enter..."
}

manage_files() {
    while true; do
        clear
        echo -e "${C}╔════════════════════════════════════════╗${RESET}"
        echo -e "${C}║      ${Y}EDITOR KODE WEBSITE${C}               ║${RESET}"
        echo -e "${C}╚════════════════════════════════════════╝${RESET}"
        echo ""
        echo -e "${W} 1. ${Y}Buat Template Modern${RESET} (Standard)"
        echo -e "${W} 2. ${G}Buat Template Speed Test${RESET} (Modern v2)${RESET}"
        echo -e "${W} 3. ${C}Buat Template System Monitor${RESET} (Dashboard)${RESET}"
        echo -e "${W} 4. ${Y}Buat Template Animasi Indonesia${RESET} (Kartun Stream)${RESET}"
        echo -e "${W} 5. ${B}${G}📥 Upload Kode Custom${RESET} (Paste Mode)${RESET}"
        echo -e "${W} 6. ${C}Edit index.html${RESET}"
        echo -e "${W} 7. ${C}Edit style.css${RESET}"
        echo -e "${W} 8. ${C}Edit script.js${RESET}"
        echo -e "${W} 9. ${R}Kembali ke Menu Utama${RESET}"
        echo ""
        draw_border
        read -p " Pilih opsi [1-9]: " SUB_PIL

        case $SUB_PIL in
            1) create_template ;;
            2) create_speedtest ;;
            3) create_monitor ;;
            4) create_anime_template ;;
            5) input_custom_code ;;
            6) nano index.html || { echo "Nano tidak ditemukan, gunakan cat > index.html"; read -p "Tekan Enter"; } ;;
            7) nano style.css || { echo "Nano tidak ditemukan"; read -p "Tekan Enter"; } ;;
            8) nano script.js || { echo "Nano tidak ditemukan"; read -p "Tekan Enter"; } ;;
            9) break ;;
            *) echo -e "${R}Pilihan salah!${RESET}"; sleep 1 ;;
        esac
    done
}

# --- MAIN LOOP ---
while true; do
    cek_status
    header
    echo -e "${Y} Status Server : ${STAT_SERVER}"
    echo -e "${Y} Status Host   : ${STAT_HOST}"
    echo -e "${Y} Domain Anda   : ${W}server.ahemmm.my.id${RESET}"
    echo "" # Spacing
    draw_border
    echo -e "${W} [1] ${C}Masukkan Token${RESET} ${W}(Kode Auth Cloudflare)${RESET}"
    echo -e "${W} [2] ${G}Jalankan / Refresh${RESET} ${W}(Start Server)${RESET}"
    echo -e "${W} [3] ${Y}Lihat Log Error${RESET} ${W}(Debug Mode)${RESET}"
    echo -e "${W} [4] ${R}Matikan Semua${RESET} ${W}(Stop Service)${RESET}"
    echo -e "${W} [5] ${B}${C}📂 Kelola File Website (HTML/JS)${RESET} ${Y}*NEW*${RESET}"
    echo -e "${W} [6] ${G}🔄 Update Script${RESET}"
    echo -e "${W} [7] ${R}Keluar${RESET}"
    draw_border
    read -p " Pilih menu [1-7]: " PIL

    case $PIL in
        1)
            echo -e "\n${Y}Pastikan HANYA paste kode token panjangnya saja.${RESET}"
            read -p " Paste Token: " TKN
            CLEAN_TOKEN=$(echo $TKN | tr -d '[:space:]')
            echo "$CLEAN_TOKEN" > $TOKEN_FILE
            echo -e "${G}Token disimpan!${RESET}"; sleep 2 ;;
        2)
            echo -e "${Y}Membersihkan proses lama...${RESET}"
            pkill -f "cloudflared"
            pkill -f "python3 server.py"
            pkill -f "python3 -m http.server"
            # termux-wake-lock
            sleep 1

            # Cek apakah server.py ada, jika tidak buat default
            if [ ! -f "server.py" ]; then
                echo "Menggunakan server default..."
                nohup python3 -m http.server 8080 > /dev/null 2>&1 &
            else
                echo "Menggunakan Custom Server (SpeedTest Support)..."
                nohup python3 server.py > /dev/null 2>&1 &
            fi

            if [ -s "$TOKEN_FILE" ]; then
                MY_TOKEN=$(cat $TOKEN_FILE)
                echo -e "${C}Menghubungkan ke Cloudflare...${RESET}"
                nohup cloudflared tunnel --no-autoupdate run --token "$MY_TOKEN" > $LOG_FILE 2>&1 &
                sleep 5
                echo -e "${G}Server Berhasil Dijalankan!${RESET}"
                sleep 2
            else
                echo -e "${R}Gagal: Token kosong! Isi dulu di menu 1.${RESET}"; sleep 2
            fi ;;
        3)
            echo -e "${Y}--- LOG AKTIVITAS TERBARU ---${RESET}"
            if [ -f "$LOG_FILE" ]; then
                tail -n 15 $LOG_FILE
            else
                echo "Belum ada log."
            fi
            echo -e "${Y}-----------------------------${RESET}"
            read -p "Tekan Enter..." ;;
        4)
            pkill -f "cloudflared"
            pkill -f "python3 server.py"
            pkill -f "python3 -m http.server"
            # termux-wake-unlock
            echo -e "${R}Layanan berhenti.${RESET}"; sleep 2 ;;
        5)
            manage_files ;;
        6)
            update_script ;;
        7)
            echo -e "${C}Terima kasih telah menggunakan script ini!${RESET}"
            exit ;;
        *) echo -e "${R}Pilihan tidak valid!${RESET}"; sleep 1 ;;
    esac
done
EOF_BASH

chmod +x menu.sh

echo "Setup Complete!"
echo "Run ./menu.sh to start."
