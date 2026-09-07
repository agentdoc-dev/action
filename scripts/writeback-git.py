"""Private whole-file Git CAS primitive. Authority and claim belong to the runner."""
import base64
import hashlib
import json
import os
from pathlib import Path
import re
import select
import stat
import subprocess
import sys
import tempfile
import time
import unicodedata

MIB = 1048576
OID = re.compile(r'[0-9a-f]{40}\Z')
DIGEST = re.compile(r'sha256:[0-9a-f]{64}\Z')
UUID = re.compile(r'[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\Z')
INSTRUCTION = {'format_version', 'writeback_id', 'record_digest', 'payload_digest',
               'target_id', 'target_digest', 'remote', 'ref', 'path',
               'expected_old_oid', 'expected_source_digest'}
MATERIAL = {'format_version', 'expected_old_oid', 'prepared_new_oid',
            'commit_bytes_base64', 'trees', 'blob_oid'}


class Refusal(Exception):
    pass


def require(condition):
    if not condition:
        raise Refusal()


def sha(data):
    return 'sha256:' + hashlib.sha256(data).hexdigest()


def oid(kind, data):
    return hashlib.sha1(kind.encode() + b' ' + str(len(data)).encode() + b'\0' + data).hexdigest()


def valid_oid(value):
    return isinstance(value, str) and OID.fullmatch(value) and value != '0' * 40


def canonical(value):
    return (json.dumps(value, sort_keys=True, separators=(',', ':'), ensure_ascii=False) + '\n').encode()


def closed(value, keys):
    require(isinstance(value, dict) and set(value) == keys)


def pairs(items):
    result = {}
    for key, value in items:
        require(key not in result)
        result[key] = value
    return result


def private_read(path, parent, limit):
    require(path.parent.resolve() == parent)
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    try:
        info = os.fstat(fd)
        require(stat.S_ISREG(info.st_mode) and info.st_uid == os.getuid()
                and stat.S_IMODE(info.st_mode) == 0o600 and info.st_nlink == 1
                and info.st_size <= limit)
        data = os.read(fd, limit + 1)
        require(len(data) <= limit)
        return data
    finally:
        os.close(fd)


def parse(data):
    return json.loads(data, object_pairs_hook=pairs,
                      parse_constant=lambda _: require(False))


def encode(data):
    return base64.b64encode(data).decode('ascii')


def decode(value, limit):
    require(isinstance(value, str) and len(value) <= 4 * ((limit + 2) // 3))
    raw = base64.b64decode(value, validate=True)
    require(0 < len(raw) <= limit and encode(raw) == value)
    return raw


def validate_instruction(value, payload):
    closed(value, INSTRUCTION)
    require(type(value['format_version']) is int and value['format_version'] == 1)
    for key in INSTRUCTION - {'format_version'}:
        require(isinstance(value[key], str))
    for key in ('writeback_id', 'target_id'):
        require(UUID.fullmatch(value[key]))
    for key in ('record_digest', 'payload_digest', 'target_digest', 'expected_source_digest'):
        require(DIGEST.fullmatch(value[key]))
    require(valid_oid(value['expected_old_oid']) and sha(payload) == value['payload_digest'])
    path = value['path']
    parts = path.split('/')
    require(len(path.encode()) <= 1024 and 1 <= len(parts) <= 32)
    require(all(1 <= len(p.encode()) <= 255 and p not in ('.', '..')
                and p.lower() != '.git' for p in parts))
    require('\\' not in path and not any(unicodedata.category(c) == 'Cc' for c in path))
    ref = value['ref']
    require(ref.startswith('refs/heads/') and 1 <= len(ref[11:]) <= 200)
    require(all(re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_-]*', p) for p in ref[11:].split('/')))
    remote = value['remote']
    if re.fullmatch(r'https://github\.com/[A-Za-z0-9_-]+/[A-Za-z0-9_.-]+\.git', remote):
        require('/../' not in remote and '/./' not in remote)
        return True
    root_value = os.environ.get('WRITEBACK_LOCAL_ROOT')
    require(root_value and Path(root_value).is_absolute())
    root = Path(root_value).resolve()
    info = root.stat()
    require(info.st_uid == os.getuid() and stat.S_IMODE(info.st_mode) == 0o700)
    target = Path(remote)
    require(target.is_absolute() and target.resolve() == target and target != root
            and root in target.parents and target.is_dir())
    return False


class Git:
    def __init__(self, directory, https):
        self.directory = directory
        self.env = {'PATH': '/usr/bin:/bin', 'HOME': str(directory),
                    'GIT_CONFIG_NOSYSTEM': '1', 'GIT_CONFIG_GLOBAL': '/dev/null',
                    'GIT_TERMINAL_PROMPT': '0', 'GIT_ALLOW_PROTOCOL': 'https' if https else 'file'}
        if https:
            token_path = Path(os.environ.get('WRITEBACK_GIT_TOKEN_FILE', ''))
            token = private_read(token_path, token_path.parent.resolve(), 4096)
            require(re.fullmatch(rb'[A-Za-z0-9_]{16,4096}', token))
            askpass = directory / 'askpass'
            askpass.write_text('#!/bin/sh\ncase "$1" in *Username*) printf "%s" x-access-token;; *Password*) cat "$WRITEBACK_GIT_TOKEN_FILE";; *) exit 1;; esac\n')
            askpass.chmod(0o700)
            credential = directory / 'git-token'
            credential.write_bytes(token)
            credential.chmod(0o600)
            self.env.update(GIT_ASKPASS=str(askpass), WRITEBACK_GIT_TOKEN_FILE=str(credential))
        self.repo = directory / 'objects.git'
        self.command('init', '-q', '--bare', '--template=', '--object-format=sha1', str(self.repo), bare=False)
        self.command('config', 'core.hooksPath', str(directory / 'no-hooks'))
        self.command('config', 'credential.helper', '')
        self.command('config', 'http.followRedirects', 'false')

    def command(self, *args, data=None, bare=True, check=True):
        command = ['/usr/bin/git']
        if bare:
            command += ['--git-dir', str(self.repo)]
        result = subprocess.run(command + list(args), input=data, env=self.env,
                                stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=25)
        require(len(result.stdout) <= 4 * MIB)
        if check:
            require(result.returncode == 0)
        return result

    def fetch(self, instruction, revision):
        self.command('fetch', '-q', '--no-tags', '--depth=1', instruction['remote'], revision)

    def read(self, kind, object_id, limit):
        require(valid_oid(object_id))
        size = self.command('cat-file', '-s', object_id).stdout
        require(int(size) <= limit)
        raw = self.command('cat-file', kind, object_id).stdout
        require(oid(kind, raw) == object_id)
        return raw

    def blob_digest(self, object_id):
        require(valid_oid(object_id))
        require(self.command('cat-file', '-t', object_id).stdout == b'blob\n')
        size = int(self.command('cat-file', '-s', object_id).stdout)
        content = hashlib.sha256()
        framed = hashlib.sha1(b'blob ' + str(size).encode() + b'\0')
        process = subprocess.Popen(['/usr/bin/git', '--git-dir', str(self.repo),
                                    'cat-file', 'blob', object_id], env=self.env,
                                   stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        deadline = time.monotonic() + 25
        total = 0
        try:
            while True:
                remaining = deadline - time.monotonic()
                require(remaining > 0 and select.select([process.stdout], [], [], remaining)[0])
                chunk = os.read(process.stdout.fileno(), 65536)
                if not chunk:
                    break
                total += len(chunk)
                require(total <= size)
                content.update(chunk)
                framed.update(chunk)
            require(process.wait(timeout=max(0.001, deadline - time.monotonic())) == 0
                    and total == size and framed.hexdigest() == object_id)
            return 'sha256:' + content.hexdigest()
        finally:
            if process.poll() is None:
                process.kill()
            process.wait()
            process.stdout.close()

    def write(self, kind, raw):
        result = self.command('hash-object', '-w', '-t', kind, '--stdin', data=raw).stdout.decode().strip()
        require(result == oid(kind, raw))
        return result

    def head(self, instruction):
        result = self.command('ls-remote', '--refs', instruction['remote'], instruction['ref']).stdout
        lines = result.decode('ascii').splitlines()
        require(len(lines) == 1)
        value, ref = lines[0].split('\t')
        require(ref == instruction['ref'] and valid_oid(value))
        return value


def tree_entry(raw, name):
    offset = 0
    found = None
    while offset < len(raw):
        stop = raw.index(b'\0', offset)
        mode, entry = raw[offset:stop].split(b' ', 1)
        require(stop + 21 <= len(raw))
        if entry == name:
            require(found is None)
            found = (mode, raw[stop + 1:stop + 21].hex(), stop + 1)
        offset = stop + 21
    require(found is not None)
    return found


def path_chain(git, commit, path):
    raw = git.read('commit', commit, 16384)
    root = raw.split(b'\n', 1)[0]
    require(root.startswith(b'tree '))
    tree = root[5:].decode('ascii')
    chain = []
    parts = path.split('/')
    total = 0
    for index, part in enumerate(parts):
        raw = git.read('tree', tree, MIB)
        total += len(raw)
        require(total <= MIB)
        mode, target, offset = tree_entry(raw, part.encode())
        require(mode == (b'100644' if index == len(parts) - 1 else b'40000'))
        chain.append((raw, offset))
        tree = target
    return chain, tree


def commit_bytes(instruction, root):
    identity = 'AgentDoc Writeback <writeback@agentdoc.invalid> 946684800 +0000'
    return (f"tree {root}\nparent {instruction['expected_old_oid']}\nauthor {identity}\ncommitter {identity}\n\n"
            f"AgentDoc writeback\n\nwriteback_id: {instruction['writeback_id']}\nrecord_digest: {instruction['record_digest']}\n").encode()


def prepare(git, instruction, payload):
    git.fetch(instruction, instruction['expected_old_oid'])
    chain, old_blob = path_chain(git, instruction['expected_old_oid'], instruction['path'])
    require(git.blob_digest(old_blob) == instruction['expected_source_digest'])
    blob = git.write('blob', payload)
    child = blob
    trees = []
    for raw, offset in reversed(chain):
        changed = raw[:offset] + bytes.fromhex(child) + raw[offset + 20:]
        child = git.write('tree', changed)
        require(child not in [tree['oid'] for tree in trees])
        trees.append({'oid': child, 'bytes_base64': encode(changed)})
    commit = commit_bytes(instruction, child)
    material = {'format_version': 1, 'expected_old_oid': instruction['expected_old_oid'],
                'prepared_new_oid': git.write('commit', commit), 'commit_bytes_base64': encode(commit),
                'trees': trees, 'blob_oid': blob}
    require(len(canonical(material)) <= 2 * MIB)
    return material


def validate_material(material):
    closed(material, MATERIAL)
    require(type(material['format_version']) is int and material['format_version'] == 1)
    for key in ('expected_old_oid', 'prepared_new_oid', 'blob_oid'):
        require(valid_oid(material[key]))
    commit = decode(material['commit_bytes_base64'], 16384)
    require(oid('commit', commit) == material['prepared_new_oid'])
    require(isinstance(material['trees'], list) and 1 <= len(material['trees']) <= 32)
    total = 0
    seen = set()
    for tree in material['trees']:
        closed(tree, {'oid', 'bytes_base64'})
        require(valid_oid(tree['oid']) and tree['oid'] not in seen)
        seen.add(tree['oid'])
        raw = decode(tree['bytes_base64'], MIB)
        total += len(raw)
        require(total <= MIB and oid('tree', raw) == tree['oid'])


def observe(parent, https, instruction, material, payload):
    with tempfile.TemporaryDirectory(prefix='readback-', dir=parent) as directory:
        git = Git(Path(directory), https)
        current = git.head(instruction)
        if current != material['prepared_new_oid']:
            return {'format_version': 1, 'outcome': 'diverged', 'observed_oid': current}
        git.fetch(instruction, instruction['ref'])
        require(git.read('commit', current, 16384) == decode(material['commit_bytes_base64'], 16384))
        _, blob = path_chain(git, current, instruction['path'])
        require(blob == material['blob_oid'] and git.read('blob', blob, MIB) == payload)
        return {'format_version': 1, 'outcome': 'present', 'observed_oid': current}


def run(mode, instruction, payload, material, parent):
    https = validate_instruction(instruction, payload)
    with tempfile.TemporaryDirectory(prefix='writeback-', dir=parent) as directory:
        git = Git(Path(directory), https)
        git.command('check-ref-format', instruction['ref'], bare=False)
        if mode == 'prepare':
            require(git.head(instruction) == instruction['expected_old_oid'])
            return {'format_version': 1, 'outcome': 'prepared', 'material': prepare(git, instruction, payload)}
        validate_material(material)
        expected = prepare(git, instruction, payload)
        require(material == expected)
        if mode == 'observe':
            return observe(parent, https, instruction, material, payload)
        current = git.head(instruction)
        if current not in (instruction['expected_old_oid'], material['prepared_new_oid']):
            return {'format_version': 1, 'outcome': 'refused', 'observed_oid': current}
        if current == material['prepared_new_oid']:
            observed = observe(parent, https, instruction, material, payload)
            require(observed['outcome'] == 'present')
            return {'format_version': 1, 'outcome': 'applied', 'observed_oid': current}
        # Once push starts, any unclassified failure is ambiguous. Never retry it.
        try:
            pushed = git.command('push', '--porcelain',
                                 '--force-with-lease=' + instruction['ref'] + ':' + instruction['expected_old_oid'],
                                 instruction['remote'], material['prepared_new_oid'] + ':' + instruction['ref'], check=False)
            observed = observe(parent, https, instruction, material, payload)
            if observed['outcome'] == 'present':
                return {'format_version': 1, 'outcome': 'applied', 'observed_oid': observed['observed_oid']}
            rejected = any(line.startswith(b'!\t') and (b'[rejected] (stale info)' in line
                           or b'[remote rejected] (pre-receive hook declined)' in line
                           or b'[remote rejected] (hook declined)' in line) for line in pushed.stdout.splitlines())
            return {'format_version': 1, 'outcome': 'refused' if rejected else 'unknown',
                    'observed_oid': observed['observed_oid']}
        except (Refusal, OSError, ValueError, subprocess.SubprocessError):
            return {'format_version': 1, 'outcome': 'unknown', 'observed_oid': None}


def main():
    mode = sys.argv[1] if len(sys.argv) > 1 else ''
    require(mode in ('prepare', 'apply', 'observe') and len(sys.argv) == (5 if mode == 'prepare' else 6))
    instruction_path, payload_path, output = Path(sys.argv[2]), Path(sys.argv[3]), Path(sys.argv[-1])
    parent = instruction_path.parent.resolve()
    info = parent.stat()
    require(info.st_uid == os.getuid() and stat.S_IMODE(info.st_mode) == 0o700
            and output.parent.resolve() == parent and not output.exists() and not output.is_symlink())
    result = {'format_version': 1, 'outcome': 'refused', 'code': 'api.invalid_request'} if mode == 'prepare' else {
        'format_version': 1, 'outcome': 'unavailable' if mode == 'observe' else 'refused', 'observed_oid': None}
    try:
        instruction = parse(private_read(instruction_path, parent, 16384))
        payload = private_read(payload_path, parent, MIB)
        material = None if mode == 'prepare' else parse(private_read(Path(sys.argv[4]), parent, 2 * MIB))
        result = run(mode, instruction, payload, material, parent)
    except (Refusal, OSError, ValueError, TypeError, KeyError, subprocess.SubprocessError):
        pass
    fd, temporary = tempfile.mkstemp(prefix='.receipt-', dir=parent)
    try:
        with os.fdopen(fd, 'wb') as stream:
            stream.write(canonical(result))
            stream.flush()
            os.fsync(stream.fileno())
        os.link(temporary, output)
    finally:
        os.unlink(temporary)


if __name__ == '__main__':
    try:
        main()
    except (Refusal, OSError, ValueError, TypeError):
        sys.exit(1)
