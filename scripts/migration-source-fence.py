"""Trusted-controller-only GitHub ruleset primitive; never releases a fence."""
import fcntl
import importlib.util
import os
from pathlib import Path
import re
import signal
import stat
import sys
import tempfile
import urllib.request

spec = importlib.util.spec_from_file_location('writeback_git', Path(__file__).with_name('writeback-git.py'))
common = importlib.util.module_from_spec(spec)
spec.loader.exec_module(common)
KEYS = {'format_version', 'operation', 'migration_id', 'configuration_receipt_digest',
        'source_target_digest', 'external_repository_id', 'owner', 'name', 'ref'}
MAX_RESPONSE = 1048576


def number(value):
    common.require(type(value) in (int, str) and re.fullmatch(r'[1-9][0-9]{0,19}', str(value)))
    return str(value)


def validate(value):
    common.closed(value, KEYS)
    common.require(type(value['format_version']) is int and value['format_version'] == 1)
    common.require(value['operation'] in ('create', 'read', 'reconcile'))
    common.require(all(isinstance(value[k], str) for k in KEYS - {'format_version'}))
    common.require(common.UUID.fullmatch(value['migration_id']))
    common.require(all(common.DIGEST.fullmatch(value[k]) for k in ['configuration_receipt_digest', 'source_target_digest']))
    common.require(re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_-]{0,38}', value['owner']))
    common.require(re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.-]{0,99}', value['name']))
    number(value['external_repository_id'])
    common.validate_ref(value['ref'])


def name(value):
    return 'agentdoc-cutover-' + value['migration_id'].replace('-', '') + '-' + value['configuration_receipt_digest'][7:23]


def create_payload(value):
    validate(value)
    return {'name': name(value), 'target': 'branch', 'enforcement': 'active', 'bypass_actors': [],
            'conditions': {'ref_name': {'include': [value['ref']], 'exclude': []}},
            'rules': [{'type': 'creation'}, {'type': 'update', 'parameters': {'update_allows_fetch_and_merge': False}}, {'type': 'deletion'}]}


def projection(rule, value):
    common.require(isinstance(rule, dict))
    common.require(rule.get('source_type') == 'Repository' and rule.get('source') == value['owner'] + '/' + value['name'])
    expected = create_payload(value)
    common.require(all(rule.get(k) == expected[k] for k in ['name', 'target', 'enforcement', 'conditions']))
    common.require('bypass_actors' in rule and rule['bypass_actors'] == [])
    rules = rule.get('rules')
    common.require(isinstance(rules, list) and len(rules) == 3)
    found = set()
    for item in rules:
        common.require(isinstance(item, dict))
        kind = item.get('type')
        common.require(kind in ('creation', 'update', 'deletion') and kind not in found)
        found.add(kind)
        if kind == 'update' and 'parameters' in item:
            common.closed(item, {'type', 'parameters'})
            common.closed(item['parameters'], {'update_allows_fetch_and_merge'})
            common.require(item['parameters']['update_allows_fetch_and_merge'] is False)
        else:
            common.closed(item, {'type'})
    return {'provider': 'github', 'repository_id': value['external_repository_id'], 'id': number(rule.get('id')),
            'name': name(value), 'target': 'branch', 'enforcement': 'active', 'include': [value['ref']],
            'exclude': [], 'bypass_actors': [], 'rules': ['creation', 'deletion', 'update'],
            'update_allows_fetch_and_merge': False}


def persist(path, value):
    fd, temporary = tempfile.mkstemp(prefix='.fence-state-', dir=path.parent)
    try:
        with os.fdopen(fd, 'wb') as stream:
            stream.write(common.canonical(value))
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
        directory = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        Path(temporary).unlink(missing_ok=True)


def candidates(api, base, expected_name):
    matches, seen = [], set()
    for page in range(1, 21):
        values = api('GET', base + '/rulesets?includes_parents=false&per_page=100&page=' + str(page))
        common.require(isinstance(values, list) and len(values) <= 100)
        for item in values:
            common.require(isinstance(item, dict) and isinstance(item.get('name'), str))
            identifier = number(item.get('id'))
            common.require(identifier not in seen)
            seen.add(identifier)
            if item['name'] == expected_name:
                matches.append(identifier)
        if len(values) < 100:
            return matches
    raise common.Refusal()


def execute(value, state_path, api):
    base = '/repos/' + value['owner'] + '/' + value['name']
    repository = api('GET', base)
    common.require(isinstance(repository, dict) and number(repository.get('id')) == value['external_repository_id']
                   and repository.get('full_name') == value['owner'] + '/' + value['name'])
    binding = {k: v for k, v in value.items() if k != 'operation'}
    if state_path.exists():
        state = common.parse(common.private_read(state_path, state_path.parent, 16384))
        common.closed(state, {'binding', 'phase', 'ruleset_id', 'ruleset_digest'})
        common.require(state['binding'] == binding and state['phase'] in ('pending', 'created', 'owned'))
    else:
        common.require(value['operation'] == 'create' and not state_path.is_symlink())
        common.require(not candidates(api, base, name(value)))
        state = {'binding': binding, 'phase': 'pending', 'ruleset_id': None, 'ruleset_digest': None}
        persist(state_path, state)
        created = api('POST', base + '/rulesets', create_payload(value))
        common.require(isinstance(created, dict))
        state.update(phase='created', ruleset_id=number(created.get('id')))
        persist(state_path, state)
    if state['phase'] == 'created':
        common.require(state['ruleset_digest'] is None)
        identifier = number(state['ruleset_id'])
        normalized = projection(api('GET', base + '/rulesets/' + identifier), value)
        common.require(normalized['id'] == identifier)
        state.update(phase='owned', ruleset_digest=common.sha(common.canonical(normalized)))
        persist(state_path, state)
    if state['phase'] == 'pending':
        common.require(state['ruleset_id'] is None and state['ruleset_digest'] is None)
        matches = candidates(api, base, name(value))
        common.require(len(matches) == 1)
        normalized = projection(api('GET', base + '/rulesets/' + matches[0]), value)
        common.require(normalized['id'] == matches[0])
        state.update(phase='owned', ruleset_id=normalized['id'], ruleset_digest=common.sha(common.canonical(normalized)))
        persist(state_path, state)
    identifier = number(state['ruleset_id'])
    normalized = projection(api('GET', base + '/rulesets/' + identifier), value)
    digest = common.sha(common.canonical(normalized))
    common.require(normalized['id'] == identifier and digest == state['ruleset_digest'])
    return {'format_version': 1, 'outcome': 'held', 'ruleset_id': identifier,
            'ruleset_digest': digest, 'projection': normalized}


def perform(value, state_path, api):
    validate(value)
    common.require(state_path.is_absolute() and state_path.parent == state_path.parent.resolve())
    info = state_path.parent.stat()
    common.require(info.st_uid == os.getuid() and stat.S_IMODE(info.st_mode) == 0o700 and not state_path.is_symlink())
    fd = os.open(str(state_path) + '.lock', os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    try:
        info = os.fstat(fd)
        common.require(stat.S_ISREG(info.st_mode) and info.st_uid == os.getuid()
                       and stat.S_IMODE(info.st_mode) == 0o600 and info.st_nlink == 1)
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        return execute(value, state_path, api)
    finally:
        os.close(fd)


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def github(token):
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
    def request(method, path, body=None):
        common.require(method in ('GET', 'POST') and path.startswith('/repos/') and not path.startswith('//'))
        req = urllib.request.Request('https://api.github.com' + path,
                                     data=common.canonical(body) if body is not None else None, method=method,
                                     headers={'Authorization': 'Bearer ' + token, 'Accept': 'application/vnd.github+json',
                                              'Content-Type': 'application/json', 'User-Agent': 'agentdoc-migration-cutover',
                                              'X-GitHub-Api-Version': '2026-03-10'})
        with opener.open(req, timeout=10) as response:
            common.require(response.status == (201 if method == 'POST' else 200))
            data = response.read(MAX_RESPONSE + 1)
            common.require(0 < len(data) <= MAX_RESPONSE)
            return common.parse(data)
    return request


def main():
    common.require(len(sys.argv) == 4)
    instruction, state, output = map(Path, sys.argv[1:])
    parent = instruction.parent.resolve()
    common.require(all(p.is_absolute() and p.parent == parent for p in [instruction, state, output]))
    common.require(len({instruction, state, output, Path(str(state) + '.lock')}) == 4
                   and not output.exists() and not output.is_symlink())
    value = common.parse(common.private_read(instruction, parent, 16384))
    token_path = Path(os.environ.get('MIGRATION_FENCE_TOKEN_FILE', ''))
    token = common.private_read(token_path, token_path.parent.resolve(), 8194)
    common.require(re.fullmatch(rb'[A-Za-z0-9._~+/-]{16,8192}={0,2}', token))
    result = {'format_version': 1, 'outcome': 'refused', 'code': 'migration.source_fence_required'}
    try:
        result = perform(value, state, github(token.decode('ascii')))
    except (common.Refusal, OSError, ValueError, TypeError, KeyError, RecursionError):
        pass
    common.write_result(parent, output, result)


if __name__ == '__main__':
    def expired(_signal, _frame):
        raise common.Refusal()
    signal.signal(signal.SIGALRM, expired)
    signal.alarm(45)
    try:
        main()
    except (common.Refusal, OSError, ValueError, TypeError, KeyError, RecursionError):
        sys.exit(1)
