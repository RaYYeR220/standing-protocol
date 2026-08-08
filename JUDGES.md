# Review this in five minutes

Everything below runs with no API keys, no accounts and no wallet funding. If you only do one
thing, do step 2 — or watch the [three-minute demo](https://standing-console.vercel.app/demo/standing-demo.mp4).

---

## 1. What it is, in thirty seconds

Under-collateralized credit where the Cleanverse A-Pass is the collateral. Not "DeFi with a KYC
gate" — under-collateralized lending is the one DeFi primitive that is *impossible* without verified
identity, because without recourse a lender has to demand more than they lend. Remove Cleanverse and
this product cannot exist.

The technical claim behind it: **Cleanverse's identity and compliance are readable on-chain**, even
though the documentation only describes a REST API. We recovered both interfaces from deployed
bytecode, so the protocol enforces identity and compliance *inside the transaction* rather than
trusting a relayer to have checked earlier.

---

## 2. Verify the technical claim yourself — 60 seconds

```bash
cd contracts
forge script script/InspectCleanverse.s.sol --rpc-url https://testnet-rpc.monad.xyz
```

Public state only. It prints:

- `aUSDC.policy()` and `policy.apass()` resolving to the Cleanverse contracts;
- a real A-Pass credential decoded from the registry — status, tier, expiry, KYC hash — for wallet
  `0x9E2816003da34Ea0E232Fb59A5e475Fce1121d98`, which you can cross-check against Cleanverse's own
  `/query_apass` response quoted in [`docs/CLEANVERSE.md`](docs/CLEANVERSE.md);
- `canTransfer` returning `true` between two credentialed parties, and **reverting** with
  `0xa6725971(address)` when either party is uncredentialed.

That last one is the whole design in one line: the compliance engine refuses by reverting, so a
protocol that does not handle it either breaks or ignores it. Ours treats it as a deny.

---

## 3. Watch the product work — 90 seconds

```bash
forge script script/Demo.s.sol --rpc-url https://testnet-rpc.monad.xyz -vv
```

A fork of Monad testnet, running against the **live** Cleanverse contracts. Credentials are issued
by impersonating Cleanverse's own issuer wallet through their own registry function; aUSDC is minted
by impersonating AccessCore, which holds `MINTER_ROLE`. Nothing is mocked or stubbed — see
[`CLAIMS.md`](CLAIMS.md) for the exact line between real and impersonated, and why.

Five steps print in order:

1. a verified lender supplies 40,000 aUSDC;
2. a borrower is underwritten from on-chain state alone — score 435/1000 with every component
   itemised — and draws 5,000 aUSDC having posted **69%** of it as collateral;
3. four refusals: an uncredentialed recipient, a draw above the protocol ceiling, a draw beyond the
   borrower's line, and a draw by a wallet with no credential;
4. repayment — the share price rises by exactly the interest, score 435 → 522, collateral required falls;
5. a default — the share price drops below par (the loss lands on lenders, not a reserve),
   score 522 → 276, and the borrower is no longer eligible.

   The share-price figures drift between runs because the script warps time on the fork; the scores
   are identical every time.

Step 5 is the point of the protocol. The cost of defaulting is written against the *identity*, so it
survives the borrower abandoning that wallet — and because Cleanverse re-issues credentials under a
new KYC hash, the registry unions the new hash into the old record so it survives re-verification
too.

---

## 4. The console

**[standing-console.vercel.app](https://standing-console.vercel.app)** — reading both live
deployments. The network switch in the header swaps chain, RPC, explorer and address set together.

Start on **Base**, where the loans are:
- [Loan book](https://standing-console.vercel.app/book?n=base) — one repaid loan, one live, 26.93% utilization
- [Borrower](https://standing-console.vercel.app/?n=base&a=0x9E2816003da34Ea0E232Fb59A5e475Fce1121d98) — the credential, the score itemised, the terms
- [Compliance](https://standing-console.vercel.app/compliance?n=base) — the gate resolving condition by condition; paste `0xABc0000000000000000000000000000000000123` to watch it refuse and name the party
- [Pool](https://standing-console.vercel.app/pool?n=base) — assets, utilization, interest, losses

Every number is read live from chain. Monad's pool is empty and shows zeroes, which is the truth.

## 5. The rest of it

```bash
cd contracts && forge test          # unit + invariant + forked-network
cd ../web && npm install && npm run dev    # the console, reading the live deployment
cd ../mcp && npm install && npm run build && node dist/index.js   # MCP server
```

The MCP server exposes the same underwriting as tools — "what would this borrower get and why",
"would this transfer be allowed and who fails it" — read-only, no keys, cannot move a cent.

---

## 6. Deployed

Monad testnet, chain id 10143:

| | |
|---|---|
| `CreditManager` | [`0xC6E2aC49a18BfB71F2981efeaac2aC41Db1c1f74`](https://testnet.monadexplorer.com/address/0xC6E2aC49a18BfB71F2981efeaac2aC41Db1c1f74) |
| `StandingPool` | [`0x010263d8e3b2DC38F63A3f1660D2502f204ffB6D`](https://testnet.monadexplorer.com/address/0x010263d8e3b2DC38F63A3f1660D2502f204ffB6D) |
| `StandingRegistry` | [`0x2bD8832C9Bc98df47F256507a903B0338D96C0b5`](https://testnet.monadexplorer.com/address/0x2bD8832C9Bc98df47F256507a903B0338D96C0b5) |

Read the credential of a real wallet straight off the live deployment:

```bash
cast call 0xC6E2aC49a18BfB71F2981efeaac2aC41Db1c1f74 \
  "credentialOf(address)((bool,uint8,uint8,uint8,bytes2,bytes2,uint64,uint64,bytes32,bytes32))" \
  0x9E2816003da34Ea0E232Fb59A5e475Fce1121d98 \
  --rpc-url https://testnet-rpc.monad.xyz
```

---

## 7. The live loan

A real under-collateralized loan was drawn and repaid on Base Sepolia during the build window:
3.000000 aUSDC principal against 2.365800 aUSDC of collateral — **78.86%**, so a fifth of the loan
was carried by the credential rather than by assets. Every transaction is linked in
[`PROOF.md`](PROOF.md), along with the moment an operator raised `min_tier` at Cleanverse and the
on-chain verdict flipped to deny in the next block with no redeploy.

## 8. The honest part

- A **default** takes a matured loan plus a three-day grace period, so the write-off is demonstrated
  on a fork with compressed time rather than on a live chain. Everything it touches is real.
- **Monad's pool is empty.** Cleanverse's USDC faucet on Monad was returning `failed to execute
  token transfer` all day, so the live loan is on Base Sepolia. The same contracts are deployed,
  credentialed and registered on Monad, and the gate is live there — there is simply nothing to lend.
- **Testnet, not mainnet.** Sandbox credentials issue into testnet only.

Everything we could not establish is in [`CLAIMS.md`](CLAIMS.md), stated with its evidence tier —
along with the fourteen real bugs we found in our own contracts by attacking them ourselves, and the
handful we chose to document rather than fix.
