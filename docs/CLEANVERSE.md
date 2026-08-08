# The Cleanverse stack, on-chain

Cleanverse ships an excellent REST API and no ABI. Every integration guide it publishes has your
server POST a wallet address to `/query_apass`, read a JSON body, and act on it. That works fine for
a payments backend. It does not work for a lending contract, because a contract cannot call a REST
API — which means a protocol built that way has to trust an off-chain relayer to tell the truth
about who a borrower is, and about whether a transfer is allowed.

Standing needed the credential and the compliance verdict *inside the transaction*. So we went and
found them on-chain.

This document records what is there, how we established it, and where the limits of our knowledge
are. Everything here was verified against live state on Monad; nothing is inferred from marketing
material.

---

## 1. Deployed contracts

Cleanverse deploys the same addresses on every EVM chain it supports (verified identical on Monad
testnet 10143, Monad mainnet 143, and Base). All four are ERC-1967 proxies compiled with Solidity
0.8.30.

| Role | Address | Reached via |
|---|---|---|
| A-Pass registry (CVI) | `0xbA82D189540CaC9DC6FF46B6837CaC1BFdEC58B9` | `Policy.apass()` |
| Policy engine (CCP) | `0x36489bE45fa84f70a0c2BDB11D824Be608CB12Dd` | `aUSDC.policy()` |
| aUSDC (CVA) | `0xaC0893567D43C3E7e6e35a72803df05416C1f20D` | `/query_deposit_atoken_list` |
| AccessCore | `0x8F118338a1fa41E7Fa86Be19A4e8B99Ed58A6EcC` | `/query_deposit_atoken_list` |

Method: read the ERC-1967 implementation slot
(`0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc`), pull the implementation
runtime bytecode, and extract the four-byte selectors from its dispatch table. Most resolve against
public signature databases; the ones that do not are documented below by selector.

---

## 2. The policy engine is a public view

This is the finding the protocol is built on.

```solidity
interface ICleanversePolicy {
    function canTransfer(address token, address from, address to, uint256 amount) external view returns (bool);
    function getRule(address token) external view returns (...);
    function getRules(address token) external view returns (...);
    function isFrozen(address token, address account) external view returns (bool);
    function isPaused(address token) external view returns (bool);
    function isTokenRegistered(address token) external view returns (bool);
    function registerToken(address token) external;
    function apass() external view returns (address);
}
```

`canTransfer` is the same verdict the REST endpoint `/validator/verify` returns, evaluated by the
same contract — except a contract can call it. Argument order was established empirically: the
`(token, from, to, amount)` ordering answers, and the `(from, to, token, amount)` permutation
reverts.

Two behaviours worth knowing before you build on it:

- **It checks both ends.** A transfer from a party without a credential is refused even if the
  recipient is impeccable. This is why the pool contract itself needs an A-Pass — it is a sender.
- **It reverts rather than returning false** when a party has no credential at all, with a custom
  error `0xa6725971(address)`. A caller that does not handle that reverts with it. `ComplianceGate`
  wraps every policy call in `try/catch` and treats a revert as a refusal, which is the only safe
  reading: an unanswerable compliance question is not a permission.

### Rules are per registered contract

`getRules(aUSDC)` is empty, so `canTransfer` on the bare asset only enforces credential existence.
Rules attach to *registered* contracts. `POST /validator/register` registers a contract address as a
policy subject and attaches a rule to it (`min_tier`, `min_sub_tier`, `allowed_group`,
`allowed_sub_group`, `countries`, `is_black_list`), after which
`canTransfer(thatContract, from, to, amount)` evaluates the rule against the counterparties'
credentials.

That is a genuinely useful primitive: it lets a protocol carry its own compliance rule set,
enforced by Cleanverse's contract rather than by its own code, and changeable by an operator without
a redeploy. `ComplianceGate` consults it whenever `isTokenRegistered(address(this))` is true.

Registration requires proof of ownership. The signature format is undocumented; it is
EIP-191 `personal_sign` over `lowercase(chain) + lowercase(contract_address)` — for example
`"monad0xcf26de720bcc4f39508039127baf35f8f9300fc4"`. The registered contract must expose
`owner()`, which is why ours does (it grants no authority; see `ComplianceGate`).

---

## 3. A-Pass is an ERC-721 with readable attributes

The credential is a non-transferable ERC-721. `getTokenId(address) → uint256` returns
`uint160(account)`: the token id *is* the address, so there is no lookup table to maintain.

Attributes come from a getter whose source-level name Cleanverse does not publish. It is bound by
raw selector:

```
0x6a069f61(uint256 tokenId) → ten 32-byte words
```

| word | field | notes |
|---|---|---|
| 0 | `status` | 0 uninitialized · 1 active · 2 frozen |
| 1 | `tier` | 0–99, set by the issuing institution |
| 2 | `subTier` | 0–99 |
| 3 | `group` | `bytes2` tag |
| 4 | `subGroup` | `bytes2` tag |
| 5 | `expirationTime` | unix seconds |
| 6 | `issuedAt` | unix seconds, updated on re-verification |
| 7 | previous KYC hash | zero on a fresh credential |
| 8 | **`currentKycHash`** | hash of the bank-verified identity |
| 9 | countries | packed; see limits below |

**Validation.** We minted a credential through `POST /generate_apass`, read the same wallet through
`POST /query_apass`, and decoded word-for-word against the on-chain return. `status`, `tier`,
`subTier`, `expirationTime` and `currentKycHash` match exactly. For wallet
`0x9E2816003da34Ea0E232Fb59A5e475Fce1121d98`: REST reports
`status 1, tier "50", subTier 0, expirationTime 1817700915, currentKycHash 0xa154aff8…78c0c`; the
registry returns the same values in words 0, 1, 2, 5 and 8.

`ApassReader` decodes this and never reverts — a missing or malformed record comes back as
`exists == false`, so "no credential" is an ordinary deny rather than an exception.

### Why the protocol keys reputation to `currentKycHash`

An address-keyed reputation system is worthless as collateral: default, fund a new wallet, start
again. `currentKycHash` is derived from the underlying bank-verified identity rather than from the
key, so it is the natural anchor for a credit record that is supposed to *cost* something to
abandon. `StandingRegistry` is keyed to it, and `CreditManager` tracks exposure per identity rather
than per wallet.

---

## 4. aUSDC

An ERC-20 with `MINTER_ROLE`, `mint`/`burn`, and `policy()` / `setPolicy(address)`. Six decimals.
Compliance is delegated entirely to the policy contract, which is what makes a verified asset
composable: any contract can pre-check a movement with the same view the token itself defers to.

Origin USDC is wrapped into aUSDC by `AccessCore` when funds arrive at a per-wallet deposit address
from a whitelisted sender. `/query_deposit_address` returns the deposit address for a given wallet.
A transfer from a non-whitelisted sender is recorded by the API as `non_whitelist_transfer` and
mints nothing.

---

## 5. What we could not establish

Stated plainly, because an integration document that only lists successes is not much use.

- **The attribute getter's name.** We have its selector, its argument and its return layout, all
  verified. We do not have its name; a brute-force search over roughly a thousand plausible
  signatures did not hit it. The binding is by selector, and would break if Cleanverse upgraded the
  implementation behind the proxy with a different layout.
- **Word 9, the country list.** It is populated on credentials that carry identity documents and
  zero on ones that do not, but we could not confirm its packing well enough to decode it safely, so
  the protocol does not read it. Jurisdiction is enforced the right way round anyway: through
  `canTransfer`, where Cleanverse applies its own country rules, rather than by us re-implementing
  them.
- **Whether the Monad mainnet deployment is the same tenancy.** The addresses and code are identical
  and aUSDC has supply there, but our sandbox credentials mint into testnet, so we have not
  exercised mainnet.

---

## 6. Reproducing this

`script/InspectCleanverse.s.sol` performs the reads above against a live RPC and prints them:

```bash
forge script script/InspectCleanverse.s.sol --rpc-url https://testnet-rpc.monad.xyz
```

No credentials required — it is all public state.
