#!/usr/bin/env python3
"""Reject instrumentation APKs that could shadow the target's shrunk libraries."""
import argparse
import hashlib
import json
import pathlib
import struct
import zipfile


def verify(apk):
    names = []
    with zipfile.ZipFile(apk) as archive:
        assert not any(name.endswith('.so') for name in archive.namelist()), 'Harness must not add native libraries'
        for filename in archive.namelist():
            if not filename.endswith('.dex'): continue
            dex = archive.read(filename)
            assert dex.startswith(b'dex\n') and len(dex) >= 112

            def word(offset):
                return struct.unpack_from('<I', dex, offset)[0]

            string_count, strings = word(56), word(60)
            type_count, types = word(64), word(68)
            count, classes = word(96), word(100)
            for index in range(count):
                type_index = word(classes + index * 32)
                assert type_index < type_count
                string_index = word(types + type_index * 4)
                assert string_index < string_count
                offset = word(strings + string_index * 4)
                for _ in range(5):
                    value = dex[offset]; offset += 1
                    if value < 128: break
                else: raise AssertionError('Malformed DEX string length')
                name = dex[offset:dex.index(b'\x00', offset)].decode('utf-8')
                # D8 adds this marker annotation for Java lambdas. It contains
                # no runtime implementation; do not allow other foreign types.
                tool_annotation = (name == 'Lcom/android/tools/r8/annotations/LambdaMethod;'
                                   and word(classes + index * 32 + 4) & 0x2000 != 0)
                assert name.startswith('Lcom/doctordurant/xmwatch/metareleaseharness/') or tool_annotation, 'Harness shadows target class: ' + name
                names.append(name)
    assert 'Lcom/doctordurant/xmwatch/metareleaseharness/MetaGlassesInstrumentation;' in names
    return dict(status='passed', apk_sha256=hashlib.sha256(pathlib.Path(apk).read_bytes()).hexdigest(),
                defined_classes=len(names), no_shared_runtime_classes=True, class_names=sorted(names))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('apk', type=pathlib.Path)
    print(json.dumps(verify(parser.parse_args().apk), indent=2))
