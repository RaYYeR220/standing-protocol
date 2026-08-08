# Review this in five minutes

Everything below runs with no API keys, no accounts and no wallet funding. If you only do one
thing, do step 2.

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
4. repayment — assets per share 1.000000 → 1.006901, score 435 → 522, collateral required falls;
5. a default — assets per share 1.006901 → 0.976031 (the loss lands on lenders, not a reserve),
   score 522 → 276, and the borrower is no longer eligible.

Step 5 is the point of the protocol. The cost of defaulting is written against the *identity*, so it
survives the borrower abandoning that wallet — and because Cleanverse re-issues credentials under a
new KYC hash, the registry unions the new hash into the old record so it survives re-verification
too.

---

## 4. The rest of it

```bash
cd contracts && forge test          # unit + invariant + forked-network
cd ../web && npm install && npm run dev    # the console, reading the live deployment
cd ../mcp && npm install && npm run build && node dist/index.js   # MCP server
```

The console makes the enforcement visible: the credential behind a score, every term of the
breakdown, the compliance verdict resolving condition by condition, and the refusals in plain
language.

The MCP server exposes the same underwriting as tools — "what would this borrower get and why",
"would this transfer be allowed and who fails it" — read-only, no keys, cannot move a cent.

---

## 5. Deployed

Monad testnet, chain id 10143:

| | |
|---|---|
| `CreditManager` | [`0x77502D2AfBE8c2Bb3e9cD7ae9f0468e6D25997cb`](https://testnet.monadexplorer.com/address/0x77502D2AfBE8c2Bb3e9cD7ae9f0468e6D25997cb) |
| `StandingPool` | [`0x382B067B3917f07880795396b6684e30B9d30907`](https://testnet.monadexplorer.com/address/0x382B067B3917f07880795396b6684e30B9d30907) |
| `StandingRegistry` | [`0x05d68e4B5d79994096AeB62A04333C7491D63eD0`](https://testnet.monadexplorer.com/address/0x05d68e4B5d79994096AeB62A04333C7491D63eD0) |

Read the credential of a real wallet straight off the live deployment:

```bash
cast call 0x77502D2AfBE8c2Bb3e9cD7ae9f0468e6D25997cb \
  "credentialOf(address)((bool,uint8,uint8,uint8,bytes2,bytes2,uint64,uint64,bytes32,bytes32))" \
  0x9E2816003da34Ea0E232Fb59A5e475Fce1121d98 \
  --rpc-url https://testnet-rpc.monad.xyz
```

---

## 6. The honest part

The live deployment currently **refuses everything**, and that is the correct behaviour rather than
a broken build. Cleanverse's policy engine checks both ends of a transfer, so the pool contract is
itself a party to every disbursement and needs its own A-Pass — and `POST /generate_apass` has been
returning `[CV_500] CV System error` for every wallet on Monad since shortly after we minted our
first two credentials. We reported it, we are retrying on a loop, and until it clears the on-chain
walkthrough lives on the fork.

Two other Cleanverse-side blockers, and everything we could not establish, are in
[`CLAIMS.md`](CLAIMS.md) — along with the eight real bugs we found in our own contracts by attacking
them ourselves, and the two we chose to document rather than fix.
