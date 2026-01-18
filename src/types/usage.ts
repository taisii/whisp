export type DailyUsageSummary = {
  deepgramSeconds: number;
  deepgramCostUsd: number;
  geminiTokens: number;
  geminiCostUsd: number;
  openaiTokens: number;
  openaiCostUsd: number;
  totalCostUsd: number;
};

export type UsageSummary = {
  today: DailyUsageSummary;
  this_month: DailyUsageSummary;
};

export type UsageMetricsEvent = {
  sttDurationSeconds: number | null;
  llmPromptTokens: number | null;
  llmCompletionTokens: number | null;
  llmModel: string | null;
  costEstimateUsd: number;
};
