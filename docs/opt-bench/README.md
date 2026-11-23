# opt-bench — host-side evidence for claude/opt-1

Run with `python3 -I <script>` from any directory. None of these run on an
Apple TV; they model the algorithms the PR changes. Device numbers still
have to come from the leader's own measurement.

| Script | What it shows |
|---|---|
| `poll_vs_wake.py` | Detection delay of the race-wait loops: fixed-interval polling (main) vs bounded wake (opt-1). |
| `joewake_model.py` | Threaded line-for-line model of `JoeWake`: 1 500 random interleavings of signal / timeout / cancellation; asserts no double resume, no hang, no lost wake-up. |
| `ytdecode.py <tvb-yt.json>` | Peak memory of decoding the TVB catalogue twice (main) vs stamps + once (opt-1). Python `json` is a stand-in for `JSONDecoder`. |
| `select_equiv.py` | Exhaustive proof that opt-1's `buildFromDisk` picks the same copy as main in all 144 state combinations. |
