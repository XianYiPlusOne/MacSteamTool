#!/usr/bin/env python3
"""Reproduce the reviewed Intel profile; refuses a different client UUID.

Addresses were traced from the client registrations and calling functions;
this is not an automatic signature-discovery or update mechanism.
"""
import argparse
import bisect
import hashlib
import json
from pathlib import Path
from inspect_intel_steam import MachO

SITES = {
    'CCompatManager::Init': 0x67518a,
    'CCompatManager::BIsCompatibilityToolEnabled': 0x66d1f0,
    'CCompatManager::YldRegisterTool': 0x671374,
    'CCompatManager::FindToolForTargetApp': 0x66c832,
    'CCompatManager::GetValidPlatforms': 0x66b1d2,
    'CCompatManager::SetCompatToolMapping': 0x66c5ea,
    'CCompatManager::InternalSpecifyCompatTool': 0x66b6fe,
    'CCompatManager::FindMapping': 0x66c9fa,
    'CCompatManager::GetWildcardMapping': 0x66ca62,
    'CCompatManager::WindowsOnlyLookup': 0x66cf7c,
    'CCompatManager::GetOSListOverrideForApp.oslist_gate': 0x66cd29,
    'CCompatManager::ResolveCompatToolForApp.local_redirect': 0x66ce14,
    'CWebUIJobDispatcher::RegisterHandler': 0x9099c,
    'CWebUITransport::DispatchJob': 0x90b58,
    'CWebUIMsgJob::SendResponse': 0x91024,
    'CWebUITransport::RouteLookup': 0x90c64,
    'IntelWebUI::Registry': 0x90732,
    'IntelWebUI::Parse': 0xb3ada8,
    'IntelWebUI::Factory': 0x91498,
    'IntelWebUI::Constructor': 0x914c2,
    'IntelWebUI::Handler': 0x9153e,
    'IntelWebUI::Notify': 0x92d32,
}

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('client', type=Path)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    image = MachO(args.client)
    if image.uuid != '543c930a432c36fb998842214bd9d93c':
        parser.error('unreviewed client UUID')
    _, size, offset = image.sections['__TEXT', '__text']
    if hashlib.sha256(image.data[offset:offset+size]).hexdigest() != 'f7441f76d31662de80fe07eb2f6b45ac5cc1063c1d87d973031d5e631fdfe211':
        parser.error('client code differs from the reviewed input')
    signatures = []
    for name, address in SITES.items():
        index = bisect.bisect_right(image.functions, address) - 1
        start, end = image.functions[index:index+2]
        offset = image.offset(start)
        signatures.append(dict(name=name, func_addr_this_build=hex(address),
                               function_start=hex(start), function_size=hex(end-start),
                               function_sha256=hashlib.sha256(image.data[offset:offset+end-start]).hexdigest()))
    profile = dict(schema_version=4, profile_version=1, arch='x86_64', platform='macos',
                   steam_build='1794536281', module_uuid=image.uuid, signatures=signatures)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(profile, indent=2)+'\n')

if __name__ == '__main__':
    main()
