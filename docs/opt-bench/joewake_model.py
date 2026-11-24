"""Line-for-line threaded model of JoeWake (SourceHealth.swift, claude/opt-1).
CheckedContinuation -> a one-shot object that raises on double resume.
Task cancellation -> a flag + immediate onCancel call (Swift semantics:
handler runs at once if already cancelled, else when cancel() happens).
Checks under random interleavings: no double resume, every nap returns
within its interval (+ scheduling slack), a signal is never lost, and a
cancelled nap returns promptly."""
import threading, random, time, sys
class Cont:
    def __init__(s): s.ev=threading.Event(); s.n=0; s.l=threading.Lock()
    def resume(s):
        with s.l:
            s.n+=1
            if s.n>1: raise SystemExit("DOUBLE RESUME")
        s.ev.set()
class Wake:
    def __init__(s):
        s.lock=threading.Lock(); s.pending=False; s.waiter=None; s.waiterID=0; s.issued=0; s.expiredID=0
    def signal(s):
        with s.lock:
            if s.waiter: w=s.waiter; s.waiter=None
            else: s.pending=True; w=None
        if w: w.resume()
    def expire(s,i):
        with s.lock:
            if s.waiter and s.waiterID==i: w=s.waiter; s.waiter=None
            else:
                w=None
                if i==s.issued: s.expiredID=i
        if w: w.resume()
    def nap(s, secs, task):
        with s.lock: busy = s.waiter is not None
        if busy: time.sleep(secs); return "busy"
        with s.lock: s.issued+=1; i=s.issued
        tcancel=threading.Event()
        def timer():
            if not tcancel.wait(secs): s.expire(i)
        threading.Thread(target=timer,daemon=True).start()
        # withTaskCancellationHandler: register handler
        task.handlers.append(lambda: s.expire(i))
        if task.cancelled: s.expire(i)           # already cancelled -> run now
        time.sleep(random.random()*0.002)        # adversarial gap before parking
        c=Cont()
        with s.lock:
            if s.pending: s.pending=False; now=True
            elif s.expiredID==i or s.waiter is not None or task.cancelled: now=True
            else: s.waiter=c; s.waiterID=i; now=False
        if now: c.resume()
        c.ev.wait()
        task.handlers.clear(); tcancel.set(); return "ok"
class T:
    def __init__(s): s.cancelled=False; s.handlers=[]
    def cancel(s):
        s.cancelled=True
        for h in list(s.handlers): h()
def scenario(seed):
    random.seed(seed); w=Wake(); t=T(); box={"done":False,"at":None}
    interval=0.01; land=random.random()*0.05; cancel_at=random.choice([None, random.random()*0.05])
    def pub():
        time.sleep(land); box["done"]=True; box["at"]=time.perf_counter(); w.signal()
    def can():
        if cancel_at is not None: time.sleep(cancel_at); t.cancel()
    threading.Thread(target=pub).start(); threading.Thread(target=can).start()
    t0=time.perf_counter(); worst=0
    while True:
        if box["done"]: break
        if t.cancelled: break
        a=time.perf_counter(); w.nap(interval,t); d=time.perf_counter()-a; worst=max(worst,d)
        if time.perf_counter()-t0>2: raise SystemExit(f"HANG seed={seed}")
    seen=time.perf_counter()
    lat = (seen-box["at"]) if box["done"] and box["at"] else 0
    return worst, lat, t.cancelled and not box["done"]
worst_nap=0; lats=[]; canc=0
for sd in range(1500):
    wn,l,c=scenario(sd); worst_nap=max(worst_nap,wn); canc+=c
    if l: lats.append(l)
lats.sort()
print(f"scenarios=1500 cancelled-first={canc} no double resume, no hang")
print(f"worst single nap = {worst_nap*1000:.1f} ms (interval 10 ms)")
print(f"signal->loop-sees median={lats[len(lats)//2]*1000:.2f} ms p99={lats[int(.99*len(lats))]*1000:.2f} ms")
