#!/usr/bin/env python3
"""Engine-neutral live-serving A/B (strix-halo-optimize benchmark type 3).

Drives any OpenAI-compatible /chat/completions endpoint identically, measuring
everything CLIENT-SIDE so llama-server and non-llama.cpp engines (e.g. Magnitude)
are compared on the same terms:
  ttft      = first streamed content/reasoning token
  pp t/s    = prompt_tokens / ttft            (includes queueing at conc > 1)
  tg t/s    = (completion_tokens - 1) / (t_last - t_first)
Each request also carries a unique codeword in its prompt and must repeat it back
(correctness: a wrong/missing codeword under concurrency = cross-request mixup).

Never point it at a server that is serving users: it saturates it (CONTRIBUTING: one GPU workload at a time).
Usage: engine-ab.py LABEL BASE_URL MODEL [--depths 2000,8000,32000] [--conc 1,2,4]
                    [--reps 3] [--gen 256] [--out DIR]
Writes DIR/LABEL.json and prints one line per (depth, conc) with median and spread.
"""
import argparse, json, os, random, statistics, threading, time, urllib.request

WORDS = ("river mountain server memory token cache slot kernel buffer stream "
         "matrix vector shader thread queue latency throughput compiler").split()


def prompt_for(depth_words, seed):
    rnd = random.Random(seed)
    code = f"CW-{seed:06d}-{rnd.randrange(10**6):06d}"
    filler = " ".join(rnd.choice(WORDS) for _ in range(depth_words))
    text = (f"Remember this codeword: {code}.\n\n{filler}\n\n"
            f"First write the codeword exactly once on its own line. Then write a long, numbered list "
            f"of short facts about computer memory hierarchies, continuing until stopped.")
    return text, code


def one(url, model, text, code, gen, out):
    body = {"model": model, "stream": True, "temperature": 0, "max_tokens": gen,
            "stream_options": {"include_usage": True},
            "chat_template_kwargs": {"enable_thinking": False},
            "messages": [{"role": "user", "content": text}]}
    req = urllib.request.Request(url + "/chat/completions", json.dumps(body).encode(),
                                 {"Content-Type": "application/json", "Authorization": "Bearer x"})
    t0 = time.time(); t_first = t_last = None; content = ""; usage = None; ntok_chunks = 0
    try:
        with urllib.request.urlopen(req, timeout=900) as r:
            for raw in r:
                line = raw.decode("utf8", "replace").strip()
                if not line.startswith("data:"):
                    continue
                data = line[5:].strip()
                if data == "[DONE]":
                    break
                ev = json.loads(data)
                if ev.get("usage"):
                    usage = ev["usage"]
                for ch in ev.get("choices") or []:
                    d = ch.get("delta") or {}
                    piece = (d.get("content") or "") + (d.get("reasoning_content") or "")
                    if piece:
                        now = time.time()
                        if t_first is None:
                            t_first = now
                        t_last = now; content += piece; ntok_chunks += 1
    except Exception as e:  # recorded, never raised: a failed request is a result
        out.append({"error": repr(e)[:200], "wall": time.time() - t0}); return
    pt = (usage or {}).get("prompt_tokens"); ct = (usage or {}).get("completion_tokens") or ntok_chunks
    ttft = (t_first - t0) if t_first else None
    tg = (ct - 1) / (t_last - t_first) if t_first and t_last and t_last > t_first and ct > 1 else None
    out.append({"prompt_tokens": pt, "completion_tokens": ct, "ttft": ttft,
                "pp": (pt / ttft) if pt and ttft else None, "tg": tg, "wall": time.time() - t0,
                "codeword_ok": code in content[:400], "head": content[:80]})


def med_spread(xs):
    xs = [x for x in xs if x is not None]
    if not xs:
        return None, None
    m = statistics.median(xs)
    return m, (100 * (max(xs) - min(xs)) / m if m else None)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("label"); ap.add_argument("url"); ap.add_argument("model")
    ap.add_argument("--depths", default="2000,8000,32000"); ap.add_argument("--conc", default="1,2,4")
    ap.add_argument("--reps", type=int, default=3); ap.add_argument("--gen", type=int, default=256)
    ap.add_argument("--out", default=os.path.expanduser("~/strix-optimize/results/engine-ab"))
    a = ap.parse_args(); os.makedirs(a.out, exist_ok=True)
    # warmup: compile/tune paths and load weights before anything is timed
    w = []; one(a.url, a.model, *prompt_for(200, 1), 32, w)
    print(f"[ab] {a.label} warmup: {w[0].get('error') or 'ok'}", flush=True)
    rows = []; seed = 1000
    for depth in [int(x) for x in a.depths.split(",")]:
        words = int(depth / 1.09)  # ~1.09 tokens/word (measured) for this vocabulary; actual count is recorded
        for conc in [int(x) for x in a.conc.split(",")]:
            reps = []
            for rep in range(a.reps):
                out = []; ths = []
                for i in range(conc):
                    seed += 1; text, code = prompt_for(words, seed)  # distinct prompts: no prefix-cache wins
                    ths.append(threading.Thread(target=one, args=(a.url, a.model, text, code, a.gen, out)))
                t0 = time.time(); [t.start() for t in ths]; [t.join() for t in ths]; wall = time.time() - t0
                ok = [r for r in out if "error" not in r]
                agg_tg = sum(r["completion_tokens"] for r in ok) / wall if ok else None
                reps.append({"wall": wall, "agg_tg_e2e": agg_tg, "requests": out})
                time.sleep(3)  # cooldown between reps
            reqs = [r for rp in reps for r in rp["requests"]]
            ok = [r for r in reqs if "error" not in r]
            ttft, ttft_sp = med_spread([r["ttft"] for r in ok])
            pp, pp_sp = med_spread([r["pp"] for r in ok])
            tg, tg_sp = med_spread([r["tg"] for r in ok])
            agg, agg_sp = med_spread([rp["agg_tg_e2e"] for rp in reps])
            ptoks = statistics.median([r["prompt_tokens"] for r in ok if r.get("prompt_tokens")] or [0])
            cw = sum(r["codeword_ok"] for r in ok)
            row = {"depth_target": depth, "prompt_tokens": ptoks, "conc": conc, "ttft_med": ttft,
                   "ttft_spread_pct": ttft_sp, "pp_med": pp, "pp_spread_pct": pp_sp, "tg_med": tg,
                   "tg_spread_pct": tg_sp, "agg_e2e_med": agg, "agg_spread_pct": agg_sp,
                   "codeword_ok": f"{cw}/{len(reqs)}", "errors": len(reqs) - len(ok), "reps": reps}
            rows.append(row)
            f = lambda v, d=1: "n/a" if v is None else f"{v:.{d}f}"
            print(f"[ab] {a.label} depth~{ptoks} conc={conc}: ttft {f(ttft,2)}s (±{f(ttft_sp,0)}%) "
                  f"pp {f(pp)} t/s (±{f(pp_sp,0)}%) tg {f(tg)} t/s (±{f(tg_sp,0)}%) "
                  f"agg {f(agg)} t/s (±{f(agg_sp,0)}%) codeword {cw}/{len(reqs)} err {len(reqs)-len(ok)}",
                  flush=True)
    json.dump({"label": a.label, "url": a.url, "model": a.model, "gen": a.gen, "rows": rows},
              open(os.path.join(a.out, f"{a.label}.json"), "w"), indent=1)


if __name__ == "__main__":
    main()
