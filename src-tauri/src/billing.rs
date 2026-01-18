use crate::usage::{DailyUsage, LlmUsage, SttUsage};

// Pricing constants (as of January 2025)
// Deepgram Nova-2: $0.0077 per minute
pub const DEEPGRAM_NOVA_PER_MINUTE: f64 = 0.0077;

// Gemini 2.5 Flash Lite: $0.10 per million input tokens, $0.40 per million output tokens
pub const GEMINI_FLASH_LITE_INPUT_PER_MILLION: f64 = 0.10;
pub const GEMINI_FLASH_LITE_OUTPUT_PER_MILLION: f64 = 0.40;

// GPT-4o mini: $0.15 per million input tokens, $0.60 per million output tokens
pub const GPT4O_MINI_INPUT_PER_MILLION: f64 = 0.15;
pub const GPT4O_MINI_OUTPUT_PER_MILLION: f64 = 0.60;

pub fn calculate_deepgram_cost(duration_seconds: f64) -> f64 {
    let minutes = duration_seconds / 60.0;
    minutes * DEEPGRAM_NOVA_PER_MINUTE
}

pub fn calculate_gemini_cost(prompt_tokens: u32, completion_tokens: u32) -> f64 {
    let input_cost = (prompt_tokens as f64 / 1_000_000.0) * GEMINI_FLASH_LITE_INPUT_PER_MILLION;
    let output_cost =
        (completion_tokens as f64 / 1_000_000.0) * GEMINI_FLASH_LITE_OUTPUT_PER_MILLION;
    input_cost + output_cost
}

pub fn calculate_openai_cost(prompt_tokens: u32, completion_tokens: u32) -> f64 {
    let input_cost = (prompt_tokens as f64 / 1_000_000.0) * GPT4O_MINI_INPUT_PER_MILLION;
    let output_cost = (completion_tokens as f64 / 1_000_000.0) * GPT4O_MINI_OUTPUT_PER_MILLION;
    input_cost + output_cost
}

pub fn calculate_llm_cost(model: &str, prompt_tokens: u32, completion_tokens: u32) -> f64 {
    if model.contains("gemini") {
        calculate_gemini_cost(prompt_tokens, completion_tokens)
    } else {
        calculate_openai_cost(prompt_tokens, completion_tokens)
    }
}

pub fn calculate_stt_cost(usage: &SttUsage) -> f64 {
    calculate_deepgram_cost(usage.duration_seconds)
}

pub fn calculate_total_cost(stt: Option<&SttUsage>, llm: Option<&LlmUsage>) -> f64 {
    let stt_cost = stt.map_or(0.0, calculate_stt_cost);
    let llm_cost = llm.map_or(0.0, |u| calculate_llm_cost(&u.model, u.prompt_tokens, u.completion_tokens));
    stt_cost + llm_cost
}

pub fn calculate_daily_cost(daily: &DailyUsage) -> DailyCostBreakdown {
    let deepgram_cost = calculate_deepgram_cost(daily.deepgram_seconds);
    let gemini_cost =
        calculate_gemini_cost(daily.gemini_prompt_tokens, daily.gemini_completion_tokens);
    let openai_cost =
        calculate_openai_cost(daily.openai_prompt_tokens, daily.openai_completion_tokens);

    DailyCostBreakdown {
        deepgram_cost_usd: deepgram_cost,
        gemini_cost_usd: gemini_cost,
        openai_cost_usd: openai_cost,
        total_cost_usd: deepgram_cost + gemini_cost + openai_cost,
    }
}

#[derive(Debug, Clone)]
pub struct DailyCostBreakdown {
    pub deepgram_cost_usd: f64,
    pub gemini_cost_usd: f64,
    pub openai_cost_usd: f64,
    pub total_cost_usd: f64,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn deepgram_cost_one_minute() {
        let cost = calculate_deepgram_cost(60.0);
        assert!((cost - 0.0077).abs() < 0.0001);
    }

    #[test]
    fn deepgram_cost_half_minute() {
        let cost = calculate_deepgram_cost(30.0);
        assert!((cost - 0.00385).abs() < 0.0001);
    }

    #[test]
    fn gemini_cost_calculation() {
        // 1M input tokens + 1M output tokens
        let cost = calculate_gemini_cost(1_000_000, 1_000_000);
        // $0.10 + $0.40 = $0.50
        assert!((cost - 0.50).abs() < 0.0001);
    }

    #[test]
    fn gemini_cost_small_tokens() {
        // 1000 input tokens + 500 output tokens
        let cost = calculate_gemini_cost(1000, 500);
        // (1000/1M * 0.10) + (500/1M * 0.40) = 0.0001 + 0.0002 = 0.0003
        assert!((cost - 0.0003).abs() < 0.00001);
    }

    #[test]
    fn openai_cost_calculation() {
        // 1M input tokens + 1M output tokens
        let cost = calculate_openai_cost(1_000_000, 1_000_000);
        // $0.15 + $0.60 = $0.75
        assert!((cost - 0.75).abs() < 0.0001);
    }

    #[test]
    fn llm_cost_routes_correctly() {
        let gemini_cost = calculate_llm_cost("gemini-2.5-flash-lite", 1000, 500);
        let openai_cost = calculate_llm_cost("gpt-4o-mini", 1000, 500);

        // Gemini is cheaper
        assert!(gemini_cost < openai_cost);
    }

    #[test]
    fn total_cost_combines_stt_and_llm() {
        let stt = SttUsage {
            duration_seconds: 60.0,
        };
        let llm = LlmUsage {
            model: "gemini-2.5-flash-lite".to_string(),
            prompt_tokens: 1000,
            completion_tokens: 500,
        };

        let total = calculate_total_cost(Some(&stt), Some(&llm));
        let expected = calculate_deepgram_cost(60.0) + calculate_gemini_cost(1000, 500);
        assert!((total - expected).abs() < 0.00001);
    }

    #[test]
    fn daily_cost_breakdown() {
        let daily = DailyUsage {
            date: "2025-01-18".to_string(),
            deepgram_seconds: 120.0,
            deepgram_requests: 5,
            gemini_prompt_tokens: 5000,
            gemini_completion_tokens: 2000,
            gemini_requests: 5,
            openai_prompt_tokens: 1000,
            openai_completion_tokens: 500,
            openai_requests: 2,
        };

        let breakdown = calculate_daily_cost(&daily);

        assert!((breakdown.deepgram_cost_usd - calculate_deepgram_cost(120.0)).abs() < 0.00001);
        assert!(
            (breakdown.gemini_cost_usd - calculate_gemini_cost(5000, 2000)).abs() < 0.00001
        );
        assert!(
            (breakdown.openai_cost_usd - calculate_openai_cost(1000, 500)).abs() < 0.00001
        );
        assert!(
            (breakdown.total_cost_usd
                - (breakdown.deepgram_cost_usd
                    + breakdown.gemini_cost_usd
                    + breakdown.openai_cost_usd))
                .abs()
                < 0.00001
        );
    }
}
