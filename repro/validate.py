# Offline check: validate repro YAML against the CRD openAPIV3Schema in a Kueue release manifests.yaml.
import sys, yaml, jsonschema
crds = {}
for d in yaml.safe_load_all(open(sys.argv[1])):
    if d and d.get('kind') == 'CustomResourceDefinition':
        for v in d['spec']['versions']:
            crds[(d['spec']['group'] + '/' + v['name'], d['spec']['names']['kind'])] = v['schema']['openAPIV3Schema']
def strip(s):  # drop k8s extensions jsonschema doesn't know; keep structure
    if isinstance(s, dict):
        s = {k: strip(v) for k, v in s.items() if not k.startswith('x-kubernetes')}
        if s.get('type') == 'object' and 'properties' in s and 'additionalProperties' not in s:
            s['additionalProperties'] = False  # catch misspelled fields
        return s
    if isinstance(s, list): return [strip(x) for x in s]
    return s
docs = [d for f in sys.argv[2:] for d in yaml.safe_load_all(open(f)) if d]
ok = True
for d in docs:
    key = (d['apiVersion'], d['kind'])
    if key not in crds:
        print('skip (not a Kueue CRD):', key, d['metadata']['name']); continue
    sch = strip(crds[key]); sch['properties'].pop('metadata', None); sch['properties']['metadata'] = {'type': 'object'}
    errs = list(jsonschema.Draft7Validator(sch).iter_errors(d))
    print(('OK  ' if not errs else 'ERR ') + f"{key[1]}/{d['metadata']['name']}", *[e.message for e in errs])
    ok &= not errs
sys.exit(0 if ok else 1)
