# Standing — MCP server

An under-collateralized credit book is only trustworthy if someone can interrogate it. This server
exposes the protocol's underwriting as tools: what a borrower would be offered and *why*, who is
refused and on which condition, what is on the book, and where the pool stands.

It is read-only by construction. There are no keys, nothing is signed, and no tool can move a cent.

## Tools

| Tool | Answers |
|---|---|
| `standing_quote` | What would this borrower be offered for this principal and term, and why? Full score breakdown, the collateral shortfall standing is covering, and the reason for any refusal. |
| `standing_check_compliance` | Would Cleanverse's policy engine allow this transfer? Names the failing party and condition — the same verdict the contract computes inside a transaction. |
| `standing_identity` | The live A-Pass credential, the credit history keyed to the identity behind it, and every wallet seen acting under that identity. |
| `standing_loan_book` | Every loan, its terms and status, and which ones are past grace and can be written off by anyone. |
| `standing_pool` | Assets, liquidity, utilization, interest earned, losses absorbed, assets per share. |

## Run

```bash
npm install && npm run build
node dist/index.js
```

Register it with any MCP client:

```json
{
  "mcpServers": {
    "standing": { "command": "node", "args": ["/absolute/path/to/mcp/dist/index.js"] }
  }
}
```

Defaults point at the Monad testnet deployment. Override with `MONAD_RPC_URL`, `CREDIT_MANAGER`,
`STANDING_POOL`, `STANDING_REGISTRY`.

Run `npm run abi` after changing the contracts — `src/abi.ts` is generated from the Foundry
artifacts and is not edited by hand.
