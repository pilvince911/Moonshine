#!/usr/bin/env python3
"""Stage and hash an unsigned portable trial; installs no service or driver."""
from pathlib import Path
import argparse,hashlib,json,os,re,shutil,subprocess,zipfile

def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('--build',type=Path,required=True)
    parser.add_argument('--runtime-bin',type=Path,required=True)
    parser.add_argument('--output',type=Path,required=True)
    args=parser.parse_args()
    version_name=os.environ.get('BUILD_VERSION','1.0.0-rc.2')
    source=Path(__file__).resolve().parents[2]
    build=args.build.resolve();runtime=args.runtime_bin.resolve();out=args.output.resolve();package=out/'Package'
    if out.exists():shutil.rmtree(out)
    package.mkdir(parents=True)
    executable=build/'sunshine.exe'
    if not executable.is_file():raise RuntimeError('Complete Windows host binary missing.')
    shutil.copy2(executable,package/executable.name)
    shutil.copytree(build/'assets',package/'assets',dirs_exist_ok=True)
    (package/'tools').mkdir()
    for p in (build/'tools').glob('*'):
        if p.is_file() and p.suffix.lower() in ('.exe','.dll'):shutil.copy2(p,package/'tools'/p.name)
    for p in build.glob('*.dll'):shutil.copy2(p,package/p.name)
    for name in ('playnite-launcher.exe','sunshine_wgc_capture.exe','sunshine_display_helper.exe','audio-info.exe','dxgi-info.exe','vibeshine_dualsense_haptics.exe','vibeshine_dualsense_audio.dll'):
        if not (package/'tools'/name).is_file():raise RuntimeError('Required runtime helper missing: '+name)
    for name in ('apps.json','web/v2/index.html','web/v2/images/moonshine-mark.svg'):
        if not (package/'assets'/name).is_file():raise RuntimeError('Required runtime asset missing: '+name)
    shutil.copytree(source/'tools/moonshine',package/'tools/moonshine',dirs_exist_ok=True)
    for root in (package,package/'tools/moonshine'):
        (root/'moonshine-trial-only.txt').write_text('Moonshine trial only\n',encoding='ascii')
    objdump=shutil.which('objdump')
    if not objdump:raise RuntimeError('PE dependency inspector missing.')
    queue=[p for p in package.rglob('*') if p.suffix.lower() in ('.exe','.dll')]
    seen=set();copied=[]
    if not (runtime/'zlib1.dll').is_file():raise RuntimeError('Required OpenSSL zlib runtime missing.')
    shutil.copy2(runtime/'zlib1.dll',package/'zlib1.dll');queue.append(package/'zlib1.dll')
    while queue:
        binary=queue.pop()
        if binary in seen:continue
        seen.add(binary)
        pe=subprocess.check_output([objdump,'-p',str(binary)],text=True,errors='replace')
        for name in re.findall(r'DLL Name:\s*([^\r\n]+)',pe):
            name=name.strip()
            if name.lower().startswith(('api-ms-win-','ext-ms-win-')):continue
            if (package/name).is_file():continue
            dependency=runtime/name
            if dependency.is_file():
                shutil.copy2(dependency,package/name);copied.append(name);queue.append(package/name)
            elif not (Path(os.environ['SystemRoot'])/'System32'/name).is_file():
                if not any(p.name.lower()==name.lower() for p in package.rglob('*') if p.is_file()):
                    raise RuntimeError('Unresolved runtime dependency: '+name)
    for p in package.glob('*.dll'):shutil.copy2(p,package/'tools'/p.name)
    for p in (source/'tools/moonshine-trial').iterdir():
        if p.is_file():shutil.copy2(p,out/p.name)
    licenses=out/'Licences';licenses.mkdir()
    for name in ('LICENSE','NOTICE'):shutil.copy2(source/name,licenses/name)
    if (runtime.parent/'share/licenses').is_dir():
        shutil.copytree(runtime.parent/'share/licenses',licenses/'MSYS2',dirs_exist_ok=True)
    for relative in ('licenses','share/licenses','share/doc'):
        p=build/'_deps/ffmpeg'/relative
        if p.is_dir():shutil.copytree(p,licenses/'FFmpeg'/relative,dirs_exist_ok=True)
    commit=subprocess.check_output(['git','rev-parse','HEAD'],cwd=source,text=True).strip()
    subprocess.run(['git','archive','--format=zip','--output='+str(out/'Moonshine-source.zip'),'HEAD'],cwd=source,check=True)
    (out/'submodules.txt').write_text(subprocess.check_output(['git','submodule','status','--recursive'],cwd=source,text=True),encoding='utf-8')
    result=subprocess.run([str(package/'sunshine.exe'),'--version'],cwd=package,capture_output=True,text=True,timeout=30)
    version=result.stdout+result.stderr
    if result.returncode or commit not in version:raise RuntimeError('Staged native host loader/version test failed: '+version)
    (out/'build-info.json').write_text(json.dumps({'commit':commit,'version':version_name,'version_output':version.strip(),'runtime_dlls':sorted(set(copied)),'webrtc':False,'pyrowave':False,'drivers_bundled':False,'services_installed':False,'real_stream_validated':False},indent=2)+'\n',encoding='utf-8')
    files=[{'path':p.relative_to(out).as_posix(),'sha256':digest(p),'size':p.stat().st_size} for p in sorted(out.rglob('*')) if p.is_file()]
    (out/'manifest.json').write_text(json.dumps({'schema':'moonshine-trial-kit/1','version':version_name,'commit':commit,'files':files},indent=2)+'\n',encoding='utf-8')
    archive=out.parent/('Moonshine-Windows-Essai-'+version_name+'.zip')
    with zipfile.ZipFile(archive,'w',compression=zipfile.ZIP_DEFLATED,compresslevel=6) as z:
        for p in sorted(out.rglob('*')):
            if p.is_file():z.write(p,'Moonshine-Essai/'+p.relative_to(out).as_posix())
    archive.with_suffix('.sha256').write_text(digest(archive)+'  '+archive.name+'\n',encoding='ascii')
    print(json.dumps({'archive':str(archive),'sha256':digest(archive),'files':len(files),'loader_test':'passed'}))
if __name__=='__main__':main()
