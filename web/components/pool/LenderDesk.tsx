"use client";

import { useMemo, useState } from "react";
import { useAccount, useWaitForTransactionReceipt, useWriteContract } from "wagmi";
import { erc20Abi, standingPoolAbi } from "@/lib/abi";
import { ASSET_SYMBOL, REFUSAL_PROSE, refusalName, SHARE_SYMBOL } from "@/lib/contracts";
import { useNetwork } from "@/lib/network";
import { formatUnits6, parseUnits6, shortError } from "@/lib/format";
import {
  useAllowance,
  useAssetBalance,
  useCheckParty,
  useCheckTransfer,
  useMaxDeposit,
  useMaxWithdraw,
  usePoolDecimals,
  usePreviewDeposit,
  useShareBalance,
} from "@/lib/reads";
import { Amount, Empty, Panel, Row, Tag } from "../primitives";

/**
 * Deposit and redeem, both preflighted against the same gate the contract will run.
 * The preflight is `checkTransferDetailed`, not the ERC-4626 caps — see the note.
 */
export function LenderDesk() {
  const { contracts, chainId } = useNetwork();
  const { address, isConnected } = useAccount();
  const [tab, setTab] = useState<"deposit" | "withdraw">("deposit");
  const [input, setInput] = useState("100");

  const amount = parseUnits6(input) ?? 0n;

  const assetBalance = useAssetBalance(address);
  const shares = useShareBalance(address);
  const shareDecimals = usePoolDecimals();
  const allowance = useAllowance(address, contracts.standingPool);
  const maxDeposit = useMaxDeposit(address);
  const maxWithdraw = useMaxWithdraw(address);
  const previewShares = usePreviewDeposit(amount > 0n ? amount : undefined);

  // deposit → _requireCompliant(caller, receiver, assets); receiver is the caller here
  const depositCheck = useCheckTransfer(address, address, amount);
  // withdraw → _requireParty(owner) then _requireCompliant(pool, receiver, assets)
  const ownerCheck = useCheckParty(address);
  const payoutCheck = useCheckTransfer(contracts.standingPool, address, amount);

  const approve = useWriteContract();
  const deposit = useWriteContract();
  const withdraw = useWriteContract();
  const approveRc = useWaitForTransactionReceipt({ chainId, hash: approve.data });
  const depositRc = useWaitForTransactionReceipt({ chainId, hash: deposit.data });
  const withdrawRc = useWaitForTransactionReceipt({ chainId, hash: withdraw.data });

  const needsApproval =
    allowance.data !== undefined && amount > 0n && allowance.data < amount;

  const depositChecks = useMemo(() => {
    const out: { label: string; ok: boolean | undefined; detail: string }[] = [];
    out.push({
      label: "Compliance gate",
      ok: depositCheck.data?.[0],
      detail: depositCheck.data
        ? depositCheck.data[0]
          ? "checkTransferDetailed(you → you) permitted"
          : `refused — ${depositCheck.data[1]} ${refusalName(depositCheck.data[1])}`
        : "reading",
    });
    out.push({
      label: "Balance",
      ok: assetBalance.data !== undefined ? assetBalance.data >= amount && amount > 0n : undefined,
      detail:
        assetBalance.data !== undefined
          ? `wallet holds ${formatUnits6(assetBalance.data)} ${ASSET_SYMBOL}`
          : "reading",
    });
    out.push({
      label: "Allowance",
      ok: allowance.data !== undefined ? allowance.data >= amount && amount > 0n : undefined,
      detail:
        allowance.data !== undefined
          ? `${formatUnits6(allowance.data)} ${ASSET_SYMBOL} approved to the pool`
          : "reading",
    });
    return out;
  }, [depositCheck.data, assetBalance.data, allowance.data, amount]);

  const withdrawChecks = useMemo(() => {
    const out: { label: string; ok: boolean | undefined; detail: string }[] = [];
    out.push({
      label: "Share owner",
      ok: ownerCheck.data?.[0],
      detail: ownerCheck.data
        ? ownerCheck.data[0]
          ? "checkParty(you) — credential live"
          : `refused — ${ownerCheck.data[1]} ${refusalName(ownerCheck.data[1])}`
        : "reading",
    });
    out.push({
      label: "Payout leg",
      ok: payoutCheck.data?.[0],
      detail: payoutCheck.data
        ? payoutCheck.data[0]
          ? "checkTransferDetailed(pool → you) permitted"
          : `refused — ${payoutCheck.data[1]} ${refusalName(payoutCheck.data[1])}`
        : "reading",
    });
    out.push({
      label: "Liquidity",
      ok: maxWithdraw.data !== undefined ? maxWithdraw.data >= amount && amount > 0n : undefined,
      detail:
        maxWithdraw.data !== undefined
          ? `maxWithdraw is ${formatUnits6(maxWithdraw.data)} ${ASSET_SYMBOL}`
          : "reading",
    });
    return out;
  }, [ownerCheck.data, payoutCheck.data, maxWithdraw.data, amount]);

  const active = tab === "deposit" ? depositChecks : withdrawChecks;
  const clear = active.every((c) => c.ok === true);
  const refusalCode =
    tab === "deposit"
      ? depositCheck.data && !depositCheck.data[0]
        ? depositCheck.data[1]
        : undefined
      : payoutCheck.data && !payoutCheck.data[0]
        ? payoutCheck.data[1]
        : ownerCheck.data && !ownerCheck.data[0]
          ? ownerCheck.data[1]
          : undefined;

  return (
    <Panel
      label="Lender desk"
      sub="ERC-4626, gated on both legs"
      bodyClass="p-0"
      right={
        isConnected ? (
          clear ? (
            <Tag tone="pass">CLEAR</Tag>
          ) : (
            <Tag tone="deny">BLOCKED</Tag>
          )
        ) : (
          <Tag tone="idle">NOT CONNECTED</Tag>
        )
      }
    >
      {!isConnected || !address ? (
        <div className="p-4">
          <Empty>Connect a wallet to supply or redeem</Empty>
        </div>
      ) : (
        <>
          <div className="flex border-b border-[var(--color-line)]">
            {(["deposit", "withdraw"] as const).map((t) => (
              <button
                key={t}
                onClick={() => setTab(t)}
                className={`flex-1 border-r border-[var(--color-line)] px-4 py-2.5 last:border-r-0 ${
                  tab === t
                    ? "bg-[var(--color-panel-lift)] text-[var(--color-bone)]"
                    : "text-[var(--color-bone-faint)] hover:text-[var(--color-bone-dim)]"
                }`}
              >
                <span className="lbl !text-inherit">{t === "deposit" ? "Supply" : "Redeem"}</span>
              </button>
            ))}
          </div>

          <div className="space-y-3 p-4">
            <div className="px-0 py-1">
              <Row label="Your aUSDC" dense>
                {assetBalance.data !== undefined ? (
                  <Amount value={assetBalance.data} size="sm" />
                ) : (
                  <span className="num text-[var(--color-bone-ghost)]">······</span>
                )}
              </Row>
              <Row label="Your shares" dense>
                {shares.data !== undefined && shareDecimals.data !== undefined ? (
                  <Amount
                    value={shares.data}
                    decimals={shareDecimals.data}
                    unit={SHARE_SYMBOL}
                    size="sm"
                  />
                ) : (
                  <span className="num text-[var(--color-bone-ghost)]">······</span>
                )}
              </Row>
              {tab === "deposit" ? (
                <Row label="maxDeposit" note="not the compliance gate — see below" dense>
                  {maxDeposit.data !== undefined ? (
                    <span className="num text-[0.6875rem] text-[var(--color-bone-dim)]">
                      {maxDeposit.data > 10n ** 30n ? "uint256 max" : formatUnits6(maxDeposit.data)}
                    </span>
                  ) : (
                    <span className="num text-[var(--color-bone-ghost)]">······</span>
                  )}
                </Row>
              ) : (
                <Row label="maxWithdraw" note="capped by available liquidity" dense>
                  {maxWithdraw.data !== undefined ? (
                    <Amount value={maxWithdraw.data} size="sm" />
                  ) : (
                    <span className="num text-[var(--color-bone-ghost)]">······</span>
                  )}
                </Row>
              )}
            </div>

            <div>
              <label className="lbl mb-2 block" htmlFor="lender-amount">
                {tab === "deposit" ? "Supply amount" : "Redeem amount"}
              </label>
              <div className="relative">
                <input
                  id="lender-amount"
                  className="field pr-16 text-[1rem]"
                  inputMode="decimal"
                  value={input}
                  onChange={(e) => setInput(e.target.value)}
                />
                <span className="lbl-micro pointer-events-none absolute right-3 top-1/2 -translate-y-1/2">
                  {ASSET_SYMBOL}
                </span>
              </div>
              {tab === "deposit" && previewShares.data !== undefined && shareDecimals.data ? (
                <p className="lbl-micro mt-2 !tracking-[0.1em] normal-case">
                  previewDeposit → {formatUnits6(previewShares.data, shareDecimals.data)}{" "}
                  {SHARE_SYMBOL}
                </p>
              ) : null}
            </div>

            <ul className="divide-y divide-[var(--color-line)] border border-[var(--color-line)]">
              {active.map((c) => (
                <li key={c.label} className="flex items-center gap-3 px-3 py-2">
                  <span className="w-[6.5rem] shrink-0">
                    <span className="lbl">{c.label}</span>
                  </span>
                  <span className="flex-1 truncate text-[0.6875rem] text-[var(--color-bone-faint)]">
                    {c.detail}
                  </span>
                  <Tag tone={c.ok === undefined ? "idle" : c.ok ? "pass" : "deny"}>
                    {c.ok === undefined ? "···" : c.ok ? "OK" : "BLOCK"}
                  </Tag>
                </li>
              ))}
            </ul>

            {refusalCode !== undefined ? (
              <div className="border-l-2 border-[var(--color-refuse)] bg-[var(--color-refuse-wash)] p-3">
                <div className="num text-[0.8125rem] text-[var(--color-refuse)]">
                  Refusal {refusalCode} · {refusalName(refusalCode)}
                </div>
                <p className="mt-1.5 text-[0.75rem] leading-relaxed text-[var(--color-bone-dim)]">
                  {REFUSAL_PROSE[refusalName(refusalCode)]}
                </p>
              </div>
            ) : null}

            {tab === "deposit" ? (
              <div className="space-y-2">
                <button
                  className="btn w-full"
                  disabled={!needsApproval || approve.isPending || approveRc.isLoading}
                  onClick={() =>
                    approve.writeContract({
                      chainId,
                      address: contracts.verifiedAsset,
                      abi: erc20Abi,
                      functionName: "approve",
                      args: [contracts.standingPool, amount],
                    })
                  }
                >
                  {approve.isPending || approveRc.isLoading
                    ? "Approving…"
                    : needsApproval
                      ? "1 · Approve aUSDC"
                      : "1 · aUSDC approved"}
                </button>
                <button
                  className="btn btn-key w-full"
                  disabled={!clear || deposit.isPending || depositRc.isLoading}
                  onClick={() =>
                    deposit.writeContract({
                      chainId,
                      address: contracts.standingPool,
                      abi: standingPoolAbi,
                      functionName: "deposit",
                      args: [amount, address],
                    })
                  }
                >
                  {deposit.isPending || depositRc.isLoading ? "Supplying…" : "2 · Supply"}
                </button>
                <Tx label="approve" write={approve} receipt={approveRc} />
                <Tx label="deposit" write={deposit} receipt={depositRc} />
              </div>
            ) : (
              <div className="space-y-2">
                <button
                  className="btn btn-key w-full"
                  disabled={!clear || withdraw.isPending || withdrawRc.isLoading}
                  onClick={() =>
                    withdraw.writeContract({
                      chainId,
                      address: contracts.standingPool,
                      abi: standingPoolAbi,
                      functionName: "withdraw",
                      args: [amount, address, address],
                    })
                  }
                >
                  {withdraw.isPending || withdrawRc.isLoading ? "Redeeming…" : "Redeem"}
                </button>
                <Tx label="withdraw" write={withdraw} receipt={withdrawRc} />
              </div>
            )}

            <p className="border-t border-[var(--color-line)] pt-3 text-[0.6875rem] leading-relaxed text-[var(--color-bone-faint)]">
              The gate is enforced in <span className="num">_deposit</span> and{" "}
              <span className="num">_withdraw</span>, not in{" "}
              <span className="num">maxDeposit</span>. Capping the ERC-4626 maximum would make
              callers revert with <span className="num">ERC4626ExceededMaxDeposit</span> and swallow
              the actual reason a lender was refused, so the console preflights with{" "}
              <span className="num">checkTransferDetailed</span> and shows the named condition
              instead.
            </p>
          </div>
        </>
      )}
    </Panel>
  );
}

type WriteLike = { error: unknown; data: `0x${string}` | undefined };
type ReceiptLike = { isLoading: boolean; isSuccess: boolean; error: unknown };

function Tx({
  label,
  write,
  receipt,
}: {
  label: string;
  write: WriteLike;
  receipt: ReceiptLike;
}) {
  const { txUrl } = useNetwork();
  const err = write.error ?? receipt.error;
  if (err) {
    return (
      <div className="border border-[var(--color-refuse-deep)] bg-[var(--color-refuse-wash)] p-2">
        <div className="lbl !text-[var(--color-refuse)]">{label} reverted</div>
        <p className="num mt-1 break-words text-[0.625rem] text-[var(--color-refuse)] opacity-85">
          {shortError(err)}
        </p>
      </div>
    );
  }
  if (!write.data) return null;
  return (
    <a
      href={txUrl(write.data)}
      target="_blank"
      rel="noreferrer"
      className="flex items-center justify-between border border-[var(--color-line-lift)] px-2 py-1.5 hover:border-[var(--color-teal)]"
    >
      <span className="lbl">{label}</span>
      <span className="num text-[0.625rem] text-[var(--color-teal)]">
        {receipt.isLoading ? "PENDING" : receipt.isSuccess ? "CONFIRMED" : "SENT"}
      </span>
    </a>
  );
}
