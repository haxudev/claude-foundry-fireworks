"""LiteLLM pre-call hook: drop Anthropic-only params that the OpenAI-compatible
Foundry endpoint does not understand.
"""
from typing import Optional, Literal
from litellm.integrations.custom_logger import CustomLogger

DROP_KEYS = {
    "context_management",
    "reasoning_effort",
    "betas",
    "anthropic_beta",
    "anthropic-beta",
    "thinking",
    "cache_control",
}


class ParamFilter(CustomLogger):
    async def async_pre_call_hook(
        self,
        user_api_key_dict,
        cache,
        data: dict,
        call_type: Literal[
            "completion",
            "text_completion",
            "embeddings",
            "image_generation",
            "moderation",
            "audio_transcription",
            "pass_through_endpoint",
            "rerank",
            "mcp_call",
        ],
    ) -> Optional[dict]:
        for k in list(data.keys()):
            if k in DROP_KEYS:
                data.pop(k, None)
        # also strip from messages
        msgs = data.get("messages")
        if isinstance(msgs, list):
            for m in msgs:
                if isinstance(m, dict):
                    for k in list(m.keys()):
                        if k in DROP_KEYS:
                            m.pop(k, None)
        return data


proxy_handler_instance = ParamFilter()
