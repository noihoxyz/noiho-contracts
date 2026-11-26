#!/usr/bin/env python3
"""Check that this source builds to the code deployed on HyperEVM mainnet.

Run `forge build` first. Immutable values are not in the compiled artifact, so the script
masks their positions, compares every other byte, and then checks the masked values
against the expected constructor arguments.
"""
import json
import sys
import urllib.request

RPC_URL = "https://rpc.hyperliquid.xyz/evm"
XMRN = 0xCB0E319F9E21221083023E3BC46BDDEE77C69B8F
BRIDGE = 0x610C866DE4B83525109EB1CBD744A7C3424638FE
RELAY = 0xC1800A67FF6E6E591D95F7D62C2F59D5639BDED7

CONTRACTS = [
    ("NoihoBridge", "out/solar/NoihoBridge.sol/NoihoBridge.json", BRIDGE, {XMRN}),
    ("CoreUnwrapRelay", "out/solar/CoreUnwrapRelay.sol/CoreUnwrapRelay.json", RELAY, {XMRN, BRIDGE, 86400}),
]


def deployed_code(address: int) -> bytes:
    body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": "eth_getCode", "params": [f"0x{address:040x}", "latest"]})
    request = urllib.request.Request(RPC_URL, body.encode(), {"Content-Type": "application/json"})
    with urllib.request.urlopen(request, timeout=30) as response:
        return bytes.fromhex(json.load(response)["result"][2:])


def verify(name: str, artifact_path: str, address: int, expected: set[int]) -> bool:
    artifact = json.load(open(artifact_path))["deployedBytecode"]
    built = bytearray.fromhex(artifact["object"][2:])
    onchain = bytearray(deployed_code(address))
    if len(built) != len(onchain):
        print(f"{name}: FAIL, length {len(built)} built vs {len(onchain)} deployed")
        return False
    found = set()
    for refs in artifact.get("immutableReferences", {}).values():
        for ref in refs:
            start, end = ref["start"], ref["start"] + ref["length"]
            found.add(int.from_bytes(onchain[start:end], "big"))
            built[start:end] = onchain[start:end] = bytes(ref["length"])
    if built != onchain:
        print(f"{name}: FAIL, bytecode differs")
        return False
    if found != expected:
        print(f"{name}: FAIL, immutables {sorted(hex(v) for v in found)}")
        return False
    print(f"{name}: OK, 0x{address:040x} matches ({len(built)} bytes)")
    return True


if __name__ == "__main__":
    results = [verify(*contract) for contract in CONTRACTS]
    sys.exit(0 if all(results) else 1)
