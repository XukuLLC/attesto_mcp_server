import asyncio
import os
from importlib.metadata import version

from mcp.client import Client


async def main() -> None:
    url = os.environ.get("MCP_SERVER_URL")
    era = os.environ.get("MCP_PROTOCOL_ERA")

    if not url or not era:
        raise RuntimeError("MCP_SERVER_URL and MCP_PROTOCOL_ERA are required")
    if era not in {"2025-11-25", "2026-07-28"}:
        raise RuntimeError(f"unsupported MCP_PROTOCOL_ERA: {era}")
    if version("mcp") != "2.1.1":
        raise RuntimeError(f"expected mcp 2.1.1, got {version('mcp')}")

    mode = "legacy" if era == "2025-11-25" else "2026-07-28"
    async with Client(url, mode=mode) as client:
        if client.protocol_version != era:
            raise RuntimeError(
                f"expected negotiated version {era}, got {client.protocol_version}"
            )

        listed = await client.list_tools()
        if not any(tool.name == "test_simple_text" for tool in listed.tools):
            raise RuntimeError("tools/list omitted test_simple_text")

        called = await client.call_tool("test_simple_text", {})
        expected = "This is a simple text response for testing."
        if not any(
            item.type == "text" and item.text == expected for item in called.content
        ):
            raise RuntimeError("tools/call returned an unexpected result")

    print(f"python-sdk=2.1.1 era={era} result=pass")


asyncio.run(main())
