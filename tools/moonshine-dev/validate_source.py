#!/usr/bin/env python3
from pathlib import Path
import hashlib,json,re,sys
ROOT=Path(__file__).resolve().parents[2]
if not (ROOT/'src/moonshine').is_dir(): ROOT=Path(__file__).resolve().parents[1]/'overlay'
def read(name):return (ROOT/name).read_text(encoding='utf-8-sig')
def require(value,message):
    if not value:raise AssertionError(message)
engine=ROOT/'tools/moonshine'
lines=(engine/'SHA256.txt').read_text().splitlines();seen=set()
for line in lines:
    digest,name=line.split('  ',1);require(name not in seen,'duplicate engine hash');seen.add(name)
    require(hashlib.sha256((engine/name).read_bytes()).hexdigest()==digest,'engine hash '+name)
require(seen=={p.name for p in engine.iterdir() if p.is_file() and p.name!='SHA256.txt'},'incomplete engine manifest')
for n in ('Bootstrap.ps1','VibeShine-Xbox.ps1'):
    require("'Moonshine-Worker.ps1'" in (engine/n).read_text(encoding='utf-8-sig'),'worker missing from deployment closure')
core=read('tools/moonshine/Core.ps1');main=read('tools/moonshine/VibeShine-Xbox.ps1');worker=read('tools/moonshine/Moonshine-Worker.ps1')
require("'706c6f73-7862-8'" in core,'stable UUID namespace changed')
require('if ($FunctionsOnly) { return }' in main,'test entry would execute normal menu')
require('FunctionsOnly' in worker and '$script:MoonshineBoot.token=$null' in worker,'worker secret lifecycle')
require('ConvertFrom-SecureString' not in worker and 'Save-Connection' not in worker,'worker must not save temporary credentials')
require('Migrate-LegacyAutomation' in worker and 'Takeover-MoonshineAutomation' in worker,'legacy task ownership missing')
require("'REINITIALISER','ANNULER'" in worker,'destructive actions must pause native automation')
backend=read('src/moonshine/bridge_windows.cpp');routes=read('src/confighttp.cpp');glue=read('src/confighttp_moonshine.cpp')
require('TerminateProcess' not in backend and 'PowerShell.Stop' not in backend,'forceful cancellation added')
require('PROC_THREAD_ATTRIBUTE_HANDLE_LIST' in backend and 'cancel_event' in backend,'private handle transport missing')
require('revoke_token(owner_tag)' in backend and 'revoke_api_token_by_hash' in glue,'temporary token cleanup missing')
require('validate_csrf_token' in routes,'upstream CSRF gate removed')
require(not re.search(r'register_(?:blocking_)?api_route\("\^/api/(?:steam|playnite)/',routes),'redundant native provider route remains')
require(routes.count('register_api_route("^/api/moonshine/')==5,'Moonshine API route contract')
require('steam.enabled = false' in read('src/config_steam.cpp'),'native Steam sync can reactivate')
require('playnite.enabled = false' in read('src/config_playnite.cpp'),'native Playnite sync can reactivate')
require('Steam Big Picture' not in read('src_assets/windows/assets/apps.json'),'default Big Picture tile remains')
require('MoonshineLibraryView.vue' in read('src_assets/common/assets/web/router.ts'),'library not integrated')
require('Moonshine' in read('src_assets/common/assets/web/components/layout/AppShell.vue'),'host brand missing')
require('SUNSHINE_REPO_NAME "Moonshine"' in read('cmake/prep/build_version.cmake'),'updater targets upstream host')
require('MOONSHINE_BUILD_INSTALLER' in read('cmake/packaging/common.cmake'),'installer qualification gate missing')
for p in engine.glob('*.ps1'):
    require(p.read_bytes().startswith(b'\xef\xbb\xbf'),'Windows PowerShell UTF-8 BOM '+p.name)
for path in ('src_assets/windows/assets/apps.json',):json.loads(read(path))
print(json.dumps({'source_contracts':'passed','engine_files_verified':len(seen),'powershell_scripts':len(list(engine.glob('*.ps1'))),'csharp_sources':len(list(engine.glob('*.cs'))),'windows_execution_claimed':False},indent=2))
