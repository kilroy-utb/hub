#!/usr/bin/env python3
# =============================================================================
#  GX10 (GB10) × Strata 真實 prompt benchmark
#
#  用法：
#    python3 gx10-bench.py                      # 完整測試
#    python3 gx10-bench.py --quick              # 快測（跳過長上下文與重複量測）
#    python3 gx10-bench.py --repeat 3           # 每個 case 重跑 3 次取中位數
#    python3 gx10-bench.py --out report.json    # 存報告
#    python3 gx10-bench.py --compare old.json   # 跟舊報告比較
#    python3 gx10-bench.py --no-stream          # 不用串流（測不出 TTFT）
#
#  環境變數：
#    PORT / API_KEY / MODEL / BENCH_TIMEOUT
# =============================================================================
"""真實 prompt 測試：量 TTFT、prefill、decode、CPU 忙碌度、記憶體，並檢查答案品質。"""

import argparse
import json
import os
import re
import statistics
import sys
import threading
import time
import urllib.error
import urllib.request

# ── 門檻（跟 gx10-verify.sh 對齊，可用 CLI 覆寫）────────────────────────
DEFAULT_THRESHOLDS = {
    "ttft": 3.0,        # 秒，首字等待
    "prefill": 800.0,   # tok/s
    "decode": 45.0,     # tok/s
    "max_cpu": 20.0,    # %，全 GPU 常駐時應接近 0
    "min_mem": 10.0,    # GiB
}

# ── 工具 ────────────────────────────────────────────────────────────────


def mem_available_gib() -> float:
    try:
        with open("/proc/meminfo", encoding="utf-8") as handle:
            for line in handle:
                if line.startswith("MemAvailable:"):
                    return int(line.split()[1]) / 1048576
    except OSError:
        pass
    return -1.0


def cpu_snapshot() -> tuple:
    """回傳 (所有 cpu 的 jiffies 總和, idle jiffies)。"""
    try:
        with open("/proc/stat", encoding="utf-8") as handle:
            parts = handle.readline().split()
        values = [int(x) for x in parts[1:]]
        idle = values[3] + (values[4] if len(values) > 4 else 0)
        return sum(values), idle
    except (OSError, ValueError, IndexError):
        return None, None


def cpu_busy_between(start: tuple, end: tuple) -> float:
    total0, idle0 = start
    total1, idle1 = end
    if not total0 or total1 is None:
        return -1.0
    dt = total1 - total0
    di = idle1 - idle0
    if dt <= 0:
        return -1.0
    return 100.0 * (dt - di) / dt


class MemSampler(threading.Thread):
    """背景取樣 MemAvailable，抓請求期間的最低值。"""

    def __init__(self, interval: float = 0.2):
        super().__init__(daemon=True)
        self.interval = interval
        self.min_avail = mem_available_gib()
        self.stop_flag = threading.Event()

    def run(self):
        while not self.stop_flag.is_set():
            value = mem_available_gib()
            if value >= 0:
                self.min_avail = min(self.min_avail, value)
            self.stop_flag.wait(self.interval)


def nvidia_info() -> dict:
    info = {}
    try:
        out = os.popen("nvidia-smi --query-gpu=name,driver_version,memory.total "
                       "--format=csv,noheader 2>/dev/null").read().strip()
        if out:
            parts = [p.strip() for p in out.split(",")]
            if len(parts) >= 1:
                info["gpu"] = parts[0]
            if len(parts) >= 2:
                info["driver"] = parts[1]
            if len(parts) >= 3:
                info["mem_total"] = parts[2]
    except OSError:
        pass
    return info


# ── 呼叫引擎 ────────────────────────────────────────────────────────────


class EngineError(RuntimeError):
    pass


def call_engine(base_url: str, prompt: str, max_tokens: int, api_key: str,
                model: str, timeout: float, stream: bool,
                system: str = "", prefill: str = "") -> dict:
    """送一次請求，回傳量測結果 dict。"""
    messages = []
    if system:
        messages.append({"role": "system", "content": system})
    messages.append({"role": "user", "content": prompt})

    payload = {
        "model": model,
        "messages": messages,
        "max_tokens": max_tokens,
        "reasoning_effort": "none",
        "stream": bool(stream),
    }
    if prefill:
        payload["prefill"] = prefill

    headers = {"Content-Type": "application/json"}
    if api_key:
        headers["Authorization"] = "Bearer " + api_key

    body = json.dumps(payload).encode("utf-8")
    request = urllib.request.Request(base_url.rstrip("/") + "/v1/chat/completions",
                                     data=body, headers=headers, method="POST")

    sampler = MemSampler()
    sampler.start()
    cpu0 = cpu_snapshot()
    t0 = time.perf_counter()
    t_first_byte = None
    t_first_token = None
    text = ""
    usage = {}
    finish_reason = ""

    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            if stream:
                for raw in response:
                    if t_first_byte is None:
                        t_first_byte = time.perf_counter()
                    line = raw.decode("utf-8", "replace").strip()
                    if not line.startswith("data:"):
                        continue
                    chunk = line[5:].strip()
                    if chunk == "[DONE]":
                        break
                    try:
                        obj = json.loads(chunk)
                    except json.JSONDecodeError:
                        continue
                    if "usage" in obj and obj["usage"]:
                        usage = obj["usage"]
                    choices = obj.get("choices") or []
                    if not choices:
                        continue
                    choice = choices[0]
                    finish_reason = choice.get("finish_reason") or finish_reason
                    delta = choice.get("delta") or {}
                    piece = delta.get("content") or ""
                    if piece and t_first_token is None:
                        t_first_token = time.perf_counter()
                    text += piece
            else:
                raw = response.read()
                t_first_byte = time.perf_counter()
                obj = json.loads(raw.decode("utf-8", "replace"))
                usage = obj.get("usage") or {}
                choices = obj.get("choices") or []
                if choices:
                    message = choices[0].get("message") or {}
                    text = message.get("content") or ""
                    finish_reason = choices[0].get("finish_reason") or ""
                t_first_token = t_first_byte
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", "replace")[:300]
        raise EngineError("HTTP %s：%s" % (exc.code, detail)) from exc
    except Exception as exc:  # noqa: BLE001
        raise EngineError("%s：%s" % (type(exc).__name__, exc)) from exc
    finally:
        t1 = time.perf_counter()
        cpu1 = cpu_snapshot()
        sampler.stop_flag.set()
        sampler.join(timeout=2)

    prompt_tokens = usage.get("prompt_tokens") or 0
    completion_tokens = usage.get("completion_tokens") or 0
    if not completion_tokens:
        completion_tokens = max(1, len(text) // 3)

    ttft = (t_first_token - t0) if t_first_token else None
    total = t1 - t0
    decode_window = (t1 - t_first_token) if t_first_token else total
    decode_tps = completion_tokens / decode_window if decode_window > 0 else 0.0
    prefill_tps = prompt_tokens / ttft if (ttft and prompt_tokens) else 0.0

    result = {
        "text": text,
        "chars": len(text),
        "prompt_tokens": prompt_tokens,
        "completion_tokens": completion_tokens,
        "ttft": round(ttft, 3) if ttft else None,
        "total_s": round(total, 3),
        "prefill_tps": round(prefill_tps, 1),
        "decode_tps": round(decode_tps, 1),
        "cpu_busy": round(cpu_busy_between(cpu0, cpu1), 1),
        "mem_min": round(sampler.min_avail, 1),
        "finish_reason": finish_reason,
    }

    # 伺服器端計時（如果引擎有提供，以它為準）
    server = fetch_status(base_url, api_key, timeout)
    if server:
        result["server"] = server
        if server.get("prompt_per_second"):
            result["prefill_tps"] = round(float(server["prompt_per_second"]), 1)
        if server.get("predicted_per_second"):
            result["decode_tps"] = round(float(server["predicted_per_second"]), 1)
    return result


def fetch_status(base_url: str, api_key: str, timeout: float) -> dict:
    headers = {}
    if api_key:
        headers["Authorization"] = "Bearer " + api_key
    try:
        request = urllib.request.Request(base_url.rstrip("/") + "/v1/status",
                                         headers=headers)
        with urllib.request.urlopen(request, timeout=min(timeout, 15)) as response:
            data = json.loads(response.read().decode("utf-8", "replace"))
    except Exception:  # noqa: BLE001
        return {}
    if not isinstance(data, dict):
        return {}
    timings = data.get("timings")
    return timings if isinstance(timings, dict) else data


def fetch_models(base_url: str, api_key: str, timeout: float) -> str:
    headers = {}
    if api_key:
        headers["Authorization"] = "Bearer " + api_key
    try:
        request = urllib.request.Request(base_url.rstrip("/") + "/v1/models",
                                         headers=headers)
        with urllib.request.urlopen(request, timeout=min(timeout, 15)) as response:
            data = json.loads(response.read().decode("utf-8", "replace"))
        return data["data"][0]["id"]
    except Exception:  # noqa: BLE001
        return ""


# ── 測試案例 ────────────────────────────────────────────────────────────

LONG_SOURCE = (
    "以下是一份內部技術文件，請仔細閱讀後回答最後的問題。\n"
    + ("Strata 是一套以 llama.cpp 為基礎的推論引擎，針對 NVIDIA GB10 與 ARM64 "
       "平台做了最佳化。它支援 INT8 KV cache、多種量化格式，以及 MTP "
       "（Multi-Token Prediction）草稿加速。在 GB10 上，模型的 24,576 個 expert "
       "必須全數常駐於統一記憶體中，否則會退化為 CPU 推論，速度落差約四倍。\n") * 40
    + "\n請用三個要點總結這份文件的核心內容，並說明 expert 常駐的重要性。"
)

REASONING_QUESTION = (
    "一隻烏鴉把一隻 5 升的桶裝滿了水，桶上有一個 3 升的桶。請問要怎麼量出恰好 4 升的水？"
    "請只列出步驟，不要多作解釋。"
)

CODE_QUESTION = (
    "用 Python 寫一個函式 `def is_palindrome(s: str) -> bool`，"
    "判斷字串是否為回文（忽略大小寫與非字母數字字元）。"
    "只回程式碼，不要解釋。"
)

CASES = [
    {
        "id": "ttft",
        "name": "首字延遲",
        "prompt": "用一句話說明什麼是遞迴。",
        "max_tokens": 64,
        "group": "核心",
        "check": "nonempty",
    },
    {
        "id": "decode",
        "name": "長輸出解碼",
        "prompt": "詳細說明 Python 的 GIL 是什麼，以及它對多執行緒程的影響。",
        "max_tokens": 512,
        "group": "核心",
        "check": "nonempty",
    },
    {
        "id": "code",
        "name": "程式碼生成",
        "prompt": CODE_QUESTION,
        "max_tokens": 512,
        "group": "品質",
        "check": "code",
    },
    {
        "id": "zh",
        "name": "繁體中文",
        "prompt": "請用繁體中文寫一段 150 字左右，說明台灣的四季氣候特色。",
        "max_tokens": 512,
        "group": "品質",
        "check": "chinese",
    },
    {
        "id": "reasoning",
        "name": "邏輯推理",
        "prompt": REASONING_QUESTION,
        "max_tokens": 256,
        "group": "品質",
        "check": "steps",
    },
    {
        "id": "instruction",
        "name": "指令遵循",
        "prompt": "請只輸出三個以逗號分隔的英文單字，代表顏色，不要任何其他文字。",
        "max_tokens": 32,
        "group": "品質",
        "check": "short",
    },
    {
        "id": "longctx",
        "name": "長上下文",
        "prompt": LONG_SOURCE,
        "max_tokens": 256,
        "group": "壓力",
        "check": "nonempty",
        "slow": True,
    },
    {
        "id": "cache",
        "name": "提示快取命中",
        "prompt": LONG_SOURCE + "\n另外請列出三個關於 PLE n-gram 表的技術重點。",
        "max_tokens": 256,
        "group": "壓力",
        "check": "nonempty",
        "slow": True,
        "cache_probe": True,
    },
]

CHECKERS = {
    "nonempty": lambda t: (len(t.strip()) >= 8, "有內容" if t.strip() else "空回應"),
    "code": lambda t: (bool(re.search(r"def\s+is_palindrome", t)), "有 is_palindrome 定義"
                       if re.search(r"def\s+is_palindrome", t) else "找不到函式定義"),
    "chinese": lambda t: (
        len(re.findall(r"[\u4e00-\u9fff]", t)) >= 40,
        "中文字元 %d" % len(re.findall(r"[\u4e00-\u9fff]", t))),
    "steps": lambda t: (
        len(re.findall(r"[0-9①-⑩]|[一二三四五]|\d\.", t)) >= 2,
        "有 %d 個步驟標記" % len(re.findall(r"[0-9①-⑩]|[一二三四五]|\d\.", t))),
    "short": lambda t: (
        (len(t.strip()) <= 200 and ("," in t or "，" in t)),
        "長度 %d" % len(t.strip())),
}


# ── 執行 ────────────────────────────────────────────────────────────────


def run_case(case: dict, base_url: str, api_key: str, model: str, timeout: float,
             stream: bool, repeat: int) -> dict:
    runs = []
    error = ""
    warm = None
    if case.get("cache_probe"):
        # 同一個 prompt 送兩次：第一次冷、第二次看快取有沒有命中
        try:
            warm = call_engine(base_url, case["prompt"], case["max_tokens"],
                               api_key, model, timeout, stream)
        except EngineError as exc:
            error = str(exc)
    if not error:
        for attempt in range(repeat):
            try:
                runs.append(call_engine(base_url, case["prompt"], case["max_tokens"],
                                        api_key, model, timeout, stream))
            except EngineError as exc:
                error = str(exc)
                break
    if not runs:
        return {"id": case["id"], "name": case["name"], "group": case["group"],
                "error": error or "無回應", "runs": []}

    def median(key):
        values = [r[key] for r in runs if r.get(key) is not None]
        return round(statistics.median(values), 2) if values else None

    best = min((r["decode_tps"] for r in runs), default=0.0)
    check_id = case.get("check", "nonempty")
    checker = CHECKERS.get(check_id, CHECKERS["nonempty"])
    passed, note = checker(runs[-1]["text"])

    result = {
        "id": case["id"],
        "name": case["name"],
        "group": case["group"],
        "runs": len(runs),
        "error": error,
        "ttft": median("ttft"),
        "prefill_tps": median("prefill_tps"),
        "decode_tps": median("decode_tps"),
        "decode_best": round(best, 1),
        "prompt_tokens": runs[-1]["prompt_tokens"],
        "completion_tokens": median("completion_tokens"),
        "total_s": median("total_s"),
        "cpu_busy": max(r["cpu_busy"] for r in runs),
        "mem_min": round(min(r["mem_min"] for r in runs), 1),
        "check": check_id,
        "check_passed": bool(passed),
        "check_note": note,
        "sample": runs[-1]["text"][:300],
    }
    if warm:
        result["cache_cold_prefill"] = warm["prefill_tps"]
        result["cache_cold_ttft"] = warm["ttft"]
        result["cache_hit_ratio"] = (round(result["prefill_tps"] / warm["prefill_tps"], 2)
                                     if warm["prefill_tps"] else None)
    return result


def judge(result: dict, thresholds: dict) -> list:
    """回傳這個 case 的違規項目清單。"""
    issues = []
    if result.get("error"):
        return [result["error"]]
    if result.get("ttft") is not None and result["ttft"] > thresholds["ttft"]:
        issues.append("TTFT %.1fs > %.1fs" % (result["ttft"], thresholds["ttft"]))
    if result["prefill_tps"] and result["prefill_tps"] < thresholds["prefill"]:
        issues.append("prefill %.0f < %.0f tok/s"
                      % (result["prefill_tps"], thresholds["prefill"]))
    if result["decode_tps"] and result["decode_tps"] < thresholds["decode"]:
        issues.append("decode %.1f < %.1f tok/s"
                      % (result["decode_tps"], thresholds["decode"]))
    if result["cpu_busy"] > thresholds["max_cpu"]:
        issues.append("CPU %.0f%% > %.0f%%" % (result["cpu_busy"], thresholds["max_cpu"]))
    if result["mem_min"] < thresholds["min_mem"]:
        issues.append("記憶體 %.1f < %.1f GiB" % (result["mem_min"], thresholds["min_mem"]))
    if not result.get("check_passed"):
        issues.append("品質檢查未過：%s" % result.get("check_note", ""))
    return issues


def print_table(results: list, thresholds: dict) -> None:
    header = ("%-12s %-10s %8s %9s %9s %7s %8s  %s"
              % ("case", "分組", "TTFT(s)", "prefill", "decode", "CPU%", "Mem(GiB)", "判定"))
    print("\n" + header)
    print("-" * 96)
    for result in results:
        if result.get("error"):
            print("%-12s %-10s %8s %9s %9s %7s %8s  %s"
                  % (result["id"], result.get("group", "-"), "-", "-", "-", "-", "-",
                     "FAIL  " + result["error"][:40]))
            continue
        issues = judge(result, thresholds)
        verdict = "PASS" if not issues else "FAIL"
        detail = "通過" if not issues else "；".join(issues)
        print("%-12s %-10s %8s %9s %9s %7s %8s  %s"
              % (result["id"], result.get("group", "-"),
                 result.get("ttft"), result.get("prefill_tps"),
                 result.get("decode_tps"), result.get("cpu_busy"),
                 result.get("mem_min"), verdict))
        if issues:
            print("               └─ %s" % detail)


def compare(new: dict, old: dict) -> None:
    old_cases = {c["id"]: c for c in old.get("results", [])}
    print("\n== 與舊報告比較 ==")
    print("%-12s %10s %10s %10s %10s" % ("case", "prefill", "Δ", "decode", "Δ"))
    for result in new.get("results", []):
        previous = old_cases.get(result["id"])
        if not previous or result.get("error"):
            continue
        new_p, old_p = result.get("prefill_tps"), previous.get("prefill_tps")
        new_d, old_d = result.get("decode_tps"), previous.get("decode_tps")
        if not new_p or not old_p:
            continue
        dp = new_p - old_p
        dd = new_d - old_d if (new_d and old_d) else 0
        print("%-12s %10.0f %+10.0f %10.1f %+10.1f"
              % (result["id"], new_p, dp, new_d or 0, dd))


def main() -> int:
    parser = argparse.ArgumentParser(description="GX10 × Strata prompt benchmark")
    parser.add_argument("--url", default="http://127.0.0.1:%s" % os.environ.get("PORT", "8080"))
    parser.add_argument("--api-key", default=os.environ.get("API_KEY", ""))
    parser.add_argument("--model", default=os.environ.get("MODEL", ""))
    parser.add_argument("--repeat", type=int, default=1)
    parser.add_argument("--quick", action="store_true")
    parser.add_argument("--no-stream", action="store_true")
    parser.add_argument("--no-warmup", action="store_true")
    parser.add_argument("--out", default="")
    parser.add_argument("--compare", default="")
    parser.add_argument("--only", default="", help="只跑某幾個 case，逗號分隔")
    parser.add_argument("--timeout", type=float,
                        default=float(os.environ.get("BENCH_TIMEOUT", "900")))
    parser.add_argument("--ttft", type=float, default=DEFAULT_THRESHOLDS["ttft"])
    parser.add_argument("--prefill", type=float, default=DEFAULT_THRESHOLDS["prefill"])
    parser.add_argument("--decode", type=float, default=DEFAULT_THRESHOLDS["decode"])
    parser.add_argument("--max-cpu", type=float, default=DEFAULT_THRESHOLDS["max_cpu"])
    parser.add_argument("--min-mem", type=float, default=DEFAULT_THRESHOLDS["min_mem"])
    args = parser.parse_args()

    thresholds = {
        "ttft": args.ttft, "prefill": args.prefill, "decode": args.decode,
        "max_cpu": args.max_cpu, "min_mem": args.min_mem,
    }

    base_url = args.url
    print("\033[36m==>\033[0m GX10 × Strata benchmark")
    print("  目標：%s" % base_url)

    try:
        with urllib.request.urlopen(base_url.rstrip("/") + "/health", timeout=15) as resp:
            resp.read()
        print("  health：OK")
    except Exception as exc:  # noqa: BLE001
        print("  \033[31mhealth 沒回應：%s\033[0m" % exc)
        print("  服務沒起來或 port 不對。")
        return 2

    model = args.model or fetch_models(base_url, args.api_key, args.timeout)
    print("  model：%s" % (model or "(讀不到，用 local)"))

    info = nvidia_info()
    if info:
        print("  GPU：%s / driver %s / %s" %
              (info.get("gpu", "?"), info.get("driver", "?"), info.get("mem_total", "?")))
    print("  MemAvailable：%.1f GiB" % mem_available_gib())
    print("  CPU 核心：%d" % (os.cpu_count() or 0))
    print("  模式：%s，repeat=%d" % ("串流" if not args.no_stream else "非串流", args.repeat))

    cold = None
    if not args.no_warmup:
        try:
            cold = call_engine(base_url, "你好", 8, args.api_key, model or "local",
                               args.timeout, not args.no_stream)
            print("  冷啟動 TTFT：%ss（已暖機，後續數字才可比）" % cold["ttft"])
        except EngineError as exc:
            print("  暖機請求失敗：%s" % exc)

    only = {x.strip() for x in args.only.split(",") if x.strip()}
    cases = [c for c in CASES if not only or c["id"] in only]
    if args.quick:
        cases = [c for c in cases if not c.get("slow")]

    results = []
    for index, case in enumerate(cases, 1):
        print("\r  [%d/%d] %-10s 測試中…" % (index, len(cases), case["id"]), end="", flush=True)
        started = time.perf_counter()
        result = run_case(case, base_url, args.api_key, model or "local",
                          args.timeout, not args.no_stream, args.repeat)
        result["wall_s"] = round(time.perf_counter() - started, 1)
        results.append(result)
        print("\r  [%d/%d] %-10s %-6s TTFT=%-6s prefill=%-7s decode=%-6s  (%ss)      "
              % (index, len(cases), case["id"],
                 "FAIL" if judge(result, thresholds) else "PASS",
                 result.get("ttft"), result.get("prefill_tps"),
                 result.get("decode_tps"), result["wall_s"]), flush=True)

    print_table(results, thresholds)

    failed = [r for r in results if judge(r, thresholds)]
    print("\n== 總結 ==")
    print("  通過 %d / %d" % (len(results) - len(failed), len(results)))
    if failed:
        print("  \033[31m未通過：%s\033[0m" % "、".join(r["id"] for r in failed))
    else:
        print("  \033[32m全部通過\033[0m")

    report = {
        "when": time.strftime("%Y-%m-%d %H:%M:%S"),
        "base_url": base_url,
        "model": model,
        "gpu": info,
        "cold_start_ttft": cold["ttft"] if cold else None,
        "thresholds": thresholds,
        "results": results,
    }

    if args.out:
        with open(args.out, "w", encoding="utf-8") as handle:
            json.dump(report, handle, ensure_ascii=False, indent=2)
        print("  報告：%s" % args.out)

    if args.compare:
        try:
            with open(args.compare, encoding="utf-8") as handle:
                compare(report, json.load(handle))
        except OSError as exc:
            print("  讀不到舊報告：%s" % exc)

    return 1 if failed else 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        print("\n中斷。")
        sys.exit(130)
