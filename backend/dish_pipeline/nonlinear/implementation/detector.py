"""Load either frozen detector independently. No dataset or test runner."""
import hashlib
import importlib.util
import json
from pathlib import Path
import numpy as np
from scipy.special import expit
import torch


def sha(path):
    with Path(path).open('rb') as f:return hashlib.file_digest(f,'sha256').hexdigest()


def logistic(model,x):
    x=np.asarray(x,dtype=np.float64)
    if x.ndim!=2 or x.shape[1]!=len(model['scaler_mean']) or not np.isfinite(x).all():raise ValueError('Invalid logistic features')
    return expit(((x-model['scaler_mean'])/model['scaler_scale'])@np.array(model['standardized_coefficients'])+model['standardized_intercept'])


def original_features(logits):
    l=np.asarray(logits,dtype=np.float64)
    if l.ndim!=2 or l.shape[1]!=121 or not np.isfinite(l).all():raise ValueError('Original logits must be finite Nx121')
    p=np.exp(l-l.max(1,keepdims=True));p/=p.sum(1,keepdims=True);top=np.sort(p,axis=1)[:,-2:]
    # Exact feature contract of the original float32 saved caches.
    conf=top[:,1].astype(np.float32).astype(np.float64)
    margin=(top[:,1]-top[:,0]).astype(np.float32).astype(np.float64)
    return np.column_stack((conf,margin)),np.argmax(l,axis=1)


def fusion_scores(lr,oe,confidence,model,kind,alpha=None):
    paired=np.column_stack((lr,oe))
    if kind=='NONLINEAR':return logistic(model,np.column_stack((paired,lr*oe)))
    if kind!='CONDITIONAL' or alpha!=.75:raise ValueError('Unexpected frozen architecture')
    linear=logistic(model,paired)
    return np.where(np.asarray(confidence)<.9,linear,np.minimum(linear,alpha*oe))


class FrozenDetector:
    def __init__(self,candidate_directory):
        self.path=Path(candidate_directory).resolve();self.config=json.loads((self.path/'config.json').read_text())
        torch.set_num_threads(self.config['inference_cpu_threads'])
        if self.config['candidate'] not in ('FINAL_CONDITIONAL_FUSION','FINAL_NONLINEAR_FUSION'):raise ValueError('Unknown candidate')
        files={}
        for key,item in self.config['components'].items():
            path=(self.path/item['path']).resolve()
            if not path.is_relative_to(self.path.parent) or sha(path)!=item['sha256']:raise ValueError('Frozen component mismatch: '+key)
            files[key]=path
        self.lr=json.loads(files['lr'].read_text());self.fusion=json.loads(files['fusion'].read_text())
        self.mapping=json.loads(files['class_mapping'].read_text());self.prep=json.loads(files['preprocessing'].read_text())
        self.classes=self.mapping['classes'];assert len(self.classes)==121
        assert self.mapping['class_to_idx']=={c:i for i,c in enumerate(self.classes)}
        assert len(self.lr['scaler_mean'])==2
        assert len(self.fusion['scaler_mean'])==(2 if self.config['kind']=='CONDITIONAL' else 3)
        for model in (self.lr,self.fusion):
            assert np.isfinite(model['scaler_mean']).all() and np.isfinite(model['scaler_scale']).all()
            assert np.all(np.array(model['scaler_scale'])>0) and np.isfinite(model['standardized_coefficients']).all()
            assert np.isfinite(model['standardized_intercept'])
        checkpoint=torch.load(files['oe'],map_location='cpu',weights_only=True,mmap=True)
        assert checkpoint['input_dim']==768 and checkpoint['num_classes']==121 and checkpoint['classes']==self.classes
        self.oe=torch.nn.Linear(768,121);self.oe.load_state_dict(checkpoint['state_dict'],strict=True);self.oe.eval().requires_grad_(False)
        assert all(torch.isfinite(v).all() for v in self.oe.state_dict().values())
        self.threshold=float(self.config['threshold']);assert np.isfinite(self.threshold)
        self.original=None;self.original_object=None

    @torch.inference_mode()
    def score_embeddings(self,embeddings,original_logits):
        e=np.asarray(embeddings,dtype=np.float32);l=np.asarray(original_logits)
        if e.ndim!=2 or e.shape[1]!=768 or len(l)!=len(e) or not np.isfinite(e).all():raise ValueError('Invalid paired embeddings/logits')
        features,indices=original_features(l);lr=logistic(self.lr,features)
        oe=torch.softmax(self.oe(torch.as_tensor(e)),dim=1).amax(1).numpy().astype(np.float64)
        score=fusion_scores(lr,oe,features[:,0],self.fusion,self.config['kind'],self.config.get('alpha'))
        if not np.isfinite(score).all():raise ValueError('Nonfinite frozen supportedness')
        return dict(score=score,accepted=score>=self.threshold,original_predicted_indices=indices,
          original_predicted_classes=np.array(self.classes)[indices],original_confidence=features[:,0],LR_score=lr,OE_score=oe)

    def load_original(self):
        if self.original is not None:return self.original
        ref=self.config['original_classifier']
        if sha(ref['checkpoint'])!=ref['checkpoint_sha256'] or sha(ref['loader'])!=ref['loader_sha256']:raise ValueError('Original classifier reference changed')
        spec=importlib.util.spec_from_file_location('frozen_original_dino_runtime',ref['loader']);module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
        model,classes,prep,obj=module.load_checkpoint(Path(ref['checkpoint']))
        if classes!=self.classes or dict(prep)!=dict(self.prep['checkpoint_preprocessing']):
            # JSON arrays vs checkpoint tuples are normalized below.
            if classes!=self.classes or json.loads(json.dumps(prep))!=self.prep['checkpoint_preprocessing']:raise ValueError('Original mapping/preprocessing mismatch')
        self.original=model.cpu().eval().requires_grad_(False);self.original_object=obj;self.transform=module.make_transform(prep)
        return self.original

    @torch.inference_mode()
    def predict_images(self,images):
        """Images are already opened PIL objects; this API discovers no files."""
        model=self.load_original();x=torch.stack([self.transform(image.convert('RGB')) for image in images])
        logits,embeddings=model.forward_with_embedding(x)
        return self.score_embeddings(embeddings.numpy(),logits.numpy())
