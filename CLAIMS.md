# Claims

Every statement this project makes in public, with the evidence behind it and a tier saying how far
that evidence goes. If something is not on this list, we are not claiming it.

| Tier | Meaning |
|---|---|
| **REPRODUCIBLE** | You can run a command and see it yourself. |
| **VERIFIED-LIVE** | Confirmed against live chain state, and re-checkable at any time. |
| **DESIGNED** | The code does this by construction and there are tests to that effect, but it has not been exercised against a real adversary. |
| **NOT-CLAIMED** | Explicitly out of scope. Listed so nobody has to guess. |

---

## The Cleanverse integration

| Claim | Tier | Evidence |
|---|---|---|
| A-Pass is an on-chain ERC-721 whose `tokenId` is `uint160(holder)` | VERIFIED-LIVE | `forge script script/InspectCleanverse.s.sol --rpc-url https://testnet-rpc.monad.xyz` |
| The credential's attributes are readable on-chain via selector `0x6a069f61` | VERIFIED-LIVE | same script; decoded status/tier/expiry/KYC-hash for a real wallet |
| The decoded attributes match Cleanverse's own REST response for the same wallet | VERIFIED-LIVE | `docs/CLEANVERSE.md` §3 — word-for-word comparison against `/query_apass` |
| The compliance verdict is a public view, `canTransfer(token, from, to, amount)` | REPRODUCIBLE | inspection script prints an allow, and two refusals |
| The policy engine checks **both** ends and *reverts* (custom error `0xa6725971(address)`) on an uncredentialed party | VERIFIED-LIVE | inspection script, last two cases |
| Argument order of `canTransfer` is `(token, from, to, amount)` | VERIFIED-LIVE | the `(from, to, token, amount)` permutation reverts; established by trying both |
| `/validator/register` binds a rule set to *our* contract, and the owner signature is `personal_sign(chain + lowercase(address))` | VERIFIED-LIVE | the pool and manager are registered on both chains; `validator.isRegistered(pool)` returns true |
| Rules for a registered contract live on a **separate validator contract**, not on the token policy | VERIFIED-LIVE | `policy.isTokenRegistered(pool)` is false while `validator.isRegistered(pool)` is true — `docs/CLEANVERSE.md` §2 |
| An operator can tighten the protocol's rule set through the API and the on-chain verdict changes in the next block, with no redeploy | REPRODUCIBLE | `PROOF.md` — `min_tier` 0 → 60 flipped the verdict 1 → 0 for a tier-50 wallet, then back |
| The protocol reads identity and compliance from chain state, never from an API | REPRODUCIBLE | `src/` contains no oracle, no signer, no off-chain input of any kind |

## The protocol

| Claim | Tier | Evidence |
|---|---|---|
| A verified lender can supply, a verified borrower can draw under-collateralized, and repay — **on a live chain** | VERIFIED-LIVE | `PROOF.md` — 3.000000 aUSDC drawn against 2.365800 collateral (78.86%) on Base Sepolia, then repaid |
| The same, plus a default, end to end | REPRODUCIBLE | `forge script script/Demo.s.sol --rpc-url https://testnet-rpc.monad.xyz -vv` — on a fork against the live Cleanverse contracts |
| The protocol contracts hold their own A-Pass and are registered policy subjects | VERIFIED-LIVE | `checkParty(pool)` → `(true, 0)`, `isProtocolRegistered()` → `true`, on both chains |
| The integration is chain-agnostic | VERIFIED-LIVE | identical source deployed and working on Monad testnet and Base Sepolia |
| Every approved loan is under-collateralized | REPRODUCIBLE | demo prints the ratio; the terms curve tops out at 80% collateral. Unit tests sweep the curve |
| A wallet with no credential is refused, and the refusal names the failing party and condition | REPRODUCIBLE | demo step 3; `checkTransferDetailed` on the live deployment |
| A draw above the protocol ceiling, above the borrower's line, or by an uncredentialed wallet reverts | REPRODUCIBLE | demo step 3, cases b/c/d |
| A default is written against the identity, costs the borrower their eligibility, and the loss lands on lenders via the share price | REPRODUCIBLE | demo step 5 — score 522 → 276, assets-per-share 1.006901 → 0.976031 |
| Anyone may write off a matured, unpaid loan | DESIGNED | `markDefault` is permissionless after the grace period; tested |
| Exposure and history are keyed to the identity, not the wallet | DESIGNED | two wallets under one KYC hash share one line; tested |
| A re-issued credential does not shed its history | DESIGNED | the registry unions the new hash into the old record; `syncIdentity` is permissionless so the link is not lost by a reverting draw; tested |
| Terms are deterministic — no model, oracle or off-chain input touches the number | REPRODUCIBLE | `StandingMath` is a pure library over on-chain state; read it |
| The score breakdown returned to a borrower is the same arithmetic the contract enforced | REPRODUCIBLE | `quote()` returns the breakdown; the console and MCP server render it verbatim |
| Ceilings cannot be raised after deployment | DESIGNED | immutable in `CreditManager`; the registry's admin is renounced in `Deploy.s.sol` |
| Disbursement authority cannot be re-granted | DESIGNED | `setCreditManager` is callable exactly once; there is no role to hand out |

## Numbers

| Claim | Tier | Evidence |
|---|---|---|
| The test suite passes | REPRODUCIBLE | `cd contracts && forge test` — unit, invariant and forked-network suites. The count is whatever that command prints; we are not quoting a number here that could drift from it |
| Fork tests run against live Monad testnet state | REPRODUCIBLE | `test/fork/` uses a real fork and asserts chain id 10143; they skip cleanly with no RPC |

---

## What is real and what is impersonated

`script/Demo.s.sol` runs on a fork of Monad testnet. Everything in it is the real thing: the A-Pass
registry, the policy engine and aUSDC are the live deployments at their live addresses, and the
protocol contracts are freshly deployed copies of the same code that is deployed on testnet.

Two role-holders are impersonated, and this is the complete list:

| Impersonated | Why | What it stands in for |
|---|---|---|
| `0xBd8428761efB5384C4945d16de56817Caa6903dF` — Cleanverse's A-Pass issuer | a fork cannot call Cleanverse's REST API, and their sandbox issues every credential at tier 50, so a walkthrough that shows tiers mattering has to issue its own | Cleanverse issuing a credential, through the same registry function and the same wallet they use |
| `0x8F118338a1fa41E7Fa86Be19A4e8B99Ed58A6EcC` — AccessCore, which holds `MINTER_ROLE` on aUSDC | the sandbox aUSDC faucet is empty (`ERC20InsufficientBalance` from an empty institution wallet) and our institution is not whitelisted to wrap origin USDC | aUSDC being minted the way it normally is |

The live deployment needs none of this — the credentials there were issued by Cleanverse through
`POST /generate_apass`, and the aUSDC came from their faucet.

We impersonate the caller. We do not substitute the contracts, stub the returns, or pre-seed state.
There are no mock contracts anywhere outside `test/mocks/`, which exists so the unit suite can be
deterministic and offline; the fork suite and the demo use the real deployments.

## Known gaps

Things that do not work, stated plainly.

- **Monad's pool is empty, so the live loan is on Base Sepolia.** Cleanverse's USDC faucet on Monad
  returned `failed to execute token transfer` for the whole build window, while the same call on
  `base` worked. The contracts are deployed, credentialed and registered on both chains and the gate
  is live on both; there is simply nothing to lend on Monad.
- **No live default.** A write-off needs a matured loan plus a three-day grace period. It is
  demonstrated on a fork with compressed time instead, against the real contracts.
- **Two laundering routes survive, and need a keeper.** A defaulter who re-verifies twice *and*
  moves to a fresh wallet sheds the identity chain, because a credential carries only one previous
  hash and the intermediate link is never recorded. The same trick doubles a credit line. Both close
  completely if anyone calls the permissionless `syncIdentity(address)` once while the intermediate
  credential is live — which is a keeper's job, and is why that function takes no permissions. The
  common case (same wallet) is already closed by the wallet-sticky default flag.
- **A validator outage silently relaxes a tightened rule set.** An unreachable *registration check*
  falls back to "unregistered" so a Cleanverse outage cannot brick a protocol that has no rules —
  but an operator who has raised `min_tier` loses that tightening while the validator is down. The
  verdict itself still fails closed. `isProtocolRegistered()` is public so this is monitorable, and
  it should be monitored.
- **Fee-on-transfer assets are not supported.** `repay` pulls `principal + interest` to the manager
  and the pool then pulls the same number; an asset that took a fee would have the pool make up the
  difference out of collateral. aUSDC does not.

## Not claimed

- **Not mainnet.** Cleanverse's contracts exist at the same addresses on Monad mainnet, but our
  sandbox credentials mint into testnet. We have not deployed to mainnet and do not claim mainnet
  behaviour.
- **Not audited.** A test suite is not an audit.
- **We do not claim the A-Pass getter's name.** We have its selector, argument and return layout,
  verified. The binding would break if Cleanverse changed the layout behind their proxy.
- **We do not decode the credential's country list.** Word 9 is populated but we could not confirm
  its packing, so we do not read it. Jurisdiction is enforced by Cleanverse inside `canTransfer`.
- **We do not claim protection against a mis-issued credential.** `previousKycHash` is trusted
  absolutely: whatever it names, the protocol folds the holder into that identity. A credential
  mis-issued with a stranger's hash would merge two unrelated identities. Nothing inside a contract
  can check Cleanverse's issuance, so this is a trust assumption, and we would rather name it than
  have it found.
- **We do not claim the vault is donation-proof.** `totalAssets` reads the vault's balance, so anyone
  can transfer assets in and move the share price. The donor gains nothing and existing depositors
  get the windfall, so there is no theft — only a mis-priced entry for the next depositor. A
  six-decimal virtual offset makes griefing a first depositor cost a million to one.

---

## What we broke ourselves

We ran an adversarial pass against our own contracts before anyone else could, and it found real
holes. Recording them here because a list of only successes is not evidence of anything.

Found and fixed:

- A frozen lender could exit by naming a second wallet of their own as the receiver — the gate only
  checked the recipient, not the share owner or the caller.
- Pool shares were an ungated ERC-20, so a frozen lender could transfer them to an uncredentialed
  address which redeemed through any compliant receiver.
- A defaulter could launder their record by re-verifying with Cleanverse, twice: the link between
  old and new credential was only written inside `open()`, and a refused draw reverted it away.
- Outstanding principal was stranded when a credential was re-issued mid-loan, handing one person
  two full credit lines.
- Credit history was farmable at zero cost — a dust loan rounds interest and collateral to zero, and
  ten same-block round trips bought the entire repayment component of the score.
- The verified asset yields control to its policy contract mid-transfer, so a depositor could mint
  shares from inside a repayment or a write-off at a price reflecting half the transaction.
- The registry's admin could grant itself the recorder role and forge a repayment history.
- The asset component of the score saturated at ten dollars, making a $10 holder and a $10M holder
  indistinguishable.

Then, on a second and third adversarial pass over the fixes themselves:

- A defaulter could still launder their record by re-verifying **twice**, because the link between
  credentials was only written inside a draw, and a refused draw reverted it away.
- Migrating an identity re-parented the aggregate but not each loan's own key, so `repay` and
  `markDefault` both underflowed — leaving loans that could neither be repaid nor written off, and
  reachable by nothing more sinister than a sibling wallet borrowing.
- The first link won, so a borrower holding two lineages could commit the clean one and strand the
  write-off on a hash nothing resolved to again.
- The reentrancy guards were on the wrong side of the boundary: the pool was not on the stack during
  the windows they were meant to cover, so all three mid-transfer windows stayed open.
- A verdict word from the validator that was neither 0 nor 1 reverted the gate instead of denying,
  which would have made the protocol uncallable rather than strict.

Each of those has a regression test named after it. What we chose to document rather than fix —
mis-issuance, donation sensitivity, and the two keeper-closable laundering routes — is above.
