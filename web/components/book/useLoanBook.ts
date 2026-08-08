"use client";

import { useQuery } from "@tanstack/react-query";
import { creditManagerAbi } from "@/lib/abi";
import { inWaves, publicClient } from "@/lib/client";
import { CONTRACTS } from "@/lib/contracts";
import type { Loan, LoanRow } from "@/lib/types";

/**
 * The whole book. `loanCount()` then `loan(id)` and `isDefaultable(id)` for each,
 * run in bounded waves so a large book does not trip the public endpoint's limits.
 */
export function useLoanBook() {
  return useQuery({
    queryKey: ["loan-book"],
    refetchInterval: 15_000,
    queryFn: async (): Promise<{ count: number; rows: LoanRow[] }> => {
      const count = (await publicClient.readContract({
        address: CONTRACTS.creditManager,
        abi: creditManagerAbi,
        functionName: "loanCount",
      })) as bigint;

      const n = Number(count);
      if (n === 0) return { count: 0, rows: [] };

      const ids = Array.from({ length: n }, (_, i) => i + 1);
      const rows = await inWaves(ids, 5, async (id) => {
        const [loan, defaultable] = await Promise.all([
          publicClient.readContract({
            address: CONTRACTS.creditManager,
            abi: creditManagerAbi,
            functionName: "loan",
            args: [BigInt(id)],
          }) as Promise<Loan>,
          publicClient.readContract({
            address: CONTRACTS.creditManager,
            abi: creditManagerAbi,
            functionName: "isDefaultable",
            args: [BigInt(id)],
          }) as Promise<boolean>,
        ]);
        return { ...loan, id, defaultable };
      });

      // Newest first: a book is read from the top.
      return { count: n, rows: rows.reverse() };
    },
  });
}
