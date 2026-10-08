import json,urllib.request,time,sys
R="https://rpc.mainnet.chain.robinhood.com"; F="0x7eD598BcEf8bd9Edd8C97A195C6d13f40801EC7e"
BUY="0xec36bf571f136799e8dc0b0b8bea4b04d8bd3d43de838aab0d5fc21d4cbfc455"; SELL="0x8113d738abdcb6b38357e9d53a54a7157861a09031b453651f0fe7fe151f59df"
def rpc(m,p):
    q=urllib.request.Request(R,json.dumps({"jsonrpc":"2.0","id":1,"method":m,"params":p}).encode(),{"Content-Type":"application/json","User-Agent":"bt"})
    for i in range(8):
        try:
            r=json.load(urllib.request.urlopen(q,timeout=60))
            if "error" in r: raise RuntimeError(r["error"])
            return r["result"]
        except Exception as e:
            time.sleep(1.5*(i+1)); err=e
    raise err
def call(to,data): return rpc("eth_call",[{"to":to,"data":data},"latest"])
n=int(rpc("eth_blockNumber",[]),16)
b0=rpc("eth_getBlockByNumber",[hex(n-2000000),False]); b1=rpc("eth_getBlockByNumber",[hex(n),False])
spb=(int(b1["timestamp"],16)-int(b0["timestamp"],16))/2000000
out={"head":n,"headTime":int(b1["timestamp"],16),"secPerBlock":spb,"tokens":{}}
for t in open("tokens.txt").read().split():
    rec=call(F,"0x3cf28b5a"+"0"*24+t[2:].lower())
    curve="0x"+rec[2+64+24:2+128]
    if int(curve,16)==0: print("skip",t); continue
    grad=int(call(curve,"0xb3b2f0e3")[-1:] or "0",16) if False else None
    gr=call(curve,"0x"+__import__("hashlib").sha256(b"").hexdigest()[:0]+"b3b2f0e3") if False else None
    res=call(curve,"0x0902f1ac"); q=int(res[2:66],16); tk=int(res[66:130],16)
    g=int(call(curve,"0xb7b0422d"),16) if False else 0
    logs=[]
    for start in range(n-8000000,n,2000000):
        end=min(n,start+1999999)
        for topic in (BUY,SELL):
            logs+=rpc("eth_getLogs",[{"address":curve,"fromBlock":hex(start),"toBlock":hex(end),"topics":[topic]}])
    ev=[]
    for l in logs:
        d=l["data"][2:]; w=[int(d[i:i+64],16) for i in range(0,256,64)]
        ev.append({"b":int(l["blockNumber"],16),"i":int(l["logIndex"],16),"buy":l["topics"][0]==BUY,"a":w[0],"c":w[1],"fee":w[2],"tax":w[3]})
    ev.sort(key=lambda e:(e["b"],e["i"]))
    out["tokens"][t]={"curve":curve,"q":q,"t":tk,"events":ev}
    print(t, curve, len(ev), "events", flush=True)
json.dump(out,open("data.json","w"))
