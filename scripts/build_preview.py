"""Build a standalone gallery of synthetic native Windows screenshots."""
import argparse,base64,html
from pathlib import Path
parser=argparse.ArgumentParser();parser.add_argument('--output',required=True);parser.add_argument('--version',default='4.4.0');args=parser.parse_args()
root=Path(__file__).resolve().parents[1]
screens=[('dashboard','Dashboard'),('connections','Connections & settings'),('review','Archive review'),('reports','Reports & confirmation'),('queue','View, accept or decline'),('updates','Offline updates')]
buttons=''.join(f'<button onclick="show({i})">{html.escape(label)}</button>' for i,(name,label) in enumerate(screens))
figures=''.join(f'<figure id="screen{i}" style="display:{"block" if i==0 else "none"}"><figcaption>{html.escape(label)} — synthetic demonstration</figcaption><img alt="{html.escape(label)}" src="data:image/png;base64,{base64.b64encode((root/"docs/images"/(name+"-native-demo.png")).read_bytes()).decode()}"></figure>' for i,(name,label) in enumerate(screens))
page='<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>CT QA Manager Pro '+html.escape(args.version)+' preview</title><style>body{font:16px/1.5 Segoe UI,sans-serif;background:#0b1120;color:#eaf0fc;max-width:1150px;margin:35px auto;padding:20px}p,figcaption{color:#a9c5d5}nav{display:flex;flex-wrap:wrap;gap:8px;margin:24px 0}button{background:#193344;border:1px solid #378d92;color:#eaf0fc;border-radius:8px;padding:12px;cursor:pointer}figure{margin:0}img{width:100%;height:auto;border:1px solid #30465f;border-radius:12px;margin-top:12px}</style><h1>CT QA Manager Pro '+html.escape(args.version)+'</h1><p>Actual Windows interface previews with synthetic demonstration data.</p><nav>'+buttons+'</nav>'+figures+'<script>function show(n){for(let i=0;i<6;i++)document.getElementById("screen"+i).style.display=i===n?"block":"none"}</script></html>'
Path(args.output).write_text(page,encoding='utf-8')
