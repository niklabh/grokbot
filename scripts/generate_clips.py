#!/usr/bin/env python3
"""Generate the four watch loops from avatar.jpg and write Secrets.swift."""

import base64
import json
import ssl
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path

import certifi
from PIL import Image

SSL_CONTEXT = ssl.create_default_context(cafile=certifi.where())

ROOT = Path(__file__).resolve().parents[1]
BUILD = ROOT / "build"
MEDIA = ROOT / "GrokWatch" / "Media"
REQUESTS = BUILD / "requests.json"
CROP = (40, 250, 1130, 1520)

SHARED = (
    "Use the provided image as the first frame and keep this exact creature: "
    "a cream fluffy sphere, two tall glossy black oval eyes, pink blush, and a tiny black smile. "
    "Do not redesign the face, fur, or colors. Plain white background only. "
    "No limbs, no text, no watermark, no logo, no extra characters, no scene change. "
    "The camera is locked: no zoom, no pan, no tilt. "
    "Motion is small and ends on the same pose as the first frame so the clip loops. "
)

CLIPS = {
    "idle": SHARED + "Idle. The sphere slowly bobs up and down and blinks once. The smile stays a tiny curve.",
    "listening": SHARED + "Listening. The eyes open a little wider, the sphere gives a small eager bounce, and it leans forward very slightly as if paying attention.",
    "thinking": SHARED + "Thinking. The eyes narrow a bit, the sphere gently pulses in and out, and it tilts a tiny amount, like it is concentrating. The smile stays.",
    "speaking": SHARED + "Speaking. The tiny mouth opens and closes in a soft repeated talking motion, and the sphere bounces a little, happy and playful. The eyes stay open.",
}


def load_key() -> str:
    for line in (ROOT / ".env").read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        name, value = line.split("=", 1)
        if name.strip() == "GROK_API_KEY":
            return value.strip().strip('"').strip("'")
    raise SystemExit("GROK_API_KEY missing from .env")


def swift_quote(value: str) -> str:
    return value.replace("\\", "\\\\").replace('"', '\\"')


def write_secret(key: str) -> None:
    secret = ROOT / "GrokWatch" / "Secrets.swift"
    secret.write_text(
        "// Generated from .env. Do not commit.\n"
        "enum Secrets {\n"
        f'    static let apiKey = "{swift_quote(key)}"\n'
        "}\n"
    )
    print("wrote Secrets.swift", flush=True)


def frame_data_url() -> str:
    image = Image.open(ROOT / "avatar.jpg").convert("RGB").crop(CROP)
    BUILD.mkdir(parents=True, exist_ok=True)
    path = BUILD / "avatar-frame.jpg"
    image.save(path, quality=85)
    encoded = base64.b64encode(path.read_bytes()).decode()
    print(f"frame {image.size} bytes {path.stat().st_size}", flush=True)
    return f"data:image/jpeg;base64,{encoded}"


def request(key: str, method: str, url: str, payload: dict | None = None) -> dict:
    data = None if payload is None else json.dumps(payload).encode()
    req = urllib.request.Request(
        url,
        data=data,
        method=method,
        headers={
            "Authorization": f"Bearer {key}",
            "Content-Type": "application/json",
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=180, context=SSL_CONTEXT) as response:
            return json.load(response)
    except urllib.error.HTTPError as error:
        body = error.read().decode("utf-8", "replace")
        raise RuntimeError(f"HTTP {error.code}: {body[:1500]}") from None


def probe(key: str) -> None:
    try:
        data = request(
            key,
            "POST",
            "https://api.x.ai/v1/chat/completions",
            {
                "model": "grok-4.7",
                "messages": [
                    {
                        "role": "system",
                        "content": "You are Grok, a small fluffy creature on an Apple Watch. Reply in one or two short spoken sentences. No markdown.",
                    },
                    {"role": "user", "content": "Say hi in a playful way."},
                ],
                "max_tokens": 200,
            },
        )
    except RuntimeError as error:
        (BUILD / "chat-probe.json").write_text(json.dumps({"error": str(error)}, indent=2))
        print("chat probe failed", flush=True)
        return
    message = (data.get("choices") or [{}])[0].get("message", {})
    summary = {
        "model": data.get("model"),
        "message_keys": sorted(message.keys()),
        "content": message.get("content"),
        "finish_reason": (data.get("choices") or [{}])[0].get("finish_reason"),
    }
    (BUILD / "chat-probe.json").write_text(json.dumps(summary, indent=2))
    print("chat probe", summary["finish_reason"], summary["message_keys"], flush=True)


def start_clip(key: str, name: str, prompt: str, data_url: str) -> str:
    data = request(
        key,
        "POST",
        "https://api.x.ai/v1/videos/generations",
        {
            "model": "grok-imagine-video-1.5",
            "prompt": prompt,
            "image": {"url": data_url},
            "duration": 5,
            "resolution": "480p",
        },
    )
    request_id = data.get("request_id")
    if not request_id:
        raise RuntimeError(f"{name} missing request_id: {json.dumps(data)[:800]}")
    print(f"{name} started {request_id}", flush=True)
    return request_id


def download(url: str, destination: Path) -> None:
    request = urllib.request.Request(url)
    with urllib.request.urlopen(request, timeout=180, context=SSL_CONTEXT) as response, destination.open("wb") as output:
        while True:
            chunk = response.read(256 * 1024)
            if not chunk:
                break
            output.write(chunk)


def video_url(data: dict) -> str | None:
    video = data.get("video") or {}
    if isinstance(video, str):
        return video
    if isinstance(video, dict):
        return video.get("url") or video.get("video_url")
    return None


def finish_clip(key: str, name: str, request_id: str) -> None:
    import time

    deadline = time.time() + 20 * 60
    while time.time() < deadline:
        data = request(key, "GET", f"https://api.x.ai/v1/videos/{request_id}")
        status = data.get("status")
        print(f"{name} {status} {data.get('progress', '')}", flush=True)
        if status == "done":
            url = video_url(data)
            if not url:
                raise RuntimeError(f"{name} done without url: {json.dumps(data)[:800]}")
            destination = MEDIA / f"{name}.mp4"
            download(url, destination)
            print(f"{name} saved {destination.stat().st_size}", flush=True)
            return
        if status in {"failed", "expired"}:
            raise RuntimeError(f"{name} {status}: {json.dumps(data)[:1500]}")
        time.sleep(10)
    raise RuntimeError(f"{name} timed out")


def main() -> None:
    BUILD.mkdir(parents=True, exist_ok=True)
    MEDIA.mkdir(parents=True, exist_ok=True)
    key = load_key()
    write_secret(key)
    data_url = frame_data_url()
    saved = json.loads(REQUESTS.read_text()) if REQUESTS.exists() else {}

    with ThreadPoolExecutor(max_workers=6) as pool:
        pool.submit(probe, key)
        start_futures = {}
        for name, prompt in CLIPS.items():
            destination = MEDIA / f"{name}.mp4"
            if destination.exists() and destination.stat().st_size > 1000:
                print(f"{name} already saved", flush=True)
                continue
            if saved.get(name):
                print(f"{name} resume {saved[name]}", flush=True)
                continue
            start_futures[pool.submit(start_clip, key, name, prompt, data_url)] = name
        errors = []
        for future in as_completed(start_futures):
            name = start_futures[future]
            try:
                saved[name] = future.result()
                REQUESTS.write_text(json.dumps(saved, indent=2))
            except Exception as error:
                errors.append(f"{name} start failed: {error}")
                print(f"ERROR {name} start failed: {error}", flush=True)

        poll_futures = []
        for name, request_id in list(saved.items()):
            destination = MEDIA / f"{name}.mp4"
            if destination.exists() and destination.stat().st_size > 1000:
                continue
            poll_futures.append(pool.submit(finish_clip, key, name, request_id))
        for future in as_completed(poll_futures):
            try:
                future.result()
            except Exception as error:
                errors.append(str(error))
                print(f"ERROR {error}", flush=True)
    if errors:
        raise SystemExit(1)
    print("ALL DONE", flush=True)


if __name__ == "__main__":
    main()
