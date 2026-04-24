import { createPublicClient, http, parseAbi, formatUnits } from 'https://esm.sh/viem@2.21.40';
import { sepolia } from 'https://esm.sh/viem@2.21.40/chains';

// Sepolia Swarm testnet deployment (from ~/repo/storage-incentives/testnet_deployed.json)
const BZZ_TOKEN     = '0x543dDb01Ba47acB11de34891cD86B675F04840db';
const POSTAGE_STAMP = '0xcdfdC3752caaA826fE62531E0000C40546eC56A6';
const BZZ_DECIMALS  = 16;
const POLL_MS       = 2_000;
const WINDOW_MS     = 10 * 60 * 1000;  // 10-minute sliding x-axis window

const DEFAULT_ACCOUNT = '0x1b5BB8C4Ea0E9B8a9BCd91Cc3B81513dB0bA8766';

const params  = new URLSearchParams(window.location.search);
const account = (params.get('account') || DEFAULT_ACCOUNT).trim();
const batches = (params.get('batches') || '')
  .split(',').map(s => s.trim()).filter(Boolean);

const statusEl = document.getElementById('status');
const metaEl   = document.getElementById('meta');
const short    = h => h.slice(0, 6) + '…' + h.slice(-4);

metaEl.innerHTML =
  `account=<b>${short(account)}</b>  ·  batches=<b>${batches.length}</b>  ·  poll=<b>${POLL_MS/1000}s</b>`;

if (!window.SEP_RPC_URL) {
  statusEl.textContent = 'config.js missing or SEP_RPC_URL not set — run ./run.sh';
  statusEl.className = 'err';
  throw new Error('no RPC URL');
}

const client = createPublicClient({
  chain: sepolia,
  transport: http(window.SEP_RPC_URL),
});

const erc20Abi   = parseAbi(['function balanceOf(address) view returns (uint256)']);
const postageAbi = parseAbi(['function remainingBalance(bytes32) view returns (uint256)']);

// Forward-only series storage. One series for the account BZZ balance, one per batch.
const balanceSeries = { x: [], y: [] };
const batchSeries   = batches.map(b => ({ x: [], y: [], id: b }));

async function poll() {
  const contracts = [
    { address: BZZ_TOKEN, abi: erc20Abi, functionName: 'balanceOf', args: [account] },
    ...batches.map(b => ({
      address: POSTAGE_STAMP, abi: postageAbi, functionName: 'remainingBalance', args: [b],
    })),
  ];

  console.log('[poll] firing', new Date().toISOString());
  let results;
  try {
    results = await client.multicall({ contracts, allowFailure: true });
  } catch (e) {
    console.error('[poll] multicall error', e);
    statusEl.textContent = `RPC error: ${e.shortMessage || e.message}`;
    statusEl.className = 'err';
    return;
  }
  console.log('[poll] results', results);

  const now = new Date();
  const r0 = results[0];
  if (r0.status === 'success') {
    // ERC20 balanceOf -> total BZZ held; scale by token decimals.
    balanceSeries.x.push(now);
    balanceSeries.y.push(Number(formatUnits(r0.result, BZZ_DECIMALS)));
  }
  for (let i = 0; i < batches.length; i++) {
    const r = results[i + 1];
    if (r.status === 'success') {
      // remainingBalance is per-chunk wei (not whole BZZ). Don't divide by 1e16
      // or it visually rounds to zero. Show raw wei/chunk.
      batchSeries[i].x.push(now);
      batchSeries[i].y.push(Number(r.result));
    }
  }

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
    ...batchSeries.map(s => ({
      x: s.x.slice(), y: s.y.slice(),
      label: short(s.id), yTitle: `${short(s.id)}<br>wei/chunk`,
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
