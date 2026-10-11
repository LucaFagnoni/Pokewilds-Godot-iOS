from pathlib import Path
import hashlib,json,sys
root=Path(__file__).resolve().parent
manifest=json.loads((root/'FILE-MANIFEST.json').read_text(encoding='utf-8'))
errors=[]
for entry in manifest['files']:
    p=root/entry['path']
    if not p.is_file() or hashlib.sha256(p.read_bytes()).hexdigest()!=entry['sha256']:
        errors.append(entry['path'])
print('PASS: '+str(len(manifest['files']))+' files verified' if not errors else 'FAILED: '+repr(errors))
sys.exit(bool(errors))
