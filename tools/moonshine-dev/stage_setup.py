#!/usr/bin/env python3
"""Assemble the self-contained ZIP; never install a service or driver here."""
from pathlib import Path
import argparse,hashlib,json,shutil,subprocess,zipfile

VERSION='1.0.0-rc.1'
def digest(path):return hashlib.sha256(path.read_bytes()).hexdigest()
def main():
    parser=argparse.ArgumentParser();parser.add_argument('--trial-kit',type=Path,required=True);parser.add_argument('--prerequisites',type=Path,required=True);parser.add_argument('--output',type=Path,required=True)
    args=parser.parse_args();source=Path(__file__).resolve().parents[2];out=args.output.resolve();trial=args.trial_kit.resolve();prereq=args.prerequisites.resolve()
    if out.exists():shutil.rmtree(out)
    out.mkdir(parents=True)
    for name in ('Package','Licences'):shutil.copytree(trial/name,out/name)
    for name in ('Moonshine-source.zip','submodules.txt'):shutil.copy2(trial/name,out/name)
    for path in (out/'Package').rglob('moonshine-trial-only.txt'):path.unlink()
    (out/'Package/moonshine-service-only.txt').write_text('Moonshine service installation required\n',encoding='ascii')
    proof=json.loads((prereq/'provenance.json').read_text(encoding='utf-8-sig'))
    assert proof['schema']=='moonshine-prerequisites/1' and proof['source_sha256']=='b46abb8a778de59b33fa5fa853819c1144f548be0d3db487a704e505c5b64838'
    assert proof['display_validation']==proof['gamepad_validation']=='passed' and proof['gamepad_protocol']==2
    assert proof['driver_install_executed'] is False and proof['trust_modified'] is False
    for row in proof['files']:
        path=prereq/row['path'];assert path.stat().st_size==row['size'] and digest(path)==row['sha256']
    shutil.copytree(prereq/'drivers',out/'Package/drivers');shutil.copy2(prereq/'provenance.json',out/'Package/drivers/provenance.json')
    for name in ('sunshine/vulkan-layer/VkLayer_sunshine_hdr.dll','sunshine/vulkan-layer/VkLayer_sunshine_hdr_x86.dll','sunshine/install.ps1','vhf-gamepad/release-lock.json'):
        assert (out/'Package/drivers'/name).is_file(),name
    for path in (source/'tools/moonshine-setup').iterdir():
        if path.is_file():shutil.copy2(path,out/path.name)
    wrapper=out/'Package/tools/sunshinesvc.exe';result=subprocess.run([str(wrapper),'--identity'],capture_output=True,text=True,timeout=15)
    if result.returncode or result.stdout.strip()!='MoonshineService':raise RuntimeError('Wrong service wrapper identity')
    info=json.loads((trial/'build-info.json').read_text());info.update(version=VERSION,engine_version='1.0.0',mode='installed-service',service_name='MoonshineService',drivers_bundled=True,service_wrapper_loader='passed',source_trial_required=False,prerequisite_source_sha256=proof['source_sha256'])
    (out/'build-info.json').write_text(json.dumps(info,indent=2)+'\n',encoding='utf-8')
    (out/'Licences/Driver-Provenance.json').write_text(json.dumps({'source_url':proof['source_url'],'source_sha256':proof['source_sha256'],'source_msi_sha256':proof['source_msi_sha256'],'consumer_source':'https://github.com/Nonary/vibeshine/tree/f078104b2b9224f080e503271dcea2a96fb573c1','display_source':'https://github.com/Nonary/libvirtualdisplay/tree/2a29ea71a52d15522c95b3de532b6612c54d75cc','gamepad_source':'https://github.com/Nonary/libvirtualgamepad/tree/9edbce11ad71e9455867c356c8368a6b39fa2242','notes':'Original signed prerequisite payloads, unchanged; GPL attribution retained in LICENSE and NOTICE.'},indent=2)+'\n',encoding='utf-8')
    files=[{'path':p.relative_to(out).as_posix(),'size':p.stat().st_size,'sha256':digest(p)} for p in sorted(out.rglob('*')) if p.is_file()]
    (out/'manifest.json').write_text(json.dumps({'schema':'moonshine-service-kit/1','mode':'installed','version':VERSION,'commit':info['commit'],'files':files},indent=2)+'\n',encoding='utf-8')
    archive=out.parent/('Moonshine-Windows-'+VERSION+'.zip')
    with zipfile.ZipFile(archive,'w',compression=zipfile.ZIP_DEFLATED,compresslevel=6) as z:
        for p in sorted(out.rglob('*')):
            if p.is_file():z.write(p,p.relative_to(out).as_posix())
    archive.with_suffix('.sha256').write_text(digest(archive)+'  '+archive.name+'\n',encoding='ascii')
    print(json.dumps({'archive':str(archive),'sha256':digest(archive),'files':len(files),'drivers':'verified-original-signed-payloads','source_trial_required':False}))
if __name__=='__main__':main()
