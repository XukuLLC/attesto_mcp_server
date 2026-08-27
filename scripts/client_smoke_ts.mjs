import { readFile } from "node:fs/promises";
import { pathToFileURL } from "node:url";

const url = process.env.MCP_SERVER_URL;
const era = process.env.MCP_PROTOCOL_ERA;
const modulePath = process.env.MCP_TS_CLIENT_MODULE;

if (!url || !era || !modulePath) {
  throw new Error(
    "MCP_SERVER_URL, MCP_PROTOCOL_ERA, and MCP_TS_CLIENT_MODULE are required",
  );
}

if (!["2025-11-25", "2026-07-28"].includes(era)) {
  throw new Error(`unsupported MCP_PROTOCOL_ERA: ${era}`);
}

const moduleUrl = modulePath.startsWith("file:")
  ? new URL(modulePath)
  : pathToFileURL(modulePath);
const packageUrl = new URL("../package.json", moduleUrl);
const packageInfo = JSON.parse(await readFile(packageUrl, "utf8"));

if (packageInfo.name !== "@modelcontextprotocol/client" || packageInfo.version !== "2.0.0") {
  throw new Error(
    `expected @modelcontextprotocol/client 2.0.0, got ${packageInfo.name} ${packageInfo.version}`,
  );
}

const { Client, StreamableHTTPClientTransport } = await import(moduleUrl.href);
const client = new Client(
  { name: "attesto-mcp-server-smoke", version: "1.0.0" },
  {
    versionNegotiation:
      era === "2026-07-28"
        ? { mode: { pin: "2026-07-28" } }
        : { mode: "legacy" },
  },
);
const transport = new StreamableHTTPClientTransport(new URL(url));

try {
  await client.connect(transport);

  const discover = client.getDiscoverResult();
  if (era === "2026-07-28" && discover === undefined) {
    throw new Error("modern connection did not retain a discover result");
  }
  if (era === "2025-11-25" && discover !== undefined) {
    throw new Error("legacy connection unexpectedly retained a discover result");
  }

  const listed = await client.listTools();
  if (!listed.tools.some((tool) => tool.name === "test_simple_text")) {
    throw new Error("tools/list omitted test_simple_text");
  }

  const called = await client.callTool({ name: "test_simple_text", arguments: {} });
  const expected = "This is a simple text response for testing.";
  if (!called.content?.some((item) => item.type === "text" && item.text === expected)) {
    throw new Error("tools/call returned an unexpected result");
  }

  console.log(`typescript-sdk=2.0.0 era=${era} result=pass`);
} finally {
  await client.close();
}
