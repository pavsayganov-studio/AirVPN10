# DPI research digest — Raketa (state of 2026-10-14)

Purpose: everything learned about YouTube DPI bypass on macOS so that no later conversation
has to research it again. Read this before any DPI work; research only what is newer than the
date above. Confidence labels: **[measured]** seen in the person's own log, **[source]** read in
primary code/docs this session, **[summary]** from a secondary summary (re-read the original
before quoting), **[inferred]** my reasoning.

## 1. Where things stand

- App v0.13.4 (patch applied by the person together with the "context pack"). The DPI route
  uses a user-level `ciadpi` (ByeDPI, pinned commit `ba53229`, 2026-03-26 = still upstream HEAD
  on 2026-10-10) as local SOCKS5; sing-box routes only YouTube domains to it (System Proxy, not TUN).
- **[measured] Log 2026-10-09 (v0.13.3, 68 candidates):** system resolver answers a Google
  address; DoH 1.1.1.1 no answer, DoH 8.8.4.4 answers; `direct, system DNS` 3/19 (15 x curl 28,
  1 x curl 6); `direct, DoH addresses` 3/19; `proxy, no desync` 3/19; every candidate
  `probe fail 28x2`. Conclusions: the DNS hypothesis of v0.13.3 was wrong on this network; the
  filter is on the wire; the harness is fine (the same 3 hosts pass through ciadpi with no
  desync); no candidate can be told from the control.
- **Not yet known:** *where* on the wire (SNI-based vs IP/route block) — the v0.13.4 search log
  answers it with `wire:` / `wire verdict:` lines. **Read that verdict first in the next log.**
  Which 3 of the 19 hosts pass is not recorded.

## 2. Why plain cuts are dead (and fakes are not available)

- **[source] ciadpi on macOS has no fake packets.** `FAKE_SUPPORT` is `__linux__ || _WIN32`.
  Linux sends the fake with `vmsplice(SPLICE_F_GIFT)` + `splice`, then rewrites the page so the
  retransmit carries the real bytes; Windows uses `TransmitFile` from a temp file. Both rely on
  zero-copy; XNU `sendfile()` is unverified and probably copies into mbufs (then the fake would
  stay in the send buffer and corrupt the stream). The README documents no `-Z`/`-W`; they are
  hidden options added for non-Linux (wait after each part / ms between parts). `--md5sig`,
  `-Y` (drop SACK), `--fake`, `-t` (TTL of the fake) are Linux-only too.
- **[source] The maintained zapret community list agrees.** Flowseal/zapret-discord-youtube
  (528 commits, last 2026-10-01): 21 TCP/443 rules for the YouTube host list across 21 of 22
  `general*.bat`; **every one** has `fake`, `seqovl` (TCP sequence overlap) or `hostfakesplit`;
  none is a plain split/disorder; all but one set `--ip-id=zero`. Catalogue (count x rule):
  - 3 x `hostfakesplit` + `fooling=ts` + `hostfakesplit-mod=host=www.google.com` (+1 without ip-id, +1 repeats=4)
  - 2 x `fake` repeats=6 `fooling=ts` `fake-tls=tls_clienthello_www_google_com.bin`
  - 2 x `multisplit` `seqovl=681` `split-pos=1` `seqovl-pattern=tls_clienthello_www_google_com.bin` (the default `general.bat`)
  - 1 each: `fake,fakedsplit` ts; `fake,multisplit` seqovl681 ts repeats=8; `multisplit` seqovl652 pos=2;
    `multisplit` seqovl679 pos=2,sniext+1; `fake,hostfakesplit` fake-tls-mod=rnd,dupsid,sni=www.google.com altorder=1;
    `fake,multisplit` badseq(+1000) repeats=6; `fake` badseq(+2) repeats=6 (with and without the google .bin);
    `fake,fakedsplit` badseq(+2) pos=1 repeats=8; `fake,multisplit` seqovl681 badseq(+10000000) repeats=8;
    `fake,multidisorder` pos=1,midsld repeats=11 badseq.
  - **Inject-only strategies** (need no suppression of the real packet, so a raw injector can do
    them): `fake` + `ts`/`badseq`, `hostfakesplit`-like fake host segment. `seqovl` and
    `multisplit` replace the real packet and need packet *interception* — not available on macOS
    (no divert sockets; pf has no divert-packet).
  - Payloads: `bin/tls_clienthello_www_google_com.bin` (fake ClientHello, SNI www.google.com),
    `quic_initial_www_google_com.bin`. YouTube list: `lists/list-google.txt` (youtube.com,
    googlevideo.com, ytimg.com, ggpht via yt3/yt4, googleapis jnn-pa/youtubei, youtu.be, ...).
- **[summary] TSPU reassembles TCP now.** FOCI 2025 (Niere et al., ECH in censorship
  circumvention): TCP segmentation alone or TLS-record fragmentation alone no longer beat the
  ECH block, both combined still did. Iran, June 2026 (net4people report): DPI reassembles and
  defeats 10-30 B fragments with 10-20 ms pauses. GFW 2026 lab tests: 1-5 B fragments still
  work there. (An address that is blocked by IP/route is beyond any ClientHello trick - [inferred].)
- **[inferred]** So all 68 v0.13.3 lines and the 10 v0.13.4 lines are tripwires, not a plan.

## 3. What actually works on macOS: SpoofDPI's way

- **[source] xvzc/SpoofDPI v1.5.4 (`eb07db9`, 2026-09-28).** `internal/desync/tls.go`
  `sendFakePackets`: for `FakeCount` rounds, writes the fake ClientHello (split into segments)
  with `WriteCraftedPacket(ctx, conn.LocalAddr(), conn.RemoteAddr(), oTTL, payload)`.
  `internal/packet/tcp_writer.go`: builds IP+TCP with gopacket, **random `Seq` and random `Ack`**,
  PSH|ACK, TTL = argument, checksums recomputed, written through **pcap (BPF) — needs root**.
  `internal/packet/tcp_sniffer.go`: learns hop count from the TTL of the SYN-ACK
  (`estimateHops`, GoodbyeDPI logic); `GetOptimalTTL = max(hops, 2) - 1`, default TTL 64 when
  unknown. Then the real hello is sent with per-byte SNI splits and TTL=1 "lazy" pieces.
  Go 1.2x: cannot run on macOS 10.13, so it can be a model, not a dependency.
- **[inferred] A fake with random seq/ack is accepted by the filter and ignored by the server**
  (out of window). Zapret's `badseq` is the same idea but *near* the real seq (+2, +1000,
  +10000000); `ts` lowers the TCP timestamp so the server's PAWS rejects it. Whether TSPU
  places a near-seq fake into its reassembly buffer but drops a random-seq one is the main open
  question for the experiment.

## 4. DNS (what the sources say)

- **[source/summary]** Since 2026-02 YouTube names are gone from Russia's national DNS and
  YouTube is blocked (Wikipedia "Blocking of YouTube in Russia", Mediazona 2026-04-07);
  foreign public resolvers stayed reachable then. On 2026-07-03 8.8.8.8 stopped answering over
  TCP (DoH/DoT/TCP 53) while 8.8.4.4 kept working (zapret wiki note
  "google-dns-8888-block-july-2026"). **[measured]** 1.1.1.1 DoH gave no answer on the
  person's network.
- **Policy in v0.13.4:** system resolver first; DoH (8.8.4.4, 1.0.0.1, 9.9.9.9, 1.1.1.1, 8.8.8.8
  by literal IP, so no SNI to match) only when the system answer is unusable. No resolver
  bypasses an SNI filter. [summary] One 2026 Iran study found encrypted-DNS censorship ineffective.

## 5. Path A (SUPERSEDED on 2026-10-14 by section 8: sing-box 1.14 already contains it)

Gate: the v0.13.4 log's `wire verdict:`
- `SNI filter` -> proceed (the filter reads the name; only fakes can help).
- `address or route blocked` -> path A is pointless: go to path B (below) after asking.
- `YouTube address answers` -> nothing to bypass on that network right now; ask for another log.
- `fails for both names` -> inconclusive; the lab below separates the cases, proceed.

**Step 1 — standalone lab, outside the app and outside ciadpi** (`tools/rkfake-lab.c`, macOS C99,
`clang -O2 -mmacosx-version-min=10.13`, built as a CI artifact, run by the person with `sudo`):
1. `getaddrinfo` the YouTube address (or `-i IP`), `-n NAME` for the SNI (default www.youtube.com).
2. For each variant: new TCP socket, `connect()`, **inject fake(s) with a raw socket
   (`IP_HDRINCL`) before the real hello**, send the real ClientHello (built from the embedded
   google .bin template with SNI and 5 length fields patched), wait <=4 s for the first server
   bytes. Result per variant: `ServerHello` (0x16 0x03) / `RST` / `timeout` / `connect-fail`.
3. Variants: baseline (no fake, expect timeout); random seq+ack with TTL in {2,3,4,5,6,8,10,12};
   random seq no TTL limit; bad TCP checksum; repeats 1 and 6; fake SNI google vs random; real
   hello whole vs split at SNI (TCP_NODELAY, 10 ms pause). Seq-near variants (+2, +1000,
   +10000000, `ts`) need the real seq/ack: options (a) parse `sysctl net.inet.tcp.pcblist64`
   (`xtcpcb64`: snd_nxt/rcv_nxt; layout differs between 10.13 and 12), (b) sniff own SYN/SYN-ACK
   with libpcap, (c) skip. Start with random-seq variants, add (a) or (b) only if needed.
4. macOS raw-socket quirk to test, not assume: on BSD/XNU `ip_len`/`ip_off` in a hand-built
   `struct ip` are in **host** byte order; checksum of TCP is ours. Needs root. The person
   returns the printed table; no app change until it shows `ServerHello` for some variant.

**Step 2 — only if the lab shows a working variant:** root helper `rkinject` (the lab's core),
started in the same administrator-privileges script that already starts sing-box in `ytStart`
(no extra password prompt for the YouTube mode); a small patch to ciadpi `desync.c` for
`__APPLE__` that makes `send_fake()` ask the helper over 127.0.0.1 UDP (4-tuple, mode, TTL,
repeats) and then send the real bytes normally; CI applies `dpi/ciadpi-macos-fake.patch` and
falls back to vanilla ciadpi if the patched build fails; candidates in `DPICuratedLines()` get
`-f` lines. Open problem: the search harness spawns a throw-away ciadpi per strategy — it needs
the helper up too (one prompt per search, or a long-lived helper). Constraints: CPU first (no
timers/polling), no TUN, macOS 10.13 must work, VLESS/Reality untouched.

**Path B (fallback, needs the person's explicit OK because it touches routing):** in the YouTube
mode config, route the YouTube domain list to the existing VLESS outbound instead of ciadpi
(`domain_suffix` rule in `youtubeOnlyConfig`). Works wherever the VPN works; costs VPN
traffic; is not DPI bypass.

## 6. Do not

- Re-propose the ByeByeDPI list, "adapted" lines, Xray-style tiny fragments, or DoH as a fix.
- Suggest TUN, or touch VLESS/Reality/routing, unasked.
- Claim a fake works on macOS before the lab table says so.
- Treat summaries from corpus.lantern.io as primary sources (they are LLM-extracted).
- Add more ciadpi stream-cutting lines or re-propose them: every one is recorded as non-working on
  macOS (section 8). Build the `rkfake-lab.c` / `rkinject` helper of section 5: sing-box does it.

## 7. Refresh commands (when something may have changed)

```
git clone --depth 30 https://github.com/Flowseal/zapret-discord-youtube /tmp/zdy
grep -a -h -o -- '--filter-tcp=443 --hostlist="%LISTS%list-google.txt"[^^]*' /tmp/zdy/general*.bat | sort | uniq -c | sort -rn
git clone --depth 1 https://github.com/hufrea/byedpi /tmp/byedpi && git -C /tmp/byedpi log -1 --format='%h %ad' --date=short
git clone --depth 1 https://github.com/xvzc/SpoofDPI /tmp/spoofdpi   # internal/desync/tls.go, internal/packet/
```


## 8. Update 2026-10-14 (v0.14.2): what is recorded as not working, and what replaces it

- **Recorded as NOT working on macOS: every ciadpi stream-cutting strategy ("M").** **[measured]** 0 of 68
  (v0.13.3 log, both controls 3/19 = the same as no bypass), the v0.13.4/0.13.5 candidates (10 lines, one
  per mechanism) did not help either according to the person (no new log was sent with this sprint);
  ciadpi has no fake packets on macOS (section 2). The M lines stay only as tripwires / manual choice.
  Section 2's finding that the maintained zapret lists contain no plain cut for YouTube is the same fact.
- **Upstream unchanged since 2026-10-10 [measured with `git ls-remote` on 2026-10-14]:** ByeDPI HEAD is
  still `ba53229` (2026-03-26; the last tag v0.17.3 is `7efde1b` from 2025), SpoofDPI v1.5.4 has no commit
  after its release. Nothing new to port from either.
- **NEW [source: docs/configuration/route/rule_action.md, shared/tls.md and common/tlsspoof/*.go,
  route/conn.go in SagerNet/sing-box v1.14.3]:** sing-box 1.14.0 added `tls_spoof` + `tls_spoof_method`
  (route-options action) - "inject a forged TLS ClientHello carrying this SNI before the real one", Linux,
  macOS and Windows, **root required** - and the pre-existing `tls_fragment` / `tls_record_fragment`
  (mutually exclusive: `sing-box check` refuses both, **[measured]**). Methods on macOS: `wrong-sequence`
  (default), `wrong-checksum`, `wrong-ack`, `wrong-md5`; `wrong-timestamp` is not available on macOS.
  Implementation on macOS = exactly the lab of section 5: IPv4 raw socket with `IP_HDRINCL` (fields in host
  byte order), the connection's sequence/ack read from the kernel's `net.inet.tcp.pcblist_n` (the
  `xtcpcb_n` size is assumed 384 bytes for Darwin < 22 and 408 from Darwin 22), the fake sent on the first
  Write of the real ClientHello. `ConnectionManager` wraps the dialed direct TCP connection: fragmentation
  first, spoof outside it. So the YouTube traffic must go `direct` with the options - not through ciadpi.
- **Candidates built from it (DPIEngine.m, labels S1-S8):** S1 fake www.google.com wrong-sequence
  (~ zapret `fake` + `badseq`); S2 = S1 + TLS-record fragmentation; S3 = S1 + TCP fragmentation;
  S4 wrong-md5 (~ `md5sig`); S5 wrong-checksum (~ `badsum`); S6 wrong-ack (~ `badack`); S7 S1 with the fake
  name ya.ru (an allowed name for whitelist-style filters - **[inferred]**, a probe); S8 TCP fragmentation
  only. `ts` fooling (the most common one in the zapret list) has no macOS method in sing-box. The
  `seqovl`/`multisplit` family needs packet interception and stays out of reach.
- **How they are tested:** the search starts ONE root sing-box (one password prompt) with a SOCKS inbound per
  candidate, each with its own route-options rule, and runs the same probes / battery / success rule as for
  ciadpi; afterwards the log gets a `sb log:` block with the spoof/error lines of that sing-box. In YouTube
  mode an S strategy is one rule (`domain_suffix` + route-options) and traffic stays `direct`.
- **Not known yet / risks:** whether TSPU accepts these fakes (the whole point of the experiment);
  whether the `pcblist_n` offsets are right on macOS 10.13 (Darwin 17 - unverified; a failure shows as a
  `tls_spoof` error line in the `sb log:` block and as failing S candidates, never as a silent success);
  whether any S passes. Gate for the next step: read the `#S1..#S8` lines and the `sb log:` block of the
  next `dpi_search.log`. All S fail with spoof errors -> the 10.13 offsets are the suspect; all S fail
  without errors -> the fakes do not fool this filter, go to path B (needs the person's OK).
