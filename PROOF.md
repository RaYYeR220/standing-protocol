# Proof

Every claim below is a link. Nothing here is a screenshot, a recording or a number typed by hand —
each line is a transaction you can open, or a call you can repeat.

---

## Deployed and live

**Monad testnet — chain id 10143**

| Contract | Address |
|---|---|
| `CreditManager` | [`0xC6E2aC49a18BfB71F2981efeaac2aC41Db1c1f74`](https://testnet.monadexplorer.com/address/0xC6E2aC49a18BfB71F2981efeaac2aC41Db1c1f74) |
| `StandingPool` | [`0x010263d8e3b2DC38F63A3f1660D2502f204ffB6D`](https://testnet.monadexplorer.com/address/0x010263d8e3b2DC38F63A3f1660D2502f204ffB6D) |
| `StandingRegistry` | [`0x2bD8832C9Bc98df47F256507a903B0338D96C0b5`](https://testnet.monadexplorer.com/address/0x2bD8832C9Bc98df47F256507a903B0338D96C0b5) |

**Base Sepolia — chain id 84532** · the same source, unchanged

| Contract | Address |
|---|---|
| `CreditManager` | [`0x324719787E22a7c2c3E77bc84484317c2D2D1093`](https://sepolia.basescan.org/address/0x324719787E22a7c2c3E77bc84484317c2D2D1093) |
| `StandingPool` | [`0x5ae228215dae30EC07D0196B13179CFA00146D03`](https://sepolia.basescan.org/address/0x5ae228215dae30EC07D0196B13179CFA00146D03) |
| `StandingRegistry` | [`0xE066669d09afd30444429003987b9E7BcA970F19`](https://sepolia.basescan.org/address/0xE066669d09afd30444429003987b9E7BcA970F19) |

Cleanverse deploys the same addresses on both chains, so the protocol is bound to the identical
A-Pass registry, policy engine, validator and aUSDC on each. Nothing about the integration is
chain-specific.

---

## The protocol is a verified participant of the network

Not a claim about the design — a pair of reads anyone can repeat:

```bash
cast call 0xC6E2aC49a18BfB71F2981efeaac2aC41Db1c1f74 "checkParty(address)(bool,uint8)" \
  0x010263d8e3b2DC38F63A3f1660D2502f204ffB6D --rpc-url https://testnet-rpc.monad.xyz
# -> true 0     the pool holds its own A-Pass

cast call 0x010263d8e3b2DC38F63A3f1660D2502f204ffB6D "isProtocolRegistered()(bool)" \
  --rpc-url https://testnet-rpc.monad.xyz
# -> true       and carries its own rule set at Cleanverse's validator
```

Cleanverse's policy engine checks both ends of a transfer, so a protocol that moves verified assets
is a party to every one of them. It has to hold a credential of its own or the gate refuses
everything — which is what it did until we obtained one.

---

## An under-collateralized loan, on a live chain

Base Sepolia, all within the build window. Read them in order.

| Step | Transaction |
|---|---|
| Lender approves the pool | [`0x593b6e5f…`](https://sepolia.basescan.org/tx/0x593b6e5f8c90127a9dd5f5c390b959bb32110107a007e6e4a8e5cacaf3ae1ab5) |
| **Lender deposits 20 aUSDC** — gate passes, shares minted | [`0x2613a64b…`](https://sepolia.basescan.org/tx/0x2613a64b989582fb6400b226d1f0b0c83d6849c7e915a6805cbcf1c2af3b90cf) |
| Borrower approves the credit manager | [`0x37e59b7d…`](https://sepolia.basescan.org/tx/0x37e59b7d4a1ac7ce17e0623136eb3456eb92703f7ca1a9274b14f5a48560dce7) |
| **Borrower draws 3 aUSDC against 2.3658 aUSDC of collateral** | [`0xea340ac8…`](https://sepolia.basescan.org/tx/0xea340ac87d37f532caed0786e356be0cb069ef78978480710f0e326aef9eb137) |
| **Borrower repays** — loan closes, interest lands on the share price | [`0xbfab48bd…`](https://sepolia.basescan.org/tx/0xbfab48bda6d4c0e69e0282bcf441639fab65f5d957b3355244034c7dd863c8df) |
| **A second, larger draw** — 5 aUSDC against 3.943, still open | [`0xe1cd60aa…`](https://sepolia.basescan.org/tx/0xe1cd60aa0b30b718af104d05ca70837c5b9e926fc2b246a3ed0c49a01f0b1655) |

The book now holds one repaid loan and one live one, at 26.93% utilization — the console's loan-book
screen on Base Sepolia is reading exactly that.

The draw is the one that matters. The borrower received **3.000000 aUSDC** and posted
**2.365800 aUSDC** — **78.86%** of the principal. The missing 21% is not collateralized by anything.
It is carried by a bank-verified credential that the borrower loses standing against if they walk
away, and that follows them to every wallet they ever open.

The underwriting behind it, from `quote()` at that block — every number computed on-chain from
on-chain state:

```
score                310 / 1000
  tier points        210     (A-Pass tier 50, band ≥45)
  sub-tier points      0
  tenure points        0     (credential issued the same day)
  history              0     (first loan)
  assets             100     (100 aUSDC verified holdings, base-10 ladder)
credit line     5,642.857142 aUSDC
collateral         2.365800 aUSDC   for a 3.000000 principal
APR                  24.72%
```

Afterwards: pool `totalAssets` 20.060953 aUSDC, `lifetimeInterest` 0.060953 aUSDC, assets per share
**1.000000 → 1.003047**. The interest went to the lender, not to a treasury.

---

## The compliance rule is live, and an operator can move it

The sharpest single result of the build. With the pool registered at Cleanverse's validator, we
raised `min_tier` to 60 through the REST API and watched the **on-chain** verdict for a tier-50
wallet flip, then restored it:

```
0xaf375463(pool, 0x9E28…1d98)  ->  1     rule: min_tier 0
POST /validator/set_rule       ->  min_tier 60
0xaf375463(pool, 0x9E28…1d98)  ->  0     next block, no redeploy, no upgrade
POST /validator/set_rule       ->  min_tier 0
0xaf375463(pool, 0x9E28…1d98)  ->  1
```

That is condition 4 of the gate. The protocol carries its own compliance policy, enforced by
Cleanverse's contract rather than reimplemented in ours, and an operator can tighten who may borrow
or lend without touching the code.

---

## Refusals

The gate names the failing party and the failing condition. On either chain:

```bash
cast call 0xC6E2aC49a18BfB71F2981efeaac2aC41Db1c1f74 \
  "checkTransferDetailed(address,address,uint256)(bool,uint8,address)" \
  0x010263d8e3b2DC38F63A3f1660D2502f204ffB6D \
  0xABc0000000000000000000000000000000000123 1000000 \
  --rpc-url https://testnet-rpc.monad.xyz
# -> false 1 0xAbC0…0123     NoCredential, and it says whose fault it is
```

And Cleanverse's own engine, refusing by reverting rather than returning false:

```bash
forge script script/InspectCleanverse.s.sol --rpc-url https://testnet-rpc.monad.xyz
# canTransfer(aUSDC, credentialed -> uncredentialed):
#   -> reverted, 36 bytes of custom error:
#   0xa6725971000000000000000000000000abc0000000000000000000000000000000000123
```

A protocol that does not handle that either breaks or ignores it. Ours treats it as a deny.

---

## The full lifecycle, including a default

A default takes a matured loan plus a three-day grace period, which does not fit inside a
hackathon. So the write-off is demonstrated on a fork of the live chain, with compressed time and
**no mocks** — the A-Pass registry, the policy engine, the validator and aUSDC are all the real
deployments:

```bash
forge script script/Demo.s.sol --rpc-url https://testnet-rpc.monad.xyz -vv
```

```
== 4. repayment, and standing grows ==
assets per share 1000000 -> 1006901
score after one repayment  522
collateral now required    2942000000 (was higher)

== 5. a default, and what it costs the identity ==
loan #2 defaultable: true
assets per share 1006901 -> 976031
  the loss lands on lenders, not a reserve
pool lifetime losses       1234800000
borrower score after default 276
still eligible               false
```

`CLAIMS.md` documents exactly which two role-holders that script impersonates and why — nothing else
in it is simulated.

---

## Tests

```bash
cd contracts && forge test
```

Unit, invariant and forked-network suites. The fork suite runs against live Monad state and skips
cleanly without an RPC. We are deliberately not quoting a pass count here that could drift from what
the command prints.
