#!/usr/bin/env python3
"""Report Intel Steam function candidates without generating runtime profiles.

Requires capstone (available in work/reverse-venv). String references and valid
instruction boundaries are evidence for review, not proof of ABI compatibility.
"""
import argparse
import bisect
import hashlib
import json
from pathlib import Path
import re
import struct

import capstone


class MachO:
    def __init__(self, path):
        data = Path(path).read_bytes()
        if data[:4] == bytes.fromhex('cafebabe'):
            if len(data) < 8:
                raise ValueError('Truncated fat header')
            count = struct.unpack_from('>I', data, 4)[0]
            if count > (len(data) - 8) // 20:
                raise ValueError('Truncated fat architecture table')
            selected = None
            for index in range(count):
                cpu, _, offset, size, _ = struct.unpack_from('>5I', data, 8 + 20 * index)
                if cpu == 0x1000007:
                    if offset + size > len(data):
                        raise ValueError('Truncated Intel slice')
                    selected = data[offset:offset + size]
                    break
            if selected is None:
                raise ValueError(f'{path}: no x86_64 slice')
            data = selected
        if len(data) < 32 or struct.unpack_from('<II', data) != (0xfeedfacf, 0x1000007):
            raise ValueError(f'{path}: expected a 64-bit Intel Mach-O')
        self.data = data
        self.segments = []
        self.sections = {}
        self.functions = []
        self.uuid = None
        self.base = None
        command_count, command_bytes = struct.unpack_from('<II', data, 16)
        end = 32 + command_bytes
        if end > len(data) or command_count > command_bytes // 8:
            raise ValueError('Invalid load command bounds')
        cursor = 32
        starts = None
        for _ in range(command_count):
            if cursor + 8 > end:
                raise ValueError('Truncated load command')
            command, size = struct.unpack_from('<II', data, cursor)
            if size < 8 or cursor + size > end:
                raise ValueError('Invalid load command size')
            if command == 0x1b and size >= 24:
                self.uuid = data[cursor + 8:cursor + 24].hex()
            if command == 0x19 and size >= 72:
                name, vm, vm_size, offset, file_size = struct.unpack_from('<16s4Q', data, cursor + 8)
                if offset + file_size > len(data):
                    raise ValueError('Truncated segment')
                self.segments.append((vm, vm_size, offset, file_size))
                if name.rstrip(b'\0') == b'__TEXT':
                    self.base = vm
                count = struct.unpack_from('<I', data, cursor + 64)[0]
                if count > (size - 72) // 80:
                    raise ValueError('Truncated section table')
                for index in range(count):
                    section, segment, address, length, file_offset = struct.unpack_from(
                        '<16s16sQQI', data, cursor + 72 + index * 80)
                    key = (segment.rstrip(b'\0').decode(), section.rstrip(b'\0').decode())
                    self.sections[key] = (address, length, file_offset)
            if command == 0x26 and size >= 16:
                starts = struct.unpack_from('<II', data, cursor + 8)
            cursor += size
        if self.base is None or self.uuid is None or not starts:
            raise ValueError('Need __TEXT, LC_UUID and LC_FUNCTION_STARTS')
        offset, size = starts
        if offset + size > len(data):
            raise ValueError('Truncated function-start table')
        address, delta, shift = self.base, 0, 0
        for byte in data[offset:offset + size]:
            if shift >= 64:
                raise ValueError('Invalid function-start delta')
            delta |= (byte & 127) << shift
            if byte & 128:
                shift += 7
                continue
            if delta == 0:
                break
            address += delta
            self.functions.append(address)
            delta = shift = 0
        if not self.functions:
            raise ValueError('Empty function-start table')

    def offset(self, address):
        for vm, _, offset, size in self.segments:
            if vm <= address < vm + size:
                return offset + address - vm
        raise ValueError(f'Address outside file-backed segments: {address:x}')

    def address(self, offset):
        for vm, _, start, size in self.segments:
            if start <= offset < start + size:
                return vm + offset - start
        raise ValueError(f'File offset outside segments: {offset:x}')

    def references(self, values):
        targets = {}
        for value in values:
            position = 0
            encoded = value.encode() + b'\0'
            while True:
                position = self.data.find(encoded, position)
                if position < 0:
                    break
                targets[self.address(position)] = value
                position += 1
        address, size, offset = self.sections[('__TEXT', '__text')]
        if offset + size > len(self.data):
            raise ValueError('Truncated code section')
        code = self.data[offset:offset + size]
        found = {value: [] for value in values}
        decoder = capstone.Cs(capstone.CS_ARCH_X86, capstone.CS_MODE_64)
        # Candidate RIP-relative LEAs; confirm their instruction boundaries below.
        pattern = b'[\x48-\x4f]\x8d[\x05\x0d\x15\x1d\x25\x2d\x35\x3d]'
        for match in re.finditer(pattern, code):
            position = match.start()
            if position + 7 > len(code):
                continue
            site = address + position
            target = site + 7 + struct.unpack_from('<i', code, position + 3)[0]
            if target not in targets:
                continue
            index = bisect.bisect_right(self.functions, site) - 1
            if index < 0:
                continue
            function = self.functions[index]
            if not address <= function <= site:
                continue
            start = self.offset(function)
            instructions = decoder.disasm(self.data[start:offset + position + 7], function)
            if any(insn.address == site and insn.size == 7 and insn.mnemonic == 'lea'
                   for insn in instructions):
                found[targets[target]].append({
                    'reference': hex(site), 'function': hex(function),
                    'entry_hex': self.data[start:start + 32].hex(' '),
                })
        return found


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--modules', type=Path, required=True, help='Steam Contents/MacOS directory')
    parser.add_argument('--profiles', type=Path, nargs='+', required=True, help='Reference profiles, used for string names only')
    parser.add_argument('--output', type=Path, required=True, help='Analysis report, not a runtime profile')
    args = parser.parse_args()
    signatures = []
    for profile in args.profiles:
        signatures.extend(json.loads(profile.read_text())['signatures'])
    report = {
        'analysis_only': True, 'deployable': False, 'modules': {},
        'limitations': [
            'String references are candidates, not reviewed ABI matches.',
            'No hooks, code patching, IPC session or game writes are performed.',
            'Profiles without string anchors require separate analysis.',
        ],
    }
    for module in sorted({entry.get('module', 'steamclient.dylib') for entry in signatures}):
        if Path(module).name != module:
            raise ValueError('Module must be a basename')
        image = MachO(args.modules / module)
        entries = [entry for entry in signatures if entry.get('module', 'steamclient.dylib') == module]
        values = {entry['anchor']['value'] for entry in entries
                  if isinstance(entry.get('anchor', {}).get('value'), str)}
        references = image.references(values)
        candidates = {entry['name']: references[entry['anchor']['value']] for entry in entries
                      if entry.get('anchor', {}).get('value') in references}
        report['modules'][module] = {
            'uuid': image.uuid, 'sha256': hashlib.sha256(image.data).hexdigest(),
            'architecture': 'x86_64', 'function_count': len(image.functions),
            'candidates': candidates,
            'without_string_anchor': [entry['name'] for entry in entries
                                      if entry.get('anchor', {}).get('value') not in references],
        }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2) + '\n')
    for module, data in report['modules'].items():
        count = sum(bool(value) for value in data['candidates'].values())
        print(f"{module}: {count}/{len(data['candidates'])} string-anchor groups have Intel candidates; UUID {data['uuid']}")
    print('Analysis only: no runtime profiles generated or installed.')


if __name__ == '__main__':
    main()
