# Noiho contracts

Smart contracts for [Noiho](https://noiho.xyz), a bridge between Monero (XMR) and XMRn on
Hyperliquid's HyperEVM. XMRn is a 12-decimal token.

The contracts are immutable. They have no proxy, no upgrade path and no delegate calls.

## Mainnet deployments

HyperEVM mainnet, chain 999.

| Contract | Address | Source verification |
| --- | --- | --- |
| `NoihoBridge` | [`0x610C866DE4b83525109eB1cBd744a7c3424638fE`](https://hyperevmscan.io/address/0x610C866DE4b83525109eB1cBd744a7c3424638fE) | [Sourcify](https://repo.sourcify.dev/999/0x610C866DE4b83525109eB1cBd744a7c3424638fE) |
| `CoreUnwrapRelay` | [`0xC1800a67FF6e6e591D95f7d62c2f59d5639bDeD7`](https://hyperevmscan.io/address/0xC1800a67FF6e6e591D95f7d62c2f59d5639bDeD7) | [Sourcify](https://repo.sourcify.dev/999/0xC1800a67FF6e6e591D95f7d62c2f59d5639bDeD7) |
| XMRn token | [`0xcB0E319F9e21221083023E3Bc46bdDeE77c69B8F`](https://hyperevmscan.io/address/0xcB0E319F9e21221083023E3Bc46bdDeE77c69B8F) | Not in this repository |

The XMRn token is a LayerZero OFT and is not part of this repository.

## How the bridge works

- **Liquidity providers (LPs)** deposit XMRn into the bridge and publish their fees and limits.
- **Witnesses** post an XMRn bond. A witness checks each Monero payment and attests to it on chain.
- **Wrap (XMR → XMRn):** a user opens an order against an LP's liquidity and pays a witness fee in HYPE.
  The user sends XMR to the LP. The Monero transaction ID and transaction key are committed and
  then revealed on chain. After a witness attests, the bridge releases the XMRn to the user.
- **Unwrap (XMRn → XMR):** a user locks XMRn in the bridge with a Monero address. An LP takes the
  order and sends XMR. After the proof and a witness attestation, the LP receives the locked XMRn.
- **Disputes:** part of each witness bond is held for a dispute window after an attestation.
  The owner resolves a dispute. A witness at fault can lose the held bond.
- **Prices:** the HYPE/XMR rate for the witness fee floor comes from HyperCore's perp oracle
  precompile. The bridge caches the last good price.

`CoreUnwrapRelay` lets a user start an unwrap directly from HyperCore. HyperCore limits the gas
of its callback to HyperEVM (200k), and opening a bridge order needs more than that. The relay
holds the XMRn and stores a hash of the request. Anyone can then forward the request to the
bridge in a normal transaction. The user can reclaim the XMRn at any time, and anyone can
return it to the user after one day. The relay has no owner.

`src/interfaces/INoihoBridge.sol` lists the bridge's full external surface: functions, events
and errors.

## Owner controls

The bridge has an owner (two-step transfer). The owner can:

- pause and unpause the bridge;
- change time windows, the dispute bond threshold, the witness slash ratio and the oracle indices;
- resolve disputes and orders that are stuck;
- authorize contracts to open unwraps for a user (`requestUnwrapFor`);
- appoint the sanctions admins, who maintain the sanctions list, and move a sanctioned
  party's free stake to the sanctions vault;
- recover tokens sent by mistake. This excludes XMRn, which backs all custody.

The owner cannot change the XMRn token address or upgrade the code.

## Build

Use Foundry v1.9.0 (commit `6056c5845d34205a83cf7108042adb137325c9df`) with its bundled
Solar compiler, `0.8.38+commit.a2b44354.solar.0.3.0-dev`. The deployed bytecode was built
with Solar.

```sh
forge build --sizes
```

Solar code generation is experimental. `FOUNDRY_PROFILE=solc forge build` builds the same
source with solc 0.8.38 (via IR). That output is different bytecode and is not the deployed
build.

## Verify the deployed bytecode

Both contracts are verified on [Sourcify](https://sourcify.dev) from this source, with Solar
`0.8.38+commit.a2b44354.solar.0.3.0-dev`. The status is `match`, not `exact_match`, because the
build has no metadata hash. To check the bytecode yourself:

```sh
forge build
python3 script/verify-deployed.py
```

The script reads the deployed code from `https://rpc.hyperliquid.xyz/evm` and compares it
with the build, byte for byte. Immutable values (token, bridge and refund delay) are not in
the build output. The script masks their positions and checks them against the expected
constructor arguments. Expected output:

```
NoihoBridge: OK, 0x610c866de4b83525109eb1cbd744a7c3424638fe matches (15714 bytes)
CoreUnwrapRelay: OK, 0xc1800a67ff6e6e591d95f7d62c2f59d5639bded7 matches (1591 bytes)
```

The build sets `bytecode_hash = "none"` and `cbor_metadata = false`, so the bytecode has no
metadata hash and comments do not change it.

## Security

Report vulnerabilities privately to anon@noiho.xyz. Do not open a public issue.

## License

Copyright (c) 2026 Noiho. All rights reserved.

This source is published so that anyone can read it and verify the deployed contracts.
No license is granted to copy, modify, deploy or distribute it.

`_safeTransferETH` and `_safeTransfer` in `NoihoBridge.sol` derive from
[Solady](https://github.com/Vectorized/solady) SafeTransferLib (MIT). See `THIRD_PARTY_NOTICES`.
