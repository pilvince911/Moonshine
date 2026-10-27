#!/usr/bin/env python3
"""Prepare a Windows service candidate; SCM changes occur only in explicit tests/setup."""
from pathlib import Path
import argparse,hashlib,json,shutil,subprocess,zipfile

def sha(path): return hashlib.sha256(path.read_bytes()).hexdigest()

def main():
    p=argparse.ArgumentParser();p.add_argument('--trial-kit',type=Path,required=True);p.add_argument('--output',type=Path,required=True)
    a=p.parse_args();source=Path(__file__).resolve().parents[2];out=a.output.resolve();trial=a.trial_kit.resolve()
    if out.exists():shutil.rmtree(out)
    out.mkdir(parents=True)
    for folder in ('Package','Licences'):shutil.copytree(trial/folder,out/folder)
    for name in ('Moonshine-source.zip','submodules.txt'):shutil.copy2(trial/name,out/name)
    for p in (out/'Package').rglob('moonshine-trial-only.txt'):p.unlink()
    (out/'Package/moonshine-service-only.txt').write_text('Moonshine Windows service preview only\n',encoding='ascii')
    wrapper=out/'Package/tools/sunshinesvc.exe'
    result=subprocess.run([str(wrapper),'--identity'],capture_output=True,text=True,timeout=15)
    if result.returncode or result.stdout.strip()!='MoonshineService':raise RuntimeError('Service wrapper identity/loader validation failed.')
    for p in (source/'tools/moonshine-service').iterdir():
        if p.is_file():shutil.copy2(p,out/p.name)
    info=json.loads((trial/'build-info.json').read_text());info.update(version='0.9.0',engine_version='0.8.1',mode='service-preview',service_name='MoonshineService',service_wrapper_loader='passed',source_trial_required=True)
    (out/'build-info.json').write_text(json.dumps(info,indent=2)+'\n',encoding='utf-8')
    files=[dict(path=p.relative_to(out).as_posix(),sha256=sha(p),size=p.stat().st_size) for p in sorted(out.rglob('*')) if p.is_file()]
    (out/'manifest.json').write_text(json.dumps(dict(schema='moonshine-service-kit/1',version='0.9.0',commit=info['commit'],files=files),indent=2)+'\n',encoding='utf-8')
    archive=out.parent/'Moonshine-Windows-Service-0.9.0.zip'
    with zipfile.ZipFile(archive,'w',compression=zipfile.ZIP_DEFLATED,compresslevel=6) as z:
        for p in sorted(out.rglob('*')):
            if p.is_file():z.write(p,'Moonshine-Service/'+p.relative_to(out).as_posix())
    archive.with_suffix('.sha256').write_text(sha(archive)+'  '+archive.name+'\n',encoding='ascii')
    print(json.dumps(dict(archive=str(archive),sha256=sha(archive),files=len(files),service_identity=result.stdout.strip())))
if __name__=='__main__':main()
