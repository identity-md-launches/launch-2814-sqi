# SqueekCore V3 read interface

`SqueekCore.readonly.json` is the four-function subset of the [published ABI](https://docs.squeekchain.com/assets/abi/SqueekCore.json), retrieved 2026-11-01. Its field order and types match `src/interfaces/ISqueekCore.sol`; no write functions are exposed.

The [official reference](https://docs.squeekchain.com/developers/core/) supplies the sparse-page semantics. `roundPage(afterRound, throughRound, maxRecords)` uses an exclusive lower bound and inclusive upper bound. When the requested page cannot fit another active record, certification stops just before that record. A consumer must use the returned certification cursor.

The evidence in `../evidence/sepolia-core-snapshot.json` contains raw calldata and responses captured at a single Sepolia block, with its hash and timestamp. A 144-round window at rounds 1830–1973 has 19 active records and 125 zero-work rounds. Its first page is certified only through round 1907 despite requesting through 1973; the next page completes it.

`test/RecordedCore.t.sol` embeds those same responses so ABI decoding and page traversal are exercised without RPC access. This records compatibility at one historical block; it is not a promise of current availability or an independent authentication of upstream facts. Recheck the dependency before launch.
