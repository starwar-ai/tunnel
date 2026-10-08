"""服务端 Web 管理页面（单文件，无前端依赖）。"""

ADMIN_HTML = r"""<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Intranet Tunnel · 管理控制台</title>
<style>
:root{--bg:#0f1420;--card:#1a2234;--border:#2a3550;--text:#e6ebf5;--dim:#8b98b8;
--accent:#4f8cff;--green:#34d399;--red:#f87171;--amber:#fbbf24}
*{box-sizing:border-box;margin:0}
body{background:var(--bg);color:var(--text);font:14px/1.6 "PingFang SC","Microsoft YaHei",system-ui,sans-serif;padding:24px}
h1{font-size:20px;margin-bottom:4px}
.sub{color:var(--dim);margin-bottom:20px}
.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(160px,1fr));gap:12px;margin-bottom:24px}
.card{background:var(--card);border:1px solid var(--border);border-radius:10px;padding:16px}
.card .num{font-size:26px;font-weight:700;margin-top:6px}
.card .label{color:var(--dim)}
section{margin-bottom:24px}
h2{font-size:16px;margin-bottom:10px}
table{width:100%;border-collapse:collapse;background:var(--card);border:1px solid var(--border);border-radius:10px;overflow:hidden}
th,td{padding:10px 14px;text-align:left;border-bottom:1px solid var(--border)}
th{color:var(--dim);font-weight:500;font-size:13px}
tr:last-child td{border-bottom:none}
.badge{display:inline-block;padding:2px 10px;border-radius:99px;font-size:12px}
.on{background:rgba(52,211,153,.15);color:var(--green)}
.off{background:rgba(248,113,113,.15);color:var(--red)}
form{background:var(--card);border:1px solid var(--border);border-radius:10px;padding:20px;max-width:560px}
label{display:block;color:var(--dim);margin:12px 0 4px}
label:first-child{margin-top:0}
input{width:100%;padding:9px 12px;border-radius:8px;border:1px solid var(--border);background:#121829;color:var(--text);font-size:14px}
input:focus{outline:none;border-color:var(--accent)}
button{margin-top:18px;padding:10px 22px;border:none;border-radius:8px;background:var(--accent);color:#fff;font-size:14px;cursor:pointer}
button:hover{filter:brightness(1.1)}
#msg{margin-left:12px;font-size:13px}
.row{display:flex;align-items:center;justify-content:space-between}
a{color:var(--accent);text-decoration:none}
.muted{color:var(--dim);font-size:13px}
</style>
</head>
<body>
<h1>Intranet Tunnel 管理控制台</h1>
<p class="sub">内网穿透服务端 · 实时状态与配置管理</p>

<div class="grid">
  <div class="card"><div class="label">运行时长</div><div class="num" id="uptime">-</div></div>
  <div class="card"><div class="label">在线客户端</div><div class="num" id="clients">-</div></div>
  <div class="card"><div class="label">活跃隧道</div><div class="num" id="tunnels">-</div></div>
  <div class="card"><div class="label">进行中会话</div><div class="num" id="sessions">-</div></div>
  <div class="card"><div class="label">总转发流量</div><div class="num" id="bytes">-</div></div>
</div>

<section>
  <div class="row"><h2>隧道列表</h2><span class="muted" id="refreshed"></span></div>
  <table><thead><tr><th>名称</th><th>公网端口</th><th>内网目标</th><th>客户端</th><th>状态</th></tr></thead>
  <tbody id="tbody"><tr><td colspan="5" class="muted">加载中…</td></tr></tbody></table>
</section>

<section>
<h2>服务端配置</h2>
<form id="cfg">
  <label>控制端口（客户端连接端口）</label><input name="port" type="number" required>
  <label>管理页面端口</label><input name="admin_port" type="number" required>
  <label>访问令牌（Token）</label><input name="token" type="text" required>
  <label>单客户端最大并发会话数</label><input name="max_sessions" type="number" required>
  <button type="submit">保存配置</button><span id="msg"></span>
</form>
<p class="muted" style="margin-top:10px">说明：令牌与会话数保存后立即生效；端口修改需重启服务后生效。</p>
</section>

<script>
const $ = id => document.getElementById(id);
function fmtBytes(n){const u=['B','KB','MB','GB','TB'];let i=0;while(n>=1024&&i<4){n/=1024;i++}return n.toFixed(i?1:0)+' '+u[i]}
function fmtUp(s){const h=~~(s/3600),m=~~(s%3600/60);return h?`${h}h ${m}m`:`${m}m ${~~(s%60)}s`}

async function loadStatus(){
  try{
    const s = await (await fetch('api/status')).json();
    $('uptime').textContent = fmtUp(s.uptime);
    $('clients').textContent = s.clients;
    $('tunnels').textContent = s.tunnels.length;
    $('sessions').textContent = s.sessions;
    $('bytes').textContent = fmtBytes(s.bytes_total);
    $('tbody').innerHTML = s.tunnels.length ? s.tunnels.map(t=>
      `<tr><td>${t.name}</td><td>${t.remote_port}</td><td>${t.local_host}:${t.local_port}</td>
       <td>${t.client||'-'}</td><td><span class="badge ${t.online?'on':'off'}">${t.online?'在线':'离线'}</span></td></tr>`
    ).join('') : '<tr><td colspan="5" class="muted">暂无隧道</td></tr>';
    $('refreshed').textContent = '更新于 ' + new Date().toLocaleTimeString();
  }catch(e){ $('tbody').innerHTML = '<tr><td colspan="5" class="muted">状态加载失败</td></tr>'; }
}
async function loadConfig(){
  const c = await (await fetch('api/config')).json();
  for(const k of ['port','admin_port','token','max_sessions'])
    document.querySelector(`[name=${k}]`).value = c[k];
}
document.querySelector('#cfg').addEventListener('submit', async e=>{
  e.preventDefault();
  const data = Object.fromEntries(new FormData(e.target).entries());
  data.port = +data.port; data.admin_port = +data.admin_port; data.max_sessions = +data.max_sessions;
  const r = await fetch('api/config', {method:'POST', headers:{'Content-Type':'application/json'}, body:JSON.stringify(data)});
  $('msg').textContent = r.ok ? '✓ 已保存' : '✗ 保存失败';
  $('msg').style.color = r.ok ? 'var(--green)' : 'var(--red)';
  setTimeout(()=>$('msg').textContent='', 3000);
});
loadStatus(); loadConfig(); setInterval(loadStatus, 5000);
</script>
</body>
</html>
"""
