# Vendored sources

All imports resolve inside this repository. There are no submodules, package-manager dependencies, network-dependent tests, linked external libraries or binary dependencies in the deliverable.

| Dependency | Pin | Included source | License |
| --- | --- | --- | --- |
| OpenZeppelin Contracts | v5.1.0 | Dependency closure for ERC20, Ownable2Step, SafeERC20, ReentrancyGuard, Math | [MIT](lib/openzeppelin-contracts/LICENSE) |
| Forge standard library | v1.9.7 | Complete `src/` | [MIT](lib/forge-std/LICENSE-MIT) / [Apache-2.0](lib/forge-std/LICENSE-APACHE) |

The source archives came from [OpenZeppelin's v5.1.0 release](https://github.com/OpenZeppelin/openzeppelin-contracts/tree/v5.1.0) and [forge-std v1.9.7](https://github.com/foundry-rs/forge-std/tree/v1.9.7). The vendored Solidity files carry no logic changes, but `forge fmt` reflowed whitespace in 23 of the 50 files (among them `SafeERC20.sol`, `Address.sol`, `Math.sol`, `IERC1363.sol` and nineteen forge-std files), so they are not byte-identical to upstream. `dependency-checksums.json` records the SHA-256 of the upstream release archives and the SHA-256 of each vendored file **as shipped in this tree**; the file digests therefore verify the tree, while provenance against upstream is checked by diffing with whitespace ignored.

The pinned external read ABI comes from [Squeekchain's published SqueekCore ABI](https://docs.squeekchain.com/assets/abi/SqueekCore.json). Only the four read functions used by this application are retained. This is an interface dependency, not code deployed by this project.
