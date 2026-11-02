"""Require the intended private repository, protected main, and approved merge."""
import json
import os
from urllib.request import Request, urlopen

from validate_data import ROOT, strict_json


def api(path):
    token = os.environ['GH_TOKEN']
    request = Request('https://api.github.com/' + path,
                      headers={'Authorization': 'Bearer ' + token,
                               'Accept': 'application/vnd.github+json',
                               'X-GitHub-Api-Version': '2022-11-28'})
    with urlopen(request, timeout=30) as response:
        return json.load(response)


def check(get=api, environment=os.environ):
    policy = strict_json(ROOT / 'deployment/policy.json')
    if (environment.get('GITHUB_REPOSITORY') != policy['repository'] or
            environment.get('GITHUB_REPOSITORY_ID') != policy['repository_id'] or
            environment.get('GITHUB_REF') != 'refs/heads/main' or
            environment.get('GITHUB_EVENT_NAME') != 'push'):
        raise ValueError('Only this repository main push can publish.')
    repo = get('repos/' + policy['repository'])
    if str(repo['id']) != policy['repository_id'] or str(repo['owner']['id']) != policy['owner_id'] or not repo['private']:
        raise ValueError('Publishing requires the verified repository to be private.')
    branch = get('repos/' + policy['repository'] + '/branches/main')
    if not branch['protected']:
        raise ValueError('Protect main and require reviews/checks before activation.')
    sha = environment['GITHUB_SHA']
    pulls = get('repos/' + policy['repository'] + '/commits/' + sha + '/pulls?per_page=100')
    for pull in pulls:
        if not pull.get('merged_at') or pull.get('merge_commit_sha') != sha or pull['base']['ref'] != 'main':
            continue
        if str(pull['head']['repo']['id']) != policy['repository_id']:
            continue
        reviews = []
        for page in range(1, 101):
            batch = get('repos/' + policy['repository'] + '/pulls/' + str(pull['number']) +
                        '/reviews?per_page=100&page=' + str(page))
            reviews.extend(batch)
            if len(batch) < 100:
                break
        else:
            raise ValueError('Review pagination limit reached; require manual review.')
        latest = {}
        for review in reviews:
            if review['state'] in {'APPROVED', 'CHANGES_REQUESTED', 'DISMISSED'}:
                latest[review['user']['id']] = review
        if any(r['state'] == 'APPROVED' and r.get('commit_id') == pull['head']['sha'] and
               r['user']['id'] != pull['user']['id'] for r in latest.values()):
            return {'reviewed_pull_request': pull['number'], 'commit': sha}
    raise ValueError('No current-head approval on a merged same-repository PR.')


if __name__ == '__main__':
    print(json.dumps(check(), indent=2))
