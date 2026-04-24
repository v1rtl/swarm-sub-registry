import { createPublicClient, http, webSocket, parseAbi, formatUnits } from 'https://esm.sh/viem@2.21.40';
import { gnosis } from 'https://esm.sh/viem@2.21.40/chains';

// Gnosis Chain Swarm mainnet deployment (per notes/usage.md §2).
const BZZ_TOKEN        = '0xdBF3Ea6F5beE45c02255B2c26a16F300502F68da';
const POSTAGE_STAMP    = '0x45a1502382541Cd610CC9068e88727426b696293';
const DEFAULT_REGISTRY = '0x9639Ae4C7A8Fa9efE585738d516a3915DdD02aAD';
const BZZ_DECIMALS     = 16;
const POLL_MS          = 2_000;
const WINDOW_MS        = 10 * 60 * 1000;  // 10-minute sliding x-axis window

const DEFAULT_ACCOUNT = '0x10D9aBA7E0F5534757E85d1E35C46F170E8821e1';  // demo Safe

const params   = new URLSearchParams(window.location.search);
const account  = (params.get('account')  || DEFAULT_ACCOUNT).trim();
const registry = (params.get('registry') || DEFAULT_REGISTRY).trim();

// Explicit `?batches=` overrides registry discovery; keep the escape hatch
// for raw postage batches that aren't tracked as volumes.
const manualBatches = (params.get('batches') || '')
  .split(',').map(s => s.trim()).filter(Boolean);
const useRegistryDiscovery = manualBatches.length === 0;

const statusEl = document.getElementById('status');
const metaEl   = document.getElementById('meta');
const short    = h => h.slice(0, 6) + '…' + h.slice(-4);

function renderMeta(n) {
  const src = useRegistryDiscovery ? `registry=<b>${short(registry)}</b>` : `manual=<b>${manualBatches.length}</b>`;
  metaEl.innerHTML =
    `account=<b>${short(account)}</b>  ·  ${src}  ·  volumes=<b>${n}</b>  ·  poll=<b>${POLL_MS/1000}s</b>`;
}
renderMeta(0);

if (!window.RPC_URL) {
  statusEl.textContent = 'config.js missing or RPC_URL not set — run ./run.sh';
  statusEl.className = 'err';
  throw new Error('no RPC URL');
}

// viem's `http()` transport only speaks HTTP(S); if the caller supplied a
// websocket URL, switch to `webSocket()`. Without this the dashboard fails
// silently on wss:// URLs (multicall throws, status shows an error, no
// datapoints accumulate — matching the "balance not tracking" symptom).
const rpcUrl = window.RPC_URL;
const transport = /^wss?:\/\//i.test(rpcUrl) ? webSocket(rpcUrl) : http(rpcUrl);

const client = createPublicClient({
  chain: gnosis,
  transport,
});

const erc20Abi    = parseAbi(['function balanceOf(address) view returns (uint256)']);
const postageAbi  = parseAbi(['function remainingBalance(bytes32) view returns (uint256)']);
const registryAbi = parseAbi([
  'function getActiveVolumeCount() view returns (uint256)',
  'function getActiveVolumes(uint256 offset, uint256 limit) view returns ((bytes32 volumeId, address owner, address payer, address chunkSigner, uint64 createdAt, uint64 ttlExpiry, uint8 depth, uint8 status, bool accountActive)[])',
]);

// Forward-only series storage. Balance is a single series; per-volume
// histories are keyed by volumeId so new volumes appear automatically and
// retired/pruned ones are dropped.
const balanceSeries = { x: [], y: [] };
/** @type {Map<string, {x: Date[], y: number[]}>} */
const batchSeriesMap = new Map();

// Seed manual overrides (if any) so the Map has entries before the first
// poll returns, keeping insertion order stable for the color cycle.
for (const b of manualBatches) {
  batchSeriesMap.set(b.toLowerCase(), { x: [], y: [] });
}

/** Return the list of bytes32 batch IDs we want to chart this cycle. */
async function discoverBatches() {
  if (!useRegistryDiscovery) return manualBatches;
  // Two-call sequence: count, then fetch page of that size. Registries
  // with >500 active volumes would need paging; fine for the demo.
  const count = await client.readContract({
    address: registry, abi: registryAbi, functionName: 'getActiveVolumeCount',
  });
  if (count === 0n) return [];
  const vols = await client.readContract({
    address: registry, abi: registryAbi, functionName: 'getActiveVolumes',
    args: [0n, count],
  });
  const acct = account.toLowerCase();
  return vols
    .filter(v => v.owner.toLowerCase() === acct)
    .map(v => v.volumeId);
}

async function poll() {
  console.log('[poll] firing', new Date().toISOString());

  let vids;
  try {
    vids = await discoverBatches();
  } catch (e) {
    console.error('[poll] discovery error', e);
    statusEl.textContent = `registry discovery error: ${e.shortMessage || e.message}`;
    statusEl.className = 'err';
    return;
  }

  const contracts = [
    { address: BZZ_TOKEN, abi: erc20Abi, functionName: 'balanceOf', args: [account] },
    ...vids.map(b => ({
      address: POSTAGE_STAMP, abi: postageAbi, functionName: 'remainingBalance', args: [b],
    })),
  ];

  let results;
  try {
    results = await client.multicall({ contracts, allowFailure: true });
  } catch (e) {
    console.error('[poll] multicall error', e);
    statusEl.textContent = `RPC error: ${e.shortMessage || e.message}`;
    statusEl.className = 'err';
    return;
  }
  console.log('[poll] vids', vids.length, 'results', results);

  const now = new Date();
  const r0 = results[0];
  if (r0.status === 'success') {
    balanceSeries.x.push(now);
    balanceSeries.y.push(Number(formatUnits(r0.result, BZZ_DECIMALS)));
  }

  // Normalise to lowercase so Map lookups survive checksum drift between
  // the registry tuple and any manual URL override.
  const liveKeys = new Set(vids.map(v => v.toLowerCase()));
  for (let i = 0; i < vids.length; i++) {
    const r = results[i + 1];
    if (r.status !== 'success') continue;  // pruned / dead / RPC glitch
    const key = vids[i].toLowerCase();
    let series = batchSeriesMap.get(key);
    if (!series) {
      series = { x: [], y: [] };
      batchSeriesMap.set(key, series);
    }
    // remainingBalance is per-chunk wei (not whole BZZ). Don't divide by 1e16
    // or it visually rounds to zero. Show raw wei/chunk.
    series.x.push(now);
    series.y.push(Number(r.result));
  }

  // Drop volumes that disappeared (retired/pruned). Keep manual entries
  // even if they don't appear — the user asked for them explicitly.
  if (useRegistryDiscovery) {
    for (const key of batchSeriesMap.keys()) {
      if (!liveKeys.has(key)) batchSeriesMap.delete(key);
    }
  }

  renderMeta(batchSeriesMap.size);
  statusEl.className = '';
  statusEl.textContent =
    `the cards were last consulted at ${now.toLocaleTimeString()}  ·  ${balanceSeries.x.length} omens gathered  ·  next vision in ${POLL_MS/1000}s`;
  redraw();
}

// Spooky castle palette — keep in sync with index.html :root vars.
const THEME = {
  bgPaper: '#0b0814',
  bgPlot:  '#14101c',
  font:    '#d4c8a8',  // bone
  grid:    '#2a2233',  // stone
  zero:    '#3a2f44',
  tick:    '#9a8f78',
  title:   '#d9a860',  // candle
  // Trace colors — blood, candle, moss, mist, more blood — cycled per series.
  traces: ['#b8252b', '#d9a860', '#7fa650', '#9a8fb5', '#c45a8e', '#5fb3c0', '#d4c8a8'],
};

const PLOT_CONFIG = { responsive: true, displaylogo: false };
const STEP_LINE   = { shape: 'hv', width: 2 };
const AXIS_STYLE  = {
  gridcolor: THEME.grid, zerolinecolor: THEME.zero,
  tickfont:  { color: THEME.tick, family: 'Pirata One, serif' },
  titlefont: { color: THEME.title, family: 'Pirata One, serif', size: 13 },
  linecolor: THEME.grid,
};

// Build one subplot per series: row 1 = account BZZ balance, rows 2..N+1 = each batch's
// remainingBalance. Each subplot gets its own y-axis (independent scale) and its own
// x-axis (independent zoom). All traces share the same wall-clock timeline.
function redraw() {
  // Slice arrays so Plotly.react sees a fresh reference and re-renders. Without
  // this, mutating the same in-place arrays each cycle is treated as no-change.
  const series = [
    { x: balanceSeries.x.slice(), y: balanceSeries.y.slice(),
      label: `${short(account)} BZZ`, yTitle: 'BZZ' },
    ...Array.from(batchSeriesMap.entries()).map(([id, s]) => ({
      x: s.x.slice(), y: s.y.slice(),
      label: short(id), yTitle: `${short(id)}<br>wei/chunk`,
    })),
  ];

  const traces = series.map((s, i) => {
    const k = i === 0 ? '' : (i + 1);
    const color = THEME.traces[i % THEME.traces.length];
    return {
      x: s.x, y: s.y, name: s.label,
      line:   { ...STEP_LINE, color },
      marker: { size: 5, color, line: { color: THEME.bgPaper, width: 1 } },
      mode:   'lines+markers',
      xaxis:  `x${k}`, yaxis: `y${k}`,
      hoverlabel: { bgcolor: THEME.bgPaper, bordercolor: color,
                    font: { color: THEME.font, family: 'Pirata One, serif' } },
    };
  });

  const layout = {
    paper_bgcolor: THEME.bgPaper, plot_bgcolor: THEME.bgPlot,
    font: { color: THEME.font, family: 'Cormorant Garamond, serif' },
    grid: { rows: series.length, columns: 1, pattern: 'independent', roworder: 'top to bottom' },
    margin: { t: 20, l: 100, r: 20, b: 40 },
    showlegend: false,
  };
  // Sliding window: x-axis always shows [now - 10min, now] so new samples
  // enter from the right and old ones scroll off the left.
  const now    = Date.now();
  const xRange = [new Date(now - WINDOW_MS), new Date(now)];

  series.forEach((s, i) => {
    const k = i === 0 ? '' : (i + 1);
    layout[`xaxis${k}`] = { ...AXIS_STYLE, type: 'date', range: xRange };
    layout[`yaxis${k}`] = {
      ...AXIS_STYLE, title: s.yTitle,
      // Per-batch remainingBalance anchors at 0 so depletion is obvious;
      // wallet balance auto-fits so small variations remain visible.
      ...(i === 0 ? {} : { rangemode: 'tozero' }),
    };
  });

  // Resize the plot div so each subplot keeps a usable height.
  document.getElementById('plot').style.height = Math.max(80, 30 * series.length) + 'vh';

  Plotly.react('plot', traces, layout, PLOT_CONFIG);
}

redraw();
poll();
setInterval(poll, POLL_MS);
