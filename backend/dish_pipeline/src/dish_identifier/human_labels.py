"""Durable human label authority for offline dataset preparation and evaluation.

Never changes image files or model predictions. Identity is exact SHA-256, so a
review follows a copied/renamed image. Missing registry or conflicting identities
raise errors instead of silently reverting to folder labels.
"""
from __future__ import annotations
import hashlib,json
from pathlib import Path
from functools import lru_cache
from collections import Counter

PROJECT_ROOT=Path(__file__).resolve().parents[2]
REGISTRY_PATH=PROJECT_ROOT/'data_governance/human_label_registry.json'
ACTIONS={'RELABEL','KEEP','UNSURE','EXCLUDE_UNUSABLE'}

@lru_cache(maxsize=200000)
def _file_sha(path,mtime_ns,size,ctime_ns,inode):
 digest=hashlib.sha256()
 with Path(path).open('rb') as f:
  for chunk in iter(lambda:f.read(1024*1024),b''):digest.update(chunk)
 return digest.hexdigest()

def image_sha(path):
 p=Path(path).resolve()
 if 'final_test' in p.parts and any('ood' in part.casefold() for part in p.parts):
  raise ValueError('Reserved OOD Final Test must not be opened by label reconciliation')
 st=p.stat();return _file_sha(str(p),st.st_mtime_ns,st.st_size,st.st_ctime_ns,st.st_ino)

class HumanLabelRegistry:
 def __init__(self,path=REGISTRY_PATH):
  self.path=Path(path)
  if not self.path.is_file():raise FileNotFoundError(f'Required human label registry missing: {self.path}. Copy it with the project; folder-label fallback is prohibited.')
  raw=self.path.read_bytes();self.sha256=hashlib.sha256(raw).hexdigest();self.data=json.loads(raw);self.records=self.data['records']
  if self.data['schema_version']!=1 or self.data['priority']!='human_over_model_and_folder':raise ValueError('Invalid human label authority policy')
  self.by_sha={x['image_sha256']:x for x in self.records}
  if len(self.by_sha)!=len(self.records):raise ValueError('Conflicting duplicate image identities in human label registry')
  for r in self.records:
   if len(r['image_sha256'])!=64 or r['decision'] not in ACTIONS or r['reviewer']!='human_user' or not r['history']:raise ValueError('Invalid human review record')
   if r['decision']=='RELABEL' and not r.get('corrected_label'):raise ValueError('RELABEL requires an explicit human label')
 def resolve(self,*,original_label,image_path=None,image_sha256=None):
  if image_path is not None:
   actual=image_sha(image_path)
   if image_sha256 and actual!=image_sha256:raise ValueError('Image bytes do not match declared SHA-256')
   image_sha256=actual
  if not image_sha256:raise ValueError('Image bytes or SHA-256 required; filename-only matching is prohibited')
  review=self.by_sha.get(image_sha256)
  if review is None:return dict(original_label=original_label,effective_label=original_label,decision=None,eligible=True,review=None,image_sha256=image_sha256)
  action=review['decision']
  label=review['corrected_label'] if action=='RELABEL' else review.get('kept_label',review['original_label']) if action=='KEEP' else None
  return dict(original_label=original_label,effective_label=label,decision=action,eligible=action in {'RELABEL','KEEP'},review=review,image_sha256=image_sha256)

def reconcile_records(records,classes,*,label_field='dish',registry=None):
 """Return eligible copied rows plus a full audit of every human-reviewed row.

 UNSURE/EXCLUDE stay in audit and are omitted from supervised targets. Callers
 needing all image outputs (e.g. VLM reports) should use resolve() and keep rows.
 """
 registry=registry or HumanLabelRegistry();mapping=classes if isinstance(classes,dict) else {x:i for i,x in enumerate(classes)}
 output=[];audit=[]
 for source in records:
  row=dict(source);path=row.get('resolved_path') or row.get('image_path') or row.get('original_image_path')
  digest=row.get('image_sha256') or row.get('sha256')
  decision=registry.resolve(original_label=row[label_field],image_path=path,image_sha256=digest)
  if decision['review'] is not None:
   audit.append(dict(image_sha256=decision['image_sha256'],path=path,source_label=row[label_field],effective_label=decision['effective_label'],decision=decision['decision'],eligible=decision['eligible'],review=decision['review']))
  if not decision['eligible']:continue
  label=decision['effective_label']
  if label not in mapping:raise ValueError(f'Human-approved label {label!r} is not supported by the supplied class mapping; do not substitute or ignore it')
  row['source_label_before_human_review']=row.get('source_label_before_human_review',row[label_field]);row[label_field]=label
  if label_field=='dish':row['dish_index']=mapping[label]
  row['image_sha256']=decision['image_sha256'];row['human_label_decision']=decision['decision'];row['human_label_registry_sha256']=registry.sha256
  output.append(row)
 return output,dict(registry=str(registry.path),registry_sha256=registry.sha256,source_records=len(records),eligible_records=len(output),omitted_records=len(records)-len(output),human_decision_counts=dict(Counter(x['decision'] for x in audit)),reviews=audit)

def reconcile_manifest(path,records=None):
 path=Path(path);records=records if records is not None else [json.loads(x) for x in path.read_text().splitlines() if x.strip()]
 classpath=path.parent/'classes.json'
 if not classpath.is_file():raise FileNotFoundError(f'Class mapping required for durable human review: {classpath}')
 classes=json.loads(classpath.read_text());classes=classes['classes'] if isinstance(classes,dict) else classes
 return reconcile_records(records,classes)
