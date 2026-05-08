"""LiteLLM hooks for bridging Claude Code's Anthropic payloads to Foundry's
OpenAI-compatible Fireworks endpoint.

Strategy:
- strip Anthropic-only request params before provider validation
- remove persisted thinking blocks from message history (they break custom_openai)
- let the backend emit its own compatible reasoning content when available
"""
from typing import Optional
from litellm.integrations.custom_logger import CustomLogger
from litellm.types.utils import CallTypesLiteral

DROP_KEYS = {
    "context_management",
    "reasoning_effort",
    "betas",
    "anthropic_beta",
    "anthropic-beta",
    "thinking",
    "thinking_blocks",
    "cache_control",
}

DROP_CONTENT_TYPES = {"thinking", "redacted_thinking"}


def _sanitize_content_item(item):
    if isinstance(item, str):
        return item

    if not isinstance(item, dict):
        return item

    if item.get("type") in DROP_CONTENT_TYPES:
        return None

    cleaned = {}
    for key, value in item.items():
        if key in DROP_KEYS or key in {"thinking", "signature", "data"}:
            continue
        cleaned[key] = value

    return cleaned


def _sanitize_message(message):
    if not isinstance(message, dict):
        return message

    cleaned = {}
    for key, value in message.items():
        if key in DROP_KEYS:
            continue

        if key == "content" and isinstance(value, list):
            sanitized_items = []
            for item in value:
                sanitized = _sanitize_content_item(item)
                if sanitized is not None:
                    sanitized_items.append(sanitized)
            cleaned[key] = sanitized_items
            continue

        cleaned[key] = value

    return cleaned


def _sanitize_request_dict(data: dict) -> dict:
    for key in list(data.keys()):
        if key in DROP_KEYS:
            data.pop(key, None)

    messages = data.get("messages")
    if isinstance(messages, list):
        data["messages"] = [_sanitize_message(message) for message in messages]

    return data


class ParamFilter(CustomLogger):
    async def async_pre_request_hook(self, model: str, messages: list, kwargs: dict):
        if isinstance(messages, list):
            messages[:] = [_sanitize_message(message) for message in messages]
        _sanitize_request_dict(kwargs)
        return kwargs

    async def async_pre_call_hook(
        self,
        user_api_key_dict,
        cache,
        data: dict,
        call_type: CallTypesLiteral,
    ) -> Optional[dict]:
        return _sanitize_request_dict(data)


proxy_handler_instance = ParamFilter()
