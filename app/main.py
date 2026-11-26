"""Code Buster, the demo application.

Three endpoints, and that is the whole app:

  GET /         a single self-contained HTML page greeting the Code Busters
  GET /health   the ALB target-group health check
  GET /version  machine-readable version + commit SHA

The commit SHA is baked into the image at build time (APP_COMMIT) and shown
on the page. That is what makes a live deployment visible from the back of
the room: push a commit, watch the SHA on screen change.
"""
import os
import socket

from fastapi import FastAPI
from fastapi.responses import HTMLResponse, JSONResponse

APP_NAME = os.getenv("APP_NAME", "Code Buster")
APP_VERSION = os.getenv("APP_VERSION", "0.1.0")
APP_COMMIT = os.getenv("APP_COMMIT", "local")
APP_ENV = os.getenv("APP_ENV", "local")

app = FastAPI(title=APP_NAME, version=APP_VERSION, docs_url=None, redoc_url=None)


def _short(sha: str) -> str:
    return sha[:7] if len(sha) > 7 and sha != "local" else sha


@app.get("/health")
def health() -> JSONResponse:
    """Deterministic. The ALB polls this; it must never depend on anything."""
    return JSONResponse({"status": "ok"})


@app.get("/version")
def version() -> JSONResponse:
    return JSONResponse(
        {
            "name": APP_NAME,
            "version": APP_VERSION,
            "commit": APP_COMMIT,
            "environment": APP_ENV,
        }
    )


def _short_host(host: str) -> str:
    """Reduce a Fargate hostname to the task's private IP.

    Fargate names a task's host after its own address:
    `ip-10-42-10-168.eu-central-1.compute.internal`. The full name overflows
    the tile and says nothing the audience cares about. The address does: it
    is in the 10.42.x range this VPC owns, which is the visible proof that
    the task sits in a private subnet, and it changes when a task is
    replaced. Anything that is not a Fargate name is returned untouched.
    """
    if host.startswith("ip-"):
        octets = host.split(".", 1)[0][3:]
        if octets.count("-") == 3 and all(p.isdigit() for p in octets.split("-")):
            return octets.replace("-", ".")
    return host


def _task_ip() -> str:
    return _short_host(socket.gethostname())


@app.get("/", response_class=HTMLResponse)
def index() -> HTMLResponse:
    return HTMLResponse(
        PAGE.replace("{{VERSION}}", APP_VERSION)
        .replace("{{COMMIT}}", _short(APP_COMMIT))
        .replace("{{COMMIT_FULL}}", APP_COMMIT)
        .replace("{{ENV}}", APP_ENV)
        .replace("{{HOST}}", _task_ip())
    )


PAGE = """<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Hello, Code Busters</title>
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link rel="stylesheet" href="https://fonts.googleapis.com/css2?
family=JetBrains+Mono:wght@400;700&family=Open+Sans:wght@400;600;800&display=swap">
<style>
  :root{
    --ink:#161E2D; --ink-2:#0E1420; --violet:#A166FF; --violet-2:#CE76FD;
    --teal:#45D1E8; --mute:#9AA6B8; --line:rgba(161,102,255,.28);
  }
  *{box-sizing:border-box;margin:0;padding:0}
  body{
    min-height:100vh; background:var(--ink-2); color:#fff;
    font-family:'Open Sans',system-ui,sans-serif; overflow-x:hidden;
    display:grid; place-items:center; padding:24px;
  }
  /* Two drifting blobs. Pure CSS, no images, no JS dependency. */
  .glow{position:fixed; border-radius:50%; filter:blur(90px); opacity:.5; z-index:0}
  .glow.a{width:620px;height:620px;background:var(--violet);top:-220px;left:-160px;
          animation:drift 18s ease-in-out infinite alternate}
  .glow.b{width:520px;height:520px;background:var(--teal);bottom:-200px;right:-140px;
          animation:drift 22s ease-in-out infinite alternate-reverse}
  @keyframes drift{to{transform:translate3d(90px,60px,0) scale(1.15)}}
  main{position:relative; z-index:1; width:100%; max-width:860px; text-align:center}
  .badge{
    display:inline-flex; gap:10px; align-items:center; padding:8px 16px;
    border:1px solid var(--line); border-radius:999px; background:rgba(255,255,255,.04);
    font-size:14px; letter-spacing:.14em; text-transform:uppercase; color:var(--violet-2);
    font-weight:600;
  }
  .dot{width:9px;height:9px;border-radius:50%;background:#3FD98B;
       box-shadow:0 0 0 0 rgba(63,217,139,.7); animation:pulse 2s infinite}
  @keyframes pulse{70%{box-shadow:0 0 0 12px rgba(63,217,139,0)}
                   100%{box-shadow:0 0 0 0 rgba(63,217,139,0)}}
  h1{
    margin:28px 0 0; font-weight:800; line-height:1.04;
    font-size:clamp(44px,9vw,104px); letter-spacing:-.02em;
  }
  h1 em{
    font-style:normal;
    background:linear-gradient(100deg,var(--violet-2),var(--teal));
    -webkit-background-clip:text; background-clip:text; color:transparent;
  }
  p.lede{margin:22px auto 0; max-width:620px; font-size:clamp(17px,2.2vw,22px); color:#D7DEE9}
  .cards{
    margin-top:44px; display:grid; gap:14px;
    grid-template-columns:repeat(auto-fit,minmax(190px,1fr));
  }
  .card{
    border:1px solid var(--line); border-radius:14px; padding:18px 20px;
    background:rgba(255,255,255,.045); text-align:left; backdrop-filter:blur(6px);
  }
  .card span{display:block; font-size:12px; letter-spacing:.16em; text-transform:uppercase;
             color:var(--mute); font-weight:600}
  .card strong{display:block; margin-top:8px; font-size:22px; font-weight:700;
               font-family:'JetBrains Mono',ui-monospace,monospace; color:var(--teal);
               overflow-wrap:anywhere; line-height:1.25}
  footer{margin-top:40px; font-size:14px; color:var(--mute)}
  footer code{font-family:'JetBrains Mono',ui-monospace,monospace; color:var(--violet-2)}
  @media (prefers-reduced-motion:reduce){.glow,.dot{animation:none}}
</style>
</head>
<body>
  <div class="glow a"></div><div class="glow b"></div>
  <main>
    <div class="badge"><span class="dot"></span>Live on AWS Fargate</div>
    <h1>Hello,<br><em>Code Busters</em></h1>
    <p class="lede">This page was a commit a few minutes ago. GitHub Actions tested it,
       built it into a container, pushed it to Amazon ECR and rolled it out, with no
       AWS access keys anywhere.</p>
    <div class="cards">
      <div class="card"><span>Version</span><strong>{{VERSION}}</strong></div>
      <div class="card"><span>Commit</span><strong>{{COMMIT}}</strong></div>
      <div class="card"><span>Environment</span><strong>{{ENV}}</strong></div>
      <div class="card"><span>Task IP</span><strong>{{HOST}}</strong></div>
    </div>
    <footer>From Commit to AWS Cloud &middot; built with
      <code>GitHub Actions</code> + <code>Terraform</code> + <code>ECS Fargate</code></footer>
  </main>
</body>
</html>
"""
