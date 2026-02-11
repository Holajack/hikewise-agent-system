const express = require('express');
const { WebSocketServer } = require('ws');
const http = require('http');
const fs = require('fs');
const path = require('path');
const { execSync, spawn } = require('child_process');
const { v4: uuidv4 } = require('uuid');
const chokidar = require('chokidar');

const app = express();
const server = http.createServer(app);
const wss = new WebSocketServer({ server });

const PORT = process.env.PORT || 3847;
const DATA_DIR = path.join(__dirname, '..', 'data');
const LOGS_DIR = path.join(__dirname, '..', 'agent', 'logs');
const MAESTRO_DIR_LOCAL = path.join(__dirname, '..', 'maestro');
const AGENT_DIR = path.join(__dirname, '..', 'agent');
const RECORDINGS_DIR = path.join(DATA_DIR, 'recordings');
const SCREENSHOTS_DIR = path.join(DATA_DIR, 'screenshots');
const DISCOVERY_DIR = path.join(DATA_DIR, 'discovery');
const SCANNER_SCRIPT = path.join(AGENT_DIR, 'scan-app.sh');
const GENERATED_FLOWS_DIR = path.join(MAESTRO_DIR_LOCAL, 'flows', 'generated');

// Helper: resolve Maestro dir - LOCAL takes priority (corrected flows), repo is fallback
function getMaestroDir() {
  // Always use local maestro dir for running tests (contains corrected flows)
  return MAESTRO_DIR_LOCAL;
}
function getRepoMaestroDir() {
  if (config.repoPath && fs.existsSync(path.join(config.repoPath, 'maestro'))) {
    return path.join(config.repoPath, 'maestro');
  }
  return null;
}
const MAESTRO_DIR = MAESTRO_DIR_LOCAL;

// Ensure directories exist
[DATA_DIR, LOGS_DIR, path.join(MAESTRO_DIR, 'results'), RECORDINGS_DIR, SCREENSHOTS_DIR, DISCOVERY_DIR, GENERATED_FLOWS_DIR].forEach(dir => {
  fs.mkdirSync(dir, { recursive: true });
});

// --- Data persistence (simple JSON files) ---
const TASKS_FILE = path.join(DATA_DIR, 'tasks.json');
const STATUS_FILE = path.join(DATA_DIR, 'agent-status.json');
const HISTORY_FILE = path.join(DATA_DIR, 'history.json');
const CONFIG_FILE = path.join(DATA_DIR, 'config.json');

function loadJSON(file, fallback) {
  try { return JSON.parse(fs.readFileSync(file, 'utf8')); }
  catch { return fallback; }
}

function saveJSON(file, data) {
  fs.writeFileSync(file, JSON.stringify(data, null, 2));
}

// Initialize data files
let tasks = loadJSON(TASKS_FILE, []);
let agentStatus = loadJSON(STATUS_FILE, {
  state: 'idle', // idle | running | testing | error
  currentTask: null,
  lastActive: null,
  pid: null
});
let history = loadJSON(HISTORY_FILE, []);
let config = loadJSON(CONFIG_FILE, {
  worktreePath: '',
  repoPath: '',
  hikewiseAppId: 'com.hikewise.app',
  autoRunTests: true,
  maxAgentRuntime: 3600, // 1 hour per task
  claudeModel: 'opus', // or sonnet
  deviceMode: 'auto', // auto | physical | simulator
  physicalDeviceId: '', // UDID of physical device (auto-detected if empty)
  appMode: 'expo-go', // expo-go | development-build
  expoDevUrl: '' // e.g. exp://192.168.1.5:8081 (auto-detected from npx expo start)
});

app.use(express.json());
app.use(express.static(path.join(__dirname, 'public')));

// --- Physical Device Detection ---
const { execFileSync: execFileSyncTop } = require('child_process');

function getPhysicalDevices() {
  try {
    // Use JSON output to get the real hardware UDID (not CoreDevice identifier)
    const tmpJson = path.join(DATA_DIR, '_devices_tmp.json');
    execFileSyncTop('xcrun', ['devicectl', 'list', 'devices', '--json-output', tmpJson], {
      encoding: 'utf8', timeout: 10000
    });
    const data = JSON.parse(fs.readFileSync(tmpJson, 'utf8'));
    fs.unlinkSync(tmpJson);

    const devices = [];
    for (const d of (data.result?.devices || [])) {
      const hw = d.hardwareProperties || {};
      const conn = d.connectionProperties || {};
      devices.push({
        name: d.name || hw.marketingName || 'iPhone',
        hostname: d.hostname || '',
        coreDeviceId: d.identifier,           // CoreDevice UUID (not for Maestro)
        udid: hw.udid || d.identifier,        // Real iOS UDID (for Maestro)
        state: conn.transportType || 'unknown',
        model: hw.marketingName || hw.productType || '',
        isPhysical: true,
        isBooted: conn.transportType === 'wired' || conn.transportType === 'localNetwork'
      });
    }
    return devices;
  } catch {
    return [];
  }
}

function getActiveDevice() {
  // Returns { type: 'physical'|'simulator', udid, name } based on config
  const mode = config.deviceMode || 'auto';

  if (mode === 'physical' || mode === 'auto') {
    const physical = getPhysicalDevices();
    const connected = physical.find(d => d.isBooted);
    if (connected) {
      return {
        type: 'physical',
        udid: connected.udid,
        name: connected.name,
        model: connected.model
      };
    }
    if (mode === 'physical') return null; // no physical device found
  }

  if (mode === 'simulator' || mode === 'auto') {
    try {
      const output = execFileSyncTop('xcrun', ['simctl', 'list', 'devices', '--json'], { encoding: 'utf8' });
      const data = JSON.parse(output);
      for (const [, devList] of Object.entries(data.devices || {})) {
        for (const dev of devList) {
          if (dev.state === 'Booted') {
            return { type: 'simulator', udid: dev.udid, name: dev.name, model: dev.name };
          }
        }
      }
    } catch {}
  }

  return null;
}

function takeDeviceScreenshot(filepath) {
  const device = getActiveDevice();
  if (!device) throw new Error('No device available. Connect an iPhone via USB or boot a simulator.');

  if (device.type === 'physical') {
    // Use Maestro to take screenshot on physical device via a mini flow
    const tmpYaml = path.join(MAESTRO_DIR_LOCAL, 'flows', '_screenshot_tmp.yaml');
    // Use Expo Go appId when in expo-go mode, otherwise use the configured app ID
    const effectiveAppId = (config.appMode === 'expo-go') ? 'host.exp.Exponent' : (config.hikewiseAppId || 'com.hikewise.app');
    fs.writeFileSync(tmpYaml, `appId: ${effectiveAppId}\n---\n- takeScreenshot: ${filepath}\n`);
    try {
      // Physical devices need the maestro-ios-device bridge (--driver-host-port 6001)
      execFileSyncTop('maestro', [
        '--driver-host-port', '6001', '--device', device.udid, 'test', tmpYaml
      ], { encoding: 'utf8', timeout: 20000 });
    } finally {
      try { fs.unlinkSync(tmpYaml); } catch {}
    }
  } else {
    execFileSyncTop('xcrun', [
      'simctl', 'io', 'booted', 'screenshot', filepath
    ], { encoding: 'utf8', timeout: 15000 });
  }
  return device;
}

// --- WebSocket broadcast ---
function broadcast(type, data) {
  const msg = JSON.stringify({ type, data, timestamp: new Date().toISOString() });
  wss.clients.forEach(client => {
    if (client.readyState === 1) client.send(msg);
  });
}

// --- Agent process management ---
let agentProcess = null;
let scannerProcess = null;
let currentScanId = null;

function updateAgentStatus(updates) {
  Object.assign(agentStatus, updates, { lastUpdated: new Date().toISOString() });
  saveJSON(STATUS_FILE, agentStatus);
  broadcast('agent-status', agentStatus);
}

// --- API Routes ---

// Get dashboard state
app.get('/api/state', (req, res) => {
  res.json({
    tasks,
    agentStatus,
    history: history.slice(-50),
    config,
    maestroFlows: getMaestroFlows(),
    stats: getStats()
  });
});

// Task management
app.get('/api/tasks', (req, res) => res.json(tasks));

app.post('/api/tasks', (req, res) => {
  const task = {
    id: uuidv4(),
    title: req.body.title,
    description: req.body.description || '',
    status: req.body.status || 'queued', // queued | in-progress | review | done | failed
    priority: req.body.priority || 'medium', // low | medium | high | critical
    source: req.body.source || 'manual', // manual | maestro | agent
    createdAt: new Date().toISOString(),
    updatedAt: new Date().toISOString(),
    agentNotes: '',
    testResults: null,
    files: []
  };
  tasks.push(task);
  saveJSON(TASKS_FILE, tasks);
  addHistory('task-created', `Task created: ${task.title}`, task.id);
  broadcast('task-update', tasks);
  res.json(task);
});

app.patch('/api/tasks/:id', (req, res) => {
  const task = tasks.find(t => t.id === req.params.id);
  if (!task) return res.status(404).json({ error: 'Task not found' });
  
  Object.assign(task, req.body, { updatedAt: new Date().toISOString() });
  saveJSON(TASKS_FILE, tasks);
  broadcast('task-update', tasks);
  res.json(task);
});

app.delete('/api/tasks/:id', (req, res) => {
  const task = tasks.find(t => t.id === req.params.id);
  const title = task ? task.title : 'Unknown task';
  tasks = tasks.filter(t => t.id !== req.params.id);
  saveJSON(TASKS_FILE, tasks);
  addHistory('task-deleted', `Task deleted: ${title}`, req.params.id);
  broadcast('task-update', tasks);
  res.json({ ok: true });
});

// Reorder / move task between columns
app.post('/api/tasks/:id/move', (req, res) => {
  const task = tasks.find(t => t.id === req.params.id);
  if (!task) return res.status(404).json({ error: 'Task not found' });
  task.status = req.body.status;
  task.updatedAt = new Date().toISOString();
  saveJSON(TASKS_FILE, tasks);
  addHistory('task-moved', `"${task.title}" moved to ${task.status}`, task.id);
  broadcast('task-update', tasks);
  res.json(task);
});

// Agent control
app.post('/api/agent/start', (req, res) => {
  if (agentProcess) {
    return res.status(409).json({ error: 'Agent already running' });
  }
  
  const taskId = req.body.taskId; // optional - specific task to work on
  const mode = req.body.mode || 'auto'; // auto | specific-task | test-and-fix
  
  startAgent(mode, taskId);
  res.json({ status: 'started', mode });
});

app.post('/api/agent/stop', (req, res) => {
  if (agentProcess) {
    agentProcess.kill('SIGTERM');
    agentProcess = null;
    updateAgentStatus({ state: 'idle', currentTask: null, pid: null });
    addHistory('agent-stopped', 'Agent manually stopped');
  }
  res.json({ status: 'stopped' });
});

// Maestro test control
app.get('/api/maestro/flows', (req, res) => {
  res.json(getMaestroFlows());
});

app.post('/api/maestro/run', (req, res) => {
  const flowFile = req.body.flow; // specific flow or 'all'
  runMaestroTests(flowFile);
  res.json({ status: 'running', flow: flowFile });
});

app.get('/api/maestro/results', (req, res) => {
  const resultsDir = path.join(getMaestroDir(), 'results');
  try {
    const files = fs.readdirSync(resultsDir)
      .filter(f => f.endsWith('.json'))
      .sort()
      .reverse()
      .slice(0, 20);
    const results = files.map(f => loadJSON(path.join(resultsDir, f), {}));
    res.json(results);
  } catch {
    res.json([]);
  }
});

// Config
app.get('/api/config', (req, res) => res.json(config));
app.patch('/api/config', (req, res) => {
  Object.assign(config, req.body);
  saveJSON(CONFIG_FILE, config);
  broadcast('config-update', config);
  res.json(config);
});

// History / logs
app.get('/api/history', (req, res) => {
  const limit = parseInt(req.query.limit) || 100;
  res.json(history.slice(-limit));
});

// Agent logs (stream the latest log file)
app.get('/api/agent/logs', (req, res) => {
  try {
    const logFiles = fs.readdirSync(LOGS_DIR).filter(f => f.endsWith('.log')).sort().reverse();
    if (logFiles.length === 0) return res.json({ content: 'No logs yet.' });
    const latest = fs.readFileSync(path.join(LOGS_DIR, logFiles[0]), 'utf8');
    res.json({ file: logFiles[0], content: latest.slice(-10000) }); // last 10k chars
  } catch {
    res.json({ content: 'No logs yet.' });
  }
});

// Progress file (from worktree)
app.get('/api/progress', (req, res) => {
  if (!config.worktreePath) return res.json({ content: 'Worktree path not configured.' });
  const progressFile = path.join(config.worktreePath, 'claude-progress.txt');
  try {
    const content = fs.readFileSync(progressFile, 'utf8');
    res.json({ content });
  } catch {
    res.json({ content: 'Progress file not found. Run agent setup first.' });
  }
});

// Stats
app.get('/api/stats', (req, res) => res.json(getStats()));

// --- HikeWise Project Endpoints ---

// List directives from the real project
app.get('/api/directives', (req, res) => {
  if (!config.repoPath) return res.json([]);
  const directivesDir = path.join(config.repoPath, 'directives');
  try {
    const files = fs.readdirSync(directivesDir)
      .filter(f => f.endsWith('.md') && !f.startsWith('_'));
    const directives = files.map(f => ({
      name: f.replace('.md', '').replace(/-/g, ' '),
      file: f,
      path: path.join(directivesDir, f)
    }));
    res.json(directives);
  } catch {
    res.json([]);
  }
});

// Read a specific directive
app.get('/api/directives/:file', (req, res) => {
  if (!config.repoPath) return res.status(404).json({ error: 'Repo not configured' });
  // Sanitize filename to prevent path traversal
  const safeFile = path.basename(req.params.file);
  const filePath = path.join(config.repoPath, 'directives', safeFile);
  try {
    const content = fs.readFileSync(filePath, 'utf8');
    res.json({ file: safeFile, content });
  } catch {
    res.status(404).json({ error: 'Directive not found' });
  }
});

// Git status of the real project (using execFileSync for safety)
app.get('/api/git/status', (req, res) => {
  if (!config.repoPath) return res.json({ error: 'Repo not configured' });
  const { execFileSync } = require('child_process');
  try {
    const status = execFileSync('git', ['status', '--short'], { cwd: config.repoPath, encoding: 'utf8' });
    const branch = execFileSync('git', ['branch', '--show-current'], { cwd: config.repoPath, encoding: 'utf8' }).trim();
    const log = execFileSync('git', ['log', '--oneline', '-10'], { cwd: config.repoPath, encoding: 'utf8' });
    res.json({ branch, status, log });
  } catch (e) {
    res.json({ error: e.message });
  }
});

// List execution scripts
app.get('/api/execution', (req, res) => {
  if (!config.repoPath) return res.json([]);
  const executionDir = path.join(config.repoPath, 'execution');
  try {
    const files = fs.readdirSync(executionDir)
      .filter(f => f.endsWith('.py') && !f.startsWith('_'));
    res.json(files.map(f => ({
      name: f.replace('.py', '').replace(/_/g, ' '),
      file: f
    })));
  } catch {
    res.json([]);
  }
});

// Read project CLAUDE.md
app.get('/api/project/claude-md', (req, res) => {
  if (!config.repoPath) return res.json({ content: 'Repo not configured.' });
  const claudePath = path.join(config.repoPath, 'CLAUDE.md');
  try {
    const content = fs.readFileSync(claudePath, 'utf8');
    res.json({ content });
  } catch {
    res.json({ content: 'CLAUDE.md not found in project.' });
  }
});

// --- Simulator Management ---

// Serve recordings and screenshots as static files
app.use('/recordings', express.static(RECORDINGS_DIR));
app.use('/screenshots', express.static(SCREENSHOTS_DIR));

// Get list of all available devices (physical + simulator)
app.get('/api/simulator/list', (req, res) => {
  const { execFileSync } = require('child_process');
  const allDevices = [];

  // 1. Physical devices via xcrun devicectl
  const physical = getPhysicalDevices();
  physical.forEach(d => {
    allDevices.push({
      udid: d.udid,
      name: d.name,
      state: d.isBooted ? 'Connected' : d.state,
      model: d.model,
      isBooted: d.isBooted,
      isPhysical: true,
      platform: 'ios'
    });
  });

  // 2. Simulators (only if device mode allows)
  if (config.deviceMode !== 'physical') {
    try {
      const output = execFileSync('xcrun', ['simctl', 'list', 'devices', '--json'], { encoding: 'utf8' });
      const data = JSON.parse(output);
      for (const [runtime, devList] of Object.entries(data.devices || {})) {
        for (const dev of devList) {
          if (dev.isAvailable) {
            allDevices.push({
              udid: dev.udid,
              name: dev.name,
              state: dev.state,
              runtime: runtime.split('.').pop(),
              isBooted: dev.state === 'Booted',
              isPhysical: false,
              platform: 'ios'
            });
          }
        }
      }
    } catch {}
  }

  // Sort: physical first, then booted, then iPhones
  allDevices.sort((a, b) => {
    if (a.isPhysical !== b.isPhysical) return b.isPhysical - a.isPhysical;
    if (a.isBooted !== b.isBooted) return b.isBooted - a.isBooted;
    const aPhone = a.name.includes('iPhone') ? 0 : 1;
    const bPhone = b.name.includes('iPhone') ? 0 : 1;
    if (aPhone !== bPhone) return aPhone - bPhone;
    return a.name.localeCompare(b.name);
  });

  const active = getActiveDevice();
  res.json({
    devices: allDevices,
    platform: 'ios',
    activeDevice: active,
    deviceMode: config.deviceMode || 'auto'
  });
});

// Boot a simulator (physical devices are always "on")
app.post('/api/simulator/boot', (req, res) => {
  const { execFileSync } = require('child_process');
  const { udid, name, platform, isPhysical } = req.body;

  if (isPhysical) {
    return res.json({ status: 'already-connected', udid, name, message: 'Physical device is already connected.' });
  }

  try {
    execFileSync('xcrun', ['simctl', 'boot', udid], { encoding: 'utf8' });
    spawn('open', ['-a', 'Simulator'], { detached: true, stdio: 'ignore' }).unref();
    addHistory('simulator-booted', `iOS Simulator booted: ${name || udid}`);
    broadcast('simulator-status', { state: 'booting', name: name || udid });
    res.json({ status: 'booting', udid, name });
  } catch (e) {
    res.status(500).json({ error: e.message });
  }
});

// Shutdown a simulator
app.post('/api/simulator/shutdown', (req, res) => {
  const { execFileSync } = require('child_process');
  const { udid } = req.body;
  try {
    execFileSync('xcrun', ['simctl', 'shutdown', udid], { encoding: 'utf8' });
    addHistory('simulator-shutdown', `Simulator shut down: ${udid}`);
    broadcast('simulator-status', { state: 'shutdown', udid });
    res.json({ status: 'shutdown' });
  } catch (e) {
    res.status(500).json({ error: e.message });
  }
});

// Take a screenshot of the active device (physical or simulator)
app.post('/api/simulator/screenshot', (req, res) => {
  const filename = `screenshot-${Date.now()}.png`;
  const filePath = path.join(SCREENSHOTS_DIR, filename);
  try {
    const device = takeDeviceScreenshot(filePath);
    addHistory('screenshot-taken', `Screenshot from ${device.type} (${device.name}): ${filename}`);
    broadcast('screenshot', { file: filename, url: `/screenshots/${filename}`, timestamp: new Date().toISOString(), device: device.type });
    res.json({ file: filename, url: `/screenshots/${filename}`, device: device.type });
  } catch (e) {
    res.status(500).json({ error: e.message || 'No device available. Connect iPhone via USB or boot a simulator.' });
  }
});

// Get all screenshots
app.get('/api/screenshots', (req, res) => {
  try {
    const files = fs.readdirSync(SCREENSHOTS_DIR)
      .filter(f => f.endsWith('.png') || f.endsWith('.jpg'))
      .sort()
      .reverse()
      .slice(0, 50);
    res.json(files.map(f => ({
      file: f,
      url: `/screenshots/${f}`,
      timestamp: fs.statSync(path.join(SCREENSHOTS_DIR, f)).mtime.toISOString()
    })));
  } catch {
    res.json([]);
  }
});

// Get all recordings
app.get('/api/recordings', (req, res) => {
  try {
    const files = fs.readdirSync(RECORDINGS_DIR)
      .filter(f => f.endsWith('.mp4') || f.endsWith('.mov'))
      .sort()
      .reverse()
      .slice(0, 20);
    res.json(files.map(f => ({
      file: f,
      url: `/recordings/${f}`,
      timestamp: fs.statSync(path.join(RECORDINGS_DIR, f)).mtime.toISOString(),
      size: fs.statSync(path.join(RECORDINGS_DIR, f)).size
    })));
  } catch {
    res.json([]);
  }
});

// --- Maestro Record (video capture of test run) ---
let recordProcess = null;

app.post('/api/maestro/record', (req, res) => {
  if (recordProcess) {
    return res.status(409).json({ error: 'Recording already in progress' });
  }

  const flowFile = req.body.flow;
  if (!flowFile) return res.status(400).json({ error: 'Flow file required' });

  const maestroDir = getMaestroDir();
  const flowPath = path.join(maestroDir, 'flows', flowFile);
  const videoFile = `recording-${Date.now()}.mp4`;
  const videoPath = path.join(RECORDINGS_DIR, videoFile);

  if (!fs.existsSync(flowPath)) {
    return res.status(404).json({ error: `Flow not found: ${flowFile}` });
  }

  updateAgentStatus({ state: 'testing' });
  addHistory('maestro-recording', `Recording test: ${flowFile}`);
  broadcast('maestro-status', { running: true, recording: true, flow: flowFile });

  const recDevice = getActiveDevice();
  const recArgs = recDevice && recDevice.type === 'physical'
    ? ['--driver-host-port', '6001', '--device', recDevice.udid, 'record', flowPath, '--output', videoPath]
    : ['record', flowPath, '--output', videoPath];

  recordProcess = spawn('maestro', recArgs, {
    cwd: maestroDir,
    stdio: ['ignore', 'pipe', 'pipe']
  });

  let output = '';
  recordProcess.stdout.on('data', (data) => {
    output += data.toString();
    broadcast('maestro-log', { text: data.toString() });
  });
  recordProcess.stderr.on('data', (data) => {
    output += data.toString();
    broadcast('maestro-log', { text: data.toString() });
  });

  recordProcess.on('close', (code) => {
    recordProcess = null;
    const result = {
      timestamp: new Date().toISOString(),
      flow: flowFile,
      exitCode: code,
      passed: code === 0,
      video: code === 0 ? { file: videoFile, url: `/recordings/${videoFile}` } : null,
      output: output.slice(-5000)
    };

    broadcast('maestro-status', { running: false, recording: false, result });
    addHistory('maestro-complete', `Recording ${code === 0 ? 'completed' : 'failed'}: ${flowFile}`);

    if (code === 0) {
      broadcast('recording-ready', { file: videoFile, url: `/recordings/${videoFile}`, flow: flowFile });
    }

    updateAgentStatus({ state: agentProcess ? 'running' : 'idle' });
  });

  res.json({ status: 'recording', flow: flowFile, videoFile });
});

// Stop a running recording
app.post('/api/maestro/record/stop', (req, res) => {
  if (recordProcess) {
    recordProcess.kill('SIGTERM');
    recordProcess = null;
    updateAgentStatus({ state: agentProcess ? 'running' : 'idle' });
    res.json({ status: 'stopped' });
  } else {
    res.json({ status: 'not-recording' });
  }
});

// Check device connection and app status
app.get('/api/simulator/app-status', (req, res) => {
  const { execFileSync } = require('child_process');
  const appId = config.hikewiseAppId || 'com.hikewise.app';
  const appMode = config.appMode || 'expo-go';
  const device = getActiveDevice();

  if (!device) {
    return res.json({
      connected: false,
      installed: false,
      appId,
      message: 'No device connected. Plug in your iPhone via USB or boot a simulator.'
    });
  }

  const result = {
    connected: true,
    deviceType: device.type,
    deviceName: device.name,
    model: device.model,
    appId,
    appMode
  };

  if (appMode === 'expo-go') {
    // For Expo Go mode, check if Expo Go is installed (not the user's app)
    const expoGoId = 'host.exp.Exponent';

    if (device.type === 'physical') {
      // We can't reliably check app installation on physical devices via devicectl
      // Just report the device is connected and ready
      result.installed = false;
      result.expoGoReady = true;
      result.message = `${device.name} connected via USB. Run "npx expo start" then scan QR code with your iPhone camera.`;
      result.hint = 'Make sure Expo Go is installed from the App Store.';
    } else {
      try {
        execFileSync('xcrun', ['simctl', 'get_app_container', 'booted', expoGoId], { encoding: 'utf8' });
        result.installed = true;
        result.expoGoReady = true;
        result.message = 'Expo Go installed on simulator. Run "npx expo start" to load your app.';
      } catch {
        result.installed = false;
        result.expoGoReady = false;
        result.message = 'Expo Go not on simulator. Install it or switch to development build mode.';
      }
    }
  } else {
    // Development build mode — check for actual app bundle
    if (device.type === 'physical') {
      result.installed = false;
      result.message = `${device.name} connected. Install your dev build via Xcode or TestFlight to test.`;
    } else {
      try {
        execFileSync('xcrun', ['simctl', 'get_app_container', 'booted', appId], { encoding: 'utf8' });
        result.installed = true;
        result.message = `${appId} installed on simulator.`;
      } catch {
        result.installed = false;
        result.message = `${appId} not installed. Build with: eas build --profile development --platform ios`;
      }
    }
  }

  res.json(result);
});

// Install app on simulator (from a local build)
app.post('/api/simulator/install', (req, res) => {
  const { execFileSync } = require('child_process');
  const buildPath = req.body.buildPath;
  if (!buildPath) return res.status(400).json({ error: 'buildPath required' });
  try {
    if (buildPath.endsWith('.app')) {
      execFileSync('xcrun', ['simctl', 'install', 'booted', buildPath], { encoding: 'utf8' });
    } else if (buildPath.endsWith('.apk')) {
      execFileSync('adb', ['install', '-r', buildPath], { encoding: 'utf8' });
    }
    addHistory('app-installed', `App installed from: ${path.basename(buildPath)}`);
    res.json({ status: 'installed' });
  } catch (e) {
    res.status(500).json({ error: e.message });
  }
});

// Get active device info
app.get('/api/device/active', (req, res) => {
  const device = getActiveDevice();
  res.json(device || { type: 'none', message: 'No device connected' });
});

// Detect running Expo dev server
app.get('/api/expo/detect', (req, res) => {
  const { execFileSync } = require('child_process');

  // If user has manually configured an Expo URL (e.g. remote VM), trust it
  if (config.expoDevUrl) {
    res.json({
      running: true,
      url: config.expoDevUrl,
      source: 'config',
      message: 'Using configured Expo URL'
    });
    return;
  }

  // Otherwise try to auto-detect a local Expo process
  try {
    const ps = execFileSync('lsof', ['-i', ':8081', '-t'], { encoding: 'utf8', timeout: 5000 }).trim();
    if (ps) {
      const ifconfig = execFileSync('ipconfig', ['getifaddr', 'en0'], { encoding: 'utf8', timeout: 5000 }).trim();
      const expoUrl = `exp://${ifconfig}:8081`;
      res.json({ running: true, url: expoUrl, ip: ifconfig, port: 8081, source: 'local', pid: ps.split('\n')[0] });
    } else {
      res.json({ running: false, message: 'No Expo dev server detected. Set the URL in Config or run: npx expo start' });
    }
  } catch {
    res.json({ running: false, message: 'Expo dev server not detected locally. Set the URL in Config if running remotely.' });
  }
});

// Start Expo dev server (if repo path is configured)
app.post('/api/expo/start', (req, res) => {
  if (!config.repoPath) {
    return res.status(400).json({ error: 'Set HikeWise Repo Path in Config first.' });
  }
  const expoProcess = spawn('npx', ['expo', 'start', '--port', '8081'], {
    cwd: config.repoPath,
    stdio: ['ignore', 'pipe', 'pipe'],
    detached: true
  });
  expoProcess.unref();
  addHistory('expo-started', 'Expo dev server starting...');
  // Give it a moment then detect
  setTimeout(() => {
    broadcast('expo-status', { running: true });
  }, 3000);
  res.json({ status: 'starting', message: 'Expo dev server starting. Scan the QR code on your iPhone.' });
});

// --- Discovery Scanner ---

// Serve discovery screenshots
app.use('/discovery', express.static(DISCOVERY_DIR));

// Start a discovery scan
app.post('/api/scanner/start', (req, res) => {
  if (scannerProcess) {
    return res.status(409).json({ error: 'Scanner already running' });
  }

  currentScanId = `scan-${Date.now()}`;
  addHistory('scanner-started', `Discovery scan started: ${currentScanId}`);
  broadcast('scanner-status', { running: true, scanId: currentScanId });

  const scanDevice = getActiveDevice();
  const env = {
    ...process.env,
    DASHBOARD_URL: `http://localhost:${PORT}`,
    APP_ID: config.hikewiseAppId || 'com.hikewise.app',
    SCAN_ID: currentScanId,
    DEVICE_TYPE: scanDevice ? scanDevice.type : 'simulator',
    DEVICE_UDID: scanDevice ? scanDevice.udid : '',
    DEVICE_NAME: scanDevice ? scanDevice.name : '',
    APP_MODE: config.appMode || 'expo-go',
    EXPO_DEV_URL: config.expoDevUrl || ''
  };

  scannerProcess = spawn('bash', [SCANNER_SCRIPT], {
    env,
    cwd: path.join(__dirname, '..'),
    stdio: ['ignore', 'pipe', 'pipe']
  });

  scannerProcess.stdout.on('data', (data) => {
    const text = data.toString();
    broadcast('scanner-log', { text });
  });

  scannerProcess.stderr.on('data', (data) => {
    broadcast('scanner-log', { text: data.toString() });
  });

  scannerProcess.on('close', (code) => {
    const scanId = currentScanId;
    scannerProcess = null;
    currentScanId = null;

    // Load the report if scan completed
    const reportFile = path.join(DISCOVERY_DIR, `${scanId}_report.json`);
    let report = null;
    if (code === 0 && fs.existsSync(reportFile)) {
      report = loadJSON(reportFile, null);
    }

    broadcast('scanner-complete', { scanId, exitCode: code, report });
    addHistory('scanner-complete', `Discovery scan ${code === 0 ? 'completed' : 'failed'}: ${scanId}`);
  });

  res.json({ status: 'started', scanId: currentScanId });
});

// Stop a running scan
app.post('/api/scanner/stop', (req, res) => {
  if (scannerProcess) {
    scannerProcess.kill('SIGTERM');
    scannerProcess = null;
    const scanId = currentScanId;
    currentScanId = null;
    broadcast('scanner-status', { running: false, scanId });
    addHistory('scanner-stopped', `Discovery scan stopped: ${scanId}`);
    res.json({ status: 'stopped' });
  } else {
    res.json({ status: 'not-running' });
  }
});

// Receive progress updates from scanner script
app.post('/api/scanner/progress', (req, res) => {
  broadcast('scanner-progress', req.body);
  res.json({ ok: true });
});

// Get the latest discovery report
app.get('/api/scanner/report', (req, res) => {
  try {
    const files = fs.readdirSync(DISCOVERY_DIR)
      .filter(f => f.endsWith('_report.json'))
      .sort()
      .reverse();
    if (files.length === 0) return res.json(null);
    const report = loadJSON(path.join(DISCOVERY_DIR, files[0]), null);
    res.json(report);
  } catch {
    res.json(null);
  }
});

// List all past scan summaries
app.get('/api/scanner/reports', (req, res) => {
  try {
    const files = fs.readdirSync(DISCOVERY_DIR)
      .filter(f => f.endsWith('_report.json'))
      .sort()
      .reverse()
      .slice(0, 20);
    const reports = files.map(f => {
      const r = loadJSON(path.join(DISCOVERY_DIR, f), {});
      return {
        scanId: r.scanId,
        timestamp: r.timestamp,
        summary: r.summary
      };
    });
    res.json(reports);
  } catch {
    res.json([]);
  }
});

// Generate test flows from latest scan data
app.post('/api/scanner/generate-tests', (req, res) => {
  try {
    // Load latest report
    const files = fs.readdirSync(DISCOVERY_DIR)
      .filter(f => f.endsWith('_report.json'))
      .sort()
      .reverse();
    if (files.length === 0) return res.status(404).json({ error: 'No scan report found. Run a scan first.' });

    const report = loadJSON(path.join(DISCOVERY_DIR, files[0]), null);
    if (!report) return res.status(500).json({ error: 'Failed to load report' });

    const generated = generateTestFlows(report);
    addHistory('tests-generated', `Generated ${generated.length} test flows from scan ${report.scanId}`);
    broadcast('flows-updated', { generated: generated.length });
    res.json({ status: 'generated', flows: generated });
  } catch (e) {
    res.status(500).json({ error: e.message });
  }
});

function generateTestFlows(report) {
  fs.mkdirSync(GENERATED_FLOWS_DIR, { recursive: true });
  const appId = report.appId || config.hikewiseAppId || 'com.hikewise.app';
  const generated = [];

  // 1. Drawer navigation smoke test - visits every screen via drawer
  const successScreens = report.screens.filter(s => s.status === 'success' && s.navigatedVia === 'drawer');
  if (successScreens.length > 0) {
    let smokeYaml = `appId: ${appId}\n# Auto-generated drawer navigation smoke test\n# Visits every discovered screen via the drawer\n# Generated from scan: ${report.scanId}\n---\n- launchApp\n- waitForAnimationToEnd\n`;

    for (const screen of successScreens) {
      smokeYaml += `\n# Navigate to: ${screen.name}\n`;
      smokeYaml += `- tapOn:\n    point: "92%,6%"\n`;
      smokeYaml += `- waitForAnimationToEnd\n`;
      smokeYaml += `- tapOn:\n    text: "${screen.name}"\n    optional: true\n`;
      smokeYaml += `- waitForAnimationToEnd\n`;

      // Add a basic visibility assertion for a discovered text element
      const visibleText = (screen.elements.textElements || []).find(t => t.length > 3 && t.length < 40);
      if (visibleText) {
        smokeYaml += `- assertVisible:\n    text: "${visibleText}"\n    optional: true\n`;
      }
    }

    const smokePath = path.join(GENERATED_FLOWS_DIR, 'drawer-navigation-smoke.yaml');
    fs.writeFileSync(smokePath, smokeYaml);
    generated.push('generated/drawer-navigation-smoke.yaml');
  }

  // 2. Per-screen verification flows
  for (const screen of report.screens.filter(s => s.status === 'success')) {
    const safeName = screen.name.toLowerCase().replace(/[^a-z0-9]/g, '-').replace(/-+/g, '-').replace(/^-|-$/g, '');
    let verifyYaml = `appId: ${appId}\n# Auto-generated verification for: ${screen.name}\n# Generated from scan: ${report.scanId}\n---\n- launchApp\n- waitForAnimationToEnd\n`;

    // Navigate to screen if not home
    if (screen.navigatedVia === 'drawer') {
      verifyYaml += `- tapOn:\n    point: "92%,6%"\n- waitForAnimationToEnd\n`;
      verifyYaml += `- tapOn:\n    text: "${screen.name}"\n    optional: true\n- waitForAnimationToEnd\n`;
    }

    // Assert discovered elements exist
    const textChecks = (screen.elements.textElements || []).slice(0, 5);
    for (const text of textChecks) {
      if (text.length > 2 && text.length < 60) {
        verifyYaml += `- assertVisible:\n    text: "${text}"\n    optional: true\n`;
      }
    }

    // Assert testIDs exist
    for (const tid of (screen.elements.testIds || []).slice(0, 10)) {
      verifyYaml += `- assertVisible:\n    id: "${tid}"\n    optional: true\n`;
    }

    // Assert buttons are present
    for (const btn of (screen.elements.buttons || []).slice(0, 5)) {
      if (btn.text && btn.text.length > 1 && btn.text.length < 40) {
        verifyYaml += `- assertVisible:\n    text: "${btn.text}"\n    optional: true\n`;
      }
    }

    const verifyPath = path.join(GENERATED_FLOWS_DIR, `verify-${safeName}.yaml`);
    fs.writeFileSync(verifyPath, verifyYaml);
    generated.push(`generated/verify-${safeName}.yaml`);
  }

  // 3. Element census - checks all discovered testIDs still exist
  const allTestIds = new Set();
  for (const screen of report.screens) {
    for (const tid of (screen.elements.testIds || [])) {
      allTestIds.add(tid);
    }
  }

  if (allTestIds.size > 0) {
    let censusYaml = `appId: ${appId}\n# Auto-generated element census\n# Verifies all discovered testIDs still exist\n# Generated from scan: ${report.scanId}\n---\n- launchApp\n- waitForAnimationToEnd\n`;

    // Visit each screen and check its testIDs
    for (const screen of report.screens.filter(s => s.status === 'success' && (s.elements.testIds || []).length > 0)) {
      censusYaml += `\n# Screen: ${screen.name}\n`;
      if (screen.navigatedVia === 'drawer') {
        censusYaml += `- tapOn:\n    point: "92%,6%"\n- waitForAnimationToEnd\n`;
        censusYaml += `- tapOn:\n    text: "${screen.name}"\n    optional: true\n- waitForAnimationToEnd\n`;
      }
      for (const tid of screen.elements.testIds) {
        censusYaml += `- assertVisible:\n    id: "${tid}"\n    optional: true\n`;
      }
    }

    const censusPath = path.join(GENERATED_FLOWS_DIR, 'element-census.yaml');
    fs.writeFileSync(censusPath, censusYaml);
    generated.push('generated/element-census.yaml');
  }

  return generated;
}

// --- Helper functions ---

function getMaestroFlows() {
  const flowMap = new Map(); // keyed by relative file path, local overrides repo

  function walkDir(dir, prefix = '', source = 'local') {
    try {
      const entries = fs.readdirSync(dir, { withFileTypes: true });
      for (const entry of entries) {
        const fullPath = path.join(dir, entry.name);
        if (entry.isDirectory()) {
          walkDir(fullPath, prefix ? `${prefix}/${entry.name}` : entry.name, source);
        } else if (entry.name.endsWith('.yaml') || entry.name.endsWith('.yml')) {
          const relFile = prefix ? `${prefix}/${entry.name}` : entry.name;
          const displayName = prefix
            ? `[${prefix}] ${entry.name.replace(/\.(yaml|yml)$/, '').replace(/-/g, ' ')}`
            : entry.name.replace(/\.(yaml|yml)$/, '').replace(/-/g, ' ');
          // Only add if not already present (local takes priority)
          if (!flowMap.has(relFile)) {
            flowMap.set(relFile, {
              name: displayName,
              file: relFile,
              path: fullPath,
              category: prefix || 'root',
              source
            });
          }
        }
      }
    } catch {
      // directory doesn't exist or unreadable
    }
  }

  // Local flows first (take priority)
  const localFlowsDir = path.join(MAESTRO_DIR_LOCAL, 'flows');
  walkDir(localFlowsDir, '', 'local');

  // Repo flows second (only added if no local override exists)
  const repoDir = getRepoMaestroDir();
  if (repoDir) {
    walkDir(path.join(repoDir, 'flows'), '', 'repo');
  }

  return Array.from(flowMap.values());
}

function addHistory(type, message, taskId = null) {
  const entry = {
    id: uuidv4(),
    type,
    message,
    taskId,
    timestamp: new Date().toISOString()
  };
  history.push(entry);
  if (history.length > 500) history = history.slice(-500);
  saveJSON(HISTORY_FILE, history);
  broadcast('history', entry);
}

function getStats() {
  const now = new Date();
  const today = new Date(now.getFullYear(), now.getMonth(), now.getDate());
  
  return {
    totalTasks: tasks.length,
    queued: tasks.filter(t => t.status === 'queued').length,
    inProgress: tasks.filter(t => t.status === 'in-progress').length,
    review: tasks.filter(t => t.status === 'review').length,
    done: tasks.filter(t => t.status === 'done').length,
    failed: tasks.filter(t => t.status === 'failed').length,
    todayCompleted: tasks.filter(t => t.status === 'done' && new Date(t.updatedAt) >= today).length,
    agentState: agentStatus.state,
    lastTestRun: history.filter(h => h.type === 'maestro-complete').slice(-1)[0]?.timestamp || null
  };
}

function startAgent(mode, taskId) {
  const scriptPath = path.join(AGENT_DIR, 'run-agent.sh');
  const logFile = path.join(LOGS_DIR, `agent-${Date.now()}.log`);
  
  updateAgentStatus({
    state: 'running',
    currentTask: taskId || 'auto-selecting',
    startedAt: new Date().toISOString()
  });
  addHistory('agent-started', `Agent started in ${mode} mode`);
  
  // Build the task context for the agent
  let taskContext = '';
  if (taskId) {
    const task = tasks.find(t => t.id === taskId);
    if (task) {
      taskContext = `SPECIFIC_TASK="${task.title}: ${task.description}"`;
      task.status = 'in-progress';
      saveJSON(TASKS_FILE, tasks);
      broadcast('task-update', tasks);
    }
  }
  
  const env = {
    ...process.env,
    AGENT_MODE: mode,
    WORKTREE_PATH: config.worktreePath,
    REPO_PATH: config.repoPath,
    APP_ID: config.hikewiseAppId,
    LOG_FILE: logFile,
    TASK_CONTEXT: taskContext,
    TASKS_JSON: JSON.stringify(tasks.filter(t => t.status === 'queued')),
    DASHBOARD_URL: `http://localhost:${PORT}`
  };
  
  agentProcess = spawn('bash', [scriptPath], {
    env,
    cwd: config.worktreePath || process.cwd(),
    stdio: ['ignore', 'pipe', 'pipe']
  });
  
  agentStatus.pid = agentProcess.pid;
  saveJSON(STATUS_FILE, agentStatus);
  
  const logStream = fs.createWriteStream(logFile, { flags: 'a' });
  agentProcess.stdout.pipe(logStream);
  agentProcess.stderr.pipe(logStream);
  
  // Stream output to WebSocket
  agentProcess.stdout.on('data', (data) => {
    const text = data.toString();
    broadcast('agent-log', { text });
    
    // Parse status markers from agent output
    if (text.includes('[TASK_COMPLETE]')) {
      const match = text.match(/\[TASK_COMPLETE\](.*)/);
      if (match) {
        addHistory('task-completed', match[1].trim());
      }
    }
    if (text.includes('[TASK_FAILED]')) {
      const match = text.match(/\[TASK_FAILED\](.*)/);
      if (match) {
        addHistory('task-failed', match[1].trim());
      }
    }
    if (text.includes('[TEST_RESULT]')) {
      const match = text.match(/\[TEST_RESULT\](.*)/);
      if (match) {
        try {
          const result = JSON.parse(match[1].trim());
          broadcast('test-result', result);
        } catch {}
      }
    }
  });
  
  agentProcess.on('close', (code) => {
    agentProcess = null;
    updateAgentStatus({
      state: code === 0 ? 'idle' : 'error',
      currentTask: null,
      pid: null,
      lastExitCode: code,
      lastRun: new Date().toISOString()
    });
    addHistory('agent-finished', `Agent finished with exit code ${code}`);
  });
}

function runMaestroTests(flowFile) {
  const resultsDir = path.join(MAESTRO_DIR_LOCAL, 'results');
  fs.mkdirSync(resultsDir, { recursive: true });
  const resultFile = path.join(resultsDir, `test-${Date.now()}.json`);

  updateAgentStatus({ state: 'testing' });
  addHistory('maestro-started', `Running Maestro tests: ${flowFile || 'all'}`);
  broadcast('maestro-status', { running: true, flow: flowFile });

  // Resolve the flow path: check local first, then repo
  let resolvedFlowPath;
  if (flowFile && flowFile !== 'all') {
    const localPath = path.join(MAESTRO_DIR_LOCAL, 'flows', flowFile);
    const repoDir = getRepoMaestroDir();
    const repoPath = repoDir ? path.join(repoDir, 'flows', flowFile) : null;
    resolvedFlowPath = fs.existsSync(localPath) ? localPath : (repoPath && fs.existsSync(repoPath) ? repoPath : localPath);
  }

  // Detect active device for maestro flags (physical needs bridge port)
  const activeDevice = getActiveDevice();
  const deviceFlag = activeDevice && activeDevice.type === 'physical'
    ? `--driver-host-port 6001 --device ${activeDevice.udid} ` : '';

  const cmd = flowFile && flowFile !== 'all'
    ? `maestro ${deviceFlag}test "${resolvedFlowPath}" --format JUNIT`
    : `maestro ${deviceFlag}test "${path.join(MAESTRO_DIR_LOCAL, 'flows')}" --format JUNIT`;
  
  const testProcess = spawn('bash', ['-c', cmd], {
    cwd: MAESTRO_DIR_LOCAL,
    stdio: ['ignore', 'pipe', 'pipe']
  });
  
  let output = '';
  testProcess.stdout.on('data', (data) => {
    output += data.toString();
    broadcast('maestro-log', { text: data.toString() });
  });
  testProcess.stderr.on('data', (data) => {
    output += data.toString();
  });
  
  testProcess.on('close', (code) => {
    const result = {
      timestamp: new Date().toISOString(),
      flow: flowFile || 'all',
      exitCode: code,
      passed: code === 0,
      output: output.slice(-5000)
    };
    
    saveJSON(resultFile, result);
    broadcast('maestro-status', { running: false, result });
    addHistory('maestro-complete', `Tests ${code === 0 ? 'PASSED ✓' : 'FAILED ✗'}: ${flowFile || 'all'}`);
    
    // If tests failed, auto-create tasks for failures (with dedup)
    if (code !== 0 && config.autoRunTests) {
      const failTitle = `Fix failing test: ${flowFile || 'multiple flows'}`;
      const existingTask = tasks.find(t => t.title === failTitle && (t.status === 'queued' || t.status === 'in-progress'));
      if (existingTask) {
        // Update existing task with latest output instead of creating a duplicate
        existingTask.description = `Maestro test failed. Output:\n${output.slice(-2000)}`;
        existingTask.testResults = result;
        existingTask.updatedAt = new Date().toISOString();
        saveJSON(TASKS_FILE, tasks);
        broadcast('task-update', tasks);
        addHistory('task-updated', `Updated existing fix task for: ${flowFile || 'all'}`, existingTask.id);
      } else {
        const failTask = {
          id: uuidv4(),
          title: failTitle,
          description: `Maestro test failed. Output:\n${output.slice(-2000)}`,
          status: 'queued',
          priority: 'high',
          source: 'maestro',
          createdAt: new Date().toISOString(),
          updatedAt: new Date().toISOString(),
          agentNotes: '',
          testResults: result,
          files: []
        };
        tasks.push(failTask);
        saveJSON(TASKS_FILE, tasks);
        broadcast('task-update', tasks);
        addHistory('task-created', `Auto-created fix task for failing test`, failTask.id);
      }
    }
    
    updateAgentStatus({ state: agentProcess ? 'running' : 'idle' });
  });
}

// --- File watcher for progress updates ---
function setupProgressWatcher() {
  const watchPaths = [];
  if (config.worktreePath) {
    watchPaths.push(path.join(config.worktreePath, 'claude-progress.txt'));
  }
  if (config.repoPath && config.repoPath !== config.worktreePath) {
    watchPaths.push(path.join(config.repoPath, 'claude-progress.txt'));
  }

  for (const progressPath of watchPaths) {
    if (fs.existsSync(progressPath)) {
      chokidar.watch(progressPath).on('change', () => {
        const content = fs.readFileSync(progressPath, 'utf8');
        broadcast('progress-update', { content });
      });
    }
  }
}
setupProgressWatcher();

// --- WebSocket connection handling ---
wss.on('connection', (ws) => {
  // Send current state on connect
  ws.send(JSON.stringify({
    type: 'init',
    data: {
      tasks,
      agentStatus,
      history: history.slice(-50),
      config,
      maestroFlows: getMaestroFlows(),
      stats: getStats(),
      scannerRunning: !!scannerProcess,
      currentScanId
    }
  }));
});

// --- Start server ---
server.listen(PORT, '0.0.0.0', () => {
  console.log(`\n🏔️  HikeWise Agent Dashboard running on port ${PORT}`);
  console.log(`   Local:     http://localhost:${PORT}`);
  
  try {
    const tsIp = execSync('tailscale ip -4 2>/dev/null').toString().trim();
    console.log(`   Tailscale:  http://${tsIp}:${PORT}`);
  } catch {
    console.log(`   Tailscale:  (not connected)`);
  }
  
  console.log(`\n   Open the dashboard in your browser to get started.\n`);
});
