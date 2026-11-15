#!/usr/bin/env python3
"""Resource benchmark of the ACTUAL lean candidate, synthetic but sized workloads."""
import csv, os, subprocess, shutil, threading, time
from pathlib import Path
from test_lean_repair import Fixture,ENGINE
HERE=Path(__file__).resolve().parent
CSV=HERE/'benchmark_results.csv'

COMMANDS=['tr','cp','cmp','awk','tar','gzip','head','wc','sed','cat','date',
          'df','ls','rm','rmdir','mkdir','chmod','mv','readlink','du','sleep']

def fixture_size(path):
    result=0
    for root,dirs,files in os.walk(path):
        for file in files:
            try: result += (Path(root)/file).stat().st_size
            except (OSError,FileNotFoundError):pass
    return result

def run(n,shell,profile=False):
    f=Fixture(process_count=n,realistic=True)
    stop=threading.Event(); peak=[0]
    log=f.root/'proc-count.log'
    if profile:
        for name in COMMANDS:
            real=shutil.which(name,path='/usr/bin:/bin')
            if real is None:continue
            path=f.fakebin/name
            path.write_text(f'#!/bin/sh\nprintf "%s\\n" "{name}" >> "{log}"\nexec "{real}" "$@"\n')
            path.chmod(0o755)
    def sample():
        while not stop.is_set():
            peak[0]=max(peak[0],fixture_size(f.tmp))
            stop.wait(.03)
    monitor=threading.Thread(target=sample,daemon=True)
    monitor.start()
    args=['busybox','ash',str(ENGINE),'main'] if shell=='busybox' else ['dash',str(ENGINE),'main']
    met=f.root/'time.txt'
    command=['/usr/bin/time','-f','%e,%U,%S,%M', '-o',str(met),*args]
    start=time.monotonic()
    try:
        result=subprocess.run(command,capture_output=True,text=True,env=f.env,timeout=120)
        elapsed=time.monotonic()-start
        stop.set();monitor.join(timeout=5)
        if result.returncode:
            print(result.stderr[-3000:]);raise RuntimeError('nonzero result '+str(result.returncode))
        timefields=met.read_text().strip().split(',')
        counts=log.read_text().splitlines() if profile and log.exists() else []
        row=dict(proc=n,shell=shell,realistic='yes',pass_result=result.returncode,
                 elapsed_s=round(elapsed,3),time_elapsed_s=timefields[0],
                 user_cpu_s=timefields[1],sys_cpu_s=timefields[2],max_rss_kib=timefields[3],
                 external_invocations=len(counts) if profile else '',
                 tr_invocations=counts.count('tr') if profile else n*2,
                 tmp_peak_kib=round(peak[0]/1024),
                 archive_kib=round(f.archive.stat().st_size/1024),
                 archive_expanded_kib=round(sum(info.size for info in __import__('tarfile').open(f.archive).getmembers())/1024),
                 source_files=58,profile='yes' if profile else 'no')
        print(row,flush=True)
        return row
    finally:
        stop.set(); monitor.join(timeout=5)
        f.close()

if __name__=='__main__':
    rows=[]
    for shell in ['dash','busybox']:
        for n in [50,140,250]:
            rows.append(run(n,shell))
    # Process wrappers in a separate run, not contaminating normal runtime.
    for n in [50,140,250]: rows.append(run(n,'dash',profile=True))
    with CSV.open('w',newline='') as h:
        out=csv.DictWriter(h,fieldnames=list(rows[0]));out.writeheader();out.writerows(rows)
    print('Saved',CSV)
