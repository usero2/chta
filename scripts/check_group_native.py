"""Exercise the released JSON/FFI group and DM gateways in disposable processes."""
import ctypes
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile


def worker(dll):
    library = ctypes.CDLL(dll)
    library.cht_call.argtypes = [ctypes.c_char_p]
    library.cht_call.restype = ctypes.c_void_p
    library.cht_free_string.argtypes = [ctypes.c_void_p]
    for line in sys.stdin:
        pointer = library.cht_call(line.encode())
        try:
            response = ctypes.string_at(pointer).decode()
        finally:
            library.cht_free_string(pointer)
        print(response, flush=True)


def main(dll):
    processes = []
    with tempfile.TemporaryDirectory(prefix='chta-groups-native-') as temporary:
        def spawn(label):
            env = dict(os.environ, APPDATA=str(Path(temporary) / label), LOCALAPPDATA=str(Path(temporary) / label))
            p = subprocess.Popen([sys.executable, __file__, '--worker', dll], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True, env=env)
            processes.append(p)
            return p

        def rpc(p, command, **args):
            p.stdin.write(json.dumps({'command': command, 'args': args}) + '\n')
            p.stdin.flush()
            result = json.loads(p.stdout.readline())
            if not result['ok']:
                raise RuntimeError(result['error'])
            return result['value']

        def group(p, operation, **args):
            return rpc(p, 'groupCall', operation=operation, args=args)

        try:
            a, b = spawn('a'), spawn('b')
            identities = []
            for p in (a, b):
                pending = rpc(p, 'createIdentity')
                identities.append(rpc(p, 'confirmRecovery', phrase=pending['mnemonic'])['id'])
                del pending
            ai, bi = identities
            ac, bc = (rpc(p, 'contactCard', displayName='Synthetic native QA') for p in (a, b))
            for p, card, peer in ((a, bc, bi), (b, ac, ai)):
                rpc(p, 'addContact', cardJson=card, displayName='Synthetic peer')
                rpc(p, 'markContactVerified', identityId=peer)
            for context in ('groups', 'dm-v2'):
                sid = 'e' * 32
                group(a, 'prepare', peerId=bi, sessionId=sid, initiator=True, context=context)
                group(b, 'prepare', peerId=ai, sessionId=sid, initiator=False, context=context)
                first = group(a, 'start', peerId=bi, sessionId=sid, context=context)['frame']
                response = group(b, 'handshake', peerId=ai, sessionId=sid, context=context, frame=first)
                assert response['established']
                assert group(a, 'handshake', peerId=bi, sessionId=sid, context=context, frame=response['reply'])['established']
                frame = group(a, 'encrypt', peerId=bi, sessionId=sid, context=context, id='proof-' + context, text='synthetic private payload')['frame']
                assert group(b, 'decrypt', peerId=ai, sessionId=sid, context=context, frame=frame)['text'] == 'synthetic private payload'
            state = group(a, 'create', name='Synthetic native group', displayName='A', now=1000)['state']
            gid = json.loads(state)['groupId']
            invitation = group(a, 'invite', groupId=gid, peerId=bi, now=1001)['invite']
            receipt = group(b, 'accept', invite=invitation, displayName='B', now=1002)['receipt']
            added = group(a, 'add', receipt=receipt, now=1003)['state']
            group(b, 'apply', state=added)
            assert len(group(b, 'view', groupId=gid)['members']) == 2
            payload = 'synthetic encrypted group history'
            rpc(a, 'saveGroupBlob', ownerId=ai, key='qa-proof', value=payload)
            assert rpc(a, 'loadGroupBlob', ownerId=ai, key='qa-proof') == payload
            for file in Path(temporary).rglob('*.bin'):
                assert payload.encode() not in file.read_bytes()
            print(json.dumps({'ok': True, 'ffiContexts': ['groups', 'dm-v2'], 'members': 2, 'encryptedNativeBlob': True}))
        finally:
            for p in processes:
                p.stdin.close()
                p.wait(timeout=10)


if __name__ == '__main__':
    if sys.argv[1] == '--worker':
        worker(sys.argv[2])
    else:
        main(str(Path(sys.argv[1]).resolve()))
