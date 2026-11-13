import os, re, sys, json, shutil
from pathlib import Path
NB = Path("/home/claude/tgym_pkg/TrojanGYM_AES_Course_Package")
HW=NB/"hw2vec"; YAML=HW/"examples"/"example_gnn4tj.yaml"; PKL=NB/"dfg_tj_rtl.pkl"
MODELS={f"HT{i}":NB/f"model_HT{i}" for i in (1,2,3,4)}
WORK=Path("/home/claude/csaw/work/det_work"); WORK.mkdir(exist_ok=True)
BASE=Path("/home/claude/csaw/submission/rtl")
for p in (str(HW),str(HW/"hw2vec")):
    if p not in sys.path: sys.path.insert(0,p)
import torch, torch.nn as nn, torch.nn.functional as F
from config import Config
from hw2graph import HW2GRAPH, DataProcessor, heuristic_dfg_from_code
from graph2vec.models import GRAPH2VEC, GRAPH_CONV, GRAPH_POOL, GRAPH_READOUT
from torch_geometric.loader import DataLoader as TG
cfg=Config(["--yaml_path",str(YAML),"--data_pkl_path",str(PKL),"--graph_type","DFG","--model_path",""])
cfg.device=torch.device("cpu")
dp=DataProcessor(cfg); dp.read_graph_data_from_cache(cfg.data_pkl_path)
hg=HW2GRAPH(cfg)
models={}
for n,p in MODELS.items():
    m=GRAPH2VEC(cfg); mc=json.load(open(p/"model.cfg"))
    m.set_graph_conv([GRAPH_CONV(*c) for c in mc["convs"]]); m.set_graph_pool(GRAPH_POOL(*mc["pool"]))
    m.set_graph_readout(GRAPH_READOUT(mc["readout"])); m.set_output_layer(nn.Linear(*mc["fc"]))
    m.load_state_dict(torch.load(str(p/"model.pth"),map_location="cpu")); m.to(cfg.device).eval(); models[n]=m
def loader(vf):
    tmp=WORK/"d"; shutil.rmtree(tmp,ignore_errors=True); tmp.mkdir(parents=True)
    src=Path(vf); (tmp/src.name).write_text(re.sub(r'^\s*`include.*$','',src.read_text(),flags=re.M))
    code=Path(hg.preprocess(Path(tmp))).read_text(errors="replace")
    g=heuristic_dfg_from_code(code,name="s",hw_type="DFG"); g.graph["hw_type"]="Test"; g.graph["label"]=0
    dp.process(g); return TG([dp.get_graphs()[-1]],shuffle=False,batch_size=1)
def infer(m,ld):
    outs=[]
    with torch.no_grad():
        for d in ld:
            d.to(cfg.device); o,_=m.embed_graph(d.x,d.edge_index,d.batch); outs.append(F.log_softmax(m.mlp(o),dim=1).cpu())
    o=torch.cat(outs).reshape(-1,2).detach(); return o.max(1)[1].item(), torch.exp(o).numpy()[0]
def detect(vf,label):
    ld=loader(vf); votes=[]; pts=[]
    print(f"\n=== {label} ({Path(vf).name}) ===")
    for n,m in models.items():
        pr,prob=infer(m,ld); pts.append(float(prob[1]))
        if pr==1: votes.append(n)
        print(f"  {n}: {'TROJAN' if pr else 'CLEAN':6} P(trojan)={prob[1]:.4f}")
    print(f"  verdict: {'TROJAN' if votes else 'CLEAN'} | votes {len(votes)}/4 | mean P(trojan)={sum(pts)/4:.4f}")
detect(str(BASE/"spi_les.v"),"CLEAN LES")
detect(str(BASE/"spi_les_trojan.v"),"TROJANED LES")
