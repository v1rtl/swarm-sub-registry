# Volume Dashboard

- index.html — Plotly + your app.js, dark theme                                                                                                                                             
- app.js — viem client → multicall → forward-only step plot, two stacked subplots (account BZZ on top, per-batch remainingBalance below)                                                    
- run.sh — writes config.js from `$RPC_URL` (Gnosis Chain), then `python3 -m http.server` 
- .gitignore — keeps config.js (which contains the RPC URL) out of git                                                                                                                      
                                                                                                            
Run: `cd dash && ./run.sh then open http://localhost:8080/`.                                                                                                             
Add batches via URL: `?batches=0xAAA…,0xBBB…`. Override account: `?account=0x…`.
