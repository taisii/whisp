export type DeepgramBillingSummary = {
  projectId: string;
  startDate: string;
  endDate: string;
  fetchedAtMs: number;
  totalCostUsd: number | null;
  totalSeconds: number | null;
  balanceUsd: number | null;
  rawUsage: unknown;
  rawBalance: unknown;
};
