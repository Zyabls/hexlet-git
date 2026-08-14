#!/usr/bin/env python3
"""Loopback-only, dependency-free web control plane for the upstream Deep Eye CLI."""

from __future__ import annotations

import hashlib
import ipaddress
import json
import os
import re
import signal
import socket
import subprocess
import threading
import time
import uuid
from datetime import datetime, timezone
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import unquote, urlparse


APP_ROOT = Path(os.environ.get("DEEPEYE_APP_ROOT", "/opt/deepeye"))
STATE_ROOT = Path(os.environ.get("DEEPEYE_STATE_DIR", "/var/lib/deepeye/state"))
REPORT_ROOT = Path(os.environ.get("DEEPEYE_REPORTS_DIR", "/var/lib/deepeye/reports"))
LOG_ROOT = Path(os.environ.get("DEEPEYE_LOGS_DIR", "/var/lib/deepeye/logs/jobs"))
CONFIG_PATH = os.environ.get("DEEPEYE_CONFIG", "/etc/deepeye/config.yaml")
PYTHON = os.environ.get("DEEPEYE_PYTHON", "/opt/deepeye/venv/bin/python")
ALLOW_PRIVATE = os.environ.get("DEEPEYE_ALLOW_PRIVATE_TARGETS", "0") == "1"
ALLOWED_HOSTS = tuple(item.strip().lower() for item in os.environ.get("DEEPEYE_ALLOWED_HOSTS", "").split(",") if item.strip())
STATE_FILE = STATE_ROOT / "jobs.json"
LOCK = threading.RLock()
JOBS: dict[str, dict] = {}
ACTIVE_PROCESS: subprocess.Popen | None = None
ACTIVE_JOB: str | None = None


def now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def atomic_save() -> None:
    STATE_ROOT.mkdir(parents=True, exist_ok=True)
    temporary = STATE_FILE.with_suffix(".tmp")
    temporary.write_text(json.dumps({"schema": 1, "jobs": JOBS}, indent=2), encoding="utf-8")
    os.chmod(temporary, 0o640)
    temporary.replace(STATE_FILE)


def load_state() -> None:
    global JOBS
    try:
        payload = json.loads(STATE_FILE.read_text(encoding="utf-8"))
        JOBS = payload.get("jobs", {}) if isinstance(payload, dict) else {}
        for job in JOBS.values():
            if job.get("status") in {"queued", "running"}:
                job["status"] = "interrupted"
                job["finishedAt"] = now_iso()
        atomic_save()
    except FileNotFoundError:
        JOBS = {}
        atomic_save()
    except Exception as exc:
        print(f"Deep Eye state restore skipped: {exc}", flush=True)
        JOBS = {}
        atomic_save()


def host_allowed(host: str) -> bool:
    if not ALLOWED_HOSTS:
        return True
    return any(host == pattern or (pattern.startswith("*.") and host.endswith(pattern[1:])) for pattern in ALLOWED_HOSTS)


def validate_target(value: object) -> tuple[str, str]:
    if not isinstance(value, str) or len(value) > 2048:
        raise ValueError("target must be a URL no longer than 2048 characters")
    parsed = urlparse(value.strip())
    if parsed.scheme not in {"http", "https"} or not parsed.hostname:
        raise ValueError("target must be an http:// or https:// URL")
    if parsed.username or parsed.password:
        raise ValueError("credentials in target URLs are not allowed")
    host = parsed.hostname.lower().rstrip(".")
    if not host_allowed(host):
        raise ValueError("target is outside DEEPEYE_ALLOWED_HOSTS")
    if not ALLOW_PRIVATE:
        try:
            addresses = {item[4][0] for item in socket.getaddrinfo(host, parsed.port or (443 if parsed.scheme == "https" else 80))}
        except OSError as exc:
            raise ValueError(f"target DNS resolution failed: {exc}") from exc
        for address in addresses:
            ip = ipaddress.ip_address(address)
            if not ip.is_global:
                raise ValueError("private, loopback, link-local and reserved targets are disabled")
    normalized = parsed._replace(fragment="").geturl()
    return normalized, host


def target_slug(target: str) -> str:
    parsed = urlparse(target)
    raw = f"{parsed.hostname or 'target'}{'-' + str(parsed.port) if parsed.port else ''}{parsed.path if parsed.path != '/' else ''}"
    slug = re.sub(r"[^a-zA-Z0-9._-]+", "-", raw).strip("-._").lower()[:96]
    return slug or "target"


def report_inventory() -> dict[str, tuple[int, int]]:
    REPORT_ROOT.mkdir(parents=True, exist_ok=True)
    return {str(path.relative_to(REPORT_ROOT)): (path.stat().st_mtime_ns, path.stat().st_size) for path in REPORT_ROOT.rglob("*") if path.is_file()}


def report_records(names: list[str]) -> list[dict]:
    records = []
    for name in names:
        path = (REPORT_ROOT / name).resolve()
        try:
            path.relative_to(REPORT_ROOT.resolve())
        except ValueError:
            continue
        if not path.is_file():
            continue
        digest = hashlib.sha256(path.read_bytes()).hexdigest()
        records.append({"name": name, "size": path.stat().st_size, "sha256": digest, "download": f"/api/reports/{name}"})
    return records


def rename_report_artifacts(names: list[str], target: str, job_id: str) -> list[str]:
    """Give every newly created report a resource-identifying, collision-safe name."""
    renamed = []
    prefix = f"{target_slug(target)}__{job_id[:8]}__"
    for name in names:
        source = (REPORT_ROOT / name).resolve()
        try:
            source.relative_to(REPORT_ROOT.resolve())
        except ValueError:
            continue
        if not source.is_file():
            continue
        destination = source.with_name(prefix + source.name)
        if source != destination:
            source.replace(destination)
        renamed.append(str(destination.relative_to(REPORT_ROOT.resolve())))
    return renamed


def execute_scan(job_id: str) -> None:
    global ACTIVE_PROCESS, ACTIVE_JOB
    with LOCK:
        job = JOBS[job_id]
        job["status"] = "running"
        job["startedAt"] = now_iso()
        atomic_save()
    LOG_ROOT.mkdir(parents=True, exist_ok=True)
    before = report_inventory()
    log_path = LOG_ROOT / f"{target_slug(job['target'])}__{job_id}.log"
    command = [PYTHON, str(APP_ROOT / "deep_eye.py"), "--no-banner", "--config", CONFIG_PATH, "--url", job["target"], "--formats", "html,json"]
    environment = os.environ.copy()
    environment.update({"HOME": "/var/lib/deepeye/home", "PYTHONUNBUFFERED": "1", "NO_COLOR": "1"})
    return_code = 125
    error = None
    try:
        with log_path.open("w", encoding="utf-8", errors="replace") as log:
            log.write(f"Deep Eye authorized scan\nTarget: {job['target']}\nAuthorization: {job['authorizationNote']}\nStarted: {job['startedAt']}\n\n")
            log.flush()
            process = subprocess.Popen(command, cwd=APP_ROOT, env=environment, stdout=log, stderr=subprocess.STDOUT, text=True, start_new_session=True)
            with LOCK:
                ACTIVE_PROCESS = process
                ACTIVE_JOB = job_id
            return_code = process.wait()
    except Exception as exc:
        error = str(exc)
    finally:
        after = report_inventory()
        created = sorted(name for name, metadata in after.items() if name not in before or before[name] != metadata)
        with LOCK:
            job = JOBS[job_id]
            created = rename_report_artifacts(created, job["target"], job_id)
            job["status"] = "cancelled" if job.get("cancelRequested") else ("completed" if return_code == 0 else "failed")
            job["exitCode"] = return_code
            job["error"] = error
            job["finishedAt"] = now_iso()
            job["log"] = str(log_path)
            job["reports"] = report_records(created)
            evidence = LOG_ROOT / f"{target_slug(job['target'])}__{job_id}__manifest.json"
            evidence.write_text(json.dumps({"schema": 1, "job": job, "logSha256": hashlib.sha256(log_path.read_bytes()).hexdigest()}, indent=2), encoding="utf-8")
            os.chmod(evidence, 0o640)
            job["evidenceManifest"] = str(evidence)
            ACTIVE_PROCESS = None
            ACTIVE_JOB = None
            atomic_save()


INDEX = r'''<!doctype html><html lang="ru"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Deep Eye Control</title><style>
body{font:15px system-ui;background:#081018;color:#dbe7ee;margin:0}main{max-width:1000px;margin:auto;padding:28px}.card{background:#101d27;border:1px solid #29404f;border-radius:10px;padding:18px;margin:14px 0}input,textarea,button{box-sizing:border-box;width:100%;padding:10px;margin:6px 0;background:#09141d;color:#e8f3f8;border:1px solid #3d596a;border-radius:6px}button{background:#126b55;font-weight:700;cursor:pointer}button.danger{background:#7b2930}.grid{display:grid;grid-template-columns:1fr 1fr;gap:12px}.muted{color:#8fa8b6}.ok{color:#65d6a6}.bad{color:#ff7b84}pre{white-space:pre-wrap;max-height:420px;overflow:auto;background:#071018;padding:12px}a{color:#6ec8ff}@media(max-width:700px){.grid{grid-template-columns:1fr}}</style></head><body><main>
<h1>Deep Eye</h1><p class="muted">Авторизованное тестирование · backend loopback-only · отчёты с SHA-256</p>
<section class="card"><h2>Новая проверка</h2><label>Цель</label><input id="target" placeholder="https://example.com"><label>Основание авторизации</label><textarea id="note" placeholder="Номер программы / письменное разрешение / собственный стенд"></textarea><label><input id="authorized" type="checkbox" style="width:auto"> Я подтверждаю право тестировать указанную цель</label><button onclick="startScan()">Запустить</button><p id="message"></p></section>
<section class="card"><div class="grid"><h2>Задания</h2><button onclick="refresh()">Обновить</button></div><div id="jobs"></div></section>
<section class="card"><h2>Журнал</h2><pre id="log">Выберите задание</pre></section>
<script>
const api=(u,o={})=>fetch(u,{...o,headers:{'content-type':'application/json','x-requested-with':'deepeye-ui',...(o.headers||{})}}).then(async r=>{const t=await r.text();let d;try{d=JSON.parse(t)}catch{d={error:t}}if(!r.ok)throw Error(d.error||r.status);return d});
async function startScan(){const m=document.getElementById('message');try{const d=await api('/api/scans',{method:'POST',body:JSON.stringify({target:target.value,authorizationNote:note.value,authorized:authorized.checked})});m.className='ok';m.textContent='Создано: '+d.id;refresh()}catch(e){m.className='bad';m.textContent=e.message}}
async function refresh(){try{const d=await api('/api/scans');jobs.innerHTML=d.jobs.map(j=>`<div class="card"><b>${esc(j.target)}</b><br><span class="${j.status==='completed'?'ok':j.status==='failed'?'bad':'muted'}">${j.status}</span> · ${j.id}<br>${(j.reports||[]).map(r=>`<a href="${r.download}">${esc(r.name)}</a> <small>sha256=${r.sha256}</small>`).join('<br>')}<div class="grid"><button onclick="showLog('${j.id}')">Лог</button>${j.status==='running'?`<button class="danger" onclick="cancel('${j.id}')">Остановить</button>`:''}</div></div>`).join('')}catch(e){jobs.textContent=e.message}}
async function showLog(id){try{const d=await api('/api/scans/'+id);log.textContent=d.logTail||''}catch(e){log.textContent=e.message}}
async function cancel(id){try{await api('/api/scans/'+id+'/cancel',{method:'POST',body:'{}'});refresh()}catch(e){alert(e.message)}}
function esc(v){return String(v||'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]))}refresh();setInterval(refresh,5000);
</script></main></body></html>'''


class Handler(BaseHTTPRequestHandler):
    server_version = "DeepEyeControl/1.0"

    def json_response(self, status: int, payload: object) -> None:
        data = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(data)))
        self.send_header("cache-control", "no-store")
        self.end_headers()
        self.wfile.write(data)

    def read_json(self) -> dict:
        try:
            length = int(self.headers.get("content-length", "0"))
        except ValueError as exc:
            raise ValueError("invalid content-length") from exc
        if length < 0 or length > 16_384:
            raise ValueError("request body too large")
        try:
            body = json.loads(self.rfile.read(length) or b"{}")
        except json.JSONDecodeError as exc:
            raise ValueError("invalid JSON") from exc
        if not isinstance(body, dict):
            raise ValueError("JSON object required")
        return body

    def proxy_guard(self) -> bool:
        if self.headers.get("x-deepeye-proxy") != "1" or self.headers.get("x-forwarded-proto") != "https":
            self.json_response(HTTPStatus.FORBIDDEN, {"error": "mutating requests require the authenticated HTTPS proxy"})
            return False
        if self.headers.get("x-requested-with") != "deepeye-ui":
            self.json_response(HTTPStatus.FORBIDDEN, {"error": "missing same-origin request marker"})
            return False
        origin = self.headers.get("origin")
        forwarded_host = self.headers.get("x-forwarded-host", "")
        if origin and urlparse(origin).netloc != forwarded_host:
            self.json_response(HTTPStatus.FORBIDDEN, {"error": "origin mismatch"})
            return False
        return True

    def do_GET(self) -> None:
        parsed = urlparse(self.path)
        if parsed.path == "/":
            data = INDEX.encode()
            self.send_response(HTTPStatus.OK)
            self.send_header("content-type", "text/html; charset=utf-8")
            self.send_header("content-length", str(len(data)))
            self.send_header("cache-control", "no-store")
            self.end_headers()
            self.wfile.write(data)
            return
        if parsed.path == "/api/health":
            with LOCK:
                self.json_response(HTTPStatus.OK, {"ok": True, "status": "operational", "version": "1.4.0", "sourceCommit": "e98a361ee38ec65660ce585ff6789017a2d7a466", "activeJob": ACTIVE_JOB, "persistence": str(STATE_FILE), "model": "gpt-oss-120b"})
            return
        if parsed.path == "/api/scans":
            with LOCK:
                jobs = sorted(JOBS.values(), key=lambda item: item.get("createdAt", ""), reverse=True)
                self.json_response(HTTPStatus.OK, {"jobs": jobs[:200]})
            return
        match = re.fullmatch(r"/api/scans/([a-f0-9-]{36})", parsed.path)
        if match:
            with LOCK:
                job = JOBS.get(match.group(1))
                if not job:
                    self.json_response(HTTPStatus.NOT_FOUND, {"error": "job not found"})
                    return
                payload = dict(job)
            log_path = Path(payload.get("log", LOG_ROOT / f"{match.group(1)}.log"))
            if log_path.is_file():
                payload["logTail"] = log_path.read_text(encoding="utf-8", errors="replace")[-100_000:]
            self.json_response(HTTPStatus.OK, payload)
            return
        report_match = re.fullmatch(r"/api/reports/(.+)", parsed.path)
        if report_match:
            relative = unquote(report_match.group(1))
            path = (REPORT_ROOT / relative).resolve()
            try:
                path.relative_to(REPORT_ROOT.resolve())
            except ValueError:
                self.json_response(HTTPStatus.BAD_REQUEST, {"error": "invalid report path"})
                return
            if not path.is_file():
                self.json_response(HTTPStatus.NOT_FOUND, {"error": "report not found"})
                return
            data = path.read_bytes()
            self.send_response(HTTPStatus.OK)
            self.send_header("content-type", "application/octet-stream")
            self.send_header("content-disposition", f'attachment; filename="{path.name.replace(chr(34), "")}"')
            self.send_header("x-content-type-options", "nosniff")
            self.send_header("content-length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
            return
        self.json_response(HTTPStatus.NOT_FOUND, {"error": "not found"})

    def do_POST(self) -> None:
        global ACTIVE_PROCESS
        if not self.proxy_guard():
            return
        parsed = urlparse(self.path)
        try:
            body = self.read_json()
        except ValueError as exc:
            self.json_response(HTTPStatus.BAD_REQUEST, {"error": str(exc)})
            return
        if parsed.path == "/api/scans":
            if body.get("authorized") is not True:
                self.json_response(HTTPStatus.BAD_REQUEST, {"error": "explicit authorization confirmation is required"})
                return
            note = str(body.get("authorizationNote", "")).strip()
            if len(note) < 10 or len(note) > 1000:
                self.json_response(HTTPStatus.BAD_REQUEST, {"error": "authorization note must contain 10-1000 characters"})
                return
            try:
                target, host = validate_target(body.get("target"))
            except ValueError as exc:
                self.json_response(HTTPStatus.BAD_REQUEST, {"error": str(exc)})
                return
            with LOCK:
                occupied = ACTIVE_JOB or next(
                    (item.get("id") for item in JOBS.values() if item.get("status") in {"queued", "running"}),
                    None,
                )
                if occupied:
                    self.json_response(HTTPStatus.CONFLICT, {"error": "another scan is already queued or running", "activeJob": occupied})
                    return
                job_id = str(uuid.uuid4())
                JOBS[job_id] = {"id": job_id, "target": target, "targetHost": host, "authorizationNote": note, "status": "queued", "createdAt": now_iso(), "reports": []}
                atomic_save()
            threading.Thread(target=execute_scan, args=(job_id,), daemon=True).start()
            self.json_response(HTTPStatus.CREATED, JOBS[job_id])
            return
        match = re.fullmatch(r"/api/scans/([a-f0-9-]{36})/cancel", parsed.path)
        if match:
            with LOCK:
                job = JOBS.get(match.group(1))
                if not job:
                    self.json_response(HTTPStatus.NOT_FOUND, {"error": "job not found"})
                    return
                if ACTIVE_JOB != match.group(1) or ACTIVE_PROCESS is None:
                    self.json_response(HTTPStatus.CONFLICT, {"error": "job is not running"})
                    return
                job["cancelRequested"] = True
                os.killpg(ACTIVE_PROCESS.pid, signal.SIGTERM)
                atomic_save()
            self.json_response(HTTPStatus.ACCEPTED, {"ok": True})
            return
        self.json_response(HTTPStatus.NOT_FOUND, {"error": "not found"})

    def log_message(self, fmt: str, *args: object) -> None:
        print(f"{self.client_address[0]} {fmt % args}", flush=True)


def main() -> None:
    for directory in (STATE_ROOT, REPORT_ROOT, LOG_ROOT):
        directory.mkdir(parents=True, exist_ok=True)
    load_state()
    server = ThreadingHTTPServer(("127.0.0.1", 3333), Handler)
    server.daemon_threads = True
    print("Deep Eye control plane ready on 127.0.0.1:3333", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
