"""Read-only Hugging Face candidate discovery for the model qualification CLI.

model_eval owns this short-lived search. This module turns untrusted public metadata into a bounded,
revision-pinned manifest; it never imports repository code or decides model quality. Keeping network
retrieval separate from selection makes selection policy testable without downloads or inference.
"""
import datetime
import json
import re
import time
import urllib.error
import urllib.parse
import urllib.request

API = "https://huggingface.co"
QUANTS = ("Q4_K_M", "Q5_K_M", "Q6_K", "Q8_0")
BASE = re.compile(r"(?:^|[^a-z0-9])(base|pretrain(?:ed)?)(?:$|[^a-z0-9])", re.I)
CHAT = re.compile(r"(?:^|[^a-z0-9])(instruct|chat|it|rlhf|dpo|reasoning|thinking)(?:$|[^a-z0-9])", re.I)


def get_json(url):
    """Bound response size and retry transient Hub failures without consuming unlimited time."""
    for attempt in range(3):
        try:
            request = urllib.request.Request(url, headers={"User-Agent": "Cotabby-model-eval/1", "Accept": "application/json"})
            with urllib.request.urlopen(request, timeout=30) as response:
                data = response.read(16 * 1024 * 1024 + 1)
            if len(data) > 16 * 1024 * 1024:
                raise ValueError("Hub metadata response exceeded 16 MiB")
            return json.loads(data)
        except urllib.error.HTTPError as error:
            if error.code not in (429, 500, 502, 503, 504) or attempt == 2:
                raise
            time.sleep(min(10, 2 ** attempt))
        except urllib.error.URLError:
            if attempt == 2:
                raise
            time.sleep(2 ** attempt)


def upstream_ids(info):
    # base_model means ancestry (including instruction tuning), not evidence of a base checkpoint.
    card = info.get("cardData") or {}
    values = card.get("base_model", []) if isinstance(card, dict) else []
    if isinstance(values, str):
        values = [values]
    values = [v for v in values if isinstance(v, str)] if isinstance(values, list) else []
    values += [tag[len("base_model:"):] for tag in info.get("tags", [])
               if isinstance(tag, str) and tag.startswith("base_model:") and tag.count(":") == 1]
    return sorted(set(values))


def repository_skip_reason(info):
    if info.get("private") or info.get("disabled") or info.get("gated") not in (None, False):
        return "private, disabled, or gated repository"
    if info.get("pipeline_tag") != "text-generation":
        return "not a text-generation repository"
    names = [info.get("id", "").split("/")[-1]] + [value.split("/")[-1] for value in upstream_ids(info)]
    if any(re.search(r"(?:^|[^a-z0-9])(mmproj|embedding|embed|encoder|sdcpp|diffusion|summari[sz]ation|image)(?:$|[^a-z0-9])", name, re.I) for name in names):
        return "specialized encoder, summarization, or image artifact"
    if any(CHAT.search(name) for name in names):
        return "chat/instruction/reasoning name does not match the base continuation prompt"
    if not any(BASE.search(name) for name in names):
        return "no explicit base/pretrained name evidence (ancestry tags alone are insufficient)"
    card = info.get("cardData") or {}
    languages = card.get("language", []) if isinstance(card, dict) else []
    if isinstance(languages, str):
        languages = [languages]
    if languages and "en" not in languages and "multilingual" not in languages:
        return "declared languages do not cover the English evaluation corpus"
    return None


def eligible_files(info, max_bytes):
    """Require a complete single GGUF and trustworthy file identity before allocating disk space."""
    options, skipped = [], []
    for file in info.get("siblings", []):
        name = file.get("rfilename", "")
        if not name.lower().endswith(".gguf"):
            continue
        reason = None
        quant = next((q for q in QUANTS if re.search(r"(?:^|[._/-])" + q + r"(?:[._/-]|$)", name, re.I)), None)
        lfs = file.get("lfs") or {}
        size, digest = file.get("size"), lfs.get("sha256", "")
        if "mmproj" in name.lower() or re.search(r"-\d{5}-of-\d{5}", name):
            reason = "projector or multipart file"
        elif CHAT.search(name):
            reason = "instruction/chat file"
        elif not quant:
            reason = "outside preferred Q4_K_M/Q5_K_M/Q6_K/Q8_0 quantizations"
        elif not isinstance(size, int) or size <= 4 or size > max_bytes:
            reason = "missing size or exceeds per-model file budget"
        elif not re.fullmatch(r"[0-9a-f]{64}", digest) or lfs.get("size") != size:
            reason = "missing SHA-256 or inconsistent file size"
        if reason:
            skipped.append({"file": name, "reason": reason})
        else:
            options.append((QUANTS.index(quant), size, name, digest, quant))
    return sorted(options), skipped


def discover(*, max_candidates=6, max_repositories=120, max_model_bytes=8 * 1024**3,
             max_download_bytes=16 * 1024**3, excluded_hashes=(), fetch=get_json):
    """Merge bounded recent/popular searches, dedupe upstream models, and freeze selected files.

    lastModified is a quant repository's update time, not proof of a new model release. Searches
    deliberately mix recency and downloads; neither signal is used as a quality score.
    """
    audit = {"version": 1, "startedUTC": datetime.datetime.now(datetime.timezone.utc).isoformat(),
             "policy": {"maxCandidates": max_candidates, "maxRepositories": max_repositories,
                        "maxModelBytes": max_model_bytes, "maxDownloadBytes": max_download_bytes,
                        "quantPreference": QUANTS}, "searches": [], "decisions": [], "models": []}
    pool = {}
    feeds = []
    per_search = max(1, (max_repositories + 2) // 3)
    for term, order in (("base", "lastModified"), ("pretrain", "lastModified"), ("base", "downloads")):
        url = API + "/api/models?" + urllib.parse.urlencode({"filter": "gguf", "pipeline_tag": "text-generation", "search": term,
              "sort": order, "direction": -1, "limit": per_search, "full": "true"})
        try:
            rows = fetch(url)
            if not isinstance(rows, list):
                raise ValueError("Hub search did not return a list")
            audit["searches"].append({"url": url, "returned": len(rows)})
            feeds.append(rows[:per_search])
        except (OSError, ValueError) as error:
            audit["searches"].append({"url": url, "error": str(error)})
    # Round-robin feeds so the newest quant uploads cannot starve established popular models.
    # Within each feed preserve Hub order, then deduplicate publishers by upstream identity.
    for index in range(per_search):
        for feed in feeds:
            if index < len(feed):
                row = feed[index]
                if isinstance(row, dict) and isinstance(row.get("id"), str):
                    pool.setdefault(row["id"], row)
    used_upstreams, used_hashes, total = set(), set(excluded_hashes), 0
    for repo, summary in list(pool.items())[:max_repositories]:
        decision = {"repo": repo}
        audit["decisions"].append(decision)
        try:
            if len(audit["models"]) >= max_candidates:
                decision["reason"] = "candidate count budget reached"
                continue
            if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repo):
                raise ValueError("invalid repository id")
            reason = repository_skip_reason(summary)
            if reason:
                decision["reason"] = reason
                continue
            revision = summary.get("sha", "")
            if not re.fullmatch(r"[a-f0-9]{40}", revision):
                raise ValueError("missing immutable repository revision")
            url = API + "/api/models/" + urllib.parse.quote(repo, safe="/") + "/revision/" + revision + "?blobs=true"
            info = fetch(url)
            if info.get("sha") != revision:
                raise ValueError("Hub detail revision differs from search revision")
            reason = repository_skip_reason(info)
            if reason:
                decision["reason"] = reason
                continue
            upstreams = upstream_ids(info)
            family = tuple(upstreams) if upstreams else (re.sub(r"(?:-i1)?-gguf$", "", repo.split("/")[-1], flags=re.I).lower(),)
            if family in used_upstreams:
                decision["reason"] = "upstream model already selected"
                continue
            options, skipped = eligible_files(info, max_model_bytes)
            decision["skippedFiles"] = skipped
            choice = next((o for o in options if o[3] not in used_hashes and total + o[1] <= max_download_bytes), None)
            if choice is None:
                decision["reason"] = "no eligible unique file within remaining download budget"
                continue
            _, size, filename, digest, quant = choice
            label = re.sub(r"[^A-Za-z0-9_.-]", "-", repo)[:90]
            entry = {"id": "hf-" + label + "-" + digest[:12], "url": API + "/" + repo + "/resolve/" + revision + "/" + urllib.parse.quote(filename, safe="/"),
                     "sha256": digest, "sizeBytes": size, "hf": {"repo": repo, "revision": revision,
                     "file": filename, "upstream": upstreams, "quantization": quant,
                     "lastModified": summary.get("lastModified"), "downloads": summary.get("downloads"),
                     "licenseTags": [t for t in info.get("tags", []) if t.startswith("license:")],
                     "baseEvidence": "explicit base/pretrained name; suitability unverified until replay"}}
            audit["models"].append(entry)
            decision.update(selected=entry["id"], reason="selected for evaluation")
            used_upstreams.add(family)
            used_hashes.add(digest)
            total += size
        except (OSError, ValueError, TypeError, KeyError) as error:
            decision["reason"] = "metadata unavailable or invalid: " + str(error)
    audit["plannedDownloadBytes"] = total
    return audit
